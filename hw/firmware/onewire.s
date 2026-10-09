; 1-Wire master on p2 (uio[2]), open drain: CLR pulls the line low, HIZ lets the pull-up
; (4.7k to 3.3 V) take it high. Standard speed, with the usual recommended slot timings:
;   reset:   low 490 us, release, sample for a presence pulse 70 us later, then 410 us
;   write 1: low 6 us, then 64 us released
;   write 0: low 62 us, then 10 us released
;   read:    low 6 us, release, sample 8 us later (14 us in, inside the 15 us a device
;            guarantees), then 56 us
; Reset and write 0 are a little over the 480 us and 60 us minimums: the line goes low a few
; cycles after the time they count from.
; Bytes go LSB first. Times count from the cycle counter: r4 = clock cycles per microsecond.
;
; Host word: [11:8] command, [7:0] data
;   1 RESET             reply: 0 = a device answered, 1 = nobody there
;   2 WRITE byte
;   3 READ byte         reply: byte
;   4 SPEED             data = clock cycles per microsecond (starts at 50)

      pin  p2, hiz
      ldi  r4, 50

loop: pull r5
      csrr r7, time_lo     ; times count from now (wait time only looks at 16 bits)
      mov  r6, r5
      shri r6, 8           ; r6 = command
      mov  r0, r5
      shli r0, 8
      shri r0, 8           ; r0 = data
      cmpi r6, 1
      j    z, c_reset
      cmpi r6, 2
      j    z, c_write
      cmpi r6, 3
      j    z, c_read
      cmpi r6, 4
      j    z, c_speed
      jmp  loop

c_reset:
      pin  p2, clr
      ldi  r6, 245
      call us
      ldi  r6, 245
      call us              ; 490 us low
      pin  p2, hiz
      ldi  r6, 70
      call us
      pin  p2, sample      ; C = line: low means a device is there
      ldi  r1, 0
      rlc  r1, 1
      ldi  r6, 205
      call us
      ldi  r6, 205
      call us              ; let the presence pulse end: 480 us after the release in all
      push r1
      jmp  loop

c_write:
      ldi  r2, 8
wbit: shri r0, 1           ; C = next bit, LSB first
      pin  p2, clr
      j    c, w1
      ldi  r6, 62
      call us
      pin  p2, hiz
      ldi  r6, 10
      call us
      jmp  wnext
w1:   ldi  r6, 6
      call us
      pin  p2, hiz
      ldi  r6, 64
      call us
wnext: djnz r2, wbit
      jmp  loop

c_read:
      ldi  r1, 0
      ldi  r2, 8
rbit: pin  p2, clr
      ldi  r6, 6
      call us
      pin  p2, hiz
      ldi  r6, 8
      call us
      pin  p2, sample      ; C = the bit
      rrc  r1, 1           ; in at the top: after 8 bits the first one is bit 8
      ldi  r6, 56
      call us
      djnz r2, rbit
      shri r1, 8
      push r1
      jmp  loop

c_speed:
      mov  r4, r0
      jmp  loop

; wait until r6 microseconds after the time in r7, and move r7 there
us:   add  r7, r4
      djnz r6, us
      wait time r7
      ret
