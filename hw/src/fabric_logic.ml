(* Combinational logic of the LUT fabric, written once for any Hardcaml backend.

   [Make (Signal)] is used to build the RTL, [Make (Bits)] gives a software model and
   [Make (Hardcaml_verify.Comb_gates)] turns the same logic into a SAT problem, which is how
   bitstreams get proven against their specs.

   Each element is a LUT4 whose 4 inputs each pick one of 8 sources:
     0..2  ext[0..2]
     3     element 0's output (the only combinational link between elements)
     4     own flop
     5     flop of element i-1
     6     flop of element i-2
     7     flop of element i+1

   Config word per element (31 bits): [15:0] lut, [27:16] input selects (4 x 3 bits),
   [28] output the flop instead of the LUT, [29] init value, [30] clock: 0 = TX ticks,
   1 = RX ticks. *)

open! Core
open! Hardcaml

let cfg_bits = 31

module Make (C : Comb.S) = struct
  open C

  let bit x i = x.:[i, i]
  let use_ff cfg = bit cfg 28
  let init cfg = bit cfg 29
  let rx_clocked cfg = bit cfg 30

  let lut_out ~cfg ~sources =
    let pick k = mux cfg.:[18 + (3 * k), 16 + (3 * k)] sources in
    let index = concat_msb [ pick 3; pick 2; pick 1; pick 0 ] in
    mux index (bits_lsb cfg.:[15, 0])
  ;;

  (* Given every element's config word, the current flop values and the 3 external inputs,
     return each element's LUT output (the flop's next value) and its visible output. *)
  let step ~(cfgs : t array) ~(q : t array) ~ext =
    let n = Array.length cfgs in
    let q_at i = if i >= 0 && i < n then q.(i) else gnd in
    let f = Array.create ~len:n gnd in
    let out = Array.create ~len:n gnd in
    for i = 0 to n - 1 do
      let sources =
        [ bit ext 0
        ; bit ext 1
        ; bit ext 2
        ; (if i = 0 then gnd else out.(0))
        ; q.(i)
        ; q_at (i - 1)
        ; q_at (i - 2)
        ; q_at (i + 1)
        ]
      in
      f.(i) <- lut_out ~cfg:cfgs.(i) ~sources;
      out.(i) <- mux2 (use_ff cfgs.(i)) q.(i) f.(i)
    done;
    f, out
  ;;
end
