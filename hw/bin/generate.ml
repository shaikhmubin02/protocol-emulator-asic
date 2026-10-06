(* Prints the Verilog for the chip. Usage: generate.exe [asic|sim] *)

open! Core
open! Hardcaml

let () =
  let mode =
    match Sys.get_argv () with
    | [| _; "sim" |] -> Pemu.Cfg_store.Sim
    | _ -> Pemu.Cfg_store.Asic
  in
  print_string "// Generated from hw/ by bin/generate.exe. Do not edit.\n\n";
  Rtl.create Verilog [ Pemu.Spike_top.circuit mode ]
  |> Rtl.full_hierarchy
  |> Rope.to_string
  |> print_string
;;
