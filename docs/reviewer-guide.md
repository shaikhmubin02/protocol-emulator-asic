# Reviewer guide

Each claim I make about the chip, what backs it, and the command that checks it. Everything runs
on Ubuntu 24.04 (I use WSL); `bash scripts/setup-wsl.sh` installs the tools. Commands are run
from the repository root unless they say otherwise.

## Timing

| Claim | Evidence | Command |
|---|---|---|
| Every instruction takes exactly the cycles the instruction set says, for any program, whatever the host, the pins and the other engines do | induction proof on the generated Verilog, program memory a free input (`formal/timing_props.sv`, properties 1 to 10) | `bash scripts/prove.sh` |
| A PIN write in cycle t is on the pad in cycle t+1 (unless the bit engine drives that pin) | engine proof (property 11) plus the chip proof that a pad is its owner's output register (`formal/chip_props.sv`) | `bash scripts/prove.sh` |
| A pin changes only when the program or the bit engine writes it | `timing_props.sv` property 12 | `bash scripts/prove.sh` |
| Every wait moves on in exactly the cycle after its condition holds, never earlier, or times out with T set | `timing_props.sv` property 13 | `bash scripts/prove.sh` |
| A SIG in one engine at cycle t is seen by every engine at t+1 | `chip_props.sv` | `bash scripts/prove.sh` |
| All engines see the same cycle counter, and it counts every cycle | `chip_props.sv` | `bash scripts/prove.sh` |
| None of the assertions above holds vacuously | 18 copies of the property files, each with one assertion broken on purpose; every copy must fail | `bash scripts/prove_teeth.sh` |

## Isolation and safety

| Claim | Evidence | Command |
|---|---|---|
| An engine never changes a pin it doesn't own; a stopped engine drives nothing | `formal/engine_props.sv` | `bash scripts/prove.sh` |
| A pin has at most one owner; a pin nobody owns is low and, on a uio pad, not driven | `formal/chip_props.sv` | `bash scripts/prove.sh` |
| The two-word mailboxes never overflow | `formal/engine_props.sv` | `bash scripts/prove.sh` |

## Debugging on the chip

| Claim | Evidence | Command |
|---|---|---|
| A breakpoint stops its engine and every engine joined to it in the same cycle, and they stay stopped until the host resumes them | `timing_props.sv` properties 14 to 16 plus the chip's breakpoint fan-out in `chip_props.sv` | `bash scripts/prove.sh` |
| Breakpoints, join, single steps and register writes work through the pins | cocotb test `test_debug_breakpoint_join_step` | `cd test && make` |

## The RTL matches the model

| Claim | Evidence | Command |
|---|---|---|
| The engine RTL equals the separately written cycle-accurate model every cycle | lockstep on random programs (with and without random debug commands) and on every firmware (`hw/test/test_lockstep.ml`) | `cd hw && dune build @runtest` |
| The whole chip equals the chip model at its pins every cycle | random programs on all four engines, random pin owners and host traffic over SPI (`hw/test/test_chip_lockstep.ml`) | `cd hw && dune build @runtest` |
| The ALU matches the instruction set for every input; each fabric configuration computes what it is meant to | SAT proofs (`hw/test/test_alu_proof.ml`, `hw/test/test_bitstream_proof.ml`) | `cd hw && dune build @runtest` |

## Protocols

| Claim | Evidence | Command |
|---|---|---|
| Each firmware in `hw/firmware` works against a model of the device on the other end, written from the protocol's specification | `hw/test/test_protocols.ml`, `test_targets.ml`, `test_ethernet.ml` | `cd hw && dune build @runtest` |
| Four protocols run at once on the four engines, driven only through the pins | cocotb test `test_four_protocols_at_once` (SPI, UART, I2C, 1-Wire against Python device models) | `cd test && make` |
| An outside decoder reads the RTL's pins the same way the tests do | the RTL's pads recorded as waveforms and decoded by the standard sigrok decoders: 26 of 26 fields agree (UART, SPI in all four modes and as a target, I2C master and target, 1-Wire, WS2812, USB TX and RX) | `bash scripts/sigrok_check.sh` (needs `sigrok-cli`) |

## After the freeze

| Claim | Evidence | Command |
|---|---|---|
| The signed-off gate netlist does what the RTL does | two checks against the netlist of the signing-off gds run: (1) formal, Yosys `equiv_*` with the configuration latches and SRAMs as the same black boxes on both sides: 7059 of 7203 matched points proven by induction, every register and output except the heads of the mailbox FIFOs (144 points, below); (2) simulation, the RTL and the netlist side by side under Verilator with the same random programs, host traffic over SPI (empty mailboxes read too), debugger commands and pin levels, every output compared every cycle: 16 seeds, 80 million cycles, equal throughout | `scripts/equiv/run.sh`, `scripts/equiv/lockstep/run.sh` (need the netlist from the gds run's artifact and the PDK cell models) |
| The hardware has not changed since the freeze tag `rtl-freeze-2026-11-26` | the hardware sources, the flow settings and the regenerated Verilog are compared with the tag | `bash scripts/check_freeze.sh` |
| The protocols in `docs/post-freeze/results.md` work on the frozen RTL, each against a model of the other end written from its specification, with the RTL in lockstep with the model every cycle | `hw/test/test_post.ml`, `hw/test/test_post2.ml`, `hw/test/test_usb.ml` (the USB keyboard: the whole chip, a host written from USB 2.0, and the board's processor at the SPI port's speed), models in `hw/test/*_node.ml` | `cd hw && dune build @runtest` |
| Each fabric configuration written after the freeze computes the rule it is meant to, for every state and input | SAT proofs with each protocol's tests (the designed-for USB transmit configuration, which had only been simulated, is now proved too, in `test_usb.ml`) | `cd hw && dune build @runtest` |
| Outside decoders read the post-freeze protocols as my tests do | 34 of 34 fields agree (60 of 60 with the designed-for protocols), including every handshake and data packet of the USB keyboard's enumeration; the decoder limits found on the way and how the check works around each are in `results.md` and `scripts/sigrok_check.py` | `bash scripts/sigrok_check.sh` (needs `sigrok-cli`) |
| Unmodified Linux software works with the chip's RTL | the whole chip under Verilator, driven through its pins: OpenOCD scans `jtag_tap.s` and finds IDCODE 0x1c0ffee1, then writes and reads its USER register; mbpoll reads holding registers of `modbus.s`, writes one, and reads it back; the Linux kernel enumerates the USB keyboard (`usb_dev_rx.s`, `usb_dev_tx.s`) through USB/IP and vhci_hcd, binds usbhid to it, turns its Caps Lock LED on and reads what it types through hidraw | `bash sim/demo_jtag.sh`, `bash sim/demo_modbus.sh` (need `verilator`, `openocd`, `mbpoll`), `sudo bash sim/demo_usb.sh` (needs vhci_hcd and USB HID in the kernel) |

## What is not covered here

- The formal check of the netlist leaves 144 points unproven: the heads of the inbox and outbox
  FIFOs of each engine and the host's read data, which plain induction does not close (deeper
  induction does not either). For those, the evidence is the lockstep simulation of the RTL and
  the netlist and the gate-level cocotb tests, not a proof.
- Nothing here has run on silicon or an FPGA. All evidence is simulation, gate-level
  simulation and proofs.
- The chip-level statements combine two proofs that meet at the engine ports: the engine proof
  and the proof of the chip around free engines. Neither is a single proof of the whole chip.
- Waits on the baud tick and on a capture edge are covered by the cycle-count proof (they never
  add a cycle) but their exact finish cycle is not, because their condition is inside the bit
  engine.
- The 1-Wire RTL lockstep test runs with time scaled down 10 times to keep it short; its
  waveform is written with the timestamps scaled back, so the decoder sees real timing. The same
  goes for DALI, NEC and RC-5 (100 times), and LIN and HDMI-CEC (10 times); LIN also has a test
  at its real rate. The other post-freeze protocols run at their real rates.
- The post-freeze protocols are checked against models I wrote from the specifications and,
  where one exists, a stock decoder; not against other implementations or real devices.
