(* The whole chip, driven only through its pins: everything is loaded and read over host SPI. *)

open! Core
open Pemu
module H = Chip_host

let assemble src =
  match Asm.assemble src with
  | Ok w -> w
  | Error e -> failwith e
;;

let load name = assemble (In_channel.read_all ("../firmware/" ^ name))
let hex l = String.concat ~sep:" " (List.map l ~f:(sprintf "%04x"))

let%expect_test "chip id, run register and cycle counter" =
  let t = H.create () in
  let lo1 = H.read1 t H.time_lo in
  let lo2 = H.read1 t H.time_lo in
  printf
    "id %04x, run %d, hi %d, counter moved %b\n"
    (H.read1 t H.id_reg)
    (H.read1 t H.run_reg)
    (H.read1 t H.time_hi)
    (lo2 > lo1);
  [%expect {| id 5045, run 0, hi 0, counter moved true |}]
;;

let%expect_test "program memory: write and read back on every engine" =
  let t = H.create () in
  let rng = Random.State.make [| 1 |] in
  let words = Array.init 4 ~f:(fun _ -> List.init 24 ~f:(fun _ -> Random.State.int rng 0x10000)) in
  Array.iteri words ~f:(fun e w -> H.write t (H.program e 100) w);
  Array.iteri words ~f:(fun e w ->
    let back = H.read t (H.program e 100) 24 in
    printf "engine %d: %s\n" e (if [%equal: int list] w back then "ok" else "differs: " ^ hex back));
  [%expect {|
    engine 0: ok
    engine 1: ok
    engine 2: ok
    engine 3: ok
    |}]
;;

let%expect_test "uart.s loaded over SPI, TX looped back to RX" =
  let t = H.create () in
  H.load t 1 (load "uart.s");
  (* nothing owns uo[0] yet, so it stays low *)
  H.run t 0b0010;
  H.cycles t 50;
  printf "uo[0] before owning: %d\n" (H.uo t land 1);
  H.own t ~pin:8 ~engine:1;
  t.on_cycle <- (fun t -> t.ui <- (t.ui land lnot 0x08) lor ((H.uo t land 1) lsl 3));
  let sent = [ 0x00; 0xff; 0x55; 0xa5; 0x3c; 0x81 ] in
  (* like a real host: one status read per turn, then drain the outbox and top up the inbox
     (the outbox holds two words; if the host stops reading, the firmware blocks on push and
     RX overruns) *)
  let pending = Queue.of_list sent in
  let got = ref [] in
  let deadline = t.cycle + 30_000 in
  while List.length !got < List.length sent && t.cycle < deadline do
    let st = H.read1 t (H.status 1) in
    let inbox = (st lsr 10) land 3
    and outbox = (st lsr 12) land 3 in
    if outbox > 0 then got := !got @ H.read t (H.mailbox 1) outbox;
    if inbox < 2 then Option.iter (Queue.dequeue pending) ~f:(fun b -> H.write t (H.mailbox 1) [ b ])
  done;
  printf "sent %s\ngot  %s\n" (hex sent) (hex !got);
  [%expect {|
    uo[0] before owning: 0
    sent 0000 00ff 0055 00a5 003c 0081
    got  0000 00ff 0055 00a5 003c 0081
    |}]
;;

let%expect_test "engines meet on an event flag" =
  let t = H.create () in
  (* three engines wait for flag 2 and report the time they woke; engine 2 raises flag 2 once
     the host raises flag 7 *)
  let waiter =
    assemble {|
      wait flag 2, 1
      csrr r0, time_lo
      push r0
      halt
|}
  in
  let starter = assemble {|
      wait flag 7, 1
      sig  2
      clrf 7
      halt
|} in
  List.iter [ 0; 1; 3 ] ~f:(fun e -> H.load t e waiter);
  H.load t 2 starter;
  H.run t 0b1111;
  H.cycles t 100;
  let before = List.map [ 0; 1; 3 ] ~f:(fun e -> H.outbox_count t e) in
  H.write t H.flags_reg [ 0x80 ];
  H.cycles t 20;
  let woke = List.map [ 0; 1; 3 ] ~f:(fun e -> H.read1 t (H.mailbox e)) in
  printf
    "outboxes before %s, flags after %02x, all woke together %b\n"
    (Sexp.to_string [%sexp (before : int list)])
    (H.read1 t H.flags_reg)
    (List.for_all woke ~f:(fun w -> w = List.hd_exn woke));
  [%expect {| outboxes before (0 0 0), flags after 04, all woke together true |}]
;;

let%expect_test "mailbox reads one word at a time lose nothing" =
  let t = H.create () in
  H.load
    t
    0
    (assemble
       {|
      ldi  r0, 1
      push r0
      ldi  r0, 2
      push r0
      ldi  r0, 3
      push r0
      halt
|});
  H.run t 0b0001;
  H.cycles t 50;
  (* a plain loop: List.init calls its function from the last index down *)
  let got = ref [] in
  for _ = 1 to 3 do
    got := !got @ [ H.read1 t (H.mailbox 0) ]
  done;
  let got = !got in
  printf "got %s, outbox left %d\n" (hex got) (H.outbox_count t 0);
  [%expect {| got 0001 0002 0003, outbox left 0 |}]
;;

(* Three engines at once, each with its own device on its own pins, all loaded and serviced over
   the host port: engine 0 is an SPI master in mode 3, engine 1 an I2C master at 400 kHz (taking
   the clock as 50 MHz) against an EEPROM that stretches the clock, engine 2 (a lite engine) a
   UART looped back on itself. *)
let%expect_test "SPI, I2C and UART running at the same time" =
  let open Devices in
  let t = H.create () in
  H.load t 0 (load "spi_master.s");
  H.load t 1 (load "i2c_master.s");
  H.load t 2 (load "uart.s");
  (* pins first: an engine's writes to pins it doesn't own are dropped *)
  List.iter [ 9; 10; 11 ] ~f:(fun pin -> H.own t ~pin ~engine:0);
  List.iter [ 0; 1 ] ~f:(fun pin -> H.own t ~pin ~engine:1);
  H.own t ~pin:8 ~engine:2;
  H.run t 0b0111;
  let spi = Spi_target.create ~mode:3 in
  let eeprom = Eeprom.create ~stretch:100 in
  let timing = I2c_timing.create () in
  (* which protocols were mid-transfer in each 1000-cycle window: SPI with CS low, I2C between
     START and STOP, UART with a frame on the wire *)
  let windows = Hashtbl.create (module Int) in
  let active k = Hashtbl.update windows (t.cycle / 1000) ~f:(fun v -> Option.value v ~default:0 lor k) in
  let prev_uo = ref (H.uo t)
  and prev_scl = ref 1 in
  t.uio_ext <- 0xff (* pull-ups *);
  t.on_cycle
  <- (fun t ->
       let uo = H.uo t in
       Spi_target.step spi ~sck:(bit uo 1) ~mosi:(bit uo 2) ~cs:(bit uo 3);
       let chip_low p = bit (H.uio_oe t) p = 1 && bit (H.uio_out t) p = 0 in
       let scl = if chip_low 0 || Eeprom.scl_low eeprom then 0 else 1 in
       let sda = if chip_low 1 || eeprom.sda_low then 0 else 1 in
       Eeprom.step eeprom ~scl ~sda;
       I2c_timing.step timing ~scl ~sda;
       let released b = if b then 0 else 1 in
       t.uio_ext
       <- 0xfc lor released (Eeprom.scl_low eeprom) lor (released eeprom.sda_low lsl 1);
       (* UART TX (uo[0]) back to RX (ui[3]); MISO to ui[4] *)
       t.ui <- (t.ui land lnot 0x18) lor ((uo land 1) lsl 3) lor (spi.miso lsl 4);
       if bit uo 3 = 0 then active 1;
       if not (Poly.equal eeprom.phase Eeprom.Idle) then active 2;
       if bit uo 0 <> bit !prev_uo 0 then active 4;
       prev_uo := uo;
       prev_scl := scl);
  let spi_data = List.init 12 ~f:(fun k -> (k * 0x35) land 0xff) in
  let i2c =
    [ 0x619 (* Q = 25 *); 0x100; 0x2A0; 0x210; 0x25A; 0x2C3; 0x500
    ; 0x100; 0x2A0; 0x210; 0x100; 0x2A1; 0x300; 0x400; 0x500 ]
  in
  let uart = List.init 12 ~f:(fun k -> (k * 0x4b) lxor 0xa5 land 0xff) in
  let pending =
    [| Queue.of_list
         (0x8003
          :: List.mapi spi_data ~f:(fun i b ->
            b lor (if i = 0 then 0x100 else 0) lor if i = 11 then 0x200 else 0))
     ; Queue.of_list i2c
     ; Queue.of_list uart
    |]
  in
  let want = [| List.length spi_data; 9; List.length uart |] in
  let got = Array.create ~len:3 [] in
  let deadline = t.cycle + 300_000 in
  while
    Array.existsi want ~f:(fun e n -> List.length got.(e) < n) && t.cycle < deadline
  do
    for e = 0 to 2 do
      let st = H.read1 t (H.status e) in
      let inbox = (st lsr 10) land 3
      and outbox = (st lsr 12) land 3 in
      if outbox > 0 then got.(e) <- got.(e) @ H.read t (H.mailbox e) outbox;
      let room = 2 - inbox in
      let words = List.init (min room (Queue.length pending.(e))) ~f:(fun _ -> ()) in
      let words = List.map words ~f:(fun () -> Queue.dequeue_exn pending.(e)) in
      if not (List.is_empty words) then H.write t (H.mailbox e) words
    done
  done;
  let khz = I2c_timing.check timing ~fast:true ~ns_per_cycle:20 in
  let all_three = Hashtbl.count windows ~f:(fun v -> v = 7)
  and any = Hashtbl.length windows in
  let spi_expected =
    0xA5 :: List.map (List.drop_last_exn spi_data) ~f:(fun b -> lnot b land 0xff)
  in
  if not ([%equal: int list] (List.rev spi.received) spi_data) then failwith "SPI target data";
  if not ([%equal: int list] got.(0) spi_expected) then failwith "SPI master data";
  if not ([%equal: int list] got.(1) [ 0; 0; 0; 0; 0; 0; 0; 0x5A; 0xC3 ]) then failwith "I2C";
  if not ([%equal: int list] got.(2) uart) then failwith "UART";
  printf "SPI  %d bytes each way in one CS-low transfer: ok\n" (List.length spi_data);
  printf "I2C  replies %s, EEPROM 0x10-11 = %02x %02x, %d kHz, %d stretched ACKs\n" (hex got.(1))
    eeprom.mem.(0x10) eeprom.mem.(0x11) khz eeprom.stretches;
  printf "UART %d bytes echoed: ok\n" (List.length uart);
  printf "all three mid-transfer in %d of %d busy 1000-cycle windows\n" all_three any;
  [%expect {|
    SPI  12 bytes each way in one CS-low transfer: ok
    I2C  replies 0000 0000 0000 0000 0000 0000 0000 005a 00c3, EEPROM 0x10-11 = 5a c3, 384 kHz, 7 stretched ACKs
    UART 12 bytes echoed: ok
    all three mid-transfer in 6 of 28 busy 1000-cycle windows
    |}]
;;
