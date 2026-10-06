(* The whole chip, driven only through its pins: everything is loaded and read over host SPI. *)

open! Core
open Pemu
module H = Chip_host

let assemble src =
  match Asm.assemble src with
  | Ok w -> w
  | Error e -> failwith e
;;

let load name = assemble (In_channel.read_all ("../firmware/" ^ name))
let hex l = String.concat ~sep:" " (List.map l ~f:(sprintf "%04x"))

let%expect_test "chip id, run register and cycle counter" =
  let t = H.create () in
  let lo1 = H.read1 t H.time_lo in
  let lo2 = H.read1 t H.time_lo in
  printf
    "id %04x, run %d, hi %d, counter moved %b\n"
    (H.read1 t H.id_reg)
    (H.read1 t H.run_reg)
    (H.read1 t H.time_hi)
    (lo2 > lo1);
  [%expect {| id 5045, run 0, hi 0, counter moved true |}]
;;

let%expect_test "program memory: write and read back on every engine" =
  let t = H.create () in
  let rng = Random.State.make [| 1 |] in
  let words = Array.init 4 ~f:(fun _ -> List.init 24 ~f:(fun _ -> Random.State.int rng 0x10000)) in
  Array.iteri words ~f:(fun e w -> H.write t (H.program e 100) w);
  Array.iteri words ~f:(fun e w ->
    let back = H.read t (H.program e 100) 24 in
    printf "engine %d: %s\n" e (if [%equal: int list] w back then "ok" else "differs: " ^ hex back));
  [%expect {|
    engine 0: ok
    engine 1: ok
    engine 2: ok
    engine 3: ok
    |}]
;;

let%expect_test "uart.s loaded over SPI, TX looped back to RX" =
  let t = H.create () in
  H.load t 1 (load "uart.s");
  (* nothing owns uo[0] yet, so it stays low *)
  H.run t 0b0010;
  H.cycles t 50;
  printf "uo[0] before owning: %d\n" (H.uo t land 1);
  H.own t ~pin:8 ~engine:1;
  t.on_cycle <- (fun t -> t.ui <- (t.ui land lnot 0x08) lor ((H.uo t land 1) lsl 3));
  let sent = [ 0x00; 0xff; 0x55; 0xa5; 0x3c; 0x81 ] in
  (* like a real host: one status read per turn, then drain the outbox and top up the inbox
     (the outbox holds two words; if the host stops reading, the firmware blocks on push and
     RX overruns) *)
  let pending = Queue.of_list sent in
  let got = ref [] in
  let deadline = t.cycle + 30_000 in
  while List.length !got < List.length sent && t.cycle < deadline do
    let st = H.read1 t (H.status 1) in
    let inbox = (st lsr 10) land 3
    and outbox = (st lsr 12) land 3 in
    if outbox > 0 then got := !got @ H.read t (H.mailbox 1) outbox;
    if inbox < 2 then Option.iter (Queue.dequeue pending) ~f:(fun b -> H.write t (H.mailbox 1) [ b ])
  done;
  printf "sent %s\ngot  %s\n" (hex sent) (hex !got);
  [%expect {|
    uo[0] before owning: 0
    sent 0000 00ff 0055 00a5 003c 0081
    got  0000 00ff 0055 00a5 003c 0081
    |}]
;;

let%expect_test "engines meet on an event flag" =
  let t = H.create () in
  (* three engines wait for flag 2 and report the time they woke; engine 2 raises flag 2 once
     the host raises flag 7 *)
  let waiter =
    assemble {|
      wait flag 2, 1
      csrr r0, time_lo
      push r0
      halt
|}
  in
  let starter = assemble {|
      wait flag 7, 1
      sig  2
      clrf 7
      halt
|} in
  List.iter [ 0; 1; 3 ] ~f:(fun e -> H.load t e waiter);
  H.load t 2 starter;
  H.run t 0b1111;
  H.cycles t 100;
  let before = List.map [ 0; 1; 3 ] ~f:(fun e -> H.outbox_count t e) in
  H.write t H.flags_reg [ 0x80 ];
  H.cycles t 20;
  let woke = List.map [ 0; 1; 3 ] ~f:(fun e -> H.read1 t (H.mailbox e)) in
  printf
    "outboxes before %s, flags after %02x, all woke together %b\n"
    (Sexp.to_string [%sexp (before : int list)])
    (H.read1 t H.flags_reg)
    (List.for_all woke ~f:(fun w -> w = List.hd_exn woke));
  [%expect {| outboxes before (0 0 0), flags after 04, all woke together true |}]
;;

let%expect_test "mailbox reads one word at a time lose nothing" =
  let t = H.create () in
  H.load
    t
    0
    (assemble
       {|
      ldi  r0, 1
      push r0
      ldi  r0, 2
      push r0
      ldi  r0, 3
      push r0
      halt
|});
  H.run t 0b0001;
  H.cycles t 50;
  (* a plain loop: List.init calls its function from the last index down *)
  let got = ref [] in
  for _ = 1 to 3 do
    got := !got @ [ H.read1 t (H.mailbox 0) ]
  done;
  let got = !got in
  printf "got %s, outbox left %d\n" (hex got) (H.outbox_count t 0);
  [%expect {| got 0001 0002 0003, outbox left 0 |}]
;;
