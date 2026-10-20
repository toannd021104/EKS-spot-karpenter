#!/usr/bin/env python3
"""pty test for confirm_by_typing: the typed confirmation reads /dev/tty and has no bypass.

Runs a tiny bash driver that sources lib/common.sh and calls confirm_by_typing, under a real pseudo-terminal
(so /dev/tty exists) and with closed stdin. Only bash and coreutils are used: no AWS, no cluster, no stub needed.
"""
import os
import pty
import select
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
COMMON = os.path.join(os.path.dirname(HERE), "lib", "common.sh")
DRIVER = 'source "$1"; confirm_by_typing finops-spot-demo; echo CONFIRMED'
BASE_ENV = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/tmp"}


def run_in_pty(answer, extra_env=None, timeout=15):
    """Run the driver with a controlling pty, type `answer`, return (exit_status, output)."""
    env = dict(BASE_ENV)
    env.update(extra_env or {})
    pid, fd = pty.fork()
    if pid == 0:  # child: the pty is stdin/stdout/stderr and the controlling terminal
        os.execvpe("bash", ["bash", "-c", DRIVER, "_", COMMON], env)
    out = b""
    sent = False
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            if not sent and b"Enter to continue" in out:
                os.write(fd, (answer + "\n").encode())
                sent = True
        else:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                return os.waitstatus_to_exitcode(status), out.decode(errors="replace")
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status), out.decode(errors="replace")


def run_non_tty(extra_env=None):
    env = dict(BASE_ENV)
    env.update(extra_env or {})
    proc = subprocess.run(
        ["bash", "-c", DRIVER, "_", COMMON],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=15,
    )
    return proc.returncode, proc.stdout + proc.stderr


class ConfirmByTyping(unittest.TestCase):
    def test_correct_text_is_accepted(self):
        status, out = run_in_pty("finops-spot-demo")
        self.assertEqual(status, 0, out)
        self.assertIn("CONFIRMED", out)

    def test_wrong_text_exits_4(self):
        status, out = run_in_pty("yes")
        self.assertEqual(status, 4, out)
        self.assertNotIn("CONFIRMED", out)

    def test_empty_answer_exits_4(self):
        status, out = run_in_pty("")
        self.assertEqual(status, 4, out)

    def test_closed_stdin_exits_4(self):
        status, out = run_non_tty()
        self.assertEqual(status, 4, out)
        self.assertNotIn("CONFIRMED", out)

    def test_environment_cannot_satisfy_the_confirmation(self):
        env = {k: "finops-spot-demo" for k in ("CONFIRM", "CONFIRMATION", "YES", "ASSUME_YES", "FORCE", "FINOPS_CONFIRM")}
        env.update({"YES": "1", "FORCE": "1", "ASSUME_YES": "1", "DRY_RUN": "1", "CI": "true"})
        status, out = run_non_tty(env)
        self.assertEqual(status, 4, out)
        self.assertNotIn("CONFIRMED", out)
        status, out = run_in_pty("no", env)
        self.assertEqual(status, 4, out)


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=2) and 0)
