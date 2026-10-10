(* The engine's ALU, for the register (ALU) and immediate (ALUI) instruction groups. A functor
   over Comb, so the same logic builds the engine RTL and is handed to a SAT solver in the
   proof (test/test_alu_proof.ml). *)

open! Core
open Hardcaml

module Make (C : Comb.S) = struct
  open C

  type t =
    { result : C.t (* the value written to rd *)
    ; writes : C.t (* whether rd is written (CMP, TST, CMPI and TSTB only set flags) *)
    ; z : C.t (* new Z *)
    ; c : C.t (* new C *)
    }

  (* rotate a 17-bit value left by m (0..16) *)
  let rotl17 v m =
    List.foldi (bits_lsb m) ~init:v ~f:(fun k acc b -> mux2 b (rotl acc ~by:(1 lsl k)) acc)
  ;;

  (* [width] bits, bit j set when j < k *)
  let below k ~width =
    concat_lsb (List.init width ~f:(fun j -> of_int_trunc ~width:(C.width k) j <: k))
  ;;

  (* n mod 17 for a 6-bit n, as 5 bits *)
  let mod17 n =
    let n7 = uresize n ~width:7 in
    let r =
      mux2
        (n7 >=:. 51)
        (n7 -:. 51)
        (mux2 (n7 >=:. 34) (n7 -:. 34) (mux2 (n7 >=:. 17) (n7 -:. 17) n7))
    in
    r.:[4, 0]
  ;;

  (* [imm] picks the ALUI group; [alu_fn] and [alui_fn] are the 3-bit function fields *)
  let create ~imm ~alu_fn ~alui_fn ~imm6 ~a ~b ~c_in =
    let n16 = uresize imm6 ~width:16 in
    (* one adder and one subtractor serve ADD/SUB/CMP and their immediate forms *)
    let y = mux2 imm n16 b in
    let sum = uresize a ~width:17 +: uresize y ~width:17 in
    let diff17 = uresize a ~width:17 -: uresize y ~width:17 in
    let diff = diff17.:[15, 0] in
    let borrow = msb diff17 in
    let alu_res = mux alu_fn [ b; sum.:[15, 0]; diff; a &: b; a |: b; a ^: b; diff; a &: b ] in
    let alu_writes = alu_fn <:. 6 in
    (* SHLI, SHRI, RLC and RRC share one 17-bit rotator. A shift is a rotation of {0, a} with
       the bits that wrapped around cleared; the carry lands in bit 16 either way. *)
    let m = mod17 imm6 in
    let big = imm6 >=:. 17 in
    let rotating = (alui_fn ==:. 5) |: (alui_fn ==:. 6) in
    let left = (alui_fn ==:. 3) |: (alui_fn ==:. 5) in
    let seventeen = of_int_trunc ~width:5 17 in
    let amount = mux2 left m (mux2 (m ==:. 0) (zero 5) (seventeen -: m)) in
    let rot = rotl17 (mux2 rotating c_in gnd @: a) amount in
    let shl = mux2 big (zero 16) (rot.:[15, 0] &: ~:(below m ~width:16)) in
    let shr = mux2 big (zero 16) (rot.:[15, 0] &: below (seventeen -: m) ~width:16) in
    let shift_carry = mux2 (imm6 ==:. 0) c_in (~:big &: rot.:[16, 16]) in
    let alui_res =
      mux alui_fn [ sum.:[15, 0]; diff; diff; shl; shr; rot.:[15, 0]; rot.:[15, 0]; a ]
    in
    let alui_writes = ~:((alui_fn ==:. 2) |: (alui_fn ==:. 7)) in
    let tstb_zero = ~:(mux imm6.:[3, 0] (bits_lsb a)) in
    let alu_z =
      mux2
        (alu_fn ==:. 6)
        (diff ==:. 0)
        (mux2 (alu_fn ==:. 7) ((a &: b) ==:. 0) (alu_res ==:. 0))
    and alui_z =
      mux2 (alui_fn ==:. 7) tstb_zero (mux2 (alui_fn ==:. 2) (diff ==:. 0) (alui_res ==:. 0))
    in
    let alu_c = mux alu_fn [ c_in; sum.:[16, 16]; borrow; c_in; c_in; c_in; borrow; c_in ]
    and alui_c =
      mux
        alui_fn
        [ sum.:[16, 16]; borrow; borrow; shift_carry; shift_carry; rot.:[16, 16]; rot.:[16, 16]; c_in ]
    in
    { result = mux2 imm alui_res alu_res
    ; writes = mux2 imm alui_writes alu_writes
    ; z = mux2 imm alui_z alu_z
    ; c = mux2 imm alui_c alu_c
    }
  ;;
end
