//
// ymf278_eg.sv
//
// MangOPL4 Fase 2c.3.h — Envelope Generator (EG) FSM esqueleto.
//
// Estados (3-bit):
//   EG_OFF   = 0   silencio total (level=127)
//   EG_ATT   = 1   attack: level desciende 0x7F → 0 (placeholder en v1)
//   EG_DEC1  = 2   decay 1: level sube 0 → DL
//   EG_DEC2  = 3   decay 2: level sigue subiendo DL → 127 (slow)
//   EG_SUS   = 4   sustain: hold
//   EG_REL   = 5   release: level → 127
//   EG_DAMP  = 6   damp: rampa rápida a silencio antes de key_on
//
// Sub-paso 2c.3.h v1: transiciones INMEDIATAS (sin rate counter, sin
// tablas AR/D1R/D2R/RR). El EG se reduce funcionalmente a:
//   - key_on edge 0→1: salto directo a EG_SUS con level=DL.
//   - key_on edge 1→0: salto directo a EG_OFF con level=127.
//   - states transitorios (ATT/DEC1/DEC2/REL): skip inmediato.
//
// Esto da DL audible: software escribe DL en reg 0x98+slot bits [7:4]
// y eg_level se queda en DL_internal durante el sustain, atenuando el
// audio antes del TL.
//
// 2c.3.i añadirá AR (attack rate) con tabla bit-exact contra openMSX.
// 2c.3.j añadirá D1R/D2R/SUS/REL completos.
//
// Combinacional puro (state_next/level_next se latchean en el pipeline
// stage 6 → stage 7 write a BSRAM).
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_eg
    import ymf278_pkg::*;
(
    // State actual (de BSRAM slot)
    input  wire [2:0]               eg_state_in,
    input  wire [7:0]               eg_level_in,
    input  wire                     key_on,
    input  wire                     key_on_prev,

    // Reg params del slot (en 2c.3.h v1 solo DL se usa)
    input  wire [3:0]               dl,           // reg 0x98+N bits [7:4]

    // Next state (combinacional)
    output logic [2:0]              eg_state_out,
    output logic [7:0]              eg_level_out
);

    localparam logic [2:0] EG_OFF  = 3'd0;
    localparam logic [2:0] EG_ATT  = 3'd1;
    localparam logic [2:0] EG_DEC1 = 3'd2;
    localparam logic [2:0] EG_DEC2 = 3'd3;
    localparam logic [2:0] EG_SUS  = 3'd4;
    localparam logic [2:0] EG_REL  = 3'd5;
    localparam logic [2:0] EG_DAMP = 3'd6;

    // DL_internal: 4-bit DL del reg → 7-bit atten level (compatible con
    // formato TL del exp_lut). dl=0 → 0 (no atten extra), dl=15 → 120
    // (-45 dB extra). Step ~6 dB por unit dl (4× TL granularity).
    // Coherente con openMSX que usa dl<<5 sobre 9-bit, equivalente a
    // dl<<3 sobre 7-bit (similar magnitude).
    wire [7:0] dl_internal = (dl == 4'd15) ? 8'd120 : {1'b0, dl, 3'b000};

    always_comb begin
        // Defaults: hold
        eg_state_out = eg_state_in;
        eg_level_out = eg_level_in;

        if (key_on && !key_on_prev) begin
            // Rising edge: arranca envelope. Salto inmediato a SUS con
            // level=DL (ATT y DEC1/2 instantáneos en v1).
            eg_state_out = EG_SUS;
            eg_level_out = dl_internal;
        end
        else if (!key_on && key_on_prev) begin
            // Falling edge: release inmediato.
            eg_state_out = EG_OFF;
            eg_level_out = 8'd127;
        end
        else begin
            unique case (eg_state_in)
                EG_OFF: begin
                    eg_level_out = 8'd127;        // silencio
                end
                EG_SUS: begin
                    eg_level_out = dl_internal;   // hold en DL
                end
                EG_ATT, EG_DEC1, EG_DEC2, EG_REL, EG_DAMP: begin
                    // Transitorios: skipean inmediato (v1).
                    // Estos casos solo se alcanzan via load inicial de
                    // BSRAM (post-reset son OFF).
                    eg_state_out = EG_OFF;
                    eg_level_out = 8'd127;
                end
                default: begin
                    eg_state_out = EG_OFF;
                    eg_level_out = 8'd127;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
