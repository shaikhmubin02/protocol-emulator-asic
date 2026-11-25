(* Protocols written after the RTL freeze (tag rtl-freeze-2026-11-26): firmware and fabric
   configurations only. Each runs on the engine RTL in lockstep with the model, against a model
   of the other end written from the protocol's specification. *)

open! Core
open Pemu

let bit v k = (v lsr k) land 1

let load name =
  match Asm.assemble (In_channel.read_all ("../firmware/" ^ name)) with
  | Ok w -> w
  | Error e -> failwith e
;;

(* ---- proofs of the post-freeze fabric configurations: for every state of the 8 elements and
   every input, the configuration computes the rule written out below as plain logic. The
   fabric logic is the Fabric_logic.Make functor the RTL is built from. *)
module G = Hardcaml_verify.Comb_gates
module L = Pemu.Fabric_logic.Make (G)

let prove ~words ~ext ~q ~spec =
  let cfgs = Array.map words ~f:(fun w -> G.of_int_trunc ~width:Fabric_logic.cfg_bits w) in
  let f, out = L.step ~cfgs ~q ~ext in
  let ok =
    List.map (spec ~f ~out) ~f:(fun (impl, want) -> G.(impl ==: want)) |> List.reduce_exn ~f:G.( &: )
  in
  match Hardcaml_verify.Solver.(solve ~solver:minisat) (G.cnf G.(~:ok)) with
  | Ok Unsat -> print_endline "proved: configuration = rule for all states and inputs"
  | Ok (Sat model) ->
    print_s [%message "counterexample" (model : Hardcaml_verify.Cnf.Model_with_vectors.input list)]
  | Error e -> print_s [%message "solver error" (e : Error.t)]
;;

let%expect_test "CAN de-stuffing configuration, proved" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and s = G.input "sample" 1
  and counting = G.input "counting" 1 in
  prove
    ~words:(Pemu_post.Fabric_post.can_rx ~n_le:8)
    ~ext:G.(counting @: s @: gnd)
    ~q
    ~spec:(fun ~f ~out ->
      let open G in
      let prev = q.(1) in
      let eq = ~:(s ^: prev) in
      [ out.(0), eq (* "same as the previous sample" *)
      ; f.(1), mux2 counting s vdd (* previous sample, held recessive while not counting *)
      ; out.(1), mux2 counting s vdd (* rx bit *)
      ; f.(2), eq &: counting
      ; f.(3), eq &: q.(2)
      ; f.(4), eq &: q.(3)
      ; f.(5), eq &: q.(4)
      ; out.(5), q.(5) (* drop: the last five samples were equal *)
      ; out.(6), eq &: q.(4) (* flag: the next sample will be dropped *)
      ; f.(7), gnd
      ]);
  [%expect {| proved: configuration = rule for all states and inputs |}]
;;

(* ---- CAN 2.0A receive with ACK. The fabric (Fabric_post.can_rx) drops the stuff bits; the
   CRC unit checks CRC-15; the node is Can_node, written from the Bosch specification. Bus on
   ui[3]; the chip's TXD on uio[0], pulled up, so it reads recessive while not driven. *)
let%expect_test "can_rx.s: CAN 2.0A frames received and acknowledged" =
  let fabric = Pemu_post.Fabric_post.can_rx ~n_le:Model.n_le in
  let ls = Lockstep.create ~fabric ~crc_poly:(0x4599 lsl 17) ~crc_init:0 (load "can_rx.s") in
  Lockstep.record ls ~ns_per_cycle:20. "can_rx";
  let frames =
    Can_node.
      [ { id = 0x123; rtr = false; data = [ 0xDE; 0xAD; 0xBE; 0xEF ]; flip = None }
      ; { id = 0x000; rtr = false; data = [ 0; 0; 0; 0; 0; 0; 0; 0 ]; flip = None }
      ; { id = 0x3FF; rtr = false; data = [ 0xFF; 0xFF ]; flip = None }
      ; { id = 0x0F0; rtr = false; data = [ 0x1F; 0xF0; 0x0F ]; flip = None }
      ; { id = 0x001; rtr = false; data = [] ; flip = None }
        (* one data bit flipped after the CRC: must not be acknowledged, CRC reported bad *)
      ; { id = 0x246; rtr = false; data = [ 0x12; 0x34 ]; flip = Some 25 }
      ; (* and the next frame is still received *)
        { id = 0x135; rtr = false; data = [ 0xA5 ]; flip = None }
        (* a remote frame: DLC 2 but no data field (CAN 2.0 part A). Last, because the stock
           sigrok CAN decoder reads DLC data bytes in a remote frame too (can/pd.py sets the
           data length from the DLC alone), which would throw it off for the frames after. *)
      ; { id = 0x555; rtr = true; data = [ 0; 0 ]; flip = None }
      ]
  in
  let got = ref [] in
  let step ~bus =
    let read, _ = Lockstep.step ~receive:true ls { Model.Pads.zero with ui_in = bus lsl 3 } in
    Option.iter read ~f:(fun v -> got := v :: !got)
  in
  let chip_tx () = if bit (Lockstep.uio_oe ls) 0 = 1 then bit (Lockstep.uio_out ls) 0 else 1 in
  (* the firmware sets up, then the bus is idle for a while *)
  while ls.cycle < 3000 do
    step ~bus:(chip_tx ())
  done;
  List.iter frames ~f:(fun f ->
    let node = Can_node.create ~bit_cycles:100 f in
    let t0 = ls.cycle in
    while ls.cycle < t0 + Can_node.cycles node do
      let c = ls.cycle - t0 in
      let bus = Can_node.drive node ~cycle:c land chip_tx () in
      Can_node.observe node ~cycle:c ~bus;
      step ~bus
    done;
    printf
      "id %03x rtr %b, %d data bytes%s, %d stuff bits on the wire: ACK %b, bit errors %d\n"
      f.id
      f.rtr
      (List.length f.data)
      (if Option.is_some f.flip then " (CRC broken on purpose)" else "")
      node.stuffed_bits
      node.ack_seen
      node.bit_errors);
  (* let the last report through *)
  for _ = 1 to 200 do
    step ~bus:(chip_tx ())
  done;
  let words = List.rev !got in
  printf "host got %d words:\n" (List.length words);
  List.chunks_of words ~length:6
  |> List.iter ~f:(fun w -> printf "  %s\n" (String.concat ~sep:" " (List.map w ~f:(sprintf "%04x"))));
  Lockstep.note ls "id" (List.map frames ~f:(fun f -> f.id));
  (* the data bytes as they are on the wire (the broken frame's flipped bit included) *)
  let wire_data (f : Can_node.frame) =
    let bits = List.concat_map f.data ~f:(fun b -> Can_node.msb_first b 8) in
    let bits =
      match f.flip with
      | Some k when k >= 19 -> List.mapi bits ~f:(fun i b -> if i = k - 19 then 1 - b else b)
      | _ -> bits
    in
    List.chunks_of bits ~length:8 |> List.map ~f:(List.fold ~init:0 ~f:(fun a b -> (a lsl 1) lor b))
  in
  Lockstep.note ls "data" (List.concat_map frames ~f:(fun f -> if f.rtr then [] else wire_data f));
  (* per frame: ID; RTR << 6 | DLC, with 0x100 when the CRC was good; then r6 r5 r4 r3, the data
     bytes in the low bytes. The broken frame is not acknowledged and has no 0x100. *)
  [%expect {|
    id 123 rtr false, 4 data bytes, 2 stuff bits on the wire: ACK true, bit errors 0
    id 000 rtr false, 8 data bytes, 16 stuff bits on the wire: ACK true, bit errors 0
    id 3ff rtr false, 2 data bytes, 6 stuff bits on the wire: ACK true, bit errors 0
    id 0f0 rtr false, 3 data bytes, 5 stuff bits on the wire: ACK true, bit errors 0
    id 001 rtr false, 0 data bytes, 3 stuff bits on the wire: ACK true, bit errors 0
    id 246 rtr false, 2 data bytes (CRC broken on purpose), 2 stuff bits on the wire: ACK false, bit errors 0
    id 135 rtr false, 1 data bytes, 2 stuff bits on the wire: ACK true, bit errors 0
    id 555 rtr true, 2 data bytes, 0 stuff bits on the wire: ACK true, bit errors 0
    host got 48 words:
      0123 0104 0000 0000 dead beef
      0000 0108 0000 0000 0000 0000
      03ff 0102 0000 0000 0000 ffff
      00f0 0103 0000 0000 001f f00f
      0001 0100 0000 0000 0000 0000
      0246 0002 0000 0000 0000 1034
      0135 0101 0000 0000 0000 00a5
      0555 0142 0000 0000 0000 0000
    |}]
;;

(* ---- CAN 2.0A transmit: stuffing, CRC and bit timing in firmware (the fabric can't do CAN's
   transmit-side stuffing). The other end is Can_node.Receiver, written from the specification;
   it also measures each bus edge against the 100-cycle grid from the start of frame. *)
let can_words (id, rtr, data) =
  let rec pairs = function
    | a :: b :: rest -> ((a lsl 8) lor b) :: pairs rest
    | [ a ] -> [ a lsl 8 ]
    | [] -> []
  in
  [ (id lor if rtr then 0x8000 else 0); List.length data ] @ if rtr then [] else pairs data
;;

(* run can_tx.s with [frames] queued by the host; [others] are extra transmitters started when the
   chip's start of frame appears (for arbitration); returns the receiver and the chip's replies *)
let run_can_tx ?(ack = true) ?(others = []) ~cycles name frames =
  let ls = Lockstep.create (load "can_tx.s") in
  Lockstep.record ls ~ns_per_cycle:20. name;
  let rx = Can_node.Receiver.create ~bit_cycles:100 in
  let pending = Queue.of_list (List.concat_map frames ~f:can_words) in
  let replies = ref [] in
  let others = ref others
  and running = ref []
  and last_bus = ref 1 in
  let chip_tx () = if bit (Lockstep.uio_oe ls) 0 = 1 then bit (Lockstep.uio_out ls) 0 else 1 in
  for _ = 1 to cycles do
    let c = ls.cycle in
    let theirs =
      List.fold !running ~init:1 ~f:(fun acc (start, n) -> acc land Can_node.drive n ~cycle:(c - start))
    in
    let ack = if ack then Can_node.Receiver.drive rx ~cycle:c else 1 in
    let bus = chip_tx () land theirs land ack in
    (* a waiting transmitter hard-synchronises on the chip's start of frame and starts with it *)
    if bus = 0 && !last_bus = 1
    then (
      match !others with
      | f :: rest ->
        running := (c, Can_node.create ~bit_cycles:100 f) :: !running;
        others := rest
      | [] -> ());
    last_bus := bus;
    Can_node.Receiver.observe rx ~cycle:c ~bus;
    let send = Queue.peek pending in
    let read, wrote = Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = bus lsl 3 } in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> replies := v :: !replies)
  done;
  ls, rx, List.rev !replies
;;

let print_received (rx : Can_node.Receiver.t) =
  List.iter (List.rev rx.frames) ~f:(fun (g : Can_node.Receiver.got) ->
    printf
      "  received id %03x%s data [%s] CRC %s, stuff errors %d\n"
      g.id
      (if g.rtr then " (remote)" else "")
      (String.concat ~sep:" " (List.map g.data ~f:(sprintf "%02x")))
      (if g.crc_ok then "good" else "BAD")
      g.stuff_errors)
;;

let%expect_test "can_tx.s: frames stuffed and timed by the program, checked by a receiver from the spec" =
  let frames =
    [ 0x123, false, [ 0xDE; 0xAD; 0xBE; 0xEF ]
    ; 0x000, false, [ 0; 0; 0; 0; 0; 0; 0; 0 ]
    ; 0x3FF, false, [ 0xFF; 0xFF; 0xFF ]
    ; 0x0F0, false, [ 0x1F ]
    ; 0x555, true, [ 0; 0 ]
    ]
  in
  let ls, rx, replies = run_can_tx ~cycles:80_000 "can_tx" frames in
  print_received rx;
  printf "replies %s; largest edge distance from the 100-cycle grid: %d cycles\n"
    (String.concat ~sep:" " (List.map replies ~f:Int.to_string))
    rx.max_edge_error;
  Lockstep.note ls "id" (List.map frames ~f:(fun (id, _, _) -> id));
  Lockstep.note ls "data" (List.concat_map frames ~f:(fun (_, rtr, d) -> if rtr then [] else d));
  [%expect {|
      received id 123 data [de ad be ef] CRC good, stuff errors 0
      received id 000 data [00 00 00 00 00 00 00 00] CRC good, stuff errors 0
      received id 3ff data [ff ff ff] CRC good, stuff errors 0
      received id 0f0 data [1f] CRC good, stuff errors 0
      received id 555 (remote) data [] CRC good, stuff errors 0
    replies 1 1 1 1 1; largest edge distance from the 100-cycle grid: 0 cycles
    |}]
;;

let%expect_test "can_tx.s: nobody acknowledges" =
  let _, rx, replies = run_can_tx ~ack:false ~cycles:20_000 "can_tx_noack" [ 0x321, false, [ 0x42 ] ] in
  print_received rx;
  printf "replies %s\n" (String.concat ~sep:" " (List.map replies ~f:Int.to_string));
  [%expect {|
      received id 321 data [42] CRC good, stuff errors 0
    replies 2
    |}]
;;

let%expect_test "can_tx.s: loses arbitration to a lower ID, then sends" =
  (* the chip sends 0x456; another node starts on the chip's start of frame with 0x123, whose
     identifier wins (a dominant bit where the chip sends recessive). The host then asks again. *)
  let other = { Can_node.id = 0x123; rtr = false; data = [ 0xAA ]; flip = None } in
  let _, rx, replies =
    run_can_tx ~others:[ other ] ~cycles:40_000 "can_tx_arb"
      [ 0x456, false, [ 0x11; 0x22 ]; 0x456, false, [ 0x11; 0x22 ] ]
  in
  print_received rx;
  printf "replies %s\n" (String.concat ~sep:" " (List.map replies ~f:Int.to_string));
  [%expect {|
      received id 123 data [aa] CRC good, stuff errors 0
      received id 456 data [11 22] CRC good, stuff errors 0
    replies 3 1
    |}]
;;

(* ---- HDLC (RFC 1662 framing): stuffing in the fabric, FCS-16 in the CRC unit *)
let%expect_test "HDLC transmit stuffing configuration, proved" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and d = G.input "d" 1
  and flags = G.input "flags" 1 in
  prove
    ~words:(Pemu_post.Fabric_post.hdlc_tx ~n_le:8)
    ~ext:G.(flags @: gnd @: d)
    ~q
    ~spec:(fun ~f ~out ->
      let open G in
      let hold = q.(1) &: ~:flags in
      let sent = d &: ~:hold in
      let counting = ~:flags in
      [ out.(0), hold (* five 1s went out: stuff a 0 *)
      ; out.(7), sent (* the line *)
      ; f.(5), sent &: counting
      ; f.(4), sent &: q.(5) &: counting
      ; f.(3), sent &: q.(4) &: counting
      ; f.(2), sent &: q.(3) &: counting
      ; f.(1), sent &: q.(2) &: counting
      ; f.(6), gnd
      ]);
  [%expect {| proved: configuration = rule for all states and inputs |}]
;;

let%expect_test "HDLC receive configuration, proved" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and s = G.input "sample" 1 in
  prove
    ~words:(Pemu_post.Fabric_post.hdlc_rx ~n_le:8)
    ~ext:G.(gnd @: s @: gnd)
    ~q
    ~spec:(fun ~f ~out ->
      let open G in
      let five = q.(5) in
      [ out.(0), s (* rx bit *)
      ; f.(1), s
      ; f.(2), s &: q.(1)
      ; f.(3), s &: q.(2)
      ; f.(4), s &: q.(3)
      ; f.(5), s &: q.(4)
      ; out.(6), five &: ~:s (* drop: the 0 after five 1s *)
      ; out.(7), five &: s (* flag: a sixth 1 *)
      ]);
  [%expect {| proved: configuration = rule for all states and inputs |}]
;;

let hdlc_frames =
  [ [ 0xFF; 0x03; 0xC0; 0x21; 0x01; 0x01; 0x00; 0x04 ] (* a PPP LCP configure-request header *)
  ; [ 0xFF; 0xFF; 0xFF; 0xFF; 0xFF ] (* stuffing after every five bits *)
  ; [ 0x7E; 0x7D; 0x7E ] (* bytes that look like flags *)
  ; [ 0x3F ]
  ]
;;

let%expect_test "hdlc_tx.s: frames checked by a receiver written from RFC 1662" =
  let ls =
    Lockstep.create
      ~fabric:(Pemu_post.Fabric_post.hdlc_tx ~n_le:Model.n_le)
      ~crc_poly:(0x1021 lsl 16)
      ~crc_init:(0xFFFF lsl 16)
      (load "hdlc_tx.s")
  in
  Lockstep.record ls ~ns_per_cycle:20. "hdlc_tx";
  let rx = Hdlc_node.Receiver.create ~bit_cycles:200 in
  let pending = Queue.of_list (List.concat_map hdlc_frames ~f:(fun f -> List.length f :: f)) in
  let replies = ref 0 in
  for _ = 1 to 90_000 do
    let send = Queue.peek pending in
    let read, wrote = Lockstep.step ?send ~receive:true ls Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun _ -> incr replies);
    Hdlc_node.Receiver.observe rx ~cycle:ls.cycle ~line:(bit (Lockstep.uo ls) 0)
  done;
  List.iter (List.rev rx.frames) ~f:(fun (g : Hdlc_node.Receiver.got) ->
    printf "received [%s], FCS %s\n"
      (String.concat ~sep:" " (List.map g.data ~f:(sprintf "%02x")))
      (if g.fcs_ok then "good" else "BAD"));
  printf "replies %d, host words left %d\n" !replies (Queue.length pending);
  [%expect {|
    received [ff 03 c0 21 01 01 00 04], FCS good
    received [ff ff ff ff ff], FCS good
    received [7e 7d 7e], FCS good
    received [3f], FCS good
    replies 4, host words left 0
    |}]
;;

let%expect_test "hdlc_rx.s: frames from a sender written from RFC 1662" =
  let ls =
    Lockstep.create
      ~fabric:(Pemu_post.Fabric_post.hdlc_rx ~n_le:Model.n_le)
      ~crc_poly:(0x1021 lsl 16)
      ~crc_init:(0xFFFF lsl 16)
      (load "hdlc_rx.s")
  in
  Lockstep.record ls ~ns_per_cycle:20. "hdlc_rx";
  let frames =
    List.map hdlc_frames ~f:(fun bytes -> { Hdlc_node.bytes; bad_fcs = false; flags_before = 1 })
    @ [ { bytes = [ 0x12; 0x34; 0x56 ]; bad_fcs = true; flags_before = 3 }
      ; { bytes = [ 0xA5 ]; bad_fcs = false; flags_before = 0 } (* shares the previous closing flag *)
      ]
  in
  let line = Array.of_list (Hdlc_node.stream ~idle:20 frames) in
  let got = ref [] in
  let n = Array.length line * 200 in
  for c = 0 to n + 2000 do
    let level = if c / 200 < Array.length line then line.(c / 200) else 1 in
    let read, _ = Lockstep.step ~receive:true ls { Model.Pads.zero with ui_in = level lsl 3 } in
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  (* print each frame: its bytes, then the end word *)
  let cur = ref [] in
  List.iter (List.rev !got) ~f:(fun w ->
    if w land 0x8000 <> 0
    then (
      printf "frame [%s] %d bytes, FCS %s\n"
        (String.concat ~sep:" " (List.rev_map !cur ~f:(sprintf "%02x")))
        (w land 0xff)
        (if w land 0x4000 <> 0 then "good" else "BAD");
      cur := [])
    else cur := w :: !cur);
  (* the FCS bytes (d1 b5 ...) are what RFC 1662's algorithm gives for each frame; the fifth frame's
     FCS was broken on purpose, the sixth shares the fifth's closing flag *)
  [%expect {|
    frame [ff 03 c0 21 01 01 00 04 d1 b5] 10 bytes, FCS good
    frame [ff ff ff ff ff b4 c9] 7 bytes, FCS good
    frame [7e 7d 7e 4a 8c] 5 bytes, FCS good
    frame [3f 0c 39] 3 bytes, FCS good
    frame [12 34 56 90 11] 5 bytes, FCS BAD
    frame [a5 df 02] 3 bytes, FCS good
    |}]
;;

let%expect_test "hdlc_tx.s on one engine into hdlc_rx.s on another" =
  let mk fabric name =
    Lockstep.create ~fabric ~crc_poly:(0x1021 lsl 16) ~crc_init:(0xFFFF lsl 16) (load name)
  in
  let tx = mk (Pemu_post.Fabric_post.hdlc_tx ~n_le:Model.n_le) "hdlc_tx.s"
  and rx = mk (Pemu_post.Fabric_post.hdlc_rx ~n_le:Model.n_le) "hdlc_rx.s" in
  let pending = Queue.of_list (List.concat_map hdlc_frames ~f:(fun f -> List.length f :: f)) in
  let got = ref [] in
  for _ = 1 to 90_000 do
    let send = Queue.peek pending in
    let _, wrote = Lockstep.step ?send ~receive:true tx Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    let line = bit (Lockstep.uo tx) 0 in
    let read, _ = Lockstep.step ~receive:true rx { Model.Pads.zero with ui_in = line lsl 3 } in
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  let cur = ref [] in
  List.iter (List.rev !got) ~f:(fun w ->
    if w land 0x8000 <> 0
    then (
      printf "frame [%s], FCS %s\n"
        (String.concat ~sep:" " (List.rev_map !cur ~f:(sprintf "%02x")))
        (if w land 0x4000 <> 0 then "good" else "BAD");
      cur := [])
    else cur := w :: !cur);
  [%expect {|
    frame [ff 03 c0 21 01 01 00 04 d1 b5], FCS good
    frame [ff ff ff ff ff b4 c9], FCS good
    frame [7e 7d 7e 4a 8c], FCS good
    frame [3f 0c 39], FCS good
    |}]
;;

(* ---- DALI (IEC 62386): forward frames through the fabric with the 10BASE-T Manchester
   configuration, unchanged; backward frames sampled by the program. Te is 100 times shorter
   than the real 416.7 us to keep the RTL simulation short; the recording is written with the
   real timing (2000 ns a cycle), so the decoder sees real DALI. *)
let%expect_test "dali.s: a control device against control gear written from IEC 62386" =
  let te = 208 in
  let ls = Lockstep.create ~fabric:(Bitstream.eth_tx ~n_le:Model.n_le) (load "dali.s") in
  Lockstep.record ls ~ns_per_cycle:2000. "dali";
  let gear = Dali_gear.create ~te ~address:5 in
  let frames =
    [ 0x0A80, "level 0x80 to gear 5"
    ; 0x0BA0, "query actual level, gear 5"
    ; 0x0DA0, "query actual level, gear 6 (there is none)"
    ; 0xFF05, "broadcast recall max level"
    ; 0xFFA0, "broadcast query actual level"
    ; 0x0B91, "query control gear present, gear 5"
    ; 0xFF00, "broadcast off"
    ; 0x0B90, "query status, gear 5"
    ]
  in
  let pending = Queue.of_list (te :: List.map frames ~f:fst) in
  let replies = ref [] in
  let chip_tx () = if bit (Lockstep.uio_oe ls) 0 = 1 then bit (Lockstep.uio_out ls) 0 else 1 in
  for _ = 1 to 120_000 do
    let c = ls.cycle in
    let bus = chip_tx () land Dali_gear.drive gear ~cycle:c in
    Dali_gear.observe gear ~cycle:c ~bus;
    let send = Queue.peek pending in
    let read, wrote = Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = bus lsl 3 } in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> replies := v :: !replies)
  done;
  List.iter2_exn frames (List.rev !replies) ~f:(fun (_, what) r ->
    printf "%-44s -> %s\n" what
      (if r = 0x100 then "no answer" else if r = 0x200 then "broken answer" else sprintf "answer %02x" r));
  printf "gear saw %d forward frames, %d broken; level now %d\n"
    (List.length gear.frames) gear.bad_frames gear.level;
  Lockstep.note ls "data" (List.map frames ~f:(fun (w, _) -> w land 0xff));
  Lockstep.note ls "reply" (List.filter (List.rev !replies) ~f:(fun r -> r < 0x100));
  [%expect {|
    level 0x80 to gear 5                         -> no answer
    query actual level, gear 5                   -> answer 80
    query actual level, gear 6 (there is none)   -> no answer
    broadcast recall max level                   -> no answer
    broadcast query actual level                 -> answer fe
    query control gear present, gear 5           -> answer ff
    broadcast off                                -> no answer
    query status, gear 5                         -> answer 00
    gear saw 8 forward frames, 0 broken; level now 0
    |}]
;;

(* ---- MIDI 1.0: 31250 baud 8N1 (1600 cycles a bit at 50 MHz), running status, real-time bytes.
   The line model is the spec's: a start bit (0), 8 data bits LSB first, a stop bit (1). *)
let midi_bit = 1600

let midi_line bytes =
  List.concat_map bytes ~f:(fun b -> (0 :: List.init 8 ~f:(fun k -> (b lsr k) land 1)) @ [ 1; 1 ])
  |> Array.of_list
;;

(* bytes on a line, read the way a MIDI IN port does: wait for a start bit (a falling edge; the
   pin is low for a few cycles at power-up, before the program drives it), sample mid-bit *)
let midi_read samples =
  let n = Array.length samples in
  let rec go i acc =
    if i >= n
    then List.rev acc
    else if i > 0 && samples.(i) = 0 && samples.(i - 1) = 1
    then (
      let at k = samples.(Int.min (n - 1) (i + (midi_bit / 2) + (k * midi_bit))) in
      let byte = List.fold (List.init 8 ~f:(fun k -> k)) ~init:0 ~f:(fun a k -> a lor (at (k + 1) lsl k)) in
      go (i + (10 * midi_bit) - (midi_bit / 2)) (byte :: acc))
    else go (i + 1) acc
  in
  go 0 []
;;

let hex_bytes l = String.concat ~sep:" " (List.map l ~f:(sprintf "%02x"))

let midi_out_messages =
  [ [ 0x90; 0x643C ] (* note on, C4, velocity 100 *)
  ; [ 0x90; 0x6440 ] (* same status: left out *)
  ; [ 0xF8 ] (* timing clock *)
  ; [ 0x90; 0x0040 ] (* note on with velocity 0 *)
  ; [ 0xC5; 0x0010 ] (* program change, one data byte *)
  ; [ 0x80; 0x003C ] (* note off *)
  ; [ 0x80; 0x0040 ] (* same status: left out *)
  ]
;;

let%expect_test "midi_out.s: running status, checked on the wire" =
  let ls = Lockstep.create (load "midi_out.s") in
  Lockstep.record ls ~ns_per_cycle:20. "midi_out";
  let pending = Queue.of_list (List.concat midi_out_messages) in
  let samples = ref [] in
  for _ = 1 to 400_000 do
    let send = Queue.peek pending in
    let _, wrote = Lockstep.step ?send ls Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    samples := bit (Lockstep.uo ls) 0 :: !samples
  done;
  let wire = midi_read (Array.of_list (List.rev !samples)) in
  printf "on the wire: %s\n" (hex_bytes wire);
  Lockstep.note ls "bytes" wire;
  (* 90 3c 64, then 40 64 with the repeated 90 left out, f8 alone, 40 00 still under 90, then
     c5 10, 80 3c 00, and 40 00 under 80 *)
  [%expect {| on the wire: 90 3c 64 40 64 f8 40 00 c5 10 80 3c 00 40 00 |}]
;;

let midi_in_stream =
  [ 0x90; 0x3C; 0x64 (* note on *)
  ; 0x40; 0xF8; 0x64 (* running status, with a clock between its two data bytes *)
  ; 0xC5; 0x10 (* program change *)
  ; 0x11 (* running status for a one-byte message *)
  ; 0xF0; 0x7E; 0xF7 (* a short system exclusive: ends the running status *)
  ; 0x45 (* a data byte with no status before it *)
  ]
;;

let print_midi_words words =
  let rec go = function
    | s :: d :: rest when s land 0x8000 <> 0 ->
      printf "  message %02x %02x %02x\n" (s land 0xff) (d land 0xff) (d lsr 8);
      go rest
    | o :: rest ->
      printf "  byte %02x\n" (o land 0xff);
      go rest
    | [] -> ()
  in
  go words
;;

let%expect_test "midi_in.s: whole messages from a byte stream" =
  let ls = Lockstep.create (load "midi_in.s") in
  Lockstep.record ls ~ns_per_cycle:20. "midi_in";
  let line = midi_line midi_in_stream in
  let got = ref [] in
  for c = 0 to (Array.length line * midi_bit) + 20_000 do
    let level = if c < 5000 then 1 else if (c - 5000) / midi_bit < Array.length line then line.((c - 5000) / midi_bit) else 1 in
    let read, _ = Lockstep.step ~receive:true ls { Model.Pads.zero with ui_in = level lsl 3 } in
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  print_midi_words (List.rev !got);
  Lockstep.note ls "bytes" midi_in_stream;
  [%expect {|
      message 90 3c 64
      byte f8
      message 90 40 64
      message c5 10 00
      message c5 11 00
      byte f0
      byte 7e
      byte f7
      byte 45
    |}]
;;

let%expect_test "midi_out.s on one engine into midi_in.s on another" =
  let tx = Lockstep.create (load "midi_out.s")
  and rx = Lockstep.create (load "midi_in.s") in
  let pending = Queue.of_list (List.concat midi_out_messages) in
  let got = ref [] in
  for _ = 1 to 400_000 do
    let send = Queue.peek pending in
    let _, wrote = Lockstep.step ?send tx Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    let line = bit (Lockstep.uo tx) 0 in
    let read, _ = Lockstep.step ~receive:true rx { Model.Pads.zero with ui_in = line lsl 3 } in
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  print_midi_words (List.rev !got);
  [%expect {|
      message 90 3c 64
      message 90 40 64
      byte f8
      message 90 40 00
      message c5 10 00
      message 80 3c 00
      message 80 40 00
    |}]
;;

(* ---- DMX512 (ANSI E1.11): 250 kbit/s, breaks and MABs, start codes, a fixture's footprint.
   The other end is Dmx_node, written from the standard. *)
let print_dmx_seen packets worst =
  List.iter packets ~f:(fun (p : Dmx_node.seen) ->
    match p.got with
    | [] -> printf "break %d us, MAB %d us, no slots\n" (p.brk / Dmx_node.us) (p.mab / Dmx_node.us)
    | sc :: data ->
      printf "break %d us, MAB %d us, start code %02x, %d slots: %s%s%s\n" (p.brk / Dmx_node.us)
        (p.mab / Dmx_node.us) sc (List.length data) (hex_bytes data)
        (if p.period > 0 then sprintf " (a slot every %d us)" (p.period / Dmx_node.us) else "")
        (if List.is_empty p.framing then "" else " FRAMING ERRORS"));
  printf "largest edge distance from the 4 us grid: %d cycles\n" worst;
  printf "E1.11 transmitter timing (break >= 92 us, MAB >= 12 us): %s\n"
    (if List.for_all packets ~f:(fun p -> p.brk >= 92 * Dmx_node.us && p.mab >= 12 * Dmx_node.us)
     then "met"
     else "NOT MET")
;;

let dmx_tx_packets =
  [ [ 0x00; 0x01; 0x02; 0x04; 0x08; 0x10; 0x20; 0x40; 0x80 ]
  ; [ 0x17; 0x44; 0x4D; 0x58 ] (* a text packet (start code 0x17) *)
  ; [ 0x00; 0xFF ]
  ]
;;

let run_dmx_tx ?(name = "") ?(mark_bits = 0) ~break_bits ~mab_bits packets ~cycles =
  let ls = Lockstep.create (load "dmx_tx.s") in
  if not (String.is_empty name) then Lockstep.record ls ~ns_per_cycle:20. name;
  let host = [ Dmx_node.bit; break_bits; mab_bits; mark_bits ] @ List.concat_map packets ~f:(fun p -> List.length p :: p) in
  let pending = Queue.of_list host in
  let samples = Array.create ~len:cycles 0 in
  for c = 0 to cycles - 1 do
    let send = Queue.peek pending in
    let _, wrote = Lockstep.step ?send ls Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    samples.(c) <- bit (Lockstep.uo ls) 0
  done;
  ls, samples
;;

let%expect_test "dmx_tx.s: packets checked by a receiver written from E1.11" =
  (* a 4 us mark between slots here: sigrok's dmx512 decoder needs one (see sigrok_check.py) *)
  let ls, samples =
    run_dmx_tx ~name:"dmx_tx" ~mark_bits:1 ~break_bits:44 ~mab_bits:3 dmx_tx_packets ~cycles:80_000
  in
  let packets, worst = Dmx_node.read samples in
  print_dmx_seen packets worst;
  Lockstep.note ls "slots" (List.hd_exn dmx_tx_packets);
  [%expect {|
    break 176 us, MAB 12 us, start code 00, 8 slots: 01 02 04 08 10 20 40 80 (a slot every 48 us)
    break 176 us, MAB 12 us, start code 17, 3 slots: 44 4d 58 (a slot every 48 us)
    break 176 us, MAB 12 us, start code 00, 1 slots: ff (a slot every 48 us)
    largest edge distance from the 4 us grid: 0 cycles
    E1.11 transmitter timing (break >= 92 us, MAB >= 12 us): met
    |}]
;;

let%expect_test "dmx_tx.s: the shortest break and MAB E1.11 lets a transmitter send" =
  let _, samples = run_dmx_tx ~break_bits:23 ~mab_bits:3 [ [ 0x00; 0x5A ]; [ 0x00; 0xA5 ] ] ~cycles:24_000 in
  let packets, worst = Dmx_node.read samples in
  print_dmx_seen packets worst;
  [%expect {|
    break 92 us, MAB 12 us, start code 00, 1 slots: 5a (a slot every 44 us)
    break 92 us, MAB 12 us, start code 00, 1 slots: a5 (a slot every 44 us)
    largest edge distance from the 4 us grid: 0 cycles
    E1.11 transmitter timing (break >= 92 us, MAB >= 12 us): met
    |}]
;;

let print_dmx_words words =
  List.iter words ~f:(fun w ->
    if w < 0x100
    then printf "  channel value %02x\n" w
    else if w land 0xFF00 = 0x0100
    then printf "  skipped a packet with start code %02x\n" (w land 0xff)
    else if w land 0x8000 <> 0
    then printf "  packet ended after %d slots, before the footprint did\n" (w land 0x3ff)
    else if w land 0x4000 <> 0
    then printf "  framing error in slot %d\n" (w land 0x3ff)
    else if w = 0x2001
    then printf "  low too short for a break\n"
    else if w = 0x2002
    then printf "  MAB too short\n"
    else printf "  ? %04x\n" w)
;;

let run_dmx_rx ?(name = "") ~address ~footprint line =
  let ls = Lockstep.create (load "dmx_rx.s") in
  if not (String.is_empty name) then Lockstep.record ls ~ns_per_cycle:20. name;
  let pending = Queue.of_list [ Dmx_node.bit; address; footprint ] in
  let got = ref [] in
  Array.iter line ~f:(fun level ->
    let send = Queue.peek pending in
    let read, wrote = Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = level lsl 3 } in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got));
  ls, List.rev !got
;;

let%expect_test "dmx_rx.s: a fixture at address 3 with 4 channels, against a line from E1.11" =
  let open Dmx_node in
  let packets =
    [ packet ~gap_us:4 [ 0x00; 0x11; 0x22; 0x33; 0x44; 0x55; 0x66; 0x77; 0x88 ]
    ; packet [ 0xCC; 0x01; 0x10; 0x20; 0x30 ] (* an RDM start code *)
    ; packet ~break_us:80 [ 0x00; 0xAA; 0xBB; 0xCC; 0xDD; 0xEE; 0xFF ] (* break too short *)
    ; packet ~break_us:90 ~mab_us:6 [ 0x00; 0xAA; 0xBB; 0xCC; 0xDD ] (* MAB too short *)
    ; packet ~break_us:90 ~mab_us:9 ~gap_us:20 [ 0x00; 0x01; 0x02; 0x03; 0x04; 0x05; 0x06 ]
    ; packet [ 0x00; 0x07; 0x08; 0x09 ] (* ends before the footprint does *)
    ; packet ~gap_us:20 ~bad_stop:4 [ 0x00; 0x10; 0x20; 0x30; 0x40; 0x50 ]
    ; packet ~break_us:2000 [ 0x00; 0xA1; 0xA2; 0xA3; 0xA4; 0xA5; 0xA6; 0xA7; 0xA8 ]
    ]
  in
  let ls, got = run_dmx_rx ~name:"dmx_rx" ~address:3 ~footprint:4 (line packets) in
  print_dmx_words got;
  Lockstep.note ls "slots" (List.hd_exn packets).slots;
  [%expect {|
    channel value 33
    channel value 44
    channel value 55
    channel value 66
    skipped a packet with start code cc
    low too short for a break
    MAB too short
    channel value 03
    channel value 04
    channel value 05
    channel value 06
    channel value 09
    packet ended after 4 slots, before the footprint did
    channel value 30
    framing error in slot 4
    channel value a3
    channel value a4
    channel value a5
    channel value a6
    |}]
;;

let%expect_test "dmx_tx.s on one engine into dmx_rx.s on another" =
  let tx = Lockstep.create (load "dmx_tx.s")
  and rx = Lockstep.create (load "dmx_rx.s") in
  let packets = [ [ 0x00; 0x10; 0x20; 0x30; 0x40 ]; [ 0x17; 0x44; 0x4D; 0x58 ]; [ 0x00; 0x01; 0x02; 0x03 ] ] in
  let to_tx = Queue.of_list ([ Dmx_node.bit; 23; 3; 0 ] @ List.concat_map packets ~f:(fun p -> List.length p :: p))
  and to_rx = Queue.of_list [ Dmx_node.bit; 1; 3 ] in
  let got = ref [] in
  for _ = 1 to 50_000 do
    let send = Queue.peek to_tx in
    let _, wrote = Lockstep.step ?send tx Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn to_tx : int);
    let send = Queue.peek to_rx in
    let read, wrote =
      Lockstep.step ?send ~receive:true rx { Model.Pads.zero with ui_in = bit (Lockstep.uo tx) 0 lsl 3 }
    in
    if wrote then ignore (Queue.dequeue_exn to_rx : int);
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  print_dmx_words (List.rev !got);
  [%expect {|
    channel value 10
    channel value 20
    channel value 30
    skipped a packet with start code 17
    channel value 01
    channel value 02
    channel value 03
    |}]
;;

(* ---- LIN 2.2A (ISO 17987). Most LIN tests run 10 times faster than 19200 bit/s (a bit is
   260 + 107/256 cycles) to keep the lockstep runs short, and are recorded at 200 ns a cycle so
   the waveforms have the real timing; one test runs at the real rate. The other ends are
   Lin_node, written from the standard. *)
let lin_fast = 260, 107
let lin_real = 2604, 43
let bit_of (whole, frac) = Float.of_int whole +. (Float.of_int frac /. 256.)

let lin_frame_word ~id ~len ~send ~classic =
  id lor ((len - 1) lsl 8) lor (if send then 1 lsl 12 else 0) lor if classic then 1 lsl 13 else 0
;;

let lin_responder_table : int -> Lin_node.answer = function
  | 0x10 -> Subscribe { length = 2; classic = false }
  | 0x22 -> Publish { data = [ 0x11; 0x22; 0x33; 0x44 ]; classic = false; bad_checksum = false }
  | 0x3C -> Subscribe { length = 8; classic = true }
  | 0x3D ->
    Publish { data = [ 0x7E; 0x06; 0xF2; 0x01; 0x02; 0x03; 0x04; 0xFF ]; classic = true; bad_checksum = false }
  | 0x23 -> Publish { data = [ 0x55; 0xAA ]; classic = false; bad_checksum = true }
  | _ -> Ignore
;;

(* the commander's schedule: (what, ID, data bytes, the commander sends them, classic checksum) *)
let lin_schedule =
  [ "commander sends 2 bytes", 0x10, [ 0x12; 0x34 ], true, false
  ; "responder sends 4 bytes", 0x22, [], false, false
  ; "master request (diagnostic, classic)", 0x3C, [ 0x7F; 0x06; 0xB2; 0x00; 0xFF; 0x7F; 0xFF; 0xFF ], true, true
  ; "slave response (diagnostic, classic)", 0x3D, [], false, true
  ; "responder sends a bad checksum", 0x23, [], false, false
  ; "nobody answers", 0x15, [], false, false
  ]
;;

let lin_lengths = function
  | 0x22 -> 4
  | 0x3D -> 8
  | _ -> 2
;;

let print_lin_status s =
  if s = 0x8000
  then "ok"
  else
    String.concat ~sep:", "
      (List.filter_map [ 1, "checksum wrong"; 2, "no response"; 4, "bit error" ] ~f:(fun (b, what) ->
         if s land b <> 0 then Some what else None))
;;

let run_lin_commander ?name ?(schedule = lin_schedule) ~rate ~bits () =
  let ls = Lockstep.create (load "lin_commander.s") in
  Option.iter name ~f:(fun n -> Lockstep.record ls ~ns_per_cycle:(20. *. bit_of lin_real /. bit_of rate) n);
  let responder = Lin_node.Responder.create ~bit:(bit_of rate) ~table:lin_responder_table in
  let host =
    [ fst rate; snd rate ]
    @ List.concat_map schedule ~f:(fun (_, id, data, send, classic) ->
      let len = if send then List.length data else lin_lengths id in
      lin_frame_word ~id ~len ~send ~classic :: (if send then data else []))
  in
  let pending = Queue.of_list host in
  let got = ref [] in
  let bus_bits = ref [] in
  let cycles = Float.iround_up_exn (bit_of rate *. Float.of_int bits) in
  for c = 0 to cycles do
    let chip_tx = if bit (Lockstep.uio_oe ls) 0 = 1 then bit (Lockstep.uio_out ls) 0 else 1 in
    let bus = chip_tx land Lin_node.Responder.drive responder ~cycle:c in
    Lin_node.Responder.observe responder ~cycle:c ~bus;
    let send = Queue.peek pending in
    let read, wrote = Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = bus lsl 3 } in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got);
    bus_bits := bus :: !bus_bits
  done;
  (* the host's words, frame by frame: data bytes, then a status word *)
  let rec frames words acc cur =
    match words with
    | [] -> List.rev acc
    | w :: rest when w land 0x8000 <> 0 -> frames rest ((List.rev cur, w) :: acc) []
    | w :: rest -> frames rest acc (w :: cur)
  in
  ls, frames (List.rev !got) [] [], responder
;;

let%expect_test "lin_commander.s: a schedule against a responder written from LIN 2.2A" =
  (* about 560 bits of frames, and 65535 cycles of waiting for the frame nobody answers *)
  let ls, results, responder = run_lin_commander ~name:"lin_commander" ~rate:lin_fast ~bits:820 () in
  List.iter2_exn lin_schedule results ~f:(fun (what, id, _, _, _) (data, status) ->
    printf "%02x %-38s %s%s\n" id what
      (if List.is_empty data then "" else sprintf "read %s, " (hex_bytes data))
      (print_lin_status status));
  List.iter (List.rev responder.frames) ~f:(fun (id, data, good) ->
    printf "responder got %02x: %s, checksum %s\n" id (hex_bytes data) (if good then "good" else "BAD"));
  Lockstep.note ls "ids" (List.map lin_schedule ~f:(fun (_, id, _, _, _) -> id));
  Lockstep.note ls "data"
    (List.concat_map lin_schedule ~f:(fun (_, id, data, send, _) ->
       if send
       then data
       else (
         match lin_responder_table id with
         | Publish p -> p.data
         | _ -> [])));
  Lockstep.note ls "invalid" [ 0x23 ];
  [%expect {|
    10 commander sends 2 bytes                ok
    22 responder sends 4 bytes                read 11 22 33 44, ok
    3c master request (diagnostic, classic)   ok
    3d slave response (diagnostic, classic)   read 7e 06 f2 01 02 03 04 ff, ok
    23 responder sends a bad checksum         read 55 aa, checksum wrong
    15 nobody answers                         no response
    responder got 10: 12 34, checksum good
    responder got 3c: 7f 06 b2 00 ff 7f ff ff, checksum good
    |}]
;;

let%expect_test "lin_commander.s at the real 19200 bit/s" =
  let schedule = List.take lin_schedule 2 in
  let _, results, responder = run_lin_commander ~schedule ~rate:lin_real ~bits:180 () in
  List.iter2_exn schedule results ~f:(fun (what, id, _, _, _) (data, status) ->
    printf "%02x %-38s %s%s\n" id what
      (if List.is_empty data then "" else sprintf "read %s, " (hex_bytes data))
      (print_lin_status status));
  List.iter (List.rev responder.frames) ~f:(fun (id, data, good) ->
    printf "responder got %02x: %s, checksum %s\n" id (hex_bytes data) (if good then "good" else "BAD"));
  [%expect {|
    10 commander sends 2 bytes                ok
    22 responder sends 4 bytes                read 11 22 33 44, ok
    responder got 10: 12 34, checksum good
    |}]
;;

(* the commander side for lin_responder.s, from the spec: each frame gets a 150-bit slot at the
   commander's own bit time; what it sends is fixed, what comes back is read off the bus *)
let lin_header ?pid_byte ?(break_bits = 13) id = Lin_node.header ~break_bits ~pid_byte id

let lin_sends ?(bad = false) ?(classic = false) id data =
  lin_header id @ Lin_node.response ~bad_checksum:bad ~classic ~pid:(Lin_node.pid id) data
;;

let lin_host_answer id =
  match id with
  | 0x10 -> [ 2 ]
  | 0x22 -> [ 0x104; 0x11; 0x22; 0x33; 0x44 ]
  | 0x3D -> [ 0x308; 0x7E; 0x06; 0xF2; 0x01; 0x02; 0x03; 0x04; 0xFF ]
  | _ -> [ 0 ]
;;

let run_lin_responder ?(record = false) ~bit_factor slots =
  let ls = Lockstep.create (load "lin_responder.s") in
  if record then Lockstep.record ls ~ns_per_cycle:(20. *. bit_of lin_real /. bit_of lin_fast) "lin_responder";
  let cbit = bit_of lin_fast *. bit_factor in
  let slot = 150. *. cbit
  and first = 2000. in
  let slots = Array.of_list (List.map slots ~f:Array.of_list) in
  let start i = first +. (Float.of_int i *. slot) in
  let commander c =
    let i = Float.iround_down_exn ((Float.of_int c -. first) /. slot) in
    if Float.(of_int c < first) || i >= Array.length slots
    then 1
    else (
      let k = Float.iround_down_exn ((Float.of_int c -. start i) /. cbit) in
      if k < Array.length slots.(i) then slots.(i).(k) else 1)
  in
  let rx = Lin_node.Rx.create ~bit:cbit in
  let heard = ref [] in
  let to_chip = Queue.of_list [ fst lin_fast ] in
  let got = ref [] in
  for c = 0 to Float.iround_up_exn (start (Array.length slots)) do
    let chip_tx = if bit (Lockstep.uio_oe ls) 0 = 1 then bit (Lockstep.uio_out ls) 0 else 1 in
    let bus = chip_tx land commander c in
    Option.iter (Lin_node.Rx.step rx ~cycle:c ~bus) ~f:(fun (v, ok) -> heard := (c, v, ok) :: !heard);
    let send = Queue.peek to_chip in
    let read, wrote = Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = bus lsl 3 } in
    if wrote then ignore (Queue.dequeue_exn to_chip : int);
    Option.iter read ~f:(fun v ->
      got := v :: !got;
      if v land 0xFF00 = 0x0100 then List.iter (lin_host_answer (v land 0x3F)) ~f:(Queue.enqueue to_chip))
  done;
  (* what the commander read in each slot after the header: the responder's bytes *)
  let after_header i =
    List.filter_map (List.rev !heard) ~f:(fun (c, v, _) ->
      let c = Float.of_int c
      and from = start i +. (Float.of_int (Array.length slots.(i)) *. cbit)
      and until = start (i + 1) in
      if Float.(c > from && c < until) then Some v else None)
  in
  ls, List.rev !got, after_header
;;

let print_lin_responder words ~nominal =
  let rec go = function
    | t8 :: code :: rest ->
      let what =
        if code land 0xFF00 = 0x0400
        then "sync byte out of range"
        else if code land 0xFF00 = 0x0200
        then sprintf "identifier %02x: parity wrong" (code land 0xff)
        else sprintf "identifier %02x" (code land 0xff)
      in
      printf "  sync byte: 8 bits in %d cycles (%.2f a bit, %+.2f%% from ours); %s" t8
        (Float.of_int t8 /. 8.)
        (100. *. ((Float.of_int t8 /. 8. /. nominal) -. 1.))
        what;
      let rec response acc = function
        | s :: rest when s land 0x8000 <> 0 ->
          printf ": %s%s\n"
            (if List.is_empty acc then "" else sprintf "received %s, " (hex_bytes (List.rev acc)))
            (print_lin_status s);
          go rest
        | d :: rest -> response (d :: acc) rest
        | [] -> printf "\n"
      in
      if code land 0xFF00 = 0x0100 && List.hd_exn (lin_host_answer (code land 0x3F)) <> 0
      then response [] rest
      else (
        printf "\n";
        go rest)
    | [ w ] -> printf "  ? %04x\n" w
    | [] -> ()
  in
  go words
;;

let%expect_test "lin_responder.s: syncs to commanders with a bit time 12% short and 12% long" =
  List.iter [ 0.88; 1.0; 1.12 ] ~f:(fun f ->
    printf "commander's bit %.2f cycles:\n" (bit_of lin_fast *. f);
    (* recorded at 12% slow: sigrok then reads the whole bus at the commander's 17143 bit/s *)
    let ls, words, heard =
      run_lin_responder ~record:Float.(f = 1.12) ~bit_factor:f
        [ lin_sends 0x10 [ 0xA5; 0x5A ]; lin_header 0x22; lin_header 0x15 ]
    in
    Lockstep.note ls "ids" [ 0x10; 0x22; 0x15 ];
    Lockstep.note ls "data" [ 0xA5; 0x5A; 0x11; 0x22; 0x33; 0x44 ];
    Lockstep.note ls "invalid" [];
    print_lin_responder words ~nominal:(bit_of lin_fast);
    let r = heard 1 in
    printf "  the commander read %s, checksum %s\n" (hex_bytes r)
      (match List.rev r with
       | c :: rd when List.length r = 5 ->
         if Lin_node.checksum ~classic:false ~pid:(Lin_node.pid 0x22) (List.rev rd) = c then "good" else "BAD"
       | _ -> "missing"));
  [%expect {|
    commander's bit 229.17 cycles:
      sync byte: 8 bits in 1833 cycles (229.12 a bit, -12.02% from ours); identifier 50: received a5 5a, ok
      sync byte: 8 bits in 1833 cycles (229.12 a bit, -12.02% from ours); identifier e2: ok
      sync byte: 8 bits in 1834 cycles (229.25 a bit, -11.97% from ours); identifier 55
      the commander read 11 22 33 44 72, checksum good
    commander's bit 260.42 cycles:
      sync byte: 8 bits in 2084 cycles (260.50 a bit, +0.03% from ours); identifier 50: received a5 5a, ok
      sync byte: 8 bits in 2083 cycles (260.38 a bit, -0.02% from ours); identifier e2: ok
      sync byte: 8 bits in 2083 cycles (260.38 a bit, -0.02% from ours); identifier 55
      the commander read 11 22 33 44 72, checksum good
    commander's bit 291.67 cycles:
      sync byte: 8 bits in 2333 cycles (291.62 a bit, +11.98% from ours); identifier 50: received a5 5a, ok
      sync byte: 8 bits in 2333 cycles (291.62 a bit, +11.98% from ours); identifier e2: ok
      sync byte: 8 bits in 2334 cycles (291.75 a bit, +12.03% from ours); identifier 55
      the commander read 11 22 33 44 72, checksum good
    |}]
;;

let%expect_test "lin_responder.s: what it must ignore or report" =
  let _, words, heard =
    run_lin_responder ~bit_factor:1.0
      [ lin_header 0x3D (* it sends 8 bytes with the classic checksum *)
      ; lin_sends ~bad:true 0x10 [ 0x01; 0x02 ] (* a bad checksum *)
      ; lin_header ~pid_byte:(Lin_node.pid 0x22 lxor 0x80) 0x22 (* a parity bit wrong *)
      ; Lin_node.byte_bits 0x00 @ List.init 20 ~f:(fun _ -> 1) @ lin_header 0x15 (* a 0x00 byte, then a frame for nobody *)
      ; lin_header ~break_bits:10 0x22 (* dominant for only 10 bits: not a break *)
      ]
  in
  print_lin_responder words ~nominal:(bit_of lin_fast);
  printf "the commander read in slot 0: %s\n" (hex_bytes (heard 0));
  printf "the commander read in slot 4: %s\n" (hex_bytes (heard 4));
  [%expect {|
      sync byte: 8 bits in 2084 cycles (260.50 a bit, +0.03% from ours); identifier 7d: ok
      sync byte: 8 bits in 2083 cycles (260.38 a bit, -0.02% from ours); identifier 50: received 01 02, checksum wrong
      sync byte: 8 bits in 2083 cycles (260.38 a bit, -0.02% from ours); identifier 62: parity wrong
      sync byte: 8 bits in 2083 cycles (260.38 a bit, -0.02% from ours); identifier 55
    the commander read in slot 0: 7e 06 f2 01 02 03 04 ff 7e
    the commander read in slot 4:
    |}]
;;

let%expect_test "lin_commander.s on one engine and lin_responder.s on another" =
  let cmd = Lockstep.create (load "lin_commander.s")
  and rsp = Lockstep.create (load "lin_responder.s") in
  let schedule =
    [ 0x10, [ 0x01; 0x02 ], true, false; 0x22, [], false, false; 0x3D, [], false, true; 0x15, [], false, false ]
  in
  let to_cmd =
    Queue.of_list
      ([ fst lin_fast; snd lin_fast ]
       @ List.concat_map schedule ~f:(fun (id, data, send, classic) ->
         let len = if send then List.length data else lin_lengths id in
         lin_frame_word ~id ~len ~send ~classic :: data))
  and to_rsp = Queue.of_list [ fst lin_fast ] in
  let from_cmd = ref []
  and from_rsp = ref [] in
  let level ls = if bit (Lockstep.uio_oe ls) 0 = 1 then bit (Lockstep.uio_out ls) 0 else 1 in
  for _ = 0 to 180_000 do
    let bus = level cmd land level rsp in
    let pads = { Model.Pads.zero with ui_in = bus lsl 3 } in
    let send = Queue.peek to_cmd in
    let read, wrote = Lockstep.step ?send ~receive:true cmd pads in
    if wrote then ignore (Queue.dequeue_exn to_cmd : int);
    Option.iter read ~f:(fun v -> from_cmd := v :: !from_cmd);
    let send = Queue.peek to_rsp in
    let read, wrote = Lockstep.step ?send ~receive:true rsp pads in
    if wrote then ignore (Queue.dequeue_exn to_rsp : int);
    Option.iter read ~f:(fun v ->
      from_rsp := v :: !from_rsp;
      if v land 0xFF00 = 0x0100 then List.iter (lin_host_answer (v land 0x3F)) ~f:(Queue.enqueue to_rsp))
  done;
  printf "commander's host: %s\n" (String.concat ~sep:" " (List.rev_map !from_cmd ~f:(sprintf "%x")));
  printf "responder's host:\n";
  print_lin_responder (List.rev !from_rsp) ~nominal:(bit_of lin_fast);
  [%expect {|
    commander's host: 8000 11 22 33 44 8000 7e 6 f2 1 2 3 4 ff 8000 8002
    responder's host:
      sync byte: 8 bits in 2083 cycles (260.38 a bit, -0.02% from ours); identifier 50: received 01 02, ok
      sync byte: 8 bits in 2083 cycles (260.38 a bit, -0.02% from ours); identifier e2: ok
      sync byte: 8 bits in 2083 cycles (260.38 a bit, -0.02% from ours); identifier 7d: ok
      sync byte: 8 bits in 2084 cycles (260.50 a bit, +0.03% from ours); identifier 55
    |}]
;;
