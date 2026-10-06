open! Core
open Pemu

let bit v k = (v lsr k) land 1

(* A random program of valid instructions, biased towards the things uniform random words almost
   never produce: CSR writes (TMO, pin groups, JPIN, JFLAG, capture config) and waits.
   Bit-engine instructions are left out until the RTL has the bit engine. *)
let random_program rng =
  let bit_engine (i : Isa.t) =
    match i with
    | Tx _ | Rx _ | Crci | Ben _ -> true
    | _ -> false
  in
  let rec any () =
    let w = Random.State.int rng 0x10000 in
    match Isa.decode w with
    | Some i when not (bit_engine i) -> w
    | _ -> any ()
  in
  let writable = Array.of_list (List.map Isa.Csr.writable ~f:fst) in
  Array.init 256 ~f:(fun _ ->
    match Random.State.int rng 100 with
    | n when n < 15 ->
      let csr = writable.(Random.State.int rng (Array.length writable)) in
      (* small TMO values so timeouts actually happen *)
      let v = if csr = Isa.Csr.tmo then Random.State.int rng 12 else Random.State.int rng 64 in
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
    | _ -> any ())
;;

let run_random ~seed ~cycles =
  let rng = Random.State.make [| seed |] in
  let program = random_program rng in
  let ls = Lockstep.create program in
  for _ = 1 to cycles do
    let pads = { Model.Pads.uio_in = Random.State.int rng 256; ui_in = Random.State.int rng 256 } in
    let send = if Random.State.int rng 4 = 0 then Some (Random.State.int rng 0x10000) else None in
    let receive = Random.State.int rng 3 = 0 in
    ignore (Lockstep.step ?send ~receive ls pads : int option * bool)
  done
;;

let%expect_test "random programs: RTL = model every cycle" =
  let programs = 300
  and cycles = 2000 in
  for seed = 1 to programs do
    try run_random ~seed ~cycles with
    | Lockstep.Mismatch s -> raise_s [%message "seed" (seed : int) (s : Sexp.t)]
  done;
  printf "%d random programs x %d cycles: no difference\n" programs cycles;
  [%expect {| 300 random programs x 2000 cycles: no difference |}]
;;

let load name =
  match Asm.assemble (In_channel.read_all ("../firmware/" ^ name)) with
  | Ok w -> w
  | Error e -> failwith e
;;

let%expect_test "spi_master.s in lockstep against an SPI target" =
  let ls = Lockstep.create (load "spi_master.s") in
  let pending = Queue.of_list [ 0x1A5; 0x03C; 0x2F0 ] in
  let miso = ref 0
  and prev_sck = ref 0
  and shift = ref 0x5A in
  let got = ref [] in
  for _ = 1 to 3000 do
    let send = Queue.peek pending in
    let read, wrote =
      Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = !miso lsl 4 }
    in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got);
    (* tiny target: shifts out 0x5A repeatedly on falling edges *)
    let sck = bit (Lockstep.uo ls) 1 in
    if sck = 0 && !prev_sck = 1 then shift := ((!shift lsl 1) lor (!shift lsr 7)) land 0xff;
    miso := bit !shift 7;
    prev_sck := sck
  done;
  printf "%d cycles in lockstep, %d replies\n" ls.cycle (List.length !got);
  [%expect {| 3000 cycles in lockstep, 3 replies |}]
;;

let%expect_test "i2c_master.s in lockstep with a stretching target" =
  let ls = Lockstep.create (load "i2c_master.s") in
  let pending = Queue.of_list [ 0x100; 0x2A0; 0x210; 0x25A; 0x500; 0x100; 0x2A1; 0x300; 0x400; 0x500 ] in
  let stretch = ref 0
  and prev_scl = ref 1
  and acked_bits = ref 0 in
  let got = ref [] in
  for _ = 1 to 20000 do
    let master_low p = bit (Lockstep.uio_oe ls) p = 1 && bit (Lockstep.uio_out ls) p = 0 in
    let scl = if master_low 0 || !stretch > 0 then 0 else 1 in
    (* a target that ACKs every 9th clock and stretches after it *)
    if scl = 1 && !prev_scl = 0 then incr acked_bits;
    let target_sda_low = !acked_bits mod 9 = 8 in
    let sda = if master_low 1 || target_sda_low then 0 else 1 in
    if scl = 0 && !prev_scl = 1 && !acked_bits mod 9 = 0 then stretch := 17;
    if !stretch > 0 then decr stretch;
    prev_scl := scl;
    let send = Queue.peek pending in
    let read, wrote =
      Lockstep.step ?send ~receive:true ls { Model.Pads.zero with uio_in = scl lor (sda lsl 1) }
    in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  printf "%d cycles in lockstep, %d replies\n" ls.cycle (List.length !got);
  [%expect {| 20000 cycles in lockstep, 6 replies |}]
;;
