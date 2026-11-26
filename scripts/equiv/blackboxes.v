// Cells kept as black boxes on both sides of the equivalence check: the SRAM macro (no logic
// model) and the configuration latch (its inputs are compared, its output is a free input).
(* blackbox *)
module RM_IHPSG13_1P_256x16_c2_bm_bist (
    input A_CLK, input A_MEN, input A_WEN, input A_REN, input [7:0] A_ADDR, input [15:0] A_DIN,
    input A_DLY, output [15:0] A_DOUT, input [15:0] A_BM, input A_BIST_CLK, input A_BIST_EN,
    input A_BIST_MEN, input A_BIST_WEN, input A_BIST_REN, input [7:0] A_BIST_ADDR,
    input [15:0] A_BIST_DIN, input [15:0] A_BIST_BM);
endmodule

(* blackbox *)
module sg13cmos5l_dlhq_1 (output Q, input D, input GATE);
endmodule
