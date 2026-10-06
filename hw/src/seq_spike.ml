(* Minimal sequencer to measure the real critical path: SRAM output -> decode -> register read
   -> ALU / compare -> next PC -> SRAM address, all in one cycle. Not the final ISA.

   Instructions (16 bits, [15:12] opcode):
     0 NOP
     1 LDI  rd, imm8    rd = [10:8], imm = [7:0]
     2 ADD  rd, rs      rd <- rd + rs, rs = [6:4]
     3 OUT  rs          uo[6:0] <- rs[6:0]
     4 JMP  t8
     5 DJNZ rd, t8      rd <- rd - 1, jump if the result isn't 0
     6 WAITP p, v       stay here until ui[p] = v, p = [10:8], v = [0]
     7 IN   rd          rd <- ui
     8 JNZ  rs, t8      jump if rs isn't 0, rs = [10:8]
   Every instruction takes exactly one cycle; WAITP repeats until its pin matches.

   Loading: shift {addr[7:0], data[15:0]} into ui[0] MSB first while ui[1] is high, pulse ui[2]
   to write the word. ui[3] high = run (from address 0), low = halt.
   uio[7:0] shows the PC. *)

open! Core
open! Hardcaml
open Signal

module I = Spike_top.I
module O = Spike_top.O

let create (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clk ~reset:i.rst_n ~reset_level:Low () in
  let pin k = i.ui_in.:[k, k] in
  let run = pin 3 in
  (* loader *)
  let sreg = reg_fb spec ~enable:(pin 1) ~width:24 ~f:(fun s -> s.:[22, 0] @: pin 0) in
  let load_we = pin 2 &: ~:run in
  (* PC and fetch *)
  let pc = wire 8 in
  let next_pc = wire 8 in
  let sram_addr = mux2 run next_pc (mux2 load_we sreg.:[23, 16] (zero 8)) in
  let instr = Sram.create ~clock:i.clk ~addr:sram_addr ~din:sreg.:[15, 0] ~wen:load_we in
  assign pc (reg spec (mux2 run next_pc (zero 8)));
  (* decode *)
  let op = instr.:[15, 12] in
  let is k = op ==:. k in
  let rd_idx = instr.:[10, 8] in
  let rs_idx = instr.:[6, 4] in
  let imm8 = instr.:[7, 0] in
  let target = instr.:[7, 0] in
  (* register file: 8 x 16 *)
  let regs = Array.init 8 ~f:(fun _ -> wire 16) in
  let read idx = mux idx (Array.to_list regs) in
  let rd_val = read rd_idx in
  let rs_val = read rs_idx in
  let dec = rd_val -:. 1 in
  let pin_sel = mux rd_idx (bits_lsb i.ui_in) in
  let wb_val =
    mux
      op
      [ rd_val
      ; uresize imm8 ~width:16
      ; rd_val +: rs_val
      ; rd_val
      ; rd_val
      ; dec
      ; rd_val
      ; uresize i.ui_in ~width:16
      ]
  in
  let wb_en = run &: (is 1 |: is 2 |: is 5 |: is 7) in
  Array.iteri regs ~f:(fun k r ->
    assign r (reg spec ~enable:(wb_en &: (rd_idx ==:. k)) wb_val));
  (* next PC *)
  let pc1 = pc +:. 1 in
  let taken =
    is 4 |: (is 5 &: (dec <>:. 0)) |: (is 8 &: (rd_val <>:. 0))
  in
  let stall = is 6 &: (pin_sel <>: instr.:[0, 0]) in
  assign next_pc (mux2 taken target (mux2 stall pc pc1));
  (* output register *)
  let out = reg spec ~enable:(run &: is 3) rs_val.:[6, 0] in
  { O.uo_out = gnd @: out; uio_out = pc; uio_oe = ones 8 }
;;

let circuit () =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"tt_um_shaikhmubin02_spike" create
;;
