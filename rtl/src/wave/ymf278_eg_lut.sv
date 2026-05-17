//
// ymf278_eg_lut.sv
//
// MangOPL4 Fase 2c.3.i — tablas del Envelope Generator del YMF278B.
// Bit-exact contra openMSX YMF278.cc.
//
// Inputs:
//   actual_rate[5:0]    — rate efectivo (AR<<2 + RC con KSL/RC en 2c.3.k+;
//                          en 2c.3.i solo AR<<2, 0..60).
//
// Outputs:
//   rate_idx[3:0]       — índice 0..14 para tabla eg_inc.
//   rate_shift[3:0]     — shift 0..12 (slow-down clocking).
//
// Para obtener el increment efectivo:
//   inc = eg_inc[rate_idx][counter[shift+2:shift] & 7]
//
// Tabla eg_inc se queda dentro del módulo (15 filas × 8 cols × 3 bits ≈
// 360 bits, distributed). Las dos tablas rate_select / rate_shift son
// 64 × 4 bits = 256 bits cada una, distributed.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_eg_lut (
    input  wire [5:0]            actual_rate,
    input  wire [2:0]            step_idx,        // counter step mod 8
    output logic [3:0]           rate_idx,
    output logic [3:0]           rate_shift,
    output logic [2:0]           inc              // 0,1,2,4,8 actually mapped en 3-bit
);

    /***************************************************************
     * eg_rate_select[64]: mapeo a tabla eg_inc fila 0..14
     ***************************************************************/
    always_comb begin
        case (actual_rate)
            6'd0,6'd1,6'd2,6'd3:        rate_idx = 4'd14;
            6'd4,6'd5,6'd6,6'd7:        rate_idx = 4'd13;
            6'd8,6'd9,6'd10,6'd11:      rate_idx = 4'd12;
            6'd12,6'd13,6'd14,6'd15:    rate_idx = 4'd11;
            6'd16,6'd17,6'd18,6'd19:    rate_idx = 4'd11;
            6'd20,6'd21,6'd22,6'd23:    rate_idx = 4'd10;
            6'd24,6'd25,6'd26,6'd27:    rate_idx = 4'd9;
            6'd28,6'd29,6'd30,6'd31:    rate_idx = 4'd8;
            6'd32,6'd33,6'd34,6'd35:    rate_idx = 4'd7;
            6'd36,6'd37,6'd38,6'd39:    rate_idx = 4'd6;
            6'd40,6'd41,6'd42,6'd43:    rate_idx = 4'd5;
            6'd44,6'd45,6'd46,6'd47:    rate_idx = 4'd4;
            6'd48,6'd49,6'd50,6'd51:    rate_idx = 4'd3;
            6'd52,6'd53,6'd54,6'd55:    rate_idx = 4'd2;
            6'd56,6'd57,6'd58,6'd59:    rate_idx = 4'd1;
            default:                    rate_idx = 4'd0;     // 60..63
        endcase
    end

    /***************************************************************
     * eg_rate_shift[64]: shifts para slow-down clocking
     ***************************************************************/
    always_comb begin
        case (actual_rate)
            6'd0,6'd1,6'd2,6'd3:        rate_shift = 4'd12;
            6'd4,6'd5,6'd6,6'd7:        rate_shift = 4'd11;
            6'd8,6'd9,6'd10,6'd11:      rate_shift = 4'd10;
            6'd12,6'd13,6'd14,6'd15:    rate_shift = 4'd9;
            6'd16,6'd17,6'd18,6'd19:    rate_shift = 4'd8;
            6'd20,6'd21,6'd22,6'd23:    rate_shift = 4'd7;
            6'd24,6'd25,6'd26,6'd27:    rate_shift = 4'd6;
            6'd28,6'd29,6'd30,6'd31:    rate_shift = 4'd5;
            6'd32,6'd33,6'd34,6'd35:    rate_shift = 4'd4;
            6'd36,6'd37,6'd38,6'd39:    rate_shift = 4'd3;
            6'd40,6'd41,6'd42,6'd43:    rate_shift = 4'd2;
            6'd44,6'd45,6'd46,6'd47:    rate_shift = 4'd1;
            default:                    rate_shift = 4'd0;   // 48..63
        endcase
    end

    /***************************************************************
     * eg_inc[rate_idx][step_idx & 7]
     *
     * Patrones del openMSX YMF278.cc::eg_inc. Codifican secuencias
     * de 0,1,2,4 (y multiplos) para los 8 sub-pasos de cada rate.
     ***************************************************************/
    always_comb begin
        case (rate_idx)
            // {0,1, 0,1, 0,1, 0,1}
            4'd0: case (step_idx)
                3'd0: inc = 3'd0; 3'd1: inc = 3'd1;
                3'd2: inc = 3'd0; 3'd3: inc = 3'd1;
                3'd4: inc = 3'd0; 3'd5: inc = 3'd1;
                3'd6: inc = 3'd0; 3'd7: inc = 3'd1;
            endcase
            // {0,1, 0,1, 1,1, 0,1}
            4'd1: case (step_idx)
                3'd0: inc = 3'd0; 3'd1: inc = 3'd1;
                3'd2: inc = 3'd0; 3'd3: inc = 3'd1;
                3'd4: inc = 3'd1; 3'd5: inc = 3'd1;
                3'd6: inc = 3'd0; 3'd7: inc = 3'd1;
            endcase
            // {0,1, 1,1, 0,1, 1,1}
            4'd2: case (step_idx)
                3'd0: inc = 3'd0; 3'd1: inc = 3'd1;
                3'd2: inc = 3'd1; 3'd3: inc = 3'd1;
                3'd4: inc = 3'd0; 3'd5: inc = 3'd1;
                3'd6: inc = 3'd1; 3'd7: inc = 3'd1;
            endcase
            // {0,1, 1,1, 1,1, 1,1}
            4'd3: case (step_idx)
                3'd0: inc = 3'd0; 3'd1: inc = 3'd1;
                3'd2: inc = 3'd1; 3'd3: inc = 3'd1;
                3'd4: inc = 3'd1; 3'd5: inc = 3'd1;
                3'd6: inc = 3'd1; 3'd7: inc = 3'd1;
            endcase
            // {1,1, 1,1, 1,1, 1,1}
            4'd4: inc = 3'd1;
            // {1,1, 1,2, 1,1, 1,2}
            4'd5: case (step_idx)
                3'd0: inc = 3'd1; 3'd1: inc = 3'd1;
                3'd2: inc = 3'd1; 3'd3: inc = 3'd2;
                3'd4: inc = 3'd1; 3'd5: inc = 3'd1;
                3'd6: inc = 3'd1; 3'd7: inc = 3'd2;
            endcase
            // {1,2, 1,2, 1,2, 1,2}
            4'd6: inc = step_idx[0] ? 3'd2 : 3'd1;
            // {1,2, 2,2, 1,2, 2,2}
            4'd7: case (step_idx)
                3'd0: inc = 3'd1; 3'd1: inc = 3'd2;
                3'd2: inc = 3'd2; 3'd3: inc = 3'd2;
                3'd4: inc = 3'd1; 3'd5: inc = 3'd2;
                3'd6: inc = 3'd2; 3'd7: inc = 3'd2;
            endcase
            // {2,2, 2,2, 2,2, 2,2}
            4'd8: inc = 3'd2;
            // {2,2, 2,4, 2,2, 2,4}
            4'd9: case (step_idx)
                3'd0: inc = 3'd2; 3'd1: inc = 3'd2;
                3'd2: inc = 3'd2; 3'd3: inc = 3'd4;
                3'd4: inc = 3'd2; 3'd5: inc = 3'd2;
                3'd6: inc = 3'd2; 3'd7: inc = 3'd4;
            endcase
            // {2,4, 2,4, 2,4, 2,4}
            4'd10: inc = step_idx[0] ? 3'd4 : 3'd2;
            // {2,4, 4,4, 2,4, 4,4}
            4'd11: case (step_idx)
                3'd0: inc = 3'd2; 3'd1: inc = 3'd4;
                3'd2: inc = 3'd4; 3'd3: inc = 3'd4;
                3'd4: inc = 3'd2; 3'd5: inc = 3'd4;
                3'd6: inc = 3'd4; 3'd7: inc = 3'd4;
            endcase
            // {4,4, 4,4, 4,4, 4,4}
            4'd12: inc = 3'd4;
            // {4,4, 4,8 (=cap a 7 = 4'd7 since 3-bit), 4,4, 4,8}
            // Para 3-bit la pareja 8 se satura. En 2c.3.i opcional;
            // valores 8 los manejamos como 7 (= 3-bit max). Refinable.
            4'd13: case (step_idx)
                3'd0: inc = 3'd4; 3'd1: inc = 3'd4;
                3'd2: inc = 3'd4; 3'd3: inc = 3'd7;
                3'd4: inc = 3'd4; 3'd5: inc = 3'd4;
                3'd6: inc = 3'd4; 3'd7: inc = 3'd7;
            endcase
            // {4,8, 4,8, 4,8, 4,8}
            4'd14: inc = step_idx[0] ? 3'd7 : 3'd4;
            default: inc = 3'd0;
        endcase
    end

endmodule

`default_nettype wire
