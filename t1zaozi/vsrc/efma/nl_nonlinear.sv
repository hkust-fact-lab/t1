//============================================================================
// nl_nonlinear.sv — Top-level nonlinear function unit
//
// Computes a complete EFMA operation in a single pipelined pass:
//   E-mode: y = 2^{α'·a + β·log₂b + γ'} + c
//   L-mode: y =    α'·a + β·log₂b + γ'  + c
//
// Transaction latency, measured from the accepting edge to out_valid:
//   BF16: 3 cycles
//   FP32: 4 cycles
// The combinational unpack/pack work is included in adjacent registered
// stages, so it must not be counted as two additional interface cycles.
//
// FMA inputs (E_b, a_fixed) are delayed via shift registers to align
// with the log2 LUT output latency.
//============================================================================

import nl_params::*;
import nl_config::*;

module nl_nonlinear #(
    parameter int FMT = 1
) (
    input  logic                     clk, rst_n,
    input  logic [FP_W(FMT)-1:0]     a, b, c,
    input  nl_cfg_t                  cfg,
    input  logic                     in_valid,
    output logic                     in_ready,
    output logic [FP_W(FMT)-1:0]     result,
    output logic                     out_valid,
    output logic                     overflow, underflow
);

    localparam int MW      = M(FMT);
    localparam int FW      = FP_W(FMT);
    localparam int FB      = F(FMT);
    localparam int FMAW    = FMA_W(FMT);
    localparam int IW      = FMA_IW(FMT);
    localparam int EW      = EXP_BITS(FMT);
    localparam int LOG2_D  = (FMT == 0) ? 1 : 2;  // log2 LUT pipeline depth
    localparam int EXP2_D  = 2;                     // exp2 LUT pipeline depth

    // ── Stage 0: Unpack (combinational) ────────────────
    logic                  sign_a, sign_b;
    logic signed [EW:0]    exp_a, exp_b;
    logic [MW-1:0]         mant_a, mant_b;
    logic                  a_special, b_special;
    logic                  a_is_zero, b_is_zero;
    logic [EW-1:0]         a_raw_exp, b_raw_exp;
    logic [MW-1:0]         a_raw_mant, b_raw_mant;
    logic                  a_is_nan, b_is_nan;
    logic                  a_is_inf, b_is_inf;

    nl_unpack #(.FMT(FMT)) u_unpack (
        .fp_in_a(a), .fp_in_b(b),
        .sign_a, .sign_b, .exp_a, .exp_b,
        .mant_a, .mant_b,
        .a_special, .b_special, .a_is_zero, .b_is_zero
    );

    // ── Valid pipeline ─────────────────────────────────
    // Shift register propagates valid through pipeline stages.
    // Depth includes: 1 for unpack reg + LOG2_D for log2 + 1 for FMA reg + EXP2_D for exp2
    localparam int RESULT_META_IDX = LOG2_D + EXP2_D;
    localparam int TOTAL_PIPE = RESULT_META_IDX;
    logic                special_bypass;

    assign a_raw_exp  = a[MW +: EW];
    assign b_raw_exp  = b[MW +: EW];
    assign a_raw_mant = a[MW-1:0];
    assign b_raw_mant = b[MW-1:0];
    assign a_is_nan   = (a_raw_exp == {EW{1'b1}}) && (a_raw_mant != '0);
    assign b_is_nan   = (b_raw_exp == {EW{1'b1}}) && (b_raw_mant != '0);
    assign a_is_inf   = (a_raw_exp == {EW{1'b1}}) && (a_raw_mant == '0);
    assign b_is_inf   = (b_raw_exp == {EW{1'b1}}) && (b_raw_mant == '0);

    // A special operand with a zero coefficient is inactive.  NaNs always
    // propagate, while c is handled by the final floating-point adder.
    assign special_bypass = a_is_nan || b_is_nan ||
                            (a_is_inf && (cfg.alpha_prime != '0)) ||
                            ((b_is_inf || b_is_zero) && (cfg.beta != 0));

    // Keep per-input configuration, sign, and c aligned with the data path.
    nl_cfg_t cfg_sr [0:TOTAL_PIPE];
    logic    sign_b_sr [0:TOTAL_PIPE];
    logic [FW-1:0] c_sr [0:TOTAL_PIPE];
    integer  meta_i;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (meta_i = 0; meta_i <= TOTAL_PIPE; meta_i++) begin
                cfg_sr[meta_i]    <= '0;
                sign_b_sr[meta_i] <= 1'b0;
                c_sr[meta_i]      <= '0;
            end
        end else begin
            cfg_sr[0]    <= cfg;
            sign_b_sr[0] <= sign_b;
            c_sr[0]      <= c;
            for (meta_i = 1; meta_i <= TOTAL_PIPE; meta_i++) begin
                cfg_sr[meta_i]    <= cfg_sr[meta_i-1];
                sign_b_sr[meta_i] <= sign_b_sr[meta_i-1];
                c_sr[meta_i]      <= c_sr[meta_i-1];
            end
        end
    end

    // ── Stage 1: log2 LUT ──────────────────────────────
    logic [FB-1:0] log2_result;
    logic          log2_valid;

    nl_lut_log2 #(.FMT(FMT)) u_log2 (
        .clk, .rst_n,
        .mantissa(mant_b),
        .log2_out(log2_result),
        .in_valid(in_valid && !special_bypass),
        .out_valid(log2_valid)
    );

    // ── FP→Fixed (combinational) ───────────────────────
    logic signed [FMAW-1:0] a_fixed_val;
    nl_fp_to_fixed #(.FMT(FMT)) u_fp2fix (
        .sign(sign_a),
        .exp(exp_a),
        .mantissa(mant_a),
        .fixed_out(a_fixed_val)
    );

    // ── Delay E_b and a_fixed to align with log2 ───────
    logic signed [EW:0]    eb_delayed;
    logic signed [FMAW-1:0] af_delayed;
    nl_cfg_t               cfg_delayed;

    if (LOG2_D == 1) begin : delay1
        always_ff @(posedge clk) begin
            eb_delayed <= exp_b;
            af_delayed <= a_fixed_val;
            cfg_delayed <= cfg;
        end
    end else begin : delay2
        logic signed [EW:0]    eb_d1;
        logic signed [FMAW-1:0] af_d1;
        nl_cfg_t               cfg_d1;
        always_ff @(posedge clk) begin
            eb_d1     <= exp_b;
            af_d1     <= a_fixed_val;
            cfg_d1     <= cfg;
            eb_delayed <= eb_d1;
            af_delayed <= af_d1;
            cfg_delayed <= cfg_d1;
        end
    end

    // ── FMA (1-cycle pipelined) ────────────────────────
    // Pipeline register inside u_fma breaks the 39-bit adder critical path.
    logic signed [FMAW-1:0] p_val_reg;  // FMA output (registered internally)
    nl_fma_fixed #(.FMT(FMT)) u_fma (
        .clk, .rst_n,
        .a_fixed(af_delayed),
        .E_b(eb_delayed),
        .log2_out(log2_result),
        .cfg(cfg_delayed),
        .p_out(p_val_reg)
    );

    // ── Delay log2_valid to align with FMA pipeline ──────
    logic log2_valid_d1;
    always_ff @(posedge clk) begin
        if (!rst_n)
            log2_valid_d1 <= 0;
        else
            log2_valid_d1 <= log2_valid;
    end

    // ── Split p into I and fractional part ─────────────
    logic signed [IW:0]   I_val;
    logic [FB-1:0]        f_frac_val;

    always_comb begin
        I_val      = p_val_reg >>> FB;
        f_frac_val = p_val_reg[FB-1:0];
    end

    // ── exp2 LUT ───────────────────────────────────────
    logic [MW:0]  exp2_mant;
    logic         exp2_valid;

    nl_lut_exp2 #(.FMT(FMT)) u_exp2 (
        .clk, .rst_n,
        .f_frac(f_frac_val),
        .mant_out(exp2_mant),
        .in_valid(log2_valid_d1),
        .out_valid(exp2_valid)
    );

    // ── E-mode / L-mode pack ───────────────────────────
    logic          result_sign;
    logic [FW-1:0] e_mode_result, l_mode_result;
    logic          e_ovfl, e_undfl;
    logic signed [IW:0]      I_val_pipe [0:EXP2_D-1];
    logic signed [FMAW-1:0] p_val_l_pipe [0:EXP2_D-1];
    integer lpipe_i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (lpipe_i = 0; lpipe_i < EXP2_D; lpipe_i++) begin
                I_val_pipe[lpipe_i]   <= '0;
                p_val_l_pipe[lpipe_i] <= '0;
            end
        end else begin
            I_val_pipe[0]   <= I_val;
            p_val_l_pipe[0] <= p_val_reg;
            for (lpipe_i = 1; lpipe_i < EXP2_D; lpipe_i++) begin
                I_val_pipe[lpipe_i]   <= I_val_pipe[lpipe_i-1];
                p_val_l_pipe[lpipe_i] <= p_val_l_pipe[lpipe_i-1];
            end
        end
    end

    assign result_sign = cfg_sr[RESULT_META_IDX].sign_passthru ? sign_b_sr[RESULT_META_IDX] : 1'b0;

    nl_pack_e #(.FMT(FMT)) u_pack_e (
        .pack_sign(result_sign),
        .exp_in(I_val_pipe[EXP2_D-1]),
        .mant_in(exp2_mant),
        .fp_out(e_mode_result),
        .overflow(e_ovfl),
        .underflow(e_undfl)
    );
    nl_pack_l #(.FMT(FMT)) u_pack_l (
        .fixed_in(p_val_l_pipe[EXP2_D-1]),
        .fp_out(l_mode_result)
    );

    // ── Output mux ─────────────────────────────────────
    logic [FW-1:0] special_result;
    logic [FW-1:0] special_result_sr [0:TOTAL_PIPE];
    logic [TOTAL_PIPE:0] special_valid_sr;
    logic          a_inf_active, b_inf_active;
    logic          a_term_pos_inf, b_term_pos_inf;
    logic          inf_conflict, p_pos_inf, p_neg_inf;
    logic          special_sign;

    assign a_inf_active   = a_is_inf && (cfg.alpha_prime != '0);
    assign b_inf_active   = (b_is_inf || b_is_zero) && (cfg.beta != 0);
    // alpha*a is +Inf when operand and coefficient signs match.
    assign a_term_pos_inf = (sign_a == cfg.alpha_prime[ALPHA_W-1]);
    // log2(Inf)=+Inf, while log2(0)=-Inf.
    assign b_term_pos_inf = b_is_inf ? !cfg.beta[BETA_W-1] : cfg.beta[BETA_W-1];
    // Inf+(-Inf)=NaN
    assign inf_conflict   = a_inf_active && b_inf_active &&
                            (a_term_pos_inf != b_term_pos_inf);
    assign p_pos_inf      = !inf_conflict &&
                            ((a_inf_active && a_term_pos_inf) ||
                             (b_inf_active && b_term_pos_inf));
    assign p_neg_inf      = !inf_conflict &&
                            ((a_inf_active && !a_term_pos_inf) ||
                             (b_inf_active && !b_term_pos_inf));
    assign special_sign   = cfg.sign_passthru ? sign_b : 1'b0;

    always_comb begin
        if (a_is_nan || b_is_nan || inf_conflict) begin
            special_result = {1'b0, {(EW){1'b1}}, {(MW-1){1'b0}}, 1'b1};
        end else if (p_pos_inf) begin
            // p=+Inf: E-mode → 2^p=+Inf; L-mode → p=+Inf.
            special_result = {special_sign, {EW{1'b1}}, {MW{1'b0}}};
        end else if (p_neg_inf) begin
            // p=-Inf: E-mode → 2^p=+0; L-mode → p=-Inf.
            special_result = cfg.mode
                ? {1'b1, {EW{1'b1}}, {MW{1'b0}}}
                : {special_sign, {(EW+MW){1'b0}}};
        end else begin
            special_result = '0;
        end
    end

    // Preserve fixed latency and input order for bypassed special operands.
    // The normal datapath already propagates its valid through both LUTs.
    integer special_i;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            special_valid_sr <= '0;
            for (special_i = 0; special_i <= TOTAL_PIPE; special_i++)
                special_result_sr[special_i] <= '0;
        end else begin
            special_valid_sr[0] <= in_valid && special_bypass;
            special_result_sr[0] <= special_result;
            for (special_i = 1; special_i <= TOTAL_PIPE; special_i++) begin
                special_valid_sr[special_i] <= special_valid_sr[special_i-1];
                special_result_sr[special_i] <= special_result_sr[special_i-1];
            end
        end
    end

    logic [FW-1:0] pre_add_result, c_aligned, add_result;
    logic          pre_add_valid, pre_add_overflow, pre_add_underflow;
    logic          add_overflow, add_underflow;

    always_comb begin
        if (special_valid_sr[RESULT_META_IDX]) begin
            pre_add_result    = special_result_sr[RESULT_META_IDX];
            c_aligned         = c_sr[RESULT_META_IDX];
            pre_add_valid     = 1'b1;
            pre_add_overflow  = 1'b0;
            pre_add_underflow = 1'b0;
        end else if (cfg_sr[RESULT_META_IDX].mode) begin
            pre_add_result    = l_mode_result;
            c_aligned         = c_sr[RESULT_META_IDX];
            pre_add_valid     = exp2_valid;
            pre_add_overflow  = 1'b0;
            pre_add_underflow = 1'b0;
        end else begin
            pre_add_result    = e_mode_result;
            c_aligned         = c_sr[RESULT_META_IDX];
            pre_add_valid     = exp2_valid;
            pre_add_overflow  = e_ovfl;
            pre_add_underflow = e_undfl;
        end
    end

    nl_fp_add #(.FMT(FMT)) u_add_c (
        .lhs(pre_add_result),
        .rhs(c_aligned),
        .sum(add_result),
        .overflow(add_overflow),
        .underflow(add_underflow)
    );

    assign result    = add_result;
    assign out_valid = pre_add_valid;
    assign overflow  = pre_add_overflow | add_overflow;
    assign underflow = pre_add_underflow | add_underflow;

    assign in_ready = 1'b1;

endmodule
