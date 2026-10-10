// Properties of one engine (the generated `engine` or `engine_lite` module from src/pemu.v),
// proven by induction with Yosys (scripts/prove.sh). Every input is free on every cycle, and the
// program memory returns an arbitrary word every cycle (formal/sram_any.v), so these hold for any
// program, any pin activity and any host behaviour that keeps the interface contract below.

module engine_props (
    input clock,
    input rst_n,
    input [7:0] uio_in,
    input [7:0] ui_in,
    input [14:0] owned,
    input host_wr,
    input [15:0] host_data,
    input host_rd,
    input prog_we,
    input prog_re,
    input [7:0] prog_addr,
    input [15:0] prog_data,
    input run,
    input cfg_we,
    input [4:0] cfg_addr,
    input [31:0] cfg_data,
    input [31:0] time_,
    input [7:0] ev_flags
);
    wire [14:0] out, oe;
    wire [1:0] inbox_count, outbox_count;

    `ENGINE dut (
        .clock(clock), .rst_n(rst_n), .uio_in(uio_in), .ui_in(ui_in), .owned(owned),
        .host_wr(host_wr), .host_data(host_data), .host_rd(host_rd),
        .prog_we(prog_we), .prog_re(prog_re), .prog_addr(prog_addr), .prog_data(prog_data),
        .run(run), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .\time (time_), .ev_flags(ev_flags),
        .out(out), .oe(oe), .inbox_count(inbox_count), .outbox_count(outbox_count)
    );

    // The interface contract the chip keeps: the host only writes the inbox when it has room
    // and only takes from the outbox when there's something there.
    always @* begin
        if (host_wr) assume (inbox_count < 2);
        if (host_rd) assume (outbox_count != 0);
    end

    // last cycle's values
    reg started = 0;
    reg [14:0] last_out, last_oe, last_owned;
    reg last_run, last_rst_n;
    always @(posedge clock) begin
        started <= 1;
        last_out <= out;
        last_oe <= oe;
        last_owned <= owned;
        last_run <= run;
        last_rst_n <= rst_n;
    end

    wire steady = started && last_rst_n && rst_n;

    always @* begin
        // 1. An engine never changes a pin it doesn't own: whatever the program does, the output
        //    and output enable of a pin it didn't own last cycle are what they were.
        if (steady && last_run) begin
            assert (((out ^ last_out) & ~last_owned) == 0);
            assert (((oe ^ last_oe) & ~last_owned) == 0);
        end
        // 2. A stopped engine drives nothing.
        if (steady && !last_run) assert (out == 0 && oe == 0);
        // 3. The two-word mailboxes never hold more than two words.
        assert (inbox_count != 3);
        assert (outbox_count != 3);
    end
endmodule
