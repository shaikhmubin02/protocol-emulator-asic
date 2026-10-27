(* Prove that a fabric bitstream computes exactly what its spec says, for every possible
   state and input, by handing the fabric logic and the spec to a SAT solver.

   The fabric logic comes from the same Fabric_logic.Make functor the RTL is built from, so
   what gets proven is the logic that goes on the chip. *)

open! Core
open! Hardcaml
module G = Hardcaml_verify.Comb_gates
module L = Pemu.Fabric_logic.Make (G)

let n_le = 24

(* Reflected CRC, one bit per step. *)
let crc_spec ~width:n ~poly_reflected crc din =
  let open G in
  let fb = lsb crc ^: din in
  (gnd @: crc.:[n - 1, 1]) ^: mux2 fb (of_int_trunc ~width:n poly_reflected) (zero n)
;;

(* Elements 1..width hold the CRC. The unused elements above it start at 0 after init; we
   check that they stay 0, so the proof covers every step, not just the first one. *)
let prove ~width ~poly_reflected words =
  let cfgs = Array.map words ~f:(fun w -> G.of_int_trunc ~width:Pemu.Fabric_logic.cfg_bits w) in
  let crc = G.input "crc" width
  and din = G.input "din" 1
  and q0 = G.input "q0" 1 in
  let q =
    Array.init n_le ~f:(fun i ->
      if i = 0 then q0 else if i <= width then G.(crc.:[i - 1, i - 1]) else G.gnd)
  in
  let f, _ = L.step ~cfgs ~q ~ext:G.(gnd @: gnd @: din) in
  let next_crc = G.concat_lsb (List.init width ~f:(fun i -> f.(i + 1))) in
  let next_unused = G.concat_lsb (List.init (n_le - width - 1) ~f:(fun i -> f.(width + 1 + i))) in
  let spec = crc_spec ~width ~poly_reflected crc din in
  let ok = G.(next_crc ==: spec &: (next_unused ==:. 0)) in
  match Hardcaml_verify.Solver.(solve ~solver:minisat) (G.cnf G.(~:ok)) with
  | Ok Unsat -> print_endline "proved: bitstream = spec for all states and inputs"
  | Ok (Sat model) ->
    print_s [%message "counterexample" (model : Hardcaml_verify.Cnf.Model_with_vectors.input list)]
  | Error e -> print_s [%message "solver error" (e : Error.t)]
;;

let%expect_test "CRC-16/USB bitstream" =
  prove
    ~width:16
    ~poly_reflected:0xA001
    (Pemu.Bitstream.crc ~n_le ~width:16 ~poly_reflected:0xA001 ~init:0xFFFF);
  [%expect {| proved: bitstream = spec for all states and inputs |}]
;;

let%expect_test "CRC-5/USB bitstream" =
  prove
    ~width:5
    ~poly_reflected:0x14
    (Pemu.Bitstream.crc ~n_le ~width:5 ~poly_reflected:0x14 ~init:0x1F);
  [%expect {| proved: bitstream = spec for all states and inputs |}]
;;

let%expect_test "a corrupted bitstream is caught" =
  let words = Pemu.Bitstream.crc ~n_le ~width:16 ~poly_reflected:0xA001 ~init:0xFFFF in
  words.(5) <- words.(5) lxor 0b10;
  prove ~width:16 ~poly_reflected:0xA001 words;
  [%expect {|
    (counterexample
     (model (((name crc) (value 0000000000100000)) ((name din) (value 0)))))
    |}]
;;

(* The 10BASE-T bitstreams, on the chip's 8 elements: every next state and every role output
   for all 256 states and all inputs, against the decoder written out as plain logic. *)
let prove_all ~words ~ext ~q ~spec =
  let cfgs = Array.map words ~f:(fun w -> G.of_int_trunc ~width:Pemu.Fabric_logic.cfg_bits w) in
  let f, out = L.step ~cfgs ~q ~ext in
  let ok =
    List.map (spec ~f ~out) ~f:(fun (impl, want) -> G.(impl ==: want)) |> List.reduce_exn ~f:G.( &: )
  in
  match Hardcaml_verify.Solver.(solve ~solver:minisat) (G.cnf G.(~:ok)) with
  | Ok Unsat -> print_endline "proved: bitstream = spec for all states and inputs"
  | Ok (Sat model) ->
    print_s [%message "counterexample" (model : Hardcaml_verify.Cnf.Model_with_vectors.input list)]
  | Error e -> print_s [%message "solver error" (e : Error.t)]
;;

let%expect_test "10BASE-T TX bitstream: Manchester" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and d = G.input "d" 1 in
  prove_all
    ~words:(Pemu.Bitstream.eth_tx ~n_le:8)
    ~ext:G.(gnd @: gnd @: d)
    ~q
    ~spec:(fun ~f ~out ->
      let first = q.(0) in
      (* element 0 toggles; line = complement first, then the bit; hold in the first half;
         the unused elements stay 0 *)
      [ f.(0), G.( ~: ) first; out.(1), G.(d ^: first); out.(0), first ]
      @ List.init 6 ~f:(fun k -> f.(k + 2), G.gnd));
  [%expect {| proved: bitstream = spec for all states and inputs |}]
;;

let%expect_test "10BASE-T RX bitstream: edge decoder" =
  let q = Array.init 8 ~f:(fun i -> G.input (sprintf "q%d" i) 1)
  and s = G.input "sample" 1 in
  prove_all
    ~words:(Pemu.Bitstream.eth_rx ~n_le:8)
    ~ext:G.(gnd @: s @: gnd)
    ~q
    ~spec:(fun ~f ~out ->
      let open G in
      let p = q.(1)
      and t1 = q.(2)
      and t2 = q.(3)
      and t3 = q.(4)
      and u = q.(5)
      and seen = q.(7) in
      let e = s ^: p in
      let take = e &: (t3 |: u) in
      [ f.(1), s
      ; f.(2), ~:e
      ; f.(3), t1 &: ~:e
      ; f.(4), t2 &: ~:e
      ; f.(5), mux2 e ~:(t3 |: u) u
      ; f.(7), seen |: (e &: u)
      ; out.(1), s (* rx bit *)
      ; out.(6), ~:(take &: seen) (* drop *)
      ; out.(7), seen (* flag *)
      ]);
  [%expect {| proved: bitstream = spec for all states and inputs |}]
;;
