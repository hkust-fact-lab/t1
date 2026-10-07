// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 FACT Lab
//
// LaneEfma.sv — hand-written body for the Chisel-declared FixedIOExtModule
// `org.chipsalliance.t1.rtl.LaneEfma` (interface in t1/src/LaneEfma.scala,
// instantiated from LaneEfmaVFU).
//
// It drives the vendored EFMA nonlinear IP (`nl_nonlinear`, FMT=1 -> FP32) with
// exactly the configuration the wukong_rvv fork uses for the RVV VEML opcode,
// so the produced values are bit-identical to that copy (the `nl_*.sv` sources
// are byte-identical; only the surrounding handshake differs):
//
//   y = 2^(alpha' * vs2 + beta * log2(vs1) + gamma') + c
//   alpha' = log2(e) @Q3.24 = 27'sd24204406, beta = 1.0 @Q4.20 = 1<<20,
//   gamma' = 0, mode = 0 (E-mode / exp), sign_passthru = 1, c = 0
//   => y = exp(vs2) * vs1
//
// Operand mapping (this is the part that is easy to get backwards): the T1 lane
// fills `src(0)` from the instruction's *vs1* field and `src(1)` from *vs2*
// (LaneStage1: `src := (vs1 read, vs2 read, vd read)`), so
//   src_0 = vs1 = multiplier -> nl.b,      src_1 = vs2 = exponent -> nl.a,
// exactly as wukong_rvv's rvv_backend_eml.sv drives the same IP
// (`.a(vs2_data)`, `.b(vs1_data)`).
//
// Timing: T1 assumes a *fixed* latency (`connectDecoupledWithShifter(latency)`)
// and VectorFunctionUnit.scala declares LaneEfmaParam(32, 6), so the response
// must be valid exactly 6 cycles after the accepting edge of requestIO:
//   T+1  : registered request drives the IP's in_valid (sources held in regs)
//   T+5  : IP out_valid (nl_nonlinear FP32 transaction latency = 4)
//   T+6  : registered response
// One request is in flight at a time, matching the fork's EFMA unit (`busy`).

module LaneEfma (
  input  logic        clock,
  input  logic        reset,                   // T1 reset: active HIGH
  output logic        requestIO_ready,
  input  logic        requestIO_valid,
  input  logic [3:0]  requestIO_bits_tag,
  input  logic [31:0] requestIO_bits_src_0,    // vs1: multiplier operand -> nl.b
  input  logic [31:0] requestIO_bits_src_1,    // vs2: exponent operand  -> nl.a
  input  logic [3:0]  requestIO_bits_opcode,
  input  logic [3:0]  requestIO_bits_mask,
  input  logic        responseIO_ready,
  output logic        responseIO_valid,
  output logic [3:0]  responseIO_bits_tag,
  output logic [31:0] responseIO_bits_data
);
  import nl_config::*;

  // Same constants as hdl/verilog/rvv/design/rvv_backend_eml.sv (wukong_rvv).
  localparam logic signed [ALPHA_W-1:0] EFMA_ALPHA_EXP = 27'sd24204406;        // alpha' = log2(e), Q3.24
  localparam logic signed [BETA_W-1:0]  EFMA_BETA_ONE  = 1 << BETA_FRAC_BITS;  // beta   = 1.0,     Q4.20

  nl_cfg_t cfg;
  assign cfg.alpha_prime   = EFMA_ALPHA_EXP;
  assign cfg.beta          = EFMA_BETA_ONE;
  assign cfg.gamma_prime   = 16'sd0;
  assign cfg.mode          = 1'b0;   // E-mode: y = 2^(...) + c
  assign cfg.sign_passthru = 1'b1;

  wire request_fire = requestIO_valid && requestIO_ready;

  logic        busy;             // request accepted / IP in flight / response pending
  logic        launch_d;         // one-cycle in_valid pulse, issued at T+1
  logic [31:0] src0_q, src1_q;   // captured at the accepting edge: src0_q = vs1, src1_q = vs2
  logic [3:0]  tag_q;

  assign requestIO_ready = ~busy;

  // ---- IP ------------------------------------------------------------------
  wire [31:0] ip_result;
  wire        ip_out_valid;

  nl_nonlinear #(.FMT(1)) u_efma (
    .clk       (clock),
    .rst_n     (~reset),
    .a         (src1_q),        // vs2: exponent operand (alpha' * vs2)
    .b         (src0_q),        // vs1: multiplier      (beta * log2(vs1))
    .c         (32'h0),         // VEML has no additive term
    .cfg       (cfg),
    .in_valid  (launch_d),
    .in_ready  (),
    .result    (ip_result),
    .out_valid (ip_out_valid),
    .overflow  (),
    .underflow ()
  );

  // ---- request register (T -> T+1) and response register (T+5 -> T+6) -------
  always_ff @(posedge clock) begin
    if (reset) begin
      busy                 <= 1'b0;
      launch_d             <= 1'b0;
      src0_q               <= 32'h0;
      src1_q               <= 32'h0;
      tag_q                <= 4'h0;
      responseIO_valid     <= 1'b0;
      responseIO_bits_tag  <= 4'h0;
      responseIO_bits_data <= 32'h0;
    end else begin
      launch_d <= request_fire;          // T+1: the IP samples in_valid

      if (request_fire) begin
        src0_q <= requestIO_bits_src_0;
        src1_q <= requestIO_bits_src_1;
        tag_q  <= requestIO_bits_tag;
        busy   <= 1'b1;
      end

      if (ip_out_valid) begin            // T+5: result available
        busy                 <= 1'b0;
        responseIO_valid     <= 1'b1;    // T+6: visible to T1
        responseIO_bits_tag  <= tag_q;
        responseIO_bits_data <= ip_result;
      end else if (responseIO_valid && responseIO_ready) begin
        responseIO_valid <= 1'b0;
      end
    end
  end

  // requestIO_bits_opcode / requestIO_bits_mask are unused on purpose: T1 decodes
  // EFMA with a single boolean field (`Decoder.efma`), so every request reaching
  // this VFU is the one custom instruction (`veml.vv`) and the op is fixed.

endmodule
