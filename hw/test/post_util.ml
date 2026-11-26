(* Helpers for the tests of protocols written after the RTL freeze. *)
open! Core
open Pemu

let bit v k = (v lsr k) land 1

let load name =
  match Asm.assemble (In_channel.read_all ("../firmware/" ^ name)) with
  | Ok w -> w
  | Error e -> failwith e
;;

let hex_bytes l = String.concat ~sep:" " (List.map l ~f:(sprintf "%02x"))
let bit_of (whole, frac) = Float.of_int whole +. (Float.of_int frac /. 256.)

(* Proofs of fabric configurations: for every state of the 8 elements and every input, the
   configuration computes the rule written out as plain logic. The fabric logic is the
   Fabric_logic.Make functor the RTL is built from. *)
module G = Hardcaml_verify.Comb_gates
module L = Pemu.Fabric_logic.Make (G)

let prove ~words ~ext ~q ~spec =
  let cfgs = Array.map words ~f:(fun w -> G.of_int_trunc ~width:Fabric_logic.cfg_bits w) in
  let f, out = L.step ~cfgs ~q ~ext in
  let ok =
    List.map (spec ~f ~out) ~f:(fun (impl, want) -> G.(impl ==: want)) |> List.reduce_exn ~f:G.( &: )
  in
  match Hardcaml_verify.Solver.(solve ~solver:minisat) (G.cnf G.(~:ok)) with
  | Ok Unsat -> print_endline "proved: configuration = rule for all states and inputs"
  | Ok (Sat model) ->
    print_s [%message "counterexample" (model : Hardcaml_verify.Cnf.Model_with_vectors.input list)]
  | Error e -> print_s [%message "solver error" (e : Error.t)]
;;

(* step an engine with the host: the next word from [q] if there is one, collecting what it
   sends into [acc] *)
let step ls q acc pads =
  let send = Queue.peek q in
  let read, wrote = Lockstep.step ?send ~receive:true ls pads in
  if wrote then ignore (Queue.dequeue_exn q : int);
  Option.iter read ~f:(fun v -> acc := v :: !acc)
;;

(* the whole chip against the chip model, every cycle, before each clock edge *)
let attach_chip_model (t : Chip_host.t) =
  let model = Chip_model.create () in
  t.before_edge
  <- (fun t ->
       let rtl =
         { Chip_model.uo_out = Chip_host.uo t; uio_out = Chip_host.uio_out t; uio_oe = Chip_host.uio_oe t }
       in
       if not (Chip_model.equal_outputs rtl (Chip_model.outputs model))
       then failwithf "chip and model differ at cycle %d" t.cycle ();
       Chip_model.step model
         { Model.Pads.ui_in = Chip_host.get t.i.ui_in; uio_in = Chip_host.get t.i.uio_in })
;;
