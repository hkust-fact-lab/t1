//============================================================================
// nl_fp_to_fixed.sv — FP→fixed saturated barrel shifter
//
// Converts unpacked (sign, exp_unbiased, mantissa) to signed fixed-point
// with F fractional bits. Adds implicit 1 internally.
//============================================================================

import nl_params::*;

module nl_fp_to_fixed #(
    parameter int FMT = 1
) (
    input  logic                         sign,
    input  logic signed [EXP_BITS(FMT):0] exp,
    input  logic [M(FMT)-1:0]            mantissa,
    output logic signed [FMA_W(FMT)-1:0] fixed_out
);

    localparam int MW   = M(FMT);
    localparam int FB   = F(FMT);
    localparam int FMAW = FMA_W(FMT);
    localparam int IW   = FMA_IW(FMT);
    localparam int MAX_LEFT_SHIFT = FMAW - MW - 1;
    localparam logic signed [FMAW-1:0] MAX_FIXED = {1'b0, {(FMAW-1){1'b1}}};
    localparam logic signed [FMAW-1:0] MIN_FIXED = {1'b1, {(FMAW-1){1'b0}}};

    // Add implicit 1
    logic [MW:0] mant_full;
    assign mant_full = {1'b1, mantissa};

    // Compute shift amount: FB - MW + exp
    logic signed [32:0] shift_amt;
    assign shift_amt = FB - MW + exp;

    logic [FMAW+MW+1:0] shifted_mag;

    always_comb begin
        shifted_mag = '0;
        if (shift_amt >= MAX_LEFT_SHIFT) begin
            // Saturation
            fixed_out = sign ? MIN_FIXED : MAX_FIXED;
        end else if (shift_amt < -FMAW) begin
            fixed_out = '0;
        end else if (shift_amt >= 0) begin
            shifted_mag = mant_full << shift_amt;
            fixed_out = sign ? -$signed(shifted_mag[FMAW-1:0])
                             :  $signed(shifted_mag[FMAW-1:0]);
        end else begin
            // Right shift with round-half-up
            automatic int rs = -shift_amt;
            shifted_mag = (mant_full + (1 << (rs - 1))) >> rs;
            fixed_out = sign ? -$signed(shifted_mag[FMAW-1:0])
                             :  $signed(shifted_mag[FMAW-1:0]);
        end
    end

endmodule
