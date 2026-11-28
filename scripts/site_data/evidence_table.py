#!/usr/bin/env python3
"""Build the per-protocol evidence table from what the repository actually contains.

    scripts/site_data/evidence_table.py [--md docs/protocols.md] [--json out.json]

For each firmware in hw/firmware it finds: its size (assembled, if hw/_build has the assembler),
the tests that run it against a model of the other end, the RTL-vs-model lockstep tests, the
cocotb pin-level tests (which CI also runs on the gate-level netlist), and the sigrok cases that
decode its recording. Nothing is typed in by hand except the "spec limits" notes below, which
name the test that checks them.
"""
import argparse
import glob
import json
import os
import re
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FW = os.path.join(ROOT, "hw", "firmware")
ASM = os.path.join(ROOT, "hw", "_build", "default", "bin", "asm.exe")
# test_post.ml: the protocols written after the freeze; each test there runs the RTL in lockstep
# with the model against a model of the other end, so it counts in both columns
MODEL_TESTS = ["test_protocols.ml", "test_targets.ml", "test_ethernet.ml", "test_post.ml", "test_post2.ml",
               "test_usb.ml"]
LOCKSTEP_TESTS = ["test_lockstep.ml", "test_post.ml", "test_post2.ml", "test_usb.ml"]
DESIGNED_FOR = {"uart", "spi_master", "spi_target", "i2c_master", "i2c_target", "ws2812",
                "onewire", "usb_tx", "usb_rx", "eth_tx", "eth_rx"}
# recordings whose name is not a firmware's: the test that makes each one runs these programs
SIGROK_RECORDINGS = {"jtag": ["jtag_host", "jtag_tap", "jtag_mon"], "swd": ["swd_host"],
                     "spdif": ["spdif_tx"], "wiegand": ["wiegand_tx"], "rc5": ["rc5_rx"],
                     "usb_dev": ["usb_dev_rx", "usb_dev_tx"]}
# files with SAT proofs of fabric configurations
PROOF_TESTS = ["test_bitstream_proof.ml", "test_post.ml", "test_post2.ml", "test_usb.ml"]
# test name fragments that mean "checked against limits from the specification"
SPEC_WORDS = re.compile(r"spec timing|\+-1\.5%|ppm|jitter|tolerance|fastest|802\.3|written from|acknowledged", re.I)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def expect_tests(path):
    """(name, body) of every expect test in a file."""
    # a test ends at its ";;" at the start of a line, so comments and helpers after it don't count
    return re.findall(r'let%expect_test "([^"]+)"(.*?)(?=^;;$|\Z)', read(path), re.S | re.M)


def tests_mentioning(path, name, bodies=False):
    """The expect tests in a file whose name or body mentions <name>.s."""
    found = [(t, b) for t, b in expect_tests(path) if re.search(rf"\b{re.escape(name)}\.s\b", t + b)]
    return found if bodies else [t for t, _ in found]


def fabric_configs(text):
    """The fabric configurations a piece of test code loads, by name."""
    return set(re.findall(r"(?:Bitstream|Fabric_post)\.([a-z0-9_]+) ~n_le", text))


CFG = r"(?:Pemu_post\.)?(?:Pemu\.)?(?:Bitstream|Fabric_post)\.([a-z0-9_]+) ~n_le"


def fabric_pairs(body):
    """(configuration, firmware) pairs a test runs together: in one Lockstep.create call; a
    firmware read from its file, then given a configuration; or, on the whole chip, a
    configuration and a program written to the same engine."""
    pairs = set(re.findall(r"Lockstep\.create\s*~fabric:\(" + CFG + r"[^;]*?\(load \"([a-z0-9_]+)\.s\"\)", body, re.S))
    bound = re.findall(r"let fabric = " + CFG, body)
    for f in re.findall(r"Lockstep\.create\s*~fabric\s[^;]*?\(load \"([a-z0-9_]+)\.s\"\)", body, re.S):
        pairs |= {(c, f) for c in bound}
    files = re.findall(r'read_all "\.\./firmware/([a-z0-9_]+)\.s"', body)
    for c in re.findall(r"Lockstep\.create\s*~fabric:\(" + CFG, body):
        pairs |= {(c, f) for f in files}
    cfg_engine = dict((e, c) for e, c in re.findall(r"config (\d) \(" + CFG, body))
    for e, f in re.findall(r'load \w+ (\d) \((?:asm|load) "([a-z0-9_]+)\.s"\)', body):
        if e in cfg_engine:
            pairs.add((cfg_engine[e], f))
    return pairs


def words(name):
    if os.path.exists(ASM):
        try:
            out = subprocess.run([ASM, os.path.join(FW, name + ".s")], capture_output=True,
                                 text=True, timeout=30).stdout
            n = len([l for l in out.split() if re.fullmatch(r"[0-9a-fA-F]{4}", l)])
            if n:
                return n
        except (OSError, subprocess.TimeoutExpired):
            pass
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--md")
    ap.add_argument("--json")
    a = ap.parse_args()
    cocotb = read(os.path.join(ROOT, "test", "test.py"))
    sigrok = read(os.path.join(ROOT, "scripts", "sigrok_check.py"))
    # plain keys, and keys made by an f-string loop such as f"spi_master_mode{m}"
    sig_keys = re.findall(r'^\s+"([a-z0-9_]+)":\s*\(', sigrok, re.M) + \
        re.findall(r'\*\*\{f"([a-z0-9_]+)\{', sigrok)
    # configurations with a SAT proof: test_bitstream_proof.ml is all proofs; elsewhere, tests
    # whose name says "proved"
    proved = set()
    for f in PROOF_TESTS:
        for t, b in expect_tests(os.path.join(ROOT, "hw", "test", f)):
            if f == "test_bitstream_proof.ml" or "proved" in t:
                proved |= fabric_configs(b)
    # programs that the Verilator harness puts in front of Linux software
    harness = "".join(read(p) for p in sorted(glob.glob(os.path.join(ROOT, "sim", "*.cpp"))))
    linux = set(re.findall(r"build/([a-z0-9_]+)\.hex", harness))
    rows = []
    for path in sorted(glob.glob(os.path.join(FW, "*.s"))):
        name = os.path.splitext(os.path.basename(path))[0]
        model = [t for f in MODEL_TESTS for t in tests_mentioning(os.path.join(ROOT, "hw", "test", f), name)]
        lock = [t for f in LOCKSTEP_TESTS for t in tests_mentioning(os.path.join(ROOT, "hw", "test", f), name)]
        pins = sorted(set(re.findall(r"async def (test_\w+)\(dut\):(?:(?!async def).)*?" + re.escape(name), cocotb, re.S)))
        sig = [k for k in sig_keys if k == name or k.startswith(name + "_") or (name == "uart" and k.startswith("uart"))
               or name in SIGROK_RECORDINGS.get(k, [])]
        used = set()
        for f in set(MODEL_TESTS + LOCKSTEP_TESTS):
            for _, b in tests_mentioning(os.path.join(ROOT, "hw", "test", f), name, bodies=True):
                used |= {c for c, fw in fabric_pairs(b) if fw == name}
        rows.append({
            "protocol": name,
            "category": "designed for" if name in DESIGNED_FOR else "after the freeze",
            "words": words(name),
            "model_tests": model,
            "lockstep_tests": lock,
            "pin_tests": pins,
            "sigrok_cases": sig,
            "spec_limit_tests": [t for t in model + lock if SPEC_WORDS.search(t)],
            "fabric": sorted(used),
            "fabric_proved": sorted(used & proved),
            "linux": name in linux,
        })
    if a.json:
        with open(a.json, "w") as f:
            json.dump(rows, f, indent=1)
    md = ["# Protocols and the evidence for each", "",
          "Generated by `scripts/site_data/evidence_table.py` from the tests in this repository.",
          "", "| Protocol | Category | Words | Model of the other end | RTL = model | Pins (cocotb, also gate-level in CI) | sigrok | Spec limits | Fabric configuration | Linux software |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    tick = lambda xs: f"yes ({len(xs)})" if xs else "-"
    fabric = lambda r: ", ".join(f"`{c}`" + (" (proved)" if c in r["fabric_proved"] else "")
                                 for c in r["fabric"]) or "-"
    for r in rows:
        md.append(f"| `{r['protocol']}` | {r['category']} | {r['words'] or '?'} | {tick(r['model_tests'])} | "
                  f"{tick(r['lockstep_tests'])} | {tick(r['pin_tests'])} | {tick(r['sigrok_cases'])} | "
                  f"{tick(r['spec_limit_tests'])} | {fabric(r)} | {'yes' if r['linux'] else '-'} |")
    md += ["", "The columns count tests (how many, in brackets):", "",
           "- Model of the other end: the firmware against a model of the device on the other end,",
           "  written from the protocol's specification (`hw/test`).",
           "- RTL = model: the engine RTL and the reference model compared every cycle while it runs.",
           "- Pins: cocotb tests that drive the chip only through its pins (`test/`).",
           "- sigrok: recordings of the RTL's pins read by a stock sigrok decoder (`scripts/sigrok_check.py`).",
           "- Spec limits: tests whose names say they check timing or tolerance limits from the specification.",
           "- Fabric configuration: the LUT fabric configuration the tests load with it; proved means a SAT",
           "  proof that it computes its rule for every state and input.",
           "- Linux software: run against unmodified Linux tools through the Verilator harness (`sim/`).",
           "",
           "Protocols written after the RTL freeze, with the predictions made before it: `docs/post-freeze/results.md`."]
    text = "\n".join(md) + "\n"
    if a.md:
        with open(a.md, "w") as f:
            f.write(text)
    print(text)


if __name__ == "__main__":
    main()
