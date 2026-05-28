module tage_table #(
    parameter int unsigned INSTR_PER_FETCH = 4,
    parameter int unsigned ENTRIES = 64,
    parameter int unsigned TAG_BITS = 8
) (
    input logic clk_i,
    input logic rst_i,

    input  logic [INSTR_PER_FETCH-1:0][((ENTRIES > 1) ? $clog2(ENTRIES) : 1)-1:0] predict_idx_i,
    input  logic [INSTR_PER_FETCH-1:0][TAG_BITS-1:0] predict_tag_i,
    output logic [INSTR_PER_FETCH-1:0] predict_hit_o,
    output logic [INSTR_PER_FETCH-1:0][1:0] predict_ctr_o,

    input  logic update_valid_i,
    input  logic [((ENTRIES > 1) ? $clog2(ENTRIES) : 1)-1:0] update_idx_i,
    input  logic [TAG_BITS-1:0] update_tag_i,
    input  logic update_taken_i,
    input  logic update_alloc_i,
    output logic update_hit_o
);

  localparam int unsigned IDX_W = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;

  logic [ENTRIES-1:0] valid_q;
  logic [ENTRIES-1:0][TAG_BITS-1:0] tag_q;
  logic [ENTRIES-1:0][1:0] ctr_q;

  function automatic logic [1:0] sat_inc(input logic [1:0] val);
    if (val == 2'b11) sat_inc = val;
    else sat_inc = val + 2'b01;
  endfunction

  function automatic logic [1:0] sat_dec(input logic [1:0] val);
    if (val == 2'b00) sat_dec = val;
    else sat_dec = val - 2'b01;
  endfunction

  always_comb begin
    for (int i = 0; i < INSTR_PER_FETCH; i++) begin
      predict_hit_o[i] = valid_q[predict_idx_i[i]] && (tag_q[predict_idx_i[i]] == predict_tag_i[i]);
      predict_ctr_o[i] = ctr_q[predict_idx_i[i]];
    end
    update_hit_o = valid_q[update_idx_i] && (tag_q[update_idx_i] == update_tag_i);
  end

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      valid_q <= '0;
      tag_q <= '0;
      for (int i = 0; i < ENTRIES; i++) begin
        ctr_q[i] <= 2'b01;
      end
    end else if (update_valid_i) begin
      if (update_alloc_i) begin
        valid_q[update_idx_i] <= 1'b1;
        tag_q[update_idx_i] <= update_tag_i;
        ctr_q[update_idx_i] <= update_taken_i ? 2'b10 : 2'b01;
      end else if (update_hit_o) begin
        if (update_taken_i) begin
          ctr_q[update_idx_i] <= sat_inc(ctr_q[update_idx_i]);
        end else begin
          ctr_q[update_idx_i] <= sat_dec(ctr_q[update_idx_i]);
        end
      end
    end
  end

endmodule
