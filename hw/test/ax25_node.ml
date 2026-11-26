(* AX.25 packet radio (and APRS) over Bell 202 audio, written from the AX.25 2.2 specification:
   UI frames between HDLC flags, a 0 after five 1s, the FCS-16 (as in HDLC), bytes LSB first,
   NRZI (a 0 changes the line, a 1 leaves it), and Bell 202's 1200 Hz while the line is 1, 2200 Hz
   while it is 0. Times in cycles, fractional, so tests can run faster than real time. *)
open! Core

(* a callsign field: 6 characters padded with spaces, shifted left one bit, then the SSID byte;
   [last] marks the end of the address field *)
let address ?(last = false) call ssid =
  let call = String.pad_right call ~len:6 ~char:' ' in
  List.map (String.to_list call) ~f:(fun c -> Char.to_int c lsl 1)
  @ [ 0x60 lor (ssid lsl 1) lor if last then 1 else 0 ]
;;

let ui_frame ~dest ~src ~path info =
  let n = List.length path in
  address (fst dest) (snd dest)
  @ address (fst src) (snd src) ~last:(n = 0)
  @ List.concat (List.mapi path ~f:(fun i (c, s) -> address c s ~last:(i = n - 1)))
  @ [ 0x03; 0xF0 ]
  @ List.map (String.to_list info) ~f:Char.to_int
;;

let with_fcs = Hdlc_node.with_fcs

let lsb b = List.init 8 ~f:(fun k -> (b lsr k) land 1)
let flag = lsb 0x7E

let stuff bits =
  let rec go ones acc = function
    | [] -> List.rev acc
    | b :: rest ->
      if b = 1 && ones = 4 then go 0 (0 :: 1 :: acc) rest
      else go (if b = 1 then ones + 1 else 0) (b :: acc) rest
  in
  go 0 [] bits
;;

(* the bits of frames on the line, before NRZI *)
let bits ?(flags = 8) frames =
  List.concat_map frames ~f:(fun f ->
    List.concat (List.init flags ~f:(fun _ -> flag)) @ stuff (List.concat_map f ~f:lsb) @ flag)
  @ flag
;;

let nrzi bits =
  let level = ref 1 in
  List.map bits ~f:(fun b ->
    if b = 0 then level := 1 - !level;
    !level)
;;

(* the audio for line levels, a square wave without phase jumps: each half period has the tone
   of the line when it starts *)
let audio ~bit ~mark ~space ?(lead = 2000) levels =
  let levels = Array.of_list levels in
  let n = lead + Float.iround_up_exn (Float.of_int (Array.length levels) *. bit) in
  let out = Array.create ~len:n 0 in
  let next = ref (Float.of_int lead) and v = ref 0 in
  for c = lead to n - 1 do
    if Float.(of_int c >= !next)
    then (
      v := 1 - !v;
      let k = Float.iround_down_exn (Float.of_int (c - lead) /. bit) in
      next := !next +. if levels.(Int.min k (Array.length levels - 1)) = 1 then mark else space);
    out.(c) <- !v
  done;
  out
;;

(* reading audio: the tone of each half period, from the time between edges; then the bits,
   sampled a bit apart and re-aligned on every change of tone; then NRZI, flags, stuffing and
   the FCS. Returns the frames (bytes without FCS, FCS right) *)
let decode ~bit ~threshold samples =
  let n = Array.length samples in
  let tone = Array.create ~len:n 1 in
  let last_edge = ref 0
  and cur = ref 1 in
  for c = 1 to n - 1 do
    if samples.(c) <> samples.(c - 1)
    then (
      let half = Float.of_int (c - !last_edge) in
      cur := if Float.(half > threshold) then 1 else 0;
      last_edge := c);
    tone.(c) <- !cur
  done;
  let levels = ref []
  and next = ref (bit /. 2.) in
  for c = 1 to n - 1 do
    if tone.(c) <> tone.(c - 1) then next := Float.of_int c +. (bit /. 2.);
    if Float.(of_int c >= !next)
    then (
      levels := tone.(c) :: !levels;
      next := !next +. bit)
  done;
  let levels = List.rev !levels in
  let decoded =
    List.map2_exn (List.drop_last_exn levels) (List.tl_exn levels) ~f:(fun a b -> if a = b then 1 else 0)
  in
  (* flags and stuffing *)
  let frames = ref []
  and cur = ref []
  and ones = ref 0
  and in_frame = ref false in
  List.iter decoded ~f:(fun b ->
    if b = 1
    then (
      incr ones;
      if !ones = 6
      then (
        (* a flag: the bits before it (0 and five 1s) are its own *)
        let data = List.rev !cur in
        let data = List.take data (List.length data - 6) in
        if !in_frame && List.length data >= 16
        then frames := data :: !frames;
        in_frame := true;
        cur := [])
      else cur := 1 :: !cur)
    else (
      if !ones >= 5 then () (* a stuffed 0, or the 0 that ends a flag *) else cur := 0 :: !cur;
      ones := 0));
  List.rev_map !frames ~f:(fun bits ->
    let bytes =
      List.map (List.chunks_of bits ~length:8) ~f:(fun l ->
        List.foldi l ~init:0 ~f:(fun k a x -> a lor (x lsl k)))
    in
    let body = List.take bytes (List.length bytes - 2) in
    body, List.length bits % 8 = 0 && List.equal Int.equal (with_fcs body) bytes)
;;

(* a frame's addresses and text, as APRS software would show them *)
let to_string bytes =
  let call k =
    let field = List.sub bytes ~pos:(7 * k) ~len:7 in
    let s = String.of_char_list (List.map (List.take field 6) ~f:(fun b -> Char.of_int_exn (b lsr 1))) in
    let ssid = (List.nth_exn field 6 lsr 1) land 0xF in
    String.strip s ^ if ssid = 0 then "" else sprintf "-%d" ssid
  in
  let rec n_addr k = if k > 9 || List.nth_exn bytes ((7 * k) + 6) land 1 = 1 then k + 1 else n_addr (k + 1) in
  let na = n_addr 0 in
  let info = List.drop bytes ((7 * na) + 2) in
  sprintf "%s>%s%s:%s" (call 1) (call 0)
    (String.concat (List.init (na - 2) ~f:(fun k -> "," ^ call (k + 2))))
    (String.of_char_list (List.map info ~f:Char.of_int_exn))
;;
