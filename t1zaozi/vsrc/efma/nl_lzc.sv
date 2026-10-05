//============================================================================
// nl_lzc.sv — Leading zero counter for L-mode normalization
//
// Counts leading zeros on |in_val|, outputs sign bit.
//============================================================================

module nl_lzc #(
    parameter int WIDTH = 38
) (
    input  logic signed [WIDTH-1:0] in_val,
    output logic [$clog2(WIDTH)-1:0] lzc_count,
    output logic                      sign
);

    logic [WIDTH-1:0] mag;
    assign sign = in_val[WIDTH-1];
    assign mag  = sign ? -in_val : in_val;

    always_comb begin
        lzc_count = 0;
        for (int i = WIDTH - 1; i >= 0; i--) begin
            if (mag[i]) begin
                lzc_count = WIDTH - 1 - i;
                break;
            end
        end
        if (mag == 0)
            lzc_count = WIDTH;
    end

endmodule
