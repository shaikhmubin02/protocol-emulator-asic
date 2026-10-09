; I2C master, open drain: CLR pulls a line low, HIZ lets it go.
; SCL = p0 (uio[0]), SDA = p1 (uio[1]).
;
; Timing comes from the shared cycle counter, not from counting instructions. r7 holds the time
; of the next step; each step adds Q cycles to it and waits until then. A bit takes 5 Q: SCL
; low for 3 Q (SDA changes 1 Q in) and high for 2 Q. The high time is counted from when SCL is
; seen high, so a target can stretch the clock.
;
;   Q = clock / (5 x rate). At 50 MHz: 100 kHz is Q = 100, 400 kHz is Q = 25.
;   100 kHz: SCL low 6 us, high 4 us (the spec asks for at least 4.7 and 4.0).
;   400 kHz: SCL low 1.5 us, high 1 us (at least 1.3 and 0.6).
;
; Host word: [11:8] command, [7:0] data
;   1 START (or repeated START)
;   2 WRITE byte        reply: 0 = ACK, 1 = NACK
;   3 READ, send ACK    reply: byte
;   4 READ, send NACK   reply: byte
;   5 STOP
;   6 SPEED             Q = data, in clock cycles (starts at 100)

      pin  p0, hiz
      pin  p1, hiz
      ldi  r4, 100         ; r4 = Q

loop: pull r5
      csrr r7, time_lo     ; steps count from now (wait time only looks at 16 bits)
      mov  r6, r5
      shri r6, 8           ; r6 = command
      mov  r0, r5
      shli r0, 8
      shri r0, 8           ; r0 = data
      cmpi r6, 1
      j    z, c_start
      cmpi r6, 2
      j    z, c_write
      cmpi r6, 3
      j    z, c_read_ack
      cmpi r6, 4
      j    z, c_read_nack
      cmpi r6, 5
      j    z, c_stop
      cmpi r6, 6
      j    z, c_speed
      jmp  loop

c_start:
      call start
      jmp  loop
c_write:
      call write_byte
      ldi  r0, 0
      rlc  r0, 1           ; r0 = C = 1 on NACK
      push r0
      jmp  loop
c_read_ack:
      ldi  r2, 0
      call read_byte
      push r1
      jmp  loop
c_read_nack:
      ldi  r2, 1
      call read_byte
      push r1
      jmp  loop
c_stop:
      call stop
      jmp  loop
c_speed:
      mov  r4, r0
      jmp  loop

; START: release SDA, then SCL. After 3 Q with both high, pull SDA low, hold 3 Q, SCL low.
; On a repeated START SCL is still low from the last bit.
start:
      pin  p1, hiz
      add  r7, r4
      wait time r7
      call scl_high        ; 2 Q
      add  r7, r4
      wait time r7         ; setup: 3 Q in all
      pin  p1, clr         ; START
      add  r7, r4
      wait time r7
      add  r7, r4
      wait time r7
      add  r7, r4
      wait time r7         ; hold 3 Q
      pin  p0, clr
      ret

; STOP: SDA low while SCL is low, release SCL, after 2 Q let SDA rise, then keep the bus free
; for 3 Q before anything else.
stop:
      add  r7, r4
      wait time r7
      pin  p1, clr
      add  r7, r4
      wait time r7
      add  r7, r4
      wait time r7
      call scl_high        ; setup 2 Q
      pin  p1, hiz         ; STOP
      add  r7, r4
      wait time r7
      add  r7, r4
      wait time r7
      add  r7, r4
      wait time r7
      ret

; release SCL, wait until it's really high, then keep it high for 2 Q
scl_high:
      pin  p0, hiz
      wait pin p0, 1
      csrr r7, time_lo
      add  r7, r4
      add  r7, r4
      wait time r7
      ret

; send the top bit of r0 (and shift it out), one clock; SCL is low on entry and exit
write_bit:
      add  r7, r4
      wait time r7         ; 1 Q after SCL fell
      shli r0, 1           ; C = bit
      j    c, wb_one
      pin  p1, clr
      jmp  wb_clk
wb_one:
      pin  p1, hiz
wb_clk:
      add  r7, r4
      wait time r7
      add  r7, r4
      wait time r7         ; SCL low for 3 Q
      call scl_high
      pin  p0, clr
      ret

; read one bit into C
read_bit:
      add  r7, r4
      wait time r7
      pin  p1, hiz         ; let the target drive SDA
      add  r7, r4
      wait time r7
      add  r7, r4
      wait time r7
      call scl_high
      pin  p1, sample      ; at the end of the high time
      pin  p0, clr
      ret

; write r0[7:0], then read the ACK bit into C (0 = ACK)
write_byte:
      shli r0, 8
      ldi  r3, 8
wbyte_bit:
      call write_bit
      djnz r3, wbyte_bit
      call read_bit
      ret

; read a byte into r1, then send ACK (r2 = 0) or NACK (r2 = 1)
read_byte:
      ldi  r1, 0
      ldi  r3, 8
rbyte_bit:
      call read_bit
      rlc  r1, 1
      djnz r3, rbyte_bit
      mov  r0, r2
      shli r0, 15          ; ACK or NACK as the next bit out
      call write_bit
      ret
