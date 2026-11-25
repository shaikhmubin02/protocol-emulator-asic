; midi_out.s: MIDI OUT (MIDI 1.0: 31250 baud, 8N1, exactly 1600 cycles a bit at 50 MHz), with
; running status: a status byte equal to the last one sent is left out. Written after the RTL
; freeze: firmware only.
;
; Pin: p8 (uo[0]) to the MIDI OUT driver (1 = idle, current off).
; Host: a channel message is two words, the status byte (0x80 to 0xEF), then data1 | data2 << 8
; (data2 is ignored for program change 0xCn and channel pressure 0xDn, which have one data byte).
; A real-time byte (0xF8 to 0xFF) is one word and goes out at once; it does not change the
; running status.

      ldi  r0, 0x09
      ldih r0, 0x09        ; txcfg: 10 bits, LSB first, pin 8, idle high
      csrw txcfg, r0
      ldi  r0, 0x40
      ldih r0, 0x06        ; 1600 cycles a bit
      csrw baud, r0
      pin  p8, set
      ben  1
      ldi  r7, 0           ; running status: nothing sent yet

next: pull r1              ; status byte
      mov  r0, r1
      ldi  r2, 0xf8
      cmp  r0, r2
      j    c, chan         ; below 0xF8: a channel message
      call byte            ; real time: just the byte
      jmp  next
chan: pull r3              ; data1 | data2 << 8
      cmp  r1, r7
      j    z, data         ; same status as the last one: leave it out
      mov  r7, r1
      mov  r0, r1
      call byte
data: mov  r0, r3
      ldi  r2, 0x7f
      and  r0, r2
      call byte            ; data1
      mov  r0, r1
      ldi  r2, 0xe0
      and  r0, r2
      ldi  r2, 0xc0
      cmp  r0, r2
      j    z, next         ; 0xCn and 0xDn have one data byte
      mov  r0, r3
      shri r0, 8
      ldi  r2, 0x7f
      and  r0, r2
      call byte            ; data2
      jmp  next

; send the byte in r0: start bit, 8 bits, stop bit
byte: shli r0, 1
      ldi  r2, 0
      ldih r2, 0x02        ; stop bit
      or   r0, r2
      tx   r0
      ret
