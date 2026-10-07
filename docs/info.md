<!---
This file is used to generate your project datasheet.
-->

## How it works

The chip has four small engines. Each one is a processor built for talking to pins: every
instruction takes a known number of clock cycles, so a program can produce or check a waveform
down to the exact cycle. Each engine has its own 256-word program memory, eight 16-bit registers
and a bit engine (baud generator, TX and RX shifters).

Engines 0 and 1 also have an 8-element LUT fabric for bit-level coding such as bit stuffing or
NRZI, and a CRC unit up to 32 bits. Those are for protocols like USB and Ethernet. Engines 2 and 3
leave them out to save area; UART, SPI, I2C, JTAG and the like run on any engine.

The engines share a 32-bit cycle counter and eight event flags, so they can start together or
wait for each other. Pins 0 to 14 (uio[7:0] and uo[6:0]) each have an owner: the host decides
which engine drives which pin. Every engine can read every input.

Everything is loaded and controlled over an SPI port on ui[0..2] and uo[7] (mode 0, SCK up to
clk/8). A frame is a command byte, a 16-bit address, then 16-bit words, MSB first, with the
address going up by one per word:

- `0x02` write: words follow the address.
- `0x03` read: one dummy byte, then words.

Address bits [15:14] pick the engine and [13:12] the region:

| Region | Offset | What |
|---|---|---|
| 0 | 0x00-0xff | program memory (while the engine is stopped) |
| 1 | 2 x word + half | fabric and CRC configuration, engines 0 and 1: low half, then high half |
| 2 | 0x00 | status: [7:0] pc, [8] halted, [9] running, [11:10] inbox, [13:12] outbox, [14] bit engine on |
| 2 | 0x10-0x17 | registers r0-r7 |
| 2 | 0x80-0xff | mailbox: write to the inbox, read from the outbox |
| 3 | 0x00-0x0e | pin owner: [1:0] engine, [2] enable |
| 3 | 0x10 | run, one bit per engine |
| 3 | 0x11 | event flags |
| 3 | 0x12, 0x13 | cycle counter low and high |
| 3 | 0x20 | chip id, reads 0x5045 |

## How to test

1. Write a program into region 0 of an engine.
2. Give it the pins it needs (region 3, offsets 0-14).
3. Set its run bit.
4. Talk to it through its mailbox.

For example, the UART firmware on engine 1 with uo[0] (pin 8) as TX and ui[3] as RX echoes
everything back when the two pins are wired together. Read the status word to see how many
words are waiting before reading the mailbox.

## External hardware

An SPI host, for example the RP2350 on the demo board. Whatever the engines are programmed to
talk to goes on the other pins.
