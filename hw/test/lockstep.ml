(* Run the Engine RTL (Hardcaml cyclesim) and the golden Model side by side and compare their
   state after every cycle. *)

open! Core
open Hardcaml
open Pemu

module Sim = Cyclesim.With_interface (Engine.I) (Engine.O)

type t =
  { sim : Sim.t
  ; i : Bits.t ref Engine.I.t
  ; o : Bits.t ref Engine.O.t
  ; before : Bits.t ref Engine.O.t (* outputs just before the clock edge *)
  ; model : Model.t
  ; program : int array
  ; mutable cycle : int
  ; mutable flags : int (* the chip-level flag register, kept here *)
  }

let create ?(lite = false) ?(fabric = [||]) ?(crc_poly = 0) ?(crc_init = 0) program =
  let sim = Sim.create (Engine.create ~lite (Engine.Mode.sim ~fabric ~crc_poly ~crc_init program)) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim
  and before = Cyclesim.outputs ~clock_edge:Before sim in
  let set r w v = r := Bits.of_int_trunc ~width:w v in
  set i.rst_n 1 1;
  set i.run 1 1;
  set i.owned 15 0x7fff;
  set i.cfg_we 1 0;
  let model = Model.create ~lite program in
  Model.set_fabric model fabric;
  Model.set_crc model ~poly:crc_poly ~init:crc_init;
  { sim; i; o; before; model; program; cycle = 0; flags = 0 }
;;

let get r = Bits.to_int_trunc !r

exception Mismatch of Sexp.t [@@deriving sexp_of]

let compare_state t =
  let m = t.model in
  let check name ~rtl ~model =
    if rtl <> model
    then (
      let pc = Model.pc m in
      raise
        (Mismatch
           [%message
             "RTL and model differ"
               ~cycle:(t.cycle : int)
               name
               (rtl : int)
               (model : int)
               (pc : int)
               ~instr_at_pc:
                 (Option.value_map (Isa.decode t.program.(pc)) ~default:"?" ~f:Isa.to_string
                  : string)]))
  in
  let o = t.o in
  check "pc" ~rtl:(get o.pc) ~model:m.pc;
  List.iteri o.regs ~f:(fun k r -> check (sprintf "r%d" k) ~rtl:(get r) ~model:m.regs.(k));
  check "Z" ~rtl:(get o.flags land 1) ~model:(Bool.to_int m.z);
  check "C" ~rtl:((get o.flags lsr 1) land 1) ~model:(Bool.to_int m.c);
  check "T" ~rtl:((get o.flags lsr 2) land 1) ~model:(Bool.to_int m.tflag);
  check "sp" ~rtl:(get o.sp) ~model:m.sp;
  check "busy" ~rtl:(get o.busy) ~model:m.busy;
  check "halted" ~rtl:(get o.halted) ~model:(Bool.to_int m.halted);
  check "flags" ~rtl:t.flags ~model:(Model.read_csr m Isa.Csr.flags);
  check "inbox" ~rtl:(get o.inbox_count) ~model:(Queue.length m.to_engine);
  check "outbox" ~rtl:(get o.outbox_count) ~model:(Queue.length m.from_engine);
  check "crc" ~rtl:(get o.crc) ~model:m.be.crc;
  check "bit engine on" ~rtl:(get o.be_enabled) ~model:(Bool.to_int m.be.enabled);
  check "bstat" ~rtl:(get o.bstat) ~model:(Model.read_csr m Isa.Csr.bstat);
  for q = 0 to 14 do
    check (sprintf "out[%d]" q) ~rtl:((get o.out lsr q) land 1) ~model:(Bool.to_int m.out.(q));
    check (sprintf "oe[%d]" q) ~rtl:((get o.oe lsr q) land 1) ~model:(Bool.to_int m.oe.(q))
  done
;;

(* One cycle. [send] is a word the host wants to write this cycle (written only if the inbox has
   room at the start of the cycle); [receive] says whether the host reads the outbox. Returns the
   word the host read, if any. *)
let step ?send ?(receive = false) t (pads : Model.Pads.t) =
  let i = t.i in
  let set r w v = r := Bits.of_int_trunc ~width:w v in
  let inbox_room = get t.o.inbox_count < 2
  and outbox_has = get t.o.outbox_count > 0 in
  let writing = Option.is_some send && inbox_room in
  let reading = receive && outbox_has in
  set i.uio_in 8 pads.uio_in;
  set i.ui_in 8 pads.ui_in;
  set i.host_wr 1 (Bool.to_int writing);
  set i.host_data 16 (Option.value send ~default:0);
  set i.host_rd 1 (Bool.to_int reading);
  set i.time 32 (Model.time t.model);
  set i.ev_flags 8 t.flags;
  let rtl_read = if reading then Some (get t.o.outbox_head) else None in
  Cyclesim.cycle t.sim;
  (* this cycle's flag requests, seen just before the edge *)
  t.flags <- t.flags land lnot (get t.before.flag_clr) lor get t.before.flag_set;
  Model.step t.model pads;
  if writing then assert (Model.host_send t.model (Option.value_exn send));
  let model_read = if reading then Model.host_receive t.model else None in
  if not ([%equal: int option] rtl_read model_read)
  then
    raise
      (Mismatch
         [%message "host read differs" ~cycle:(t.cycle : int) (rtl_read : int option) (model_read : int option)]);
  t.cycle <- t.cycle + 1;
  compare_state t;
  rtl_read, writing
;;

let uo t = get t.o.out lsr 8
let uio_out t = get t.o.out land 0xff
let uio_oe t = get t.o.oe land 0xff
