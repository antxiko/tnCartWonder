//
// ymf278_phase.sv
//
// MangOPL4 Fase 2c.2 — phase accumulator 32-bit (16.16 fixed point) para
// 1 canal del YMF278B. Calcula phase_inc desde FNUM/OCTAVE y avanza el
// accumulator a cada sample_clk_en (44.1 kHz). Reset de phase en flanco
// subiente de key_on.
//
// Sub-paso 2c.2.a: módulo standalone, no instanciado todavía. El
// sintetizador lo elimina por unused → bitstream funcionalmente idéntico
// al 2b.4. Esto valida solo que el código compila/sintetiza sin romper
// nada.
//
// Fórmula YMF278B (basada en openMSX YMF278.cc::Slot::step):
//   phase_inc = (FNUM[9:0] | (1 << 10)) << OCTAVE
// Donde FNUM es 10-bit y OCTAVE es 4-bit signed (-8..+7) representado
// como bias +0 (raw register value) interpretado como Two's complement.
// Por simplicidad de este sub-paso, OCTAVE se trata como signed sin más
// (los valores negativos hacen shift right). El detalle exacto se afina
// en 2c.2.b cuando se conecte al regfile.
//
// Sample rate efectivo del MangOPL4: CLK_OPL3 / OPL3_PER_SAMPLE = 44.16 kHz
// (-0.04% vs MoonSound real 44.1 kHz, inaudible).
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_phase #(
    parameter int PHASE_WIDTH = 32,
    parameter int PHASE_INT_WIDTH = 16,
    parameter int PHASE_FRAC_WIDTH = 16
) (
    input  wire                          RESET_n,
    input  wire                          CLK,

    // Slot register state (de regfile en sub-pasos posteriores)
    input  wire        [9:0]             fnum,        // FNUM 10-bit
    input  wire signed [3:0]             octave,      // OCTAVE 4-bit signed -8..+7
    input  wire                          key_on,      // 1 = playing, 0 = idle

    // Sample tick: pulso de 1 ciclo CLK a frecuencia sample_rate (44.1 kHz)
    input  wire                          sample_clk_en,

    // Output
    output logic [PHASE_WIDTH-1:0]       phase_acc
);

    // Edge detect de key_on para resetear phase a 0 al iniciar nota nueva.
    logic key_on_prev;

    // FNUM-with-implicit-leading-1 (11-bit). En el YMF278B real, FNUM se
    // trata como mantissa con bit implícito MSB=1 (formato similar a
    // floating-point). Esto da rango de 1024..2047 antes del shift por
    // OCTAVE.
    wire [10:0] fnum_full = {1'b1, fnum};

    // phase_inc calculado combinacionalmente. Para octave>=0, shift left.
    // Para octave<0, shift right. Ancho intermedio amplio para no perder
    // precisión.
    logic [PHASE_WIDTH-1:0] phase_inc;
    always_comb begin
        if (octave >= 0) begin
            phase_inc = {21'b0, fnum_full} << octave;
        end else begin
            phase_inc = {21'b0, fnum_full} >> (-octave);
        end
    end

    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            phase_acc   <= '0;
            key_on_prev <= 1'b0;
        end
        else begin
            key_on_prev <= key_on;
            if (key_on && !key_on_prev) begin
                phase_acc <= '0;            // reset phase en flanco subiente
            end
            else if (sample_clk_en && key_on) begin
                phase_acc <= phase_acc + phase_inc;
            end
        end
    end

endmodule

`default_nettype wire
