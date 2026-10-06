; UART bridge, 8N1, full duplex.
; Words from the host go out on TX; bytes received on RX go to the host.
; TX = p8 (uo[0]), RX = p19 (ui[3]). BIT = clock cycles per bit.

.equ BIT 10

      ldi  r1, 0x09
      ldih r1, 0x09        ; txcfg: 10 bits, LSB first, pin 8, idle high
      csrw txcfg, r1
      ldi  r1, 0x69
      ldih r1, 0x12        ; rxcfg: 10 bits, LSB first, pin 19, start on falling edge
      csrw rxcfg, r1
      csrwi baud, BIT
      ldi  r2, 0
      ldih r2, 0x02        ; stop bit, bit 9
      ldi  r3, 0xff
      pin  p8, set         ; line idles high
      ben  1

; never block: only take a host word when TX can accept it, so RX is always serviced
loop: j    rx_ready, recv
      j    tx_empty, tx_free
      jmp  loop
tx_free:
      j    mbx_data, send
      jmp  loop

send: pull r0
      shli r0, 1           ; start bit in bit 0
      or   r0, r2
      tx   r0
      jmp  loop

recv: rx   r0
      shri r0, 1           ; drop the start bit
      and  r0, r3
      push r0
      jmp  loop
