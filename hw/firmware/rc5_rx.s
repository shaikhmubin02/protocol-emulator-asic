; rc5_rx.s: Philips RC-5 infrared receiver (with the RC-5X seventh command bit), reading a
; demodulating IR receiver (its output is low while the carrier is there). Written after the RTL
; freeze: firmware only.
;
; Every RC-5 bit has an edge in its middle: falling (space to mark) for a 1, rising for a 0. The
; first is the middle of S1. From each middle the program waits three quarters of a bit, then
; waits up to half a bit for the next middle edge, so it follows a remote whose bits are a little
; long or short, and edges between two bits are never taken for a middle.
;
; Pin: p19 (ui[3]) from the IR receiver.
; Host: first a quarter bit in cycles (22222 at 50 MHz). The program sends per frame
; 0x8000 | command (7 bits) | address << 7 | T << 12; or 0x4000 | the bits it had when a frame
; broke off (no middle edge where one must be).
;
; Registers: r7 the last middle, r6 a quarter bit, r5 half a bit, r1 the bits, r2 bits left.

      pull r6
      mov  r5, r6
      add  r5, r6

idle: csrwi tmo, 0
      wait pin p19, 1
      wait pin p19, 0      ; the middle of S1
      csrr r7, time_lo
      ldi  r1, 0
      ldi  r2, 13          ; S2, T, 5 address bits, 6 command bits
bit:  add  r7, r6          ; three quarters of a bit on, one deadline at a time
      wait time r7
      add  r7, r6
      wait time r7
      add  r7, r6
      wait time r7
      csrw tmo, r5
      pin  p19, sample
      j    c, hi
      wait pin p19, 1      ; low now: a rising middle, a 0
      j    t, broke
      ldi  r0, 0
      jmp  got
hi:   wait pin p19, 0      ; high now: a falling middle, a 1
      j    t, broke
      ldi  r0, 1
got:  csrr r7, time_lo     ; this bit's middle
      shri r0, 1
      rlc  r1, 1
      djnz r2, bit
      csrwi tmo, 0

      mov  r0, r1          ; r1 = S2 T A4..A0 C5..C0
      ldi  r2, 0x3f
      and  r0, r2          ; command bits 5..0
      tstb r1, 12
      j    nz, c6
      ldi  r2, 0x40
      or   r0, r2          ; command bit 6 = the inverse of S2
c6:   mov  r2, r1
      shri r2, 6
      ldi  r3, 0x3f
      and  r2, r3          ; T and the address
      shli r2, 7
      or   r0, r2
      ldi  r2, 0
      ldih r2, 0x80
      or   r0, r2
      push r0
      jmp  idle
broke: csrwi tmo, 0
      ldi  r0, 13
      sub  r0, r2
      ldi  r2, 0
      ldih r2, 0x40
      or   r0, r2
      push r0
      jmp  idle
