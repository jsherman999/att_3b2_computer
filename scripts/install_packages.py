"""Install SVR3.2 add-on packages from the mirrored floppy images onto machine/700/disk0.img.

Usage: install_packages.py PKG [PKG ...]     (keys of PACKAGES below)

Each package's floppies are attached in order; the package's own INSTALL script is
run exactly as sysadm installpkg would run it. Disk-swap prompts are answered by
attaching the next image. Unrecognised prompts abort the run so they can be
inspected (see machine/700/logs/).
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import time

import pexpect

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim3b2 import MACHINE, PROMPT, Sim, software  # noqa: E402


def imgs(pattern):
    found = sorted(glob.glob(software(pattern)), key=lambda p: [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", p)])
    if not found:
        raise SystemExit(f"no images match {pattern}")
    return found


PACKAGES = {
    "ksh": lambda: imgs("Miscellaneous/Korn_Shell.img"),
    "ni": lambda: imgs("TCP-IP_Networking/Network_Interface_Drivers_1-1.img"),
    "nsu": lambda: imgs("TCP-IP_Networking/Networking_Support_Utilities_3-2-2.img"),
    "tcpip": lambda: imgs("TCP-IP_Networking/Wollongong_TCP-IP_3-2_*.img"),
    "rfs": lambda: imgs("TCP-IP_Networking/Remote_File_Sharing_Utilities_1-2_*.img"),
    "nfs": lambda: imgs("TCP-IP_Networking/System_V_NFS_3-2-4_*.img"),
    "dwb": lambda: imgs("Documenters_Workbench/*.img"),
    "wwb": lambda: imgs("Writers_Workbench/*.img"),
    "fortran": lambda: imgs("Development_Tools/Other_Languages/Fortran_*.img"),
    "pascal": lambda: imgs("Development_Tools/Other_Languages/Pascal_*.img"),
    "basic": lambda: imgs("Development_Tools/Other_Languages/BASIC_*.img"),
}

# Package-specific answers: regex -> list of replies, used in order (last one repeats).
ANSWERS = {
    "ni": [
        (r"board to be assigned/unassigned \(or q to quit\): $", ["0", "q"]),
        (r"last 4 digits \(hexadecimal\) of the address \(or q to quit\): $", ["0001"]),
    ],
    # Wollongong WIN/3B 3.2. Host 10.0.2.15 on SLIRP's 10.0.2.0/24 (gw .2, dns .3);
    # resolver is configured by hand afterwards.
    "tcpip": [
        (r"run the nameserver on this host\? \[y, n\]: $", ["n"]),
        (r"run this host as a resolver\? \[y, n\]: $", ["n"]),
        (r"previously saved .*\? \[y, n\]: $", ["n"]),
        (r"installing 3\.2 on a old 2\.1\? .*\[y, n\]: $", ["y"]),
        (r"enter host's network number> $", ["10"]),
        (r"enter the network number your host is on> $", ["10"]),
        (r"enter name of network host is on> $", ["slirpnet"]),
        (r"enter aliases your network is known by> $", [""]),
        (r"'s internet address> $", ["10.0.2.15"]),
        (r"enter alias names host will be known by> $", [""]),
        (r"enter other hosts into your /etc/hosts file\? \[y, n\]: $", ["n"]),
        (r"TFTP daemon enabled\? \[y, n\]: $", ["n"]),
        (r"ROUTE daemon enabled\? \[y, n\]: $", ["n"]),
        (r"FTP daemon logging enabled\? \[y, n\]: $", ["y"]),
        (r"RFS enabled \? \[y, n\]: $", ["n"]),
        (r"how many pseudo ttys .*\[1-64\]: $", ["32"]),
    ],
    "nsu": [(r"number of pseudo terminal devices \[0 - 256\]: $", ["32"])],
    "wwb": [
        (r"installation requirements and procedures\? \(y or n\) $", ["n"]),
        (r"is already installed\.\s*Do you want to reinstall it\? \(y or n\) $", ["n"]),
    ],
}

# Answers that apply to every package (checked after the package-specific ones).
GENERIC = [
    (r"Type 'y' to [^\n]*\n?[^\n]*'n' to [^\n]*: *$", ["y"]),
    (r"\(yes or no\): *$", ["yes"]),
]

# Prompts seen in AT&T INSTALL scripts. Order matters: first match wins.
NEXT_DISK = re.compile(r"(?is)(insert|place).{0,200}?(diskette|floppy|medium|disk)\s*(number\s*)?\d.{0,300}?(RETURN|ready|continue)")
YES_NO = re.compile(r"(?i)(\[y(es)?\s*[,/|]\s*n(o)?|\(y/n\)|\[y/n\]|y or n)[^\n]*[\]\)?:]\s*$")
PRESS_RETURN = re.compile(r"(?i)(press|strike|hit|type|enter)\s*<?(return|enter|cr)>?[^\n]*:?\s*$")


def snapshot(tag):
    os.makedirs(os.path.join(MACHINE, "snapshots"), exist_ok=True)
    dst = os.path.join(MACHINE, "snapshots", f"{time.strftime('%Y%m%d-%H%M%S')}-{tag}.img")
    subprocess.run(["cp", "-c", os.path.join(MACHINE, "disk0.img"), dst], check=True)  # APFS clone
    return dst


def install(s, name, images):
    print(f"\n===== installing {name}: {len(images)} floppies", flush=True)
    s.floppy(images[0])
    s.sh("cd /; /etc/umount /dev/diskette 2>/dev/null; mkdir /install 2>/dev/null; chmod 700 /install")
    out = s.sh("/etc/mount /dev/diskette /install -r && cp /install/install/INSTALL /tmp/INSTALL.$$ && chmod +x /tmp/INSTALL.$$ && echo MOUNTED $$")
    if "MOUNTED" not in out:
        raise SystemExit(f"{name}: could not mount first floppy:\n{out}")
    pid = out.split("MOUNTED")[1].split()[0]
    s.send(f"cd /tmp; /tmp/INSTALL.{pid} /dev/diskette /install diskette; echo INSTALL-EXIT=$?\r")
    disk = 0
    buf = ""        # console text since we last answered something
    quiet = 0.0     # seconds since the console last produced output
    answers = [(re.compile(rx, re.I), list(replies)) for rx, replies in ANSWERS.get(name, []) + GENERIC]
    generic = [(NEXT_DISK, "disk"), (YES_NO, "y"), (PRESS_RETURN, "")]
    while True:
        # The console is a slow serial line: collect output until it goes quiet, then
        # judge the whole prompt, so a partial "[y, n]" can't trigger the wrong answer.
        got = False
        try:
            buf += s.p.read_nonblocking(4096, timeout=1.5)
            quiet, got = 0.0, True
        except pexpect.TIMEOUT:
            quiet += 1.5
        m = re.search(r"INSTALL-EXIT=(\d+)", buf)
        if m:
            code = int(m.group(1))
            # The prompt may have arrived split across reads; ask for a fresh one.
            time.sleep(1)
            s.send("\r")
            s.expect("\n" + PROMPT, timeout=60)
            break
        if got:
            continue
        tail = buf[-800:]
        reply = None
        for rx, replies in answers:
            if rx.search(tail):
                reply = replies.pop(0) if len(replies) > 1 else replies[0]
                break
        if reply is None:
            for rx, action in generic:
                if rx.search(tail):
                    reply = action
                    break
        if reply == "disk":
            disk += 1
            if disk >= len(images):
                raise SystemExit(f"{name}: asked for disk {disk + 1} but only {len(images)} images\n{tail}")
            s.floppy(images[disk], resync=False)
            s.send("\r")
            buf, quiet = "", 0.0
        elif reply is not None:
            print(f"\n[auto-answer {reply!r}]", flush=True)
            s.send(reply + "\r")
            buf, quiet = "", 0.0
        elif quiet >= 60 and re.search(r"[:?>]\s*$", tail):
            raise SystemExit(f"{name}: stuck on an unrecognised prompt:\n{tail}")
        elif quiet >= 600:
            diag = s.scp("show cpu", resync=False)
            raise SystemExit(f"{name}: no output for 10 minutes:\n{tail}\n--- simulator ---\n{diag}")
    s.sh("cd /; /etc/umount /dev/diskette 2>/dev/null; rm -f /tmp/INSTALL.*")
    s.floppy(None)
    print(f"\n===== {name}: INSTALL exited {code}", flush=True)
    return code


def main(names):
    unknown = [n for n in names if n not in PACKAGES]
    if unknown:
        raise SystemExit(f"unknown packages {unknown}; choose from {list(PACKAGES)}")
    os.makedirs(os.path.join(MACHINE, "logs"), exist_ok=True)
    log = open(os.path.join(MACHINE, "logs", f"install-{'-'.join(names)}.log"), "w")

    class Tee:
        def write(self, d):
            log.write(d); log.flush(); sys.stdout.write(d)

        def flush(self):
            sys.stdout.flush()

    s = Sim(log=Tee(), idle=False)
    s.login()
    results = {}
    for n in names:
        results[n] = install(s, n, PACKAGES[n]())
    print(s.sh("ls /usr/options; df"))
    s.shutdown()
    for n in names:
        print(f"{n}: exit {results[n]}")
    print("snapshot:", snapshot("-".join(names)))


if __name__ == "__main__":
    main(sys.argv[1:])
