//
// cartridge_opl3.sv
//
// MangOPL4 — wrapper del core OPL3 (gtaylormb/opl3_fpga) para tnCartWonder.
// Decodifica C4h-C7h del bus MSX (mapeo nativo MoonSound FM) y conecta al
// módulo `opl3` del core. Salida PCM 24-bit signed estéreo se promedia y se
// trunca a SOUND_BIT_WIDTH bits (signed, top bit = signo) para alimentar al
// SOUND_MIXER existente.
//
// El core tiene host_if con FIFO async entre clk_host (=CLK del bus MSX) y
// clk (=CLK_OPL3 = 33.5625 MHz). Las escrituras se sincronizan vía esa FIFO,
// no hace falta CDC adicional.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module CARTRIDGE_OPL3 (
    input   wire            RESET_n,
    input   wire            CLK,        // 107.4 MHz, dominio bus MSX (clk_host)
    input   wire            CLK_OPL3,   // 33.5625 MHz, dominio core OPL3
    BUS_IF.CARTRIDGE        Bus,
    SOUND_IF.OUT            Sound
);

    /***************************************************************
     * Bus.INT_n: IRQ del core OPL3 hacia el MSX, en modo PULSO+GAP+REPEAT.
     *
     * Razón: VGMPlay-MSX hace OPLTimer_Detect que arranca Timer1 antes
     * de instalar su propio IRQ handler. Si en ese momento tenemos
     * INT_n asserted de forma sostenida, Z80 entra en BIOS ISR (JP 0x38)
     * que no limpia ft1 del OPL3 → tormenta IRQ → cuelgue.
     *
     * Tu pista (re: 2º run sin sonido) reveló también que un único pulso
     * por flanco no funciona: si Z80 pierde 1 IRQ (en sección DI), el
     * detector de flanco no vuelve a disparar (irq_active queda en 1
     * sin transición). Recovery imposible.
     *
     * Solución: máquina pulso+gap+repeat:
     *   - PULSE 5 µs (INT_n=0): suficiente para que Z80 capture IRQ
     *   - GAP 50 µs (INT_n=1): > BIOS handler (~50 µs), permite RETI
     *     antes del próximo pulso (no causa storm en detección)
     *   - Toggle continuo PULSE↔GAP mientras irq_active=1
     *   - Reset máquina cuando irq_active=0 (handler limpió ft1)
     * Esto recupera de IRQs perdidos: el siguiente pulso a 55 µs es
     * nueva oportunidad de captura.
     ***************************************************************/
    assign Bus.WAIT_n = 1;
    wire opl3_irq_n_raw;

    // Settle counter — evita glitches power-on antes de empezar a
    // mirar irq_n_raw (Gowin no honra init en output ports).
    logic [4:0] settle_count = 0;
    always_ff @(posedge CLK_OPL3 or negedge RESET_n) begin
        if (!RESET_n)                       settle_count <= 5'd0;
        else if (!Bus.RESET_n)              settle_count <= 5'd0;
        else if (settle_count != 5'h1F)     settle_count <= settle_count + 5'd1;
    end
    wire armed = (settle_count == 5'h1F);

    wire  irq_active = !opl3_irq_n_raw;
    localparam PULSE_CYCLES = 11'd168;   // 5 µs a 33.5625 MHz
    localparam GAP_CYCLES   = 11'd1678;  // 50 µs a 33.5625 MHz
    localparam MAX_PULSES   = 6'd32;     // tras 32 pulsos sin ack, dar por
                                          // perdido y holdear INT_n alto.
                                          // Evita storm cuando software no
                                          // limpia ft1 (ej: tras exit de
                                          // VGMPlay).
    logic [10:0] state_count;
    logic        in_pulse;   // 1 = INT_n bajo, 0 = INT_n alto (gap)
    logic [5:0]  miss_count; // pulsos consecutivos sin ack
    logic        gave_up;    // 1 = dejé de pulsar hasta que irq_active=0
    always_ff @(posedge CLK_OPL3 or negedge RESET_n) begin
        if (!RESET_n) begin
            state_count <= 11'd0;
            in_pulse    <= 1'b0;
            miss_count  <= 6'd0;
            gave_up     <= 1'b0;
        end
        else if (!Bus.RESET_n) begin
            state_count <= 11'd0;
            in_pulse    <= 1'b0;
            miss_count  <= 6'd0;
            gave_up     <= 1'b0;
        end
        else if (!armed || !irq_active) begin
            // Software reconoció IRQ (o no hay IRQ pendiente). Reset todo.
            state_count <= 11'd0;
            in_pulse    <= 1'b0;
            miss_count  <= 6'd0;
            gave_up     <= 1'b0;
        end
        else if (gave_up) begin
            // Rendido. Mantener INT_n alto hasta próximo evento de ack.
            state_count <= 11'd0;
            in_pulse    <= 1'b0;
        end
        else if (state_count == 11'd0) begin
            if (in_pulse) begin
                state_count <= GAP_CYCLES - 11'd1;
                in_pulse    <= 1'b0;
            end
            else begin
                if (miss_count == MAX_PULSES) begin
                    gave_up    <= 1'b1;
                    in_pulse   <= 1'b0;
                end
                else begin
                    state_count <= PULSE_CYCLES - 11'd1;
                    in_pulse    <= 1'b1;
                    miss_count  <= miss_count + 6'd1;
                end
            end
        end
        else begin
            state_count <= state_count - 11'd1;
        end
    end
    wire int_n_pulse_clk_opl3 = !in_pulse;  // 1 cuando NO en pulso

    // Sincronizador 2-FF a CLK (clk_host)
    logic int_n_s1, int_n_s2;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            int_n_s1 <= 1'b1;
            int_n_s2 <= 1'b1;
        end
        else begin
            int_n_s1 <= int_n_pulse_clk_opl3;
            int_n_s2 <= int_n_s1;
        end
    end
    assign Bus.INT_n = int_n_s2;

    /***************************************************************
     * Decodificación C4h-C7h (0xC4>>2 = 0x31 = 6'b110001)
     ***************************************************************/
    wire cs_opl3   = !Bus.IORQ_n && (Bus.ADDR[7:2] == 6'b110001);
    wire rd_opl3   = cs_opl3 && !Bus.RD_n;
    wire opl3_cs_n = !cs_opl3;

    /***************************************************************
     * Puerto Wave 7Eh-7Fh — Fase 2 sub-fase 2a:
     * decodificación + edge detection del write strobe del bus MSX.
     * El motor real vive en wave/ymf278_top.sv. En 2a solo produce una
     * onda cuadrada interna cuando se hace key-on en slot 0
     * (registro 0x68 bit 7). Read-back sigue devolviendo 0x20 stub
     * para preservar detección MoonSound de VGMPlay.
     ***************************************************************/
    wire cs_wave  = !Bus.IORQ_n && (Bus.ADDR[7:1] == 7'b0111111);
    wire rd_wave  = cs_wave && !Bus.RD_n;
    wire rd_wave_data = rd_wave && Bus.ADDR[0];   // solo 7F drivea

    // Edge detection del write strobe del puerto Wave (mismo patrón
    // que el OPL3 más abajo, pero independiente).
    logic prev_wave_wr_active = 0;
    wire  wave_wr_active = cs_wave && !Bus.WR_n;
    wire  wave_wr_strobe = wave_wr_active && !prev_wave_wr_active;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n || !Bus.RESET_n) prev_wave_wr_active <= 1'b0;
        else                          prev_wave_wr_active <= wave_wr_active;
    end

    /***************************************************************
     * Shadow register file — emula la legibilidad de registros
     * OPL3 que tiene el YMF278B real (verificado en openMSX
     * YMF278B.cc: read C5/C7 devuelve ymf262.readReg(opl3latch)).
     * El core gtaylormb es OPL3 puro y no expone read-back; aquí
     * capturamos las escrituras del bus y mantenemos un mirror de
     * 256 bytes × 2 banks. Sin esto MoonBlaster FM y similares
     * fallan la detección write/read-verify.
     *
     * En el YMF278B real, status read aparece en C4 Y C6
     * (port&0x03 == 0 ó 2). Aquí lo replicamos.
     ***************************************************************/
    logic [7:0] shadow_b0 [0:255];
    logic [7:0] shadow_b1 [0:255];
    logic [7:0] sel_reg_b0 = 0;
    logic [7:0] sel_reg_b1 = 0;

    // Detecta flanco ascendente del strobe de escritura en el bus
    logic prev_wr_active = 0;
    wire  wr_active = cs_opl3 && !Bus.WR_n;
    wire  wr_strobe = wr_active && !prev_wr_active;

    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n || !Bus.RESET_n) begin
            prev_wr_active <= 1'b0;
            sel_reg_b0 <= 8'd0;
            sel_reg_b1 <= 8'd0;
        end
        else begin
            prev_wr_active <= wr_active;
            if (wr_strobe) begin
                case (Bus.ADDR[1:0])
                    2'b00: sel_reg_b0 <= Bus.DIN;
                    2'b01: shadow_b0[sel_reg_b0] <= Bus.DIN;
                    2'b10: sel_reg_b1 <= Bus.DIN;
                    2'b11: shadow_b1[sel_reg_b1] <= Bus.DIN;
                endcase
            end
        end
    end

    /***************************************************************
     * Mux de lectura: status del core en C4/C6, registro shadow en
     * C5/C7. YMF278B drivea en cualquier read C4-C7.
     ***************************************************************/
    wire [7:0] opl3_dout;
    logic [7:0] read_data;
    always_comb begin
        case (Bus.ADDR[1:0])
            2'b00, 2'b10: read_data = opl3_dout;                  // status (mirror C4/C6)
            2'b01:        read_data = shadow_b0[sel_reg_b0];      // bank 0 register
            2'b11:        read_data = shadow_b1[sel_reg_b1];      // bank 1 register
            default:      read_data = 8'h00;
        endcase
    end

    /***************************************************************
     * Motor Wave (Fase 2). En 2a produce square wave interna en slot 0
     * cuando se hace key-on (write a registro 0x68 con bit 7).
     ***************************************************************/
    // Width 24 hardcoded para evitar dependencia de DAC_W (declarado más
     // abajo). opl3_pkg::DAC_OUTPUT_WIDTH = 24.
    wire [7:0]               wave_rd_data;
    wire signed [23:0]       wave_sample;
    ymf278_top u_wave (
        .RESET_n        (RESET_n),
        .CLK            (CLK),
        .CLK_OPL3       (CLK_OPL3),
        .bus_reset_n    (Bus.RESET_n),
        .new2           (shadow_b1[8'h05][1]),  // bit 1 = NEW2 (verificado en openMSX YMF278B.cc:203)
        .wr_strobe      (wave_wr_strobe),
        .addr0          (Bus.ADDR[0]),
        .din            (Bus.DIN),
        .rd_data        (wave_rd_data),
        .wave_sample    (wave_sample)
    );

    // YMF278B drivea bus en cualquier read C4-C7 + 7F (7E flota)
    assign Bus.BUSDIR_n = !(rd_opl3 || rd_wave_data);
    assign Bus.DOUT     = rd_opl3       ? read_data :
                          rd_wave_data  ? wave_rd_data :  // 0x20 stub en 2a
                                          8'h00;

    /***************************************************************
     * Instancia del core gtaylormb/opl3_fpga
     ***************************************************************/
    wire signed [opl3_pkg::DAC_OUTPUT_WIDTH-1:0] sample_l;
    wire signed [opl3_pkg::DAC_OUTPUT_WIDTH-1:0] sample_r;
    wire        sample_valid;
    /* verilator lint_off PINMISSING */
    opl3 u_opl3 (
        .clk            (CLK_OPL3),
        .clk_host       (CLK),
        .clk_dac        (1'b0),                 // INSTANTIATE_SAMPLE_SYNC_TO_DAC_CLK=0
        .ic_n           (RESET_n && Bus.RESET_n),
        .cs_n           (opl3_cs_n),
        .rd_n           (Bus.RD_n),
        .wr_n           (Bus.WR_n),
        .address        (Bus.ADDR[1:0]),
        .din            (Bus.DIN),
        .dout           (opl3_dout),
        .sample_valid   (sample_valid),
        .sample_l       (sample_l),
        .sample_r       (sample_r),
        .led            (),
        .irq_n          (opl3_irq_n_raw),
        // mangopl4: cuando el watchdog del IRQ se rinde, también
        // forzamos limpieza de st1/st2/ft1/ft2 dentro del core. Sin
        // esto, tras un exit "natural" de VGMPlay (Timer1 sigue
        // corriendo, ft1 sticky), el siguiente arranque no detecta
        // MoonSound porque el chip no se reinicializa limpio.
        .force_clear_flags (gave_up)
    );
    /* verilator lint_on PINMISSING */

    /***************************************************************
     * Promedio L+R del FM, sumado con wave_sample (Wave block), luego
     * amplificación con shift-left saturante (64x), y truncado a
     * SOUND_BIT_WIDTH bits (signed, top=signo).
     *
     * Sin amplificación el rango efectivo del core gtaylormb (~±2^17
     * dentro del DAC de 24 bits) deja el signal a 1/64 de full-scale
     * en 10 bits, audible pero muy bajo. GAIN_BITS=6 (64x) lleva el
     * pico típico cerca de full-scale 10-bit con saturación en peaks.
     *
     * wave_sample ya viene en formato 24-bit signed (sign-extended
     * desde 16-bit) por lo que se suma directamente al FM averaged.
     * En 2a el wave_sample tiene rango ±2^14 (square wave 16-bit
     * a media escala), que tras gain 64x queda a ±2^20 ≈ 1/8 de
     * full-scale 24-bit. Audible sin saturar.
     ***************************************************************/
    localparam DAC_W = opl3_pkg::DAC_OUTPUT_WIDTH;
    localparam SND_W = $bits(Sound.Signal);
    localparam GAIN_BITS = 6;

    // FM mono averaged + Wave summed, todo en CLK_OPL3 domain.
    logic signed [DAC_W-1:0] mono_q;
    always_ff @(posedge CLK_OPL3) begin
        mono_q <= DAC_W'(
            (({sample_l[DAC_W-1], sample_l} + {sample_r[DAC_W-1], sample_r}) >>> 1)
            + {wave_sample[DAC_W-1], wave_sample}   // sign-extend 1 bit y sumar
        );
    end

    // Saturating shift-left por GAIN_BITS: detecta si los GAIN_BITS bits
    // por debajo del signo no coinciden con el signo (overflow), y satura.
    wire signed [DAC_W-1:0] mono_shifted = mono_q <<< GAIN_BITS;
    wire ovf_pos = !mono_q[DAC_W-1] &&  |mono_q[DAC_W-2 -: GAIN_BITS];
    wire ovf_neg =  mono_q[DAC_W-1] && ~&mono_q[DAC_W-2 -: GAIN_BITS];

    logic signed [DAC_W-1:0] mono_amp;
    always_ff @(posedge CLK_OPL3) begin
        if (ovf_pos)      mono_amp <= {1'b0, {(DAC_W-1){1'b1}}};
        else if (ovf_neg) mono_amp <= {1'b1, {(DAC_W-1){1'b0}}};
        else              mono_amp <= mono_shifted;
    end

    // Cruce de dominio CLK_OPL3 → CLK por simple registro.
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n || !Bus.RESET_n) begin
            Sound.Signal <= 0;
        end
        else begin
            Sound.Signal <= mono_amp[DAC_W-1 -: SND_W];
        end
    end

endmodule

`default_nettype wire
