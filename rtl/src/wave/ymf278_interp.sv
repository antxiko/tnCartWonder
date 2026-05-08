//
// ymf278_interp.sv
//
// MangOPL4 Fase 2c.2.e — interpolación lineal entre dos samples
// consecutivos para reproducción del YMF278B.
//
// Fórmula: out = sample_a + ((sample_b - sample_a) * frac) >> 16
//          (lerp clásico, frac es 16-bit unsigned tratado como 0.16)
//
// 1 DSP signed 17×17 → 33-bit, shift right 16 → 17-bit, add a 16-bit.
// Latencia: combinacional (Gowin permite multiplicar combinacional con
// 1 DSP).
//
// Sub-paso 2c.2.e.1: módulo standalone, no instanciado todavía. El
// sintetizador lo elimina por sweep → bitstream funcionalmente
// idéntico al 2c.2.d.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_interp (
    input  wire signed [15:0] sample_a,    // sample N
    input  wire signed [15:0] sample_b,    // sample N+1
    input  wire        [15:0] frac,        // 0.16 unsigned: 0=all_a, 0xFFFF≈all_b
    output wire signed [15:0] out
);

    // delta = sample_b - sample_a, 17-bit signed
    wire signed [16:0] delta = $signed({sample_b[15], sample_b}) -
                               $signed({sample_a[15], sample_a});

    // frac como signed 17-bit (MSB=0 → siempre positivo)
    wire signed [16:0] frac_s = $signed({1'b0, frac});

    // delta * frac_s = 34-bit signed (17×17→34)
    wire signed [33:0] mul = delta * frac_s;

    // shift right 16 → escala a 18-bit signed
    wire signed [17:0] mul_shifted = mul[33:16];

    // Suma con sample_a (extendido) y satura a 16-bit
    wire signed [17:0] sum = $signed({{2{sample_a[15]}}, sample_a}) + mul_shifted;

    // Saturate a 16-bit
    assign out = (sum > 18'sd32767)  ? 16'sd32767  :
                 (sum < -18'sd32768) ? -16'sd32768 :
                                        sum[15:0];

endmodule

`default_nettype wire
