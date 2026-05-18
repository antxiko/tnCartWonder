//
// ymf278_eg.sv
//
// MangOPL4 Fase 2c.3.j — Envelope Generator (EG) FSM con DADSR completo.
//
// Estados:
//   EG_OFF   = 0   silencio (level=127, hold)
//   EG_ATT   = 1   attack: level desciende 127→0 con AR (linear, refinable)
//   EG_DEC1  = 2   decay 1: level sube 0→DL con D1R
//   EG_DEC2  = 3   decay 2: level sube DL→127 con D2R (sustain natural)
//   EG_SUS   = 4   (alias estado: openMSX usa DEC2 continuo; reservado)
//   EG_REL   = 5   release: level sube actual→127 con RR. Después EG_OFF.
//   EG_DAMP  = 6   placeholder (2c.3.k)
//
// Sub-paso 2c.3.j: DEC1/DEC2/REL con rate tables. Ningun parámetro RC/
// OCT extras (2c.3.k). ATT sigue linear.
//
// Convención de eg_level (formato atenuación log-like, 8-bit):
//   0   = max volume (no atten)
//   127 = silence (max atten)
// ATT desciende (de silencio hacia max), DEC/REL ascienden (max hacia silence).
//
// Behavior:
//   - key_on rising:
//       AR=15 → instant attack (= no att), salto a DEC1 con level=0.
//       AR=0  → stays in EG_ATT silencio forever.
//       sino  → EG_ATT con level=127, counter=0.
//   - key_on falling (cualquier state activo):
//       → EG_REL con counter=0. eg_level se mantiene como estaba.
//         (release ramps FROM current level UP to 127).
//   - ATT done → EG_DEC1 con counter=0.
//   - DEC1 al alcanzar DL → EG_DEC2.
//   - DEC2 al alcanzar 127 → EG_OFF.
//   - REL al alcanzar 127 → EG_OFF.
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
    input  wire [3:0]               d1r,            // reg 0x80+N bits [3:0]
    input  wire [3:0]               dl,             // reg 0x98+N bits [7:4]
    input  wire [3:0]               d2r,            // reg 0x98+N bits [3:0]
    input  wire [3:0]               rr,             // reg 0xB0+N bits [3:0]

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

    // Selección de rate según estado actual.
    logic [3:0] active_rate_reg;
    always_comb begin
        unique case (eg_state_in)
            EG_ATT:  active_rate_reg = ar;
            EG_DEC1: active_rate_reg = d1r;
            EG_DEC2: active_rate_reg = d2r;
            EG_REL:  active_rate_reg = rr;
            default: active_rate_reg = 4'd0;
        endcase
    end
    wire [5:0] actual_rate = (active_rate_reg == 4'd0) ? 6'd0 : {active_rate_reg, 2'b00};

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

    // ATT (descending): level -= inc.
    wire [8:0] att_minus       = {1'b0, eg_level_in} - {6'd0, inc};
    wire       att_at_zero     = att_minus[8] || (eg_level_in <= {5'd0, inc});

    // DEC/REL (ascending): level += inc, saturate at 127.
    wire [8:0] dec_plus        = {1'b0, eg_level_in} + {6'd0, inc};
    wire [7:0] dec_plus_satd   = (dec_plus > 9'd127) ? 8'd127 : dec_plus[7:0];
    wire       dec_at_dl       = dec_plus_satd >= dl_internal;
    wire       dec_at_127      = dec_plus_satd == 8'd127;

    always_comb begin
        // Defaults: hold
        eg_state_out   = eg_state_in;
        eg_level_out   = eg_level_in;
        eg_counter_out = eg_counter_in;

        if (key_on && !key_on_prev) begin
            // Rising edge: arranca attack.
            if (ar == 4'd15) begin
                // Instant attack: skip directo a DEC1 con level=0.
                eg_state_out = EG_DEC1;
                eg_level_out = 8'd0;
            end
            else begin
                eg_state_out = EG_ATT;
                eg_level_out = 8'd127;       // start at silence
            end
            eg_counter_out = 16'd0;
        end
        else if (!key_on && key_on_prev) begin
            // Falling edge: arranca release. eg_level se mantiene
            // como estaba, RR lo subirá a 127.
            eg_state_out   = EG_REL;
            eg_counter_out = 16'd0;
        end
        else begin
            unique case (eg_state_in)
                EG_OFF: begin
                    eg_level_out = 8'd127;
                end

                EG_ATT: begin
                    eg_counter_out = eg_counter_in + 16'd1;
                    if (tick_fires && (ar != 4'd0)) begin
                        if (att_at_zero) begin
                            // Attack completo → DEC1
                            eg_state_out   = EG_DEC1;
                            eg_level_out   = 8'd0;
                            eg_counter_out = 16'd0;
                        end
                        else begin
                            eg_level_out = att_minus[7:0];
                        end
                    end
                end

                EG_DEC1: begin
                    eg_counter_out = eg_counter_in + 16'd1;
                    if (tick_fires && (d1r != 4'd0)) begin
                        if (dec_at_dl) begin
                            eg_state_out   = EG_DEC2;
                            eg_level_out   = dl_internal;
                            eg_counter_out = 16'd0;
                        end
                        else begin
                            eg_level_out = dec_plus_satd;
                        end
                    end
                end

                EG_DEC2: begin
                    eg_counter_out = eg_counter_in + 16'd1;
                    if (tick_fires && (d2r != 4'd0)) begin
                        if (dec_at_127) begin
                            // Decay 2 alcanzó silencio total → OFF.
                            eg_state_out   = EG_OFF;
                            eg_level_out   = 8'd127;
                            eg_counter_out = 16'd0;
                        end
                        else begin
                            eg_level_out = dec_plus_satd;
                        end
                    end
                end

                EG_REL: begin
                    eg_counter_out = eg_counter_in + 16'd1;
                    if (tick_fires && (rr != 4'd0)) begin
                        if (dec_at_127) begin
                            eg_state_out   = EG_OFF;
                            eg_level_out   = 8'd127;
                            eg_counter_out = 16'd0;
                        end
                        else begin
                            eg_level_out = dec_plus_satd;
                        end
                    end
                    else if (rr == 4'd0) begin
                        // RR=0: release infinito (hold actual)
                    end
                end

                EG_SUS: begin
                    // Compat con residual BSRAM o software que ponga
                    // explicit EG_SUS. YMF278B real no transiciona aquí
                    // (DEC2 actúa como sustain natural), pero si llegamos
                    // mantenemos el level actual (no silenciamos).
                    eg_level_out = eg_level_in;
                end

                EG_DAMP: begin
                    // Placeholder 2c.3.k: DAMP rápido a silencio. En
                    // 2c.3.j tratamos como hold defensive.
                    eg_level_out = eg_level_in;
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
