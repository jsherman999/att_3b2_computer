# AT&T 630 MTG: reverse-engineering notes

Status (2026-11-04): `mtg630/` boots the real 630 firmware (bitsavers
`460620-1` to `460623-1`, CRC-identical to MAME's `att630` set). It passes the
self-test, draws the desktop, runs the button-3 menu and creates windows. The
power-on **H1** window is a working terminal on the 3B2: `scripts/test_630.py`
logs in as jay by typing on the emulated keyboard and runs commands. With
**layers** (pseudo-tty layers on the Mac, see "Layers" below) the 630 is a
windowing terminal: `scripts/test_630_layers.py` logs in on one window and loads
a 630 program (`eyes`) into another with `dmdld`.

## Hardware, as the firmware expects it

| Address | Device | Notes |
|---|---|---|
| 000000-03FFFF | ROM | 460621/460620 (even/odd) at 0, 460623/460622 at 20000 |
| 200000-20001F | DUART 1 (SCN2681), odd bytes | A = **Main EIA** (host), B = **keyboard** (4800 baud) |
| 200020-20003F | DUART 2, odd bytes | A = **Aux EIA**, B = 9600 baud (printer/aux) |
| 200040/42 | mouse X/Y counters | 12-bit; the firmware tracks *changes*, like the 5620 |
| 200045 | mouse buttons | active low: 0x04 = 1, 0x02 = 2, 0x01 = 3 |
| 700000-75FFFF | video controller | never touched in a normal boot |
| 760000-77FFFF | VRAM | 1024x1024, 1 bpp, MSB first, set bit = dark |
| 780000-7FFFFF | RAM | 512 KB |
| E00000-FFFFFF | battery RAM | 8 KB on odd bytes. IACK reads vectors here (64-70 = levels 1-7) |

### Interrupts

The firmware registers handlers per level in a table at 783F38. Its common
dispatcher is at 066C.

| Level | Source | How the firmware uses it |
|---|---|---|
| 5 | DUART 1 **OP4 (RxRDYA)**, OPCR = 0x70 | Main EIA receive (handler EBB2 only drains the receiver) |
| 4 | DUART 2 OP4, OPCR = 0x50 | Aux EIA receive |
| 3 | DUART 1 INTR (counter/timer, 60 Hz, ACR = E0) | system tick, counter at 7800AA |
| 2 | DUART 2 INTR (IP2 change) and DUART 1 **OP5 (RxRDYB)** | mouse strobe *and* keyboard receive |
| 1 | vertical blank *and* DUART 1/2 **OP6 (TxRDYA)** | **transmit**: EED4/F064 -> ECF8 fill THR while TxRDY, then disable the transmitter |

MAME's skeleton driver wires only the DUART INTR pins. The receive interrupt on
OP4 is why host input appeared to be ignored. The firmware also programs OP6 as
TxRDYA. Its handler is the level-1 one: ECF8 moves the output queue into THR while
TxRDY is set and disables the transmitter when the queue is empty, which is what
removes the interrupt. Wiring OP6 to level 5 instead causes an interrupt storm
(that handler only drains the receiver). With vertical blank alone the terminal sent
about one byte per frame; plain terminal use survived that, but layers stalled: the
630 stopped partway through xt packets and never recovered.

### Modem-control inputs (active low)

The port "ready" check (EB76) reads the DUART input port and ANDs it with a
mask from the port's info block (7846EC+0x0F). If every masked line is high, the
line counts as hung up and the write routine (F25C) drops the data. Masks: Main
EIA = DUART 1 **IP4/IP5** (0x30), Aux EIA = DUART 2 **IP3** (0x08). `mtg630`
holds these low (carrier present). This was the main reason typed keys never
reached the host.

### The mouse strobe is the scheduler's clock

The level-2 handler (3796) counts down process timers (7800F6, 780170) and sets
the reschedule flag 780114. If IP2 changes only when the mouse moves (as in
MAME), any process that sleeps (the H1 windowproc does at 14B68 → 3BEA) never
wakes, and the window is never drawn. `mtg630` therefore pulses IP2 every frame.

### Battery RAM and setup

Zeroed BRAM passes the checksum and means 300 baud, no host. Filling it with
0xFF fails the checksum, so the firmware loads the factory defaults: Host1 on
Main EIA at 9600 8N1, and an H1 window at power-on (User's Guide 7-14, 7-18).
The app saves BRAM to `~/Library/Application Support/ATT3B2/630-bram.bin`.

### Boot straps (leave these input pins high)

- DUART 1 IP2 low with no cartridge → jumps into the empty cartridge slot (08F0)
- DUART 2 IP4 low with an expansion card answering 0xFE at 400081 → extra port (03B4)
- DUART 1 IP1 low → probes expansion RAM at 800000 (10172)

## Keyboard protocol (DUART 1 channel B, 4800 baud, 8 bits + even parity)

- The keyboard sends its **ID = type - 1** once after power-up, with a **parity
  error**: the parity bit acts as a ninth bit marking status bytes. Type 0x11
  selects the key table at 1D6BE (98-key keyboard). Type 2 selects 1D4BE.
- **An ID byte at any other time means "keyboard re-plugged".** In the normal
  state (6DE4) the decoder returns -1 for it, 5F96 resets keyboard state and
  drops back to the identify state (6D48), which ignores keys for 63 ticks (about
  a second). `mtg630` used to answer every 0x84 with the ID, which made the
  terminal reset itself every second and swallow most keys.
- The terminal's own bytes are settings, not requests: 0x88 | click volume
  (BRAM E0000B) from 6A72, 0x84 followed by an LED byte (0x00, 0x01, 0x04, 0x05
  as Caps Lock and friends change), and so on. The keyboard does not answer them.
- Key bytes: **bit 7 set = make (pressed)**, clear = break. The table entry is
  `[class, normal, ctrl, shift]`, indexed by `code & 0x7F`. Class 0x01 entries
  are modifiers: **0x1E = Shift, 0x1D = Ctrl** (the first version of the app had
  these swapped), 0x64 and others are locks.
- 78010E counts keys held down. 7800F6 is a watchdog reloaded (31 ticks) by every
  keyboard byte; if it runs out while a key is still held, the terminal assumes the
  keyboard was unplugged mid-keystroke and re-initialises it.

### Path of a key to the host

1. The ISR at 6286 reads SRB/RHRB and queues (flags, byte) for the keyboard
   process. Parity-flagged bytes go to the ID path (6114).
2. The keyboard process (state machine at 7801BE: 6D48 identify, 6DE4 normal,
   6F08 recheck) decodes with 5EE0, then 67AE -> 65BC -> 6882.
3. 6882 delivers to the keyboard owner (7801C6). If that process reads its own
   keyboard (flag bit 4) the character goes to its queue at +0x11A. The H1
   windowproc does not, so the character goes to its host connection: the
   connection's write method (struct+0x1C = 70F8) -> port write F25C -> ready check
   EB76 -> output queue -> start output EB32 (CR = 0x04, transmitter on).
4. The vertical-blank handler (ECF8) moves the queue into THRA.

### Scan codes

`mtg630/src/keymap.rs` maps ASCII to scan codes, checked by `kbmap630`, which
presses every code alone, with Shift and with Ctrl and records the host output.
Highlights: `s` = 0x56, Return = 0x5A (0x5E, 0x6A, 0x72 and 0x7F also send CR),
arrows Up 0x55 / Down 0x6C / Right 0x0E / Left 0x3A (ANSI `ESC [ A`-`D`), Tab
0x39, Backspace 0x2E, Esc 0x53, Delete 0x2D. Many keys send `ESC N x` sequences
(the 630's function keys).

## Layers (the 630 as a windowing terminal)

No 630 host package for the 3B2 survives online (the original came on the
"Windowing Utilities" and 630 MTG software floppies). What does survive, from Dave
Dykstra (AT&T) on github.com/dmdmtg: **dmd-layers** (pseudo-tty layers, public
domain), **freesdp630** (the 630 software development package: dmdld, jx, ...,
GPL) and **mtg-binaries** (prebuilt 630 programs, little-endian COFF). They need
pseudo-ttys, which SVR3.2 on the 3B2 lacks, so layers runs on the Mac:
`scripts/build-630host.sh` builds it into a `$DMD` tree that the app bundles.

- The app runs layers on a pty wired to the 630's Main EIA port (Host: Layers).
- `SHELL` is `host630/3b2line`, so every window layers opens (the 630's initial
  window, and New from the button-3 menu) takes its own 3B2 PORTS line: a login
  prompt per window, up to 7 windows.
- The startup file (`host630/layersrc`) reshapes window 1 and opens a local
  "630 tools" shell (`host630/toolsh`) for `dmdld`, `ucache`, `dmddemo`.
- `host630/compat/macos`: a System V `termio.h` (struct termio and its flag and
  baud values, TCGETA/TCSETA translated to termios; the tools index tables by
  `c_cflag & CBAUD`), and STREAMS stubs. `host630/movelogin` replaces the
  setuid-root utmp helper with one that reports success.

Porting notes (patches/dmd-layers-0001, patches/freesdp630-0001):

- **Apple Silicon passes variadic arguments on the stack.** `Debug()` was called
  without a prototype, so it read garbage (`(null)` pty names, a bus error with
  `-d`). It is now prototyped. Everything else undeclared returns int.
- Old names that collide with libc: `sendfile` (dmdld), `listen` (jx), `abort`
  (dmdversion), `carg` (loadfont), `log` (layers trace.c). Renamed.
- `cntrlspeed()` uses `cfgetospeed()` where there is no CBAUD.
- freesdp630 has files whose names differ only in case; on a case-insensitive
  disk one of each pair is missing. Only terminal-side sources are affected.

## Tools

- `mtg630/src/bin/boot630.rs`: headless boot with a timed event script
  (`move/down/up/key/scan/host/snap/dump/ip1/ip2/pcs`). `pcs PROC` ... `pcs off`
  prints the code ranges a process ran (current process pointer: 78020E).
  Environment variables: `BRAMFILL`, `WATCH`, `CALLERS`, `VEC`, `TRACESR`,
  `WWATCH` (log writes to addresses, with the writing PC).
- `mtg630/src/bin/kbmap630.rs`: presses every scan code and records the
  host-port output (`GAPMS`, `TIMELINE=1`).
- `mtg630/src/bin/link630.rs`: the 630 on a TCP host (the 3B2's PORTS line),
  driven by an expect/type script. Used by `scripts/test_630.py` and
  `scripts/test_630_layers.py`. `pcs MS` samples the PC and interrupt mask, `duart`
  prints the Main EIA transmitter state, `KBDCMDS=1` lists keyboard commands,
  `BRAMDUMP=1` prints the per-port flow-control setup bytes.
- Disassemble with capstone: `machine/630/rom630.bin` (the interleaved image)
  produces `rom630.dis`.
