(* Modbus RTU over RS-485, written from "Modbus over serial line" (V1.02) and the Modbus
   application protocol (V1.1b3): characters are 8E1, a frame ends after 3.5 characters of
   silence, the CRC-16 (0xA001 reflected, start 0xFFFF) goes low byte first. *)
open! Core

let crc16 bytes =
  List.fold bytes ~init:0xFFFF ~f:(fun c b ->
    Fn.apply_n_times ~n:8 (fun c -> if c land 1 = 1 then (c lsr 1) lxor 0xA001 else c lsr 1) (c lxor b))
;;

let with_crc bytes =
  let c = crc16 bytes in
  bytes @ [ c land 0xFF; c lsr 8 ]
;;

let char_bits b =
  (0 :: List.init 8 ~f:(fun k -> (b lsr k) land 1)) @ [ Int.popcount (b land 0xFF) land 1; 1 ]
;;

(* the client's side of the line: each frame starts at its cycle, characters back to back *)
let client_line ~bit frames ~cycles =
  let line = Array.create ~len:cycles 1 in
  List.iter frames ~f:(fun (at, bytes) ->
    List.iteri (List.concat_map bytes ~f:char_bits) ~f:(fun k b ->
      let from = at + Float.iround_nearest_exn (Float.of_int k *. bit) in
      let until = at + Float.iround_nearest_exn (Float.of_int (k + 1) *. bit) in
      for c = from to Int.min (cycles - 1) (until - 1) do
        line.(c) <- b
      done));
  line
;;

(* characters read off a line: (start cycle, byte, parity and stop right) *)
let read ~bit samples =
  let n = Array.length samples in
  let rec go i acc =
    if i >= n
    then List.rev acc
    else if i > 0 && samples.(i) = 0 && samples.(i - 1) = 1
    then (
      let at k = samples.(Int.min (n - 1) (i + Float.iround_nearest_exn ((Float.of_int k +. 0.5) *. bit))) in
      let b = List.fold (List.init 8 ~f:Fn.id) ~init:0 ~f:(fun a k -> a lor (at (k + 1) lsl k)) in
      let ok = at 9 = Int.popcount b land 1 && at 10 = 1 in
      go (i + Float.iround_nearest_exn (10.5 *. bit)) ((i, b, ok) :: acc))
    else go (i + 1) acc
  in
  go 1 []
;;

(* a server's register map, as the host keeps it: answers the PDU of a request *)
module Registers = struct
  type t = int array

  let create () : t = Array.init 16 ~f:(fun k -> 0x1000 + k)

  let answer (t : t) pdu =
    let word hi lo = (hi lsl 8) lor lo in
    match pdu with
    | [ 0x03; ah; al; nh; nl ] ->
      let a = word ah al
      and n = word nh nl in
      if a + n > Array.length t || n = 0
      then [ 0x83; 0x02 ]
      else
        0x03
        :: (2 * n)
        :: List.concat (List.init n ~f:(fun k -> [ t.(a + k) lsr 8; t.(a + k) land 0xFF ]))
    | [ 0x06; ah; al; vh; vl ] ->
      let a = word ah al in
      if a >= Array.length t
      then [ 0x86; 0x02 ]
      else (
        t.(a) <- word vh vl;
        pdu)
    | 0x10 :: ah :: al :: nh :: nl :: _count :: values ->
      let a = word ah al
      and n = word nh nl in
      if a + n > Array.length t || List.length values <> 2 * n
      then [ 0x90; 0x02 ]
      else (
        List.iteri (List.chunks_of values ~length:2) ~f:(fun k v ->
          match v with
          | [ hi; lo ] -> t.(a + k) <- word hi lo
          | _ -> ());
        [ 0x10; ah; al; nh; nl ])
    | f :: _ -> [ 0x80 lor f; 0x01 ] (* illegal function *)
    | [] -> []
  ;;
end
