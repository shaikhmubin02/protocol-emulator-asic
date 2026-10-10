#!/usr/bin/env bash
# Prove the engine properties in formal/engine_props.sv by induction, on both engine variants in
# the generated chip Verilog. Uses only Yosys's built-in SAT solver.
#   scripts/prove.sh [verilog]   (default: src/pemu.v)
set -euo pipefail
cd "$(dirname "$0")/.."
v=${1:-src/pemu.v}
status=0
for e in engine engine_lite; do
    log=$(mktemp)
    if yosys -q -l "$log" -p "
        read_verilog -sv $v
        read_verilog -formal formal/sram_any.v formal/latch_any.v
        read_verilog -formal -sv -DENGINE=$e formal/engine_props.sv
        hierarchy -top engine_props
        proc; flatten; async2sync; opt_clean
        sat -tempinduct -prove-asserts -set-assumes -set-init-zero -maxsteps 4 -verify
    " > /dev/null 2>&1; then
        echo "$e: proved ($(grep -o 'Induction step proven: SUCCESS!' "$log" | head -1 | sed 's/: SUCCESS!//'))"
    else
        echo "$e: FAILED"
        grep -E 'failed|FAIL|counter|ERROR' "$log" | head -20
        status=1
    fi
    rm -f "$log"
done
exit $status
