module tage_table #(
    parameter int unsigned INSTR_PER_FETCH = 4,
    parameter int unsigned ENTRIES = 64,
    parameter int unsigned TAG_BITS = 8,
    parameter int unsigned USEFUL_BITS = 2
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
    input  logic update_alloc_i,   // 分配新条目：写 tag、弱 ctr、清 useful
    input  logic update_ctr_i,     // 命中 provider：按方向饱和增减 ctr
    input  logic update_u_inc_i,   // provider 有用：useful++
    input  logic update_u_dec_i,   // provider 无用/分配失败：useful--
    input  logic update_age_i,     // 周期老化脉冲：所有条目 useful 递减
    output logic update_hit_o,
    output logic [1:0] update_ctr_o,            // update_idx 处的 ctr（修分配判据噪声 bug）
    output logic [USEFUL_BITS-1:0] update_useful_o  // update_idx 处的 useful（u==0 牺牲项选择）
);

  localparam int unsigned IDX_W = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
  localparam logic [USEFUL_BITS-1:0] U_MAX = '1;

  logic [ENTRIES-1:0] valid_q;
  logic [ENTRIES-1:0][TAG_BITS-1:0] tag_q;
  logic [ENTRIES-1:0][1:0] ctr_q;
  logic [ENTRIES-1:0][USEFUL_BITS-1:0] u_q;

  function automatic logic [1:0] sat_inc(input logic [1:0] val);
    if (val == 2'b11) sat_inc = val;
    else sat_inc = val + 2'b01;
  endfunction

  function automatic logic [1:0] sat_dec(input logic [1:0] val);
    if (val == 2'b00) sat_dec = val;
    else sat_dec = val - 2'b01;
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
    for (int i = 0; i < INSTR_PER_FETCH; i++) begin
      predict_hit_o[i] = valid_q[predict_idx_i[i]] && (tag_q[predict_idx_i[i]] == predict_tag_i[i]);
      predict_ctr_o[i] = ctr_q[predict_idx_i[i]];
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
        ctr_q[i] <= 2'b01;
        u_q[i]   <= '0;
      end
    end else begin
      // 周期老化：所有 useful 递减（让长期不被用到的条目重新可被牺牲）。
      if (update_age_i) begin
        for (int i = 0; i < ENTRIES; i++) begin
          u_q[i] <= u_down(u_q[i]);
        end
      end
      // 针对 update_idx 的写：放在老化之后，保证该条目的写覆盖老化结果。
      if (update_valid_i) begin
        if (update_alloc_i) begin
          valid_q[update_idx_i] <= 1'b1;
          tag_q[update_idx_i]   <= update_tag_i;
          ctr_q[update_idx_i]   <= update_taken_i ? 2'b10 : 2'b01;
          u_q[update_idx_i]     <= '0;
        end else begin
          if (update_ctr_i) begin
            ctr_q[update_idx_i] <= update_taken_i ? sat_inc(ctr_q[update_idx_i])
                                                  : sat_dec(ctr_q[update_idx_i]);
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
