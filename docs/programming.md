# Programming the engines

An engine is a small processor whose instructions are about pins and time. A protocol is a
program for it, written in assembly and loaded over the chip's SPI port. This page goes from a
first program to a protocol with its own line coding. [isa.md](isa.md) is the reference for
every instruction; the two example programs here are in `hw/firmware/examples` and
`hw/test/test_examples.ml` runs them on the RTL.

## What a program has

| | |
|---|---|
| Registers | r0 to r7, 16 bits each |
| Program | 256 words, a 4-deep call stack |
| Pins | p0 to p7 = `uio[0..7]` (read and drive, or let go), p8 to p14 = `uo[0..6]`, p16 to p23 = `ui[0..7]` (inputs; `ui[0..2]` are the host port) |
| Time | a 32-bit cycle counter shared by all engines (`TIME_LO`, `TIME_HI`) |
| Host | a mailbox of two words each way (`PUSH`, `PULL`), 8 event flags shared by all engines |
| Bit engine | a baud generator and shift registers that send and receive words on their own |
| Engines 0 and 1 only | an 8-element LUT fabric for line coding, and a CRC unit of up to 32 bits |

## The rules of time

Every instruction takes 1 cycle, except a delay of n (1 + n cycles) and a wait, which moves on in
the cycle after its condition holds. A pin write in cycle k is on the pad from cycle k+1. An input
is seen 2 cycles after it changes on the pad. Nothing outside an engine can stall it. These rules
are proved for any program (`formal/timing_props.sv`), so the timing of a program can be worked
out from the program alone.

The usual way to use them is a deadline: keep the time of the next edge in a register, add the
period to it, and `wait time` on it. Then the period does not depend on which way the code
branched.

## A first program: a square wave

`hw/firmware/examples/square.s`:

```asm
.equ HALF 25

      ldi  r1, HALF
      csrr r7, time_lo     ; the deadline starts from now
loop: add  r7, r1          ; the next edge is exactly HALF cycles after the last one
      wait time r7         ; wait until the counter reaches it
      pin  p8, tgl         ; the pin changes in the next cycle
      jmp  loop
```

At 50 MHz this is a 1 MHz square wave on `uo[0]`. The loop is four instructions, and the edges
are 25 cycles apart whatever they are: the test measures 79 edges in 2,000 cycles
and every gap is exactly 25. With `dly` instead of `wait time` the period would be the delay plus
the body, and it would change whenever the body did.

Assemble it:

    cd hw && dune build ./bin/asm.exe
    ./_build/default/bin/asm.exe firmware/examples/square.s

which prints one hex word per line.

## Loading and running it over SPI

The host port is SPI mode 0 with SCK up to clk/8. A frame is a command byte (`02` write, `03`
read), a 16-bit address, then 16-bit words, MSB first. Address bits [15:14] pick the engine and
[13:12] the region ([info.md](info.md) has the whole map). For `square.s` on engine 0:

| Frame | What it does |
|---|---|
| `02 00 00` then the program words | write program memory from address 0 (engines are stopped after reset) |
| `02 30 08 00 04` | pin 8 belongs to engine 0 (bit 2 = enable, [1:0] = engine) |
| `02 30 10 00 01` | run engine 0 (one bit per engine) |

An engine only drives the pins the host has given it, so two programs cannot fight over a pin.

## Talking to the host

`hw/firmware/examples/echo.s`:

```asm
loop: pull r0
      addi r0, 1
      push r0
      jmp  loop
```

`PULL` waits while the inbox is empty and `PUSH` while the outbox is full, so the host sets the
pace. The host writes a word with `02 20 80 00 07` (offset 0x80 of engine 0's region 2, address
0x2080), reads the status with `03 20 00 00` and two more bytes (bits [11:10] count the inbox,
[13:12] the outbox), and reads the answer from 0x2080. Each mailbox holds two words; the host reads the
status before it reads or writes. Words 1, 2, 3, 0x1233, 0xFFFF come back as 2, 3, 4, 0x1234, 0.

## Letting the bit engine shift bits

For a serial protocol the program configures the bit engine and hands it words; the bits go out
on the baud generator's ticks while the program does something else. The transmit half of
`hw/firmware/uart.s`, simplified:

```asm
      ldi  r1, 0x09
      ldih r1, 0x09        ; txcfg: 10 bits, LSB first, pin 8, idle high
      csrw txcfg, r1
      csrwi baud, BIT      ; cycles per bit; BAUDF adds 1/256ths
      ldi  r2, 0
      ldih r2, 0x02        ; the stop bit, bit 9
      ben  1               ; start the bit engine
send: pull r0              ; a byte from the host
      shli r0, 1           ; the start bit (0) in bit 0
      or   r0, r2
      tx   r0              ; waits only if the last word is still waiting
      jmp  send
```

The real file also receives, from the same bit engine, and services both directions without
blocking either: 37 words in all. The baud generator has a fraction, so 115200 baud at 50 MHz is
434 + 8/256 cycles a bit.

## Line coding in the fabric

Engines 0 and 1 have a fabric of 8 elements between the shift registers and the pins. Each element
is a 4-input LUT with a flop; its inputs pick from the bit being sent, the sample being received,
a bit the program sets, element 0's output, its own flop and its neighbours' flops. Roles say which
element drives the line, which one holds a bit back (to insert a stuffed bit), which one gives the
received bit, which one drops it, and which one is the flag the program can branch on.

A configuration is written in OCaml, one line per element, and loaded by the host (region 1). The
USB receiver's (`hw/post/fabric_post.ml`):

```ocaml
w.(0) <- word ~on_rx:true ~inputs:[ Ext1; Next ] (fun s last _ _ -> if s = last then 1 else 0);
w.(1) <- word ~on_rx:true ~use_ff:true ~inputs:[ Ext1 ] (fun s _ _ _ -> s);
w.(2) <- word ~on_rx:true ~use_ff:true ~inputs:[ Le0; Self ] (fun d c0 _ _ -> d land (1 - c0));
(* elements 3 and 4: the rest of a 3-bit count of 1s in a row; element 5: drop when it is 6 *)
```

Element 0 undoes NRZI, elements 2 to 4 count the 1s in a row, and element 5 drops the bit after six
of them. The program only says which element plays which role (`csrwi fabctl2, 0x15`: drop =
element 5, on) and reads one decoded bit per word. Every configuration is proved with a SAT solver
to compute its rule for every state and input; the proof is a few lines next to the protocol's
tests. Biphase-mark, which the chip was not designed with, is a 3-element configuration of this
kind (`bmc_tx`), used by `spdif_tx.s`.

## Testing a program

The tests in `hw/test` run a program on the engine RTL and the separately written model at the
same time and compare them every cycle, while a model of the device on the other end, written from
the protocol's specification, plays the pins. `hw/test/test_examples.ml` is the smallest example:

```ocaml
let ls = Lockstep.create (load "examples/square.s") in
for c = 1 to 2000 do
  ignore (Lockstep.step ls Model.Pads.zero : int option * bool);
  (* ... look at Lockstep.uo ls, the uo pins, every cycle ... *)
done
```

Set `PEMU_VCD_DIR` and the tests record the pins for a logic analyser view or the sigrok decoders
(`scripts/sigrok_check.sh`). `sim/` runs the whole chip under Verilator for programs that talk to
Linux software, and `test/` drives the chip only through its pins with cocotb.

## Where to look next

| File | Words | What it shows |
|---|---|---|
| `ws2812.s` | 29 | pulse widths to the cycle, with deadlines |
| `uart.s` | 37 | the bit engine in both directions, a fractional baud rate |
| `dmx_tx.s` | 40 | a break and mark-after-break made with the bit engine's idle level |
| `spi_master.s` | 41 | all four SPI modes |
| `spdif_tx.s` | 76 | a new line coding as a fabric configuration (`bmc_tx`) |
| `jtag_tap.s` | 131 | a target clocked by the other side |
| `can_tx.s` | 172 | bit stuffing in firmware and arbitration by reading the bus back |
| `usb_dev_tx.s` | 190 | two engines, event flags between them, the CRC unit sending a CRC-16 |

`docs/post-freeze/results.md` has every protocol written after the RTL freeze, with what went
wrong on the way. The limits to keep in mind: 256 words a program (the USB receiver uses 253), 8
registers, the fabric and CRC unit on engines 0 and 1 only, and a host that moves about one word
per 450 to 700 cycles over SPI, so a protocol whose data must come from the host faster than that
needs it buffered on the chip.
