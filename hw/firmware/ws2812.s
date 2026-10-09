; WS2812 ("NeoPixel") LED chain on p8 (uo[0]). Not one of the protocols the chip was designed
; around: it's a single wire where each bit is a high pulse whose width says 0 or 1.
;
; Host words: 16 bits each, sent MSB first. Each LED takes 24 bits (green, red, blue), so two
; LEDs are three words. When no word is waiting the line stays low, and once it has been low for
; the reset time (50 us or more) the LEDs latch what they got.
;
; Timing from the cycle counter, at 50 MHz (20 ns a cycle), datasheet values +-150 ns:
;   0: high 20 (0.40 us, spec 0.40), low 43 (0.86 us, spec 0.85)
;   1: high 40 (0.80 us, spec 0.80), low 23 (0.46 us, spec 0.45)
; For another clock, change the four numbers.

      pin  p8, clr
      ldi  r1, 20          ; T0H
      ldi  r2, 43          ; T0L
      ldi  r3, 40          ; T1H
      ldi  r4, 23          ; T1L

idle: pull r5
      csrr r7, time_lo     ; the line has been idle: start the bit clock afresh,
      addi r7, 8           ; a little ahead, so the first edge comes out of a wait like the rest
      jmp  word
loop: j    mbx_data, next  ; the next word is already here: keep the bits back to back
      jmp  idle
next: pull r5
word: ldi  r6, 16

bit:  wait time r7         ; start of the bit
      pin  p8, set
      shli r5, 1           ; C = bit
      j    c, one
      add  r7, r1
      wait time r7
      pin  p8, clr
      add  r7, r2
      djnz r6, bit
      jmp  loop
one:  add  r7, r3
      wait time r7
      pin  p8, clr
      add  r7, r4
      djnz r6, bit
      jmp  loop
