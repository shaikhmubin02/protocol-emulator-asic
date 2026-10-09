(* Devices for the protocol tests, written from the protocol definitions: an SPI target for
   any mode, an I2C EEPROM that stretches the clock, and an I2C bus timing checker. Each one is
   stepped once per clock cycle with the levels on the wires. *)

open! Core

let bit v k = (v lsr k) land 1

(* SPI target for any mode. CPOL is the level SCK idles at; the leading edge is the one away
   from it. CPHA 0: MISO is valid before the leading edge, both sides sample on it, MISO changes
   on the trailing edge. CPHA 1: MISO changes on the leading edge, both sides sample on the
   trailing edge. It answers each byte with the previous byte it received, inverted (0xA5 for
   the first). It also checks the bus: SCK must be idle whenever CS changes. *)
module Spi_target = struct
  type t =
    { cpol : int
    ; cpha : bool
    ; mutable sck : int
    ; mutable cs : int
    ; mutable rx : int
    ; mutable tx : int
    ; mutable count : int
    ; mutable miso : int
    ; mutable last : int
    ; mutable received : int list
    ; mutable edges : int
    }

  let create ~mode =
    let cpol = (mode lsr 1) land 1 in
    { cpol
    ; cpha = mode land 1 = 1
    ; sck = cpol
    ; cs = 1
    ; rx = 0
    ; tx = 0xA5
    ; count = 0
    ; miso = 0
    ; last = 0xA5
    ; received = []
    ; edges = 0
    }
  ;;

  let sample t mosi =
    t.rx <- ((t.rx lsl 1) lor mosi) land 0xff;
    t.count <- t.count + 1;
    if t.count = 8
    then (
      t.received <- t.rx :: t.received;
      t.last <- lnot t.rx land 0xff)
  ;;

  (* next bit out; after a full byte, start on the reply to it *)
  let shift_out t =
    if t.count = 8
    then (
      t.count <- 0;
      t.tx <- t.last);
    t.miso <- bit t.tx (7 - t.count)
  ;;

  let step t ~sck ~mosi ~cs =
    if cs <> t.cs && sck <> t.cpol then raise_s [%message "CS changed with SCK not idle" (sck : int)];
    if cs = 0 && t.cs = 1
    then (
      t.count <- 0;
      t.tx <- t.last;
      if not t.cpha then t.miso <- bit t.tx 7);
    if cs = 0 && sck <> t.sck
    then (
      t.edges <- t.edges + 1;
      let leading = sck <> t.cpol in
      match t.cpha, leading with
      | false, true | true, false -> sample t mosi
      | false, false | true, true -> shift_out t);
    t.sck <- sck;
    t.cs <- cs
  ;;
end

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

(* Watches SCL and SDA and keeps the shortest time seen for each of the I2C spec's timing
   parameters, in clock cycles. *)
module I2c_timing = struct
  type t =
    { mutable now : int
    ; mutable scl : int
    ; mutable sda : int
    ; mutable rise : int option (* last SCL rise *)
    ; mutable fall : int option (* last SCL fall *)
    ; mutable sda_change : int
    ; mutable start : int option (* START waiting for its SCL fall *)
    ; mutable stop : int option
    ; mutable fastest : int option (* rise to rise *)
    ; mins : (string, int) Hashtbl.t
    ; mutable longest_low : int
    }

  let create () =
    { now = 0
    ; scl = 1
    ; sda = 1
    ; rise = None
    ; fall = None
    ; sda_change = 0
    ; start = None
    ; stop = None
    ; fastest = None
    ; mins = Hashtbl.create (module String)
    ; longest_low = 0
    }
  ;;

  let note t name v =
    Hashtbl.update t.mins name ~f:(function
      | None -> v
      | Some m -> min m v)
  ;;

  let step t ~scl ~sda =
    let since = Option.map ~f:(fun x -> t.now - x) in
    if scl = 1 && t.scl = 0
    then (
      Option.iter (since t.fall) ~f:(fun d ->
        note t "tLOW" d;
        t.longest_low <- max t.longest_low d);
      Option.iter (since t.rise) ~f:(fun d ->
        t.fastest <- Some (Option.value_map t.fastest ~default:d ~f:(min d)));
      note t "tSU;DAT" (t.now - t.sda_change);
      t.rise <- Some t.now);
    if scl = 0 && t.scl = 1
    then (
      Option.iter (since t.rise) ~f:(note t "tHIGH");
      Option.iter (since t.start) ~f:(note t "tHD;STA");
      t.start <- None;
      t.fall <- Some t.now);
    if sda <> t.sda
    then (
      if scl = 1 && t.scl = 1 && sda = 0
      then (
        (* START: setup from the SCL rise (repeated START) and bus free since the last STOP *)
        Option.iter (since t.rise) ~f:(note t "tSU;STA");
        Option.iter (since t.stop) ~f:(note t "tBUF");
        t.start <- Some t.now);
      if scl = 1 && t.scl = 1 && sda = 1
      then (
        Option.iter (since t.rise) ~f:(note t "tSU;STO");
        t.stop <- Some t.now);
      t.sda_change <- t.now);
    t.scl <- scl;
    t.sda <- sda;
    t.now <- t.now + 1
  ;;

  (* minimums from the I2C spec (UM10204, table 10), in ns *)
  let spec ~fast =
    if fast
    then
      [ "tLOW", 1300; "tHIGH", 600; "tSU;STA", 600; "tHD;STA", 600; "tSU;STO", 600
      ; "tBUF", 1300; "tSU;DAT", 100 ]
    else
      [ "tLOW", 4700; "tHIGH", 4000; "tSU;STA", 4700; "tHD;STA", 4000; "tSU;STO", 4000
      ; "tBUF", 4700; "tSU;DAT", 250 ]
  ;;

  (* check against the spec at [ns_per_cycle]; returns the SCL rate in kHz *)
  let check t ~fast ~ns_per_cycle =
    List.iter (spec ~fast) ~f:(fun (name, min_ns) ->
      match Hashtbl.find t.mins name with
      | None -> raise_s [%message "never measured" name]
      | Some cycles ->
        if cycles * ns_per_cycle < min_ns
        then raise_s [%message "too short" name (cycles : int) (min_ns : int)]);
    let period = Option.value_exn t.fastest in
    let khz = 1_000_000 / (period * ns_per_cycle) in
    let limit = if fast then 400 else 100 in
    if khz > limit then raise_s [%message "SCL too fast" (khz : int)];
    khz
  ;;
end
