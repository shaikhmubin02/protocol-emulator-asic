; dmx_rx.s: a DMX512 receiver that works as a fixture does (ANSI E1.11): it keeps the channels
; from its start address on. Receiver timing from the standard: a break is a low of 88 us or more,
; the MAB a high of 8 us or more. Written after the RTL freeze: firmware only.
;
; The bit engine takes the slots in (11 bits, LSB first, starting on a falling edge). A break
; first reads as a slot with every bit low, stop bits included; the program then times the rest
; of the low from its falling edge (CAP) and the MAB on the pin, each with a wait timeout, so a
; break of any length is measured right.
;
; Pin: p19 (ui[3]) from the RS-485 receiver (1 = mark).
; Host: first the bit time in cycles (200 at 50 MHz), the start address A (1 to 512) and the
; footprint F (1 or more channels). For each packet with the null start code the program sends
; the values of channels A to A + F - 1 as they come in. Every other word is 0x100 or more:
;   0x0100 | sc  a packet with another start code, skipped
;   0x8000 | n   a break after n slots (start code included), before channel A + F - 1: the
;                values sent for that packet are not all there
;   0x4000 | n   slot n (0 = the start code) had a stop bit low: the rest of the packet is dropped
;   0x2001       a low too short for a break (under 88 us), ignored
;   0x2002       a MAB under 8 us: the packet is ignored
;
; Registers: r7 bit time, r5 A, r6 F, r3 the number of the next slot, r4 channels still to send.

      ldi  r0, 0x6a
      ldih r0, 0x12        ; rxcfg: 11 bits, LSB first, pin 19, start on a falling edge
      csrw rxcfg, r0
      ldi  r0, 0xe0
      ldih r0, 0x0b        ; txcfg: TX pin 31 (no pad); this engine only receives
      csrw txcfg, r0
      csrwi capcfg, 0x33   ; CAP = the time of the last falling edge on p19
      pull r7
      csrw baud, r7
      pull r5
      pull r6
      ben  1

hunt: rx   r0              ; skip slots until a break
      tst  r0, r0
      j    nz, hunt

      ; 11 bits low so far: a break if the line is still low 88 us (22 bits) after it fell
brk:  csrr r1, time_lo
      csrr r2, cap
      sub  r1, r2          ; low for this long already
      mov  r2, r7
      shli r2, 1           ; 2 bits
      mov  r0, r2
      shli r0, 1
      add  r2, r0          ; 6 bits
      shli r0, 2
      add  r2, r0          ; 22 bits
      sub  r2, r1          ; still to go
      csrw tmo, r2
      wait pin p19, 1
      j    t, long         ; timed out still low: a break
      csrwi tmo, 0
      ldi  r0, 0x01
      ldih r0, 0x20
      push r0              ; too short for a break
      jmp  hunt
long: csrwi tmo, 0
      wait pin p19, 1      ; the end of the break
      mov  r2, r7
      shli r2, 1           ; 8 us
      csrw tmo, r2
      wait pin p19, 0      ; the start bit of the start code
      j    t, mab
      csrwi tmo, 0
      ldi  r0, 0x02
      ldih r0, 0x20
      push r0              ; MAB too short
      jmp  hunt
mab:  csrwi tmo, 0         ; the bit engine takes the start code in on its own falling edge
      ldi  r3, 0
      call get
      j    nz, cut
      tst  r0, r0
      j    z, null
      ldi  r1, 0
      ldih r1, 0x01
      or   r1, r0
      push r1              ; another start code: skip the packet
      jmp  hunt
null: ldi  r3, 1
      mov  r4, r6
chan: call get
      j    nz, cut
      cmp  r3, r5
      j    c, next         ; before the start address
      push r0
      djnz r4, next
      jmp  hunt            ; all F channels sent: skip the rest of the packet
next: addi r3, 1
      jmp  chan

      ; slot r3 was not a good slot: r1 = 1 a break began, 2 a stop bit was low
cut:  cmpi r1, 1
      j    nz, frame
      ldi  r0, 0
      ldih r0, 0x80
      or   r0, r3
      push r0              ; the packet ended after r3 slots
      jmp  brk
frame: ldi r0, 0
      ldih r0, 0x40
      or   r0, r3
      push r0
      jmp  hunt

; the next slot: r0 = its byte and Z = 1; or Z = 0 and r1 = 1 if all 11 bits were low (a break
; began), 2 if a stop bit was low
get:  rx   r0
      ldi  r1, 1
      tst  r0, r0
      j    z, gx
      ldi  r1, 2
      mov  r2, r0
      shri r2, 9
      cmpi r2, 3
      j    nz, gx          ; a stop bit low
      shri r0, 1
      ldi  r2, 0xff
      and  r0, r2
      ldi  r1, 0
gx:   tst  r1, r1
      ret
