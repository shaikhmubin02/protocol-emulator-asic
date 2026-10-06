open! Core
open Pemu

let assemble src =
  match Asm.assemble src with
  | Ok w -> w
  | Error e -> failwith e
;;

(* Run a model; returns it and uo_out bit 0 after every cycle. *)
let run ?(setup = fun _ -> ()) ?(pads = fun _ -> Model.Pads.zero) ~cycles src =
  let m = Model.create (assemble src) in
  setup m;
  let line = Array.init cycles ~f:(fun c ->
    Model.step m (pads c);
    Model.uo_out m land 1)
  in
  m, line
;;

(* Decode 8N1 frames from a sampled line with [period] cycles per bit. *)
let uart_decode line ~period =
  let n = Array.length line in
  let rec go c acc =
    if c + (10 * period) >= n
    then List.rev acc
    else if c > 0 && line.(c - 1) = 1 && line.(c) = 0
    then (
      let sample k = line.(c + (period / 2) + (k * period)) in
      if sample 0 <> 0 || sample 9 <> 1 then failwith "framing error";
      let byte = List.init 8 ~f:(fun k -> sample (k + 1) lsl k) |> List.fold ~init:0 ~f:( lor ) in
      go (c + (10 * period)) (byte :: acc))
    else go (c + 1) acc
  in
  go 1 []
;;

let uart_tx_program bytes =
  sprintf
    {|
      ldi  r1, 0x09
      ldih r1, 0x09        ; txcfg: 10 bits, LSB first, pin 8, idle high
      csrw txcfg, r1
      csrwi baud, 10
      ldi  r2, 0
      ldih r2, 0x02        ; stop bit (bit 9)
      pin  p8, set         ; line idles high before the bit engine takes over
      ben  1
%s
      halt
|}
    (List.map bytes ~f:(fun b ->
       sprintf "      ldi r0, %d\n      shli r0, 1\n      or r0, r2\n      tx r0" b)
     |> String.concat ~sep:"\n")
;;

let%expect_test "UART TX through the bit engine" =
  let _, line = run ~cycles:600 (uart_tx_program [ 0x55; 0xA3; 0x00; 0xFF ]) in
  let bytes = uart_decode line ~period:10 in
  if not ([%equal: int list] bytes [ 0x55; 0xA3; 0x00; 0xFF ])
  then raise_s [%message (bytes : int list)];
  (* every edge from the first start bit on must be on the 10-cycle baud grid *)
  let edges = List.filter (List.range 1 600) ~f:(fun c -> line.(c) <> line.(c - 1)) in
  let first = List.find_exn edges ~f:(fun c -> line.(c) = 0) in
  let edges = List.filter edges ~f:(fun c -> c >= first) in
  if List.exists edges ~f:(fun e -> (e - first) % 10 <> 0)
  then raise_s [%message "off-grid edge" (edges : int list)];
  printf "decoded %s, %d edges all on the 10-cycle grid\n"
    (Sexp.to_string [%sexp (bytes : int list)])
    (List.length edges);
  [%expect {| decoded (85 163 0 255), 20 edges all on the 10-cycle grid |}]
;;

let%expect_test "UART RX with start-on-falling-edge" =
  (* host side: drive ui[0] (pin 16) with frames at 10 cycles/bit *)
  let bits_of byte = (0 :: List.init 8 ~f:(fun k -> (byte lsr k) land 1)) @ [ 1 ] in
  let wave =
    List.concat_map [ 0xC5; 0x3A; 0x80 ] ~f:(fun b -> List.init 7 ~f:(fun _ -> 1) @ bits_of b)
    |> List.concat_map ~f:(fun b -> List.init 10 ~f:(fun _ -> b))
    |> Array.of_list
  in
  let pads c =
    { Model.Pads.zero with ui_in = (if c < 40 || c - 40 >= Array.length wave then 1 else wave.(c - 40)) }
  in
  let m = Model.create (assemble {|
      ldi  r1, 0x09
      ldih r1, 0x12        ; rxcfg: 10 bits, LSB first, pin 16, start on falling edge
      csrw rxcfg, r1
      csrwi baud, 10
      ben  1
loop: rx   r0
      shri r0, 1           ; drop the start bit
      push r0
      jmp  loop
|}) in
  (* the host drains the mailbox every cycle *)
  let got = ref [] in
  for c = 0 to Array.length wave + 100 do
    Model.step m (pads c);
    Option.iter (Model.host_receive m) ~f:(fun v -> got := v :: !got)
  done;
  let got = List.rev !got in
  let bytes = List.map got ~f:(fun w -> w land 0xff) in
  let stops = List.map got ~f:(fun w -> (w lsr 8) land 1) in
  if not ([%equal: int list] bytes [ 0xC5; 0x3A; 0x80 ]) then raise_s [%message (got : int list)];
  if List.exists stops ~f:(fun s -> s <> 1) then failwith "stop bit not 1";
  printf "received %s\n" (Sexp.to_string [%sexp (bytes : int list)]);
  [%expect {| received (197 58 128) |}]
;;

let%expect_test "CRC-16/USB of \"123456789\" from the TX bit stream" =
  let m = Model.create (assemble {|
      ldi  r1, 0x07
      ldih r1, 0x0f        ; txcfg: 8 bits, LSB first, pin 24 (not driven)
      csrw txcfg, r1
      csrwi baud, 2
      csrwi crcctl, 9      ; enable, source = TX bit, reversed read
      crci
      ben  1
      ldi  r3, 9
next: pull r0
      tx   r0
      djnz r3, next
idle: csrr r1, bstat
      tstb r1, 1           ; TX idle?
      j    z, idle
      csrr r2, crc_lo
      push r2
      halt
|}) in
  Model.set_crc m ~poly:(0x8005 lsl 16) ~init:(0xFFFF lsl 16);
  let host = Host.create (String.to_list "123456789" |> List.map ~f:Char.to_int) in
  for _ = 1 to 1000 do
    Model.step m Model.Pads.zero;
    Host.service host m
  done;
  let crc = List.hd_exn (Host.received host) lxor 0xFFFF in
  if crc <> 0xB4C8 then raise_s [%message "wrong CRC" (crc : int)];
  printf "CRC-16/USB = 0x%04X\n" crc;
  [%expect {| CRC-16/USB = 0xB4C8 |}]
;;

let usb_tx_bitstream = Bitstream.usb_tx ~n_le:Model.n_le

let reference_usb_tx bits =
  let stuffed =
    List.fold bits ~init:([], 0) ~f:(fun (acc, ones) b ->
      if ones = 6
      then if b = 1 then (1 :: 0 :: acc, 1) else (0 :: 0 :: acc, 0)
      else (b :: acc, if b = 1 then ones + 1 else 0))
    |> fst
    |> List.rev
  in
  let _, line =
    List.fold_map stuffed ~init:1 ~f:(fun level b ->
      let level = if b = 1 then level else 1 - level in
      level, level)
  in
  line
;;

let%expect_test "USB NRZI + bit stuffing in the LUT fabric matches a software encoder" =
  let data = [ 0xFF; 0xFF; 0x81; 0x7E ] in
  let m = Model.create (assemble (sprintf {|
      ldi  r1, 0x07
      ldih r1, 0x0d        ; txcfg: 8 bits, LSB first, pin 8, through fabric, idle high
      csrw txcfg, r1
      ldi  r1, 0x0e
      ldih r1, 0x02        ; fabctl: line = element 7, hold = element 0, hold enabled
      csrw fabctl, r1
      csrwi baud, 4
      ben  1
%s
      halt
|} (List.map data ~f:(fun b -> sprintf "      ldi r0, %d\n      tx r0" b) |> String.concat ~sep:"\n")))
  in
  Model.set_fabric m usb_tx_bitstream;
  (* the line value right after each tick: ticks happen every 4 cycles after ben *)
  let line = Array.init 400 ~f:(fun _ ->
    Model.step m Model.Pads.zero;
    Model.uo_out m land 1)
  in
  let bits = List.concat_map data ~f:(fun b -> List.init 8 ~f:(fun k -> (b lsr k) land 1)) in
  let expected = reference_usb_tx bits in
  (* ben runs in cycle 7, so ticks are in cycles 11, 15, ... *)
  let got = List.init (List.length expected) ~f:(fun i -> line.(11 + (4 * i))) in
  if not ([%equal: int list] got expected)
  then raise_s [%message (got : int list) (expected : int list)];
  printf "%d data bits -> %d line bits (%d stuffed), all match\n"
    (List.length bits) (List.length expected) (List.length expected - List.length bits);
  [%expect {| 32 data bits -> 35 line bits (3 stuffed), all match |}]
;;
