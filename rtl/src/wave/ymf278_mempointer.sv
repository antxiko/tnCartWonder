//
// ymf278_mempointer.sv
//
// MangOPL4 Fase 2.2 — registros de acceso a memoria del YMF278B Wave:
//   0x02: memory mode (en 2.2 ignorado: el R/W lo decidimos por contexto)
//   0x03/04/05: pointer high/mid/low (24-bit)
//   0x06: data port. Write → SDRAM write + auto-increment pointer.
//         Read  → devuelve byte prefetched + auto-increment pointer.
//
// Mapeo YMF278 24-bit addr → SDRAM addr (mapa reorganizado 8 MB):
//   ymf278 0x000000-0x1FFFFF (YRW801, RO) → SDRAM 0x100000+ymf278
//   ymf278 0x200000-0x37FFFF (SRAM main)  → SDRAM 0x100000+ymf278
//   ymf278 0x380000-0x3FFFFF (SRAM ext)   → SDRAM 0x400000+ymf278
//                                            (= 0x780000 a 0x7FFFFF;
//                                             zona ex-V9990 VRAM)
//   ymf278 ≥ 0x400000 → reads return 0xFF, writes ignored.
//
// Sample RAM total = 1.5 MB main + 512 KB ext = 2 MB (igual que
// MoonSound real con expansión de RAM máxima).
//
// Vive en CLK domain (107.4 MHz). Ciclo SDRAM ~6 CLK = 56 ns.
// Z80 OUT/IN ≥9 ciclos a 3.58 MHz ≥22 µs. Margen 400×, no hace falta queue.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_mempointer
    import ymf278_pkg::*;
(
    input  wire             RESET_n,
    input  wire             CLK,
    input  wire             bus_reset_n,

    // Strobe de write a 7F (1 ciclo CLK), con dirección de registro
    // ya latched en reg_addr (= valor escrito previamente a 7E):
    input  wire             reg_wr_stb,
    input  wire [7:0]       reg_addr,
    input  wire [7:0]       reg_data,           // = Bus.DIN

    // Strobe de read terminado en 7F (flanco descendente del IORQ_n=0
    // && RD_n=0 && ADDR[0]=1). En el momento del strobe, el byte ya
    // ha sido entregado al MSX vía mem_data_byte.
    input  wire             reg_rd_done_stb,

    // Bus.MERQ_n del Z80: 1 = no hay ciclo de memoria, safe acceder
    // SDRAM sin pisar a cartridge_ram (memory mapper). Gate las
    // transiciones IDLE→REQ con esto. Si MERQ_n=0 (Z80 en M-cycle),
    // diferimos el acceso hasta el próximo OUT/IO cycle.
    input  wire             bus_merq_n,

    // Byte actualmente disponible para read en 7F (si reg_addr=0x06):
    output logic [7:0]      mem_data_byte,

    // RAM_IF.HOST: maestro del bus SDRAM.
    RAM_IF.HOST             Ram
);

    // 24-bit pointer (regs 03/04/05 packed)
    logic [23:0] pointer;

    // Byte prefetched (resultado de la última lectura SDRAM)
    logic [7:0]  fetched_byte;

    // Pending operations (settled by bus events, consumed by FSM)
    logic        pending_read;
    logic        pending_write;
    logic [7:0]  pending_write_data;

    // Estado del state machine SDRAM
    typedef enum logic [2:0] {
        S_IDLE,
        S_READ_REQ,
        S_READ_WAIT_DEASSERT,
        S_WRITE_REQ,
        S_WRITE_WAIT_DEASSERT
    } state_t;
    state_t state;

    // Helpers — mapa SDRAM reorganizado (8 MB strict bounds):
    //
    // YRW801: read-only ROM (writes ignored), ymf278 < 0x200000.
    //         Para 2b.2 está sin cargar (datos garbage hasta 2b.4).
    // SRAM main: 1.5 MB en ymf278 0x200000-0x37FFFF.
    // SRAM ext:  512 KB en ymf278 0x380000-0x3FFFFF (zona ex-VRAM).
    wire        ymf278_in_yrw801   = (pointer < 24'h20_0000);
    wire        ymf278_in_sram_main= (pointer >= 24'h20_0000) &&
                                     (pointer <  24'h38_0000);
    wire        ymf278_in_sram_ext = (pointer >= 24'h38_0000) &&
                                     (pointer <  24'h40_0000);
    wire        ymf278_in_sram     = ymf278_in_sram_main || ymf278_in_sram_ext;
    wire        ymf278_in_range    = ymf278_in_yrw801 || ymf278_in_sram;

    // Traducción a SDRAM. La rama solo distingue ext: el resto comparte
    // el offset +0x100000.
    wire [23:0] sdram_addr = ymf278_in_sram_ext ? (24'h40_0000 + pointer)
                                                : (24'h10_0000 + pointer);

    /***************************************************************
     * Bloque único que maneja: pointer, fetched_byte, pending flags,
     * state machine FSM, y RAM_IF outputs.
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n || !bus_reset_n) begin
            pointer            <= 24'h0;
            fetched_byte       <= 8'h00;
            pending_read       <= 1'b0;
            pending_write      <= 1'b0;
            pending_write_data <= 8'h0;
            state              <= S_IDLE;
            Ram.ADDR           <= 24'h0;
            Ram.DIN            <= 32'h0;
            Ram.DIN_SIZE       <= 3'b000;
            Ram.OE_n           <= 1'b1;
            Ram.WE_n           <= 1'b1;
            Ram.RFSH_n         <= 1'b1;
        end
        else begin
            // Defaults RAM_IF cada ciclo. CRÍTICO clarear ADDR/DIN/
            // DIN_SIZE a 0: el OR-collapse del EXPANSION_RAM combina
            // los valores de TODOS los hosts. Si dejamos ADDR con su
            // último valor (e.g., 0x300000) mientras cartridge_ram lee
            // a 0x05XXXX, primary.ADDR = 0x05XXXX | 0x300000 = 0x35XXXX
            // → cartridge_ram recibe byte de Sample RAM como si fuera
            // instrucción → Z80 ejecuta basura → cuelgue.
            // Mismo patrón que cartridge_ram.sv:138.
            Ram.ADDR     <= 24'h0;
            Ram.DIN      <= 32'h0;
            Ram.DIN_SIZE <= 3'b000;
            Ram.OE_n     <= 1'b1;
            Ram.WE_n     <= 1'b1;
            Ram.RFSH_n   <= 1'b1;

            // ============ Eventos del bus ============
            // Cambios al pointer (regs 03/04/05): solo actualizan
            // los bytes correspondientes. NO disparan prefetch — eso
            // se hace solo al hacer SELECT de reg 06 (más abajo) o
            // al consumir un byte vía IN de reg 06. Esto minimiza
            // el número de accesos SDRAM (cada acceso es ventana
            // potencial de contention con cartridge_ram).
            if (reg_wr_stb) begin
                case (reg_addr)
                    8'h03: pointer[23:16] <= reg_data;
                    8'h04: pointer[15:8]  <= reg_data;
                    8'h05: pointer[7:0]   <= reg_data;
                    8'h06: begin
                        pending_write       <= 1'b1;
                        pending_write_data  <= reg_data;
                    end
                    default: ; // otros regs no son problema nuestro
                endcase
            end

            if (reg_rd_done_stb && reg_addr == 8'h06) begin
                pointer      <= pointer + 24'd1;
                pending_read <= 1'b1;
            end

            // ============ FSM SDRAM ============
            case (state)
                S_IDLE: begin
                    // Gate por Ram.TIMING=1 (SDRAM en STATE_IDLE) +
                    // bus_merq_n=1 (Z80 NO en memory cycle).
                    //
                    // Ram.TIMING=1 garantiza que la SDRAM puede aceptar
                    // un nuevo request — si está en otra operación
                    // (cartridge_ram, refresh, bootloader xfer) nuestro
                    // pulso se IGNORARÍA y el ACK_n que veríamos sería
                    // de OTRO host → estado interno corrupto.
                    //
                    // bus_merq_n=1 nos pone en ventana segura (Z80 en
                    // ciclo I/O, no fetcheando instrucciones via mapper).
                    if (!Ram.TIMING || !bus_merq_n) begin
                        // SDRAM busy o Z80 en memory cycle, esperar
                    end
                    else if (pending_write) begin
                        // Write tiene prioridad sobre read
                        pending_write <= 1'b0;
                        if (ymf278_in_sram) begin
                            state        <= S_WRITE_REQ;
                            Ram.ADDR     <= sdram_addr;
                            Ram.DIN      <= {24'b0, pending_write_data};
                            Ram.DIN_SIZE <= 3'b000;  // DIN_SIZE_8
                            Ram.WE_n     <= 1'b0;
                        end
                        else begin
                            // Write fuera de Sample RAM: ignorar dato, pero
                            // aún hay que incrementar pointer + prefetch.
                            pointer      <= pointer + 24'd1;
                            pending_read <= 1'b1;
                        end
                    end
                    else if (pending_read) begin
                        pending_read <= 1'b0;
                        if (ymf278_in_range) begin
                            state        <= S_READ_REQ;
                            Ram.ADDR     <= sdram_addr;
                            Ram.DIN_SIZE <= 3'b000;
                            Ram.OE_n     <= 1'b0;
                        end
                        else begin
                            // Fuera de rango: 0xFF, no SDRAM access
                            fetched_byte <= 8'hFF;
                        end
                    end
                end

                S_READ_REQ: begin
                    // CRÍTICO: NO re-asertamos OE_n aquí. La SDRAM
                    // (LEVEL_TRIG=1) ya recibió begin_rd en el ciclo
                    // de la transición IDLE→READ_REQ. Mantener OE_n=0
                    // durante varios ciclos haría que la primary
                    // SDRAM diera ACK_n=0 a NUESTRA petición, pero si
                    // cartridge_ram simultáneamente asserta su OE_n=0
                    // creería que el ACK es para ÉL → leería NUESTRO
                    // DOUT como instrucción Z80 → MSX cuelga.
                    // Default Ram.OE_n=1 (del top del always_ff) hace
                    // el deassert automático.
                    Ram.ADDR     <= sdram_addr;
                    Ram.DIN_SIZE <= 3'b000;
                    if (Ram.ACK_n == 1'b0) begin
                        state    <= S_READ_WAIT_DEASSERT;
                    end
                end

                S_READ_WAIT_DEASSERT: begin
                    // OE_n ya en 1 por default. Esperamos ACK_n=1.
                    if (Ram.ACK_n == 1'b1) begin
                        fetched_byte <= Ram.DOUT[7:0];
                        state        <= S_IDLE;
                    end
                end

                S_WRITE_REQ: begin
                    // CRÍTICO: NO re-asertamos WE_n aquí (mismo motivo
                    // que S_READ_REQ — evitar que cartridge_ram lea
                    // nuestro DOUT como ACK suyo). Default Ram.WE_n=1
                    // del top hace el deassert automático.
                    Ram.ADDR     <= sdram_addr;
                    Ram.DIN      <= {24'b0, pending_write_data};
                    Ram.DIN_SIZE <= 3'b000;
                    if (Ram.ACK_n == 1'b0) begin
                        state    <= S_WRITE_WAIT_DEASSERT;
                    end
                end

                S_WRITE_WAIT_DEASSERT: begin
                    if (Ram.ACK_n == 1'b1) begin
                        // Write completado: solo incrementar pointer.
                        // NO auto-prefetch (Fase 2.2): mantener la
                        // ventana de acceso a SDRAM minimal para evitar
                        // contention con cartridge_ram durante M1
                        // fetches del Z80 entre OUTs. El siguiente
                        // read se disparará cuando el software lea
                        // reg 0x06 o cambie el pointer (regs 3/4/5).
                        pointer      <= pointer + 24'd1;
                        state        <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign mem_data_byte = fetched_byte;

endmodule

`default_nettype wire
