; lin_commander.s: LIN 2.2A commander (ISO 17987): sends frame headers and either the response
; or reads it back from a responder. Written after the RTL freeze: firmware only.
;
; Header: a break of 13 dominant bits and a delimiter of one recessive bit, both the bit engine's
; idle level held for whole bit times (as in dmx_tx.s), then the sync byte 0x55 and the protected
; identifier, whose two parity bits the program works out. Response: 1 to 8 data bytes and the
; checksum, the inverted 8-bit sum with carry over the data (classic) or the identifier and the
; data (enhanced). LIN is one wire, so the program reads every byte it sends back off the bus and
; compares, which is how a LIN node finds a bit error.
;
; Pins: p0 (uio[0]) to the transceiver's TXD (1 = recessive; with a pull-up the bus is left alone
; until the program runs); p19 (ui[3]) from its RXD.
; Host: first the bit time, whole cycles and then the 1/256 fraction (2604 and 43 for 19200 bit/s
; at 50 MHz). Then per frame a word: ID [5:0], data bytes - 1 [10:8], 1 << 12 if the commander
; sends the response, 1 << 13 for the classic checksum; then those data bytes if it sends them.
; The program answers with the data bytes of a response it received, then 0x8000 | status:
; 1 checksum wrong, 2 the response did not come (or not all of it, or a stop bit was dominant),
; 4 a byte read back from the bus was not the byte sent.
;
; Registers: r1 the frame word, r4 the identifier, r5 bytes left, r6 the sum, r7 status,
; r3 the word expected back.

      pin  p0, set         ; recessive until the bit engine takes the pin
      pull r0
      csrw baud, r0
      pull r0
      csrw baudf, r0
      ldi  r0, 0x69
      ldih r0, 0x12        ; rxcfg: 10 bits, LSB first, pin 19, start on a falling edge
      csrw rxcfg, r0
      ldi  r0, 0x09
      ldih r0, 0x08        ; txcfg: 10 bits, LSB first, pin 0, idle 1 (recessive)
      csrw txcfg, r0
      ben  1

frame: pull r1
      mov  r0, r1
      ldi  r2, 0x3f
      and  r0, r2
      call pidof
      mov  r4, r0
      mov  r6, r4          ; the enhanced checksum counts the identifier
      tstb r1, 13
      j    z, sum
      ldi  r6, 0           ; the classic one does not
sum:  ldi  r7, 0
drain: j   rx_ready, dr    ; nothing left over from the last frame
      jmp  idle
dr:   rx   r0
      jmp  drain
idle: csrr r0, bstat       ; the last stop bit of the last frame is out
      tstb r0, 1
      j    z, idle

      ldi  r0, 0x09
      ldih r0, 0x00        ; idle level dominant: the break starts on the next tick
      csrw txcfg, r0
      ldi  r2, 13
brk:  wait event tick
      djnz r2, brk
      ldih r0, 0x08        ; recessive: the delimiter starts on the next tick
      csrw txcfg, r0
      wait event tick      ; one bit of it
      ldi  r0, 0xaa
      ldih r0, 0x02        ; 0x55 with its start and stop bits
      tx   r0
      ldi  r3, 0
      call back            ; the break reads back as a word of zeros
      mov  r0, r4
      call frm
      mov  r5, r3
      tx   r5              ; the identifier, right after the sync byte
      ldi  r3, 0xaa
      ldih r3, 0x02
      call back
      mov  r3, r5
      call back

      mov  r5, r1
      shri r5, 8
      ldi  r2, 7
      and  r5, r2
      addi r5, 1           ; data bytes
      tstb r1, 12
      j    z, recv
send: pull r0
      add  r6, r0
      call out
      djnz r5, send
      call fold
      call out             ; the checksum
      jmp  done

recv: call get
      j    t, late
      tstb r0, 9
      j    z, late         ; a dominant stop bit
      shri r0, 1
      ldi  r2, 0xff
      and  r0, r2
      push r0
      add  r6, r0
      djnz r5, recv
      call get             ; the checksum
      j    t, late
      tstb r0, 9
      j    z, late
      shri r0, 1
      ldi  r2, 0xff
      and  r0, r2
      mov  r3, r0
      call fold
      cmp  r0, r3
      j    z, done
      ldi  r2, 1
      or   r7, r2
      jmp  done
late: ldi  r2, 2
      or   r7, r2
done: ldi  r0, 0
      ldih r0, 0x80
      or   r0, r7
      push r0
      jmp  frame

; out: send the byte in r0 and check it on the bus
out:  call frm
      tx   r3
; back: read a word off the bus; status |= 4 unless it is r3
back: call get
      j    t, bad
      cmp  r0, r3
      j    z, bk
bad:  ldi  r2, 4
      or   r7, r2
bk:   ret

; frm: r3 = the byte in r0 with a start bit (0) below and a stop bit (1) above
frm:  mov  r3, r0
      shli r3, 1
      ldi  r2, 0
      ldih r2, 0x02
      or   r3, r2
      ret

; get: the next word off the bus into r0; T = 1 if none came within 65535 cycles
get:  ldi  r0, 0xff
      ldih r0, 0xff
      csrw tmo, r0
      rx   r0
      csrwi tmo, 0
      ret

; fold: r0 = the checksum of the sum in r6: fold the carries back in twice, then invert
fold: ldi  r2, 0xff
      mov  r0, r6
      shri r0, 8
      and  r6, r2
      add  r6, r0
      mov  r0, r6
      shri r0, 8
      and  r6, r2
      add  r6, r0
      mov  r0, r6
      xor  r0, r2
      ret

; pidof: r0 = the protected identifier of the ID in r0: P0 = ID0 ^ ID1 ^ ID2 ^ ID4 in bit 6,
; P1 = not (ID1 ^ ID3 ^ ID4 ^ ID5) in bit 7. Uses r2, r3.
pidof: mov r3, r0
      ldi  r2, 0x17
      and  r0, r2
      call par
      shli r0, 6
      or   r3, r0
      mov  r0, r3
      ldi  r2, 0x3a
      and  r0, r2
      call par
      ldi  r2, 1
      xor  r0, r2
      shli r0, 7
      or   r0, r3
      ret

; par: r0 = the parity of the bits of r0 (8 bits or fewer). Uses r2.
par:  mov  r2, r0
      shri r2, 4
      xor  r0, r2
      mov  r2, r0
      shri r2, 2
      xor  r0, r2
      mov  r2, r0
      shri r2, 1
      xor  r0, r2
      ldi  r2, 1
      and  r0, r2
      ret
