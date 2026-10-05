//============================================================================
// nl_params.sv — Parameter package for the nonlinear unit
//
// All bit-widths derive from the precision_check.md corollary.
// FORMAT selects: 0 = BF16, 1 = FP32.
//
// BF16: M=7,  EXP_BITS=8, BIAS=127, FP_W=16
//        k1=7,  W1=11, S1=0
//        k2=4,  W2=11, S2=7,  F=13, FMA_IW=9
// FP32: M=23, EXP_BITS=8, BIAS=127, FP_W=32
//        k1=11, W1=24, S1=15
//        k2=11, W2=24, S2=16, F=31, FMA_IW=9

package nl_params;

    //──────────────────────────────────────────────────────────
    // Mantissa bits
    //──────────────────────────────────────────────────────────
    function automatic int unsigned M(int FMT);
        return (FMT == 0) ? 7 : 23;
    endfunction

    //──────────────────────────────────────────────────────────
    // Exponent bits (8 for both BF16 and FP32)
    //──────────────────────────────────────────────────────────
    function automatic int unsigned EXP_BITS(int FMT);
        return 8;
    endfunction

    //──────────────────────────────────────────────────────────
    // Exponent bias (127 for both formats — BF16 uses IEEE-style bias)
    //──────────────────────────────────────────────────────────
    function automatic int unsigned BIAS(int FMT);
        return 127;
    endfunction

    //──────────────────────────────────────────────────────────
    // Total FP word width: 16 for BF16, 32 for FP32
    //──────────────────────────────────────────────────────────
    function automatic int unsigned FP_W(int FMT);
        return 1 + EXP_BITS(FMT) + M(FMT);
    endfunction

    //──────────────────────────────────────────────────────────
    // log2 table: index bits
    //   BF16: k1=7  (direct lookup, 128 entries)
    //   FP32: k1=11 (interpolation, 2048 entries)
    //──────────────────────────────────────────────────────────
    function automatic int unsigned K1(int FMT);
        return (FMT == 0) ? 7 : 11;
    endfunction
    function automatic int unsigned W1(int FMT);
        return (FMT == 0) ? 11 : 24;
    endfunction

    //──────────────────────────────────────────────────────────
    // log2 table: slope fractional bits (0 = no interpolation)
    //──────────────────────────────────────────────────────────
    function automatic int unsigned S1(int FMT);
        return (FMT == 0) ? 0 : 15;
    endfunction

    // Signed Q2.S1 slope width for d(log2(1+t))/dt.
    function automatic int unsigned LOG2_SLOPE_W(int FMT);
        return (S1(FMT) > 0) ? (S1(FMT) + 2) : 1;
    endfunction

    //──────────────────────────────────────────────────────────
    // log2 table: total depth
    //──────────────────────────────────────────────────────────
    function automatic int unsigned LOG2_DEPTH(int FMT);
        return 1 << K1(FMT);
    endfunction

    //──────────────────────────────────────────────────────────
    // log2 table: residual bits (bits below the index for interpolation)
    //──────────────────────────────────────────────────────────
    function automatic int unsigned LOG2_RESIDUAL(int FMT);
        return (K1(FMT) < M(FMT)) ? (M(FMT) - K1(FMT)) : 0;
    endfunction

    //──────────────────────────────────────────────────────────
    // exp2 table: index bits
    //   BF16: k2=4  (16 entries)
    //   FP32: k2=11 (2048 entries)
    //──────────────────────────────────────────────────────────
    function automatic int unsigned K2(int FMT);
        return (FMT == 0) ? 4 : 11;
    endfunction
    function automatic int unsigned W2(int FMT);
        return (FMT == 0) ? 11 : 24;
    endfunction

    //──────────────────────────────────────────────────────────
    // exp2 table: slope fractional bits
    //──────────────────────────────────────────────────────────
    function automatic int unsigned S2(int FMT);
        return (FMT == 0) ? 7 : 16;
    endfunction

    // Signed Q2.S2 slope width for d(2^f)/df.
    function automatic int unsigned EXP2_SLOPE_W(int FMT);
        return S2(FMT) + 2;
    endfunction

    //──────────────────────────────────────────────────────────
    // exp2 table: total depth
    //──────────────────────────────────────────────────────────
    function automatic int unsigned EXP2_DEPTH(int FMT);
        return 1 << K2(FMT);
    endfunction

    //──────────────────────────────────────────────────────────
    // exp2 table: residual bits
    //──────────────────────────────────────────────────────────
    function automatic int unsigned EXP2_RESIDUAL(int FMT);
        return F(FMT) - K2(FMT);
    endfunction

    //──────────────────────────────────────────────────────────
    // Fixed-point fractional bits in the FMA datapath
    function automatic int unsigned F(int FMT);
        return (FMT == 0) ? 13 : 31;
    endfunction

    //──────────────────────────────────────────────────────────
    // FMA integer width (signed, 9 bits covers ±2^8)
    //──────────────────────────────────────────────────────────
    function automatic int unsigned FMA_IW(int FMT);
        return 9;
    endfunction

    //──────────────────────────────────────────────────────────
    // Total FMA word width: IW + F (signed)
    //──────────────────────────────────────────────────────────
    function automatic int unsigned FMA_W(int FMT);
        return FMA_IW(FMT) + F(FMT);
    endfunction

    //──────────────────────────────────────────────────────────
    // Interpolation multiplier widths
    //──────────────────────────────────────────────────────────
    function automatic int unsigned LOG2_MULT_A(int FMT);
        return LOG2_SLOPE_W(FMT);  // slope width (signed)
    endfunction

    function automatic int unsigned LOG2_MULT_B(int FMT);
        return LOG2_RESIDUAL(FMT);  // residual width
    endfunction

    function automatic int unsigned EXP2_MULT_A(int FMT);
        return EXP2_SLOPE_W(FMT);  // slope width (signed)
    endfunction

    function automatic int unsigned EXP2_MULT_B(int FMT);
        return EXP2_RESIDUAL(FMT);  // residual width
    endfunction

    //──────────────────────────────────────────────────────────
    // Pipeline depths
    //   BF16: 4 cycles (unpack → log2_rom → FMA → exp2_rom+pack)
    //   FP32: 6 cycles (unpack → log2_s1 → log2_s2 → FMA → exp2_s1 → exp2_s2+pack)
    //──────────────────────────────────────────────────────────
    function automatic int unsigned PIPELINE_DEPTH(int FMT);
        return (FMT == 0) ? 4 : 6;
    endfunction

endpackage
