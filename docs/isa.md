# Engine instruction set

This is one engine as its program sees it: state, timing, pins, instructions, control registers
and the bit engine. The chip has four engines. The host side (SPI port, address map, debugger) is
in [info.md](info.md).

The reference for every detail here is the cycle-accurate model in `hw/src/model.ml`; the RTL is
checked against it every cycle (lockstep), and the timing rules in section 2 are proven on the
generated Verilog (`formal/timing_props.sv`, `formal/chip_props.sv`).

## 1. State

| State | Size | Notes |
|---|---|---|
| r0 to r7 | 8 x 16 bits | general purpose, reset to 0 |
| pc | 8 bits | reset to 0 |
| Z, C, T | 1 bit each | zero, carry, timeout |
| call stack | 4 x 8 bits | 4 deep, wraps around (no trap) |
| program memory | 256 x 16 bits | written by the host while the engine is stopped |
| CSRs | 64 addresses | section 6 |

## 2. Timing

These are the rules a program can count on. All of them are proven for any program, with the
host, the pins and the other engines doing anything at all.

1. Every instruction takes 1 cycle, except:
   - `PIN` and `OUTG` with a delay field d: 1 + d cycles (d = 0 to 7);
   - `DLY n`: 1 + n cycles (n = 0 to 255);
   - a wait (`WAIT`, `PUSH`, `PULL`, `TX`, `RX`): it checks its condition every cycle and moves
     on in the cycle after the condition holds, never earlier. It adds no cycle of its own: a
     wait whose condition already holds takes 1 cycle.
2. Branches take 1 cycle whether they are taken or not. `JMP` and `CALL` take 1 cycle.
3. A pin write in cycle k is on the pad from cycle k+1, with no other stage in between.
   The one exception: while the bit engine is on, it owns the level of its TX pin.
4. Inputs go through a 2-flop synchroniser: a wait on a pad pin sees the pad as it was 2 cycles
   earlier. That is the same for every pin and every engine.
5. Nothing outside an engine can stall it, except the debugger (which only acts when the host
   asks). Engines never wait for each other unless a program waits on a flag or the time.
6. A `SIG` in cycle k is seen by every engine in cycle k+1, so a `WAIT flag` in another engine
   moves on in cycle k+2 at the earliest.

Because of rule 1 and 2, the run time of straight-line code is the sum of its instruction times.
Programs that need exact timing usually keep a deadline in a register, add the bit time to it,
and `WAIT time` on it; then the time doesn't depend on which way the code branched.

## 3. Pins

Pin numbers are 5 bits.

| p | Pin | Drive | Read |
|---|---|---|---|
| 0 to 7 | uio[0..7] | push-pull, or released (`HIZ`) | the pad, through the synchroniser |
| 8 to 14 | uo[0..6] | push-pull only (`HIZ` drives 0) | the output register |
| 15 | uo[7] | the host port's MISO: writes are ignored | 0 |
| 16 to 23 | ui[0..7] | inputs: writes are ignored | the pad, through the synchroniser (ui[0..2] are the host port) |
| 24 to 31 | none | writes are ignored | 0 |

An engine only changes a pin the host has given it (pin owners, info.md). A write to a pin it
doesn't own takes its normal cycles and changes nothing. Every engine can read every pin.
Open drain (I2C, 1-Wire) is `CLR` to pull low and `HIZ` to let go.

Pin groups: each engine has 4 groups, each a run of 1 to 8 pins set by a CSR (base pin, count).
`OUTG` writes the low bits of a register to a group (bit 0 to the base pin), `INP` reads one.

## 4. Instructions

16 bits each, op = bits [15:12]. Unused fields must be 0 (the assembler makes sure of it).

| op | Instruction | Fields | Effect |
|---|---|---|---|
| 0 | system | [11:8] sub | table 4.1 |
| 1 | `LDI rd, imm8` / `LDIH rd, imm8` | [11:9] rd, [8] high, [7:0] imm | LDI: rd = imm. LDIH: rd[15:8] = imm, low byte kept |
| 2 | `MOV ADD SUB AND OR XOR CMP TST rd, rs` | [11:9] rd, [8:6] rs, [5:3] fn | fn 0 to 7 in that order |
| 3 | `ADDI SUBI CMPI SHLI SHRI RLC RRC TSTB rd, imm6` | [11:9] rd, [8:6] fn, [5:0] imm | fn 0 to 7 in that order |
| 4 | `J cc, target` | [11:8] cc, [7:0] target | jump if the condition holds (4.2); `JMP t` = `J always, t` |
| 5 | `DJNZ rd, target` | [11:9] rd, [7:0] target | rd = rd - 1, jump if rd != 0; flags unchanged |
| 6 | `CALL target` | [7:0] target | push pc + 1, jump |
| 7 | `PIN p, action, d` | [11:10] op, [9:5] p, [4:3] mode, [2:0] d | 4.3 |
| 8 | `OUTG g, rs, d` | [11:9] rs, [8:7] g, [2:0] d | drive group g from rs |
| 9 | `INP rd, g` | [11:9] rd, [8:7] g | rd = the pins of group g |
| 10 | `WAIT kind ...` | [11:10] kind | section 5 |
| 11 | `DLY n` | [7:0] n | take 1 + n cycles |
| 12 | `CSRR rd, c` | [11:9] rd, [5:0] c | rd = CSR c |
| 13 | `CSRW c, rs` | [11:9] rs, [5:0] c | CSR c = rs |
| 14 | `CSRWI c, imm6` | [11:6] imm, [5:0] c | CSR c = imm |
| 15 | reserved | | |

### 4.1 System instructions (op 0)

| sub | Instruction | Effect |
|---|---|---|
| 0 | `NOP` | |
| 1 | `HALT` | stop in place; the host sees it in the status word |
| 2 | `RET` | pop the pc |
| 3 | `PUSH rs` | put rs in the outbox to the host (waits while it is full) |
| 4 | `PULL rd` | take a word from the inbox (waits while it is empty) |
| 5 | `SIG f` | set event flag f (0 to 7), shared by all engines |
| 6 | `CLRF f` | clear event flag f (a `SIG` of the same flag in the same cycle wins) |
| 7 | `TX rs` | give rs to the bit engine's TX holding register (waits while it is full) |
| 8 | `RX rd` | take the bit engine's received word (waits until there is one) |
| 9 | `CRCI` | load the CRC register with its start value |
| 10 | `BEN on` | [0]: turn the bit engine on (restarting its timing) or off |

### 4.2 Flags and conditions

ALU instructions set Z from the result. ADD, ADDI, SUB, SUBI, CMP and CMPI set C to the carry
(C = 1 on a borrow for subtracts); shifts and rotates set C to the last bit shifted out; TST and
TSTB set only Z; MOV, LDI and LDIH set Z (LDIH from the whole register). Every wait sets T: 0 when its condition held, 1 when it
timed out.

| cc | Condition | cc | Condition |
|---|---|---|---|
| 0 | always | 8 | pin JPIN low |
| 1 | Z | 9 | RX word ready |
| 2 | not Z | 10 | TX holding register empty |
| 3 | C | 11 | inbox has a word |
| 4 | not C | 12 | flag JFLAG set |
| 5 | T | 13 | flag JFLAG clear |
| 6 | not T | 14 | the fabric's flag output |
| 7 | pin JPIN high | 15 | never |

### 4.3 PIN

| mode [4:3] | Action |
|---|---|
| 0 | op 0 `CLR` (drive 0), 1 `SET` (drive 1), 2 `TGL` (drive the inverse of the output), 3 `HIZ` (let go) |
| 1 | drive C |
| 2 | drive not C |
| 3 | `SAMPLE`: C = the pin |

Driving a uio pin also turns its output on.

## 5. Waits and timeouts

| kind | Instruction | Moves on when |
|---|---|---|
| 0 | `WAIT pin p, v` ([9:5] p, [4] v) | pin p reads v |
| 1 | `WAIT flag f, v` ([2:0] f, [3] v) | event flag f is v |
| 2 | `WAIT time rs` ([2:0] rs) | TIME_LO - rs, as a signed 16-bit number, is 0 or more (the time has come or passed) |
| 3 | `WAIT event e` ([3:0] e) | 0 TX holding register empty, 1 RX word ready, 2 TX baud tick, 3 capture edge, 4 inbox has a word |

`PUSH`, `PULL`, `TX` and `RX` wait the same way. If the CSR `TMO` is not 0 and the condition has
been false on `TMO` checks in a row, the wait gives up in that cycle with T = 1 (`PULL` and `RX`
then leave rd unchanged), so a wait that never succeeds takes exactly `TMO` cycles. `TMO` = 0
waits forever.

## 6. Control registers (CSRs)

| c | Name | R/W | Meaning |
|---|---|---|---|
| 0x00 | TIME_LO | R | the chip's cycle counter [15:0]; reading it also latches [31:16] into TIME_HI |
| 0x01 | TIME_HI | R | the latched [31:16] |
| 0x02 | CAP | R | TIME_LO at the last capture edge |
| 0x03 | CAPCFG | RW | [4:0] pin, [6:5] edge: 0 rising, 1 falling, 2 or 3 both |
| 0x04 | TMO | RW | wait timeout in cycles, 0 = none |
| 0x05 | JPIN | RW | [4:0] the pin for conditions 7 and 8 |
| 0x06 | JFLAG | RW | [2:0] the flag for conditions 12 and 13 |
| 0x07 | FLAGS | R | the 8 event flags |
| 0x08 | BAUD | RW | bit time, whole cycles (0 counts as 1) |
| 0x09 | BAUDF | RW | [7:0] the fraction of the bit time, in 1/256 cycles |
| 0x0A | TXCFG | RW | [3:0] bits - 1, [4] MSB first, [9:5] TX pin, [10] through the fabric, [11] idle level |
| 0x0B | RXCFG | RW | [3:0] bits - 1, [4] MSB first, [9:5] RX pin, [10] through the fabric, [11] re-align on every edge, [13:12] start: 0 free running, 1 falling edge, 2 rising edge, 3 any edge |
| 0x0C | BSTAT | R | [0] TX holding register empty, [1] TX idle, [2] RX word ready, [3] RX overrun |
| 0x10 | CRC_LO | R | CRC register [15:0] (bit-reversed if CRCCTL[3]) |
| 0x11 | CRC_HI | R | CRC register [31:16] |
| 0x12 | CRCCTL | RW | [0] on, [2:1] input: 0 TX bits, 1 RX bits, 2 or 3 the fabric's aux output; [3] read reversed; [4] send: words loaded from now on carry the CRC register instead (inverted, top bit first) |
| 0x18 | FABCTL | RW | [0] the fabric's ext2 input, [3:1] line element, [7:5] hold element, [9] hold on, [12:10] rx bit element |
| 0x19 | FABCTL2 | RW | [2:0] drop element, [4] drop on, [7:5] flag element, [11:9] aux element |
| 0x20 to 0x23 | GROUP0 to GROUP3 | RW | [4:0] base pin, [7:5] count - 1 |

Other addresses read 0. The CRC polynomial and start value and the fabric configuration are
written by the host.

## 7. Bit engine

Each engine has a bit engine that runs on its own once turned on (`BEN 1`): a baud generator,
a TX shifter, an RX shifter, an 8-element LUT fabric and a CRC unit. The program only hands it
words (`TX`, `RX`), so the program is free while bits go out and come in.

### 7.1 Baud generator

TX and RX each have a phase accumulator with the same period, BAUD + BAUDF/256 cycles on
average (exactly BAUD cycles when BAUDF = 0). `BEN 1` restarts both, so the first tick comes a
full bit time later. An edge on the RX pin (the start edge, or every edge with RXCFG[11])
restarts the RX phase so the next sample is about half a bit time later, in the middle of the
bit. TX ticks are not affected, so full duplex works.

### 7.2 TX and RX

- TX: `TX rs` fills the holding register. When the shifter is empty it takes the next word
  (TXCFG[3:0] + 1 bits); each tick sends one bit, LSB or MSB first. Without the fabric the bit
  goes to the TX pin. Through the fabric, the bit is the fabric's ext0 input, the line element
  drives the pin, and a hold element at 1 keeps the bit for another tick (that is how a stuffed
  bit gets in). With nothing to send the pin shows TXCFG[11].
  TXCFG starts at 0, so while the bit engine is on it drives pin 0 at level 0 on every tick: a
  program that only receives should set TXCFG to pin 31 (no pad) with idle level 1.
  With MSB first, the bit sent is picked by the word length in TXCFG at each tick, not the
  length the word was loaded with; change the length only while the shifter is empty, or send
  LSB first, where the order doesn't depend on it.
- RX: each tick samples the RX pin. Without the fabric the sample is the bit. Through the fabric,
  the sample is ext1, the rx bit element gives the bit, and a drop element at 1 throws it away
  (that is how a stuffed bit gets out). After RXCFG[3:0] + 1 kept bits the word is ready.

### 7.3 LUT fabric

8 elements, each a 4-input LUT with a flop. Each LUT input picks one of: ext0 (TX bit), ext1
(RX sample), ext2 (FABCTL[0]), element 0's output (the only link that isn't through a flop),
its own flop, or the flop of the element
1 or 2 below it or 1 above it. Each element steps on TX ticks or on RX ticks (its own choice),
can show its flop or its LUT output, and has a start value loaded by `BEN 1`. The roles (line,
hold, rx bit, drop, flag, aux) each pick an element. The configuration format is in
`hw/src/fabric_logic.ml`; examples (USB stuffing and NRZI, 10BASE-T Manchester both ways, a
CRC) are in `hw/src/bitstream.ml`, and each is proven against what it is meant to compute with a
SAT solver.

### 7.4 CRC unit

Up to 32 bits, any polynomial and start value. When on, it takes one bit per tick from its input;
held TX bits and dropped RX bits are skipped. `CRCI` loads the start value. With CRCCTL[4] the
TX shifter sends the CRC register itself, so a frame check sequence can follow the data with no
gap (10BASE-T does this).

## 8. Assembler

`hw/src/asm.ml`, one instruction per line, `;` comments, `label:` labels and `.equ NAME value`.
Registers are `r0` to `r7`, pins `p0` to `p31`, CSRs by name (`txcfg`) or number. A program can
be assembled with `hw/_build/default/bin/asm.exe file.s`, which prints one hex word per line.
The firmware in `hw/firmware` is the best set of examples.
