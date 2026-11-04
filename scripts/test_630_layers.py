"""End-to-end test of 630 layers: the 630 MTG emulator as a windowing terminal.

Boots a throwaway 3B2 (APFS clone of golden.img) on spare ports, so it can run
next to the app. Runs pseudo-tty layers (build/630host, scripts/build-630host.sh)
on a pty wired to the headless 630 (mtg630 link630). The startup file makes
window 1 a 3B2 line (3b2line) and loads a 630 program with dmdld in window 2.
The test logs in on window 1 by typing on the 630 keyboard, runs a command that
writes a file, checks the file from the 3B2 console, and saves the 630 screen as
a PNG (path printed).

Usage: .venv/bin/python scripts/test_630_layers.py
"""
import os
import pty
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim3b2 import MACHINE, ROOT, Sim, spare_ini  # noqa: E402
from test_630 import LINK, ROMS, pbm_to_png  # noqa: E402

HOST = os.path.join(ROOT, "build", "630host")
PORTS, LINE = 9101, 9630

STARTUP = """autodelete on
autocurrent on
reshape 1 6 6 1017 640
command 600 650 1017 1017 dmdld $DMD/lib/630bin/eyes.m
current 1
"""

# Text from the 3B2 arrives in xt packets, so it can be split by packet headers on the
# line: drive window 1 on timing, then check the result on the 3B2 console instead.
SCRIPT = r"""sleep 45000
type jay\r
sleep 5000
type att3b2\r
sleep 8000
type stty erase '^H' kill '^U'\r
sleep 2000
type echo L`expr 6 \* 7`K > /tmp/630layers; echo done\r
sleep 6000
snap layers
"""


def bridge(srv, dmd, startup, log):
    """Accept the 630's line, then run layers on a pty and shuttle bytes."""
    c, _ = srv.accept()
    time.sleep(10)  # let the 630 finish its power-on self-test
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(DMD=dmd, SHELL=os.path.join(dmd, "bin", "3b2line"),
                          PATH=os.path.join(dmd, "bin") + ":/usr/bin:/bin",
                          ATT3B2_PORTS=f"127.0.0.1:{PORTS}", TERM="630")
        dbg = ["-d", "7", "-o", os.path.join(os.path.dirname(startup), "layers.dbg")]
        os.execv(os.path.join(dmd, "bin", "layers"), ["layers", "-f", startup] + dbg)
    while True:
        r, _, _ = select.select([c, fd], [], [])
        if c in r:
            d = c.recv(4096)
            if not d:
                break
            os.write(fd, d)
        if fd in r:
            try:
                d = os.read(fd, 4096)
            except OSError:
                break
            if not d:
                break
            c.sendall(d)
            log.write(d)
    log.write(b"\n[layers exited]\n")


def main():
    if not os.path.exists(os.path.join(HOST, "bin", "layers")):
        subprocess.run([os.path.join(ROOT, "scripts", "build-630host.sh")], check=True)
    subprocess.run(["cargo", "build", "--release", "-q"], cwd=os.path.join(ROOT, "mtg630"), check=True)
    out = tempfile.mkdtemp(prefix="att3b2-630layers-")

    # $DMD: the build tree plus a writable xt directory (layers' named pipes).
    dmd = os.path.join(out, "dmd")
    os.makedirs(os.path.join(dmd, "xt"))
    os.chmod(os.path.join(dmd, "xt"), 0o777)
    for d in ("bin", "lib", "include"):
        os.symlink(os.path.join(HOST, d), os.path.join(dmd, d))
    startup = os.path.join(out, "layersrc")
    open(startup, "w").write(STARTUP)

    ini = spare_ini(out, ports=PORTS)

    img = "test630layers.img"
    subprocess.run(["cp", "-c", os.path.join(MACHINE, "golden.img"), os.path.join(MACHINE, img)], check=True)
    sim = Sim(ini=ini, disk=img, log=open(os.path.join(out, "console.log"), "w"))
    ok = False
    try:
        sim.expect("Console Login:", timeout=600)
        print("  3B2 is up; starting layers and the 630")
        time.sleep(5)
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", LINE))
        srv.listen(1)
        log = open(os.path.join(out, "line.log"), "wb", buffering=0)
        threading.Thread(target=bridge, args=(srv, dmd, startup, log), daemon=True).start()
        script = os.path.join(out, "script.txt")
        open(script, "w").write(SCRIPT)
        r = subprocess.run([LINK, ROMS, f"127.0.0.1:{LINE}", script, os.path.join(out, "630")], timeout=900)
        snap = os.path.join(out, "630-layers.pbm")
        ok = r.returncode == 0 and os.path.exists(snap)
        if os.path.exists(snap):
            pbm_to_png(snap, os.path.join(out, "630-layers.png"))
            print(f"  screen: {os.path.join(out, '630-layers.png')}")
        print(f"  line log: {os.path.join(out, 'line.log')}")
        sim.send("\r")
        sim.login("root", os.environ.get("ROOT_PW", "att3b2"))
        typed = sim.sh("cat /tmp/630layers")
        print(f"  3B2 /tmp/630layers: {typed.strip()!r}")
        ok = ok and "L42K" in typed
        sim.shutdown()
    finally:
        if sim.p.isalive():
            sim.p.terminate(force=True)
        os.remove(os.path.join(MACHINE, img))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
