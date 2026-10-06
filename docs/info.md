<!---
This file is used to generate your project datasheet.
-->

## How it works

A test block for a programmable protocol chip: a small LUT fabric (24 elements, each a LUT4 and a
flop) plus a bit-serial CRC unit with a programmable polynomial. Both are configured at run time
through a shift register on the input pins. The fabric does bit-level jobs like CRCs, NRZI and
bit-stuffing detection; the CRC unit handles CRCs up to 32 bits.

## How to test

Shift a 38-bit word `{addr[5:0], data[31:0]}` into ui[0] (MSB first) while ui[1] is high, then pulse
ui[2] for one clock. Addresses 0-23 configure fabric elements, 62 sets the CRC polynomial
(left-aligned) and 63 the CRC init value. Pulse ui[4] to load init values, then put a data bit on
ui[5] and pulse ui[3] for each bit. uio[2:0] selects what appears on uo: 0-2 fabric outputs, 3-6
the CRC (bit-reversed).

## External hardware

None.
