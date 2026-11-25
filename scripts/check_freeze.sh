#!/usr/bin/env bash
# Check that the hardware has not changed since the RTL freeze.
#   - the hardware sources (hw/src, the generated Verilog, the flow plugin and power script, the
#     SRAM macro, info.yaml) are identical to the tag;
#   - src/config.json has the same settings as at the tag (its "//" comments may change);
#   - the Verilog generated from hw/src now is byte-identical to src/pemu.v.
# Everything after the freeze is firmware, fabric configuration, tests and documents.
set -e
cd "$(dirname "$0")/.."
tag=rtl-freeze-2026-11-26
git diff --exit-code --stat "$tag" -- hw/src src/pemu.v info.yaml librelane_plugin_pemu.py \
  scripts/bridge_sram_power.py src/pdn_cfg.tcl macro
echo "hardware sources: identical to $tag"
python3 - "$tag" <<'EOF'
import json, subprocess, sys
strip = lambda d: {k: v for k, v in d.items() if k != "//"}
then = json.loads(subprocess.run(["git", "show", f"{sys.argv[1]}:src/config.json"],
                                 capture_output=True, text=True, check=True).stdout,
                  object_pairs_hook=lambda kv: strip(dict(kv)))
now = json.load(open("src/config.json"), object_pairs_hook=lambda kv: strip(dict(kv)))
if then != now:
    sys.exit("src/config.json settings differ from the freeze")
print("flow settings: identical to the freeze (comments aside)")
EOF
(cd hw && dune build -j 1 ./bin/generate.exe 2>&1 | head -20 && ./_build/default/bin/generate.exe chip) \
  | cmp - src/pemu.v
echo "regenerated Verilog: identical to src/pemu.v"
