module tage_table #(
    parameter int unsigned INSTR_PER_FETCH = 4,
    parameter int unsigned LANES = 2,
    parameter int unsigned ENTRIES = 64,
    parameter int unsigned WAYS = 2,
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
  localparam int unsigned WAY_W = (WAYS > 1) ? $clog2(WAYS) : 1;
  localparam logic [USEFUL_BITS-1:0] U_MAX = '1;
  localparam logic signed [CTR_BITS-1:0] CTR_MAX =
      {1'b0, {(CTR_BITS - 1) {1'b1}}};
  localparam logic signed [CTR_BITS-1:0] CTR_MIN =
      {1'b1, {(CTR_BITS - 1) {1'b0}}};
  localparam logic signed [CTR_BITS-1:0] CTR_WEAK_NT = -$signed(1);
  localparam logic signed [CTR_BITS-1:0] CTR_WEAK_T  =  $signed(1);

  logic [ENTRIES-1:0][WAYS-1:0] valid_q;
  logic [ENTRIES-1:0][WAYS-1:0][TAG_BITS-1:0] tag_q;
  logic [ENTRIES-1:0][WAYS-1:0][CTR_BITS-1:0] ctr_q;
  logic [ENTRIES-1:0][WAYS-1:0][USEFUL_BITS-1:0] u_q;

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

  // 牺牲路：useful==0 优先（低 way 优先），否则最小 useful（平局 way0）。
  function automatic logic [WAY_W-1:0] pick_victim_way(
      input logic [WAYS-1:0][USEFUL_BITS-1:0] u_set);
    logic [WAY_W-1:0] victim;
    logic [WAY_W-1:0] zero_way;
    logic             zero_found;
    begin
      victim     = '0;
      zero_way   = '0;
      zero_found = 1'b0;
      for (int w = 0; w < WAYS; w++) begin
        if (!zero_found && (u_set[w] == '0)) begin
          zero_found = 1'b1;
          zero_way   = WAY_W'(w);
        end
      end
      if (zero_found) begin
        pick_victim_way = zero_way;
      end else begin
        for (int w = 1; w < WAYS; w++) begin
          if (u_set[w] < u_set[victim]) victim = WAY_W'(w);
        end
        pick_victim_way = victim;
      end
    end
  endfunction

  function automatic logic [USEFUL_BITS-1:0] min_useful(
      input logic [WAYS-1:0][USEFUL_BITS-1:0] u_set);
    logic [USEFUL_BITS-1:0] m;
    begin
      m = u_set[0];
      for (int w = 1; w < WAYS; w++) begin
        if (u_set[w] < m) m = u_set[w];
      end
      min_useful = m;
    end
  endfunction

  logic [WAY_W-1:0] upd_hit_way;
  logic [WAY_W-1:0] upd_victim_way;

  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      logic [IDX_W-1:0] pidx;
      logic             phit;
      logic [CTR_BITS-1:0]       pctr;
      logic [USEFUL_BITS-1:0]    pu;

      pidx = predict_idx_i[i];
      phit = 1'b0;
      pctr = CTR_BITS'(CTR_WEAK_NT);
      pu   = '0;
      for (int w = 0; w < WAYS; w++) begin
        if (!phit && valid_q[pidx][w] && (tag_q[pidx][w] == predict_tag_i[i])) begin
          phit = 1'b1;
          pctr = ctr_q[pidx][w];
          pu   = u_q[pidx][w];
        end
      end
      predict_hit_o[i]      = phit;
      predict_ctr_o[i]      = pctr;
      predict_useful_o[i]   = pu;
    end

    upd_hit_way    = '0;
    update_hit_o   = 1'b0;
    update_ctr_o   = CTR_BITS'(CTR_WEAK_NT);
    for (int w = 0; w < WAYS; w++) begin
      if (!update_hit_o && valid_q[update_idx_i][w] &&
          (tag_q[update_idx_i][w] == update_tag_i)) begin
        update_hit_o = 1'b1;
        upd_hit_way  = WAY_W'(w);
        update_ctr_o = ctr_q[update_idx_i][w];
      end
    end
    upd_victim_way  = pick_victim_way(u_q[update_idx_i]);
    // 组内最小 useful：供上层判断是否存在 u==0 牺牲项（2-way 对上层透明）。
    update_useful_o = min_useful(u_q[update_idx_i]);
  end

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      valid_q <= '0;
      tag_q   <= '0;
      for (int i = 0; i < ENTRIES; i++) begin
        for (int w = 0; w < WAYS; w++) begin
          ctr_q[i][w] <= CTR_BITS'(CTR_WEAK_NT);
          u_q[i][w]   <= '0;
        end
      end
    end else begin
      if (update_age_i) begin
        for (int i = 0; i < ENTRIES; i++) begin
          for (int w = 0; w < WAYS; w++) begin
            u_q[i][w] <= u_down(u_q[i][w]);
          end
        end
      end
      if (update_valid_i) begin
        if (update_alloc_i) begin
          valid_q[update_idx_i][upd_victim_way] <= 1'b1;
          tag_q[update_idx_i][upd_victim_way]   <= update_tag_i;
          ctr_q[update_idx_i][upd_victim_way]   <= CTR_BITS'(update_taken_i ? CTR_WEAK_T : CTR_WEAK_NT);
          u_q[update_idx_i][upd_victim_way]     <= '0;
        end else begin
          if (update_ctr_i && update_hit_o) begin
            ctr_q[update_idx_i][upd_hit_way] <=
                CTR_BITS'(update_taken_i ? sat_inc($signed(ctr_q[update_idx_i][upd_hit_way]))
                                         : sat_dec($signed(ctr_q[update_idx_i][upd_hit_way])));
          end
          if (update_u_inc_i && update_hit_o) begin
            u_q[update_idx_i][upd_hit_way] <= u_up(u_q[update_idx_i][upd_hit_way]);
          end else if (update_u_dec_i) begin
            if (update_hit_o) begin
              u_q[update_idx_i][upd_hit_way] <= u_down(u_q[update_idx_i][upd_hit_way]);
            end else begin
              u_q[update_idx_i][upd_victim_way] <= u_down(u_q[update_idx_i][upd_victim_way]);
            end
          end
        end
      end
    end
  end

endmodule
