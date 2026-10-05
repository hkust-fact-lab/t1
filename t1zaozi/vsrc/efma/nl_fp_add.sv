//============================================================================
// nl_fp_add.sv — Target-format floating-point add for the EFMA c operand
//
// Supports BF16 and FP32 with round-to-nearest-even.  Subnormal operands and
// subnormal results follow the nonlinear unit's existing flush-to-zero policy.
//============================================================================

import nl_params::*;

module nl_fp_add #(
    parameter int FMT = 1
) (
    input  logic [FP_W(FMT)-1:0] lhs,
    input  logic [FP_W(FMT)-1:0] rhs,
    output logic [FP_W(FMT)-1:0] sum,
    output logic                  overflow,
    output logic                  underflow
);

    localparam int MW = M(FMT);
    localparam int EW = EXP_BITS(FMT);
    localparam int FW = FP_W(FMT);
    localparam int SW = MW + 1;
    localparam int EXT_W = SW + 3;  // significand plus guard/round/sticky

    logic lhs_sign, rhs_sign, result_sign;
    logic [EW-1:0] lhs_exp, rhs_exp;
    logic [MW-1:0] lhs_mant, rhs_mant;
    logic lhs_zero, rhs_zero, lhs_inf, rhs_inf, lhs_nan, rhs_nan;
    logic [SW-1:0] lhs_sig, rhs_sig, rounded_sig;
    logic [EXT_W-1:0] lhs_ext, rhs_ext;
    logic [EXT_W-1:0] large_ext, small_ext, aligned_small;
    logic [EXT_W-1:0] normalized, difference;
    logic [EXT_W:0] add_result;
    logic [SW:0] rounded_ext;
    logic [EW-1:0] large_exp;
    logic round_increment;
    logic found_one;
    integer exponent_work;
    integer align_shift;
    integer normalize_shift;
    integer bit_i;

    function automatic logic [EXT_W-1:0] shift_right_sticky(
        input logic [EXT_W-1:0] value,
        input integer shift
    );
        logic [EXT_W-1:0] shifted;
        logic sticky;
        integer i;
        begin
            shifted = '0;
            sticky = 1'b0;
            if (shift <= 0) begin
                shifted = value;
            end else if (shift >= EXT_W) begin
                shifted[0] = |value;
            end else begin
                shifted = value >> shift;
                for (i = 0; i < EXT_W; i = i + 1) begin
                    if (i < shift)
                        sticky = sticky | value[i];
                end
                shifted[0] = shifted[0] | sticky;
            end
            return shifted;
        end
    endfunction

    always_comb begin
        lhs_sign = lhs[FW-1];
        rhs_sign = rhs[FW-1];
        lhs_exp  = lhs[MW +: EW];
        rhs_exp  = rhs[MW +: EW];
        lhs_mant = lhs[MW-1:0];
        rhs_mant = rhs[MW-1:0];

        lhs_zero = (lhs_exp == '0);
        rhs_zero = (rhs_exp == '0);
        lhs_inf  = (lhs_exp == {EW{1'b1}}) && (lhs_mant == '0);
        rhs_inf  = (rhs_exp == {EW{1'b1}}) && (rhs_mant == '0);
        lhs_nan  = (lhs_exp == {EW{1'b1}}) && (lhs_mant != '0);
        rhs_nan  = (rhs_exp == {EW{1'b1}}) && (rhs_mant != '0);

        sum = '0;
        overflow = 1'b0;
        underflow = 1'b0;
        result_sign = 1'b0;
        lhs_sig = {1'b1, lhs_mant};
        rhs_sig = {1'b1, rhs_mant};
        lhs_ext = {lhs_sig, 3'b000};
        rhs_ext = {rhs_sig, 3'b000};
        large_ext = '0;
        small_ext = '0;
        aligned_small = '0;
        normalized = '0;
        difference = '0;
        add_result = '0;
        rounded_ext = '0;
        rounded_sig = '0;
        large_exp = '0;
        round_increment = 1'b0;
        found_one = 1'b0;
        exponent_work = 0;
        align_shift = 0;
        normalize_shift = 0;

        if (lhs_nan || rhs_nan ||
            (lhs_inf && rhs_inf && (lhs_sign != rhs_sign))) begin
            sum = {1'b0, {EW{1'b1}}, 1'b1, {(MW-1){1'b0}}};
        end else if (lhs_inf) begin
            sum = {lhs_sign, {EW{1'b1}}, {MW{1'b0}}};
        end else if (rhs_inf) begin
            sum = {rhs_sign, {EW{1'b1}}, {MW{1'b0}}};
        end else if (rhs_zero) begin
            // c=0 is the EFMA identity operation.  Preserve the body result's
            // sign, including a signed zero produced by sign_passthru/FTZ.
            sum = lhs;
        end else if (lhs_zero) begin
            sum = rhs;
        end else begin
            // Select the larger magnitude, then align the smaller operand.
            if ((lhs_exp > rhs_exp) ||
                ((lhs_exp == rhs_exp) && (lhs_sig >= rhs_sig))) begin
                large_exp = lhs_exp;
                large_ext = lhs_ext;
                small_ext = rhs_ext;
                result_sign = lhs_sign;
                align_shift = lhs_exp - rhs_exp;
            end else begin
                large_exp = rhs_exp;
                large_ext = rhs_ext;
                small_ext = lhs_ext;
                result_sign = rhs_sign;
                align_shift = rhs_exp - lhs_exp;
            end
            aligned_small = shift_right_sticky(small_ext, align_shift);
            exponent_work = large_exp;

            if (lhs_sign == rhs_sign) begin
                add_result = {1'b0, large_ext} + {1'b0, aligned_small};
                if (add_result[EXT_W]) begin
                    normalized = add_result[EXT_W:1];
                    normalized[0] = normalized[0] | add_result[0];
                    exponent_work = exponent_work + 1;
                end else begin
                    normalized = add_result[EXT_W-1:0];
                end
            end else begin
                difference = large_ext - aligned_small;
                if (difference != '0) begin
                    for (bit_i = EXT_W-1; bit_i >= 0; bit_i = bit_i - 1) begin
                        if (!found_one && difference[bit_i]) begin
                            normalize_shift = EXT_W - 1 - bit_i;
                            found_one = 1'b1;
                        end
                    end
                    normalized = difference << normalize_shift;
                    exponent_work = exponent_work - normalize_shift;
                end
            end

            if ((lhs_sign != rhs_sign) && (difference == '0)) begin
                sum = '0;
            end else if (exponent_work <= 0) begin
                sum = {result_sign, {(EW+MW){1'b0}}};
                underflow = 1'b1;
            end else begin
                round_increment = normalized[2] &&
                                  (normalized[1] || normalized[0] || normalized[3]);
                rounded_ext = {1'b0, normalized[EXT_W-1:3]} + round_increment;
                if (rounded_ext[SW]) begin
                    rounded_sig = rounded_ext[SW:1];
                    exponent_work = exponent_work + 1;
                end else begin
                    rounded_sig = rounded_ext[SW-1:0];
                end

                if (exponent_work >= {EW{1'b1}}) begin
                    sum = {result_sign, {EW{1'b1}}, {MW{1'b0}}};
                    overflow = 1'b1;
                end else begin
                    sum = {result_sign, exponent_work[EW-1:0],
                           rounded_sig[MW-1:0]};
                end
            end
        end
    end

endmodule
