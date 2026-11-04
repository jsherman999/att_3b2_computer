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
