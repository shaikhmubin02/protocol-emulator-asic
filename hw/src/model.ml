(* Cycle-accurate golden model of one engine (ISA spec v1.1). This is the reference the RTL is
   checked against, so it follows the spec's timing rules literally:

   - [step] is one clock cycle. Everything uses the state at the start of the cycle; register,
     flag and pin updates are visible from the next cycle.
   - Pin inputs pass two synchroniser stages: a pad value given to [step] in cycle k is seen
     from cycle k+2.
   - PIN/OUTG with delay d and DLY n hold the engine for d (or n) extra cycles.
   - Waits are evaluated every cycle; with TMO = n > 0 they give up on the n-th failed
     evaluation and set T.
   - The bit engine (baud generator, TX/RX shifters, LUT fabric, CRC) runs on baud ticks.
     Instruction effects on it land after its update for the same cycle (spec section 7.5).

   The fabric is [Fabric_logic.Make (Bits)], the same code the RTL is generated from. *)

open! Core
open! Hardcaml

exception Illegal_instruction of int * int

let n_le = 16

module Fab = Fabric_logic.Make (Bits)

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

type bit_engine =
  { mutable enabled : bool
  ; mutable acc_tx : int
  ; mutable acc_rx : int
  ; mutable hold : int option
  ; mutable sh_value : int
  ; mutable sh_left : int
  ; mutable sh_index : int
  ; mutable rx_active : bool
  ; mutable rx_shift : int
  ; mutable rx_count : int
  ; mutable rx_word : int
  ; mutable rx_ready : bool
  ; mutable completed : bool
  ; mutable overrun : bool
  ; mutable crc : int
  ; mutable crc_poly : int
  ; mutable crc_init : int
  ; fab_cfg : Bits.t array
  ; fab_q : Bits.t array
  ; mutable flag_latch : bool
  }

(* Instruction effects on the bit engine, applied at the end of the cycle. *)
type pending =
  { mutable p_tx : int option
  ; mutable p_rx_take : bool
  ; mutable p_crci : bool
  ; mutable p_ben : bool option
  ; mutable p_csr : (int * int) list
  }

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
  ; mutable captured : bool
  ; to_engine : int Queue.t
  ; from_engine : int Queue.t
  ; mailbox_depth : int
  ; be : bit_engine
  ; pend : pending
  }

let mask16 = 0xffff
let mask32 = 0xffff_ffff

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
  ; captured = false
  ; to_engine = Queue.create ()
  ; from_engine = Queue.create ()
  ; mailbox_depth
  ; be =
      { enabled = false
      ; acc_tx = 0
      ; acc_rx = 0
      ; hold = None
      ; sh_value = 0
      ; sh_left = 0
      ; sh_index = 0
      ; rx_active = false
      ; rx_shift = 0
      ; rx_count = 0
      ; rx_word = 0
      ; rx_ready = false
      ; completed = false
      ; overrun = false
      ; crc = 0
      ; crc_poly = 0
      ; crc_init = 0
      ; fab_cfg = Array.init n_le ~f:(fun _ -> Bits.zero Fabric_logic.cfg_bits)
      ; fab_q = Array.init n_le ~f:(fun _ -> Bits.gnd)
      ; flag_latch = false
      }
  ; pend = { p_tx = None; p_rx_take = false; p_crci = false; p_ben = None; p_csr = [] }
  }
;;

(* ---- host side configuration ---- *)

let set_fabric t words =
  Array.iteri words ~f:(fun i w ->
    t.be.fab_cfg.(i) <- Bits.of_int_trunc ~width:Fabric_logic.cfg_bits w)
;;

let set_crc t ~poly ~init =
  t.be.crc_poly <- poly land mask32;
  t.be.crc_init <- init land mask32
;;

(* ---- pins ---- *)

let read_vector v p = (v lsr p) land 1 = 1

let read_pin t p =
  if (p >= 0 && p < 8) || (p >= 16 && p < 24)
  then read_vector t.sync2 p
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

let pack f n = List.init n ~f:(fun k -> if f k then 1 lsl k else 0) |> List.fold ~init:0 ~f:( lor )
let uo_out t = pack (fun k -> t.out.(8 + k)) 7
let uio_out t = pack (fun k -> t.out.(k)) 8
let uio_oe t = pack (fun k -> t.oe.(k)) 8

let group t g =
  let v = t.csr.(Isa.Csr.group g) in
  v land 0x1f, ((v lsr 5) land 7) + 1
;;

(* ---- bit engine config fields ---- *)

let field v ~hi ~lo = (v lsr lo) land ((1 lsl (hi - lo + 1)) - 1)
let txcfg t = t.csr.(Isa.Csr.txcfg)
let rxcfg t = t.csr.(Isa.Csr.rxcfg)
let fabctl t = t.csr.(Isa.Csr.fabctl)
let fabctl2 t = t.csr.(Isa.Csr.fabctl2)
let period t = (256 * Int.max 1 t.csr.(Isa.Csr.baud)) + (t.csr.(Isa.Csr.baudf) land 0xff)
let tick_now t = t.be.enabled && t.be.acc_tx + 256 >= period t

let bit_reverse32 v =
  List.init 32 ~f:(fun k -> if (v lsr k) land 1 = 1 then 1 lsl (31 - k) else 0)
  |> List.fold ~init:0 ~f:( lor )
;;

let crc_view t =
  if field t.csr.(Isa.Csr.crcctl) ~hi:3 ~lo:3 = 1 then bit_reverse32 t.be.crc else t.be.crc
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
  then (
    t.captured <- false;
    t.cap land mask16)
  else if c = Isa.Csr.flags
  then pack (fun i -> t.flags.(i)) 8
  else if c = Isa.Csr.bstat
  then
    pack
      (function
        | 0 -> Option.is_none t.be.hold
        | 1 -> Option.is_none t.be.hold && t.be.sh_left = 0
        | 2 -> t.be.rx_ready
        | _ -> t.be.overrun)
      4
  else if c = Isa.Csr.crc_lo
  then crc_view t land mask16
  else if c = Isa.Csr.crc_hi
  then (crc_view t lsr 16) land mask16
  else t.csr.(c)
;;

let read_only =
  [ Isa.Csr.time_lo
  ; Isa.Csr.time_hi
  ; Isa.Csr.cap
  ; Isa.Csr.flags
  ; Isa.Csr.bstat
  ; Isa.Csr.crc_lo
  ; Isa.Csr.crc_hi
  ]
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
  | Rx_ready -> t.be.rx_ready
  | Tx_empty -> Option.is_none t.be.hold
  | Fab_flag -> t.be.flag_latch
;;

(* ---- one instruction ---- *)

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
  let p = t.pend in
  let goto pc = finish t ~next_pc:pc ~extra:0 in
  let csr_write c v =
    if not (List.mem read_only c ~equal:Int.equal) then p.p_csr <- (c, v land mask16) :: p.p_csr
  in
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
  | Tx s ->
    wait_step t ~ready:(Option.is_none t.be.hold) ~on_done:(fun () -> p.p_tx <- Some r.(s))
  | Rx d ->
    wait_step
      t
      ~ready:t.be.rx_ready
      ~on_done:(fun () ->
        r.(d) <- t.be.rx_word;
        p.p_rx_take <- true)
  | Crci ->
    p.p_crci <- true;
    goto next
  | Ben on ->
    p.p_ben <- Some on;
    goto next
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
  | Pin (act, pin, d) ->
    (match act with
     | Clr -> drive t pin false
     | Set -> drive t pin true
     | Tgl -> drive t pin (not t.out.(pin land 31))
     | Hiz -> release t pin
     | Drive_c -> drive t pin t.c
     | Drive_not_c -> drive t pin (not t.c)
     | Sample -> t.c <- read_pin t pin);
    finish t ~next_pc:next ~extra:d
  | Outg (g, s, d) ->
    let base, count = group t g in
    for k = 0 to count - 1 do
      drive t (base + k) ((r.(s) lsr k) land 1 = 1)
    done;
    finish t ~next_pc:next ~extra:d
  | Inp (d, g) ->
    let base, count = group t g in
    r.(d) <- pack (fun k -> read_pin t (base + k)) count;
    goto next
  | Wait w ->
    let ready =
      match w with
      | Wait_pin (pin, v) -> Bool.equal (read_pin t pin) v
      | Wait_flag (f, v) -> Bool.equal t.flags.(f) v
      | Wait_time s ->
        let diff = ((t.time land mask16) - r.(s)) land mask16 in
        diff < 0x8000
      | Wait_event Ev_mailbox -> not (Queue.is_empty t.to_engine)
      | Wait_event Ev_capture -> t.captured
      | Wait_event Ev_tx_empty -> Option.is_none t.be.hold
      | Wait_event Ev_rx_ready -> t.be.rx_ready
      | Wait_event Ev_tick -> tick_now t
    in
    let clears_capture =
      match w with
      | Wait_event Ev_capture -> true
      | _ -> false
    in
    wait_step t ~ready ~on_done:(fun () -> if clears_capture then t.captured <- false)
  | Dly n -> finish t ~next_pc:next ~extra:n
  | Csrr (d, c) ->
    r.(d) <- read_csr t c;
    goto next
  | Csrw (c, s) ->
    csr_write c r.(s);
    goto next
  | Csrwi (c, v) ->
    csr_write c v;
    goto next
;;

(* ---- bit engine, one tick (spec 7.5) ---- *)

let crc_step t bit =
  let be = t.be in
  let fb = ((be.crc lsr 31) land 1) lxor bit = 1 in
  be.crc <- ((be.crc lsl 1) land mask32) lxor if fb then be.crc_poly else 0
;;

let tick t ~tx_tick ~rx_tick =
  let be = t.be in
  let tx = txcfg t
  and rx = rxcfg t
  and fc = fabctl t
  and fc2 = fabctl2 t in
  (* 1. TX load and next bit *)
  if tx_tick && be.sh_left = 0
  then (
    match be.hold with
    | Some v ->
      be.sh_value <- v;
      be.sh_left <- field tx ~hi:3 ~lo:0 + 1;
      be.sh_index <- 0;
      be.hold <- None
    | None -> ());
  let tx_bit =
    if (not tx_tick) || be.sh_left = 0
    then None
    else (
      let n = field tx ~hi:3 ~lo:0 + 1 in
      let pos = if field tx ~hi:4 ~lo:4 = 1 then n - 1 - be.sh_index else be.sh_index in
      Some ((be.sh_value lsr pos) land 1))
  in
  (* 2. RX sample *)
  let rx_sample = Bool.to_int (read_pin t (field rx ~hi:9 ~lo:5)) in
  (* 3. fabric: evaluated once; each element only steps on its own tick *)
  let tx_fab = field tx ~hi:10 ~lo:10 = 1
  and rx_fab = field rx ~hi:10 ~lo:10 = 1 in
  let role =
    if tx_fab || rx_fab
    then (
      let ext =
        Bits.of_int_trunc
          ~width:3
          (Option.value tx_bit ~default:0 lor (rx_sample lsl 1) lor (field fc ~hi:0 ~lo:0 lsl 2))
      in
      let f, out = Fab.step ~cfgs:be.fab_cfg ~q:be.fab_q ~ext in
      Array.iteri f ~f:(fun i next ->
        let on_rx = Bits.to_bool (Fab.rx_clocked be.fab_cfg.(i)) in
        if (on_rx && rx_tick) || ((not on_rx) && tx_tick) then be.fab_q.(i) <- next);
      fun i -> Bits.to_bool out.(i))
    else fun _ -> false
  in
  be.flag_latch <- role (field fc2 ~hi:8 ~lo:5);
  (* 4. TX pin *)
  let tx_pin = field tx ~hi:9 ~lo:5 in
  let consumed =
    if not tx_tick
    then None
    else (
      match tx_bit with
      | Some b ->
        let line = if tx_fab then role (field fc ~hi:4 ~lo:1) else b = 1 in
        drive t tx_pin line;
        let held = tx_fab && field fc ~hi:9 ~lo:9 = 1 && role (field fc ~hi:8 ~lo:5) in
        if held
        then None
        else (
          be.sh_index <- be.sh_index + 1;
          be.sh_left <- be.sh_left - 1;
          Some b)
      | None ->
        drive t tx_pin (field tx ~hi:11 ~lo:11 = 1);
        None)
  in
  (* 5. RX *)
  let kept =
    if not (rx_tick && be.rx_active)
    then None
    else (
      let b = if rx_fab then Bool.to_int (role (field fc ~hi:13 ~lo:10)) else rx_sample in
      let dropped = rx_fab && field fc2 ~hi:4 ~lo:4 = 1 && role (field fc2 ~hi:3 ~lo:0) in
      if dropped
      then None
      else (
        let n = field rx ~hi:3 ~lo:0 + 1 in
        if field rx ~hi:4 ~lo:4 = 1
        then be.rx_shift <- ((be.rx_shift lsl 1) lor b) land mask16
        else be.rx_shift <- be.rx_shift lor (b lsl be.rx_count);
        be.rx_count <- be.rx_count + 1;
        if be.rx_count = n
        then (
          (* the old word is lost only if it isn't being read in this same cycle *)
          if be.rx_ready && not t.pend.p_rx_take then be.overrun <- true;
          be.completed <- true;
          be.rx_word <- be.rx_shift;
          be.rx_ready <- true;
          be.rx_shift <- 0;
          be.rx_count <- 0;
          if field rx ~hi:13 ~lo:12 <> 0 then be.rx_active <- false);
        Some b))
  in
  (* 6. CRC *)
  if field t.csr.(Isa.Csr.crcctl) ~hi:0 ~lo:0 = 1
  then (
    match field t.csr.(Isa.Csr.crcctl) ~hi:2 ~lo:1 with
    | 0 -> Option.iter consumed ~f:(crc_step t)
    | 1 -> Option.iter kept ~f:(crc_step t)
    | _ -> if tx_tick then crc_step t (Bool.to_int (role (field fc2 ~hi:12 ~lo:9))))
;;

let advance_baud t =
  let be = t.be in
  if be.enabled
  then (
    let p = period t in
    let tx_tick = be.acc_tx + 256 >= p
    and rx_tick = be.acc_rx + 256 >= p in
    be.acc_tx <- (if tx_tick then be.acc_tx + 256 - p else be.acc_tx + 256);
    be.acc_rx <- (if rx_tick then be.acc_rx + 256 - p else be.acc_rx + 256);
    if tx_tick || rx_tick then tick t ~tx_tick ~rx_tick)
;;

(* Instruction effects on the bit engine (spec 7.5: after the tick). *)
let apply_pending t =
  let be = t.be
  and p = t.pend in
  List.iter (List.rev p.p_csr) ~f:(fun (c, v) -> t.csr.(c) <- v);
  Option.iter p.p_tx ~f:(fun v -> be.hold <- Some v);
  (* RX read the word that was ready at the start of the cycle; a word completed by this
     cycle's tick stays ready *)
  if p.p_rx_take && not be.completed then be.rx_ready <- false;
  if p.p_crci then be.crc <- be.crc_init;
  (match p.p_ben with
   | Some true ->
     be.enabled <- true;
     be.acc_tx <- 0;
     be.acc_rx <- 0;
     be.hold <- None;
     be.sh_left <- 0;
     be.sh_index <- 0;
     be.rx_shift <- 0;
     be.rx_count <- 0;
     be.rx_ready <- false;
     be.overrun <- false;
     be.rx_active <- field (rxcfg t) ~hi:13 ~lo:12 = 0;
     Array.iteri be.fab_cfg ~f:(fun i cfg -> be.fab_q.(i) <- Fab.init cfg)
   | Some false -> be.enabled <- false
   | None -> ());
  p.p_tx <- None;
  p.p_rx_take <- false;
  p.p_crci <- false;
  p.p_ben <- None;
  p.p_csr <- []
;;

(* End of cycle: input synchronisers, edge capture, RX start/alignment. *)
let update_inputs t pads =
  let before = t.sync2 in
  t.sync2 <- t.sync1;
  t.sync1 <- Pads.to_vector pads;
  let after = t.sync2 in
  let edge_on p ~mode =
    let was = read_vector before p
    and now = read_vector after p in
    match mode with
    | 0 -> (not was) && now
    | 1 -> was && not now
    | _ -> not (Bool.equal was now)
  in
  let cfg = t.csr.(Isa.Csr.capcfg) in
  if edge_on (cfg land 31) ~mode:((cfg lsr 5) land 3)
  then (
    t.cap <- t.time;
    t.captured <- true);
  let be = t.be in
  let rx = rxcfg t in
  let rx_pin = field rx ~hi:9 ~lo:5 in
  let align () =
    be.acc_rx <- period t - (256 * (Int.max 1 t.csr.(Isa.Csr.baud) / 2))
  in
  if be.enabled
  then (
    let start = field rx ~hi:13 ~lo:12 in
    if (not be.rx_active) && start <> 0
    then (
      let mode =
        match start with
        | 1 -> 1
        | 2 -> 0
        | _ -> 2
      in
      if edge_on rx_pin ~mode
      then (
        be.rx_active <- true;
        be.rx_shift <- 0;
        be.rx_count <- 0;
        align ()))
    else if be.rx_active && field rx ~hi:11 ~lo:11 = 1 && edge_on rx_pin ~mode:2
    then align ())
;;

let step t (pads : Pads.t) =
  t.be.completed <- false;
  if not t.halted
  then
    if t.busy > 0
    then (
      t.busy <- t.busy - 1;
      if t.busy = 0 then t.pc <- t.busy_next_pc)
    else execute t;
  advance_baud t;
  apply_pending t;
  t.time <- (t.time + 1) land mask32;
  update_inputs t pads
;;

(* ---- host side / inspection ---- *)

let host_send t v = Queue.enqueue t.to_engine (v land mask16)
let host_receive t = Queue.dequeue t.from_engine
let pc t = t.pc
let reg t i = t.regs.(i)
let halted t = t.halted
let time t = t.time
let crc t = t.be.crc
