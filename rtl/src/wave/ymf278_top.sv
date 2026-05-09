//
// ymf278_top.sv
//
// MangOPL4 Fase 2 — top-level del motor Wave del YMF278B.
//
// Estado en sub-fase 2a "hello world":
//   - Decodifica writes a 7E (latch reg address) y 7F (write reg data).
//   - Mantiene el regfile de 256 bytes (en CLK domain).
//   - Sintetiza UNA voz con onda cuadrada interna (no LUT, para máxima
//     simplicidad). Se usa el bit 7 del registro 0x68 (slot 0 offset 4)
//     como "key-on" — el formato real del YMF278B.
//   - Pitch fijo: ~1.7 kHz audible. No depende de FN/OCT del slot.
//   - Read-back (puerto 7F) devuelve 0x20 stub (preserva detección
//     MoonSound de VGMPlay como en el wrapper original).
//
// En sub-fases posteriores este módulo crece: SDRAM fetch, 24 canales
// time-shared, envelope DADSR, LFO, pan, etc.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_top
    import ymf278_pkg::*;
(
    input  wire                 RESET_n,
    input  wire                 CLK,            // 107.4 MHz, bus MSX
    input  wire                 CLK_OPL3,       // 33.5625 MHz, motor wave
    input  wire                 bus_reset_n,    // Bus.RESET_n del MSX
    input  wire                 new2,           // OPL3 reg 0x105 bit 1 (NEW2)

    // Bus decodificado por el caller (cartridge_opl3.sv):
    input  wire                 wr_strobe,      // 1 ciclo CLK cuando hay write a 7E o 7F
    input  wire                 addr0,          // 0=7E (reg select), 1=7F (data)
    input  wire [7:0]           din,            // Bus.DIN

    // Strobe de read terminado en 7F (flanco descendente IORQ_n=0 &&
    // RD_n=0 && ADDR[0]=1) — usado por mempointer para auto-incrementar
    // el pointer tras una lectura del data port (reg 06).
    input  wire                 rd_done_strobe,

    // Bus.MERQ_n del Z80 (gate del acceso SDRAM en mempointer):
    input  wire                 bus_merq_n,

    // Read-back para 7F:
    output logic [7:0]          rd_data,

    // Salida audio: signed 24-bit (mismo width que DAC OPL3) para sumar
    // directamente con mono_q antes del gain stage en cartridge_opl3.sv.
    output logic signed [23:0]  wave_sample,

    // MangOPL4 Fase 2 — SDRAM Wave (YRW801 + Sample RAM). 2b.2 lo usa
    // el memory port, 2b.3 lo compartirá con el sample fetch del
    // playback (mempointer prioridad cuando MSX está accediendo).
    RAM_IF.HOST                 Ram
);

    /***************************************************************
     * 7E/7F decode + regfile (todo en dominio CLK)
     ***************************************************************/
    logic [7:0] reg_addr_latch;
    logic       reg_wr_stb;       // pulso a regfile cuando hay write a 7F

    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n || !bus_reset_n) begin
            reg_addr_latch <= 8'h00;
        end
        else if (wr_strobe && !addr0) begin
            // Write a 7E: latch dirección de registro
            reg_addr_latch <= din;
        end
    end

    // NEW2 gating: writes ignorados si new2=0 (chip dormido)
    assign reg_wr_stb = wr_strobe && addr0 && new2;

    logic [7:0] regs [0:NUM_REGS-1];
    ymf278_regfile u_regfile (
        .RESET_n        (RESET_n),
        .CLK            (CLK),
        .wr_stb         (reg_wr_stb),
        .wr_addr        (reg_addr_latch),
        .wr_data        (din),
        .regs           (regs)
    );

    /***************************************************************
     * 2c.2.b/c: phase generator del slot 0.
     *
     * Sample tick: divider local en CLK a 44.1 kHz (TICK_DIV=2435).
     * FNUM/OCT extraídos del regfile bit-exact YMF278B (openMSX):
     *   reg 0x20+slot: bits[7:1] → FN[6:0], bit[0] → wave[8].
     *   reg 0x38+slot: bits[2:0] → FN[9:7], bit[3] → PRVB,
     *                  bits[7:4] → OCT (4-bit signed).
     *
     * 2c.2.d: phase_acc_clk[17:10] alimenta el cache_index del
     * mempointer → pitch del playback ahora controlable por FNUM/OCT.
     * Con FNUM=0, OCT=0 (defaults post-reset): phase_inc=1024,
     * phase_acc[17:10] avanza +1 por sample tick → mismo pitch
     * baseline del counter previo (172 Hz para cache 256 bytes).
     *
     * Read-back observable de phase_acc[31:0] en regs 0xFC-0xFF
     * (chip ID range del YMF278B real, no usado por software estándar).
     ***************************************************************/
    wire keyon_slot0_clk = regs[8'h68][7];

    localparam int TICK_DIV_TOP = 2435;     // CLK 107.4 MHz / 2435 ≈ 44.1 kHz
    logic [11:0] tick_counter_top;
    logic        sample_tick_top;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n || !bus_reset_n) begin
            tick_counter_top <= 12'h0;
            sample_tick_top  <= 1'b0;
        end
        else if (tick_counter_top == TICK_DIV_TOP - 1) begin
            tick_counter_top <= 12'h0;
            sample_tick_top  <= 1'b1;
        end
        else begin
            tick_counter_top <= tick_counter_top + 12'd1;
            sample_tick_top  <= 1'b0;
        end
    end

    wire [9:0]        fn_slot0  = {regs[8'h38][2:0], regs[8'h20][7:1]};
    wire signed [3:0] oct_slot0 = regs[8'h38][7:4];

    logic [31:0] phase_acc_clk;
    ymf278_phase u_phase (
        .RESET_n        (RESET_n),
        .CLK            (CLK),
        .fnum           (fn_slot0),
        .octave         (oct_slot0),
        .key_on         (keyon_slot0_clk),
        .sample_clk_en  (sample_tick_top),
        .phase_acc      (phase_acc_clk)
    );

    /***************************************************************
     * Memory port (regs 02-06) + wave_arbiter. ESTADO 2c.2.e.2a:
     * arbiter v5 instanciado, fetch1 todavía NO (BusB con stub idle).
     * Próximo sub-paso 2c.2.e.2b reinstanciará fetch1. Validado en
     * MSX real con wavemem/wavedump/MoonBlaster FM/VGMPlay OPL3.
     ***************************************************************/
    logic [7:0]               mem_data_byte;
    logic signed [15:0]       playback_sample_clk;

    RAM_IF Ram_mempointer();
    RAM_IF Ram_fetch1();

    ymf278_mempointer u_mempointer (
        .RESET_n            (RESET_n),
        .CLK                (CLK),
        .bus_reset_n        (bus_reset_n),
        .reg_wr_stb         (reg_wr_stb),
        .reg_addr           (reg_addr_latch),
        .reg_data           (din),
        .reg_rd_done_stb    (rd_done_strobe),
        .bus_merq_n         (bus_merq_n),
        .key_on_slot0       (keyon_slot0_clk),
        .cache_index        (phase_acc_clk[17:10]),
        .mem_data_byte      (mem_data_byte),
        .playback_sample    (playback_sample_clk),
        .Ram                (Ram_mempointer)
    );

    // BusB stub: fetch1 todavía no instanciado en 2c.2.e.2a. Drivear
    // los signals HOST de Ram_fetch1 a defaults idle para que arbiter
    // vea BusB siempre quiet (requesting_b=0). 2c.2.e.2b lo reemplaza
    // por la instancia real de ymf278_fetch1.
    assign Ram_fetch1.ADDR     = 24'h0;
    assign Ram_fetch1.DIN      = 32'h0;
    assign Ram_fetch1.DIN_SIZE = 3'b000;
    assign Ram_fetch1.OE_n     = 1'b1;
    assign Ram_fetch1.WE_n     = 1'b1;
    assign Ram_fetch1.RFSH_n   = 1'b1;

    wave_arbiter u_wave_arbiter (
        .RESET_n,
        .CLK,
        .Primary    (Ram),
        .BusA       (Ram_mempointer),
        .BusB       (Ram_fetch1)
    );

    // Read-back: reg 0x06 → memory data, regs 0xFC-0xFF → phase_acc.
    // (Sin 0xFA/0xFB porque fetch1 NO está instanciado.)
    // Default 0x20 stub (preserva detección MoonSound).
    always_comb begin
        case (reg_addr_latch)
            8'h06:    rd_data = mem_data_byte;
            8'hFC:    rd_data = phase_acc_clk[7:0];
            8'hFD:    rd_data = phase_acc_clk[15:8];
            8'hFE:    rd_data = phase_acc_clk[23:16];
            8'hFF:    rd_data = phase_acc_clk[31:24];
            default:  rd_data = 8'h20;
        endcase
    end

    /***************************************************************
     * 2b.3 Playback output: registramos playback_sample_clk en
     * CLK_OPL3 con un FF (single, suficiente porque el signal cambia
     * a sample rate 44 kHz, mucho más lento que CLK_OPL3 = 33.5 MHz).
     * Luego sign-extiende a 24-bit para el mixer.
     *
     * El square wave de 2a se ha eliminado — playback toma su lugar.
     ***************************************************************/
    logic signed [15:0] playback_sample_clkopl3;
    always_ff @(posedge CLK_OPL3 or negedge RESET_n) begin
        if (!RESET_n || !bus_reset_n) begin
            playback_sample_clkopl3 <= 16'sh0000;
        end
        else begin
            playback_sample_clkopl3 <= playback_sample_clk;
        end
    end

    // Sign-extend a 24-bit para sumar con mono_q en cartridge_opl3.sv
    assign wave_sample = {{8{playback_sample_clkopl3[15]}}, playback_sample_clkopl3};

    // (RAM_IF lo drivea ymf278_mempointer arriba — ya no idle aquí)

endmodule

`default_nettype wire
