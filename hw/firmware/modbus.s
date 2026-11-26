; modbus.s: a Modbus RTU server (slave) link layer: framing, CRC-16, address filtering and the
; RS-485 turnaround; the host holds the registers and answers each request. Written after the RTL
; freeze: firmware only.
;
; Characters are 8E1 (start, 8 bits LSB first, even parity, stop). A frame ends when the line has
; been silent for 3.5 character times; it is the address, the function code and data, then the
; CRC-16 (polynomial 0xA001 reflected, start 0xFFFF, low byte first). The CRC over the whole
; frame, its own two bytes included, is 0 when the frame is right.
;
; Pins: p8 (uo[0]) TX to the RS-485 driver, p9 (uo[1]) driver enable (1 only while sending; the
; transceiver's receiver is off then, so the program does not hear itself), p19 (ui[3]) RX.
; Host: first the bit time (whole cycles, then the 1/256 fraction; 4800 bit/s or faster) and the
; server address. For a frame to this address or a broadcast (address 0) the program sends the
; bytes after the address as they come, 0x100 | byte, CRC bytes left out, then 0x8000 | how
; many (| 0x4000 for a broadcast) if the CRC and every character were right, or 0x2000 | how
; many if not (the host drops the bytes). After 0x8000 without 0x4000 the host answers: the
; number of reply bytes from the function code on, then those bytes (0: no reply). The program
; sends the address, them, and the CRC.
;
; Registers: r7 the address, r5 the CRC, r3 bytes after the address | flags, r1/r2 the last two
; bytes (not passed on yet: they may be the CRC), r0/r4/r6 scratch.

      pin  p9, clr         ; driver off
      pin  p8, set
      pull r0
      csrw baud, r0
      pull r0
      csrw baudf, r0
      pull r7
      ldi  r0, 0x6a
      ldih r0, 0x12        ; rxcfg: 11 bits, LSB first, pin 19, start on a falling edge
      csrw rxcfg, r0
      ldi  r0, 0x0a
      ldih r0, 0x09        ; txcfg: 11 bits, LSB first, pin 8, idle 1
      csrw txcfg, r0
      ben  1

frame: csrwi tmo, 0
      rx   r0              ; the first character: the address
      call chr
      j    nz, skip
      ldi  r3, 0
      tst  r0, r0
      j    z, bcast
      cmp  r0, r7
      j    nz, skip
      jmp  mine
bcast: ldih r3, 0x40
mine: ldi  r5, 0xff
      ldih r5, 0xff
      call crc
      csrr r6, baud        ; half a character: 5.5 bit times
      mov  r0, r6
      shli r0, 2
      add  r0, r6
      shri r6, 1
      add  r6, r0
      csrw tmo, r6
next: ldi  r4, 7           ; 3.5 characters of silence ends the frame
nw:   rx   r0
      j    nt, got
      djnz r4, nw
      jmp  end
got:  call chr
      j    z, gd
      ldi  r4, 0
      ldih r4, 0x20
      or   r3, r4          ; a bad character: the frame will be dropped
gd:   mov  r6, r0
      call crc
      mov  r4, r3          ; pass on the byte from two places back
      ldi  r0, 0xff
      ldih r0, 0x0f
      and  r4, r0
      cmpi r4, 2
      j    c, hold
      ldi  r4, 0
      ldih r4, 0x01
      or   r4, r2
      push r4
hold: mov  r2, r1
      mov  r1, r6
      addi r3, 1
      jmp  next

end:  csrwi tmo, 0
      subi r3, 2           ; the CRC bytes do not count
      tst  r5, r5
      j    z, e1
      ldi  r4, 0
      ldih r4, 0x20
      or   r3, r4
e1:   tstb r3, 13
      j    nz, drop
      ldi  r4, 0
      ldih r4, 0x80
      or   r4, r3
      push r4
      tstb r3, 14
      j    nz, frame       ; broadcast: no reply
      pull r3              ; reply length
      tst  r3, r3
      j    z, frame
      ldi  r4, 8           ; the silence is measured from the last character's middle of its
dl:   wait event tick      ; stop bit: 8 bits more keep the reply clear of 3.5 characters
      djnz r4, dl
      pin  p9, set         ; driver on
      ldi  r5, 0xff
      ldih r5, 0xff
      mov  r0, r7
      call put
rl:   pull r0
      call put
      djnz r3, rl
      mov  r0, r5
      ldi  r4, 0xff
      and  r0, r4
      call send            ; CRC low byte
      mov  r0, r5
      shri r0, 8
      call send            ; CRC high byte
wd:   csrr r0, bstat       ; the last stop bit
      tstb r0, 1
      j    z, wd
      wait event tick
      pin  p9, clr         ; driver off
      jmp  frame
drop: push r3
      jmp  frame

; skip: a frame for another server: let it pass, then 3.5 characters of silence
skip: csrr r6, baud
      mov  r0, r6
      shli r0, 2
      add  r0, r6
      shri r6, 1
      add  r6, r0
      csrw tmo, r6
sk:   ldi  r4, 7
sk1:  rx   r0
      j    nt, sk
      djnz r4, sk1
      jmp  frame

; chr: r0 = the received character's byte; Z = 1 if start, stop and even parity were right.
; Uses r4, r6.
chr:  mov  r6, r0
      shri r6, 1
      ldi  r4, 0xff
      ldih r4, 0x01
      and  r6, r4          ; the 8 bits and the parity bit
      mov  r4, r6
      shri r4, 8
      xor  r6, r4
      mov  r4, r6
      shri r4, 4
      xor  r6, r4
      mov  r4, r6
      shri r4, 2
      xor  r6, r4
      mov  r4, r6
      shri r4, 1
      xor  r6, r4
      ldi  r4, 1
      and  r6, r4          ; 1 if the parity was odd
      tstb r0, 10
      j    nz, c1
      ldi  r6, 1           ; stop bit 0
c1:   tstb r0, 0
      j    z, c2
      ldi  r6, 1           ; start bit 1
c2:   shri r0, 1
      ldi  r4, 0xff
      and  r0, r4
      tst  r6, r6
      ret

; crc: r5 = the CRC-16/MODBUS of r5 and the byte in r0. Uses r0, r4.
crc:  xor  r5, r0
      ldi  r4, 8
cl:   shri r5, 1
      j    nc, cn
      ldi  r0, 0x01
      ldih r0, 0xa0
      xor  r5, r0
cn:   djnz r4, cl
      ret

; put: send the byte in r0 and add it to the CRC. Uses r0, r1, r4, r6.
put:  mov  r1, r0
      call crc
      mov  r0, r1
; send: the byte in r0 as an 8E1 character. Uses r4, r6.
send: mov  r6, r0
      mov  r4, r6
      shri r4, 4
      xor  r6, r4
      mov  r4, r6
      shri r4, 2
      xor  r6, r4
      mov  r4, r6
      shri r4, 1
      xor  r6, r4
      ldi  r4, 1
      and  r6, r4          ; even parity bit
      shli r6, 9
      shli r0, 1
      or   r0, r6
      ldi  r4, 0
      ldih r4, 0x04
      or   r0, r4          ; stop bit
      tx   r0
      ret
