//
// ymf278_fetch1.sv
//
// MangOPL4 Fase 2c.2.e — fetcher SDRAM dedicado al slot 0.
//
// Fetch de 2 bytes consecutivos del YRW801 según phase_acc[31:16]
// (sample index). Mini-cache de 2 samples para no refetchear cuando
// solo cambia phase_acc[15:0] (frac).
//
// Formato 2c.2.e: solo 8-bit unsigned (formato más simple del YRW801).
// El byte se XOR con 0x80 y sign-extiende a 16-bit signed:
//   byte 0x80 → 0, byte 0x00 → -32768, byte 0xFF → +32512.
// Sub-paso 2d ampliará a 12-bit packed y 16-bit signed.
//
// Sub-paso 2c.2.e.1: módulo standalone, no instanciado todavía.
// Sintetizador lo sweepea → bitstream funcionalmente idéntico al 2c.2.d.
//
// FSM (mismo patrón que ymf278_mempointer):
//   S_IDLE       → si key_on && idx cambió && TIMING=1, ir a S_REQ_A.
//   S_REQ_A      → asserta OE_n=0 con ADDR=start+idx. Espera ACK_n=0
//                  → S_WAIT_DEASSERT_A.
//   S_WAIT_DEASSERT_A → libera OE_n. Espera ACK_n=1 → captura byte_a
//                  → S_REQ_B.
//   S_REQ_B      → asserta OE_n=0 con ADDR=start+idx+1. ACK_n=0
//                  → S_WAIT_DEASSERT_B.
//   S_WAIT_DEASSERT_B → libera OE_n. ACK_n=1 → captura byte_b
//                  → S_IDLE.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_fetch1 (
    input  wire                 RESET_n,
    input  wire                 CLK,
    input  wire                 bus_reset_n,

    // Configuración del slot
    input  wire [23:0]          start_addr_sdram,    // SDRAM addr base
    input  wire [31:0]          phase_acc,
    input  wire                 key_on,

    // Output: 2 samples consecutivos en formato 16-bit signed (post-XOR
    // 0x80) y la fracción para interpolación.
    output logic signed [15:0]  sample_a,
    output logic signed [15:0]  sample_b,
    output logic        [15:0]  frac,

    // SDRAM bus
    RAM_IF.HOST                 Ram
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_REQ_A,
        S_WAIT_DEASSERT_A,
        S_REQ_B,
        S_WAIT_DEASSERT_B
    } state_t;

    state_t state;

    wire [15:0] curr_idx = phase_acc[31:16];
    logic [15:0] last_idx_fetched;

    logic [7:0]  byte_a;
    logic [7:0]  byte_b;

    assign frac = phase_acc[15:0];

    // Conversión 8-bit unsigned a 16-bit signed: byte XOR 0x80 → high
    wire [7:0] byte_a_signed_high = byte_a ^ 8'h80;
    wire [7:0] byte_b_signed_high = byte_b ^ 8'h80;
    assign sample_a = signed'({byte_a_signed_high, 8'h00});
    assign sample_b = signed'({byte_b_signed_high, 8'h00});

    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n || !bus_reset_n) begin
            state            <= S_IDLE;
            last_idx_fetched <= 16'hFFFF;
            byte_a           <= 8'h80;
            byte_b           <= 8'h80;
            Ram.ADDR         <= 24'h0;
            Ram.DIN          <= 32'h0;
            Ram.DIN_SIZE     <= 3'b000;
            Ram.OE_n         <= 1'b1;
            Ram.WE_n         <= 1'b1;
            Ram.RFSH_n       <= 1'b1;
        end
        else begin
            Ram.ADDR     <= 24'h0;
            Ram.DIN      <= 32'h0;
            Ram.DIN_SIZE <= 3'b000;
            Ram.OE_n     <= 1'b1;
            Ram.WE_n     <= 1'b1;
            Ram.RFSH_n   <= 1'b1;

            case (state)
                S_IDLE: begin
                    if (key_on && (curr_idx != last_idx_fetched) && Ram.TIMING) begin
                        state    <= S_REQ_A;
                        Ram.ADDR <= start_addr_sdram + {8'h0, curr_idx};
                        Ram.OE_n <= 1'b0;
                    end
                end

                S_REQ_A: begin
                    Ram.ADDR <= start_addr_sdram + {8'h0, curr_idx};
                    if (Ram.ACK_n == 1'b0) begin
                        state <= S_WAIT_DEASSERT_A;
                    end
                end

                S_WAIT_DEASSERT_A: begin
                    if (Ram.ACK_n == 1'b1) begin
                        byte_a <= Ram.DOUT[7:0];
                        state  <= S_REQ_B;
                    end
                end

                S_REQ_B: begin
                    if (Ram.TIMING) begin
                        Ram.ADDR <= start_addr_sdram + {8'h0, curr_idx} + 24'd1;
                        Ram.OE_n <= 1'b0;
                    end
                    if (Ram.ACK_n == 1'b0) begin
                        state <= S_WAIT_DEASSERT_B;
                    end
                end

                S_WAIT_DEASSERT_B: begin
                    if (Ram.ACK_n == 1'b1) begin
                        byte_b           <= Ram.DOUT[7:0];
                        last_idx_fetched <= curr_idx;
                        state            <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
