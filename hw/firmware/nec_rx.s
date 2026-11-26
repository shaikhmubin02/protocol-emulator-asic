; nec_rx.s: NEC infrared remote control receiver, reading a demodulating IR receiver (its output
; is low while the carrier is there). Written after the RTL freeze: firmware only.
;
; Each mark and space is measured in half units (281 us) by counting wait timeouts of half a
; unit while the pin stays as it is, so a 9 ms leader is no trouble for the 16-bit timer. Ranges,
; in half units (a unit is 562.5 us): leader mark 24 to 40 (16 units), leader space 12 to 20 (a
; frame, 8 units) or 6 to 10 (a repeat code, 4 units), bit mark 1 to 3, bit space 1 to 3 (a 0)
; or 4 to 8 (a 1).
;
; Pin: p19 (ui[3]) from the IR receiver.
; Host: first the unit in cycles (28125 at 50 MHz). The program sends 1 and then the 32 bits as
; two words (bits 15:0, 31:16: address, its inverse or the address's high byte, command, its
; inverse) for a frame; 2 for a repeat code; 3 | bits << 8 for a frame that broke off.
;
; Registers: r6 half a unit, r2 a length, r3/r4 the bits, r5 bits left.

      pull r6
      shri r6, 1           ; half a unit

idle: csrwi tmo, 0
      wait pin p19, 0      ; a mark begins
      call low
      cmpi r2, 24
      j    c, idle
      cmpi r2, 41
      j    nc, idle
      call high
      cmpi r2, 6
      j    c, idle
      cmpi r2, 11
      j    c, repeat
      cmpi r2, 12
      j    c, idle
      cmpi r2, 21
      j    nc, idle

      ldi  r5, 32          ; a frame
bit:  call low
      cmpi r2, 1
      j    c, broke
      cmpi r2, 4
      j    nc, broke
      call high
      cmpi r2, 1
      j    c, broke
      cmpi r2, 9
      j    nc, broke
      cmpi r2, 4           ; C = 1 for a 0, 0 for a 1
      ldi  r0, 0
      rlc  r0, 1
      ldi  r2, 1
      xor  r0, r2          ; the bit
      shri r0, 1           ; into C
      rrc  r4, 1
      rrc  r3, 1
      djnz r5, bit
      call low             ; the final mark
      ldi  r0, 1
      push r0
      push r3
      push r4
      jmp  idle
repeat: call low           ; its final mark
      ldi  r0, 2
      push r0
      jmp  idle
broke: ldi r0, 32
      sub  r0, r5
      shli r0, 8
      ldi  r2, 3
      or   r0, r2
      push r0
      jmp  idle

; low: r2 = how many half units the pin stays low (at most 63)
low:  ldi  r2, 0
      csrw tmo, r6
lo1:  wait pin p19, 1
      j    nt, lo2
      addi r2, 1
      cmpi r2, 63
      j    nz, lo1
lo2:  csrwi tmo, 0
      ret

; high: the same while the pin stays high
high: ldi  r2, 0
      csrw tmo, r6
hi1:  wait pin p19, 0
      j    nt, hi2
      addi r2, 1
      cmpi r2, 63
      j    nz, hi1
hi2:  csrwi tmo, 0
      ret
