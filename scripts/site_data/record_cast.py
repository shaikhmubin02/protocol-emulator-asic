#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0
"""Run a command in a pseudo-terminal and write what it prints, with its timing, as an
asciicast v2 file (one JSON header line, then [seconds, "o", text] lines), for a terminal player
on the write-up's web page.

    scripts/site_data/record_cast.py out.cast "shown command" command [args...]

"shown command" is printed after a prompt at the start, as if typed.
"""
import fcntl
import json
import os
import pty
import select
import struct
import sys
import termios
import time

WIDTH, HEIGHT = 100, 32


def record(out, shown, cmd):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", HEIGHT, WIDTH, 0, 0))
    start = time.time()
    events = [[0.0, "o", f"$ {shown}\r\n"]]
    pending = b""
    while True:
        try:
            ready, _, _ = select.select([fd], [], [], 0.5)
        except InterruptedError:
            continue
        if not ready:
            if os.waitpid(pid, os.WNOHANG)[0]:
                break
            continue
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        pending += data
        # keep a multi-byte character whole: decode up to the last complete one
        for cut in range(len(pending), max(len(pending) - 4, 0) - 1, -1):
            try:
                text = pending[:cut].decode("utf-8")
            except UnicodeDecodeError:
                continue
            if text:
                events.append([round(time.time() - start, 6), "o", text])
            pending = pending[cut:]
            break
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0
    header = {"version": 2, "width": WIDTH, "height": HEIGHT, "timestamp": int(start),
              "title": shown, "env": {"TERM": "xterm-256color", "SHELL": "/bin/bash"}}
    with open(out, "w") as f:
        f.write(json.dumps(header) + "\n")
        for e in events:
            f.write(json.dumps(e) + "\n")
    return os.waitstatus_to_exitcode(status) if status else 0


if __name__ == "__main__":
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    rc = record(sys.argv[1], sys.argv[2], sys.argv[3:])
    print(f"wrote {sys.argv[1]} (exit {rc})")
    sys.exit(rc)
