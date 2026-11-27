#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0
"""Waveform data for the write-up's page: the pins of a recorded RTL run and what the stock
sigrok decoders read from them, as one JSON file per recording.

The recordings are the ones scripts/sigrok_check.sh makes (PEMU_VCD_DIR); the decoder stack
for each is the one scripts/sigrok_check.py checks, so every field shown on the page is one the
check compares with the test's own data.

    scripts/site_data/waveforms.py <vcd dir> <out dir> [name ...]   (default: every recording)

Each file: {"name", "end_ns", "pins": {pin: [[ns, level], ...]},
            "rows": [{"decoder", "items": [[start_ns, end_ns, text], ...]}]}
"""
import json
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import sigrok_check as sc  # noqa: E402


def read_vcd(path):
    """{pin name: [[ns, level], ...]} from a pads VCD (one wire per pin)."""
    ids, pins, t = {}, {}, 0
    for line in path.read_text().splitlines():
        if line.startswith("$var"):
            f = line.split()
            ids[f[3]] = f[4]
            pins[f[4]] = []
        elif line.startswith("#"):
            t = int(line[1:])
        elif line[:1] in "01" and line[1:] in ids:
            trace = pins[ids[line[1:]]]
            level = int(line[0])
            if not trace or trace[-1][1] != level:
                trace.append([t, level])
    return pins, t


def pins_of(stack):
    """the pins a decoder stack reads: the values of its channel options (uo0, uio4, ...)"""
    return sorted({v for d in stack for v in re.findall(r"=(u[io]{1,2}\d|ui\d)", d)})


def annotations(vcd, stack, name):
    """every annotation of every decoder in the stack, with its time span in ns"""
    step = sc.downsample(vcd)
    opts = f"vcd:downsample={step}"
    offset = 0
    if name in sc.START_AT_FIRST_EDGE:
        offset = sc.first_edge(vcd, sc.START_AT_FIRST_EDGE[name])
        opts += f":skip={offset}"
    decoders = [d.split(":")[0] for d in stack]
    cmd = ["sigrok-cli", "-I", opts, "-i", str(vcd), "-P", ",".join(stack),
           "-A", ",".join(decoders), "--protocol-decoder-samplenum"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    rows = {}
    for line in out.splitlines():
        m = re.match(r"(\d+)-(\d+) ([\w-]+?)-\d+: (.*)$", line)
        if not m:
            continue
        a, b, dec, text = m.groups()
        rows.setdefault(dec, []).append([offset + int(a) * step, offset + int(b) * step, text])
    return [{"decoder": d, "items": rows[d]} for d in decoders if d in rows]


def export(vcd, out):
    name = vcd.stem
    case = sc.CASES.get(name)
    if case is None:
        return None
    stack = case[0]
    pins, end = read_vcd(vcd)
    keep = pins_of(stack)
    data = {"name": name, "end_ns": end, "pins": {p: pins[p] for p in keep if p in pins},
            "rows": annotations(vcd, stack, name)}
    path = out / f"{name}.json"
    path.write_text(json.dumps(data, separators=(",", ":")))
    return path, sum(len(v) for v in data["pins"].values()), sum(len(r["items"]) for r in data["rows"])


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    names = sys.argv[3:]
    vcds = [src / f"{n}.vcd" for n in names] if names else sorted(src.glob("*.vcd"))
    for vcd in vcds:
        r = export(vcd, out)
        if r:
            path, edges, items = r
            print(f"{path.name}: {edges} edges, {items} decoded items, {path.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
