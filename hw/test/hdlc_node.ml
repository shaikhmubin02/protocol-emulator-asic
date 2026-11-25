(* The other end for the HDLC firmware, written from RFC 1662 (PPP in HDLC-like framing) and
   ISO 13239, not from the firmware:
   - FCS-16: the RFC's table-free algorithm (reflected polynomial 0x8408, start 0xFFFF), sent
     as its ones' complement, low byte first; a receiver that runs the FCS over the frame and its
     FCS gets 0xF0B8 when they agree.
   - Bits go out least significant first. Between the opening and closing flag (0x7E), a 0 is
     inserted after five 1s in a row; flags are never stuffed. The line is NRZ.
   - [stream] is a whole line: idle 1s, flags, frames. *)

open! Core

let fcs16 ?(start = 0xFFFF) data =
  List.fold data ~init:start ~f:(fun f b ->
    let f = ref (f lxor b) in
    for _ = 1 to 8 do
      f := if !f land 1 = 1 then (!f lsr 1) lxor 0x8408 else !f lsr 1
    done;
    !f)
;;

let with_fcs data =
  let f = fcs16 data lxor 0xFFFF in
  data @ [ f land 0xFF; f lsr 8 ]
;;

let lsb_bits bytes = List.concat_map bytes ~f:(fun b -> List.init 8 ~f:(fun k -> (b lsr k) land 1))
let flag = lsb_bits [ 0x7E ]

let stuff bits =
  let ones = ref 0 in
  List.concat_map bits ~f:(fun b ->
    if b = 1
    then (
      incr ones;
      if !ones = 5
      then (
        ones := 0;
        [ 1; 0 ])
      else [ 1 ])
    else (
      ones := 0;
      [ 0 ]))
;;

type frame =
  { bytes : int list (* address, control, information: everything before the FCS *)
  ; bad_fcs : bool (* send a wrong FCS on purpose *)
  ; flags_before : int
  }

let frame_bits f =
  let body = with_fcs f.bytes in
  let body =
    if f.bad_fcs
    then List.mapi body ~f:(fun i b -> if i = List.length body - 1 then b lxor 0x01 else b)
    else body
  in
  List.concat (List.init f.flags_before ~f:(fun _ -> flag)) @ stuff (lsb_bits body)
;;

(* idle, then the frames; a closing flag after each (it can open the next one too) *)
let stream ~idle frames =
  List.init idle ~f:(fun _ -> 1) @ List.concat_map frames ~f:(fun f -> frame_bits f @ flag)
  @ List.init 16 ~f:(fun _ -> 1)
;;

(* A receiver: hard-synchronises on the line's first falling edge, samples in the middle of each
   bit, finds flags (six 1s), removes stuffed 0s, and hands back each frame with its FCS check. *)
module Receiver = struct
  type got =
    { data : int list (* without the FCS *)
    ; fcs_ok : bool
    }

  type t =
    { bit_cycles : int
    ; mutable t0 : int option
    ; mutable ones : int
    ; mutable bits : int list (* kept bits since the last flag, newest first *)
    ; mutable in_frame : bool
    ; mutable frames : got list
    ; mutable last : int
    }

  let create ~bit_cycles =
    { bit_cycles; t0 = None; ones = 0; bits = []; in_frame = false; frames = []; last = 1 }
  ;;

  let bytes_of bits =
    let rec go acc = function
      | b0 :: b1 :: b2 :: b3 :: b4 :: b5 :: b6 :: b7 :: rest ->
        go
          ((b0 lor (b1 lsl 1) lor (b2 lsl 2) lor (b3 lsl 3) lor (b4 lsl 4) lor (b5 lsl 5)
            lor (b6 lsl 6) lor (b7 lsl 7))
           :: acc)
          rest
      | _ -> List.rev acc
    in
    go [] bits
  ;;

  let close t =
    (* the kept bits end with the flag's own 0 and five 1s *)
    let bits = List.rev t.bits in
    let n = List.length bits - 6 in
    if t.in_frame && n >= 24 && n % 8 = 0
    then (
      let bytes = bytes_of (List.take bits n) in
      let data = List.take bytes (List.length bytes - 2) in
      t.frames <- { data; fcs_ok = fcs16 bytes = 0xF0B8 } :: t.frames);
    t.bits <- [];
    t.in_frame <- true
  ;;

  let observe t ~cycle ~line =
    (match t.t0 with
     | None -> if line = 0 && t.last = 1 then t.t0 <- Some cycle
     | Some t0 ->
       if (cycle - t0) % t.bit_cycles = t.bit_cycles / 2
       then
         if line = 1
         then (
           t.ones <- t.ones + 1;
           if t.ones = 6 then close t else t.bits <- 1 :: t.bits)
         else (
           if t.ones = 5
           then () (* a stuffed 0 *)
           else if t.ones >= 6
           then () (* the 0 that ends a flag *)
           else t.bits <- 0 :: t.bits;
           t.ones <- 0));
    t.last <- line
  ;;
end
