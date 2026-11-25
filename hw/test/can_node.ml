(* The other end for the CAN firmware: a CAN 2.0A node written from the Bosch CAN 2.0
   specification (part A), not from the firmware.
   - Frame: start of frame (0), 11-bit identifier, RTR, IDE (0), r0 (0), 4-bit DLC, 0 to 8 data
     bytes (none for a remote frame), 15-bit CRC sequence, CRC delimiter (1), ACK slot, ACK
     delimiter (1), end of frame (seven 1s), then three 1s of intermission. All fields are sent
     most significant bit first.
   - CRC: x^15 + x^14 + x^10 + x^8 + x^7 + x^4 + x^3 + 1 (0x4599) over start of frame to the end
     of the data field, starting from 0.
   - Stuffing: from the start of frame to the end of the CRC sequence, after five equal bits the
     sender inserts one bit of the other value; inserted bits count toward the next run.
   - Dominant = 0. The bus is the wired AND of every node's output. A transmitter sends a
     recessive ACK slot and a receiver that got the frame right fills it with a dominant bit. *)

open! Core

let crc15 bits =
  List.fold bits ~init:0 ~f:(fun crc b ->
    let next = b lxor ((crc lsr 14) land 1) in
    let crc = (crc lsl 1) land 0x7fff in
    if next = 1 then crc lxor 0x4599 else crc)
;;

let msb_first v n = List.init n ~f:(fun k -> (v lsr (n - 1 - k)) land 1)

(* start of frame to the end of the CRC sequence, before stuffing. [flip] inverts one bit after
   the CRC has been computed, to make a frame whose CRC is wrong. *)
let unstuffed ?flip ~id ~rtr ~data () =
  let dlc = List.length data in
  let head = [ 0 ] @ msb_first id 11 @ [ Bool.to_int rtr; 0; 0 ] @ msb_first dlc 4 in
  let body = if rtr then [] else List.concat_map data ~f:(fun b -> msb_first b 8) in
  let bits = head @ body in
  let bits = bits @ msb_first (crc15 bits) 15 in
  match flip with
  | None -> bits
  | Some k -> List.mapi bits ~f:(fun i b -> if i = k then 1 - b else b)
;;

let stuff bits =
  let out = ref []
  and last = ref (-1)
  and run = ref 0 in
  let emit b =
    out := b :: !out;
    if b = !last
    then incr run
    else (
      last := b;
      run := 1)
  in
  List.iter bits ~f:(fun b ->
    emit b;
    if !run = 5 then emit (1 - b));
  List.rev !out
;;

type frame =
  { id : int
  ; rtr : bool
  ; data : int list
  ; flip : int option (* corrupt this bit (index from the start of frame) after the CRC *)
  }

type t =
  { bit_cycles : int
  ; wire : int array (* what this node sends, bit by bit, from the start of frame *)
  ; ack_slot : int (* bit index of the ACK slot *)
  ; stuffed_bits : int
  ; mutable ack_seen : bool
  ; mutable bit_errors : int (* recessive sent, dominant read, outside the ACK slot *)
  }

let create ~bit_cycles f =
  let raw = unstuffed ?flip:f.flip ~id:f.id ~rtr:f.rtr ~data:f.data () in
  let stuffed = stuff raw in
  let wire = Array.of_list (stuffed @ [ 1; 1; 1 ] @ List.init 7 ~f:(fun _ -> 1) @ [ 1; 1; 1 ]) in
  { bit_cycles
  ; wire
  ; ack_slot = List.length stuffed + 1
  ; stuffed_bits = List.length stuffed - List.length raw
  ; ack_seen = false
  ; bit_errors = 0
  }
;;

let cycles t = Array.length t.wire * t.bit_cycles

(* What the node drives [cycle] cycles after its start of frame (1 = recessive, also after the
   frame). [bus] is the bus level in that cycle; the node samples it at 70% of each bit. *)
let drive t ~cycle =
  let k = cycle / t.bit_cycles in
  if k >= 0 && k < Array.length t.wire then t.wire.(k) else 1
;;

let observe t ~cycle ~bus =
  let k = cycle / t.bit_cycles
  and phase = cycle % t.bit_cycles in
  if k >= 0 && k < Array.length t.wire && phase = t.bit_cycles * 7 / 10
  then
    if k = t.ack_slot
    then (if bus = 0 then t.ack_seen <- true)
    else if t.wire.(k) = 1 && bus = 0
    then t.bit_errors <- t.bit_errors + 1
;;
