(* Records the pads of a simulation as a VCD file, one sample per clock, for outside tools (sigrok
   decoders) to read. Only active when PEMU_VCD_DIR is set, so normal test runs write nothing.

   Channels: ui0..ui7 (inputs), uo0..uo7 (outputs), uio0..uio7 (the bidirectional pins as the
   wire sees them: the chip's output when it drives the pin, otherwise the input). *)

open! Core

type t =
  { oc : Out_channel.t
  ; path : string
  ; ns_per_cycle : float
  ; pullups : int (* uio pins pulled high when nothing drives them (the test gives no input) *)
  ; mutable last : int (* the 24 channel bits last written, -1 before the first sample *)
  ; mutable cycle : int
  }

let dir = Sys.getenv "PEMU_VCD_DIR"
let open_files : t list ref = ref []

let names =
  List.concat
    [ List.init 8 ~f:(sprintf "ui%d"); List.init 8 ~f:(sprintf "uo%d"); List.init 8 ~f:(sprintf "uio%d") ]
;;

(* one printable VCD identifier per channel *)
let id k = String.make 1 (Char.of_int_exn (Char.to_int '!' + k))
let time t = Float.iround_nearest_exn (Float.of_int t.cycle *. t.ns_per_cycle)

let close t =
  fprintf t.oc "#%d\n" (time t);
  Out_channel.close t.oc
;;

let () = at_exit (fun () -> List.iter !open_files ~f:close)

let create ?(ns_per_cycle = 20.0) ?(pullups = 0) name =
  Option.map dir ~f:(fun dir ->
    let path = dir ^/ name ^ ".vcd" in
    let oc = Out_channel.create path in
    Out_channel.write_all (dir ^/ name ^ ".expect") ~data:"";
    fprintf oc "$timescale 1ns $end\n$scope module pads $end\n";
    List.iteri names ~f:(fun k n -> fprintf oc "$var wire 1 %s %s $end\n" (id k) n);
    fprintf oc "$upscope $end\n$enddefinitions $end\n";
    let t = { oc; path; ns_per_cycle; pullups; last = -1; cycle = 0 } in
    open_files := t :: !open_files;
    t)
;;

(* the pads during one clock cycle; [uio_out] and [uio_oe] are what the chip drives *)
let sample t ~ui_in ~uo_out ~uio_in ~uio_out ~uio_oe =
  let uio = uio_out land uio_oe lor ((uio_in lor t.pullups) land lnot uio_oe) land 0xff in
  let v = (ui_in land 0xff) lor ((uo_out land 0xff) lsl 8) lor (uio lsl 16) in
  if v <> t.last
  then (
    fprintf t.oc "#%d\n" (time t);
    for k = 0 to 23 do
      let b = (v lsr k) land 1 in
      if t.last < 0 || (t.last lsr k) land 1 <> b then fprintf t.oc "%d%s\n" b (id k)
    done;
    t.last <- v);
  t.cycle <- t.cycle + 1
;;

(* What the test itself sent and saw, next to the VCD as <name>.expect, one "key v v v" line
   (hex bytes) per call, for the checker to compare with what the decoders read. *)
let note t key values =
  let path = String.chop_suffix_if_exists t.path ~suffix:".vcd" ^ ".expect" in
  Out_channel.with_file path ~append:true ~f:(fun oc ->
    fprintf oc "%s %s\n" key (String.concat ~sep:" " (List.map values ~f:(sprintf "%02x"))))
;;
