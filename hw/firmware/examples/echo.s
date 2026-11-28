; Talking to the host: every word the host writes to the inbox comes back in the outbox, plus 1.
; PULL waits while the inbox is empty and PUSH while the outbox is full, so the host sets the pace.

loop: pull r0
      addi r0, 1
      push r0
      jmp  loop
