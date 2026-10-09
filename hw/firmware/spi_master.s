; SPI master, modes 0 to 3, MSB first.
; SCK = p9 (uo[1]), MOSI = p10 (uo[2]), CS = p11 (uo[3]), MISO = p20 (ui[4]).
; Host word with bit 15 set: pick the mode from bits [1:0] (bit 1 = CPOL, bit 0 = CPHA).
;   Starts in mode 0. Send it while CS is high.
; Other host words: [7:0] byte to send, [8] lower CS first, [9] raise CS after.
; Reply: the byte received.
;
; CPOL only sets the level SCK idles at. Every edge is a toggle, so the same code makes the
; leading and trailing edges for either polarity. CPHA picks which edge samples:
;   CPHA 0: data out before the leading edge, both sides sample on it.
;   CPHA 1: both sides change data on the leading edge and sample on the trailing one.

.equ HALF 4

      pin  p11, set        ; CS idle high
      pin  p9, clr         ; SCK idle low
      ldi  r6, 0           ; mode

loop: pull r5
      tstb r5, 15
      j    nz, mode
      tstb r5, 8
      j    z, nocs
      pin  p11, clr, HALF  ; select
nocs: mov  r0, r5
      shli r0, 8           ; byte in bits 15..8
      ldi  r1, 0
      ldi  r3, 8
      tstb r6, 0
      j    nz, cpha1

cpha0: shli r0, 1          ; C = next bit out
      pin  p10, c, HALF    ; MOSI, then let it settle
      pin  p9, tgl         ; leading edge: both sides sample
      pin  p20, sample     ; C = MISO
      rlc  r1, 1
      pin  p9, tgl, HALF   ; trailing edge: target shifts out its next bit
      djnz r3, cpha0
      jmp  done

cpha1: shli r0, 1
      pin  p9, tgl         ; leading edge: both sides shift out
      pin  p10, c, HALF
      pin  p9, tgl         ; trailing edge: both sides sample
      pin  p20, sample
      rlc  r1, 1
      djnz r3, cpha1

done: push r1
      tstb r5, 9
      j    z, loop
      pin  p11, set        ; deselect
      jmp  loop

mode: mov  r6, r5
      pin  p9, clr         ; idle low for CPOL 0
      tstb r5, 1
      j    z, loop
      pin  p9, set         ; idle high for CPOL 1
      jmp  loop
