(* More protocols written after the RTL freeze (tag rtl-freeze-2026-11-26), as in test_post.ml:
   firmware and fabric configurations only, each on the engine RTL in lockstep with the model,
   against a model of the other end written from the protocol's specification. *)

open! Core
open Pemu
open Post_util

(* ---- Philips RC-5. Run 100 times faster than real time (see "Rates" in
   docs/post-freeze/results.md): the carrier tick is 6 + 242/256 cycles and a quarter bit 222
   cycles; recordings are written at 2000 ns a cycle, so they show the real timing. *)
let rc5_tick = 6, 242
let rc5_quarter = 222
let rc5_scale = 100.

let rc5_keys =
  (* command | address << 7, | 0x8000 when it repeats the last key *)
  [ 0x35 lor (5 lsl 7); 0x8000 lor 0x35 lor (5 lsl 7); 0x8000 lor 0x35 lor (5 lsl 7); 0x4C lor (0 lsl 7)
  ; 0x0C lor (20 lsl 7)
  ]
;;

let rc5_host keys = [ fst rc5_tick; snd rc5_tick; rc5_quarter ] @ keys

let%expect_test "rc5_tx.s: new keys and held keys, through a receiver written from the RC-5 format" =
  let ls =
    Lockstep.create ~fabric:(Pemu_post.Fabric_post.ir_carrier ~n_le:Model.n_le) (load "rc5_tx.s")
  in
  let pending = Queue.of_list (rc5_host rc5_keys) in
  let demod = Ir_node.Demod.create ~hold:16 in
  let cycles = (List.length rc5_keys * 256 * rc5_quarter) + 2000 in
  let led = Array.create ~len:cycles 0
  and out = Array.create ~len:cycles 1 in
  let ignore_words = ref [] in
  for c = 0 to cycles - 1 do
    step ls pending ignore_words Model.Pads.zero;
    led.(c) <- bit (Lockstep.uo ls) 0;
    out.(c) <- Ir_node.Demod.step demod ~cycle:c ~led:led.(c)
  done;
  let frames = Ir_node.rc5_decode out ~quarter:(Float.of_int rc5_quarter) in
  List.iter frames ~f:(fun b -> printf "%s\n" (Ir_node.rc5_to_string b));
  let rises =
    List.filter (List.init (cycles - 1) ~f:(fun i -> i + 1)) ~f:(fun i -> led.(i) = 1 && led.(i - 1) = 0)
  in
  let first = List.hd_exn rises in
  let in_burst = List.filter rises ~f:(fun i -> i - first < 2 * rc5_quarter) in
  let period =
    Float.of_int (List.last_exn in_burst - first) /. Float.of_int (List.length in_burst - 1)
  in
  printf "carrier %.2f kHz\n" (50e3 /. period /. rc5_scale);
  [%expect {|
    address 5, command 53, T 1
    address 5, command 53, T 1
    address 5, command 53, T 1
    address 0, command 76, T 0
    address 20, command 12, T 1
    carrier 36.05 kHz
    |}]
;;

let run_rc5_rx ?(record = false) line =
  let ls = Lockstep.create (load "rc5_rx.s") in
  if record then Lockstep.record ls ~ns_per_cycle:(20. *. rc5_scale) "rc5";
  let pending = Queue.of_list [ rc5_quarter ] in
  let got = ref [] in
  Array.iter line ~f:(fun level -> step ls pending got { Model.Pads.zero with ui_in = level lsl 3 });
  List.iter (List.rev !got) ~f:(fun w ->
    if w land 0x8000 <> 0
    then
      printf "  address %d, command %d, T %d\n" ((w lsr 7) land 0x1F) (w land 0x7F) ((w lsr 12) land 1)
    else if w land 0x4000 <> 0
    then printf "  a frame broke off after %d bits\n" (w land 0xFF + 1)
    else printf "  ? %04x\n" w);
  ls
;;

let%expect_test "rc5_rx.s: remotes 10% slow and 10% fast, an RC-5X command, and a frame that breaks off" =
  let quarter = Float.of_int rc5_quarter in
  let frames =
    [ Ir_node.rc5_bits ~address:5 ~command:0x35 ~toggle:1
    ; Ir_node.rc5_bits ~address:5 ~command:0x35 ~toggle:1
    ; Ir_node.rc5_bits ~address:0 ~command:0x4C ~toggle:0
    ]
  in
  printf "bits 110%% of 1.778 ms:\n";
  let ls = run_rc5_rx ~record:true (Ir_node.rc5_line ~quarter ~stretch:1.1 frames) in
  Lockstep.note ls "frames" [ 5; 0x35; 5; 0x35; 0; 0x4C ];
  printf "bits 90%%:\n";
  ignore (run_rc5_rx (Ir_node.rc5_line ~quarter ~stretch:0.9 frames) : Lockstep.t);
  printf "the last frame cut after 8 bits:\n";
  ignore (run_rc5_rx (Ir_node.rc5_line ~quarter ~cut:8 frames) : Lockstep.t);
  [%expect {|
    bits 110% of 1.778 ms:
      address 5, command 53, T 1
      address 5, command 53, T 1
      address 0, command 76, T 0
    bits 90%:
      address 5, command 53, T 1
      address 5, command 53, T 1
      address 0, command 76, T 0
    the last frame cut after 8 bits:
      address 5, command 53, T 1
      address 5, command 53, T 1
      a frame broke off after 8 bits
    |}]
;;

let%expect_test "rc5_tx.s through a receiver model into rc5_rx.s" =
  let tx =
    Lockstep.create ~fabric:(Pemu_post.Fabric_post.ir_carrier ~n_le:Model.n_le) (load "rc5_tx.s")
  and rx = Lockstep.create (load "rc5_rx.s") in
  let to_tx = Queue.of_list (rc5_host rc5_keys)
  and to_rx = Queue.of_list [ rc5_quarter ] in
  let demod = Ir_node.Demod.create ~hold:16 in
  let from_tx = ref []
  and got = ref [] in
  for c = 0 to (List.length rc5_keys * 256 * rc5_quarter) + 2000 do
    step tx to_tx from_tx Model.Pads.zero;
    let ir = Ir_node.Demod.step demod ~cycle:c ~led:(bit (Lockstep.uo tx) 0) in
    step rx to_rx got { Model.Pads.zero with ui_in = ir lsl 3 }
  done;
  printf "%s\n" (String.concat ~sep:" " (List.rev_map !got ~f:(sprintf "%04x")));
  [%expect {| 92b5 92b5 92b5 804c 9a0c |}]
;;

(* ---- PS/2, at the real rate: a 12.5 kHz clock, a quarter period of 1000 cycles. The other ends
   are Ps2_node: a computer and a keyboard. Both lines are open drain: low if either side pulls. *)
let ps2_q = 1000
let ps2_line ls k = if bit (Lockstep.uio_oe ls) k = 1 then bit (Lockstep.uio_out ls) k else 1

let%expect_test "ps2_dev.s: a keyboard, against a computer written from the PS/2 description" =
  let ls = Lockstep.create (load "ps2_dev.s") in
  let pc =
    Ps2_node.Host.create
      [ Inhibit (60_000, 70_000) (* in the middle of the second scan code *)
      ; Send (350_000, 0xFF)
      ; Send (500_000, 0xF2)
      ; Send (700_000, 0xED)
      ; Send (800_000, 0x02)
      ; Send (900_000, 0xEE)
      ]
  in
  let to_dev = Queue.of_list [ ps2_q; 0x1C; 0xF0; 0x1C; 0x32; 0xF0; 0x32 ] in
  let words = ref [] in
  for c = 0 to 1_000_000 do
    let clk = pc.clk land ps2_line ls 0
    and data = pc.data land ps2_line ls 1 in
    Ps2_node.Host.step pc ~cycle:c ~clk ~data;
    step ls to_dev words { Model.Pads.zero with uio_in = clk lor (data lsl 1) }
  done;
  printf "the computer read: %s\n"
    (String.concat ~sep:" "
       (List.rev_map pc.received ~f:(fun (b, ok) -> sprintf "%02x%s" b (if ok then "" else "!"))));
  printf "its commands acknowledged: %s\n"
    (String.concat ~sep:" " (List.rev_map pc.acks ~f:Bool.to_string));
  printf "the keyboard's host was told: %s\n" (String.concat ~sep:" " (List.rev_map !words ~f:(sprintf "%03x")));
  let falls = List.rev pc.falls in
  let gaps =
    List.map (List.zip_exn (List.drop_last_exn falls) (List.tl_exn falls)) ~f:(fun (a, b) -> b - a)
    |> List.sort ~compare:Int.compare
  in
  (* the median time from one falling edge to the next: a bit inside a byte *)
  printf "clock %.2f kHz\n" (50e3 /. Float.of_int (List.nth_exn gaps (List.length gaps / 2)));
  [%expect {|
    the computer read: 1c f0 1c 32 f0 32 fa aa fa ab 83 fa fa ee
    its commands acknowledged: true true true true true
    the keyboard's host was told: 1ff 1f2 1ed 102 1ee
    clock 12.50 kHz
    |}]
;;

(* sigrok's ps2 decoder takes every falling edge of CLK as a bit, so it cannot follow host-to-
   device bytes; and it ends each frame only at the next falling edge, so in a burst it takes the
   next byte's start bit as the end of this one. This recording has the keyboard's bytes only,
   and the computer holds CLK low for 20 us after each byte, as hosts may: that is the edge that
   ends each frame for the decoder. *)
let%expect_test "ps2_dev.s: a typed word, recorded for an outside decoder" =
  let ls = Lockstep.create (load "ps2_dev.s") in
  Lockstep.record ls ~ns_per_cycle:20. "ps2_dev";
  let pc = Ps2_node.Host.create ~hold_after:1000 [] in
  let codes = [ 0x33; 0xF0; 0x33; 0x43; 0xF0; 0x43 ] (* H and I, pressed and released *) in
  let to_dev = Queue.of_list (ps2_q :: codes) in
  let words = ref [] in
  for c = 0 to 300_000 do
    let clk = pc.clk land ps2_line ls 0
    and data = pc.data land ps2_line ls 1 in
    Ps2_node.Host.step pc ~cycle:c ~clk ~data;
    step ls to_dev words { Model.Pads.zero with uio_in = clk lor (data lsl 1) }
  done;
  printf "the computer read: %s\n"
    (String.concat ~sep:" "
       (List.rev_map pc.received ~f:(fun (b, ok) -> sprintf "%02x%s" b (if ok then "" else "!"))));
  Lockstep.note ls "bytes" codes;
  [%expect {| the computer read: 33 f0 33 43 f0 43 |}]
;;

let%expect_test "ps2_host.s: reading a keyboard and sending it commands" =
  let ls = Lockstep.create (load "ps2_host.s") in
  let kb = Ps2_node.Keyboard.create ~q:ps2_q ~sends:[ 0x1C; 0xF0; 0x1C ] in
  (* commands go to the program one at a time, each after the last exchange is over *)
  let commands = [ 200_000, 0xFF; 400_000, 0xED; 500_000, 0x02; 600_000, 0xEE ] in
  let to_host = Queue.create () in
  let words = ref [] in
  for c = 0 to 750_000 do
    List.iter commands ~f:(fun (at, b) -> if c = at then Queue.enqueue to_host b);
    let clk = kb.clk land ps2_line ls 0
    and data = kb.data land ps2_line ls 1 in
    Ps2_node.Keyboard.step kb ~cycle:c ~clk ~data;
    step ls to_host words { Model.Pads.zero with uio_in = clk lor (data lsl 1) }
  done;
  printf "the program read: %s\n" (String.concat ~sep:" " (List.rev_map !words ~f:(sprintf "%03x")));
  printf "the keyboard got: %s\n"
    (String.concat ~sep:" "
       (List.rev_map kb.commands ~f:(fun (b, ok) -> sprintf "%02x%s" b (if ok then "" else "!"))));
  [%expect {|
    the program read: 11c 1f0 11c 200 1fa 1aa 200 1fa 200 1fa 200 1ee
    the keyboard got: ff ed 02 ee
    |}]
;;

let%expect_test "ps2_host.s on one engine and ps2_dev.s on another" =
  let host = Lockstep.create (load "ps2_host.s")
  and dev = Lockstep.create (load "ps2_dev.s") in
  let to_host = Queue.create ()
  and to_dev = Queue.of_list [ ps2_q; 0x1C; 0xF0; 0x1C ] in
  let from_host = ref []
  and from_dev = ref [] in
  for c = 0 to 600_000 do
    if c = 200_000 then Queue.enqueue to_host 0xFF;
    if c = 350_000 then Queue.enqueue to_host 0xF2;
    let clk = ps2_line host 0 land ps2_line dev 0
    and data = ps2_line host 1 land ps2_line dev 1 in
    let pads = { Model.Pads.zero with uio_in = clk lor (data lsl 1) } in
    step host to_host from_host pads;
    step dev to_dev from_dev pads
  done;
  printf "host side: %s\n" (String.concat ~sep:" " (List.rev_map !from_host ~f:(sprintf "%03x")));
  printf "device side: %s\n" (String.concat ~sep:" " (List.rev_map !from_dev ~f:(sprintf "%03x")));
  [%expect {|
    host side: 11c 1f0 11c 200 1fa 1aa 200 1fa 1ab 183
    device side: 1ff 1f2
    |}]
;;

(* ---- Modbus RTU at 115200 bit/s, at the real rate. The other end is Modbus_node: a client from
   the specifications, and the host's register map. RS-485 half duplex: the bus is the chip's TX
   while its driver is on, else the client's; the transceiver's receiver is off while it sends. *)
let mb_rate = 434, 7
let mb_bit = bit_of mb_rate
let mb_char = 11. *. mb_bit

let mb_requests =
  let open Modbus_node in
  let bad = List.mapi (with_crc [ 0x01; 0x03; 0x00; 0x00; 0x00; 0x02 ]) ~f:(fun i x -> if i = 6 then x lxor 1 else x) in
  [ "read registers 0 and 1", with_crc [ 0x01; 0x03; 0x00; 0x00; 0x00; 0x02 ]
  ; "write register 1", with_crc [ 0x01; 0x06; 0x00; 0x01; 0x12; 0x34 ]
  ; "write registers 2 and 3", with_crc [ 0x01; 0x10; 0x00; 0x02; 0x00; 0x02; 0x04; 0xAB; 0xCD; 0xEF; 0x01 ]
  ; "read registers 0 to 3", with_crc [ 0x01; 0x03; 0x00; 0x00; 0x00; 0x04 ]
  ; "a request for server 2", with_crc [ 0x02; 0x03; 0x00; 0x00; 0x00; 0x01 ]
  ; "a request with its CRC wrong", bad
  ; "broadcast: write register 5", with_crc [ 0x00; 0x06; 0x00; 0x05; 0x00; 0x07 ]
  ; "function 0x2b (not served)", with_crc [ 0x01; 0x2B; 0x0E; 0x01; 0x00 ]
  ]
;;

let%expect_test "modbus.s: a server, against a client written from the Modbus specifications" =
  let ls = Lockstep.create (load "modbus.s") in
  Lockstep.record ls ~ns_per_cycle:20. "modbus";
  let regs = Modbus_node.Registers.create () in
  let slot = 150_000 in
  let starts = List.mapi mb_requests ~f:(fun i _ -> 2000 + (i * slot)) in
  let cycles = 2000 + (List.length mb_requests * slot) in
  let client = Modbus_node.client_line ~bit:mb_bit (List.zip_exn starts (List.map mb_requests ~f:snd)) ~cycles in
  let to_chip = Queue.of_list [ fst mb_rate; snd mb_rate; 1 ] in
  let bus = Array.create ~len:cycles 1
  and de = Array.create ~len:cycles 0 in
  let pdu = ref [] in
  for c = 0 to cycles - 1 do
    let chip_de = bit (Lockstep.uo ls) 1 in
    let line = if chip_de = 1 then bit (Lockstep.uo ls) 0 else client.(c) in
    bus.(c) <- line;
    de.(c) <- chip_de;
    let rx = if chip_de = 1 then 1 else line in
    let send = Queue.peek to_chip in
    let read, wrote = Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = rx lsl 3 } in
    if wrote then ignore (Queue.dequeue_exn to_chip : int);
    Option.iter read ~f:(fun w ->
      if w land 0xFF00 = 0x0100
      then pdu := !pdu @ [ w land 0xFF ]
      else (
        if w land 0x8000 <> 0
        then (
          let reply = Modbus_node.Registers.answer regs !pdu in
          if w land 0x4000 = 0 then List.iter (List.length reply :: reply) ~f:(Queue.enqueue to_chip));
        pdu := []))
  done;
  let chars = Modbus_node.read ~bit:mb_bit bus in
  let frames = ref [] in
  List.iteri (List.zip_exn mb_requests starts) ~f:(fun i ((what, req), at) ->
    let req_end = Float.of_int at +. (Float.of_int (List.length req) *. mb_char) in
    let reply =
      List.filter chars ~f:(fun (c, _, _) ->
        Float.(of_int c > req_end) && c < at + slot)
    in
    frames := !frames @ [ req ] @ if List.is_empty reply then [] else [ List.map reply ~f:(fun (_, b, _) -> b) ];
    match reply with
    | [] -> printf "%-30s no reply\n" what
    | (first, _, _) :: _ ->
      let bytes = List.map reply ~f:(fun (_, b, _) -> b) in
      let last, _, _ = List.last_exn reply in
      let gaps =
        List.map (List.zip_exn (List.drop_last_exn reply) (List.tl_exn reply)) ~f:(fun ((a, _, _), (b, _, _)) ->
          (Float.of_int (b - a) -. mb_char) /. mb_char)
      in
      let rise = ref first in
      while !rise > 0 && de.(!rise - 1) = 1 do decr rise done;
      let fall = ref last in
      while !fall < cycles - 1 && de.(!fall) = 1 do incr fall done;
      let stop_end = Float.of_int last +. mb_char in
      printf "%-30s %s, CRC %s, parity %s\n" what (hex_bytes bytes)
        (if Modbus_node.crc16 bytes = 0 then "good" else "BAD")
        (if List.for_all reply ~f:(fun (_, _, ok) -> ok) then "good" else "BAD");
      printf "%-30s %.2f characters after the request; gaps up to %.2f characters; driver on %.1f bit before, off %.1f bit after\n" ""
        ((Float.of_int first -. req_end) /. mb_char)
        (List.fold gaps ~init:0. ~f:Float.max)
        (Float.of_int (first - !rise) /. mb_bit)
        ((Float.of_int !fall -. stop_end) /. mb_bit);
      ignore i);
  printf "registers 0 to 5: %s\n" (String.concat ~sep:" " (List.init 6 ~f:(fun k -> sprintf "%04x" regs.(k))));
  (* every frame on the bus in order, requests and replies: its server ID, whether its CRC is
     right (sigrok's decoder does not decode function 0x2b, so it gives no verdict for that
     request), and the exception codes of the replies that are exceptions *)
  Lockstep.note ls "ids" (List.map !frames ~f:List.hd_exn);
  Lockstep.note ls "crc"
    (List.filter_map !frames ~f:(fun f ->
       if List.nth_exn f 1 = 0x2B then None else Some (if Modbus_node.crc16 f = 0 then 1 else 0)));
  Lockstep.note ls "exceptions"
    (List.filter_map !frames ~f:(fun f -> if List.nth_exn f 1 land 0x80 <> 0 then Some (List.nth_exn f 2) else None));
  [%expect {|
    read registers 0 and 1         01 03 04 10 00 10 01 32 f3, CRC good, parity good
                                   4.22 characters after the request; gaps up to 0.00 characters; driver on 1.0 bit before, off 0.0 bit after
    write register 1               01 06 00 01 12 34 d5 7d, CRC good, parity good
                                   4.26 characters after the request; gaps up to 0.00 characters; driver on 1.0 bit before, off 0.0 bit after
    write registers 2 and 3        01 10 00 02 00 02 e0 08, CRC good, parity good
                                   4.29 characters after the request; gaps up to 0.00 characters; driver on 1.0 bit before, off 0.0 bit after
    read registers 0 to 3          01 03 08 10 00 12 34 ab cd ef 01 1a 46, CRC good, parity good
                                   4.24 characters after the request; gaps up to 0.00 characters; driver on 1.0 bit before, off 0.0 bit after
    a request for server 2         no reply
    a request with its CRC wrong   no reply
    broadcast: write register 5    no reply
    function 0x2b (not served)     01 ab 01 9e f0, CRC good, parity good
                                   4.29 characters after the request; gaps up to 0.00 characters; driver on 1.0 bit before, off 0.0 bit after
    registers 0 to 5: 1000 1234 abcd ef01 1004 0007
    |}]
;;

(* ---- HDMI-CEC, run 10 times faster than real time: a 50 us unit is 250 cycles, and the
   recording is written at 200 ns a cycle, so it has the real timing. The device under test has
   logical address 4 (a playback device); the other ends are Cec_node: a TV (address 0) that
   sends frames and acknowledges frames to it, an audio system (5) that acknowledges frames to
   it, and a listener that only reads the line. *)
let cec_u = 250
let cec_line ls = if bit (Lockstep.uio_oe ls) 0 = 1 then bit (Lockstep.uio_out ls) 0 else 1

let run_cec ?(record = false) ~from_tv ~to_send ~cycles () =
  let ls = Lockstep.create (load "cec.s") in
  if record then Lockstep.record ls ~ns_per_cycle:(20. *. 10.) "cec";
  let tv = Cec_node.initiator ~u:cec_u ~cycles from_tv in
  let tv_acks = Cec_node.Follower.create ~u:cec_u ~address:0
  and audio = Cec_node.Follower.create ~u:cec_u ~address:5
  and listener = Cec_node.Follower.create ~u:cec_u ~address:(-1) in
  let to_chip = Queue.of_list ([ cec_u; 4 ] @ to_send) in
  let words = ref [] in
  let bus = Array.create ~len:cycles 1 in
  for c = 0 to cycles - 1 do
    let b = tv.(c) land tv_acks.out land audio.out land cec_line ls in
    bus.(c) <- b;
    List.iter [ tv_acks; audio; listener ] ~f:(fun f -> Cec_node.Follower.step f ~cycle:c ~bus:b);
    step ls to_chip words { Model.Pads.zero with uio_in = b }
  done;
  ls, List.rev !words, listener, bus
;;

let print_cec_words words =
  List.iter words ~f:(fun w ->
    if w land 0x8000 <> 0
    then
      printf "  sent: %s\n"
        (match w land 0xFF with
         | 0 -> "done"
         | 1 -> "not acknowledged"
         | 2 -> "lost arbitration"
         | s -> sprintf "status %d" s)
    else
      printf "  read %02x%s%s\n" (w land 0xFF)
        (if w land 0x400 <> 0 then ", acknowledged" else "")
        (if w land 0x200 <> 0 then ", last block" else ""))
;;

let%expect_test "cec.s: frames from a TV model, some for it, written from the HDMI-CEC spec" =
  let frames =
    [ 10_000, [ 0x04 ] (* polling: is there a device 4? *)
    ; 260_000, [ 0x04; 0x8F ] (* Give Device Power Status, to 4 *)
    ; 630_000, [ 0x05; 0x8F ] (* the same, to the audio system *)
    ; 1_000_000, [ 0x0F; 0x84; 0x10; 0x00; 0x00 ] (* broadcast: Report Physical Address *)
    ; 1_730_000, [ 0x03; 0x8F ] (* to 3: nobody there *)
    ]
  in
  let _, words, listener, _ = run_cec ~from_tv:frames ~to_send:[] ~cycles:2_100_000 () in
  print_cec_words words;
  printf "on the line: %s\n" (String.concat ~sep:" | " (List.rev_map listener.frames ~f:Cec_node.to_string));
  [%expect {|
      read 04, acknowledged, last block
      read 04, acknowledged
      read 8f, acknowledged, last block
      read 05, acknowledged
      read 8f, acknowledged, last block
      read 0f
      read 84
      read 10
      read 00
      read 00, last block
      read 03
      read 8f, last block
    on the line: 04a. | 04a 8fa. | 05a 8fa. | 0f 84 10 00 00. | 03 8f.
    |}]
;;

let%expect_test "cec.s: sending for its host, checked on the line" =
  let to_send = [ 3; 0x40; 0x90; 0x00 ] @ [ 1; 0x43 ] @ [ 4; 0x4F; 0x82; 0x10; 0x00 ] in
  let ls, words, listener, bus = run_cec ~record:true ~from_tv:[] ~to_send ~cycles:1_400_000 () in
  print_cec_words words;
  printf "on the line: %s\n" (String.concat ~sep:" | " (List.rev_map listener.frames ~f:Cec_node.to_string));
  (* every low stretch on the line, in ms at real time *)
  let lows = ref []
  and fell = ref 0 in
  Array.iteri bus ~f:(fun i b ->
    if i > 0 && b = 0 && bus.(i - 1) = 1 then fell := i;
    if i > 0 && b = 1 && bus.(i - 1) = 0 then lows := (i - !fell) :: !lows);
  let ms c = Float.of_int c /. Float.of_int cec_u *. 0.05 in
  let kinds =
    List.dedup_and_sort ~compare:Float.compare (List.map !lows ~f:(fun l -> Float.round_decimal (ms l) ~decimal_digits:2))
  in
  printf "low stretches on the line: %s ms\n" (String.concat ~sep:", " (List.map kinds ~f:(sprintf "%.2f")));
  let starts = List.rev_map listener.starts ~f:fst in
  printf "start bits at: %s ms\n" (String.concat ~sep:", " (List.map starts ~f:(fun c -> sprintf "%.1f" (ms c))));
  Lockstep.note ls "frames" (List.concat_map (List.rev listener.frames) ~f:(List.map ~f:(fun (b, _, _) -> b)));
  [%expect {|
      sent: done
      sent: not acknowledged
      sent: done
    on the line: 40a 90a 00a. | 43. | 4f 82 10 00.
    low stretches on the line: 0.60, 1.50, 3.70 ms
    start bits at: 17.3, 111.2, 157.0 ms
    |}]
;;

let%expect_test "cec.s: the TV starts a frame on the same cycle and wins arbitration" =
  (* first find the cycle the device starts its frame on, then let the TV start there too *)
  let to_send = [ 2; 0x45; 0x36 ] (* Standby, to the audio system *) in
  let _, _, _, bus = run_cec ~from_tv:[] ~to_send ~cycles:200_000 () in
  let start = Option.value_exn (Array.findi bus ~f:(fun _ b -> b = 0)) |> fst in
  let _, words, listener, _ =
    run_cec ~from_tv:[ start, [ 0x05; 0x8F ] ] ~to_send ~cycles:(start + 600_000) ()
  in
  print_cec_words words;
  printf "on the line: %s\n" (String.concat ~sep:" | " (List.rev_map listener.frames ~f:Cec_node.to_string));
  [%expect {|
      sent: lost arbitration
    on the line: 05a 8fa.
    |}]
;;

(* ---- AX.25 packet radio (APRS) over Bell 202 audio. Run 100 times faster than real time: a bit
   is 416 cycles, the 1200 Hz and 2200 Hz half periods 208 and 114. The other end is Ax25_node. *)
let ax_bit = 416
let ax_mark = 208
let ax_space = 114
let ax_threshold = 161

let%expect_test "AX.25 transmit configuration (HDLC stuffing, then NRZI), proved" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and d = G.input "d" 1
  and flags = G.input "flags" 1 in
  prove
    ~words:(Pemu_post.Fabric_post.ax25_tx ~n_le:8)
    ~ext:G.(flags @: gnd @: d)
    ~q
    ~spec:(fun ~f ~out ->
      let open G in
      let hold = q.(1) &: ~:flags in
      let sent = d &: ~:hold in
      let counting = ~:flags in
      let level = mux2 sent q.(6) ~:(q.(6)) (* a 0 changes the line *) in
      [ out.(0), hold
      ; out.(6), level
      ; f.(6), level
      ; f.(5), sent &: counting
      ; f.(4), sent &: q.(5) &: counting
      ; f.(3), sent &: q.(4) &: counting
      ; f.(2), sent &: q.(3) &: counting
      ; f.(1), sent &: q.(2) &: counting
      ]);
  [%expect {| proved: configuration = rule for all states and inputs |}]
;;

let%expect_test "AX.25 receive configuration (NRZI, then HDLC de-stuffing), proved" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and s = G.input "sample" 1 in
  prove
    ~words:(Pemu_post.Fabric_post.ax25_rx ~n_le:8)
    ~ext:G.(gnd @: s @: gnd)
    ~q
    ~spec:(fun ~f ~out ->
      let open G in
      let d = ~:(s ^: q.(1)) (* the same level as the last sample: a 1 *) in
      [ out.(0), d
      ; f.(1), s
      ; f.(2), d
      ; f.(3), d &: q.(2)
      ; f.(4), d &: q.(3)
      ; f.(5), d &: q.(4)
      ; f.(6), d &: q.(5)
      ; out.(7), q.(6) &: ~:d (* the 0 after five 1s *)
      ]);
  [%expect {| proved: configuration = rule for all states and inputs |}]
;;

let aprs_frames =
  let open Ax25_node in
  [ ui_frame ~dest:("APRS", 0) ~src:("N0CALL", 7) ~path:[ "WIDE1", 1 ] "!4903.50N/07201.75W-pemu test"
  ; ui_frame ~dest:("APRS", 0) ~src:("N0CALL", 7) ~path:[] ">running on the bit engine"
  ]
;;

let print_ax25_words words =
  let rec go acc = function
    | w :: rest when w land 0x2000 <> 0 -> go [] rest (* not a frame: drop its bytes *)
    | w :: rest when w land 0x8000 <> 0 ->
      let bytes = List.rev acc in
      let body = List.take bytes (List.length bytes - 2) in
      printf "  %s  (FCS %s)\n"
        (if List.length body >= 16 then Ax25_node.to_string body else "?")
        (if w land 0x4000 <> 0 then "right" else "WRONG");
      go [] rest
    | w :: rest -> go ((w land 0xFF) :: acc) rest
    | [] -> ()
  in
  go [] words
;;

let%expect_test "ax25_rx.s: APRS frames from audio written from the AX.25 and Bell 202 specs" =
  let open Ax25_node in
  let good = List.map aprs_frames ~f:with_fcs in
  let broken =
    List.mapi (with_fcs (List.hd_exn aprs_frames)) ~f:(fun i b -> if i = 3 then b lxor 0x10 else b)
  in
  let frames = [ List.nth_exn good 0; broken; List.nth_exn good 1 ] in
  let audio =
    audio ~bit:(Float.of_int ax_bit) ~mark:(Float.of_int ax_mark) ~space:(Float.of_int ax_space)
      (nrzi (bits frames))
  in
  let ls =
    Lockstep.create ~fabric:(Pemu_post.Fabric_post.ax25_rx ~n_le:Model.n_le) ~crc_poly:(0x1021 lsl 16)
      ~crc_init:(0xFFFF lsl 16) (load "ax25_rx.s")
  in
  let pending = Queue.of_list [ ax_bit; ax_threshold ] in
  let got = ref [] in
  Array.iter audio ~f:(fun a ->
    (* the program drives uio[1] and the bit engine reads it back through the pad *)
    let pads = Lockstep.uio_out ls land Lockstep.uio_oe ls in
    step ls pending got { Model.Pads.uio_in = pads; ui_in = a lsl 3 });
  print_ax25_words (List.rev !got);
  printf "the model reads its own audio as: %s\n"
    (String.concat ~sep:" | "
       (List.map (decode ~bit:(Float.of_int ax_bit) ~threshold:(Float.of_int ax_threshold) audio)
          ~f:(fun (b, ok) -> sprintf "%d bytes, FCS %s" (List.length b) (if ok then "right" else "WRONG"))));
  [%expect {|
      N0CALL-7>APRS,WIDE1-1:!4903.50N/07201.75W-pemu test  (FCS right)
      N0CALL-7>APR[,WIDE1-1:!4903.50N/07201.75W-pemu test  (FCS WRONG)
      N0CALL-7>APRS:>running on the bit engine  (FCS right)
    the model reads its own audio as: 52 bytes, FCS right | 52 bytes, FCS WRONG | 42 bytes, FCS right
    |}]
;;

(* the model of the whole chip, checked against the RTL at the pins every cycle *)
let%expect_test "three engines on one chip: ax25_tx.s frames, afsk_tx.s tones, ax25_rx.s reads them back" =
  let module H = Chip_host in
  let t = H.create () in
  attach_chip_model t;
  let asm name = load name in
  H.load t 0 (asm "ax25_tx.s");
  H.load t 1 (asm "ax25_rx.s");
  H.load t 2 (asm "afsk_tx.s");
  let config e fabric =
    Array.iteri fabric ~f:(fun k w -> H.set_config t e ~word:k w);
    H.set_config t e ~word:16 (0x1021 lsl 16);
    H.set_config t e ~word:17 (0xFFFF lsl 16)
  in
  config 0 (Pemu_post.Fabric_post.ax25_tx ~n_le:Model.n_le);
  config 1 (Pemu_post.Fabric_post.ax25_rx ~n_le:Model.n_le);
  H.own t ~pin:2 ~engine:0 (* the NRZI line, on a uio pad so the tone engine can read it *);
  H.own t ~pin:1 ~engine:1 (* the tone the receiver finds *);
  H.own t ~pin:8 ~engine:2 (* the audio *);
  (* the audio goes out on uo[0] and back in on ui[3], as through a radio's audio path *)
  let audio = ref [] in
  t.on_cycle
  <- (fun t ->
       let a = H.uo t land 1 in
       audio := a :: !audio;
       t.ui <- (t.ui land lnot 0x08) lor (a lsl 3));
  H.run t 0b111;
  let send e w = H.write t (H.mailbox e) [ w ] in
  List.iter [ ax_bit; 6 ] ~f:(send 0) (* bit time, opening flags *);
  List.iter [ ax_bit; ax_threshold ] ~f:(send 1);
  List.iter [ ax_mark; ax_space ] ~f:(send 2);
  let from_rx = ref []
  and from_tx = ref [] in
  let drain e acc =
    let n = H.outbox_count t e in
    if n > 0 then acc := List.rev_append (H.read t (H.mailbox e) n) !acc
  in
  List.iter aprs_frames ~f:(fun f ->
    let words = List.length f :: f in
    List.iter words ~f:(fun w ->
      while H.inbox_count t 0 >= 2 do
        H.cycles t 200;
        drain 1 from_rx
      done;
      send 0 w));
  for _ = 1 to 400 do
    H.cycles t 1000;
    drain 1 from_rx;
    drain 0 from_tx
  done;
  printf "ax25_tx.s said: %s\n" (String.concat ~sep:" " (List.rev_map !from_tx ~f:Int.to_string));
  printf "ax25_rx.s, on the same chip:\n";
  print_ax25_words (List.rev !from_rx);
  let samples = Array.of_list (List.rev !audio) in
  printf "the model reads the chip's audio as:\n";
  List.iter (Ax25_node.decode ~bit:(Float.of_int ax_bit) ~threshold:(Float.of_int ax_threshold) samples)
    ~f:(fun (b, ok) -> printf "  %s  (FCS %s)\n" (Ax25_node.to_string b) (if ok then "right" else "WRONG"));
  [%expect {|
    ax25_tx.s said: 1 1
    ax25_rx.s, on the same chip:
      N0CALL-7>APRS,WIDE1-1:!4903.50N/07201.75W-pemu test  (FCS right)
      N0CALL-7>APRS:>running on the bit engine  (FCS right)
    the model reads the chip's audio as:
      N0CALL-7>APRS,WIDE1-1:!4903.50N/07201.75W-pemu test  (FCS right)
      N0CALL-7>APRS:>running on the bit engine  (FCS right)
    |}]
;;
