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
50 MHz clock unless the row says otherwise; each file says which numbers to change for another clock.

| File | Protocol | Pins | Host words |
|---|---|---|---|
| `uart.s` | UART 8N1, full duplex | TX uo[0], RX ui[3] | byte to send; `0x8000 + n` sets the bit time to n cycles, `0x4000 + f` adds f/256. 115200 baud = 434 + 8/256 |
| `spi_master.s` | SPI controller, modes 0-3 | SCK uo[1], MOSI uo[2], CS uo[3], MISO ui[4] | `0x8000 + mode`; then byte, +0x100 to lower CS first, +0x200 to raise it after. Reply: byte read |
| `i2c_master.s` | I2C controller, 100 and 400 kHz, clock stretching | SCL uio[0], SDA uio[1] | `0x100` START, `0x2xx` write (reply 0 for ACK, 1 for NACK), `0x300` / `0x400` read with ACK / NACK, `0x500` STOP, `0x6xx` speed (100 = 100 kHz, 25 = 400 kHz) |
| `spi_target.s` | SPI target, modes 0-3, SCK up to 1.6 MHz | SCK ui[5], MOSI ui[6], CS ui[7], MISO uio[0] (driven only while CS is low) | `0x8000 + mode` between transactions; other words: next byte to send (0xFF if none). Replies: each byte received, `0x100` when CS goes high. CS has to go low 400 ns before the first edge in modes 0 and 2 |
| `i2c_target.s` | I2C target, 100 and 400 kHz | SCL uio[0], SDA uio[1] | first word: the 7-bit address. Replies: `0x1aa` START for us (aa = address byte, bit 0 = read), `0x2dd` byte written, `0x300` STOP. For a read, one word per byte to send. It stretches SCL while it waits for the host, so a slow host slows the bus instead of losing data |
| `ws2812.s` | WS2812 LED chain | DIN uo[0] | 16 bits of colour per word, GRB, MSB first. The LEDs latch when the words stop |
| `onewire.s` | 1-Wire controller | DQ uio[2] | `0x100` reset (reply 0 if a device answered), `0x2xx` write, `0x300` read, `0x4xx` cycles per microsecond |
| `usb_tx.s` | USB low speed, sending packets (48 MHz clock) | D+ uio[4], D- uio[5] | `0x1pp` SYNC and PID, `0x2dd` data byte, `0x3dd` byte outside the CRC, `0x400` CRC-16 and end of packet, `0x500` end of packet. SYNC, NRZI, bit stuffing, CRC-16 and EOP are done on the chip |
| `usb_rx.s` | USB low speed, receiving packets (48 MHz clock) | D+ uio[4], D- uio[5] | replies: each byte, with bit 8 set once the CRC-16 checks out; `0x8000` at the end of each packet. Clock recovery, NRZI, unstuffing, SE0 and the CRC check are done on the chip |
| `eth_tx.s` | 10BASE-T, sending frames | TD uo[0] | any word sends the frame once. The frame is part of the program (the SPI port is slower than the line), see below. Manchester coding, preamble, FCS, TP_IDL and link pulses are done on the chip |
| `eth_rx.s` | 10BASE-T, receiving frames | RD ui[3]; out: RXD uo[4:1], DV uo[5], strobe uo[6] | reply after each frame: [14:0] bytes including the FCS, [15] set if the FCS is right. The bytes go out on the 4-bit bus as they arrive, low nibble first, each nibble good on the rising edge of the strobe |


### 10BASE-T

At 10 Mbit/s a frame is faster than the SPI port, so neither direction goes through the mailbox.

`eth_tx.s` keeps the frame in program memory, as code at the label `frame`: `ldi r0, a`,
`ldih r0, b`, `tx r0` for each pair of bytes, `wait event tx_empty`, `csrw txcfg, r5`,
`ldi r0, a`, `tx r0` for an odd last byte, then `ret`. The bytes start at the destination address;
the preamble and FCS are added by the program. That fits frames up to about 126 bytes. To change
the frame, stop the engine and write the new code. While idle it sends a link pulse every
15.7 ms, which a link partner needs before it accepts frames. Load the fabric with the `eth_tx`
bitstream and the CRC with polynomial 0x04C11DB7, init 0x13256D64 (all ones, worked back over
the preamble, which also goes through the CRC).

`eth_rx.s` decodes the Manchester code in the fabric (the `eth_rx` bitstream): it takes the
mid-bit edges, skips the ones at bit boundaries, finds the SFD and only lets the frame through,
so the RX words are already bytes. Load the CRC with polynomial 0x04C11DB7, init 0xFFFFFFFF.
Frames of any length work, since nothing is stored on the chip.

Both bitstreams are generated by `hw/src/bitstream.ml`. Measured in simulation at 50 MHz: TX zero
crossings are at most 10 ns off the ideal grid (802.3 allows 20 ns). RX takes +-100 ppm and
decodes every frame with up to 4 ns of jitter on each zero crossing, 28 of 30 at 6 ns, and none
at the 13.5 ns 802.3 asks for, because sampling every 20 ns leaves little room between a
bit-boundary edge (50 ns) and a mid-bit one (100 ns). How much jitter a real link has depends on
the cable and the line receiver; I haven't measured one yet. A faster clock would help.

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
- USB low speed: series resistors on D+ and D- and a 1.5 k pull-up on D- (for a device), as for any
  3.3 V USB implementation.
- 10BASE-T, sending: TD through a series capacitor and resistor into a 10BASE-T transformer
  (MagJack). The line idles low, so the capacitor leaves 0 V across the pair when idle. I haven't
  tried this on hardware yet; one pad may not give the full 802.3 amplitude.
- 10BASE-T, receiving: the pair through a transformer into a line receiver or comparator with a
  little hysteresis, whose output goes to ui[3].
