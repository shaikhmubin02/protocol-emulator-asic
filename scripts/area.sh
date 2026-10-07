#!/usr/bin/env bash
# Quick area check without the PDK: generate the chip Verilog and run a generic Yosys synthesis.
# Prints cell counts per module (2-input gates, flops, config latches). Usage: scripts/area.sh
set -e
cd "$(dirname "$0")/../hw"
eval "$(opam env --switch=5.2.0+ox)"
dune build -j 2 2>&1 | head -20; [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "build failed"; exit 1; }
tmp=$(mktemp -d)
./_build/default/bin/generate.exe chip > "$tmp/chip.v"
cat > "$tmp/bb.v" <<'V'
(* blackbox *) module sg13cmos5l_dlhq_1(input D, input GATE, output Q); endmodule
V
yosys -q -p "read_verilog $tmp/bb.v ../src/RM_IHPSG13_1P_256x16_c2_bm_bist.v $tmp/chip.v; \
  hierarchy -top tt_um_shaikhmubin02_pemu; synth -top tt_um_shaikhmubin02_pemu; \
  abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX; opt_clean; tee -q -o $tmp/stat.txt stat" > "$tmp/yosys.log" 2>&1
awk '/^=== /{m=$2} /Number of cells/{c[m]=$NF} /\$_DFF/{f[m]+=$NF} /dlhq/{l[m]+=$NF}
     END{for (k in c) printf "%-28s cells %6d  flops %5d  latches %5d  gates %6d\n", k, c[k], f[k], l[k], c[k]-f[k]-l[k]}' "$tmp/stat.txt"
rm -rf "$tmp"
