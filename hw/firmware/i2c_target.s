; I2C target (the other end from i2c_master.s), 100 and 400 kHz, open drain.
; SCL = p0 (uio[0]), SDA = p1 (uio[1]).
;
; The first host word is the 7-bit address to answer to. After that:
; Replies:
;   0x1aa  a START (or repeated START) for us; aa = the address byte, bit 0 set for a read
;   0x2dd  a byte the controller wrote (each one is ACKed)
;   0x300  STOP
; Host words, for a read: each byte to send, one word per byte.
;
; The target holds SCL low (clock stretching) while it hands a byte to the host and while it
; waits for the host's next byte to send, so a slow host slows the bus down instead of losing
; data. START and STOP are SDA changes while SCL is high, watched for on every bit the
; controller sends.
;
; r0 byte   r1 bits left   r2 pins (bit 0 SCL, bit 1 SDA)   r3 our address << 1
; r4 pins when SCL went high   r5 reply   r6 scratch   r7 0xfe

      csrwi group0, 0x20   ; group 0: p0 and p1
      pin  p0, hiz
      pin  p1, hiz
      pull r3
      shli r3, 1
      ldi  r7, 0xfe

; wait for a START: both lines high, then SDA falls while SCL stays high
idle: inp  r2, 0
      cmpi r2, 3
      j    nz, idle
id1:  inp  r2, 0
      cmpi r2, 3
      j    z, id1
      cmpi r2, 1
      j    nz, idle        ; SCL fell first: that wasn't a START

start: inp r2, 0
      tstb r2, 0
      j    nz, start       ; wait for SCL to go low after the START
      call rbyte
      mov  r5, r0
      and  r5, r7
      cmp  r5, r3
      j    nz, idle        ; another target's address
      ldi  r5, 0
      ldih r5, 1
      or   r5, r0
      call ack
      tstb r0, 0
      j    nz, read

write: call rbyte
      ldi  r5, 0
      ldih r5, 2
      or   r5, r0
      call ack
      jmp  write

stop: ldi  r5, 0
      ldih r5, 3
      push r5
      jmp  idle

; the controller reads: send bytes until it answers with NACK
read: pin  p0, clr         ; hold SCL low until the host has given the byte
      pull r0
      shli r0, 8
      ldi  r1, 8
rd1:  shli r0, 1
      j    c, rd1h
      pin  p1, clr
      jmp  rd2
rd1h: pin  p1, hiz
rd2:  pin  p0, hiz
rd3:  inp  r2, 0
      tstb r2, 0
      j    z, rd3          ; SCL high: the controller samples
rd4:  inp  r2, 0
      tstb r2, 0
      j    nz, rd4         ; SCL low: next bit
      djnz r1, rd1
      pin  p1, hiz         ; let go for the controller's ACK
rd5:  inp  r2, 0
      tstb r2, 0
      j    z, rd5
      mov  r6, r2          ; SDA in the 9th clock: 0 = ACK
rd6:  inp  r2, 0
      tstb r2, 0
      j    nz, rd6
      tstb r6, 1
      j    z, read         ; ACK: it wants another byte
      call rbyte           ; NACK: next comes STOP or a repeated START, which rbyte catches
      jmp  idle

; take in a byte on the SCL rising edges (SCL is low on entry and on return); a START or STOP
; on the way goes straight to start / stop
rbyte: ldi r0, 0
      ldi  r1, 8
rb1:  inp  r2, 0
      tstb r2, 0
      j    z, rb1
      mov  r4, r2
      mov  r6, r2
      shri r6, 2           ; C = SDA
      rlc  r0, 1
rb2:  inp  r2, 0
      tstb r2, 0
      j    z, rb3          ; SCL low: the bit is done
      xor  r2, r4
      tstb r2, 1
      j    z, rb2          ; SDA hasn't moved
      tstb r4, 1           ; it moved while SCL was high: falling = START, rising = STOP
      j    nz, start
      jmp  stop
rb3:  djnz r1, rb1
      ret

; ACK the byte just taken in, holding SCL low while the reply goes to the host
ack:  pin  p1, clr
      pin  p0, clr
      push r5
      pin  p0, hiz
ak1:  inp  r2, 0
      tstb r2, 0
      j    z, ak1
ak2:  inp  r2, 0
      tstb r2, 0
      j    nz, ak2
      pin  p1, hiz
      ret
