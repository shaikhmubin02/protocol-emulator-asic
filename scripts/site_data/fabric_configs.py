#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0
"""The LUT fabric configurations as JSON for the write-up's fabric visualiser: each element's
truth table, the source of each LUT input, flop or LUT output, start value and clock, the roles
(line, hold, rx bit, drop, flag) and the comment that explains the configuration. The words come
from hw/post/fabric_words.exe (build it first: cd hw && dune build ./post/fabric_words.exe), the
comments and roles from hw/src/bitstream.ml and hw/post/fabric_post.ml, where each one is stated
next to its definition. The config word format is in hw/src/fabric_logic.ml.

    scripts/site_data/fabric_configs.py <out.json>
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORDS = ROOT / "hw" / "_build" / "default" / "post" / "fabric_words.exe"
SOURCES = [ROOT / "hw" / "src" / "bitstream.ml", ROOT / "hw" / "post" / "fabric_post.ml"]
SOURCE_NAMES = ["ext0 (TX bit)", "ext1 (RX sample)", "ext2 (FABCTL[0])", "element 0's output",
                "own flop", "flop below", "flop 2 below", "flop above"]
# the configurations a program uses, with the protocol it is for and whether it is post-freeze
CONFIGS = {
    "usb_tx": ("USB transmit: a 0 after six 1s, then NRZI", False),
    "eth_tx": ("10BASE-T transmit: Manchester", False),
    "eth_rx": ("10BASE-T receive: Manchester decoder", False),
    "can_rx": ("CAN 2.0 receive: stuff bits removed", True),
    "hdlc_tx": ("HDLC transmit: a 0 after five 1s", True),
    "hdlc_rx": ("HDLC receive: zero removal and flags", True),
    "bmc_tx": ("S/PDIF transmit: biphase-mark", True),
    "ir_carrier": ("Infrared carrier (NEC, RC-5)", True),
    "ax25_tx": ("AX.25 transmit: HDLC stuffing, then NRZI", True),
    "ax25_rx": ("AX.25 receive: NRZI, then de-stuffing", True),
    "usb_rx": ("USB receive: NRZI, then the bit after six 1s dropped", True),
}
# eth_rx describes its roles in its element list rather than a "Roles:" line
ROLES_OVERRIDE = {"eth_rx": {"rx bit": 1, "drop": 6, "flag": 7}}


def comments():
    """{config name: comment text} for every `let <name> ~n_le` with a comment just above it"""
    found = {}
    for src in SOURCES:
        text = src.read_text()
        for m in re.finditer(r"\(\*((?:(?!\*\)).)*)\*\)\s*let (\w+) ~n_le", text, re.S):
            body = " ".join(line.strip() for line in m.group(1).splitlines())
            found[m.group(2)] = re.sub(r"\s+", " ", body).strip()
    return found


def roles(comment):
    m = re.search(r"Roles: ([^.]*)\.", comment)
    out = {}
    if m:
        for part in m.group(1).split(","):
            k, _, v = part.partition("=")
            if v.strip().isdigit():
                out[k.strip()] = int(v)
    return out


def element(word):
    sel = [(word >> (16 + 3 * k)) & 7 for k in range(4)]
    return {"lut": word & 0xFFFF, "inputs": [SOURCE_NAMES[s] for s in sel], "input_codes": sel,
            "shows": "flop" if (word >> 28) & 1 else "lut", "init": (word >> 29) & 1,
            "clock": "rx" if (word >> 30) & 1 else "tx", "word": f"{word:08x}"}


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    notes = comments()
    out = []
    for name, (title, post) in CONFIGS.items():
        words = subprocess.run([str(WORDS), name], capture_output=True, text=True, check=True).stdout.split()
        comment = notes.get(name, "")
        out.append({"name": name, "title": title, "after_freeze": post, "proved": True,
                    "roles": ROLES_OVERRIDE.get(name, roles(comment)), "comment": comment,
                    "elements": [element(int(w, 16)) for w in words]})
    pathlib.Path(sys.argv[1]).write_text(json.dumps(out, indent=1))
    for c in out:
        used = sum(1 for e in c["elements"] if e["lut"] or e["init"])
        print(f"{c['name']}: {used} elements, roles {c['roles']}")


if __name__ == "__main__":
    main()
