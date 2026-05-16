//
// ymf278_exp_lut.sv
//
// MangOPL4 Fase 2c.3.g — LUT exponencial 128×16 para conversión de
// Total Level (TL, 7-bit log) → linear scale (16-bit unsigned).
//
// Fórmula bit-exact contra openMSX YMF278.cc::volTable:
//   scale = round(65536 × 2^(-TL/16))
//
// Esto da 0.375 dB por step (formato YMF278B/OPL4).
//   TL=0    → 0xFFFF (full volume, max)
//   TL=16   → 0x8000 (= -6 dB, half)
//   TL=32   → 0x4000 (= -12 dB)
//   TL=64   → 0x1000 (= -24 dB)
//   TL=127  → 0x010B (= -47.6 dB, casi silencio)
//
// Combinacional (distributed ROM via case en LUTs). 128 entries × 16 bits
// = 2 Kbits, trivial.
//
// Uso típico: `wave atenuated = (sample × scale) >>> 16`. 1 DSP signed
// 17×17 → 33-bit shift right 16 → 17-bit, después saturar a 16-bit.
//
// BSD 3-Clause License
// Copyright (c) 2026, Jokin Miragaia <tech.fxmedia@gmail.com>
//
`default_nettype none

module ymf278_exp_lut (
    input  wire  [6:0]              tl,        // Total Level, 7-bit
    output logic [15:0]             scale      // linear scale, 16-bit unsigned
);
    always_comb begin
        case (tl)
            7'd0:   scale = 16'hFFFF;
            7'd1:   scale = 16'hF525;
            7'd2:   scale = 16'hEAC0;
            7'd3:   scale = 16'hE0CC;
            7'd4:   scale = 16'hD744;
            7'd5:   scale = 16'hCE24;
            7'd6:   scale = 16'hC567;
            7'd7:   scale = 16'hBD08;
            7'd8:   scale = 16'hB504;
            7'd9:   scale = 16'hAD58;
            7'd10:  scale = 16'hA5FE;
            7'd11:  scale = 16'h9EF5;
            7'd12:  scale = 16'h9837;
            7'd13:  scale = 16'h91C3;
            7'd14:  scale = 16'h8B95;
            7'd15:  scale = 16'h85AA;
            7'd16:  scale = 16'h8000;
            7'd17:  scale = 16'h7A92;
            7'd18:  scale = 16'h7560;
            7'd19:  scale = 16'h7066;
            7'd20:  scale = 16'h6BA2;
            7'd21:  scale = 16'h6712;
            7'd22:  scale = 16'h62B3;
            7'd23:  scale = 16'h5E84;
            7'd24:  scale = 16'h5A82;
            7'd25:  scale = 16'h56AC;
            7'd26:  scale = 16'h52FF;
            7'd27:  scale = 16'h4F7A;
            7'd28:  scale = 16'h4C1B;
            7'd29:  scale = 16'h48E1;
            7'd30:  scale = 16'h45CA;
            7'd31:  scale = 16'h42D5;
            7'd32:  scale = 16'h4000;
            7'd33:  scale = 16'h3D49;
            7'd34:  scale = 16'h3AB0;
            7'd35:  scale = 16'h3833;
            7'd36:  scale = 16'h35D1;
            7'd37:  scale = 16'h3389;
            7'd38:  scale = 16'h3159;
            7'd39:  scale = 16'h2F42;
            7'd40:  scale = 16'h2D41;
            7'd41:  scale = 16'h2B56;
            7'd42:  scale = 16'h297F;
            7'd43:  scale = 16'h27BD;
            7'd44:  scale = 16'h260D;
            7'd45:  scale = 16'h2470;
            7'd46:  scale = 16'h22E5;
            7'd47:  scale = 16'h216A;
            7'd48:  scale = 16'h2000;
            7'd49:  scale = 16'h1EA4;
            7'd50:  scale = 16'h1D58;
            7'd51:  scale = 16'h1C19;
            7'd52:  scale = 16'h1AE8;
            7'd53:  scale = 16'h19C4;
            7'd54:  scale = 16'h18AC;
            7'd55:  scale = 16'h17A1;
            7'd56:  scale = 16'h16A0;
            7'd57:  scale = 16'h15AB;
            7'd58:  scale = 16'h14BF;
            7'd59:  scale = 16'h13DE;
            7'd60:  scale = 16'h1306;
            7'd61:  scale = 16'h1238;
            7'd62:  scale = 16'h1172;
            7'd63:  scale = 16'h10B5;
            7'd64:  scale = 16'h1000;
            7'd65:  scale = 16'h0F52;
            7'd66:  scale = 16'h0EAC;
            7'd67:  scale = 16'h0E0C;
            7'd68:  scale = 16'h0D74;
            7'd69:  scale = 16'h0CE2;
            7'd70:  scale = 16'h0C56;
            7'd71:  scale = 16'h0BD0;
            7'd72:  scale = 16'h0B50;
            7'd73:  scale = 16'h0AD5;
            7'd74:  scale = 16'h0A5F;
            7'd75:  scale = 16'h09EF;
            7'd76:  scale = 16'h0983;
            7'd77:  scale = 16'h091C;
            7'd78:  scale = 16'h08B9;
            7'd79:  scale = 16'h085A;
            7'd80:  scale = 16'h0800;
            7'd81:  scale = 16'h07A9;
            7'd82:  scale = 16'h0756;
            7'd83:  scale = 16'h0706;
            7'd84:  scale = 16'h06BA;
            7'd85:  scale = 16'h0671;
            7'd86:  scale = 16'h062B;
            7'd87:  scale = 16'h05E8;
            7'd88:  scale = 16'h05A8;
            7'd89:  scale = 16'h056A;
            7'd90:  scale = 16'h052F;
            7'd91:  scale = 16'h04F7;
            7'd92:  scale = 16'h04C1;
            7'd93:  scale = 16'h048E;
            7'd94:  scale = 16'h045C;
            7'd95:  scale = 16'h042D;
            7'd96:  scale = 16'h0400;
            7'd97:  scale = 16'h03D4;
            7'd98:  scale = 16'h03AB;
            7'd99:  scale = 16'h0383;
            7'd100: scale = 16'h035D;
            7'd101: scale = 16'h0338;
            7'd102: scale = 16'h0315;
            7'd103: scale = 16'h02F4;
            7'd104: scale = 16'h02D4;
            7'd105: scale = 16'h02B5;
            7'd106: scale = 16'h0297;
            7'd107: scale = 16'h027B;
            7'd108: scale = 16'h0260;
            7'd109: scale = 16'h0247;
            7'd110: scale = 16'h022E;
            7'd111: scale = 16'h0216;
            7'd112: scale = 16'h0200;
            7'd113: scale = 16'h01EA;
            7'd114: scale = 16'h01D5;
            7'd115: scale = 16'h01C1;
            7'd116: scale = 16'h01AE;
            7'd117: scale = 16'h019C;
            7'd118: scale = 16'h018A;
            7'd119: scale = 16'h017A;
            7'd120: scale = 16'h016A;
            7'd121: scale = 16'h015A;
            7'd122: scale = 16'h014B;
            7'd123: scale = 16'h013D;
            7'd124: scale = 16'h0130;
            7'd125: scale = 16'h0123;
            7'd126: scale = 16'h0117;
            7'd127: scale = 16'h010B;
            default: scale = 16'h0000;
        endcase
    end
endmodule

`default_nettype wire
