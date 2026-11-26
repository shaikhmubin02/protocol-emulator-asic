(* The board's processor for the chip as a USB keyboard: the part a small microcontroller next to
   the chip would do, through the chip's SPI host port, at the port's real speed. It holds the
   descriptors (chapter 9 of USB 2.0, the HID 1.11 boot keyboard), answers requests and feeds
   key reports; the chip does everything on the wire.

   usb_dev_rx.s (engine 0) tells it what came in; it reads SETUP and OUT data straight out of
   engine 0's registers, writes engine 0's token value (address) back, and loads the next packet
   into usb_dev_tx.s (engine 1) through its inbox. *)

open! Core
module H = Chip_host

let rx = 0
let tx = 1
let pid_data0 = 0xC3
let pid_data1 = 0x4B
let pid_stall = 0x1E

let device_descriptor =
  [ 18; 1; 0x10; 0x01 (* USB 1.1 *); 0; 0; 0 (* class in the interface *); 8 (* EP0 packets *)
  ; 0x09; 0x12; 0x01; 0x00 (* vendor 0x1209, product 0x0001 *); 0x00; 0x01 (* release 1.00 *)
  ; 1; 2; 0 (* manufacturer, product, no serial number *); 1 (* configurations *)
  ]
;;

(* HID 1.11 appendix B.1: the boot keyboard report, 8 bytes in, 1 byte (LEDs) out *)
let report_descriptor =
  [ 0x05; 0x01; 0x09; 0x06; 0xA1; 0x01 (* generic desktop, keyboard, application *)
  ; 0x05; 0x07; 0x19; 0xE0; 0x29; 0xE7; 0x15; 0x00; 0x25; 0x01; 0x75; 0x01; 0x95; 0x08; 0x81; 0x02
    (* 8 modifier bits *)
  ; 0x95; 0x01; 0x75; 0x08; 0x81; 0x01 (* a reserved byte *)
  ; 0x95; 0x05; 0x75; 0x01; 0x05; 0x08; 0x19; 0x01; 0x29; 0x05; 0x91; 0x02 (* 5 LEDs *)
  ; 0x95; 0x01; 0x75; 0x03; 0x91; 0x01 (* padding *)
  ; 0x95; 0x06; 0x75; 0x08; 0x15; 0x00; 0x25; 0x65; 0x05; 0x07; 0x19; 0x00; 0x29; 0x65; 0x81; 0x00
    (* 6 key codes *)
  ; 0xC0
  ]
;;

let config_descriptor =
  [ 9; 2; 34; 0; 1; 1; 0; 0x80; 50 (* 34 bytes, 1 interface, bus powered, 100 mA *)
  ; 9; 4; 0; 0; 1; 3; 1; 1; 0 (* interface 0: HID, boot, keyboard, 1 endpoint *)
  ; 9; 0x21; 0x11; 0x01; 0; 1; 0x22; List.length report_descriptor; 0 (* HID 1.11 *)
  ; 7; 5; 0x81; 3; 8; 0; 10 (* endpoint 1 IN, interrupt, 8 bytes, every 10 ms *)
  ]
;;

let string_descriptor s =
  let u = List.concat_map (String.to_list s) ~f:(fun c -> [ Char.to_int c; 0 ]) in
  (2 + List.length u) :: 3 :: u
;;

let strings = [| [ 4; 3; 0x09; 0x04 ]; string_descriptor "pemu"; string_descriptor "pemu keyboard" |]

(* what the transmit engine holds: endpoint and packet *)
type held =
  { ep : int
  ; pid : int
  ; data : int list
  }

type t =
  { h : H.t
  ; mutable addr : int
  ; mutable new_addr : int option (* SET_ADDRESS: used once its status stage is over *)
  ; mutable ep0 : held list (* still to go on endpoint 0, the first one loaded or next *)
  ; mutable after_out : held list (* the status packet that follows an OUT data stage *)
  ; mutable held : held option
  ; mutable configured : bool
  ; mutable leds : int
  ; mutable reports : int list list (* key reports still to send *)
  ; mutable ep1_pid : int
  ; mutable lost : int
  ; log : string Queue.t
  }

let create h =
  { h
  ; addr = 0
  ; new_addr = None
  ; ep0 = []
  ; after_out = []
  ; held = None
  ; configured = false
  ; leds = 0
  ; reports = []
  ; ep1_pid = pid_data0
  ; lost = 0
  ; log = Queue.create ()
  }
;;

let say t fmt = ksprintf (fun s -> Queue.enqueue t.log s) fmt

(* the 16 bits after a token's PID for (address, endpoint 0): what usb_dev_rx.s compares *)
let token_value addr =
  match Usb_host.token_bytes ~addr ~ep:0 with
  | [ lo; hi ] -> lo lor (hi lsl 8)
  | _ -> assert false
;;

(* write words to an engine's inbox, waiting for room *)
let to_inbox t e words =
  List.iter words ~f:(fun w ->
    while H.inbox_count t.h e >= 2 do
      ()
    done;
    H.write t.h (H.mailbox e) [ w ])
;;

let load t (p : held) =
  let n = List.length p.data in
  let is_data = p.pid = pid_data0 || p.pid = pid_data1 in
  let header = (n lsl 12) lor ((if is_data then 1 else 0) lsl 11) lor (p.ep lsl 10) lor p.pid in
  let rec pairs = function
    | a :: b :: rest -> (a lor (b lsl 8)) :: pairs rest
    | [ a ] -> [ a ]
    | [] -> []
  in
  to_inbox t tx (header :: List.rev (pairs p.data));
  t.held <- Some p
;;

let clear_tx t =
  to_inbox t tx [ 0 ];
  t.held <- None
;;

(* load the next packet if the transmit engine is free: endpoint 0 first *)
let feed t =
  match t.ep0, t.held with
  | p :: _, None -> load t p
  | p :: _, Some h when h.ep = 1 ->
    (* a key report waits while endpoint 0 has something to say *)
    clear_tx t;
    load t p
  | [], None when t.configured && List.is_empty t.after_out ->
    (match t.reports with
     | r :: _ -> load t { ep = 1; pid = t.ep1_pid; data = r }
     | [] -> ())
  | _ -> ()
;;

let other pid = if pid = pid_data0 then pid_data1 else pid_data0

(* the packets of a control read: [data] cut to [len], 8 bytes a packet from DATA1, and an empty
   packet at the end if the data stops short of [len] on a packet boundary *)
let reply data ~len =
  let data = List.take data len in
  let rec cut pid = function
    | [] -> []
    | l ->
      let p = List.take l 8 in
      { ep = 0; pid; data = p } :: cut (other pid) (List.drop l 8)
  in
  let packets = cut pid_data1 data in
  let n = List.length data in
  if n < len && n % 8 = 0
  then packets @ [ { ep = 0; pid = (if n / 8 % 2 = 0 then pid_data1 else pid_data0); data = [] } ]
  else packets
;;

let zlp = { ep = 0; pid = pid_data1; data = [] }
let stall = { ep = 0; pid = pid_stall; data = [] }

let setup t bytes =
  let typ = List.nth_exn bytes 0
  and req = List.nth_exn bytes 1
  and value = List.nth_exn bytes 2 lor (List.nth_exn bytes 3 lsl 8)
  and len = List.nth_exn bytes 6 lor (List.nth_exn bytes 7 lsl 8) in
  (* a new SETUP ends whatever endpoint 0 was doing; an endpoint 1 report waits *)
  (match t.held with
   | Some _ -> clear_tx t
   | None -> ());
  t.after_out <- [];
  let packets =
    match typ, req with
    | 0x80, 6 ->
      let d =
        match value lsr 8, value land 0xFF with
        | 1, _ -> Some device_descriptor
        | 2, 0 -> Some config_descriptor
        | 3, i when i < Array.length strings -> Some strings.(i)
        | _ -> None
      in
      (match d with
       | Some d -> reply d ~len
       | None -> [ stall ])
    | 0x81, 6 when value lsr 8 = 0x22 -> reply report_descriptor ~len
    | 0x00, 5 ->
      t.new_addr <- Some (value land 0x7F);
      [ zlp ]
    | 0x00, 9 ->
      t.configured <- value = 1;
      t.ep1_pid <- pid_data0;
      [ zlp ]
    | 0x80, 8 -> reply [ (if t.configured then 1 else 0) ] ~len
    | 0x80, 0 -> reply [ 0; 0 ] ~len
    | 0x21, 0x0A (* SET_IDLE *) | 0x21, 0x0B (* SET_PROTOCOL *) -> [ zlp ]
    | 0x21, 0x09 (* SET_REPORT: the LEDs come in an OUT data stage *) ->
      t.after_out <- [ zlp ];
      []
    | _ -> [ stall ]
  in
  say t "SETUP %s" (String.concat ~sep:" " (List.map bytes ~f:(sprintf "%02x")));
  t.ep0 <- packets
;;

(* the data words usb_dev_rx.s kept: [count] bytes came in with the CRC *)
let read_data t ~count =
  let n = Int.min (count - 2) 8 in
  let kept = Int.min count 8 in
  let words = (kept + 1) / 2 in
  let regs = H.read t.h (H.reg rx 4) 4 in
  let ws = List.drop regs (4 - words) in
  List.concat_map ws ~f:(fun w -> [ w land 0xFF; w lsr 8 ]) |> fun l -> List.take l n
;;

let handle t w =
  match w lsr 12 with
  | 4 ->
    say t "bus reset";
    t.addr <- 0;
    t.new_addr <- None;
    t.ep0 <- [];
    t.after_out <- [];
    t.configured <- false;
    if Option.is_some t.held then clear_tx t
  | 1 ->
    let bytes = read_data t ~count:((w lsr 8) land 0xF) in
    to_inbox t rx [ token_value t.addr ];
    if List.length bytes = 8 then setup t bytes else say t "a SETUP with %d bytes" (List.length bytes)
  | 2 ->
    let bytes = read_data t ~count:((w lsr 8) land 0xF) in
    to_inbox t rx [ token_value t.addr ];
    (match bytes with
     | [ leds ] when not (List.is_empty t.after_out) ->
       t.leds <- leds;
       say t "LEDs %02x" leds;
       t.ep0 <- t.after_out;
       t.after_out <- []
     | [] -> () (* the status stage of a control read *)
     | b -> say t "OUT data %s" (String.concat ~sep:" " (List.map b ~f:(sprintf "%02x"))))
  | 3 ->
    let ep = w land 1 in
    (match t.held with
     | Some p when p.ep = ep ->
       t.held <- None;
       if ep = 0
       then (
         t.ep0 <- List.tl t.ep0 |> Option.value ~default:[];
         if List.is_empty t.ep0
         then
           Option.iter t.new_addr ~f:(fun a ->
             t.addr <- a;
             t.new_addr <- None;
             to_inbox t rx [ token_value a ];
             say t "address %d" a))
       else (
         t.reports <- List.tl t.reports |> Option.value ~default:[];
         t.ep1_pid <- other t.ep1_pid)
     | _ -> say t "an ACK for endpoint %d, which holds nothing" ep)
  | _ -> say t "unknown word %04x" w
;;

(* one round: read what engine 0 has, act on it, keep engine 1 fed *)
let poll t =
  let n = H.outbox_count t.h rx in
  if n > 0 then List.iter (H.read t.h (H.mailbox rx) n) ~f:(handle t);
  feed t
;;
