//
// cartridge_opl3.sv
//
// MangOPL4 — wrapper del core OPL3 (gtaylormb/opl3_fpga) para tnCartWonder.
// Decodifica C4h-C7h del bus MSX (mapeo nativo MoonSound FM) y conecta al
// módulo `opl3` del core. Salida PCM 24-bit signed estéreo se promedia y se
// trunca a SOUND_BIT_WIDTH bits (signed, top bit = signo) para alimentar al
// SOUND_MIXER existente.
//
// El core tiene host_if con FIFO async entre clk_host (=CLK del bus MSX) y
// clk (=CLK_OPL3 = 33.5625 MHz). Las escrituras se sincronizan vía esa FIFO,
// no hace falta CDC adicional.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module CARTRIDGE_OPL3 (
    input   wire            RESET_n,
    input   wire            CLK,        // 107.4 MHz, dominio bus MSX (clk_host)
    input   wire            CLK_OPL3,   // 33.5625 MHz, dominio core OPL3
    BUS_IF.CARTRIDGE        Bus,
    SOUND_IF.OUT            Sound
);

    /***************************************************************
     * 未使用の出力信号の処理
     ***************************************************************/
    assign Bus.INT_n = 1;
    assign Bus.WAIT_n = 1;

    /***************************************************************
     * Decodificación C4h-C7h (0xC4>>2 = 0x31 = 6'b110001)
     ***************************************************************/
    wire cs_opl3   = !Bus.IORQ_n && (Bus.ADDR[7:2] == 6'b110001);
    wire rd_opl3   = cs_opl3 && !Bus.RD_n;
    wire opl3_cs_n = !cs_opl3;

    /***************************************************************
     * Shadow register file — emula la legibilidad de registros
     * OPL3 que tiene el YMF278B real (verificado en openMSX
     * YMF278B.cc: read C5/C7 devuelve ymf262.readReg(opl3latch)).
     * El core gtaylormb es OPL3 puro y no expone read-back; aquí
     * capturamos las escrituras del bus y mantenemos un mirror de
     * 256 bytes × 2 banks. Sin esto MoonBlaster FM y similares
     * fallan la detección write/read-verify.
     *
     * En el YMF278B real, status read aparece en C4 Y C6
     * (port&0x03 == 0 ó 2). Aquí lo replicamos.
     ***************************************************************/
    logic [7:0] shadow_b0 [0:255];
    logic [7:0] shadow_b1 [0:255];
    logic [7:0] sel_reg_b0 = 0;
    logic [7:0] sel_reg_b1 = 0;

    // Detecta flanco ascendente del strobe de escritura en el bus
    logic prev_wr_active = 0;
    wire  wr_active = cs_opl3 && !Bus.WR_n;
    wire  wr_strobe = wr_active && !prev_wr_active;

    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n || !Bus.RESET_n) begin
            prev_wr_active <= 1'b0;
            sel_reg_b0 <= 8'd0;
            sel_reg_b1 <= 8'd0;
        end
        else begin
            prev_wr_active <= wr_active;
            if (wr_strobe) begin
                case (Bus.ADDR[1:0])
                    2'b00: sel_reg_b0 <= Bus.DIN;
                    2'b01: shadow_b0[sel_reg_b0] <= Bus.DIN;
                    2'b10: sel_reg_b1 <= Bus.DIN;
                    2'b11: shadow_b1[sel_reg_b1] <= Bus.DIN;
                endcase
            end
        end
    end

    /***************************************************************
     * DEBUG MÁXIMO: TODOS los puertos C4-C7 devuelven 0x42 fijo
     ***************************************************************/
    wire [7:0] opl3_dout;

    /* verilator lint_off UNUSEDSIGNAL */
    wire [7:0] _unused_b0 = shadow_b0[sel_reg_b0];
    wire [7:0] _unused_b1 = shadow_b1[sel_reg_b1];
    wire [7:0] _unused_dout = opl3_dout;
    /* verilator lint_on UNUSEDSIGNAL */

    assign Bus.BUSDIR_n = !rd_opl3;
    assign Bus.DOUT     = rd_opl3 ? 8'h42 : 8'h00;

    /***************************************************************
     * Instancia del core gtaylormb/opl3_fpga
     ***************************************************************/
    wire signed [opl3_pkg::DAC_OUTPUT_WIDTH-1:0] sample_l;
    wire signed [opl3_pkg::DAC_OUTPUT_WIDTH-1:0] sample_r;
    wire        sample_valid;
    /* verilator lint_off PINMISSING */
    opl3 u_opl3 (
        .clk            (CLK_OPL3),
        .clk_host       (CLK),
        .clk_dac        (1'b0),                 // INSTANTIATE_SAMPLE_SYNC_TO_DAC_CLK=0
        .ic_n           (RESET_n && Bus.RESET_n),
        .cs_n           (opl3_cs_n),
        .rd_n           (Bus.RD_n),
        .wr_n           (Bus.WR_n),
        .address        (Bus.ADDR[1:0]),
        .din            (Bus.DIN),
        .dout           (opl3_dout),
        .sample_valid   (sample_valid),
        .sample_l       (sample_l),
        .sample_r       (sample_r),
        .led            (),
        .irq_n          ()
    );
    /* verilator lint_on PINMISSING */

    /***************************************************************
     * Promedio L+R, amplificación con shift-left saturante (64x), y
     * truncado a SOUND_BIT_WIDTH bits (signed, top=signo).
     * Sin amplificación el rango efectivo del core gtaylormb (~±2^17
     * dentro del DAC de 24 bits) deja el signal a 1/64 de full-scale
     * en 10 bits, audible pero muy bajo. GAIN_BITS=6 (64x) lleva el
     * pico típico cerca de full-scale 10-bit con saturación en peaks.
     ***************************************************************/
    localparam DAC_W = opl3_pkg::DAC_OUTPUT_WIDTH;
    localparam SND_W = $bits(Sound.Signal);
    localparam GAIN_BITS = 6;

    logic signed [DAC_W-1:0] mono_q;
    always_ff @(posedge CLK_OPL3) begin
        mono_q <= DAC_W'(({sample_l[DAC_W-1], sample_l} + {sample_r[DAC_W-1], sample_r}) >>> 1);
    end

    // Saturating shift-left por GAIN_BITS: detecta si los GAIN_BITS bits
    // por debajo del signo no coinciden con el signo (overflow), y satura.
    wire signed [DAC_W-1:0] mono_shifted = mono_q <<< GAIN_BITS;
    wire ovf_pos = !mono_q[DAC_W-1] &&  |mono_q[DAC_W-2 -: GAIN_BITS];
    wire ovf_neg =  mono_q[DAC_W-1] && ~&mono_q[DAC_W-2 -: GAIN_BITS];

    logic signed [DAC_W-1:0] mono_amp;
    always_ff @(posedge CLK_OPL3) begin
        if (ovf_pos)      mono_amp <= {1'b0, {(DAC_W-1){1'b1}}};
        else if (ovf_neg) mono_amp <= {1'b1, {(DAC_W-1){1'b0}}};
        else              mono_amp <= mono_shifted;
    end

    // Cruce de dominio CLK_OPL3 → CLK por simple registro.
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n || !Bus.RESET_n) begin
            Sound.Signal <= 0;
        end
        else begin
            Sound.Signal <= mono_amp[DAC_W-1 -: SND_W];
        end
    end

endmodule

`default_nettype wire
