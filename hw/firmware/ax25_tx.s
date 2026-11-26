; ax25_tx.s: AX.25 frames (packet radio, APRS) as an NRZI bit stream, for afsk_tx.s on another
; engine to turn into Bell 202 tones. Written after the RTL freeze: firmware and a fabric
; configuration.
;
; As hdlc_tx.s: flags, the frame with a 0 put after five 1s, the FCS-16 from the CRC unit (the
; host sets the polynomial 0x1021 << 16 and the start value 0xFFFF << 16), a closing flag; then the
; fabric (ax25_tx in hw/post/fabric_post.ml) sends it NRZI: a 0 changes the line, a 1 leaves it.
;
; Pin: p2 (uio[2]), the NRZI line. It is a uio pin because another engine reads it: engines see
; each other's outputs only through the uio pads.
; Host: first the bit time in cycles (41667 for 1200 bit/s at 50 MHz) and how many flags open a
; frame (the transmitter's start-up delay; 1 or more). Then per frame the number of bytes and the
; bytes, one a word. After the closing flag the program answers 1.

      pull r0
      csrw baud, r0
      pull r6              ; opening flags
      ldi  r0, 0x47
      ldih r0, 0x0c        ; txcfg: 8 bits, LSB first, pin 2, through the fabric, idle 1
      csrw txcfg, r0
      ldi  r0, 0x0d
      ldih r0, 0x02        ; fabctl: line = element 6, hold = element 0 (on), ext2 = 1: flags
      csrw fabctl, r0
      csrwi crcctl, 1      ; CRC on, fed by the TX bits (held bits skipped)
      ben  1

main: pull r1              ; number of bytes
      ldi  r0, 0x7e
      mov  r3, r6
of:   tx   r0              ; opening flags
      djnz r3, of
      wait event tx_empty  ; the last flag is in the shifter: its bit 0 went out on this tick
      pull r2
      tx   r2              ; the first byte waits behind it
      ldi  r3, 7
fl:   wait event tick      ; flag bits 1 to 7
      djnz r3, fl
      ldi  r0, 0x0c
      ldih r0, 0x02        ; stuffing on, CRC from the start value
      csrw fabctl, r0
      crci
      subi r1, 1
      j    z, fcs
dl:   pull r2
      tx   r2
      subi r1, 1
      j    nz, dl
fcs:  wait event tx_empty  ; the last byte is in the shifter
      csrwi crcctl, 0x11   ; the next two words carry the CRC
      tx   r0
      tx   r0
      wait event tx_empty
      csrwi crcctl, 1
      ldi  r0, 0x7e
      tx   r0              ; closing flag
      wait event tx_empty
      ldi  r0, 0x0d
      ldih r0, 0x02        ; no stuffing for the flag
      csrw fabctl, r0
      ldi  r0, 0x7e
      tx   r0              ; one more flag, so the closing one is all out before the line idles
      wait event tx_empty
      ldi  r0, 1
      push r0
      jmp  main
