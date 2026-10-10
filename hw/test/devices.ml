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

(* A chain of WS2812B LEDs on one wire, from the datasheet: each bit is a high pulse, 0.40 us
   for a 0 and 0.80 us for a 1, followed by a low of 0.85 us or 0.45 us, all +-150 ns. The
   first LED keeps the first 24 bits (green, red, blue, MSB first) and passes the rest on down
   the chain. A low of 50 us or more latches. Every pulse is checked against the datasheet. *)
module Ws2812 = struct
  type t =
    { n : int
    ; ns_per_cycle : int
    ; mutable level : int
    ; mutable since : int
    ; mutable now : int
    ; mutable bits : int list (* this frame, newest first *)
    ; mutable last_bit : int option
    ; mutable frames : int array list (* latched colours, newest first *)
    ; mutable errors : string list
    }

  let create ~n ~ns_per_cycle =
    { n
    ; ns_per_cycle
    ; level = 0
    ; since = 0
    ; now = 0
    ; bits = []
    ; last_bit = None
    ; frames = []
    ; errors = []
    }
  ;;

  let reset_ns = 50_000
  let error t s = t.errors <- sprintf "cycle %d: %s" t.now s :: t.errors
  let near t cycles ~ns = abs ((cycles * t.ns_per_cycle) - ns) <= 150

  let latch t =
    let bits = Array.of_list (List.rev t.bits) in
    if Array.length bits < 24 * t.n
    then error t (sprintf "latched after %d bits" (Array.length bits))
    else
      t.frames
      <- Array.init t.n ~f:(fun led ->
           Array.foldi (Array.sub bits ~pos:(24 * led) ~len:24) ~init:0 ~f:(fun _ acc b ->
             (acc lsl 1) lor b))
         :: t.frames;
    t.bits <- [];
    t.last_bit <- None
  ;;

  let step t level =
    if level <> t.level
    then (
      let width = t.now - t.since in
      if t.level = 1
      then (
        let b =
          if near t width ~ns:400 then 0 else if near t width ~ns:800 then 1 else -1
        in
        if b < 0
        then error t (sprintf "high for %d ns" (width * t.ns_per_cycle))
        else (
          t.bits <- b :: t.bits;
          t.last_bit <- Some b))
      else (
        match t.last_bit with
        | None -> ()
        | Some b ->
          let ns = if b = 0 then 850 else 450 in
          if not (near t width ~ns)
          then error t (sprintf "low for %d ns after a %d" (width * t.ns_per_cycle) b));
      t.level <- level;
      t.since <- t.now);
    if t.level = 0
       && (t.now - t.since) * t.ns_per_cycle >= reset_ns
       && not (List.is_empty t.bits)
    then latch t;
    t.now <- t.now + 1
  ;;
end

(* Dallas/Maxim CRC-8 (x^8 + x^5 + x^4 + 1, LSB first), the one 1-Wire ROM IDs end with *)
let crc8 bytes =
  List.fold bytes ~init:0 ~f:(fun crc b ->
    let crc = ref crc
    and b = ref b in
    for _ = 1 to 8 do
      let mix = (!crc lxor !b) land 1 in
      crc := !crc lsr 1;
      if mix = 1 then crc := !crc lxor 0x8C;
      b := !b lsr 1
    done;
    !crc)
;;

(* A 1-Wire device with a 64-bit ROM ID (family, 6-byte serial, CRC-8), from the 1-Wire spec as
   used by the DS18B20 datasheet, standard speed. After a reset pulse it answers with a presence
   pulse; it reads each bit by looking at the line 30 us after the master pulls it low; on READ
   ROM (0x33) it sends its ID, holding the line low for 15 us for each 0 bit. Other bytes it just
   records.

   It's stepped with what the master is doing ([master_low]) and returns the line level. It checks
   the master's side of every slot: reset low at least 480 us, a written 0 low 60-120 us, a 1 or
   a read slot low 1-15 us, at least 60 us per slot plus 1 us recovery. *)
module One_wire_device = struct
  type mode =
    | Idle
    | Command
    | Send_rom of int (* next bit *)

  type t =
    { us : int (* cycles per microsecond *)
    ; rom : int array
    ; mutable now : int
    ; mutable master_was_low : bool
    ; mutable fell : int option (* when the master last pulled low *)
    ; mutable released : int (* when the master last let go *)
    ; mutable low_from : int
    ; mutable low_until : int (* when the device itself holds the line low *)
    ; mutable mode : mode
    ; mutable shift : int
    ; mutable nbits : int
    ; mutable sample_at : int option
    ; mutable written : int list (* newest first *)
    ; mutable resets : int
    ; mutable errors : string list
    }

  let create ~us ~family ~serial =
    let id = (family :: serial) in
    { us
    ; rom = Array.of_list (id @ [ crc8 id ])
    ; now = 0
    ; master_was_low = false
    ; fell = None
    ; released = -1_000_000
    ; low_from = 0
    ; low_until = 0
    ; mode = Idle
    ; shift = 0
    ; nbits = 0
    ; sample_at = None
    ; written = []
    ; resets = 0
    ; errors = []
    }
  ;;

  let error t s = t.errors <- sprintf "%d us: %s" (t.now / t.us) s :: t.errors
  let device_low t = t.now >= t.low_from && t.now < t.low_until

  let take_bit t b =
    t.shift <- t.shift lor (b lsl t.nbits);
    t.nbits <- t.nbits + 1;
    if t.nbits = 8
    then (
      t.written <- t.shift :: t.written;
      if t.shift = 0x33 then t.mode <- Send_rom 0;
      t.shift <- 0;
      t.nbits <- 0)
  ;;

  let step t ~master_low =
    let us_since x = (t.now - x) / t.us in
    if master_low && not t.master_was_low
    then (
      (* start of a slot (or of a reset) *)
      Option.iter t.fell ~f:(fun f ->
        if us_since f < 61 && t.resets > 0 && not (Poly.equal t.mode Idle)
        then error t (sprintf "slot only %d us" (us_since f)));
      if us_since t.released < 1 then error t "no recovery time";
      t.fell <- Some t.now;
      match t.mode with
      | Idle -> ()
      | Command -> t.sample_at <- Some (t.now + (30 * t.us))
      | Send_rom k ->
        let b = (t.rom.(k / 8) lsr (k mod 8)) land 1 in
        (* a 0 is held for 15 us, the shortest the spec allows: the master has to sample
           within 15 us of its falling edge *)
        if b = 0
        then (
          t.low_from <- t.now;
          t.low_until <- t.now + (15 * t.us));
        t.mode <- (if k = 63 then Idle else Send_rom (k + 1)));
    if (not master_low) && t.master_was_low
    then (
      t.released <- t.now;
      match t.fell with
      | None -> ()
      | Some f ->
        let low_us = us_since f in
        if low_us >= 480
        then (
          (* reset: answer with a presence pulse, 30 us after the release, for 120 us *)
          t.resets <- t.resets + 1;
          t.low_from <- t.now + (30 * t.us);
          t.low_until <- t.now + (150 * t.us);
          t.mode <- Command;
          t.shift <- 0;
          t.nbits <- 0;
          t.sample_at <- None;
          t.fell <- None)
        else if not ((low_us >= 1 && low_us < 15) || (low_us >= 60 && low_us <= 120))
        then error t (sprintf "master held the line low for %d us" low_us));
    let line = if master_low || device_low t then 0 else 1 in
    (match t.sample_at with
     | Some at when t.now = at ->
       take_bit t line;
       t.sample_at <- None
     | _ -> ());
    t.master_was_low <- master_low;
    t.now <- t.now + 1;
    line
  ;;
end

(* A UART at the far end of the wire, 8N1, on its own exact clock: it decodes the line by
   sampling the middle of each bit by its own timing (start bit low, stop bit high or it's a
   framing error), sends bytes back to back at its own rate, and measures how far each edge it
   receives lands from where an ideal transmitter would put it. Times in ns. *)
module Uart_line = struct
  type t =
    { bit_ns : float
    ; ns_per_cycle : float
    ; mutable now : float
    ; (* receiving *)
      mutable prev : int
    ; mutable frame_start : float option
    ; mutable sampled : int (* bits sampled in this frame *)
    ; mutable shift : int
    ; mutable received : int list (* newest first *)
    ; mutable errors : string list
    ; mutable worst_edge : float (* as a fraction of a bit *)
    ; (* sending *)
      to_send : int Queue.t
    ; mutable tx_start : float
    ; mutable tx_byte : int option
    }

  let create ~baud ~ns_per_cycle words =
    { bit_ns = 1e9 /. Float.of_int baud
    ; ns_per_cycle = Float.of_int ns_per_cycle
    ; now = 0.
    ; prev = 0 (* a frame needs a falling edge: the line must have been idle (high) first *)
    ; frame_start = None
    ; sampled = 0
    ; shift = 0
    ; received = []
    ; errors = []
    ; worst_edge = 0.
    ; to_send = Queue.of_list words
    ; tx_start = 0.
    ; tx_byte = None
    }
  ;;

  (* the level it drives this cycle *)
  let tx_level t =
    (match t.tx_byte with
     | None ->
       (* start the next frame after at least one idle bit *)
       if Float.(t.now >= t.tx_start)
       then
         Option.iter (Queue.dequeue t.to_send) ~f:(fun b ->
           t.tx_byte <- Some b;
           t.tx_start <- t.now)
     | Some _ -> ());
    match t.tx_byte with
    | None -> 1
    | Some b ->
      let k = Float.iround_down_exn ((t.now -. t.tx_start) /. t.bit_ns) in
      if k = 0
      then 0
      else if k <= 8
      then (b lsr (k - 1)) land 1
      else (
        if k >= 10
        then (
          t.tx_byte <- None;
          t.tx_start <- t.tx_start +. (11. *. t.bit_ns));
        1)
  ;;

  (* the level it sees from the chip this cycle *)
  let rx_step t level =
    (match t.frame_start with
     | None -> if level = 0 && t.prev = 1 then t.frame_start <- Some t.now
     | Some f ->
       if level <> t.prev
       then (
         let bits = (t.now -. f) /. t.bit_ns in
         let off = Float.abs (bits -. Float.round_nearest bits) in
         t.worst_edge <- Float.max t.worst_edge off);
       let next_sample = f +. ((Float.of_int t.sampled +. 0.5) *. t.bit_ns) in
       if Float.(t.now >= next_sample)
       then (
         (match t.sampled with
          | 0 -> if level <> 0 then t.errors <- "start bit not low" :: t.errors
          | 9 ->
            if level <> 1 then t.errors <- "framing error" :: t.errors;
            t.received <- t.shift :: t.received;
            t.frame_start <- None
          | k -> t.shift <- t.shift lor (level lsl (k - 1)));
         if t.sampled = 9
         then (
           t.sampled <- 0;
           t.shift <- 0)
         else t.sampled <- t.sampled + 1));
    t.prev <- level
  ;;

  let step t level =
    let tx = tx_level t in
    rx_step t level;
    t.now <- t.now +. t.ns_per_cycle;
    tx
  ;;
end

