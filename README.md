![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg)

# protocol-emulator-asic

A programmable protocol chip for Tiny Tapeout (IHP 130nm CMOS5L). It has four small engines,
each a processor whose instructions read and write pins and count cycles, so protocols like
UART, SPI and I2C are done in software instead of fixed hardware. The engines can run different
protocols at the same time, and the host loads them over SPI.

This is my entry for the Jane Street protocol emulator ASIC competition. The datasheet with the
address map and the firmware list is in [docs/info.md](docs/info.md).

## What runs on it so far

Firmware in `hw/firmware`, each one tested against a model of the device on the other end:

- UART, 8N1 full duplex, any baud rate (tested at 9600 and 115200)
- SPI controller, all four modes
- I2C controller at 100 and 400 kHz with clock stretching, checked against the timing table in
  the I2C spec
- WS2812 LED chains
- 1-Wire, including reading a device's ROM ID

USB low speed and 10BASE-T are next; engines 0 and 1 have a small LUT fabric and a CRC unit for
the bit-level coding those need.

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

The cocotb tests:

    source ~/.venvs/asic/bin/activate
    cd test
    make

Started from the Tiny Tapeout [ttihp-verilog-template](https://github.com/TinyTapeout/ttihp-verilog-template/tree/cmos5l).

## License

Apache 2.0, see [LICENSE](LICENSE).
