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

(* ---- JTAG (IEEE 1149.1): a TAP, a controller and a passive monitor. The other ends are
   Jtag_node, written from the standard. *)
let tap_idcode = 0x1C0FFEE1
let tap_ids = [ tap_idcode land 0xFFFF; tap_idcode lsr 16; 0x1234 ]

(* a controller's moves as named pieces, so the TDO bits of each can be found afterwards *)
let jtag_script =
  let open Jtag_node in
  [ None, reset
  ; None, to_shift_dr
  ; Some "IDCODE (32 bits)", shift ~n:32 0
  ; None, to_idle
  ; None, to_shift_ir
  ; Some "IR capture, loading USER", shift ~n:4 user_ir
  ; None, to_idle
  ; None, to_shift_dr
  ; Some "USER, writing beef", shift ~n:16 0xBEEF
  ; None, to_idle
  ; None, to_shift_dr
  ; Some "USER, first 8 bits", shift ~n:8 0x00
  ; None, tms [ 0; 0; 0; 1; 0 ] (* Pause-DR three ticks, Exit2-DR, back to Shift-DR *)
  ; Some "USER, last 8 bits after a pause", shift ~n:8 0x00
  ; None, to_idle
  ; None, to_shift_ir
  ; Some "IR capture, loading BYPASS", shift ~n:4 0b1111
  ; None, to_idle
  ; None, to_shift_dr
  ; Some "BYPASS, shifting 10110011", shift ~n:8 0b10110011
  ; None, to_idle
  ; None, reset
  ; None, to_shift_dr
  ; Some "IDCODE again after a TMS reset", shift ~n:32 0
  ; None, to_idle
  ]
;;

let run_jtag_tap ?(record = false) ~half script =
  let ls = Lockstep.create (load "jtag_tap.s") in
  if record then Lockstep.record ls ~ns_per_cycle:20. "jtag_tap";
  let ctl = Jtag_node.Controller.create ~half (List.concat_map script ~f:snd) in
  let pending = Queue.of_list tap_ids in
  let got = ref [] in
  for c = 0 to 200 + Jtag_node.Controller.cycles ctl do
    (* the controller starts once the program has its setup words *)
    let cycle = c - 200 in
    let tck, tms, tdi = if cycle < 0 then 0, 1, 0 else Jtag_node.Controller.levels ctl ~cycle in
    let tdo = if bit (Lockstep.uio_oe ls) 0 = 1 then bit (Lockstep.uio_out ls) 0 else 1 in
    if cycle >= 0 then Jtag_node.Controller.read_tdo ctl ~cycle ~tdo;
    let send = Queue.peek pending in
    let read, wrote =
      Lockstep.step ?send ~receive:true ls
        { Model.Pads.zero with ui_in = (tck lsl 4) lor (tms lsl 5) lor (tdi lsl 6) }
    in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  (* the TDO bits of each named piece *)
  let _, results =
    List.fold script ~init:(0, []) ~f:(fun (pos, acc) (name, bits) ->
      let n = List.length bits in
      ( pos + n
      , match name with
        | None -> acc
        | Some what -> (what, n, Jtag_node.value ctl.tdo ~from:pos ~n) :: acc ))
  in
  ls, List.rev results, List.rev !got
;;

let%expect_test "jtag_tap.s: found and used by a controller written from IEEE 1149.1, TCK 1 MHz" =
  let _, results, words = run_jtag_tap ~half:25 jtag_script in
  List.iter results ~f:(fun (what, n, v) -> printf "%-34s TDO %0*x\n" what ((n + 3) / 4) v);
  printf "USER values the host was sent: %s\n" (String.concat ~sep:" " (List.map words ~f:(sprintf "%04x")));
  [%expect {|
    IDCODE (32 bits)                   TDO 1c0ffee1
    IR capture, loading USER           TDO 1
    USER, writing beef                 TDO 1234
    USER, first 8 bits                 TDO ef
    USER, last 8 bits after a pause    TDO be
    IR capture, loading BYPASS         TDO 1
    BYPASS, shifting 10110011          TDO 66
    IDCODE again after a TMS reset     TDO 1c0ffee1
    USER values the host was sent: beef 0000
    |}]
;;

let%expect_test "jtag_tap.s: how fast TCK can go" =
  let script = List.take jtag_script 4 in
  List.iter [ 50; 25; 16; 12; 10; 8; 7; 6; 5 ] ~f:(fun half ->
    let _, results, _ = run_jtag_tap ~half script in
    let _, _, id = List.hd_exn results in
    printf "TCK %.2f MHz (%d cycles high, %d low): IDCODE %08x %s\n"
      (50. /. Float.of_int (2 * half)) half half id
      (if id = tap_idcode then "right" else "WRONG"));
  [%expect {|
    TCK 0.50 MHz (50 cycles high, 50 low): IDCODE 1c0ffee1 right
    TCK 1.00 MHz (25 cycles high, 25 low): IDCODE 1c0ffee1 right
    TCK 1.56 MHz (16 cycles high, 16 low): IDCODE 1c0ffee1 right
    TCK 2.08 MHz (12 cycles high, 12 low): IDCODE 1c0ffee1 right
    TCK 2.50 MHz (10 cycles high, 10 low): IDCODE 1c0ffee1 right
    TCK 3.12 MHz (8 cycles high, 8 low): IDCODE 1c0ffee1 right
    TCK 3.57 MHz (7 cycles high, 7 low): IDCODE 1c0ffee1 right
    TCK 4.17 MHz (6 cycles high, 6 low): IDCODE 381ffdc3 WRONG
    TCK 5.00 MHz (5 cycles high, 5 low): IDCODE 03fff783 WRONG
    |}]
;;

(* commands for jtag_host.s: a command word and a data word *)
let jcmd ?(tms = false) ?(leave = false) ?(read = false) n data =
  [ (n - 1) lor (if tms then 0x100 else 0) lor (if leave then 0x200 else 0) lor if read then 0x400 else 0
  ; data
  ]
;;

let jtag_host_script =
  List.concat
    [ jcmd ~tms:true 6 0b011111 (* reset, then Run-Test/Idle *)
    ; jcmd ~tms:true 3 0b001 (* to Shift-DR *)
    ; jcmd ~read:true 16 0
    ; jcmd ~read:true 16 0
    ; jcmd ~read:true 16 0
    ; jcmd ~read:true ~leave:true 16 0 (* both IDCODEs, 64 bits *)
    ; jcmd ~tms:true 2 0b01 (* Update-DR, Run-Test/Idle *)
    ; jcmd ~tms:true 4 0b0011 (* to Shift-IR *)
    ; jcmd ~read:true ~leave:true 8 0xFF (* both to BYPASS *)
    ; jcmd ~tms:true 2 0b01
    ; jcmd ~tms:true 3 0b001
    ; jcmd ~read:true ~leave:true 16 0xA5C3 (* through two BYPASS bits *)
    ; jcmd ~tms:true 2 0b01
    ; jcmd ~tms:true 4 0b0011
    ; jcmd ~read:true ~leave:true 8 0xF8 (* the TAP next to TDO: USER; the other: BYPASS *)
    ; jcmd ~tms:true 2 0b01
    ; jcmd ~tms:true 3 0b001
    ; jcmd ~read:true 16 0xBEEF
    ; jcmd ~read:true ~leave:true 1 0 (* 17 bits: USER, then the other TAP's BYPASS bit *)
    ; jcmd ~tms:true 2 0b01
    ]
;;

let%expect_test "jtag_host.s: a chain of two TAPs written from IEEE 1149.1" =
  let ls = Lockstep.create (load "jtag_host.s") in
  let near = Jtag_node.Tap.create ~idcode:0x0FACE00D ~user:0x5678
  and far = Jtag_node.Tap.create ~idcode:tap_idcode ~user:0 in
  (* TDI goes into [far] first; [near] drives TDO *)
  let chain = Jtag_node.Chain.create [ far; near ] in
  let pending = Queue.of_list (25 :: jtag_host_script) in
  let got = ref [] in
  for _ = 0 to 12_000 do
    let uo = Lockstep.uo ls in
    Jtag_node.Chain.step chain ~tck:(bit uo 0) ~tms:(bit uo 1) ~tdi:(bit uo 2);
    let send = Queue.peek pending in
    let read, wrote =
      Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = Jtag_node.Chain.tdo chain lsl 3 }
    in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  (match List.rev !got with
   | [ a; b; c; d; ir1; byp; ir2; user; last ] ->
     printf "IDCODEs, the TAP next to TDO first: %08x %08x\n" ((b lsl 16) lor a) ((d lsl 16) lor c);
     printf "IR captures: %02x\n" ir1;
     printf "a5c3 through the BYPASS bits came out as %04x: %d TAPs in the chain\n" byp
       (List.find_exn [ 0; 1; 2; 3 ] ~f:(fun k -> (0xA5C3 lsl k) land 0xFFFF = byp));
     printf "IR captures: %02x; USER read %04x, then the BYPASS bit %d\n" ir2 user last
   | l -> printf "got %s\n" (String.concat ~sep:" " (List.map l ~f:(sprintf "%x"))));
  printf "the TAP next to TDO: USER now %04x, written %d times\n" near.user (List.length near.updates);
  [%expect {|
    IDCODEs, the TAP next to TDO first: 0face00d 1c0ffee1
    IR captures: 11
    a5c3 through the BYPASS bits came out as 970c: 2 TAPs in the chain
    IR captures: 11; USER read 5678, then the BYPASS bit 0
    the TAP next to TDO: USER now beef, written 1 times
    |}]
;;

let print_jtag_scans words =
  let rec go acc = function
    | w :: rest when w land 0x8000 <> 0 ->
      let n = w land 0x3FFF in
      let pairs = List.rev acc in
      let value pick =
        List.foldi pairs ~init:0 ~f:(fun i v (tdi, tdo) ->
          let word = pick (tdi, tdo) in
          let bits = if (i + 1) * 15 <= n then 15 else n - (i * 15) in
          let word = if bits < 15 then word lsr (15 - bits) else word in
          v lor (word lsl (15 * i)))
      in
      printf "  %s scan, %2d bits: TDI %0*x, TDO %0*x\n"
        (if w land 0x4000 <> 0 then "IR" else "DR")
        n
        ((n + 3) / 4)
        (value fst)
        ((n + 3) / 4)
        (value snd);
      go [] rest
    | tdi :: tdo :: rest -> go ((tdi, tdo) :: acc) rest
    | _ -> ()
  in
  go [] words
;;

let%expect_test "jtag_host.s drives jtag_tap.s, and jtag_mon.s listens: three engines" =
  let host = Lockstep.create (load "jtag_host.s")
  and tap = Lockstep.create (load "jtag_tap.s")
  and mon = Lockstep.create (load "jtag_mon.s") in
  Lockstep.record mon ~ns_per_cycle:20. "jtag";
  let script =
    List.concat
      [ jcmd ~tms:true 6 0b011111
      ; jcmd ~tms:true 3 0b001
      ; jcmd ~read:true 16 0
      ; jcmd ~read:true ~leave:true 16 0
      ; jcmd ~tms:true 2 0b01
      ; jcmd ~tms:true 4 0b0011
      ; jcmd ~read:true ~leave:true 4 0b1000
      ; jcmd ~tms:true 2 0b01
      ; jcmd ~tms:true 3 0b001
      ; jcmd ~read:true ~leave:true 16 0xBEEF
      ; jcmd ~tms:true 2 0b01
      ]
  in
  let to_host = Queue.of_list (25 :: script)
  and to_tap = Queue.of_list tap_ids in
  let from_host = ref []
  and from_tap = ref []
  and from_mon = ref [] in
  let step ls q acc pads =
    let send = Option.bind q ~f:Queue.peek in
    let read, wrote = Lockstep.step ?send ~receive:true ls pads in
    if wrote then Option.iter q ~f:(fun q -> ignore (Queue.dequeue_exn q : int));
    Option.iter read ~f:(fun v -> acc := v :: !acc)
  in
  for c = 0 to 10_000 do
    let uo = Lockstep.uo host in
    (* the controller waits for the TAP's setup words *)
    let tck, tms, tdi = if c < 100 then 0, 1, 0 else bit uo 0, bit uo 1, bit uo 2 in
    let tdo = if bit (Lockstep.uio_oe tap) 0 = 1 then bit (Lockstep.uio_out tap) 0 else 1 in
    let jtag = (tck lsl 4) lor (tms lsl 5) lor (tdi lsl 6) in
    step host (if c < 100 then None else Some to_host) from_host { Model.Pads.zero with ui_in = tdo lsl 3 };
    step tap (Some to_tap) from_tap { Model.Pads.zero with ui_in = jtag };
    step mon None from_mon { Model.Pads.zero with ui_in = jtag lor (tdo lsl 7) }
  done;
  printf "controller's host: %s\n" (String.concat ~sep:" " (List.rev_map !from_host ~f:(sprintf "%04x")));
  printf "TAP's host (USER written): %s\n" (String.concat ~sep:" " (List.rev_map !from_tap ~f:(sprintf "%04x")));
  printf "monitor's host:\n";
  print_jtag_scans (List.rev !from_mon);
  Lockstep.note mon "ir_tdi" [ 0b1000 ];
  Lockstep.note mon "ir_tdo" [ 0b0001 ];
  Lockstep.note mon "dr_tdi" [ 0; 0xBEEF ];
  Lockstep.note mon "dr_tdo" [ tap_idcode; 0x1234 ];
  [%expect {|
    controller's host: fee1 1c0f 0001 1234
    TAP's host (USER written): beef
    monitor's host:
      DR scan, 32 bits: TDI 00000000, TDO 1c0ffee1
      IR scan,  4 bits: TDI 8, TDO 1
      DR scan, 16 bits: TDI beef, TDO 1234
    |}]
;;

(* ---- SWD (ARM Debug Interface v5). The target is Swd_node, a SW-DP and a MEM-AP written from
   the spec. *)
let swd_raw n v = [ n - 1; v ]

let swd_xfer ?(bad_parity = false) ?data ~ap ~reg () =
  let rnw = if Option.is_none data then 1 else 0 in
  (0x8000 lor ap lor (rnw lsl 1) lor (reg lsl 2) lor if bad_parity then 0x1000 else 0)
  :: (match data with
      | None -> []
      | Some v -> [ v land 0xFFFF; v lsr 16 ])
;;

let swd_line_reset = List.concat (List.init 4 ~f:(fun _ -> swd_raw 16 0xFFFF))

(* what the host asks, with a name for each transfer *)
let swd_script =
  let dp = swd_xfer ~ap:0
  and ap = swd_xfer ~ap:1 in
  [ None, swd_line_reset @ swd_raw 16 0xE79E @ swd_line_reset @ swd_raw 2 0
  ; Some "DP read DPIDR", dp ~reg:0 ()
  ; Some "DP write CTRL/STAT 50000000", dp ~reg:1 ~data:0x5000_0000 ()
  ; Some "DP read CTRL/STAT", dp ~reg:1 ()
  ; Some "DP write SELECT 000000f0", dp ~reg:2 ~data:0xF0 ()
  ; Some "AP read IDR (posted)", ap ~reg:3 ()
  ; Some "DP read RDBUFF", dp ~reg:3 ()
  ; Some "DP write SELECT 00000000", dp ~reg:2 ~data:0 ()
  ; Some "AP write CSW 23000012", ap ~reg:0 ~data:0x2300_0012 ()
  ; Some "AP write TAR 20000000", ap ~reg:1 ~data:0x2000_0000 ()
  ; Some "AP write DRW cafef00d", ap ~reg:3 ~data:0xCAFE_F00D ()
  ; Some "AP write DRW 12345678", ap ~reg:3 ~data:0x1234_5678 ()
  ; Some "AP write TAR 20000000", ap ~reg:1 ~data:0x2000_0000 ()
  ; Some "AP read DRW (posted)", ap ~reg:3 ()
  ; Some "AP read DRW (posted)", ap ~reg:3 ()
  ; Some "DP read RDBUFF", dp ~reg:3 ()
  ; Some "DP read DPIDR, parity bit sent wrong", swd_xfer ~bad_parity:true ~ap:0 ~reg:0 ()
  ; None, swd_line_reset @ swd_raw 2 0
  ; Some "DP read DPIDR after a line reset", dp ~reg:0 ()
  ]
;;

let%expect_test "swd_host.s: a debug port and memory access port written from ADIv5" =
  let ls = Lockstep.create (load "swd_host.s") in
  Lockstep.record ls ~ns_per_cycle:20. "swd";
  let target = Swd_node.create ~dpidr:0x2BA01477 ~ap_idr:0x24770011 ~memory:[] in
  let pending = Queue.of_list (25 :: List.concat_map swd_script ~f:snd) in
  let got = ref [] in
  let both = ref 0 in
  for _ = 0 to 80_000 do
    let host_drives = bit (Lockstep.uio_oe ls) 0 = 1 in
    if host_drives && Option.is_some target.drive then incr both;
    let swdio =
      if host_drives then bit (Lockstep.uio_out ls) 0 else Option.value target.drive ~default:1
    in
    Swd_node.step target ~swclk:(bit (Lockstep.uo ls) 0) ~swdio;
    let send = Queue.peek pending in
    let read, wrote = Lockstep.step ?send ~receive:true ls { Model.Pads.zero with uio_in = swdio } in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  let ack = function
    | 1 -> "OK"
    | 2 -> "WAIT"
    | 4 -> "FAULT"
    | 7 -> "no answer"
    | a -> sprintf "ack %d" a
  in
  let words = ref (List.rev !got) in
  let take () =
    match !words with
    | w :: rest ->
      words := rest;
      w
    | [] -> -1
  in
  List.iter swd_script ~f:(fun (name, cmd) ->
    Option.iter name ~f:(fun what ->
      let read = List.length cmd = 1 in
      if read
      then (
        let lo = take () in
        let hi = take () in
        let s = take () in
        printf "%-38s %s %08x%s\n" what (ack (s land 7)) ((hi lsl 16) lor lo)
          (if s land 0x10 <> 0 then " PARITY WRONG" else ""))
      else printf "%-38s %s\n" what (ack (take () land 7))));
  printf "memory: %s\n"
    (String.concat ~sep:" "
       (List.map
          (List.sort (Hashtbl.to_alist target.memory) ~compare:[%compare: int * int])
          ~f:(fun (a, v) -> sprintf "%08x=%08x" a v)));
  printf "the target noted: %s\n" (String.concat ~sep:"; " (List.rev target.log));
  printf "cycles with both sides driving SWDIO: %d\n" !both;
  Lockstep.note ls "acks" (List.init 15 ~f:(fun _ -> 1) @ [ 7; 1 ]);
  Lockstep.note ls "data"
    [ 0x2BA01477; 0x5000_0000; 0xF000_0000; 0xF0; 0; 0x24770011; 0; 0x2300_0012; 0x2000_0000
    ; 0xCAFE_F00D; 0x1234_5678; 0x2000_0000; 0x24770011; 0xCAFE_F00D; 0x1234_5678; 0x2BA01477
    ];
  [%expect {|
    DP read DPIDR                          OK 2ba01477
    DP write CTRL/STAT 50000000            OK
    DP read CTRL/STAT                      OK f0000000
    DP write SELECT 000000f0               OK
    AP read IDR (posted)                   OK 00000000
    DP read RDBUFF                         OK 24770011
    DP write SELECT 00000000               OK
    AP write CSW 23000012                  OK
    AP write TAR 20000000                  OK
    AP write DRW cafef00d                  OK
    AP write DRW 12345678                  OK
    AP write TAR 20000000                  OK
    AP read DRW (posted)                   OK 24770011
    AP read DRW (posted)                   OK cafef00d
    DP read RDBUFF                         OK 12345678
    DP read DPIDR, parity bit sent wrong   no answer 00000000
    DP read DPIDR after a line reset       OK 2ba01477
    memory: 20000000=cafef00d 20000004=12345678
    the target noted: line reset; line reset; DP read 0; DP write 1; DP read 1; DP write 2; AP read 3; DP read 3; DP write 2; AP write 0; AP write 1; AP write 3; AP write 3; AP write 1; AP read 3; AP read 3; DP read 3; request 85 not answered; line reset; DP read 0
    cycles with both sides driving SWDIO: 0
    |}]
;;

(* ---- S/PDIF (IEC 60958): biphase-mark, a line coding the chip was not designed with, done by
   the fabric. *)
let%expect_test "biphase-mark (S/PDIF) transmit configuration, proved" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and d = G.input "d" 1
  and raw = G.input "raw" 1 in
  prove
    ~words:(Pemu_post.Fabric_post.bmc_tx ~n_le:8)
    ~ext:G.(raw @: gnd @: d)
    ~q
    ~spec:(fun ~f ~out ->
      let open G in
      let first = q.(0)
      and last = q.(1) in
      (* biphase-mark: a transition at the start of every cell, another in the middle for a 1;
         raw: a transition for each 1 *)
      let line = mux2 raw (last ^: d) (mux2 first ~:last (last ^: d)) in
      [ out.(0), first
      ; f.(0), raw |: ~:first
      ; out.(1), line
      ; f.(1), line
      ; out.(2), first &: ~:raw (* hold: the bit stays for its second half *)
      ]);
  [%expect {| proved: configuration = rule for all states and inputs |}]
;;

let spdif_rate = 8, 35 (* a half-bit tick of 8 + 35/256 cycles: 128 a frame, 48 kHz *)

(* consumer channel status (24 bytes, bit 0 of byte 0 first): copying permitted, 48 kHz *)
let spdif_status = [ 0x04; 0x00; 0x00; 0x02 ] @ List.init 20 ~f:(fun _ -> 0)

let%expect_test "spdif_tx.s: a block of 192 frames, read by a receiver written from IEC 60958" =
  let ls =
    Lockstep.create ~fabric:(Pemu_post.Fabric_post.bmc_tx ~n_le:Model.n_le) (load "spdif_tx.s")
  in
  Lockstep.record ls ~ns_per_cycle:20. "spdif";
  let frames = 194 in
  let left k = ((k * 0x010203) + 0x123456) land 0xFFFFFF
  and right k = ((k * 0x00F1E2) + 0x765432) land 0xFFFFFF in
  let cbit k = (List.nth_exn spdif_status (k mod 192 / 8) lsr (k mod 8)) land 1 in
  let sub ~pre s ~c = [ s land 0xFFFF; (s lsr 16) lor (c lsl 10) lor (pre lsl 12) ] in
  let host =
    [ fst spdif_rate; snd spdif_rate ]
    @ List.concat
        (List.init frames ~f:(fun k ->
           sub ~pre:(if k % 192 = 0 then 2 else 0) (left k) ~c:(cbit k) @ sub ~pre:1 (right k) ~c:(cbit k)))
  in
  let pending = Queue.of_list host in
  let ui = bit_of spdif_rate in
  let cycles = Float.iround_up_exn (Float.of_int (frames * 128) *. ui) + 2000 in
  let samples = Array.create ~len:cycles 0 in
  for c = 0 to cycles - 1 do
    let send = Queue.peek pending in
    let _, wrote = Lockstep.step ?send ls Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    samples.(c) <- bit (Lockstep.uo ls) 0
  done;
  let subs, bad_runs = Spdif_node.decode samples ~ui in
  let subs = Array.of_list subs in
  let want = 2 * (frames - 1) in
  printf "subframes read: %d (the last frame is still being sent when the host runs out)\n"
    (Array.length subs);
  let ok f = Array.for_alli (Array.sub subs ~pos:0 ~len:want) ~f in
  printf "preambles B at frames 0 and 192, M and W in between: %b\n"
    (ok (fun i s ->
       Char.equal s.preamble
         (if i % 2 = 1 then 'W' else if i / 2 % 192 = 0 then 'B' else 'M')));
  printf "audio samples as sent: %b\n"
    (ok (fun i s -> s.audio = if i % 2 = 0 then left (i / 2) else right (i / 2)));
  printf "parity good: %b; every cell starts with a transition: %b; runs not 1, 2 or 3 half cells: %d\n"
    (ok (fun _ s -> s.parity_ok))
    (ok (fun _ s -> s.biphase_ok))
    bad_runs;
  let per_frame = Float.of_int (subs.(384).at - subs.(0).at) /. 192. in
  printf "a frame every %.2f cycles: %.1f Hz at 50 MHz\n" per_frame (50e6 /. per_frame);
  let status =
    List.init 4 ~f:(fun byte ->
      List.fold (List.init 8 ~f:Fn.id) ~init:0 ~f:(fun a k -> a lor (subs.(2 * ((8 * byte) + k)).c lsl k)))
  in
  printf "channel status bytes 0 to 3, from the C bits: %s\n" (hex_bytes status);
  (* sigrok's decoder spends the first preamble learning the clock: from the second subframe on *)
  Lockstep.note ls "audio" (List.tl_exn (List.concat (List.init 5 ~f:(fun k -> [ left k; right k ]))) |> Fn.flip List.take 8);
  [%expect {|
    subframes read: 387 (the last frame is still being sent when the host runs out)
    preambles B at frames 0 and 192, M and W in between: true
    audio samples as sent: true
    parity good: true; every cell starts with a transition: true; runs not 1, 2 or 3 half cells: 0
    a frame every 1041.50 cycles: 48007.7 Hz at 50 MHz
    channel status bytes 0 to 3, from the C bits: 04 00 00 02
    |}]
;;

(* ---- NEC infrared. The tests run 100 times faster than real time (see "Rates" in
   docs/post-freeze/results.md): the carrier tick is 6 + 148/256 cycles (3.8 MHz instead of
   38 kHz) and the unit 281 cycles; the recording is written at 2000 ns a cycle, so it shows the
   real 38 kHz and 562.5 us. *)
let nec_tick = 6, 148
let nec_unit = 281
let nec_scale = 100.

let%expect_test "infrared carrier configuration, proved" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and on = G.input "on" 1
  and d = G.input "d" 1 in
  prove
    ~words:(Pemu_post.Fabric_post.ir_carrier ~n_le:8)
    ~ext:G.(on @: gnd @: d)
    ~q
    ~spec:(fun ~f ~out ->
      let open G in
      [ out.(0), q.(0); f.(0), ~:(q.(0)) (* the carrier toggles every tick *)
      ; out.(1), q.(0) &: on (* the line: carrier while on *)
      ; out.(2), vdd (* hold: the word is never used up *)
      ]);
  [%expect {| proved: configuration = rule for all states and inputs |}]
;;

let nec_codes = [ 0, 0xFF00, 0x45; 0, 0x1234, 0x16; 1, 0, 0; 1, 0, 0; 0, 0xFB04, 0x08 ]

let nec_host codes =
  [ fst nec_tick; snd nec_tick; nec_unit ]
  @ List.concat_map codes ~f:(fun (kind, address, command) ->
    if kind = 1 then [ 1 ] else [ 0; address; command ])
;;

let%expect_test "nec_tx.s: frames and repeat codes, through a receiver written from the NEC format" =
  let ls =
    Lockstep.create ~fabric:(Pemu_post.Fabric_post.ir_carrier ~n_le:Model.n_le) (load "nec_tx.s")
  in
  Lockstep.record ls ~ns_per_cycle:(20. *. nec_scale) "nec_tx";
  let pending = Queue.of_list (nec_host nec_codes) in
  let demod = Ir_node.Demod.create ~hold:14 in
  let cycles = (List.length nec_codes * 192 * nec_unit) + 4000 in
  let led = Array.create ~len:cycles 0
  and out = Array.create ~len:cycles 1 in
  for c = 0 to cycles - 1 do
    let send = Queue.peek pending in
    let _, wrote = Lockstep.step ?send ls Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    led.(c) <- bit (Lockstep.uo ls) 0;
    out.(c) <- Ir_node.Demod.step demod ~cycle:c ~led:led.(c)
  done;
  let codes = Ir_node.decode out ~unit:(Float.of_int nec_unit) in
  List.iter codes ~f:(fun (code, _) -> printf "%s\n" (Ir_node.to_string code));
  (match codes with
   | (_, a) :: (_, b) :: _ ->
     printf "frames start %.1f ms apart\n" (Float.of_int (b - a) *. nec_scale /. 50e3)
   | _ -> ());
  (* the carrier: rising edges inside the first mark *)
  let rises =
    List.filter (List.init (12 * nec_unit) ~f:(fun i -> i + 100)) ~f:(fun i ->
      led.(i) = 1 && led.(i - 1) = 0)
  in
  let period =
    Float.of_int (List.last_exn rises - List.hd_exn rises) /. Float.of_int (List.length rises - 1)
  in
  let high = Array.count (Array.sub led ~pos:100 ~len:(12 * nec_unit)) ~f:(fun l -> l = 1) in
  printf "carrier %.2f kHz, %.0f%% on while sending\n"
    (50e3 /. period /. nec_scale)
    (100. *. Float.of_int high /. Float.of_int (12 * nec_unit));
  (* the stock decoder does not take extended addresses: it reads the address, not the command,
     of the second frame (scripts/sigrok_check.py) *)
  Lockstep.note ls "addresses" [ 0x00; 0x1234; 0x04 ];
  Lockstep.note ls "commands" [ 0x45; 0x08 ];
  [%expect {|
    address 00, command 45
    extended address 1234, command 16
    repeat
    repeat
    address 04, command 08
    frames start 107.9 ms apart
    carrier 38.01 kHz, 50% on while sending
    |}]
;;

let run_nec_rx line =
  let ls = Lockstep.create (load "nec_rx.s") in
  let pending = Queue.of_list [ nec_unit ] in
  let got = ref [] in
  Array.iter line ~f:(fun level ->
    let send = Queue.peek pending in
    let read, wrote = Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = level lsl 3 } in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got));
  let rec show = function
    | 1 :: lo :: hi :: rest ->
      printf "  %s\n" (Ir_node.to_string (Frame ((hi lsl 16) lor lo)));
      show rest
    | 2 :: rest ->
      printf "  repeat\n";
      show rest
    | w :: rest when w land 0xFF = 3 ->
      printf "  a frame broke off after %d bits\n" (w lsr 8);
      show rest
    | w :: rest ->
      printf "  ? %04x\n" w;
      show rest
    | [] -> ()
  in
  show (List.rev !got)
;;

let nec_frame address command = Ir_node.Frame (address lor (command lsl 16) lor ((command lxor 0xFF) lsl 24))

let%expect_test "nec_rx.s: remotes 10% slow and 20% fast, and a frame that breaks off" =
  let unit = Float.of_int nec_unit in
  let codes =
    [ nec_frame (0x00 lor (0xFF lsl 8)) 0x45; Ir_node.Repeat; nec_frame 0x1234 0x16 ]
  in
  List.iter [ 1.1; 0.8 ] ~f:(fun stretch ->
    printf "units %.0f%% of 562.5 us:\n" (100. *. stretch);
    run_nec_rx (Ir_node.line ~unit ~stretch codes));
  printf "cut after 10 bits:\n";
  run_nec_rx
    (Array.append
       (Ir_node.line ~unit ~cut:10 [ nec_frame 0x10EF 0x01 ])
       (Ir_node.line ~unit [ nec_frame 0x10EF 0x02 ]));
  [%expect {|
    units 110% of 562.5 us:
      address 00, command 45
      repeat
      extended address 1234, command 16
    units 80% of 562.5 us:
      address 00, command 45
      repeat
      extended address 1234, command 16
    cut after 10 bits:
      a frame broke off after 9 bits
      address ef, command 02
    |}]
;;

let%expect_test "nec_tx.s through a receiver model into nec_rx.s" =
  let tx =
    Lockstep.create ~fabric:(Pemu_post.Fabric_post.ir_carrier ~n_le:Model.n_le) (load "nec_tx.s")
  and rx = Lockstep.create (load "nec_rx.s") in
  let to_tx = Queue.of_list (nec_host nec_codes)
  and to_rx = Queue.of_list [ nec_unit ] in
  let demod = Ir_node.Demod.create ~hold:14 in
  let got = ref [] in
  for c = 0 to (List.length nec_codes * 192 * nec_unit) + 4000 do
    let send = Queue.peek to_tx in
    let _, wrote = Lockstep.step ?send tx Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn to_tx : int);
    let ir = Ir_node.Demod.step demod ~cycle:c ~led:(bit (Lockstep.uo tx) 0) in
    let send = Queue.peek to_rx in
    let read, wrote = Lockstep.step ?send ~receive:true rx { Model.Pads.zero with ui_in = ir lsl 3 } in
    if wrote then ignore (Queue.dequeue_exn to_rx : int);
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  printf "%s\n" (String.concat ~sep:" " (List.rev_map !got ~f:(sprintf "%x")));
  [%expect {| 1 ff00 ba45 1 1234 e916 2 2 1 fb04 f708 |}]
;;
