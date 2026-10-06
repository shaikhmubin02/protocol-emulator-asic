open! Core
open Pemu

let assemble src =
  match Asm.assemble src with
  | Ok w -> w
  | Error e -> failwith e
;;

(* Run for [cycles] cycles; [pads c] gives the pad values during cycle c. Returns, for every
   cycle, uo_out after that cycle. *)
let run ?(pads = fun _ -> Model.Pads.zero) ~cycles src =
  let m = Model.create (assemble src) in
  let trace = Array.init cycles ~f:(fun c ->
    Model.step m (pads c);
    Model.uo_out m)
  in
  m, trace
;;

(* Cycles after which a uo bit changed value. *)
let edges trace ~bit =
  List.filter_map (List.range 0 (Array.length trace)) ~f:(fun c ->
    let v c = (trace.(c) lsr bit) land 1 in
    let prev = if c = 0 then 0 else v (c - 1) in
    if v c <> prev then Some c else None)
;;

let check name ~got ~expect =
  if not ([%equal: int list] got expect)
  then raise_s [%message name (got : int list) (expect : int list)]
;;

let%expect_test "taken jumps cost one cycle: djnz loop toggles every 2 cycles" =
  let _, trace =
    run ~cycles:14 {|
      ldi r1, 5
loop: pin p8, tgl
      djnz r1, loop
      halt
|}
  in
  let e = edges trace ~bit:0 in
  check "edges" ~got:e ~expect:[ 1; 3; 5; 7; 9 ];
  print_s [%sexp (e : int list)];
  [%expect {| (1 3 5 7 9) |}]
;;

let%expect_test "pin delay: set with d=3 holds the engine 3 extra cycles" =
  let m, trace = run ~cycles:8 {|
      pin p8, set, 3
      pin p8, clr
      halt
|} in
  check "edges" ~got:(edges trace ~bit:0) ~expect:[ 0; 4 ];
  print_s [%message (edges trace ~bit:0 : int list) (Model.pc m : int)];
  [%expect {| (("edges trace ~bit:0" (0 4)) ("Model.pc m" 2)) |}]
;;

let%expect_test "inputs are visible 2 cycles after the pad changes" =
  (* copy ui[0] (pin 16) to uo[0] every cycle; raise the pad in cycle 3 *)
  let _, trace =
    run
      ~pads:(fun c -> { Model.Pads.zero with ui_in = (if c >= 3 then 1 else 0) })
      ~cycles:12
      {|
loop: pin p16, sample
      pin p8, c
      jmp loop
|}
  in
  (* sample at cycle 6 (first sample >= 5) then drive at cycle 7 *)
  check "edges" ~got:(edges trace ~bit:0) ~expect:[ 7 ];
  print_s [%sexp (edges trace ~bit:0 : int list)];
  [%expect {| (7) |}]
;;

let%expect_test "wait with timeout gives up on the TMO-th failed evaluation" =
  let src = {|
      csrwi tmo, 5
      wait pin p16, 1
      j t, timeout
      pin p8, set
      halt
timeout:
      pin p9, set
      halt
|} in
  (* never raised: wait occupies cycles 1..5, j t in 6, pin p9 in 7 *)
  let _, trace = run ~cycles:10 src in
  check "timeout edge" ~got:(edges trace ~bit:1) ~expect:[ 7 ];
  check "no success edge" ~got:(edges trace ~bit:0) ~expect:[];
  (* raised in cycle 2 -> visible in cycle 4 -> wait completes in 4, j in 5, set in 6 *)
  let _, trace =
    run ~pads:(fun c -> { Model.Pads.zero with ui_in = (if c >= 2 then 1 else 0) }) ~cycles:10 src
  in
  check "success edge" ~got:(edges trace ~bit:0) ~expect:[ 6 ];
  check "no timeout edge" ~got:(edges trace ~bit:1) ~expect:[];
  print_endline "ok";
  [%expect {| ok |}]
;;

let%expect_test "alu flags and call stack" =
  let m, _ =
    run ~cycles:40 {|
      ldi r0, 0xff
      ldih r0, 0xff      ; r0 = 0xffff
      ldi r1, 1
      add r0, r1         ; 0x0000, C=1, Z=1
      j nc, bad
      j nz, bad
      ldi r2, 0x81
      shri r2, 1         ; 0x40, C=1
      j nc, bad
      rlc r2, 1          ; 0x81, C=0
      j c, bad
      call sub
      ldi r4, 7          ; runs after ret
      halt
sub:  ldi r3, 3
      ret
bad:  ldi r7, 0xbd
      halt
|}
  in
  print_s
    [%message
      (Model.reg m 0 : int)
        (Model.reg m 2 : int)
        (Model.reg m 3 : int)
        (Model.reg m 4 : int)
        (Model.reg m 7 : int)
        (Model.halted m : bool)];
  if Model.reg m 7 <> 0 then failwith "took the bad branch";
  [%expect {|
    (("Model.reg m 0" 0) ("Model.reg m 2" 129) ("Model.reg m 3" 3)
     ("Model.reg m 4" 7) ("Model.reg m 7" 0) ("Model.halted m" true))
    |}]
;;

(* Bit-banged UART, 4 cycles per bit, LSB first: shri puts the next bit in C, pin drives it. *)
let%expect_test "bit-banged UART byte decodes back from the pin waveform" =
  let _, trace =
    run ~cycles:60 {|
      ldi r0, 0x55
      ldi r2, 8
      pin p8, set        ; idle high
      pin p8, clr, 2     ; start bit
bit:  shri r0, 1
      pin p8, c, 1
      djnz r2, bit
      nop
      pin p8, set        ; stop bit
      halt
|}
  in
  let line c = (trace.(c) lsr 0) land 1 in
  let start = List.find_exn (List.range 1 60) ~f:(fun c -> line c = 0 && line (c - 1) = 1) in
  let sample k = line (start + 2 + (4 * k)) in
  let byte = List.init 8 ~f:(fun k -> sample (k + 1) lsl k) |> List.fold ~init:0 ~f:( lor ) in
  let edges_ = edges trace ~bit:0 in
  let gaps = List.map2_exn (List.drop_last_exn edges_) (List.tl_exn edges_) ~f:(fun a b -> b - a) in
  if byte <> 0x55 || sample 9 <> 1 then raise_s [%message "bad byte" (byte : int)];
  (* 0x55 alternates every bit, so every edge after the first is exactly 4 cycles apart *)
  if List.exists (List.tl_exn gaps) ~f:(fun g -> g <> 4) then raise_s [%message (gaps : int list)];
  printf "byte=0x%02x start=%d edges=%s\n" byte start
    (Sexp.to_string [%sexp (edges_ : int list)]);
  [%expect {| byte=0x55 start=3 edges=(2 3 7 11 15 19 23 27 31 35 39) |}]
;;
