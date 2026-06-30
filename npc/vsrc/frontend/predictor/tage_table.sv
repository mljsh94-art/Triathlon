module tage_table #(
    parameter int unsigned INSTR_PER_FETCH = 4,
    parameter int unsigned LANES = 2,
    parameter int unsigned ENTRIES = 64,
    parameter int unsigned TAG_BITS = 8,
    parameter int unsigned CTR_BITS = 3,
    parameter int unsigned USEFUL_BITS = 2
) (
    input logic clk_i,
    input logic rst_i,

    input  logic [LANES-1:0][((ENTRIES > 1) ? $clog2(ENTRIES) : 1)-1:0] predict_idx_i,
    input  logic [LANES-1:0][TAG_BITS-1:0] predict_tag_i,
    output logic [LANES-1:0] predict_hit_o,
    output logic [LANES-1:0][CTR_BITS-1:0] predict_ctr_o,
    output logic [LANES-1:0][USEFUL_BITS-1:0] predict_useful_o,

    input  logic update_valid_i,
    input  logic [((ENTRIES > 1) ? $clog2(ENTRIES) : 1)-1:0] update_idx_i,
    input  logic [TAG_BITS-1:0] update_tag_i,
    input  logic update_taken_i,
    input  logic update_alloc_i,   // 分配新条目：写 tag、弱 ctr、清 useful
    input  logic update_ctr_i,     // 命中 provider：按方向饱和增减 ctr
    input  logic update_u_inc_i,   // provider 有用：useful++
    input  logic update_u_dec_i,   // provider 无用/分配失败：useful--
    input  logic update_age_i,     // 周期老化脉冲：所有条目 useful 递减
    output logic update_hit_o,
    output logic [CTR_BITS-1:0] update_ctr_o,
    output logic [USEFUL_BITS-1:0] update_useful_o
);

  localparam int unsigned IDX_W = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
  localparam logic [USEFUL_BITS-1:0] U_MAX = '1;
  localparam logic signed [CTR_BITS-1:0] CTR_MAX =
      {1'b0, {(CTR_BITS - 1) {1'b1}}};
  localparam logic signed [CTR_BITS-1:0] CTR_MIN =
      {1'b1, {(CTR_BITS - 1) {1'b0}}};
  localparam logic signed [CTR_BITS-1:0] CTR_WEAK_NT = -$signed(1);
  localparam logic signed [CTR_BITS-1:0] CTR_WEAK_T  =  $signed(1);

  logic [ENTRIES-1:0] valid_q;
  logic [ENTRIES-1:0][TAG_BITS-1:0] tag_q;
  logic [ENTRIES-1:0][CTR_BITS-1:0] ctr_q;
  logic [ENTRIES-1:0][USEFUL_BITS-1:0] u_q;

  function automatic logic signed [CTR_BITS-1:0] sat_inc(input logic signed [CTR_BITS-1:0] val);
    if (val == CTR_MAX) sat_inc = val;
    else sat_inc = val + $signed(1);
  endfunction

  function automatic logic signed [CTR_BITS-1:0] sat_dec(input logic signed [CTR_BITS-1:0] val);
    if (val == CTR_MIN) sat_dec = val;
    else sat_dec = val - $signed(1);
  endfunction

  function automatic logic [USEFUL_BITS-1:0] u_up(input logic [USEFUL_BITS-1:0] v);
    if (v == U_MAX) u_up = v;
    else u_up = v + 1'b1;
  endfunction

  function automatic logic [USEFUL_BITS-1:0] u_down(input logic [USEFUL_BITS-1:0] v);
    if (v == '0) u_down = v;
    else u_down = v - 1'b1;
  endfunction

  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      predict_hit_o[i] = valid_q[predict_idx_i[i]] && (tag_q[predict_idx_i[i]] == predict_tag_i[i]);
      predict_ctr_o[i] = ctr_q[predict_idx_i[i]];
      predict_useful_o[i] = u_q[predict_idx_i[i]];
    end
    update_hit_o    = valid_q[update_idx_i] && (tag_q[update_idx_i] == update_tag_i);
    update_ctr_o    = ctr_q[update_idx_i];
    update_useful_o = u_q[update_idx_i];
  end

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      valid_q <= '0;
      tag_q   <= '0;
      for (int i = 0; i < ENTRIES; i++) begin
        ctr_q[i] <= CTR_BITS'(CTR_WEAK_NT);
        u_q[i]   <= '0;
      end
    end else begin
      if (update_age_i) begin
        for (int i = 0; i < ENTRIES; i++) begin
          u_q[i] <= u_down(u_q[i]);
        end
      end
      if (update_valid_i) begin
        if (update_alloc_i) begin
          valid_q[update_idx_i] <= 1'b1;
          tag_q[update_idx_i]   <= update_tag_i;
          ctr_q[update_idx_i]   <= CTR_BITS'(update_taken_i ? CTR_WEAK_T : CTR_WEAK_NT);
          u_q[update_idx_i]     <= '0;
        end else begin
          if (update_ctr_i) begin
            ctr_q[update_idx_i] <= CTR_BITS'(update_taken_i ? sat_inc($signed(ctr_q[update_idx_i]))
                                                             : sat_dec($signed(ctr_q[update_idx_i])));
          end
          if (update_u_inc_i) begin
            u_q[update_idx_i] <= u_up(u_q[update_idx_i]);
          end else if (update_u_dec_i) begin
            u_q[update_idx_i] <= u_down(u_q[update_idx_i]);
          end
        end
      end
    end
  end

endmodule
