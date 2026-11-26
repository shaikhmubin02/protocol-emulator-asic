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
  state and input;
- four of them also run through the chip's pins on the signed-off gate-level netlist, loaded
  over the host port as a board would load them (`test/test.py`, the `test_post_*` tests): CAN
  receive with its fabric configuration and CRC-15 settings, the JTAG TAP read by a controller,
  DMX512 transmit with its break and mark after break, and S/PDIF transmit with the biphase-mark
  configuration. They give the same results on the netlist as on the RTL.

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
| S/PDIF transmit | fits at 48 kHz, not at 96 kHz | works at 48 kHz: biphase-mark, a coding none of the designed-for configurations has, in a 3-element fabric configuration (proved), with the preambles sent in its raw mode; a whole 192-frame block read by a receiver written from IEC 60958: preambles, every sample, parity, the biphase rule, the channel status bytes; 48,007.7 frames a second from a 50 MHz clock. A limit outside the program: at 48 kHz it needs two words from the host every 520 cycles through a two-word inbox, which a host that reads the status before each write cannot keep up with over the SPI port (about 700 cycles a word); the pin-level test runs it 5 times slower for that reason. 96 kHz not tried yet | 76, plus the fabric configuration | agrees from the second subframe on (decoder limits below) |
| NEC infrared transmit and receive | fits; receive times long pulses with counted loops | works: the fabric makes the 38 kHz carrier (proved) and the program turns it on and off at exact times; frames, extended addresses and repeat codes 108 ms apart, read by a receiver model; the receiver reads remotes running 10% slow and 20% fast and reports a frame that breaks off | 62 and 73, plus the fabric configuration | agrees on the addresses and on the commands of the standard frames (decoder limit below) |
| Wiegand 26/34 | fits | works at 20 us pulses 200 us apart (the shortest the interface allows): 26-bit and 34-bit cards with their parity bits, and a receiver that ignores a 0.8 us glitch and takes messages of any length up to 48 bits | 77 and 48 | agrees |
| RC-5 infrared transmit and receive | fits, on half-bit ticks | works: the same carrier configuration at 36 kHz, Manchester bits on deadlines, the toggle bit kept across held keys, the RC-5X seventh command bit; the receiver finds each bit by the edge in its middle and reads remotes 10% slow and 10% fast, and reports a frame that breaks off | 64 and 56 | agrees, including the RC-5X command |
| PS/2 device (the chip as a keyboard) and PS/2 host | fits, on `uio` pins (open drain) | works at a 12.5 kHz clock: the keyboard sends scan codes, gives way when the computer holds the clock low and sends the cut-off byte again, clocks in the computer's commands and acknowledges them, and answers reset, read ID and echo; the host reads a keyboard model and sends it commands, checking each acknowledge | 177 and 116 | agrees on the keyboard's bytes (decoder limit below) |
| Modbus RTU server | fits with a few registers on the chip; CRC-16 in firmware | works at 115200 bit/s as the link layer, with the registers kept by the host: frames ended by 3.5 characters of silence, CRC-16, parity, server address and broadcasts, exception replies, and the RS-485 driver enable on exactly from a bit before the reply until its last stop bit | 179 | agrees on every frame's server ID and CRC and on the exception code |
| HDMI-CEC | fits | works: one program follows every frame and acknowledges the ones addressed to it, and sends for the host after 7 free bit periods, with broadcasts' reversed acknowledge, and arbitration (the device stops cleanly when a lower address starts on the same cycle); bit times on the line exactly 0.6, 1.5 and 3.7 ms. After losing arbitration it does not pick up the winner's frame | 186 | agrees on every byte |
| AX.25 / APRS at 1200 baud (HDLC on one engine, AFSK tones on another) | fits | works, on one chip: one engine frames APRS packets (the HDLC stuffing configuration with an NRZI element added, proved), a second makes the Bell 202 tones, and a third reads them back: it times the audio's edges, and the bit engine with a new configuration (NRZI decoding and de-stuffing in all 8 elements, proved) gives it the bits; frames checked by the FCS, and also read from the chip's audio by a model written from the AX.25 specification. Tested 100 times faster than real time | 50, 11 and 88, plus two fabric configurations | no stock decoder for the audio; checked by my AX.25 model |
| USB low speed HID keyboard (enumeration, then typing) | fits only with the host holding the descriptors | works, with a processor next to the chip holding the descriptors, as predicted: a host written from the USB 2.0 specification enumerates the chip the way Linux does (two bus resets, a 64-byte device descriptor read at address 0, SET_ADDRESS, the device, configuration, string and HID report descriptors, SET_CONFIGURATION, SET_IDLE, SET_REPORT for the keyboard LEDs) and then reads 8 key reports from endpoint 1. Engine 0 receives (NRZI and de-stuffing in a new fabric configuration, proved; the CRC-16 in the CRC unit; the address, endpoint and CRC-5 of a token checked with one 16-bit compare), engine 1 answers (the designed-for USB transmit configuration, now also proved, and the CRC unit sending the CRC-16), each answer 3.50 to 3.69 bit times after the host's packet (USB allows 2 to 6.5), every edge exactly on the bit grid, D+ and D- changing in the same cycle. NAK while the processor is still loading, ACK, STALL, DATA0/DATA1 kept, a packet whose ACK was lost sent again, a broken ACK and a SETUP with a bad CRC handled as the specification says, no answer to another address. The processor is modelled at the SPI port's real speed: it reads SETUP data straight out of engine 0's registers and loads engine 1 through its inbox. The whole chip ran in lockstep with the chip model, 613,000 cycles. The Linux kernel's own USB stack enumerates it too (through USB/IP and vhci_hcd, with the chip's RTL under Verilator, `sim/demo_usb.sh`): usbhid binds to it as a keyboard, and a program that turns its Caps Lock LED on through hidraw reads back what it types. Not run on real hardware yet | 253 and 190 (the receiver has 3 words left), plus the new fabric configuration | agrees on every handshake and data packet, the host's and the chip's |

No protocol from the planned list is left.

## Rates

CAN, HDLC, DMX512, MIDI, JTAG, SWD, S/PDIF, Wiegand, PS/2 and Modbus run at their real rates in
the tests. DALI, NEC, RC-5 and AX.25 run 100 times faster and LIN and HDMI-CEC 10 times
faster, to keep the cycle-by-cycle runs short; their recordings are written with the real
timing, so the decoders read them at the real rates (DALI at 1200 bit/s, LIN at 19200 bit/s,
NEC with its 38 kHz carrier, RC-5 at 1.778 ms a bit, CEC at 2.4 ms a bit). LIN also has a test
at the real 19200 bit/s. A faster test is the harder one for the firmware, since its fixed instruction
counts take a larger share of each bit. The USB keyboard runs at the real 1.5 Mbit/s from a
48 MHz clock; only the waits between transfers are shorter than a real host's (a 20 us bus reset
instead of 10 ms, which the device sees after 4 us; key polls 200 us apart instead of 10 ms).

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
- A uo pin reads back the engine's own output register, not another engine's: my first AX.25
  wiring had the tone engine read the framing engine's uo pin, which it cannot see. The line moved
  to a uio pad, and `docs/isa.md` now says so.
- My JTAG monitor's first output format could not be decoded: data words could have bit 15 set,
  the same bit that marks the end of a scan. Data words now carry 15 bits.
- USB: only engines 0 and 1 have a fabric and a CRC unit, which I had forgotten until I planned
  a third USB engine. The device is two engines.
- USB: the TX idle bit in BSTAT is already set right after the tick that sends the last bit,
  so my first ACK ended one bit early. Every packet now ends with a 1-bit word behind its last
  real one, which the program never shows: when the shifter takes it, the program knows the
  packet is over or that a stuffed bit still has to go out.
- USB: a handshake after a data packet went out with CRC bits instead of its PID, because the
  CRC unit's send mode was still on. Every packet now sets the CRC mode before it starts.
- USB: after a STALL, the next request's first IN still got the STALL. The processor clears it
  over the SPI port, which is slower than the host's next IN. A good SETUP now clears whatever
  endpoint 0 held, on the chip, as USB wants.
- USB, in my test models rather than the chip: my host started its next packet the cycle after
  the device's end of packet (USB wants 2 bit times of idle), and my board processor let a key
  report sit in the only transmit buffer while endpoint 0 needed it, which deadlocked.

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
- PS/2: the decoder ends a frame only at the next falling edge of the clock, so in a burst of
  bytes it takes the next byte's start bit for the end of the last one and reads one bit late
  from then on. In the recorded test the computer holds the clock low briefly after each byte,
  as hosts may, which gives the decoder that edge. It also takes every falling edge as a bit, so
  it cannot follow bytes from the host to the device; those are checked by my models.
- Modbus: the decoder does not decode function 0x2b, so it gives no CRC verdict for that
  request; the check leaves that one out.
