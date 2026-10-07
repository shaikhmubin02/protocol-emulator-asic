(* One protocol engine (ISA v1.2): sequencer + bit engine (baud generators, TX/RX shifters, LUT
   fabric, CRC). Checked cycle by cycle against Model.

   The SRAM word is decoded in the same cycle it arrives, and the next PC goes straight back to
   the SRAM address, so every instruction (jumps included) takes one cycle.

   Configuration the host writes (fabric words, CRC polynomial and init) goes through cfg_we /
   cfg_addr (0..7 fabric element, 16 polynomial, 17 init) / cfg_data. In simulation it can also
   start preloaded. *)

open! Core
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a
    ; uio_in : 'a [@bits 8]
    ; ui_in : 'a [@bits 8]
    ; owned : 'a [@bits 15]
    ; host_wr : 'a (* host puts host_data in the inbox (only when it isn't full) *)
    ; host_data : 'a [@bits 16]
    ; host_rd : 'a (* host takes the outbox head (only when it isn't empty) *)
    ; prog_we : 'a
    ; prog_re : 'a (* host reads program memory at prog_addr (only while stopped) *)
    ; prog_addr : 'a [@bits 8]
    ; prog_data : 'a [@bits 16]
    ; run : 'a
    ; cfg_we : 'a
    ; cfg_addr : 'a [@bits 5]
    ; cfg_data : 'a [@bits 32]
    ; time : 'a [@bits 32] (* the chip's cycle counter *)
    ; ev_flags : 'a [@bits 8] (* the chip's event flags *)
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { out : 'a [@bits 15]
    ; oe : 'a [@bits 15]
    ; pc : 'a [@bits 8]
    ; halted : 'a
    ; regs : 'a list [@length 8] [@bits 16]
    ; flags : 'a [@bits 3] (* T, C, Z *)
    ; sp : 'a [@bits 2]
    ; busy : 'a [@bits 8]
    ; flag_set : 'a [@bits 8]
    ; flag_clr : 'a [@bits 8]
    ; inbox_count : 'a [@bits 2]
    ; outbox_count : 'a [@bits 2]
    ; outbox_head : 'a [@bits 16]
    ; crc : 'a [@bits 32]
    ; bstat : 'a [@bits 4]
    ; be_enabled : 'a
    ; prog_q : 'a [@bits 16] (* program word at the prog_addr of the cycle before *)
    }
  [@@deriving hardcaml]
end

let bit x k = x.:[k, k]
let width_of_mask m = Int.popcount m

(* A CSR keeps only the bits its mask allows: [gather] picks them out of a 16-bit value, [scatter]
   puts them back at their positions (up to the highest one). *)
let mask_bits mask = List.filter (List.init 16 ~f:Fn.id) ~f:(fun k -> (mask lsr k) land 1 = 1)
let gather mask v = concat_lsb (List.map (mask_bits mask) ~f:(fun k -> v.:[k, k]))

let scatter mask stored =
  let bits = mask_bits mask in
  let top = List.last_exn bits in
  concat_lsb
    (List.init (top + 1) ~f:(fun k ->
       match List.findi bits ~f:(fun _ b -> b = k) with
       | Some (i, _) -> stored.:[i, i]
       | None -> gnd))
;;

(* rotate a 17-bit value left by m (0..16) *)
let rotl17 v m =
  List.foldi (bits_lsb m) ~init:v ~f:(fun k acc b -> mux2 b (rotl acc ~by:(1 lsl k)) acc)
;;

let mod17 n =
  (* n is 6 bits *)
  let n7 = uresize n ~width:7 in
  mux2
    (n7 >=:. 51)
    (n7 -:. 51)
    (mux2 (n7 >=:. 34) (n7 -:. 34) (mux2 (n7 >=:. 17) (n7 -:. 17) n7))
  |> fun r -> r.:[4, 0]
;;

module Mode = struct
  type t =
    | Asic
    | Sim of
        { program : int array
        ; fabric : int array
        ; crc_poly : int
        ; crc_init : int
        }

  let sim ?(fabric = [||]) ?(crc_poly = 0) ?(crc_init = 0) program =
    Sim { program; fabric; crc_poly; crc_init }
  ;;
end

module Fab = Fabric_logic.Make (Signal)

let n_le = 8

let create (mode : Mode.t) (i : _ I.t) : _ O.t =
  let cfg_spec = Reg_spec.create ~clock:i.clock ~reset:i.rst_n ~reset_level:Low () in
  (* while run is low the engine sits in reset; program memory and config are kept *)
  let spec = Reg_spec.override cfg_spec ~clear:~:(i.run) in
  let sram_mode, cfg_mode, init_of =
    match mode with
    | Asic -> Sram.Asic, Cfg_store.Asic, fun _ -> None
    | Sim { program; fabric; crc_poly; crc_init } ->
      let init addr =
        if addr < n_le
        then Some (if addr < Array.length fabric then fabric.(addr) else 0)
        else if addr = 16
        then Some crc_poly
        else Some crc_init
      in
      Sram.Sim program, Cfg_store.Sim, init
  in
  let open Always in
  let var w = Variable.reg spec ~width:w in
  let pc = var 8
  and halted = var 1
  and busy = var 8
  and busy_next = var 8
  and fails = var 16
  and z = var 1
  and c = var 1
  and t = var 1
  and sp = var 2
  and time_hi = var 16
  and cap = var 16
  and captured = var 1
  and sync1_uio = var 8
  and sync1_ui = var 8
  and sync2_uio = var 8
  and sync2_ui = var 8 in
  let regs = Array.init 8 ~f:(fun _ -> var 16) in
  let stack = Array.init 4 ~f:(fun _ -> var 8) in
  let out = Array.init 15 ~f:(fun _ -> var 1) in
  let oe = Array.init 15 ~f:(fun _ -> var 1) in
  let flag k = bit i.ev_flags k in
  let flag_list = List.init 8 ~f:flag in
  let time = i.time in
  let csrs = List.map Isa.Csr.writable ~f:(fun (addr, mask) -> addr, mask, var (width_of_mask mask)) in
  let csr_value addr =
    let _, mask, v = List.find_exn csrs ~f:(fun (a, _, _) -> a = addr) in
    scatter mask v.value
  in
  (* mailboxes: 2-deep FIFOs, head in e0 *)
  let fifo () = var 2, var 16, var 16 in
  let in_count, in_e0, in_e1 = fifo () in
  let out_count, out_e0, out_e1 = fifo () in
  (* bit engine state *)
  let be_en = var 1
  and acc_tx = var 24
  and acc_rx = var 24
  and hold_v = var 1
  and hold = var 16
  and sh_value = var 16
  and sh_left = var 5
  and sh_index = var 5
  and rx_active = var 1
  and rx_shift = var 16
  and rx_count = var 5
  and rx_word = var 16
  and rx_ready = var 1
  and overrun = var 1
  and crc = var 32
  and flag_latch = var 1 in
  let fab_q = Array.init n_le ~f:(fun _ -> var 1) in
  let cfg_word addr ~width =
    let init = Option.map (init_of addr) ~f:(Bits.of_int_trunc ~width) in
    Cfg_store.create
      cfg_mode
      ?init
      ~spec:cfg_spec
      ~we:(i.cfg_we &: (i.cfg_addr ==:. addr))
      ~d:i.cfg_data.:[width - 1, 0]
  in
  let fab_cfg = Array.init n_le ~f:(fun k -> cfg_word k ~width:Fabric_logic.cfg_bits) in
  let crc_poly = cfg_word 16 ~width:32 in
  let crc_init = cfg_word 17 ~width:32 in
  (* ---------- fetch / decode ---------- *)
  let run = i.run in
  let next_pc = wire 8 in
  (* while stopped the SRAM sits on address 0 so that instruction 0 is ready when run goes high *)
  let sram_addr = mux2 run next_pc (mux2 (i.prog_we |: i.prog_re) i.prog_addr (zero 8)) in
  let instr =
    Sram.create sram_mode ~clock:i.clock ~addr:sram_addr ~din:i.prog_data ~wen:(i.prog_we &: ~:run)
  in
  let f hi lo = instr.:[hi, lo] in
  let op = f 15 12 in
  let is k = op ==:. k in
  let sub = f 11 8 in
  let sys k = is 0 &: (sub ==:. k) in
  let reg_a = mux (f 11 9) (Array.to_list (Array.map regs ~f:(fun r -> r.value))) in
  let reg_b = mux (f 8 6) (Array.to_list (Array.map regs ~f:(fun r -> r.value))) in
  let reg_c = mux (f 2 0) (Array.to_list (Array.map regs ~f:(fun r -> r.value))) in
  let imm6 = f 5 0 in
  let imm8 = f 7 0 in
  let target = f 7 0 in
  let pc1 = pc.value +:. 1 in
  (* ---------- pins ---------- *)
  let out_vec = concat_lsb (Array.to_list (Array.map out ~f:(fun v -> v.value))) in
  let pin_vec =
    (* pins 0..7 read the uio pads, 8..14 read back the uo outputs, 16..23 the ui pads *)
    concat_lsb [ sync2_uio.value; out_vec.:[14, 8]; gnd; sync2_ui.value; zero 8 ]
    |> uresize ~width:64
  in
  let read_pin p = mux (uresize p ~width:6) (bits_lsb pin_vec) in
  let group g =
    let v = csr_value (Isa.Csr.group 0) in
    let v = mux g [ v; csr_value (Isa.Csr.group 1); csr_value (Isa.Csr.group 2); csr_value (Isa.Csr.group 3) ] in
    v.:[4, 0], uresize v.:[7, 5] ~width:4 +:. 1
  in
  (* ---------- ALU ---------- *)
  let a = reg_a
  and b = reg_b in
  let sum = uresize a ~width:17 +: uresize b ~width:17 in
  let diff = a -: b in
  let borrow = a <: b in
  let alu_fn = f 5 3 in
  let alu_res = mux alu_fn [ b; sum.:[15, 0]; diff; a &: b; a |: b; a ^: b; diff; a &: b ] in
  let alu_writes = alu_fn <:. 6 in
  let n16 = uresize imm6 ~width:16 in
  let sumi = uresize a ~width:17 +: uresize n16 ~width:17 in
  let diffi = a -: n16 in
  let borrowi = a <: n16 in
  let shl = log_shift ~f:sll (uresize a ~width:32) ~by:imm6 in
  let shr = log_shift ~f:srl (a @: zero 16) ~by:imm6 in
  let m = mod17 imm6 in
  let rl = rotl17 (c.value @: a) m in
  let rr = rotl17 (c.value @: a) (mux2 (m ==:. 0) (zero 5) (of_int_trunc ~width:5 17 -: m)) in
  let alui_fn = f 8 6 in
  let alui_res =
    mux
      alui_fn
      [ sumi.:[15, 0]; diffi; diffi; shl.:[15, 0]; shr.:[31, 16]; rl.:[15, 0]; rr.:[15, 0]; a ]
  in
  let alui_writes = ~:((alui_fn ==:. 2) |: (alui_fn ==:. 7)) in
  let tstb_zero = ~:(mux imm6.:[3, 0] (bits_lsb a)) in
  (* ---------- conditions ---------- *)
  let jpin = read_pin (csr_value Isa.Csr.jpin) in
  let jflag = mux (csr_value Isa.Csr.jflag) flag_list in
  let inbox_has = in_count.value <>:. 0 in
  let outbox_room = out_count.value <:. 2 in
  let cond =
    mux
      (f 11 8)
      [ vdd; z.value; ~:(z.value); c.value; ~:(c.value); t.value; ~:(t.value); jpin; ~:jpin
      ; rx_ready.value
      ; ~:(hold_v.value)
      ; inbox_has; jflag; ~:jflag
      ; flag_latch.value
      ; gnd
      ]
  in
  let dec = a -:. 1 in
  (* ---------- baud generators ---------- *)
  let baud = csr_value Isa.Csr.baud in
  let baud_eff = mux2 (baud ==:. 0) (one 16) baud in
  let period = baud_eff @: csr_value Isa.Csr.baudf in
  let fires acc = be_en.value &: (uresize acc ~width:25 +:. 256 >=: uresize period ~width:25) in
  let tx_tick = fires acc_tx.value
  and rx_tick = fires acc_rx.value in
  let advance acc tick = mux2 tick (acc +:. 256 -: period) (acc +:. 256) in
  (* ---------- waits ---------- *)
  let wait_kind = f 11 10 in
  let wait_ready =
    mux
      wait_kind
      [ read_pin (f 9 5) ==: f 4 4
      ; mux (f 2 0) flag_list ==: f 3 3
      ; ~:(msb (time.:[15, 0] -: reg_c))
      ; mux
          (f 3 0)
          [ ~:(hold_v.value); rx_ready.value; tx_tick; captured.value; inbox_has ]
      ]
  in
  let is_wait = sys 3 |: sys 4 |: sys 7 |: sys 8 |: is 10 in
  let ready =
    mux2
      (sys 3)
      outbox_room
      (mux2
         (sys 4)
         inbox_has
         (mux2 (sys 7) ~:(hold_v.value) (mux2 (sys 8) rx_ready.value wait_ready)))
  in
  let tmo = csr_value Isa.Csr.tmo in
  let timeout = (tmo <>:. 0) &: (uresize fails.value ~width:17 +:. 1 >=: uresize tmo ~width:17) in
  let complete = ready |: timeout in
  (* ---------- next PC ---------- *)
  let exec = run &: ~:(halted.value) &: (busy.value ==:. 0) in
  let delay = mux2 (is 11) imm8 (uresize (f 2 0) ~width:8) in
  let has_delay = is 7 |: is 8 |: is 11 in
  let ret_pc = mux (sp.value -:. 1) (Array.to_list (Array.map stack ~f:(fun v -> v.value))) in
  let exec_next =
    let open Signal in
    mux2
      (sys 1)
      pc.value
      (mux2
         (sys 2)
         ret_pc
         (mux2
            (is 4)
            (mux2 cond target pc1)
            (mux2
               (is 5)
               (mux2 (dec <>:. 0) target pc1)
               (mux2
                  (is 6)
                  target
                  (mux2
                     has_delay
                     (mux2 (delay ==:. 0) pc1 pc.value)
                     (mux2 is_wait (mux2 complete pc1 pc.value) pc1))))))
  in
  assign
    next_pc
    (mux2
       ~:run
       (zero 8)
       (mux2
          halted.value
          pc.value
          (mux2
             (busy.value <>:. 0)
             (mux2 (busy.value ==:. 1) busy_next.value pc.value)
             exec_next)));
  (* ---------- CSR read ---------- *)
  let caddr = f 5 0 in
  let bstat =
    concat_lsb
      [ ~:(hold_v.value)
      ; ~:(hold_v.value) &: (sh_left.value ==:. 0)
      ; rx_ready.value
      ; overrun.value
      ]
  in
  let crc_view = mux2 (csr_value Isa.Csr.crcctl).:[3, 3] (reverse crc.value) crc.value in
  let csr_read =
    let named =
      [ Isa.Csr.time_lo, time.:[15, 0]
      ; Isa.Csr.time_hi, time_hi.value
      ; Isa.Csr.cap, cap.value
      ; Isa.Csr.flags, uresize i.ev_flags ~width:16
      ; Isa.Csr.bstat, uresize bstat ~width:16
      ; Isa.Csr.crc_lo, crc_view.:[15, 0]
      ; Isa.Csr.crc_hi, crc_view.:[31, 16]
      ]
      @ List.map csrs ~f:(fun (a, mask, v) -> a, uresize (scatter mask v.value) ~width:16)
    in
    List.fold named ~init:(zero 16) ~f:(fun acc (a, v) -> mux2 (caddr ==:. a) v acc)
  in
  (* ---------- write-back ---------- *)
  let wb_idx = mux2 (is 0) (f 2 0) (f 11 9) in
  let inp_value =
    let base, count = group (f 8 7) in
    List.init 8 ~f:(fun k ->
      (of_int_trunc ~width:4 k <: count)
      &: read_pin (uresize base ~width:6 +:. k))
    |> concat_lsb
    |> uresize ~width:16
  in
  let wb_val =
    mux
      op
      [ mux2 (sys 8) rx_word.value in_e0.value (* RX / PULL *)
      ; mux2 (f 8 8) (imm8 @: a.:[7, 0]) (uresize imm8 ~width:16)
      ; alu_res
      ; alui_res
      ; a
      ; dec
      ; a
      ; a
      ; a
      ; inp_value
      ; a
      ; a
      ; csr_read
      ; a
      ; a
      ; a
      ]
  in
  let wb_en =
    exec
    &: (is 1
        |: (is 2 &: alu_writes)
        |: (is 3 &: alui_writes)
        |: is 5
        |: is 9
        |: is 12
        |: (sys 4 &: ready)
        |: (sys 8 &: ready))
  in
  (* flags *)
  let z_new =
    mux2
      (is 1)
      (wb_val ==:. 0)
      (mux2
         (is 2)
         (mux2 (alu_fn ==:. 6) (diff ==:. 0) (mux2 (alu_fn ==:. 7) ((a &: b) ==:. 0) (alu_res ==:. 0)))
         (mux2 (alui_fn ==:. 7) tstb_zero (mux2 (alui_fn ==:. 2) (diffi ==:. 0) (alui_res ==:. 0))))
  in
  let z_en = exec &: (is 1 |: is 2 |: is 3) in
  let c_new_alu = mux (uresize alu_fn ~width:3) [ c.value; sum.:[16, 16]; borrow; c.value; c.value; c.value; borrow; c.value ] in
  let c_new_alui =
    mux
      alui_fn
      [ sumi.:[16, 16]
      ; borrowi
      ; borrowi
      ; mux2 (imm6 ==:. 0) c.value shl.:[16, 16]
      ; mux2 (imm6 ==:. 0) c.value shr.:[15, 15]
      ; rl.:[16, 16]
      ; rr.:[16, 16]
      ; c.value
      ]
  in
  let pin_p = f 9 5 in
  let pin_mode = f 4 3 in
  let pin_op = f 11 10 in
  let sample = is 7 &: (pin_mode ==:. 3) in
  let c_new = mux2 (is 2) c_new_alu (mux2 (is 3) c_new_alui (read_pin pin_p)) in
  let c_en = exec &: (is 2 |: is 3 |: sample) in
  (* ---------- pin drive (PIN / OUTG) ---------- *)
  let out_now k = out.(k).value in
  let pin_value =
    mux
      pin_mode
      [ mux pin_op [ gnd; vdd; ~:(mux (uresize pin_p ~width:4) (List.init 16 ~f:(fun k -> if k < 15 then out_now k else gnd))); gnd ]
      ; c.value
      ; ~:(c.value)
      ; gnd
      ]
  in
  let pin_hiz = (pin_mode ==:. 0) &: (pin_op ==:. 3) in
  let outg_base, outg_count = group (f 8 7) in
  (* ---------- the state update ---------- *)
  let in_pop = exec &: sys 4 &: ready in
  let out_push = exec &: sys 3 &: ready in
  let wait_done = exec &: is_wait &: complete in
  let capcfg = csr_value Isa.Csr.capcfg in
  let cap_pin = capcfg.:[4, 0] in
  let cap_mode = capcfg.:[6, 5] in
  let sync_vec v_uio v_ui = concat_lsb [ v_uio; zero 8; v_ui; zero 8 ] in
  let old_cap = mux cap_pin (bits_lsb (sync_vec sync2_uio.value sync2_ui.value)) in
  let new_cap = mux cap_pin (bits_lsb (sync_vec sync1_uio.value sync1_ui.value)) in
  let cap_fire =
    mux cap_mode [ ~:old_cap &: new_cap; old_cap &: ~:new_cap; old_cap ^: new_cap; old_cap ^: new_cap ]
  in
  let csr_we = exec &: (is 13 |: is 14) in
  let csr_wval = mux2 (is 14) (uresize (f 11 6) ~width:16) a in
  let fifo_update (count : Variable.t) (e0 : Variable.t) (e1 : Variable.t) ~push ~data ~pop =
    let pos = count.value -: uresize pop ~width:2 in
    [ count <-- count.value +: uresize push ~width:2 -: uresize pop ~width:2
    ; when_ pop [ e0 <-- e1.value ]
    ; when_ (push &: (pos ==:. 0)) [ e0 <-- data ]
    ; when_ (push &: (pos ==:. 1)) [ e1 <-- data ]
    ]
  in
  let per_pin q =
    let owned = bit i.owned q in
    (* PIN *)
    let pin_hit = exec &: is 7 &: (pin_mode <>:. 3) &: (pin_p ==:. q) &: owned in
    (* OUTG *)
    let base6 = uresize outg_base ~width:6 in
    let in_range =
      (of_int_trunc ~width:6 q >=: base6) &: (of_int_trunc ~width:6 q <: base6 +: uresize outg_count ~width:6)
    in
    let idx = (of_int_trunc ~width:6 q -: base6).:[2, 0] in
    let outg_hit = exec &: is 8 &: in_range &: owned in
    let hiz_value_out, hiz_value_oe = if q < 8 then out_now q, gnd else gnd, vdd in
    [ when_ pin_hit
        [ if_
            pin_hiz
            [ out.(q) <-- hiz_value_out; oe.(q) <-- hiz_value_oe ]
            [ out.(q) <-- pin_value; oe.(q) <-- vdd ]
        ]
    ; when_ outg_hit [ out.(q) <-- mux idx (bits_lsb a.:[7, 0]); oe.(q) <-- vdd ]
    ]
  in
  (* ---------- bit engine tick (spec 7.5) ---------- *)
  let txcfg = csr_value Isa.Csr.txcfg
  and rxcfg = csr_value Isa.Csr.rxcfg
  and fabctl = csr_value Isa.Csr.fabctl
  and fabctl2 = csr_value Isa.Csr.fabctl2
  and crcctl = csr_value Isa.Csr.crcctl in
  let n_tx = uresize txcfg.:[3, 0] ~width:5 +:. 1
  and n_rx = uresize rxcfg.:[3, 0] ~width:5 +:. 1 in
  let tx_pin = txcfg.:[9, 5]
  and tx_fab = bit txcfg 10
  and rx_pin = rxcfg.:[9, 5]
  and rx_fab = bit rxcfg 10
  and rx_start = rxcfg.:[13, 12] in
  (* 1. TX load and next bit *)
  let load = tx_tick &: (sh_left.value ==:. 0) &: hold_v.value in
  let sh_value_l = mux2 load hold.value sh_value.value
  and sh_left_l = mux2 load n_tx sh_left.value
  and sh_index_l = mux2 load (zero 5) sh_index.value in
  let have_bit = tx_tick &: (sh_left_l <>:. 0) in
  let pos = mux2 (bit txcfg 4) (n_tx -:. 1 -: sh_index_l) sh_index_l in
  let tx_bit = mux pos.:[3, 0] (bits_lsb sh_value_l) in
  (* 2. RX sample *)
  let rx_sample = read_pin rx_pin in
  (* 3. fabric *)
  let fabric_used = tx_fab |: rx_fab in
  let ext = concat_lsb [ have_bit &: tx_bit; rx_sample; bit fabctl 0 ] in
  let fab_next, fab_out =
    Fab.step ~cfgs:fab_cfg ~q:(Array.map fab_q ~f:(fun v -> v.value)) ~ext
  in
  let role idx = fabric_used &: mux idx (Array.to_list fab_out) in
  (* 4. TX pin *)
  let line = mux2 tx_fab (role fabctl.:[3, 1]) tx_bit in
  let held = tx_fab &: bit fabctl 9 &: role fabctl.:[7, 5] in
  let consume = have_bit &: ~:held in
  let tx_level = mux2 have_bit line (bit txcfg 11) in
  (* 5. RX *)
  let rx_go = rx_tick &: rx_active.value in
  let rx_b = mux2 rx_fab (role fabctl.:[12, 10]) rx_sample in
  let dropped = rx_fab &: bit fabctl2 4 &: role fabctl2.:[2, 0] in
  let keep = rx_go &: ~:dropped in
  let shift_new =
    mux2
      (bit rxcfg 4)
      (rx_shift.value.:[14, 0] @: rx_b)
      (rx_shift.value |: (uresize rx_b ~width:16 |> fun v -> log_shift ~f:sll v ~by:rx_count.value.:[3, 0]))
  in
  let count_new = rx_count.value +:. 1 in
  let rx_done = keep &: (count_new >=: n_rx) in
  let rx_take = exec &: sys 8 &: rx_ready.value in
  (* 6. CRC *)
  let crc_src = crcctl.:[2, 1] in
  let crc_bit = mux crc_src [ tx_bit; rx_b; role fabctl2.:[11, 9]; role fabctl2.:[11, 9] ] in
  let crc_go =
    bit crcctl 0 &: mux crc_src [ consume; keep; tx_tick; tx_tick ]
  in
  let crc_step =
    let fb = msb crc.value ^: crc_bit in
    (crc.value.:[30, 0] @: gnd) ^: (crc_poly &: repeat fb ~count:32)
  in
  (* end of cycle: RX start / re-align, from start-of-cycle config *)
  let rx_active_post = mux2 (rx_done &: (rx_start <>:. 0)) gnd rx_active.value in
  let sync_now = sync_vec sync2_uio.value sync2_ui.value
  and sync_next = sync_vec sync1_uio.value sync1_ui.value in
  let rx_was = mux rx_pin (bits_lsb sync_now)
  and rx_will = mux rx_pin (bits_lsb sync_next) in
  let rx_edge =
    mux rx_start [ rx_was ^: rx_will; rx_was &: ~:rx_will; ~:rx_was &: rx_will; rx_was ^: rx_will ]
  in
  let start_fire = be_en.value &: ~:rx_active_post &: (rx_start <>:. 0) &: rx_edge in
  let realign = be_en.value &: rx_active_post &: bit rxcfg 11 &: (rx_was ^: rx_will) in
  let half = period -: (uresize (srl baud_eff ~by:1) ~width:16 @: zero 8) in
  let ben = exec &: sys 10 in
  let ben_on = f 0 0 in
  let tx_drive q =
    when_
      (tx_tick &: (tx_pin ==:. q) &: bit i.owned q)
      [ out.(q) <-- tx_level; oe.(q) <-- vdd ]
  in
  let bit_engine_updates =
    [ when_ be_en.value
        [ acc_tx <-- advance acc_tx.value tx_tick; acc_rx <-- advance acc_rx.value rx_tick ]
    ; (* TX *)
      when_ load [ hold_v <-- gnd ]
    ; when_ (exec &: sys 7 &: ~:(hold_v.value)) [ hold <-- reg_c; hold_v <-- vdd ]
    ; when_ tx_tick
        [ sh_value <-- sh_value_l
        ; sh_left <-- mux2 consume (sh_left_l -:. 1) sh_left_l
        ; sh_index <-- mux2 consume (sh_index_l +:. 1) sh_index_l
        ]
    ; (* RX *)
      when_ rx_take [ rx_ready <-- gnd ]
    ; when_
        keep
        [ if_
            rx_done
            [ rx_word <-- shift_new
            ; rx_ready <-- vdd
            ; rx_shift <-- zero 16
            ; rx_count <-- zero 5
            ; when_ (rx_ready.value &: ~:rx_take) [ overrun <-- vdd ]
            ; when_ (rx_start <>:. 0) [ rx_active <-- gnd ]
            ]
            [ rx_shift <-- shift_new; rx_count <-- count_new ]
        ]
    ; (* fabric *)
      when_ (tx_tick |: rx_tick) [ flag_latch <-- role fabctl2.:[7, 5] ]
    ]
    @ List.init n_le ~f:(fun k ->
      let on_rx = Fab.rx_clocked fab_cfg.(k) in
      when_ (fabric_used &: mux2 on_rx rx_tick tx_tick) [ fab_q.(k) <-- fab_next.(k) ])
    @ [ (* CRC *)
        when_ crc_go [ crc <-- crc_step ]
      ; when_ (exec &: sys 9) [ crc <-- crc_init ]
      ; (* RX start / re-align *)
        when_ start_fire
          [ rx_active <-- vdd; rx_shift <-- zero 16; rx_count <-- zero 5; acc_rx <-- half ]
      ; when_ realign [ acc_rx <-- half ]
      ; (* BEN goes last: it overrides everything above *)
        when_
          ben
          [ if_
              ben_on
              ([ be_en <-- vdd
               ; acc_tx <-- zero 24
               ; acc_rx <-- zero 24
               ; hold_v <-- gnd
               ; sh_left <-- zero 5
               ; sh_index <-- zero 5
               ; rx_shift <-- zero 16
               ; rx_count <-- zero 5
               ; rx_ready <-- gnd
               ; overrun <-- gnd
               ; rx_active <-- (rx_start ==:. 0)
               ]
               @ List.init n_le ~f:(fun k -> fab_q.(k) <-- Fab.init fab_cfg.(k)))
              [ be_en <-- gnd ]
          ]
      ]
    @ List.init 15 ~f:tx_drive
  in
  compile
    (List.concat
       [ [ pc <-- next_pc
         ; sync1_uio <-- i.uio_in
         ; sync1_ui <-- i.ui_in
         ; sync2_uio <-- sync1_uio.value
         ; sync2_ui <-- sync1_ui.value
         ; when_ (run &: ~:(halted.value) &: (busy.value <>:. 0)) [ busy <-- busy.value -:. 1 ]
         ; when_ (exec &: has_delay &: (delay <>:. 0)) [ busy <-- delay; busy_next <-- pc1 ]
         ; when_ (exec &: sys 1) [ halted <-- vdd ]
         ; when_ (exec &: is 6) [ sp <-- sp.value +:. 1 ]
         ; when_ (exec &: sys 2) [ sp <-- sp.value -:. 1 ]
         ; when_ z_en [ z <-- z_new ]
         ; when_ c_en [ c <-- c_new ]
         ; when_ wait_done [ t <-- ~:ready ]
         ; when_ (exec &: is_wait) [ if_ complete [ fails <-- zero 16 ] [ fails <-- fails.value +:. 1 ] ]
         ; when_ (exec &: is 12 &: (caddr ==:. Isa.Csr.time_lo)) [ time_hi <-- time.:[31, 16] ]
         ; when_ (exec &: is 12 &: (caddr ==:. Isa.Csr.cap)) [ captured <-- gnd ]
         ; when_
             (wait_done &: ready &: is 10 &: (wait_kind ==:. 3) &: (f 3 0 ==:. 3))
             [ captured <-- gnd ]
         ; when_ cap_fire [ cap <-- (time +:. 1).:[15, 0]; captured <-- vdd ]
         ]
       ; List.init 4 ~f:(fun k -> when_ (exec &: is 6 &: (sp.value ==:. k)) [ stack.(k) <-- pc1 ])
       ; List.init 8 ~f:(fun k -> when_ (wb_en &: (wb_idx ==:. k)) [ regs.(k) <-- wb_val ])
       ; List.concat (List.init 15 ~f:per_pin)
       ; bit_engine_updates
       ; List.map csrs ~f:(fun (addr, mask, v) ->
           when_
             (csr_we &: (caddr ==:. addr))
             [ v <-- gather mask csr_wval ])
       ; fifo_update in_count in_e0 in_e1 ~push:i.host_wr ~data:i.host_data ~pop:in_pop
       ; fifo_update
           out_count
           out_e0
           out_e1
           ~push:out_push
           ~data:reg_c
           ~pop:(i.host_rd &: (out_count.value <>:. 0))
       ]);
  { O.out = out_vec
  ; oe = concat_lsb (Array.to_list (Array.map oe ~f:(fun v -> v.value)))
  ; pc = pc.value
  ; halted = halted.value
  ; regs = Array.to_list (Array.map regs ~f:(fun r -> r.value))
  ; flags = concat_msb [ t.value; c.value; z.value ]
  ; sp = sp.value
  ; busy = busy.value
  ; flag_set = mux2 (exec &: sys 5) (binary_to_onehot (f 2 0)) (zero 8)
  ; flag_clr = mux2 (exec &: sys 6) (binary_to_onehot (f 2 0)) (zero 8)
  ; inbox_count = in_count.value
  ; outbox_count = out_count.value
  ; outbox_head = out_e0.value
  ; crc = crc.value
  ; bstat
  ; be_enabled = be_en.value
  ; prog_q = instr
  }
;;

let circuit mode =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"engine" (create mode)
;;
