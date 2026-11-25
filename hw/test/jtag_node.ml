(* JTAG (IEEE 1149.1) written from the standard: the 16-state TAP controller, a TAP with a 4-bit
   IR (captures 0001), IDCODE (0001, 32 bits), USER (1000, 16 bits) and BYPASS (anything else),
   a chain of TAPs, and a controller that clocks a list of (TMS, TDI) bits at a given TCK. *)
open! Core

type state =
  | Tlr
  | Rti
  | Sel_dr
  | Cap_dr
  | Sh_dr
  | Ex1_dr
  | Pause_dr
  | Ex2_dr
  | Upd_dr
  | Sel_ir
  | Cap_ir
  | Sh_ir
  | Ex1_ir
  | Pause_ir
  | Ex2_ir
  | Upd_ir
[@@deriving sexp_of, equal]

let next s tms =
  match s, tms with
  | Tlr, 1 -> Tlr
  | Tlr, _ -> Rti
  | Rti, 1 -> Sel_dr
  | Rti, _ -> Rti
  | Sel_dr, 1 -> Sel_ir
  | Sel_dr, _ -> Cap_dr
  | Cap_dr, 1 -> Ex1_dr
  | Cap_dr, _ -> Sh_dr
  | Sh_dr, 1 -> Ex1_dr
  | Sh_dr, _ -> Sh_dr
  | Ex1_dr, 1 -> Upd_dr
  | Ex1_dr, _ -> Pause_dr
  | Pause_dr, 1 -> Ex2_dr
  | Pause_dr, _ -> Pause_dr
  | Ex2_dr, 1 -> Upd_dr
  | Ex2_dr, _ -> Sh_dr
  | Upd_dr, 1 -> Sel_dr
  | Upd_dr, _ -> Rti
  | Sel_ir, 1 -> Tlr
  | Sel_ir, _ -> Cap_ir
  | Cap_ir, 1 -> Ex1_ir
  | Cap_ir, _ -> Sh_ir
  | Sh_ir, 1 -> Ex1_ir
  | Sh_ir, _ -> Sh_ir
  | Ex1_ir, 1 -> Upd_ir
  | Ex1_ir, _ -> Pause_ir
  | Pause_ir, 1 -> Ex2_ir
  | Pause_ir, _ -> Pause_ir
  | Ex2_ir, 1 -> Upd_ir
  | Ex2_ir, _ -> Sh_ir
  | Upd_ir, 1 -> Sel_dr
  | Upd_ir, _ -> Rti
;;

let idcode_ir = 0b0001
let user_ir = 0b1000

module Tap = struct
  type t =
    { idcode : int
    ; mutable state : state
    ; mutable ir : int
    ; mutable ir_sh : int
    ; mutable dr_sh : int
    ; mutable dr_len : int
    ; mutable user : int
    ; mutable tdo : int option (* None: released *)
    ; mutable updates : int list (* USER values written, newest first *)
    }

  let create ~idcode ~user =
    { idcode; state = Tlr; ir = idcode_ir; ir_sh = 0; dr_sh = 0; dr_len = 1; user; tdo = None; updates = [] }
  ;;

  (* the rising edge: the current state's action, then the next state *)
  let rise t ~tms ~tdi =
    (match t.state with
     | Cap_dr ->
       let v, len =
         if t.ir = idcode_ir then t.idcode, 32 else if t.ir = user_ir then t.user, 16 else 0, 1
       in
       t.dr_sh <- v;
       t.dr_len <- len
     | Sh_dr -> t.dr_sh <- (t.dr_sh lsr 1) lor (tdi lsl (t.dr_len - 1))
     | Cap_ir -> t.ir_sh <- 0b0001
     | Sh_ir -> t.ir_sh <- (t.ir_sh lsr 1) lor (tdi lsl 3)
     | _ -> ());
    t.state <- next t.state tms;
    if equal_state t.state Tlr then t.ir <- idcode_ir
  ;;

  (* the falling edge: updates, and TDO *)
  let fall t =
    (match t.state with
     | Upd_dr when t.ir = user_ir ->
       t.user <- t.dr_sh land 0xFFFF;
       t.updates <- t.user :: t.updates
     | Upd_ir -> t.ir <- t.ir_sh
     | _ -> ());
    t.tdo
    <- (match t.state with
        | Sh_dr -> Some (t.dr_sh land 1)
        | Sh_ir -> Some (t.ir_sh land 1)
        | _ -> None)
  ;;
end

(* TAPs in a chain: TDI goes into the first, each TDO into the next, the last one's TDO out *)
module Chain = struct
  type t =
    { taps : Tap.t array
    ; mutable tck : int
    }

  let create taps = { taps = Array.of_list taps; tck = 0 }

  let tdo t =
    match (Array.last_exn t.taps).tdo with
    | Some b -> b
    | None -> 1 (* a pull-up *)
  ;;

  let step t ~tck ~tms ~tdi =
    if tck = 1 && t.tck = 0
    then (
      let ins =
        Array.mapi t.taps ~f:(fun i _ ->
          if i = 0 then tdi else Option.value t.taps.(i - 1).tdo ~default:1)
      in
      Array.iteri t.taps ~f:(fun i tap -> Tap.rise tap ~tms ~tdi:ins.(i)));
    if tck = 0 && t.tck = 1 then Array.iter t.taps ~f:Tap.fall;
    t.tck <- tck
  ;;
end

(* a controller: TCK low for [half] cycles then high for [half]; TMS and TDI change as TCK falls,
   TDO is read as TCK rises *)
module Controller = struct
  type t =
    { half : int
    ; bits : (int * int) array (* TMS, TDI *)
    ; tdo : int array
    }

  let create ~half bits = { half; bits = Array.of_list bits; tdo = Array.create ~len:(List.length bits) 0 }
  let cycles t = (2 * t.half * Array.length t.bits) + t.half

  (* the levels at a cycle: (tck, tms, tdi); TDO read at each rising edge through [tdo] *)
  let levels t ~cycle =
    let k = cycle / (2 * t.half) in
    if k >= Array.length t.bits
    then 0, 1, 0
    else (
      let tms, tdi = t.bits.(k) in
      (if cycle mod (2 * t.half) >= t.half then 1 else 0), tms, tdi)
  ;;

  let read_tdo t ~cycle ~tdo =
    let k = cycle / (2 * t.half) in
    if k < Array.length t.bits && cycle mod (2 * t.half) = t.half then t.tdo.(k) <- tdo
  ;;
end

(* bit lists for the usual moves; TMS first, TDI 0 *)
let tms l = List.map l ~f:(fun m -> m, 0)
let reset = tms [ 1; 1; 1; 1; 1; 0 ] (* to Test-Logic-Reset, then Run-Test/Idle *)
let to_shift_dr = tms [ 1; 0; 0 ]
let to_shift_ir = tms [ 1; 1; 0; 0 ]
let to_idle = tms [ 1; 0 ] (* from Exit1: Update, then Run-Test/Idle *)

(* shift n bits of [v], TMS 1 on the last *)
let shift ~n v = List.init n ~f:(fun k -> (if k = n - 1 then 1 else 0), (v lsr k) land 1)

(* the TDO bits at positions [from, from + n) as a number, first bit in bit 0 *)
let value tdo ~from ~n =
  List.fold (List.init n ~f:Fn.id) ~init:0 ~f:(fun a k -> a lor (tdo.(from + k) lsl k))
;;
