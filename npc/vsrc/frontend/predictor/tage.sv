import config_pkg::*;

module tage #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned LANES = 2,
    parameter int unsigned GHR_BITS = 8,
    parameter int unsigned TABLE_ENTRIES = 128,
    parameter int unsigned BASE_ENTRIES = 512,
    parameter int unsigned TAG_BITS = 8,
    parameter int unsigned HIST_LEN0 = 2,
    parameter int unsigned HIST_LEN1 = 4,
    parameter int unsigned HIST_LEN2 = 6,
    parameter int unsigned HIST_LEN3 = 8,
    parameter int unsigned TAGE_WAYS = 2,
    parameter int unsigned USEFUL_BITS = 2,
    parameter int unsigned CTR_BITS = 3,
    parameter int unsigned USE_ALT_BITS = 4,
    parameter int unsigned AGING_PERIOD = 4096
) (
    input logic clk_i,
    input logic rst_i,

    input  logic [LANES-1:0][Cfg.PLEN-1:0] predict_pc_i,
    input  logic [LANES-1:0][((GHR_BITS > 0) ? GHR_BITS : 1)-1:0] predict_ghr_i,
    // predict_hit_o: tagged provider 命中（顶层 override 门控用，语义不含 base）。
    output logic [LANES-1:0] predict_hit_o,
    // predict_taken_o: 最终方向（tagged provider/alt 或 T0 base 回退，始终有效）。
    output logic [LANES-1:0] predict_taken_o,
    output logic [LANES-1:0] predict_strong_o,
    output logic [LANES-1:0][1:0] predict_provider_o,
    output logic [LANES-1:0][USEFUL_BITS-1:0] predict_useful_o,
    // provider/base 居中有符号 ctr（供 SC 校准；hit 取 provider ctr，否则 T0 base ctr）。
    output logic [LANES-1:0][CTR_BITS-1:0] predict_conf_o,
    // T0 base 侧带（供顶层 SC legacy_strong 门控与 backward 启发）。
    output logic [LANES-1:0] predict_base_strong_o,
    output logic [LANES-1:0] predict_base_weak_o,

    input logic update_valid_i,
    // tagged_en_i=0 时仅训练 T0 base，TAGE 退化为纯 bimodal（完全替代 BHT）。
    input logic tagged_en_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic [((GHR_BITS > 0) ? GHR_BITS : 1)-1:0] update_ghr_i,
    input logic update_taken_i,
    // update 侧 provider/base 居中 ctr（供 SC commit 重算 sum）。
    output logic [CTR_BITS-1:0] update_conf_o,
    // update 侧 TAGE 方向与 tagged provider 命中（供 SC commit 校准重算）。
    output logic update_taken_o,
    output logic update_hit_o,

    // Diagnostic cond accuracy counters (T0 base；tb 经 i_bpu.u_tage 层级引用)。
    output logic [63:0] dbg_cond_update_total_o,
    output logic [63:0] dbg_cond_local_correct_o,
    // Legacy profiler hooks (tournament removed; tie off or alias)。
    output logic [63:0] dbg_cond_global_correct_o,
    output logic [63:0] dbg_cond_selected_correct_o,
    output logic [63:0] dbg_cond_choose_local_o,
    output logic [63:0] dbg_cond_choose_global_o
);

  localparam int unsigned NUM_TABLES = 4;
  localparam int unsigned INSTR_ADDR_LSB = 1;
  localparam int unsigned IDX_W = (TABLE_ENTRIES > 1) ? $clog2(TABLE_ENTRIES) : 1;
  localparam int unsigned GHR_W = (GHR_BITS > 0) ? GHR_BITS : 1;
  localparam int unsigned AGE_W = (AGING_PERIOD > 1) ? $clog2(AGING_PERIOD) : 1;
  localparam logic signed [CTR_BITS-1:0] CTR_MAX =
      {1'b0, {(CTR_BITS - 1) {1'b1}}};
  localparam logic signed [CTR_BITS-1:0] CTR_MIN =
      {1'b1, {(CTR_BITS - 1) {1'b0}}};
  localparam logic signed [CTR_BITS-1:0] CTR_WEAK_NT = -$signed(1);

  // T0 base：untagged、PC-only 索引的 bimodal 表（与 tagged 表共用 3-bit 有符号计数器）。
  localparam int unsigned BASE_IDX_W = (BASE_ENTRIES > 1) ? $clog2(BASE_ENTRIES) : 1;

  // 几何递增历史长度与各表的撒盐常数（盐用于打散 PC/历史的折叠位置）。
  localparam int unsigned HIST_LEN  [NUM_TABLES] = '{HIST_LEN0, HIST_LEN1, HIST_LEN2, HIST_LEN3};
  localparam int unsigned IDX_SALT  [NUM_TABLES] = '{1, 2, 4, 6};
  localparam int unsigned IDX_HSALT [NUM_TABLES] = '{3, 5, 7, 11};
  localparam int unsigned TAG_SALT  [NUM_TABLES] = '{1, 2, 4, 6};
  localparam int unsigned TAG_HSALT [NUM_TABLES] = '{3, 5, 7, 11};

  logic [LANES-1:0][IDX_W-1:0]   pred_idx [NUM_TABLES];
  logic [LANES-1:0][TAG_BITS-1:0] pred_tag [NUM_TABLES];
  logic [LANES-1:0]              hit      [NUM_TABLES];
  logic [LANES-1:0][CTR_BITS-1:0]         ctr      [NUM_TABLES];
  logic [LANES-1:0][USEFUL_BITS-1:0] useful [NUM_TABLES];

  logic [IDX_W-1:0]            upd_idx [NUM_TABLES];
  logic [TAG_BITS-1:0]         upd_tag [NUM_TABLES];
  logic                        upd_hit [NUM_TABLES];
  logic [CTR_BITS-1:0]                  upd_ctr [NUM_TABLES];
  logic [USEFUL_BITS-1:0]      upd_u   [NUM_TABLES];

  logic                        upd_t_valid [NUM_TABLES];
  logic                        upd_t_alloc [NUM_TABLES];
  logic                        upd_t_ctr   [NUM_TABLES];
  logic                        upd_t_uinc  [NUM_TABLES];
  logic                        upd_t_udec  [NUM_TABLES];

  // alt-pred / use_alt_on_newalloc 状态与周期老化计数器。
  logic [USE_ALT_BITS-1:0] use_alt_on_na_q;
  logic [AGE_W-1:0]        age_cnt_q;
  logic                    upd_age;

  // 折叠后的 update 侧 provider / alt 解析结果（也供时序块训练 use_alt 计数器）。
  logic       upd_prov_found, upd_alt_found;
  logic [1:0] upd_prov_t, upd_alt_t;
  logic [CTR_BITS-1:0] upd_prov_ctr;
  logic       upd_prov_taken, upd_prov_strong, upd_prov_weak;
  logic       upd_alt_taken;
  logic       upd_use_alt, upd_final_taken, upd_mispred;
  logic       upd_alloc_found;
  logic [1:0] upd_alloc_t;

  // update 侧 T0 base 读端（alt 缺失时回退，及每 cond 训练用）。
  logic [BASE_IDX_W-1:0] upd_base_idx;
  logic [CTR_BITS-1:0]   upd_base_ctr;
  logic                  upd_base_taken;

  // ---- 折叠哈希（PC 与历史各自折叠后再异或；历史侧 lim 限制实现长历史折叠） ----
  function automatic logic [IDX_W-1:0] fold_hist_idx(input logic [GHR_W-1:0] hist,
                                                     input int unsigned hist_len,
                                                     input int unsigned salt);
    logic [IDX_W-1:0] out_v;
    int lim;
    begin
      out_v = IDX_W'(salt);
      lim = (hist_len < GHR_W) ? int'(hist_len) : int'(GHR_W);
      for (int i = 0; i < lim; i++) begin
        out_v[(i+salt)%IDX_W] ^= hist[i];
      end
      fold_hist_idx = out_v;
    end
  endfunction

  function automatic logic [TAG_BITS-1:0] fold_hist_tag(input logic [GHR_W-1:0] hist,
                                                         input int unsigned hist_len,
                                                         input int unsigned salt);
    logic [TAG_BITS-1:0] out_v;
    int lim;
    begin
      out_v = TAG_BITS'(salt * 5);
      lim = (hist_len < GHR_W) ? int'(hist_len) : int'(GHR_W);
      for (int i = 0; i < lim; i++) begin
        out_v[(i+salt)%TAG_BITS] ^= hist[i];
      end
      fold_hist_tag = out_v;
    end
  endfunction

  function automatic logic [IDX_W-1:0] fold_pc_idx(input logic [Cfg.PLEN-1:0] pc,
                                                   input int unsigned salt);
    logic [IDX_W-1:0] out_v;
    begin
      out_v = IDX_W'(salt * 3);
      for (int i = INSTR_ADDR_LSB; i < Cfg.PLEN; i++) begin
        out_v[(i+salt)%IDX_W] ^= pc[i];
      end
      fold_pc_idx = out_v;
    end
  endfunction

  function automatic logic [TAG_BITS-1:0] fold_pc_tag(input logic [Cfg.PLEN-1:0] pc,
                                                      input int unsigned salt);
    logic [TAG_BITS-1:0] out_v;
    begin
      out_v = TAG_BITS'(salt * 7);
      for (int i = INSTR_ADDR_LSB; i < Cfg.PLEN; i++) begin
        out_v[(i+salt)%TAG_BITS] ^= pc[i];
      end
      fold_pc_tag = out_v;
    end
  endfunction

  function automatic logic ctr_taken(input logic [CTR_BITS-1:0] c);
    ctr_taken = ($signed(c) >= 0);
  endfunction

  function automatic logic is_strong(input logic [CTR_BITS-1:0] c);
    logic signed [CTR_BITS-1:0] s;
    s = $signed(c);
    is_strong = (s == CTR_MAX) || (s == CTR_MIN);
  endfunction

  function automatic logic [CTR_BITS-1:0] ctr_sat_inc(input logic [CTR_BITS-1:0] c);
    ctr_sat_inc = ($signed(c) == CTR_MAX) ? c : (c + 1'b1);
  endfunction

  function automatic logic [CTR_BITS-1:0] ctr_sat_dec(input logic [CTR_BITS-1:0] c);
    ctr_sat_dec = ($signed(c) == CTR_MIN) ? c : (c - 1'b1);
  endfunction

  // T0 base 索引：PC-only 折叠，风格对齐旧 bimodal（低位取 PC[1+:IDX]，高位异或折叠），与 GHR 无关。
  function automatic logic [BASE_IDX_W-1:0] base_pc_index(input logic [Cfg.PLEN-1:0] pc);
    logic [BASE_IDX_W-1:0] pc_idx;
    logic [BASE_IDX_W-1:0] fold_idx;
    begin
      pc_idx   = pc[INSTR_ADDR_LSB+:BASE_IDX_W];
      fold_idx = '0;
      for (int i = INSTR_ADDR_LSB + BASE_IDX_W; i < Cfg.PLEN; i++) begin
        fold_idx[(i-(INSTR_ADDR_LSB+BASE_IDX_W))%BASE_IDX_W] ^= pc[i];
      end
      base_pc_index = pc_idx ^ fold_idx;
    end
  endfunction

  // T0 base 计数器阵列：无 tag/valid，复位为弱 not-taken。
  logic [CTR_BITS-1:0] base_ctr_q [BASE_ENTRIES];

  logic [63:0] dbg_cond_update_total_q;
  logic [63:0] dbg_cond_local_correct_q;

  assign dbg_cond_update_total_o    = dbg_cond_update_total_q;
  assign dbg_cond_local_correct_o   = dbg_cond_local_correct_q;
  assign dbg_cond_global_correct_o  = 64'd0;
  assign dbg_cond_selected_correct_o = dbg_cond_local_correct_q;
  assign dbg_cond_choose_local_o    = dbg_cond_update_total_q;
  assign dbg_cond_choose_global_o   = 64'd0;

  // 预测端按 lane 使用前缀化 GHR；lane 内再与各自 PC 折叠。
  logic [LANES-1:0][IDX_W-1:0] hist_idx_fold [NUM_TABLES];
  logic [LANES-1:0][TAG_BITS-1:0] hist_tag_fold [NUM_TABLES];

  always_comb begin
    for (int t = 0; t < NUM_TABLES; t++) begin
      for (int i = 0; i < LANES; i++) begin
        hist_idx_fold[t][i] = fold_hist_idx(predict_ghr_i[i], HIST_LEN[t], IDX_HSALT[t]);
        hist_tag_fold[t][i] = fold_hist_tag(predict_ghr_i[i], HIST_LEN[t], TAG_HSALT[t]);
      end
    end

    for (int i = 0; i < LANES; i++) begin
      for (int t = 0; t < NUM_TABLES; t++) begin
        pred_idx[t][i] = fold_pc_idx(predict_pc_i[i], IDX_SALT[t]) ^ hist_idx_fold[t][i];
        pred_tag[t][i] = fold_pc_tag(predict_pc_i[i], TAG_SALT[t]) ^ hist_tag_fold[t][i];
      end
    end

    for (int t = 0; t < NUM_TABLES; t++) begin
      upd_idx[t] = fold_pc_idx(update_pc_i, IDX_SALT[t]) ^
                   fold_hist_idx(update_ghr_i, HIST_LEN[t], IDX_HSALT[t]);
      upd_tag[t] = fold_pc_tag(update_pc_i, TAG_SALT[t]) ^
                   fold_hist_tag(update_ghr_i, HIST_LEN[t], TAG_HSALT[t]);
    end
  end

  generate
    for (genvar t = 0; t < NUM_TABLES; t++) begin : g_table
      tage_table #(
          .INSTR_PER_FETCH(LANES),
          .ENTRIES(TABLE_ENTRIES),
          .WAYS(TAGE_WAYS),
          .TAG_BITS(TAG_BITS),
          .CTR_BITS(CTR_BITS),
          .USEFUL_BITS(USEFUL_BITS)
      ) u_tab (
          .clk_i(clk_i),
          .rst_i(rst_i),
          .predict_idx_i(pred_idx[t]),
          .predict_tag_i(pred_tag[t]),
          .predict_hit_o(hit[t]),
          .predict_ctr_o(ctr[t]),
          .predict_useful_o(useful[t]),
          .update_valid_i(upd_t_valid[t]),
          .update_idx_i(upd_idx[t]),
          .update_tag_i(upd_tag[t]),
          .update_taken_i(update_taken_i),
          .update_alloc_i(upd_t_alloc[t]),
          .update_ctr_i(upd_t_ctr[t]),
          .update_u_inc_i(upd_t_uinc[t]),
          .update_u_dec_i(upd_t_udec[t]),
          .update_age_i(upd_age),
          .update_hit_o(upd_hit[t]),
          .update_ctr_o(upd_ctr[t]),
          .update_useful_o(upd_u[t])
      );
    end
  endgenerate

  // ---- 预测：最长命中表为 provider，次长命中表为 alt；alt 缺失回退 T0 base；
  //      无 tagged 命中则直接用 T0 base 方向（predict_taken_o 始终有效）----
  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      logic       prov_found, alt_found;
      logic [1:0] prov_t, alt_t;
      logic [CTR_BITS-1:0] prov_ctr_v, alt_ctr_v, base_ctr_v;
      logic       prov_weak, use_alt_sel;
      logic       base_taken;

      // T0 base 读端：PC-only 索引，恒有效。
      base_ctr_v = base_ctr_q[base_pc_index(predict_pc_i[i])];
      base_taken = ctr_taken(base_ctr_v);
      predict_base_strong_o[i] = is_strong(base_ctr_v);
      predict_base_weak_o[i]   = !is_strong(base_ctr_v);

      // 默认：无 tagged 命中，采用 T0 base 方向。
      predict_hit_o[i]      = 1'b0;
      predict_taken_o[i]    = base_taken;
      predict_strong_o[i]   = is_strong(base_ctr_v);
      predict_provider_o[i] = '0;
      predict_useful_o[i]   = '0;
      predict_conf_o[i]     = base_ctr_v;

      prov_found  = 1'b0;
      alt_found   = 1'b0;
      prov_t      = '0;
      alt_t       = '0;
      prov_ctr_v  = CTR_BITS'(CTR_WEAK_NT);
      alt_ctr_v   = base_ctr_v;
      prov_weak   = 1'b0;
      use_alt_sel = 1'b0;
      for (int t = NUM_TABLES - 1; t >= 0; t--) begin
        if (hit[t][i]) begin
          if (!prov_found) begin
            prov_found = 1'b1;
            prov_t     = t[1:0];
          end else if (!alt_found) begin
            alt_found = 1'b1;
            alt_t     = t[1:0];
          end
        end
      end

      if (prov_found) begin
        prov_ctr_v  = ctr[prov_t][i];
        prov_weak   = !is_strong(prov_ctr_v);
        // alt 始终存在（tagged 次长命中，或缺失时回退 T0 base）。
        use_alt_sel = prov_weak && use_alt_on_na_q[USE_ALT_BITS-1];

        predict_hit_o[i]      = 1'b1;
        predict_provider_o[i] = prov_t;
        predict_useful_o[i]   = useful[prov_t][i];
        predict_conf_o[i]     = prov_ctr_v;
        if (use_alt_sel) begin
          alt_ctr_v           = alt_found ? ctr[alt_t][i] : base_ctr_v;
          predict_taken_o[i]  = ctr_taken(alt_ctr_v);
          predict_strong_o[i] = is_strong(alt_ctr_v);
        end else begin
          predict_taken_o[i]  = ctr_taken(prov_ctr_v);
          predict_strong_o[i] = is_strong(prov_ctr_v);
        end
      end
    end
  end

  // ---- 更新：基于 update_idx 处的真实 ctr/useful 判断分配，而非预测槽噪声 ----
  always_comb begin
    for (int t = 0; t < NUM_TABLES; t++) begin
      upd_t_valid[t] = 1'b0;
      upd_t_alloc[t] = 1'b0;
      upd_t_ctr[t]   = 1'b0;
      upd_t_uinc[t]  = 1'b0;
      upd_t_udec[t]  = 1'b0;
    end

    upd_prov_found = 1'b0;
    upd_alt_found  = 1'b0;
    upd_prov_t     = '0;
    upd_alt_t      = '0;
    for (int t = NUM_TABLES - 1; t >= 0; t--) begin
      if (upd_hit[t]) begin
        if (!upd_prov_found) begin
          upd_prov_found = 1'b1;
          upd_prov_t     = t[1:0];
        end else if (!upd_alt_found) begin
          upd_alt_found = 1'b1;
          upd_alt_t     = t[1:0];
        end
      end
    end

    // T0 base 读端（PC-only）：alt 缺失时充当回退，与预测端对称。
    upd_base_idx    = base_pc_index(update_pc_i);
    upd_base_ctr    = base_ctr_q[upd_base_idx];
    upd_base_taken  = ctr_taken(upd_base_ctr);

    upd_prov_ctr    = upd_prov_found ? upd_ctr[upd_prov_t] : CTR_BITS'(CTR_WEAK_NT);
    upd_prov_taken  = ctr_taken(upd_prov_ctr);
    upd_prov_strong = is_strong(upd_prov_ctr);
    upd_prov_weak   = !upd_prov_strong;
    // alt 始终存在（tagged 次长命中，或缺失时回退 T0 base）。
    upd_alt_taken   = upd_alt_found ? ctr_taken(upd_ctr[upd_alt_t]) : upd_base_taken;
    upd_use_alt     = upd_prov_weak && use_alt_on_na_q[USE_ALT_BITS-1];
    upd_final_taken = upd_prov_found ? (upd_use_alt ? upd_alt_taken : upd_prov_taken)
                                     : upd_base_taken;
    upd_mispred     = (upd_final_taken != update_taken_i);

    // 牺牲项：在比 provider 更长的表里挑第一个 useful==0 的条目。
    upd_alloc_found = 1'b0;
    upd_alloc_t     = '0;
    for (int t = 0; t < NUM_TABLES; t++) begin
      if (((!upd_prov_found) || (t > int'(upd_prov_t))) && (upd_u[t] == '0) && !upd_alloc_found) begin
        upd_alloc_found = 1'b1;
        upd_alloc_t     = t[1:0];
      end
    end

    if (update_valid_i && tagged_en_i) begin
      // provider：强化方向计数；与 alt 分歧时按命中与否调整 useful。
      if (upd_prov_found) begin
        upd_t_valid[upd_prov_t] = 1'b1;
        upd_t_ctr[upd_prov_t]   = 1'b1;
        if (upd_alt_found && (upd_prov_taken != upd_alt_taken)) begin
          if (upd_prov_taken == update_taken_i) begin
            upd_t_uinc[upd_prov_t] = 1'b1;
          end else begin
            upd_t_udec[upd_prov_t] = 1'b1;
          end
        end
      end

      // 误预测才分配；有 u==0 牺牲项就分配，否则把候选项 useful 全部老化一格。
      if (upd_mispred) begin
        if (upd_alloc_found) begin
          upd_t_valid[upd_alloc_t] = 1'b1;
          upd_t_alloc[upd_alloc_t] = 1'b1;
        end else begin
          for (int t = 0; t < NUM_TABLES; t++) begin
            if ((!upd_prov_found) || (t > int'(upd_prov_t))) begin
              upd_t_valid[t] = 1'b1;
              upd_t_udec[t]  = 1'b1;
            end
          end
        end
      end
    end
  end

  assign upd_age = update_valid_i && tagged_en_i && (age_cnt_q == AGE_W'(AGING_PERIOD - 1));
  assign update_conf_o = upd_prov_found ? upd_prov_ctr : upd_base_ctr;
  assign update_taken_o = upd_final_taken;
  assign update_hit_o   = upd_prov_found;

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      // MSB 置 1：初始倾向于对新分配弱条目使用 alt。
      use_alt_on_na_q <= {1'b1, {(USE_ALT_BITS - 1) {1'b0}}};
      age_cnt_q       <= '0;
      dbg_cond_update_total_q  <= '0;
      dbg_cond_local_correct_q <= '0;
      // T0 base：复位为弱 not-taken（与 tagged 表一致）。
      for (int b = 0; b < BASE_ENTRIES; b++) begin
        base_ctr_q[b] = CTR_BITS'(CTR_WEAK_NT);
      end
    end else begin
      // T0 base：每条 cond commit 都训练（不受 tagged_en_i 门控），3-bit 饱和。
      if (update_valid_i) begin
        logic base_pred_before;
        logic base_correct;

        base_pred_before = ctr_taken(upd_base_ctr);
        base_correct     = (base_pred_before == update_taken_i);

        dbg_cond_update_total_q <= dbg_cond_update_total_q + 64'd1;
        if (base_correct) begin
          dbg_cond_local_correct_q <= dbg_cond_local_correct_q + 64'd1;
        end

        base_ctr_q[upd_base_idx] <= update_taken_i ? ctr_sat_inc(upd_base_ctr)
                                                   : ctr_sat_dec(upd_base_ctr);
      end

      // use_alt / 老化：仅在 tagged 使能时更新（alt 缺失回退 T0 亦参与训练）。
      if (update_valid_i && tagged_en_i) begin
        if (upd_prov_found && upd_prov_weak &&
            (upd_prov_taken != upd_alt_taken)) begin
          if ((upd_alt_taken == update_taken_i) && (upd_prov_taken != update_taken_i)) begin
            if (use_alt_on_na_q != '1) use_alt_on_na_q <= use_alt_on_na_q + 1'b1;
          end else if ((upd_prov_taken == update_taken_i) && (upd_alt_taken != update_taken_i)) begin
            if (use_alt_on_na_q != '0) use_alt_on_na_q <= use_alt_on_na_q - 1'b1;
          end
        end

        if (age_cnt_q == AGE_W'(AGING_PERIOD - 1)) begin
          age_cnt_q <= '0;
        end else begin
          age_cnt_q <= age_cnt_q + 1'b1;
        end
      end
    end
  end

endmodule
