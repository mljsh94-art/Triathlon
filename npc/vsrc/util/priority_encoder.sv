module priority_encoder #(
    parameter int unsigned WIDTH = 8
) (
    input logic [WIDTH-1:0] in,
    output logic [$clog2(WIDTH)-1:0] out
);
  always_comb begin
    out = '0;
    for (int i = 0; i < WIDTH; i++) begin
      if (in[i]) begin
        out = i[$clog2(WIDTH)-1:0];
        break;
      end
    end
  end
endmodule : priority_encoder
