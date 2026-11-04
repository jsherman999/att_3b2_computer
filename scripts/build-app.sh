#!/bin/sh
# Build ATT3B2.app: SwiftUI front end + patched SIMH 3b2-700 + ROMs + golden disk.
# Usage: scripts/build-app.sh [--install]   (--install copies the app to ~/Applications)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/ATT3B2.app"
M="$ROOT/machine/700"

for f in "$ROOT/vendor/simh/BIN/3b2-700" "$M/3b2_700.bin" "$M/nvram.bin" "$M/tod.bin" "$M/golden.img"; do
  [ -f "$f" ] || { echo "missing $f — run scripts/fetch-assets.sh and the phase 1 install first" >&2; exit 1; }
done

"$ROOT/scripts/check-patches.sh"          # vendored changes must all be in patches/
( cd "$ROOT/dmd_ffi" && cargo build --release )        # libatt_dmd.a: the DMD 5620 core
( cd "$ROOT/app" && swift build -c release )
BIN=$(cd "$ROOT/app" && swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/sim" "$APP/Contents/Resources/seed"
cp "$BIN/ATT3B2" "$APP/Contents/MacOS/ATT3B2"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cp "$ROOT/vendor/simh/BIN/3b2-700" "$APP/Contents/Resources/sim/"
cp "$M/3b2_700.bin" "$M/nvram.bin" "$M/tod.bin" "$APP/Contents/Resources/seed/"
cp -c "$M/golden.img" "$APP/Contents/Resources/seed/golden.img"     # APFS clone: no extra space
[ -f "$ROOT/app/Resources/AppIcon.icns" ] && cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ATT3B2</string>
  <key>CFBundleDisplayName</key><string>AT&amp;T 3B2</string>
  <key>CFBundleIdentifier</key><string>io.github.jsherman999.att3b2</string>
  <key>CFBundleExecutable</key><string>ATT3B2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep -s - "$APP" >/dev/null
echo "built $APP"
if [ "$1" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ATT3B2.app"
  cp -cR "$APP" "$HOME/Applications/ATT3B2.app"
  echo "installed $HOME/Applications/ATT3B2.app"
fi
