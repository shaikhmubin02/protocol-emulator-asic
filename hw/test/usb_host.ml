(* A USB low-speed host on one root port, written from the USB 2.0 specification (chapter 7
   for the signalling, chapter 8 for packets and transactions, chapter 9 for the requests). It
   plays the host's packets onto D+/D- and reads the device's with the receiver in Devices,
   which watches every packet on the line and checks its shape (bit grid, stuffing, SYNC, PID,
   CRC-16, SE0 width, gaps). On top of that it checks:
   - the device starts its answer 2 to 6.5 bit times after the J that ends the host's packet
     (7.1.18.1; 6.5 is the limit at the device, there is no cable here),
   - the device never drives the line while the host does,
   - DATA0/DATA1 alternate as 8.6 says, and a repeated packet is acknowledged and dropped.

   Transactions are written in continuation-passing style: [transact t tr k] runs [k] with the
   result once the transaction is over, so a control transfer reads as a chain of them. *)

open! Core
module R = Devices.Usb_ls_receiver

let pid_out = 0xE1
let pid_in = 0x69
let pid_setup = 0x2D
let pid_data0 = 0xC3
let pid_data1 = 0x4B
let pid_ack = 0xD2
let pid_nak = 0x5A
let pid_stall = 0x1E

let pid_name p =
  if p = pid_data0
  then "DATA0"
  else if p = pid_data1
  then "DATA1"
  else if p = pid_ack
  then "ACK"
  else if p = pid_nak
  then "NAK"
  else if p = pid_stall
  then "STALL"
  else if p = pid_in
  then "IN"
  else if p = pid_out
  then "OUT"
  else if p = pid_setup
  then "SETUP"
  else sprintf "PID %02x" p
;;

(* the token's two bytes after the PID: address, endpoint, CRC-5 (8.3.5.1) *)
let token_bytes ~addr ~ep =
  let bits = List.init 7 ~f:(fun k -> (addr lsr k) land 1) @ List.init 4 ~f:(fun k -> (ep lsr k) land 1) in
  let c =
    List.fold bits ~init:0x1F ~f:(fun c b ->
      let fb = ((c lsr 4) land 1) lxor b in
      let c = (c lsl 1) land 0x1F in
      if fb = 1 then c lxor 0x05 else c)
    lxor 0x1F
  in
  let v = addr lor (ep lsl 7) lor (List.foldi (List.init 5 ~f:(fun k -> (c lsr (4 - k)) land 1)) ~init:0 ~f:(fun k acc b -> acc lor (b lsl (11 + k)))) in
  [ v land 0xFF; v lsr 8 ]
;;

type result =
  | Data of int * int list (* PID and data, CRC good *)
  | Handshake of int
  | No_answer
[@@deriving sexp_of]

type phase =
  | Free
  | Playing of
      { states : R.line array
      ; start : int
      ; next : unit -> unit
      }
  | Listening of
      { from : int (* the cycle of the J that ended the host's packet *)
      ; seen : int (* packets the bus receiver had decoded before *)
      ; mutable first_k : int option
      ; k : result -> unit
      }
  | Waiting of
      { until : int
      ; next : unit -> unit
      }

type t =
  { ns_per_cycle : float
  ; bit_cycles : float
  ; bus : R.t
  ; mutable cycle : int
  ; mutable phase : phase
  ; mutable drive : (int * int) option
  ; mutable errors : string list
  ; mutable turnarounds : float list (* in bit times *)
  ; mutable naks : int
  ; mutable no_answers : int
  ; trace : string Queue.t (* every packet on the line, with its cycle *)
  ; mutable traced : int
  ; log : string Queue.t
  }

let create ?(clock_hz = 48e6) () =
  let ns_per_cycle = 1e9 /. clock_hz in
  { ns_per_cycle
  ; bit_cycles = clock_hz /. 1.5e6
  ; bus = R.create ~ns_per_cycle
  ; cycle = 0
  ; phase = Free
  ; drive = None
  ; errors = []
  ; turnarounds = []
  ; naks = 0
  ; no_answers = 0
  ; trace = Queue.create ()
  ; traced = 0
  ; log = Queue.create ()
  }
;;

let error t s = t.errors <- sprintf "cycle %d: %s" t.cycle s :: t.errors
let say t fmt = ksprintf (fun s -> Queue.enqueue t.log s) fmt
let idle t = match t.phase with Free -> true | _ -> false

(* the first state goes out from the next cycle on, for a whole bit like the others *)
let play t states next = t.phase <- Playing { states = Array.of_list states; start = t.cycle + 1; next }

(* a new transaction: the line must have been idle for 2 bit times since the last packet
   (7.1.18); 3 here *)
let start t states next =
  t.phase <- Waiting { until = t.cycle + Float.iround_up_exn (3. *. t.bit_cycles); next = (fun () -> play t states next) }
;;
let wait t cycles next = t.phase <- Waiting { until = t.cycle + cycles; next }
let bits t n = Float.iround_up_exn (Float.of_int n *. t.bit_cycles)

let listen t k =
  t.phase <- Listening { from = t.cycle; seen = List.length t.bus.packets; first_k = None; k }
;;

(* SYNC and [bytes], bit-stuffed and NRZI-coded from J, then the end of packet *)
let line_states bytes =
  let line = ref R.J
  and ones = ref 0
  and out = ref [] in
  let toggle () = line := if R.equal_line !line R.J then R.K else R.J in
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
  List.iter (0x80 :: bytes) ~f:(fun byte ->
    for k = 0 to 7 do
      send ((byte lsr k) land 1)
    done);
  List.rev !out @ [ R.Se0; Se0; J ]
;;

(* [corrupt_crc]: the first data bit is flipped after the CRC was made, as noise would *)
let packet_states ?(corrupt_crc = false) (pid, data) =
  if not corrupt_crc
  then Devices.Usb_ls_transmitter.encode (pid, data)
  else (
    let crc = lnot (Devices.crc16_usb data) land 0xFFFF in
    let bad = List.mapi data ~f:(fun i b -> if i = 0 then b lxor 0x01 else b) in
    line_states ((pid :: bad) @ [ crc land 0xFF; crc lsr 8 ]))
;;

let gap = [ R.J; J ] (* with the J that ends a packet: 3 bit times between packets *)
let token pid ~addr ~ep = packet_states (pid, token_bytes ~addr ~ep)

(* one cycle. [dp]/[dm]: the line as the pads show it; [chip_drives]: the device drives D+ or
   D-. Returns what the host drives, if anything. *)
let step t ~dp ~dm ~chip_drives =
  t.cycle <- t.cycle + 1;
  R.step t.bus ~dp ~dm;
  if List.length t.bus.packets > t.traced
  then (
    t.traced <- List.length t.bus.packets;
    let p = List.hd_exn t.bus.packets in
    Queue.enqueue t.trace
      (sprintf "%7d %s %s %s" t.cycle
         (if Option.is_some t.drive then "host  " else "line  ")
         (pid_name p.pid)
         (String.concat ~sep:" " (List.map p.data ~f:(sprintf "%02x")))));
  (match t.phase with
   | Free -> t.drive <- None
   | Waiting w ->
     t.drive <- None;
     if t.cycle >= w.until
     then (
       t.phase <- Free;
       w.next ())
   | Playing p ->
     let k = Float.iround_down_exn (Float.of_int (t.cycle - p.start) /. t.bit_cycles) in
     if k < Array.length p.states
     then
       t.drive
       <- Some
            (match p.states.(k) with
             | J -> 0, 1
             | K -> 1, 0
             | Se0 -> 0, 0
             | Se1 -> 1, 1)
     else (
       t.drive <- None;
       t.phase <- Free;
       p.next ())
   | Listening l ->
     t.drive <- None;
     if Option.is_none l.first_k && dp = 1 && dm = 0 then l.first_k <- Some t.cycle;
     let decoded = List.length t.bus.packets in
     if decoded > l.seen
     then (
       let p = List.hd_exn t.bus.packets in
       let first = Option.value l.first_k ~default:t.cycle in
       (* the host's packet ended with one bit of J, which [from] is the end of *)
       let ta = (Float.of_int (first - l.from) /. t.bit_cycles) +. 1. in
       t.turnarounds <- ta :: t.turnarounds;
       if Float.(ta < 2. || ta > 6.5)
       then error t (sprintf "device answered %.2f bit times after the end of the host's packet" ta);
       let r =
         if List.mem [ pid_data0; pid_data1 ] p.pid ~equal:Int.equal
         then
           if Poly.equal p.crc_ok (Some true)
           then Data (p.pid, p.data)
           else (
             error t "a data packet with a bad CRC";
             No_answer)
         else Handshake p.pid
       in
       t.phase <- Free;
       l.k r)
     else if Option.is_none l.first_k
             && Float.(of_int Int.(t.cycle - l.from) > 17. *. t.bit_cycles)
     then (
       (* 16 to 18 bit times from the host's EOP with no SYNC: timeout (8.7.3) *)
       t.phase <- Free;
       l.k No_answer)
     else if Float.(of_int Int.(t.cycle - l.from) > 120. *. t.bit_cycles)
     then (
       (* a packet started but the line receiver never read a whole one *)
       error t "the device's answer never became a packet";
       t.phase <- Free;
       l.k No_answer));
  if Option.is_some t.drive && chip_drives then error t "the device drives the line while the host does";
  t.drive
;;

(* ---- transactions (8.4, 8.5) *)

let setup t ~addr ?(corrupt_crc = false) data k =
  start t (token pid_setup ~addr ~ep:0 @ gap @ packet_states ~corrupt_crc (pid_data0, data)) (fun () ->
    listen t k)
;;

(* IN: on good data the host acknowledges it, unless [ack] is false (the ACK lost on the way);
   [garble_ack] sends a broken ACK the device must ignore *)
let in_ t ~addr ~ep ?(ack = true) ?(garble_ack = false) k =
  start t (token pid_in ~addr ~ep) (fun () ->
    listen t (fun r ->
      match r with
      | Data _ when ack ->
        let hs =
          if garble_ack
          then packet_states (0xD3, []) (* the PID's check bits don't match: not an ACK *)
          else packet_states (pid_ack, [])
        in
        wait t (bits t 3) (fun () -> play t hs (fun () -> t.phase <- Free; k r))
      | _ -> k r))
;;

let out t ~addr ~ep ~pid data k =
  start t (token pid_out ~addr ~ep @ gap @ packet_states (pid, data)) (fun () -> listen t k)
;;

let bus_reset t ~cycles k =
  start t (List.init (Float.iround_up_exn (Float.of_int cycles /. t.bit_cycles)) ~f:(fun _ -> R.Se0) @ [ R.J ])
    (fun () -> wait t cycles k)
;;

(* ---- retries: NAK means try again later; no answer counts as an error, three end it *)

let rec in_retry t ~addr ~ep ?(errors = 0) k =
  in_ t ~addr ~ep (fun r ->
    match r with
    | Handshake p when p = pid_nak ->
      t.naks <- t.naks + 1;
      wait t (bits t 40) (fun () -> in_retry t ~addr ~ep ~errors k)
    | No_answer when errors < 2 ->
      t.no_answers <- t.no_answers + 1;
      wait t (bits t 20) (fun () -> in_retry t ~addr ~ep ~errors:(errors + 1) k)
    | r -> k r)
;;

let rec out_retry t ~addr ~ep ~pid ?(errors = 0) data k =
  out t ~addr ~ep ~pid data (fun r ->
    match r with
    | Handshake p when p = pid_nak ->
      t.naks <- t.naks + 1;
      wait t (bits t 40) (fun () -> out_retry t ~addr ~ep ~pid ~errors data k)
    | No_answer when errors < 2 ->
      t.no_answers <- t.no_answers + 1;
      wait t (bits t 20) (fun () -> out_retry t ~addr ~ep ~pid ~errors:(errors + 1) data k)
    | r -> k r)
;;

let rec setup_retry t ~addr ?(errors = 0) ?corrupt_crc data k =
  setup t ~addr ?corrupt_crc data (fun r ->
    match r with
    | Handshake p when p = pid_ack -> k ()
    | No_answer when errors < 2 ->
      t.no_answers <- t.no_answers + 1;
      wait t (bits t 20) (fun () -> setup_retry t ~addr ~errors:(errors + 1) data k)
    | r -> error t (sprintf !"SETUP answered with %{sexp:result}" r))
;;

(* ---- control transfers (8.5.3) *)

type control_result =
  | Done of int list
  | Stalled
[@@deriving sexp_of]

let request ~typ ~req ~value ~index ~len =
  [ typ; req; value land 0xFF; value lsr 8; index land 0xFF; index lsr 8; len land 0xFF; len lsr 8 ]
;;

let other pid = if pid = pid_data0 then pid_data1 else pid_data0

let control_read t ~addr ?corrupt_crc ?(lose_ack_at = -1) ?(garble_ack_at = -1) setup_data k =
  let len = List.nth_exn setup_data 6 lor (List.nth_exn setup_data 7 lsl 8) in
  setup_retry t ~addr ?corrupt_crc setup_data (fun () ->
    let rec data_stage acc ~want ~n =
      let ack = n <> lose_ack_at
      and garble_ack = n = garble_ack_at in
      in_ t ~addr ~ep:0 ~ack ~garble_ack (fun r ->
        match r with
        | Handshake p when p = pid_nak ->
          t.naks <- t.naks + 1;
          wait t (bits t 40) (fun () -> data_stage acc ~want ~n)
        | Handshake p when p = pid_stall -> k Stalled
        | Data (p, d) when not ack ->
          say t "  (the host lost its ACK of packet %d: %s, %d bytes)" n (pid_name p) (List.length d);
          wait t (bits t 40) (fun () -> data_stage acc ~want ~n:(n + 1))
        | Data (p, _) when p <> want ->
          (* a packet the host already has: the device didn't see the ACK (8.6.4) *)
          say t "  (a repeat of the last packet, %s: acknowledged and dropped)" (pid_name p);
          wait t (bits t 40) (fun () -> data_stage acc ~want ~n:(n + 1))
        | Data (_, d) ->
          let acc = acc @ d in
          if garble_ack then say t "  (the host's ACK of packet %d was broken on the line)" n;
          if List.length d < 8 || List.length acc >= len
          then
            out_retry t ~addr ~ep:0 ~pid:pid_data1 [] (fun r ->
              match r with
              | Handshake p when p = pid_ack -> k (Done acc)
              | r -> error t (sprintf !"status stage: %{sexp:result}" r))
          else wait t (bits t 40) (fun () -> data_stage acc ~want:(other want) ~n:(n + 1))
        | r -> error t (sprintf !"data stage: %{sexp:result}" r))
    in
    data_stage [] ~want:pid_data1 ~n:0)
;;

(* a request with no data stage, or with an OUT data stage of [data] *)
let control_write t ~addr ?(data = []) setup_data k =
  setup_retry t ~addr setup_data (fun () ->
    let status () =
      in_retry t ~addr ~ep:0 (fun r ->
        match r with
        | Data (p, []) when p = pid_data1 -> k (Done [])
        | Handshake p when p = pid_stall -> k Stalled
        | r -> error t (sprintf !"status stage: %{sexp:result}" r))
    in
    if List.is_empty data
    then status ()
    else
      out_retry t ~addr ~ep:0 ~pid:pid_data1 data (fun r ->
        match r with
        | Handshake p when p = pid_ack -> wait t (bits t 20) status
        | Handshake p when p = pid_stall -> k Stalled
        | r -> error t (sprintf !"data stage: %{sexp:result}" r)))
;;

(* run steps one after the other; each gets the function that starts the next *)
let rec seq = function
  | [] -> ()
  | step :: rest -> step (fun () -> seq rest)
;;
