; jtag_host.s: a JTAG controller (IEEE 1149.1): the host says what to clock, the program makes
; TCK and sets TMS and TDI, and sends back what TDO said. Written after the RTL freeze:
; firmware only.
;
; TCK is timed with WAIT time deadlines, so its period is exactly twice the host's half period
; whatever the program does in between. TMS and TDI change right after TCK falls; TDO is
; sampled just before TCK rises (the target changes it after the falling edge).
;
; Pins: p8 (uo[0]) TCK, p9 (uo[1]) TMS, p10 (uo[2]) TDI, p19 (ui[3]) TDO.
; Host: first half the TCK period, in cycles (25 or more). Then commands of two words: a command
; word and a data word, the bits LSB first.
;   command [3:0] bits - 1 (1 to 16 bits)
;           [8]   TMS bits: the data word is TMS, TDI stays 0, nothing is sent back
;           [9]   shift with TMS 1 on the last bit (leave Shift-DR or Shift-IR)
;           [10]  send back the TDO bits as one word, the first bit in bit 0
;
; Registers: r7 half period, r6 the deadline, r1 command, r2 data, r3 bits left, r4 TDO bits,
; r5 the bit TDO goes to.

      pin  p8, clr         ; TCK low
      pin  p9, set         ; TMS high
      pin  p10, clr
      pull r7
cmd:  pull r1
      pull r2
      mov  r3, r1
      ldi  r0, 0x0f
      and  r3, r0
      addi r3, 1
      ldi  r4, 0
      ldi  r5, 1
      csrr r6, time_lo     ; TCK has been low since the last command

bit:  tstb r1, 8
      j    z, shift
      shri r2, 1           ; TMS bit
      pin  p9, c
      pin  p10, clr
      jmp  half
shift: shri r2, 1          ; TDI bit
      pin  p10, c
      cmpi r3, 1
      j    nz, tms0
      tstb r1, 9
      j    z, tms0
      pin  p9, set         ; the last bit leaves the shift state
      jmp  half
tms0: pin  p9, clr
half: add  r6, r7
      wait time r6
      pin  p19, sample     ; TDO
      pin  p8, set         ; TCK rises
      j    nc, h2
      or   r4, r5
h2:   shli r5, 1
      add  r6, r7
      wait time r6
      pin  p8, clr         ; TCK falls
      djnz r3, bit
      tstb r1, 10
      j    z, cmd
      push r4
      jmp  cmd
