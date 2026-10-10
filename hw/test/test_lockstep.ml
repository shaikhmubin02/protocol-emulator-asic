open! Core
open Pemu

let bit v k = (v lsr k) land 1

(* how much of the bit engine the random programs reach *)
let coverage = Array.create ~len:8 0

let run_random ?(lite = false) ~seed ~cycles () =
  let rng = Random.State.make [| seed |] in
  let program = Random_program.create rng in
  let fabric = Array.init Model.n_le ~f:(fun _ -> Random.State.int rng (1 lsl Fabric_logic.cfg_bits)) in
  let crc_poly = Random.State.int rng 0x1_0000_0000
  and crc_init = Random.State.int rng 0x1_0000_0000 in
  let ls = Lockstep.create ~lite ~fabric ~crc_poly ~crc_init program in
  for _ = 1 to cycles do
    let pads = { Model.Pads.uio_in = Random.State.int rng 256; ui_in = Random.State.int rng 256 } in
    let send = if Random.State.int rng 4 = 0 then Some (Random.State.int rng 0x10000) else None in
    let receive = Random.State.int rng 3 = 0 in
    let m = ls.model in
    let crc_before = m.be.crc
    and q_before = Array.map m.be.fab_q ~f:Hardcaml.Bits.to_int_trunc
    and left_before = m.be.sh_left
    and ready_before = m.be.rx_ready
    and acc_before = m.be.acc_rx
    and active_before = m.be.rx_active in
    ignore (Lockstep.step ?send ~receive ls pads : int option * bool);
    let bump k b = if b then coverage.(k) <- coverage.(k) + 1 in
    bump 0 m.be.enabled;
    bump 1 (m.be.sh_left < left_before);
    bump 2 (m.be.rx_ready && not ready_before);
    bump 3 (m.be.crc <> crc_before);
    bump 4 (not ([%equal: int array] q_before (Array.map m.be.fab_q ~f:Hardcaml.Bits.to_int_trunc)));
    bump 5 (m.be.rx_active && ((not active_before) || m.be.acc_rx < acc_before - 256));
    (* a CRC step with data bit 1 (the result differs from stepping with a 0) *)
    let step_with_zero =
      let fb = (crc_before lsr 31) land 1 = 1 in
      ((crc_before lsl 1) land 0xffff_ffff) lxor if fb then m.be.crc_poly else 0
    in
    bump 6 (m.be.crc <> crc_before && m.be.crc <> step_with_zero && m.be.crc <> m.be.crc_init);
    bump 7 (Array.existsi m.be.fab_cfg ~f:(fun k cfg ->
      Hardcaml.Bits.to_bool (Model.Fab.rx_clocked cfg)
      && Hardcaml.Bits.to_int_trunc m.be.fab_q.(k) <> q_before.(k)))
  done
;;

let%expect_test "random programs: RTL = model every cycle" =
  let programs = 300
  and cycles = 2000 in
  for seed = 1 to programs do
    try run_random ~seed ~cycles () with
    | Lockstep.Mismatch s -> raise_s [%message "seed" (seed : int) (s : Sexp.t)]
  done;
  printf "%d random programs x %d cycles: no difference\n" programs cycles;
  printf
    "bit engine: on %d, TX bits %d, RX words %d, CRC steps %d (data=1: %d), fabric changes %d (RX-clocked: %d), RX starts/aligns %d\n"
    coverage.(0)
    coverage.(1)
    coverage.(2)
    coverage.(3)
    coverage.(6)
    coverage.(4)
    coverage.(7)
    coverage.(5);
  [%expect {|
    300 random programs x 2000 cycles: no difference
    bit engine: on 351195, TX bits 3192, RX words 2516, CRC steps 65979 (data=1: 22858), fabric changes 78265 (RX-clocked: 60030), RX starts/aligns 30085
    |}]
;;

let load name =
  match Asm.assemble (In_channel.read_all ("../firmware/" ^ name)) with
  | Ok w -> w
  | Error e -> failwith e
;;

let%expect_test "spi_master.s in lockstep against an SPI target, all four modes" =
  for mode = 0 to 3 do
    let ls = Lockstep.create (load "spi_master.s") in
    let pending = Queue.of_list [ 0x8000 lor mode; 0x1A5; 0x03C; 0x2F0 ] in
    let miso = ref 0
    and prev_sck = ref 0
    and shift = ref 0x5A in
    let got = ref [] in
    for _ = 1 to 3000 do
      let send = Queue.peek pending in
      let read, wrote =
        Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = !miso lsl 4 }
      in
      if wrote then ignore (Queue.dequeue_exn pending : int);
      Option.iter read ~f:(fun v -> got := v :: !got);
      (* tiny target: shifts out 0x5A repeatedly on falling edges *)
      let sck = bit (Lockstep.uo ls) 1 in
      if sck = 0 && !prev_sck = 1 then shift := ((!shift lsl 1) lor (!shift lsr 7)) land 0xff;
      miso := bit !shift 7;
      prev_sck := sck
    done;
    printf "mode %d: %d cycles in lockstep, %d replies\n" mode ls.cycle (List.length !got)
  done;
  [%expect {|
    mode 0: 3000 cycles in lockstep, 3 replies
    mode 1: 3000 cycles in lockstep, 3 replies
    mode 2: 3000 cycles in lockstep, 3 replies
    mode 3: 3000 cycles in lockstep, 3 replies
    |}]
;;

let%expect_test "i2c_master.s in lockstep with a stretching target" =
  let ls = Lockstep.create (load "i2c_master.s") in
  let pending = Queue.of_list [ 0x608; 0x100; 0x2A0; 0x210; 0x25A; 0x500; 0x100; 0x2A1; 0x300; 0x400; 0x500 ] in
  let stretch = ref 0
  and prev_scl = ref 1
  and acked_bits = ref 0 in
  let got = ref [] in
  for _ = 1 to 20000 do
    let master_low p = bit (Lockstep.uio_oe ls) p = 1 && bit (Lockstep.uio_out ls) p = 0 in
    let scl = if master_low 0 || !stretch > 0 then 0 else 1 in
    (* a target that ACKs every 9th clock and stretches after it *)
    if scl = 1 && !prev_scl = 0 then incr acked_bits;
    let target_sda_low = !acked_bits mod 9 = 8 in
    let sda = if master_low 1 || target_sda_low then 0 else 1 in
    if scl = 0 && !prev_scl = 1 && !acked_bits mod 9 = 0 then stretch := 17;
    if !stretch > 0 then decr stretch;
    prev_scl := scl;
    let send = Queue.peek pending in
    let read, wrote =
      Lockstep.step ?send ~receive:true ls { Model.Pads.zero with uio_in = scl lor (sda lsl 1) }
    in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got)
  done;
  printf "%d cycles in lockstep, %d replies\n" ls.cycle (List.length !got);
  [%expect {| 20000 cycles in lockstep, 6 replies |}]
;;

let%expect_test "uart.s in lockstep, TX wired back to RX" =
  let ls = Lockstep.create (load "uart.s") in
  let pending = Queue.of_list [ 0x00; 0xFF; 0x55; 0xA5; 0x3C ] in
  let got = ref [] in
  let tx = ref 1 in
  for _ = 1 to 1500 do
    let send = Queue.peek pending in
    let read, wrote = Lockstep.step ?send ~receive:true ls { Model.Pads.zero with ui_in = !tx lsl 3 } in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got);
    tx := bit (Lockstep.uo ls) 0
  done;
  let got = List.rev !got in
  if not ([%equal: int list] got [ 0x00; 0xFF; 0x55; 0xA5; 0x3C ]) then raise_s [%message (got : int list)];
  printf "%d cycles in lockstep, echoed %s\n" ls.cycle (Sexp.to_string [%sexp (got : int list)]);
  [%expect {| 1500 cycles in lockstep, echoed (0 255 85 165 60) |}]
;;

let%expect_test "USB NRZI + bit stuffing bitstream in lockstep" =
  let program =
    match
      Asm.assemble
        {|
      ldi  r1, 0x07
      ldih r1, 0x0d        ; txcfg: 8 bits, LSB first, pin 8, through fabric, idle high
      csrw txcfg, r1
      ldi  r1, 0x0e
      ldih r1, 0x02        ; fabctl: line = element 7, hold = element 0, hold enabled
      csrw fabctl, r1
      csrwi baud, 3
      ben  1
loop: pull r0
      tx   r0
      jmp  loop
|}
    with
    | Ok w -> w
    | Error e -> failwith e
  in
  let ls = Lockstep.create ~fabric:(Bitstream.usb_tx ~n_le:Model.n_le) program in
  let pending = Queue.of_list [ 0xFF; 0xFF; 0x81; 0x7E; 0xFE; 0x3F ] in
  for _ = 1 to 600 do
    let send = Queue.peek pending in
    let _, wrote = Lockstep.step ?send ls Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn pending : int)
  done;
  printf "%d cycles in lockstep, %d bytes left unsent\n" ls.cycle (Queue.length pending);
  [%expect {| 600 cycles in lockstep, 0 bytes left unsent |}]
;;

let%expect_test "random programs on a lite engine (no fabric, no CRC)" =
  let programs = 150 in
  for seed = 1001 to 1000 + programs do
    try run_random ~lite:true ~seed ~cycles:2000 () with
    | Lockstep.Mismatch s -> raise_s [%message "seed" (seed : int) (s : Sexp.t)]
  done;
  printf "%d random programs x 2000 cycles on a lite engine: no difference\n" programs;
  [%expect {| 150 random programs x 2000 cycles on a lite engine: no difference |}]
;;

let%expect_test "ws2812.s in lockstep" =
  let ls = Lockstep.create (load "ws2812.s") in
  let pending = Queue.of_list (List.init 12 ~f:(fun k -> (k * 0x9e37) land 0xffff)) in
  for _ = 1 to 15_000 do
    let send = Queue.peek pending in
    let _, wrote = Lockstep.step ?send ls Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn pending : int)
  done;
  printf "%d cycles in lockstep, %d words left\n" ls.cycle (Queue.length pending);
  [%expect {| 15000 cycles in lockstep, 0 words left |}]
;;

(* 1-Wire with time scaled down 10x (5 cycles a microsecond) to keep the RTL simulation short *)
let%expect_test "onewire.s in lockstep against a 1-Wire device" =
  let ls = Lockstep.create (load "onewire.s") in
  let dev =
    Devices.One_wire_device.create ~us:5 ~family:0x28 ~serial:[ 1; 2; 3; 4; 5; 6 ]
  in
  let pending =
    Queue.of_list ([ 0x405; 0x100; 0x233 ] @ List.init 8 ~f:(fun _ -> 0x300))
  in
  let line = ref 1
  and got = ref [] in
  for _ = 1 to 60_000 do
    let send = Queue.peek pending in
    let read, wrote =
      Lockstep.step ?send ~receive:true ls { Model.Pads.zero with uio_in = !line lsl 2 }
    in
    if wrote then ignore (Queue.dequeue_exn pending : int);
    Option.iter read ~f:(fun v -> got := v :: !got);
    let master_low = bit (Lockstep.uio_oe ls) 2 = 1 && bit (Lockstep.uio_out ls) 2 = 0 in
    line := Devices.One_wire_device.step dev ~master_low
  done;
  let got = List.rev !got in
  if not (List.is_empty dev.errors) then raise_s [%message (dev.errors : string list)];
  printf "%d cycles in lockstep, replies %s, ROM matches %b\n" ls.cycle
    (Sexp.to_string [%sexp (got : int list)])
    ([%equal: int list] (List.drop got 1) (Array.to_list dev.rom));
  [%expect {| 60000 cycles in lockstep, replies (0 40 1 2 3 4 5 6 158), ROM matches true |}]
;;


let%expect_test "usb_tx.s in lockstep" =
  let ls = Lockstep.create (load "usb_tx.s") in
  let pending =
    Queue.of_list
      ([ 0x1C3 ] @ List.map [ 0x80; 0x06; 0xFF; 0xFF; 0xFF; 0x00 ] ~f:(fun b -> 0x200 lor b)
       @ [ 0x400; 0x1D2; 0x500 ])
  in
  for _ = 1 to 6_000 do
    let send = Queue.peek pending in
    let _, wrote = Lockstep.step ?send ls Model.Pads.zero in
    if wrote then ignore (Queue.dequeue_exn pending : int)
  done;
  printf "%d cycles in lockstep, %d words left\n" ls.cycle (Queue.length pending);
  [%expect {| 6000 cycles in lockstep, 0 words left |}]
;;

let%expect_test "usb_rx.s in lockstep, fed 1.5% slow" =
  let ls = Lockstep.create (load "usb_rx.s") in
  let far =
    Devices.Usb_ls_transmitter.create
      ~bit_ns:(1e9 /. 1.5e6 *. 1.015)
      ~ns_per_cycle:(1e9 /. 48e6)
      ~gap_bits:2
      [ 0xC3, [ 0x80; 0x06; 0xFF; 0xFF ]; 0xD2, [] ]
  in
  let got = ref 0 in
  for _ = 1 to 8_000 do
    let dp, dm = Devices.Usb_ls_transmitter.step far in
    let read, _ =
      Lockstep.step ~receive:true ls { Model.Pads.zero with uio_in = (dp lsl 4) lor (dm lsl 5) }
    in
    Option.iter read ~f:(fun _ -> incr got)
  done;
  printf "%d cycles in lockstep, %d words received\n" ls.cycle !got;
  [%expect {| 8000 cycles in lockstep, 10 words received |}]
;;
