/*
 * Copyright (c) 2026 Mubin
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Small reconfigurable LUT fabric for bit-level protocol work.
//
// Each element is a LUT4 with a flop (can be bypassed) and an init value.
// Each LUT input picks one of 8 sources:
//   0..2  ext[0..2]
//   3     LE0's output (combinational broadcast)
//   4     own flop
//   5     flop of LE i-1
//   6     flop of LE i-2
//   7     flop of LE i+1
// Only LE0 drives other elements combinationally, so the longest path is about two LUTs
// whatever the size.
//
// Config word per element: [15:0] lut, [27:16] input selects (4 x 3 bits),
// [28] use the flop output, [29] init value.
module fabric #(
    parameter integer N_LE = 24
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire [N_LE-1:0] cfg_we,
    input  wire [29:0]     cfg_word,
    input  wire            fab_en,
    input  wire            fab_init,
    input  wire [2:0]      ext,
    output wire [N_LE-1:0] out
);
  wire [N_LE-1:0] out_c  /*verilator split_var*/;
  reg  [N_LE-1:0] q;

  genvar i;
  generate
    for (i = 0; i < N_LE; i = i + 1) begin : g_le
      wire [29:0] cfg;
      cfg_latch #(.W(30)) u_cfg (
          .clk  (clk),
          .rst_n(rst_n),
          .we   (cfg_we[i]),
          .d    (cfg_word),
          .q    (cfg)
      );

      wire [15:0] lut    = cfg[15:0];
      wire [11:0] sel    = cfg[27:16];
      wire        use_ff = cfg[28];
      wire        init   = cfg[29];

      wire [7:0] src;
      assign src[0] = ext[0];
      assign src[1] = ext[1];
      assign src[2] = ext[2];
      assign src[3] = (i == 0) ? 1'b0 : out_c[0];
      assign src[4] = q[i];
      assign src[5] = (i >= 1) ? q[(i >= 1) ? i - 1 : 0] : 1'b0;
      assign src[6] = (i >= 2) ? q[(i >= 2) ? i - 2 : 0] : 1'b0;
      assign src[7] = (i + 1 < N_LE) ? q[(i + 1 < N_LE) ? i + 1 : 0] : 1'b0;

      wire [3:0] lin = {src[sel[11:9]], src[sel[8:6]], src[sel[5:3]], src[sel[2:0]]};
      wire       f = lut[lin];

      always @(posedge clk or negedge rst_n)
        if (!rst_n) q[i] <= 1'b0;
        else if (fab_init) q[i] <= init;
        else if (fab_en) q[i] <= f;

      assign out_c[i] = use_ff ? q[i] : f;
    end
  endgenerate

  assign out = out_c;
endmodule
