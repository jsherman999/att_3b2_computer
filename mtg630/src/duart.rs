//! Signetics SCN2681 DUART: two serial channels, a 6-bit input port, an 8-bit
//! output port, and a counter/timer. Timing is driven by CPU cycles (`tick`), so
//! the whole terminal stays deterministic; the frontend paces it to real time.
//!
//! Register map (offset = register number; the 630 puts the chip on odd bytes):
//!   read:  0 MR1/2A  1 SRA  2 -  3 RHRA  4 IPCR  5 ISR  6 CTU  7 CTL
//!          8 MR1/2B  9 SRB 10 - 11 RHRB 12 -  13 IP  14 start-ctr 15 stop-ctr
//!   write: 0 MR1/2A  1 CSRA 2 CRA 3 THRA 4 ACR  5 IMR 6 CTUR 7 CTLR
//!          8 MR1/2B  9 CSRB 10 CRB 11 THRB 12 - 13 OPCR 14 set-OP 15 reset-OP

use std::collections::VecDeque;

pub const CLOCK_HZ: u64 = 3_686_400; // X1 crystal
const BAUD_ACR0: [u32; 13] = [50, 110, 134, 200, 300, 600, 1200, 1050, 2400, 4800, 7200, 9600, 38400];
const BAUD_ACR1: [u32; 13] = [75, 110, 134, 150, 300, 600, 1200, 2000, 2400, 4800, 1800, 9600, 19200];

// Status register bits
const SR_RXRDY: u8 = 0x01;
const SR_FFULL: u8 = 0x02;
const SR_TXRDY: u8 = 0x04;
const SR_TXEMT: u8 = 0x08;
const SR_OVERRUN: u8 = 0x10;

// Interrupt status bits
const ISR_TXRDYA: u8 = 0x01;
const ISR_RXRDYA: u8 = 0x02;
const ISR_COUNTER: u8 = 0x08;
const ISR_TXRDYB: u8 = 0x10;
const ISR_RXRDYB: u8 = 0x20;
const ISR_IPCHANGE: u8 = 0x80;

#[derive(Default)]
struct Channel {
    mr: [u8; 2],
    mr_ptr: usize,
    csr: u8,
    rx_enabled: bool,
    tx_enabled: bool,
    rx_fifo: VecDeque<(u8, u8)>,    // the chip's 3-byte FIFO: (byte, SR error bits)
    rx_pending: VecDeque<(u8, u8)>, // bytes still "on the wire" from the outside world
    rx_wait: u64,               // cycles until the next pending byte lands in the FIFO
    tx_holding: Option<u8>,
    tx_wait: u64,               // cycles until the holding byte is "sent"
    tx_out: VecDeque<u8>,       // bytes that have left the chip
    overrun: bool,
    /// THR writes lost: transmitter disabled, or a byte still waiting (debug counters).
    pub thr_lost_disabled: u64,
    pub thr_overwritten: u64,
}

impl Channel {
    fn status(&self) -> u8 {
        let mut s = 0;
        if !self.rx_fifo.is_empty() {
            s |= SR_RXRDY;
        }
        if self.rx_fifo.len() >= 3 {
            s |= SR_FFULL;
        }
        if self.tx_enabled && self.tx_holding.is_none() {
            s |= SR_TXRDY | SR_TXEMT;
        }
        if self.overrun {
            s |= SR_OVERRUN;
        }
        // Error bits (parity 0x20, framing 0x40, break 0x80) belong to the
        // character at the head of the FIFO.
        if let Some(&(_, err)) = self.rx_fifo.front() {
            s |= err & 0xe0;
        }
        s
    }
}

pub struct Duart {
    pub name: &'static str,
    ch: [Channel; 2],
    acr: u8,
    imr: u8,
    isr_counter: bool,
    ctr_preset: u16,
    ctr_value: u32,         // cycles remaining in this half period (timer mode)
    ctr_running: bool,
    ctr_half: bool,
    ipcr: u8,
    input_port: u8,         // pins IP0..IP5 (1 = high)
    opcr: u8,
    output_port: u8,        // OP register; pins are its complement
    cpu_hz: u64,
    pub reads: [u64; 16],
    pub writes: [u64; 16],
    pub cr_log: Vec<(usize, u8)>,
}

impl Duart {
    pub fn new(name: &'static str, cpu_hz: u64) -> Self {
        Duart {
            name,
            ch: [Channel::default(), Channel::default()],
            acr: 0,
            imr: 0,
            isr_counter: false,
            ctr_preset: 0xffff,
            ctr_value: 0,
            ctr_running: false,
            ctr_half: false,
            ipcr: 0,
            input_port: 0x3f,
            opcr: 0,
            output_port: 0,
            cpu_hz,
            reads: [0; 16],
            writes: [0; 16],
            cr_log: Vec::new(),
        }
    }

    fn baud(&self, ch: usize, rx: bool) -> u32 {
        let sel = if rx { self.ch[ch].csr >> 4 } else { self.ch[ch].csr & 0x0f } as usize;
        let table = if self.acr & 0x80 != 0 { &BAUD_ACR1 } else { &BAUD_ACR0 };
        table.get(sel).copied().unwrap_or(9600)
    }

    /// CPU cycles per character (10 bits) at the channel's current speed.
    fn char_cycles(&self, ch: usize, rx: bool) -> u64 {
        self.cpu_hz * 10 / self.baud(ch, rx).max(50) as u64
    }

    pub fn isr(&self) -> u8 {
        let mut isr = 0;
        let a = self.ch[0].status();
        let b = self.ch[1].status();
        if a & SR_TXRDY != 0 { isr |= ISR_TXRDYA; }
        if a & SR_RXRDY != 0 { isr |= ISR_RXRDYA; }
        if b & SR_TXRDY != 0 { isr |= ISR_TXRDYB; }
        if b & SR_RXRDY != 0 { isr |= ISR_RXRDYB; }
        if self.isr_counter { isr |= ISR_COUNTER; }
        if self.ipcr & 0x0f & self.acr != 0 { isr |= ISR_IPCHANGE; }
        isr
    }

    pub fn irq(&self) -> bool {
        self.isr() & self.imr != 0
    }

    /// Is output pin OPn asserted? With OPCR bits 4-7 set, OP4..OP7 carry RxRDYA,
    /// RxRDYB, TxRDYA and TxRDYB instead of the output register (open-drain,
    /// active low). The 630 wires these to its interrupt levels.
    pub fn op_asserted(&self, n: u8) -> bool {
        let a = self.ch[0].status();
        let b = self.ch[1].status();
        match n {
            4 if self.opcr & 0x10 != 0 => a & SR_RXRDY != 0,
            5 if self.opcr & 0x20 != 0 => b & SR_RXRDY != 0,
            6 if self.opcr & 0x40 != 0 => a & SR_TXRDY != 0,
            7 if self.opcr & 0x80 != 0 => b & SR_TXRDY != 0,
            _ => self.output_port & (1 << n) != 0,
        }
    }

    pub fn opcr_bits(&self) -> u8 { self.opcr }

    pub fn output_pins(&self) -> u8 {
        !self.output_port
    }

    /// Bytes arriving from outside on channel `ch` (0 = A, 1 = B).
    pub fn receive(&mut self, ch: usize, bytes: &[u8]) {
        let c = &mut self.ch[ch];
        if c.rx_pending.is_empty() {
            c.rx_wait = 0;
        }
        c.rx_pending.extend(bytes.iter().map(|&b| (b, 0)));
    }

    /// A byte that arrives with a parity error: the 630 keyboard uses the parity
    /// bit as a ninth bit to mark status bytes (such as its ID) apart from key codes.
    pub fn receive_marked(&mut self, ch: usize, byte: u8) {
        let c = &mut self.ch[ch];
        if c.rx_pending.is_empty() {
            c.rx_wait = 0;
        }
        c.rx_pending.push_back((byte, 0x20));
    }

    pub fn has_transmitted(&self, ch: usize) -> bool { !self.ch[ch].tx_out.is_empty() }

    /// Bytes the chip has transmitted on channel `ch`.
    pub fn take_transmitted(&mut self, ch: usize) -> Vec<u8> {
        self.ch[ch].tx_out.drain(..).collect()
    }

    /// Set input pin `n` (IP0..IP5); a change latches IPCR delta bits for IP0..IP3.
    pub fn set_input(&mut self, n: u8, high: bool) {
        let mask = 1 << n;
        let old = self.input_port & mask != 0;
        if high { self.input_port |= mask } else { self.input_port &= !mask }
        if n < 4 && old != high {
            self.ipcr |= mask; // delta bit
        }
    }

    pub fn tick(&mut self, cycles: u64) {
        for ch in 0..2 {
            // Receive: move one pending byte per character time into the FIFO,
            // holding back (rather than overrunning) while the FIFO is full.
            if !self.ch[ch].rx_pending.is_empty() {
                let cc = self.char_cycles(ch, true);
                let c = &mut self.ch[ch];
                c.rx_wait = c.rx_wait.saturating_sub(cycles);
                if c.rx_wait == 0 && c.rx_fifo.len() < 3 {
                    if let Some(b) = c.rx_pending.pop_front() {
                        if c.rx_enabled {
                            c.rx_fifo.push_back(b);
                        }
                    }
                    c.rx_wait = cc;
                }
            }
            // Transmit: the holding byte leaves after one character time.
            if self.ch[ch].tx_holding.is_some() {
                let c = &mut self.ch[ch];
                c.tx_wait = c.tx_wait.saturating_sub(cycles);
                if c.tx_wait == 0 {
                    let b = c.tx_holding.take().unwrap();
                    if (c.mr[1] >> 6) & 3 == 2 {
                        c.rx_fifo.push_back((b, 0)); // local loopback
                    } else {
                        c.tx_out.push_back(b);
                    }
                }
            }
        }
        self.tick_counter(cycles);
    }

    fn counter_source_hz(&self) -> Option<u64> {
        match (self.acr >> 4) & 7 {
            3 | 7 => Some(CLOCK_HZ / 16),
            6 => Some(CLOCK_HZ),
            _ => None, // IP2 / TxC sources: not used here
        }
    }

    fn tick_counter(&mut self, cycles: u64) {
        let timer_mode = self.acr & 0x40 != 0;
        if !(timer_mode || self.ctr_running) {
            return;
        }
        let Some(src) = self.counter_source_hz() else { return };
        let preset = self.ctr_preset.max(1) as u64;
        // Cycles per half period of the square wave (timer) or per full count (counter).
        let period = (preset * self.cpu_hz / src).max(1);
        let mut left = cycles as u64;
        if self.ctr_value == 0 {
            self.ctr_value = period as u32;
        }
        while left > 0 {
            let v = self.ctr_value as u64;
            if left >= v {
                left -= v;
                self.ctr_value = period as u32;
                if timer_mode {
                    // Counter-ready is set once per full square-wave cycle.
                    self.ctr_half = !self.ctr_half;
                    if !self.ctr_half {
                        self.isr_counter = true;
                    }
                } else {
                    self.isr_counter = true;
                }
            } else {
                self.ctr_value = (v - left) as u32;
                left = 0;
            }
        }
    }

    pub fn read(&mut self, reg: u8) -> u8 {
        self.reads[(reg & 15) as usize] += 1;
        match reg & 0x0f {
            0 | 8 => {
                let c = &mut self.ch[(reg >> 3) as usize & 1];
                let v = c.mr[c.mr_ptr];
                c.mr_ptr = 1;
                v
            }
            1 | 9 => self.ch[(reg >> 3) as usize & 1].status(),
            3 | 11 => {
                let c = &mut self.ch[(reg >> 3) as usize & 1];
                c.rx_fifo.pop_front().map(|(b, _)| b).unwrap_or(0)
            }
            4 => {
                let v = (self.ipcr & 0x0f) << 4 | (self.input_port & 0x0f);
                self.ipcr = 0;
                v
            }
            5 => self.isr(),
            6 => (self.ctr_value >> 8) as u8,
            7 => self.ctr_value as u8,
            13 => self.input_port | 0x80,
            14 => {
                // start counter
                self.ctr_running = true;
                self.ctr_value = 0;
                0xff
            }
            15 => {
                // stop counter / clear counter-ready
                self.isr_counter = false;
                if self.acr & 0x40 == 0 {
                    self.ctr_running = false;
                }
                0xff
            }
            _ => 0xff,
        }
    }

    pub fn write(&mut self, reg: u8, v: u8) {
        self.writes[(reg & 15) as usize] += 1;
        match reg & 0x0f {
            0 | 8 => {
                let c = &mut self.ch[(reg >> 3) as usize & 1];
                c.mr[c.mr_ptr] = v;
                c.mr_ptr = 1;
            }
            1 | 9 => self.ch[(reg >> 3) as usize & 1].csr = v,
            2 | 10 => self.command((reg >> 3) as usize & 1, v),
            3 | 11 => {
                let ch = (reg >> 3) as usize & 1;
                let cc = self.char_cycles(ch, false);
                let c = &mut self.ch[ch];
                if c.tx_enabled {
                    if c.tx_holding.is_some() { c.thr_overwritten += 1; }
                    c.tx_holding = Some(v);
                    c.tx_wait = cc;
                } else {
                    c.thr_lost_disabled += 1;
                }
            }
            4 => self.acr = v,
            5 => self.imr = v,
            6 => self.ctr_preset = (self.ctr_preset & 0x00ff) | (v as u16) << 8,
            7 => self.ctr_preset = (self.ctr_preset & 0xff00) | v as u16,
            13 => self.opcr = v,
            14 => self.output_port |= v,
            15 => self.output_port &= !v,
            _ => {}
        }
    }

    fn command(&mut self, ch: usize, v: u8) {
        if self.cr_log.len() < 400 { self.cr_log.push((ch, v)); }
        let c = &mut self.ch[ch];
        match v & 0x03 {
            1 => c.rx_enabled = true,
            2 => c.rx_enabled = false,
            _ => {}
        }
        match (v >> 2) & 0x03 {
            1 => c.tx_enabled = true,
            2 => c.tx_enabled = false,
            _ => {}
        }
        match (v >> 4) & 0x07 {
            1 => c.mr_ptr = 0,
            2 => {
                c.rx_enabled = false;
                c.rx_fifo.clear();
            }
            3 => {
                c.tx_enabled = false;
                c.tx_holding = None;
            }
            4 => c.overrun = false,
            _ => {}
        }
    }

    /// Transmitter state of a channel (for debugging stalls).
    pub fn tx_state(&self, ch: usize) -> String {
        let c = &self.ch[ch];
        format!("tx_enabled={} holding={:?} wait={} lost_disabled={} overwritten={} status={:02x}",
                c.tx_enabled, c.tx_holding, c.tx_wait, c.thr_lost_disabled, c.thr_overwritten, c.status())
    }

    /// Short description of how the firmware configured the chip (for logs).
    pub fn describe(&self) -> String {
        format!(
            "{}: A {} baud rx={} tx={} | B {} baud rx={} tx={} | ACR={:02x} IMR={:02x} OP={:02x} OPCR={:02x} CTR={}",
            self.name,
            self.baud(0, true), self.ch[0].rx_enabled, self.ch[0].tx_enabled,
            self.baud(1, true), self.ch[1].rx_enabled, self.ch[1].tx_enabled,
            self.acr, self.imr, self.output_port, self.opcr, self.ctr_preset
        )
    }
}
