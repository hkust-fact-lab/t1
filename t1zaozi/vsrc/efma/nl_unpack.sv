//============================================================================
// nl_unpack.sv — FP unpack for the nonlinear unit
//
// Extracts sign, bias-subtracted exponent, and mantissa (fractional only).
// Detects specials (Inf/NaN/zero). Subnormals flushed to zero.
//============================================================================

import nl_params::*;
import nl_config::*;

module nl_unpack #(
    parameter int FMT = 1
) (
    input  logic [FP_W(FMT)-1:0]                   fp_in_a, fp_in_b,
    output logic                                   sign_a, sign_b,
    output logic signed [EXP_BITS(FMT):0]           exp_a, exp_b,
    output logic [M(FMT)-1:0]                      mant_a, mant_b,
    output logic                                   a_special, b_special,
    output logic                                   a_is_zero, b_is_zero
);

    localparam int MW = M(FMT);
    localparam int EW = EXP_BITS(FMT);
    localparam int BIAS_VAL = BIAS(FMT);
    localparam int FW = FP_W(FMT);
    localparam int EXP_ALL_ONES = (1 << EW) - 1;
    localparam int SIGN_BIT = FW - 1;

    function automatic void do_unpack(
        input  logic [FW-1:0] fp,
        output logic          sgn,
        output logic signed [EW:0] exp_out,
        output logic [MW-1:0] mant_out,
        output logic          special,
        output logic          is_zero
    );
        logic [EW-1:0] raw_exp;
        logic [MW-1:0] raw_mant;

        sgn     = fp[SIGN_BIT];
        raw_exp = fp[MW +: EW];
        raw_mant = fp[MW-1:0];

        if (raw_exp == 0) begin
            exp_out  = -BIAS_VAL;
            mant_out = 0;
            special  = 1'b1;
            is_zero  = 1'b1;
        end else if (raw_exp == EXP_ALL_ONES) begin
            exp_out  = raw_exp - BIAS_VAL;
            mant_out = raw_mant;
            special  = 1'b1;
            is_zero  = 1'b0;
        end else begin
            exp_out  = raw_exp - BIAS_VAL;
            mant_out = raw_mant;
            special  = 1'b0;
            is_zero  = 1'b0;
        end
    endfunction

    always_comb begin
        do_unpack(fp_in_a, sign_a, exp_a, mant_a, a_special, a_is_zero);
        do_unpack(fp_in_b, sign_b, exp_b, mant_b, b_special, b_is_zero);
    end

endmodule
