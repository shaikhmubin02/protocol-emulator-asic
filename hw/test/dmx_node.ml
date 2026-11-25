(* DMX512 (ANSI E1.11) as the line sees it, in cycles at 50 MHz: a bit is 4 us, 200 cycles. A
   packet is a break (low), a mark after break (high), then slots: a start bit (0), 8 data bits
   LSB first, two stop bits (1). The first slot is the start code (0 for dimmer data). *)
open! Core

let us = 50
let bit = 4 * us

type packet =
  { break_us : int
  ; mab_us : int
  ; slots : int list (* the start code first *)
  ; gap_us : int (* mark between slots *)
  ; bad_stop : int option (* this slot's second stop bit goes out low *)
  ; mbb_us : int (* mark after the packet, before the next break *)
  }

let packet ?(break_us = 176) ?(mab_us = 12) ?(gap_us = 0) ?bad_stop ?(mbb_us = 20) slots =
  { break_us; mab_us; slots; gap_us; bad_stop; mbb_us }
;;

(* the line, one level per cycle, after [lead_us] of mark *)
let line ?(lead_us = 20) packets =
  let runs =
    (1, lead_us * us)
    :: List.concat_map packets ~f:(fun p ->
      let slot i b =
        ((0, bit) :: List.init 8 ~f:(fun k -> (b lsr k) land 1, bit))
        @ [ 1, bit; (if Option.equal Int.equal p.bad_stop (Some i) then 0 else 1), bit ]
        @ if i < List.length p.slots - 1 && p.gap_us > 0 then [ 1, p.gap_us * us ] else []
      in
      [ 0, p.break_us * us; 1, p.mab_us * us ]
      @ List.concat (List.mapi p.slots ~f:slot)
      @ [ 1, p.mbb_us * us ])
  in
  Array.concat (List.map runs ~f:(fun (level, n) -> Array.create ~len:n level))
;;

type seen =
  { brk : int (* cycles *)
  ; mab : int
  ; got : int list
  ; framing : int list (* slots with a start or stop bit wrong *)
  ; period : int (* the longest time from one slot's start to the next one's *)
  ; last : int (* where the last slot started *)
  }

(* read a line as an E1.11 receiver: a low of 88 us or more is a break, the high after it the
   MAB, then a slot at each falling edge, sampled in the middle of each bit. Also returns the
   largest distance of any edge from the bit grid that starts at the first break. *)
let read samples =
  let n = Array.length samples in
  let run_from i =
    let rec go j = if j < n && samples.(j) = samples.(i) then go (j + 1) else j in
    go i - i
  in
  let falling i = i > 0 && i < n && samples.(i) = 0 && samples.(i - 1) = 1 in
  let rec next_fall i = if i >= n then None else if falling i then Some i else next_fall (i + 1) in
  let packets = ref []
  and cur = ref None in
  let finish () = Option.iter !cur ~f:(fun p -> packets := p :: !packets) in
  let rec go i =
    match next_fall i with
    | None -> finish ()
    | Some e ->
      let low = run_from e in
      if low >= 88 * us
      then (
        finish ();
        let mab = run_from (e + low) in
        cur := Some { brk = low; mab; got = []; framing = []; period = 0; last = -1 };
        go (e + low + mab))
      else (
        match !cur with
        | None -> go (e + 1)
        | Some p ->
          let at k = samples.(Int.min (n - 1) (e + (bit / 2) + (k * bit))) in
          let byte = List.fold (List.init 8 ~f:Fn.id) ~init:0 ~f:(fun a k -> a lor (at (k + 1) lsl k)) in
          let ok = at 0 = 0 && at 9 = 1 && at 10 = 1 in
          let index = List.length p.got in
          cur
          := Some
               { p with
                 got = p.got @ [ byte ]
               ; framing = (if ok then p.framing else p.framing @ [ index ])
               ; period = (if p.last < 0 then 0 else Int.max p.period (e - p.last))
               ; last = e
               };
          go (e + (10 * bit) + (bit / 2)))
  in
  go 0;
  let first_break = Option.value (next_fall 0) ~default:0 in
  let worst = ref 0 in
  for i = first_break to n - 1 do
    if i > 0 && samples.(i) <> samples.(i - 1)
    then (
      let d = (i - first_break) mod bit in
      worst := Int.max !worst (Int.min d (bit - d)))
  done;
  List.rev !packets, !worst
;;
