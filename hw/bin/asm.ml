(* Assembles a program and prints one 16-bit word per line in hex. Usage: asm.exe file.s *)

open! Core

let () =
  match Sys.get_argv () with
  | [| _; file |] ->
    (match Pemu.Asm.assemble (In_channel.read_all file) with
     | Ok words -> Array.iter words ~f:(printf "%04x\n")
     | Error e ->
       eprintf "%s: %s\n" file e;
       exit 1)
  | _ ->
    eprintf "usage: asm.exe file.s\n";
    exit 2
;;
