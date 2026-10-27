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

(* 10BASE-T TX line coding: Manchester, on TX ticks at twice the bit rate. Element 0 toggles
   every tick and is 1 in the first half of a bit; it is also the hold role, so the shifter keeps
   each bit for two ticks. Element 1 = line: the complement of the bit in the first half, the bit
   in the second (802.3: a 1 goes low to high in the middle). Roles: line = 1, hold = 0. *)
let eth_tx ~n_le =
  let w = Array.create ~len:n_le empty in
  w.(0) <- word ~use_ff:true ~init:1 ~inputs:[ Self ] (fun first _ _ _ -> 1 - first);
  w.(1) <- word ~inputs:[ Ext0; Le0 ] (fun d first _ _ -> d lxor first);
  w
;;

(* 10BASE-T RX Manchester decoder, on RX ticks with one tick per cycle (all elements RX-clocked).
     0 e      an edge: the sample differs from the last one (combinational)
     1 P      the last sample; its LUT output is the sample itself = the rx bit role
     2..4     t1 t2 t3: a thermometer cleared on every edge, so t3 = "4 or more cycles since the
              last edge"
     5 U      the last edge was not taken (it was a bit boundary)
     6 D      drop role: keep a bit only on a taken edge after the SFD
     7 S      the SFD has been seen (sticky until BEN 1); also the flag role
   An edge is taken (a mid-bit edge) if t3 or U: a boundary edge comes about 2.5 cycles after a
   mid-bit edge, and a mid-bit edge always follows a boundary edge. The preamble has only mid-bit
   edges, so the first edge taken through U is the second 1 of the SFD; S goes up there, and the
   first bit kept is the first bit of the frame. *)
let eth_rx ~n_le =
  let w = Array.create ~len:n_le empty in
  let on_rx = true in
  w.(0) <- word ~on_rx ~inputs:[ Ext1; Next ] (fun s p _ _ -> s lxor p);
  w.(1) <- word ~on_rx ~inputs:[ Ext1 ] (fun s _ _ _ -> s);
  w.(2) <- word ~on_rx ~init:1 ~inputs:[ Le0 ] (fun e _ _ _ -> 1 - e);
  w.(3) <- word ~on_rx ~init:1 ~inputs:[ Le0; Prev ] (fun e t _ _ -> t land (1 - e));
  w.(4) <- word ~on_rx ~init:1 ~inputs:[ Le0; Prev ] (fun e t _ _ -> t land (1 - e));
  w.(5)
  <- word ~on_rx ~inputs:[ Le0; Prev; Self ] (fun e t3 u _ ->
       if e = 1 then (1 - t3) land (1 - u) else u);
  w.(6)
  <- word ~on_rx ~inputs:[ Le0; Prev2; Prev; Next ] (fun e t3 u s ->
       1 - (e land (t3 lor u) land s));
  w.(7)
  <- word ~on_rx ~use_ff:true ~inputs:[ Self; Le0; Prev2 ] (fun s e u _ -> s lor (e land u));
  w
;;

(* Ethernet CRC-32 as the CRC unit computes it (shift left, poly 0x04C11DB7), one bit at a time
   in the order the bits are sent, and the step run backwards. *)
let eth_poly = 0x04C11DB7

let crc32_step c b =
  let fb = ((c lsr 31) land 1) lxor b in
  ((c lsl 1) land 0xFFFF_FFFF) lxor if fb = 1 then eth_poly else 0
;;

let crc32_unstep c b =
  let fb = c land 1 in
  let shifted = c lxor if fb = 1 then eth_poly else 0 in
  (shifted lsr 1) lor ((fb lxor b) lsl 31)
;;

let lsb_first_bits bytes =
  List.concat_map bytes ~f:(fun x -> List.init 8 ~f:(fun k -> (x lsr k) land 1))
;;

let eth_preamble = List.init 7 ~f:(fun _ -> 0x55) @ [ 0xD5 ]

(* eth_tx.s feeds the preamble and SFD through the CRC too, so the CRC init value is the one
   that leaves all ones after them. *)
let eth_tx_crc_init =
  List.fold (List.rev (lsb_first_bits eth_preamble)) ~init:0xFFFF_FFFF ~f:crc32_unstep
;;
