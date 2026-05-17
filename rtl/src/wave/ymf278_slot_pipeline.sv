//
// ymf278_slot_pipeline.sv
//
// MangOPL4 Fase 2c.3 — pipeline 8-stage time-shared para N slots del
// motor Wave del YMF278B con state en BSRAM externa.
//
// Parameter ACTIVE_SLOTS controla cuántos slots time-shared se procesan
// por cada sample_tick:
//   2c.3.b: ACTIVE_SLOTS=1
//   2c.3.c: ACTIVE_SLOTS=2
//   2c.3.f: ACTIVE_SLOTS=24
//
// Pipeline (arranca cada sample_tick, se ejecuta ACTIVE_SLOTS veces):
//   Stage 0: emit state_read_addr = current_slot.
//   Stage 1: latch state_read_data en state_buffer.
//   Stage 2: calcular new_phase_acc con edge-detect key_on. Snapshot
//            phase_acc_slot0 si current_slot=0.
//   Stage 3: idle (placeholder fetch dispatch).
//   Stage 4: idle (placeholder fetch wait).
//   Stage 5: latch sample_buffer = slot_sample_in (= interp_out si
//            current_slot=0, else 0; muxado en ymf278_top).
//   Stage 6: invocar ymf278_eg (combinacional) para advance EG state.
//            Compute atten_total = sat(TL + (new_eg_level >> 1)) →
//            scale = exp_lut[atten_total]. Multiplicar
//            slot_atten = sat(sample_buffer × scale >>> 16) (1 DSP).
//            Snapshot slot0_atten si current_slot=0.
//   Stage 7: emit state_write_en con state actualizado (phase_acc,
//            key_on_prev, eg_state, eg_level).
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_slot_pipeline
    import ymf278_pkg::*;
#(
    parameter int ACTIVE_SLOTS = 1
) (
    input  wire                              RESET_n,
    input  wire                              CLK,

    // Sample tick: pulse 1-cycle CLK a 44.1 kHz
    input  wire                              sample_tick,

    // Slot index activo (output a ymf278_top para mux externo de regs)
    output logic [STATE_ADDR_BITS-1:0]       current_slot,

    // Reg state del slot activo (ymf278_top muxea por current_slot)
    input  wire [9:0]                        fnum,
    input  wire signed [3:0]                 octave,
    input  wire                              key_on,
    input  wire [6:0]                        tl,             // 2c.3.h
    input  wire [3:0]                        dl,             // 2c.3.h
    input  wire signed [15:0]                slot_sample_in, // 2c.3.h

    // State file external (BSRAM dual-port)
    output logic [STATE_ADDR_BITS-1:0]       state_read_addr,
    input  wire  [STATE_BITS_PER_SLOT-1:0]   state_read_data,
    output logic [STATE_ADDR_BITS-1:0]       state_write_addr,
    output logic [STATE_BITS_PER_SLOT-1:0]   state_write_data,
    output logic                             state_write_en,

    // Phase accumulator del slot 0 (snapshot para fetch1 / interp externos)
    output logic [PHASE_WIDTH-1:0]           phase_acc_out_slot0,

    // 2c.3.h: salida atenuada del slot 0 (sample × exp_lut[TL+eg_level])
    output logic signed [15:0]               slot0_atten_out
);

    /***************************************************************
     * FFs internos del pipeline
     ***************************************************************/
    logic [2:0]                          stage_counter;
    logic                                pipeline_active;
    logic [STATE_BITS_PER_SLOT-1:0]      state_buffer;
    logic [PHASE_WIDTH-1:0]              phase_acc_slot0_snapshot;
    logic signed [15:0]                  sample_buffer;
    logic signed [15:0]                  slot0_atten_snapshot;

    /***************************************************************
     * phase_inc combinacional
     ***************************************************************/
    wire [10:0] fnum_full = {1'b1, fnum};
    logic [PHASE_WIDTH-1:0] phase_inc;
    always_comb begin
        if (octave >= 0) phase_inc = {21'b0, fnum_full} << octave;
        else             phase_inc = {21'b0, fnum_full} >> (-octave);
    end

    /***************************************************************
     * State buffer field accessors (legibilidad)
     ***************************************************************/
    wire [PHASE_WIDTH-1:0] state_phase_acc   = state_buffer[31:0];
    wire                   state_key_on_prev = state_buffer[64];
    wire [16:0]            state_eg_level    = state_buffer[81:65];
    wire [2:0]             state_eg_state    = state_buffer[84:82];

    /***************************************************************
     * Stage 2 compute: new phase_acc + new key_on_prev (combinacional)
     ***************************************************************/
    logic [PHASE_WIDTH-1:0] new_phase_acc;
    logic                   new_key_on_prev;
    always_comb begin
        if (key_on && !state_key_on_prev) begin
            new_phase_acc = '0;
        end
        else if (key_on) begin
            new_phase_acc = state_phase_acc + phase_inc;
        end
        else begin
            new_phase_acc = state_phase_acc;
        end
        new_key_on_prev = key_on;
    end

    /***************************************************************
     * Stage 6: EG advance + atenuación combinacional.
     *
     * EG FSM combinacional. Solo usa los 8 bits LSB de eg_level (los
     * 17 bits totales del state están reservados para 2c.3.i+).
     ***************************************************************/
    logic [2:0]    new_eg_state;
    logic [7:0]    new_eg_level;
    ymf278_eg u_eg (
        .eg_state_in  (state_eg_state),
        .eg_level_in  (state_eg_level[7:0]),
        .key_on       (key_on),
        .key_on_prev  (state_key_on_prev),
        .dl           (dl),
        .eg_state_out (new_eg_state),
        .eg_level_out (new_eg_level)
    );

    // atten_total = TL + (eg_level >> 1). eg_level es 8-bit, shift 1
    // mantiene granularidad similar al TL 7-bit. Saturar a 127.
    wire [7:0] atten_sum = {1'b0, tl} + {1'b0, new_eg_level[7:1]};
    wire [6:0] atten_total = (atten_sum > 8'd127) ? 7'd127 : atten_sum[6:0];

    wire [15:0] atten_scale;
    ymf278_exp_lut u_exp_lut (
        .tl    (atten_total),
        .scale (atten_scale)
    );

    // Multiplicación signed 17×17 → 34-bit, shift right 16, satura.
    wire signed [16:0] sample_s17     = $signed({sample_buffer[15], sample_buffer});
    wire signed [16:0] scale_s17      = $signed({1'b0, atten_scale});
    wire signed [33:0] atten_mul      = sample_s17 * scale_s17;
    wire signed [17:0] atten_mul_shft = atten_mul[33:16];
    wire signed [15:0] slot_atten_combo =
        (atten_mul_shft > 18'sd32767)   ? 16'sd32767  :
        (atten_mul_shft < -18'sd32768)  ? -16'sd32768 :
                                          atten_mul_shft[15:0];

    /***************************************************************
     * Next-state combinacional (anti-Gowin CE)
     ***************************************************************/
    logic [2:0]                          next_stage_counter;
    logic                                next_pipeline_active;
    logic [STATE_ADDR_BITS-1:0]          next_current_slot;
    logic [STATE_BITS_PER_SLOT-1:0]      next_state_buffer;
    logic [PHASE_WIDTH-1:0]              next_phase_acc_slot0_snapshot;
    logic signed [15:0]                  next_sample_buffer;
    logic signed [15:0]                  next_slot0_atten_snapshot;

    always_comb begin
        // Defaults: hold
        next_stage_counter             = stage_counter;
        next_pipeline_active           = pipeline_active;
        next_current_slot              = current_slot;
        next_state_buffer              = state_buffer;
        next_phase_acc_slot0_snapshot  = phase_acc_slot0_snapshot;
        next_sample_buffer             = sample_buffer;
        next_slot0_atten_snapshot      = slot0_atten_snapshot;

        // Control: sample_tick arranca, stage 7 avanza o termina
        if (sample_tick) begin
            next_pipeline_active = 1'b1;
            next_stage_counter   = 3'd0;
            next_current_slot    = '0;
        end
        else if (pipeline_active) begin
            if (stage_counter == 3'd7) begin
                if (current_slot < (ACTIVE_SLOTS - 1)) begin
                    next_current_slot  = current_slot + 1'd1;
                    next_stage_counter = 3'd0;
                end
                else begin
                    next_pipeline_active = 1'b0;
                    next_current_slot    = '0;   // idle vuelve a slot 0
                end
            end
            else begin
                next_stage_counter = stage_counter + 3'd1;
            end
        end

        // Stage 1: latch state_read_data
        if (pipeline_active && (stage_counter == 3'd1)) begin
            next_state_buffer = state_read_data;
        end

        // Stage 2 snapshot slot 0 phase_acc
        if (pipeline_active && (stage_counter == 3'd2) && (current_slot == '0)) begin
            next_phase_acc_slot0_snapshot = new_phase_acc;
        end

        // Stage 5: latch sample_buffer
        if (pipeline_active && (stage_counter == 3'd5)) begin
            next_sample_buffer = slot_sample_in;
        end

        // Stage 6: latch slot0_atten_snapshot (slot 0 only)
        if (pipeline_active && (stage_counter == 3'd6) && (current_slot == '0)) begin
            next_slot0_atten_snapshot = slot_atten_combo;
        end
    end

    /***************************************************************
     * FFs registran next-state
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            stage_counter            <= 3'd0;
            pipeline_active          <= 1'b0;
            current_slot             <= '0;
            state_buffer             <= '0;
            phase_acc_slot0_snapshot <= '0;
            sample_buffer            <= '0;
            slot0_atten_snapshot     <= '0;
        end
        else begin
            stage_counter            <= next_stage_counter;
            pipeline_active          <= next_pipeline_active;
            current_slot             <= next_current_slot;
            state_buffer             <= next_state_buffer;
            phase_acc_slot0_snapshot <= next_phase_acc_slot0_snapshot;
            sample_buffer            <= next_sample_buffer;
            slot0_atten_snapshot     <= next_slot0_atten_snapshot;
        end
    end

    /***************************************************************
     * Outputs combinacionales
     ***************************************************************/
    assign state_read_addr  = current_slot;
    assign state_write_addr = current_slot;
    assign state_write_data = {
        {(STATE_BITS_PER_SLOT-85){1'b0}},                       // [127:85] reservado
        new_eg_state,                                            // [84:82]
        {{9{1'b0}}, new_eg_level},                               // [81:65] eg_level (17 bits, top 9 a 0)
        new_key_on_prev,                                         // [64]
        8'h00,                                                   // [63:56] byte_b (placeholder)
        8'h00,                                                   // [55:48] byte_a (placeholder)
        16'h0000,                                                // [47:32] last_idx_fetched (placeholder)
        new_phase_acc                                            // [31:0]
    };
    assign state_write_en   = pipeline_active && (stage_counter == 3'd7);

    assign phase_acc_out_slot0 = phase_acc_slot0_snapshot;
    assign slot0_atten_out     = slot0_atten_snapshot;

endmodule

`default_nettype wire
