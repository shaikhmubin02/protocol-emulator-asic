; can_tx.s: CAN 2.0A transmitter with arbitration, at 500 kbit/s with a 50 MHz clock (100 cycles
; a bit). Written after the RTL freeze: firmware only. The fabric cannot do CAN's transmit-side
; stuffing (it needs the run state and the bit at once), so the program stuffs, counts the CRC and
; keeps the bit timing itself. Every bit edge comes from a deadline, so bit edges sit on a grid of
; exactly 100 cycles whatever the code did in between.
;
; Pins: p0 (uio[0]) to the transceiver's TXD (1 = recessive, pulled up while not driven),
; p19 (ui[3]) the bus from its RXD.
;
; Host: write the ID (11 bits; bit 15 set for a remote frame), then the DLC (0 to 8), then the data
; two bytes a word, first byte in the high byte (an odd last byte in the high byte). Data words
; can follow while the frame goes out: the inbox holds two, a word lasts 16 bits on the bus. Each
; frame is answered with one word:
;   1 sent and acknowledged, 2 sent but nobody acknowledged, 3 lost arbitration (another node's ID
;   won; the program stopped sending), 4 bit error or the host was late with a data word.
;
; Registers while sending: r1 bits to send, first bit in bit 15; r2 how many; r3 flags (bit 0 CRC
; on, bit 1 arbitration field, bit 2 stuffing on, bit 3 remote frame, bit 4 this is a stuff bit)
; and in bits 11:8 the data bytes still to send; r4 the run of equal bits; r5 the bit being sent;
; r6 the CRC shifted up by one (CRC[14:0] in bits 15:1); r7 the time the next bit starts.

.equ BIT 100
.equ SAMPLE 50

      ldi  r0, 0xe0
      ldih r0, 0x0b        ; txcfg: bit engine TX on pin 31 (no pad); the bit engine is not used
      csrw txcfg, r0
      pin  p0, set         ; recessive

main: csrwi tmo, 0         ; wait for the next frame as long as it takes
      pull r1              ; ID word
      ldi  r0, 0
      ldih r0, 0x40        ; then 16384 cycles at most for each host word
      csrw tmo, r0
      pull r3              ; DLC
      j    t, main
      shli r3, 8           ; DLC << 8
      ldi  r0, 0x05
      or   r3, r0          ; stuffing and CRC on
      tstb r1, 15
      j    z, idle
      ldi  r0, 0x08
      or   r3, r0          ; remote frame

      ; wait for the bus to be idle: 11 recessive bits in a row
idle: ldi  r2, 11
idlb: csrr r7, time_lo
      ldi  r0, BIT
      add  r7, r0
      wait time r7
      pin  p19, sample
      j    nc, idle        ; dominant: start counting again
      djnz r2, idlb
      csrr r7, time_lo
      addi r7, 12          ; the start of frame goes out on this deadline, which the code below
                           ; reaches in time, so it is on the same grid as every later edge

      ; start of frame: one dominant bit, the first of a run
      ldi  r4, 1
      ldi  r5, 0
      ldi  r6, 0
      call drive
      ; identifier, 11 bits: the arbitration field
      shli r1, 5           ; ID left-aligned (the remote flag in bit 15 goes out of the word)
      ldi  r2, 11
      ldi  r0, 0x02
      or   r3, r0
      call bits
      ldi  r0, 0x02
      xor  r3, r0
      ; control field: RTR, IDE = 0, r0 = 0, DLC
      mov  r1, r3
      ldi  r0, 0x00
      ldih r0, 0x0f
      and  r1, r0          ; DLC in bits 11:8
      shli r1, 1           ; DLC in bits 12:9; RTR IDE r0 in bits 15:13
      tstb r3, 3
      j    z, ctl
      ldi  r0, 0
      ldih r0, 0x80
      or   r1, r0          ; RTR
ctl:  ldi  r2, 7
      call bits
      ; data field: DLC bytes (none in a remote frame), one host word (two bytes) at a time
data: tstb r3, 3
      j    nz, crc
      mov  r0, r3
      shri r0, 8
      tst  r0, r0
      j    z, crc
      cmpi r0, 2
      pull r1              ; a wait does not change the flags
      j    t, berr         ; the host was too late
      j    c, one          ; one byte left
      ldi  r2, 16
      ldi  r0, 0
      ldih r0, 0x02
      sub  r3, r0          ; two bytes fewer
      call bits
      jmp  data
one:  ldi  r2, 8
      ldi  r0, 0
      ldih r0, 0x01
      sub  r3, r0
      call bits
      ; CRC sequence: 15 bits, stuffed, not part of the CRC
crc:  mov  r1, r6
      ldi  r2, 15
      ldi  r0, 0x01
      xor  r3, r0          ; CRC off
      call bits
      call tail            ; a stuff bit due after the last CRC bit
      ldi  r0, 0x04
      xor  r3, r0          ; no stuffing from here on
      ldi  r5, 1           ; CRC delimiter: recessive
      call drive
      ; ACK slot: send recessive and look; a receiver that got the frame fills it with a dominant bit
      ldi  r0, 1
      rrc  r0, 1
      wait time r7
      pin  p0, c
      ldi  r0, SAMPLE
      add  r0, r7
      wait time r0
      pin  p19, sample
      ldi  r1, 1           ; acknowledged
      j    nc, acked
      ldi  r1, 2           ; nobody acknowledged
acked: ldi r0, BIT
      add  r7, r0
      ldi  r2, 8           ; ACK delimiter and end of frame: 8 recessive bits
eof:  call drive
      djnz r2, eof
      push r1
      jmp  main

; send r2 bits from r1 (first bit in bit 15) with stuffing, CRC and bus checking as r3 says
bits: call tail            ; a stuff bit first, if five equal bits went out
      shli r1, 1           ; C = the next bit
      ldi  r0, 0
      rlc  r0, 1
      cmp  r0, r5
      j    z, same
      mov  r5, r0
      ldi  r4, 0
same: addi r4, 1
      call drive
      djnz r2, bits
      ret

; if stuffing is on and the last five bits were equal, send one bit of the other value (it starts
; the next run and is not part of the CRC)
tail: tstb r3, 2
      j    z, tdone
      cmpi r4, 5
      j    nz, tdone
      ldi  r0, 1
      xor  r5, r0
      ldi  r4, 1
      ldi  r0, 0x10
      or   r3, r0          ; a stuff bit
      call drive
      ldi  r0, 0x10
      xor  r3, r0
tdone: ret

; send the bit in r5 at time r7, add it to the CRC (CRC on and not a stuff bit), sample the bus
; SAMPLE cycles in and check it, then move r7 to the next bit
drive: mov r0, r5
      rrc  r0, 1           ; C = the bit
      wait time r7
      pin  p0, c
      tstb r3, 0
      j    z, nocrc
      tstb r3, 4
      j    nz, nocrc
      shli r6, 1           ; C = CRC[14]
      ldi  r0, 0
      rlc  r0, 1
      xor  r0, r5          ; feedback = CRC[14] xor the bit
      j    z, nocrc
      ldi  r0, 0x32
      ldih r0, 0x8b        ; 0x4599 << 1
      xor  r6, r0
nocrc: ldi r0, SAMPLE
      add  r0, r7
      wait time r0
      pin  p19, sample     ; C = the bus
      ldi  r0, 0
      rlc  r0, 1
      cmp  r0, r5
      j    z, fine
      tstb r3, 1           ; the bus is not what we sent
      j    nz, lost        ; in the arbitration field: another node's ID won
      jmp  berr
fine: ldi  r0, BIT
      add  r7, r0
      ret

lost: pin  p0, set         ; stop sending
      ldi  r1, 3
      jmp  drain
berr: pin  p0, set
      ldi  r1, 4
      ; take the frame's data words the host has not had taken yet, so the next frame starts clean
drain: tstb r3, 3
      j    nz, report      ; a remote frame has none
      mov  r2, r3
      shri r2, 8           ; data bytes not taken yet
      addi r2, 1
      shri r2, 1           ; words
      j    z, report
drw:  pull r0
      j    t, report
      djnz r2, drw
report: push r1
      jmp  main
