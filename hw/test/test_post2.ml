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
