; ps2_host.s: a PS/2 host (the computer's side of a keyboard or mouse port). Written after the
; RTL freeze: firmware only.
;
; The device makes the clock. Device to host: the host reads DATA as CLK falls: start (0), 8 bits
; LSB first, odd parity, stop (1). Host to device: the host holds CLK low for 100 us, pulls DATA
; low (the start bit), lets CLK go, then sets each bit while CLK is low (8 bits, odd parity, and
; the stop bit by letting DATA go); on the next clock the device pulls DATA low to acknowledge.
;
; Pins: p0 (uio[0]) CLK, p1 (uio[1]) DATA, open drain.
; Host: bytes to send to the device. The program sends 0x100 | byte for each byte the device
; sent, 0x400 | byte if its start, stop or parity bit was wrong, and after each byte it sent,
; 0x200 if the device acknowledged it or 0x201 if not.
;
; Registers: r1 bits, r2 the frame being sent, r3 counts, r7 a deadline.

      pin  p0, hiz
      pin  p1, hiz
main: j    mbx_data, cmd
      pin  p0, sample
      j    c, main         ; CLK high: nothing is coming
      call recv            ; CLK fell: the start bit
      jmp  main

; recv: 11 bits, each read as CLK falls (CLK is low now, for the start bit)
recv: ldi  r3, 11
      ldi  r1, 0
      ldi  r0, 0xff
      ldih r0, 0xff
      csrw tmo, r0         ; a bit that does not come within 1.3 ms: start again
rbit: pin  p1, sample
      rrc  r1, 1           ; from the top: start in bit 5, data 13:6, parity 14, stop 15
      djnz r3, rnext
      jmp  rdone
rnext: wait pin p0, 1
      j    t, rlost
      wait pin p0, 0
      j    t, rlost
      jmp  rbit
rlost: csrwi tmo, 0
      ret
rdone: wait pin p0, 1      ; the stop bit's clock pulse ends before the next byte can start
      csrwi tmo, 0
      mov  r2, r1          ; odd parity over data and parity bit
      shri r2, 6
      ldi  r0, 0xff
      ldih r0, 0x01
      and  r2, r0
      call par
      shri r1, 5           ; start in bit 0, data 8:1, parity 9, stop 10
      mov  r0, r1
      shri r0, 1
      ldi  r2, 0xff
      and  r0, r2          ; the byte
      ldi  r2, 0
      ldih r2, 0x01        ; good
      tstb r1, 0
      j    nz, rbad        ; the start bit was 1
      tstb r1, 10
      j    z, rbad         ; the stop bit was 0
      tst  r3, r3
      j    nz, rgood       ; parity odd
rbad: ldi  r2, 0
      ldih r2, 0x04
rgood: or  r0, r2
      push r0
      ret

; cmd: send a byte to the device
cmd:  pull r1
      mov  r2, r1
      ldi  r0, 0xff
      and  r2, r0
      call par             ; r3 = its parity
      ldi  r0, 1
      xor  r3, r0          ; odd parity bit
      shli r3, 8
      or   r2, r3
      ldi  r0, 0
      ldih r0, 0x02
      or   r2, r0          ; the stop bit
      pin  p0, clr         ; hold CLK low for 100 us
      csrr r7, time_lo
      ldi  r0, 0x88
      ldih r0, 0x13        ; 5000 cycles
      add  r7, r0
      wait time r7
      pin  p1, clr         ; the start bit
      pin  p0, hiz         ; the device may clock now
      ldi  r0, 0xff
      ldih r0, 0xff
      csrw tmo, r0
      ldi  r3, 10
cbit: wait pin p0, 0       ; CLK low: set the next bit
      j    t, noack
      shri r2, 1
      j    c, c1
      pin  p1, clr
      jmp  c2
c1:   pin  p1, hiz
c2:   wait pin p0, 1       ; the device reads it while CLK is high
      j    t, noack
      djnz r3, cbit
      wait pin p0, 0       ; the acknowledge clock
      j    t, noack
      pin  p1, sample
      j    c, noack        ; DATA still high: no acknowledge
      wait pin p0, 1
      wait pin p1, 1       ; the device lets DATA go
      csrwi tmo, 0
      ldi  r0, 0
      ldih r0, 0x02
      push r0
      jmp  main
noack: csrwi tmo, 0
      pin  p1, hiz
      ldi  r0, 1
      ldih r0, 0x02
      push r0
      jmp  main

; par: r3 = the parity of r2's bits. Uses r0.
par:  mov  r3, r2
      mov  r0, r3
      shri r0, 8
      xor  r3, r0
      mov  r0, r3
      shri r0, 4
      xor  r3, r0
      mov  r0, r3
      shri r0, 2
      xor  r3, r0
      mov  r0, r3
      shri r0, 1
      xor  r3, r0
      ldi  r0, 1
      and  r3, r0
      ret
