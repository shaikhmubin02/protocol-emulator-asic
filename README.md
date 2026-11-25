![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg)

# protocol-emulator-asic

A programmable protocol chip for Tiny Tapeout (IHP 130nm CMOS5L). It has four small engines,
each a processor whose instructions read and write pins and count cycles, so protocols like
UART, SPI and I2C are done in software instead of fixed hardware. The engines can run different
protocols at the same time, and the host loads them over SPI.

This is my entry for the Jane Street protocol emulator ASIC competition. The datasheet with the
address map and the firmware list is in [docs/info.md](docs/info.md), and the instruction set
is in [docs/isa.md](docs/isa.md). [docs/reviewer-guide.md](docs/reviewer-guide.md) lists every claim
with the command that checks it.

The RTL was frozen on 2026-11-26 (git tag `rtl-freeze-2026-11-26`). Everything added after
that is firmware and configuration on the same hardware. Before the freeze I published the list
of protocols I planned to try next, with a prediction for each, and the rule for a random draw
of protocols I did not plan: [docs/post-freeze/pool.md](docs/post-freeze/pool.md).

## What runs on it so far

Firmware in `hw/firmware`, each one tested against a model of the device on the other end:

- UART, 8N1 full duplex, any baud rate (tested at 9600 and 115200)
- SPI controller and SPI target, all four modes
- I2C controller and I2C target at 100 and 400 kHz with clock stretching, checked against the
  timing table in the I2C spec
- WS2812 LED chains
- 1-Wire, including reading a device's ROM ID
- USB low speed: sending and receiving packets, with the line coding, clock recovery and CRC-16
  done on the chip (tested at the 1.5% clock error the spec allows)
- 10BASE-T: sending frames (Manchester, FCS, TP_IDL and link pulses on the chip) and receiving
  them onto a 4-bit bus with the FCS checked. RX jitter tolerance is below what 802.3 asks for at
  50 MHz; the datasheet has the numbers

Each engine also has a small LUT fabric and a CRC unit for bit-level coding; USB and 10BASE-T
use them, and any engine can run them.

Engines can be debugged on the chip over the host port: breakpoints, single cycle steps, and
reading or changing registers while stopped. A breakpoint on one engine can stop the others in
the same clock cycle, so the whole chip can be inspected at one moment of a protocol exchange.

## How it's checked

The design is written in [Hardcaml](https://github.com/janestreet/hardcaml) (`hw/`), which
generates the Verilog in `src/`. Next to it is a cycle-accurate model of an engine written
separately in OCaml, and most of the testing compares the two:

- Lockstep: the RTL and the model run side by side and are compared every cycle, on hundreds of
  random programs and on the real firmware. The same is done for the whole chip at its pins,
  with a separate model of the chip, while a test host drives the SPI port.
- Mutation testing: I break the RTL on purpose in a few ways and check that the tests notice.
- Proofs with a SAT solver: the ALU against the instruction set for every input, and the LUT
  fabric configurations against what they are meant to compute.
- Induction proofs on the generated Verilog (`formal/`, `scripts/prove.sh`): for any program,
  an engine never changes a pin it doesn't own, a stopped engine drives nothing, and the
  mailboxes never overflow.
- A timing proof on the same Verilog (`formal/timing_props.sv`): every instruction takes
  exactly the cycles the instruction set says, whatever the host, the pins and the other engines
  do. One cycle for most instructions, 1 + n for a delay of n, and a wait moves on in the cycle
  after it sees its pin. Apart from the debugger, nothing outside an engine can stall it, so a program's timing can be
  worked out from the program alone. Five timing bugs planted on purpose (a host write that
  pauses a delay, a delay one cycle too long, and so on) each make the proof fail.
  The same proof also covers: a PIN write reaches the engine's output register exactly one cycle
  later (unless the bit engine is driving that pin), a pin changes only when the program or the
  bit engine writes it, every kind of wait moves on exactly in the cycle after its condition
  holds (or times out, which sets T), and a breakpoint stops its engine and every engine joined
  to it in the same cycle.
- A proof of the chip around the engines (`formal/chip_props.sv`), with each engine replaced by
  outputs that can do anything: a pad is its owner's output register with nothing in between,
  a pin has at most one owner, a breakpoint reaches the other engines in the same cycle, every
  engine sees the same cycle counter, and a SIG in one engine is seen by all of them one cycle
  later. Put together with the engine proof: a PIN write at cycle t is on the pad at t+1.
  Each assertion also has a planted break that must make it fail, so none of them holds
  vacuously.
- An outside check: the protocol tests can record the RTL's pins as waveforms, and
  `scripts/sigrok_check.sh` decodes them with the standard sigrok protocol decoders (UART, SPI,
  I2C, 1-Wire, WS2812, USB). All 26 decoded fields agree with what the tests sent and received.
- cocotb tests in `test/` that drive the chip only through its pins, as the board will.

## Layout

- `hw/` - Hardcaml source, the engine model, the assembler, firmware and tests
- `src/` - generated Verilog, plus the LibreLane config
- `test/` - cocotb tests
- `formal/` - property wrappers for the induction proofs
- `docs/info.md` - Tiny Tapeout datasheet page
- `scripts/` - setup and helper scripts

## Running the tests

I develop on WSL (Ubuntu 24.04). To install the tools:

    bash scripts/setup-wsl.sh

The Hardcaml tests (lockstep, protocols, SAT proofs):

    cd hw
    dune build @runtest

The induction proofs:

    bash scripts/prove.sh

The sigrok check (needs `sigrok-cli`):

    bash scripts/sigrok_check.sh

The cocotb tests:

    source ~/.venvs/asic/bin/activate
    cd test
    make

Started from the Tiny Tapeout [ttihp-verilog-template](https://github.com/TinyTapeout/ttihp-verilog-template/tree/cmos5l).

## License

Apache 2.0, see [LICENSE](LICENSE).
