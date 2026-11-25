# Protocols after the RTL freeze: the pool, the predictions and the draw

I wrote this page before tagging the RTL freeze, so its git history shows what I expected before
any of it was tried. After the freeze the hardware does not change: every protocol below is
firmware and configuration only, on the chip as it was taped out.

Each protocol gets the same treatment as the ones I designed the chip around: firmware, a model
of the device on the other end written from the protocol's specification, a test that runs the
RTL against that model, and, where one exists, a decoder written by someone else reading the
pins. The results page will report every protocol in this pool that I attempt, including the
ones that do not fit, with what was missing.

## What the chip was designed for

UART, SPI controller and target, I2C controller and target, WS2812, 1-Wire, USB low speed (TX
and RX), 10BASE-T (TX and RX). Those were written before the freeze.

## Planned (I picked these)

| Protocol | Prediction |
|---|---|
| CAN 2.0A/B receive with ACK (fabric removes stuff bits, CRC unit checks CRC-15) | fits |
| CAN 2.0 transmit (stuffing in firmware, arbitration by reading the bus back) | fits at 500 kbit/s; 1 Mbit/s is tight |
| HDLC/SDLC transmit and receive with FCS-16 (fabric inserts and removes the zero after five ones) | fits, one engine per direction |
| AX.25 / APRS at 1200 baud (HDLC on one engine, AFSK tones on another) | fits |
| DALI forward and backward frames (Manchester through the fabric, the 10BASE-T configurations reused) | fits |
| S/PDIF transmit (biphase-mark, a coding none of the existing configurations has, done in the fabric) | fits at 48 kHz, not at 96 kHz |
| MIDI in and out | fits |
| DMX512 transmit and receive | fits; a universe of only a few slots lives on the chip, more come from the host |
| NEC infrared transmit and receive | fits; receive times long pulses with counted loops |
| RC-5 infrared | fits, on half-bit ticks |
| PS/2 device (the chip as a keyboard) and PS/2 host | fits, on `uio` pins (open drain) |
| SWD host (read a part's DPIDR) | fits |
| JTAG controller, TAP target and passive monitor | fits; the target up to about 1.6 MHz TCK |
| HDMI-CEC | fits |
| LIN 2.x | fits, but the bit engine drives push-pull, so the transceiver does the open drain |
| Modbus RTU slave | fits with a few registers on the chip; CRC-16 in firmware |
| Wiegand 26/34 | fits |
| DShot150/300/600 | fits |
| I2S transmit | fits with a fractional bit clock at 50 MHz |
| MDIO clause 22 | fits |
| USB low speed HID enumeration | fits only with the host holding the descriptors |
| SD card in SPI mode, nRF24L01, LoRa SX127x | host-driven over the existing SPI controller: no new engine firmware, labelled as such |

## Not planned: the blind pool

I did not plan to write any of these. Eight of them will be drawn at random after the freeze and
written under the conditions below, whatever they are.

| ID | Protocol | Prediction |
|---|---|---|
| U01 | RC-6 mode 0 infrared | fits |
| U02 | DCF77 time-signal emulator | fits; the antenna is the open question, not the logic |
| U03 | 433 MHz on-off keying (PT2262 / EV1527 style) | fits |
| U04 | EM4100 125 kHz tag (tag side) | fits |
| U05 | IrDA SIR at 115200 | fits for transmit; receive depends on the transceiver's pulse width |
| U06 | ISO 7816-3 T=0 smart card reader | fits, bit-banged on one `uio` pin |
| U07 | MIL-STD-1553B remote terminal | fits for transmit; detecting the sync word on receive is the risk |
| U08 | ARINC 429 | fits |
| U09 | DCC model railway | fits |
| U10 | SENT (SAE J2716) | fits |
| U11 | SMBus with PEC | fits, but the I2C firmware plus PEC may not fit in 256 words |
| U12 | HD44780 character LCD, 4-bit | fits |
| U13 | TM1637 display | fits |
| U14 | DHT22 sensor | fits |
| U15 | HX711 load-cell ADC | fits |
| U16 | NES / SNES gamepad | fits |
| U17 | Quadrature encoder counter | fits |
| U18 | 8-channel RC servo PWM | fits |
| U19 | STEP/DIR stepper with a ramp | fits |
| U20 | VGA 640x480 timing with colour bars | fits; no pixel memory, so patterns only |
| U21 | PAL composite test card | fits with a two-pin resistor ladder |
| U22 | PDM microphone level meter | fits, with a crude filter |
| U23 | QSPI flash read (0xEB) | fits |
| U24 | Microwire 93C46 EEPROM | fits |
| U25 | APA102 LED strip | fits |
| U26 | SK6812 RGBW LEDs | fits |
| U27 | SD card native 1-bit mode | fits; 4-bit mode does not |
| U28 | S/PDIF receive | fits only if the fabric can find the preamble; uncertain |
| U29 | USB Power Delivery BMC sniffer | the digital side fits; it needs an analog front end |
| U30 | Differential Manchester (802.5 style) | fits |
| U31 | EnOcean ESP3 serial link | fits |
| U32 | Logic analyser mode (timestamped edges to the host) | fits, without burst capture |
| U33 | PMBus device | fits for a handful of commands |
| U34 | I3C SDR controller | uncertain: the word budget |
| U35 | EDID monitor emulator (DDC target) | fits only with the host holding the 128 bytes |
| U36 | CAN FD | does not fit: the data phase rate, two CRC polynomials, no packet memory |
| U37 | 4b5b with MLT-3 at the real 125 Mbaud | does not fit: the rate is above the clock |
| U38 | AC'97 | does not fit: 4 cycles per bit |

## The draw

- **Source**: the drand public randomness beacon, default (mainnet) chain, round **6725846**,
  which is published at 2026-12-14 00:00:00 UTC. Nobody, me included, can know its value before
  then.
- **Rule**: for each ID above, compute `SHA-256(randomness + ":" + ID)`, with the round's
  randomness as lowercase hex and the ID as written (for example `U07`). Sort the IDs by that
  hash as a hex string, smallest first, and take the first eight.
- **Conditions**: each drawn protocol gets at most four hours of work. The firmware is written
  only from `docs/isa.md`, `docs/info.md` and the assembler; at least three of the eight are
  written in a fresh session that is given nothing but those documents. The model of the other
  end and the test are written the same way as for every other protocol. A protocol counts as
  working only when its test passes against that model.
- **Reporting**: all eight results go on the results page, each as works, works with a stated
  limit, or does not fit, with the time taken, the number of instructions and what was missing.
  The predictions above stay as they are.
