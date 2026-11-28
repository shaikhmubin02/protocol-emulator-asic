; A square wave on uo[0] (p8) with an exact period: an edge every HALF cycles, however long the
; loop body is, as long as it is shorter than HALF. At 50 MHz, HALF = 25 gives 1 MHz.

.equ HALF 25

      ldi  r1, HALF
      csrr r7, time_lo     ; the deadline starts from now
loop: add  r7, r1          ; the next edge is exactly HALF cycles after the last one
      wait time r7         ; wait until the counter reaches it
      pin  p8, tgl         ; the pin changes in the next cycle
      jmp  loop
