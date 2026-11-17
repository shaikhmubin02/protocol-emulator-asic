#!/usr/bin/env bash
# Prove the engine and chip properties by induction on the generated chip Verilog.
# Uses only Yosys's built-in SAT solver.
#   formal/engine_props.sv  pin ownership, a stopped engine drives nothing, mailbox bounds
#   formal/timing_props.sv  the cycle count of every instruction, pin-write latency, the exact
#                           finish cycle of waits, the debugger's same-cycle stop
#   formal/chip_props.sv    the chip around the engines (engines replaced by free outputs):
#                           pads, one owner per pin, breakpoint fan-out, shared time and flags
#   scripts/prove.sh [verilog]   (default: src/pemu.v)
set -euo pipefail
cd "$(dirname "$0")/.."
v=${1:-src/pemu.v}
status=0

report() {  # name log ok
    if [ "$3" = 1 ]; then
        echo "$1: proved ($(grep -o 'Induction step proven: SUCCESS!' "$2" | head -1 | sed 's/: SUCCESS!//'))"
    else
        echo "$1: FAILED"
        grep -E 'failed|FAIL|counter|ERROR|Assert' "$2" | head -20
        status=1
    fi
}

for props in engine_props timing_props; do
    for e in engine engine_lite; do
        # the lite variant only exists in builds with fewer than four full engines
        grep -q "^module $e\b" "$v" || { echo "$props on $e: not in $v, skipped"; continue; }
        log=$(mktemp)
        ok=0
        yosys -q -l "$log" -p "
            read_verilog -sv $v
            read_verilog -formal formal/sram_any.v formal/latch_any.v
            read_verilog -formal -sv -DENGINE=$e formal/$props.sv
            hierarchy -top $props
            proc; flatten; async2sync; opt_clean
            sat -tempinduct -prove-asserts -set-assumes -set-init-zero -maxsteps 4 -verify
        " > /dev/null 2>&1 && ok=1
        report "$props on $e" "$log" $ok
        rm -f "$log"
    done
done

# The chip: empty every engine (its outputs become free on every cycle), then tie the harness's
# observation wires to the engine ports. -nounset keeps the harness's own uses of those wires.
ties=""
n=$(grep -cE '^\s+engine(_lite)?$' "$v" || true)
for ((e = 0; e < n; e++)); do
    for p in owned:owned out:out oe:oe trig:dbg_trigger others:dbg_others_hit time:time \
             evf:ev_flags set:flag_set clr:flag_clr; do
        ties="$ties connect -nounset -set ${p%%:*}$e chip.engine$e.${p##*:};"
    done
done
if [ "$n" = 4 ]; then
    log=$(mktemp)
    ok=0
    yosys -q -l "$log" -p "
        read_verilog -sv $v
        read_verilog -formal formal/sram_any.v formal/latch_any.v
        read_verilog -formal -sv formal/chip_props.sv
        hierarchy -top chip_props
        proc
        delete engine/t:* engine_lite/t:*
        flatten
        $ties
        opt_clean
        setundef -undriven -anyseq
        async2sync; opt_clean
        sat -tempinduct -prove-asserts -set-assumes -set-init-zero -maxsteps 4 -verify
    " > /dev/null 2>&1 && ok=1
    report "chip_props" "$log" $ok
    rm -f "$log"
else
    echo "chip_props: written for four engines, $n in $v, skipped"
fi
exit $status
