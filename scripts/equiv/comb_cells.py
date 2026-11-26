#!/usr/bin/env python3
"""Write the PDK's combinational cell models without the cells that use UDP tables.

    scripts/equiv/comb_cells.py <sg13cmos5l_stdcell.v> <out.v>

The cells built on UDPs (flip-flops, latches, muxes) are replaced by scripts/equiv/cells_seq.v.
Specify blocks are dropped; everything else is copied as it is.
"""
import re
import sys

src, out = sys.argv[1], sys.argv[2]
text = open(src).read()
# real declarations only: the file's comment headers also contain "module name: ..."
mods = re.findall(r"^(module\s+(\w+)\s*\(.*?^endmodule)", text, re.S | re.M)
kept, dropped = [], []
for body, name in mods:
    if re.search(r"\bihp_\w+\s*\(", body):
        dropped.append(name)
        continue
    body = re.sub(r"\bspecify\b.*?\bendspecify\b", "", body, flags=re.S)
    kept.append(body)
open(out, "w").write("`timescale 1ns/1ps\n" + "\n\n".join(kept) + "\n")
print(f"kept {len(kept)} cells, dropped {len(dropped)} built on UDPs: {' '.join(dropped)}")
