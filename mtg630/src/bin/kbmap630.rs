//! Press every scan code on an emulated 630 (alone, with Shift, with Ctrl) and
//! record what the terminal sends to the host on the Main EIA port.
use mtg630::{interleave_roms, Mtg630, CPU_HZ};
use std::{env, fs};

fn main() {
    let dir = env::args().nth(1).expect("rom dir");
    let rd = |n: &str| fs::read(format!("{dir}/{n}")).expect(n);
    let rom = interleave_roms(&rd("460621-1.BIN"), &rd("460620-1.BIN"), &rd("460623-1.BIN"), &rd("460622-1.BIN"));
    let mut t = Mtg630::new(rom);
    t.bus.bram.iter_mut().for_each(|b| *b = 0xff); // factory defaults
    t.reset();
    for a in [0x6882u32, 0x68be, 0x68e0, 0x68e4, 0x68ee, 0x6926, 0x692e, 0x6984, 0x6990] { t.bus.watch.insert(a, 0); }
    if let Ok(v) = env::var("KWATCH") { t.bus.watch.insert(u32::from_str_radix(&v, 16).unwrap(), 0); }
    t.run(CPU_HZ * 40); // boot, selftest, H1 window
    for ((pc, chip, reg, v), n) in &t.bus.sr_log { if *chip == 1 && (*reg == 11 || *reg == 9) { eprintln!("  pc={pc:06x} reg{reg} -> {v:02x} x{n}"); } }
    // Click button 1 inside the H1 window so it is current (keyboard focus).
    for (x, y) in [(400u16, 500u16), (300, 600), (200, 700)] {
        t.bus.mouse_x = x; t.bus.mouse_y = y; t.run(CPU_HZ / 10);
    }
    t.bus.buttons |= 1; t.run(CPU_HZ / 5); t.bus.buttons &= !1; t.run(CPU_HZ);
    t.bus.duart1.take_transmitted(0);
    let rd16 = |t: &Mtg630, a: u32| (t.bus.read_ram((a - 0x780000) as usize) as u16) << 8 | t.bus.read_ram((a - 0x780000 + 1) as usize) as u16;
    eprintln!("watch after boot: {:x?}", t.bus.watch);
    eprintln!("kbd type {:04x} table {:04x}{:04x} alive {:04x}", rd16(&t, 0x780112), rd16(&t, 0x7801b6), rd16(&t, 0x7801b8), rd16(&t, 0x780110));
    eprintln!("{}", t.bus.duart1.describe());
    let (shift, ctrl) = (0x1d, 0x1e);
    for (label, modifier) in [("plain", None), ("shift", Some(shift)), ("ctrl", Some(ctrl))] {
        for code in 0..0x80u8 {
            if code == shift || code == ctrl { continue; }
            if let Some(m) = modifier { t.key(m, true); t.run(CPU_HZ / 20); }
            t.key(code, true);
            t.run(CPU_HZ / 10);
            t.key(code, false);
            t.run(CPU_HZ / 10);
            if let Some(m) = modifier { t.key(m, false); t.run(CPU_HZ / 20); }
            let out = t.bus.duart1.take_transmitted(0);
            if code == 0x4a && label == "plain" {
                eprintln!("watch after 'a' key: {:x?}", t.bus.watch);
                eprintln!("duart1 CR log (chA): {:02x?}", t.bus.duart1.cr_log.iter().filter(|(c, _)| *c == 0).map(|(_, v)| *v).collect::<Vec<_>>());
            }
            if !out.is_empty() {
                println!("{label} {code:02x} -> {}", out.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(" "));
            }
        }
    }
}
