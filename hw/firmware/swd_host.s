; swd_host.s: a Serial Wire Debug host (ARM Debug Interface v5): line resets, the JTAG-to-SWD
; switch, and DP and AP reads and writes with their parity and ACK. Written after the RTL freeze:
; firmware only.
;
; SWCLK is timed with WAIT time deadlines (low for a half period, then high for one). The host
; sets SWDIO right after SWCLK falls and reads it just before SWCLK rises; around the target's
; turn it lets go of SWDIO for one turnaround slot each way.
;
; Pins: p8 (uo[0]) SWCLK, p0 (uio[0]) SWDIO (a pull-up holds it high when nobody drives it).
; Host: first the half period in cycles (25 or more). Then commands:
;   raw bits:  a word [3:0] bits - 1, then a data word, sent LSB first (line reset: 1s; the
;              JTAG-to-SWD switch: 0xE79E; idle: 0s). Nothing comes back.
;   transfer:  0x8000 | [0] APnDP | [1] RnW | [3:2] A[3:2] | [12] send the parity bit wrong (to
;              test the target), then for a write the data, bits 15:0 and 31:16.
;              A read answers with the data (15:0, 31:16; 0 if the ACK was not OK), and every
;              transfer with a status word: the ACK (first bit in bit 0: 1 OK, 2 WAIT, 4 FAULT,
;              7 nobody answered), | 0x10 if the read data's parity was wrong.
;
; Registers: r7 half period, r6 the deadline, r1 command, r2 bits out, r3 ACK, r4/r5 data,
; r0 counts.

      pin  p8, clr         ; SWCLK low
      pin  p0, set         ; SWDIO driven high
      pull r7
cmd:  pull r1
      csrr r6, time_lo
      tstb r1, 15
      j    nz, xfer
      pull r2              ; raw bits
      mov  r0, r1
      ldi  r3, 0x0f
      and  r0, r3
      addi r0, 1
raw:  shri r2, 1
      pin  p0, c
      call clk
      djnz r0, raw
      jmp  cmd

xfer: tstb r1, 1
      j    nz, req         ; a read: nothing more from the host
      pull r4              ; write data
      pull r5
req:  mov  r0, r1
      ldi  r3, 0x0f
      and  r0, r3          ; APnDP, RnW, A2, A3
      mov  r2, r0
      shli r2, 1
      mov  r3, r0          ; their parity
      shri r3, 2
      xor  r3, r0
      mov  r0, r3
      shri r0, 1
      xor  r3, r0
      ldi  r0, 1
      and  r3, r0
      tstb r1, 12
      j    z, par
      xor  r3, r0          ; the test hook: parity wrong
par:  shli r3, 5
      or   r2, r3
      ldi  r3, 0x81
      or   r2, r3          ; start and park bits
      csrr r6, time_lo
      ldi  r0, 8
rq:   shri r2, 1
      pin  p0, c
      call clk
      djnz r0, rq
      pin  p0, hiz         ; turnaround to the target
      call clk
      ldi  r3, 0
      call clka
      call clka
      call clka
      shri r3, 13          ; the ACK, first bit in bit 0
      tstb r1, 1
      j    z, wr

      cmpi r3, 1           ; a read
      j    nz, rdx
      ldi  r0, 32
rd:   call clkr
      djnz r0, rd
      push r4
      push r5
      mov  r2, r4          ; the parity of what came
      xor  r2, r5
      mov  r0, r2
      shri r0, 8
      xor  r2, r0
      mov  r0, r2
      shri r0, 4
      xor  r2, r0
      mov  r0, r2
      shri r0, 2
      xor  r2, r0
      mov  r0, r2
      shri r0, 1
      xor  r2, r0          ; in bit 0
      call clkr            ; the parity bit, now r5 bit 15
      mov  r0, r5
      shli r0, 1
      ldi  r0, 0
      rlc  r0, 1
      xor  r0, r2
      ldi  r4, 1
      and  r0, r4
      shli r0, 4
      or   r3, r0
      call clk             ; turnaround back to the host
      pin  p0, clr         ; idle low
      push r3
      jmp  cmd
rdx:  ldi  r0, 0           ; no data
      push r0
      push r0
      call clk
      pin  p0, clr
      push r3
      jmp  cmd

wr:   call clk             ; turnaround back to the host
      cmpi r3, 1
      j    nz, wrx
      mov  r2, r4          ; the parity of the data
      xor  r2, r5
      mov  r0, r2
      shri r0, 8
      xor  r2, r0
      mov  r0, r2
      shri r0, 4
      xor  r2, r0
      mov  r0, r2
      shri r0, 2
      xor  r2, r0
      mov  r0, r2
      shri r0, 1
      xor  r2, r0
      ldi  r0, 16
w1:   shri r4, 1
      pin  p0, c
      call clk
      djnz r0, w1
      ldi  r0, 16
w2:   shri r5, 1
      pin  p0, c
      call clk
      djnz r0, w2
      shri r2, 1           ; the parity bit
      pin  p0, c
      call clk
wrx:  pin  p0, clr
      push r3
      jmp  cmd

; clk: one slot: SWCLK low until the deadline, then high for a half period
clk:  add  r6, r7
      wait time r6
      pin  p8, set
      add  r6, r7
      wait time r6
      pin  p8, clr
      ret
; clkr: a slot, reading SWDIO just before SWCLK rises into r5:r4 from the top
clkr: add  r6, r7
      wait time r6
      pin  p0, sample
      rrc  r5, 1
      rrc  r4, 1
      pin  p8, set
      add  r6, r7
      wait time r6
      pin  p8, clr
      ret
; clka: a slot, reading SWDIO into r3 from the top
clka: add  r6, r7
      wait time r6
      pin  p0, sample
      rrc  r3, 1
      pin  p8, set
      add  r6, r7
      wait time r6
      pin  p8, clr
      ret
