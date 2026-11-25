(* LIN 2.2A (ISO 17987) on the bus: a single wire, dominant low, recessive high. A frame is a
   header from the commander (a break of 13 or more dominant bits, a delimiter of 1 or more
   recessive bits, the sync byte 0x55 and the protected identifier) and a response from one node
   (1 to 8 data bytes and a checksum). Bytes are 8N1, LSB first. Bit times are in cycles and can
   be fractional, so a node's clock can be off. *)
open! Core

let pid id =
  let b k = (id lsr k) land 1 in
  let p0 = b 0 lxor b 1 lxor b 2 lxor b 4
  and p1 = 1 lxor b 1 lxor b 3 lxor b 4 lxor b 5 in
  id land 0x3F lor (p0 lsl 6) lor (p1 lsl 7)
;;

(* the inverted 8-bit sum with carry: 255 is taken off whenever the sum passes 255. The enhanced
   checksum (LIN 2.x) counts the protected identifier too; the classic one (LIN 1.x, and the
   diagnostic frames 0x3C and 0x3D) only the data *)
let checksum ~classic ~pid data =
  List.fold (if classic then data else pid :: data) ~init:0 ~f:(fun s b ->
    let s = s + b in
    if s > 255 then s - 255 else s)
  |> lnot
  |> ( land ) 0xFF
;;

let byte_bits b = (0 :: List.init 8 ~f:(fun k -> (b lsr k) land 1)) @ [ 1 ]

let header ?(break_bits = 13) ?(pid_byte = None) id =
  List.init break_bits ~f:(fun _ -> 0)
  @ [ 1 ]
  @ byte_bits 0x55
  @ byte_bits (Option.value pid_byte ~default:(pid id))
;;

let response ?(bad_checksum = false) ~classic ~pid data =
  let c = checksum ~classic ~pid data in
  List.concat_map (data @ [ (if bad_checksum then c lxor 0x01 else c) ]) ~f:byte_bits
;;

(* a UART receiver on the bus at a node's own bit time: a falling edge starts a byte, each bit is
   sampled in its middle; a byte is (value, stop bit good) *)
module Rx = struct
  type t =
    { bit : float
    ; mutable last : int
    ; mutable start : int option
    ; mutable k : int (* the next bit to sample: 1 to 8 data, 9 the stop bit *)
    ; mutable value : int
    }

  let create ~bit = { bit; last = 1; start = None; k = 1; value = 0 }

  let step t ~cycle ~bus =
    let out =
      match t.start with
      | None ->
        if t.last = 1 && bus = 0
        then (
          t.start <- Some cycle;
          t.k <- 1;
          t.value <- 0);
        None
      | Some s ->
        if cycle - s = Float.iround_nearest_exn ((Float.of_int t.k +. 0.5) *. t.bit)
        then
          if t.k <= 8
          then (
            t.value <- t.value lor (bus lsl (t.k - 1));
            t.k <- t.k + 1;
            None)
          else (
            t.start <- None;
            Some (t.value, bus = 1))
        else None
    in
    t.last <- bus;
    out
  ;;
end

(* a responder written from the spec, at an exact clock: it answers a header from a table *)
type answer =
  | Publish of { data : int list; classic : bool; bad_checksum : bool }
  | Subscribe of { length : int; classic : bool }
  | Ignore

module Responder = struct
  type state =
    | Wait_break
    | Wait_sync
    | Wait_pid
    | Receiving of { pid : int; length : int; classic : bool; got : int list }
    | Sending of { from : int; bits : int array }

  type t =
    { rx : Rx.t
    ; bit : float
    ; table : int -> answer
    ; mutable state : state
    ; mutable frames : (int * int list * bool) list (* id, data, checksum good *)
    ; mutable sent : int
    }

  let create ~bit ~table = { rx = Rx.create ~bit; bit; table; state = Wait_break; frames = []; sent = 0 }

  let drive t ~cycle =
    match t.state with
    | Sending { from; bits } ->
      let k = Float.iround_down_exn (Float.of_int (cycle - from) /. t.bit) in
      if cycle < from then 1 else if k < Array.length bits then bits.(k) else 1
    | _ -> 1
  ;;

  let observe t ~cycle ~bus =
    (match t.state with
     | Sending { from; bits } ->
       let elapsed = Float.of_int (cycle - from) in
       if Float.(elapsed >= of_int (Array.length bits) * t.bit) then t.state <- Wait_break
     | _ -> ());
    match Rx.step t.rx ~cycle ~bus with
    | None -> ()
    | Some (v, stop_ok) ->
      (match t.state with
       | _ when v = 0 && not stop_ok -> t.state <- Wait_sync (* a break *)
       | Wait_break | Sending _ -> ()
       | Wait_sync -> t.state <- (if v = 0x55 && stop_ok then Wait_pid else Wait_break)
       | Wait_pid ->
         let id = v land 0x3F in
         if (not stop_ok) || pid id <> v
         then t.state <- Wait_break
         else (
           match t.table id with
           | Ignore -> t.state <- Wait_break
           | Subscribe { length; classic } -> t.state <- Receiving { pid = v; length; classic; got = [] }
           | Publish { data; classic; bad_checksum } ->
             (* the response starts one bit after the identifier's stop bit *)
             let from = cycle + Float.iround_nearest_exn (1.5 *. t.bit) in
             t.sent <- t.sent + 1;
             t.state
             <- Sending { from; bits = Array.of_list (response ~bad_checksum ~classic ~pid:v data) })
       | Receiving r ->
         if List.length r.got < r.length
         then t.state <- Receiving { r with got = r.got @ [ v ] }
         else (
           let good = stop_ok && checksum ~classic:r.classic ~pid:r.pid r.got = v in
           t.frames <- (r.pid land 0x3F, r.got, good) :: t.frames;
           t.state <- Wait_break))
  ;;
end
