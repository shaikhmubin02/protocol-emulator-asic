; SPI target (the other end from spi_master.s), modes 0 to 3, MSB first.
; SCK = p21 (ui[5]), MOSI = p22 (ui[6]), CS = p23 (ui[7]), MISO = p0 (uio[0]). MISO is only
; driven while CS is low, so other targets can share the bus.
;
; Host words: 0x8000 + mode (bit 1 = CPOL, bit 0 = CPHA) between transactions; starts in mode 0.
;   Any other word: [7:0] the next byte to send. With nothing waiting it sends 0xFF.
; Replies: each byte received, and 0x100 when CS goes high (a partial byte is dropped).
;
; Every wait gives up after 8 cycles to look at CS, then waits again, so CS going high is seen
; at any point. The work between bytes is done right after the last bit is sampled, before the
; edge that shifts out the next one.
;
; r0 bits to send (in [15:8])   r1 bits received   r3 bits left
; r4 set while r0 holds a host byte none of which has been clocked out   r5 host word   r6 mode

      csrwi jpin, 23       ; jpin_hi = CS high
      csrwi tmo, 8
      pin  p0, hiz
      ldi  r6, 0
      ldi  r4, 0

idle: wait pin p23, 0
      j    nt, sel
      tstb r4, 0
      j    nz, idle        ; already holding the first byte
      j    mbx_data, get
      jmp  idle
get:  pull r5
      tstb r5, 15
      j    nz, mode
      mov  r0, r5
      shli r0, 8
      ldi  r4, 1
      jmp  idle
mode: mov  r6, r5
      jmp  idle

sel:  tstb r4, 0
      j    nz, sel1
      call fetch
sel1: ldi  r1, 0
      ldi  r3, 8
      tstb r6, 1
      j    nz, cpol1
      tstb r6, 0
      j    nz, m1
      jmp  m0
cpol1: tstb r6, 0
      j    nz, m3
      jmp  m2

; mode 0: out before the rising edge, sample on it, shift out on the falling edge
m0:   shli r0, 1
      pin  p0, c
m0r:  wait pin p21, 1
      j    nt, m0s
      j    jpin_hi, end
      jmp  m0r
m0s:  pin  p22, sample
      ldi  r4, 0           ; the byte being sent is in use
      rlc  r1, 1
      djnz r3, m0f
      call next
m0f:  wait pin p21, 0
      j    nt, m0
      j    jpin_hi, end
      jmp  m0f

; mode 1: shift out on the rising edge, sample on the falling edge
m1:   wait pin p21, 1
      j    nt, m1o
      j    jpin_hi, end
      jmp  m1
m1o:  shli r0, 1
      pin  p0, c
m1f:  wait pin p21, 0
      j    nt, m1s
      j    jpin_hi, end
      jmp  m1f
m1s:  pin  p22, sample
      ldi  r4, 0           ; the byte being sent is in use
      rlc  r1, 1
      djnz r3, m1
      call next
      jmp  m1

; mode 2: mode 0 with SCK inverted
m2:   shli r0, 1
      pin  p0, c
m2f:  wait pin p21, 0
      j    nt, m2s
      j    jpin_hi, end
      jmp  m2f
m2s:  pin  p22, sample
      ldi  r4, 0           ; the byte being sent is in use
      rlc  r1, 1
      djnz r3, m2r
      call next
m2r:  wait pin p21, 1
      j    nt, m2
      j    jpin_hi, end
      jmp  m2r

; mode 3: mode 1 with SCK inverted
m3:   wait pin p21, 0
      j    nt, m3o
      j    jpin_hi, end
      jmp  m3
m3o:  shli r0, 1
      pin  p0, c
m3r:  wait pin p21, 1
      j    nt, m3s
      j    jpin_hi, end
      jmp  m3r
m3s:  pin  p22, sample
      ldi  r4, 0           ; the byte being sent is in use
      rlc  r1, 1
      djnz r3, m3
      call next
      jmp  m3

; a byte is in: hand it over and get the next one to send
next: push r1
      ldi  r1, 0
      ldi  r3, 8
fetch: ldi r0, 0
      ldih r0, 0xff
      j    mbx_data, f1
      ret
f1:   pull r5
      mov  r0, r5
      shli r0, 8
      ldi  r4, 1
      ret

end:  pin  p0, hiz
      tstb r4, 0
      j    z, end1
      mov  r0, r5          ; a byte was fetched but none of it was clocked out: keep it
      shli r0, 8
end1: ldi  r5, 0
      ldih r5, 1
      push r5
      jmp  idle
