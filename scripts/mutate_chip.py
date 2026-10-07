"""Plants one bug at a time in hw/src/chip.ml and checks that the chip-level lockstep test
(hw/test/test_chip_lockstep.ml) catches it. chip.ml is put back afterwards.

Run in WSL from anywhere: python3 scripts/mutate_chip.py"""
import os
import subprocess

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hw")
SRC = os.path.join(ROOT, "src/chip.ml")

MUTANTS = [
    ("mailbox pop at fetch time",
     "(rise &: pop_pending.value &: (pop_engine.value ==:. e))",
     "(word_loaded &: (r_engine ==:. e) &: (r_region ==:. 2) &: bit r_off 7)"),
    ("flag clear wins over set",
     "((flags_base &: ~:flag_clr) |: flag_set)",
     "((flags_base |: flag_set) &: ~:flag_clr)"),
    ("pin owner enable bit ignored",
     "    o &: bit owners.(q).value 2\n",
     "    o\n"),
    ("MISO not gated to the data words",
     "selected &: reading &: (count.value >=:. 32) &: msb shift_out.value",
     "selected &: reading &: msb shift_out.value"),
    ("run register drops engine 3",
     "[ run <-- wr_data.value.:[n_engines - 1, 0] ]",
     "[ run <-- gnd @: wr_data.value.:[2, 0] ]"),
    ("status word: inbox and outbox counts swapped",
     "[ o.pc; o.halted; bit run.value e; o.inbox_count; o.outbox_count; o.be_enabled; gnd ]",
     "[ o.pc; o.halted; bit run.value e; o.outbox_count; o.inbox_count; o.be_enabled; gnd ]"),
    ("owned mask uses the wrong engine",
     "; owned = concat_lsb (List.init n_pins ~f:(fun q -> owner_is q e))",
     "; owned = concat_lsb (List.init n_pins ~f:(fun q -> owner_is q ((e + 1) % n_engines)))"),
]

RUN = f"""
eval "$(opam env --switch=5.2.0+ox)"
cd {ROOT}
dune build -j 2 test/.pemu_test.inline-tests/inline-test-runner.exe > /tmp/mut_build.log 2>&1 || exit 3
cd _build/default/test
rm -f test_chip_lockstep.ml.corrected
timeout 900 ./.pemu_test.inline-tests/inline-test-runner.exe inline-test-runner pemu_test \
  -only-test test_chip_lockstep.ml -source-tree-root . -diff-cmd - > /tmp/mut_run.log 2>&1
if [ -f test_chip_lockstep.ml.corrected ]; then exit 1; else exit 0; fi
"""

original = open(SRC).read()
results = []
try:
    for name, a, b in MUTANTS:
        n = original.count(a)
        if n != 1:
            results.append((name, f"pattern found {n} times, skipped"))
            continue
        open(SRC, "w").write(original.replace(a, b))
        rc = subprocess.run(["bash", "-c", RUN]).returncode
        if rc == 3:
            verdict = "DID NOT COMPILE"
        elif rc == 1:
            corrected = open(os.path.join(ROOT, "_build/default/test/test_chip_lockstep.ml.corrected")).read()
            if "chip and model differ" in corrected:
                verdict = "caught (pins)"
            elif "uncaught_exn" in corrected:
                verdict = "caught (model)"
            else:
                verdict = "only stats moved"
        else:
            verdict = "NOT CAUGHT"
        results.append((name, verdict))
        print(f"{verdict:16} {name}", flush=True)
finally:
    open(SRC, "w").write(original)
print("restored chip.ml")
for name, v in results:
    print(f"  {v:16} {name}")
