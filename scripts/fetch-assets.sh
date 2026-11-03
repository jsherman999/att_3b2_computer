#!/bin/sh
# Fetch 3B2/700 ROM, NVRAM, TOD and the SVR3.2.3 disk image, then build the simulator.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
M="$ROOT/machine/700"; mkdir -p "$M" "$ROOT/vendor"
for f in 3b2_700.bin nvram.bin tod.bin sd630.img.gz; do
  [ -f "$M/$f" ] || curl -fL -o "$M/$f" "https://archives.loomcom.com/3b2/emulator/700/$f"
done
[ -f "$M/sd630.img" ] || gunzip -k "$M/sd630.img.gz"
[ -f "$M/disk0.img" ] || cp "$M/sd630.img" "$M/disk0.img"
[ -d "$ROOT/vendor/simh" ] || git clone --depth 1 https://github.com/open-simh/simh.git "$ROOT/vendor/simh"
make -C "$ROOT/vendor/simh" 3b2-700
