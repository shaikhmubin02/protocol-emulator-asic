; jtag_tap.s: a JTAG TAP (IEEE 1149.1) for a debugger or a boundary-scan tool to find and talk
; to. Written after the RTL freeze: firmware only.
;
; Each of the 16 TAP states is a place in the program: it waits for TCK low, then TCK high, and
; samples TMS (and TDI in the shift states) right after the rising edge; TDO changes after the
; falling edge and is driven only in Shift-DR and Shift-IR, released otherwise.
; Instructions (4-bit IR, captures 0001): 0001 IDCODE (the default after Test-Logic-Reset),
; 1000 USER (a 16-bit register the host reads and writes), anything else BYPASS.
;
; Pins: p20 (ui[4]) TCK, p21 (ui[5]) TMS, p22 (ui[6]) TDI, p0 (uio[0]) TDO.
; Host: first the IDCODE, bits 15:0 then 31:16 (bit 0 must be 1), and USER's first value. Any
; word the host sends later is what USER captures next. The program sends USER's value after
; every Update-DR with USER selected.
;
; Registers: r7 the instruction, r1/r2 the data register being shifted (r2 the top half of the
; IDCODE; BYPASS in r1 bit 15), r3 the instruction register being shifted (in bits 15:12),
; r4 USER, r5/r6 the IDCODE.

      pin  p0, hiz         ; TDO released
      pull r5
      pull r6
      pull r4

tlr:  ldi  r7, 1           ; Test-Logic-Reset: IDCODE selected
      wait pin p20, 0
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

      ; Capture-DR: load the selected register
      cmpi r7, 1
      j    z, cid
      cmpi r7, 8
      j    z, cus
      ldi  r1, 0           ; BYPASS captures 0
      jmp  cdr
cid:  mov  r1, r5
      mov  r2, r6
      jmp  cdr
cus:  j    mbx_data, new   ; the host has a new value for USER
      jmp  cu2
new:  pull r4
cu2:  mov  r1, r4
cdr:  wait pin p20, 0
      wait pin p20, 1
      pin  p21, sample
      j    c, x1d

      ; Shift-DR, one loop per register
shd:  cmpi r7, 1
      j    z, sid
      cmpi r7, 8
      j    z, sus
sbp:  wait pin p20, 0      ; BYPASS: one bit, kept in r1 bit 15
      mov  r0, r1
      shli r0, 1
      pin  p0, c
      wait pin p20, 1
      pin  p22, sample
      rrc  r1, 1
      pin  p21, sample
      j    c, x1d
      jmp  sbp
sid:  wait pin p20, 0      ; IDCODE: 32 bits, r2:r1, bit 0 first
      mov  r0, r1
      shri r0, 1
      pin  p0, c
      wait pin p20, 1
      pin  p22, sample
      rrc  r2, 1
      rrc  r1, 1
      pin  p21, sample
      j    c, x1d
      jmp  sid
sus:  wait pin p20, 0      ; USER: 16 bits
      mov  r0, r1
      shri r0, 1
      pin  p0, c
      wait pin p20, 1
      pin  p22, sample
      rrc  r1, 1
      pin  p21, sample
      j    c, x1d
      jmp  sus

x1d:  wait pin p20, 0      ; Exit1-DR
      pin  p0, hiz
      wait pin p20, 1
      pin  p21, sample
      j    c, udr
pdr:  wait pin p20, 0      ; Pause-DR
      wait pin p20, 1
      pin  p21, sample
      j    nc, pdr
      wait pin p20, 0      ; Exit2-DR
      wait pin p20, 1
      pin  p21, sample
      j    nc, shd
udr:  cmpi r7, 8           ; Update-DR
      j    nz, ud2
      mov  r4, r1
      push r4
ud2:  wait pin p20, 0
      wait pin p20, 1
      pin  p21, sample
      j    c, sdr
      jmp  rti

sir:  wait pin p20, 0      ; Select-IR-Scan
      wait pin p20, 1
      pin  p21, sample
      j    c, tlr
      ldi  r3, 0
      ldih r3, 0x10        ; Capture-IR: 0001
      wait pin p20, 0
      wait pin p20, 1
      pin  p21, sample
      j    c, x1i
shi:  wait pin p20, 0      ; Shift-IR: 4 bits in r3 bits 15:12, bit 12 first
      mov  r0, r3
      shri r0, 13
      pin  p0, c
      wait pin p20, 1
      pin  p22, sample
      rrc  r3, 1
      pin  p21, sample
      j    c, x1i
      jmp  shi
x1i:  wait pin p20, 0      ; Exit1-IR
      pin  p0, hiz
      wait pin p20, 1
      pin  p21, sample
      j    c, uir
pir:  wait pin p20, 0      ; Pause-IR
      wait pin p20, 1
      pin  p21, sample
      j    nc, pir
      wait pin p20, 0      ; Exit2-IR
      wait pin p20, 1
      pin  p21, sample
      j    nc, shi
uir:  mov  r7, r3          ; Update-IR
      shri r7, 12
      wait pin p20, 0
      wait pin p20, 1
      pin  p21, sample
      j    c, sdr
      jmp  rti
