(* Wiegand (access control), written from the interface's description: two lines, D0 and D1,
   pulled high; a 0 is a low pulse on D0, a 1 on D1; pulses 20 to 100 us wide, 200 us to 20 ms
   apart. The 26-bit format (H10301): an even parity bit over the next 12 bits, facility code
   (8 bits), card number (16 bits), an odd parity bit over the 12 bits before it. The 34-bit
   format: the same with a 16-bit facility code and parity over 16 bits each. *)
open! Core

let parity bits = List.count bits ~f:(fun b -> b = 1) % 2

(* the bits of a card, first sent first *)
let card ~bits:n ~facility ~number =
  let m = n - 2 in
  let data = (facility lsl 16) lor number in
  let d = List.init m ~f:(fun k -> (data lsr (m - 1 - k)) land 1) in
  let first = List.take d (m / 2)
  and second = List.drop d (m / 2) in
  (parity first :: d) @ [ 1 - parity second ]
;;

(* what a reader puts on the lines: (d0, d1) per cycle. [glitch] adds a short low on D0 that
   far into the message (in cycles from its start) *)
let lines ~width ~period ?(lead = 2000) ?(gap = 100_000) ?glitch messages =
  let total = lead + List.sum (module Int) messages ~f:(fun m -> (List.length m * period) + gap) in
  let d0 = Array.create ~len:total 1
  and d1 = Array.create ~len:total 1 in
  let at = ref lead in
  List.iter messages ~f:(fun bits ->
    let start = !at in
    List.iteri bits ~f:(fun k b ->
      let line = if b = 1 then d1 else d0 in
      for c = start + (k * period) to start + (k * period) + width - 1 do
        line.(c) <- 0
      done);
    Option.iter glitch ~f:(fun (g, len) ->
      for c = start + g to start + g + len - 1 do
        d0.(c) <- 0
      done);
    at := start + (List.length bits * period) + gap);
  d0, d1
;;

(* reading the lines: each low pulse is a bit; a message ends after [silence] cycles with no
   pulse. Returns the messages with the widths and the start-to-start times of their pulses *)
let read ~d0 ~d1 ~silence =
  let n = Array.length d0 in
  let messages = ref []
  and cur = ref []
  and last = ref (-1_000_000) in
  let finish () =
    if not (List.is_empty !cur) then messages := List.rev !cur :: !messages;
    cur := []
  in
  let i = ref 1 in
  while !i < n do
    let fall line = line.(!i) = 0 && line.(!i - 1) = 1 in
    if fall d0 || fall d1
    then (
      if !i - !last > silence then finish ();
      let line, b = if fall d1 then d1, 1 else d0, 0 in
      let j = ref !i in
      while !j < n && line.(!j) = 0 do
        incr j
      done;
      cur := (b, !j - !i, !i - !last) :: !cur;
      last := !i;
      i := !j)
    else incr i
  done;
  finish ();
  List.rev !messages
;;

(* a message's bits as a card number, if it is one of the two formats and the parity is right *)
let to_string bits =
  let n = List.length bits in
  let value l = List.fold l ~init:0 ~f:(fun a b -> (a lsl 1) lor b) in
  if n = 26 || n = 34
  then (
    let d = List.sub bits ~pos:1 ~len:(n - 2) in
    let m = n - 2 in
    let ok =
      parity (List.take bits (1 + (m / 2))) = 0 && parity (List.drop bits (1 + (m / 2))) = 1
    in
    let v = value d in
    sprintf "%d bits: facility %d, card %d, parity %s" n (v lsr 16) (v land 0xFFFF)
      (if ok then "good" else "BAD"))
  else sprintf "%d bits: %s" n (String.concat (List.map bits ~f:Int.to_string))
;;
