; 10BASE-T receiver: RD on p19 (ui[3]), from a line receiver that turns the pair into a logic
; level. Clock 50 MHz.
;
; The bit engine samples RD every cycle and the fabric (bitstream eth_rx) decodes the
; Manchester code: it takes the mid-bit edges, skips the bit-boundary ones, finds the SFD and
; only lets frame bits through, so the RX words are already the frame's bytes. The CRC unit
; checks the FCS on the same bits (CRC config: poly 0x04C11DB7, init 0xFFFFFFFF).
;
; The frame is too fast for the host's SPI port, so it goes out on pins as it arrives, a nibble
; at a time like MII, low nibble first:
;   p9..p12  RXD0..3
;   p13      DV, high from the first nibble to the end of the frame
;   p14      strobe: RXD is good on its rising edge, 200 ns after it changes (2.5 MHz, but only
;            while a frame comes in)
; After each frame the host gets one mailbox word: [14:0] the number of bytes including the
; FCS, [15] set if the FCS was right.
;
; r0 byte   r1 bus   r2/r7 CRC vs. its value after a good FCS   r3/r4 that value
; r5 0x0f   r6 bytes

      ldi  r6, 0x67
      ldih r6, 0x06        ; rxcfg: 8 bits, LSB first, pin 19, through the fabric, free-running
      csrw rxcfg, r6
      ldi  r6, 0x00
      ldih r6, 0x04        ; fabctl: rx bit = element 1
      csrw fabctl, r6
      ldi  r6, 0xf6
      csrw fabctl2, r6     ; drop = element 6 (on), flag = element 7
      csrwi crcctl, 3      ; CRC on, fed with the bits kept
      csrwi baud, 1        ; a sample every cycle
      ldi  r6, 0xa9
      csrw group0, r6      ; group 0: 6 pins from p9
      ldi  r1, 0
      outg 0, r1
      csrwi tmo, 60        ; a frame has ended when no byte comes for 60 cycles
      ldi  r3, 0x7b
      ldih r3, 0xdd
      ldi  r4, 0x04
      ldih r4, 0xc7        ; 0xc704dd7b
      ldi  r5, 0x0f

frame: crci
      ben  1               ; clears the decoder, so it looks for a new SFD
      ldi  r6, 0
first: rx   r0
      j    t, first

; one byte every 40 cycles; this takes 38
byte: csrr r2, crc_lo      ; read the CRC now, before the end of TP_IDL can add a bit
      csrr r7, crc_hi
      mov  r1, r0
      and  r1, r5
      addi r1, 16          ; low nibble, DV
      outg 0, r1
      addi r1, 32          ; strobe
      xor  r2, r3
      xor  r7, r4
      or   r2, r7          ; 0 if the FCS checks out up to this byte
      addi r6, 1
      dly  3
      outg 0, r1
      mov  r1, r0
      shri r1, 4
      addi r1, 16          ; high nibble, DV
      dly  5
      outg 0, r1
      addi r1, 32
      dly  7
      outg 0, r1
      rx   r0
      j    nt, byte

      ldi  r1, 0
      outg 0, r1           ; DV low: the frame is over
      cmpi r2, 0
      j    nz, done
      ldi  r7, 0
      ldih r7, 0x80
      or   r6, r7
done: push r6
      ben  0
      jmp  frame
