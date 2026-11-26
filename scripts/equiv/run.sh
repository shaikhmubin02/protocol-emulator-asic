#!/usr/bin/env bash
# RTL vs signed-off netlist equivalence.
#   scripts/equiv/run.sh <netlist.v> <sg13cmos5l_stdcell.v>
# The netlist is tt_submission/tt_um_shaikhmubin02_pemu.v from the gds run's tt_submission
# artifact; the cell models are the PDK's libs.ref/sg13cmos5l_stdcell/verilog file at the PDK
# version the build used (pdk.json in the same artifact).
# Result on the netlist of gds run 45669465134: 7059 of 7203 points proven; the 144 left are
# the heads of the mailbox FIFOs (see docs/reviewer-guide.md). 13 minutes, 3 GB.
set -e
cd "$(dirname "$0")/../.."
mkdir -p build/equiv
cp "$1" build/equiv/netlist.v
python3 scripts/equiv/comb_cells.py "$2" build/equiv/comb_cells.v
yosys -q -l build/equiv/equiv.log scripts/equiv/equiv.ys || true
grep -E "Of those cells|Equivalence successfully|ERROR" build/equiv/equiv.log | tail -3
