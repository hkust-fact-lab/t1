//============================================================================
// nl_pack_e.sv — FP pack (E-mode) for the nonlinear unit
//
// Packs sign + integer exponent I + exp2 mantissa into an FP word.
// Checks I+bias range for overflow→Inf / underflow→0.
//============================================================================

import nl_params::*;
import nl_config::*;

module nl_pack_e #(
    parameter int FMT = 1
) (
    input  logic                         pack_sign,
    input  logic signed [FMA_IW(FMT):0]  exp_in,
    input  logic [M(FMT):0]              mant_in,
    output logic [FP_W(FMT)-1:0]         fp_out,
    output logic                         overflow, underflow
);

    localparam int MW = M(FMT);
    localparam int EW = EXP_BITS(FMT);
    localparam int BIAS_VAL = BIAS(FMT);
    localparam int EXP_ALL_ONES = (1 << EW) - 1;

    logic signed [EW+1:0] biased_e;
    always_comb begin
        biased_e = exp_in + BIAS_VAL;

        if (biased_e >= EXP_ALL_ONES) begin
            fp_out    = {pack_sign, {EW{1'b1}}, {MW{1'b0}}};
            overflow  = 1'b1;
            underflow = 1'b0;
        end else if (biased_e <= 0) begin
            fp_out    = {pack_sign, {(EW+MW){1'b0}}};
            overflow  = 1'b0;
            underflow = 1'b1;
        end else begin
            fp_out    = {pack_sign, biased_e[EW-1:0], mant_in[MW-1:0]};
            overflow  = 1'b0;
            underflow = 1'b0;
        end
    end

endmodule
