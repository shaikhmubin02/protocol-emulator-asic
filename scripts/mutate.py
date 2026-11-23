#!/usr/bin/env python3
"""Mutation campaign on the RTL source (hw/src/engine.ml, hw/src/chip.ml).

Each mutant changes one operator or constant in the Hardcaml source. It is built in a private
copy of hw/ and run against, in order:
  1. the RTL-vs-model lockstep tests (random programs, real firmware, the whole chip),
  2. the proofs (scripts/prove.sh on the Verilog generated from the mutant),
and is reported as: did not compile / killed by lockstep / killed by proofs / survived.
A survivor is either equivalent to the original or a gap in the checks; each one gets a written
argument in the report.

    scripts/mutate.py list                      list every mutant (id, file, line, change)
    scripts/mutate.py run [--ids 1,5,9] [--sample N --seed S] [--out results.jsonl]
"""
import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ["hw/src/engine.ml", "hw/src/chip.ml"]
WORK = os.path.expanduser("~/pemu_mut")
LOCKSTEP_TESTS = ["test_lockstep.ml", "test_chip_lockstep.ml", "test_chip.ml"]

# (name, pattern, replacement). Patterns match Hardcaml operators as written in the source.
OPERATORS = [
    ("and->or", r"&:", "|:"),
    ("or->and", r"\|:", "&:"),
    ("add->sub", r"\+:(?=[ .])", "-:"),
    ("sub->add", r"-:(?=[ .])", "+:"),
    ("eq->ne", r"==:", "<>:"),
    ("ne->eq", r"<>:", "==:"),
    ("lt->le", r"<:(?=[ .])", "<=:"),
    ("le->lt", r"<=:", "<:"),
    ("ge->gt", r">=:", ">:"),
    ("gt->ge", r"(?<![<])>:(?=[ .])", ">=:"),
    ("drop not", r"~:", ""),
    ("vdd->gnd", r"\bvdd\b", "gnd"),
    ("gnd->vdd", r"\bgnd\b", "vdd"),
    ("const+1", r"(?<=:\. )(\d+)\b", lambda m: str(int(m.group(1)) + 1)),  # "==:. N" etc.
    # an update that never happens: when_ c [...] -> when_ (gnd &: c) [...]
    ("when off", r"\bwhen_ (\((?:[^()]|\([^()]*\))*\)|[a-z_][a-z_0-9.]*)",
     lambda m: f"when_ (gnd &: {m.group(1)})"),
]


def comment_mask(s):
    """True for every character inside an OCaml comment (nested) or a string literal."""
    mask = [False] * len(s)
    i, depth, in_str = 0, 0, False
    while i < len(s):
        if not in_str and s.startswith("(*", i):
            depth += 1
            mask[i] = mask[i + 1] = True
            i += 2
            continue
        if depth and s.startswith("*)", i):
            depth -= 1
            mask[i] = mask[i + 1] = True
            i += 2
            continue
        if not depth and s[i] == '"' and (i == 0 or s[i - 1] != "\\"):
            in_str = not in_str
        mask[i] = depth > 0 or in_str or s[i] == '"'
        i += 1
    return mask


def mutants():
    out = []
    for f in FILES:
        s = open(os.path.join(ROOT, f), newline="").read()
        mask = comment_mask(s)
        for name, pat, rep in OPERATORS:
            for m in re.finditer(pat, s):
                if mask[m.start()]:
                    continue
                new = rep(m) if callable(rep) else rep
                line = s.count("\n", 0, m.start()) + 1
                out.append({"file": f, "op": name, "start": m.start(), "end": m.end(),
                            "new": new, "line": line,
                            "text": s.splitlines()[line - 1].strip()[:120]})
    for k, m in enumerate(out):
        m["id"] = k + 1
    return out


def sh(cmd, cwd, timeout):
    env = dict(os.environ)
    try:
        r = subprocess.run(["bash", "-c", cmd], cwd=cwd, capture_output=True, text=True,
                           timeout=timeout, env=env)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def prepare():
    # copy the sources over any earlier copy (which may hold a half-run mutant), keeping its
    # _build so dune only rebuilds what changed
    for d in ["hw", "formal", "scripts"]:
        shutil.copytree(os.path.join(ROOT, d), os.path.join(WORK, d), dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("_build", "*.corrected"))
    os.makedirs(os.path.join(WORK, "src"), exist_ok=True)
    rc, log = sh("dune build -j 1 2>&1 | tail -5", os.path.join(WORK, "hw"), 3600)
    if rc:
        sys.exit("original does not build:\n" + log)


def run_tests(hw):
    runner = "./.pemu_test.inline-tests/inline-test-runner.exe inline-test-runner pemu_test"
    for t in LOCKSTEP_TESTS:
        for c in os.listdir(os.path.join(hw, "_build/default/test")):
            if c.endswith(".corrected"):
                os.remove(os.path.join(hw, "_build/default/test", c))
        rc, log = sh(f"{runner} -only-test {t} -source-tree-root . -diff-cmd -",
                     os.path.join(hw, "_build/default/test"), 1800)
        # The runner can leave a .corrected file identical to the source even when every test
        # passes, so a test only counts as failed if the file differs (or the runner fails).
        corrected = os.path.join(hw, "_build/default/test", t + ".corrected")
        a = open(os.path.join(hw, "test", t)).read().splitlines()
        b = open(corrected).read().splitlines() if os.path.exists(corrected) else a
        if rc or a != b:
            new = [l.strip() for l in b if l not in set(a) and len(l.strip()) > 2]
            first = next((l for l in new if re.search(r"differ|Mismatch|cycle|seed", l)),
                         new[0] if new else "")
            return t, (first or log.strip().splitlines()[-1:] or ["runner failed"])[0][:160]
    return None, ""


def run_one(m):
    t0 = time.time()
    r = check_one(m)
    r["seconds"] = round(time.time() - t0)
    return r


def check_one(m):
    hw = os.path.join(WORK, "hw")
    path = os.path.join(WORK, m["file"])
    orig = open(path, newline="").read()
    open(path, "w", newline="").write(orig[: m["start"]] + m["new"] + orig[m["end"]:])
    try:
        build = ("dune build -j 1 ./bin/generate.exe ./test/.pemu_test.inline-tests/inline-test-runner.exe "
                 "$(cd firmware && ls *.s | sed 's|^|./firmware/|') 2>&1 | head -30")
        rc, log = sh(build, hw, 3600)
        if rc or "Error" in log:
            return dict(m, result="did not compile", detail=log.strip()[:200])
        test, detail = run_tests(hw)
        if test:
            return dict(m, result="killed by lockstep", by=test, detail=detail)
        rc, _ = sh("./_build/default/bin/generate.exe chip > ../src/pemu.v", hw, 600)
        rc, log = sh("bash scripts/prove.sh src/pemu.v", WORK, 7200)
        if rc:
            failed = [l for l in log.splitlines() if "FAILED" in l]
            return dict(m, result="killed by proofs", by=" ".join(failed)[:160])
        return dict(m, result="survived")
    finally:
        open(path, "w", newline="").write(orig)


def host_free_gb():
    """Free physical memory of the Windows host (WSL interop), or None if it can't be read."""
    try:
        out = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command",
             "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory"],
            capture_output=True, text=True, timeout=60).stdout
        return int(out.strip()) / 1024 / 1024
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["list", "run"])
    ap.add_argument("--ids")
    ap.add_argument("--sample", type=int)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default=os.path.join(WORK + "_results.jsonl"))
    ap.add_argument("--baseline", action="store_true",
                    help="run the unmutated source through the same checks (must survive)")
    ap.add_argument("--min-free-gb", type=float, default=0,
                    help="stop before a mutant if the host has less free memory than this")
    a = ap.parse_args()
    if a.baseline:
        prepare()
        r = run_one({"id": 0, "file": FILES[0], "op": "none", "start": 0, "end": 0, "new": "",
                     "line": 0, "text": "the unmutated source"})
        print(f"baseline: {r['result']} {r.get('by', '')} {r.get('detail', '')} ({r['seconds']} s)")
        return
    ms = mutants()
    if a.cmd == "list":
        for m in ms:
            print(f"{m['id']:4} {m['file']}:{m['line']:<4} {m['op']:9} {m['text']}")
        print(f"{len(ms)} mutants", file=sys.stderr)
        return
    if a.ids:
        want = {int(x) for x in a.ids.split(",")}
        ms = [m for m in ms if m["id"] in want]
    if a.sample:
        ms = sorted(random.Random(a.seed).sample(ms, min(a.sample, len(ms))), key=lambda m: m["id"])
    done = set()
    if os.path.exists(a.out):
        done = {json.loads(l)["id"] for l in open(a.out) if l.strip()}
    todo = [m for m in ms if m["id"] not in done]
    print(f"{len(todo)} to run ({len(done)} already in {a.out})", flush=True)
    if todo:
        prepare()
    with open(a.out, "a") as out:
        for m in todo:
            free = host_free_gb()
            if a.min_free_gb and free is not None and free < a.min_free_gb:
                print(f"stopping: {free:.1f} GB free, below {a.min_free_gb} GB", flush=True)
                return
            r = run_one(m)
            out.write(json.dumps(r) + "\n")
            out.flush()
            print(f"{r['id']:4} {r['op']:9} {r['file']}:{r['line']:<4} {r['result']} "
                  f"{r.get('by', '')} ({r['seconds']} s)", flush=True)


if __name__ == "__main__":
    main()
