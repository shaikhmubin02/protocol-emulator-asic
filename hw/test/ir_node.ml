(* NEC infrared remote control, written from the NEC format: a demodulating IR receiver, a
   decoder, and the line a remote sends, in units of 562.5 us (a unit in cycles is given, so a
   test can run faster than real time). A frame: a 16-unit mark, an 8-unit space, 32 bits LSB
   first, each a 1-unit mark and a 1-unit (0) or 3-unit (1) space, then a 1-unit mark. A repeat
   code: a 16-unit mark, a 4-unit space, a 1-unit mark. *)
open! Core

(* a demodulating receiver: low while the carrier is there, that is while the LED pin has
   changed within the last [hold] cycles *)
module Demod = struct
  type t =
    { hold : int
    ; mutable last_edge : int
    ; mutable last : int
    }

  let create ~hold = { hold; last_edge = -1_000_000; last = 0 }

  let step t ~cycle ~led =
    if led <> t.last
    then (
      t.last_edge <- cycle;
      t.last <- led);
    if cycle - t.last_edge <= t.hold then 0 else 1
  ;;
end

type code =
  | Frame of int (* the 32 bits *)
  | Repeat

(* the receiver's output for some codes; [stretch] makes the remote's units longer or shorter;
   [cut] stops a frame after that many bits *)
let line ~unit ?(stretch = 1.0) ?cut codes =
  let u n = Float.iround_nearest_exn (Float.of_int n *. unit *. stretch) in
  let runs =
    List.concat_map codes ~f:(fun code ->
      let body =
        match code with
        | Repeat -> [ 0, u 16; 1, u 4; 0, u 1 ]
        | Frame bits ->
          let n = Option.value cut ~default:32 in
          [ 0, u 16; 1, u 8 ]
          @ List.concat (List.init n ~f:(fun k -> [ 0, u 1; 1, u (if (bits lsr k) land 1 = 1 then 3 else 1) ]))
          @ if n = 32 then [ 0, u 1 ] else []
      in
      let used = List.sum (module Int) body ~f:snd in
      body @ [ 1, u 192 - used ])
  in
  Array.concat (Array.create ~len:2000 1 :: List.map runs ~f:(fun (l, n) -> Array.create ~len:n l))
;;

(* runs of (level, cycles) *)
let runs samples =
  let n = Array.length samples in
  let rec go i acc =
    if i >= n
    then List.rev acc
    else (
      let j = ref i in
      while !j < n && samples.(!j) = samples.(i) do
        incr j
      done;
      go !j ((samples.(i), !j - i, i) :: acc))
  in
  go 0 []
;;

(* decode the receiver's output; returns the codes and where each began *)
let decode samples ~unit =
  let units c = Float.of_int c /. unit in
  let near c x tol = Float.(abs (units c - x) <= tol) in
  let rec go acc = function
    | (0, m, at) :: (1, s, _) :: rest when near m 16. 3. ->
      if near s 4. 1.
      then (
        match rest with
        | (0, _, _) :: rest -> go ((Repeat, at) :: acc) rest
        | _ -> List.rev acc)
      else if near s 8. 2.
      then (
        let rec bits k v = function
          | (0, m, _) :: (1, s, _) :: rest when k < 32 && near m 1. 0.5 ->
            if near s 1. 0.5
            then bits (k + 1) v rest
            else if near s 3. 1.
            then bits (k + 1) (v lor (1 lsl k)) rest
            else None
          | (0, m, _) :: rest when k = 32 && near m 1. 0.5 -> Some (v, rest)
          | _ -> None
        in
        match bits 0 0 rest with
        | Some (v, rest) -> go ((Frame v, at) :: acc) rest
        | None -> go acc rest)
      else go acc rest
    | _ :: rest -> go acc rest
    | [] -> List.rev acc
  in
  go [] (runs samples)
;;

let to_string = function
  | Repeat -> "repeat"
  | Frame v ->
    let b k = (v lsr (8 * k)) land 0xFF in
    if b 0 lxor b 1 = 0xFF && b 2 lxor b 3 = 0xFF
    then sprintf "address %02x, command %02x" (b 0) (b 2)
    else if b 2 lxor b 3 = 0xFF
    then sprintf "extended address %04x, command %02x" (v land 0xFFFF) (b 2)
    else sprintf "code %08x (command check failed)" v
;;

(* ---- Philips RC-5 (with the RC-5X seventh command bit): 14 bits of 1.778 ms (4 quarters),
   Manchester: a 1 is a space then a mark, a 0 a mark then a space. S1 = 1, S2 = the inverse of
   command bit 6, T (toggles on a new key press), 5 address bits, 6 command bits, MSB first. A
   held key repeats the frame every 64 bits. *)
let rc5_bits ~address ~command ~toggle =
  [ 1; 1 - ((command lsr 6) land 1); toggle ]
  @ List.init 5 ~f:(fun k -> (address lsr (4 - k)) land 1)
  @ List.init 6 ~f:(fun k -> (command lsr (5 - k)) land 1)
;;

(* the receiver's output (low = mark) for frames of bits; [stretch] makes the remote slow or
   fast; [cut] stops the last frame after that many bits *)
let rc5_line ~quarter ?(stretch = 1.0) ?cut frames =
  let q n = Float.iround_nearest_exn (Float.of_int n *. quarter *. stretch) in
  let last = List.length frames - 1 in
  let runs =
    List.concat_mapi frames ~f:(fun i bits ->
      let bits = if i = last then Option.value_map cut ~default:bits ~f:(List.take bits) else bits in
      let halves = List.concat_map bits ~f:(fun b -> if b = 1 then [ 1; 0 ] else [ 0; 1 ]) in
      List.map halves ~f:(fun l -> l, q 2) @ [ 1, q (256 - (4 * List.length bits)) ])
  in
  Array.concat (Array.create ~len:2000 1 :: List.map runs ~f:(fun (l, n) -> Array.create ~len:n l))
;;

(* read the receiver's output the way the format defines a bit: by the edge in its middle,
   expected a bit after the last middle (between three quarters and five quarters of a bit) *)
let rc5_decode samples ~quarter =
  let t = 4. *. quarter in
  let n = Array.length samples in
  let rec change_after i = if i + 1 >= n then None else if samples.(i + 1) <> samples.(i) then Some (i + 1) else change_after (i + 1) in
  let rec frames i acc =
    (* idle high, then the falling middle of S1 *)
    match change_after i with
    | None -> List.rev acc
    | Some j when samples.(j) = 0 ->
      let rec bits m k got =
        if k = 13
        then Some (List.rev got, m)
        else (
          let from = m + Float.iround_nearest_exn (0.75 *. t) in
          match change_after from with
          | Some e ->
            let d = Float.of_int (e - m) in
            if Float.(d <= 1.25 * t)
            then bits e (k + 1) ((if samples.(e) = 0 then 1 else 0) :: got)
            else None
          | None -> None)
      in
      (match bits j 0 [ 1 ] with
       | Some (b, m) -> frames (m + Float.iround_nearest_exn t) (b :: acc)
       | None -> frames j acc)
    | Some j -> frames j acc
  in
  frames 0 []
;;

let rc5_to_string bits =
  let v l = List.fold l ~init:0 ~f:(fun a b -> (a lsl 1) lor b) in
  match bits with
  | [ _s1; s2; t; a4; a3; a2; a1; a0; c5; c4; c3; c2; c1; c0 ] ->
    sprintf "address %d, command %d, T %d" (v [ a4; a3; a2; a1; a0 ])
      (v [ 1 - s2; c5; c4; c3; c2; c1; c0 ]) t
  | _ -> sprintf "%d bits" (List.length bits)
;;
