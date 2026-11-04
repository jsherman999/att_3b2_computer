"""End-to-end test of the DMD 5620 in build/ATT3B2.app.

Boots the 3B2, logs in on the 5620, starts layers, opens a window from the
button-3 menu, runs a command in it that writes a marker file, then checks the
marker from the system console. Screens are saved as PNGs (path printed).

Usage: test_dmd.py [--fresh] [--keep]
  --fresh  start from the factory disk image
  --keep   leave the machine running afterwards
Environment: WIRELOG=1 also records every serial byte to wire.log.
"""
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build", "ATT3B2.app", "Contents", "MacOS", "ATT3B2")
SUPPORT = os.path.expanduser("~/Library/Application Support/ATT3B2/700")

# Open a new layer: button 3 (index 2) brings up the menu, release on "New", then
# sweep a rectangle with button 3. The 5620 tracks the mouse relatively, so these
# are gestures rather than exact screen positions.
NEW_WINDOW = """dmdmove 400 500
sleep 300
dmdpress 400 500 2
sleep 1200
dmdrelease 2
sleep 1200
dmdpress 400 500 2
sleep 300
dmdmove 600 300
sleep 300
dmdmove 700 200
sleep 600
dmdrelease 2
sleep 5000"""


def main(argv):
    fresh, keep = "--fresh" in argv, "--keep" in argv
    cap = tempfile.mkdtemp(prefix="att3b2-dmd-")
    if fresh and os.path.exists(os.path.join(SUPPORT, "disk0.img")):
        os.remove(os.path.join(SUPPORT, "disk0.img"))
    extra = ["-dmdWireLog", os.path.join(cap, "wire.log")] if os.environ.get("WIRELOG") == "1" else []
    app = subprocess.Popen([APP, "-autoPowerOn", "YES", "-openDMD", "YES", "-debugCapture", cap] + extra,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def read(name):
        try:
            with open(os.path.join(cap, name), errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    def run(script, wait):
        with open(os.path.join(cap, "cmd.txt"), "w") as f:
            f.write(script.strip() + "\n")
        time.sleep(wait)

    def snap(label):
        dst = os.path.join(cap, f"dmd-{label}.png")
        shutil.copy(os.path.join(cap, "dmd.png"), dst)

    ok = False
    try:
        t0 = time.time()
        while read("state.txt").strip() != "Running" and time.time() - t0 < 600:
            time.sleep(3)
        print(f"  3B2 {read('state.txt').strip()} after {time.time() - t0:.0f}s; "
              f"5620 link: {read('dmd-link.txt').strip()}")
        time.sleep(5)
        run("dmdtype \\r", 4)
        run("dmdslow jay\\r", 4)
        run("dmdslow att3b2\\r", 8)
        snap("1-login")
        run("dmdslow layers\\r", 20)
        snap("2-layers")
        run(NEW_WINDOW, 16)
        marker = f"DMD-{random.randint(1000, 9999)}"
        run(f"dmdslow date; uname -a; echo {marker} > /tmp/dmdtest\\r", 12)
        run("dmdslow cal 11 1991\\r", 12)
        snap("3-window")
        # Check from the console that the command really ran on the 3B2.
        run("type root\\r", 4)
        run("type att3b2\\r", 6)
        run("type cat /tmp/dmdtest\\r", 6)
        ok = marker in read("console.txt")
        print(f"  {'ok  ' if ok else 'FAIL'} command typed in a layers window ran on the 3B2 ({marker})")
    finally:
        if not keep:
            run("type exit\\r", 3)
            run("power", 15)
            app.terminate()
    print("  screens:", cap)
    print("PASS" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
