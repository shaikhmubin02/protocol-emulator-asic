# Protocols after the RTL freeze: results

Every protocol from the pool (`pool.md`) that I have attempted so far, with the prediction I
wrote before the freeze next to what happened. The hardware is the frozen RTL (tag
`rtl-freeze-2026-11-26`); everything here is firmware in `hw/firmware` and, where noted, a LUT
fabric configuration in `hw/post`. I keep this page up to date as I go, failures included.

How each one is checked:
- the firmware runs on the engine RTL in lockstep with the reference model, cycle by cycle
  (`hw/test/test_post.ml`), against a model of the other end that I wrote from the protocol's
  specification (`hw/test/*_node.ml`);
- where the pair makes sense, two engines run the two ends against each other;
- where a stock sigrok decoder exists, the recorded pins are decoded by it and compared with
  what the test itself sent and received (`scripts/sigrok_check.py`);
- fabric configurations are proved equal to the rule they implement with a SAT solver, for every
  state and input.

| Protocol | Prediction | Result | Program words | Outside decoder |
|---|---|---|---|---|
| CAN 2.0A receive with ACK | fits | works: 8 frames, including 16 stuff bits in one frame, a remote frame, and a frame with a flipped bit that is not acknowledged | 99, plus a 7-element fabric configuration that removes stuff bits (proved) | agrees, after working around a decoder limit (below) |
| CAN 2.0 transmit | fits at 500 kbit/s; 1 Mbit/s is tight | works at 500 kbit/s: frames acknowledged, arbitration lost to a lower ID and retried, no acknowledgement reported; every edge exactly on the 100-cycle bit grid. 1 Mbit/s not tried yet | 172 | agrees |
| HDLC transmit and receive with FCS-16 | fits, one engine per direction | works at 250 kbit/s: zero insertion and removal in the fabric, the FCS from the CRC unit, frames with bad FCS reported | 45 and 51, plus two fabric configurations (proved) | no stock decoder; checked against RFC 1662 models both ways and engine to engine |
| DALI | fits | works: 8 transactions against IEC 62386 control gear, the 10BASE-T Manchester configuration reused unchanged for sending; receiving is in firmware (the 10BASE-T receive configuration does not fit DALI) | 69 | agrees |
| MIDI in and out | fits | works: running status both ways, real-time bytes between the data bytes of another message | 44 and 73 | agrees |
| DMX512 transmit and receive | fits | works: the break and the mark after break come from the bit engine's idle level, so every edge of a packet is on the 4 us bit clock (0 cycles off, measured); the receiver works as a fixture with a start address and a footprint, and reports other start codes, short packets, framing errors, and a break or MAB that is too short | 40 and 95 | agrees on the first packet of each recording (decoder limits below) |
| LIN 2.x | fits, but the transceiver does the open drain | works: the commander sends headers and responses with both checksums and reads every byte back; the responder times the sync byte and sets its bit time to 1/256 of a cycle, and keeps up with commanders 12% fast and 12% slow | 158 and 192 | agrees, including the responder's replies read at the slow commander's own rate |
| JTAG controller, TAP target and passive monitor | fits; the target up to about 1.6 MHz TCK | works: the controller reads both IDCODEs of a two-TAP chain and finds the chain length from BYPASS; the TAP is found and used by a controller written from IEEE 1149.1 and is right up to 3.57 MHz TCK (wrong at 4.17 MHz); the monitor on a third engine reports every scan | 43, 131 and 76 | agrees on every IR and DR scan |
| SWD host | fits | works: the JTAG-to-SWD switch, DPIDR, the debug power-up handshake, the AP's IDR through a posted read and RDBUFF, memory writes and reads with auto-increment, a request with a wrong parity bit left unanswered, recovery by line reset; the two sides never drive SWDIO at once | 157 | agrees on every ACK and data word |
| S/PDIF transmit | fits at 48 kHz, not at 96 kHz | works at 48 kHz: biphase-mark, a coding none of the designed-for configurations has, in a 3-element fabric configuration (proved), with the preambles sent in its raw mode; a whole 192-frame block read by a receiver written from IEC 60958: preambles, every sample, parity, the biphase rule, the channel status bytes; 48,007.7 frames a second from a 50 MHz clock. 96 kHz not tried yet | 76, plus the fabric configuration | agrees from the second subframe on (decoder limits below) |
| NEC infrared transmit and receive | fits; receive times long pulses with counted loops | works: the fabric makes the 38 kHz carrier (proved) and the program turns it on and off at exact times; frames, extended addresses and repeat codes 108 ms apart, read by a receiver model; the receiver reads remotes running 10% slow and 20% fast and reports a frame that breaks off | 62 and 73, plus the fabric configuration | agrees on the addresses and on the commands of the standard frames (decoder limit below) |
| Wiegand 26/34 | fits | works at 20 us pulses 200 us apart (the shortest the interface allows): 26-bit and 34-bit cards with their parity bits, and a receiver that ignores a 0.8 us glitch and takes messages of any length up to 48 bits | 77 and 48 | agrees |

Not attempted yet from the planned list: AX.25/APRS, RC-5, PS/2 device and host, HDMI-CEC,
Modbus RTU, USB low speed HID enumeration.

## Rates

CAN, HDLC, DMX512, MIDI, JTAG, SWD, S/PDIF and Wiegand run at their real rates in the tests. DALI and NEC
run 100 times faster and LIN 10 times faster, to keep the cycle-by-cycle runs short; their
recordings are written with the real timing, so the decoders read them at the real rates (DALI
at 1200 bit/s, LIN at 19200 bit/s, NEC with its 38 kHz carrier). LIN also has a test at the
real 19200 bit/s. A faster test is the harder one for the firmware, since its fixed
instruction counts take a larger share of each bit.

## What I got wrong, and what the tests found

- The bit engine's TX pin is pin 0 with idle level 0 after reset, so a program that only
  receives but turns the bit engine on holds pin 0 low. That jammed the CAN bus in my first
  receive test. A receive-only program now points TX at pin 31. This is in `docs/isa.md`.
- With MSB-first sending, the bit engine picks each bit using the word length in TXCFG at that
  moment, not the length the word was loaded with. DALI changes the length between the start bit
  and the frame, so it sends LSB first with the frame reversed in firmware. Also in `docs/isa.md`.
- My first CAN transmit put the first deadline too close: every edge came out 4 cycles late.
- `BEN 1` empties the TX holding register. Two programs handed the bit engine their first word
  before `BEN 1`: the S/PDIF stream started without its first preamble, and the infrared carrier
  never started. The word now comes after `BEN 1`, and `docs/isa.md` says so.
- My JTAG monitor's first output format could not be decoded: data words could have bit 15 set,
  the same bit that marks the end of a scan. Data words now carry 15 bits.

## Decoder limits found on the way

Each of these showed up because my model of the other end and the chip agreed and the decoder
did not; the specification settled it each time. The check works around each one and says so in
`scripts/sigrok_check.py`.

- CAN: the decoder takes the data length from the DLC even in a remote frame, which has no data
  field, and loses its place for the frames after it.
- DMX512: the decoder only looks for a new break after channel 512, so after a shorter packet it
  reads the next break as a slot; it takes the line's polarity from the first long run; and with
  slots back to back (allowed by the standard) it takes the next start bit for the mark between
  slots. The recorded DMX tests put a 4 us mark between slots; back to back is checked against
  my E1.11 model.
- NEC: the decoder checks the address byte against its inverse, so a frame with an extended
  (16-bit) address, which the format allows, comes out as an address error and its command is
  not decoded. The check compares that frame's address only.
- S/PDIF: the decoder learns the clock from the first three pulse widths it sees, and counts
  the idle line before the stream's first edge as one of them; a real capture starts in the
  middle of a stream, so the check starts the recording at its first edge. Learning the clock
  uses up the first preamble, so its first sample is the second subframe's.
