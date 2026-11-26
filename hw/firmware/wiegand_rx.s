; wiegand_rx.s: a Wiegand controller input (the access-control interface): collects the pulses
; on D0 and D1 into a message and hands it to the host. Written after the RTL freeze: firmware
; only.
;
; A low pulse on D0 is a 0, on D1 a 1. A low only counts if it is still there 256 cycles (5 us)
; later, so short glitches are ignored. A message ends when both lines stay high for the
; host's silence time. The host checks the parity bits and splits the fields, since the formats
; differ (26, 34, 37 bits and more).
;
; Pins: p0 (uio[0]) D0, p1 (uio[1]) D1, inputs only (pin group 0).
; Host: first the silence that ends a message, in units of 1024 cycles (100 is about 2 ms at
; 50 MHz). The program sends per message 0x8000 | the number of bits, then the bits in three
; words, the last bit in bit 0 of the third: bits 47:32, 31:16, 15:0.
;
; Registers: r4:r1:r2 the bits, r5 how many, r3 the silence deadline, r6 silence units left,
; r7 the silence time.

      csrwi group0, 0x20   ; pins 0 and 1
      pull r7
msg:  ldi  r5, 0
      ldi  r4, 0
      ldi  r1, 0
      ldi  r2, 0
first: inp r0, 0
      cmpi r0, 3
      j    z, first        ; both high: nothing yet

pulse: dly 255             ; still low 256 cycles later?
      inp  r3, 0
      cmp  r3, r0
      j    nz, gl          ; no: a glitch
      ldi  r3, 0
      cmpi r0, 1           ; D1 low, D0 high: a 1
      j    nz, b0
      ldi  r3, 1
b0:   shri r3, 1           ; C = the bit
      rlc  r2, 1
      rlc  r1, 1
      rlc  r4, 1
      addi r5, 1
pe:   inp  r0, 0           ; the end of the pulse
      cmpi r0, 3
      j    nz, pe

gl:   csrr r3, time_lo     ; now wait for the next pulse, or the silence
      mov  r6, r7
nx:   inp  r0, 0
      cmpi r0, 3
      j    nz, pulse
      csrr r0, time_lo
      sub  r0, r3
      shri r0, 10
      j    z, nx           ; less than 1024 cycles since r3
      ldi  r0, 0
      ldih r0, 0x04
      add  r3, r0
      djnz r6, nx

      tst  r5, r5          ; silence: the message is over
      j    z, msg
      ldi  r0, 0
      ldih r0, 0x80
      or   r0, r5
      push r0
      push r4
      push r1
      push r2
      jmp  msg
