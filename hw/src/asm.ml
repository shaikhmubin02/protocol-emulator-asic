(* Two-pass assembler for engine programs.

   Syntax, one instruction per line (case doesn't matter):
     label:                     defines a label (may share a line with an instruction)
     .equ NAME value            defines a constant
     ; comment                  also #
   Operands are registers (r0..r7), pins (p0..p31), numbers (12, 0x1f, 0b101), labels,
   .equ names and CSR names (tmo, baud, ...). Instruction syntax is what [Isa.to_string]
   prints, plus `jmp label` for `j always, label`. *)

open! Core

exception Error of int * string

let fail line fmt = Printf.ksprintf (fun s -> raise (Error (line, s))) fmt

let strip_comment s =
  match String.lfindi s ~f:(fun _ c -> Char.equal c ';' || Char.equal c '#') with
  | Some i -> String.prefix s i
  | None -> s
;;

let tokens s =
  String.split_on_chars s ~on:[ ' '; '\t'; ',' ]
  |> List.filter ~f:(fun t -> not (String.is_empty t))
;;

type line =
  { number : int
  ; words : string list
  }

(* Pass 1: labels -> addresses, constants, and the instruction lines. *)
let collect source =
  let labels = String.Table.create () in
  let consts = String.Table.create () in
  let lines = ref [] in
  let pc = ref 0 in
  List.iteri (String.split_lines source) ~f:(fun i raw ->
    let number = i + 1 in
    let text = String.strip (String.lowercase (strip_comment raw)) in
    let text =
      match String.lsplit2 text ~on:':' with
      | Some (label, rest) when not (String.exists label ~f:Char.is_whitespace) ->
        if Hashtbl.mem labels label then fail number "label %s defined twice" label;
        Hashtbl.set labels ~key:label ~data:!pc;
        String.strip rest
      | _ -> text
    in
    match tokens text with
    | [] -> ()
    | [ ".equ"; name; value ] -> Hashtbl.set consts ~key:name ~data:value
    | ".equ" :: _ -> fail number ".equ needs a name and a value"
    | words ->
      lines := { number; words } :: !lines;
      incr pc);
  labels, consts, List.rev !lines
;;

let assemble_exn source =
  let labels, consts, lines = collect source in
  let rec number line s =
    let parse_int s =
      try Some (Int.of_string s) with
      | _ -> None
    in
    match parse_int s with
    | Some v -> v
    | None ->
      (match Hashtbl.find labels s with
       | Some v -> v
       | None ->
         (match Hashtbl.find consts s with
          | Some v -> number line v
          | None ->
            (match List.Assoc.find Isa.Csr.names s ~equal:String.equal with
             | Some v -> v
             | None -> fail line "unknown value %S" s)))
  in
  let prefixed line ~prefix s =
    match String.chop_prefix s ~prefix with
    | Some n -> number line n
    | None -> fail line "expected %s<n>, got %S" prefix s
  in
  let reg line s = prefixed line ~prefix:"r" s in
  let pin line s =
    match String.chop_prefix s ~prefix:"p" with
    | Some n -> number line n
    | None -> number line s
  in
  let bit line s =
    match number line s with
    | 0 -> false
    | 1 -> true
    | _ -> fail line "expected 0 or 1, got %S" s
  in
  let pick line what table s =
    match List.Assoc.find table s ~equal:String.equal with
    | Some v -> v
    | None -> fail line "unknown %s %S" what s
  in
  let alu_ops = List.map Isa.all_of_alu ~f:(fun a -> String.lowercase (Sexp.to_string (Isa.sexp_of_alu a)), a) in
  let alui_ops =
    List.map Isa.all_of_alui ~f:(fun a -> String.lowercase (Sexp.to_string (Isa.sexp_of_alui a)), a)
  in
  let conds =
    List.map Isa.all_of_cond ~f:(fun c ->
      String.chop_prefix_exn (Isa.to_string (Isa.J (c, 0))) ~prefix:"j "
      |> String.chop_suffix_exn ~suffix:", 0", c)
  in
  let actions =
    List.map Isa.all_of_pin_action ~f:(fun a ->
      match tokens (Isa.to_string (Isa.Pin (a, 0, 0))) with
      | [ _; _; name; _ ] -> name, a
      | _ -> assert false)
  in
  let events =
    List.map Isa.all_of_event ~f:(fun e ->
      match tokens (Isa.to_string (Isa.Wait (Isa.Wait_event e))) with
      | [ _; _; name ] -> name, e
      | _ -> assert false)
  in
  let one { number = n; words } : Isa.t =
    let num = number n
    and reg = reg n
    and pin = pin n in
    match words with
    | [ "nop" ] -> Nop
    | [ "halt" ] -> Halt
    | [ "ret" ] -> Ret
    | [ "push"; r ] -> Push (reg r)
    | [ "pull"; r ] -> Pull (reg r)
    | [ "sig"; f ] -> Sig (num f)
    | [ "clrf"; f ] -> Clrf (num f)
    | [ "tx"; r ] -> Tx (reg r)
    | [ "rx"; r ] -> Rx (reg r)
    | [ "crci" ] -> Crci
    | [ "ben"; v ] -> Ben (bit n v)
    | [ "ldi"; d; v ] -> Ldi (reg d, num v)
    | [ "ldih"; d; v ] -> Ldih (reg d, num v)
    | [ op; d; s ] when List.Assoc.mem alu_ops op ~equal:String.equal ->
      Alu (pick n "alu op" alu_ops op, reg d, reg s)
    | [ op; d; v ] when List.Assoc.mem alui_ops op ~equal:String.equal ->
      Alui (pick n "alu op" alui_ops op, reg d, num v)
    | [ "j"; cc; t ] -> J (pick n "condition" conds cc, num t)
    | [ "jmp"; t ] -> J (Always, num t)
    | [ "djnz"; d; t ] -> Djnz (reg d, num t)
    | [ "call"; t ] -> Call (num t)
    | [ "pin"; p; a ] -> Pin (pick n "pin action" actions a, pin p, 0)
    | [ "pin"; p; a; d ] -> Pin (pick n "pin action" actions a, pin p, num d)
    | [ "outg"; g; s ] -> Outg (num g, reg s, 0)
    | [ "outg"; g; s; d ] -> Outg (num g, reg s, num d)
    | [ "inp"; d; g ] -> Inp (reg d, num g)
    | [ "wait"; "pin"; p; v ] -> Wait (Wait_pin (pin p, bit n v))
    | [ "wait"; "flag"; f; v ] -> Wait (Wait_flag (num f, bit n v))
    | [ "wait"; "time"; r ] -> Wait (Wait_time (reg r))
    | [ "wait"; "event"; e ] -> Wait (Wait_event (pick n "event" events e))
    | [ "dly"; c ] -> Dly (num c)
    | [ "csrr"; d; c ] -> Csrr (reg d, num c)
    | [ "csrw"; c; s ] -> Csrw (num c, reg s)
    | [ "csrwi"; c; v ] -> Csrwi (num c, num v)
    | _ -> fail n "can't parse %S" (String.concat ~sep:" " words)
  in
  let program =
    List.map lines ~f:(fun l ->
      let i = one l in
      match Isa.encode_exn i with
      | w -> w
      | exception exn -> fail l.number "%s" (Exn.to_string exn))
  in
  if List.length program > 256 then fail 0 "program is %d words, max 256" (List.length program);
  Array.of_list program
;;

let assemble source =
  match assemble_exn source with
  | words -> Ok words
  | exception Error (line, msg) -> Error (sprintf "line %d: %s" line msg)
;;
