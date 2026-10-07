(* The whole chip as an executable spec, at its pins: four engine models, the host SPI port, pin
   owners, the run register, and the shared cycle counter and event flags (see chip.ml for the
   host protocol and address map).

   [outputs] gives the pins during the current cycle; [step] advances one clock with the pad
   values of that cycle. Checked cycle by cycle against Chip.

   Not modelled: configuration writes to a running engine (the cycle they take effect is not
   specified). *)

open! Core

let n_engines = 4
let n_pins = 15
let n_cfg = 18
let chip_id = 0x5045
let bit v k = (v lsr k) land 1 = 1
let b2i = Bool.to_int

type engine =
  { lite : bool (* no LUT fabric, no CRC unit, no configuration *)
  ; mem : int array (* program memory *)
  ; cfg : int array (* 0..7 fabric elements, 8..15 unused, 16 CRC polynomial, 17 CRC init *)
  ; mutable model : Model.t option (* None while the engine is held in reset *)
  ; mutable sram_addr : int (* address the program SRAM took at the last edge *)
  ; mutable room : bool (* inbox had room / outbox had a word, one cycle ago *)
  ; mutable has : bool
  ; mutable head : int (* the outbox's two registers: the head stays put when it empties *)
  ; mutable second : int
  }

type t =
  { engines : engine array
  ; mutable time : int
  ; mutable flags : int
  ; mutable run : int
  ; owners : int array
  ; mutable sck : int list (* synchronisers, newest first *)
  ; mutable sel : int list
  ; mutable mosi : int list
  ; mutable count : int
  ; mutable shift_in : int
  ; mutable cmd : int
  ; mutable addr : int
  ; mutable shift_out : int
  ; mutable lo_half : int
  ; mutable wr : bool
  ; mutable wr_addr : int
  ; mutable wr_data : int
  ; mutable pop_pending : bool
  ; mutable pop_engine : int
  ; mutable read_word : int
  }

let create () =
  { engines =
      Array.init n_engines ~f:(fun e ->
        { lite = e >= 2
        ; mem = Array.create ~len:256 0
        ; cfg = Array.create ~len:n_cfg 0
        ; model = None
        ; sram_addr = 0
        ; room = false
        ; has = false
        ; head = 0
        ; second = 0
        })
  ; time = 0
  ; flags = 0
  ; run = 0
  ; owners = Array.create ~len:n_pins 0
  ; sck = [ 0; 0; 0 ]
  ; sel = [ 0; 0 ]
  ; mosi = [ 0; 0 ]
  ; count = 0
  ; shift_in = 0
  ; cmd = 0
  ; addr = 0
  ; shift_out = 0
  ; lo_half = 0
  ; wr = false
  ; wr_addr = 0
  ; wr_data = 0
  ; pop_pending = false
  ; pop_engine = 0
  ; read_word = 0
  }
;;

let running t e = Option.is_some t.engines.(e).model
let model t e = t.engines.(e).model
let selected t = List.nth_exn t.sel 1 = 1
let reading t = t.cmd = 0x03
let writing t = t.cmd = 0x02

let owner_of t q =
  let o = t.owners.(q) in
  if bit o 2 then Some (o land 3) else None
;;

type outputs =
  { uo_out : int
  ; uio_out : int
  ; uio_oe : int
  }
[@@deriving sexp_of, equal]

let outputs t =
  let pin (f : Model.t -> bool array) q =
    match owner_of t q with
    | Some e -> Option.value_map (model t e) ~default:false ~f:(fun m -> (f m).(q))
    | None -> false
  in
  let pack f lo n = List.init n ~f:(fun k -> b2i (f (lo + k)) lsl k) |> List.fold ~init:0 ~f:( lor ) in
  let miso = selected t && reading t && t.count >= 32 && bit t.shift_out 15 in
  { uo_out = (b2i miso lsl 7) lor pack (pin (fun m -> m.out)) 8 7
  ; uio_out = pack (pin (fun m -> m.out)) 0 8
  ; uio_oe = pack (pin (fun m -> m.oe)) 0 8
  }
;;

let fields a = a lsr 14, (a lsr 12) land 3, a land 0xfff

(* what a read of [addr] returns, from the state at the start of the cycle *)
let read_value t =
  let engine, region, off = fields t.addr in
  if region = 3
  then
    if off < n_pins
    then t.owners.(off)
    else (
      match off with
      | 0x10 -> t.run
      | 0x11 -> t.flags
      | 0x12 -> t.time land 0xffff
      | 0x13 -> t.time lsr 16
      | 0x20 -> chip_id
      | _ -> 0)
  else (
    let en = t.engines.(engine) in
    let m = en.model in
    match region with
    | 0 ->
      (* the SRAM output: the instruction at pc while running, else the word it was pointed at *)
      (match m with
       | Some m -> en.mem.(m.pc)
       | None -> en.mem.(en.sram_addr))
    | 2 when bit off 7 -> en.head
    | 2 when off = 0 ->
      (match m with
       | None -> b2i (bit t.run engine) lsl 9
       | Some m ->
         m.pc
         lor (b2i m.halted lsl 8)
         lor (b2i (bit t.run engine) lsl 9)
         lor (Queue.length m.to_engine lsl 10)
         lor (Queue.length m.from_engine lsl 12)
         lor (b2i m.be.enabled lsl 14))
    | 2 when off lsr 3 = 2 -> Option.value_map m ~default:0 ~f:(fun m -> m.regs.(off land 7))
    | _ -> 0)
;;

let fresh_model en =
  let m = Model.create ~lite:en.lite en.mem in
  Model.set_fabric m (Array.sub en.cfg ~pos:0 ~len:Model.n_le);
  Model.set_crc m ~poly:en.cfg.(16) ~init:en.cfg.(17);
  m
;;

let step t (pads : Model.Pads.t) =
  let ui k = (pads.ui_in lsr k) land 1 in
  (* ---- host port, combinational from the state at the start of the cycle ---- *)
  let sck_now = List.nth_exn t.sck 1
  and sck_before = List.nth_exn t.sck 2
  and mosi = List.nth_exn t.mosi 1 in
  let rise = sck_now = 1 && sck_before = 0 && selected t in
  let shifted = ((t.shift_in lsl 1) lor mosi) land 0xffff in
  let word_written = rise && writing t && t.count = 39 in
  let word_loaded = rise && reading t && (t.count = 31 || t.count = 47) in
  let w_engine, w_region, w_off = fields t.wr_addr in
  let r_engine, r_region, r_off = fields t.addr in
  let w_global k = t.wr && w_region = 3 && w_off = k in
  let read_next = read_value t in
  let has_before = Array.map t.engines ~f:(fun en -> en.has) in
  (* ---- engines ---- *)
  let set = ref 0
  and clr = ref 0 in
  let flags_now = t.flags in
  Array.iteri t.engines ~f:(fun e en ->
    let w_this = t.wr && w_engine = e in
    let host_wr = w_this && w_region = 2 && bit w_off 7 && en.room in
    let host_rd = rise && t.pop_pending && t.pop_engine = e in
    let prog_we = w_this && w_region = 0 in
    let prog_re = selected t && reading t && r_engine = e && r_region = 0 in
    let running_now = bit t.run e in
    let inbox_before, outbox_before =
      match en.model with
      | Some m -> Queue.length m.to_engine, Queue.length m.from_engine
      | None -> 0, 0
    in
    if not running_now
    then (
      if prog_we then en.mem.(w_off land 0xff) <- t.wr_data;
      en.sram_addr
      <- (if prog_we || prog_re then (if t.wr then w_off else r_off) land 0xff else 0);
      en.model <- None;
      en.head <- 0;
      en.second <- 0)
    else (
      let m =
        match en.model with
        | Some m -> m
        | None -> fresh_model en
      in
      m.time <- t.time;
      Array.iteri m.flags ~f:(fun k _ -> m.flags.(k) <- bit flags_now k);
      for q = 0 to n_pins - 1 do
        m.owned.(q) <- [%equal: int option] (owner_of t q) (Some e)
      done;
      Model.step m pads;
      en.sram_addr <- m.pc;
      set := !set lor m.flag_set;
      clr := !clr lor m.flag_clr;
      let pushed =
        if Queue.length m.from_engine > outbox_before
        then Some (Option.value_exn (Queue.last m.from_engine))
        else None
      in
      if host_wr && not (Model.host_send m t.wr_data)
      then failwith "chip model: host wrote into a full inbox";
      if host_rd then ignore (Model.host_receive m : int option);
      (* the outbox registers: pop moves the second word up, a push lands behind what's left *)
      let left = outbox_before - b2i host_rd in
      if host_rd then en.head <- en.second;
      Option.iter pushed ~f:(fun v -> if left = 0 then en.head <- v else en.second <- v);
      en.model <- Some m);
    en.room <- inbox_before < 2;
    en.has <- outbox_before <> 0);
  (* configuration writes (stored now, loaded into the engine when it starts) *)
  let cfg_index = (w_off lsr 1) land 31 in
  if t.wr && w_region = 1 && bit w_off 0 && cfg_index < n_cfg && not t.engines.(w_engine).lite
  then (
    let en = t.engines.(w_engine) in
    if running t w_engine then failwith "chip model: configuration write to a running engine";
    en.cfg.(cfg_index) <- (t.wr_data lsl 16) lor t.lo_half);
  (* ---- chip registers ---- *)
  let base = if w_global 0x11 then t.wr_data land 0xff else t.flags in
  t.flags <- base land lnot !clr lor !set;
  t.time <- (t.time + 1) land 0xffff_ffff;
  if t.wr && w_region = 1 && not (bit w_off 0) then t.lo_half <- t.wr_data;
  if w_global 0x10 then t.run <- t.wr_data land 0xf;
  for q = 0 to n_pins - 1 do
    if w_global q then t.owners.(q) <- t.wr_data land 7
  done;
  t.wr <- word_written;
  if word_written
  then (
    t.wr_addr <- t.addr;
    t.wr_data <- shifted);
  if not (selected t)
  then (
    t.count <- 0;
    t.cmd <- 0;
    t.pop_pending <- false)
  else if rise
  then (
    let count = t.count in
    t.shift_in <- shifted;
    t.count <- (count + 1) land 63;
    if count = 7 then t.cmd <- shifted land 0xff;
    if count = 23 then t.addr <- shifted;
    if reading t && count >= 32 then t.shift_out <- (t.shift_out lsl 1) land 0xffff;
    t.pop_pending <- false;
    if word_written
    then (
      t.count <- 24;
      t.addr <- (t.addr + 1) land 0xffff);
    if word_loaded
    then (
      t.shift_out <- t.read_word;
      t.count <- 32;
      t.addr <- (t.addr + 1) land 0xffff;
      t.pop_pending <- r_region = 2 && bit r_off 7 && has_before.(r_engine);
      t.pop_engine <- r_engine));
  t.read_word <- read_next;
  t.sck <- [ ui 0; List.nth_exn t.sck 0; List.nth_exn t.sck 1 ];
  t.sel <- [ 1 - ui 1; List.nth_exn t.sel 0 ];
  t.mosi <- [ ui 2; List.nth_exn t.mosi 0 ]
;;
