![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg)

# emulator-asic

A small programmable protocol engine for Tiny Tapeout (IHP 130nm CMOS5L). The idea is a tiny
CPU whose instructions read and write pins and count cycles, so protocols like UART, SPI and
I2C can be done in software instead of fixed hardware.

This is my entry for the Jane Street protocol emulator ASIC competition.

Work in progress, nothing interesting in `src/` yet.

## Layout

- `src/` - Verilog for the design
- `test/` - cocotb tests
- `docs/info.md` - Tiny Tapeout datasheet page
- `scripts/` - setup scripts

## Running the tests

I develop on WSL (Ubuntu 24.04). To install the tools:

    bash scripts/setup-wsl.sh

Then:

    source ~/.venvs/asic/bin/activate
    cd test
    make

Started from the Tiny Tapeout [ttihp-verilog-template](https://github.com/TinyTapeout/ttihp-verilog-template/tree/cmos5l).

## License

Apache 2.0, see [LICENSE](LICENSE).
