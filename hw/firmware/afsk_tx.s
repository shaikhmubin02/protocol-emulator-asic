; afsk_tx.s: Bell 202 audio tones for packet radio: a square wave at 1200 Hz while the line from
; ax25_tx.s (on another engine) is 1 and 2200 Hz while it is 0, without phase jumps (the tone
; changes at the next half period). For a radio's microphone input, through an RC filter.
; Written after the RTL freeze: firmware only.
;
; Pins: p2 (uio[2]) the NRZI line (read only: another engine drives it, and engines see each
; other's outputs through the uio pads), p8 (uo[0]) the audio.
; Host: the two half periods in cycles (20833 for 1200 Hz and 11364 for 2200 Hz at 50 MHz).

      pull r5              ; 1200 Hz half period
      pull r6              ; 2200 Hz half period
      csrr r7, time_lo
loop: pin  p2, sample      ; the line now chooses the next half period
      j    c, m
      add  r7, r6
      jmp  w
m:    add  r7, r5
w:    wait time r7
      pin  p8, tgl
      jmp  loop
