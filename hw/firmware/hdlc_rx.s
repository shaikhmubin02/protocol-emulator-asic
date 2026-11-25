; hdlc_rx.s: HDLC / SDLC frames (ISO 13239, RFC 1662) at 250 kbit/s with a 50 MHz clock, NRZ.
; Written after the RTL freeze: firmware and a fabric configuration only.
;
; The fabric (hdlc_rx) drops the 0 that follows five 1s and raises its flag output on a sixth 1
; (a flag, or an abort). The program takes one bit at a time, so it can start bytes right after
; a flag. The CRC unit runs over the kept bits; the host sets the polynomial to 0x1021 << 16 and
; the start value to 0xFFFF << 16. A good frame, FCS included, leaves 0x1D0F in the top half of the
; CRC register (the FCS-16 residue 0xF0B8 seen in transmission order).
;
; Pin: p19 (ui[3]). The host gets every byte of a frame, FCS included, as it comes in, then a word
; 0x8000 + the byte count, plus 0x4000 if the FCS is right. A flag with no bytes before it is not
; reported.
;
; Registers: r1 the byte being built (bits come in LSB first, so they shift in from the top), r2
; bits in it, r3 the CRC at the last byte boundary, r4 bytes in the frame, r5 and r0 scratch.

      ldi  r0, 200
      csrw baud, r0
      ldi  r0, 0xe0
      ldih r0, 0x0b        ; txcfg: TX pin 31 (no pad); this engine only receives
      csrw txcfg, r0
      ldi  r0, 0x60
      ldih r0, 0x0e        ; rxcfg: 1 bit, pin 19, through the fabric, re-align on every edge
      csrw rxcfg, r0
      csrwi fabctl, 0      ; rx bit = element 0
      ldi  r0, 0xf6        ; fabctl2: drop = element 6 (on), flag = element 7
      csrw fabctl2, r0
      csrwi crcctl, 3      ; CRC on, fed by the kept RX bits
      ben  1

; hunt for a flag
hunt: rx   r0
      j    fab_flag, frame
      jmp  hunt

; a flag: a frame (perhaps empty) starts with the next kept bit
frame: crci
      ldi  r1, 0
      ldi  r2, 0
      ldi  r4, 0
      csrr r3, crc_hi
bit:  rx   r0
      j    fab_flag, end   ; a sixth 1: the closing flag
      shri r1, 1
      rrc  r0, 1           ; C = the bit
      j    nc, zero
      ldi  r0, 0x80
      or   r1, r0
zero: addi r2, 1
      cmpi r2, 8
      j    nz, bit
      push r1              ; a whole byte
      addi r4, 1
      csrr r3, crc_hi      ; the CRC so far, at this byte boundary
      ldi  r1, 0
      ldi  r2, 0
      jmp  bit

; the closing flag: the bits since the last byte boundary are its own (0 and five 1s)
end:  tst  r4, r4
      j    z, frame        ; just another flag
      ldi  r0, 0
      ldih r0, 0x80
      or   r4, r0          ; 0x8000 + byte count
      ldi  r0, 0x0f
      ldih r0, 0x1d
      cmp  r3, r0          ; FCS residue
      j    nz, bad
      ldi  r0, 0
      ldih r0, 0x40
      or   r4, r0
bad:  push r4
      jmp  frame           ; this flag can also open the next frame
