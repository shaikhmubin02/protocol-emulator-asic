; I2C master, open drain: CLR pulls a line low, HIZ lets it go.
; SCL = p0 (uio[0]), SDA = p1 (uio[1]). Q = a quarter of a bit, in clock cycles.
; Waits for SCL to really go high, so targets can stretch the clock.
;
; Host word: [11:8] command, [7:0] data
;   1 START (or repeated START)
;   2 WRITE byte        reply: 0 = ACK, 1 = NACK
;   3 READ, send ACK    reply: byte
;   4 READ, send NACK   reply: byte
;   5 STOP

.equ Q 4

      pin  p0, hiz
      pin  p1, hiz

loop: pull r5
      mov  r6, r5
      shri r6, 8           ; r6 = command
      mov  r0, r5
      ldi  r4, 0xff
      and  r0, r4          ; r0 = data
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

; START: release SDA and SCL, then pull SDA low while SCL is high
start:
      pin  p1, hiz, Q
      call scl_high
      pin  p1, clr, Q
      pin  p0, clr, Q
      ret

; STOP: SDA low, release SCL, then let SDA rise while SCL is high
stop:
      pin  p1, clr, Q
      call scl_high
      pin  p1, hiz, Q
      ret

; release SCL and wait until it's really high
scl_high:
      pin  p0, hiz
      wait pin p0, 1
      dly  Q
      ret

; put C on SDA for one clock
write_bit:
      j    c, wb_one
      pin  p1, clr, Q
      jmp  wb_clk
wb_one:
      pin  p1, hiz, Q
wb_clk:
      call scl_high
      pin  p0, clr, Q
      ret

; read one bit into C
read_bit:
      pin  p1, hiz, Q
      call scl_high
      pin  p1, sample
      pin  p0, clr, Q
      ret

; write r0[7:0], then read the ACK bit into C (0 = ACK)
write_byte:
      shli r0, 8
      ldi  r3, 8
wbyte_bit:
      shli r0, 1
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
      mov  r4, r2
      shri r4, 1           ; C = r2 bit 0
      call write_bit
      ret
