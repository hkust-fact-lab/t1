//============================================================================
// nl_fma_fixed.sv — Fixed-point FMA
//
// Computes: p = α'·a_fixed + β·(E_b + log2_out) + γ'
//
// α' is Q3.24 (27-bit signed), a_fixed is Q(IW).F
// β is Q4.20 signed (-8 <= β < 8)
// E_b is signed exponent (9 bits)
// log2_out is Q0.F unsigned
// γ' is Q6.10 (16-bit signed)
//============================================================================

import nl_params::*;
import nl_config::*;

module nl_fma_fixed #(
    parameter int FMT = 1
) (
    input  logic                                     clk, rst_n,
    input  logic signed [FMA_W(FMT)-1:0]             a_fixed,
    input  logic signed [EXP_BITS(FMT):0]             E_b,
    input  logic [F(FMT)-1:0]                         log2_out,
    input  nl_cfg_t                                   cfg,
    output logic signed [FMA_W(FMT)-1:0]              p_out
);

    localparam int F_VAL  = F(FMT);
    localparam int IW     = FMA_IW(FMT);
    localparam int FMAW   = FMA_W(FMT);
    localparam int EW     = EXP_BITS(FMT);

    localparam int SUMW = ALPHA_W + FMAW + 2;
    localparam logic signed [SUMW-1:0] FMA_MAX = $signed({{(SUMW-FMAW){1'b0}}, 1'b0, {(FMAW-1){1'b1}}});
    localparam logic signed [SUMW-1:0] FMA_MIN = $signed({{(SUMW-FMAW){1'b1}}, 1'b1, {(FMAW-1){1'b0}}});

    // ── Term 1: α' · a_fixed ──────────────────────────
    // α' is Q3.24, a_fixed is Q(IW).F.
    // Product shifted right by ALPHA_FRAC_BITS to align to F fractional bits.
    logic signed [ALPHA_W+FMAW-1:0] term1_full;
    logic signed [SUMW-1:0] term1;
    always_comb begin
        term1_full = cfg.alpha_prime * a_fixed;
        term1      = term1_full >>> ALPHA_FRAC_BITS;
    end

    // ── Term 2: β · (E_b + log2_out) ──────────────────
    // E_b << F aligns to same scale as log2_out (both at F fractional bits)
    // Exponent plus fraction needs only exponent bits + F guard bits.
    // Keep the beta multiplier narrow; sign extend its result into SUMW.
    localparam int LOGW = EW + F_VAL + 2;
    logic signed [LOGW-1:0] e_plus_log2;
    logic signed [SUMW-1:0] term2;
    logic signed [LOGW+BETA_W-1:0] beta_product;
    logic signed [LOGW-1:0] E_b_ext;
    logic signed [LOGW-1:0] log2_ext;
    always_comb begin
        E_b_ext  = {{(LOGW-(EW+1)){E_b[EW]}}, E_b};
        log2_ext = $signed({{(LOGW-F_VAL){1'b0}}, log2_out});
        e_plus_log2 = (E_b_ext <<< F_VAL) + log2_ext;

        beta_product = e_plus_log2 * cfg.beta;
        term2 = beta_product >>> BETA_FRAC_BITS;
    end

    // ── Term 3: γ' (Q6.10) ────────────────────────────
    // Scale to F fractional bits
    logic signed [SUMW-1:0] term3;
    logic signed [SUMW-1:0] gamma_ext;
    always_comb begin
        gamma_ext = {{(SUMW-GAMMA_W){cfg.gamma_prime[GAMMA_W-1]}}, cfg.gamma_prime};
        if (F_VAL >= GAMMA_FRAC_BITS)
            term3 = gamma_ext <<< (F_VAL - GAMMA_FRAC_BITS);
        else
            term3 = gamma_ext >>> (GAMMA_FRAC_BITS - F_VAL);
    end
    // ── Sum with saturation ───────────────────────────
    logic signed [SUMW-1:0] sum;
    always_comb begin
        sum = term1 + term2 + term3;
    end

    // ── Pipeline register (breaks 39-bit adder critical path) ──
    always_ff @(posedge clk) begin
        if (sum > FMA_MAX)
            p_out <= FMA_MAX[FMAW-1:0];
        else if (sum < FMA_MIN)
            p_out <= FMA_MIN[FMAW-1:0];
        else
            p_out <= sum[FMAW-1:0];
    end
endmodule
