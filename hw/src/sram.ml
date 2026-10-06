(* 256 x 16 single-port SRAM (IHP RM_IHPSG13_1P_256x16_c2_bm_bist).

   Reads are synchronous: the address is taken on the clock edge and the word appears on
   [dout] about 3-5 ns later, and stays there until the next read. The sequencer uses [dout]
   in the same cycle, which is what lets jumps take no extra cycle.

   [Asic] instantiates the macro. [Sim] is the same behaviour built from a Hardcaml memory with a
   registered read address, so Hardcaml's simulator can run it; it can start with a program. *)

open! Core
open! Hardcaml
open Signal

let name = "RM_IHPSG13_1P_256x16_c2_bm_bist"

type mode =
  | Asic
  | Sim of int array

let create mode ~clock ~addr ~din ~wen =
  match mode with
  | Asic ->
    let inst =
      Instantiation.create
        ()
        ~instance:"sram"
        ~name
        ~inputs:
          [ "A_CLK", clock
          ; "A_MEN", vdd
          ; "A_WEN", wen
          ; "A_REN", vdd
          ; "A_ADDR", addr
          ; "A_DIN", din
          ; "A_DLY", vdd
          ; "A_BM", ones 16
          ; "A_BIST_CLK", gnd
          ; "A_BIST_EN", gnd
          ; "A_BIST_MEN", gnd
          ; "A_BIST_WEN", gnd
          ; "A_BIST_REN", gnd
          ; "A_BIST_ADDR", zero 8
          ; "A_BIST_DIN", zero 16
          ; "A_BIST_BM", zero 16
          ]
        ~outputs:[ "A_DOUT", 16 ]
    in
    Instantiation.output inst "A_DOUT"
  | Sim program ->
    let init =
      Array.init 256 ~f:(fun i ->
        Bits.of_int_trunc ~width:16 (if i < Array.length program then program.(i) else 0))
    in
    let read_addr = reg (Reg_spec.create ~clock ()) addr in
    let mem =
      multiport_memory
        256
        ~initialize_to:init
        ~write_ports:
          [| { write_clock = clock; write_address = addr; write_enable = wen; write_data = din } |]
        ~read_addresses:[| read_addr |]
    in
    mem.(0)
;;
