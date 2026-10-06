(* Builds fabric config words. Hand-placed mappings for now; this becomes the bitstream
   compiler later. Mirrors the source numbering in Fabric_logic. *)

open! Core

type source =
  | Ext0
  | Ext1
  | Ext2
  | Le0
  | Self
  | Prev
  | Prev2
  | Next

let source_index = function
  | Ext0 -> 0
  | Ext1 -> 1
  | Ext2 -> 2
  | Le0 -> 3
  | Self -> 4
  | Prev -> 5
  | Prev2 -> 6
  | Next -> 7
;;

(* [fn] is the LUT function of its 4 inputs, each 0 or 1. *)
let word ?(use_ff = false) ?(init = 0) ~inputs fn =
  let inputs = List.take (inputs @ List.init 4 ~f:(fun _ -> Ext0)) 4 in
  let lut =
    List.init 16 ~f:(fun idx ->
      let b k = (idx lsr k) land 1 in
      if fn (b 0) (b 1) (b 2) (b 3) = 1 then 1 lsl idx else 0)
    |> List.fold ~init:0 ~f:( lor )
  in
  let sel =
    List.foldi inputs ~init:0 ~f:(fun k acc s -> acc lor (source_index s lsl (3 * k)))
  in
  lut lor (sel lsl 16) lor ((if use_ff then 1 else 0) lsl 28) lor (init lsl 29)
;;

let empty = word ~inputs:[] (fun _ _ _ _ -> 0)

(* Reflected (LSB-first) CRC of [width] bits: element 0 is the feedback, elements 1..width
   hold crc[0..width-1]. *)
let crc ~n_le ~width ~poly_reflected ~init =
  Array.init n_le ~f:(fun j ->
    if j = 0
    then word ~inputs:[ Ext0; Next ] (fun din c0 _ _ -> din lxor c0)
    else if j <= width
    then (
      let p = (poly_reflected lsr (j - 1)) land 1 in
      word
        ~use_ff:true
        ~init:((init lsr (j - 1)) land 1)
        ~inputs:[ Next; Le0 ]
        (fun upper fb _ _ -> upper lxor (p land fb)))
    else empty)
;;

(* Software reference for the same CRC. *)
let crc_ref ~poly_reflected ~init bits =
  List.fold bits ~init ~f:(fun c b ->
    let fb = (c lxor b) land 1 in
    (c lsr 1) lxor if fb = 1 then poly_reflected else 0)
;;
