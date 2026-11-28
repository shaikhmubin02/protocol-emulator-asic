# Mutation testing

Do the tests notice when the RTL is wrong? To find out I break it on purpose, one small change at
a time, and check that something fails.

## How

`scripts/mutate.py` lists every place in the RTL source (`hw/src/engine.ml`, `hw/src/chip.ml`)
where one operator or constant can be swapped: `&:` and `|:`, `+:` and `-:`, `==:` and `<>:`,
`<:` and `<=:`, `>=:` and `>:`, a constant made one larger, `gnd` and `vdd` swapped, a `~:` dropped,
or a `when_` switched off. That gives 497 mutants. Each one is built in a private copy of the
repository and run against:

1. the lockstep tests, which compare the RTL with the separately written model every cycle
   (`hw/test/test_lockstep.ml`, `test_chip_lockstep.ml`, `test_chip.ml`: random programs, random
   debugger commands, every firmware, the whole chip with host traffic over SPI);
2. the proofs (`scripts/prove.sh`).

A mutant that builds and passes all of them has survived. Either it changes nothing a program or
the host can see, or the tests have a gap.

    python3 scripts/mutate.py list                  # every mutant
    python3 scripts/mutate.py run --sample 20       # a random 20 (about 70 s each)
    python3 scripts/mutate.py run                   # all 497 (about 7 hours here)

## Result

| | Mutants |
|---|---|
| Caught on the first run, by the lockstep tests | 476 |
| Caught on the first run, by the proofs only | 1 |
| Survived, and showed a gap in the tests: each gap now has a test, and the mutant is caught | 9 |
| Survived, and change nothing a program or the host can see (argued below) | 11 |
| Open | 0 |

## The gaps, and the tests that close them

| Mutants | Change | What no test did | Test that catches it now |
|---|---|---|---|
| 96 | `engine.ml:660`, CALL writes a stack slot under a wider condition | nest calls 4 deep and return all the way | `test_lockstep.ml` "call stack at full depth and past it" |
| 429 | `chip.ml:138`, the configuration write enable | write a fabric and CRC configuration over the host port and check it arrived | `test_chip.ml` "host-written fabric and CRC configuration reaches the engine" |
| 88, 89, 182, 359 | `engine.ml:653`, when TIME_HI latches the high half of the counter | read TIME_LO, let the counter cross 0x10000, then read TIME_HI (random programs are never that long) | `test_lockstep.ml` "TIME_HI keeps the half latched by the TIME_LO read across a 16-bit wrap" |
| 155 | `engine.ml:468`, where a word pushed into a mailbox FIFO goes | push and pop in the same cycle while the FIFO holds a word | `test_lockstep.ml` "mailboxes with a push and a pop in the same cycle" (856 such cycles on the outbox, 603 on the inbox) |
| 448, 464 | `chip.ml:118`, the host port's "inbox has room" check | write to a full inbox (every test host reads the status first) | `test_chip.ml` "a write to a full inbox is dropped" |

## The ones that change nothing visible

| Mutants | Change | Why nothing a program or the host sees changes |
|---|---|---|
| 38 | `engine.ml:472`, the second FIFO slot is also written while it holds no word | no word read from a mailbox changes; only the value a read of an empty mailbox returns, which `docs/info.md` says means nothing |
| 263 | `engine.ml:268`, condition 15 becomes "always" | condition 15 is not a legal instruction: the assembler has no name for it and the model rejects it (`docs/isa.md`) |
| 265, 266 | `engine.ml:439`, the value PIN would drive for HIZ, and for toggling a pin number of 15 or more | a HIZ write takes the let-go path and never uses it; pins 15 and up cannot be written |
| 267 | `engine.ml:442`, the value PIN would drive in SAMPLE mode | a SAMPLE never writes a pin |
| 379, 386, 387 | `chip.ml:119`, `chip.ml:134`, the program-memory read enable | it only chooses the SRAM address while the engine is held, and none of the three asserts it in the cycle that starts the engine (a write frame to region 3) |
| 395 | `chip.ml:225`, the low half of a configuration word is also latched when no word is written | it latches the word that is already there |
| 400, 458 | `chip.ml:244`, the MISO shift register in write frames, and its fill bit | MISO only means something while the host reads a word, and the read register is reloaded for every word |

## What this does not show

- Mutants are single small changes. A wrong design that the model shares (both written from my
  reading of `docs/isa.md`) would not be caught by the lockstep tests; the proofs and the
  protocol tests against models of the other end are there for that.
- "Equivalent" above is my argument, not a proof.
- The mutants change the RTL source only, not the netlist; the netlist is checked against the
  RTL separately (`scripts/equiv/`).
