(* A Serial Wire Debug target written from the ARM Debug Interface spec (ADIv5.2): a SW-DP and
   one MEM-AP.

   The wire in slots: the host drives SWCLK; in each slot SWCLK is low, then high. Whoever drives
   a slot sets SWDIO before the rising edge (the host right after the falling edge, the target
   right after the rising edge that ends the slot before); the other side reads it at the rising
   edge. A read:  request (8, host), turnaround, ACK (3, target), data (32) and parity (target),
   turnaround. A write: request, turnaround, ACK, turnaround, data and parity (host).
   Request bits, first first: start (1), APnDP, RnW, A[2], A[3], parity of those four, stop (0),
   park (1). ACK, first first: OK = 1 0 0, WAIT = 0 1 0, FAULT = 0 0 1; no answer reads 1 1 1.
   A line reset is 50 or more slots of 1. The target starts locked out, and goes back to that
   after a request it cannot answer; it then answers nothing until a line reset and a DPIDR read. The AP's reads are posted: each AP read returns the value of the previous one, and
   RDBUFF holds the last. *)
open! Core

let parity v = Int.popcount v land 1

type phase =
  | Idle
  | Request of int * int (* bits so far, value *)
  | Ack_then_read of { slot : int; value : int }
  | Ack_then_write of { slot : int; reg : int * int } (* APnDP, A[3:2] *)
  | Write_turn of { reg : int * int }
  | Write_data of { got : int; value : int; reg : int * int }
  | Turnaround (* the slot after a read: nobody drives, nothing is read *)

type t =
  { dpidr : int
  ; ap_idr : int
  ; memory : (int, int) Hashtbl.t
  ; mutable ctrl_stat : int
  ; mutable select : int
  ; mutable csw : int
  ; mutable tar : int
  ; mutable rdbuff : int
  ; mutable reset_ones : int
  ; mutable after_reset : bool (* waiting for the DPIDR read *)
  ; mutable phase : phase
  ; mutable drive : int option (* what the target puts on SWDIO for the next slot *)
  ; mutable clk : int
  ; mutable log : string list
  }

let create ~dpidr ~ap_idr ~memory =
  { dpidr
  ; ap_idr
  ; memory = Hashtbl.of_alist_exn (module Int) memory
  ; ctrl_stat = 0
  ; select = 0
  ; csw = 0
  ; tar = 0
  ; rdbuff = 0
  ; reset_ones = 0
  ; after_reset = true (* a SW-DP starts locked out: it needs a line reset and a DPIDR read *)
  ; phase = Idle
  ; drive = None
  ; clk = 0
  ; log = []
  }
;;

let note t s = t.log <- s :: t.log

(* CTRL/STAT: the power-up requests (bits 30 and 28) are acknowledged in bits 31 and 29 *)
let write_ctrl_stat t v =
  let req = v land 0x5000_0000 in
  t.ctrl_stat <- req lor (req lsl 1)
;;

let ap_read t reg =
  let bank = (t.select lsr 4) land 0xF in
  match bank, reg with
  | 0xF, 3 -> t.ap_idr
  | 0, 0 -> t.csw
  | 0, 1 -> t.tar
  | 0, 3 ->
    let v = Option.value (Hashtbl.find t.memory t.tar) ~default:0 in
    if (t.csw lsr 4) land 3 = 1 then t.tar <- t.tar + 4;
    v
  | _ -> 0
;;

let ap_write t reg v =
  let bank = (t.select lsr 4) land 0xF in
  match bank, reg with
  | 0, 0 -> t.csw <- v
  | 0, 1 -> t.tar <- v
  | 0, 3 ->
    Hashtbl.set t.memory ~key:t.tar ~data:v;
    if (t.csw lsr 4) land 3 = 1 then t.tar <- t.tar + 4
  | _ -> ()
;;

(* a request has come in: the value to send for a read *)
let read_value t ~ap ~reg =
  if ap = 1
  then (
    let previous = t.rdbuff in
    t.rdbuff <- ap_read t reg;
    previous)
  else (
    match reg with
    | 0 -> t.dpidr
    | 1 -> t.ctrl_stat
    | 3 -> t.rdbuff
    | _ -> 0)
;;

let write_reg t ~ap ~reg v =
  if ap = 1
  then ap_write t reg v
  else (
    match reg with
    | 0 -> () (* ABORT *)
    | 1 -> write_ctrl_stat t v
    | 2 -> t.select <- v
    | _ -> ())
;;

(* the bits the target sends for a read, slot by slot after the turnaround: ACK OK, 32 data bits,
   parity *)
let read_bits value = [ 1; 0; 0 ] @ List.init 32 ~f:(fun k -> (value lsr k) land 1) @ [ parity value ]

(* one SWCLK rising edge, with SWDIO as it was just before it *)
let rise t ~swdio =
  t.reset_ones <- (if swdio = 1 then t.reset_ones + 1 else 0);
  if t.reset_ones = 50
  then (
    t.after_reset <- true;
    note t "line reset");
  if t.reset_ones >= 50
  then (
    t.phase <- Idle;
    t.drive <- None)
  else (
    match t.phase with
    | Idle -> if swdio = 1 then t.phase <- Request (1, 1)
    | Request (n, v) ->
      let v = v lor (swdio lsl n) in
      if n + 1 < 8
      then t.phase <- Request (n + 1, v)
      else (
        let ap = (v lsr 1) land 1
        and rnw = (v lsr 2) land 1
        and reg = (v lsr 3) land 3 in
        let ok =
          v land 1 = 1
          && (v lsr 6) land 1 = 0
          && (v lsr 7) land 1 = 1
          && parity ((v lsr 1) land 0xF) = (v lsr 5) land 1
        in
        let allowed = (not t.after_reset) || (ap = 0 && rnw = 1 && reg = 0) in
        if not (ok && allowed)
        then (
          (* while it waits for the DPIDR read, the target ignores everything (the JTAG-to-SWD
             sequence comes through here) *)
          if not t.after_reset then note t (sprintf "request %02x not answered" v);
          (* a protocol error: no answer until the next line reset and DPIDR read *)
          t.after_reset <- true;
          t.phase <- Idle)
        else (
          if ap = 0 && rnw = 1 && reg = 0 then t.after_reset <- false;
          note t (sprintf "%s %s %d" (if ap = 1 then "AP" else "DP") (if rnw = 1 then "read" else "write") reg);
          if rnw = 1
          then t.phase <- Ack_then_read { slot = 0; value = read_value t ~ap ~reg }
          else t.phase <- Ack_then_write { slot = 0; reg = ap, reg }))
    | Ack_then_read { slot; value } ->
      (* slot 0 was the turnaround; drive bit [slot] of the reply for the next slot *)
      let bits = read_bits value in
      if slot < List.length bits
      then (
        t.drive <- Some (List.nth_exn bits slot);
        t.phase <- Ack_then_read { slot = slot + 1; value })
      else (
        t.drive <- None;
        t.phase <- Turnaround)
    | Turnaround -> t.phase <- Idle
    | Ack_then_write { slot; reg } ->
      if slot < 3
      then (
        t.drive <- Some (List.nth_exn [ 1; 0; 0 ] slot);
        t.phase <- Ack_then_write { slot = slot + 1; reg })
      else (
        (* the turnaround back to the host *)
        t.drive <- None;
        t.phase <- Write_turn { reg })
    | Write_turn { reg } -> t.phase <- Write_data { got = 0; value = 0; reg }
    | Write_data { got; value; reg } ->
      if got < 32
      then t.phase <- Write_data { got = got + 1; value = value lor (swdio lsl got); reg }
      else (
        if parity value = swdio
        then (
          let ap, r = reg in
          write_reg t ~ap ~reg:r value)
        else note t "write parity wrong: ignored";
        t.phase <- Idle))
;;

let step t ~swclk ~swdio =
  if swclk = 1 && t.clk = 0 then rise t ~swdio;
  t.clk <- swclk
;;
