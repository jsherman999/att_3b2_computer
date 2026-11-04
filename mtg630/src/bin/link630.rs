//! Run the 630 headless, wired to a host over TCP (the 3B2's PORTS line), and drive
//! it from a script: wait for host text, type on the 630 keyboard, save the screen.
//!
//! Usage: link630 <rom-dir> <host:port> <script> [out-prefix]
//! Script lines:
//!   expect TEXT     wait (up to 60 s) until the host has sent TEXT
//!   type TEXT       type TEXT on the keyboard; \r \t \e \\ escapes
//!   sleep MS        run for MS milliseconds
//!   snap NAME       write <out-prefix>-NAME.pbm
//!   pcs MS          sample the CPU's PC for MS milliseconds (where is it stuck?)
//! Exits 0 when every step succeeded, 1 on a timeout.
use mtg630::{interleave_roms, keymap, Mtg630, CPU_HZ, VRAM_BYTES};
use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};
use std::{env, fs, process};

struct Link {
    t: Mtg630,
    sock: TcpStream,
    seen: Vec<u8>,
    /// Host output before this offset has already been matched by an `expect`.
    cursor: usize,
}

impl Link {
    /// Run `ms` milliseconds of terminal time, shuttling bytes to and from the host.
    fn run(&mut self, ms: u64) {
        for _ in 0..ms.max(1) {
            self.t.run(CPU_HZ / 1000);
            let mut buf = [0u8; 4096];
            match self.sock.read(&mut buf) {
                Ok(0) => { eprintln!("host closed the connection"); process::exit(1) }
                Ok(n) => {
                    self.t.bus.duart1.receive(0, &buf[..n]);
                    self.seen.extend_from_slice(&buf[..n]);
                }
                Err(e) if e.kind() == ErrorKind::WouldBlock => {}
                Err(e) => { eprintln!("read: {e}"); process::exit(1) }
            }
            let out = self.t.bus.duart1.take_transmitted(0);
            if !out.is_empty() {
                self.sock.write_all(&out).unwrap();
            }
            // Keep roughly in step with the host: the 3B2 runs in real time.
            std::thread::sleep(Duration::from_micros(300));
        }
    }

    fn press(&mut self, code: u8, shift: bool, ctrl: bool) {
        if ctrl { self.t.key(keymap::CTRL, true); }
        if shift { self.t.key(keymap::SHIFT, true); }
        self.t.key(code, true);
        self.run(15);
        self.t.key(code, false);
        if shift { self.t.key(keymap::SHIFT, false); }
        if ctrl { self.t.key(keymap::CTRL, false); }
        self.run(25);
    }
}

fn unescape(s: &str) -> String {
    s.replace("\\r", "\r").replace("\\t", "\t").replace("\\e", "\x1b").replace("\\\\", "\\")
}

fn main() {
    let a: Vec<String> = env::args().collect();
    if a.len() < 4 {
        eprintln!("usage: link630 <rom-dir> <host:port> <script> [out-prefix]");
        process::exit(2);
    }
    let rd = |n: &str| fs::read(format!("{}/{n}", a[1])).expect(n);
    let rom = interleave_roms(&rd("460621-1.BIN"), &rd("460620-1.BIN"), &rd("460623-1.BIN"), &rd("460622-1.BIN"));
    let mut t = Mtg630::new(rom);
    t.bus.bram.iter_mut().for_each(|b| *b = 0xff); // factory defaults: Host1 on Main EIA, 9600
    t.reset();
    let sock = TcpStream::connect(&a[2]).expect("connect");
    sock.set_nonblocking(true).unwrap();
    let out = a.get(4).cloned().unwrap_or("link630".into());
    let mut l = Link { t, sock, seen: Vec::new(), cursor: 0 };
    println!("booting the 630");
    l.run(30_000);
    if env::var("BRAMDUMP").is_ok() {
        // Per-host setup records: 0x21 BRAM bytes (0x42 bus bytes) each, from E00041.
        for h in 0..4 {
            // E00069 + 0x42*port: XON/XOFF; E0006D + 0x42*port: keep XON/XOFF in layers (F3D4)
            let at = |a: usize| l.t.bus.bram[((a + 0x42 * h) & 0x3fff) >> 1];
            println!("  port {h}: E00069 xon/xoff={:02x}  E0006D in-layers={:02x}", at(0xe00069), at(0xe0006d));
        }
    }
    let script = fs::read_to_string(&a[3]).expect("script");
    for line in script.lines().filter(|l| !l.trim().is_empty() && !l.starts_with('#')) {
        let (cmd, arg) = line.split_once(' ').unwrap_or((line, ""));
        match cmd {
            "expect" => {
                let want = unescape(arg).into_bytes();
                let t0 = Instant::now();
                let find = |s: &[u8]| s.windows(want.len()).position(|w| w == want.as_slice());
                loop {
                    if let Some(i) = find(&l.seen[l.cursor..]) {
                        l.cursor += i + want.len();
                        break;
                    }
                    if t0.elapsed() > Duration::from_secs(60) {
                        println!("TIMEOUT waiting for {arg:?}; host sent: {:?}",
                                 String::from_utf8_lossy(&l.seen[l.seen.len().saturating_sub(300)..]));
                        process::exit(1);
                    }
                    l.run(50);
                }
                println!("got {arg:?}");
            }
            "type" => {
                for c in unescape(arg).chars() {
                    match keymap::ascii(c) {
                        Some((k, s, ctl)) => l.press(k, s, ctl),
                        None => println!("no key for {c:?}"),
                    }
                }
                println!("typed {arg:?}");
            }
            "sleep" => l.run(arg.parse().unwrap()),
            "duart" => {
                println!("  {}", l.t.bus.duart1.describe());
                println!("  main EIA {}", l.t.bus.duart1.tx_state(0));
                let crs: Vec<String> = l.t.bus.duart1.cr_log.iter().filter(|e| e.0 == 0).map(|e| format!("{:02x}", e.1)).collect();
                println!("  channel A commands (first {}): {}", crs.len(), crs.join(" "));
            }
            "pcs" => {
                // pcs MS: sample the PC for MS milliseconds and print the busiest addresses
                let mut hits = std::collections::BTreeMap::<u32, u64>::new();
                let mut srs = std::collections::BTreeMap::<u16, u64>::new();
                for _ in 0..arg.parse::<u64>().unwrap() * 10 {
                    l.t.run(CPU_HZ / 10_000);
                    *hits.entry(l.t.pc() & !0xf).or_default() += 1;
                    *srs.entry(l.t.sr() & 0x0700).or_default() += 1;
                }
                println!("  interrupt mask samples: {srs:x?}");
                let mut v: Vec<_> = hits.into_iter().collect();
                v.sort_by(|a, b| b.1.cmp(&a.1));
                for (pc, n) in v.iter().take(12) { println!("  pc {pc:06x}.. x{n}"); }
            }
            "snap" => {
                let mut pbm = b"P4\n1024 1024\n".to_vec();
                pbm.extend_from_slice(&l.t.bus.vram[..VRAM_BYTES]);
                let p = format!("{out}-{arg}.pbm");
                fs::write(&p, pbm).unwrap();
                println!("screen -> {p}");
            }
            other => println!("unknown step {other}"),
        }
    }
    if env::var("KBDCMDS").is_ok() {
        for (at, c) in &l.t.keyboard_cmds { println!("  kbd cmd {:8.3}s {c:02x}", *at as f64 / CPU_HZ as f64); }
    }
    println!("host output tail: {:?}", String::from_utf8_lossy(&l.seen[l.seen.len().saturating_sub(400)..]));
}
