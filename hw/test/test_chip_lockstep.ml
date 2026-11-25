(* The whole chip against Chip_model at the pins, every cycle. Random programs on all four
   engines, random configuration, random pin owners, random host traffic over SPI (including
   stopping and restarting engines), and input pins that change now and then. *)

open! Core
open Pemu
module H = Chip_host

exception Mismatch of Sexp.t [@@deriving sexp_of]

(* what the random runs reached, summed over all seeds *)
let cycles = ref 0
let engine_cycles = ref 0
let driven_pin_cycles = ref 0
let flag_changes = ref 0
let words_in = ref 0
let words_out = ref 0
let restarts = ref 0
let program_reads = ref 0

(* small programs that move words through the mailboxes and flags, which random programs
   rarely do; mixed in with random ones *)
(* drives all of uio[7:0] and uo[1], so pin ownership matters *)
let wiggler =
  Array.to_list
    (Result.ok_or_failwith
       (Asm.assemble
          {|
      ldi  r2, 0xe0        ; group 0 = pins 0..7
      csrw 0x20, r2
loop: addi r1, 1
      outg 0, r1
      pin  p9, tgl
      pin  p3, hiz, 2
      jmp  loop
|}))
;;

let structured =
  List.map
    ~f:(fun src -> Array.to_list (Result.ok_or_failwith (Asm.assemble src)))
    [ {|
loop: pull r0
      push r0
      jmp  loop
|}
    ; {|
      ldi  r1, 0
loop: push r1
      addi r1, 1
      dly  3
      jmp  loop
|}
    ; {|
loop: sig  1
      wait flag 2, 1
      clrf 2
      csrr r0, time_lo
      push r0
      jmp  loop
|}
    ; {|
loop: wait flag 1, 1
      clrf 1
      sig  2
      pull r2
      push r2
      jmp  loop
|}
    ; In_channel.read_all "../firmware/uart.s"
    ]
;;

let attach ~seed (t : H.t) =
  let model = Chip_model.create () in
  t.before_edge
  <- (fun t ->
       let rtl = { Chip_model.uo_out = H.uo t; uio_out = H.uio_out t; uio_oe = H.uio_oe t } in
       let m = Chip_model.outputs model in
       if not (Chip_model.equal_outputs rtl m)
       then
         raise
           (Mismatch
              [%message
                "chip and model differ"
                  (seed : int)
                  ~cycle:(t.cycle : int)
                  (rtl : Chip_model.outputs)
                  ~model:(m : Chip_model.outputs)
                  ~spi:
                    ((model.count, model.cmd, model.addr, model.shift_out, model.read_word)
                     : int * int * int * int * int)
                  ~owners:(model.owners : int array)]);
       let flags = model.flags in
       Chip_model.step model { Model.Pads.ui_in = H.get t.i.ui_in; uio_in = H.get t.i.uio_in };
       incr cycles;
       Array.iter model.engines ~f:(fun en -> if Option.is_some en.model then incr engine_cycles);
       driven_pin_cycles := !driven_pin_cycles + Int.popcount (m.uio_oe lor (m.uo_out land 0x7f));
       if model.flags <> flags then incr flag_changes);
  model
;;

let debug_actions = ref 0
let debug_stops = ref 0

let run ?(log = false) ?(config = true) ?(wiggle = true) ?(debug = false) ~seed ~actions () =
  let rng = Random.State.make [| seed |] in
  let rand n = Random.State.int rng n in
  let t = H.create () in
  let model = attach ~seed t in
  t.on_cycle
  <- (fun t ->
       if wiggle && rand 64 = 0 then t.ui <- rand 256;
       if wiggle && rand 64 = 0 then t.uio_ext <- rand 256);
  let engine () = rand 4 in
  let stopped e = not (Chip_model.running model e) && not ((model.run lsr e) land 1 = 1) in
  (* programs: the first 48 words of a random program (the rest of memory is 0 = nop) *)
  for e = 0 to 3 do
    let program =
      if e = seed % 4
      then wiggler
      else if Random.State.bool rng
      then List.random_element_exn ~random_state:rng structured
      else List.take (Array.to_list (Random_program.create rng)) 48
    in
    H.write t (H.program e 0) program
  done;
  (* random fabric and CRC configuration on two engines *)
  for _ = 1 to if config then 2 else 0 do
    let e = engine () in
    let words = List.init Chip_model.n_cfg ~f:(fun _ -> rand 0x1_0000_0000) in
    H.write t (H.config e ~word:0 ~half:0) (List.concat_map words ~f:(fun w -> [ w land 0xffff; w lsr 16 ]))
  done;
  (* random owners, some pins left unowned *)
  H.write t (H.owner 0) (List.init Chip_model.n_pins ~f:(fun _ -> rand 8));
  H.run t (1 + rand 15);
  if log
  then
    printf
      "owners %s run %d programs %s
"
      (Sexp.to_string [%sexp (model.owners : int array)])
      model.run
      (Sexp.to_string [%sexp (Array.map model.engines ~f:(fun en -> en.mem.(0)) : int array)]);
  for _ = 1 to actions do
    (match rand (if debug then 18 else 12) with
     | 12 ->
       (* debug (ADR 0013): breakpoint somewhere in the first 48 words, maybe joined *)
       H.write t (H.engine_addr (engine ()) ~region:2 1) [ rand 48 lor (rand 4 lsl 8) ];
       incr debug_actions
     | 13 | 14 ->
       (* stop / resume / step any engines, all in one cycle *)
       H.write t (H.global 0x14) [ rand 0x1000 ];
       incr debug_actions
     | 15 ->
       let e = engine () in
       if rand 2 = 0
       then H.write t (H.reg e (rand 8)) [ rand 0x10000 ]
       else H.write t (H.status e) [ rand 48 ];
       incr debug_actions
     | 16 ->
       let d = H.read1 t (H.global 0x14) in
       debug_stops := !debug_stops + Int.popcount (d land 0xf)
     | 17 ->
       let e = engine () in
       ignore (H.read t (H.engine_addr e ~region:2 1) 2 : int list)
     | 0 -> H.write t H.flags_reg [ rand 256 ]
     | 1 | 2 ->
       let e = engine () in
       if H.inbox_count t e < 2
       then (
         H.write t (H.mailbox e) [ rand 0x10000 ];
         incr words_in)
     | 3 | 4 ->
       let e = engine () in
       let n = H.outbox_count t e in
       ignore (H.read t (H.mailbox e) (Int.max 1 n) : int list);
       words_out := !words_out + n
     | 5 -> ignore (H.read1 t (H.status (engine ())) : int)
     | 6 -> ignore (H.read t (H.reg (engine ()) 0) 8 : int list)
     | 7 -> H.write t (H.owner (rand Chip_model.n_pins)) [ rand 8 ]
     | 8 ->
       let before = model.run in
       let after = rand 16 in
       if before land lnot after <> 0 then incr restarts;
       H.run t after
     | 9 ->
       (* reload part of a stopped engine's program and read it back *)
       let e = engine () in
       if stopped e
       then (
         let off = rand 40 in
         H.write t (H.program e off) (List.take (Array.to_list (Random_program.create rng)) 8);
         ignore (H.read t (H.program e off) 8 : int list);
         incr program_reads)
     | 10 -> ignore (H.read t H.time_lo 2 : int list)
     | _ -> ignore (H.read t (H.owner 0) Chip_model.n_pins : int list));
    H.cycles t (rand 300)
  done
;;

let%expect_test "whole chip against the chip model, random programs and host traffic" =
  let seeds = 16 in
  for seed = 1 to seeds do
    run ~seed ~actions:60 ()
  done;
  printf
    "%d seeds, %d cycles, no differences\n\
     engine-cycles %d, driven pin-cycles %d, flag changes %d\n\
     host words in %d, out %d, engine stops %d, program reloads %d\n"
    seeds
    !cycles
    !engine_cycles
    !driven_pin_cycles
    !flag_changes
    !words_in
    !words_out
    !restarts
    !program_reads;
  [%expect {|
    16 seeds, 1306149 cycles, no differences
    engine-cycles 1873186, driven pin-cycles 528072, flag changes 117
    host words in 142, out 38, engine stops 54, program reloads 35
    |}]
;;

(* The host writes configuration (fabric words, CRC polynomial and start value) through SPI, and
   reading it back gives 0, so the only way to see that a write landed is an engine using it.
   Random programs rarely do, and a mutant that sent configuration writes to the wrong region
   survived. Here engine 0 sends three bytes through the USB stuffing + NRZI configuration on
   uo[0] with the CRC on, and the host reads the CRC back; pins and SPI are checked against the
   chip model every cycle. *)
let%expect_test "host-written fabric and CRC configuration reaches the engine" =
  let t = H.create () in
  ignore (attach ~seed:0 t : Chip_model.t);
  let program =
    Array.to_list
      (Result.ok_or_failwith
         (Asm.assemble
            {|
      ldi  r1, 0x07
      ldih r1, 0x0d        ; txcfg: 8 bits, LSB first, pin 8, through the fabric, idle high
      csrw txcfg, r1
      ldi  r1, 0x0e
      ldih r1, 0x02        ; fabctl: line = element 7, hold = element 0, hold on
      csrw fabctl, r1
      csrwi crcctl, 1      ; CRC on, fed by the TX bits
      csrwi baud, 3
      crci
      ben  1
      ldi  r0, 0xff
      tx   r0
      ldi  r0, 0x81
      tx   r0
      ldi  r0, 0x3f
      tx   r0
      dly  255
      csrr r2, crc_lo
      csrr r3, crc_hi
      halt
|}))
  in
  H.write t (H.program 0 0) program;
  let fabric = Array.to_list (Bitstream.usb_tx ~n_le:Model.n_le) in
  let words =
    fabric @ List.init (16 - List.length fabric) ~f:(fun _ -> 0) @ [ 0x04C1_1DB7; 0xFFFF_FFFF ]
  in
  H.write t (H.config 0 ~word:0 ~half:0) (List.concat_map words ~f:(fun w -> [ w land 0xffff; w lsr 16 ]));
  H.write t (H.owner 8) [ 4 ];
  H.run t 1;
  H.cycles t 800;
  (match H.read t (H.reg 0 2) 2 with
   | [ lo; hi ] -> printf "CRC after 3 bytes: %04x%04x\n" hi lo
   | _ -> assert false);
  (* the same CRC-32 computed outside the chip: shift left, xor the polynomial when the top bit
     xor the data bit is 1, over FF 81 3F sent LSB first, from FFFFFFFF *)
  [%expect {| CRC after 3 bytes: ec691b54 |}]
;;

let%expect_test "whole chip against the chip model, with random debug traffic" =
  let seeds = 16 in
  for seed = 1 to seeds do
    run ~debug:true ~seed:(100 + seed) ~actions:80 ()
  done;
  printf "%d seeds: no differences; debug writes %d, engines seen stopped %d\n"
    seeds
    !debug_actions
    !debug_stops;
  [%expect {| 16 seeds: no differences; debug writes 305, engines seen stopped 47 |}]
;;
