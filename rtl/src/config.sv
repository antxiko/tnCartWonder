//
// config.sv
//
// BSD 3-Clause License
// 
// Copyright (c) 2024, Shinobu Hashimoto
// 
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
// 
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
// 
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

`default_nettype none

/***********************************************************************************
 * メイン設定
 ***********************************************************************************/
package CONFIG;
    /***************************************************************
     * 機能に指定する定数
     ***************************************************************/
    localparam DISABLE          = 0;            // 機能の無効
    localparam ENABLE           = 1;            // 機能の有効
    localparam ENABLE_VM2413    = 1;            // 機能の有効(VM2413)
    localparam ENABLE_IKAOPLL   = 2;            // 機能の有効(IKAOPLL)
    localparam ENABLE_IKASCC    = 2;            // 機能の有効(IKASCC)
    localparam ENABLE_MEGA_SCC  = 2;            // 機能の有効(電源ON で SCC を有効)
    localparam ENABLE_MEGA_SCC_I= 3;            // 機能の有効(電源ON で SCC-I を有効)

    /***************************************************************
     * フラッシュメモリマップ
     *  00_0000 +-------------------+
     *          | bit stream(1MB)   |
     *  10_0000 +-------------------+
     *          | NEXTOR(128KB)     |
     *  12_0000 +-------------------+
     *          | FM-BIOS(16KB)     |
     *  12_4000 +-------------------+
     *          | (816KB)           |
     *  1F_0000 +-------------------+
     *          | PAC(64KB)         | (予定)
     *  20_0000 +-------------------+
     *          | MEGA ROM (2MB)    | (FLASHからMEGAROMをブートするときに使う予定)
     *  40_0000 +-------------------+
     ***************************************************************/
    localparam [23:0]   FLASH_ADDR_MEGAROM      = 24'h20_0000;
    localparam [23:0]   FLASH_SIZE_MEGAROM      = 24'h20_0000;
    localparam [23:0]   FLASH_ADDR_BIOS         = 24'h10_0000;
    localparam [23:0]   FLASH_SIZE_BIOS         = (FLASH_SIZE_BIOS_NEXTOR + FLASH_SIZE_BIOS_FM);
    localparam [23:0]   FLASH_SIZE_BIOS_NEXTOR  = 24'h02_0000;
    localparam [23:0]   FLASH_SIZE_BIOS_FM      = 24'h00_4000;
    localparam [23:0]   FLASH_ADDR_PAC          = 24'h1F_0000;
    localparam [23:0]   FLASH_SIZE_PAC          = 24'h01_0000;

    /***************************************************************
     * SD-RAM メモリマップ
     *  00_0000 +-------------------+
     *          | MEM MAPPER(4MB)   |
     *  40_0000 +-------------------+
     *          | MEGA ROM(3MB)     |
     *  70_0000 +-------------------+
     *          | NEXTOR(128KB)     |
     *  72_0000 +-------------------+
     *          | FM-BIOS(16KB)     |
     *  72_4000 +-------------------+
     *          | (360KB)           |
     *  77_E000 +-------------------+
     *          | PAC(8KB)          |
     *  78_0000 +-------------------+
     *          | VRAM(512KB)       |
     *  80_0000 +-------------------+
     ***************************************************************/
    /***************************************************************
     * MangOPL4 Fase 2 — mapa SDRAM reorganizado para Wave block.
     *
     * Reducimos el memory mapper del MSX de 4 MB a 1 MB (suficiente
     * para Nextor + casi todo software MSX-DOS — varias máquinas
     * MSX2+ tienen mappers de solo 256-512 KB) para liberar 3 MB
     * contiguos. También reciclamos los 512 KB del V9990 VRAM
     * (V9990 deshabilitado por presupuesto FPGA) como Sample RAM
     * extension. Y reducimos MEGA ROM de 3 MB a 2.5 MB.
     *
     * Resultado: Sample RAM total = 1.5 MB main + 512 KB ext = 2 MB
     * (igual que el MoonSound real con expansión máxima de RAM).
     *
     *  00_0000 +-------------------+
     *          | MEM MAPPER (1 MB) |  ↓ con BANK_MASK=0x3F en CARTRIDGE_RAM
     *  10_0000 +-------------------+
     *          | YRW801 (2 MB)     |  copiada de FLASH al boot (2b.4)
     *  30_0000 +-------------------+
     *          | Sample RAM main   |  1.5 MB, RW vía regs 02-06
     *  48_0000 +-------------------+
     *          | MEGA ROM (2.5 MB) |
     *  70_0000 +-------------------+
     *          | NEXTOR (128 KB)   |
     *  72_0000 +-------------------+
     *          | FM-BIOS (16 KB)   |
     *  72_4000 +-------------------+
     *          | (free 360 KB)     |
     *  77_E000 +-------------------+
     *          | PAC (8 KB)        |
     *  78_0000 +-------------------+
     *          | Sample RAM ext    |  512 KB (ex-V9990 VRAM)
     *  80_0000 +-------------------+ (8 MB total)
     *
     * Traducción YMF278 24-bit addr → SDRAM addr:
     *   ymf278 0x000000-0x1FFFFF (YRW801, RO) → SDRAM 0x100000+ymf278
     *   ymf278 0x200000-0x37FFFF (SRAM main)  → SDRAM 0x100000+ymf278
     *   ymf278 0x380000-0x3FFFFF (SRAM ext)   → SDRAM 0x400000+ymf278
     *                                             (= 0x780000 a 0x7FFFFF)
     *   ymf278 ≥ 0x400000 → reads return 0xFF, writes ignored.
     ***************************************************************/
    localparam [23:0]   RAM_ADDR_RAM            = 24'h00_0000;
    localparam [23:0]   RAM_SIZE_RAM            = 24'h10_0000;  // 1 MB
    localparam [7:0]    RAM_BANK_MASK_1MB       = 8'h3F;        // 64 banks × 16 KB

    localparam [23:0]   RAM_ADDR_YRW801         = 24'h10_0000;
    localparam [23:0]   RAM_SIZE_YRW801         = 24'h20_0000;  // 2 MB

    localparam [23:0]   RAM_ADDR_WAVE_SRAM_MAIN = 24'h30_0000;
    localparam [23:0]   RAM_SIZE_WAVE_SRAM_MAIN = 24'h18_0000;  // 1.5 MB
    localparam [23:0]   RAM_ADDR_WAVE_SRAM_EXT  = 24'h78_0000;
    localparam [23:0]   RAM_SIZE_WAVE_SRAM_EXT  = 24'h08_0000;  // 512 KB

    localparam [23:0]   RAM_ADDR_MEGAROM        = 24'h48_0000;
    localparam [23:0]   RAM_SIZE_MEGAROM        = 24'h28_0000;  // 2.5 MB
    localparam [23:0]   RAM_ADDR_BIOS           = 24'h70_0000;
    localparam [23:0]   RAM_ADDR_BIOS_NEXTOR    = RAM_ADDR_BIOS;
    localparam [23:0]   RAM_ADDR_BIOS_FM        = (RAM_ADDR_BIOS_NEXTOR + FLASH_SIZE_BIOS_NEXTOR);
    localparam [23:0]   RAM_ADDR_PAC            = 24'h77_E000;
    // RAM_ADDR_VRAM mantenido como alias de RAM_ADDR_WAVE_SRAM_EXT por
    // compat con tnCart_board_wt200b_top.sv:242 (assign UMA.ADDR[1]).
    // V9990 está deshabilitado, así que UMA no se instancia y este
    // valor solo participa en un assign muerto. La misma dirección
    // física es ahora Sample RAM ext del Wave block.
    localparam [23:0]   RAM_ADDR_VRAM           = RAM_ADDR_WAVE_SRAM_EXT;

    // (Las direcciones SDRAM del Wave block YMF278B están definidas
    //  arriba en el bloque de RAM map junto con MEM MAPPER, MEGA ROM,
    //  Nextor, FM, etc. Ver RAM_ADDR_YRW801 / RAM_ADDR_WAVE_SRAM_*.)

    /***************************************************************
     * アッテネータ
     ***************************************************************/
    // 3.5mm ジャック
    localparam          ATT_EXT_PSG_MUL         = 1;
    localparam          ATT_EXT_PSG_DIV         = 1;
    localparam          ATT_EXT_FM_MUL          = 1;
    localparam          ATT_EXT_FM_DIV          = 1;
    localparam          ATT_EXT_MEGAROM_MUL     = 1;
    localparam          ATT_EXT_MEGAROM_DIV     = 1;
    localparam          ATT_EXT_OPL3_MUL        = 1;
    localparam          ATT_EXT_OPL3_DIV        = 1;

    // MSX 本体側
    localparam          ATT_INT_FM_MUL          = 9;
    localparam          ATT_INT_FM_DIV          = 4;
    localparam          ATT_INT_MEGAROM_MUL     = 9;
    localparam          ATT_INT_MEGAROM_DIV     = 4;
    localparam          ATT_INT_OPL3_MUL        = 9;
    localparam          ATT_INT_OPL3_DIV        = 4;

    /***************************************************************
     * 機能
     ***************************************************************/
    localparam          ENABLE_MEGAROM          = ENABLE;           // メガロムカートリッジを有効にするか(DISABLE/ENABLE/ENABLE_MEGA_SCC/ENABLE_MEGA_SCC_I)
    localparam          ENABLE_FM               = ENABLE_IKAOPLL;   // FM 音源カートリッジを有効にするか(DISABLE/ENABLE_VM2413/ENABLE_IKAOPLL)
    localparam          ENABLE_NEXTOR           = ENABLE;           // NEXTOR カートリッジを有効にするか(DISABLE/ENABLE)
    localparam          ENABLE_RAM              = ENABLE;           // 拡張 RAM カートリッジを有効にするか(DISABLE/ENABLE)
    localparam          ENABLE_PSG              = ENABLE;           // PSG を有効にするか(DISABLE/ENABLE)
    localparam          ENABLE_SCC              = ENABLE;           // SCC を有効にするか(DISABLE/ENABLE/ENABLE_IKASCC)
    localparam          ENABLE_V9990            = DISABLE;          // MangOPL4: deshabilitado para liberar CLS (estaba al 100% con OPL3+V9990)
    localparam          ENABLE_OPL3             = ENABLE;           // MangOPL4: OPL3 (MoonSound FM) en C4-C7h
    localparam          ENABLE_V9990_CMD        = DISABLE;          // MangOPL4: deshabilitado junto con V9990
    localparam          ENABLE_PAC_WRITE        = ENABLE;           // PAC データを FLASH に保存するか(DISABLE/ENABLE)
    localparam          ENABLE_SCANLINE         = DISABLE;          // 200ラインモード時に走査線の隙間を空ける

    localparam          ENABLE_DAC_I2S          = DISABLE;          // I2S DAC を使用するか(DISABLE/ENABLE)
    localparam          ENABLE_DAC_STEREO       = DISABLE;          // ステレオ出力を有効にするか(DISABLE/ENABLE)

    /***************************************************************
     * other(ここを変更すると動作しなくなる可能性があります)
     ***************************************************************/
    localparam          RAM_IF_EXPANSION_USES_FF= 0;                // RAM I/F 拡張動作に FF を使用(0=使用しない/1=使用する)
    localparam          SLOT_EXPANSION_USES_FF  = 1;                // SLOT 拡張に FF を使用(0=使用しない/1=使用する)
    localparam          SOUND_BIT_WIDTH         = 10;               // サウンド生成の量子化幅(bits)
endpackage

`default_nettype wire
