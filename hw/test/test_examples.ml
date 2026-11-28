(* The example programs of docs/programming.md (hw/firmware/examples), run on the engine RTL in
   lockstep with the model, so the guide's listings are known to work. *)

open! Core
open Pemu
open Post_util

let%expect_test "examples/square.s: an edge every 25 cycles, exactly" =
  let ls = Lockstep.create (load "examples/square.s") in
  let edges = ref []
  and last = ref 0 in
  for c = 1 to 2000 do
    ignore (Lockstep.step ls Model.Pads.zero : int option * bool);
    let pin = Lockstep.uo ls land 1 in
    if pin <> !last then edges := c :: !edges;
    last := pin
  done;
  let edges = List.rev !edges in
  let gaps = List.map2_exn (List.drop_last_exn edges) (List.tl_exn edges) ~f:(fun a b -> b - a) in
  printf "%d edges; gaps between them: %s\n" (List.length edges)
    (String.concat ~sep:" " (List.map (List.dedup_and_sort gaps ~compare:Int.compare) ~f:Int.to_string));
  [%expect {| 79 edges; gaps between them: 25 |}]
;;

let%expect_test "examples/echo.s: every word comes back plus 1" =
  let ls = Lockstep.create (load "examples/echo.s") in
  let q = Queue.of_list [ 1; 2; 3; 0x1233; 0xFFFF ] in
  let got = ref [] in
  for _ = 1 to 200 do
    step ls q got Model.Pads.zero
  done;
  printf "%s\n" (String.concat ~sep:" " (List.rev_map !got ~f:(sprintf "%x")));
  [%expect {| 2 3 4 1234 0 |}]
;;
