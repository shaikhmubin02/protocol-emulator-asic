(* The firmware in hw/firmware, run on the golden model against device models written from the
   protocol definitions. *)

open! Core
open Pemu
open Devices

let load name =
  let src = In_channel.read_all ("../firmware/" ^ name) in
  match Asm.assemble src with
  | Ok words -> words
  | Error e -> failwithf "%s: %s" name e ()
;;

let bit v k = (v lsr k) land 1

(* ---------------- UART ---------------- *)

let%expect_test "uart.s: full-duplex loopback, back-to-back frames" =
  let prog = load "uart.s" in
  let m = Model.create prog in
  let sent = [ 0x00; 0xFF; 0x55; 0xA5; 0x3C; 0x81; 0x7E ] in
  let host = Host.create sent in
  let tx = ref 1 in
  for _ = 1 to 2000 do
    (* wire TX (uo[0]) back to RX (ui[3]) *)
    Model.step m { Model.Pads.zero with ui_in = !tx lsl 3 };
    tx := bit (Model.uo_out m) 0;
    Host.service host m
  done;
  let got = Host.received host in
  if not ([%equal: int list] got sent) then raise_s [%message (got : int list) (sent : int list)];
  printf "%d words; echoed %s\n" (Array.length prog) (Sexp.to_string [%sexp (got : int list)]);
  [%expect {| 37 words; echoed (0 255 85 165 60 129 126) |}]
;;

(* At real baud rates against a UART on its own exact clock, both directions at once. The chip
   is clocked at 50 MHz. *)
let%expect_test "uart.s at 115200 and 9600 baud" =
  List.iter [ 115200, 434, 8; 9600, 5208, 85 ] ~f:(fun (baud, whole, frac) ->
    let prog = load "uart.s" in
    let m = Model.create prog in
    let to_chip = [ 0x55; 0x00; 0xFF; 0xA5; 0x3C; 0x81 ]
    and from_chip = [ 0x12; 0xED; 0x80; 0x01; 0x7F; 0xC3 ] in
    let host = Host.create ([ 0x8000 lor whole; 0x4000 lor frac ] @ from_chip) in
    (* the far end starts sending once the bit time is set *)
    let far = Uart_line.create ~baud ~ns_per_cycle:20 [] in
    let cycles = 14 * 10 * (whole + 1) in
    for cycle = 1 to cycles do
      if cycle = 200 then List.iter to_chip ~f:(Queue.enqueue far.to_send);
      let rx = Uart_line.step far (bit (Model.uo_out m) 0) in
      Model.step m { Model.Pads.zero with ui_in = rx lsl 3 };
      Host.service host m
    done;
    let got = Host.received host
    and far_got = List.rev far.received in
    if not (List.is_empty far.errors) then raise_s [%message (far.errors : string list)];
    if not ([%equal: int list] got to_chip) then raise_s [%message (baud : int) (got : int list)];
    if not ([%equal: int list] far_got from_chip)
    then raise_s [%message (baud : int) (far_got : int list)];
    printf "%6d baud: both directions ok, worst TX edge %.2f%% of a bit from ideal\n" baud
      (100. *. far.worst_edge));
  [%expect {|
    115200 baud: both directions ok, worst TX edge 0.22% of a bit from ideal
      9600 baud: both directions ok, worst TX edge 0.01% of a bit from ideal
    |}]
;;

(* ---------------- SPI ---------------- *)

let spi_run ~mode data =
  let prog = load "spi_master.s" in
  let m = Model.create prog in
  let dev = Spi_target.create ~mode in
  (* pick the mode, then one transaction: CS low before the first byte, high after the last *)
  let host =
    Host.create
      ((0x8000 lor mode)
       :: List.mapi data ~f:(fun i b ->
         let first = if i = 0 then 0x100 else 0 in
         let last = if i = List.length data - 1 then 0x200 else 0 in
         b lor first lor last))
  in
  let cs_rises = ref 0 in
  for _ = 1 to 3000 do
    Model.step m { Model.Pads.zero with ui_in = dev.miso lsl 4 };
    let uo = Model.uo_out m in
    let cs = bit uo 3 in
    if cs = 1 && dev.cs = 0 then incr cs_rises;
    Spi_target.step dev ~sck:(bit uo 1) ~mosi:(bit uo 2) ~cs;
    Host.service host m
  done;
  let replies = Host.received host in
  let received = List.rev dev.received in
  let expected_replies = 0xA5 :: List.map (List.drop_last_exn data) ~f:(fun b -> lnot b land 0xff) in
  if not ([%equal: int list] received data) then raise_s [%message (mode : int) (received : int list)];
  if not ([%equal: int list] replies expected_replies)
  then raise_s [%message (mode : int) (replies : int list) (expected_replies : int list)];
  if !cs_rises <> 1 then raise_s [%message "CS should rise once" (!cs_rises : int)];
  if dev.edges <> 16 * List.length data then raise_s [%message "SCK edges" (dev.edges : int)];
  if bit (Model.uo_out m) 1 <> dev.cpol then raise_s [%message "SCK not idle at the end"];
  printf "mode %d: %d words; target got %s, master got %s\n" mode (Array.length prog)
    (Sexp.to_string [%sexp (received : int list)])
    (Sexp.to_string [%sexp (replies : int list)])
;;

let%expect_test "spi_master.s against an SPI target, all four modes" =
  for mode = 0 to 3 do
    spi_run ~mode [ 0x12; 0x34; 0xF0; 0x0F ]
  done;
  [%expect {|
    mode 0: 41 words; target got (18 52 240 15), master got (165 237 203 15)
    mode 1: 41 words; target got (18 52 240 15), master got (165 237 203 15)
    mode 2: 41 words; target got (18 52 240 15), master got (165 237 203 15)
    mode 3: 41 words; target got (18 52 240 15), master got (165 237 203 15)
    |}]
;;

(* ---------------- I2C ---------------- *)

let i2c_eeprom_run ?speed ~stretch () =
  let prog = load "i2c_master.s" in
  let m = Model.create prog in
  let dev = Eeprom.create ~stretch in
  let timing = I2c_timing.create () in
  let start = 0x100
  and write b = 0x200 lor b
  and read_ack = 0x300
  and read_nack = 0x400
  and stop = 0x500 in
  let commands =
    Option.to_list (Option.map speed ~f:(fun q -> 0x600 lor q))
    @ [ start; write 0xA0; write 0x10; write 0x5A; write 0xC3; stop
      ; start; write 0xA0; write 0x10; start; write 0xA1; read_ack; read_nack; stop
      ; start; write 0x84; stop
      ]
  in
  let host = Host.create commands in
  let master_drove_high = ref false in
  for _ = 1 to 200_000 do
    let master_low p = bit (Model.uio_oe m) p = 1 && bit (Model.uio_out m) p = 0 in
    if (bit (Model.uio_oe m) 0 = 1 && bit (Model.uio_out m) 0 = 1)
       || (bit (Model.uio_oe m) 1 = 1 && bit (Model.uio_out m) 1 = 1)
    then master_drove_high := true;
    let scl = if master_low 0 || Eeprom.scl_low dev then 0 else 1 in
    let sda = if master_low 1 || dev.sda_low then 0 else 1 in
    Eeprom.step dev ~scl ~sda;
    I2c_timing.step timing ~scl ~sda;
    Model.step m { Model.Pads.zero with uio_in = scl lor (sda lsl 1) };
    Host.service host m
  done;
  let replies = Host.received host in
  let expected = [ 0; 0; 0; 0; 0; 0; 0; 0x5A; 0xC3; 1 ] in
  if not ([%equal: int list] replies expected)
  then raise_s [%message (replies : int list) (expected : int list)];
  if dev.mem.(0x10) <> 0x5A || dev.mem.(0x11) <> 0xC3 then failwith "EEPROM contents wrong";
  if !master_drove_high then failwith "master drove a line high (not open drain)";
  if dev.stretches = 0 then failwith "no clock stretching happened";
  prog, replies, dev, timing
;;

let%expect_test "i2c_master.s against an EEPROM that stretches the clock" =
  let prog, replies, dev, _ = i2c_eeprom_run ~stretch:23 () in
  printf "%d words; replies %s; %d STARTs, %d stretched ACKs\n" (Array.length prog)
    (Sexp.to_string [%sexp (replies : int list)]) dev.starts dev.stretches;
  [%expect {| 120 words; replies (0 0 0 0 0 0 0 90 195 1); 4 STARTs, 7 stretched ACKs |}]
;;

(* At a 50 MHz clock (20 ns a cycle), with the target holding SCL low for longer than the master
   would, so the master really has to wait. *)
let%expect_test "i2c_master.s meets the spec timing at 100 and 400 kHz" =
  List.iter [ "standard", 100, false; "fast", 25, true ] ~f:(fun (name, q, fast) ->
    let _, _, dev, timing = i2c_eeprom_run ~speed:q ~stretch:(4 * q) () in
    let khz = I2c_timing.check timing ~fast ~ns_per_cycle:20 in
    let mins =
      List.map (I2c_timing.spec ~fast) ~f:(fun (n, _) ->
        sprintf "%s %d" n (Hashtbl.find_exn timing.mins n * 20))
    in
    printf "%s (Q = %d): SCL %d kHz, %d stretched ACKs, longest SCL low %d ns\n  shortest (ns): %s\n"
      name q khz dev.stretches (timing.longest_low * 20) (String.concat ~sep:", " mins));
  [%expect {|
    standard (Q = 100): SCL 98 kHz, 7 stretched ACKs, longest SCL low 8020 ns
      shortest (ns): tLOW 5980, tHIGH 4120, tSU;STA 6100, tHD;STA 6000, tSU;STO 4120, tBUF 14140, tSU;DAT 3980
    fast (Q = 25): SCL 381 kHz, 7 stretched ACKs, longest SCL low 2020 ns
      shortest (ns): tLOW 1480, tHIGH 1120, tSU;STA 1600, tHD;STA 1500, tSU;STO 1120, tBUF 3640, tSU;DAT 980
    |}]
;;

(* ---------------- WS2812 ---------------- *)

(* colours as 24-bit GRB values, packed MSB first into 16-bit host words *)
let ws2812_words colours =
  let bits =
    List.concat_map colours ~f:(fun c -> List.init 24 ~f:(fun k -> bit c (23 - k)))
  in
  List.chunks_of bits ~length:16
  |> List.map ~f:(fun chunk -> List.fold chunk ~init:0 ~f:(fun acc b -> (acc lsl 1) lor b))
;;

let ws2812_frames =
  [ [ 0xFF0000; 0x00FF00; 0x0000FF; 0x123456; 0xABCDEF; 0x000001; 0x800000; 0xFFFFFF ]
  ; [ 0x000000; 0x555555; 0xAAAAAA; 0x0F0F0F; 0xF0F0F0; 0x010203; 0x7F7F7F; 0x808080 ]
  ]
;;

let%expect_test "ws2812.s drives an LED chain (a protocol the chip wasn't designed for)" =
  let prog = load "ws2812.s" in
  let m = Model.create prog in
  let leds = Ws2812.create ~n:8 ~ns_per_cycle:20 in
  (* two frames, with the line left idle in between *)
  List.iter ws2812_frames ~f:(fun frame ->
    let host = Host.create (ws2812_words frame) in
    for _ = 1 to 20_000 do
      Model.step m Model.Pads.zero;
      Ws2812.step leds (bit (Model.uo_out m) 0);
      Host.service host m
    done);
  if not (List.is_empty leds.errors) then raise_s [%message (leds.errors : string list)];
  let got = List.rev_map leds.frames ~f:Array.to_list in
  if not ([%equal: int list list] got ws2812_frames)
  then raise_s [%message (got : int list list)];
  printf "%d words; %d frames latched, every pulse within the datasheet's +-150 ns\n"
    (Array.length prog) (List.length got);
  [%expect {| 29 words; 2 frames latched, every pulse within the datasheet's +-150 ns |}]
;;

(* ---------------- 1-Wire ---------------- *)

let onewire_run ?device ~cycles commands =
  let prog = load "onewire.s" in
  let m = Model.create prog in
  let host = Host.create commands in
  let line = ref 1
  and drove_high = ref false in
  for _ = 1 to cycles do
    Model.step m { Model.Pads.zero with uio_in = !line lsl 2 };
    let oe = bit (Model.uio_oe m) 2 = 1 in
    if oe && bit (Model.uio_out m) 2 = 1 then drove_high := true;
    let master_low = oe && bit (Model.uio_out m) 2 = 0 in
    line
    := (match device with
        | Some d -> One_wire_device.step d ~master_low
        | None -> if master_low then 0 else 1);
    Host.service host m
  done;
  if !drove_high then failwith "master drove the line high (not open drain)";
  prog, Host.received host
;;

let%expect_test "onewire.s reads a device's ROM ID (another protocol it wasn't designed for)" =
  printf "CRC-8 of the example in Maxim's app note 27: %02X\n"
    (crc8 [ 0x02; 0x1C; 0xB8; 0x01; 0x00; 0x00; 0x00 ]);
  let dev =
    One_wire_device.create ~us:50 ~family:0x28 ~serial:[ 0xA1; 0xB2; 0xC3; 0xD4; 0xE5; 0xF6 ]
  in
  (* RESET, READ ROM, read 8 bytes; then RESET, SKIP ROM, CONVERT T (as for a DS18B20) *)
  let commands =
    [ 0x100; 0x233 ] @ List.init 8 ~f:(fun _ -> 0x300) @ [ 0x100; 0x2CC; 0x244 ]
  in
  let prog, replies = onewire_run ~device:dev ~cycles:500_000 commands in
  if not (List.is_empty dev.errors) then raise_s [%message (dev.errors : string list)];
  let rom = List.sub replies ~pos:1 ~len:8 in
  if not ([%equal: int list] rom (Array.to_list dev.rom)) then raise_s [%message (rom : int list)];
  if crc8 (List.take rom 7) <> List.nth_exn rom 7 then failwith "CRC";
  printf "%d words; presence %d, ROM %s (CRC ok), presence %d; device got %s\n"
    (Array.length prog) (List.hd_exn replies)
    (String.concat ~sep:" " (List.map rom ~f:(sprintf "%02X")))
    (List.nth_exn replies 9)
    (String.concat ~sep:" " (List.rev_map dev.written ~f:(sprintf "%02X")));
  let _, replies = onewire_run ~cycles:60_000 [ 0x100 ] in
  printf "with nothing on the bus, RESET says %s\n" (Sexp.to_string [%sexp (replies : int list)]);
  [%expect {|
    CRC-8 of the example in Maxim's app note 27: A2
    74 words; presence 0, ROM 28 A1 B2 C3 D4 E5 F6 AC (CRC ok), presence 0; device got 33 CC 44
    with nothing on the bus, RESET says (1)
    |}]
;;

(* ---------------- USB low speed ---------------- *)

let%expect_test "usb_tx.s: low-speed packets, checked by a receiver written from the USB spec" =
  let prog = load "usb_tx.s" in
  let m = Model.create prog in
  (* at 48 MHz *)
  let rx = Usb_ls_receiver.create ~ns_per_cycle:(1e9 /. 48e6) in
  let data b = 0x200 lor b
  and raw b = 0x300 lor b in
  let setup = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] (* GET_DESCRIPTOR *) in
  let words =
    (* SETUP token to address 0, endpoint 0 (the CRC-5 is part of the second byte) *)
    [ 0x12D; raw 0x00; raw 0x10; 0x500 ]
    (* DATA0 with the setup request *)
    @ [ 0x1C3 ] @ List.map setup ~f:data @ [ 0x400 ]
    (* ACK *)
    @ [ 0x1D2; 0x500 ]
    (* zero-length DATA1: its CRC field is 00 00 *)
    @ [ 0x14B; 0x400 ]
    (* lots of 1s, so lots of stuffing *)
    @ [ 0x1C3 ] @ List.map [ 0xFF; 0xFF; 0xFF; 0x7F; 0xFE ] ~f:data @ [ 0x400 ]
  in
  let host = Host.create words in
  for _ = 1 to 40_000 do
    Model.step m Model.Pads.zero;
    let oe = Model.uio_oe m
    and out = Model.uio_out m in
    (* D+ has the host's pull-down, D- the device's pull-up *)
    let dp = if bit oe 4 = 1 then bit out 4 else 0
    and dm = if bit oe 5 = 1 then bit out 5 else 1 in
    Usb_ls_receiver.step rx ~dp ~dm;
    Host.service host m
  done;
  if not (List.is_empty rx.errors) then raise_s [%message (rx.errors : string list)];
  (* the spec allows 95 ns; the firmware is meant to be exact, so anything over a cycle means a
     bit boundary was missed *)
  if Float.(rx.worst_jitter_ns > 1e9 /. 48e6 /. 2.)
  then raise_s [%message "a bit boundary was late" (rx.worst_jitter_ns : float)];
  printf "%d words, worst transition %.1f ns off the bit grid\n" (Array.length prog)
    rx.worst_jitter_ns;
  List.iter (List.rev rx.packets) ~f:(fun p ->
    printf "PID %02X  data [%s]%s  stuffed bits %d\n" p.pid
      (String.concat ~sep:" " (List.map p.data ~f:(sprintf "%02X")))
      (match p.crc_ok with
       | Some true -> "  CRC-16 ok"
       | Some false -> "  CRC-16 WRONG"
       | None -> "")
      p.stuffed);
  [%expect {|
    89 words, worst transition 0.0 ns off the bit grid
    PID 2D  data [00 10]  stuffed bits 0
    PID C3  data [80 06 00 01 00 00 40 00]  CRC-16 ok  stuffed bits 0
    PID D2  data []  stuffed bits 0
    PID 4B  data []  CRC-16 ok  stuffed bits 0
    PID C3  data [FF FF FF 7F FE]  CRC-16 ok  stuffed bits 7
    |}]
;;

