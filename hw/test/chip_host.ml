(* Drives the whole chip in simulation the way a board would: an SPI host on ui[0..2] / uo[7],
   plus whatever is wired to the protocol pins.

   [on_cycle] runs after every clock cycle; tests use it to wire outputs back to inputs or to play
   a device. ui[7:3] come from [ui], the uio pads read [uio_ext] where no engine drives them. *)

open! Core
open Hardcaml
open Pemu

module Sim = Cyclesim.With_interface (Chip.I) (Chip.O)

type t =
  { sim : Sim.t
  ; i : Bits.t ref Chip.I.t
  ; o : Bits.t ref Chip.O.t
  ; mutable sck : int
  ; mutable cs_n : int
  ; mutable mosi : int
  ; mutable ui : int
  ; mutable uio_ext : int
  ; mutable cycle : int
  ; mutable on_cycle : t -> unit
  }

let get r = Bits.to_int_trunc !r
let set r w v = r := Bits.of_int_trunc ~width:w v
let uo t = get t.o.uo_out
let uio_out t = get t.o.uio_out
let uio_oe t = get t.o.uio_oe

(* what the uio pads read: the chip where it drives, the outside world elsewhere *)
let uio_pads t = uio_out t land uio_oe t lor (t.uio_ext land lnot (uio_oe t)) land 0xff

let cycle t =
  set t.i.ui_in 8 ((t.ui land 0xf8) lor (t.mosi lsl 2) lor (t.cs_n lsl 1) lor t.sck);
  set t.i.uio_in 8 (uio_pads t);
  Cyclesim.cycle t.sim;
  t.cycle <- t.cycle + 1;
  t.on_cycle t
;;

let cycles t n =
  for _ = 1 to n do
    cycle t
  done
;;

let create () =
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (Chip.create Chip.Sim scope) in
  let t =
    { sim
    ; i = Cyclesim.inputs sim
    ; o = Cyclesim.outputs sim
    ; sck = 0
    ; cs_n = 1
    ; mosi = 0
    ; ui = 0
    ; uio_ext = 0
    ; cycle = 0
    ; on_cycle = (fun _ -> ())
    }
  in
  set t.i.ena 1 1;
  set t.i.rst_n 1 0;
  cycles t 3;
  set t.i.rst_n 1 1;
  t
;;

(* SCK = clk/8, the fastest the chip supports *)
let half = 4

(* One SPI frame, mode 0: returns the bytes seen on MISO, one per byte sent. *)
let transfer t bytes =
  t.cs_n <- 0;
  cycles t half;
  let got =
    List.map bytes ~f:(fun b ->
      let r = ref 0 in
      for k = 7 downto 0 do
        t.mosi <- (b lsr k) land 1;
        cycles t half;
        r := (!r lsl 1) lor (uo t lsr 7);
        t.sck <- 1;
        cycles t half;
        t.sck <- 0
      done;
      !r)
  in
  cycles t half;
  t.cs_n <- 1;
  cycles t (2 * half);
  got
;;

let word_bytes w = [ (w lsr 8) land 0xff; w land 0xff ]

let write t addr words =
  ignore (transfer t ((0x02 :: word_bytes addr) @ List.concat_map words ~f:word_bytes) : int list)
;;

let read t addr n =
  let got = transfer t ((0x03 :: word_bytes addr) @ (0 :: List.init (2 * n) ~f:(fun _ -> 0))) in
  let rec words = function
    | hi :: lo :: rest -> ((hi lsl 8) lor lo) :: words rest
    | _ -> []
  in
  words (List.drop got 4)
;;

let read1 t addr = List.hd_exn (read t addr 1)

(* addresses *)
let engine_addr e ~region off = (e lsl 14) lor (region lsl 12) lor off
let program e off = engine_addr e ~region:0 off
let config e ~word ~half = engine_addr e ~region:1 ((2 * word) + half)
let status e = engine_addr e ~region:2 0
let reg e r = engine_addr e ~region:2 (0x10 + r)
let mailbox e = engine_addr e ~region:2 0x80
let global off = engine_addr 0 ~region:3 off
let owner q = global q
let run_reg = global 0x10
let flags_reg = global 0x11
let time_lo = global 0x12
let time_hi = global 0x13
let id_reg = global 0x20

let load t e words = write t (program e 0) (Array.to_list words)

let set_config t e ~word v = write t (config e ~word ~half:0) [ v land 0xffff; (v lsr 16) land 0xffff ]

let own t ~pin ~engine = write t (owner pin) [ 4 lor engine ]
let run t mask = write t run_reg [ mask ]
let outbox_count t e = (read1 t (status e) lsr 12) land 3
let inbox_count t e = (read1 t (status e) lsr 10) land 3
let pc t e = read1 t (status e) land 0xff
