#!/usr/bin/env python3
"""Turn a pad recording (hw/test/pad_vcd.ml writes them) into compact JSON for the web page.

    scripts/site_data/vcd_to_json.py <in.vcd> [--expect in.expect] [--pins uo0,uio1] [--out f.json]

Output: {"name", "timescale_ns", "end", "signals": [{"name", "edges": [[t, v], ...]}],
"notes": {key: [hex bytes]}}. Only signals that change are kept, unless --pins names them.
Times are in the VCD's units (pad_vcd uses 1 ns).
"""
import argparse
import json
import os
import re
import sys


def parse_vcd(path):
    ids, names, edges, now, ts = {}, [], {}, 0, 1
    with open(path) as f:
        text = f.read()
    head, _, body = text.partition("$enddefinitions")
    m = re.search(r"\$timescale\s+(\d+)\s*(\w+)\s+\$end", head)
    if m:
        ts = int(m.group(1)) * {"s": 1e9, "ms": 1e6, "us": 1e3, "ns": 1, "ps": 1e-3}[m.group(2)]
    for code, name in re.findall(r"\$var\s+\w+\s+1\s+(\S+)\s+(\S+)(?:\s+\[\d+\])?\s+\$end", head):
        ids.setdefault(code, []).append(name)
        names.append(name)
        edges[name] = []
    for tok in body.split()[1:]:
        if tok[0] == "#":
            now = int(tok[1:])
        elif tok[0] in "01xz" and tok[1:] in ids:
            v = 1 if tok[0] == "1" else 0
            for name in ids[tok[1:]]:
                e = edges[name]
                if not e or e[-1][1] != v:
                    e.append([now, v])
    return names, edges, now, ts


def parse_expect(path):
    notes = {}
    if path and os.path.exists(path):
        for line in open(path):
            parts = line.split()
            if parts:
                notes[parts[0]] = parts[1:]
    return notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("--expect")
    ap.add_argument("--pins", help="comma-separated signals to keep even if they never change")
    ap.add_argument("--out")
    a = ap.parse_args()
    names, edges, end, ts = parse_vcd(a.vcd)
    keep = set(a.pins.split(",")) if a.pins else set()
    signals = [{"name": n, "edges": edges[n]} for n in names if len(edges[n]) > 1 or n in keep]
    expect = a.expect or re.sub(r"\.vcd$", ".expect", a.vcd)
    doc = {
        "name": os.path.splitext(os.path.basename(a.vcd))[0],
        "timescale_ns": ts,
        "end": end,
        "signals": signals,
        "notes": parse_expect(expect),
    }
    out = json.dumps(doc, separators=(",", ":"))
    if a.out:
        open(a.out, "w").write(out)
    else:
        sys.stdout.write(out)
    print(f"{doc['name']}: {len(signals)} active signals, "
          f"{sum(len(s['edges']) for s in signals)} edges, end {end}, {len(out)} bytes",
          file=sys.stderr)


if __name__ == "__main__":
    main()
