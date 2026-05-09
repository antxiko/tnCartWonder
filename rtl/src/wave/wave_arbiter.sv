//
// wave_arbiter.sv — mini-arbiter del wave block (mempointer vs fetch1).
//
// 2 entradas (priority A=mempointer > B=fetch1), 1 salida hacia el
// RAM_IF externo del wave block (= ExpRam[RAM_WAVE]).
//
// HISTORIA DEL DISEÑO. Versiones previas v1-v4 fallaron en hardware
// Gowin (silent fail o cuelgue MSX) pero pasaban Verilator. Causa
// raíz tras debug: **Gowin sintetiza mal FFs con CE-style condicional
// `else if (interface_modport_signal)`**. La señal de enable se
// pierde (FF nunca actualiza) y grant_a_held queda atascado en 0.
// La passthrough simple funciona porque no tiene FFs. Las versiones
// con `else if (Primary.TIMING)` o `else if (timing_in_wire)` (v3/v4)
// se rompen idénticamente.
//
// v5 (esta) evita el patrón problemático:
//   1. FF expresado con D input como mux completo (sin `else if`).
//   2. Sticky `active_a/b`: set cuando host pide, clear cuando ACK_n=1
//      sin nuevo request.
//   3. Passthrough OR/AND collapse para ADDR/DIN/etc.
//   4. ACK_n gateado por active.
//
// Validado en hardware MSX real (wavemem PASS, sin regresión en
// MoonBlaster FM / VGMPlay OPL3 / Nextor boot).
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module wave_arbiter (
    input  wire             RESET_n,
    input  wire             CLK,
    RAM_IF.HOST             Primary,
    RAM_IF.DEVICE           BusA,
    RAM_IF.DEVICE           BusB
);

    // Passthrough OR/AND collapse
    assign Primary.ADDR     = BusA.ADDR     | BusB.ADDR;
    assign Primary.DIN      = BusA.DIN      | BusB.DIN;
    assign Primary.DIN_SIZE = BusA.DIN_SIZE | BusB.DIN_SIZE;
    assign Primary.OE_n     = BusA.OE_n     & BusB.OE_n;
    assign Primary.WE_n     = BusA.WE_n     & BusB.WE_n;
    assign Primary.RFSH_n   = BusA.RFSH_n   & BusB.RFSH_n;

    wire requesting_a = !BusA.OE_n || !BusA.WE_n || !BusA.RFSH_n;
    wire requesting_b = !BusB.OE_n || !BusB.WE_n || !BusB.RFSH_n;

    // Sticky FF "active": set on request, clear on ACK_n=1 + no req.
    // Sin clock-enable: D input es mux completo.
    reg active_a;
    reg active_b;
    wire other_a_active = active_a || active_b;
    wire other_b_active = active_a || active_b;

    wire next_active_a = (active_a && (!Primary.ACK_n || requesting_a)) ||
                         (!active_a && !active_b && requesting_a);
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

    wire grant_a = active_a;
    wire grant_b = active_b;

    assign BusA.DOUT   = Primary.DOUT;
    assign BusA.ACK_n  = grant_a ? Primary.ACK_n : 1'b1;
    assign BusA.TIMING = Primary.TIMING;

    assign BusB.DOUT   = Primary.DOUT;
    assign BusB.ACK_n  = grant_b ? Primary.ACK_n : 1'b1;
    assign BusB.TIMING = Primary.TIMING;

endmodule

`default_nettype wire
