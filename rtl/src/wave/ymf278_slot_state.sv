//
// ymf278_slot_state.sv
//
// MangOPL4 Fase 2c.3.a — state file dual-port para los 24 slots del
// motor Wave del YMF278B.
//
// Configuración:
//   - 32 entries × STATE_BITS_PER_SLOT bits (24 entries utilizadas, 8 sobran
//     como margen). 32 × 128 = 4096 bits = 1 BSRAM block de Gowin (4 Kbit).
//   - Síncrono read (1 ciclo latencia) y síncrono write, mismo CLK domain.
//   - Read y Write addresses independientes → permite leer slot N en el
//     mismo ciclo que se escribe slot M.
//
// Uso en 2c.3.a (este sub-paso):
//   - Slot 0 hardcoded en read y write. write_data contiene un shadow
//     del phase_acc actual. read_data se expone a través de regs de
//     debug (0xF0-0xF3) para verificar que la BSRAM funciona.
//
// Uso en 2c.3.b en adelante:
//   - El slot_idx del pipeline 8-stage controlará read/write addr.
//   - Stage 0 lanza read; stage 7 escribe back updated state.
//
// Patrón Gowin: BSRAM nativo síncrono. NO usa CE-style FF con modport
// signal (regla feedback_gowin_ce_ff.md). El write_en es entrada del
// modulo, no señal de modport, así que es seguro.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_slot_state
    import ymf278_pkg::*;
(
    input  wire                                CLK,
    input  wire                                RESET_n,

    // Read port (1 ciclo latencia)
    input  wire [STATE_ADDR_BITS-1:0]          read_addr,
    output logic [STATE_BITS_PER_SLOT-1:0]     read_data,

    // Write port
    input  wire [STATE_ADDR_BITS-1:0]          write_addr,
    input  wire [STATE_BITS_PER_SLOT-1:0]      write_data,
    input  wire                                write_en
);

    localparam int DEPTH = 1 << STATE_ADDR_BITS;

    logic [STATE_BITS_PER_SLOT-1:0] mem [0:DEPTH-1];

    // Inicialización a 0 (Gowin permite BSRAM con init values en bitstream)
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = '0;
    end

    // Síncrono read: write-first NO necesario (read y write se hacen a
    // direcciones distintas en el pipeline). Si coincidieran, el
    // comportamiento es "read-before-write" (= valor antiguo en read_data),
    // lo que es seguro para el pipeline pero conviene NO escribir y leer
    // la misma slot el mismo ciclo.
    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            read_data <= '0;
        end
        else begin
            read_data <= mem[read_addr];
            if (write_en) begin
                mem[write_addr] <= write_data;
            end
        end
    end

endmodule

`default_nettype wire
