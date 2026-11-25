; lin_responder.s: LIN 2.2A responder (ISO 17987) that syncs its bit time to the commander's
; sync byte, as a node without a crystal must. Written after the RTL freeze: firmware only.
;
; Between frames the bit engine is off and the program times the bus itself. A break is the bus
; dominant for 11 of our own bit times or more. The sync byte 0x55 that follows has falling edges
; at bits 0, 2, 4, 6 and 8: CAP takes the time of the first and of the last, 8 bit times apart,
; so BAUD = that / 8 and BAUDF = the remainder in 1/256 cycles. Then the bit engine starts on the
; commander's bit time and takes the identifier in. LIN lets a responder's clock be 14% off
; before this sync; the program takes a sync byte of 6.5 to 9.5 of its own bit times.
;
; Pins: p0 (uio[0]) to the transceiver's TXD (1 = recessive); p19 (ui[3]) from its RXD.
; Host: first our own bit time in cycles (2604 for 19200 bit/s at 50 MHz). Per header the
; program sends two words: the sync byte's 8 bit times in cycles, then 0x100 | identifier,
; 0x200 | identifier if the parity bits are wrong (the frame is ignored), or 0x400 if the sync
; byte was out of range (ignored). After 0x100 | identifier the host answers: 0 = not ours; else
; the number of data bytes (1 to 8), | 0x100 if we send the response, then those bytes, | 0x200
; for the classic checksum. The program then answers as lin_commander.s does: the data bytes it
; received, then 0x8000 | status (1 checksum wrong, 2 not all in time, 4 a bit error).
;
; Registers: r7 our bit time, r1 the host's answer, r5 bytes left, r6 the sum, r4 status,
; r3 the word expected back.

      pin  p0, set         ; recessive
      pull r7
      csrwi capcfg, 0x33   ; CAP = the time of the last falling edge on p19
      ldi  r0, 0x69
      ldih r0, 0x12        ; rxcfg: 10 bits, LSB first, pin 19, start on a falling edge
      csrw rxcfg, r0
      ldi  r0, 0x09
      ldih r0, 0x08        ; txcfg: 10 bits, LSB first, pin 0, idle 1 (recessive)
      csrw txcfg, r0

hunt: ben  0               ; the pin stays recessive
      csrwi tmo, 0
      wait pin p19, 0
      mov  r2, r7          ; 11 bit times
      shli r2, 3
      mov  r0, r7
      shli r0, 1
      add  r2, r0
      add  r2, r7
      csrw tmo, r2
      wait pin p19, 1
      j    nt, hunt        ; recessive again sooner: not a break
      csrwi tmo, 0
      wait pin p19, 1      ; the delimiter
      wait pin p19, 0      ; the sync byte's start bit
      csrr r3, cap
      ldi  r2, 4
sync: wait pin p19, 1
      wait pin p19, 0      ; the falling edges at bits 2, 4, 6 and 8
      djnz r2, sync
      csrr r4, cap
      sub  r4, r3          ; 8 bit times
      push r4
      mov  r2, r7          ; 6.5 of our bit times or more
      shli r2, 1
      mov  r0, r7
      shli r0, 2
      add  r2, r0
      mov  r0, r7
      shri r0, 1
      add  r2, r0
      cmp  r4, r2
      j    c, bsync
      add  r2, r7
      add  r2, r7
      add  r2, r7          ; 9.5 or fewer
      cmp  r2, r4
      j    c, bsync
      mov  r0, r4
      shri r0, 3
      csrw baud, r0
      ldi  r2, 7
      and  r4, r2
      shli r4, 5
      csrw baudf, r4       ; the commander's bit time, to 1/256 of a cycle
      ben  1               ; the RX engine takes the identifier in from its start bit

      call get
      j    t, hunt
      tstb r0, 9
      j    z, hunt
      shri r0, 1
      ldi  r2, 0xff
      and  r0, r2
      mov  r5, r0
      ldi  r2, 0x3f
      and  r0, r2
      call pidof
      cmp  r0, r5
      j    z, pid
      ldi  r0, 0
      ldih r0, 0x02
      or   r0, r5
      push r0              ; parity wrong
      jmp  hunt
bsync: ldi r0, 0
      ldih r0, 0x04
      push r0
      jmp  hunt

pid:  ldi  r0, 0
      ldih r0, 0x01
      or   r0, r5
      push r0
      pull r1              ; the host's answer
      tst  r1, r1
      j    z, hunt
      mov  r6, r5          ; the enhanced checksum counts the identifier
      tstb r1, 9
      j    z, sum
      ldi  r6, 0
sum:  ldi  r4, 0
      mov  r5, r1
      ldi  r2, 0x0f
      and  r5, r2          ; data bytes
      tstb r1, 8
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
      j    z, late
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
      or   r4, r2
      jmp  done
late: ldi  r2, 2
      or   r4, r2
done: ldi  r0, 0
      ldih r0, 0x80
      or   r0, r4
      push r0
      jmp  hunt

; out: send the byte in r0 and check it on the bus
out:  call frm
      tx   r3
; back: read a word off the bus; status |= 4 unless it is r3
back: call get
      j    t, bad
      cmp  r0, r3
      j    z, bk
bad:  ldi  r2, 4
      or   r4, r2
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

; pidof: r0 = the protected identifier of the ID in r0. Uses r2, r3.
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
