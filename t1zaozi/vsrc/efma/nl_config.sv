//============================================================================
// nl_config.sv — Configuration register definition
//
// Packed struct for the nonlinear unit configuration.
// 69 bits total, mapped as:
//   [68:42] alpha_prime   Q3.24 signed (27 bits)
//   [41:18] beta          Q4.20 signed (24 bits, -8 <= β < 8)
//   [17:2]  gamma_prime   Q6.10 signed (16 bits)
//   [1]     mode          0 = E-mode, 1 = L-mode
//   [0]     sign_passthru forward sign of b (for odd powers)
//============================================================================

package nl_config;

    localparam int ALPHA_FRAC_BITS = 24;
    localparam int ALPHA_W         = 27;
    localparam int BETA_FRAC_BITS  = 20;
    localparam int BETA_W          = 24;
    localparam int GAMMA_FRAC_BITS = 10;
    localparam int GAMMA_W         = 16;
    localparam int CFG_W           = ALPHA_W + BETA_W + GAMMA_W + 2;

    typedef struct packed {
        logic signed [ALPHA_W-1:0] alpha_prime;   // α' = α·log₂e, Q3.24
        logic signed [BETA_W-1:0] beta; // β, Q4.20 two's complement
        logic signed [15:0] gamma_prime;   // γ' pre-scaled, Q6.10
        logic               mode;          // 0 = E-mode, 1 = L-mode
        logic               sign_passthru; // forward sign of b
    } nl_cfg_t;

endpackage
