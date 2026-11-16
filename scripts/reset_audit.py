# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0

"""Reset audit.

1. src/pemu.v: every clocked block has an asynchronous reset on rst_n, and its reset branch
   sets every register the block assigns.
2. A gate-level netlist (optional argument, e.g. the tt_submission one): every flop cell is a
   flop with a reset pin, and that pin traces back to rst_n through buffers only.

The latches (fabric and CRC configuration) and the SRAMs have no reset; test/test.py
(test_power_up_state) checks that nothing depends on them until they are written.

    python scripts/reset_audit.py [gate_level_netlist.v]
"""

import collections
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def rtl(path):
    src = open(path).read()
    problems = 0
    for module, body in re.findall(r"^module (\w+) \((.*?)^endmodule", src, re.S | re.M):
        rst = re.search(r"assign (\w+) = rst_n;", body).group(1)
        blocks = re.findall(r"always @\(posedge \w+ or negedge (\w+)\) begin\n(.*?)\n    end\n", body, re.S)
        plain = len(re.findall(r"always @\(posedge \w+\)", body))
        for net, blk in blocks:
            m = re.match(r"\s*if \((\w+) == 0\)\n(.*?)\n\s*else\n(.*)", blk, re.S)
            if net != rst or not m or m.group(1) != net:
                print(f"{module}: block not reset by rst_n:\n{blk[:200]}")
                problems += 1
                continue
            missing = set(re.findall(r"(\w+) <=", m.group(3))) - set(re.findall(r"(\w+) <=", m.group(2)))
            if missing:
                print(f"{module}: not set on reset: {sorted(missing)}")
                problems += 1
        if plain:
            print(f"{module}: {plain} clocked blocks without a reset")
            problems += plain
        if not problems:
            print(f"{module}: {len(blocks)} clocked blocks, all reset by rst_n")
    return problems


def netlist(path):
    src = open(path).read()
    cells = re.findall(r"^\s*(sg13cmos5l_\w+|RM_IHPSG13\w+)\s+(\S+)\s*\((.*?)\);", src, re.S | re.M)
    driver = {}
    kinds = collections.Counter()
    reset_pins = collections.Counter()
    for typ, _, body in cells:
        pins = {k: v.strip() for k, v in re.findall(r"\.(\w+)\(([^()]*)\)", body)}
        outs = [p for p in ("X", "Y", "Q", "Q_N") if p in pins]
        for o in outs:
            driver[pins[o]] = (typ, [v for k, v in pins.items() if k not in outs])
        if re.match(r"sg13cmos5l_(s?df|dl[a-z]*q)", typ):  # flops and latches, not dlygate buffers
            kinds[typ] += 1
        if typ.startswith("sg13cmos5l_dfrbp"):
            reset_pins[pins["RESET_B"]] += 1
    for a, b in re.findall(r"assign\s+(\S+)\s*=\s*([^;]+);", src):
        driver.setdefault(a, ("assign", [b.strip()]))

    def source(net):
        for _ in range(64):
            typ, ins = driver.get(net, (None, None))
            if typ is None or not (typ == "assign" or typ.startswith(("sg13cmos5l_buf", "sg13cmos5l_dlygate"))):
                return net
            net = ins[0]
        return net

    for typ, n in sorted(kinds.items()):
        print(f"{n:6d} {typ}")
    flops = sum(n for t, n in kinds.items() if "df" in t)
    roots = collections.Counter()
    for net, n in reset_pins.items():
        roots[source(net)] += n
    for r, n in roots.items():
        print(f"{n:6d} flops have RESET_B from {r}")
    ok = sum(reset_pins.values()) == flops and set(roots) == {"rst_n"}
    print("every flop is reset by rst_n" if ok else "SOME FLOPS ARE NOT RESET BY rst_n")
    return 0 if ok else 1


if __name__ == "__main__":
    bad = rtl(os.path.join(HERE, "..", "src", "pemu.v"))
    if len(sys.argv) > 1:
        bad += netlist(sys.argv[1])
    sys.exit(1 if bad else 0)
