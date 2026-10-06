/*
 * Copyright (c) 2026 Mubin
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Bit-serial CRC/LFSR with a programmable polynomial, up to 32 bits.
// An n-bit CRC sits in the top n bits (crc[31:32-n]) and the polynomial and init value are
// left-aligned the same way, so no width select is needed. Bits go in MSB-first. For
// LSB-first protocols (USB, Ethernet) feed bits in wire order and read the reversed output.
module crc_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        poly_we,
    input  wire        init_we,
    input  wire [31:0] cfg_word,
    input  wire        crc_init,
    input  wire        crc_en,
    input  wire        din,
    output wire [31:0] crc_out,
    output wire [31:0] crc_rev
);
  wire [31:0] poly, init;
  cfg_latch #(.W(32)) u_poly (.clk(clk), .rst_n(rst_n), .we(poly_we), .d(cfg_word), .q(poly));
  cfg_latch #(.W(32)) u_init (.clk(clk), .rst_n(rst_n), .we(init_we), .d(cfg_word), .q(init));

  reg [31:0] crc;
  wire fb = crc[31] ^ din;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) crc <= 32'd0;
    else if (crc_init) crc <= init;
    else if (crc_en) crc <= {crc[30:0], 1'b0} ^ (poly & {32{fb}});

  assign crc_out = crc;
  genvar k;
  generate
    for (k = 0; k < 32; k = k + 1) begin : g_rev
      assign crc_rev[k] = crc[31-k];
    end
  endgenerate
endmodule
