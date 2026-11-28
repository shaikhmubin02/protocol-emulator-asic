# How I checked the chip

Nothing here has run on silicon or on an FPGA. Every claim below rests on simulation of the RTL,
simulation of the signed-off gate netlist, proofs on the generated Verilog, decoders written by
other people reading the chip's pins, and unmodified Linux software talking to the simulated chip.
I say "tested" for simulation, "proved" only together with what exactly is proved, and "shown" for
gate-level runs.

Each section has the same parts, in this order: the claim, why to believe it, and what it does not
cover, then the command that checks it and a way to make that command fail. All commands run on
Ubuntu 24.04 from the repository root; `bash scripts/setup-wsl.sh` installs the tools.

## 1. The RTL against a second, independent model, every cycle

**Claim.** The engine RTL does what a separately written cycle-accurate model of the instruction
set does, every cycle: for random programs, random debugger commands, every firmware in
`hw/firmware`, and the whole chip at its pins.

**Why to believe it.** The model (`hw/src/model.ml`) and the RTL are two different pieces of
code. The lockstep tests run both and compare the program counter, registers, flags, stack
pointer, mailbox counts, every word the host reads and every pin output after each cycle. The
chip-level version drives a test host over the SPI port, with random pin owners and random board
activity, against a separate model of the whole chip. One run of 300 random programs with random
debugger commands made 8,036 breakpoint hits, 2,327 stops caused by another engine and about
90,000 single steps, with no difference.

**A real bug it found.** On its first run it found an RTL bug: the pin read vector put the 15
outputs at positions 8 to 22, which pushed the input pins to 24 to 31. I had read that code many
times without seeing it.

**Why "no differences" can mean little.** My first bit-engine run showed no mismatches, and I did
not trust it. Coverage counts showed that random programs barely touched the bit engine. Later,
"driven pin-cycles" was 0 in 16 seeds. Both were holes in the stimulus, fixed with structured
programs, and the tests now print their coverage counts (for example, over 600,000 random cycles:
3,175 bits sent, 2,634 words received, 67,555 CRC steps) so that a quiet result can be judged.

**What it does not cover.** Two models can share a misreading of the manual: lockstep shows the
RTL equals the model, not that the model is right. Sections 4, 5 and 8 bring in other readings of
the specifications. Lockstep also covers only what the stimulus reaches, which is why section 9
exists.

**Command.** `cd hw && dune build @runtest`. **To make it fail:** change one operator in
`hw/src/engine.ml`; section 9 does this 497 times.

## 2. Proofs by induction on the generated Verilog

**Claim.** For any program, any host behaviour, any pin values and any behaviour of the other
engines:

- an engine never changes a pin it does not own, and a stopped engine drives nothing;
- the two-word mailboxes never overflow;
- every instruction takes exactly the cycles `docs/isa.md` section 2 says: 1 cycle for most,
  1 + n for a delay of n, and a wait moves on in the cycle after its condition holds;
- a PIN write in cycle t reaches the engine's output register in cycle t+1, unless the bit engine
  drives that pin;
- a breakpoint stops its engine and every engine joined to it in the same cycle;
- around the engines: a pad is its owner's output, a pin has at most one owner, all engines see
  one cycle counter, and a SIG in one engine at cycle t is seen by every engine at t+1.

**Why to believe it.** The proofs run on the Verilog that goes to the fab, not on the Hardcaml
source, with Yosys's SAT solver by induction. The program memory is a free input, so the proof
covers every program. The properties are in `formal/engine_props.sv`, `formal/timing_props.sv` and
`formal/chip_props.sv`. The chip statements combine two proofs that meet at the engine ports: the
engine proof, and the proof of the chip with the four engines replaced by outputs that can do
anything. Neither is one proof of the whole chip.

**Every assertion has a broken copy.** A proof that holds vacuously is worse than no proof.
`scripts/prove_teeth.sh` builds 18 copies of the property files, each with one assertion broken on
purpose (an expectation flipped, or a needed condition dropped). All 18 must fail to prove, and
they do. Separately, five timing bugs planted in the RTL (a host write that pauses a delay, a delay
one cycle too long, and so on) each make the timing proof fail.

**A real story.** The chip proof once failed with a counterexample whose printed values satisfied
every assertion. Both causes were in my script: `setundef -anyseq` ran before the ties and gave
harness wires a second, free driver, and `connect -set` first unsets its target, which left a net
undriven. Yosys `check` found it. The script now also checks that the only undriven nets left are
the 16 engine outputs.

**What it does not cover.** Waits on the baud tick and on a capture edge are proved never to add a
cycle, but their exact finish cycle is not, because their condition is inside the bit engine. The
statements are about time and pins, not about what a program computes.

**Command.** `bash scripts/prove.sh`, then `bash scripts/prove_teeth.sh`. **To make it fail:**
edit a Hardcaml operator, regenerate `src/pemu.v`, and run `prove.sh`.

## 3. SAT proofs of the ALU and of every fabric configuration

**Claim.** The ALU matches the instruction set for every input. Each of the 11 LUT fabric
configurations in use computes exactly the rule it is meant to compute, for every state and input.

**Why to believe it.** Each configuration is compared with the same rule written as plain logic
(`hw/test/test_bitstream_proof.ml` and each protocol's tests), using the same `Fabric_logic`
functor the RTL is built from. A single flipped LUT bit is caught.

**A real find.** While I wrote the USB keyboard I noticed that the USB transmit configuration
from before the freeze had only ever been simulated against a reference, although this repository
said it was proved. It is proved now, in `hw/test/test_usb.ml`.

**What it does not cover.** The proof says the configuration computes the rule, not that the rule
is the right line coding for the standard: sections 4 and 5 check that. It says nothing about the
bit engine's timing around the fabric.

**Command.** `cd hw && dune build @runtest`. **To make it fail:** flip one bit of a configuration in
`hw/post/fabric_post.ml` or `hw/src/bitstream.ml`.

## 4. Protocol tests against the other end, written from the specification

**Claim.** Each firmware in `hw/firmware` works against a model of the device on the other end,
written from the protocol's specification, not from my firmware.

**Why to believe it.** The models are in `hw/test/*_node.ml`, `test_protocols.ml`,
`test_targets.ml`, `test_ethernet.ml` and `usb_host.ml`: an I2C EEPROM that stretches the clock, a
wired-AND CAN bus with CRC-15 and stuffing, a USB host written from USB 2.0, checkers for the
timing limits of each standard. The firmware runs on the engine RTL in lockstep with the model
while this happens. Where two ends make sense, two engines run them against each other.

**Bugs it found.** The I2C master released SCL a quarter period early after a repeated START, low
for 2.2 us where the specification asks at least 4.7 us; my EEPROM model's clock stretching had
hidden it (fixed, 4 program words). A real RTL bug: every mailbox read frame popped one extra word,
because read data is fetched ahead at each word boundary, including after the last word. After the
freeze, the USB keyboard's first ACK came out one bit short, because the transmit-idle status is
already set after the tick that sends the last bit (fixed in firmware). What I got wrong on every
post-freeze protocol is in `docs/post-freeze/results.md`.

**What it does not cover.** These models are mine, from specifications I read. They are not other
implementations or real devices. Some tests run time scaled down to keep lockstep short (DALI, NEC
and RC-5 100 times, LIN, HDMI-CEC and 1-Wire 10 times); their recordings are written with the real
timing.

**Command.** `cd hw && dune build @runtest`. **To make it fail:** change a constant in a firmware
file, for example a baud rate.

## 5. Decoders I did not write

**Claim.** The stock sigrok decoders, written by other people, read the chip's pins the same way
my tests do: 60 of 60 recorded fields agree, 26 for the protocols the chip was designed for and 34
for those added after the freeze, including every handshake and data packet of the USB keyboard's
enumeration.

**Why to believe it.** The tests record the RTL's pads and write what they sent and saw.
`scripts/sigrok_check.py` decodes the recording and compares the fields. A decoder and my model are
independent readings of the specification.

**What it found.** My SPI test target changed MISO on the falling edge in every mode, which in
modes 1 and 2 is the sampling edge. The chip read 5a, sigrok read b4. The chip was right and my
target model was wrong. In the other direction, each time my model and the chip agreed and the
decoder did not, the specification settled it: six decoder limits, listed with the workaround for
each in `docs/post-freeze/results.md`.

**What it does not cover.** There is no stock decoder for HDLC, 10BASE-T or AX.25 audio. A
decoder agrees on fields, not on edge placement in cycles.

**Command.** `bash scripts/sigrok_check.sh` (needs `sigrok-cli`). **To make it fail:** change a
baud constant in a recorded firmware.

## 6. Through the pins, and on the gate-level netlist

**Claim.** The chip works when driven only through its pins, and the signed-off gate-level netlist
gives the same results as the RTL.

**Why to believe it.** The cocotb tests in `test/test.py` load programs over the SPI host port as
a board would: four protocols running at once against Python device models, the debugger's
same-cycle stop, and four protocols written after the freeze (CAN receive, the JTAG TAP, DMX512,
S/PDIF). All 10 pass on the RTL. On the netlist, the gate-level job of the signing-off gds run
passed the 6 that existed then, and the 4 post-freeze tests pass on the same netlist locally, with
the same results as on the RTL.

**What it does not cover.** The gate-level simulation has no delays, so it is not a timing check;
timing is signed off by static analysis in the flow. The tests are directed and few.

**Command.** `cd test && make`, and `make GATES=yes` with the netlist from the gds run. **To make
it fail:** change a program word a test loads.

## 7. The RTL against the netlist

**Claim.** The signed-off netlist (gds run 45669465134) does what the RTL does.

**Formal.** Yosys `equiv_*` proves 7,059 of 7,203 matched points by induction: every register and
output except the heads of each engine's inbox and outbox FIFOs and the host's read data (144
points). The configuration latches and the SRAMs are cut out as the same black boxes on both
sides, so this is equivalence of the logic around them.

**Simulation.** `scripts/equiv/lockstep` puts the RTL and the netlist in one Verilator model with
the same random programs, host traffic (empty mailboxes read too), debugger commands and pin
levels, and compares every output every cycle: 16 seeds, 80.1 million cycles, equal throughout.
The status words read back show the mailboxes full, empty and in between.

**The bugs were in my script.** The first pass left 2,271 points unproven. OpenROAD writes every
bus bit as its own net (`\engine0.pc[3]`) while the RTL has an 8-bit `engine0.pc`, and
`equiv_make` pairs by name and width, so only 1-bit signals had paired. Splitting the buses on both
sides fixed it.

**What it does not cover.** The 144 points are tested, not proved; deeper induction does not close
them. Equivalence is about function, not timing.

**Command.** `bash scripts/equiv/run.sh <netlist.v> <stdcell.v>` (13 minutes, 3 GB) and
`bash scripts/equiv/lockstep/run.sh <netlist.v> <stdcell.v>`. **To make it fail:** change one gate
in the netlist file.

## 8. Unmodified Linux software on the other end

**Claim.** Software I did not write works with the chip's RTL, driven only through its pins under
Verilator (`sim/`).

**Why to believe it.** OpenOCD, through its remote_bitbang driver, finds the TAP of `jtag_tap.s`
(IDCODE 0x1c0ffee1) and writes and reads its USER register. `mbpoll` reads, writes and reads back
holding registers of `modbus.s` through a pseudo-terminal. The Linux kernel's own USB stack
enumerates the chip as a keyboard through USB/IP and `vhci_hcd`: `lsusb` lists it, `usbhid` binds
to it, and a program turns Caps Lock on through hidraw and reads back "hello from the chip". In
that run, 197 answers came 3.50 to 3.56 bit times after the host's packet (USB allows 2 to 6.5).

**A real find.** The first time, all the key reports went to the kernel's console and none to my
program, because the console keyboard handler opens the device at once. The board now starts
typing when the host turns Caps Lock on, which makes the demo work in both directions.

**What it does not cover.** The chip is a simulation, not hardware, and the USB keyboard needs a
processor next to the chip that holds the descriptors (modelled at the SPI port's real speed).

**Command.** `bash sim/demo_jtag.sh`, `bash sim/demo_modbus.sh`, `sudo bash sim/demo_usb.sh`.
**To make it fail:** change the IDCODE words `sim/main.cpp` hands the TAP, and OpenOCD reports
an unexpected IDCODE.

## 9. Testing the tests: mutation

**Claim.** If I break the RTL in one small way, a test notices. I measured that.

**How.** `scripts/mutate.py` makes every one-operator or one-constant change to `hw/src/engine.ml`
and `hw/src/chip.ml` it can: 497 mutants. Each is built in a private copy and run against the
lockstep tests, then the proofs. A survivor is either harmless or a gap in the tests.

**Result** (`docs/mutation.md` has every survivor): 477 caught at once (476 by the lockstep tests,
1 by the proofs). Of the 20 that survived, 9 showed real gaps, each now closed by a new test that
catches it, and 11 change nothing a program or the host can see, each argued. The gaps were good
ones. Random programs never ran long enough for the cycle counter's high half to change, so four
ways of breaking TIME_HI went unnoticed. No test pushed into a mailbox in the same cycle the other
side popped it (the new test finds 856 such cycles). The datasheet promised that a write to a full
inbox is dropped, and nothing had ever tried it.

**The time my runner was wrong.** I once had "66 of 66 killed". It was not true: the test runner
can leave a `.corrected` file identical to the source when every test passes, and my script counted
the file's existence as a kill. Mutants in `chip.ml` "killed" by a test that cannot see `chip.ml`
gave it away. The runner now compares contents, `--baseline` checks that the unmutated source
passes, and "did not compile" is reported apart from "not caught".

**What it does not cover.** Mutants are single small changes in two files. They do not model a
wrong idea shared by the RTL and the model, or errors in firmware. "Harmless" is my argument, not a
proof.

**Command.** `python3 scripts/mutate.py run --sample 20` (about 70 s a mutant; all 497 take about
7 hours). **To make it fail:** weaken a test, and the mutants it caught survive.

## The layers on one page

| Layer | Catches | Misses | Command |
|---|---|---|---|
| 1. Lockstep, RTL vs model | any cycle where RTL and model differ | a misreading both share; what the stimulus does not reach | `cd hw && dune build @runtest` |
| 2. Induction proofs, with broken copies | pin ownership, mailbox bounds, cycle counts for any program, same-cycle stop | exact finish of baud and capture waits | `bash scripts/prove.sh` |
| 3. SAT proofs | the ALU and each fabric configuration against its rule | whether the rule is the right line coding | `cd hw && dune build @runtest` |
| 4. Models of the other end | firmware errors at the pins, timing limits | my own misreading of a specification | `cd hw && dune build @runtest` |
| 5. sigrok decoders | disagreement with an outside reading (60 of 60 agree) | edge placement; protocols with no decoder | `bash scripts/sigrok_check.sh` |
| 6. cocotb, RTL and netlist | host port and pins, the netlist | timing (no delays) | `cd test && make` |
| 7. RTL vs netlist | a netlist that differs: 7,059 of 7,203 points proved, 80.1 million cycles equal | the 144 FIFO head points are tested, not proved | `bash scripts/equiv/run.sh` |
| 8. Linux software | protocols as real software uses them | hardware, real pads and hosts | `sudo bash sim/demo_usb.sh` |
| 9. Mutation | gaps in layers 1 to 3 (497: 9 found and closed, 11 argued, 0 open) | wrong ideas; firmware errors | `python3 scripts/mutate.py run` |

## What none of this covers

- Silicon. Pad delays, the SRAM's analog behaviour, clock quality and the 3.3 V board are not
  simulated here.
- Timing closure: it comes from the flow's static timing analysis.
- A misreading of a specification shared by my model, my tests and me. The decoders and the Linux
  software are my defence, and they cover some protocols, not all.
- The 144 FIFO head points of the netlist check: tested, not proved.

The hardware has not changed since the freeze tag `rtl-freeze-2026-11-26`;
`bash scripts/check_freeze.sh` compares the sources, the flow settings and the regenerated Verilog
with the tag.
