/*
 * Copyright (c) 2026 Mubin
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Test harness for one block: LUT fabric + CRC unit, driven straight from the pins.
//
// Config: shift a 38-bit word {addr[5:0], data[31:0]} in MSB first on ui[0] while ui[1] is high,
// then pulse ui[2] for one cycle to write it. addr 0..23 = fabric element, 62 = CRC polynomial,
// 63 = CRC init value.
// Run: ui[3] steps the fabric and CRC, ui[4] loads init values, ui[7:5] = ext inputs
// (the CRC takes its data bit from ext[0]).
// uio[2:0] selects what uo shows: 0..2 fabric outputs (bytes), 3..6 reversed CRC bytes.
module tt_um_shaikhmubin02_spike (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
  localparam integer N_LE = 24;

  wire cfg_dat = ui_in[0];
  wire cfg_shift = ui_in[1];
  wire cfg_we = ui_in[2];
  wire step = ui_in[3];
  wire init = ui_in[4];
  wire [2:0] ext = ui_in[7:5];

  reg [37:0] sreg;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) sreg <= 38'd0;
    else if (cfg_shift) sreg <= {sreg[36:0], cfg_dat};

  wire [5:0] addr = sreg[37:32];
  wire [31:0] data = sreg[31:0];

  wire [N_LE-1:0] le_we;
  genvar i;
  generate
    for (i = 0; i < N_LE; i = i + 1) begin : g_we
      assign le_we[i] = cfg_we & (addr == i);
    end
  endgenerate

  wire [N_LE-1:0] fab_out;
  fabric #(.N_LE(N_LE)) u_fabric (
      .clk     (clk),
      .rst_n   (rst_n),
      .cfg_we  (le_we),
      .cfg_word(data[29:0]),
      .fab_en  (step),
      .fab_init(init),
      .ext     (ext),
      .out     (fab_out)
  );

  wire [31:0] crc_out, crc_rev;
  crc_unit u_crc (
      .clk     (clk),
      .rst_n   (rst_n),
      .poly_we (cfg_we & (addr == 6'd62)),
      .init_we (cfg_we & (addr == 6'd63)),
      .cfg_word(data),
      .crc_init(init),
      .crc_en  (step),
      .din     (ext[0]),
      .crc_out (crc_out),
      .crc_rev (crc_rev)
  );

  reg [7:0] o;
  always @* begin
    case (uio_in[2:0])
      3'd0: o = fab_out[7:0];
      3'd1: o = fab_out[15:8];
      3'd2: o = fab_out[23:16];
      3'd3: o = crc_rev[7:0];
      3'd4: o = crc_rev[15:8];
      3'd5: o = crc_rev[23:16];
      3'd6: o = crc_rev[31:24];
      default: o = crc_out[31:24];
    endcase
  end

  assign uo_out = o;
  assign uio_out = 8'd0;
  assign uio_oe = 8'd0;

  wire _unused = &{ena, uio_in[7:3], crc_out[23:0], 1'b0};
endmodule
