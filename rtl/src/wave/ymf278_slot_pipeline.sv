//
// ymf278_slot_pipeline.sv
//
// MangOPL4 Fase 2c.3.b — pipeline de 8 stages para procesar 1 slot
// del motor Wave del YMF278B con state en BSRAM externa.
//
// Sub-paso 2c.3.b: slot_idx hardcoded a 0 desde fuera. Solo los stages
// 0, 1, 2 y 7 hacen trabajo real; stages 3-6 son placeholders para
// fetch / interp / EG / mix que se añadirán en sub-pasos siguientes.
//
// Pipeline (arranca cada sample_tick = pulse 1-cycle a 44.1 kHz):
//   Stage 0: emit state_read_addr = slot_idx. La BSRAM responde en
//            stage 1 (latencia 1 ciclo del SSRAM/BSRAM síncrono).
//   Stage 1: latch state_read_data en state_buffer.
//   Stage 2: calcular new_phase_acc con edge-detect key_on
//            (key_on 0→1 → reset a 0; key_on=1 + sample_tick → +phase_inc;
//             key_on=0 → hold). Actualizar key_on_prev_reg.
//   Stages 3..6: idle (placeholders para fetch trigger, interp, EG, atten).
//   Stage 7: emit state_write_addr/data/en para escribir el state actualizado.
//
// phase_acc_out se actualiza al final del stage 2 y se mantiene estable
// hasta el próximo sample_tick. fetch1 y interp (externos) lo usan igual
// que cuando se usaba ymf278_phase directamente.
//
// Patrón anti-Gowin CE-style FF: TODOS los FFs tienen D-input como mux
// combinacional completo, sin `else if (modport_signal)`. Las señales
// internas (stage_counter, pipeline_active) son FF locales, no modport,
// pero aplico el mismo patrón por defensiva (regla
// feedback_gowin_ce_ff.md).
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_slot_pipeline
    import ymf278_pkg::*;
(
    input  wire                              RESET_n,
    input  wire                              CLK,

    // Sample tick: pulse 1-cycle CLK a 44.1 kHz
    input  wire                              sample_tick,

    // Slot index (en 2c.3.b siempre 0, parametrizable en 2c.3.c+)
    input  wire [STATE_ADDR_BITS-1:0]        slot_idx,

    // Reg state del slot indexado (mux 24:1 fuera del módulo)
    input  wire [9:0]                        fnum,
    input  wire signed [3:0]                 octave,
    input  wire                              key_on,

    // State file external (BSRAM dual-port)
    output logic [STATE_ADDR_BITS-1:0]       state_read_addr,
    input  wire  [STATE_BITS_PER_SLOT-1:0]   state_read_data,
    output logic [STATE_ADDR_BITS-1:0]       state_write_addr,
    output logic [STATE_BITS_PER_SLOT-1:0]   state_write_data,
    output logic                             state_write_en,

    // Phase accumulator expuesto para fetch1 / interp (estable entre ticks)
    output logic [PHASE_WIDTH-1:0]           phase_acc_out
);

    /***************************************************************
     * FFs internos del pipeline
     ***************************************************************/
    logic [2:0]                          stage_counter;
    logic                                pipeline_active;
    logic [STATE_BITS_PER_SLOT-1:0]      state_buffer;
    logic [PHASE_WIDTH-1:0]              phase_acc_reg;
    logic                                key_on_prev_reg;

    /***************************************************************
     * phase_inc combinacional (idéntico a ymf278_phase original)
     ***************************************************************/
    wire [10:0] fnum_full = {1'b1, fnum};
    logic [PHASE_WIDTH-1:0] phase_inc;
    always_comb begin
        if (octave >= 0) phase_inc = {21'b0, fnum_full} << octave;
        else             phase_inc = {21'b0, fnum_full} >> (-octave);
    end

    /***************************************************************
     * Next-state combinacional
     ***************************************************************/
    logic [2:0]                          next_stage_counter;
    logic                                next_pipeline_active;
    logic [STATE_BITS_PER_SLOT-1:0]      next_state_buffer;
    logic [PHASE_WIDTH-1:0]              next_phase_acc_reg;
    logic                                next_key_on_prev_reg;

    always_comb begin
        // Defaults: hold actual
        next_stage_counter   = stage_counter;
        next_pipeline_active = pipeline_active;
        next_state_buffer    = state_buffer;
        next_phase_acc_reg   = phase_acc_reg;
        next_key_on_prev_reg = key_on_prev_reg;

        // Control del pipeline: sample_tick arranca, stage 7 termina
        if (sample_tick) begin
            next_stage_counter   = 3'd0;
            next_pipeline_active = 1'b1;
        end
        else if (pipeline_active) begin
            if (stage_counter == 3'd7) begin
                next_pipeline_active = 1'b0;
            end
            else begin
                next_stage_counter = stage_counter + 3'd1;
            end
        end

        // Stage 1: latch state_read_data
        if (pipeline_active && (stage_counter == 3'd1)) begin
            next_state_buffer = state_read_data;
        end

        // Stage 2: calcular new phase_acc + key_on_prev
        if (pipeline_active && (stage_counter == 3'd2)) begin
            if (key_on && !state_buffer[64]) begin
                next_phase_acc_reg = '0;                                    // edge: reset
            end
            else if (key_on) begin
                next_phase_acc_reg = state_buffer[31:0] + phase_inc;        // tick: advance
            end
            else begin
                next_phase_acc_reg = state_buffer[31:0];                    // hold
            end
            next_key_on_prev_reg = key_on;
        end
    end

    /***************************************************************
     * FFs registran next-state (anti-Gowin CE)
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            stage_counter   <= 3'd0;
            pipeline_active <= 1'b0;
            state_buffer    <= '0;
            phase_acc_reg   <= '0;
            key_on_prev_reg <= 1'b0;
        end
        else begin
            stage_counter   <= next_stage_counter;
            pipeline_active <= next_pipeline_active;
            state_buffer    <= next_state_buffer;
            phase_acc_reg   <= next_phase_acc_reg;
            key_on_prev_reg <= next_key_on_prev_reg;
        end
    end

    /***************************************************************
     * Outputs combinacionales
     ***************************************************************/
    assign state_read_addr  = slot_idx;
    assign state_write_addr = slot_idx;
    assign state_write_data = {
        {(STATE_BITS_PER_SLOT-65){1'b0}},   // [127:65] reserved (EG en 2c.3.h)
        key_on_prev_reg,                     // [64]
        8'h00,                               // [63:56] byte_b (placeholder)
        8'h00,                               // [55:48] byte_a (placeholder)
        16'h0000,                            // [47:32] last_idx_fetched (placeholder)
        phase_acc_reg                        // [31:0]
    };
    assign state_write_en   = pipeline_active && (stage_counter == 3'd7);

    assign phase_acc_out    = phase_acc_reg;

endmodule

`default_nettype wire
