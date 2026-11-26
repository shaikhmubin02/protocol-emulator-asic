; USB low-speed device, the receive side (engine 0; usb_dev_tx.s on engine 1 answers).
; D+ = p4 (uio[4]), D- = p5 (uio[5]), read only. Clock 48 MHz: 32 cycles a bit.
;
; The bit engine samples D+ once a bit, re-aligning on every edge; the usb_rx fabric
; configuration undoes NRZI and drops the bit after six 1s, so the program gets one decoded bit
; per word. It reads D+ and D- with each bit too, to see SE0 (both low): the end of a packet, or,
; when it lasts 6 samples (4 us) on an idle line, a bus reset. The CRC unit runs the CRC-16 of
; data packets over the decoded bits.
;
; Tokens: the 16 bits after the PID (address, endpoint, CRC-5) are compared whole with the
; value for this device's address and endpoint 0 (r1, from the board's processor), and, XOR
; 0xB080, endpoint 1: the CRC-5 of a token is affine in its bits, so one constant moves any
; address to endpoint 1. A match is also the CRC-5 check.
;
; What it does (flags go to usb_dev_tx.s):
;   IN to us, endpoint 0 / 1             flag 0 / flag 1 (send the packet, or NAK)
;   SETUP, then DATA0 with a good CRC     keep the data, flag 2 (ACK), word to the processor
;   OUT, then DATA with a good CRC        the same, but if the last data hasn't been taken yet:
;                                         flag 3 (NAK), and it isn't kept
;   ACK from the host after our data      flag 4, word to the processor
;   a good SETUP also raises flag 4: the transmit side drops what it held (USB: a SETUP ends
;   any transfer on endpoint 0 and clears a STALL)
;   a bad CRC                             nothing: the host sends it again
; The data stays in r4..r7 for the processor to read over the host port (r7 the last word,
; 2 bytes a word, low byte first, at most 8 bytes); it writes r1 again when it has, which also
; carries a new address after SET_ADDRESS.
;
; Words to the processor (a full outbox drops the word rather than stall the receiver):
;   0x1cpp  SETUP data, c = bytes received with the CRC, pp = the data PID
;   0x2cpp  OUT data, the same
;   0x300e  the host acknowledged the data sent on endpoint e
;   0x4000  bus reset (the address is 0 again)
;
; r0 scratch       r1 token value for (address, endpoint 0)
; r2 [3:0] bytes in this data packet, [4] data not taken yet, [7:5] what the last token was
;    (0 not for us, 1 SETUP, 2 OUT, 3 IN 0, 4 IN 1), [15:8] the token's first byte / the data PID
; r3 the byte coming in, with a 1 above it that falls into C after 8 bits
; r4..r7 the data words

      csrwi group0, 0x24   ; group 0: p4 (D+), p5 (D-)
      ldi  r0, 0xE0
      ldih r0, 0x0B        ; txcfg: TX on pin 31 (no pad), idle 1: this engine drives nothing
      csrw txcfg, r0
      ldi  r0, 0x80
      ldih r0, 0x0C        ; rxcfg: 1 bit, pin 4, through the fabric, re-align, free-running
      csrw rxcfg, r0
      csrwi fabctl, 0      ; rx bit = element 0
      csrwi fabctl2, 0x15  ; drop = element 5, on
      csrwi crcctl, 3      ; CRC on, from the kept RX bits
      csrwi baud, 32
      ldi  r1, 0x00
      ldih r1, 0x10        ; address 0, endpoint 0: token bytes 00 10
      ldi  r2, 0
      ben  1

idle: ldi  r3, 0           ; SE0 samples in a row
id1:  rx   r0
      shri r0, 1           ; C = the bit
      inp  r0, 0
      tst  r0, r0
      j    z, ise0
      ldi  r3, 0
      j    nc, sync        ; a 0: the line changed, a SYNC starts
      j    mbx_data, mail
      jmp  id1
ise0: addi r3, 1
      cmpi r3, 6
      j    nz, id1
      ldi  r1, 0x00        ; bus reset
      ldih r1, 0x10
      ldi  r2, 0
      ldi  r0, 0
      ldih r0, 0x40
      call put
      jmp  id1

mail: pull r1              ; the token value again (maybe a new address); the data was taken
      ldi  r0, 0xEF
      ldih r0, 0xFF
      and  r2, r0
      jmp  id1

; push without waiting: a full outbox loses the word, it never stalls the receiver
put:  csrwi tmo, 1
      push r0
      csrwi tmo, 0
      ret

sync: ldi  r3, 1           ; 0s so far
sy1:  rx   r0
      shri r0, 1
      j    c, sy2
      addi r3, 1
      jmp  sy1
sy2:  cmpi r3, 4
      j    c, idle         ; fewer than four 0s: not a SYNC
      ldi  r3, 0x80
pid:  rx   r0
      shri r0, 1
      inp  r0, 0
      tst  r0, r0
      j    z, junk
      rrc  r3, 1
      j    nc, pid
      shri r3, 8           ; the PID
      crci                 ; the CRC-16 starts with the next bit
      ldi  r0, 0x69
      cmp  r3, r0
      j    z, tin
      ldi  r0, 0xC3
      cmp  r3, r0
      j    z, data
      ldi  r0, 0x4B
      cmp  r3, r0
      j    z, data
      ldi  r0, 0x2D
      cmp  r3, r0
      j    z, tsetup
      ldi  r0, 0xE1
      cmp  r3, r0
      j    z, tout
      ldi  r0, 0xD2
      cmp  r3, r0
      j    z, hack
      jmp  skip            ; NAK or STALL (ours), or something else: not for us

; ---- tokens
tin:  ldi  r0, 0x60        ; kind 3 (IN; endpoint 1 is sorted out below)
      jmp  tok
tsetup: ldi r0, 0x20       ; kind 1
      jmp  tok
tout: ldi  r0, 0x40        ; kind 2
tok:  ldi  r3, 0x10
      and  r2, r3          ; keep only "data not taken"
      or   r2, r0
      ldi  r3, 0x80
tb1:  rx   r0
      shri r0, 1
      inp  r0, 0
      tst  r0, r0
      j    z, junk
      rrc  r3, 1
      j    nc, tb1
      or   r2, r3          ; first byte -> r2[15:8]
      ldi  r3, 0x80
tb2:  rx   r0
      shri r0, 1
      inp  r0, 0
      tst  r0, r0
      j    z, junk
      rrc  r3, 1
      j    nc, tb2
      mov  r0, r2
      shri r0, 8
      or   r3, r0          ; the 16 bits after the PID
      ldi  r0, 0xFF
      and  r2, r0
      rx   r0              ; and then the end of the packet
      inp  r0, 0
      tst  r0, r0
      j    nz, junk
      cmp  r3, r1
      j    z, tep0
      xor  r3, r1
      ldi  r0, 0x80
      ldih r0, 0xB0
      cmp  r3, r0
      j    z, tep1
junk: ldi  r0, 0x1F        ; not for us
      and  r2, r0
      jmp  idle
tep0: mov  r0, r2
      shri r0, 5
      cmpi r0, 3
      j    nz, idle        ; SETUP or OUT: the data packet comes next
      sig  0
      jmp  idle
tep1: mov  r0, r2
      shri r0, 5
      cmpi r0, 3
      j    nz, junk        ; this device has no SETUP or OUT on endpoint 1
      ldi  r0, 0x1F
      and  r2, r0
      ldi  r0, 0x80        ; kind 4: IN 1
      or   r2, r0
      sig  1
      jmp  idle

; ---- the host's ACK
hack: rx   r0
      inp  r0, 0
      tst  r0, r0
      j    nz, junk        ; not the end of the packet
      mov  r0, r2
      shli r0, 8
      shri r0, 13          ; kind
      cmpi r0, 3
      j    z, ha0
      cmpi r0, 4
      j    nz, junk        ; our own ACK of the host's data, or not for us
      sig  4
      ldi  r0, 0x01
      jmp  ha1
ha0:  sig  4
      ldi  r0, 0x00
ha1:  ldih r0, 0x30
      call put
      jmp  junk

; ---- data packets
data: mov  r0, r2
      shli r0, 8
      shri r0, 13          ; kind
      cmpi r0, 1
      j    z, dkeep        ; after SETUP: always taken
      cmpi r0, 2
      j    nz, skip        ; after IN it's our own data; or not for us
      tstb r2, 4
      j    nz, dnak        ; after OUT, but the last data hasn't been taken yet
dkeep: ldi r0, 0xF0
      and  r2, r0          ; no bytes yet (kind and "not taken" stay)
      shli r3, 8
      or   r2, r3          ; the PID in r2[15:8]
      ldi  r3, 0x80
db:   rx   r0
      shri r0, 1
      inp  r0, 0
      tst  r0, r0
      j    z, dend
      rrc  r3, 1
      j    nc, db
      tstb r2, 3
      j    nz, dcnt        ; 8 bytes kept already: the rest is the CRC
      tstb r2, 0
      j    nz, dhi
      mov  r4, r5          ; a new word
      mov  r5, r6
      mov  r6, r7
      shri r3, 8
      mov  r7, r3
      jmp  dcnt
dhi:  or   r7, r3
dcnt: tstb r2, 3
      j    z, dinc
      tstb r2, 2
      j    nz, dnxt        ; 12 or more: too long, stop counting
dinc: addi r2, 1
dnxt: ldi  r3, 0x80
      jmp  db

; the end of the packet. C = the decoded bit of the SE0 sample, which the CRC took in too:
; after good data and its CRC the register is 0x800D, then 0x801F after a 0, 0x001A after a 1
dend: csrr r0, crc_hi
      j    c, de1
      shli r0, 1
      j    nc, dbad
      cmpi r0, 0x3E
      j    nz, dbad
      jmp  dgood
de1:  cmpi r0, 0x1A
      j    nz, dbad
dgood: sig 2               ; ACK
      mov  r0, r2
      shli r0, 8
      shri r0, 13
      cmpi r0, 1
      j    nz, dg1
      sig  4               ; a SETUP: whatever endpoint 0 was sending (or STALL) is over, now
dg1:  ldi  r0, 0x10
      or   r2, r0          ; the data waits for the processor
      mov  r0, r2
      shli r0, 8
      shri r0, 13
      shli r0, 12          ; kind << 12
      mov  r3, r2
      shli r3, 12
      shri r3, 4
      or   r0, r3          ; bytes << 8
      mov  r3, r2
      shri r3, 8
      or   r0, r3          ; PID
      call put
dbad: ldi  r0, 0x10        ; forget the token, keep "data not taken"
      and  r2, r0
      jmp  idle

; OUT data that can't be taken: read it to the end, NAK it if it arrived whole
dnak: rx   r0
      shri r0, 1
      inp  r0, 0
      tst  r0, r0
      j    nz, dnak
      csrr r0, crc_hi
      j    c, dn1
      shli r0, 1
      j    nc, dbad
      cmpi r0, 0x3E
      j    nz, dbad
      jmp  dn2
dn1:  cmpi r0, 0x1A
      j    nz, dbad
dn2:  sig  3
      jmp  dbad

; anything else: wait for the end of the packet
skip: rx   r0
      inp  r0, 0
      tst  r0, r0
      j    nz, skip
      jmp  idle
