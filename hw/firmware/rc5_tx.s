; rc5_tx.s: Philips RC-5 infrared remote control transmitter (with the RC-5X seventh command
; bit). The LUT fabric makes the 36 kHz carrier (ir_carrier in hw/post/fabric_post.ml); the
; program turns it on and off on WAIT time deadlines. Written after the RTL freeze: firmware and
; a fabric configuration.
;
; A frame is 14 bits of 1.778 ms, Manchester coded: a 1 is a space then a mark, a 0 a mark then
; a space. Bits, first first: S1 (1), S2 (the inverse of command bit 6), T (toggles on every new
; key press, not on repeats), 5 address bits and 6 command bits, MSB first. A held key repeats
; the frame every 64 bits (113.8 ms).
;
; Pin: p8 (uo[0]) to the IR LED driver.
; Host: first the carrier tick, whole cycles and then the 1/256 fraction (half a carrier period:
; 694 and 114 for 36 kHz at 50 MHz), then a quarter bit in cycles (22222). Then per frame a word:
; command (7 bits) | address << 7 | 0x8000 if it repeats the last key (T stays).
;
; Registers: r7 the deadline, r6 a quarter bit, r5/r4 FABCTL carrier on/off, r3 T (in bit 11),
; r2 the frame, r1 bits left, r0 counts.

      pull r0
      csrw baud, r0
      pull r0
      csrw baudf, r0
      pull r6
      ldi  r4, 0x42
      ldih r4, 0x02        ; fabctl: line = element 1, hold = element 2, hold on; carrier off
      mov  r5, r4
      addi r5, 1           ; carrier on
      csrw fabctl, r4
      ldi  r0, 0
      ldih r0, 0x05        ; txcfg: pin 8, through the fabric, idle 0
      csrw txcfg, r0
      ben  1
      tx   r0              ; one word, held for ever by the fabric's hold element
      ldi  r3, 0

key:  pull r1
      tstb r1, 15
      j    nz, same
      ldi  r0, 0
      ldih r0, 0x08
      xor  r3, r0          ; a new key press: T flips
same: ldi  r2, 0
      ldih r2, 0x20        ; S1
      tstb r1, 6
      j    nz, s2
      ldi  r0, 0
      ldih r0, 0x10
      or   r2, r0          ; S2 = the inverse of command bit 6
s2:   or   r2, r3          ; T
      mov  r0, r1
      shri r0, 7
      ldi  r7, 0x1f
      and  r0, r7
      shli r0, 6
      or   r2, r0          ; the address
      ldi  r7, 0x3f
      and  r1, r7
      or   r2, r1          ; command bits 5..0
      shli r2, 2           ; S1 in bit 15
      csrr r7, time_lo
      ldi  r1, 14
bit:  shli r2, 1
      j    c, one
      ldi  r0, 2
      call mk              ; a 0: mark, then space
      ldi  r0, 2
      call sp
      jmp  nb
one:  ldi  r0, 2
      call sp              ; a 1: space, then mark
      ldi  r0, 2
      call mk
nb:   djnz r1, bit
      ldi  r0, 200         ; off for the rest of 64 bits
      call sp
      jmp  key

; mk: carrier on for r0 quarter bits; sp: off. Each quarter is a deadline r6 after the last.
mk:   csrw fabctl, r5
      jmp  u
sp:   csrw fabctl, r4
u:    add  r7, r6
      wait time r7
      djnz r0, u
      ret
