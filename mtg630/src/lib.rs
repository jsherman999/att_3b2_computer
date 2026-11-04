//! AT&T / Teletype 630 MTG terminal emulator core.
//!
//! Hardware (from MAME's att630 driver, the bitsavers board photos and the ROMs):
//!   000000-03FFFF  ROM, 4 x 64 KB EPROMs interleaved even/odd (460621/460620, 460623/460622)
//!   100000-1FFFFF  cartridge slot (empty)
//!   200000-20001F  DUART 1 (SCN2681, odd bytes)  -> IRQ 3
//!   200020-20003F  DUART 2 (SCN2681, odd bytes)  -> IRQ 2
//!   200040/42      mouse X / Y counters (12 bit)
//!   200045         mouse buttons, active low: 0x04 = 1, 0x02 = 2, 0x01 = 3; reading clears IRQ 1
//!   700000-75FFFF  video controller (registers not yet understood; writes are logged)
//!   760000-77FFFF  video RAM, 1024 x 1024, 1 bit per pixel, MSB first
//!   780000-7FFFFF  program RAM (512 KB)
//!   E00000-FFFFFF  8 KB battery-backed RAM on odd bytes (mirrored); interrupt
//!                  vectors are fetched from it during interrupt acknowledge
//!   vertical blank (60 Hz) -> IRQ 1

pub mod duart;
pub mod keymap;

use duart::Duart;
use m68k::{AddressBus, CpuCore, CpuType};
use std::collections::BTreeMap;

pub const CPU_HZ: u64 = 10_000_000;
pub const WIDTH: usize = 1024;
pub const HEIGHT: usize = 1024;
pub const VRAM_BYTES: usize = WIDTH * HEIGHT / 8;
pub const BRAM_BYTES: usize = 8192;
const VBLANK_CYCLES: u64 = CPU_HZ / 60;

pub struct Bus {
    pub rom: Vec<u8>,
    ram: Vec<u8>,
    pub vram: Vec<u8>,
    pub bram: Vec<u8>,
    pub duart1: Duart,
    pub duart2: Duart,
    pub mouse_x: u16,
    pub mouse_y: u16,
    pub buttons: u8, // bit0 = button 1, bit1 = button 2, bit2 = button 3 (1 = pressed)
    pub vblank_irq: bool,
    pub video_regs: BTreeMap<u32, u16>,
    /// Unmapped / unexplained accesses: address -> count (for reverse engineering).
    pub unknown: BTreeMap<u32, u64>,
    pub trace_unknown: bool,
    /// PC of the instruction being executed (for access tracing).
    pub cur_pc: u32,
    /// (pc, chip, reg, value) for status/data register reads, when enabled.
    pub sr_log: BTreeMap<(u32, u8, u8, u8), u64>,
    pub trace_sr: bool,
    /// PCs to count hits on (debugging).
    pub watch: BTreeMap<u32, u64>,
    /// For this PC, count the return addresses found on the stack (who called it).
    pub callers_of: Option<u32>,
    pub callers: BTreeMap<u32, u64>,
    /// When set, count every PC executed while the current process (78020E) is this one.
    pub proc_watch: Option<u32>,
    pub proc_pcs: BTreeMap<u32, u64>,
    /// Log writes to these addresses: (pc, address, value). For debugging.
    pub write_watch: Vec<u32>,
    pub write_log: Vec<(u32, u32, u8)>,
}

impl Bus {
    fn note(&mut self, addr: u32) {
        if self.trace_unknown {
            *self.unknown.entry(addr).or_insert(0) += 1;
        }
    }

    fn read8(&mut self, a: u32) -> u8 {
        let a = a & 0x00ff_ffff;
        match a {
            0x000000..=0x03ffff => self.rom[a as usize],
            0x040000..=0x1fffff => { self.note(a); 0xff }
            0x200000..=0x20003f => {
                if a & 1 == 0 { return 0xff; }
                let chip = if a < 0x200020 { 1 } else { 2 };
                let reg = (((a - 0x200000) & 0x1f) >> 1) as u8;
                let v = if chip == 1 { self.duart1.read(reg) } else { self.duart2.read(reg) };
                if self.trace_sr && matches!(reg, 1 | 3 | 9 | 11) {
                    *self.sr_log.entry((self.cur_pc, chip, reg, v)).or_insert(0) += 1;
                }
                v
            }
            0x200040 => (self.mouse_x >> 8) as u8 & 0x0f,
            0x200041 => self.mouse_x as u8,
            0x200042 => (self.mouse_y >> 8) as u8 & 0x0f,
            0x200043 => self.mouse_y as u8,
            0x200045 => {
                self.vblank_irq = false;
                // Active low: button1 -> 0x04, button2 -> 0x02, button3 -> 0x01.
                let mut v = 0xff;
                if self.buttons & 1 != 0 { v &= !0x04; }
                if self.buttons & 2 != 0 { v &= !0x02; }
                if self.buttons & 4 != 0 { v &= !0x01; }
                v
            }
            0x700000..=0x75ffff => {
                self.note(a);
                let w = *self.video_regs.get(&(a & !1)).unwrap_or(&0);
                if a & 1 == 0 { (w >> 8) as u8 } else { w as u8 }
            }
            0x760000..=0x77ffff => self.vram[(a - 0x760000) as usize],
            0x780000..=0x7fffff => self.ram[(a - 0x780000) as usize],
            0xe00000..=0xffffff => if a & 1 == 1 { self.bram[((a & 0x3fff) >> 1) as usize] } else { 0xff },
            _ => { self.note(a); 0xff }
        }
    }

    fn write8(&mut self, a: u32, v: u8) {
        let a = a & 0x00ff_ffff;
        if !self.write_watch.is_empty() && self.write_watch.contains(&a) && self.write_log.len() < 100_000 {
            self.write_log.push((self.cur_pc, a, v));
        }
        match a {
            0x200000..=0x20001f => if a & 1 == 1 { self.duart1.write(((a - 0x200000) >> 1) as u8, v) },
            0x200020..=0x20003f => if a & 1 == 1 { self.duart2.write(((a - 0x200020) >> 1) as u8, v) },
            0x700000..=0x75ffff => {
                self.note(a);
                let e = self.video_regs.entry(a & !1).or_insert(0);
                *e = if a & 1 == 0 { (*e & 0x00ff) | (v as u16) << 8 } else { (*e & 0xff00) | v as u16 };
            }
            0x760000..=0x77ffff => self.vram[(a - 0x760000) as usize] = v,
            0x780000..=0x7fffff => self.ram[(a - 0x780000) as usize] = v,
            0xe00000..=0xffffff => if a & 1 == 1 { self.bram[((a & 0x3fff) >> 1) as usize] = v },
            _ => self.note(a),
        }
    }

    pub fn read_ram(&self, off: usize) -> u8 { self.ram[off] }
    pub fn read_ram_long(&self, off: usize) -> u32 {
        (0..4).fold(0u32, |a, i| a << 8 | self.ram[off + i] as u32)
    }

    /// Interrupt wiring, worked out from the firmware's handler registry:
    ///   5: DUART1 OP4 (Main EIA, channel A receive ready)
    ///   4: DUART2 OP4 (Aux EIA, channel A receive ready)
    ///   3: DUART1 INTR (counter/timer: the system tick)
    ///   2: DUART2 INTR (mouse, input-port change) and DUART1 OP5 (keyboard receive)
    ///   1: vertical blank
    fn irq_level(&self) -> u8 {
        let d1 = &self.duart1;
        let d2 = &self.duart2;
        // Only RxRDYA (OP4) interrupts. The firmware programs OP6 as TxRDYA too, but its
        // level 5/4 handler (EBB2) only drains the receiver; transmit is polled from the
        // vertical-blank handler (EED4/F064 -> ECF8). Wiring OP6 here makes an interrupt storm.
        if d1.opcr_bits() & 0x10 != 0 && d1.op_asserted(4) {
            5
        } else if d2.opcr_bits() & 0x10 != 0 && d2.op_asserted(4) {
            4
        } else if d1.irq() {
            3
        } else if d2.irq() || (d1.opcr_bits() & 0x20 != 0 && d1.op_asserted(5)) {
            2
        } else if self.vblank_irq {
            1
        } else {
            0
        }
    }
}

impl AddressBus for Bus {
    fn read_byte(&mut self, address: u32) -> u8 { self.read8(address) }
    fn read_word(&mut self, address: u32) -> u16 {
        (self.read8(address) as u16) << 8 | self.read8(address.wrapping_add(1)) as u16
    }
    fn read_long(&mut self, address: u32) -> u32 {
        (self.read_word(address) as u32) << 16 | self.read_word(address.wrapping_add(2)) as u32
    }
    fn write_byte(&mut self, address: u32, value: u8) { self.write8(address, value) }
    fn write_word(&mut self, address: u32, value: u16) {
        self.write8(address, (value >> 8) as u8);
        self.write8(address.wrapping_add(1), value as u8);
    }
    fn write_long(&mut self, address: u32, value: u32) {
        self.write_word(address, (value >> 16) as u16);
        self.write_word(address.wrapping_add(2), value as u16);
    }
    /// The 630 answers interrupt acknowledge from battery RAM (MAME: cpu space = program):
    /// the IACK cycle reads the odd byte at FFFFF0 | level << 1.
    fn interrupt_acknowledge(&mut self, level: u8) -> u32 {
        let a = 0x00ff_fff1 | ((level as u32) << 1);
        self.read8(a) as u32
    }
}

pub struct Mtg630 {
    pub cpu: CpuCore,
    pub bus: Bus,
    /// Keyboard type reported when the terminal asks (0x84): ID byte = type - 1.
    /// 0x10 = type 0x11, the 630's 98-key keyboard.
    pub keyboard_id: u8,
    /// Commands the terminal sent to the keyboard (bell, click, LEDs...), with the
    /// cycle count when each was sent. Capped; for debugging.
    pub keyboard_cmds: Vec<(u64, u8)>,
    kbd_reply_at: Option<u64>,
    kbd_identified: bool,
    pub cycles: u64,
    next_vblank: u64,
}

impl Mtg630 {
    /// `rom` is the 256 KB image already interleaved (see `interleave_roms`).
    pub fn new(rom: Vec<u8>) -> Self {
        let mut cpu = CpuCore::new();
        cpu.set_cpu_type(CpuType::M68000);
        let mut bus = Bus {
            rom,
            ram: vec![0; 0x80000],
            vram: vec![0; VRAM_BYTES],
            bram: vec![0; BRAM_BYTES],
            duart1: Duart::new("duart1", CPU_HZ),
            duart2: Duart::new("duart2", CPU_HZ),
            mouse_x: 512,
            mouse_y: 512,
            buttons: 0,
            vblank_irq: false,
            video_regs: BTreeMap::new(),
            unknown: BTreeMap::new(),
            trace_unknown: false,
            cur_pc: 0,
            sr_log: BTreeMap::new(),
            trace_sr: false,
            watch: BTreeMap::new(),
            callers_of: None,
            callers: BTreeMap::new(),
            proc_watch: None,
            proc_pcs: BTreeMap::new(),
            write_watch: Vec::new(),
            write_log: Vec::new(),
        };
        // Modem-control inputs (active low). The firmware's "port ready" check (EB76)
        // reads the input port and treats the line as hung up, silently dropping
        // everything typed, unless one of the masked lines is asserted:
        //   DUART 1 IP4/IP5 = Main EIA (mask 0x30), DUART 2 IP3 = Aux EIA (mask 0x08).
        // The other inputs are boot straps and must stay high (see docs/630-mtg-notes.md).
        bus.duart1.set_input(4, false);
        bus.duart1.set_input(5, false);
        bus.duart2.set_input(3, false);
        cpu.reset(&mut bus);
        Mtg630 { cpu, bus, keyboard_id: 0x10, keyboard_cmds: Vec::new(), kbd_reply_at: None, kbd_identified: false, cycles: 0, next_vblank: VBLANK_CYCLES }
    }

    pub fn reset(&mut self) {
        self.cpu.reset(&mut self.bus);
        self.kbd_identified = false;
        self.kbd_reply_at = None;
    }

    /// Run for about `cycles` CPU cycles.
    pub fn run(&mut self, cycles: u64) {
        let end = self.cycles + cycles;
        while self.cycles < end {
            self.bus.cur_pc = self.cpu.pc;
            if let Some(n) = self.bus.watch.get_mut(&self.cpu.pc) { *n += 1; }
            if self.bus.callers_of == Some(self.cpu.pc) {
                let sp = self.cpu.dar[15];
                let ret = self.bus.read_long(sp);
                *self.bus.callers.entry(ret).or_insert(0) += 1;
            }
            if let Some(p) = self.bus.proc_watch {
                if self.bus.read_ram_long(0x20e) == p {
                    *self.bus.proc_pcs.entry(self.cpu.pc).or_insert(0) += 1;
                }
            }
            let level = self.bus.irq_level();
            self.cpu.set_irq(level);
            let used = match self.cpu.step(&mut self.bus) {
                m68k::StepResult::Ok { cycles } => cycles.max(4) as u64,
                _ => 4,
            };
            self.cycles += used;
            self.bus.duart1.tick(used);
            if self.bus.duart1.has_transmitted(1) { self.service_keyboard(); }
            if let Some(at) = self.kbd_reply_at {
                if self.cycles >= at {
                    self.kbd_reply_at = None;
                    let id = self.keyboard_id;
                    self.bus.duart1.receive_marked(1, id);
                }
            }
            self.bus.duart2.tick(used);
            if self.cycles >= self.next_vblank {
                self.next_vblank += VBLANK_CYCLES;
                self.bus.vblank_irq = true;
                // The mouse interface strobes DUART 2's IP2 every frame; the firmware's
                // level-2 handler uses that as a tick (it counts down process timers),
                // so it must keep coming even when the mouse is still.
                self.bus.duart2.set_input(2, false);
                self.bus.duart2.set_input(2, true);
            }
        }
    }

    /// The keyboard side of DUART 1 channel B. The terminal's commands (0x84/0x8C:
    /// 0x88 | click volume, LEDs, ...) are settings, not requests. The keyboard sends
    /// its ID once, after power-up: an ID byte arriving later means "keyboard
    /// re-plugged" to the firmware (6DE4 -> 5F96), which resets keyboard state and
    /// ignores keys for about a second. So answer only the first command after reset,
    /// which arrives once the firmware is waiting for the keyboard (state 6D48).
    fn service_keyboard(&mut self) {
        for c in self.bus.duart1.take_transmitted(1) {
            if !self.kbd_identified {
                self.kbd_identified = true;
                self.kbd_reply_at = Some(self.cycles + CPU_HZ / 50);
            }
            if self.keyboard_cmds.len() < 100_000 { self.keyboard_cmds.push((self.cycles, c)); }
        }
    }

    /// A key event: scan code 0x00-0x7f, `down` = pressed. On this keyboard bit 7
    /// set means "make" (pressed) and clear means "break" (released).
    pub fn key(&mut self, code: u8, down: bool) {
        self.bus.duart1.receive(1, &[if down { code | 0x80 } else { code & 0x7f }]);
    }

    pub fn pc(&self) -> u32 { self.cpu.pc }
}

/// Build the 256 KB program image from the four EPROMs, as MAME's ROM_LOAD16_BYTE does.
pub fn interleave_roms(r621: &[u8], r620: &[u8], r623: &[u8], r622: &[u8]) -> Vec<u8> {
    let mut rom = vec![0u8; 0x40000];
    for i in 0..0x10000 {
        rom[2 * i] = r621[i];
        rom[2 * i + 1] = r620[i];
        rom[0x20000 + 2 * i] = r623[i];
        rom[0x20000 + 2 * i + 1] = r622[i];
    }
    rom
}
