; can_rx.s: CAN 2.0A receiver that acknowledges, at 500 kbit/s with a 50 MHz clock (100 cycles a
; bit). Written after the RTL freeze: firmware and a fabric configuration only.
;
; Pins: p19 (ui[3]) is the bus as the transceiver's RXD shows it; p0 (uio[0]) goes to the
; transceiver's TXD (1 = recessive), with a pull-up, so the pin is recessive until the program
; drives it (a uo pin would sit at 0, dominant, until then). The host loads the fabric configuration can_rx
; (hw/post/fabric_post.ml), which drops stuff bits, and sets the CRC polynomial to 0x4599 << 17
; with a start value of 0 (CRC-15 in the top of the 32-bit CRC register).
;
; The bit engine hands over one de-stuffed bit per RX word, so the program always knows where
; in the frame it is. Per frame the host gets six words:
;   ID (11 bits), then RTR << 6 | IDE << 5 | r0 << 4 | DLC, with bit 8 set if the CRC is good,
;   then the data bytes, the last one in the low byte of the fourth word (r3), the first
;   furthest up: r6 r5 r4 r3 hold the last 8 bytes shifted in, so a frame of n bytes has them in
;   the low n bytes of r6:r5:r4:r3.
; Only base frames (IDE = 0) are acknowledged; an extended frame is reported with its first
; 11 ID bits and not acknowledged.

.equ BIT 100

      ldi  r0, BIT
      csrw baud, r0
      ldi  r0, 0xe0
      ldih r0, 0x0b        ; txcfg: TX pin 31 (no pad), idle 1. The bit engine only receives here,
      csrw txcfg, r0       ; and left at pin 0 it would hold p0 (our TXD) at its idle level, 0
      ldi  r0, 0x60
      ldih r0, 0x0e        ; rxcfg: 1 bit, pin 19, through the fabric, re-align on every edge, free running
      csrw rxcfg, r0
      ldi  r0, 0x00
      ldih r0, 0x04        ; fabctl: rx bit = element 1, ext2 = 0 (not counting runs)
      csrw fabctl, r0
      ldi  r0, 0xd5        ; fabctl2: drop = element 5 (on), flag = element 6
      csrw fabctl2, r0
      csrwi crcctl, 3      ; CRC on, fed by the kept RX bits
      pin  p0, set         ; recessive
      ben  1

; ---- wait for a start of frame (the previous frame's end was waited out below)
sof:  wait pin p19, 0
      ldi  r0, 0x01
      ldih r0, 0x04        ; ext2 = 1: count runs from the start of frame on
      csrw fabctl, r0
      crci
      j    rx_ready, stale ; a bit from the idle bus may still be waiting
      jmp  fresh
stale: rx  r0
fresh: rx  r0             ; the start of frame itself (0)

      ldi  r1, 0           ; ID, 11 bits, first bit first
      ldi  r7, 11
id:   rx   r0
      shli r1, 1
      or   r1, r0
      djnz r7, id

      ldi  r2, 0           ; RTR, IDE, r0, DLC[3:0]
      ldi  r7, 7
ctl:  rx   r0
      shli r2, 1
      or   r2, r0
      djnz r7, ctl

      ; data bits: none for a remote frame (RTR) or an extended frame, else 8 x min(DLC, 8)
      ldi  r3, 0
      ldi  r4, 0
      ldi  r5, 0
      ldi  r6, 0
      tstb r2, 6           ; RTR
      j    nz, crc
      tstb r2, 5           ; IDE: not handled, stop here
      j    nz, report
      mov  r7, r2
      ldi  r0, 0x0f
      and  r7, r0          ; DLC
      cmpi r7, 9
      j    c, small        ; DLC < 9
      ldi  r7, 8
small: tst r7, r7
      j    z, crc
      shli r7, 3           ; bits
data: rx   r0
      rrc  r0, 1           ; the bit into C
      rlc  r3, 1           ; r6:r5:r4:r3 <<= 1, C in at the bottom
      rlc  r4, 1
      rlc  r5, 1
      rlc  r6, 1
      djnz r7, data

crc:  ldi  r7, 15          ; the 15 CRC bits go through the CRC unit like the rest
crcb: rx   r0
      djnz r7, crcb
      csrr r7, time_lo     ; about 3 cycles after the middle of the last CRC bit
      ldi  r0, 0x00
      ldih r0, 0x04        ; ext2 = 0: the frame from here on is not stuffed
      csrw fabctl, r0
      ldi  r0, 146         ; the ACK slot starts 1.5 bits after the middle of the last CRC bit
      j    fab_flag, stuf  ; ...or 2.5 if a stuff bit follows the CRC
      jmp  ack
stuf: ldi  r0, 246
ack:  add  r7, r0
      csrr r0, crc_hi
      tst  r0, r0
      j    nz, bad         ; a wrong CRC is not acknowledged
      wait time r7
      pin  p0, clr         ; dominant for the ACK slot
      ldi  r0, BIT
      add  r7, r0
      wait time r7
      pin  p0, set
      ldi  r0, 0
      ldih r0, 0x01        ; CRC good
      or   r2, r0
      jmp  report
bad:  ldi  r0, BIT
      add  r7, r0

report: push r1
      push r2
      push r6
      push r5
      push r4
      push r3
      ldi  r0, 0x4c
      ldih r0, 0x04        ; 1100 cycles: ACK delimiter, end of frame and intermission (11 bits)
      add  r7, r0
      wait time r7
      jmp  sof
