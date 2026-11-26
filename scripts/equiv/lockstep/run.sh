#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0
#
# RTL vs signed-off netlist in simulation: both under Verilator in one model, the same random
# board activity on their inputs, every output compared every cycle (lockstep.cpp).
#   scripts/equiv/lockstep/run.sh <netlist.v> <sg13cmos5l_stdcell.v> [first seed] [seeds] [cycles]
# The netlist is tt_submission/tt_um_shaikhmubin02_pemu.v from the gds run's artifact; the cell
# models are the PDK's sg13cmos5l_stdcell.v (the flops, latch and muxes it builds from UDP tables
# come from scripts/equiv/cells_seq_nolatch.v and test/sim_models.v instead).
set -euo pipefail
cd "$(dirname "$0")/../../.."
out=build/equiv/lockstep
mkdir -p "$out"
sed 's/^module tt_um_shaikhmubin02_pemu /module tt_um_gl /' "$1" > "$out/netlist_gl.v"
python3 scripts/equiv/comb_cells.py "$2" "$out/comb_cells.v"
# -DSYNTHESIS only drops the SRAM model's check at time 0 that A_DLY is tied high: the netlist
# ties it through a tie cell, which has not settled when that check runs. Nothing else uses it.
verilator --cc --exe --build -j 1 -O1 --no-timing -Wno-fatal -Wno-lint -Wno-style -Wno-LATCH \
  -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -Wno-COMBDLY -Wno-STMTDLY -Wno-MULTIDRIVEN -DFUNCTIONAL -DSYNTHESIS \
  --top-module lockstep -Mdir "$out/obj" -o ../lockstep_sim \
  scripts/equiv/lockstep/lockstep.v src/pemu.v test/sim_models.v \
  test/models/RM_IHPSG13_1P_core_behavioral_bm_bist.v test/models/RM_IHPSG13_1P_256x16_c2_bm_bist.v \
  "$out/netlist_gl.v" "$out/comb_cells.v" scripts/equiv/cells_seq_nolatch.v \
  "$(pwd)/scripts/equiv/lockstep/lockstep.cpp" > "$out/build.log" 2>&1 || { tail -30 "$out/build.log"; exit 1; }
first=${3:-1}
n=${4:-4}
cycles=${5:-1000000}
for s in $(seq "$first" $((first + n - 1))); do
  "$out/lockstep_sim" "$s" "$cycles"
done
