; hdlc_tx.s: HDLC / SDLC frames (ISO 13239, the framing PPP uses, RFC 1662) at 250 kbit/s with a
; 50 MHz clock (200 cycles a bit), NRZ. Written after the RTL freeze: firmware and a fabric configuration only.
;
; The fabric (hdlc_tx in hw/post/fabric_post.ml) puts a 0 after five 1s inside a frame and nothing
; inside a flag, which has six 1s: FABCTL[0] (ext2) says which. The CRC unit makes the FCS-16: the
; host sets the polynomial to 0x1021 << 16 and the start value to 0xFFFF << 16; in send mode it
; puts out the CRC inverted, top bit first, which is the order HDLC sends the FCS in, and that goes
; through the stuffing too.
;
; Pin: p8 (uo[0]), idle 1. Host: write the number of bytes, then the bytes, one a word. After the
; closing flag the program answers 1.

      ldi  r0, 200
      csrw baud, r0        ; 200 cycles a bit
      ldi  r0, 0x07
      ldih r0, 0x0d        ; txcfg: 8 bits, LSB first, pin 8, through the fabric, idle 1
      csrw txcfg, r0
      ldi  r0, 0x0f
      ldih r0, 0x02        ; fabctl: line = element 7, hold = element 0 (on), ext2 = 1: no stuffing
      csrw fabctl, r0
      csrwi crcctl, 1      ; CRC on, fed by the TX bits (held bits skipped)
      ben  1

main: pull r1              ; number of bytes
      ldi  r0, 0x7e
      tx   r0              ; opening flags
      tx   r0
      wait event tx_empty  ; the second flag is in the shifter: its bit 0 went out on this tick
      pull r2
      tx   r2              ; the first byte waits behind it
      ldi  r3, 7
fl:   wait event tick      ; flag bits 1 to 7
      djnz r3, fl
      ; between the flag's last bit and the first data bit: stuffing on, CRC from the start value
      ldi  r0, 0x0e
      ldih r0, 0x02
      csrw fabctl, r0
      crci
      subi r1, 1
      j    z, fcs
dl:   pull r2
      tx   r2              ; waits while the holding register is full
      subi r1, 1
      j    nz, dl
      ; FCS: the next two words loaded carry the CRC instead of their own bits
fcs:  wait event tx_empty  ; the last byte is in the shifter
      csrwi crcctl, 0x11
      tx   r0
      tx   r0
      wait event tx_empty  ; the second half of the FCS is in the shifter
      csrwi crcctl, 1
      ldi  r0, 0x7e
      tx   r0              ; closing flag
      wait event tx_empty  ; loaded: its bit 0 (or a stuffed 0 before it) goes out on this tick
      ldi  r0, 0x0f
      ldih r0, 0x02        ; no stuffing for the flag's six 1s
      csrw fabctl, r0
      ldi  r0, 1
      push r0
      jmp  main
