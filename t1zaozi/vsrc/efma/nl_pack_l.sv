//============================================================================
// nl_pack_l.sv — FP pack (L-mode) for the nonlinear unit
//
// Converts signed fixed-point to FP via leading-zero-counter normalization.
// Overflow/underflow handled silently (Inf/zero output).
//============================================================================

import nl_params::*;
import nl_config::*;

module nl_pack_l #(
    parameter int FMT = 1
) (
    input  logic signed [FMA_W(FMT)-1:0]  fixed_in,
    output logic [FP_W(FMT)-1:0]           fp_out
);

    localparam int MW = M(FMT);
    localparam int EW = EXP_BITS(FMT);
    localparam int BIAS_VAL = BIAS(FMT);
    localparam int FW = FP_W(FMT);
    localparam int FMAW = FMA_W(FMT);
    localparam int LZC_W = $clog2(FMAW);
    localparam int EXP_ALL_ONES = (1 << EW) - 1;

    logic [FMAW-1:0]        l_mag;
    logic [LZC_W-1:0]       lzc_cnt;
    logic                   l_sign;

    nl_lzc #(.WIDTH(FMAW)) u_lzc (
        .in_val(fixed_in),
        .lzc_count(lzc_cnt),
        .sign(l_sign)
    );

    always_comb begin
        l_mag = l_sign ? -fixed_in : fixed_in;
    end

    logic signed [EW+1:0]   l_exp;
    logic [MW-1:0]          l_mant_field;
    integer                 shift_amt;

    always_comb begin
        if (fixed_in == 0) begin
            fp_out = {l_sign, {(EW+MW){1'b0}}};
        end else begin
            l_exp = FMAW - 1 - lzc_cnt - F(FMT) + BIAS_VAL;
            shift_amt = FMAW - 1 - MW - lzc_cnt;
            if (shift_amt >= 0)
                l_mant_field = l_mag[shift_amt +: MW];
            else
                l_mant_field = l_mag << (-shift_amt);

            if (l_exp >= EXP_ALL_ONES)
                fp_out = {l_sign, {EW{1'b1}}, {MW{1'b0}}};  // Inf
            else if (l_exp <= 0)
                fp_out = {l_sign, {(EW+MW){1'b0}}};          // zero
            else
                fp_out = {l_sign, l_exp[EW-1:0], l_mant_field};
        end
    end

endmodule
