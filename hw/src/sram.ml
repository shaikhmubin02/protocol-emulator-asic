(* 256 x 16 single-port SRAM (IHP RM_IHPSG13_1P_256x16_c2_bm_bist).

   Reads are synchronous: the address is taken on the clock edge and the word appears on
   [dout] about 3-5 ns later, and stays there until the next read. The sequencer uses [dout]
   in the same cycle, which is what lets jumps take no extra cycle. *)

open! Core
open! Hardcaml
open Signal

let name = "RM_IHPSG13_1P_256x16_c2_bm_bist"

let create ~clock ~addr ~din ~wen =
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
;;
