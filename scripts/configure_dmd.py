"""Guest-side setup for the DMD 5620: logins on the PORTS lines, TERM=dmd there.

The app's 5620 connects to 127.0.0.1:9001, which SIMH maps to the next free PORTS
line. This enables a getty on every PORTS tty so whichever line answers gives a
login, and makes logins on those ttys default to TERM=dmd so `layers` works.

Usage: configure_dmd.py [DISK]     (relative to machine/700, default disk0.img)
"""
import os
import sys

import pexpect

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim3b2 import MACHINE, Sim  # noqa: E402

PROFILE_SNIPPET = r"""
# att3b2: DMD 5620 development tools (dmdcc, 32ld, jx, ...) live in /usr/dmd. They go
# after the system path so the SVR3 /usr/bin/layers is the one that runs.
DMD=/usr/dmd; export DMD
PATH=$PATH:$DMD/bin; export PATH
# The 5620 terminal is on the PORTS lines (tty21-24, tty31-34).
case "`tty`" in
/dev/tty[2-9][1-4])
    TERM=dmd; export TERM
    # New layers run $SHELL. ksh exits after its first command inside an xt
    # channel, so layers windows get the Bourne shell.
    SHELL=/bin/sh; export SHELL ;;
esac
"""


def main(disk="disk0.img"):
    s = Sim(log=open(os.path.join(MACHINE, "logs", "configure_dmd.log"), "w"), disk=disk)
    s.login(password=os.environ.get("ROOT_PW", "att3b2"))
    # tty21-24 / tty31-34 are the serial ports; ttyX5 is each card's printer port.
    ttys = s.sh("ls /dev | grep '^tty[2-9][1-4]$'").split()
    print("PORTS ttys:", ttys)
    print(s.sh("grep -n '^[0-9]*:' /etc/gettydefs | sed -n 1,12p"))
    # One respawning getty per PORTS line, at 9600 (the speed label is all SIMH uses).
    entries = "".join(f"{t[3:]}:234:respawn:/etc/getty {t} 9600\n" for t in ttys)
    s.sh("grep -v ':respawn:/etc/getty tty[0-9][0-9] ' /etc/inittab > /tmp/inittab.new")
    s.sh(f"cat >> /tmp/inittab.new <<'EOF_INITTAB'\n{entries}EOF_INITTAB")
    s.sh("cp /tmp/inittab.new /etc/inittab; init q")
    print(s.sh("grep getty /etc/inittab"))
    # Replace any earlier version of the snippet (it runs to the end of the file).
    s.sh("sed '/^# att3b2: /,$d' /etc/profile > /tmp/profile.new && cp /tmp/profile.new /etc/profile")
    s.sh(f"cat >> /etc/profile <<'EOF_PROFILE'\n{PROFILE_SNIPPET}EOF_PROFILE")
    # The 5620's firmware 2.0 (8;7;5) has the layers system in ROM: an empty lsys file
    # tells the SVR3 layers there is nothing to download.
    s.sh("touch '/usr/lib/layersys/lsys.8;7;5'; chmod 755 '/usr/lib/layersys/lsys.8;7;5'")
    restore_svr3_xt(s)
    print(s.sh(". /etc/profile; echo DMD=$DMD; type layers dmdcc 32ld jx; ls -l /usr/lib/layersys /boot/XT"))
    s.shutdown()


def restore_svr3_xt(s):
    """The 1985 DMD package's drvinstall swaps in its own xt driver (major 68), which
    panics the SVR3.2.3 kernel when layers starts. Put the SVR3 driver back (saved in
    /etc/att3b2 before the package went on), fix the device nodes, rebuild the kernel."""
    if "XT.svr3" not in s.sh("ls /etc/att3b2 2>/dev/null"):
        print("no saved SVR3 xt driver; leaving the kernel alone")
        return
    s.sh("cp /etc/att3b2/XT.svr3 /boot/XT; cp /etc/att3b2/xt.master.svr3 /etc/master.d/xt")
    # Re-create any xt nodes that are not on the SVR3 major (35).
    fix_xt_nodes(s)
    print(s.sh("ls -l /dev/xt000 /dev/xt/000 /boot/XT"))
    s.sh("touch /etc/system")
    s.send("cd /; sync; shutdown -y -g0 -i6\r")
    i = s.p.expect(["Generating a new /unix", "Console Login:", pexpect.TIMEOUT], timeout=600)
    print("kernel:", ["rebuilt with the SVR3 xt driver", "NOT rebuilt", "timeout"][i])
    s.login(password=os.environ.get("ROOT_PW", "att3b2"))


if __name__ == "__main__":
    main(*sys.argv[1:2])


def fix_xt_nodes(s):
    """Rebuild every xt channel node on major 35. A channel's minor is its octal name
    (xt017 is minor 15); /dev/xt/NNN and /dev/xtNNN are links to the same node."""
    names = [n for n in s.sh("ls /dev/xt").split() if len(n) == 3 and n.isdigit()]
    # One channel per command: SVR3 canonical tty input lines max out at 256 chars.
    for n in names:
        s.sh(f"cd /dev; rm -f xt/{n} xt{n}; mknod xt/{n} c 35 {int(n, 8)}; chmod 644 xt/{n}; ln xt/{n} xt{n}")
    bad = s.sh("ls -l /dev/xt/* | grep -v ' 35,' | wc -l").strip().split()
    print(f"rebuilt {len(names)} xt channels on major 35; nodes still wrong: {bad[-1] if bad else '?'}")
