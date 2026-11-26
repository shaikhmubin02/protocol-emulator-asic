; wiegand_tx.s: a Wiegand card reader (the access-control interface): sends 26-bit (H10301) and
; 34-bit card numbers with their parity bits. Written after the RTL freeze: firmware only.
;
; Two open-drain lines, D0 and D1, pulled high; a 0 is a low pulse on D0, a 1 a low pulse on D1.
; A message: an even parity bit over the first half of the data bits, the data MSB first, an odd
; parity bit over the second half. 26 bits: facility code (8) and card number (16); 34 bits:
; facility code (16) and card number (16). Pulses start one period apart, on deadlines; after a
; message the lines stay released for 16 periods.
;
; Pins: p0 (uio[0]) D0, p1 (uio[1]) D1 (open drain: pulled low or let go).
; Host: first the pulse width and the pulse period in cycles (each at most 32767: 2500 and 20000
; are 50 us and 400 us at 50 MHz). Then per card: 26 or 34, the facility code, the card number.
;
; Registers: r1:r2 the data, left aligned (the next bit is r1 bit 15), r7 the next pulse's
; start, r6 pulse width, r5 pulse period, r3 and r4 counts and parity.

      pin  p0, hiz
      pin  p1, hiz
      pull r6
      pull r5
card: pull r3              ; 26 or 34
      pull r1              ; facility code
      pull r2              ; card number
      ldi  r0, 0xff
      ldih r0, 0xff        ; the first half of the data: all of r1 (34 bits) ...
      cmpi r3, 34
      j    z, al
      mov  r4, r2          ; 26 bits: facility and card number left aligned in r1:r2
      shri r4, 8
      shli r1, 8
      or   r1, r4
      shli r2, 8
      ldi  r0, 0xf0
      ldih r0, 0xff        ; ... or r1's top 12 bits (26 bits)
al:   mov  r4, r1
      and  r4, r0
      call par             ; even parity over the first half
      csrr r7, time_lo
      addi r7, 20
      shri r4, 1           ; C = it
      call send
      subi r3, 2
      shri r3, 1           ; half the data bits: 12 or 16
      mov  r4, r3
h1:   shli r2, 1
      rlc  r1, 1           ; C = the next bit
      call send
      djnz r4, h1
      ldi  r4, 0           ; the second half, counting its 1s
h2:   shli r2, 1
      rlc  r1, 1
      ldi  r0, 0
      rlc  r0, 1
      add  r4, r0
      shri r0, 1           ; C = the bit again
      call send
      djnz r3, h2
      ldi  r0, 1
      xor  r0, r4          ; odd parity over the second half
      shri r0, 1
      call send
      ldi  r4, 16          ; the lines stay released between messages
gap:  add  r7, r5
      wait time r7
      djnz r4, gap
      jmp  card

; send: at the deadline r7, a low pulse on D1 if C is 1, on D0 if it is 0; r7 moves on a period
send: wait time r7
      j    c, s1
      pin  p0, clr
      jmp  s2
s1:   pin  p1, clr
s2:   mov  r0, r7
      add  r0, r6
      wait time r0
      pin  p0, hiz
      pin  p1, hiz
      add  r7, r5
      ret

; par: r4 = the parity of r4's bits. Uses r0.
par:  mov  r0, r4
      shri r0, 8
      xor  r4, r0
      mov  r0, r4
      shri r0, 4
      xor  r4, r0
      mov  r0, r4
      shri r0, 2
      xor  r4, r0
      mov  r0, r4
      shri r0, 1
      xor  r4, r0
      ldi  r0, 1
      and  r4, r0
      ret
