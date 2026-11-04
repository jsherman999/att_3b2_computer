"""Boot the configured disk and exercise the installed software. Prints PASS/FAIL per check."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim3b2 import MACHINE, Sim  # noqa: E402

# (name, shell command, substring expected in output)
CHECKS = [
    ("release", "uname -a", "3.2.3"),
    ("hostname", "uname -n", "att3b2"),
    ("ksh", "/bin/ksh -c 'echo ksh-ok ${#HOME}'", "ksh-ok"),
    ("cc", "cd /tmp; cat > t.c <<'X'\nmain() { printf(\"cc-ok %d\\n\", 6 * 7); }\nX\ncc -O -o t t.c && ./t", "cc-ok 42"),
    ("make+sccs", "type make admin get delta lex yacc lint", "admin is"),
    ("f77", "cd /tmp; cat > t.f <<'X'\n      PRINT *, 'F77-OK', 6*7\n      END\nX\nf77 -o tf t.f 2>&1 && ./tf", "F77-OK"),
    ("pascal", "cd /tmp; cat > t.p <<'X'\nprogram t(output);\nbegin writeln('PAS-OK') end.\nX\n"
               "(pc -o tp t.p 2>&1 && ./tp) || (pascal t.p 2>&1); ls -l /usr/bin/pc", "PAS-OK"),
    ("basic", "ls /usr/bin | grep -i basic", "basic"),
    ("nroff", "cat > /tmp/t.mm <<'X'\n.ce\nNROFF OK\nX\nnroff /tmp/t.mm | grep -v '^$'", "NROFF OK"),
    ("troff+dwb", "type troff tbl eqn pic grap mm", "troff is"),
    ("wwb", "type style diction spellwwb", "style is"),
    ("kermit", "echo 'version' | kermit 2>&1 | sed -n 1,3p", "Kermit"),
    ("dmd layers", "ls -l /usr/bin/layers /usr/lib/layersys 2>&1 | sed -n 1,5p; ls /usr/options | grep dmd", "dmdcore"),
    ("route", "netstat -rn", "default"),
    ("dns+tcp", "(echo 'user anonymous x@'; echo bye) | ftp -n -v ftp.gnu.org 2>&1 | sed -n 1,3p", "220"),
    ("nfs", "ls /usr/options | grep -i nfs; type mount share 2>&1", "nfs"),
]


def main():
    s = Sim(log=open(os.path.join(MACHINE, "logs", "verify.log"), "w"))
    s.login(password=os.environ.get("ROOT_PW", "att3b2"))
    s.sh("PATH=$PATH:/usr/lbin:/usr/etc:/usr/ucb; export PATH")
    failed = 0
    for name, cmd, want in CHECKS:
        out = s.sh(cmd, timeout=300)
        ok = want.lower() in out.lower()
        failed += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {name:12s} {out.strip().splitlines()[-1][:90] if out.strip() else ''}")
        if not ok:
            print("      " + out.strip().replace("\n", "\n      ")[:600])
    s.shutdown()
    print(f"\n{len(CHECKS) - failed}/{len(CHECKS)} checks passed")
    return failed


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
