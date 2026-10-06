(* Test harness for one block: LUT fabric + CRC unit, driven straight from the pins.
   Same behaviour as the hand-written src/project.v it replaces.

   Config: shift a 38-bit word {addr[5:0], data[31:0]} in MSB first on ui[0] while ui[1] is
   high, then pulse ui[2] for one cycle. addr 0..23 = fabric element, 62 = CRC polynomial,
   63 = CRC init value.
   Run: ui[3] steps the fabric and CRC, ui[4] loads init values, ui[7:5] = ext inputs
   (the CRC takes its data bit from ext[0]).
   uio[2:0] selects what uo shows: 0..2 fabric outputs (bytes), 3..6 reversed CRC bytes. *)

open! Core
open! Hardcaml
open Signal

let n_le = 24

module I = struct
  type 'a t =
    { clk : 'a
    ; rst_n : 'a
    ; ena : 'a
    ; ui_in : 'a [@bits 8]
    ; uio_in : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uo_out : 'a [@bits 8]
    ; uio_out : 'a [@bits 8]
    ; uio_oe : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module L = Fabric_logic.Make (Signal)

let create mode (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clk ~reset:i.rst_n ~reset_level:Low () in
  let pin k = i.ui_in.:[k, k] in
  let cfg_dat = pin 0
  and cfg_shift = pin 1
  and cfg_we = pin 2
  and step = pin 3
  and init = pin 4
  and ext = i.ui_in.:[7, 5] in
  (* config shift register *)
  let sreg =
    reg_fb spec ~enable:cfg_shift ~width:38 ~f:(fun s -> s.:[36, 0] @: cfg_dat)
  in
  let addr = sreg.:[37, 32]
  and data = sreg.:[31, 0] in
  let write_to a = cfg_we &: (addr ==:. a) in
  (* fabric *)
  let cfgs =
    Array.init n_le ~f:(fun k ->
      Cfg_store.create mode ~spec ~we:(write_to k) ~d:data.:[29, 0])
  in
  let q = Array.init n_le ~f:(fun _ -> wire 1) in
  let f, out = L.step ~cfgs ~q ~ext in
  Array.iteri q ~f:(fun k q_k ->
    assign q_k (reg spec ~enable:(init |: step) (mux2 init (L.init cfgs.(k)) f.(k))));
  let fabric_out = concat_lsb (Array.to_list out) in
  (* CRC unit: n-bit CRCs live in the top n bits, MSB-first *)
  let poly = Cfg_store.create mode ~spec ~we:(write_to 62) ~d:data in
  let crc_init = Cfg_store.create mode ~spec ~we:(write_to 63) ~d:data in
  let crc =
    reg_fb spec ~enable:(init |: step) ~width:32 ~f:(fun c ->
      let fb = msb c ^: L.bit ext 0 in
      mux2 init crc_init ((c.:[30, 0] @: gnd) ^: mux2 fb poly (zero 32)))
  in
  let crc_rev = reverse crc in
  let byte x k = x.:[(8 * k) + 7, 8 * k] in
  let uo_out =
    mux
      i.uio_in.:[2, 0]
      [ byte fabric_out 0
      ; byte fabric_out 1
      ; byte fabric_out 2
      ; byte crc_rev 0
      ; byte crc_rev 1
      ; byte crc_rev 2
      ; byte crc_rev 3
      ; byte crc 3
      ]
  in
  { O.uo_out; uio_out = zero 8; uio_oe = zero 8 }
;;

let circuit mode =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"tt_um_shaikhmubin02_spike" (create mode)
;;
