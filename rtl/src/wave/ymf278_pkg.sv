//
// ymf278_pkg.sv
//
// MangOPL4 Fase 2 — package con constantes del Wave block del YMF278B.
// Compartido por todos los módulos del directorio wave/.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

package ymf278_pkg;
    // 24 canales PCM (slots) en el chip real
    localparam int NUM_SLOTS = 24;

    // Tamaño del register file: 256 bytes (registros 0x00-0xFF)
    localparam int NUM_REGS = 256;

    // Cálculo de slot/offset desde dirección de registro:
    //   offset = (reg_addr - 8) / 24   ∈ [0..9]
    //   slot   = (reg_addr - 8) % 24   ∈ [0..23]
    // Solo válido para reg_addr ∈ [0x08..0xF7].

    // Direcciones notables (referencia, no usadas todas en 2a)
    localparam logic [7:0] REG_MEM_MODE     = 8'h02;  // Memory mode + R/W
    localparam logic [7:0] REG_MEM_ADDR_HI  = 8'h03;  // Memory pointer high
    localparam logic [7:0] REG_MEM_ADDR_MID = 8'h04;  // Memory pointer mid
    localparam logic [7:0] REG_MEM_ADDR_LO  = 8'h05;  // Memory pointer low
    localparam logic [7:0] REG_MEM_DATA     = 8'h06;  // Memory R/W data + busy bit
    localparam logic [7:0] REG_FM_MIX       = 8'hF8;  // FM output level (3-bit)
    localparam logic [7:0] REG_PCM_MIX      = 8'hF9;  // PCM/Wave output level (3-bit)

    // Phase accumulator: 32 bits, formato 16.16
    //   - Parte entera (top 16 bits): índice de muestra dentro del sample
    //   - Parte fraccional (bottom 16 bits): peso para interpolación lineal
    localparam int PHASE_WIDTH      = 32;
    localparam int PHASE_INT_WIDTH  = 16;
    localparam int PHASE_FRAC_WIDTH = 16;

    // Output del Wave block: 16-bit signed (igual que muestras 16-bit del chip)
    localparam int WAVE_OUT_WIDTH = 16;

    // Sample tick divider: CLK_OPL3 (33.5625 MHz) / 760 ≈ 44.16 kHz
    // Igualmente cerca de los 44.1 kHz nominales del MoonSound real (-0.13%).
    localparam int SAMPLE_TICK_DIV = 760;

    // State file por slot (BSRAM dual-port en ymf278_slot_state.sv).
    // Plan 2c.3: 24 slots, cada uno con state persistente entre slot ticks.
    // 128 bits/slot con headroom hasta el final de 2c.3 (EG state, cache fetch).
    //
    // Offsets de campos dentro del state vector (LSB-aligned):
    //   [31:0]    phase_acc           (2c.3.a)
    //   [47:32]   last_idx_fetched    (2c.3.b)
    //   [55:48]   byte_a              (2c.3.b)
    //   [63:56]   byte_b              (2c.3.b)
    //   [64]      key_on_prev         (2c.3.b)
    //   [81:65]   eg_level            (2c.3.h)
    //   [84:82]   eg_state            (2c.3.h)
    //   [100:85]  eg_counter          (2c.3.i)
    //   [127:101] reservado
    localparam int STATE_BITS_PER_SLOT = 128;
    localparam int STATE_ADDR_BITS     = 5;     // 32 entries (24 usados)

endpackage

`default_nettype wire
