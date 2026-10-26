open! Core
open Pemu

(* A random program of valid instructions, biased towards the things uniform random words almost
   never produce: CSR writes (TMO, pin groups, bit engine config, ...), waits, and the bit-engine
   instructions. *)
let create rng =
  let rec any () =
    let w = Random.State.int rng 0x10000 in
    match Isa.decode w with
    | Some _ -> w
    | None -> any ()
  in
  let writable = Array.of_list (List.map Isa.Csr.writable ~f:fst) in
  let bit_engine_csrs =
    Isa.Csr.[| txcfg; rxcfg; fabctl; fabctl2; crcctl; capcfg; baud; baudf; group 0 |]
  in
  (* CSRWI only carries 6 bits, so full-width CSR values need ldi + ldih + csrw *)
  let full_csr_write () =
    let csr = bit_engine_csrs.(Random.State.int rng (Array.length bit_engine_csrs)) in
    let v = Random.State.int rng 0x10000 in
    let v = if csr = Isa.Csr.baud then v land 7 else v in
    let r = Random.State.int rng 8 in
    Isa.[ Ldi (r, v land 0xff); Ldih (r, v lsr 8); Csrw (csr, r) ]
  in
  let one () =
    match Random.State.int rng 100 with
    | n when n < 15 ->
      let csr = writable.(Random.State.int rng (Array.length writable)) in
      (* small TMO values so timeouts actually happen *)
      let v =
        if csr = Isa.Csr.tmo
        then Random.State.int rng 12
        else if csr = Isa.Csr.baud
        then Random.State.int rng 6 (* fast ticks so the bit engine does a lot *)
        else Random.State.int rng 64
      in
      Isa.encode_exn (Csrwi (csr, v))
    | n when n < 25 ->
      let w : Isa.wait =
        match Random.State.int rng 4 with
        | 0 -> Wait_pin (Random.State.int rng 32, Random.State.bool rng)
        | 1 -> Wait_flag (Random.State.int rng 8, Random.State.bool rng)
        | 2 -> Wait_time (Random.State.int rng 8)
        | _ -> Wait_event (List.random_element_exn ~random_state:rng [ Isa.Ev_capture; Ev_mailbox; Ev_tx_empty ])
      in
      Isa.encode_exn (Wait w)
    | n when n < 35 ->
      let r = Random.State.int rng 8 in
      Isa.encode_exn
        (List.random_element_exn
           ~random_state:rng
           [ Isa.Tx r; Rx r; Crci; Ben true; Ben true; Ben false; Ldi (r, Random.State.int rng 256) ])
    | _ -> any ()
  in
  let rec fill acc n =
    if n >= 256
    then List.rev acc
    else if Random.State.int rng 100 < 8
    then (
      let seq = List.map (full_csr_write ()) ~f:Isa.encode_exn in
      fill (List.rev_append seq acc) (n + List.length seq))
    else fill (one () :: acc) (n + 1)
  in
  let prologue =
    (* half the programs start by putting the bit engine in a busy, meaningful setup: CRC on with a
       random source, RX in a start-edge mode, random routing through the fabric *)
    if Random.State.bool rng
    then (
      let set csr v r = Isa.[ Ldi (r, v land 0xff); Ldih (r, v lsr 8); Csrw (csr, r) ] in
      let pin () = Random.State.int rng 24 in
      let txcfg =
        Random.State.int rng 16 lor (Random.State.int rng 2 lsl 4) lor (pin () lsl 5)
        lor (Random.State.int rng 2 lsl 10) lor (Random.State.int rng 2 lsl 11)
      and rxcfg =
        Random.State.int rng 16 lor (Random.State.int rng 2 lsl 4) lor (pin () lsl 5)
        lor (Random.State.int rng 2 lsl 10) lor (Random.State.int rng 2 lsl 11)
        lor ((1 + Random.State.int rng 3) lsl 12)
      and crcctl =
        1 lor (Random.State.int rng 3 lsl 1) lor (Random.State.int rng 2 lsl 3)
        lor (Random.State.int rng 2 lsl 4)
      in
      List.concat
        [ set Isa.Csr.txcfg txcfg 0
        ; set Isa.Csr.rxcfg rxcfg 1
        ; set Isa.Csr.crcctl crcctl 2
        ; set Isa.Csr.fabctl (Random.State.int rng 0x4000) 3
        ; set Isa.Csr.fabctl2 (Random.State.int rng 0x2000) 4
        ; Isa.[ Csrwi (Csr.baud, 1 + Random.State.int rng 4); Crci; Ben true ]
        ]
      |> List.map ~f:Isa.encode_exn)
    else []
  in
  let body = fill [] (List.length prologue) in
  Array.of_list (List.take (prologue @ body) 256)
;;
