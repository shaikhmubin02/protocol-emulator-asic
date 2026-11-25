; dmx_tx.s: DMX512 transmitter (ANSI E1.11): 250 kbit/s, 4 us bits. Written after the RTL
; freeze: firmware only.
;
; A packet is a break (the line low), the mark after break (MAB, high), then 1 to 513 slots: the
; start code and up to 512 channels, each a start bit, 8 data bits LSB first and two stop bits.
; The bit engine's shifter sends the slots back to back, or with a mark between them made of
; more stop bits in the same word. The break and the MAB are the shifter's
; idle level, first low and then high, held for a whole number of bit times counted on the TX
; ticks, so every edge of every packet is on the same bit clock.
;
; Pin: p8 (uo[0]) to the RS-485 driver's input (1 = mark).
; Host: first the bit time in cycles (200 at 50 MHz), the break in bits (23 or more for E1.11's
; 92 us; 44 = 176 us is typical), the MAB in bits (3 or more for 12 us) and the mark between
; slots in bits (0 to 5; 0 = back to back). Then per packet the number of slots N (1 to 513, the
; start code counts) and N words, one slot each, start code first.
;
; Registers: r5 break bits, r6 MAB bits, r4 TXCFG for slots, r7 the stop bits of a slot word,
; r3 slots left, r1 the slot, r2 counts.

      pin  p8, set         ; mark until the first break
      pull r0
      csrw baud, r0
      pull r5
      pull r6
      pull r2              ; mark between slots: that many more stop bits in each slot word
      ldi  r7, 3           ; two stop bits
      ldi  r4, 10          ; in an 11-bit word
      tst  r2, r2
      j    z, cfg
stop: shli r7, 1
      addi r7, 1
      addi r4, 1
      djnz r2, stop
cfg:  shli r7, 9           ; above the start bit and the 8 data bits
      ldih r4, 0x09        ; txcfg: LSB first, pin 8, idle high (mark)
      csrw txcfg, r4
      ben  1

packet: pull r3            ; slots in this packet
      pull r1              ; the start code, here before the break so the MAB ends on time
idle: csrr r0, bstat       ; wait until the last bit of the last packet is on the line
      tstb r0, 1
      j    z, idle
      mov  r0, r4
      ldih r0, 0x01        ; idle level low: the break starts on the next tick
      csrw txcfg, r0
      mov  r2, r5
brk:  wait event tick
      djnz r2, brk
      csrw txcfg, r4       ; idle level high: the MAB starts on the next tick
      mov  r2, r6
mab:  wait event tick
      djnz r2, mab
slot: shli r1, 1           ; the start bit (0) below the data
      or   r1, r7          ; the stop bits above it
      tx   r1              ; loaded on the next tick, right after the MAB or the last slot
      djnz r3, more
      jmp  packet
more: pull r1
      jmp  slot
