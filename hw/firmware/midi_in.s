; midi_in.s: MIDI IN (MIDI 1.0: 31250 baud, 8N1, 1600 cycles a bit at 50 MHz) that hands the host
; whole messages. Written after the RTL freeze: firmware only.
;
; - Running status: data bytes with no status byte before them belong to the last channel status.
; - Real-time bytes (0xF8 to 0xFF) can come anywhere, even between the data bytes of another
;   message; they are reported on their own and change nothing else.
; - System common and exclusive bytes (0xF0 to 0xF7) end the running status; they and stray data
;   bytes are reported as they are.
;
; Pin: p19 (ui[3]) from the MIDI IN optocoupler (1 = idle).
; Host gets: a channel message as two words, 0x8000 | status, then data1 | data2 << 8 (data2 = 0
; for 0xCn and 0xDn); any other byte as one word, 0x4000 | byte.
;
; Registers: r4 the running status (0 = none), r5 data bytes still wanted, r6 data1.

      ldi  r0, 0x69
      ldih r0, 0x12        ; rxcfg: 10 bits, LSB first, pin 19, start on a falling edge
      csrw rxcfg, r0
      ldi  r0, 0xe0
      ldih r0, 0x0b        ; txcfg: TX pin 31 (no pad); this engine only receives
      csrw txcfg, r0
      ldi  r0, 0x40
      ldih r0, 0x06
      csrw baud, r0
      ben  1
      ldi  r4, 0

next: rx   r0
      shri r0, 1           ; drop the start bit
      ldi  r1, 0xff
      and  r0, r1          ; the byte
      ldi  r1, 0xf8
      cmp  r0, r1
      j    nc, other       ; real time: report, nothing else changes
      tstb r0, 7
      j    z, data
      ldi  r1, 0xf0
      cmp  r0, r1
      j    nc, common      ; 0xF0 to 0xF7
      mov  r4, r0          ; a channel status
      ldi  r5, 2
      ldi  r1, 0xe0
      and  r1, r0
      ldi  r2, 0xc0
      cmp  r1, r2
      j    nz, next
      ldi  r5, 1           ; 0xCn, 0xDn: one data byte
      jmp  next
common: ldi r4, 0          ; running status ends
      jmp  other

data: tst  r4, r4
      j    z, other        ; no status to belong to
      cmpi r5, 2
      j    nz, second
      mov  r6, r0          ; data1
      ldi  r5, 1
      ; a message with only one data byte is complete now
      mov  r1, r4
      ldi  r2, 0xe0
      and  r1, r2
      ldi  r2, 0xc0
      cmp  r1, r2
      j    nz, next
      ldi  r0, 0
      jmp  emit
second: cmpi r5, 1
      j    nz, other
      ; data2 (or data1 of a one-byte message after running status)
      mov  r1, r4
      ldi  r2, 0xe0
      and  r1, r2
      ldi  r2, 0xc0
      cmp  r1, r2
      j    nz, two
      mov  r6, r0          ; one-byte message under running status: this is its data1
      ldi  r0, 0
      jmp  emit
two:  shli r0, 8           ; data2 in the high byte
emit: or   r0, r6
      ldi  r1, 0
      ldih r1, 0x80
      or   r1, r4
      push r1              ; 0x8000 | status
      push r0              ; data1 | data2 << 8
      ldi  r5, 2           ; ready for the next message under running status
      jmp  next

other: ldi r1, 0
      ldih r1, 0x40
      or   r1, r0
      push r1
      jmp  next
