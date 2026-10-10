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
wait for each other. Programs that need exact timing keep a deadline in a register and wait for
the counter to reach it, so their timing doesn't depend on which way the code branched. Pins 0
to 14 (uio[7:0] and uo[6:0]) each have an owner: the host decides which engine drives which
pin. Every engine can read every input.

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

Each mailbox holds two words each way. Read the status word to see how many are waiting before
reading the outbox, and only write the inbox when it has room.

### Example firmware

All of these are in `hw/firmware` and assemble with the assembler in `hw/bin`. Times assume a
50 MHz clock; each file says which numbers to change for another clock.

| File | Protocol | Pins | Host words |
|---|---|---|---|
| `uart.s` | UART 8N1, full duplex | TX uo[0], RX ui[3] | byte to send; `0x8000 + n` sets the bit time to n cycles, `0x4000 + f` adds f/256. 115200 baud = 434 + 8/256 |
| `spi_master.s` | SPI controller, modes 0-3 | SCK uo[1], MOSI uo[2], CS uo[3], MISO ui[4] | `0x8000 + mode`; then byte, +0x100 to lower CS first, +0x200 to raise it after. Reply: byte read |
| `i2c_master.s` | I2C controller, 100 and 400 kHz, clock stretching | SCL uio[0], SDA uio[1] | `0x100` START, `0x2xx` write (reply 0 for ACK, 1 for NACK), `0x300` / `0x400` read with ACK / NACK, `0x500` STOP, `0x6xx` speed (100 = 100 kHz, 25 = 400 kHz) |
| `ws2812.s` | WS2812 LED chain | DIN uo[0] | 16 bits of colour per word, GRB, MSB first. The LEDs latch when the words stop |
| `onewire.s` | 1-Wire controller | DQ uio[2] | `0x100` reset (reply 0 if a device answered), `0x2xx` write, `0x300` read, `0x4xx` cycles per microsecond |

## How to test

1. Write a program into region 0 of an engine.
2. Give it the pins it needs (region 3, offsets 0-14). Do this before starting it: an engine's
   writes to pins it doesn't own are dropped, so a program that sets its idle levels first thing
   would lose them.
3. Set its run bit.
4. Talk to it through its mailbox.

For example, `uart.s` on engine 1 with uo[0] (pin 8) as TX and ui[3] as RX echoes everything back
when the two pins are wired together.

Some things to know:

- Hold rst_n low after power-up; the engines and the host port start from reset, not from
  whatever the flops came up as.
- When the design is deselected on the board it loses power and its programs. Load them again
  after selecting it.
- uo pins read 0 until their engine drives them. A UART on uo[0] therefore looks like a break
  until `uart.s` sets the line high; a device on the other end may see one junk byte.
- Several engines can run different protocols at the same time on different pins.

## External hardware

An SPI host, for example the RP2350 on the demo board. Then whatever the engines are programmed to
talk to, on a Pmod:

- I2C and 1-Wire need pull-up resistors (for example 4.7 k to 3.3 V) on their lines.
- WS2812 LEDs usually want 5 V power; their data input generally works from 3.3 V for short
  chains, otherwise add a level shifter.
- UART, SPI: direct connection at 3.3 V.
