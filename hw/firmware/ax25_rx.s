; ax25_rx.s: AX.25 frames (packet radio, APRS) from Bell 202 audio: a comparator on the radio's
; audio output gives a square wave, 1200 Hz for a mark, 2200 Hz for a space. Written after the
; RTL freeze: firmware and a fabric configuration.
;
; The program times every edge of the audio with the capture register (both edges): a half
; period longer than the host's threshold is a mark, a shorter one a space, and it puts that on
; p1. The bit engine samples p1 at the bit rate, re-aligning on every edge, and the fabric
; (ax25_rx in hw/post/fabric_post.ml) decodes NRZI and drops the stuffed 0s; the program takes
; one kept bit at a time and finds flags as six 1s in a row. The CRC unit runs over the kept bits
; as in hdlc_rx.s (the host sets the polynomial 0x1021 << 16 and the start value 0xFFFF << 16);
; a good frame leaves 0x1D0F in its top half.
;
; Pins: p19 (ui[3]) the audio comparator; p1 (uio[1]) the tone found (driven here, read back by
; the bit engine through its pad).
; Host: first the bit time in cycles (41667 for 1200 bit/s at 50 MHz) and the half-period
; threshold in cycles (16100: between 2200 Hz's 11364 and 1200 Hz's 20833). The host gets each
; byte of a frame as it comes, 0x100 | byte, FCS included, then 0x8000 | the byte count,
; | 0x4000 if the FCS is right. Fewer than 17 bytes between flags is not a frame (AX.25 2.2,
; 3.9): then the word is 0x2000 | the count, and the host drops those bytes.
;
; Registers: r7 the last edge, r6 the threshold, r5 1s in a row, r4 bytes in the frame (0x8000
; until the first flag), r3 the CRC at the last byte boundary, r2 bits in the byte, r1 the byte.

      pull r0
      csrw baud, r0
      pull r6
      ldi  r0, 0xe0
      ldih r0, 0x0b        ; txcfg: TX pin 31 (no pad); the bit engine only receives
      csrw txcfg, r0
      ldi  r0, 0x20
      ldih r0, 0x0c        ; rxcfg: 1 bit, pin 1, through the fabric, re-align on every edge
      csrw rxcfg, r0
      csrwi fabctl, 0      ; rx bit = element 0
      ldi  r0, 0x17
      csrw fabctl2, r0     ; drop = element 7 (on)
      csrwi crcctl, 3      ; CRC on, fed by the kept RX bits
      ldi  r0, 0x53
      csrw capcfg, r0      ; capture both edges of p19
      pin  p1, clr
      csrr r7, cap
      ldi  r5, 0
      ldi  r4, 0
      ldih r4, 0x80        ; no flag seen yet
      ben  1

loop: j    rx_ready, bit
      csrr r0, cap         ; the time of the last edge
      cmp  r0, r7
      j    z, loop         ; no new edge
      sub  r0, r7          ; the half period
      add  r7, r0          ; the last edge = this one
      cmp  r0, r6
      j    c, space
      pin  p1, set         ; a long half period: 1200 Hz, a mark
      jmp  loop
space: pin p1, clr         ; 2200 Hz, a space
      jmp  loop

bit:  rx   r0              ; a kept bit
      shri r0, 1           ; C = it
      j    nc, b0
      addi r5, 1
      cmpi r5, 6
      j    z, flag
      shri r1, 1
      ldi  r0, 0x80
      or   r1, r0
      jmp  b1
b0:   ldi  r5, 0
      shri r1, 1
b1:   tstb r4, 15
      j    nz, loop        ; before the first flag: nothing to build
      addi r2, 1
      cmpi r2, 8
      j    nz, loop
      ldi  r0, 0
      ldih r0, 0x01
      or   r0, r1
      push r0              ; a whole byte
      addi r4, 1
      csrr r3, crc_hi      ; the CRC at this byte boundary
      ldi  r1, 0
      ldi  r2, 0
      jmp  loop

; six 1s in a row: a flag (its last 0 was dropped). After bytes, it closes the frame.
flag: ldi  r5, 0
      tstb r4, 15
      j    nz, open
      tst  r4, r4
      j    z, open         ; just another flag
      cmpi r4, 17
      j    nc, full
      ldi  r0, 0           ; under 17 bytes (two addresses, control, FCS): not a frame (AX.25 3.9)
      ldih r0, 0x20
      or   r4, r0
      push r4
      jmp  open
full: ldi  r0, 0
      ldih r0, 0x80
      or   r4, r0
      ldi  r0, 0x0f
      ldih r0, 0x1d
      cmp  r3, r0          ; FCS residue
      j    nz, rep
      ldi  r0, 0
      ldih r0, 0x40
      or   r4, r0
rep:  push r4
open: crci
      ldi  r1, 0
      ldi  r2, 0
      ldi  r4, 0
      csrr r3, crc_hi
      jmp  loop
