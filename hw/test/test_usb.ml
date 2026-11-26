(* The chip as a USB low-speed keyboard, after the RTL freeze (tag rtl-freeze-2026-11-26):
   usb_dev_rx.s on engine 0 with a new fabric configuration, usb_dev_tx.s on engine 1 with the
   designed-for USB transmit configuration, and a board processor holding the descriptors. The
   host is written from the USB 2.0 specification; the whole chip runs in lockstep with the
   chip model, every cycle. *)

open! Core
open Pemu
open Post_util

let%expect_test "USB receive configuration (NRZI, then the bit after six 1s dropped), proved" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and s = G.input "sample" 1 in
  prove
    ~words:(Pemu_post.Fabric_post.usb_rx ~n_le:8)
    ~ext:G.(gnd @: s @: gnd)
    ~q
    ~spec:(fun ~f ~out ->
      let open G in
      let d = ~:(s ^: q.(1)) (* the same level as the last sample: a 1 *) in
      [ out.(0), d
      ; f.(1), s
      ; (* c = q2 + 2 q3 + 4 q4: one more on a 1, back to 0 on a 0 *)
        f.(2), d &: ~:(q.(2))
      ; f.(3), d &: (q.(3) ^: q.(2))
      ; f.(4), d &: (q.(4) ^: (q.(3) &: q.(2)))
      ; out.(5), q.(4) &: q.(3) (* c is 6 (or 7): drop this bit *)
      ]);
  [%expect {| proved: configuration = rule for all states and inputs |}]
;;

(* the designed-for transmit configuration the USB device sends with; until now it was checked by
   simulation against a reference (test_bitengine.ml), not proved *)
let%expect_test "USB transmit configuration (a 0 after six 1s, then NRZI), proved" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and d = G.input "d" 1 in
  prove
    ~words:(Bitstream.usb_tx ~n_le:8)
    ~ext:G.(gnd @: gnd @: d)
    ~q
    ~spec:(fun ~f ~out ->
      let open G in
      let hold = q.(1) (* the last six bits sent were 1: send a 0 and keep this bit *) in
      let sent = d &: ~:hold in
      [ out.(0), hold
      ; f.(6), sent
      ; f.(5), sent &: q.(6)
      ; f.(4), sent &: q.(5)
      ; f.(3), sent &: q.(4)
      ; f.(2), sent &: q.(3)
      ; f.(1), sent &: q.(2)
      ; out.(7), mux2 sent q.(7) ~:(q.(7)) (* a 1 keeps the line, a 0 changes it *)
      ]);
  [%expect {| proved: configuration = rule for all states and inputs |}]
;;

let usb_crc_poly = 0x8005 lsl 16
let usb_crc_init = 0xFFFF lsl 16
let clock_hz = 48e6
let us n = Float.iround_up_exn (n *. clock_hz /. 1e6)

let%expect_test "a USB keyboard: enumerated by a host written from the USB 2.0 spec, then typing" =
  let module H = Chip_host in
  let module U = Usb_host in
  let h = H.create () in
  attach_chip_model h;
  H.load h 0 (load "usb_dev_rx.s");
  H.load h 1 (load "usb_dev_tx.s");
  let config e fabric =
    Array.iteri fabric ~f:(fun k w -> H.set_config h e ~word:k w);
    H.set_config h e ~word:16 usb_crc_poly;
    H.set_config h e ~word:17 usb_crc_init
  in
  config 0 (Pemu_post.Fabric_post.usb_rx ~n_le:Model.n_le);
  config 1 (Bitstream.usb_tx ~n_le:Model.n_le);
  H.own h ~pin:4 ~engine:1;
  H.own h ~pin:5 ~engine:1;
  let host = U.create ~clock_hz () in
  (* no pull-up in the recording: the host model already gives J when nobody drives *)
  let vcd = Pad_vcd.create ~ns_per_cycle:(1e9 /. clock_hz) "usb_dev" in
  h.uio_ext <- 0x20 (* J: the device's pull-up on D- *);
  h.on_cycle
  <- (fun h ->
       let pads = H.uio_pads h in
       let drive =
         U.step host ~dp:(bit pads 4) ~dm:(bit pads 5) ~chip_drives:(H.uio_oe h land 0x30 <> 0)
       in
       h.uio_ext
       <- (match drive with
           | Some (dp, dm) -> (dp lsl 4) lor (dm lsl 5)
           | None -> 0x20);
       Option.iter vcd ~f:(fun v ->
         Pad_vcd.sample v ~ui_in:(H.get h.i.ui_in) ~uo_out:(H.uo h) ~uio_in:(H.get h.i.uio_in)
           ~uio_out:(H.uio_out h) ~uio_oe:(H.uio_oe h)));
  H.run h 0b11;
  let board = Usb_board.create h in
  (* "pemu", each key pressed and let go; boot report: modifiers, 0, six key codes *)
  let key c = [ 0; 0; c; 0; 0; 0; 0; 0 ] in
  let up = [ 0; 0; 0; 0; 0; 0; 0; 0 ] in
  board.reports <- List.concat_map [ 0x13; 0x08; 0x10; 0x18 ] ~f:(fun c -> [ key c; up ]);
  let addr = 5 in
  let finished = ref false in
  let show name want (r : U.control_result) =
    match r with
    | Done got when [%equal: int list] got want ->
      U.say host "%s: %d bytes, the same as the board's" name (List.length got)
    | Done got -> U.say host "%s: WRONG: %s" name (hex_bytes got)
    | Stalled -> U.say host "%s: STALL" name
  in
  let get ?lose_ack_at ?garble_ack_at ~addr ~typ ~value ~len name want k =
    U.control_read host ~addr ?lose_ack_at ?garble_ack_at
      (U.request ~typ ~req:6 ~value ~index:(if typ = 0x81 then 0 else if value lsr 8 = 3 then 0x0409 else 0) ~len)
      (fun r ->
        show name (List.take want len) r;
        k ())
  in
  let set ~addr ?data ~typ ~req ~value ~index name k =
    U.control_write host ~addr ?data
      (U.request ~typ ~req ~value ~index ~len:(List.length (Option.value data ~default:[])))
      (fun r ->
        U.say host "%s: %s" name
          (match r with
           | Done _ -> "done"
           | Stalled -> "STALL");
        k ())
  in
  let reports = ref [] in
  let rec poll_keys ~want k =
    if List.length !reports >= List.length want
    then (
      U.say host "keyboard: %d reports, %s" (List.length !reports)
        (if [%equal: int list list] (List.rev !reports) want then "the same as the board's" else "WRONG");
      k ())
    else
      U.in_retry host ~addr ~ep:1 (fun r ->
        (match r with
         | Data (_, d) -> reports := d :: !reports
         | r -> U.error host (sprintf !"keyboard: %{sexp:U.result}" r));
        (* the next poll 10 ms later on a real bus (bInterval); much sooner here *)
        U.wait host (us 200.) (fun () -> poll_keys ~want k))
  in
  let keys_want = board.reports in
  U.seq
    [ (fun k ->
        U.say host "bus reset";
        U.bus_reset host ~cycles:(us 20.) k)
    ; get ~addr:0 ~typ:0x80 ~value:0x0100 ~len:64 "device descriptor, 64 asked" Usb_board.device_descriptor
    ; (fun k ->
        U.say host "bus reset";
        U.bus_reset host ~cycles:(us 20.) k)
    ; set ~addr:0 ~typ:0 ~req:5 ~value:addr ~index:0 (sprintf "SET_ADDRESS %d" addr)
    ; (fun k -> U.wait host (us 50.) k)
    ; (fun k ->
        (* a token for another address must get no answer at all *)
        U.in_ host ~addr:0 ~ep:0 (fun r ->
          U.say host !"IN to the old address 0: %{sexp:U.result}" r;
          U.wait host (us 20.) k))
    ; get ~addr ~typ:0x80 ~value:0x0100 ~len:18 "device descriptor" Usb_board.device_descriptor
    ; get ~addr ~typ:0x80 ~value:0x0200 ~len:9 "configuration descriptor, 9 asked" Usb_board.config_descriptor
    ; get ~addr ~typ:0x80 ~value:0x0200 ~len:34 ~lose_ack_at:1 ~garble_ack_at:3
        "configuration descriptor, all 34" Usb_board.config_descriptor
    ; get ~addr ~typ:0x80 ~value:0x0300 ~len:255 "string 0 (languages)" Usb_board.strings.(0)
    ; get ~addr ~typ:0x80 ~value:0x0302 ~len:255 "string 2 (product)" Usb_board.strings.(2)
    ; get ~addr ~typ:0x80 ~value:0x0301 ~len:255 "string 1 (manufacturer)" Usb_board.strings.(1)
    ; get ~addr ~typ:0x80 ~value:0x0600 ~len:10 "device qualifier (a full-speed-only request)" []
    ; (fun k ->
        (* a SETUP hit by noise: no ACK, the host sends it again *)
        U.control_read host ~addr ~corrupt_crc:true (U.request ~typ:0x80 ~req:0 ~value:0 ~index:0 ~len:2)
          (fun r ->
            show "GET_STATUS, first SETUP broken on the line" [ 0; 0 ] r;
            k ()))
    ; set ~addr ~typ:0 ~req:9 ~value:1 ~index:0 "SET_CONFIGURATION 1"
    ; set ~addr ~typ:0x21 ~req:0x0A ~value:0 ~index:0 "HID SET_IDLE"
    ; get ~addr ~typ:0x81 ~value:0x2200 ~len:(List.length Usb_board.report_descriptor) "report descriptor"
        Usb_board.report_descriptor
    ; set ~addr ~data:[ 0x02 ] ~typ:0x21 ~req:0x09 ~value:0x0200 ~index:0 "HID SET_REPORT (caps lock LED)"
    ; poll_keys ~want:keys_want
    ; (fun _ -> finished := true)
    ];
  let limit = 3_000_000 in
  while (not !finished) && h.cycle < limit && List.is_empty host.errors do
    Usb_board.poll board
  done;
  Queue.iter host.log ~f:print_endline;
  print_endline "the board processor saw:";
  Queue.iter board.log ~f:(printf "  %s\n");
  printf "LEDs on the board: %02x\n" board.leds;
  let tas = host.turnarounds in
  printf "device answers: %d, %.2f to %.2f bit times after the host's packet ended (2 to 6.5 allowed)\n"
    (List.length tas)
    (List.min_elt tas ~compare:Float.compare |> Option.value ~default:0.)
    (List.max_elt tas ~compare:Float.compare |> Option.value ~default:0.);
  printf "NAKs: %d, no answer: %d, cycles: %d%s\n" host.naks host.no_answers h.cycle
    (if !finished then "" else " (NOT FINISHED)");
  printf "line: worst edge %.0f ns off the bit grid\n" host.bus.worst_jitter_ns;
  List.iter (List.take (List.rev host.errors) 5) ~f:(printf "host error: %s\n");
  print_endline "line errors, from the two faults this test puts on the line on purpose:";
  List.iter (List.rev host.bus.errors) ~f:(printf "  %s\n");
  if not (List.is_empty host.errors) then Queue.iter host.trace ~f:(printf "  %s\n");
  (* for sigrok: every handshake and data packet on the line, the host's and the chip's *)
  Option.iter vcd ~f:(fun v ->
    let shown =
      List.rev host.bus.packets
      |> List.filter ~f:(fun (p : Devices.Usb_ls_receiver.packet) ->
        List.mem [ U.pid_data0; U.pid_data1; U.pid_ack; U.pid_nak; U.pid_stall ] p.pid ~equal:Int.equal)
    in
    Pad_vcd.note v "pids" (List.map shown ~f:(fun p -> p.pid));
    Pad_vcd.note v "data" (List.concat_map shown ~f:(fun p -> p.data)));
  [%expect {|
    bus reset
    device descriptor, 64 asked: 18 bytes, the same as the board's
    bus reset
    SET_ADDRESS 5: done
    IN to the old address 0: No_answer
    device descriptor: 18 bytes, the same as the board's
    configuration descriptor, 9 asked: 9 bytes, the same as the board's
      (the host lost its ACK of packet 1: DATA0, 8 bytes)
      (the host's ACK of packet 3 was broken on the line)
      (a repeat of the last packet, DATA1: acknowledged and dropped)
    configuration descriptor, all 34: 34 bytes, the same as the board's
    string 0 (languages): 4 bytes, the same as the board's
    string 2 (product): 28 bytes, the same as the board's
    string 1 (manufacturer): 10 bytes, the same as the board's
    device qualifier (a full-speed-only request): STALL
    GET_STATUS, first SETUP broken on the line: 2 bytes, the same as the board's
    SET_CONFIGURATION 1: done
    HID SET_IDLE: done
    report descriptor: 63 bytes, the same as the board's
    HID SET_REPORT (caps lock LED): done
    keyboard: 8 reports, the same as the board's
    the board processor saw:
      bus reset
      SETUP 80 06 00 01 00 00 40 00
      bus reset
      SETUP 00 05 05 00 00 00 00 00
      address 5
      SETUP 80 06 00 01 00 00 12 00
      SETUP 80 06 00 02 00 00 09 00
      SETUP 80 06 00 02 00 00 22 00
      SETUP 80 06 00 03 09 04 ff 00
      SETUP 80 06 02 03 09 04 ff 00
      SETUP 80 06 01 03 09 04 ff 00
      SETUP 80 06 00 06 00 00 0a 00
      SETUP 80 00 00 00 00 00 02 00
      SETUP 00 09 01 00 00 00 00 00
      SETUP 21 0a 00 00 00 00 00 00
      SETUP 81 06 00 22 00 00 3f 00
      SETUP 21 09 00 02 00 00 01 00
      LEDs 02
    LEDs on the board: 02
    device answers: 106, 3.50 to 3.69 bit times after the host's packet ended (2 to 6.5 allowed)
    NAKs: 38, no answer: 1, cycles: 613059
    line: worst edge 0 ns off the bit grid
    line errors, from the two faults this test puts on the line on purpose:
      3224042 ns: bad PID d3
      5847208 ns: CRC-16 wrong
    |}]
;;
