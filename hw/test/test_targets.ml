(* Target (peripheral) firmware: the chip as the device, driven by controller models. *)

open! Core
open Pemu
open Devices

let load name =
  match Asm.assemble (In_channel.read_all ("../firmware/" ^ name)) with
  | Ok words -> words
  | Error e -> failwithf "%s: %s" name e ()
;;

let bit v k = (v lsr k) land 1

(* ---------------- SPI ---------------- *)

(* The controller sends [sent] (one byte list per transaction); the host gives the target
   [replies] to send back. Returns what the controller read and the host's words. *)
let worst_release = ref 0

let run_spi_target ?lead_ns ~mode ~half_ns ~sent ~replies () =
  let m = Model.create (load "spi_target.s") in
  let ctrl = Spi_controller.create ?lead_ns ~mode ~half_ns ~ns_per_cycle:20. sent in
  let host = Host.create ((0x8000 lor mode) :: replies) in
  let miso = ref None
  and tail = ref 0
  and cs_up = ref 0 in
  while !tail < 500 do
    let sck, mosi, cs = Spi_controller.step ctrl ~miso:!miso in
    Model.step m { Model.Pads.zero with ui_in = (sck lsl 5) lor (mosi lsl 6) lor (cs lsl 7) };
    miso := if bit (Model.uio_oe m) 0 = 1 then Some (bit (Model.uio_out m) 0) else None;
    (* how long MISO stays driven after CS goes high *)
    if cs = 0 then cs_up := 0 else incr cs_up;
    if cs = 1 && Option.is_some !miso then worst_release := Int.max !worst_release !cs_up;
    Host.service host m;
    if Spi_controller.finished ctrl then incr tail
  done;
  List.rev ctrl.received, Host.received host, ctrl.errors
;;

let spi_sent = [ [ 0x9F; 0x00; 0x00; 0x00 ]; [ 0x03; 0xA5; 0x5A ]; [ 0x01 ] ]

(* the host has 6 bytes for the target, so the last transaction gets 0xFF *)
let spi_replies = [ 0xEF; 0x40; 0x18; 0x00; 0x81; 0x7E ]
let spi_expected_back = [ [ 0xEF; 0x40; 0x18; 0x00 ]; [ 0x81; 0x7E; 0xFF ]; [ 0xFF ] ]

let spi_expected_host =
  List.concat_map spi_sent ~f:(fun bytes -> bytes @ [ 0x100 ])
;;

let spi_ok (back, host, errors) =
  List.is_empty errors
  && [%equal: int list list] back spi_expected_back
  && [%equal: int list] host spi_expected_host
;;

let%expect_test "spi_target.s: all four modes at 1 MHz" =
  for mode = 0 to 3 do
    let r = run_spi_target ~mode ~half_ns:500. ~sent:spi_sent ~replies:spi_replies () in
    if not (spi_ok r)
    then (
      let back, host, errors = r in
      raise_s [%message (mode : int) (back : int list list) (host : int list) (errors : string list)]);
    printf "mode %d: 3 transactions, both directions right\n" mode
  done;
  printf "MISO let go at most %d ns after CS goes high
" (20 * !worst_release);
  [%expect {|
    mode 0: 3 transactions, both directions right
    mode 1: 3 transactions, both directions right
    mode 2: 3 transactions, both directions right
    mode 3: 3 transactions, both directions right
    MISO let go at most 260 ns after CS goes high
    |}]
;;

(* How fast can SCK go? Bytes back to back, so the work between bytes counts too. CS goes low
   1 us before the first edge here; the next test finds how little the target needs. *)
let%expect_test "spi_target.s: fastest SCK" =
  for mode = 0 to 3 do
    let fastest =
      List.find [ 100.; 120.; 140.; 160.; 180.; 200.; 250.; 300.; 400.; 500. ] ~f:(fun half_ns ->
        spi_ok (run_spi_target ~lead_ns:1000. ~mode ~half_ns ~sent:spi_sent ~replies:spi_replies ()))
    in
    match fastest with
    | Some h -> printf "mode %d: works down to %.0f ns half periods (%.2f MHz)
" mode h (1e3 /. (2. *. h))
    | None -> printf "mode %d: fails even at 1 MHz
" mode
  done;
  [%expect {|
    mode 0: works down to 300 ns half periods (1.67 MHz)
    mode 1: works down to 300 ns half periods (1.67 MHz)
    mode 2: works down to 300 ns half periods (1.67 MHz)
    mode 3: works down to 300 ns half periods (1.67 MHz)
    |}]
;;

let%expect_test "spi_target.s: CS low before the first SCK edge" =
  for mode = 0 to 3 do
    let least =
      List.find (List.init 40 ~f:(fun k -> 20. *. Float.of_int (k + 1))) ~f:(fun lead_ns ->
        spi_ok (run_spi_target ~lead_ns ~mode ~half_ns:500. ~sent:spi_sent ~replies:spi_replies ()))
    in
    printf "mode %d: needs CS low %s before the first edge
" mode
      (Option.value_map least ~default:"more than 800 ns" ~f:(sprintf "%.0f ns"))
  done;
  [%expect {|
    mode 0: needs CS low 400 ns before the first edge
    mode 1: needs CS low 20 ns before the first edge
    mode 2: needs CS low 400 ns before the first edge
    mode 3: needs CS low 20 ns before the first edge
    |}]
;;

(* ---------------- I2C ---------------- *)

(* i2c_master.s on one engine and i2c_target.s on another, on one open-drain bus. [late] holds
   back the target host's read bytes until that cycle, so the target has to stretch the clock. *)
let run_i2c ~q ~late =
  let master = Model.create (load "i2c_master.s")
  and target = Model.create (load "i2c_target.s") in
  let mhost =
    Host.create
      [ 0x600 lor q
      ; 0x100; 0x2A0; 0x210; 0x255 (* write 0x10 0x55 to 0x50 *)
      ; 0x100; 0x2A1; 0x300; 0x400 (* repeated START, read two bytes *)
      ; 0x500
      ; 0x100; 0x2A2; 0x500 (* address 0x51: nobody answers *)
      ]
  and thost = Host.create [ 0x50 ] in
  let timing = I2c_timing.create () in
  let line m k = if bit (Model.uio_oe m) k = 1 then bit (Model.uio_out m) k else 1 in
  let scl = ref 1
  and sda = ref 1 in
  for cycle = 1 to 60 * 5 * q * 2 do
    if cycle = late then List.iter [ 0xC3; 0x5A ] ~f:(Queue.enqueue thost.Host.pending);
    let pads = { Model.Pads.zero with uio_in = !scl lor (!sda lsl 1) } in
    Model.step master pads;
    Model.step target pads;
    scl := line master 0 land line target 0;
    sda := line master 1 land line target 1;
    I2c_timing.step timing ~scl:!scl ~sda:!sda;
    Host.service mhost master;
    Host.service thost target
  done;
  Host.received mhost, Host.received thost, timing
;;

let%expect_test "i2c_target.s against i2c_master.s, at 100 and 400 kHz" =
  List.iter [ "standard", 100, false; "fast", 25, true ] ~f:(fun (name, q, fast) ->
    List.iter [ "host keeps up", 1; "host late", 300 * q ] ~f:(fun (how, late) ->
      let m, t, timing = run_i2c ~q ~late in
      let khz = I2c_timing.check timing ~fast ~ns_per_cycle:20 in
      let want_m = [ 0; 0; 0; 0; 0xC3; 0x5A; 1 ]
      and want_t = [ 0x1A0; 0x210; 0x255; 0x1A1; 0x300 ] in
      if not ([%equal: int list] m want_m && [%equal: int list] t want_t)
      then raise_s [%message name how (m : int list) (t : int list)];
      printf "%-8s %-13s SCL %3d kHz, longest SCL low %5d ns, spec timing met\n" name how khz
        (timing.longest_low * 20)));
  [%expect {|
    standard host keeps up SCL  98 kHz, longest SCL low  6200 ns, spec timing met
    standard host late     SCL  98 kHz, longest SCL low 198180 ns, spec timing met
    fast     host keeps up SCL 381 kHz, longest SCL low  1700 ns, spec timing met
    fast     host late     SCL 381 kHz, longest SCL low 45180 ns, spec timing met
    |}]
;;
