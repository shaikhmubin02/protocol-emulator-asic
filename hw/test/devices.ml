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

(* CRC-16 of USB data packets: x^16 + x^15 + x^2 + 1, LSB first, starting at all ones; the
   packet carries it inverted *)
let crc16_usb bytes =
  List.fold bytes ~init:0xFFFF ~f:(fun crc b ->
    let crc = ref crc in
    for k = 0 to 7 do
      let fb = (!crc lxor (b lsr k)) land 1 in
      crc := !crc lsr 1;
      if fb = 1 then crc := !crc lxor 0xA001
    done;
    !crc)
;;

(* The receiving end of a USB low-speed link, from the USB 2.0 spec (chapters 7 and 8). It
   watches D+ and D-; with the 1.5k pull-up on D-, a line nobody drives reads J. It records each
   packet from its first K to the end of packet (SE0, then J), then decodes it: samples the middle
   of each bit on the grid set by the first transition, undoes NRZI (a change is a 0) and bit
   stuffing (after six 1s comes a 0 that isn't data), and checks:
   - every transition is within 95 ns of that grid (low-speed source jitter, table 7-9 TDJ1),
   - SE0 at the end lasts 1.25-1.5 us (TEOPT),
   - SYNC is 00000001, the PID's top nibble is the inverse of its bottom nibble,
   - no stuffing errors, whole bytes, and the CRC-16 of data packets,
   - at least 2 bit times of idle between packets. *)
module Usb_ls_receiver = struct
  type line =
    | J
    | K
    | Se0
    | Se1
  [@@deriving equal, sexp_of]

  type packet =
    { pid : int
    ; data : int list (* without the CRC-16 for data packets *)
    ; crc_ok : bool option
    ; stuffed : int
    }
  [@@deriving sexp_of]

  type t =
    { ns_per_cycle : float
    ; bit_ns : float
    ; mutable now : float
    ; mutable prev : line
    ; mutable start : float option (* first K of the packet *)
    ; mutable states : (float * line) list (* transitions in this packet, newest first *)
    ; mutable se0_from : float option
    ; mutable idle_from : float
    ; mutable packets : packet list (* newest first *)
    ; mutable errors : string list
    ; mutable worst_jitter_ns : float
    }

  let create ~ns_per_cycle =
    { ns_per_cycle
    ; bit_ns = 1e9 /. 1.5e6
    ; now = 0.
    ; prev = J
    ; start = None
    ; states = []
    ; se0_from = None
    ; idle_from = -1e9
    ; packets = []
    ; errors = []
    ; worst_jitter_ns = 0.
    }
  ;;

  let error t s = t.errors <- sprintf "%.0f ns: %s" t.now s :: t.errors

  let decode t ~start ~se0_from =
    let states = List.rev t.states in
    (* the line in the middle of bit k: the last transition before that time *)
    let level_at time =
      List.fold states ~init:K ~f:(fun acc (at, l) -> if Float.(at <= time) then l else acc)
    in
    let n_bits = Float.iround_nearest_exn ((se0_from -. start) /. t.bit_ns) in
    let prev = ref J
    and ones = ref 0
    and bits = ref []
    and stuffed = ref 0 in
    for k = 0 to n_bits - 1 do
      let l = level_at (start +. ((Float.of_int k +. 0.5) *. t.bit_ns)) in
      let b = if equal_line l !prev then 1 else 0 in
      prev := l;
      if !ones = 6
      then (
        if b = 1 then error t "bit stuffing error";
        incr stuffed;
        ones := 0)
      else (
        bits := b :: !bits;
        if b = 1 then incr ones else ones := 0)
    done;
    let bits = List.rev !bits in
    let rec bytes = function
      | [] -> []
      | l when List.length l < 8 ->
        error t (sprintf "%d bits left over" (List.length l));
        []
      | l ->
        let b = List.take l 8
        and rest = List.drop l 8 in
        List.foldi b ~init:0 ~f:(fun k acc x -> acc lor (x lsl k)) :: bytes rest
    in
    match bytes bits with
    | sync :: pid :: rest ->
      if sync <> 0x80 then error t (sprintf "SYNC was %02x" sync);
      if (pid lsr 4) lxor 0xF <> pid land 0xF then error t (sprintf "bad PID %02x" pid);
      let is_data = List.mem [ 0xC3; 0x4B; 0x87; 0x0F ] pid ~equal:Int.equal in
      let data, crc_ok =
        if is_data && List.length rest >= 2
        then (
          let data = List.drop_last_exn (List.drop_last_exn rest) in
          let crc = lnot (crc16_usb data) land 0xFFFF in
          let sent =
            match List.drop rest (List.length data) with
            | [ lo; hi ] -> lo lor (hi lsl 8)
            | _ -> -1
          in
          data, Some (crc = sent))
        else rest, None
      in
      if Poly.equal crc_ok (Some false) then error t "CRC-16 wrong";
      t.packets <- { pid; data; crc_ok; stuffed = !stuffed } :: t.packets
    | _ -> error t "packet too short"
  ;;

  let step t ~dp ~dm =
    let l =
      match dp, dm with
      | 0, 1 -> J
      | 1, 0 -> K
      | 0, 0 -> Se0
      | _ -> Se1
    in
    if not (equal_line l t.prev)
    then (
      if equal_line l Se1 then error t "SE1 on the line";
      match t.start with
      | None ->
        if equal_line l K
        then (
          if Float.(t.now -. t.idle_from < 2. *. t.bit_ns)
          then error t "less than 2 bit times between packets";
          t.start <- Some t.now;
          t.states <- [ t.now, K ])
      | Some start ->
        let bits = (t.now -. start) /. t.bit_ns in
        let off = Float.abs (bits -. Float.round_nearest bits) *. t.bit_ns in
        t.worst_jitter_ns <- Float.max t.worst_jitter_ns off;
        if Float.(off > 95.) then error t (sprintf "transition %.0f ns off the bit grid" off);
        t.states <- (t.now, l) :: t.states;
        if equal_line l Se0 then t.se0_from <- Some t.now;
        if equal_line l J && equal_line t.prev Se0
        then (
          let se0_from = Option.value_exn t.se0_from in
          let width = t.now -. se0_from in
          if Float.(width < 1250. || width > 1500.)
          then error t (sprintf "SE0 for %.0f ns" width);
          decode t ~start ~se0_from;
          t.start <- None;
          t.states <- [];
          t.se0_from <- None;
          t.idle_from <- t.now));
    t.prev <- l;
    t.now <- t.now +. t.ns_per_cycle
  ;;
end

(* A USB low-speed transmitter to drive the chip's receiver, from the same spec: whole packets
   (SYNC, PID, data, the inverted CRC-16 after a data PID) bit-stuffed, NRZI-coded from J, each
   ended by SE0, SE0, J, with idle J between. It plays them out at [bit_ns], which can be set off
   the nominal rate to test clock recovery. *)
module Usb_ls_transmitter = struct
  type t =
    { bit_ns : float
    ; ns_per_cycle : float
    ; mutable now : float
    ; states : Usb_ls_receiver.line array
    }

  let data_pids = [ 0xC3; 0x4B; 0x87; 0x0F ]

  let encode (pid, data) =
    let bytes =
      [ 0x80; pid ]
      @ data
      @
      if List.mem data_pids pid ~equal:Int.equal
      then (
        let crc = lnot (crc16_usb data) land 0xFFFF in
        [ crc land 0xFF; crc lsr 8 ])
      else []
    in
    let line = ref Usb_ls_receiver.J
    and ones = ref 0
    and out = ref [] in
    let toggle () =
      line
      := match !line with
         | J -> K
         | _ -> J
    in
    let send b =
      if b = 0
      then (
        toggle ();
        ones := 0)
      else incr ones;
      out := !line :: !out;
      if !ones = 6
      then (
        toggle ();
        ones := 0;
        out := !line :: !out)
    in
    List.iter bytes ~f:(fun byte ->
      for k = 0 to 7 do
        send ((byte lsr k) land 1)
      done);
    List.rev !out @ [ Usb_ls_receiver.Se0; Se0; J ]
  ;;

  let create ~bit_ns ~ns_per_cycle ?(gap_bits = 8) packets =
    let idle = List.init gap_bits ~f:(fun _ -> Usb_ls_receiver.J) in
    { bit_ns
    ; ns_per_cycle
    ; now = 0.
    ; states = Array.of_list (idle @ List.concat_map packets ~f:(fun p -> encode p @ idle))
    }
  ;;

  (* (D+, D-) this cycle *)
  let step t =
    let k = Float.iround_down_exn (t.now /. t.bit_ns) in
    t.now <- t.now +. t.ns_per_cycle;
    match if k < Array.length t.states then t.states.(k) else J with
    | J -> 0, 1
    | K -> 1, 0
    | Se0 -> 0, 0
    | Se1 -> 1, 1
  ;;
end


(* ---------------- 10BASE-T (802.3 clause 14) ---------------- *)

(* The Ethernet CRC-32 the usual (reflected) way; the FCS is its value, low byte first. *)
let crc32_eth bytes =
  List.fold bytes ~init:0xFFFF_FFFF ~f:(fun c b ->
    let c = ref (c lxor b) in
    for _ = 1 to 8 do
      c := if !c land 1 = 1 then (!c lsr 1) lxor 0xEDB8_8320 else !c lsr 1
    done;
    !c)
  lxor 0xFFFF_FFFF
;;

let with_fcs data =
  let c = crc32_eth data in
  data @ List.init 4 ~f:(fun k -> (c lsr (8 * k)) land 0xFF)
;;

(* The host's side of eth_tx.s: the frame as code to put at label `frame`. *)
let eth_frame_code data =
  let rec go = function
    | [] -> []
    | [ b ] -> [ "wait event tx_empty"; "csrw txcfg, r5"; sprintf "ldi r0, %d" b; "tx r0" ]
    | a :: b :: rest -> sprintf "ldi r0, %d" a :: sprintf "ldih r0, %d" b :: "tx r0" :: go rest
  in
  String.concat ~sep:"\n" (go data @ [ "ret"; "" ])
;;

(* Watches a TD line (one level per chip cycle) the way a link partner would: link pulses, and
   frames decoded from the Manchester code with every zero crossing checked against the 50 ns
   grid of the first one. A frame has to start with the preamble and SFD, carry whole bytes
   and a right FCS, and end with TP_IDL: high for 250-350 ns from the last rising edge (TP_IDL
   starts with the last positive transition), then idle. *)
module Ten_base_t_receiver = struct
  type frame =
    { data : int list (* without the FCS *)
    ; fcs_ok : bool
    ; tp_idl_ns : float
    ; ended : float (* when TP_IDL started *)
    }

  type t =
    { ns_per_cycle : float
    ; mutable now : float
    ; mutable level : int
    ; mutable edges : (float * int) list (* this burst, newest first *)
    ; mutable frames : frame list (* newest first *)
    ; mutable link_pulses : (float * float) list (* start, width; newest first *)
    ; mutable errors : string list
    ; mutable worst_grid_ns : float
    }

  let create ~ns_per_cycle =
    { ns_per_cycle
    ; now = 0.
    ; level = 0
    ; edges = []
    ; frames = []
    ; link_pulses = []
    ; errors = []
    ; worst_grid_ns = 0.
    }
  ;;

  let error t s = t.errors <- sprintf "%.0f ns: %s" t.now s :: t.errors

  let decode t edges =
    let first, _ = List.hd_exn edges in
    let near time = List.find edges ~f:(fun (at, _) -> Float.(abs (at -. time) <= 25.)) in
    let rec bits k acc =
      match near (first +. (100. *. Float.of_int k)) with
      | Some (_, l) -> bits (k + 1) (l :: acc)
      | None -> List.rev acc
    in
    let bits = bits 0 [] in
    let n = List.length bits in
    let fall, _ = List.last_exn edges in
    let rise = List.filter edges ~f:(fun (_, l) -> l = 1) |> List.last_exn |> fst in
    (* every crossing but the end of TP_IDL sits on the half-bit grid *)
    List.iter (List.drop_last_exn edges) ~f:(fun (at, _) ->
      let half = (at -. first) /. 50. in
      let off = Float.abs (half -. Float.round_nearest half) *. 50. in
      t.worst_grid_ns <- Float.max t.worst_grid_ns off;
      if Float.(off > 20.) then error t (sprintf "crossing %.0f ns off the grid" off));
    let tp_idl = fall -. rise in
    if Float.(tp_idl < 250. || tp_idl > 350.) then error t (sprintf "TP_IDL %.0f ns" tp_idl);
    let preamble = Pemu.Bitstream.(lsb_first_bits eth_preamble) in
    if n < 64 || not ([%equal: int list] (List.take bits 64) preamble)
    then error t "no preamble and SFD"
    else if (n - 64) mod 8 <> 0
    then error t (sprintf "%d bits after the SFD" (n - 64))
    else (
      let bytes =
        List.chunks_of (List.drop bits 64) ~length:8
        |> List.map ~f:(List.foldi ~init:0 ~f:(fun k acc b -> acc lor (b lsl k)))
      in
      if List.length bytes < 5
      then error t "frame too short"
      else (
        let data = List.take bytes (List.length bytes - 4) in
        let fcs_ok = [%equal: int list] (with_fcs data) bytes in
        if not fcs_ok then error t "FCS wrong";
        t.frames
        <- { data; fcs_ok; tp_idl_ns = tp_idl; ended = first +. (100. *. Float.of_int n) -. 50. }
           :: t.frames))
  ;;

  (* a burst ends after 1 us of idle *)
  let finish_burst t =
    let edges = List.rev t.edges in
    t.edges <- [];
    match edges with
    | [ (r, 1); (f, 0) ] when Float.(f -. r < 300.) ->
      let width = f -. r in
      if Float.(width < 80. || width > 200.) then error t (sprintf "link pulse %.0f ns" width);
      t.link_pulses <- (r, width) :: t.link_pulses
    | (_, 1) :: _ -> decode t edges
    | _ -> error t "burst doesn't start with a rising edge"
  ;;

  let step t level =
    if level <> t.level
    then (
      t.edges <- (t.now, level) :: t.edges;
      t.level <- level)
    else if level = 0
    then (
      match t.edges with
      | (last, _) :: _ when Float.(t.now -. last > 1000.) -> finish_burst t
      | _ -> ());
    t.now <- t.now +. t.ns_per_cycle
  ;;
end

(* A 10BASE-T transmitter to drive the chip's receiver: frames (the bytes after the SFD, FCS
   included) with preamble, SFD and TP_IDL, and a link pulse in each gap, at [bit_ns], with every
   zero crossing moved by a random amount in +-[jitter_ns] (802.3 asks a receiver to take
   13.5 ns). The chip samples it once a cycle, starting at [phase_ns]. *)
module Ten_base_t_transmitter = struct
  type t =
    { ns_per_cycle : float
    ; mutable now : float
    ; edges : (float * int) array
    ; mutable next : int
    ; mutable level : int
    }

  let create ~ns_per_cycle ~bit_ns ~jitter_ns ~phase_ns ~seed frames =
    let rng = Random.State.make [| seed |] in
    let jitter () =
      if Float.(jitter_ns > 0.) then Random.State.float_range rng (-.jitter_ns) jitter_ns else 0.
    in
    let edges = ref []
    and level = ref 0 in
    let go time l =
      if l <> !level
      then (
        edges := (time +. jitter (), l) :: !edges;
        level := l)
    in
    let start = ref 2000. in
    List.iter frames ~f:(fun bytes ->
      let bits = Pemu.Bitstream.lsb_first_bits (Pemu.Bitstream.eth_preamble @ bytes) in
      List.iteri bits ~f:(fun k b ->
        let at = !start +. (bit_ns *. Float.of_int k) in
        go at (1 - b);
        go (at +. (bit_ns /. 2.)) b);
      let fin = !start +. (bit_ns *. Float.of_int (List.length bits)) in
      (* TP_IDL: 300 ns high from the last rising edge *)
      let fall = if !level = 1 then fin +. 250. else fin +. 300. in
      go fin 1;
      go fall 0;
      (* a link pulse in the gap, then the next frame *)
      go (fall +. 3000.) 1;
      go (fall +. 3100.) 0;
      start := fall +. 9600.);
    { ns_per_cycle
    ; now = phase_ns
    ; edges = Array.of_list (List.rev !edges)
    ; next = 0
    ; level = 0
    }
  ;;

  let step t =
    while t.next < Array.length t.edges && Float.(fst t.edges.(t.next) <= t.now) do
      t.level <- snd t.edges.(t.next);
      t.next <- t.next + 1
    done;
    t.now <- t.now +. t.ns_per_cycle;
    t.level
  ;;

  let finished t = t.next >= Array.length t.edges
end

(* Reads eth_rx.s's nibble bus on uo[6:1]: RXD = uo[4:1], DV = uo[5], strobe = uo[6]. *)
module Nibble_bus = struct
  type t =
    { mutable strobe : int
    ; mutable dv : int
    ; mutable nibbles : int list (* this frame, newest first *)
    ; mutable frames : int list list (* newest first *)
    ; mutable errors : string list
    }

  let create () = { strobe = 0; dv = 0; nibbles = []; frames = []; errors = [] }

  let step t uo =
    let strobe = bit uo 6
    and dv = bit uo 5 in
    if strobe = 1 && t.strobe = 0
    then
      if dv = 1
      then t.nibbles <- ((uo lsr 1) land 0xF) :: t.nibbles
      else t.errors <- "strobe without DV" :: t.errors;
    if dv = 0 && t.dv = 1
    then (
      let rec bytes = function
        | lo :: hi :: rest -> (lo lor (hi lsl 4)) :: bytes rest
        | [] -> []
        | [ _ ] ->
          t.errors <- "odd number of nibbles" :: t.errors;
          []
      in
      t.frames <- bytes (List.rev t.nibbles) :: t.frames;
      t.nibbles <- []);
    t.strobe <- strobe;
    t.dv <- dv
  ;;
end
