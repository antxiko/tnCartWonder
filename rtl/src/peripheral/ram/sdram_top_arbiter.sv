//
// sdram_top_arbiter.sv — top-level arbiter SDRAM de 2 entradas con
// priority A > B y OR-collapse passthrough (gateado en B por priority).
//
// Entradas:
//   BusA = OUTPUT del EXPANSION_RAM con los 5 hosts MSX (cartridge_ram,
//          megarom, nextor, fm, bootloader). Estos hosts NO chequean
//          ACK_n y NO drivean WAIT_n (auditoría 2c.1, ver comentarios
//          en cartridge_ram.sv / megarom_controller.sv / pacrom_controller.sv).
//   BusB = wave block (mempointer + fetch1 vía wave_arbiter v5). Estos
//          SÍ chequean ACK_n y usan patrón 1-pulse OE_n.
//
// Diseño: passthrough OR/AND collapse (igual que wave_arbiter v5 que
// validó funcionar en hardware), AÑADIENDO gate por priority sobre las
// señales de B. Cuando A está requesting o active, B se MUTEA: sus
// ADDR/DIN/OE_n/WE_n no llegan a Primary. Esto evita el bug 2c.2.e.2b
// (OR-collapse corrompe save_addr cuando A y B asertan a la vez).
//
// Por qué NO un MUX puro gated por sticky-grant FF:
//   El sticky-grant FF tiene 1 ciclo de delay entre el request de B y
//   la propagación a Primary. SDRAM ve la asertición de B 1 ciclo más
//   tarde, así que Primary.ACK_n=0 llega 1 ciclo más tarde, y la
//   condición `(active_b && !Primary.ACK_n)` cae antes de que B pueda
//   ver ACK_n=0 → deadlock B. El passthrough OR-collapse evita ese
//   delay (la señal de B llega a Primary el mismo ciclo).
//
// Reglas:
//   1. Priority A > B fija. A nunca espera por B.
//   2. Cuando A está requesting OR active: las señales de B se MUTEA
//      (no propagan a Primary). B se queda en S_IDLE esperando.
//   3. Cuando A no está requesting NI active: B puede asertar
//      libremente. Una vez asertado y la SDRAM granta ACK, active_b
//      sticky mantiene el ACK gating hasta que la transacción termine.
//   4. ACK_n: solo el granted ve el ACK real; el otro ve ACK_n=1.
//   5. DOUT broadcast a ambos.
//   6. TIMING: A ve TIMING real. B ve TIMING gateado por priority,
//      así mempointer/fetch1 (gate por Ram.TIMING) solo asertan cuando
//      tienen luz verde para ser granted.
//
// Patrón Gowin: FFs SIN clock-enable condicional sobre modport signal
// (workaround del bug Gowin descubierto en wave_arbiter v5).
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module sdram_top_arbiter (
    input  wire             RESET_n,
    input  wire             CLK,
    RAM_IF.HOST             Primary,    // → SDRAM controller
    RAM_IF.DEVICE           BusA,       // ← EXPANSION_RAM (5 hosts MSX)
    RAM_IF.DEVICE           BusB        // ← wave block
);

    /***************************************************************
     * Detección de requests (combinacional)
     ***************************************************************/
    wire requesting_a = !BusA.OE_n || !BusA.WE_n || !BusA.RFSH_n;
    wire requesting_b = !BusB.OE_n || !BusB.WE_n || !BusB.RFSH_n;

    /***************************************************************
     * FSM sticky active_a / active_b — patrón validado en
     * wave_arbiter v5 (D input como mux completo, no else if).
     * Solo se usa para gating de ACK_n hacia A/B.
     ***************************************************************/
    reg active_a;
    reg active_b;

    wire next_active_a = (active_a && (!Primary.ACK_n || requesting_a)) ||
                         (!active_a && !active_b && requesting_a);

    // active_b solo arranca cuando A está fully idle (priority).
    wire next_active_b = (active_b && (!Primary.ACK_n || requesting_b)) ||
                         (!active_a && !active_b && requesting_b && !requesting_a);

    always_ff @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            active_a <= 1'b0;
            active_b <= 1'b0;
        end
        else begin
            active_a <= next_active_a;
            active_b <= next_active_b;
        end
    end

    /***************************************************************
     * Passthrough OR/AND collapse hacia Primary, con gate de priority
     * sobre B. Cuando A está requesting o active, B se mutea.
     ***************************************************************/
    wire allow_b_signals = !active_a && !requesting_a;

    assign Primary.ADDR     = BusA.ADDR     | (allow_b_signals ? BusB.ADDR     : 24'h0);
    assign Primary.DIN      = BusA.DIN      | (allow_b_signals ? BusB.DIN      : 32'h0);
    assign Primary.DIN_SIZE = BusA.DIN_SIZE | (allow_b_signals ? BusB.DIN_SIZE : 3'b000);
    assign Primary.OE_n     = BusA.OE_n     & (allow_b_signals ? BusB.OE_n     : 1'b1);
    assign Primary.WE_n     = BusA.WE_n     & (allow_b_signals ? BusB.WE_n     : 1'b1);
    assign Primary.RFSH_n   = BusA.RFSH_n   & (allow_b_signals ? BusB.RFSH_n   : 1'b1);

    /***************************************************************
     * Returns hacia A y B.
     ***************************************************************/
    // DOUT broadcast a ambos.
    assign BusA.DOUT   = Primary.DOUT;
    assign BusB.DOUT   = Primary.DOUT;

    // ACK_n: solo el granted ve ACK_n real. Crítico para que B
    // (mempointer/fetch1, que sí chequean ACK) no salte la FSM por ver
    // ACK_n=0 que no era para él.
    assign BusA.ACK_n  = active_a ? Primary.ACK_n : 1'b1;
    assign BusB.ACK_n  = active_b ? Primary.ACK_n : 1'b1;

    // TIMING:
    //   A ve TIMING real (no chequea, pero lo ofrecemos por simetría).
    //   B ve TIMING gateado por priority — solo true cuando A está
    //   totalmente idle. Así mempointer (gate por Ram.TIMING) solo
    //   asertaria cuando va a ser granted, evitando un assert perdido
    //   que dejaría su FSM esperando un ACK_n=0 que no llega.
    assign BusA.TIMING = Primary.TIMING;
    assign BusB.TIMING = Primary.TIMING && !active_a && !requesting_a;

endmodule

`default_nettype wire
