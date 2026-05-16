//
// ymf278_slot_pipeline.sv
//
// MangOPL4 Fase 2c.3 — pipeline 8-stage time-shared para N slots del
// motor Wave del YMF278B con state en BSRAM externa.
//
// Parameter ACTIVE_SLOTS controla cuántos slots time-shared se procesan
// por cada sample_tick:
//   2c.3.b: ACTIVE_SLOTS=1 (slot 0 solo)
//   2c.3.c: ACTIVE_SLOTS=2 (slots 0, 1)
//   2c.3.d: ACTIVE_SLOTS=4
//   2c.3.e: ACTIVE_SLOTS=8
//   2c.3.f: ACTIVE_SLOTS=24 (todos)
//
// Cada slot consume 8 ciclos CLK (stages 0..7) back-to-back. Tras
// procesar ACTIVE_SLOTS slots, el pipeline queda idle hasta el próximo
// sample_tick. Con CLK_OPL3 33.5 MHz y SAMPLE_TICK_DIV=760, hay 760
// ciclos por sample period; 24 slots × 8 stages = 192 ciclos → 4x
// holgura. NB: en MangOPL4, CLK = 107.4 MHz (no CLK_OPL3); aún más
// holgura.
//
// Pipeline (arranca cada sample_tick, se ejecuta ACTIVE_SLOTS veces):
//   Stage 0: emit state_read_addr = current_slot.
//   Stage 1: latch state_read_data en state_buffer.
//   Stage 2: calcular new_phase_acc con edge-detect key_on. También
//            snapshot phase_acc_slot0 si current_slot=0 (para
//            consumidores externos como fetch1 que ven solo slot 0).
//   Stages 3..6: idle (placeholders para fetch / interp / EG en sub-pasos).
//   Stage 7: emit state_write_en con state actualizado.
//
// Tras stage 7 de un slot:
//   - Si current_slot < ACTIVE_SLOTS-1: incrementa current_slot, reinicia
//     stage_counter=0 (back-to-back).
//   - Sino: pipeline_active=0 (idle).
//
// El mux externo (ymf278_top) usa current_slot para seleccionar las
// regs FNUM/OCT/KEY_ON del slot activo cycle by cycle.
//
// Patrón anti-Gowin CE FF: TODOS los FFs internos usan D-input como
// mux combinacional completo. Sin `else if (modport_signal)`.
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

    // State file external (BSRAM dual-port)
    output logic [STATE_ADDR_BITS-1:0]       state_read_addr,
    input  wire  [STATE_BITS_PER_SLOT-1:0]   state_read_data,
    output logic [STATE_ADDR_BITS-1:0]       state_write_addr,
    output logic [STATE_BITS_PER_SLOT-1:0]   state_write_data,
    output logic                             state_write_en,

    // Phase accumulator del slot 0 (snapshot para fetch1 / interp externos)
    output logic [PHASE_WIDTH-1:0]           phase_acc_out_slot0
);

    /***************************************************************
     * FFs internos del pipeline
     ***************************************************************/
    logic [2:0]                          stage_counter;
    logic                                pipeline_active;
    logic [STATE_BITS_PER_SLOT-1:0]      state_buffer;
    logic [PHASE_WIDTH-1:0]              phase_acc_slot0_snapshot;

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
     * State buffer field accessors (legibilidad)
     ***************************************************************/
    wire [PHASE_WIDTH-1:0] state_phase_acc   = state_buffer[31:0];
    wire                   state_key_on_prev = state_buffer[64];

    /***************************************************************
     * Stage 2 compute: new phase_acc + new key_on_prev
     * (combinacional, se aplica al state_buffer en stage 7 via
     * state_write_data)
     ***************************************************************/
    logic [PHASE_WIDTH-1:0] new_phase_acc;
    logic                   new_key_on_prev;
    always_comb begin
        if (key_on && !state_key_on_prev) begin
            new_phase_acc = '0;                                 // edge: reset
        end
        else if (key_on) begin
            new_phase_acc = state_phase_acc + phase_inc;        // tick: advance
        end
        else begin
            new_phase_acc = state_phase_acc;                    // hold
        end
        new_key_on_prev = key_on;
    end

    /***************************************************************
     * Next-state combinacional (anti-Gowin CE)
     ***************************************************************/
    logic [2:0]                          next_stage_counter;
    logic                                next_pipeline_active;
    logic [STATE_ADDR_BITS-1:0]          next_current_slot;
    logic [STATE_BITS_PER_SLOT-1:0]      next_state_buffer;
    logic [PHASE_WIDTH-1:0]              next_phase_acc_slot0_snapshot;

    always_comb begin
        // Defaults: hold
        next_stage_counter            = stage_counter;
        next_pipeline_active          = pipeline_active;
        next_current_slot             = current_slot;
        next_state_buffer             = state_buffer;
        next_phase_acc_slot0_snapshot = phase_acc_slot0_snapshot;

        // Control: sample_tick arranca desde slot 0, stage 7 avanza/termina
        if (sample_tick) begin
            next_pipeline_active = 1'b1;
            next_stage_counter   = 3'd0;
            next_current_slot    = '0;
        end
        else if (pipeline_active) begin
            if (stage_counter == 3'd7) begin
                // Fin de un slot; ¿próximo o idle?
                if (current_slot < (ACTIVE_SLOTS - 1)) begin
                    next_current_slot  = current_slot + 1'd1;
                    next_stage_counter = 3'd0;
                end
                else begin
                    next_pipeline_active = 1'b0;
                    next_current_slot    = '0;   // volver a slot 0 idle
                                                  // (estabiliza state_read_addr
                                                  // entre sample_ticks para debug
                                                  // y para fetch1/interp futuros)
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

        // Stage 2 snapshot slot 0: phase_acc del slot 0 expuesto al exterior
        if (pipeline_active && (stage_counter == 3'd2) && (current_slot == '0)) begin
            next_phase_acc_slot0_snapshot = new_phase_acc;
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
        end
        else begin
            stage_counter            <= next_stage_counter;
            pipeline_active          <= next_pipeline_active;
            current_slot             <= next_current_slot;
            state_buffer             <= next_state_buffer;
            phase_acc_slot0_snapshot <= next_phase_acc_slot0_snapshot;
        end
    end

    /***************************************************************
     * Outputs combinacionales
     ***************************************************************/
    assign state_read_addr  = current_slot;
    assign state_write_addr = current_slot;
    assign state_write_data = {
        {(STATE_BITS_PER_SLOT-65){1'b0}},   // [127:65] reserved (EG en 2c.3.h)
        new_key_on_prev,                     // [64]
        8'h00,                               // [63:56] byte_b (placeholder)
        8'h00,                               // [55:48] byte_a (placeholder)
        16'h0000,                            // [47:32] last_idx_fetched (placeholder)
        new_phase_acc                        // [31:0]
    };
    assign state_write_en   = pipeline_active && (stage_counter == 3'd7);

    assign phase_acc_out_slot0 = phase_acc_slot0_snapshot;

endmodule

`default_nettype wire
