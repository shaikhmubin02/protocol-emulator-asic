(* The firmware in hw/firmware, run on the golden model against device models written from the
   protocol definitions. *)

open! Core
open Pemu

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
  [%expect {| 27 words; echoed (0 255 85 165 60 129 126) |}]
;;

(* ---------------- SPI ---------------- *)

(* SPI mode 0 target: samples MOSI on the rising edge, changes MISO after the falling edge.
   It answers each byte with the previous byte it received, inverted (0xA5 for the first). *)
module Spi_target = struct
  type t =
    { mutable sck : int
    ; mutable cs : int
    ; mutable rx : int
    ; mutable tx : int
    ; mutable count : int
    ; mutable miso : int
    ; mutable last : int
    ; mutable received : int list
    }

  let create () =
    { sck = 0; cs = 1; rx = 0; tx = 0xA5; count = 0; miso = 0; last = 0xA5; received = [] }
  ;;

  let step t ~sck ~mosi ~cs =
    if cs = 0 && t.cs = 1
    then (
      t.count <- 0;
      t.tx <- t.last;
      t.miso <- bit t.tx 7);
    if cs = 0
    then (
      if sck = 1 && t.sck = 0
      then (
        t.rx <- ((t.rx lsl 1) lor mosi) land 0xff;
        t.count <- t.count + 1;
        if t.count = 8
        then (
          t.received <- t.rx :: t.received;
          t.last <- lnot t.rx land 0xff));
      if sck = 0 && t.sck = 1
      then
        if t.count = 8
        then (
          t.count <- 0;
          t.tx <- t.last;
          t.miso <- bit t.tx 7)
        else t.miso <- bit t.tx (7 - t.count));
    t.sck <- sck;
    t.cs <- cs
  ;;
end

let%expect_test "spi_master.s against an SPI mode 0 target" =
  let prog = load "spi_master.s" in
  let m = Model.create prog in
  let dev = Spi_target.create () in
  let data = [ 0x12; 0x34; 0xF0; 0x0F ] in
  (* one transaction: CS low before the first byte, high after the last *)
  let host =
    Host.create
      (List.mapi data ~f:(fun i b ->
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
  if not ([%equal: int list] received data) then raise_s [%message (received : int list)];
  if not ([%equal: int list] replies expected_replies)
  then raise_s [%message (replies : int list) (expected_replies : int list)];
  if !cs_rises <> 1 then raise_s [%message "CS should rise once" (!cs_rises : int)];
  printf "%d words; target got %s, master got %s\n" (Array.length prog)
    (Sexp.to_string [%sexp (received : int list)])
    (Sexp.to_string [%sexp (replies : int list)]);
  [%expect {| 22 words; target got (18 52 240 15), master got (165 237 203 15) |}]
;;

(* ---------------- I2C ---------------- *)

(* 24C02-style EEPROM at 7-bit address 0x50, from the I2C spec's bus rules: START/STOP are SDA
   edges while SCL is high, data is sampled on SCL rising, the receiver ACKs in the 9th clock.
   It stretches the clock for [stretch] cycles after each byte it ACKs. *)
module Eeprom = struct
  type phase =
    | Idle
    | Address
    | Pointer
    | Write_data
    | Read_data
    | Ignore

  type t =
    { mem : int array
    ; stretch : int
    ; mutable phase : phase
    ; mutable bits : int
    ; mutable shift : int
    ; mutable ptr : int
    ; mutable sda_low : bool
    ; mutable scl_low_left : int
    ; mutable prev_scl : int
    ; mutable prev_sda : int
    ; mutable stretches : int
    ; mutable starts : int
    }

  let create ~stretch =
    { mem = Array.create ~len:256 0xFF
    ; stretch
    ; phase = Idle
    ; bits = 0
    ; shift = 0
    ; ptr = 0
    ; sda_low = false
    ; scl_low_left = 0
    ; prev_scl = 1
    ; prev_sda = 1
    ; stretches = 0
    ; starts = 0
    }
  ;;

  let scl_low t = t.scl_low_left > 0

  let send_bit t = t.sda_low <- bit t.mem.(t.ptr) (7 - t.bits) = 0

  (* [bits] counts rising SCL edges in the current byte: 1..8 are data, 9 is the ACK clock *)
  let step t ~scl ~sda =
    if t.scl_low_left > 0 then t.scl_low_left <- t.scl_low_left - 1;
    let rise_scl = scl = 1 && t.prev_scl = 0
    and fall_scl = scl = 0 && t.prev_scl = 1 in
    if scl = 1 && t.prev_scl = 1 && sda = 0 && t.prev_sda = 1
    then (
      (* START *)
      t.starts <- t.starts + 1;
      t.phase <- Address;
      t.bits <- 0;
      t.shift <- 0;
      t.sda_low <- false)
    else if scl = 1 && t.prev_scl = 1 && sda = 1 && t.prev_sda = 0
    then (
      (* STOP *)
      t.phase <- Idle;
      t.sda_low <- false)
    else (
      match t.phase with
      | Idle | Ignore -> ()
      | Address | Pointer | Write_data ->
        if rise_scl
        then (
          t.bits <- t.bits + 1;
          if t.bits <= 8 then t.shift <- ((t.shift lsl 1) lor sda) land 0xff);
        if fall_scl && t.bits = 8
        then (
          let ack =
            match t.phase with
            | Address -> t.shift lsr 1 = 0x50
            | _ -> true
          in
          if ack then t.sda_low <- true else t.phase <- Ignore)
        else if fall_scl && t.bits = 9
        then (
          t.sda_low <- false;
          t.bits <- 0;
          t.scl_low_left <- t.stretch;
          t.stretches <- t.stretches + 1;
          match t.phase with
          | Address when t.shift land 1 = 1 ->
            t.phase <- Read_data;
            send_bit t
          | Address -> t.phase <- Pointer
          | Pointer ->
            t.ptr <- t.shift;
            t.phase <- Write_data
          | Write_data ->
            t.mem.(t.ptr) <- t.shift;
            t.ptr <- (t.ptr + 1) land 0xff
          | _ -> ())
      | Read_data ->
        if rise_scl
        then (
          t.bits <- t.bits + 1;
          if t.bits = 9 && sda = 1 then t.phase <- Ignore (* master NACK: stop sending *));
        if fall_scl
        then
          if t.bits < 8
          then send_bit t
          else if t.bits = 8
          then t.sda_low <- false (* let go for the master's ACK *)
          else (
            t.bits <- 0;
            t.ptr <- (t.ptr + 1) land 0xff;
            send_bit t));
    t.prev_scl <- scl;
    t.prev_sda <- sda
  ;;
end

let%expect_test "i2c_master.s against an EEPROM that stretches the clock" =
  let prog = load "i2c_master.s" in
  let m = Model.create prog in
  let dev = Eeprom.create ~stretch:23 in
  let start = 0x100
  and write b = 0x200 lor b
  and read_ack = 0x300
  and read_nack = 0x400
  and stop = 0x500 in
  let commands =
    [ start; write 0xA0; write 0x10; write 0x5A; write 0xC3; stop
    ; start; write 0xA0; write 0x10; start; write 0xA1; read_ack; read_nack; stop
    ; start; write 0x84; stop
    ]
  in
  let host = Host.create commands in
  let master_drove_high = ref false in
  for _ = 1 to 20000 do
    let master_low p = bit (Model.uio_oe m) p = 1 && bit (Model.uio_out m) p = 0 in
    if (bit (Model.uio_oe m) 0 = 1 && bit (Model.uio_out m) 0 = 1)
       || (bit (Model.uio_oe m) 1 = 1 && bit (Model.uio_out m) 1 = 1)
    then master_drove_high := true;
    let scl = if master_low 0 || Eeprom.scl_low dev then 0 else 1 in
    let sda = if master_low 1 || dev.sda_low then 0 else 1 in
    Eeprom.step dev ~scl ~sda;
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
  printf "%d words; replies %s; %d STARTs, %d stretched ACKs\n" (Array.length prog)
    (Sexp.to_string [%sexp (replies : int list)]) dev.starts dev.stretches;
  [%expect {| 77 words; replies (0 0 0 0 0 0 0 90 195 1); 4 STARTs, 7 stretched ACKs |}]
;;
