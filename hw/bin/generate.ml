(* Prints the Verilog for the chip. Usage: generate.exe [seq|fabric] [asic|sim] *)

open! Core
open! Hardcaml

let () =
  let args = Sys.get_argv () |> Array.to_list |> List.tl_exn in
  let mode =
    if List.mem args "sim" ~equal:String.equal
    then Pemu.Cfg_store.Sim
    else Pemu.Cfg_store.Asic
  in
  let circuit =
    if List.mem args "fabric" ~equal:String.equal
    then Pemu.Spike_top.circuit mode
    else Pemu.Seq_spike.circuit ()
  in
  print_string "// Generated from hw/ by bin/generate.exe. Do not edit.\n\n";
  Rtl.create Verilog [ circuit ] |> Rtl.full_hierarchy |> Rope.to_string |> print_string
;;
