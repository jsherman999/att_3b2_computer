//! Boot the 630 MTG firmware headless and drive it with a timed event script.
//!
//! Usage: boot630 <rom-dir> <seconds> <out-prefix> [script]
//! Script lines (time in seconds):
//!   T move X Y         mouse counters (absolute)
//!   T down N | up N    mouse button 1..3
//!   T key "text"       bytes on the keyboard channel (duart1 B); \r \n \e escapes
//!   T host "text"      bytes from the host (on every A channel, enabled or not)
//!   T snap NAME        write <out-prefix>-NAME.pbm
//! Everything any channel transmits is printed.

use mtg630::{interleave_roms, Mtg630, CPU_HZ, VRAM_BYTES};
use std::{env, fs};

fn unescape(s: &str) -> Vec<u8> {
    let s = s.trim_matches('"');
    s.replace("\\r", "\r").replace("\\n", "\n").replace("\\e", "\x1b").into_bytes()
}

fn snap(t: &Mtg630, path: &str) {
    let mut pbm = b"P4\n1024 1024\n".to_vec();
    pbm.extend_from_slice(&t.bus.vram[..VRAM_BYTES]);
    fs::write(path, pbm).unwrap();
    println!("  screen -> {path}");
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let dir = &args[1];
    let secs: f64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5.0);
    let out = args.get(3).cloned().unwrap_or("630".into());
    let script = args.get(4).map(|p| fs::read_to_string(p).unwrap()).unwrap_or_default();
    let mut events: Vec<(f64, Vec<String>)> = script
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .map(|l| {
            let mut p = l.splitn(3, ' ');
            let t: f64 = p.next().unwrap().parse().unwrap();
            (t, p.map(String::from).collect())
        })
        .collect();
    events.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());

    let rd = |n: &str| fs::read(format!("{dir}/{n}")).expect(n);
    let rom = interleave_roms(&rd("460621-1.BIN"), &rd("460620-1.BIN"), &rd("460623-1.BIN"), &rd("460622-1.BIN"));
    let mut t = Mtg630::new(rom);
    if let Ok(v) = env::var("BRAMFILL") {
        let b = u8::from_str_radix(v.trim_start_matches("0x"), 16).unwrap();
        t.bus.bram.iter_mut().for_each(|x| *x = b);
        t.reset();
    }
    t.bus.trace_unknown = true;
    t.bus.trace_sr = env::var("TRACESR").is_ok();
    t.bus.callers_of = env::var("CALLERS").ok().map(|v| u32::from_str_radix(&v, 16).unwrap());
    if let Ok(w) = env::var("WATCH") {
        for a in w.split(',') { t.bus.watch.insert(u32::from_str_radix(a, 16).unwrap(), 0); }
    }
    let slice = CPU_HZ / 100;
    let mut now = 0.0;
    let mut ev = 0;
    while now < secs {
        while ev < events.len() && events[ev].0 <= now {
            let (at, e) = &events[ev];
            let arg = e.get(1).cloned().unwrap_or_default();
            println!("{at:6.2}s event: {} {}", e[0], arg);
            match e[0].as_str() {
                "move" => {
                    let v: Vec<u16> = arg.split(' ').filter_map(|x| x.parse().ok()).collect();
                    t.bus.mouse_x = v[0];
                    t.bus.mouse_y = v[1];
                    // MAME: movement pulses DUART 2 input IP2.
                    t.bus.duart2.set_input(2, false);
                    t.bus.duart2.set_input(2, true);
                }
                "down" => t.bus.buttons |= 1 << (arg.parse::<u8>().unwrap() - 1),
                "up" => t.bus.buttons &= !(1 << (arg.parse::<u8>().unwrap() - 1)),
                "key" => t.bus.duart1.receive(1, &unescape(&arg)),
                "scan" => {
                    // scan HH [HH...]: press and release each scan code
                    for h in arg.split(' ') {
                        let c = u8::from_str_radix(h, 16).unwrap();
                        t.key(c, true); t.run(CPU_HZ / 20); t.key(c, false); t.run(CPU_HZ / 20);
                    }
                }
                "host" => {
                    let b = unescape(&arg);
                    t.bus.duart1.receive(0, &b);
                    t.bus.duart2.receive(0, &b);
                }
                "snap" => snap(&t, &format!("{out}-{arg}.pbm")),
                "dump" => {
                    // dump ADDR LEN: hex bytes of RAM
                    let v: Vec<u32> = arg.split(' ').map(|x| u32::from_str_radix(x, 16).unwrap()).collect();
                    let bytes: Vec<String> = (0..v[1]).map(|i| format!("{:02x}", t.bus.read_ram((v[0] - 0x780000 + i) as usize))).collect();
                    println!("  dump {:06x}: {}", v[0], bytes.join(" "));
                }
                "ip1" | "ip2" => {
                    // set all six input pins of a DUART: ip1 0x00 = every line asserted (active low)
                    let v = u8::from_str_radix(arg.trim_start_matches("0x"), 16).unwrap();
                    let d = if e[0] == "ip1" { &mut t.bus.duart1 } else { &mut t.bus.duart2 };
                    for n in 0..6 { d.set_input(n, v & (1 << n) != 0); }
                }
                other => println!("unknown event {other}"),
            }
            ev += 1;
        }
        t.run(slice);
        now += 0.01;
        for (name, d) in [("duart1", &mut t.bus.duart1), ("duart2", &mut t.bus.duart2)] {
            for ch in 0..2 {
                let tx = d.take_transmitted(ch);
                if !tx.is_empty() {
                    let txt: String = tx.iter().map(|&b| if (32..127).contains(&b) { b as char } else { '.' }).collect();
                    println!("{now:6.2}s {name}{} tx {:02x?} |{txt}|", if ch == 0 { 'A' } else { 'B' }, tx);
                }
            }
        }
    }
    println!("final PC={:08x} SR={:04x}", t.pc(), t.cpu.get_sr());
    println!("{}", t.bus.duart1.describe());
    println!("{}", t.bus.duart2.describe());
    println!("duart1 reads {:?}\n       writes {:?}", t.bus.duart1.reads, t.bus.duart1.writes);
    println!("duart2 reads {:?}\n       writes {:?}", t.bus.duart2.reads, t.bus.duart2.writes);
    for ((pc, chip, reg, v), n) in &t.bus.sr_log { println!("  read pc={pc:06x} duart{chip} reg{reg} -> {v:02x} x{n}"); }
    println!("watch: {:x?}", t.bus.watch);
    if !t.bus.callers.is_empty() { println!("callers: {:x?}", t.bus.callers); }
    if let Ok(v) = env::var("VEC") {
        for a in v.split(',') {
            let o = (u32::from_str_radix(a, 16).unwrap() - 0x780000) as usize;
            let f = (0..4).fold(0u32, |acc, i| acc << 8 | t.bus.read_ram(o + i) as u32);
            println!("  ram vector {a} -> {f:06x}");
        }
    }
    println!("video-controller accesses: {:x?}", t.bus.unknown.iter().filter(|(a, _)| (0x700000..0x760000).contains(*a)).take(30).collect::<Vec<_>>());
    println!("unknown: {:x?}", t.bus.unknown.iter().filter(|(a, _)| !(0x700000..0x760000).contains(*a)).take(30).collect::<Vec<_>>());
    if !t.bus.video_regs.is_empty() {
        println!("video regs: {:x?}", t.bus.video_regs);
    }
    snap(&t, &format!("{out}-final.pbm"));
    for lvl in 1..=6usize {
        let base = 0x3f38 + (lvl - 1) * 0x72;
        let rd16 = |o: usize| (t.bus.read_ram(o) as u16) << 8 | t.bus.read_ram(o + 1) as u16;
        let rd32 = |o: usize| (rd16(o) as u32) << 16 | rd16(o + 2) as u32;
        let n = rd16(base);
        let mut hs = vec![];
        for i in 0..8usize {
            let e = base + 2 + i * 0xe;
            if rd16(e) != 0 { hs.push(format!("[{}] flag={} fn={:06x}", i, rd16(e), rd32(e + 2))); }
        }
        println!("  level {lvl}: count={n} {}", hs.join("  "));
    }
    let rd32r = |o: usize| (0..4).fold(0u32, |a, i| a << 8 | t.bus.read_ram(o + i) as u32);
    for port in [0x784f34u32, 0x784f96] {
        let p = rd32r((port - 0x780000 + 0x40) as usize);
        let base = if (0x780000..0x800000).contains(&p) { rd32r((p - 0x780000 + 4) as usize) } else { 0 };
        println!("  port struct {port:06x}: info={p:06x} device base={base:06x}");
    }
    for lvl in 1..=7u32 {
        let a = 0x00ff_fff1 | (lvl << 1);
        let vec = t.bus.bram[((a & 0x3fff) >> 1) as usize] as u32;
        let handler = u32::from_be_bytes([0,1,2,3].map(|i| (t.bus.rom.get((vec * 4 + i) as usize).copied()).unwrap_or(0)));
        let o = (handler - 0x780000) as usize;
        let r = |i: usize| t.bus.read_ram(o + i);
        let target = u32::from_be_bytes([r(2), r(3), r(4), r(5)]);
        println!("  IRQ{lvl}: vector {vec:3} -> {handler:06x}: {:02x}{:02x} -> {target:06x}", r(0), r(1));
    }
}
