// SPDX-FileCopyrightText: © 2026 Mubin
// SPDX-License-Identifier: Apache-2.0
//
// The RTL (src/pemu.v) and the signed-off gate netlist (its top renamed tt_um_gl) side by side,
// fed the same inputs every cycle; lockstep.cpp compares their outputs every cycle.
module lockstep (
    input clk,
    input rst_n,
    input ena,
    input [7:0] ui_in,
    input [7:0] uio_in,
    output [7:0] uo_rtl,
    output [7:0] uio_out_rtl,
    output [7:0] uio_oe_rtl,
    output [7:0] uo_gl,
    output [7:0] uio_out_gl,
    output [7:0] uio_oe_gl
);
  tt_um_shaikhmubin02_pemu rtl (
      .clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in), .uio_in(uio_in),
      .uo_out(uo_rtl), .uio_out(uio_out_rtl), .uio_oe(uio_oe_rtl));
  tt_um_gl gl (
      .clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in), .uio_in(uio_in),
      .uo_out(uo_gl), .uio_out(uio_out_gl), .uio_oe(uio_oe_gl));
endmodule
