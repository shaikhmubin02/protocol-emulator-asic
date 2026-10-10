// Stand-in for the configuration latches (fabric and CRC settings) in the proofs: the output is
// arbitrary every cycle. That covers every configuration, including ones that change while the
// engine runs, so it only makes a proven property stronger.
module sg13cmos5l_dlhq_1 (
    input D,
    input GATE,
    output Q
);
    assign Q = $anyseq;
endmodule
