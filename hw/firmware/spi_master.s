; SPI master, mode 0 (clock idles low, sample on the rising edge), MSB first.
; SCK = p9 (uo[1]), MOSI = p10 (uo[2]), CS = p11 (uo[3]), MISO = p20 (ui[4]).
; Host word: [7:0] byte to send, [8] lower CS first, [9] raise CS after.
; Reply: the byte received.

.equ HALF 4

      pin  p11, set        ; CS idle high
      pin  p9, clr         ; SCK idle low

loop: pull r5
      tstb r5, 8
      j    z, nocs
      pin  p11, clr, HALF  ; select
nocs: mov  r0, r5
      shli r0, 8           ; byte in bits 15..8
      ldi  r1, 0
      ldi  r3, 8

bit:  shli r0, 1           ; C = next bit out
      pin  p10, c, HALF    ; MOSI, then let it settle
      pin  p9, set         ; rising edge: both sides sample
      pin  p20, sample     ; C = MISO
      rlc  r1, 1
      pin  p9, clr, HALF   ; falling edge: target shifts out its next bit
      djnz r3, bit

      push r1
      tstb r5, 9
      j    z, loop
      pin  p11, set        ; deselect
      jmp  loop
