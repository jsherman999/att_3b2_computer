"""End-to-end smoke test of build/ATT3B2.app, driven through its -debugCapture channel.

Boots the machine in the app, logs in on the console, runs a command, presses the
power switch, checks for a clean power-off, takes a snapshot and quits.
Usage: test_app.py [--fresh]   (--fresh starts from the factory disk image)
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


def main():
    cap = tempfile.mkdtemp(prefix="att3b2-test-")
    if "--fresh" in sys.argv and os.path.exists(os.path.join(SUPPORT, "disk0.img")):
        os.remove(os.path.join(SUPPORT, "disk0.img"))       # app re-clones the factory image
    app = subprocess.Popen([APP, "-autoPowerOn", "YES", "-debugCapture", cap],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def read(name):
        try:
            with open(os.path.join(cap, name), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    def wait(pred, what, timeout):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if pred():
                print(f"  ok   {what} ({time.time() - t0:.0f}s)")
                return True
            time.sleep(2)
        print(f"  FAIL {what} (state={read('state.txt').strip()!r})")
        print("\n".join(l for l in read("console.txt").splitlines() if l.strip())[-1500:])
        return False

    def cmd(text):
        with open(os.path.join(cap, "cmd.txt"), "w") as f:
            f.write(text + "\n")
        time.sleep(4)

    ok = True
    try:
        ok &= wait(lambda: read("state.txt").strip() == "Running", "boots to Console Login", 600)
        ok &= "NAT args" not in read("console.txt") or print("  FAIL NAT banner on console") or False
        cmd("type root\\r")
        ok &= wait(lambda: "Password:" in read("console.txt"), "password prompt", 60)
        cmd("type att3b2\\r")
        time.sleep(4)
        cmd("type uname -a; date; echo APP-TEST-`expr 6 \\* 7`\\r")
        ok &= wait(lambda: "APP-TEST-42" in read("console.txt"), "command runs on console", 60)
        year = time.strftime("%Y")
        ok &= wait(lambda: any(l.rstrip().endswith(year) and ":" in l for l in read("console.txt").splitlines()),
                   f"guest clock is in {year}", 10)
        cmd("power")
        ok &= wait(lambda: read("state.txt").strip() == "Off", "power switch -> clean power off", 180)
        ok &= ("Soft power switch shutdown" in read("console.txt")) or print("  FAIL no soft shutdown notice") or False
        cmd("snapshot app-test")
        snaps = os.listdir(os.path.join(SUPPORT, "snapshots"))
        ok &= any(s.endswith("app-test.img") for s in snaps) or print("  FAIL snapshot missing") or False
        print("  ok   snapshot taken" if any(s.endswith("app-test.img") for s in snaps) else "")
        for s in snaps:
            if s.endswith("app-test.img"):
                os.remove(os.path.join(SUPPORT, "snapshots", s))
    finally:
        app.terminate()
        app.wait(timeout=20)
        shutil.copy(os.path.join(cap, "window.png"), os.path.join(tempfile.gettempdir(), "att3b2-last-window.png")) \
            if os.path.exists(os.path.join(cap, "window.png")) else None
    print("PASS" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
