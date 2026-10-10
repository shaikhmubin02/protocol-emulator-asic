; USB low-speed packet receiver (1.5 Mbit/s): D+ on p4 (uio[4]), D- on p5 (uio[5]). Clock 48 MHz.
;
; The bit engine recovers the bit clock: it samples D+ once a bit and moves its sampling point
; to the middle of the bit on every edge, so the far end's clock can be off by the 1.5% the
; spec allows. It hands over one sample at a time, and the program checks D- at that moment
; too, so it sees SE0 (both lines low), which is how a packet ends. It undoes NRZI and bit
; stuffing, finds SYNC and checks the CRC-16.
;
; Each bit has 32 cycles; the common path takes about 25, and a byte boundary takes longer but
; the bit engine holds one sample, so the next few bits catch up.
;
; Words to the host:
;   0x00dd  a byte; for every byte after the PID, bit 8 is set when the CRC-16 over the bytes so
;           far (after the PID) checks out, so on a data packet it should be set on the last byte
;   0x8000  end of packet (a partial byte before it is dropped)
;
; r0 sample   r1 last sample   r2 1s in a row   r3 0 while on the PID   r4 CRC
; r5 byte     r6 scratch       r7 bits left in the byte

.equ BIT 32

      ldi  r6, 0x80
      ldih r6, 0x08        ; rxcfg: 1 bit, pin 4, free-running, re-align on every edge
      csrw rxcfg, r6
      csrwi jpin, 5        ; jpin_hi / jpin_lo look at D-
      csrwi baud, BIT
      ldi  r1, 0           ; idle (J) has D+ low
      ben  1

; wait for the line to change: the start of SYNC
idle: rx   r0
      mov  r6, r0
      xor  r6, r1
      mov  r1, r0
      tstb r6, 0
      j    z, idle         ; no change: still idle
      ldi  r7, 6
sync: rx   r0              ; SYNC: seven changes, then none
      mov  r6, r0
      xor  r6, r1
      mov  r1, r0
      tstb r6, 0
      j    z, idle
      djnz r7, sync
      rx   r0
      mov  r6, r0
      xor  r6, r1
      mov  r1, r0
      tstb r6, 0
      j    nz, idle
      ldi  r2, 1           ; stuffing counts from the 1 at the end of SYNC
      ldi  r3, 0

byte: ldi  r5, 0
      ldi  r7, 8
bit:  rx   r0
      j    jpin_hi, b1     ; D- high: J or K, not SE0
      tstb r0, 0
      j    z, eop          ; D+ low as well: SE0, the end of the packet
b1:   mov  r6, r0
      xor  r6, r1          ; bit 0 = the line changed = a 0
      mov  r1, r0
      tstb r6, 0
      j    nz, b0
      addi r2, 1           ; a 1
      cmpi r2, 7
      j    z, eop          ; seven 1s can't happen in a packet: give up on it
      jmp  keep
b0:   cmpi r2, 6
      j    z, stuffed
      ldi  r2, 0
keep: xor  r4, r6          ; CRC bit 0 ^= "changed", which is the feedback inverted
      shri r6, 1           ; C = changed = not the data bit
      rrc  r5, 1           ; so the byte builds up inverted
      shri r4, 1           ; C = not the feedback
      j    c, nofb
      ldi  r6, 0x01
      ldih r6, 0xa0
      xor  r4, r6
nofb: djnz r7, bit

      shri r5, 8
      ldi  r6, 0xff
      xor  r5, r6          ; the byte, the right way up
      tstb r3, 0
      j    nz, flag
      ldi  r3, 1           ; that was the PID: the CRC starts after it
      ldi  r4, 0xff
      ldih r4, 0xff
      jmp  send
flag: ldi  r6, 0x01
      ldih r6, 0xb0        ; what the CRC-16 is left at after good data and its CRC
      cmp  r4, r6
      j    nz, send
      ldi  r6, 0
      ldih r6, 0x01
      or   r5, r6          ; CRC good so far
send: push r5
      jmp  byte

stuffed:
      ldi  r2, 0           ; a 0 after six 1s isn't data
      jmp  bit

eop:  ldi  r6, 0
      ldih r6, 0x80
      push r6
      ldi  r1, 0           ; D+ is low through SE0 and the idle J after it
      jmp  idle
