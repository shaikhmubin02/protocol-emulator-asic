/*
 * Copyright (c) 2026 Mubin
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// A word of configuration storage made of latch cells.
// The write enable is registered so the latch gate comes straight from a flop and can't glitch.
// The data input must stay stable from the cycle `we` is high until one cycle after.
module cfg_latch #(
    parameter integer W = 32
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         we,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
  reg gate;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) gate <= 1'b0;
    else gate <= we;

  genvar k;
  generate
    for (k = 0; k < W; k = k + 1) begin : g_bit
      sg13cmos5l_dlhq_1 u_lat (
          .D(d[k]),
          .GATE(gate),
          .Q(q[k])
      );
    end
  endgenerate
endmodule
