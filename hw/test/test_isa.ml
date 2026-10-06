open! Core
open Pemu

(* Every 16-bit word either decodes to an instruction that encodes back to the same word, or
   is rejected. Every instruction also survives printing and re-assembling. *)
let%expect_test "encode/decode/assemble round trip over all 65536 words" =
  let valid = ref 0 in
  for w = 0 to 0xffff do
    match Isa.decode w with
    | None -> ()
    | Some i ->
      incr valid;
      let w' = Isa.encode_exn i in
      if w' <> w then raise_s [%message "encode mismatch" (w : int) (w' : int) (i : Isa.t)];
      (match Asm.assemble (Isa.to_string i) with
       | Ok [| w'' |] when w'' = w -> ()
       | other ->
         raise_s
           [%message
             "assembler mismatch"
               (Isa.to_string i : string)
               (other : (int array, string) Result.t)])
  done;
  printf "%d of 65536 words are valid instructions\n" !valid;
  [%expect {| 22451 of 65536 words are valid instructions |}]
;;

let%expect_test "assembler: labels, constants, CSR names, errors" =
  let src =
    {|
      .equ COUNT 5
start: ldi r1, COUNT       ; loop counter
loop:  pin p8, tgl
       djnz r1, loop
       csrwi tmo, 0x10
       jmp start
|}
  in
  (match Asm.assemble src with
   | Ok words -> Array.iter words ~f:(fun w -> printf "%04x  %s\n" w (Isa.to_string (Option.value_exn (Isa.decode w))))
   | Error e -> print_endline e);
  (match Asm.assemble "ldi r9, 1" with
   | Ok _ -> print_endline "accepted?!"
   | Error e -> print_endline e);
  (match Asm.assemble "j sometimes, 3" with
   | Ok _ -> print_endline "accepted?!"
   | Error e -> print_endline e);
  [%expect {|
    1205  ldi r1, 5
    7900  pin p8, tgl, 0
    5201  djnz r1, 1
    e404  csrwi 4, 16
    4000  j always, 0
    line 1: ("operand out of range" rd (v 9) (max 7))
    line 1: unknown condition "sometimes"
    |}]
;;
