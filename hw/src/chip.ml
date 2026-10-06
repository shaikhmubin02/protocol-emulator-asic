(* The chip: four engines, the host SPI port, pin owners, and the cycle counter and event flags
   that all engines share.

   Pins: ui[0] SCK, ui[1] CSn, ui[2] MOSI, uo[7] MISO. That's the host port: SPI mode 0, SCK at
   most clk/8. Protocol pins 0..14 (uio[7:0], uo[6:0]) are driven by whichever engine owns them.
   Every engine sees all of ui[7:0] and the uio pads.

   Host frames are MSB first: a command byte, a 16-bit address, then 16-bit words. The address
   goes up by one after every word.
     0x02 write: the words follow the address.
     0x03 read: one dummy byte after the address, then the words.

   Address: [15:14] engine, [13:12] region, [11:0] offset.
     region 0  program memory, offset = word address. Write and read only while the engine is
               stopped.
     region 1  configuration, offset = 2 * word + half. Writing the low half holds it; writing
               the high half stores the 32-bit word (0..15 fabric elements, 16 CRC polynomial,
               17 CRC init). Write only.
     region 2  0x00 status (read): [7:0] pc, [8] halted, [9] running, [11:10] inbox count,
                    [13:12] outbox count, [14] bit engine on
               0x10..0x17 r0..r7 (read)
               0x80..0xff mailbox. A write goes into the inbox (dropped if it's full). A read
                    returns the outbox head, and takes it out once the host clocks the word's
                    first bit. If the outbox is empty nothing is taken and the value means
                    nothing, so read the status first.
     region 3  chip-wide, the engine field is ignored:
               0x00..0x0e owner of pin 0..14: [1:0] engine, [2] enable
               0x10 run: [3:0] one bit per engine. One write starts or stops engines together.
                    A stopped engine sits in reset; its program and configuration are kept.
               0x11 event flags [7:0]
               0x12, 0x13 cycle counter, low and high half (read)
               0x20 chip id (read)
   Reads of anything else return 0. *)

open! Core
open! Hardcaml
open Signal

module I = Spike_top.I
module O = Spike_top.O

type mode =
  | Asic
  | Sim

let n_engines = 4
let n_pins = 15
let chip_id = 0x5045
let bit x k = x.:[k, k]

module Engine_in_scope = Hierarchy.In_scope (Engine.I) (Engine.O)

let create mode scope (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clk ~reset:i.rst_n ~reset_level:Low () in
  let pin k = i.ui_in.:[k, k] in
  let sync x = reg spec (reg spec x) in
  (* ---------- host SPI ---------- *)
  let sck = sync (pin 0) in
  let selected = sync ~:(pin 1) in
  let mosi = sync (pin 2) in
  let rise = sck &: ~:(reg spec sck) &: selected in
  let open Always in
  let var w = Variable.reg spec ~width:w in
  let count = var 6
  and shift_in = var 16
  and cmd = var 8
  and addr = var 16
  and shift_out = var 16
  and lo_half = var 16
  and run = var n_engines
  and flags = var 8
  and time = var 32
  and wr = var 1
  and wr_addr = var 16
  and wr_data = var 16
  and pop_pending = var 1
  and pop_engine = var 2 in
  let owners = Array.init n_pins ~f:(fun _ -> var 3) in
  let shifted = shift_in.value.:[14, 0] @: mosi in
  let reading = cmd.value ==:. 0x03 in
  let writing = cmd.value ==:. 0x02 in
  let word_written = rise &: writing &: (count.value ==:. 39) in
  let word_loaded = (rise &: reading &: (count.value ==:. 31 |: (count.value ==:. 47))) -- "spi_word_loaded" in
  (* writes act one cycle after the last bit, from registers that then hold still *)
  let field a hi lo = a.:[hi, lo] in
  let w_engine = field wr_addr.value 15 14
  and w_region = field wr_addr.value 13 12
  and w_off = field wr_addr.value 11 0 in
  let r_engine = field addr.value 15 14
  and r_region = field addr.value 13 12
  and r_off = field addr.value 11 0 in
  let w_global k = wr.value &: (w_region ==:. 3) &: (w_off ==:. k) in
  (* ---------- engines ---------- *)
  let engine_mode =
    match mode with
    | Asic -> Engine.Mode.Asic
    | Sim -> Engine.Mode.sim [||]
  in
  let inbox_count = Array.init n_engines ~f:(fun _ -> wire 2) in
  let mailbox_has = Array.init n_engines ~f:(fun _ -> wire 1) in
  let outbox_count = Array.init n_engines ~f:(fun _ -> wire 2) in
  let owner_is q e = bit owners.(q).value 2 &: (owners.(q).value.:[1, 0] ==:. e) in
  let engines =
    Array.init n_engines ~f:(fun e ->
      let w_this = wr.value &: (w_engine ==:. e) in
      let mailbox_room = reg spec (inbox_count.(e) <:. 2) in
      let r_this_region k = (r_engine ==:. e) &: (r_region ==:. k) in
      Engine_in_scope.hierarchical
        ~name:"engine"
        ~instance:(sprintf "engine%d" e)
        ~scope
        (fun _scope i -> Engine.create engine_mode i)
        { Engine.I.clock = i.clk
        ; rst_n = i.rst_n
        ; uio_in = i.uio_in
        ; ui_in = i.ui_in
        ; owned = concat_lsb (List.init n_pins ~f:(fun q -> owner_is q e))
        ; host_wr = w_this &: (w_region ==:. 2) &: bit w_off 7 &: mailbox_room
        ; host_data = wr_data.value
        ; host_rd = (rise &: pop_pending.value &: (pop_engine.value ==:. e)) -- sprintf "host_rd%d" e
        ; prog_we = w_this &: (w_region ==:. 0)
        ; prog_re = selected &: reading &: r_this_region 0
        ; prog_addr = mux2 wr.value w_off.:[7, 0] r_off.:[7, 0]
        ; prog_data = wr_data.value
        ; run = bit run.value e
        ; cfg_we = w_this &: (w_region ==:. 1) &: bit w_off 0
        ; cfg_addr = w_off.:[5, 1]
        ; cfg_data = wr_data.value @: lo_half.value
        ; time = time.value
        ; ev_flags = flags.value
        })
  in
  Array.iteri engines ~f:(fun e (o : _ Engine.O.t) ->
    assign inbox_count.(e) o.inbox_count;
    assign outbox_count.(e) o.outbox_count;
    assign mailbox_has.(e) (reg spec (o.outbox_count <>:. 0)));
  (* ---------- reads ---------- *)
  let engine_word (o : _ Engine.O.t) e =
    let status =
      concat_lsb
        [ o.pc; o.halted; bit run.value e; o.inbox_count; o.outbox_count; o.be_enabled; gnd ]
    in
    let regs = mux r_off.:[2, 0] o.regs in
    mux
      r_region
      [ o.prog_q
      ; zero 16
      ; mux2
          (bit r_off 7)
          o.outbox_head
          (mux2
             (r_off ==:. 0)
             status
             (mux2 (r_off.:[11, 3] ==:. 2) regs (zero 16)))
      ; zero 16
      ]
  in
  let global_word =
    let table =
      List.init n_pins ~f:(fun q -> q, uresize owners.(q).value ~width:16)
      @ [ 0x10, uresize run.value ~width:16
        ; 0x11, uresize flags.value ~width:16
        ; 0x12, time.value.:[15, 0]
        ; 0x13, time.value.:[31, 16]
        ; 0x20, of_int_trunc ~width:16 chip_id
        ]
    in
    List.fold table ~init:(zero 16) ~f:(fun acc (k, v) -> mux2 (r_off ==:. k) v acc)
  in
  let read_word =
    reg
      spec
      (mux2
         (r_region ==:. 3)
         global_word
         (mux r_engine (Array.to_list (Array.mapi engines ~f:(fun e o -> engine_word o e)))))
  in
  (* ---------- event flags ---------- *)
  let any f = List.reduce_exn (Array.to_list (Array.map engines ~f)) ~f:( |: ) in
  let flag_set = any (fun o -> o.flag_set)
  and flag_clr = any (fun o -> o.flag_clr) in
  let flags_base = mux2 (w_global 0x11) wr_data.value.:[7, 0] flags.value in
  compile
    [ time <-- time.value +:. 1
    ; flags <-- ((flags_base &: ~:flag_clr) |: flag_set) (* a set wins over a clear *)
    ; wr <-- word_written
    ; when_ word_written [ wr_addr <-- addr.value; wr_data <-- shifted ]
    ; when_ (wr.value &: (w_region ==:. 1) &: ~:(bit w_off 0)) [ lo_half <-- wr_data.value ]
    ; when_ (w_global 0x10) [ run <-- wr_data.value.:[n_engines - 1, 0] ]
    ; proc
        (List.init n_pins ~f:(fun q ->
           when_ (w_global q) [ owners.(q) <-- wr_data.value.:[2, 0] ]))
    ; if_
        ~:selected
        [ count <-- zero 6; cmd <-- zero 8; pop_pending <-- gnd ]
        [ when_
            rise
            [ shift_in <-- shifted
            ; count <-- count.value +:. 1
            ; when_ (count.value ==:. 7) [ cmd <-- shifted.:[7, 0] ]
            ; when_ (count.value ==:. 23) [ addr <-- shifted ]
            ; when_ (reading &: (count.value >=:. 32)) [ shift_out <-- shift_out.value.:[14, 0] @: gnd ]
            ; pop_pending <-- gnd
            ; when_ word_written [ count <-- of_int_trunc ~width:6 24; addr <-- addr.value +:. 1 ]
            ; when_
                word_loaded
                [ shift_out <-- read_word
                ; count <-- of_int_trunc ~width:6 32
                ; addr <-- addr.value +:. 1
                ; pop_pending <-- ((r_region ==:. 2) &: bit r_off 7 &: mux r_engine (Array.to_list mailbox_has))
                ; pop_engine <-- r_engine
                ]
            ]
        ]
    ];
  (* ---------- pins ---------- *)
  let owned_pin (sel : _ Engine.O.t -> Signal.t) q =
    let o = mux owners.(q).value.:[1, 0] (Array.to_list (Array.map engines ~f:(fun o -> bit (sel o) q))) in
    o &: bit owners.(q).value 2
  in
  let out = concat_lsb (List.init n_pins ~f:(owned_pin (fun o -> o.out))) in
  let oe = concat_lsb (List.init n_pins ~f:(owned_pin (fun o -> o.oe))) in
  (* MISO is 0 outside the data words *)
  let miso = selected &: reading &: (count.value >=:. 32) &: msb shift_out.value in
  { O.uo_out = miso @: out.:[14, 8]; uio_out = out.:[7, 0]; uio_oe = oe.:[7, 0] }
;;

let circuit mode scope =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"tt_um_shaikhmubin02_pemu" (create mode scope)
;;
