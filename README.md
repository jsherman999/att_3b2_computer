# att3b2 — an AT&T 3B2/700 + DMD terminal workstation for macOS

Goal: a native macOS app that shows a 3B2 booting from ROM through to a working
1991-era System V Release 3.2.3 system (development tools, TCP/IP, NFS, DWB),
with a bitmapped AT&T graphical terminal as its monitor.

## Decisions (2026-11-03)

- **Machine: 3B2/700, labeled as such.** Nobody emulates the 3B2/600. Open SIMH
  emulates the /400 and /700; the /700 is the 600's closest sibling.
- **App: native macOS (SwiftUI).** It bundles the `3b2-700` simulator and runs
  it as a subprocess, with the console on a telnet port.
- **Graphical terminal: DMD 5620 first, 630 MTG later.** `dmd_core` (Rust)
  already emulates the 5620 accurately, and SVR3 runs `layers` on it through
  the DMD Core Utilities. MAME's `att630`/`att730x` drivers are skeletons
  marked MACHINE_NOT_WORKING, but the firmware has been dumped. That makes the
  630 a research track.

## Phases

1. **Headless bring-up.** Build `3b2-700` from `vendor/simh` and boot
   `sd630.img`. Install packages from `machine/software/`: Wollongong TCP/IP
   3.2, NI drivers, NFS 3.2.4, C/SGU Issue 4.2, DMD Core Utilities, DWB/WWB.
   Save a golden disk image.
2. **macOS app.** Show the boot console (CRT-style VT window attached to the
   CONTTY port) and add power, reset and snapshot controls.
3. **DMD 5620 terminal.** Embed `dmd_core` and connect it to a PORTS line.
   Run `layers` from SVR3.
4. **630 MTG research.** Finish the MAME driver (video controller, keyboard,
   host DUART) or write a dedicated 68000-based core. Then swap it in as the
   monitor.

## Layout

- `vendor/simh/` — Open SIMH checkout (not committed)
- `machine/700/` — ROM, NVRAM, TOD, boot.ini, disk images (not committed)
- `machine/software/` — 3B2 install floppies mirrored from
  archives.loomcom.com/3b2/software (not committed)

## Quick start

    scripts/fetch-assets.sh                 # ROMs, disk image, patches, build simulator
    cd machine/700 && ../../vendor/simh/BIN/3b2-700 ../../config/smoke-test.ini

## Phase 1 status (2026-11-03): done, 16/16 checks in `scripts/verify_system.py`

`machine/700/golden.img` (not committed, rebuildable) is SVR3.2.3 on the
3B2/700 with:

| Area | Installed |
|---|---|
| Base | System V 3.2.3, FMLI/FACE, LP, UUCP, spell, Terminal Filters |
| Shells | sh, Korn shell (`/bin/ksh`) |
| Development | C (`cc`, `make`, `lex`, `yacc`, `lint`), SCCS, Fortran 77, Pascal (`pc`), BASIC |
| Text processing | Documenter's Workbench (troff, tbl, eqn, pic, grap, mm), Writer's Workbench (style, diction) |
| Networking | NI Ethernet driver, Wollongong WIN/3B TCP/IP 3.2, NFS 3.2.4, C-Kermit 5A(189) |
| DMD | DMD Core/Application/Text utilities: `layers`, for the 5620 terminal |

Networking uses SIMH's SLIRP NAT: the guest is `att3b2` at 10.0.2.15 (gateway
10.0.2.2, DNS 10.0.2.3). Host forwards, bound to 127.0.0.1 only:
`telnet 127.0.0.1 2323`, ftp `127.0.0.1 2121`. PORTS serial lines are on
`127.0.0.1:9001`. Accounts: `root` and `jay`, both with password `att3b2`.

Rebuilding the image from the pristine `sd630.img`:

    .venv/bin/python scripts/install_packages.py ksh ni tcpip
    .venv/bin/python scripts/configure_system.py
    .venv/bin/python scripts/install_packages.py kermit fortran pascal basic termfilt dwb wwb nfs
    .venv/bin/python scripts/verify_system.py

The install floppies are mirrored into `machine/software/` from
archives.loomcom.com/3b2/software.

## Phase 2 status (2026-11-03): done

`scripts/build-app.sh [--install]` builds `build/ATT3B2.app` (SwiftUI and
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)). The bundle contains the
patched simulator, the ROM, NVRAM and TOD files, and the golden disk as an APFS
clone. On first launch the app clones these into
`~/Library/Application Support/ATT3B2/700`.

- The console is a CRT-styled VT100 on the simulator's pty. You can pick
  green, amber or white phosphor, the font size and scanlines in Settings.
- **Power switch** (⇧⌘P): UNIX syncs and powers off, like the real front-panel
  switch (`SET CSR POWERDOWN`, patch 0003). **Reset** (⇧⌘R). **Pull the Plug**
  kills the simulator. Quitting while the machine runs asks first.
- **Snapshots**: APFS clones of the hard disk, taken or restored while the
  machine is off, plus a factory restore.
- Test harness: `-autoPowerOn YES -debugCapture <dir>` makes the app write
  `console.txt` and `state.txt` and run commands from `cmd.txt`.
  `scripts/test_app.py` uses it to boot, log in, run a command, press the
  power switch and take a snapshot.
- The guest clock follows the Mac (`scripts/set_clock.py`). The TZ comes from
  the Mac, and `date` needs a four-digit year under the Y2K patch.
- The first-boot `setup` banner and the slow `firstcheck` fsck are retired.
  Boot to login takes about 80 s.

## Phase 3 status (2026-11-03): done, the DMD 5620 terminal

Open it with the **DMD 5620** toolbar button. It is Seth Morabito's
[dmd_core](https://github.com/dmdmtg/dmd_core) (WE32100, firmware 8;7;5)
behind `dmd_ffi/`, a small C-ABI crate. The 5620 connects over raw TCP to
`127.0.0.1:9001`, which SIMH gives to the first free PORTS line (`tty21`).

Using it: log in as `jay`, run `layers`, then hold the **right** mouse button
on the grey desktop for the menu (New, Reshape, Move, Top, Bottom, Current,
Delete, Exit). Choose **New** and sweep a rectangle with the right button.
⌥-click is button 2. F9 is the 5620's Setup key. The 5620 tracks the mouse
relatively, like the real quadrature mouse, and the Mac pointer is hidden
over its screen.

On the 3B2: `getty` runs on the PORTS lines, logins there get `TERM=dmd`,
and layers windows run `/bin/sh` (ksh exits after its first command inside an
xt channel). The DMD 2.0 development tools (`dmdcc`, `32ld`, `jx`, demos)
live in `/usr/dmd`. `scripts/configure_dmd.py` sets all this up.

Problems found and fixed on the way to working layers:

| Symptom | Cause | Fix |
|---|---|---|
| `layers`: terminal is not a 5620 | PORTS delivered 1 char per clock tick, so the ID reply was too slow | `patches/0006`: receive up to 64 chars per poll |
| no `lsys.8;7;5` | firmware 2.0 carries layers in ROM, so there is nothing to download | empty `/usr/lib/layersys/lsys.8;7;5` |
| kernel panic (MMU fault) at `layers` | the 1985 DMD package's `drvinstall` replaced the SVR3 `xt` driver | SVR3 driver and major-35 nodes restored |
| window hangs on Return | PORTS card did CR→NL inside xt's binary packets | `patches/0007`: translation only for line discipline 0 |
| output stalls under load | 5620 DUART overwrote unread bytes; PORTS could fill the completion queue and lose a transmit-done | `patches/dmd_core-0001`, `patches/0008` |

Tests: `scripts/test_dmd.py` logs in on the 5620, runs layers, opens a window,
runs commands, and confirms on the console that they ran (PASS).
`scripts/check-patches.sh` runs from `build-app.sh` and fails the build if a
vendored change is missing from `patches/`.

## Phase 4 status (2026-11-04): 630 MTG works as a terminal

`mtg630/` is a new 630 MTG emulator core: an MC68000 via the `m68k` crate, two
SCN2681s, the mouse, the keyboard, 1024x1024 video and battery RAM. It runs the
real firmware from bitsavers (`scripts/fetch-630.sh`). Use the **630 MTG**
toolbar button. It self-tests, draws the desktop, runs menus and windows, and
its H1 window is a working terminal on the 3B2: log in, run commands, use the
arrow keys. Not done yet: the 630's own windowing protocol to the host
(`layers`/xt for the 630 and its downloaded programs) and 630 setup from the
keyboard (Setup key).

| Symptom | Cause | Fix |
|---|---|---|
| no host output | receive interrupts are on DUART OP4, not INTR | wired OP4 to levels 5/4 |
| windows never drawn | process timers count IP2 strobes | IP2 pulses every frame |
| typed keys dropped silently | the port "ready" check reads the modem lines (DUART 1 IP4/IP5), and all inputs read high = no carrier | hold IP4/IP5 (and DUART 2 IP3) low |
| transmitter enabled, then an interrupt storm | TxRDY (OP6) was wired to level 5, but transmit is polled at vertical blank | OP6 not wired |
| most keys lost, terminal resets every second | the keyboard answered every 0x84 with its ID; an ID after power-up means "keyboard re-plugged" | ID once after reset |
| Shift gave control characters, no `s`, Return sent Up-arrow | keymap guessed from the ROM table | every scan code checked with `kbmap630`: Shift 0x1E, Ctrl 0x1D, `s` 0x56, Return 0x5A |

Tests: `scripts/test_630.py` boots the 3B2 headless on a throwaway clone and
logs in through the 630 core (`mtg630` `link630`) (PASS). `scripts/test_630_app.py`
does the same in the app's 630 window and confirms on the console that the typed
command ran (PASS). Details: `docs/630-mtg-notes.md`.

### Gotchas found along the way

- A fresh SVR3 tty uses `#` as erase and `@` as kill. The harness runs
  `stty erase '^H' kill '^U'` before typing anything else.
- The console is a slow serial line. Prompts are judged only after the output
  goes quiet, otherwise a half-printed `[y, n]` gets the wrong answer.
- Floppy-to-disk copies hung intermittently with `set cpu idle`. Installs run
  with `noidle`.
- `patches/0001`: SLIRP port forwards bind to loopback, not every interface.
  `patches/0002`: the SLIRP doorbell socket no longer loops forever on a
  refused port.
- `patches/0004`: a reboot that came after the boot diagnostics but before
  UNIX started the NI (fsck's automatic reboot after a power loss) hung the
  firmware with `SYSGEN FAILED FOR NI`. The stale pump CRC is now cleared on
  system reset. `patches/0005`: the NAT banner honours `-q`.
- The 1990 Bourne shell has no `$((...))`; use `expr`. `grep` has no `\\|`; use `egrep`.
- SVR3 canonical tty input lines max out at 256 characters. Keep scripted
  commands short.
