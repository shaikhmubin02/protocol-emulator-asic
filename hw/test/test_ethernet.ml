(* 10BASE-T: eth_tx.s and eth_rx.s on the golden model, against 802.3 device models. *)

open! Core
open Pemu
open Devices

let firmware name = In_channel.read_all ("../firmware/" ^ name)

let assemble name src =
  match Asm.assemble src with
  | Ok words -> words
  | Error e -> failwithf "%s: %s" name e ()
;;

let bit v k = (v lsr k) land 1

(* eth_tx.s with a frame in it, and its fabric and CRC configuration *)
let tx_model data =
  let m = Model.create (assemble "eth_tx.s" (firmware "eth_tx.s" ^ eth_frame_code data)) in
  Model.set_fabric m (Bitstream.eth_tx ~n_le:Model.n_le);
  Model.set_crc m ~poly:Bitstream.eth_poly ~init:Bitstream.eth_tx_crc_init;
  m
;;

let rx_model () =
  let m = Model.create (assemble "eth_rx.s" (firmware "eth_rx.s")) in
  Model.set_fabric m (Bitstream.eth_rx ~n_le:Model.n_le);
  Model.set_crc m ~poly:Bitstream.eth_poly ~init:0xFFFF_FFFF;
  m
;;

(* A minimum-size frame (60 bytes before the FCS): broadcast, an ARP request. *)
let arp =
  [ 0xFF; 0xFF; 0xFF; 0xFF; 0xFF; 0xFF; 0x02; 0x00; 0x00; 0x12; 0x34; 0x56; 0x08; 0x06 ]
  @ [ 0x00; 0x01; 0x08; 0x00; 0x06; 0x04; 0x00; 0x01 ]
  @ [ 0x02; 0x00; 0x00; 0x12; 0x34; 0x56; 192; 168; 1; 50 ]
  @ [ 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 192; 168; 1; 1 ]
  @ List.init 18 ~f:(fun _ -> 0)
;;

let%expect_test "CRC constants" =
  let res =
    List.fold (Bitstream.lsb_first_bits (with_fcs arp)) ~init:0xFFFF_FFFF ~f:Bitstream.crc32_step
  in
  let after_preamble =
    List.fold
      (Bitstream.lsb_first_bits Bitstream.eth_preamble)
      ~init:Bitstream.eth_tx_crc_init
      ~f:Bitstream.crc32_step
  in
  printf "TX init 0x%08X (0x%08X after the preamble), residue after a good FCS 0x%08X\n"
    Bitstream.eth_tx_crc_init after_preamble res;
  [%expect {| TX init 0x13256D64 (0xFFFFFFFF after the preamble), residue after a good FCS 0xC704DD7B |}]
;;


let random_bytes ~seed n =
  let rng = Random.State.make [| seed |] in
  List.init n ~f:(fun _ -> Random.State.int rng 256)
;;

(* Runs eth_tx.s with [data] as its frame; the host asks for a frame at each cycle in [at]. *)
let run_tx ?(cycles = 20_000) ~at data =
  let m = tx_model data in
  let rx = Ten_base_t_receiver.create ~ns_per_cycle:20. in
  let host = Host.create [] in
  for cycle = 1 to cycles do
    if List.mem at cycle ~equal:Int.equal then Queue.enqueue host.Host.pending 1;
    Model.step m Model.Pads.zero;
    Ten_base_t_receiver.step rx (bit (Model.uo_out m) 0);
    Host.service host m
  done;
  if not (List.is_empty rx.errors) then raise_s [%message (rx.errors : string list)];
  rx
;;

(* TP_IDL starts at the last rising edge, which depends on the last bit *)
let fcs_ends_in_0 =
  List.init 50 ~f:(fun k -> random_bytes ~seed:(200 + k) 60)
  |> List.find_exn ~f:(fun d -> crc32_eth d lsr 31 = 0)
;;

let%expect_test "eth_tx.s: frames checked by a receiver written from 802.3" =
  List.iter
    [ "ARP request", arp; "61 bytes", random_bytes ~seed:1 61; "64 bytes", random_bytes ~seed:2 64
    ; "126 bytes", random_bytes ~seed:3 126; "FCS ends 0", fcs_ends_in_0 ]
    ~f:(fun (name, data) ->
      let words = Array.length (assemble "eth_tx.s" (firmware "eth_tx.s" ^ eth_frame_code data)) in
      let rx = run_tx ~at:[ 1000; 10_000 ] data in
      let frames = List.rev rx.frames in
      let ok =
        List.length frames = 2
        && List.for_all frames ~f:(fun f -> f.fcs_ok && [%equal: int list] f.data data)
      in
      if not ok then raise_s [%message name "frames wrong"];
      let tp = List.map frames ~f:(fun f -> f.tp_idl_ns) in
      printf "%-11s %3d program words: 2 frames ok, crossings <= %.0f ns off, TP_IDL %s ns\n"
        name words rx.worst_grid_ns
        (String.concat ~sep:"/" (List.map tp ~f:(sprintf "%.0f"))));
  [%expect {|
    ARP request 141 program words: 2 frames ok, crossings <= 10 ns off, TP_IDL 340/340 ns
    61 bytes    145 program words: 2 frames ok, crossings <= 10 ns off, TP_IDL 340/340 ns
    64 bytes    147 program words: 2 frames ok, crossings <= 10 ns off, TP_IDL 340/340 ns
    126 bytes   240 program words: 2 frames ok, crossings <= 10 ns off, TP_IDL 340/340 ns
    FCS ends 0  141 program words: 2 frames ok, crossings <= 10 ns off, TP_IDL 280/280 ns
    |}]
;;

(* 802.3: a link pulse every 16 +- 8 ms, also 16 +- 8 ms after the start of TP_IDL *)
let%expect_test "eth_tx.s: link pulses" =
  let rx = run_tx ~cycles:2_600_000 ~at:[ 1_700_000 ] arp in
  let pulses = List.rev rx.link_pulses in
  let frame = List.hd_exn rx.frames in
  let events =
    List.map pulses ~f:(fun (at, _) -> at, "pulse") @ [ frame.ended, "frame" ]
    |> List.sort ~compare:(fun (a, _) (b, _) -> Float.compare a b)
  in
  List.iter2_exn (List.drop_last_exn events) (List.tl_exn events) ~f:(fun (a, _) (b, what) ->
    let ms = (b -. a) /. 1e6 in
    if String.equal what "pulse" && Float.(ms < 8. || ms > 24.)
    then raise_s [%message "link pulse spacing" (ms : float)];
    printf "%-5s after %6.2f ms\n" what ms);
  List.iter pulses ~f:(fun (_, w) -> printf "pulse %.0f ns wide\n" w);
  [%expect {|
    pulse after  15.73 ms
    frame after   2.60 ms
    pulse after  15.73 ms
    pulse 100 ns wide
    pulse 100 ns wide
    pulse 100 ns wide
    |}]
;;

(* ---------------- RX ---------------- *)

(* Feeds [frames] (FCS included) to eth_rx.s; returns the frames read off the nibble bus and
   the status words from the mailbox. *)
let run_rx ?(bit_ns = 100.) ?(jitter_ns = 0.) ?(phase_ns = 0.) ?(seed = 0) frames =
  let m = rx_model () in
  let far =
    Ten_base_t_transmitter.create ~ns_per_cycle:20. ~bit_ns ~jitter_ns ~phase_ns ~seed frames
  in
  let bus = Nibble_bus.create () in
  let host = Host.create [] in
  let overrun = ref false in
  let tail = ref 0 in
  while !tail < 2000 do
    let level = Ten_base_t_transmitter.step far in
    Model.step m { Model.Pads.zero with ui_in = level lsl 3 };
    if m.be.overrun then overrun := true;
    Nibble_bus.step bus (Model.uo_out m);
    Host.service host m;
    if Ten_base_t_transmitter.finished far then incr tail
  done;
  List.rev bus.frames, Host.received host, !overrun, bus.errors
;;

let rx_ok frames (got, status, overrun, errors) =
  (not overrun)
  && List.is_empty errors
  && [%equal: int list list] got frames
  && [%equal: int list]
       status
       (List.map frames ~f:(fun f ->
          List.length f lor if [%equal: int list] (with_fcs (List.take f (List.length f - 4))) f then 0x8000 else 0))
;;

let%expect_test "eth_rx.s: frames out on the nibble bus, FCS checked" =
  let bad = with_fcs (random_bytes ~seed:5 70) |> List.mapi ~f:(fun i b -> if i = 20 then b lxor 4 else b) in
  let frames =
    [ with_fcs arp; with_fcs (random_bytes ~seed:4 61); bad; with_fcs (random_bytes ~seed:6 1500) ]
  in
  List.iter
    [ "nominal", 100.; "100 ppm slow", 100.01; "100 ppm fast", 99.99 ]
    ~f:(fun (name, bit_ns) ->
      List.iter [ 0.; 7.; 13. ] ~f:(fun phase_ns ->
        let r = run_rx ~bit_ns ~phase_ns frames in
        let got, status, _, _ = r in
        if not (rx_ok frames r)
        then
          raise_s
            [%message name (phase_ns : float) (status : int list) ~lengths:(List.map got ~f:List.length : int list)]);
      printf "%-12s %d frames (60, 61, 70 with a bad bit, 1500 bytes), all bytes right, FCS flags right\n"
        name (List.length frames));
  [%expect {|
    nominal      4 frames (60, 61, 70 with a bad bit, 1500 bytes), all bytes right, FCS flags right
    100 ppm slow 4 frames (60, 61, 70 with a bad bit, 1500 bytes), all bytes right, FCS flags right
    100 ppm fast 4 frames (60, 61, 70 with a bad bit, 1500 bytes), all bytes right, FCS flags right
    |}]
;;

(* 802.3 wants a receiver to take +-13.5 ns on every zero crossing. Our decoder samples at
   50 MHz, so the answer is a measurement, not a guarantee. *)
let%expect_test "eth_rx.s: jitter tolerance" =
  let n = 30 in
  List.iter [ 0.; 2.; 4.; 6.; 8.; 10.; 12.; 13.5; 16. ] ~f:(fun jitter_ns ->
    let good = ref 0 in
    for k = 1 to n do
      let frames = [ with_fcs (random_bytes ~seed:(100 + k) 60) ] in
      let phase_ns = Float.of_int (k * 7 mod 20) in
      if rx_ok frames (run_rx ~jitter_ns ~phase_ns ~seed:k ~bit_ns:(if k % 2 = 0 then 100.01 else 99.99) frames)
      then incr good
    done;
    printf "+-%4.1f ns: %2d/%d frames right\n" jitter_ns !good n);
  [%expect {|
    +- 0.0 ns: 30/30 frames right
    +- 2.0 ns: 30/30 frames right
    +- 4.0 ns: 30/30 frames right
    +- 6.0 ns: 28/30 frames right
    +- 8.0 ns: 17/30 frames right
    +-10.0 ns: 11/30 frames right
    +-12.0 ns:  4/30 frames right
    +-13.5 ns:  0/30 frames right
    +-16.0 ns:  0/30 frames right
    |}]
;;

let%expect_test "eth_tx.s into eth_rx.s" =
  let frames = [ arp; random_bytes ~seed:9 61 ] in
  List.iter frames ~f:(fun data ->
    let tx = tx_model data
    and rx = rx_model () in
    let bus = Nibble_bus.create () in
    let tx_host = Host.create []
    and rx_host = Host.create [] in
    for cycle = 1 to 12_000 do
      if cycle = 100 || cycle = 5000 then Queue.enqueue tx_host.Host.pending 1;
      Model.step tx Model.Pads.zero;
      Model.step rx { Model.Pads.zero with ui_in = bit (Model.uo_out tx) 0 lsl 3 };
      Nibble_bus.step bus (Model.uo_out rx);
      Host.service tx_host tx;
      Host.service rx_host rx
    done;
    let want = with_fcs data in
    let ok =
      [%equal: int list list] (List.rev bus.frames) [ want; want ]
      && [%equal: int list] (Host.received rx_host) (List.init 2 ~f:(fun _ -> List.length want lor 0x8000))
    in
    if not ok then raise_s [%message "tx into rx" (Host.received rx_host : int list)];
    printf "%d-byte frame twice from one engine to another: bytes and FCS right\n" (List.length data));
  [%expect {|
    60-byte frame twice from one engine to another: bytes and FCS right
    61-byte frame twice from one engine to another: bytes and FCS right
    |}]
;;
