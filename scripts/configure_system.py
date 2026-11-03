"""Post-install configuration: networking (SLIRP), hostname, accounts.

Usage: configure_system.py [ROOT_PASSWORD] [USER_PASSWORD]   (both default to "att3b2")
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim3b2 import MACHINE, PROMPT, Sim  # noqa: E402

HOSTNAME = "att3b2"
USER = "jay"

RC_NET = r"""#ident "att3b2 local network setup"
# Runs after S86win3b. SLIRP gateway 10.0.2.2, DNS 10.0.2.3.
case "$1" in
start|'')
    /usr/etc/route add default 10.0.2.2 1 >/dev/null 2>&1
    ;;
esac
"""

RESOLV = "domain local\nnameserver 10.0.2.3\n"


def write_file(s, path, text, mode="644"):
    # Use a here-document; avoid '#' and '@' issues by having already reset erase/kill.
    s.sh(f"cat > {path} <<'EOF_ATT3B2'\n{text}EOF_ATT3B2")
    s.sh(f"chmod {mode} {path}")


def set_password(s, user, pw):
    s.send(f"passwd {user}\r")
    for _ in range(2):
        s.expect(r"(?i)new password:", timeout=60)
        s.send(pw + "\r")
    s.expect(PROMPT, timeout=60)


def main(root_pw="att3b2", user_pw="att3b2"):
    s = Sim(log=open(os.path.join(MACHINE, "logs", "configure.log"), "w"))
    s.login()
    print(s.sh(f"uname -S {HOSTNAME}; uname -n"))
    # Persist the node name the SVR3 way and fix the host table to match.
    s.sh(f"ed - /etc/hosts <<'EOF_ED'\n/^10.0.2.15/c\n10.0.2.15 {HOSTNAME} unix\n.\na\n10.0.2.2 gateway\n10.0.2.3 dns\n.\nw\nq\nEOF_ED")
    write_file(s, "/etc/rc2.d/S87localnet", RC_NET, "744")
    write_file(s, "/etc/resolv.conf", RESOLV)
    # The installer turned the resolver off via NONAMESERVER in /etc/profile.
    s.sh("grep -v NONAMESERVER /etc/profile > /tmp/profile.$$ && cp /tmp/profile.$$ /etc/profile; rm -f /tmp/profile.$$")
    print(s.sh("grep -n NODE /etc/rc2.d/* /etc/inittab /etc/rc* 2>/dev/null | sed -n 1,10p"))
    # Accounts
    print(s.sh(f"grep '^{USER}:' /etc/passwd || /usr/bin/useradd -m -d /usr/{USER} -s /bin/ksh {USER} 2>&1 || "
               f"(mkdir /usr/{USER}; echo '{USER}::201:1::/usr/{USER}:/bin/ksh' >> /etc/passwd; chown {USER} /usr/{USER}); [ -f /etc/shadow ] && /usr/bin/pwconv; echo done"))
    set_password(s, "root", root_pw)
    set_password(s, USER, user_pw)
    print(s.sh("tail -3 /etc/passwd; cat /etc/hosts | grep -v '^#'"))
    s.shutdown()


if __name__ == "__main__":
    main(*sys.argv[1:3])
