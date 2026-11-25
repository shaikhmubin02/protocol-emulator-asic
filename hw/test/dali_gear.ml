(* The other end for dali.s: DALI control gear (a lamp driver), written from IEC 62386-101
   (bit coding and timing) and -102 (commands), not from the firmware.
   - Bi-phase coding, Te = half a bit: a 1 is low for Te then high for Te, a 0 the other way
     round. The bus idles high; any device pulls it low.
   - Forward frame: start bit (1), address byte, data byte, MSB first, 2 stop bits (idle).
     Address byte YAAAAAAS: Y = 0 short address AAAAAA, 1111111S broadcast; S = 0: the data byte
     is a light level (direct arc power control), S = 1: it is a command.
   - Commands used here: 0x00 OFF, 0x05 RECALL MAX LEVEL, 0x90 QUERY STATUS, 0x91 QUERY CONTROL
     GEAR PRESENT, 0xA0 QUERY ACTUAL LEVEL. Queries are answered with a backward frame (start
     bit, one byte) between 7 and 22 Te after the forward frame: here after 10 Te.
   The gear samples each half of every bit in its middle and rejects a frame whose halves are not
   one high and one low. *)

open! Core

type t =
  { te : int
  ; address : int
  ; mutable level : int
  ; mutable max_level : int
  ; mutable start : int option (* cycle of the forward frame's first falling edge *)
  ; mutable halves : int list (* sampled half-bit levels, newest first *)
  ; mutable reply : (int * int array) option (* start cycle, half-bit levels *)
  ; mutable last : int
  ; mutable frames : (int * int) list (* forward frames seen *)
  ; mutable bad_frames : int
  }

let create ~te ~address =
  { te
  ; address
  ; level = 0
  ; max_level = 254
  ; start = None
  ; halves = []
  ; reply = None
  ; last = 1
  ; frames = []
  ; bad_frames = 0
  }
;;

let halves_of_bits bits = Array.of_list (List.concat_map bits ~f:(fun b -> if b = 1 then [ 0; 1 ] else [ 1; 0 ]))

let answer t ~now byte =
  let bits = 1 :: List.init 8 ~f:(fun k -> (byte lsr (7 - k)) land 1) in
  t.reply <- Some (now + (10 * t.te), halves_of_bits bits)
;;

let addressed t a =
  let y = a lsr 7 in
  (a lor 1 = 0xFF) || (y = 0 && (a lsr 1) land 0x3F = t.address)
;;

let handle t ~now a d =
  t.frames <- (a, d) :: t.frames;
  if addressed t a
  then
    if a land 1 = 0
    then t.level <- d (* direct arc power control *)
    else (
      match d with
      | 0x00 -> t.level <- 0
      | 0x05 -> t.level <- t.max_level
      | 0x90 -> answer t ~now (if t.level > 0 then 0x04 else 0x00) (* lamp arc power on *)
      | 0x91 -> answer t ~now 0xFF
      | 0xA0 -> answer t ~now t.level
      | _ -> ())
;;

(* what the gear drives in [cycle] (1 = released) *)
let drive t ~cycle =
  match t.reply with
  | Some (at, halves) when cycle >= at ->
    let k = (cycle - at) / t.te in
    if k < Array.length halves
    then halves.(k)
    else (
      t.reply <- None;
      1)
  | _ -> 1
;;

let observe t ~cycle ~bus =
  (match t.start with
   | None -> if bus = 0 && t.last = 1 && Option.is_none t.reply then t.start <- Some cycle
   | Some s ->
     let rel = cycle - s in
     if rel % t.te = t.te / 2
     then (
       t.halves <- bus :: t.halves;
       if List.length t.halves = 34
       then (
         let h = Array.of_list (List.rev t.halves) in
         let bits = List.init 17 ~f:(fun k -> if h.(2 * k) <> h.((2 * k) + 1) then Some h.((2 * k) + 1) else None) in
         if List.for_all bits ~f:Option.is_some && Option.value_exn (List.hd_exn bits) = 1
         then (
           let v = List.fold (List.tl_exn bits) ~init:0 ~f:(fun a b -> (a lsl 1) lor Option.value_exn b) in
           handle t ~now:(s + (38 * t.te)) (v lsr 8) (v land 0xFF))
         else t.bad_frames <- t.bad_frames + 1;
         t.start <- None;
         t.halves <- [])));
  t.last <- bus
;;
