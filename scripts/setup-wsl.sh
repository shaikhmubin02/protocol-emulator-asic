#!/usr/bin/env bash
# Toolchain setup for WSL Ubuntu 24.04. Run inside WSL:
#   bash /mnt/d/emulator-asic/scripts/setup-wsl.sh
# Idempotent: safe to re-run.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "== apt packages (needs sudo) =="
sudo apt-get update
sudo apt-get install -y \
  build-essential git curl unzip pkg-config \
  python3 python3-pip python3-venv \
  iverilog verilator yosys gtkwave \
  z3 boolector \
  opam autoconf libgmp-dev libffi-dev

echo "== Python venv with cocotb (pinned by template) =="
python3 -m venv "$HOME/.venvs/asic"
"$HOME/.venvs/asic/bin/pip" install --upgrade pip
"$HOME/.venvs/asic/bin/pip" install -r "$REPO/test/requirements.txt"

echo "== OxCaml + Hardcaml (as recommended by hardcaml.org) =="
SWITCH=5.2.0+ox
if [ ! -d "$HOME/.opam" ]; then
  opam init -y --disable-sandboxing --bare
fi
opam update --all
if ! opam switch list --short | grep -qxF "$SWITCH"; then
  opam switch create "$SWITCH" -y \
    --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
fi
eval "$(opam env --switch="$SWITCH")"
opam install -y dune core utop ocamlformat merlin ocaml-lsp-server \
  hardcaml hardcaml_waveterm ppx_hardcaml

echo
echo "Done. In new shells run:"
echo "  source ~/.venvs/asic/bin/activate && eval \$(opam env --switch=$SWITCH)"
