//! Press every scan code on an emulated 630 (alone, with Shift, with Ctrl) and
//! record what the terminal sends to the host on the Main EIA port.
//!
//! Usage: kbmap630 <rom-dir>   (prints "<modifier> <code> -> <hex bytes>")
use mtg630::{interleave_roms, Mtg630, CPU_HZ};
use std::{env, fs};

const SHIFT: u8 = 0x1d;
const CTRL: u8 = 0x1e;

fn main() {
    let dir = env::args().nth(1).expect("rom dir");
    let rd = |n: &str| fs::read(format!("{dir}/{n}")).expect(n);
    let rom = interleave_roms(&rd("460621-1.BIN"), &rd("460620-1.BIN"), &rd("460623-1.BIN"), &rd("460622-1.BIN"));
    let mut t = Mtg630::new(rom);
    t.bus.bram.iter_mut().for_each(|b| *b = 0xff); // factory defaults: H1 window on Main EIA
    t.reset();
    t.run(CPU_HZ * 40); // boot, self-test, H1 window
    t.bus.duart1.take_transmitted(0);
    let boot_cmds = t.keyboard_cmds.len();
    let gap = env::var("GAPMS").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(50) * CPU_HZ / 1000;
    for (label, modifier) in [("plain", None), ("shift", Some(SHIFT)), ("ctrl", Some(CTRL))] {
        for code in 0..0x80u8 {
            if code == SHIFT || code == CTRL {
                continue;
            }
            if let Some(m) = modifier { t.key(m, true); t.run(gap); }
            t.key(code, true);
            t.run(gap);
            t.key(code, false);
            t.run(gap);
            if let Some(m) = modifier { t.key(m, false); t.run(gap); }
            t.run(CPU_HZ / 10); // let the vertical-blank transmit poll drain it
            let out = t.bus.duart1.take_transmitted(0);
            if env::var("TIMELINE").is_ok() && label == "plain" {
                let start = t.cycles - 3 * gap - CPU_HZ / 10;
                let cmds: Vec<String> = t.keyboard_cmds.iter().filter(|(c, _)| *c >= start)
                    .map(|(c, b)| format!("{b:02x}@{}ms", (c - start) * 1000 / CPU_HZ)).collect();
                eprintln!("{code:02x} out={out:02x?} cmds={cmds:?}");
            }
            if !out.is_empty() {
                println!("{label} {code:02x} -> {}", out.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(" "));
            }
        }
    }
    eprintln!("keyboard commands: {} during boot, then {:02x?}", boot_cmds, t.keyboard_cmds[boot_cmds..].iter().map(|x| x.1).collect::<Vec<_>>());
}
