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
# the designed-for protocols (test_lockstep.ml) and the ones written after the freeze (test_post.ml)
for t in test_lockstep.ml test_post.ml test_post2.ml; do
  PEMU_VCD_DIR="$out" ./.pemu_test.inline-tests/inline-test-runner.exe inline-test-runner pemu_test \
      -only-test "$t" -source-tree-root . -diff-cmd -
done
python3 "$root/scripts/sigrok_check.py" "$out" --md "$out/sigrok.md"
