// Generated from hw/ by bin/generate.exe. Do not edit.

module tt_um_shaikhmubin02_spike (
    clk,
    rst_n,
    ui_in,
    ena,
    uio_in,
    uo_out,
    uio_out,
    uio_oe
);

    input clk;
    input rst_n;
    input [7:0] ui_in;
    input ena;
    input [7:0] uio_in;
    output [7:0] uo_out;
    output [7:0] uio_out;
    output [7:0] uio_oe;

    wire [7:0] signal_const;
    wire [3:0] signal_const_1;
    wire signal_eq;
    wire signal_and;
    wire [6:0] signal_const_2;
    wire [15:0] signal_const_3;
    wire [7:0] signal_const_5;
    wire [15:0] signal_const_6;
    wire [15:0] signal_select;
    wire [7:0] signal_select_1;
    wire [7:0] signal_const_7;
    wire [7:0] signal_mux;
    reg [7:0] signal_reg;
    wire [7:0] signal_wire;
    wire [7:0] signal_add;
    wire signal_select_2;
    wire signal_select_3;
    wire signal_select_4;
    wire signal_select_5;
    wire signal_select_6;
    wire signal_select_7;
    wire signal_select_8;
    wire signal_select_9;
    wire signal_select_10;
    reg signal_mux_1;
    wire signal_eq_1;
    wire signal_not;
    wire [3:0] signal_const_10;
    wire signal_eq_2;
    wire signal_and_1;
    wire [7:0] signal_mux_2;
    wire signal_eq_3;
    wire signal_not_1;
    wire [3:0] signal_const_12;
    wire signal_eq_4;
    wire signal_and_2;
    wire [15:0] signal_const_14;
    wire [2:0] signal_const_15;
    wire signal_eq_5;
    wire signal_and_3;
    reg [15:0] signal_reg_1;
    wire [15:0] signal_wire_1;
    wire [2:0] signal_const_17;
    wire signal_eq_6;
    wire signal_and_4;
    reg [15:0] signal_reg_2;
    wire [15:0] signal_wire_2;
    wire [2:0] signal_const_19;
    wire signal_eq_7;
    wire signal_and_5;
    reg [15:0] signal_reg_3;
    wire [15:0] signal_wire_3;
    wire [2:0] signal_const_21;
    wire signal_eq_8;
    wire signal_and_6;
    reg [15:0] signal_reg_4;
    wire [15:0] signal_wire_4;
    wire [2:0] signal_const_23;
    wire signal_eq_9;
    wire signal_and_7;
    reg [15:0] signal_reg_5;
    wire [15:0] signal_wire_5;
    wire [2:0] signal_const_25;
    wire signal_eq_10;
    wire signal_and_8;
    reg [15:0] signal_reg_6;
    wire [15:0] signal_wire_6;
    wire [2:0] signal_const_27;
    wire signal_eq_11;
    wire signal_and_9;
    reg [15:0] signal_reg_7;
    wire [15:0] signal_wire_7;
    wire [2:0] signal_const_29;
    wire signal_eq_12;
    wire [3:0] signal_const_30;
    wire signal_eq_13;
    wire [3:0] signal_const_31;
    wire signal_eq_14;
    wire [3:0] signal_const_32;
    wire signal_eq_15;
    wire [3:0] signal_const_33;
    wire signal_eq_16;
    wire signal_or;
    wire signal_or_1;
    wire signal_or_2;
    wire signal_and_10;
    wire signal_and_11;
    wire [15:0] signal_cat;
    wire [15:0] signal_add_1;
    wire [7:0] signal_select_11;
    wire [15:0] signal_cat_1;
    reg [15:0] signal_mux_3;
    reg [15:0] signal_reg_8;
    wire [15:0] signal_wire_8;
    wire [2:0] signal_select_12;
    reg [15:0] signal_mux_4;
    wire [15:0] signal_sub;
    wire signal_eq_17;
    wire signal_not_2;
    wire signal_eq_18;
    wire signal_and_12;
    wire [3:0] signal_const_38;
    wire [3:0] signal_select_13;
    wire signal_eq_19;
    wire signal_or_3;
    wire signal_or_4;
    wire [7:0] signal_mux_5;
    wire [7:0] signal_wire_9;
    wire signal_select_14;
    wire [23:0] signal_const_39;
    wire signal_wire_10;
    wire signal_select_15;
    wire [22:0] signal_select_16;
    wire [23:0] signal_cat_2;
    wire [23:0] signal_wire_11;
    reg [23:0] signal_reg_9;
    wire [7:0] signal_select_17;
    wire [7:0] signal_mux_6;
    wire [7:0] signal_mux_7;
    wire signal_select_18;
    wire signal_not_3;
    wire [7:0] signal_wire_12;
    wire signal_select_19;
    wire signal_and_13;
    wire vdd;
    wire signal_wire_13;
    wire [15:0] signal_inst;
    wire [15:0] signal_wire_14;
    wire [2:0] signal_select_20;
    reg [15:0] signal_mux_8;
    wire [6:0] signal_select_21;
    reg [6:0] signal_reg_10;
    wire gnd;
    wire [7:0] signal_cat_3;
    assign signal_const = 8'b11111111;
    assign signal_const_1 = 4'b0011;
    assign signal_eq = signal_select_13 == signal_const_1;
    assign signal_and = signal_select_18 & signal_eq;
    assign signal_const_2 = 7'b0000000;
    assign signal_const_3 = 16'b0000000000000000;
    assign signal_const_5 = 8'b00000000;
    assign signal_const_6 = 16'b1111111111111111;
    assign signal_select = signal_reg_9[15:0];
    assign signal_select_1 = signal_wire_14[7:0];
    assign signal_const_7 = 8'b00000001;
    assign signal_mux = signal_select_18 ? signal_wire_9 : signal_const_5;
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg <= signal_const_5;
        else
            signal_reg <= signal_mux;
    end
    assign signal_wire = signal_reg;
    assign signal_add = signal_wire + signal_const_7;
    assign signal_select_2 = signal_wire_14[0:0];
    assign signal_select_3 = signal_wire_12[7:7];
    assign signal_select_4 = signal_wire_12[6:6];
    assign signal_select_5 = signal_wire_12[5:5];
    assign signal_select_6 = signal_wire_12[4:4];
    assign signal_select_7 = signal_wire_12[3:3];
    assign signal_select_8 = signal_wire_12[2:2];
    assign signal_select_9 = signal_wire_12[1:1];
    assign signal_select_10 = signal_wire_12[0:0];
    always @* begin
        case (signal_select_12)
        0:
            signal_mux_1 <= signal_select_10;
        1:
            signal_mux_1 <= signal_select_9;
        2:
            signal_mux_1 <= signal_select_8;
        3:
            signal_mux_1 <= signal_select_7;
        4:
            signal_mux_1 <= signal_select_6;
        5:
            signal_mux_1 <= signal_select_5;
        6:
            signal_mux_1 <= signal_select_4;
        default:
            signal_mux_1 <= signal_select_3;
        endcase
    end
    assign signal_eq_1 = signal_mux_1 == signal_select_2;
    assign signal_not = ~ signal_eq_1;
    assign signal_const_10 = 4'b0110;
    assign signal_eq_2 = signal_select_13 == signal_const_10;
    assign signal_and_1 = signal_eq_2 & signal_not;
    assign signal_mux_2 = signal_and_1 ? signal_wire : signal_add;
    assign signal_eq_3 = signal_mux_4 == signal_const_3;
    assign signal_not_1 = ~ signal_eq_3;
    assign signal_const_12 = 4'b1000;
    assign signal_eq_4 = signal_select_13 == signal_const_12;
    assign signal_and_2 = signal_eq_4 & signal_not_1;
    assign signal_const_14 = 16'b0000000000000001;
    assign signal_const_15 = 3'b111;
    assign signal_eq_5 = signal_select_12 == signal_const_15;
    assign signal_and_3 = signal_and_10 & signal_eq_5;
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg_1 <= signal_const_3;
        else
            if (signal_and_3)
                signal_reg_1 <= signal_mux_3;
    end
    assign signal_wire_1 = signal_reg_1;
    assign signal_const_17 = 3'b110;
    assign signal_eq_6 = signal_select_12 == signal_const_17;
    assign signal_and_4 = signal_and_10 & signal_eq_6;
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg_2 <= signal_const_3;
        else
            if (signal_and_4)
                signal_reg_2 <= signal_mux_3;
    end
    assign signal_wire_2 = signal_reg_2;
    assign signal_const_19 = 3'b101;
    assign signal_eq_7 = signal_select_12 == signal_const_19;
    assign signal_and_5 = signal_and_10 & signal_eq_7;
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg_3 <= signal_const_3;
        else
            if (signal_and_5)
                signal_reg_3 <= signal_mux_3;
    end
    assign signal_wire_3 = signal_reg_3;
    assign signal_const_21 = 3'b100;
    assign signal_eq_8 = signal_select_12 == signal_const_21;
    assign signal_and_6 = signal_and_10 & signal_eq_8;
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg_4 <= signal_const_3;
        else
            if (signal_and_6)
                signal_reg_4 <= signal_mux_3;
    end
    assign signal_wire_4 = signal_reg_4;
    assign signal_const_23 = 3'b011;
    assign signal_eq_9 = signal_select_12 == signal_const_23;
    assign signal_and_7 = signal_and_10 & signal_eq_9;
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg_5 <= signal_const_3;
        else
            if (signal_and_7)
                signal_reg_5 <= signal_mux_3;
    end
    assign signal_wire_5 = signal_reg_5;
    assign signal_const_25 = 3'b010;
    assign signal_eq_10 = signal_select_12 == signal_const_25;
    assign signal_and_8 = signal_and_10 & signal_eq_10;
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg_6 <= signal_const_3;
        else
            if (signal_and_8)
                signal_reg_6 <= signal_mux_3;
    end
    assign signal_wire_6 = signal_reg_6;
    assign signal_const_27 = 3'b001;
    assign signal_eq_11 = signal_select_12 == signal_const_27;
    assign signal_and_9 = signal_and_10 & signal_eq_11;
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg_7 <= signal_const_3;
        else
            if (signal_and_9)
                signal_reg_7 <= signal_mux_3;
    end
    assign signal_wire_7 = signal_reg_7;
    assign signal_const_29 = 3'b000;
    assign signal_eq_12 = signal_select_12 == signal_const_29;
    assign signal_const_30 = 4'b0111;
    assign signal_eq_13 = signal_select_13 == signal_const_30;
    assign signal_const_31 = 4'b0101;
    assign signal_eq_14 = signal_select_13 == signal_const_31;
    assign signal_const_32 = 4'b0010;
    assign signal_eq_15 = signal_select_13 == signal_const_32;
    assign signal_const_33 = 4'b0001;
    assign signal_eq_16 = signal_select_13 == signal_const_33;
    assign signal_or = signal_eq_16 | signal_eq_15;
    assign signal_or_1 = signal_or | signal_eq_14;
    assign signal_or_2 = signal_or_1 | signal_eq_13;
    assign signal_and_10 = signal_select_18 & signal_or_2;
    assign signal_and_11 = signal_and_10 & signal_eq_12;
    assign signal_cat = { signal_const_5,
                          signal_wire_12 };
    assign signal_add_1 = signal_mux_4 + signal_mux_8;
    assign signal_select_11 = signal_wire_14[7:0];
    assign signal_cat_1 = { signal_const_5,
                            signal_select_11 };
    always @* begin
        case (signal_select_13)
        0:
            signal_mux_3 <= signal_mux_4;
        1:
            signal_mux_3 <= signal_cat_1;
        2:
            signal_mux_3 <= signal_add_1;
        3:
            signal_mux_3 <= signal_mux_4;
        4:
            signal_mux_3 <= signal_mux_4;
        5:
            signal_mux_3 <= signal_sub;
        6:
            signal_mux_3 <= signal_mux_4;
        default:
            signal_mux_3 <= signal_cat;
        endcase
    end
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg_8 <= signal_const_3;
        else
            if (signal_and_11)
                signal_reg_8 <= signal_mux_3;
    end
    assign signal_wire_8 = signal_reg_8;
    assign signal_select_12 = signal_wire_14[10:8];
    always @* begin
        case (signal_select_12)
        0:
            signal_mux_4 <= signal_wire_8;
        1:
            signal_mux_4 <= signal_wire_7;
        2:
            signal_mux_4 <= signal_wire_6;
        3:
            signal_mux_4 <= signal_wire_5;
        4:
            signal_mux_4 <= signal_wire_4;
        5:
            signal_mux_4 <= signal_wire_3;
        6:
            signal_mux_4 <= signal_wire_2;
        default:
            signal_mux_4 <= signal_wire_1;
        endcase
    end
    assign signal_sub = signal_mux_4 - signal_const_14;
    assign signal_eq_17 = signal_sub == signal_const_3;
    assign signal_not_2 = ~ signal_eq_17;
    assign signal_eq_18 = signal_select_13 == signal_const_31;
    assign signal_and_12 = signal_eq_18 & signal_not_2;
    assign signal_const_38 = 4'b0100;
    assign signal_select_13 = signal_wire_14[15:12];
    assign signal_eq_19 = signal_select_13 == signal_const_38;
    assign signal_or_3 = signal_eq_19 | signal_and_12;
    assign signal_or_4 = signal_or_3 | signal_and_2;
    assign signal_mux_5 = signal_or_4 ? signal_select_1 : signal_mux_2;
    assign signal_wire_9 = signal_mux_5;
    assign signal_select_14 = signal_wire_12[1:1];
    assign signal_const_39 = 24'b000000000000000000000000;
    assign signal_wire_10 = rst_n;
    assign signal_select_15 = signal_wire_12[0:0];
    assign signal_select_16 = signal_reg_9[22:0];
    assign signal_cat_2 = { signal_select_16,
                            signal_select_15 };
    assign signal_wire_11 = signal_cat_2;
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg_9 <= signal_const_39;
        else
            if (signal_select_14)
                signal_reg_9 <= signal_wire_11;
    end
    assign signal_select_17 = signal_reg_9[23:16];
    assign signal_mux_6 = signal_and_13 ? signal_select_17 : signal_const_5;
    assign signal_mux_7 = signal_select_18 ? signal_wire_9 : signal_mux_6;
    assign signal_select_18 = signal_wire_12[3:3];
    assign signal_not_3 = ~ signal_select_18;
    assign signal_wire_12 = ui_in;
    assign signal_select_19 = signal_wire_12[2:2];
    assign signal_and_13 = signal_select_19 & signal_not_3;
    assign vdd = 1'b1;
    assign signal_wire_13 = clk;
    RM_IHPSG13_1P_256x16_c2_bm_bist
        sram
        ( .A_CLK(signal_wire_13),
          .A_MEN(vdd),
          .A_WEN(signal_and_13),
          .A_REN(vdd),
          .A_ADDR(signal_mux_7),
          .A_DIN(signal_select),
          .A_DLY(vdd),
          .A_BM(signal_const_6),
          .A_BIST_CLK(gnd),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(signal_const_5),
          .A_BIST_DIN(signal_const_3),
          .A_BIST_BM(signal_const_3),
          .A_DOUT(signal_inst[15:0]) );
    assign signal_wire_14 = signal_inst;
    assign signal_select_20 = signal_wire_14[6:4];
    always @* begin
        case (signal_select_20)
        0:
            signal_mux_8 <= signal_wire_8;
        1:
            signal_mux_8 <= signal_wire_7;
        2:
            signal_mux_8 <= signal_wire_6;
        3:
            signal_mux_8 <= signal_wire_5;
        4:
            signal_mux_8 <= signal_wire_4;
        5:
            signal_mux_8 <= signal_wire_3;
        6:
            signal_mux_8 <= signal_wire_2;
        default:
            signal_mux_8 <= signal_wire_1;
        endcase
    end
    assign signal_select_21 = signal_mux_8[6:0];
    always @(posedge signal_wire_13 or negedge signal_wire_10) begin
        if (signal_wire_10 == 0)
            signal_reg_10 <= signal_const_2;
        else
            if (signal_and)
                signal_reg_10 <= signal_select_21;
    end
    assign gnd = 1'b0;
    assign signal_cat_3 = { gnd,
                            signal_reg_10 };
    assign uo_out = signal_cat_3;
    assign uio_out = signal_wire;
    assign uio_oe = signal_const;

endmodule
