(* Prove the engine's ALU correct for every input: each ALU and ALUI function, every pair of
   16-bit operands, every carry-in and every 6-bit immediate. The ALU logic comes from the same
   Alu.Make functor the engine RTL is built from; the spec below is written separately and as
   plainly as possible from the instruction set (the semantics the golden model implements). A
   SAT solver looks for any input where the two differ. *)

open! Core
open! Hardcaml
module G = Hardcaml_verify.Comb_gates
module A = Pemu.Alu.Make (G)

type spec =
  { result : G.t
  ; writes : bool
  ; z : G.t
  ; c : G.t
  }

let writing result ~c = { result; writes = true; z = G.(result ==:. 0); c }

(* ALU group: rd = rd op rs *)
let alu_spec (fn : Pemu.Isa.alu) ~a ~b ~c_in =
  let open G in
  let a17 = uresize a ~width:17
  and b17 = uresize b ~width:17 in
  match fn with
  | Mov -> writing b ~c:c_in
  | Add ->
    let s = a17 +: b17 in
    writing s.:[15, 0] ~c:(msb s)
  | Sub -> writing (a -: b) ~c:(a <: b)
  | And -> writing (a &: b) ~c:c_in
  | Or -> writing (a |: b) ~c:c_in
  | Xor -> writing (a ^: b) ~c:c_in
  | Cmp -> { result = zero 16; writes = false; z = (a -: b) ==:. 0; c = a <: b }
  | Tst -> { result = zero 16; writes = false; z = (a &: b) ==:. 0; c = c_in }
;;

(* one step of a rotate through the carry: (C, a) as a 17-bit ring *)
let rotate_left (c, a) = G.msb a, G.(a.:[14, 0] @: c)
let rotate_right (c, a) = G.lsb a, G.(c @: a.:[15, 1])

(* ALUI group with the immediate fixed at k; the proof puts all 64 values side by side *)
let alui_spec_k (fn : Pemu.Isa.alui) ~k ~a ~c_in =
  let open G in
  let n = of_int_trunc ~width:16 k in
  match fn with
  | Addi | Subi | Cmpi ->
    alu_spec
      (match fn with
       | Addi -> Add
       | Subi -> Sub
       | _ -> Cmp)
      ~a
      ~b:n
      ~c_in
  | Shli ->
    let c = if k = 0 then c_in else if k <= 16 then a.:(16 - k) else gnd in
    writing (if k >= 16 then zero 16 else sll a ~by:k) ~c
  | Shri ->
    let c = if k = 0 then c_in else if k <= 16 then a.:(k - 1) else gnd in
    writing (if k >= 16 then zero 16 else srl a ~by:k) ~c
  | Rlc ->
    let c, r = Fn.apply_n_times ~n:k rotate_left (c_in, a) in
    writing r ~c
  | Rrc ->
    let c, r = Fn.apply_n_times ~n:k rotate_right (c_in, a) in
    writing r ~c
  | Tstb -> { result = zero 16; writes = false; z = ~:(a.:(k land 15)); c = c_in }
;;

let check ~rtl:(r : A.t) specs ~sel =
  (* [specs] are the cases [sel] chooses between *)
  let open G in
  let pick f = mux sel (List.map specs ~f) in
  let writes = pick (fun s -> if s.writes then vdd else gnd) in
  let ok =
    r.writes ==: writes
    &: (~:writes |: (r.result ==: pick (fun s -> s.result)))
    &: (r.z ==: pick (fun s -> s.z))
    &: (r.c ==: pick (fun s -> s.c))
  in
  match Hardcaml_verify.Solver.(solve ~solver:minisat) (G.cnf ~:ok) with
  | Ok Unsat -> "proved"
  | Ok (Sat model) ->
    let model = (model : Hardcaml_verify.Cnf.Model_with_vectors.input list) in
    "counterexample " ^ Sexp.to_string [%sexp (model : Hardcaml_verify.Cnf.Model_with_vectors.input list)]
  | Error e -> "solver error " ^ Error.to_string_hum e
;;

let operands () = G.input "a" 16, G.input "b" 16, G.input "c_in" 1, G.input "imm6" 6

let prove_alu fn =
  let a, b, c_in, imm6 = operands () in
  let alu_fn = G.of_int_trunc ~width:3 (Pemu.Isa.index_of ~all:Pemu.Isa.all_of_alu fn ~equal:Pemu.Isa.equal_alu) in
  let rtl = A.create ~imm:G.gnd ~alu_fn ~alui_fn:(G.zero 3) ~imm6 ~a ~b ~c_in in
  check ~rtl [ alu_spec fn ~a ~b ~c_in ] ~sel:G.gnd
;;

let prove_alui ?(spec = alui_spec_k) fn =
  let a, b, c_in, imm6 = operands () in
  let alui_fn = G.of_int_trunc ~width:3 (Pemu.Isa.index_of ~all:Pemu.Isa.all_of_alui fn ~equal:Pemu.Isa.equal_alui) in
  let rtl = A.create ~imm:G.vdd ~alu_fn:(G.zero 3) ~alui_fn ~imm6 ~a ~b ~c_in in
  check ~rtl (List.init 64 ~f:(fun k -> spec fn ~k ~a ~c_in)) ~sel:imm6
;;

let%expect_test "every ALU function, for all operands and carry-in" =
  List.iter Pemu.Isa.all_of_alu ~f:(fun fn ->
    printf "%-4s %s\n" (Sexp.to_string [%sexp (fn : Pemu.Isa.alu)]) (prove_alu fn));
  [%expect {|
    Mov  proved
    Add  proved
    Sub  proved
    And  proved
    Or   proved
    Xor  proved
    Cmp  proved
    Tst  proved
    |}]
;;

let%expect_test "every ALUI function, for all operands, carry-in and all 64 immediates" =
  List.iter Pemu.Isa.all_of_alui ~f:(fun fn ->
    printf "%-4s %s\n" (Sexp.to_string [%sexp (fn : Pemu.Isa.alui)]) (prove_alui fn));
  [%expect {|
    Addi proved
    Subi proved
    Cmpi proved
    Shli proved
    Shri proved
    Rlc  proved
    Rrc  proved
    Tstb proved
    |}]
;;

(* the proof has teeth: a spec with SHRI's carry taken one bit too high is refuted *)
let%expect_test "a wrong spec is refuted" =
  let wrong fn ~k ~a ~c_in =
    let s = alui_spec_k fn ~k ~a ~c_in in
    if k >= 1 && k <= 15 then { s with c = G.(a.:(k)) } else s
  in
  print_endline (String.prefix (prove_alui ~spec:wrong Shri) 14);
  [%expect {| counterexample |}]
;;
