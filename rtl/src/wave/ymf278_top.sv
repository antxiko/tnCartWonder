//
// ymf278_top.sv
//
// MangOPL4 Fase 2 — top-level del motor Wave del YMF278B.
//
// Estado en sub-fase 2a "hello world":
//   - Decodifica writes a 7E (latch reg address) y 7F (write reg data).
//   - Mantiene el regfile de 256 bytes (en CLK domain).
//   - Sintetiza UNA voz con onda cuadrada interna (no LUT, para máxima
//     simplicidad). Se usa el bit 7 del registro 0x68 (slot 0 offset 4)
//     como "key-on" — el formato real del YMF278B.
//   - Pitch fijo: ~1.7 kHz audible. No depende de FN/OCT del slot.
//   - Read-back (puerto 7F) devuelve 0x20 stub (preserva detección
//     MoonSound de VGMPlay como en el wrapper original).
//
// En sub-fases posteriores este módulo crece: SDRAM fetch, 24 canales
// time-shared, envelope DADSR, LFO, pan, etc.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_top
    import ymf278_pkg::*;
(
    input  wire                 RESET_n,
    input  wire                 CLK,            // 107.4 MHz, bus MSX
    input  wire                 CLK_OPL3,       // 33.5625 MHz, motor wave
    input  wire                 bus_reset_n,    // Bus.RESET_n del MSX
    input  wire                 new2,           // OPL3 reg 0x105 bit 1 (NEW2)

    // Bus decodificado por el caller (cartridge_opl3.sv):
    input  wire                 wr_strobe,      // 1 ciclo CLK cuando hay write a 7E o 7F
    input  wire                 addr0,          // 0=7E (reg select), 1=7F (data)
    input  wire [7:0]           din,            // Bus.DIN

    // Read-back para 7F:
    output logic [7:0]          rd_data,

    // Salida audio: signed 24-bit (mismo width que DAC OPL3) para sumar
    // directamente con mono_q antes del gain stage en cartridge_opl3.sv.
    output logic signed [23:0]  wave_sample
);

    /***************************************************************
     * 7E/7F decode + regfile (todo en dominio CLK)
     ***************************************************************/
    logic [7:0] reg_addr_latch;
    logic       reg_wr_stb;       // pulso a regfile cuando hay write a 7F

    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n || !bus_reset_n) begin
            reg_addr_latch <= 8'h00;
        end
        else if (wr_strobe && !addr0) begin
            // Write a 7E: latch dirección de registro
            reg_addr_latch <= din;
        end
    end

    // NEW2 gating: writes ignorados si new2=0 (chip dormido)
    assign reg_wr_stb = wr_strobe && addr0 && new2;

    logic [7:0] regs [0:NUM_REGS-1];
    ymf278_regfile u_regfile (
        .RESET_n        (RESET_n),
        .CLK            (CLK),
        .wr_stb         (reg_wr_stb),
        .wr_addr        (reg_addr_latch),
        .wr_data        (din),
        .regs           (regs)
    );

    // Read-back stub: 0x20 (preserva detección MoonSound de VGMPlay)
    assign rd_data = 8'h20;

    /***************************************************************
     * Key-on de slot 0: bit 7 del registro 0x68 (slot=0, offset=4)
     * Sync 2-FF de CLK → CLK_OPL3.
     ***************************************************************/
    wire keyon_slot0_clk = regs[8'h68][7];
    logic keyon_s1, keyon_s2;
    always_ff @(posedge CLK_OPL3 or negedge RESET_n) begin
        if (!RESET_n) begin
            keyon_s1 <= 1'b0;
            keyon_s2 <= 1'b0;
        end
        else begin
            keyon_s1 <= keyon_slot0_clk;
            keyon_s2 <= keyon_s1;
        end
    end
    wire keyon_sync = keyon_s2;

    /***************************************************************
     * Sample tick divider: ~44.16 kHz desde CLK_OPL3
     ***************************************************************/
    localparam int TICK_BITS = $clog2(SAMPLE_TICK_DIV);
    logic [TICK_BITS-1:0] tick_counter;
    logic                  sample_tick;
    always_ff @(posedge CLK_OPL3 or negedge RESET_n) begin
        if (!RESET_n) begin
            tick_counter <= '0;
            sample_tick  <= 1'b0;
        end
        else if (tick_counter == TICK_BITS'(SAMPLE_TICK_DIV - 1)) begin
            tick_counter <= '0;
            sample_tick  <= 1'b1;
        end
        else begin
            tick_counter <= tick_counter + 1'b1;
            sample_tick  <= 1'b0;
        end
    end

    /***************************************************************
     * Phase accumulator (1 voz, paso fijo) + square wave
     *
     * Paso fijo elegido para tono audible ~1.7 kHz a sample rate
     * 44.16 kHz: step = 2^32 * 1700 / 44160 ≈ 0x0270_0000.
     * El bit 31 de phase es el signo de la onda cuadrada.
     ***************************************************************/
    localparam logic [PHASE_WIDTH-1:0] FIXED_STEP = 32'h0270_0000;
    localparam logic signed [15:0]    SQUARE_HI  = 16'sh4000;   //  +16384
    localparam logic signed [15:0]    SQUARE_LO  = -16'sh4000;  //  −16384

    logic [PHASE_WIDTH-1:0] phase;
    always_ff @(posedge CLK_OPL3 or negedge RESET_n) begin
        if (!RESET_n || !bus_reset_n) begin
            phase <= '0;
        end
        else if (!keyon_sync) begin
            // Key-off: reset phase a 0 para evitar click al re-key-on
            phase <= '0;
        end
        else if (sample_tick) begin
            phase <= phase + FIXED_STEP;
        end
    end

    logic signed [15:0] wave16;
    always_ff @(posedge CLK_OPL3 or negedge RESET_n) begin
        if (!RESET_n || !bus_reset_n) begin
            wave16 <= 16'sh0000;
        end
        else if (!keyon_sync) begin
            wave16 <= 16'sh0000;
        end
        else begin
            wave16 <= phase[PHASE_WIDTH-1] ? SQUARE_LO : SQUARE_HI;
        end
    end

    // Sign-extend a 24-bit para sumar con mono_q en cartridge_opl3.sv
    assign wave_sample = {{8{wave16[15]}}, wave16};

endmodule

`default_nettype wire
