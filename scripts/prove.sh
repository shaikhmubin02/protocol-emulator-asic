#!/usr/bin/env bash
# Prove the engine properties by induction, on each engine variant in the generated chip Verilog.
# Uses only Yosys's built-in SAT solver.
#   formal/engine_props.sv  pin ownership, a stopped engine drives nothing, mailbox bounds
#   formal/timing_props.sv  the cycle count of every instruction, whatever happens outside
#   scripts/prove.sh [verilog]   (default: src/pemu.v)
set -euo pipefail
cd "$(dirname "$0")/.."
v=${1:-src/pemu.v}
status=0
for props in engine_props timing_props; do
    for e in engine engine_lite; do
        # the lite variant only exists in builds with fewer than four full engines
        grep -q "^module $e\b" "$v" || { echo "$props on $e: not in $v, skipped"; continue; }
        log=$(mktemp)
        if yosys -q -l "$log" -p "
            read_verilog -sv $v
            read_verilog -formal formal/sram_any.v formal/latch_any.v
            read_verilog -formal -sv -DENGINE=$e formal/$props.sv
            hierarchy -top $props
            proc; flatten; async2sync; opt_clean
            sat -tempinduct -prove-asserts -set-assumes -set-init-zero -maxsteps 4 -verify
        " > /dev/null 2>&1; then
            echo "$props on $e: proved ($(grep -o 'Induction step proven: SUCCESS!' "$log" | head -1 | sed 's/: SUCCESS!//'))"
        else
            echo "$props on $e: FAILED"
            grep -E 'failed|FAIL|counter|ERROR|Assert' "$log" | head -20
            status=1
        fi
        rm -f "$log"
    done
done
exit $status
