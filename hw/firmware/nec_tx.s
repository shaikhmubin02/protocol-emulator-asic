; nec_tx.s: NEC infrared remote control transmitter. The LUT fabric makes the 38 kHz carrier
; (ir_carrier in hw/post/fabric_post.ml); the program turns it on and off at exact times with
; WAIT time deadlines. Written after the RTL freeze: firmware and a fabric configuration.
;
; NEC, in units of 562.5 us: a frame is a 16-unit mark and an 8-unit space, then 32 bits LSB
; first (address, its inverse, command, its inverse; the first two can be a 16-bit address in
; the extended form), each a 1-unit mark and a 1-unit (0) or 3-unit (1) space, then a 1-unit
; mark. A repeat code (key held) is a 16-unit mark, a 4-unit space and a 1-unit mark. Frames
; start 108 ms (192 units) apart.
;
; Pin: p8 (uo[0]) to the IR LED driver.
; Host: first the carrier tick, whole cycles and then the 1/256 fraction (half a carrier period:
; 657 and 228 for 38 kHz at 50 MHz), then the unit in cycles (28125). Then per frame 0, the
; 16-bit address and the command byte; or 1 for a repeat code.
;
; Registers: r7 the deadline, r6 the unit, r5/r4 FABCTL with the carrier on/off, r3 units used
; in this frame, r1 data, r2 and r0 counts.

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

next: pull r1
      ldi  r3, 0
      csrr r7, time_lo
      ldi  r2, 16
      call mk              ; the leader mark
      tst  r1, r1
      j    nz, rep
      ldi  r2, 8
      call sp
      pull r1              ; the address
      call bits
      pull r1              ; the command, and its inverse
      ldi  r0, 0xff
      and  r1, r0
      xor  r0, r1
      shli r0, 8
      or   r1, r0
      call bits
      ldi  r2, 1
      call mk              ; the final mark
      jmp  gap
rep:  ldi  r2, 4
      call sp
      ldi  r2, 1
      call mk
gap:  ldi  r2, 192         ; off until 108 ms after this frame began
      sub  r2, r3
      call sp
      jmp  next

; bits: the 16 bits of r1, LSB first
bits: ldi  r0, 16
b:    ldi  r2, 1
      call mk
      ldi  r2, 1
      shri r1, 1
      j    nc, b0
      ldi  r2, 3
b0:   call sp
      djnz r0, b
      ret

; mk: carrier on for r2 units; sp: off for r2 units. Each unit is a deadline r6 after the last.
mk:   csrw fabctl, r5
      jmp  u
sp:   csrw fabctl, r4
u:    add  r7, r6
      wait time r7
      addi r3, 1
      djnz r2, u
      ret
