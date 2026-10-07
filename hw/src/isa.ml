(* Engine instruction set: the instruction type, its 16-bit encoding and a printer.
   Encoding tables follow the ISA spec; [decode] rejects words with non-zero unused fields. *)

open! Core

type alu =
  | Mov
  | Add
  | Sub
  | And
  | Or
  | Xor
  | Cmp
  | Tst
[@@deriving sexp, compare, equal, enumerate]

type alui =
  | Addi
  | Subi
  | Cmpi
  | Shli
  | Shri
  | Rlc
  | Rrc
  | Tstb
[@@deriving sexp, compare, equal, enumerate]

type cond =
  | Always
  | Z
  | Nz
  | C
  | Nc
  | T
  | Nt
  | Jpin_hi
  | Jpin_lo
  | Rx_ready
  | Tx_empty
  | Mbx_data
  | Jflag_set
  | Jflag_clr
  | Fab_flag
[@@deriving sexp, compare, equal, enumerate]

type pin_action =
  | Clr
  | Set
  | Tgl
  | Hiz
  | Drive_c
  | Drive_not_c
  | Sample
[@@deriving sexp, compare, equal, enumerate]

type event =
  | Ev_tx_empty
  | Ev_rx_ready
  | Ev_tick
  | Ev_capture
  | Ev_mailbox
[@@deriving sexp, compare, equal, enumerate]

type wait =
  | Wait_pin of int * bool
  | Wait_flag of int * bool
  | Wait_time of int
  | Wait_event of event
[@@deriving sexp, compare, equal]

(* Registers are 0..7, pins 0..31, flags 0..7, CSRs 0..63, targets 0..255. *)
type t =
  | Nop
  | Halt
  | Ret
  | Push of int
  | Pull of int
  | Sig of int
  | Clrf of int
  | Tx of int
  | Rx of int
  | Crci
  | Ben of bool
  | Ldi of int * int
  | Ldih of int * int
  | Alu of alu * int * int
  | Alui of alui * int * int
  | J of cond * int
  | Djnz of int * int
  | Call of int
  | Pin of pin_action * int * int
  | Outg of int * int * int
  | Inp of int * int
  | Wait of wait
  | Dly of int
  | Csrr of int * int
  | Csrw of int * int
  | Csrwi of int * int
[@@deriving sexp, compare, equal]

let index_of ~all x ~equal =
  List.findi_exn all ~f:(fun _ y -> equal x y) |> fst
;;

let nth_opt all i = List.nth all i

(* field helpers *)
let field w ~hi ~lo = (w lsr lo) land ((1 lsl (hi - lo + 1)) - 1)
let put v ~hi ~lo = (v land ((1 lsl (hi - lo + 1)) - 1)) lsl lo
let op o = put o ~hi:15 ~lo:12

let check name v ~max =
  if v < 0 || v > max then raise_s [%message "operand out of range" name (v : int) (max : int)]
;;

let encode_exn (i : t) =
  let reg name r = check name r ~max:7 in
  let sys sub low = op 0 lor put sub ~hi:11 ~lo:8 lor low in
  match i with
  | Nop -> sys 0 0
  | Halt -> sys 1 0
  | Ret -> sys 2 0
  | Push r ->
    reg "rs" r;
    sys 3 r
  | Pull r ->
    reg "rd" r;
    sys 4 r
  | Sig f ->
    check "flag" f ~max:7;
    sys 5 f
  | Clrf f ->
    check "flag" f ~max:7;
    sys 6 f
  | Tx r ->
    reg "rs" r;
    sys 7 r
  | Rx r ->
    reg "rd" r;
    sys 8 r
  | Crci -> sys 9 0
  | Ben on -> sys 10 (if on then 1 else 0)
  | Ldi (rd, imm) | Ldih (rd, imm) ->
    reg "rd" rd;
    check "imm8" imm ~max:255;
    let h =
      match i with
      | Ldih _ -> 1
      | _ -> 0
    in
    op 1 lor put rd ~hi:11 ~lo:9 lor put h ~hi:8 ~lo:8 lor imm
  | Alu (fn, rd, rs) ->
    reg "rd" rd;
    reg "rs" rs;
    op 2
    lor put rd ~hi:11 ~lo:9
    lor put rs ~hi:8 ~lo:6
    lor put (index_of ~all:all_of_alu fn ~equal:equal_alu) ~hi:5 ~lo:3
  | Alui (fn, rd, imm) ->
    reg "rd" rd;
    check "imm6" imm ~max:63;
    op 3
    lor put rd ~hi:11 ~lo:9
    lor put (index_of ~all:all_of_alui fn ~equal:equal_alui) ~hi:8 ~lo:6
    lor imm
  | J (cc, t) ->
    check "target" t ~max:255;
    op 4 lor put (index_of ~all:all_of_cond cc ~equal:equal_cond) ~hi:11 ~lo:8 lor t
  | Djnz (rd, t) ->
    reg "rd" rd;
    check "target" t ~max:255;
    op 5 lor put rd ~hi:11 ~lo:9 lor t
  | Call t ->
    check "target" t ~max:255;
    op 6 lor t
  | Pin (act, p, d) ->
    check "pin" p ~max:31;
    check "delay" d ~max:7;
    let opf, mode =
      match act with
      | Clr -> 0, 0
      | Set -> 1, 0
      | Tgl -> 2, 0
      | Hiz -> 3, 0
      | Drive_c -> 0, 1
      | Drive_not_c -> 0, 2
      | Sample -> 0, 3
    in
    op 7 lor put opf ~hi:11 ~lo:10 lor put p ~hi:9 ~lo:5 lor put mode ~hi:4 ~lo:3 lor d
  | Outg (g, rs, d) ->
    check "group" g ~max:3;
    reg "rs" rs;
    check "delay" d ~max:7;
    op 8 lor put rs ~hi:11 ~lo:9 lor put g ~hi:8 ~lo:7 lor d
  | Inp (rd, g) ->
    reg "rd" rd;
    check "group" g ~max:3;
    op 9 lor put rd ~hi:11 ~lo:9 lor put g ~hi:8 ~lo:7
  | Wait w ->
    (match w with
     | Wait_pin (p, v) ->
       check "pin" p ~max:31;
       op 10 lor put 0 ~hi:11 ~lo:10 lor put p ~hi:9 ~lo:5 lor put (Bool.to_int v) ~hi:4 ~lo:4
     | Wait_flag (f, v) ->
       check "flag" f ~max:7;
       op 10 lor put 1 ~hi:11 ~lo:10 lor put (Bool.to_int v) ~hi:3 ~lo:3 lor f
     | Wait_time rs ->
       reg "rs" rs;
       op 10 lor put 2 ~hi:11 ~lo:10 lor rs
     | Wait_event e ->
       op 10 lor put 3 ~hi:11 ~lo:10 lor index_of ~all:all_of_event e ~equal:equal_event)
  | Dly n ->
    check "count" n ~max:255;
    op 11 lor n
  | Csrr (rd, c) ->
    reg "rd" rd;
    check "csr" c ~max:63;
    op 12 lor put rd ~hi:11 ~lo:9 lor c
  | Csrw (c, rs) ->
    reg "rs" rs;
    check "csr" c ~max:63;
    op 13 lor put rs ~hi:11 ~lo:9 lor c
  | Csrwi (c, imm) ->
    check "csr" c ~max:63;
    check "imm6" imm ~max:63;
    op 14 lor put imm ~hi:11 ~lo:6 lor c
;;

(* Returns [None] for reserved encodings or non-zero unused fields. *)
let decode w : t option =
  let f hi lo = field w ~hi ~lo in
  let zero hi lo = f hi lo = 0 in
  let ( &&& ) ok v = if ok then Some v else None in
  match f 15 12 with
  | 0 ->
    let sub = f 11 8
    and low = f 2 0 in
    let only_low = zero 7 3 in
    (match sub with
     | 0 -> (only_low && low = 0) &&& Nop
     | 1 -> (only_low && low = 0) &&& Halt
     | 2 -> (only_low && low = 0) &&& Ret
     | 3 -> only_low &&& Push low
     | 4 -> only_low &&& Pull low
     | 5 -> only_low &&& Sig low
     | 6 -> only_low &&& Clrf low
     | 7 -> only_low &&& Tx low
     | 8 -> only_low &&& Rx low
     | 9 -> (only_low && low = 0) &&& Crci
     | 10 -> (zero 7 1) &&& Ben (f 0 0 = 1)
     | _ -> None)
  | 1 -> Some (if f 8 8 = 1 then Ldih (f 11 9, f 7 0) else Ldi (f 11 9, f 7 0))
  | 2 ->
    zero 2 0
    &&& Alu (List.nth_exn all_of_alu (f 5 3), f 11 9, f 8 6)
  | 3 -> Some (Alui (List.nth_exn all_of_alui (f 8 6), f 11 9, f 5 0))
  | 4 -> Option.map (nth_opt all_of_cond (f 11 8)) ~f:(fun cc -> J (cc, f 7 0))
  | 5 -> zero 8 8 &&& Djnz (f 11 9, f 7 0)
  | 6 -> zero 11 8 &&& Call (f 7 0)
  | 7 ->
    let act =
      match f 4 3, f 11 10 with
      | 0, 0 -> Some Clr
      | 0, 1 -> Some Set
      | 0, 2 -> Some Tgl
      | 0, 3 -> Some Hiz
      | 1, 0 -> Some Drive_c
      | 2, 0 -> Some Drive_not_c
      | 3, 0 -> Some Sample
      | _ -> None
    in
    Option.map act ~f:(fun a -> Pin (a, f 9 5, f 2 0))
  | 8 -> zero 6 3 &&& Outg (f 8 7, f 11 9, f 2 0)
  | 9 -> zero 6 0 &&& Inp (f 11 9, f 8 7)
  | 10 ->
    (match f 11 10 with
     | 0 -> zero 3 0 &&& Wait (Wait_pin (f 9 5, f 4 4 = 1))
     | 1 -> zero 9 4 &&& Wait (Wait_flag (f 2 0, f 3 3 = 1))
     | 2 -> zero 9 3 &&& Wait (Wait_time (f 2 0))
     | _ ->
       if zero 9 4
       then Option.map (nth_opt all_of_event (f 3 0)) ~f:(fun e -> Wait (Wait_event e))
       else None)
  | 11 -> zero 11 8 &&& Dly (f 7 0)
  | 12 -> zero 8 6 &&& Csrr (f 11 9, f 5 0)
  | 13 -> zero 8 6 &&& Csrw (f 5 0, f 11 9)
  | 14 -> Some (Csrwi (f 5 0, f 11 6))
  | _ -> None
;;

(* Assembly text for an instruction; [Asm] parses exactly this syntax back. *)
let to_string (i : t) =
  let r = sprintf "r%d" in
  let lower s = String.lowercase (Sexp.to_string s) in
  let alu fn = lower (sexp_of_alu fn) in
  let alui fn = lower (sexp_of_alui fn) in
  let cond cc =
    match cc with
    | Always -> "always"
    | Z -> "z"
    | Nz -> "nz"
    | C -> "c"
    | Nc -> "nc"
    | T -> "t"
    | Nt -> "nt"
    | Jpin_hi -> "jpin_hi"
    | Jpin_lo -> "jpin_lo"
    | Rx_ready -> "rx_ready"
    | Tx_empty -> "tx_empty"
    | Mbx_data -> "mbx_data"
    | Jflag_set -> "jflag_set"
    | Jflag_clr -> "jflag_clr"
    | Fab_flag -> "fab_flag"
  in
  let action = function
    | Clr -> "clr"
    | Set -> "set"
    | Tgl -> "tgl"
    | Hiz -> "hiz"
    | Drive_c -> "c"
    | Drive_not_c -> "nc"
    | Sample -> "sample"
  in
  let event = function
    | Ev_tx_empty -> "tx_empty"
    | Ev_rx_ready -> "rx_ready"
    | Ev_tick -> "tick"
    | Ev_capture -> "capture"
    | Ev_mailbox -> "mailbox"
  in
  match i with
  | Nop -> "nop"
  | Halt -> "halt"
  | Ret -> "ret"
  | Push x -> "push " ^ r x
  | Pull x -> "pull " ^ r x
  | Sig f -> sprintf "sig %d" f
  | Clrf f -> sprintf "clrf %d" f
  | Tx x -> "tx " ^ r x
  | Rx x -> "rx " ^ r x
  | Crci -> "crci"
  | Ben on -> sprintf "ben %d" (Bool.to_int on)
  | Ldi (d, v) -> sprintf "ldi %s, %d" (r d) v
  | Ldih (d, v) -> sprintf "ldih %s, %d" (r d) v
  | Alu (fn, d, s) -> sprintf "%s %s, %s" (alu fn) (r d) (r s)
  | Alui (fn, d, v) -> sprintf "%s %s, %d" (alui fn) (r d) v
  | J (cc, t) -> sprintf "j %s, %d" (cond cc) t
  | Djnz (d, t) -> sprintf "djnz %s, %d" (r d) t
  | Call t -> sprintf "call %d" t
  | Pin (a, p, d) -> sprintf "pin p%d, %s, %d" p (action a) d
  | Outg (g, s, d) -> sprintf "outg %d, %s, %d" g (r s) d
  | Inp (d, g) -> sprintf "inp %s, %d" (r d) g
  | Wait (Wait_pin (p, v)) -> sprintf "wait pin p%d, %d" p (Bool.to_int v)
  | Wait (Wait_flag (f, v)) -> sprintf "wait flag %d, %d" f (Bool.to_int v)
  | Wait (Wait_time x) -> "wait time " ^ r x
  | Wait (Wait_event e) -> "wait event " ^ event e
  | Dly n -> sprintf "dly %d" n
  | Csrr (d, c) -> sprintf "csrr %s, %d" (r d) c
  | Csrw (c, s) -> sprintf "csrw %d, %s" c (r s)
  | Csrwi (c, v) -> sprintf "csrwi %d, %d" c v
;;

(* CSR addresses (ISA spec section 6). *)
module Csr = struct
  let time_lo = 0x00
  let time_hi = 0x01
  let cap = 0x02
  let capcfg = 0x03
  let tmo = 0x04
  let jpin = 0x05
  let jflag = 0x06
  let flags = 0x07
  let baud = 0x08
  let baudf = 0x09
  let txcfg = 0x0A
  let rxcfg = 0x0B
  let bstat = 0x0C
  let crc_lo = 0x10
  let crc_hi = 0x11
  let crcctl = 0x12
  let fabctl = 0x18
  let fabctl2 = 0x19
  let group g = 0x20 + g

  (* Read/write CSRs and the bits they keep. Anything else reads 0 and ignores writes, except
     the read-only status CSRs above. *)
  let writable =
    [ tmo, 0xffff
    ; jpin, 0x1f
    ; jflag, 0x7
    ; capcfg, 0x7f
    ; baud, 0xffff
    ; baudf, 0xff
    ; txcfg, 0xfff
    ; rxcfg, 0x3fff
    ; crcctl, 0xf
    ; fabctl, 0x1eef (* element fields [3:1] [7:5] [12:10]; bits 4, 8, 13 reserved *)
    ; fabctl2, 0x0ef7 (* element fields [2:0] [7:5] [11:9]; bits 3, 8, 12 reserved *)
    ; group 0, 0xff
    ; group 1, 0xff
    ; group 2, 0xff
    ; group 3, 0xff
    ]
  ;;

  (* A lite engine has no LUT fabric and no CRC unit: FABCTL, FABCTL2 and CRCCTL don't exist
     (they read 0) and the "through fabric" bit of TXCFG/RXCFG isn't kept. *)
  let writable_lite =
    List.filter_map writable ~f:(fun (c, mask) ->
      if c = fabctl || c = fabctl2 || c = crcctl
      then None
      else if c = txcfg || c = rxcfg
      then Some (c, mask land lnot 0x400)
      else Some (c, mask))
  ;;

  let writable_for ~lite = if lite then writable_lite else writable

  let names =
    [ "time_lo", time_lo
    ; "time_hi", time_hi
    ; "cap", cap
    ; "capcfg", capcfg
    ; "tmo", tmo
    ; "jpin", jpin
    ; "jflag", jflag
    ; "flags", flags
    ; "baud", baud
    ; "baudf", baudf
    ; "txcfg", txcfg
    ; "rxcfg", rxcfg
    ; "bstat", bstat
    ; "crc_lo", crc_lo
    ; "crc_hi", crc_hi
    ; "crcctl", crcctl
    ; "fabctl", fabctl
    ; "fabctl2", fabctl2
    ; "group0", group 0
    ; "group1", group 1
    ; "group2", group 2
    ; "group3", group 3
    ]
  ;;
end
