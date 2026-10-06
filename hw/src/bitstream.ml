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
let word ?(use_ff = false) ?(init = 0) ?(on_rx = false) ~inputs fn =
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
  lut
  lor (sel lsl 16)
  lor ((if use_ff then 1 else 0) lsl 28)
  lor (init lsl 29)
  lor ((if on_rx then 1 else 0) lsl 30)
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

(* USB-style TX line coding: bit stuffing (a 0 after six 1s) then NRZI (0 = toggle), on TX
   ticks. Element 0 = hold (six 1s were sent), 1..6 = "the last k sent bits were 1",
   7 = NRZI line (starts high, the USB idle state). Roles: line = 7, hold = 0. *)
let usb_tx ~n_le =
  let w = Array.create ~len:n_le empty in
  w.(0) <- word ~inputs:[ Next ] (fun t5 _ _ _ -> t5);
  for k = 1 to 6 do
    let inputs = if k = 6 then [ Ext0; Le0 ] else [ Ext0; Le0; Next ] in
    w.(k)
    <- word ~use_ff:true ~inputs (fun d hold above _ ->
         let sent = d land (1 - hold) in
         if k = 6 then sent else sent land above)
  done;
  w.(7)
  <- word ~init:1 ~inputs:[ Ext0; Le0; Self ] (fun d hold prev _ ->
       let sent = d land (1 - hold) in
       if sent = 1 then prev else 1 - prev);
  w
;;
