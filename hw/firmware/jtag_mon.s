; jtag_mon.s: a passive JTAG monitor (IEEE 1149.1): follows the TAP state machine from TCK and
; TMS and records every scan, without driving anything. Written after the RTL freeze: firmware only.
;
; A scan runs from Capture-DR (or -IR) to Update-DR (or -IR); Pause states in between are part of
; it. TDI, TDO and TMS are sampled right after each rising edge of TCK.
;
; Pins (all inputs): p20 (ui[4]) TCK, p21 (ui[5]) TMS, p22 (ui[6]) TDI, p23 (ui[7]) TDO.
; Host gets, per scan: for every 15 bits a TDI word and a TDO word (the first bit in bit 0, bit 15
; always 0); at the end the bits left over, if any, as a TDI word and a TDO word with the last bit
; in bit 14; then 0x8000 | the number of bits, | 0x4000 for an IR scan. Data words carry 15 bits
; so that bit 15 tells them from the end word.
;
; Registers: r1 TDI bits, r2 TDO bits, r4 bits in this word, r5 bits in this scan, r7 the IR flag.

tlr:  wait pin p20, 0      ; Test-Logic-Reset
      wait pin p20, 1
      pin  p21, sample
      j    c, tlr
rti:  wait pin p20, 0      ; Run-Test/Idle
      wait pin p20, 1
      pin  p21, sample
      j    nc, rti
sdr:  wait pin p20, 0      ; Select-DR-Scan
      wait pin p20, 1
      pin  p21, sample
      j    c, sir
      ldi  r7, 0
      jmp  cap
sir:  wait pin p20, 0      ; Select-IR-Scan
      wait pin p20, 1
      pin  p21, sample
      j    c, tlr
      ldi  r7, 0
      ldih r7, 0x40
cap:  ldi  r5, 0           ; Capture
      ldi  r4, 0
      wait pin p20, 0
      wait pin p20, 1
      pin  p21, sample
      j    c, ex1
sh:   wait pin p20, 0      ; Shift
      wait pin p20, 1
      pin  p22, sample
      rrc  r1, 1
      pin  p23, sample
      rrc  r2, 1
      pin  p21, sample
      j    c, shx
      call word
      jmp  sh
shx:  call word            ; the last bit
ex1:  wait pin p20, 0      ; Exit1
      wait pin p20, 1
      pin  p21, sample
      j    c, upd
pau:  wait pin p20, 0      ; Pause
      wait pin p20, 1
      pin  p21, sample
      j    nc, pau
      wait pin p20, 0      ; Exit2
      wait pin p20, 1
      pin  p21, sample
      j    nc, sh
upd:  tst  r4, r4          ; Update: report the scan
      j    z, u2
      shri r1, 1
      shri r2, 1
      push r1
      push r2
u2:   mov  r0, r5
      or   r0, r7
      ldi  r3, 0
      ldih r3, 0x80
      or   r0, r3
      push r0
      wait pin p20, 0
      wait pin p20, 1
      pin  p21, sample
      j    c, sdr
      jmp  rti

; one more bit in the scan; 15 of them go to the host
word: addi r5, 1
      addi r4, 1
      cmpi r4, 15
      j    nz, w2
      shri r1, 1
      shri r2, 1
      push r1
      push r2
      ldi  r4, 0
w2:   ret
