(* Storage for one configuration word.

   On the chip it's made of latch cells, which are about 40% smaller than flops. Hardcaml's
   simulator can't run the PDK latch cell, so for simulation the same word is held in flops.
   Either way the write strobe goes through a flop first, so the latch gate can't glitch.
   The data must stay put from the cycle [we] is high until one cycle after. *)

open! Core
open! Hardcaml
open Signal

type mode =
  | Sim
  | Asic

(* [init] is the starting value in simulation (latches on the chip start undefined). *)
let create ?init mode ~spec ~we ~d =
  let gate = reg spec we in
  match mode with
  | Sim -> reg spec ?initialize_to:init ~enable:gate d
  | Asic ->
    List.init (width d) ~f:(fun k ->
      let latch =
        Instantiation.create
          ()
          ~name:"sg13cmos5l_dlhq_1"
          ~inputs:[ "D", d.:[k, k]; "GATE", gate ]
          ~outputs:[ "Q", 1 ]
      in
      Instantiation.output latch "Q")
    |> concat_lsb
;;
