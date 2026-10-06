(* Cycle-accurate golden model of one engine (ISA spec v1). This is the reference the RTL is
   checked against, so it follows the spec's timing rules literally:

   - [step] is one clock cycle. The instruction at [pc] uses the state at the start of the
     cycle; its register, flag and pin updates are visible from the next cycle.
   - Pin inputs pass two synchroniser stages: a pad value given to [step] in cycle k is seen by
     instructions from cycle k+2.
   - PIN/OUTG with delay d and DLY n hold the engine for d (or n) extra cycles.
   - Waits are evaluated every cycle; with TMO = n > 0 they give up on the n-th failed
     evaluation and set T.

   Not modelled yet: the bit engine (TX, RX, CRCI, BEN and their CSRs/conditions). *)

open! Core

exception Illegal_instruction of int * int
exception Not_modelled of string

module Pads = struct
  (* Pad values during one cycle: uio_in[7:0] and ui_in[7:0]. *)
  type t =
    { uio_in : int
    ; ui_in : int
    }

  let zero = { uio_in = 0; ui_in = 0 }

  (* As a 32-bit vector indexed by pin number (uio = pins 0..7, ui = pins 16..23). *)
  let to_vector t = (t.uio_in land 0xff) lor ((t.ui_in land 0xff) lsl 16)
end

type t =
  { program : int array
  ; regs : int array
  ; mutable pc : int
  ; mutable z : bool
  ; mutable c : bool
  ; mutable tflag : bool
  ; stack : int array
  ; mutable sp : int
  ; mutable halted : bool
  ; mutable busy : int
  ; mutable busy_next_pc : int
  ; mutable failed_evals : int
  ; csr : int array
  ; mutable time : int
  ; mutable time_hi_latch : int
  ; flags : bool array
  ; out : bool array
  ; oe : bool array
  ; owned : bool array
  ; mutable sync1 : int
  ; mutable sync2 : int
  ; mutable cap : int
  ; to_engine : int Queue.t
  ; from_engine : int Queue.t
  ; mailbox_depth : int
  }

let mask16 = 0xffff

let create ?(mailbox_depth = 2) program =
  if Array.length program > 256 then invalid_arg "program longer than 256 words";
  let words = Array.create ~len:256 0 in
  Array.blit ~src:program ~src_pos:0 ~dst:words ~dst_pos:0 ~len:(Array.length program);
  { program = words
  ; regs = Array.create ~len:8 0
  ; pc = 0
  ; z = false
  ; c = false
  ; tflag = false
  ; stack = Array.create ~len:4 0
  ; sp = 0
  ; halted = false
  ; busy = 0
  ; busy_next_pc = 0
  ; failed_evals = 0
  ; csr = Array.create ~len:64 0
  ; time = 0
  ; time_hi_latch = 0
  ; flags = Array.create ~len:8 false
  ; out = Array.create ~len:32 false
  ; oe = Array.create ~len:32 false
  ; owned = Array.init 32 ~f:(fun p -> p < 15)
  ; sync1 = 0
  ; sync2 = 0
  ; cap = 0
  ; to_engine = Queue.create ()
  ; from_engine = Queue.create ()
  ; mailbox_depth
  }
;;

(* ---- pins ---- *)

let read_pin t p =
  if (p >= 0 && p < 8) || (p >= 16 && p < 24)
  then (t.sync2 lsr p) land 1 = 1
  else if p >= 8 && p < 15
  then t.out.(p)
  else false
;;

let drive t p v =
  if p < 15 && t.owned.(p)
  then (
    t.out.(p) <- v;
    t.oe.(p) <- true)
;;

let release t p =
  if p < 15 && t.owned.(p)
  then
    if p < 8
    then t.oe.(p) <- false
    else (
      (* output-only pins can't float: HIZ drives 0 *)
      t.out.(p) <- false;
      t.oe.(p) <- true)
;;

let uo_out t =
  List.init 7 ~f:(fun k -> if t.out.(8 + k) then 1 lsl k else 0) |> List.fold ~init:0 ~f:( lor )
;;

let uio_out t =
  List.init 8 ~f:(fun k -> if t.out.(k) then 1 lsl k else 0) |> List.fold ~init:0 ~f:( lor )
;;

let uio_oe t =
  List.init 8 ~f:(fun k -> if t.oe.(k) then 1 lsl k else 0) |> List.fold ~init:0 ~f:( lor )
;;

let group t g =
  let v = t.csr.(Isa.Csr.group g) in
  v land 0x1f, ((v lsr 5) land 7) + 1
;;

(* ---- CSRs ---- *)

let read_csr t c =
  if c = Isa.Csr.time_lo
  then (
    t.time_hi_latch <- (t.time lsr 16) land mask16;
    t.time land mask16)
  else if c = Isa.Csr.time_hi
  then t.time_hi_latch
  else if c = Isa.Csr.cap
  then t.cap land mask16
  else if c = Isa.Csr.flags
  then
    Array.foldi t.flags ~init:0 ~f:(fun i acc f -> if f then acc lor (1 lsl i) else acc)
  else if c = Isa.Csr.bstat || c = Isa.Csr.crc_lo || c = Isa.Csr.crc_hi
  then raise (Not_modelled "bit engine CSR")
  else t.csr.(c)
;;

let write_csr t c v =
  let read_only = [ Isa.Csr.time_lo; Isa.Csr.time_hi; Isa.Csr.cap; Isa.Csr.flags; Isa.Csr.bstat ] in
  if not (List.mem read_only c ~equal:Int.equal) then t.csr.(c) <- v land mask16
;;

(* ---- ALU ---- *)

let set_z t v = t.z <- v land mask16 = 0

let alu t (fn : Isa.alu) a b =
  match fn with
  | Mov -> Some b
  | Add ->
    let s = a + b in
    t.c <- s > mask16;
    Some (s land mask16)
  | Sub ->
    t.c <- a < b;
    Some ((a - b) land mask16)
  | Cmp ->
    t.c <- a < b;
    set_z t (a - b);
    None
  | And -> Some (a land b)
  | Or -> Some (a lor b)
  | Xor -> Some (a lxor b)
  | Tst ->
    set_z t (a land b);
    None
;;

let rotate_left t v =
  let c = (v lsr 15) land 1 = 1 in
  let v = ((v lsl 1) lor Bool.to_int t.c) land mask16 in
  t.c <- c;
  v
;;

let rotate_right t v =
  let c = v land 1 = 1 in
  let v = (v lsr 1) lor (Bool.to_int t.c lsl 15) in
  t.c <- c;
  v
;;

let alui t (fn : Isa.alui) a n =
  match fn with
  | Addi | Subi | Cmpi ->
    let fn : Isa.alu =
      match fn with
      | Addi -> Add
      | Subi -> Sub
      | _ -> Cmp
    in
    alu t fn a n
  | Shli ->
    if n > 0 then t.c <- n <= 16 && (a lsr (16 - n)) land 1 = 1;
    Some ((a lsl n) land mask16)
  | Shri ->
    if n > 0 then t.c <- n <= 16 && (a lsr (n - 1)) land 1 = 1;
    Some (a lsr n)
  | Rlc -> Some (Fn.apply_n_times ~n (rotate_left t) a)
  | Rrc -> Some (Fn.apply_n_times ~n (rotate_right t) a)
  | Tstb ->
    t.z <- (a lsr (n land 15)) land 1 = 0;
    None
;;

(* ---- conditions ---- *)

let cond t (cc : Isa.cond) =
  match cc with
  | Always -> true
  | Z -> t.z
  | Nz -> not t.z
  | C -> t.c
  | Nc -> not t.c
  | T -> t.tflag
  | Nt -> not t.tflag
  | Jpin_hi -> read_pin t (t.csr.(Isa.Csr.jpin) land 31)
  | Jpin_lo -> not (read_pin t (t.csr.(Isa.Csr.jpin) land 31))
  | Mbx_data -> not (Queue.is_empty t.to_engine)
  | Jflag_set -> t.flags.(t.csr.(Isa.Csr.jflag) land 7)
  | Jflag_clr -> not t.flags.(t.csr.(Isa.Csr.jflag) land 7)
  | Rx_ready | Tx_empty | Fab_flag -> raise (Not_modelled "bit engine condition")
;;

(* ---- one cycle ---- *)

let finish t ~next_pc ~extra =
  if extra = 0
  then t.pc <- next_pc land 0xff
  else (
    t.busy <- extra;
    t.busy_next_pc <- next_pc land 0xff)
;;

(* A waiting instruction: [ready] is checked this cycle, [on_done] runs when it completes. *)
let wait_step t ~ready ~on_done =
  if ready
  then (
    on_done ();
    t.tflag <- false;
    t.failed_evals <- 0;
    t.pc <- (t.pc + 1) land 0xff)
  else (
    t.failed_evals <- t.failed_evals + 1;
    let tmo = t.csr.(Isa.Csr.tmo) in
    if tmo > 0 && t.failed_evals >= tmo
    then (
      t.tflag <- true;
      t.failed_evals <- 0;
      t.pc <- (t.pc + 1) land 0xff))
;;

let execute t =
  let word = t.program.(t.pc) in
  let instr =
    match Isa.decode word with
    | Some i -> i
    | None -> raise (Illegal_instruction (t.pc, word))
  in
  let next = t.pc + 1 in
  let r = t.regs in
  let goto pc = finish t ~next_pc:pc ~extra:0 in
  match instr with
  | Nop -> goto next
  | Halt -> t.halted <- true
  | Ret ->
    t.sp <- (t.sp - 1) land 3;
    goto t.stack.(t.sp)
  | Push s ->
    wait_step
      t
      ~ready:(Queue.length t.from_engine < t.mailbox_depth)
      ~on_done:(fun () -> Queue.enqueue t.from_engine r.(s))
  | Pull d ->
    wait_step
      t
      ~ready:(not (Queue.is_empty t.to_engine))
      ~on_done:(fun () -> r.(d) <- Queue.dequeue_exn t.to_engine land mask16)
  | Sig f ->
    t.flags.(f) <- true;
    goto next
  | Clrf f ->
    t.flags.(f) <- false;
    goto next
  | Tx _ | Rx _ | Crci | Ben _ -> raise (Not_modelled (Isa.to_string instr))
  | Ldi (d, v) ->
    r.(d) <- v;
    set_z t v;
    goto next
  | Ldih (d, v) ->
    r.(d) <- (v lsl 8) lor (r.(d) land 0xff);
    set_z t r.(d);
    goto next
  | Alu (fn, d, s) ->
    (match alu t fn r.(d) r.(s) with
     | Some v ->
       r.(d) <- v;
       set_z t v
     | None -> ());
    goto next
  | Alui (fn, d, n) ->
    (match alui t fn r.(d) n with
     | Some v ->
       r.(d) <- v;
       set_z t v
     | None -> ());
    goto next
  | J (cc, target) -> goto (if cond t cc then target else next)
  | Djnz (d, target) ->
    r.(d) <- (r.(d) - 1) land mask16;
    goto (if r.(d) <> 0 then target else next)
  | Call target ->
    t.stack.(t.sp) <- next land 0xff;
    t.sp <- (t.sp + 1) land 3;
    goto target
  | Pin (act, p, d) ->
    (match act with
     | Clr -> drive t p false
     | Set -> drive t p true
     | Tgl -> drive t p (not t.out.(p land 31))
     | Hiz -> release t p
     | Drive_c -> drive t p t.c
     | Drive_not_c -> drive t p (not t.c)
     | Sample -> t.c <- read_pin t p);
    finish t ~next_pc:next ~extra:d
  | Outg (g, s, d) ->
    let base, count = group t g in
    for k = 0 to count - 1 do
      drive t (base + k) ((r.(s) lsr k) land 1 = 1)
    done;
    finish t ~next_pc:next ~extra:d
  | Inp (d, g) ->
    let base, count = group t g in
    r.(d)
    <- List.init count ~f:(fun k -> if read_pin t (base + k) then 1 lsl k else 0)
       |> List.fold ~init:0 ~f:( lor );
    goto next
  | Wait w ->
    let ready =
      match w with
      | Wait_pin (p, v) -> Bool.equal (read_pin t p) v
      | Wait_flag (f, v) -> Bool.equal t.flags.(f) v
      | Wait_time s ->
        let diff = ((t.time land mask16) - r.(s)) land mask16 in
        diff < 0x8000
      | Wait_event Ev_mailbox -> not (Queue.is_empty t.to_engine)
      | Wait_event Ev_capture -> raise (Not_modelled "wait capture")
      | Wait_event (Ev_tx_empty | Ev_rx_ready | Ev_tick) ->
        raise (Not_modelled "bit engine event")
    in
    wait_step t ~ready ~on_done:(fun () -> ())
  | Dly n -> finish t ~next_pc:next ~extra:n
  | Csrr (d, c) ->
    r.(d) <- read_csr t c;
    goto next
  | Csrw (c, s) ->
    write_csr t c r.(s);
    goto next
  | Csrwi (c, v) ->
    write_csr t c v;
    goto next
;;

(* Edge capture: CAP = the first cycle in which the new value of the watched pin is visible. *)
let update_capture t ~before ~after =
  let cfg = t.csr.(Isa.Csr.capcfg) in
  let p = cfg land 31 in
  let bit v = (v lsr p) land 1 = 1 in
  let was = bit before
  and now = bit after in
  let fire =
    match (cfg lsr 5) land 3 with
    | 0 -> (not was) && now
    | 1 -> was && not now
    | _ -> not (Bool.equal was now)
  in
  if fire then t.cap <- t.time
;;

let step t (pads : Pads.t) =
  if not t.halted
  then
    if t.busy > 0
    then (
      t.busy <- t.busy - 1;
      if t.busy = 0 then t.pc <- t.busy_next_pc)
    else execute t;
  t.time <- (t.time + 1) land 0xffff_ffff;
  let before = t.sync2 in
  t.sync2 <- t.sync1;
  t.sync1 <- Pads.to_vector pads;
  update_capture t ~before ~after:t.sync2
;;

(* ---- host side ---- *)

let host_send t v = Queue.enqueue t.to_engine (v land mask16)
let host_receive t = Queue.dequeue t.from_engine
let pc t = t.pc
let reg t i = t.regs.(i)
let halted t = t.halted
let time t = t.time
