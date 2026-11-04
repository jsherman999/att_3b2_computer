"""Set the 3B2's time zone and time-of-day clock from the Mac.

SIMH's TOD clock only catches up on gaps shorter than five years, and tod.bin from
the archive dates from 2022, so the clock has to be set once from inside UNIX.
After that SIMH keeps it current between runs.

Usage: set_clock.py [DISK]     (DISK relative to machine/700, default disk0.img)
"""
import datetime
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim3b2 import MACHINE, Sim  # noqa: E402

# Olson zone -> SVR3 TZ string (POSIX-style, as SVR3 expects).
SVR3_TZ = {
    "America/New_York": "EST5EDT", "America/Chicago": "CST6CDT", "America/Denver": "MST7MDT",
    "America/Phoenix": "MST7", "America/Los_Angeles": "PST8PDT", "UTC": "GMT0", "Etc/UTC": "GMT0",
}


def host_tz():
    try:
        zone = os.readlink("/etc/localtime").split("zoneinfo/")[-1]
    except OSError:
        zone = "UTC"
    return SVR3_TZ.get(zone, "GMT0")


def main(disk="disk0.img"):
    tz = host_tz()
    s = Sim(log=open(os.path.join(MACHINE, "logs", "set_clock.log"), "w"), disk=disk)
    s.login(password=os.environ.get("ROOT_PW", "att3b2"))
    print(s.sh(f"cp /etc/TIMEZONE /etc/TIMEZONE.orig 2>/dev/null; "
               f"sed 's/^TZ=.*/TZ={tz}/' /etc/TIMEZONE.orig > /etc/TIMEZONE; cat /etc/TIMEZONE"))
    now = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=5)
    stamp = now.strftime("%m%d%H%M%Y")           # Y2K-patched SVR3: mmddHHMM[ccyy]
    print(s.sh(f"TZ=GMT0 date {stamp}; TZ={tz}; export TZ; date"))
    print("host:", time.strftime("%a %b %d %H:%M:%S %Z %Y"))
    s.shutdown()


if __name__ == "__main__":
    main(*sys.argv[1:2])
