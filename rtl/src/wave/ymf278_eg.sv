//
// ymf278_eg.sv
//
// MangOPL4 Fase 2c.3.i — Envelope Generator (EG) FSM con state ATT
// real driven por tabla AR (Attack Rate).
//
// Estados:
//   EG_OFF   = 0   silencio total (level=127)
//   EG_ATT   = 1   attack: level desciende 127 → 0 según AR + tabla
//   EG_DEC1  = 2   (placeholder, transición instant a SUS en 2c.3.i)
//   EG_DEC2  = 3   (placeholder)
//   EG_SUS   = 4   sustain: hold en DL
//   EG_REL   = 5   (placeholder, transición instant a OFF en 2c.3.i)
//   EG_DAMP  = 6   (placeholder, 2c.3.k)
//
// Sub-paso 2c.3.i: solo ATT con rate counter real. DEC1/2/REL/DAMP
// se completan en 2c.3.j/k.
//
// ATT behavior:
//   - Rising edge key_on (con ar < 15): EG_ATT, level=127 (silencio),
//     counter=0.
//   - Cada slot_tick: counter++. Si counter & ((1<<shift)-1) == 0 →
//     decrement level por inc (de tabla eg_lut).
//   - Cuando level llega a 0 → EG_SUS con level=DL.
//   - ar=15 → instant attack (skip ATT, salto directo a SUS).
//   - ar=0 → infinitely slow attack (stays at silence).
//
// Counter es 16-bit. Wraps en ~1.5 sec a 44 kHz sample rate.
//
// Nota: el ATT es LINEAR en 2c.3.i (eg_level -= inc). El openMSX usa
// curva exponencial (`eg_vol -= ~eg_vol * inc / 8`). Refinable a
// bit-exact en 2c.3.j+ cuando hagamos DEC también.
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
    input  wire [15:0]              eg_counter_in,
    input  wire                     key_on,
    input  wire                     key_on_prev,

    // Reg params del slot
    input  wire [3:0]               ar,             // reg 0x80+N bits [7:4]
    input  wire [3:0]               dl,             // reg 0x98+N bits [7:4]

    // Next state (combinacional)
    output logic [2:0]              eg_state_out,
    output logic [7:0]              eg_level_out,
    output logic [15:0]             eg_counter_out
);

    localparam logic [2:0] EG_OFF  = 3'd0;
    localparam logic [2:0] EG_ATT  = 3'd1;
    localparam logic [2:0] EG_DEC1 = 3'd2;
    localparam logic [2:0] EG_DEC2 = 3'd3;
    localparam logic [2:0] EG_SUS  = 3'd4;
    localparam logic [2:0] EG_REL  = 3'd5;
    localparam logic [2:0] EG_DAMP = 3'd6;

    wire [7:0] dl_internal = (dl == 4'd15) ? 8'd120 : {1'b0, dl, 3'b000};

    // Rate efectivo. En 2c.3.i sin RC/OCT extras: actual_rate = AR << 2
    // (excepto AR=0 que da rate 0).
    wire [5:0] actual_rate = (ar == 4'd0) ? 6'd0 : {ar, 2'b00};

    // LUT lookup
    wire [3:0] rate_idx, rate_shift;
    wire [15:0] counter_shifted = eg_counter_in >> rate_shift;
    wire [2:0]  step_idx        = counter_shifted[2:0];
    wire [2:0]  inc;
    ymf278_eg_lut u_eg_lut (
        .actual_rate (actual_rate),
        .step_idx    (step_idx),
        .rate_idx    (rate_idx),
        .rate_shift  (rate_shift),
        .inc         (inc)
    );

    // Tick condition: low bits of counter == 0
    wire [15:0] counter_mask = (16'd1 << rate_shift) - 16'd1;
    wire        tick_fires   = (eg_counter_in & counter_mask) == 16'd0;

    // ATT linear decrement
    wire [8:0] level_minus_inc = {1'b0, eg_level_in} - {6'd0, inc};
    wire       level_reaches_zero = level_minus_inc[8] || (eg_level_in <= {5'd0, inc});

    always_comb begin
        // Defaults: hold
        eg_state_out   = eg_state_in;
        eg_level_out   = eg_level_in;
        eg_counter_out = eg_counter_in;

        if (key_on && !key_on_prev) begin
            // Rising edge: start attack
            if (ar == 4'd15) begin
                // Instant attack: skip directo a SUS con level=DL
                eg_state_out = EG_SUS;
                eg_level_out = dl_internal;
            end
            else begin
                eg_state_out = EG_ATT;
                eg_level_out = 8'd127;        // start at silence
            end
            eg_counter_out = 16'd0;
        end
        else if (!key_on && key_on_prev) begin
            // Falling edge: release inmediato
            eg_state_out   = EG_OFF;
            eg_level_out   = 8'd127;
            eg_counter_out = 16'd0;
        end
        else begin
            unique case (eg_state_in)
                EG_OFF: begin
                    eg_level_out = 8'd127;
                end
                EG_ATT: begin
                    // Counter siempre avanza
                    eg_counter_out = eg_counter_in + 16'd1;
                    // Si tick fires y AR != 0, decrement
                    if (tick_fires && (ar != 4'd0)) begin
                        if (level_reaches_zero) begin
                            // Attack completo → SUS con level=DL
                            eg_state_out = EG_SUS;
                            eg_level_out = dl_internal;
                        end
                        else begin
                            eg_level_out = level_minus_inc[7:0];
                        end
                    end
                end
                EG_SUS: begin
                    eg_level_out = dl_internal;
                end
                EG_DEC1, EG_DEC2, EG_REL, EG_DAMP: begin
                    // Placeholders 2c.3.j/k: skipean instant
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
