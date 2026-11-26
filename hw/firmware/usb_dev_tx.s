; USB low-speed device, the transmit side (engine 1; usb_dev_rx.s on engine 0 is the receive
; side). D+ = p4 (uio[4]), D- = p5 (uio[5]); this engine owns both. Clock 48 MHz: 32 cycles a bit.
;
; The bit engine does the line coding: the usb_tx fabric configuration (bit stuffing, then
; NRZI), with the CRC unit (CRC-16, x^16 + x^15 + x^2 + 1, in send mode for the end of a data
; packet). Its TX pin is pin 31 (no pad); the fabric's line element is also the flag role, and
; the program copies it to D+ and D- with one OUTG, 8 cycles after each tick, so both lines
; change in the same cycle and every edge is on the 32-cycle grid.
;
; A 1-bit word after the CRC tells whether a stuffed bit still has to go out: at the tick that
; takes it, the shifter holds it (a stuffed bit goes out first) or sends it (the packet is over).
; The program shows SE0 instead of that bit, for two bits, then J for one, then lets go.
;
; The receive side raises an event flag when the host wants an answer:
;   flag 0  IN to endpoint 0     flag 2  send ACK (the host's data was good)
;   flag 1  IN to endpoint 1     flag 3  send NAK
;   flag 4  the host acknowledged the data this engine sent: the buffer is free
; An answer starts 3.5 bit times after the J that ends the host's packet (USB allows 2 to 6.5).
;
; The board's processor loads the packet for the next IN through the inbox:
;   header  [15:12] data bytes n (0 to 8), [11] 1 = a data packet (PID, data, CRC-16),
;           0 = a handshake (e.g. STALL), [10] endpoint, [7:0] PID. A header of 0 empties it.
;   then ceil(n / 2) words, the LAST one first: word k = byte 2k | byte 2k+1 << 8.
; The packet stays until the host acknowledges it, so a lost ACK makes it go out again (same
; DATA0/DATA1, as USB wants). An IN when there is no packet for that endpoint gets NAK.
;
; r0..r3 the packet's data words (r0 first; they turn round while sending and are turned back)
; r4 header (0 = no packet)   r5 words still to come (while sending: bytes still to send)
; r6 line state for OUTG      r7 scratch (ticks to the CRC start, BSTAT)
; Line states, as OUTG writes them (bit 0 = D+, bit 1 = D-): J = 2, K = 1, SE0 = 0.

.equ DELAY 64              ; J seen -> BEN: the first K comes 3.5 bit times after the J

      csrwi group0, 0x24   ; group 0: p4, p5
      pin  p4, hiz
      pin  p5, hiz
      csrwi baud, 32
      ldi  r7, 0xEF
      ldih r7, 0x0F        ; txcfg: 16 bits, LSB first, pin 31, through the fabric, idle 1
      csrw txcfg, r7
      ldi  r7, 0x0E
      ldih r7, 0x02        ; fabctl: line = element 7, hold = element 0, hold on
      csrw fabctl, r7
      ldi  r7, 0xE0        ; fabctl2: flag = element 7 (the line)
      csrw fabctl2, r7
      ldi  r4, 0
      ldi  r5, 0

idle: j    mbx_data, load
      csrr r7, flags
      tstb r7, 0
      j    nz, in0
      tstb r7, 1
      j    nz, in1
      tstb r7, 2
      j    nz, ack
      tstb r7, 3
      j    nz, nak
      tstb r7, 4
      j    nz, freed
      jmp  idle

load: cmpi r5, 0
      j    nz, ldat
      pull r4              ; a header
      mov  r5, r4
      shri r5, 12
      addi r5, 1
      shri r5, 1           ; data words to come
      jmp  idle
ldat: mov  r3, r2          ; a data word (they come last first)
      mov  r2, r1
      mov  r1, r0
      pull r0
      subi r5, 1
      jmp  idle

freed: clrf 4
      ldi  r4, 0
      jmp  idle

in0:  clrf 0
      cmpi r5, 0
      j    nz, nakp        ; still loading
      tst  r4, r4
      j    z, nakp         ; nothing to send
      tstb r4, 10
      j    nz, nakp        ; it's for endpoint 1
      jmp  send
in1:  clrf 1
      cmpi r5, 0
      j    nz, nakp
      tst  r4, r4
      j    z, nakp
      tstb r4, 10
      j    z, nakp         ; it's for endpoint 0
send: mov  r6, r4
      shli r6, 8
      ldi  r7, 0x80
      or   r6, r7          ; first word: SYNC, then the PID
      tstb r4, 11
      j    z, hstart       ; a handshake from the buffer (STALL)
      mov  r5, r4
      shri r5, 12          ; data bytes to send
      jmp  dstart

ack:  clrf 2
      ldi  r6, 0x80
      ldih r6, 0xD2
      jmp  hstart
nak:  clrf 3
nakp: ldi  r6, 0x80
      ldih r6, 0x5A
      jmp  hstart

; ---- start of a packet: the same number of cycles from the J to BEN either way
hstart: csrwi crcctl, 1    ; not sending the CRC (a data packet before may have left it on)
      wait pin p5, 1       ; the J after the SE0 of the host's packet
      ldi  r7, 0xEF
      ldih r7, 0x0F
      csrw txcfg, r7       ; 16-bit words
      dly  DELAY
      ben  1
      tx   r6
      ldi  r7, 0xE0
      ldih r7, 0x0F
; the first tick has its own slot: once the shifter has taken SYNC + PID, the 1-bit word goes
; in behind it, so the shifter isn't idle after the PID's last bit (no stuffed bit can follow
; SYNC + PID, so it ends the packet at the next tick)
      wait event tick
      csrw txcfg, r7       ; 1 bit, for the next word loaded
      tx   r7
      ldi  r6, 1
      j    fab_flag, h1
      jmp  h2
h1:   ldi  r6, 2
h2:   dly  1
      outg 0, r6           ; 8 cycles after the tick, like every other slot
      jmp  fslot

dstart: csrwi crcctl, 1    ; CRC on, from the TX bits (not sending it yet)
      wait pin p5, 1
      ldi  r7, 0xEF
      ldih r7, 0x0F
      csrw txcfg, r7
      dly  DELAY
      ben  1
      tx   r6
      ldi  r7, 16          ; the PID's last bit goes out on tick 16

; ---- one slot per tick while words are still to be fed; OUTG 8 cycles after the tick
nslot: wait event tick
      ldi  r6, 1           ; K
      j    fab_flag, n1    ; the line element is 1: J
      jmp  n2
n1:   ldi  r6, 2           ; J
n2:   dly  3
      outg 0, r6
      djnz r7, n3
      crci                 ; after tick 16: the CRC starts with the first data bit
n3:   j    tx_empty, nfeed
      jmp  nslot

nfeed: tstb r5, 15
      j    nz, ndum        ; the CRC is in: now the 1-bit word
      cmpi r5, 0
      j    z, ncrc
      cmpi r5, 1
      j    z, nodd
      tx   r0              ; two data bytes
      subi r5, 2
      jmp  nrot
nodd: ldi  r6, 0xE7
      ldih r6, 0x0F
      csrw txcfg, r6       ; 8 bits for the last byte
      tx   r0
      subi r5, 1
nrot: mov  r6, r0          ; turn the data words: r0 <- r1 <- r2 <- r3 <- r0
      mov  r0, r1
      mov  r1, r2
      mov  r2, r3
      mov  r3, r6
      jmp  nslot
ncrc: ldi  r6, 0xEF
      ldih r6, 0x0F
      csrw txcfg, r6       ; 16 bits
      csrwi crcctl, 0x11   ; the next word loaded is the CRC register
      tx   r6
      subi r5, 1           ; -1
      jmp  nslot
ndum: ldi  r6, 0xE0
      ldih r6, 0x0F
      csrw txcfg, r6       ; 1 bit
      tx   r6

; ---- one slot per tick until the shifter is idle: then SE0, 8 cycles after the tick as well
fslot: wait event tick
      csrr r7, bstat
      ldi  r6, 1
      j    fab_flag, f1
      jmp  f2
f1:   ldi  r6, 2
f2:   tstb r7, 1           ; TX idle?
      j    z, f3
      ldi  r6, 0           ; SE0: the packet is over
      outg 0, r6
      jmp  eop
f3:   nop
      outg 0, r6
      jmp  fslot

eop:  wait event tick
      wait event tick
      ldi  r6, 2
      dly  5
      outg 0, r6           ; J, two bit times after the SE0 began
      wait event tick
      dly  6
      pin  p4, hiz         ; and let go: the pull-up on D- keeps the line at J
      pin  p5, hiz
      ben  0
      tstb r5, 15
      j    z, idle         ; a handshake: nothing to turn back
      mov  r5, r4          ; a data packet: turn the data words back
      shri r5, 12
      addi r5, 1
      shri r5, 1           ; how many turns they made
back: cmpi r5, 0
      j    z, done
      cmpi r5, 4
      j    z, done
      mov  r6, r0
      mov  r0, r1
      mov  r1, r2
      mov  r2, r3
      mov  r3, r6
      addi r5, 1
      jmp  back
done: ldi  r5, 0
      jmp  idle
