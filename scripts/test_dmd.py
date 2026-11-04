"""Drive the DMD 5620 in build/ATT3B2.app: boot, log in on the 5620, run commands.

Usage: test_dmd.py [--fresh] [COMMAND ...]   (default command: layers)
Screens are saved as dmd-<n>.png in a temp directory (printed at the end).
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build", "ATT3B2.app", "Contents", "MacOS", "ATT3B2")
SUPPORT = os.path.expanduser("~/Library/Application Support/ATT3B2/700")


def main(argv):
    fresh = "--fresh" in argv
    commands = [a for a in argv if a != "--fresh"] or ["layers"]
    cap = tempfile.mkdtemp(prefix="att3b2-dmd-")
    if fresh and os.path.exists(os.path.join(SUPPORT, "disk0.img")):
        os.remove(os.path.join(SUPPORT, "disk0.img"))
    app = subprocess.Popen([APP, "-autoPowerOn", "YES", "-openDMD", "YES", "-debugCapture", cap],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def read(name):
        try:
            with open(os.path.join(cap, name)) as f:
                return f.read().strip()
        except OSError:
            return ""

    def cmd(line, wait):
        with open(os.path.join(cap, "cmd.txt"), "w") as f:
            f.write(line + "\n")
        time.sleep(wait)

    shot = [0]

    def snap(label):
        shot[0] += 1
        dst = os.path.join(cap, f"dmd-{shot[0]}-{label}.png")
        shutil.copy(os.path.join(cap, "dmd.png"), dst)
        print("  screen:", dst)

    try:
        t0 = time.time()
        while read("state.txt") != "Running" and time.time() - t0 < 600:
            time.sleep(3)
        print(f"  3B2 {read('state.txt')} after {time.time() - t0:.0f}s; 5620 link: {read('dmd-link.txt')}")
        time.sleep(5)
        cmd("dmdtype \\r", 4)
        cmd("dmdtype jay\\r", 4)
        cmd("dmdtype att3b2\\r", 8)
        snap("login")
        for c in commands:
            cmd("dmdtype " + c + "\\r", 30)
            snap(c.split()[0].replace("/", "_"))
    finally:
        # Leave the machine running for inspection only if asked.
        if os.environ.get("KEEP") != "1":
            cmd("power", 15)
            app.terminate()
    print("captures in", cap)


if __name__ == "__main__":
    main(sys.argv[1:])
