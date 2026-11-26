// Behavioural versions of the IHP sg13cmos5l cells whose PDK models are written with UDP
// tables (which Yosys cannot read). Each follows the cell's UDP table in sg13cmos5l_udp.v:
//   dfrbpq: D flip-flop on the rising clock edge, cleared while RESET_B is low (ihp_dff_r)
//   dlhq:   latch, transparent while GATE is high (ihp_latch)
//   mux2:   X = S ? A1 : A0 (ihp_mux2);  mux4: X = A[{S1,S0}] (ihp_mux4)
// All other cells come from the PDK's own Verilog, which is plain gate primitives.

module sg13cmos5l_dfrbpq_1 (Q, CLK, D, RESET_B);
  output reg Q;
  input CLK, D, RESET_B;
  always @(posedge CLK or negedge RESET_B)
    if (!RESET_B) Q <= 1'b0; else Q <= D;
endmodule

module sg13cmos5l_dfrbpq_2 (Q, CLK, D, RESET_B);
  output reg Q;
  input CLK, D, RESET_B;
  always @(posedge CLK or negedge RESET_B)
    if (!RESET_B) Q <= 1'b0; else Q <= D;
endmodule

module sg13cmos5l_mux2_1 (X, A0, A1, S);
  output X;
  input A0, A1, S;
  assign X = S ? A1 : A0;
endmodule

module sg13cmos5l_mux2_2 (X, A0, A1, S);
  output X;
  input A0, A1, S;
  assign X = S ? A1 : A0;
endmodule

module sg13cmos5l_mux4_1 (X, A0, A1, A2, A3, S0, S1);
  output X;
  input A0, A1, A2, A3, S0, S1;
  assign X = S1 ? (S0 ? A3 : A2) : (S0 ? A1 : A0);
endmodule
