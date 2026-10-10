; UART bridge, 8N1, full duplex.
; Words from the host go out on TX; bytes received on RX go to the host.
; TX = p8 (uo[0]), RX = p19 (ui[3]).
;
; Host words:
;   [7:0] a byte to send
;   bit 15 set: bit time, whole clock cycles in [14:0] (starts at BIT)
;   bit 14 set: bit time, the fraction in 1/256 of a cycle in [7:0]
; Set the bit time while the line is idle. At 50 MHz: 115200 baud = 434 + 8/256 cycles,
; 9600 baud = 5208 + 85/256.

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
      tstb r0, 15
      j    nz, set_bit
      tstb r0, 14
      j    nz, set_frac
      shli r0, 1           ; start bit in bit 0
      or   r0, r2
      tx   r0
      jmp  loop

recv: rx   r0
      shri r0, 1           ; drop the start bit
      and  r0, r3
      push r0
      jmp  loop

set_bit:
      shli r0, 1
      shri r0, 1           ; drop bit 15
      csrw baud, r0
      jmp  loop
set_frac:
      csrw baudf, r0       ; keeps [7:0]
      jmp  loop
