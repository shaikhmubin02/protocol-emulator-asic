`default_nettype none

// Behavioural models of the PDK cells instantiated directly in src/.
// Only used for RTL simulation; gate-level simulation uses the real PDK models.
module sg13cmos5l_dlhq_1 (
    input  wire D,
    input  wire GATE,
    output reg  Q
);
  always @* if (GATE) Q = D;
endmodule
