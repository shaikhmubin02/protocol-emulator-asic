// The timing guarantee, proven by induction with Yosys (scripts/prove.sh) on the generated
// engine. As in engine_props.sv every input is free on every cycle: the host, the pins, the
// other engines (flags, time, debug links) and the program word itself (formal/sram_any.v).
// So the cycle counts below hold for any program, and nothing outside the engine can stretch
// them: there are no hidden stalls.
//
// What is proven, for a running engine that the debugger isn't holding:
//   - every instruction that isn't a jump, wait or delay takes exactly one cycle;
//   - JMP and CALL take one cycle and land on their target, HALT stops in one cycle;
//   - an instruction with a delay of n (DLY n, or PIN/OUTG with n) takes exactly 1 + n cycles
//     and then moves on to the next instruction;
//   - a wait (WAIT, PUSH, PULL, TX, RX) checks its condition every cycle, never adds a cycle of
//     its own, and a pin wait moves on in the cycle after it sees the pin, which is the pin as it
//     was two clocks earlier (the input synchroniser);
//   - while the debugger holds the engine, the pc and the delay count don't move;
//   - a PIN write to an owned pin is in the output register in the next cycle (and so on the
//     pad, chip_props.sv), unless the bit engine is on and that pin is its TX pin;
//   - a pin changes only by a PIN or OUTG write or the bit engine: nothing else drives it;
//   - a wait on a pin, flag, time, the mailboxes or the TX/RX buffers moves on in exactly the
//     cycle after its condition holds and never earlier, except for a timeout, which sets T;
//   - the cycle a breakpoint fires, that engine and every engine joined to it issue nothing,
//     and they stay stopped until the host resumes them.

module timing_props (
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
    input [7:0] ev_flags,
    input [7:0] dbg_bp,
    input dbg_bp_on,
    input dbg_join,
    input dbg_others_hit,
    input dbg_stop,
    input dbg_resume,
    input dbg_step,
    input dbg_reg_we,
    input dbg_pc_we,
    input [2:0] dbg_idx
);
    wire [7:0] pc, busy;
    wire [15:0] instr;
    wire halted, stopped;
    wire [1:0] inbox_count, outbox_count;
    wire [14:0] out, oe;
    wire [2:0] flags;  // T, C, Z
    wire [3:0] bstat;  // [0] TX holding register empty, [2] RX word ready
    wire be_en, trigger;
    wire [4:0] tx_pin;
    wire [15:0] regs [0:7];

    `ENGINE dut (
        .clock(clock), .rst_n(rst_n), .uio_in(uio_in), .ui_in(ui_in), .owned(owned),
        .host_wr(host_wr), .host_data(host_data), .host_rd(host_rd),
        .prog_we(prog_we), .prog_re(prog_re), .prog_addr(prog_addr), .prog_data(prog_data),
        .run(run), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .\time (time_), .ev_flags(ev_flags),
        .dbg_bp(dbg_bp), .dbg_bp_on(dbg_bp_on), .dbg_join(dbg_join),
        .dbg_others_hit(dbg_others_hit), .dbg_stop(dbg_stop), .dbg_resume(dbg_resume),
        .dbg_step(dbg_step), .dbg_reg_we(dbg_reg_we), .dbg_pc_we(dbg_pc_we), .dbg_idx(dbg_idx),
        .pc(pc), .busy(busy), .halted(halted), .prog_q(instr), .dbg_stopped(stopped),
        .inbox_count(inbox_count), .outbox_count(outbox_count),
        .out(out), .oe(oe), .flags(flags), .bstat(bstat), .be_enabled(be_en), .tx_pin(tx_pin),
        .dbg_trigger(trigger),
        .regs_0(regs[0]), .regs_1(regs[1]), .regs_2(regs[2]), .regs_3(regs[3]),
        .regs_4(regs[4]), .regs_5(regs[5]), .regs_6(regs[6]), .regs_7(regs[7])
    );

    // the interface contract the chip keeps (see engine_props.sv)
    always @* begin
        if (host_wr) assume (inbox_count < 2);
        if (host_rd) assume (outbox_count != 0);
    end

    // ---- decoding the instruction being issued (ISA encoding, hw/src/isa.ml) ----
    wire [3:0] op = instr[15:12];
    wire [3:0] sub = instr[11:8];
    wire is_sys = op == 4'd0;
    wire is_wait = (is_sys && (sub == 4'd3 || sub == 4'd4 || sub == 4'd7 || sub == 4'd8))
                   || op == 4'd10;
    wire is_halt = is_sys && sub == 4'd1;
    wire is_ret = is_sys && sub == 4'd2;
    wire is_jmp = op == 4'd4 && sub == 4'd0;  // j always
    wire is_call = op == 4'd6;
    wire is_branch = op == 4'd4 || op == 4'd5;  // conditional jumps and djnz: either way, 1 cycle
    wire has_delay = op == 4'd7 || op == 4'd8 || op == 4'd11;
    wire [7:0] delay = op == 4'd11 ? instr[7:0] : {5'd0, instr[2:0]};
    wire straight = !is_wait && !is_halt && !is_ret && !is_branch && !is_call
                    && !(has_delay && delay != 0);
    wire wait_pin = op == 4'd10 && instr[11:10] == 2'd0;
    wire [4:0] wpin = instr[9:5];

    // the debugger isn't holding the engine this cycle (no stop, no breakpoint armed, no stop
    // coming in from another engine)
    wire quiet = !stopped && !dbg_bp_on && !(dbg_join && dbg_others_hit);

    // ---- last cycle's values ----
    reg started = 0, started2 = 0, started3 = 0;
    reg l_rst_n, l2_rst_n, l3_rst_n, l_run, l2_run, l3_run, l_quiet, l_halted, l_stopped, l_step, l_pc_we;
    reg [7:0] l_pc, l_busy;
    reg [15:0] l_instr;
    reg [7:0] l_uio, l2_uio, l3_uio, l_ui, l2_ui, l3_ui;
    reg [14:0] l_out, l_oe, l_owned;
    reg [2:0] l_flags;
    reg [3:0] l_bstat;
    reg l_be_en, l_trigger, l_join, l_others_hit, l_resume;
    reg [4:0] l_tx_pin;
    reg [1:0] l_inbox, l_outbox;
    reg [15:0] l_time, l_wait_reg;
    reg [7:0] l_ev_flags;
    always @(posedge clock) begin
        started <= 1;
        started2 <= started;
        started3 <= started2;
        l_rst_n <= rst_n;
        l2_rst_n <= l_rst_n;
        l3_rst_n <= l2_rst_n;
        l_run <= run;
        l2_run <= l_run;
        l3_run <= l2_run;
        l_quiet <= quiet;
        l_halted <= halted;
        l_stopped <= stopped;
        l_step <= dbg_step;
        l_pc_we <= dbg_pc_we;
        l_pc <= pc;
        l_busy <= busy;
        l_instr <= instr;
        l_uio <= uio_in;
        l2_uio <= l_uio;
        l3_uio <= l2_uio;
        l_ui <= ui_in;
        l2_ui <= l_ui;
        l3_ui <= l2_ui;
        l_out <= out;
        l_oe <= oe;
        l_owned <= owned;
        l_flags <= flags;
        l_bstat <= bstat;
        l_be_en <= be_en;
        l_tx_pin <= tx_pin;
        l_trigger <= trigger;
        l_inbox <= inbox_count;
        l_outbox <= outbox_count;
        l_time <= time_[15:0];
        l_ev_flags <= ev_flags;
        l_join <= dbg_join;
        l_others_hit <= dbg_others_hit;
        l_resume <= dbg_resume;
        l_wait_reg <= regs[instr[2:0]];
    end

    // same decode, for the instruction issued last cycle
    wire [3:0] l_op = l_instr[15:12];
    wire [3:0] l_sub = l_instr[11:8];
    wire l_is_sys = l_op == 4'd0;
    wire l_is_wait = (l_is_sys && (l_sub == 4'd3 || l_sub == 4'd4 || l_sub == 4'd7 || l_sub == 4'd8))
                     || l_op == 4'd10;
    wire l_is_halt = l_is_sys && l_sub == 4'd1;
    wire l_is_ret = l_is_sys && l_sub == 4'd2;
    wire l_is_jmp = l_op == 4'd4 && l_sub == 4'd0;
    wire l_is_call = l_op == 4'd6;
    wire l_is_branch = l_op == 4'd4 || l_op == 4'd5;
    wire l_has_delay = l_op == 4'd7 || l_op == 4'd8 || l_op == 4'd11;
    wire [7:0] l_delay = l_op == 4'd11 ? l_instr[7:0] : {5'd0, l_instr[2:0]};
    wire l_straight = !l_is_wait && !l_is_halt && !l_is_ret && !l_is_branch && !l_is_call
                      && !(l_has_delay && l_delay != 0);
    wire l_wait_pin = l_op == 4'd10 && l_instr[11:10] == 2'd0;
    wire [4:0] l_wpin = l_instr[9:5];
    wire l_wpin_level = l_instr[4];

    // no reset in the way: rst_n was high last cycle and is high now
    wire steady = started && l_rst_n && rst_n;
    // last cycle the engine issued an instruction (running, not halted, no delay counting, free)
    wire issued = steady && l_run && !l_halted && l_busy == 0 && l_quiet;
    // last cycle a delay was counting down
    wire counting = steady && l_run && !l_halted && l_busy != 0 && l_quiet;

    // what the pin wait saw last cycle: the pad two clocks before that, if the synchroniser
    // wasn't cleared or reset on the way (run low clears it)
    wire sync_valid = started3 && l2_run && l3_run && l_rst_n && l2_rst_n && l3_rst_n;
    wire l_pin_seen = l_wpin < 5'd8 ? l3_uio[l_wpin[2:0]]
                      : l_wpin >= 5'd16 && l_wpin < 5'd24 ? l3_ui[l_wpin[2:0]]
                      : 1'b0;
    wire l_pin_is_pad = l_wpin < 5'd8 || (l_wpin >= 5'd16 && l_wpin < 5'd24);

    // ---- pin writes ----
    wire [4:0] l_pin_p = l_instr[9:5];
    wire [1:0] l_pin_mode = l_instr[4:3];
    wire [1:0] l_pin_op = l_instr[11:10];
    wire l_pin_drive = l_op == 4'd7 && l_pin_mode != 2'd3;  // everything but SAMPLE
    wire l_pin_is_tx = l_be_en && l_tx_pin == l_pin_p;
    wire l_c = l_flags[1];
    wire l_pin_hiz = l_pin_mode == 2'd0 && l_pin_op == 2'd3;
    wire l_pin_out = l_pin_mode == 2'd1 ? l_c
                   : l_pin_mode == 2'd2 ? !l_c
                   : l_pin_op == 2'd0 ? 1'b0
                   : l_pin_op == 2'd1 ? 1'b1
                   : l_pin_op == 2'd2 ? !l_out[l_pin_p]
                   : l_pin_p < 5'd8 ? l_out[l_pin_p] : 1'b0;  // HIZ: uo pins can't float, drive 0
    wire l_pin_oe = !(l_pin_hiz && l_pin_p < 5'd8);

    // 12. a pin changes only when the program writes it (PIN on that pin, or any OUTG) or the
    //     bit engine drives it: no other path reaches the output register
    genvar q;
    generate
        for (q = 0; q < 15; q = q + 1) begin : quiet_pin
            wire could_write = l_run && !l_halted && l_busy == 0
                               && ((l_pin_drive && l_pin_p == q) || l_op == 4'd8);
            always @* begin
                if (steady && l_run && !could_write && !(l_be_en && l_tx_pin == q))
                    assert (out[q] == l_out[q] && oe[q] == l_oe[q]);
            end
        end
    endgenerate

    // ---- what each wait was waiting for, seen at the start of the cycle it was issued ----
    wire l_pin_level = l_wpin < 5'd8 ? l3_uio[l_wpin[2:0]]
                     : l_wpin < 5'd15 ? l_out[l_wpin]
                     : l_wpin >= 5'd16 && l_wpin < 5'd24 ? l3_ui[l_wpin[2:0]]
                     : 1'b0;
    wire [15:0] l_time_diff = l_time - l_wait_reg;
    wire [3:0] l_ev = l_instr[3:0];
    reg l_cond, l_cond_known;
    always @* begin
        l_cond_known = 1;
        l_cond = 0;
        if (l_is_sys && l_sub == 4'd3) l_cond = l_outbox < 2'd2;  // PUSH: outbox has room
        else if (l_is_sys && l_sub == 4'd4) l_cond = l_inbox != 2'd0;  // PULL: inbox has a word
        else if (l_is_sys && l_sub == 4'd7) l_cond = l_bstat[0];  // TX: holding register free
        else if (l_is_sys && l_sub == 4'd8) l_cond = l_bstat[2];  // RX: a word is ready
        else case (l_instr[11:10])
            2'd0: begin  // WAIT PIN: a pad pin through the synchroniser, an output pin directly
                l_cond = l_pin_level == l_wpin_level;
                l_cond_known = !l_pin_is_pad || sync_valid;
            end
            2'd1: l_cond = l_ev_flags[l_instr[2:0]] == l_instr[3];  // WAIT FLAG
            2'd2: l_cond = !l_time_diff[15];  // WAIT TIME: time - r >= 0 (mod 2^16)
            2'd3: begin  // WAIT EVENT
                if (l_ev == 4'd0) l_cond = l_bstat[0];
                else if (l_ev == 4'd1) l_cond = l_bstat[2];
                else if (l_ev >= 4'd4) l_cond = l_inbox != 2'd0;
                else l_cond_known = 0;  // baud tick, capture: internal, not checked here
            end
        endcase
    end

    always @* begin
        if (issued) begin
            // 1. one cycle, then the next instruction
            if (l_straight) assert (pc == l_pc + 8'd1 && busy == 0 && !halted);
            // 2. JMP and CALL: one cycle, on the target
            if (l_is_jmp || l_is_call) assert (pc == l_instr[7:0] && busy == 0);
            // 3. conditional jumps and DJNZ: one cycle, taken or not
            if (l_is_branch) assert (busy == 0 && (pc == l_instr[7:0] || pc == l_pc + 8'd1));
            // 4. HALT stops in place
            if (l_is_halt) assert (halted && pc == l_pc);
            // 5. a delay of n starts counting n
            if (l_has_delay && l_delay != 0) assert (pc == l_pc && busy == l_delay);
            // 6. a wait checks every cycle and adds nothing of its own
            if (l_is_wait) assert (busy == 0 && (pc == l_pc || pc == l_pc + 8'd1));
            // 7. a pin wait moves on in the cycle after it sees the pin
            if (l_wait_pin && l_pin_is_pad && sync_valid && l_pin_seen == l_wpin_level)
                assert (pc == l_pc + 8'd1);
        end
        // 8. the count goes down by exactly one a cycle, the pc stays...
        if (counting && l_busy != 1) assert (busy == l_busy - 8'd1 && pc == l_pc);
        // 9. ...and the last count moves on to the next instruction
        if (counting && l_busy == 1) assert (busy == 0 && pc == l_pc + 8'd1);
        // 10. held by the debugger (and no step or pc write): nothing moves
        if (steady && l_run && l_stopped && !l_step && !l_pc_we)
            assert (pc == l_pc && busy == l_busy);

        // 11. a PIN write to a pin the engine owns is on its output register in the next cycle,
        //     whatever the delay field says, unless the bit engine is on and drives that pin
        if (issued && l_pin_drive && l_pin_p < 5'd15 && l_owned[l_pin_p] && !l_pin_is_tx)
            assert (out[l_pin_p] == l_pin_out && oe[l_pin_p] == l_pin_oe);

        // 13. waits finish exactly: in the cycle after the condition holds, never before it
        //     (except for a timeout, which sets T), and T is clear when the condition was met
        if (issued && l_is_wait && l_cond_known) begin
            if (l_cond) assert (pc == l_pc + 8'd1 && !flags[2]);
            else assert (pc == l_pc || (pc == l_pc + 8'd1 && flags[2]));
        end

        // 14. the cycle this engine's breakpoint fires it issues nothing...
        if (steady && l_run && l_trigger && !l_pc_we) assert (pc == l_pc && busy == l_busy);
        // 15. ...and neither does any engine joined to it, in that same cycle
        if (steady && l_run && l_join && l_others_hit && !l_step && !l_pc_we)
            assert (pc == l_pc && busy == l_busy);
        // 16. both then stay stopped until the host resumes them
        if (steady && l_run && (l_trigger || (l_join && l_others_hit && !l_step)) && !l_resume)
            assert (stopped);
    end

endmodule
