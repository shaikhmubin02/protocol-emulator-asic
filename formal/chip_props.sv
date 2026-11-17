// Properties of the chip's own logic around the engines, proven by induction with Yosys
// (scripts/prove.sh). The four engines are replaced by free outputs: every output of every
// engine is arbitrary on every cycle. So these hold whatever the engines do, and they combine
// with the engine-level proofs (timing_props.sv) into chip-level statements:
//   - a PIN write issued at cycle t is on the pad at t+1 (timing_props 11 + pads below);
//   - the cycle a breakpoint fires in one engine, every engine joined to it stops too
//     (timing_props 14-16 + others_hit below);
//   - a SIG at cycle t is seen by every engine at t+1, so another engine's WAIT FLAG moves on
//     at exactly t+2 (flags below + timing_props 13).
// The prove script ties the wires below to the engine ports after flattening (connect -set).

module chip_props (
    input clk,
    input rst_n,
    input ena,
    input [7:0] ui_in,
    input [7:0] uio_in
);
    wire [7:0] uo_out, uio_out, uio_oe;

    tt_um_shaikhmubin02_pemu chip (
        .clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in), .uio_in(uio_in),
        .uo_out(uo_out), .uio_out(uio_out), .uio_oe(uio_oe)
    );

    // engine ports (driven by the prove script)
    wire [14:0] owned0, owned1, owned2, owned3;
    wire [14:0] out0, out1, out2, out3;
    wire [14:0] oe0, oe1, oe2, oe3;
    wire trig0, trig1, trig2, trig3;
    wire others0, others1, others2, others3;
    wire [31:0] time0, time1, time2, time3;
    wire [7:0] evf0, evf1, evf2, evf3;
    wire [7:0] set0, set1, set2, set3;
    wire [7:0] clr0, clr1, clr2, clr3;

    reg started = 0;
    reg l_rst_n;
    reg [31:0] l_time;
    reg [7:0] l_set, l_clr;
    always @(posedge clk) begin
        started <= 1;
        l_rst_n <= rst_n;
        l_time <= time0;
        l_set <= set0 | set1 | set2 | set3;
        l_clr <= clr0 | clr1 | clr2 | clr3;
    end
    wire steady = started && l_rst_n && rst_n;

    // pins 0..7 are the uio pads, 8..14 are uo_out[6:0] (uo_out[7] is the host port's MISO)
    wire [14:0] pad_out = {uo_out[6:0], uio_out};

    genvar q;
    generate
        for (q = 0; q < 15; q = q + 1) begin : pin
            wire [3:0] own = {owned3[q], owned2[q], owned1[q], owned0[q]};
            always @* begin
                // 1. a pin has at most one owner
                assert ((own & (own - 4'd1)) == 0);
                // 2. the pad is the owner's output register in the same cycle: no extra stage
                if (own[0]) assert (pad_out[q] == out0[q]);
                if (own[1]) assert (pad_out[q] == out1[q]);
                if (own[2]) assert (pad_out[q] == out2[q]);
                if (own[3]) assert (pad_out[q] == out3[q]);
                // 3. a pin nobody owns is driven low and, on a uio pad, not driven at all
                if (own == 0) assert (pad_out[q] == 0);
                if (q < 8) begin
                    if (own[0]) assert (uio_oe[q] == oe0[q]);
                    if (own[1]) assert (uio_oe[q] == oe1[q]);
                    if (own[2]) assert (uio_oe[q] == oe2[q]);
                    if (own[3]) assert (uio_oe[q] == oe3[q]);
                    if (own == 0) assert (uio_oe[q] == 0);
                end
            end
        end
    endgenerate

    always @* begin
        // 4. a breakpoint firing in one engine reaches every other engine in the same cycle
        assert (others0 == (trig1 | trig2 | trig3));
        assert (others1 == (trig0 | trig2 | trig3));
        assert (others2 == (trig0 | trig1 | trig3));
        assert (others3 == (trig0 | trig1 | trig2));
        // 5. every engine sees the same cycle counter and the same event flags
        assert (time0 == time1 && time1 == time2 && time2 == time3);
        assert (evf0 == evf1 && evf1 == evf2 && evf2 == evf3);
        if (steady) begin
            // 6. the counter goes up by exactly one every cycle
            assert (time0 == l_time + 32'd1);
            // 7. a SIG in any engine at t is seen by every engine at t+1: a set wins over a
            //    CLRF in another engine and over a host write in the same cycle
            assert ((evf0 & l_set) == l_set);
        end
    end
endmodule
