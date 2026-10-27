; 10BASE-T transmitter on TD = p8 (uo[0]). Clock 50 MHz: 5 cycles a bit.
;
; The bit engine does the Manchester coding (fabric bitstream eth_tx, half-bit ticks of 2.5
; cycles) and the CRC unit sends the FCS right after the data with no gap ("send" mode).
; Configuration the host loads with the program:
;   fabric   Bitstream.eth_tx
;   CRC      poly 0x04C11DB7, init 0x13256D64 (all ones, run back over the preamble and SFD,
;            because they go through the CRC too)
;
; The host's SPI port is slower than the line, so the frame can't be streamed in. It is part of
; the program instead, at label `frame` (the end of this file), as code: for each pair of bytes
;       ldi  r0, <first byte>
;       ldih r0, <second byte>
;       tx   r0
; and for an odd last byte
;       wait event tx_empty
;       csrw txcfg, r5
;       ldi  r0, <byte>
;       tx   r0
; then `ret`. Destination address first, no preamble, no FCS.
;
; Between frames it sends a link pulse (100 ns high) every 15.7 ms. Any word from the host
; sends the frame once; the host can reload `frame` while the engine is stopped.
;
; r0 data   r2 link pulse count   r3 longest timeout   r4 txcfg with idle high
; r5 txcfg for 8 bits   r6 txcfg   r7 time

      csrwi baud, 2
      ldi  r6, 0x80
      csrw baudf, r6       ; a tick every 2.5 cycles: two per bit
      ldi  r6, 0x02
      ldih r6, 0x02        ; fabctl: line = element 1, hold = element 0, hold on
      csrw fabctl, r6
      ldi  r6, 0x0f
      ldih r6, 0x05        ; txcfg: 16 bits, LSB first, pin 8, through the fabric, idle low
      ldi  r5, 0x07
      ldih r5, 0x05        ; the same for 8 bits
      ldi  r4, 0x0f
      ldih r4, 0x0d        ; the same with the idle level high
      ldi  r3, 0xff
      ldih r3, 0xff
      jmp  idle            ; a link partner wants link pulses before any frame

send: csrwi tmo, 0
      csrw txcfg, r6
      csrwi crcctl, 1      ; CRC on, fed with the bits sent
      crci
      ben  1
      ldi  r0, 0x55
      ldih r0, 0x55
      tx   r0
      tx   r0
      tx   r0
      ldih r0, 0xd5        ; the last 0x55, then the SFD
      tx   r0
      call frame
      tx   r0              ; FCS: a dummy word, taken once the last data has started
      csrw txcfg, r6       ; back to 16 bits after an odd last byte
      csrwi crcctl, 0x11   ; words from now on carry the CRC
      tx   r0
      wait event tx_empty  ; the second half of the FCS has started: 80 cycles left
      csrr r7, time_lo
      csrw txcfg, r4       ; after it the line stays high (TP_IDL)...
      addi r7, 46
      addi r7, 44
      wait time r7
      ben  0
      pin  p8, clr         ; ...for 280 ns, then idle (counted from the last rising edge,
                           ; as 802.3 does, that is 280-340 ns)

idle: csrw tmo, r3
      ldi  r2, 12
il:   wait event mailbox   ; gives up after 65535 cycles
      j    nt, go
      djnz r2, il
      pin  p8, set, 4      ; link pulse
      pin  p8, clr
      jmp  idle
go:   pull r0
      jmp  send

frame:
