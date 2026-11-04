"""End-to-end test of the AT&T 630 window in build/ATT3B2.app.

Boots the 3B2, opens the 630, logs in as jay by typing on the 630's emulated
keyboard, runs a command that writes a marker file, then checks the marker from
the system console. 630 screens are saved as PNGs (path printed).

Usage: test_630_app.py [--keep]
"""
import os
import random
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build", "ATT3B2.app", "Contents", "MacOS", "ATT3B2")


def main(argv):
    keep = "--keep" in argv
    cap = tempfile.mkdtemp(prefix="att3b2-630app-")
    app = subprocess.Popen([APP, "-autoPowerOn", "YES", "-open630", "YES", "-debugCapture", cap],
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

    ok = False
    try:
        t0 = time.time()
        while read("state.txt").strip() != "Running" and time.time() - t0 < 600:
            time.sleep(3)
        print(f"  3B2 {read('state.txt').strip()} after {time.time() - t0:.0f}s")
        time.sleep(10)  # the 630 needs ~30 s for its self-test; the 3B2 boot covers that
        run("630type \\r", 4)
        run("630type jay\\r", 5)
        run("630type att3b2\\r", 8)
        run("630snap 1-login", 2)
        marker = f"MTG-{random.randint(1000, 9999)}"
        run(f"630type uname -a; echo {marker} > /tmp/630test; cal 11 1991\\r", 20)
        run("630snap 2-command", 2)
        # Check from the console that the command really ran on the 3B2.
        run("type root\\r", 4)
        run("type att3b2\\r", 6)
        run("type cat /tmp/630test\\r", 6)
        ok = marker in read("console.txt")
        print(f"  {'ok  ' if ok else 'FAIL'} command typed on the 630 ran on the 3B2 ({marker})")
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
