//
// ymf278_regfile.sv
//
// MangOPL4 Fase 2 — register file de 256 bytes del Wave block.
// Vive en el dominio CLK (bus MSX, 107.4 MHz) para escrituras atómicas.
// El motor Wave (en CLK_OPL3) lee fields concretos a través de syncs
// 2-FF añadidos en ymf278_top, no directamente desde aquí.
//
// Implementado como 256x8 distributed FFs por simplicidad en 2a (~2 Kbit
// de FF, dentro del presupuesto sobrado). En sub-fases posteriores se
// puede migrar a BSRAM si hace falta.
//
// El gating por NEW2 (bit 0 del registro 0x105 del OPL3) lo hace el
// caller — este módulo procesa cualquier write que reciba.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_regfile
    import ymf278_pkg::*;
(
    input  wire                 RESET_n,
    input  wire                 CLK,
    input  wire                 wr_stb,     // pulso de 1 ciclo CLK
    input  wire [7:0]           wr_addr,
    input  wire [7:0]           wr_data,
    output logic [7:0]          regs [0:NUM_REGS-1]
);
    integer i;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            for (i = 0; i < NUM_REGS; i = i + 1) begin
                regs[i] <= 8'h00;
            end
        end
        else if (wr_stb) begin
            regs[wr_addr] <= wr_data;
        end
    end
endmodule

`default_nettype wire
