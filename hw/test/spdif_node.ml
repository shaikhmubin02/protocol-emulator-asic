(* An S/PDIF receiver written from IEC 60958, working from the edges alone, as a real receiver
   does: the time between edges is 1, 2 or 3 half cells (3 only inside a preamble). A preamble is
   8 half cells: from a low line X (M) = 11100010, Y (W) = 11100100, Z (B) = 11101000, or the
   same inverted from a high line. Then 28 bits in biphase-mark: every cell starts with a
   transition, a 1 has another in the middle; aux and audio (24 bits, LSB first), V, U, C, and P,
   which makes the 28 bits even. *)
open! Core

type subframe =
  { preamble : char (* 'B', 'M' or 'W' *)
  ; audio : int (* 24 bits *)
  ; v : int
  ; u : int
  ; c : int
  ; parity_ok : bool
  ; biphase_ok : bool (* every cell started with a transition *)
  ; at : int (* the cycle the preamble started *)
  }

let preambles = [ 'M', [ 1; 1; 1; 0; 0; 0; 1; 0 ]; 'W', [ 1; 1; 1; 0; 0; 1; 0; 0 ]; 'B', [ 1; 1; 1; 0; 1; 0; 0; 0 ] ]

(* the half cells, from the edges: [ui] is the half-cell time in cycles *)
let half_cells samples ~ui =
  let n = Array.length samples in
  let edges = List.filter (List.init n ~f:Fn.id) ~f:(fun i -> i > 0 && samples.(i) <> samples.(i - 1)) in
  let rec go acc bad = function
    | a :: (b :: _ as rest) ->
      let k = Float.iround_nearest_exn (Float.of_int (b - a) /. ui) in
      let bad = if k < 1 || k > 3 then bad + 1 else bad in
      let level = samples.(a) in
      go (List.rev_append (List.init (Int.max k 0) ~f:(fun j -> level, a + Float.iround_nearest_exn (Float.of_int j *. ui))) acc) bad rest
    | _ -> List.rev acc, bad
  in
  go [] 0 edges
;;

let decode samples ~ui =
  let cells, bad_runs = half_cells samples ~ui in
  let cells = Array.of_list cells in
  let n = Array.length cells in
  let level i = fst cells.(i) in
  let matches i =
    if i + 8 > n
    then None
    else
      List.find_map preambles ~f:(fun (name, pat) ->
        let first = level i in
        (* from a low line the pattern as written, from a high line inverted *)
        if List.for_alli pat ~f:(fun j p -> level (i + j) = if first = 1 then p else 1 - p)
           && (i = 0 || level (i - 1) <> first)
        then Some name
        else None)
  in
  let rec go i acc =
    if i + 64 > n
    then List.rev acc
    else (
      match matches i with
      | None -> go (i + 1) acc
      | Some name ->
        let bits = Array.init 28 ~f:(fun k -> level (i + 8 + (2 * k)) <> level (i + 9 + (2 * k))) in
        let biphase_ok =
          List.for_all (List.init 28 ~f:Fn.id) ~f:(fun k ->
            level (i + 8 + (2 * k)) <> level (i + 7 + (2 * k)))
        in
        let b k = Bool.to_int bits.(k) in
        let audio = List.fold (List.init 24 ~f:Fn.id) ~init:0 ~f:(fun a k -> a lor (b k lsl k)) in
        let ones = Array.count bits ~f:Fn.id in
        go
          (i + 64)
          ({ preamble = name
           ; audio
           ; v = b 24
           ; u = b 25
           ; c = b 26
           ; parity_ok = ones % 2 = 0
           ; biphase_ok
           ; at = snd cells.(i)
           }
           :: acc))
  in
  go 0 [], bad_runs
;;
