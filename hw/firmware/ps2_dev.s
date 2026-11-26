; ps2_dev.s: a PS/2 device (a keyboard, to the computer it is plugged into). Written after the
; RTL freeze: firmware only.
;
; Two open-drain lines, CLK and DATA, pulled high; the device makes the clock (12.5 kHz here).
; Device to host: start (0), 8 bits LSB first, odd parity, stop (1); the device changes DATA in
; the middle of CLK high, the host reads it as CLK falls. The host can hold CLK low at any time
; to stop the device (inhibit); a byte cut off that way is sent again later. Host to device:
; the host holds CLK low, pulls DATA low and lets CLK go; the device then clocks in 8 bits,
; parity and stop, reading DATA while CLK is high, and acknowledges by pulling DATA low for one
; more clock.
; As a keyboard it answers the host's commands itself: FF (reset) with FA and AA (self test
; passed), F2 (read ID) with FA AB 83, EE (echo) with EE, a byte with bad parity with FE
; (resend), anything else with FA.
;
; Pins: p0 (uio[0]) CLK, p1 (uio[1]) DATA, open drain.
; Host: first a quarter of the clock period in cycles (1000: 80 us, 12.5 kHz at 50 MHz). Then any
; byte to send (scan codes). The program sends 0x100 | byte for every byte the computer sent.
;
; Registers: r6 a quarter period, r7 the deadline, r5 the byte waiting to go (0x100 | byte, or
; 0), r1 the byte, r2 bits, r3 counts.

      pin  p0, hiz
      pin  p1, hiz
      pull r6
      ldi  r5, 0

main: pin  p0, sample
      j    nc, main        ; CLK held low: inhibited
      pin  p1, sample
      j    nc, rx          ; DATA low while CLK is high: the host wants to send
      tst  r5, r5
      j    nz, tx
      j    mbx_data, take
      jmp  main
take: pull r5
      ldi  r0, 0
      ldih r0, 0x01
      or   r5, r0
tx:   csrr r7, time_lo     ; the bus must stay idle for 3 quarters (60 us) first
      add  r7, r6
      add  r7, r6
      add  r7, r6
idl:  pin  p0, sample
      j    nc, main
      pin  p1, sample
      j    nc, main
      csrr r0, time_lo
      sub  r0, r7
      tstb r0, 15
      j    nz, idl
      mov  r1, r5
      call send
      tst  r0, r0
      j    z, main         ; cut off: r5 still holds it
      ldi  r5, 0
      jmp  main

; send: the byte in r1 to the host. r0 = 1 if it all went, 0 if the host cut it off.
send: ldi  r0, 0xff
      and  r1, r0
      mov  r2, r1          ; odd parity
      call par
      ldi  r0, 1
      xor  r3, r0          ; (par leaves the parity of r2 in r3)
      shli r3, 9
      shli r2, 1           ; start bit 0
      or   r2, r3
      ldi  r0, 0
      ldih r0, 0x04        ; stop bit 1
      or   r2, r0
      ldi  r3, 11
      csrr r7, time_lo
sb:   shri r2, 1
      j    c, s1
      pin  p1, clr
      jmp  s2
s1:   pin  p1, hiz
s2:   add  r7, r6
      wait time r7         ; the middle of CLK high
      pin  p0, clr         ; CLK falls: the host reads the bit
      add  r7, r6
      wait time r7
      add  r7, r6
      wait time r7
      pin  p0, hiz
      add  r7, r6
      wait time r7
      pin  p0, sample
      j    nc, cut         ; the host holds CLK low
      djnz r3, sb
      pin  p1, hiz
      ldi  r0, 1
      ret
cut:  pin  p1, hiz
      ldi  r0, 0
      ret

; rx: the host sends a byte; clock it in, acknowledge, answer
rx:   ldi  r3, 10          ; 8 bits, parity, stop
      csrr r7, time_lo
      add  r7, r6
      wait time r7
rb:   pin  p0, clr
      add  r7, r6
      wait time r7
      add  r7, r6
      wait time r7
      pin  p0, hiz
      add  r7, r6
      wait time r7
      pin  p1, sample      ; read while CLK is high
      rrc  r1, 1           ; from the top: data ends in bits 13:6, parity 14, stop 15
      add  r7, r6
      wait time r7
      djnz r3, rb
      pin  p1, clr         ; acknowledge: DATA low for one more clock
      pin  p0, clr
      add  r7, r6
      wait time r7
      add  r7, r6
      wait time r7
      pin  p0, hiz
      add  r7, r6
      wait time r7
      pin  p1, hiz
      add  r7, r6
      wait time r7
      mov  r2, r1          ; parity over the data and the parity bit must be odd
      shri r2, 6
      ldi  r0, 0xff
      ldih r0, 0x01
      and  r2, r0
      call par
      shri r1, 6
      ldi  r0, 0xff
      and  r1, r0          ; the byte
      ldi  r0, 0
      ldih r0, 0x01
      or   r0, r1
      push r0
      tst  r3, r3
      j    nz, ok
      ldi  r1, 0xfe        ; parity wrong: resend
      jmp  one
ok:   ldi  r0, 0xee
      cmp  r1, r0
      j    z, one          ; echo
      ldi  r0, 0xff
      cmp  r1, r0
      j    z, reset
      ldi  r0, 0xf2
      cmp  r1, r0
      j    z, ident
      ldi  r1, 0xfa
one:  call resend
      jmp  main
reset: ldi r1, 0xfa
      call resend
      ldi  r1, 0xaa        ; self test passed
      call resend
      jmp  main
ident: ldi r1, 0xfa
      call resend
      ldi  r1, 0xab
      call resend
      ldi  r1, 0x83
      call resend
      jmp  main

; resend: send r1 until it all goes, waiting for an idle bus each time
resend: mov r4, r1
rs1:  pin  p0, sample
      j    nc, rs1
      csrr r7, time_lo
      add  r7, r6
      add  r7, r6
rs2:  pin  p0, sample
      j    nc, rs1
      pin  p1, sample
      j    nc, rs1
      csrr r0, time_lo
      sub  r0, r7
      tstb r0, 15
      j    nz, rs2
      mov  r1, r4
      call send
      tst  r0, r0
      j    z, rs1
      ret

; par: r3 = the parity of r2's bits. Uses r0, r2.
par:  mov  r3, r2
      mov  r0, r3
      shri r0, 8
      xor  r3, r0
      mov  r0, r3
      shri r0, 4
      xor  r3, r0
      mov  r0, r3
      shri r0, 2
      xor  r3, r0
      mov  r0, r3
      shri r0, 1
      xor  r3, r0
      ldi  r0, 1
      and  r3, r0
      ret
