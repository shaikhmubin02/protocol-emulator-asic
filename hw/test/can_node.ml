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

(* A receiving node, also from the specification: it hard-synchronises on the start-of-frame
   edge, samples each bit at 70%, removes stuff bits (and counts a missing one as a stuff
   error), reads the fields, checks the CRC, and drives the ACK slot dominant when the CRC is
   good. It also measures every bus edge against the 100-cycle grid that starts at the start of
   frame, so a transmitter whose edges wander is caught. *)
module Receiver = struct
  type got =
    { id : int
    ; rtr : bool
    ; data : int list
    ; crc_ok : bool
    ; stuff_errors : int
    }

  type t =
    { bit_cycles : int
    ; mutable in_frame : bool
    ; mutable idle_run : int (* cycles the bus has been recessive *)
    ; mutable need_idle : int (* bits of recessive bus before a start of frame counts *)
    ; mutable t0 : int (* cycle of the start-of-frame edge *)
    ; mutable bits : int list (* de-stuffed, newest first *)
    ; mutable run_value : int
    ; mutable run : int
    ; mutable stuffed_done : bool
    ; mutable stuff_errors : int
    ; mutable after : int (* bits sampled after the stuffed part *)
    ; mutable ack_from : int
    ; mutable crc_ok : bool
    ; mutable last_bus : int
    ; mutable max_edge_error : int
    ; mutable frames : got list
    }

  let create ~bit_cycles =
    { bit_cycles
    ; in_frame = false
    ; idle_run = 0
    ; need_idle = 11 (* joining the bus: 11 recessive bits *)
    ; t0 = 0
    ; bits = []
    ; run_value = -1
    ; run = 0
    ; stuffed_done = false
    ; stuff_errors = 0
    ; after = 0
    ; ack_from = -1
    ; crc_ok = false
    ; last_bus = 1
    ; max_edge_error = 0
    ; frames = []
    }
  ;;

  let to_int bits = List.fold bits ~init:0 ~f:(fun a b -> (a lsl 1) lor b)

  (* de-stuffed length of the whole stuffed part, once the control field is in *)
  let stuffed_length bits =
    let b = List.rev bits in
    if List.length b < 19
    then None
    else (
      let rtr = List.nth_exn b 12 = 1 in
      let dlc = to_int (List.sub b ~pos:15 ~len:4) in
      Some (19 + (if rtr then 0 else 8 * Int.min dlc 8) + 15))
  ;;

  let finish t =
    let b = List.rev t.bits in
    let rtr = List.nth_exn b 12 = 1 in
    let dlc = to_int (List.sub b ~pos:15 ~len:4) in
    let n = if rtr then 0 else Int.min dlc 8 in
    let data = List.init n ~f:(fun k -> to_int (List.sub b ~pos:(19 + (8 * k)) ~len:8)) in
    { id = to_int (List.sub b ~pos:1 ~len:11)
    ; rtr
    ; data
    ; crc_ok = t.crc_ok
    ; stuff_errors = t.stuff_errors
    }
  ;;

  (* the ACK this node drives in [cycle] (1 = recessive) *)
  let drive t ~cycle =
    if t.ack_from >= 0 && cycle >= t.ack_from && cycle < t.ack_from + t.bit_cycles then 0 else 1
  ;;

  let observe t ~cycle ~bus =
    if not t.in_frame
    then (
      if bus = 0 && t.last_bus = 1 && t.idle_run >= t.need_idle * t.bit_cycles
      then (
        t.in_frame <- true;
        t.t0 <- cycle;
        t.bits <- [];
        t.run_value <- -1;
        t.run <- 0;
        t.stuffed_done <- false;
        t.stuff_errors <- 0;
        t.after <- 0;
        t.ack_from <- -1;
        t.crc_ok <- false);
      t.idle_run <- (if bus = 1 then t.idle_run + 1 else 0))
    else (
      let rel = cycle - t.t0 in
      (* edges driven by others than this node: how far from the grid *)
      if bus <> t.last_bus && not (t.ack_from >= 0 && (cycle = t.ack_from || cycle = t.ack_from + t.bit_cycles))
      then (
        let off = rel % t.bit_cycles in
        let err = Int.min off (t.bit_cycles - off) in
        t.max_edge_error <- Int.max t.max_edge_error err);
      if rel % t.bit_cycles = t.bit_cycles * 7 / 10
      then
        if not t.stuffed_done
        then (
          if t.run = 5
          then (
            (* a stuff bit: must be the other value *)
            if bus = t.run_value then t.stuff_errors <- t.stuff_errors + 1;
            t.run_value <- bus;
            t.run <- 1)
          else (
            t.bits <- bus :: t.bits;
            if bus = t.run_value
            then t.run <- t.run + 1
            else (
              t.run_value <- bus;
              t.run <- 1));
          match stuffed_length t.bits with
          | Some n when List.length t.bits = n && t.run < 5 ->
            t.stuffed_done <- true;
            let b = List.rev t.bits in
            let body = List.take b (n - 15) and crc = to_int (List.drop b (n - 15)) in
            t.crc_ok <- crc15 body = crc
          | _ -> ())
        else (
          t.after <- t.after + 1;
          (* 1: CRC delimiter, 2: ACK slot, 3: ACK delimiter, 4..10: end of frame *)
          if t.after = 1 && t.crc_ok
          then t.ack_from <- t.t0 + ((rel / t.bit_cycles) + 1) * t.bit_cycles;
          if t.after = 10
          then (
            t.frames <- finish t :: t.frames;
            t.in_frame <- false;
            (* between frames only the intermission (3 recessive bits) is needed *)
            t.need_idle <- 3;
            t.idle_run <- 0)));
    t.last_bus <- bus
  ;;
end

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
