(* HDMI-CEC, written from the CEC part of the HDMI specification. One open-drain line, low if
   anyone pulls it. Times in units of 50 us ([u] cycles each). Start bit: low 3.7 ms (74), period
   4.5 ms (90). Data bit: period 2.4 ms (48), low 1.5 ms (30) for a 0, 0.6 ms (12) for a 1, read
   1.05 ms (21) after the fall. A block: 8 bits MSB first, EOM, ACK (sent as 1; a follower the
   frame is addressed to makes it a 0). The first block is initiator << 4 | destination. *)
open! Core

(* an initiator's frames, as the low stretches of the line: (start, length) in units from the
   frame's start *)
let frame_lows bytes =
  let n = List.length bytes in
  (0, 74)
  :: List.concat
       (List.mapi bytes ~f:(fun i b ->
          let bits = List.init 8 ~f:(fun k -> (b lsr (7 - k)) land 1) @ [ (if i = n - 1 then 1 else 0); 1 ] in
          List.mapi bits ~f:(fun k bit -> 90 + (((10 * i) + k) * 48), if bit = 1 then 12 else 30)))
;;

let frame_units bytes = 90 + (10 * List.length bytes * 48)

(* what a model initiator does to the line: frames at given cycles *)
let initiator ~u ~cycles frames =
  let line = Array.create ~len:cycles 1 in
  List.iter frames ~f:(fun (at, bytes) ->
    List.iter (frame_lows bytes) ~f:(fun (s, len) ->
      for c = at + (s * u) to Int.min (cycles - 1) (at + ((s + len) * u) - 1) do
        line.(c) <- 0
      done));
  line
;;

(* a follower: it reads every frame, and acknowledges the blocks of frames to [address] (pass
   -1 for a device that only listens) *)
module Follower = struct
  type t =
    { u : int
    ; address : int
    ; mutable out : int
    ; mutable last : int
    ; mutable fell_at : int
    ; mutable sample_at : int
    ; mutable release_at : int
    ; mutable in_frame : bool
    ; mutable bits : int list
    ; mutable header_done : bool
    ; mutable for_me : bool
    ; mutable cur : (int * bool * bool) list (* byte, EOM, the ACK bit was 0 *)
    ; mutable frames : (int * bool * bool) list list (* newest first *)
    ; mutable starts : (int * int) list (* start bits seen: (fall, low cycles), newest first *)
    }

  let create ~u ~address =
    { u
    ; address
    ; out = 1
    ; last = 1
    ; fell_at = 0
    ; sample_at = -1
    ; release_at = 0
    ; in_frame = false
    ; bits = []
    ; header_done = false
    ; for_me = false
    ; cur = []
    ; frames = []
    ; starts = []
    }
  ;;

  let step t ~cycle ~bus =
    let u = t.u in
    if t.out = 0 && cycle >= t.release_at then t.out <- 1;
    if cycle = t.sample_at && t.in_frame
    then (
      t.bits <- bus :: t.bits;
      let n = List.length t.bits in
      let value l = List.fold (List.rev l) ~init:0 ~f:(fun a b -> (a lsl 1) lor b) in
      if n = 8 && not t.header_done then t.for_me <- value t.bits land 0xF = t.address;
      if n = 10
      then (
        let b = List.rev t.bits in
        let byte = List.fold (List.take b 8) ~init:0 ~f:(fun a x -> (a lsl 1) lor x) in
        let eom = List.nth_exn b 8 = 1
        and acked = List.nth_exn b 9 = 0 in
        t.cur <- (byte, eom, acked) :: t.cur;
        t.bits <- [];
        t.header_done <- true;
        if eom
        then (
          t.frames <- List.rev t.cur :: t.frames;
          t.in_frame <- false)));
    if bus = 0 && t.last = 1
    then (
      t.fell_at <- cycle;
      t.sample_at <- cycle + (21 * u);
      (* the ACK bit of a block for me: hold the line low to 1.5 ms *)
      if t.in_frame && t.for_me && List.length t.bits = 9
      then (
        t.out <- 0;
        t.release_at <- cycle + (30 * u)));
    if bus = 1 && t.last = 0
    then (
      let low = cycle - t.fell_at in
      if low >= 70 * u && low <= 78 * u
      then (
        if t.in_frame && not (List.is_empty t.cur) then t.frames <- List.rev t.cur :: t.frames;
        t.starts <- (t.fell_at, low) :: t.starts;
        t.in_frame <- true;
        t.bits <- [];
        t.cur <- [];
        t.header_done <- false;
        t.for_me <- false));
    t.last <- bus
  ;;
end

let to_string blocks =
  String.concat ~sep:" "
    (List.map blocks ~f:(fun (b, eom, acked) ->
       sprintf "%02x%s%s" b (if acked then "a" else "") (if eom then "." else "")))
;;
