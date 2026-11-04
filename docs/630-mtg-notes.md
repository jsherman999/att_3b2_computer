# AT&T 630 MTG: reverse-engineering notes

Status (2026-11-03): `mtg630/` boots the real 630 firmware (bitsavers
`460620-1` to `460623-1`, CRC-identical to MAME's `att630` set). It passes the
self-test, draws the desktop, runs the button-3 menu and creates windows. The
power-on **H1** window shows host output, including the 3B2's `login:` prompt
over a PORTS line in the app. **Not working yet:** typed keys never reach the
host.

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
| 5 | DUART 1 **OP4 (RxRDYA) / OP6 (TxRDYA)**, OPCR = 0x70 | Main EIA receive and transmit |
| 4 | DUART 2 OP4 / OP6, OPCR = 0x50 | Aux EIA receive and transmit |
| 3 | DUART 1 INTR (counter/timer, 60 Hz, ACR = E0) | system tick, counter at 7800AA |
| 2 | DUART 2 INTR (IP2 change) and DUART 1 **OP5 (RxRDYB)** | mouse strobe *and* keyboard receive |
| 1 | vertical blank | transmit polling and housekeeping |

MAME's skeleton driver wires only the DUART INTR pins. The receive and transmit
interrupts on OP4-OP6 are why host input appeared to be ignored.

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

- The terminal sends **0x84** ("identify") followed by 0x00, and later 0x8C
  (probably click or LEDs). It repeats this about every 2.1 s while the
  keyboard counts as absent.
- The keyboard answers with **ID = type - 1**, sent with a **parity error**:
  the parity bit acts as a ninth bit marking status bytes. Type 0x11 selects
  the key table at 1D6BE (98-key keyboard). Type 2 selects 1D4BE.
- Key bytes: **bit 7 set = make (pressed)**, clear = break. The table entry is
  `[class, normal, ctrl, shift]`, indexed by `code & 0x7F`. Class 0x01 entries
  are modifiers (1D/26 shift-like, 1E/2B/64 ctrl/lock-like).
- 7800F6 is a keyboard watchdog (31 IP2 ticks). If it expires, the keyboard
  is considered gone, 780110 is cleared, and identification restarts.

### Where keyboard input stops

Traced with `boot630 WATCH=... CALLERS=...`:

1. The ISR at 6286 reads RHRB and queues the byte. The keyboard process
   (6588 → state machine at 7801BE: 6D48 init, 6DE4 normal) decodes it.
2. 67AE → 65BC → 6858 → 6882: the H1 windowproc (78957C) is current and has
   flag bit 4 set ("reads its own keyboard"), so each character is put into
   its input queue at +0x11A. This was hit once per key.
3. **The windowproc never reads that queue and never calls start-output**
   (EB32, which enables the Main EIA transmitter with CR = 0x04). The queue's
   head and tail pointers are equal afterwards.

Leads for next time:

- The windowproc requested resources with mask 0x0C (4408 → 4430). Check
  whether its keyboard event bit is ever delivered, or whether it waits on
  another event.
- Answer the 0x8C command (status) correctly, so 780110 stays set and the
  keyboard state machine stops reinitialising.
- `s`/`S` are not in the plain or letter classes of table 1D6BE. Find the
  class 0x0A/0x88/0x89 handlers in the class table at 1D98E.

## Tools

- `mtg630/src/bin/boot630.rs`: headless boot with a timed event script
  (`move/down/up/key/scan/host/snap/dump/ip1/ip2`). Environment variables:
  `BRAMFILL`, `WATCH`, `CALLERS`, `VEC`, `TRACESR`.
- `mtg630/src/bin/kbmap630.rs`: presses every scan code and records the
  host-port output.
- Disassemble with capstone: `machine/630/rom630.bin` (the interleaved image)
  produces `rom630.dis`.
