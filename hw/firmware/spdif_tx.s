; spdif_tx.s: S/PDIF transmitter (IEC 60958, consumer audio): biphase-mark coding done by the LUT
; fabric (bmc_tx in hw/post/fabric_post.ml), with the preambles sent in its raw mode. Written
; after the RTL freeze: firmware and a fabric configuration.
;
; A subframe is 32 bit cells = 64 half-bit ticks: the preamble (8 half cells, raw), then 28 bits
; in biphase-mark: aux and audio (24 bits, LSB first), V, U, C, and P (even parity over the 27
; bits before it). The shifter takes three words per subframe: the preamble (8 bits, raw: 1 = a
; transition), A = slots 4 to 19 (16 bits), B = slots 20 to 31 (12 bits). The program switches
; the fabric between raw and biphase-mark at exact ticks, counted from the moment the shifter
; loads the word before: raw to biphase after the preamble's 8th half cell, back to raw after
; the parity bit.
;
; Pin: p8 (uo[0]) to the S/PDIF driver.
; Host: first the half-bit tick, whole cycles and then the 1/256 fraction (8 and 35 for
; 48 kHz at 50 MHz: 128 ticks a frame). Then per subframe two words: audio bits 15:0, then
; audio bits 23:16 | V << 8 | U << 9 | C << 10 | the preamble << 12 (0 M, 1 W, 2 B).
;
; Registers: r1 the next preamble, r2 word A, r3 word B, r4 FABCTL biphase-mark, r5 FABCTL raw.

      pull r0
      csrw baud, r0
      pull r0
      csrw baudf, r0
      ldi  r4, 0x42
      ldih r4, 0x02        ; fabctl: line = element 1, hold = element 2, hold on, ext2 = 0
      mov  r5, r4
      addi r5, 1           ; the same with ext2 = 1: raw
      csrw fabctl, r5      ; the stream starts with a preamble
      ldi  r0, 0x07
      ldih r0, 0x05        ; txcfg: 8 bits, LSB first, pin 8, through the fabric
      csrw txcfg, r0
      call next
      ben  1               ; (it empties the holding register, so the word comes after it)
      tx   r1              ; the first preamble, loaded on the first tick

loop: wait event tx_empty  ; the preamble is going out: its first half cell is tick T
      wait event tick      ; T+1
      ldi  r0, 0x0f
      ldih r0, 0x05        ; 16 bits
      csrw txcfg, r0
      tx   r2              ; A, loaded at T+8
      wait event tick      ; T+2
      ldi  r0, 5
pre:  wait event tick
      djnz r0, pre         ; T+7: the preamble's last half cell
      csrw fabctl, r4      ; biphase-mark from T+8
      wait event tx_empty  ; A is going out
      ldi  r0, 0x0b
      ldih r0, 0x05        ; 12 bits
      csrw txcfg, r0
      tx   r3              ; B, loaded at T+40
      call next            ; the next subframe's words, while A goes out
      wait event tx_empty  ; B is going out (T+40)
      wait event tick      ; T+41
      ldi  r0, 0x07
      ldih r0, 0x05        ; 8 bits
      csrw txcfg, r0
      tx   r1              ; the next preamble, loaded at T+64
      ldi  r0, 22
dat:  wait event tick
      djnz r0, dat         ; T+63: the parity bit's second half
      csrw fabctl, r5      ; raw from T+64
      jmp  loop

; next: take a subframe from the host: r1 = its preamble as transitions, r2 = A, r3 = B with
; the parity bit. Uses r0, r6, r7.
next: pull r2
      pull r3
      mov  r0, r3
      shri r0, 12
      ldi  r1, 0xc9        ; M (X): 1110 0010 from a low line
      cmpi r0, 1
      j    nz, n1
      ldi  r1, 0x69        ; W (Y): 1110 0100
n1:   cmpi r0, 2
      j    nz, n2
      ldi  r1, 0x39        ; B (Z): 1110 1000
n2:   ldi  r0, 0xff
      ldih r0, 0x07
      and  r3, r0          ; slots 20 to 30
      mov  r6, r2          ; their parity, with A's
      xor  r6, r3
      mov  r7, r6
      shri r7, 8
      xor  r6, r7
      mov  r7, r6
      shri r7, 4
      xor  r6, r7
      mov  r7, r6
      shri r7, 2
      xor  r6, r7
      mov  r7, r6
      shri r7, 1
      xor  r6, r7
      ldi  r7, 1
      and  r6, r7
      shli r6, 11
      or   r3, r6          ; P: even parity over slots 4 to 31
      ret
