#!/bin/sh
# Download the AT&T 630 MTG firmware and manuals from bitsavers into machine/630.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D="$ROOT/machine/630"; mkdir -p "$D/docs"
for f in 460620-1.BIN 460621-1.BIN 460622-1.BIN 460623-1.BIN; do
  [ -f "$D/$f" ] || curl -fL -A "Mozilla/5.0" -o "$D/$f" "https://www.bitsavers.org/pdf/att/630_mtg/firmware/$f"
done
for f in 630_MTG_Terminal_Users_Guide_Jul87.pdf 630_MTG_Software_Reference_1987.pdf; do
  [ -f "$D/docs/$f" ] || curl -fL -A "Mozilla/5.0" -o "$D/docs/$f" "https://www.bitsavers.org/pdf/att/630_mtg/$f"
done
