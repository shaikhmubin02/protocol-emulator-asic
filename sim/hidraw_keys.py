#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0
"""Turn on the Caps Lock LED of the pemu keyboard (1209:0001) through its hidraw node (the
kernel sends it as a SET_REPORT), then read its boot keyboard reports and print what was
typed: the board starts typing when it sees the LED come on. The LED goes off at the end.

    python3 hidraw_keys.py [characters to wait for]
"""
import glob
import os
import select
import sys

KEYS = {0x28: "\n", 0x2C: " ", 0x2D: "-", 0x37: "."}
KEYS.update({0x04 + k: chr(ord("a") + k) for k in range(26)})
KEYS.update({0x1E + k: str(k + 1) for k in range(9)})
KEYS[0x27] = "0"


def find_node():
    for d in glob.glob("/sys/class/hidraw/hidraw*"):
        with open(os.path.join(d, "device", "uevent")) as f:
            if "HID_ID=0003:00001209:00000001" in f.read():
                return "/dev/" + os.path.basename(d)
    raise SystemExit("no hidraw node for 1209:0001")


def main():
    want = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    node = find_node()
    print(f"reading {node}", flush=True)
    fd = os.open(node, os.O_RDWR)
    os.write(fd, bytes([0, 0x02]))  # no report ID, then the LED byte: Caps Lock
    print("Caps Lock LED on", flush=True)
    text, down = "", set()
    while len(text) < want:
        r, _, _ = select.select([fd], [], [], 30)
        if not r:
            break
        report = os.read(fd, 8)
        print("report " + " ".join(f"{b:02x}" for b in report), flush=True)
        keys = {b for b in report[2:] if b}
        for k in sorted(keys - down):
            c = KEYS.get(k, "?")
            text += c.upper() if report[0] & 0x22 else c
        down = keys
    os.write(fd, bytes([0, 0x00]))
    print(f"typed: {text!r}")


if __name__ == "__main__":
    main()
