; cec.s: an HDMI-CEC device: it follows every frame on the bus, acknowledges the ones addressed
; to it, and sends frames for the host. Written after the RTL freeze: firmware only.
;
; One open-drain line, pulled high. Times are in units of 50 us (the host gives one unit in
; cycles). A start bit is low for 3.7 ms (74 units) in a 4.5 ms period (90); a data bit is a
; 2.4 ms period (48), low for 1.5 ms (30) for a 0 or 0.6 ms (12) for a 1, read 1.05 ms (21)
; after it falls. A block is 8 bits MSB first, EOM (1 on the last block) and ACK: the initiator
; sends ACK as a 1, and a follower the frame is addressed to holds the line low to 1.5 ms (a 0)
; to acknowledge; for a broadcast (destination 15) a 0 means a follower rejects it. The first
; block is the header: initiator << 4 | destination. Before sending, the line must have been
; free for 7 bit periods; while sending its first four bits, an initiator that reads a 0 where
; it sent a 1 has lost arbitration and stops.
;
; Pin: p0 (uio[0]) the CEC line, open drain.
; Host: first one unit (50 us) in cycles and the device's logical address. To send: the number
; of bytes, then the bytes (the header first). The program sends 0x100 | byte for each block it
; read (| 0x200 on the last block, | 0x400 if it was acknowledged, that is if the ACK bit was 0),
; and after each frame it sent 0x8000 | status: 0 done, 1 not acknowledged (for a broadcast:
; rejected), 2 lost arbitration (or another device pulled the line where a 1 was sent). After
; losing arbitration it does not pick up the rest of the winner's frame.
;
; Registers: r7 a unit, r6 the address, r5 the deadline, r4 bits left in a block, r3 bytes left
; or flags, r2 status, r1 the block, r0 counts.

      pin  p0, hiz
      pull r7
      pull r6

idle: ldi  r3, 0           ; units the line has been free
      csrw tmo, r7
il:   wait pin p0, 0
      j    nt, rx          ; it fell: a frame starts
      ldi  r0, 0x50
      ldih r0, 0x01        ; 336 units: 7 bit periods
      cmp  r3, r0
      j    nc, free
      addi r3, 1
      jmp  il
free: j    mbx_data, tx
      jmp  il

; ---- receive. A start bit: low for 70 units, high again by 78, the next fall by 94
rx:   ldi  r0, 70          ; low all the way to 70 units, or it is not a start bit
      call high
      j    nt, idle
      ldi  r0, 8
      call high
      j    t, stuck
      ldi  r0, 24          ; the first bit's fall: the start bit's period is 86 to 94 units
      call fall
      j    t, idle
      ldi  r3, 0           ; flags: 1 header done, 2 for us
blk:  ldi  r4, 10
      ldi  r1, 0
rbit: tstb r3, 1           ; the ACK bit of a block for us: hold the line low to 30 units
      j    z, rb1
      cmpi r4, 1
      j    nz, rb1
      pin  p0, clr
rb1:  ldi  r0, 21
      call wu
      pin  p0, sample      ; the bit
      rlc  r1, 1
      tstb r3, 1
      j    z, rb2
      cmpi r4, 1
      j    nz, rb2
      ldi  r0, 9
      call wu
      pin  p0, hiz
rb2:  cmpi r4, 3           ; after the header's eighth bit: is it for us?
      j    nz, rb3
      tstb r3, 0
      j    nz, rb3
      mov  r0, r1
      ldi  r2, 0x0f
      and  r0, r2
      cmp  r0, r6
      j    nz, rb3
      ldi  r2, 2
      or   r3, r2
rb3:  djnz r4, rnext
      mov  r0, r1          ; the block: 8 bits, EOM, ACK
      shri r0, 2
      ldi  r2, 0xff
      and  r0, r2
      ldi  r2, 0
      ldih r2, 0x01
      or   r0, r2
      tstb r1, 1
      j    z, nl
      ldi  r2, 0
      ldih r2, 0x02        ; the last block
      or   r0, r2
nl:   tstb r1, 0
      j    nz, na
      ldi  r2, 0
      ldih r2, 0x04        ; acknowledged
      or   r0, r2
na:   push r0
      ldi  r2, 1
      or   r3, r2          ; the header is done
      tstb r1, 1
      j    nz, idle        ; EOM
      call next
      j    t, idle
      jmp  blk
rnext: call next
      j    t, idle
      jmp  rbit
stuck: csrwi tmo, 0        ; held low: wait it out
      wait pin p0, 1
      jmp  idle

; ---- send. r3 bytes; r2 status; the start bit, then the blocks
tx:   pull r3
      ldi  r2, 0
      csrr r5, time_lo
      pin  p0, clr
      ldi  r0, 74
      call wu
      pin  p0, hiz
      ldi  r0, 16
      call wu
      pull r1              ; the header
      mov  r0, r1
      ldi  r4, 0x0f
      and  r0, r4
      cmpi r0, 15
      j    nz, tb0
      ldi  r2, 0x20        ; a broadcast: the ACK sense is the other way
      jmp  tb0
tblk: pull r1
tb0:  shli r1, 2           ; 8 bits, then EOM and ACK
      cmpi r3, 1
      j    nz, te
      addi r1, 2           ; EOM on the last block
te:   addi r1, 1           ; ACK sent as 1
      shli r1, 6           ; the first bit in bit 15
      ldi  r4, 10
tbit: pin  p0, clr
      shli r1, 1
      j    c, t1
      ldi  r0, 30          ; a 0
      call wu
      pin  p0, hiz
      ldi  r0, 18
      call wu
      jmp  tn
t1:   ldi  r0, 12          ; a 1: let go at 12, read at 21
      call wu
      pin  p0, hiz
      ldi  r0, 9
      call wu
      pin  p0, sample
      j    c, t2           ; high, as sent
      cmpi r4, 1
      j    z, ack          ; low in the ACK bit: acknowledged
      ldi  r2, 2           ; low where a 1 was sent: another initiator won
      csrwi tmo, 0
      wait pin p0, 1
      jmp  drain
ack:  ldi  r0, 0x10        ; a 0 in the ACK bit
      or   r2, r0
t2:   ldi  r0, 27
      call wu
tn:   djnz r4, tbit
      mov  r0, r2          ; acknowledged: a 0 for a frame to one device, a 1 for a broadcast
      shri r0, 4
      ldi  r4, 1
      and  r0, r4          ; 1 if the ACK bit was 0
      tstb r2, 5
      j    z, tk
      xor  r0, r4
tk:   tst  r0, r0
      j    nz, acked
      ldi  r2, 1           ; not acknowledged (a broadcast: rejected)
      jmp  drain
acked: ldi r0, 0x10
      and  r0, r2
      xor  r2, r0          ; clear the ACK mark for the next block
      djnz r3, tblk
      ldi  r2, 0
      jmp  done
drain: subi r3, 1         ; the frame's bytes not sent are dropped
      j    z, done
dr1:  pull r0
      djnz r3, dr1
done: ldi  r0, 0
      ldih r0, 0x80
      or   r0, r2
      push r0
      jmp  idle

; wu: wait r0 units after the deadline r5 (r5 moves on)
wu:   add  r5, r7
      wait time r5
      djnz r0, wu
      ret

; high: wait for the line high, up to r0 units; T = 1 if it stayed low
high: csrw tmo, r7
hi1:  wait pin p0, 1
      j    nt, hi2
      djnz r0, hi1
hi2:  ret

; fall: wait for the line to fall, up to r0 units; T = 1 if it did not. r5 = when it fell.
fall: csrw tmo, r7
fa1:  wait pin p0, 0
      j    nt, fa2
      djnz r0, fa1
      ret
fa2:  csrr r5, time_lo
      ret

; next: from a bit's read point, the line must go high (by 30 units) and fall again by 55 units
; from the bit's start: T = 1 if not (the frame is over)
next: ldi  r0, 15
      call high
      j    t, nx
      ldi  r0, 34
      call fall
nx:   ret
