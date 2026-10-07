(* Prints the Verilog for the chip. Usage: generate.exe [chip|chip2|seq|fabric] [asic|sim] *)

open! Core
open! Hardcaml

let () =
  let args = Sys.get_argv () |> Array.to_list |> List.tl_exn in
  let has a = List.mem args a ~equal:String.equal in
  let mode = if has "sim" then Pemu.Cfg_store.Sim else Pemu.Cfg_store.Asic in
  let scope = Scope.create ~flatten_design:false () in
  let circuit =
    if has "chip2"
    then Pemu.Chip.circuit ~n_engines:2 Pemu.Chip.Asic scope
    else if has "chip"
    then Pemu.Chip.circuit Pemu.Chip.Asic scope
    else if has "fabric"
    then Pemu.Spike_top.circuit mode
    else Pemu.Seq_spike.circuit ()
  in
  print_string "// Generated from hw/ by bin/generate.exe. Do not edit.\n\n";
  Rtl.create ~database:(Scope.circuit_database scope) Verilog [ circuit ]
  |> Rtl.full_hierarchy
  |> Rope.to_string
  |> print_string
;;
