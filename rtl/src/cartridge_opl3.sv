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
     * Lectura de status (registro C4h, address 00) — el core devuelve
     * dout en dominio CLK (clk_host)
     ***************************************************************/
    wire [7:0] opl3_dout;
    wire status_read = rd_opl3 && (Bus.ADDR[1:0] == 2'b00);
    assign Bus.BUSDIR_n = !status_read;
    assign Bus.DOUT     = status_read ? opl3_dout : 8'h00;

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
