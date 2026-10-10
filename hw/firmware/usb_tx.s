; USB low-speed packet transmitter (1.5 Mbit/s) on D+ = p4 (uio[4]) and D- = p5 (uio[5]).
; Clock 48 MHz: 32 cycles a bit.
;
; The chip does the line coding itself: SYNC, NRZI, bit stuffing, the CRC-16 of data packets and
; the end of packet. Both lines change together, from one OUTG at each bit boundary, and the
; boundaries come from the cycle counter.
;
; Host words:
;   0x1pp  start a packet: SYNC, then PID pp
;   0x2dd  data byte dd (counted in the CRC-16)
;   0x3dd  byte dd sent as is (no CRC), e.g. the address/endpoint/CRC-5 bytes of a token
;   0x400  end a data packet: send the CRC-16, then the end of packet
;   0x500  end any other packet: just the end of packet
; Words for one packet have to arrive about as fast as the bits go out (one word per byte).
;
; Line states, as OUTG writes them (bit 0 = D+, bit 1 = D-): J = 2 (idle), K = 1, SE0 = 0.
;
; r0 bits to send   r1 line state   r2 1s in a row   r3 bit count   r4 CRC
; r5 host word      r6 scratch      r7 time of the next bit boundary

.equ BIT 32

      csrwi group0, 0x24   ; group 0: 2 pins from p4
      pin  p4, hiz
      pin  p5, hiz

; Between two bytes of a packet there's one bit time for all of this, so data bytes are
; checked first, then the other commands that continue a packet, and the byte isn't masked
; (only its low 8 bits get sent).
loop: pull r5
      mov  r6, r5
      shri r6, 8           ; command
      mov  r0, r5          ; byte in [7:0]
      cmpi r6, 2
      j    z, c_data
      cmpi r6, 4
      j    z, c_end_crc
      cmpi r6, 3
      j    z, c_raw
      cmpi r6, 5
      j    z, c_end
      cmpi r6, 1
      j    z, c_start      ; starts its own timing, so it can come last
      jmp  loop

c_start:
      csrr r7, time_lo
      addi r7, BIT
      addi r7, BIT         ; first boundary 2 bits ahead: the gap between packets
      ldi  r1, 2           ; the line is at J
      ldi  r2, 0
      ldi  r4, 0xff
      ldih r4, 0xff        ; CRC-16 starts at all ones
      mov  r5, r0          ; keep the PID (r6 is used while sending)
      ldi  r0, 0x80        ; SYNC: KJKJKJKK
      call byte
      mov  r0, r5
      call byte
      jmp  loop

c_data:
      call byte_crc
      jmp  loop

c_raw:
      call byte
      jmp  loop

c_end_crc:
      ldi  r0, 0xff
      ldih r0, 0xff
      xor  r0, r4          ; the CRC goes out inverted, LSB first
      call byte
      call byte
c_end:
      ldi  r6, 0           ; SE0 for two bits
      wait time r7
      outg 0, r6
      addi r7, BIT
      addi r7, BIT
      ldi  r6, 2           ; then J for one bit
      wait time r7
      outg 0, r6
      addi r7, BIT
      wait time r7
      pin  p4, hiz         ; and let go: the pull-up on D- holds J
      pin  p5, hiz
      jmp  loop

; send r0[7:0], LSB first, without touching the CRC (shifts r0 right by 8)
byte: ldi  r3, 8
by1:  shri r0, 1           ; C = bit
      call sbit
      djnz r3, by1
      ret

; the same, counting each bit into the CRC-16 (x^16 + x^15 + x^2 + 1, LSB first)
byte_crc:
      ldi  r3, 8
bc1:  mov  r6, r0
      xor  r6, r4          ; bit 0 = data bit xor CRC bit 0
      shri r4, 1
      tstb r6, 0
      j    z, bc2
      ldi  r6, 0x01
      ldih r6, 0xa0
      xor  r4, r6
bc2:  shri r0, 1
      call sbit
      djnz r3, bc1
      ret

; send the bit in C at the next boundary: NRZI (a 0 changes the line, a 1 keeps it), and after
; six 1s in a row an extra 0
sbit: j    c, sb1
      ldi  r6, 3
      xor  r1, r6
      ldi  r2, 0
      jmp  sb2
sb1:  addi r2, 1
sb2:  wait time r7
      outg 0, r1
      addi r7, BIT
      cmpi r2, 6
      j    nz, sb3
      ldi  r6, 3           ; stuffed 0
      xor  r1, r6
      ldi  r2, 0
      wait time r7
      outg 0, r1
      addi r7, BIT
sb3:  ret
