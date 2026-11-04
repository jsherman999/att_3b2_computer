"""End-to-end test of the AT&T 630 MTG emulator against the 3B2 (headless).

Boots the 3B2 from a throwaway APFS clone of golden.img, then runs mtg630's
link630 on the PORTS line (127.0.0.1:9001): the emulated 630 boots its real
firmware, then logs in as jay by typing on its emulated keyboard, runs a command
and waits for its output. The 630 screen is saved as a PNG (path printed).

Usage: .venv/bin/python scripts/test_630.py
"""
import os
import struct
import subprocess
import sys
import tempfile
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim3b2 import MACHINE, ROOT, Sim  # noqa: E402

LINK = os.path.join(ROOT, "mtg630", "target", "release", "link630")
ROMS = os.path.join(ROOT, "machine", "630")
SCRIPT = r"""type \r
expect login:
type jay\r
expect Password:
type att3b2\r
expect $
type uname -a; echo 630-OK-`expr 6 \* 7`\r
expect 630-OK-42
sleep 2000
snap typed
"""


def pbm_to_png(src, dst):
    data = open(src, "rb").read()
    px = data[len(b"P4\n1024 1024\n"):]
    raw = b"".join(b"\x00" + bytes(255 - b for b in px[y * 128:(y + 1) * 128]) for y in range(1024))

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xffffffff)

    with open(dst, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1024, 1024, 1, 0, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def main():
    subprocess.run(["cargo", "build", "--release", "-q"], cwd=os.path.join(ROOT, "mtg630"), check=True)
    out = tempfile.mkdtemp(prefix="att3b2-630-")
    img = "test630.img"
    subprocess.run(["cp", "-c", os.path.join(MACHINE, "golden.img"), os.path.join(MACHINE, img)], check=True)
    sim = Sim(disk=img, log=open(os.path.join(out, "console.log"), "w"))
    ok = False
    try:
        sim.expect("Console Login:", timeout=600)
        print("  3B2 is up; starting the 630")
        time.sleep(5)
        with open(os.path.join(out, "script.txt"), "w") as f:
            f.write(SCRIPT)
        r = subprocess.run([LINK, ROMS, "127.0.0.1:9001", os.path.join(out, "script.txt"), os.path.join(out, "630")],
                           timeout=900)
        ok = r.returncode == 0 and os.path.exists(os.path.join(out, "630-typed.pbm"))
        if os.path.exists(os.path.join(out, "630-typed.pbm")):
            pbm_to_png(os.path.join(out, "630-typed.pbm"), os.path.join(out, "630-typed.png"))
            print(f"  screen: {os.path.join(out, '630-typed.png')}")
        sim.send("\r")  # fresh console prompt, then shut down cleanly
        sim.login("root", os.environ.get("ROOT_PW", "att3b2"))
        sim.shutdown()
    finally:
        if sim.p.isalive():
            sim.p.terminate(force=True)
        os.remove(os.path.join(MACHINE, img))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
