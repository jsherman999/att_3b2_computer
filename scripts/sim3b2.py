"""Drive the SIMH 3B2/700 console with pexpect: boot, log in, run commands, swap floppies."""
import os
import re
import sys
import time

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(ROOT, "vendor", "simh", "BIN", "3b2-700")
MACHINE = os.path.join(ROOT, "machine", "700")
PROMPT = "SIMSH> "


class Sim:
    def __init__(self, ini=os.path.join(ROOT, "config", "base.ini"), log=sys.stdout, disk="disk0.img", idle=True):
        # idle=False keeps the CPU spinning; installs use it because floppy I/O has hung
        # intermittently with SIMH idling enabled.
        env = dict(os.environ, DISK=disk, IDLE="idle" if idle else "noidle")
        self.p = pexpect.spawn(SIM, [ini], cwd=MACHINE, env=env, encoding="latin-1",
                               timeout=300, codec_errors="replace")
        self.p.logfile_read = log

    # -- console -------------------------------------------------------------
    def expect(self, pat, timeout=300):
        return self.p.expect(pat, timeout=timeout)

    def send(self, s):
        # The 3B2 console is a slow serial line; pace input so nothing is dropped.
        for ch in s:
            self.p.send(ch)
            time.sleep(0.004)

    def login(self, user="root", password=None):
        self.expect("Console Login:", timeout=600)
        self.send(user + "\r")
        i = self.expect(["Password:", r"[#\$] "])
        if i == 0:
            self.send((password or "") + "\r")
            self.expect(r"[#\$] ")
        # Fresh SVR3 ttys use '#' as erase and '@' as kill; switch to ^H/^U first.
        self.send("stty erase '^H' kill '^U'\r")
        self.expect(r"[#\$] ")
        self.send(f"PS1='{PROMPT}'; export PS1; TERM=dumb; export TERM\r")
        self.expect("\n" + PROMPT)

    def sh(self, cmd, timeout=600):
        """Run a command at the root prompt and return its output.

        A numbered end marker on its own line delimits the output, so stray prompts
        (here-documents, typed-ahead echo) can't make results drift between calls.
        """
        self._seq = getattr(self, "_seq", 0) + 1
        mark = f"END{self._seq}OF{os.getpid()}"
        self.send(cmd + "\r")
        self.send(f"echo {mark}\r")
        # Match the marker as printed output, not its echoed "echo MARK" command. Because the
        # echo line is typed ahead, its output can follow a prompt on the same line.
        self.expect(r"(\n|" + re.escape(PROMPT) + ")" + mark + r"\r?\n", timeout=timeout)
        out = self.p.before.replace("\r", "")
        self.expect(PROMPT, timeout=60)
        lines = out.split("\n")[1:]  # drop the echo of the command's first line
        return "\n".join(l for l in lines if f"echo {mark}" not in l and not l.startswith("> "))

    # -- simulator control (Ctrl-E drops to sim>) ---------------------------
    def scp(self, cmd, resync=True):
        for attempt in range(5):
            self.p.send("\x05")
            try:
                self.expect("sim> ", timeout=5)
                break
            except pexpect.TIMEOUT:
                continue
        else:
            raise RuntimeError("could not reach sim> prompt")
        self.p.send(cmd + "\r")
        self.expect("sim> ", timeout=30)
        out = self.p.before
        self.p.send("c\r")
        self.expect("\n", timeout=10)
        if resync:  # only valid when the guest is sitting at our shell prompt
            time.sleep(1)
            self.p.send("\r")
            self.expect(PROMPT, timeout=60)
        return out

    def floppy(self, path, resync=True):
        self.scp("detach ifloppy", resync=False)
        self.scp(f"attach -r ifloppy {os.path.abspath(path)}" if path else "show ifloppy", resync=resync)

    def shutdown(self):
        self.send("cd /; sync; sync; shutdown -y -g0 -i0\r")
        self.expect(["The system is down", "FIRMWARE MODE", "Enter name of program", "sim> "], timeout=300)
        time.sleep(5)
        self.p.send("\x05")
        try:
            self.expect("sim> ", timeout=10)
        except pexpect.TIMEOUT:
            pass
        self.p.send("quit\r")
        self.p.expect(pexpect.EOF, timeout=30)


def software(rel):
    return os.path.join(ROOT, "machine", "software", rel)
