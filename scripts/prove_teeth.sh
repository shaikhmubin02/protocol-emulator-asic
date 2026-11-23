#!/usr/bin/env bash
# Checks that the proofs have teeth: each line below breaks one assertion in a copy of a
# property file (flips what it expects, or drops a condition it needs), and every broken copy
# must FAIL to prove. A broken copy that still proves would mean that assertion holds vacuously.
#   scripts/prove_teeth.sh [verilog]   (default: src/pemu.v; ONLY=<regex> picks some checks)
set -uo pipefail
cd "$(dirname "$0")/.."
v=${1:-src/pemu.v}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bad=0

engine_proves() {  # property file
    yosys -q -p "
        read_verilog -sv $v
        read_verilog -formal formal/sram_any.v formal/latch_any.v
        read_verilog -formal -sv -DENGINE=engine $1
        hierarchy -top timing_props
        proc; flatten; async2sync; opt_clean
        sat -tempinduct -prove-asserts -set-assumes -set-init-zero -maxsteps 4 -verify
    " > /dev/null 2>&1
}

chip_proves() {  # property file
    local ties=""
    for e in 0 1 2 3; do
        for p in owned:owned out:out oe:oe trig:dbg_trigger others:dbg_others_hit time:time \
                 evf:ev_flags set:flag_set clr:flag_clr; do
            ties="$ties connect -nounset -set ${p%%:*}$e chip.engine$e.${p##*:};"
        done
    done
    yosys -q -p "
        read_verilog -sv $v
        read_verilog -formal formal/sram_any.v formal/latch_any.v
        read_verilog -formal -sv $1
        hierarchy -top chip_props
        proc
        delete engine/t:*
        flatten
        $ties
        opt_clean
        setundef -undriven -anyseq
        async2sync; opt_clean
        sat -tempinduct -prove-asserts -set-assumes -set-init-zero -maxsteps 4 -verify
    " > /dev/null 2>&1
}

check() {  # kind name file from to
    # ONLY=<regex> runs just the checks whose name matches
    if [ -n "${ONLY:-}" ] && ! [[ "$2" =~ $ONLY ]]; then return; fi
    local m="$work/$2.sv"
    sed "s/$4/$5/" "formal/$3" > "$m"
    if cmp -s "$m" "formal/$3"; then
        echo "$2: the edit did not apply"; bad=1; return
    fi
    if "$1"_proves "$m"; then
        echo "$2: still proves (VACUOUS)"; bad=1
    else
        echo "$2: fails, as it should"
    fi
}

T=timing_props.sv
check engine pin_value  $T 'assert (out\[l_pin_p\] == l_pin_out' 'assert (out[l_pin_p] != l_pin_out'
check engine pin_tx     $T '\&\& !l_pin_is_tx)' ')'
check engine quiet_tx   $T ' \&\& !(l_be_en \&\& l_tx_pin == q))' ')'
check engine quiet_outg $T ' || l_op == 4.d8)' ')'
check engine wait_met   $T 'if (l_cond) assert (pc == l_pc + 8.d1 \&\& !flags\[2\]);' 'if (l_cond) assert (pc == l_pc);'
check engine wait_unmet $T 'else assert (pc == l_pc || (pc == l_pc + 8.d1 \&\& flags\[2\]));' 'else assert (pc == l_pc);'
check engine wait_tflag $T 'if (l_cond) assert (pc == l_pc + 8.d1 \&\& !flags' 'if (l_cond) assert (pc == l_pc + 8'"'"'d1 \&\& flags'
check engine bp_stop    $T 'if (steady \&\& l_run \&\& l_trigger \&\& !l_pc_we) assert (pc == l_pc \&\& busy == l_busy);' 'if (steady \&\& l_run \&\& l_trigger \&\& !l_pc_we) assert (pc != l_pc);'
check engine join_stop  $T 'if (steady \&\& l_run \&\& l_join \&\& l_others_hit' 'if (steady \&\& l_run \&\& l_others_hit'
check engine stay_stop  $T 'assert (stopped);' 'assert (!stopped);'

C=chip_props.sv
check chip pad_owner0   $C 'if (own\[0\]) assert (pad_out\[q\] == out0\[q\]);' 'if (own[0]) assert (pad_out[q] != out0[q]);'
check chip pad_owner3   $C 'if (own\[3\]) assert (pad_out\[q\] == out3\[q\]);' 'if (own[3]) assert (pad_out[q] != out3[q]);'
check chip pad_unowned  $C 'if (own == 0) assert (pad_out\[q\] == 0);' 'if (own == 0) assert (pad_out[q] == 1);'
check chip oe_owner     $C 'if (own\[1\]) assert (uio_oe\[q\] == oe1\[q\]);' 'if (own[1]) assert (uio_oe[q] != oe1[q]);'
check chip one_owner    $C 'assert ((own \& (own - 4.d1)) == 0);' "assert (own != 4'd4);"
check chip bp_fanout    $C 'assert (others0 == (trig1 | trig2 | trig3));' 'assert (others0 == (trig1 | trig2));'
check chip time_step    $C 'assert (time0 == l_time + 32.d1);' "assert (time0 == l_time + 32'd2);"
check chip sig_wins     $C 'assert ((evf0 \& l_set) == l_set);' 'assert ((evf0 \& l_clr) == 0);'

exit $bad
