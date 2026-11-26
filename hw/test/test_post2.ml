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
