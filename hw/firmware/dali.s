; dali.s: DALI control device (IEC 62386-101/102): sends forward frames and reads the backward
; frames that control gear answers with. Written after the RTL freeze: firmware only, plus the
; 10BASE-T Manchester configuration (eth_tx in hw/src/bitstream.ml), loaded unchanged: DALI's
; bi-phase coding has the same polarity as 802.3 (a 1 goes low to high in the middle of the bit),
; only the tick is 4000 times slower.
;
; Forward frame: a start bit (1), the address byte and the data byte, most significant bit first,
; then the line idles high (the stop bits). Backward frame: a start bit and one byte. Te = half a
; bit = 416.7 us at 1200 bit/s, 20833 cycles at 50 MHz; every deadline here is at most Te ahead,
; inside the reach of WAIT time.
;
; Pins: p0 (uio[0]) to the DALI interface's transmit input (1 = bus released, which a pull-up
; holds while the pin is not driven); p19 (ui[3]) the bus as the interface shows it.
; Host: first the half-bit time Te in cycles. Then per transaction the forward frame, address
; byte << 8 | data byte; the program answers the backward frame byte, 0x100 if no gear answered
; within 22 Te, or 0x200 if the answer was not a valid frame.
;
; Registers: r5 = Te, r6 = Te / 2, r7 deadlines, r1 frame, r2 counts.

      pin  p0, set
      pull r5              ; Te
      mov  r6, r5
      shri r6, 1
      csrw baud, r5        ; one tick per half bit
      ldi  r0, 0x02
      ldih r0, 0x02        ; fabctl: line = element 1, hold = element 0 (on): 802.3 Manchester
      csrw fabctl, r0

send: pull r1
      ; DALI sends the most significant bit first. The shifter goes LSB first here, because with
      ; MSB first it picks each bit by the word length in TXCFG at that moment, and TXCFG changes
      ; between the start bit and the frame; so the frame is reversed first.
      ldi  r2, 0
      ldi  r3, 16
rev:  shli r1, 1           ; C = the next bit, from the top
      rrc  r2, 1           ; in at the top of r2: the first one ends up in bit 0
      djnz r3, rev
      ben  1               ; restart the bit engine, so the Manchester phase starts on a bit
      ldi  r0, 0x00
      ldih r0, 0x0c        ; txcfg: 1 bit, LSB first, pin 0, through the fabric, idle 1
      csrw txcfg, r0
      ldi  r0, 1
      tx   r0              ; the start bit
      wait event tx_empty  ; it is in the shifter
      ldi  r0, 0x0f
      ldih r0, 0x0c        ; then 16 bits
      csrw txcfg, r0
      tx   r2
      wait event tx_empty
wtx:  csrr r0, bstat       ; wait for the last bit to go out
      tstb r0, 1
      j    z, wtx
      wait event tick      ; its second half ends here and the line goes to the idle level
      ben  0               ; the pin keeps it (high, released) until the next frame

      ; listen: control gear answers between 7 and 22 Te after the forward frame
      ldi  r2, 24
      csrw tmo, r5         ; each wait gives up after Te
lw:   wait pin p19, 0
      j    nt, edge
      djnz r2, lw
      csrwi tmo, 0
      ldi  r0, 0
      ldih r0, 0x01        ; nobody answered
      push r0
      jmp  send

      ; a start bit began: sample the second half of each of 9 bits, 1.5 Te into the start bit and
      ; then every 2 Te
edge: csrwi tmo, 0
      csrr r7, time_lo
      add  r7, r5
      add  r7, r6
      wait time r7
      pin  p19, sample
      j    nc, bad         ; a start bit is low then high
      ldi  r1, 0
      ldi  r2, 8
rb:   add  r7, r5
      wait time r7
      add  r7, r5
      wait time r7
      pin  p19, sample     ; the second half is the bit
      rlc  r1, 1
      djnz r2, rb
      ldi  r0, 0xff
      and  r1, r0
      push r1
      ; let the stop bits and the bus settle before the next forward frame
      add  r7, r5
      wait time r7
      add  r7, r5
      wait time r7
      jmp  send
bad:  ldi  r0, 0
      ldih r0, 0x02
      push r0
      jmp  send
