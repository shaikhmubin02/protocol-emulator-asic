#!/usr/bin/env bash
# Toolchain setup for WSL Ubuntu 24.04. Run inside WSL:
#   bash /mnt/d/emulator-asic/scripts/setup-wsl.sh
# Safe to re-run.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$HOME/tools"
mkdir -p "$TOOLS"

echo "== apt packages =="
sudo apt-get update
sudo apt-get install -y \
  build-essential git curl unzip pkg-config \
  python3 python3-pip python3-venv \
  iverilog verilator yosys gtkwave minisat \
  opam autoconf libgmp-dev libffi-dev

echo "== python venv with cocotb =="
python3 -m venv "$HOME/.venvs/asic"
"$HOME/.venvs/asic/bin/pip" install --upgrade pip
"$HOME/.venvs/asic/bin/pip" install -r "$REPO/test/requirements.txt"

# CI uses the apt iverilog, so tests run with that. OSS CAD Suite is only for formal
# (sby, yosys-smtbmc, solvers) and is kept off the default PATH.
echo "== OSS CAD Suite =="
if [ ! -x "$TOOLS/oss-cad-suite/bin/sby" ]; then
  url=$(curl -fsS https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest \
    | grep -o 'https://[^"]*oss-cad-suite-linux-x64-[0-9]*\.tgz' | head -1)
  tgz="$TOOLS/$(basename "$url")"
  echo "downloading $url"
  # big file, the connection sometimes drops; resume until it's complete
  until curl -fL --retry 10 --retry-all-errors -C - -o "$tgz" "$url"; do
    echo "download interrupted, resuming"; sleep 5
  done
  rm -rf "$TOOLS/oss-cad-suite" "$TOOLS/oss-cad-suite.tmp"
  mkdir "$TOOLS/oss-cad-suite.tmp"
  tar xzf "$tgz" -C "$TOOLS/oss-cad-suite.tmp"
  mv "$TOOLS/oss-cad-suite.tmp/oss-cad-suite" "$TOOLS/oss-cad-suite"
  rmdir "$TOOLS/oss-cad-suite.tmp"
  rm -f "$tgz"
fi

echo "== OxCaml + Hardcaml =="
# Pin the compiler and the Jane Street package release together. The ox repo has releases
# with missing upper bounds, so left alone opam mixes minus39 with v0.18~preview.130.91,
# which doesn't build. 130.106 is declared for minus39/minus40. dune is the ox-patched one.
# Note: with this ppx_expect, every test dir needs (inline_tests (flags (-source-tree-root .)))
# or expect tests fail with "No such file or directory".
SWITCH=5.2.0+ox
COMPILER=oxcaml-compiler.5.2.0minus39
JS=v0.18~preview.130.106+341
if [ ! -d "$HOME/.opam" ]; then
  opam init -y --disable-sandboxing --bare
fi
opam update --all
if opam switch list --short | grep -qxF "$SWITCH" \
   && ! opam list --switch="$SWITCH" --installed --short "$COMPILER" | grep -q .; then
  echo "switch $SWITCH has the wrong compiler, recreating"
  opam switch remove "$SWITCH" -y
fi
if ! opam switch list --short | grep -qxF "$SWITCH"; then
  opam switch create "$SWITCH" -y -j 2 \
    --packages "ocaml-variants.5.2.0+ox,$COMPILER" \
    --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
fi
eval "$(opam env --switch="$SWITCH")"
opam install -y -j 2 "dune.3.22.2+ox" rope re utop ocamlformat merlin ocaml-lsp-server \
  core.$JS core_unix.$JS ppx_jane.$JS \
  hardcaml.$JS hardcaml_waveterm.$JS hardcaml_test_harness.$JS ppx_hardcaml.$JS \
  hardcaml_verify.$JS

echo
echo "Done. In new shells: source scripts/env.sh"
echo "For formal runs:     source ~/tools/oss-cad-suite/environment"
