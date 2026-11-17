#!/usr/bin/env bash
# Run the protocol lockstep tests with pad recording on, then check the recorded RTL waveforms
# with the stock sigrok decoders (scripts/sigrok_check.py). Needs sigrok-cli.
#   scripts/sigrok_check.sh [out dir]   (default: hw/_build/vcd)
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
out=$(realpath -m "${1:-hw/_build/vcd}")
rm -rf "$out"
mkdir -p "$out"
cd hw
dune build -j 1 ./test/.pemu_test.inline-tests/inline-test-runner.exe \
    $(cd firmware && ls *.s | sed 's|^|./firmware/|')
cd _build/default/test
PEMU_VCD_DIR="$out" ./.pemu_test.inline-tests/inline-test-runner.exe inline-test-runner pemu_test \
    -only-test test_lockstep.ml -source-tree-root . -diff-cmd -
python3 "$root/scripts/sigrok_check.py" "$out" --md "$out/sigrok.md"
