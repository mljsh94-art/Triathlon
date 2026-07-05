import config_pkg::*;

// Statistical Corrector (SC), GEHL 风格多表校准器 + 2-lane。
//  - NUM_TABLES 张 signed 计数器表：表0 为 bias/PC-only；表1..3 用几何历史长度
//    HIST_LEN1..3（复用共享 spec GHR，capped ≤ GHR 宽度）。
//  - 预测：每 lane sum = Σ_t ctr_t[idx] + TAGE 项(2*tage_conf+1)；sc_taken=(sum>=0)；
//    sc_use = tage_hit && |tage_conf|<=TAGE_WEAK_MAX && |sum|>=thresh_q &&
//    (sc_taken != tage_taken)，即仅在 TAGE 弱置信、SC 跨阈值且方向相反时才 flip。
//  - 更新（单口，commit 一条）：用 update 侧 PC/GHR/TAGE-conf 重算 sum；当 SCPRED 错或
//    |sum|<thresh_q 时按 outcome 训练全部 GEHL 计数器（含 bias）；自适应阈值 thresh_q 按
//    Seznec TC 规则调整（SC 被采用且错 -> TC 增、阈值升；被采用且对 -> TC 减、阈值降）。
// Loop prediction 仍在 loop_predictor.sv（独立 BPU_USE_LOOP）。
module stat_corr #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned LANES = 2,
    parameter int unsigned GHR_BITS = 32,
    parameter int unsigned NUM_TABLES = 4,
    parameter int unsigned ENTRIES = 256,
    parameter int unsigned CTR_BITS = 6,
    parameter int unsigned TAGE_CONF_BITS = 3,
    parameter int unsigned HIST_LEN1 = 8,
    parameter int unsigned HIST_LEN2 = 16,
    parameter int unsigned HIST_LEN3 = 32,
    parameter int unsigned THRESH_INIT = 6,
    parameter int unsigned THRESH_MIN = 3,
    parameter int unsigned THRESH_MAX = 63,
    parameter int unsigned TC_BITS = 6,
    // 仅当 |tage_conf| <= TAGE_WEAK_MAX 时才允许 SC override TAGE。
    parameter int unsigned TAGE_WEAK_MAX = 1
) (
    input logic clk_i,
    input logic rst_i,

    // 预测端（每 lane 一个 cond 候选 PC/GHR；后续 lane 使用块内前缀历史）
    input  logic [LANES-1:0][Cfg.PLEN-1:0] predict_pc_i,
    input  logic [LANES-1:0][((GHR_BITS > 0) ? GHR_BITS : 1)-1:0] predict_ghr_i,
    // TAGE 侧带（provider/base 居中 ctr，signed）
    input  logic [LANES-1:0] tage_taken_i,
    input  logic [LANES-1:0] tage_hit_i,
    input  logic [LANES-1:0][TAGE_CONF_BITS-1:0] tage_conf_i,
    // SC 输出
    output logic [LANES-1:0] sc_taken_o,
    output logic [LANES-1:0] sc_use_o,

    // 更新端（单口，commit 一条 cond 分支）
    input logic update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic [((GHR_BITS > 0) ? GHR_BITS : 1)-1:0] update_ghr_i,
    input logic update_taken_i,
    input logic update_tage_taken_i,
    input logic update_tage_hit_i,
    input logic [TAGE_CONF_BITS-1:0] update_tage_conf_i
);
  localparam int unsigned INSTR_ADDR_LSB = 1;
  localparam int unsigned IDX_W = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
  localparam int unsigned GHR_W = (GHR_BITS > 0) ? GHR_BITS : 1;
  localparam int unsigned SUM_W = CTR_BITS + $clog2(NUM_TABLES + 1) + 4;
  localparam int unsigned TC_W = (TC_BITS > 1) ? TC_BITS : 2;

  localparam logic signed [CTR_BITS-1:0] SC_MAX = {1'b0, {(CTR_BITS - 1) {1'b1}}};
  localparam logic signed [CTR_BITS-1:0] SC_MIN = {1'b1, {(CTR_BITS - 1) {1'b0}}};
  localparam logic signed [TC_W-1:0] TC_MAX = {1'b0, {(TC_W - 1) {1'b1}}};
  localparam logic signed [TC_W-1:0] TC_MIN = {1'b1, {(TC_W - 1) {1'b0}}};

  // GEHL 计数器表：[表][组]，signed。表0=bias/PC-only。
  logic signed [CTR_BITS-1:0] ctr_q [NUM_TABLES][ENTRIES];
  // 自适应阈值 + Seznec TC 计数器。
  logic signed [SUM_W-1:0] thresh_q;
  logic signed [TC_W-1:0]  tc_q;

  function automatic int unsigned get_hist_len(input int unsigned t);
    case (t)
      0:       get_hist_len = 0;
      1:       get_hist_len = HIST_LEN1;
      2:       get_hist_len = HIST_LEN2;
      default: get_hist_len = HIST_LEN3;
    endcase
  endfunction

  function automatic logic [IDX_W-1:0] fold_pc_idx(input logic [Cfg.PLEN-1:0] pc,
                                                   input int unsigned salt);
    logic [IDX_W-1:0] out_v;
    begin
      out_v = IDX_W'(salt * 9);
      for (int i = INSTR_ADDR_LSB; i < Cfg.PLEN; i++) begin
        out_v[(i+salt)%IDX_W] ^= pc[i];
      end
      fold_pc_idx = out_v;
    end
  endfunction

  function automatic logic [IDX_W-1:0] fold_hist_idx(input logic [GHR_W-1:0] hist,
                                                     input int unsigned hist_len,
                                                     input int unsigned salt);
    logic [IDX_W-1:0] out_v;
    begin
      out_v = IDX_W'(salt * 13);
      for (int i = 0; i < GHR_W; i++) begin
        if (i < hist_len) out_v[(i+salt)%IDX_W] ^= hist[i];
      end
      fold_hist_idx = out_v;
    end
  endfunction

  function automatic logic [IDX_W-1:0] gehl_index(input logic [Cfg.PLEN-1:0] pc,
                                                  input logic [GHR_W-1:0] ghr,
                                                  input int unsigned t);
    logic [IDX_W-1:0] pc_part;
    logic [IDX_W-1:0] hist_part;
    begin
      pc_part = fold_pc_idx(pc, 3 + t * 2);
      if (t == 0) hist_part = '0;
      else hist_part = fold_hist_idx(ghr, get_hist_len(t), 5 + t * 2);
      gehl_index = pc_part ^ hist_part;
    end
  endfunction

  function automatic logic signed [CTR_BITS-1:0] sat_inc(input logic signed [CTR_BITS-1:0] v);
    sat_inc = (v == SC_MAX) ? v : (v + $signed(1));
  endfunction

  function automatic logic signed [CTR_BITS-1:0] sat_dec(input logic signed [CTR_BITS-1:0] v);
    sat_dec = (v == SC_MIN) ? v : (v - $signed(1));
  endfunction

  // TAGE 置信项：2*conf+1（conf 为居中 signed）。
  function automatic logic signed [SUM_W-1:0] tage_term(input logic [TAGE_CONF_BITS-1:0] conf);
    logic signed [SUM_W-1:0] c;
    begin
      c = SUM_W'($signed(conf));
      tage_term = (c <<< 1) + $signed(1);
    end
  endfunction

  function automatic logic tage_weak_ok(input logic [TAGE_CONF_BITS-1:0] conf);
    logic signed [TAGE_CONF_BITS:0] abs_conf;
    logic signed [TAGE_CONF_BITS-1:0] sconf;
    begin
      sconf = $signed(conf);
      abs_conf = (sconf < $signed(0)) ? -sconf : sconf;
      tage_weak_ok = abs_conf <= TAGE_WEAK_MAX'(TAGE_WEAK_MAX);
    end
  endfunction

  // ---------------- 预测 ----------------
  logic signed [SUM_W-1:0] pred_sum_w [LANES];

  always_comb begin
    for (int l = 0; l < LANES; l++) begin
      logic signed [SUM_W-1:0] sum_v;
      logic signed [SUM_W-1:0] abs_v;
      logic                    sc_tk;
      sum_v = '0;
      for (int t = 0; t < NUM_TABLES; t++) begin
        sum_v += SUM_W'(ctr_q[t][gehl_index(predict_pc_i[l], predict_ghr_i[l], t)]);
      end
      sum_v += tage_term(tage_conf_i[l]);
      pred_sum_w[l] = sum_v;

      sc_tk = (sum_v >= $signed(0));
      abs_v = (sum_v < $signed(0)) ? -sum_v : sum_v;

      sc_taken_o[l] = sc_tk;
      sc_use_o[l]   = tage_hit_i[l] && tage_weak_ok(tage_conf_i[l]) &&
                      (abs_v >= thresh_q) && (sc_tk != tage_taken_i[l]);
    end
  end

  // ---------------- 更新（单口）----------------
  logic signed [SUM_W-1:0] upd_sum_w;
  logic signed [SUM_W-1:0] upd_abs_w;
  logic                    upd_sc_taken_w;
  logic                    upd_sc_wrong_w;
  logic                    upd_sc_used_w;
  logic                    upd_train_w;

  always_comb begin
    logic signed [SUM_W-1:0] sum_v;
    sum_v = '0;
    for (int t = 0; t < NUM_TABLES; t++) begin
      sum_v += SUM_W'(ctr_q[t][gehl_index(update_pc_i, update_ghr_i, t)]);
    end
    sum_v += tage_term(update_tage_conf_i);
    upd_sum_w = sum_v;
    upd_abs_w = (sum_v < $signed(0)) ? -sum_v : sum_v;

    upd_sc_taken_w = (sum_v >= $signed(0));
    upd_sc_wrong_w = (upd_sc_taken_w != update_taken_i);
    // SC 在预测时是否会被采用（与 sc_use_o 同判据，用 update 侧带重算）。
    upd_sc_used_w  = update_tage_hit_i && tage_weak_ok(update_tage_conf_i) &&
                     (upd_abs_w >= thresh_q) && (upd_sc_taken_w != update_tage_taken_i);
    // 训练 GEHL：SCPRED 错，或置信不足（|sum|<thresh）。
    upd_train_w    = upd_sc_wrong_w || (upd_abs_w < thresh_q);
  end

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      for (int t = 0; t < NUM_TABLES; t++) begin
        for (int e = 0; e < ENTRIES; e++) ctr_q[t][e] = '0;
      end
      thresh_q <= SUM_W'($signed(THRESH_INIT));
      tc_q     <= '0;
    end else if (update_valid_i) begin
      // GEHL 计数器训练（含 bias 表0）。
      if (upd_train_w) begin
        for (int t = 0; t < NUM_TABLES; t++) begin
          automatic logic [IDX_W-1:0] uidx = gehl_index(update_pc_i, update_ghr_i, t);
          if (update_taken_i) ctr_q[t][uidx] <= sat_inc(ctr_q[t][uidx]);
          else ctr_q[t][uidx] <= sat_dec(ctr_q[t][uidx]);
        end
      end
      // 自适应阈值（Seznec TC 规则）：仅当 SC 会被采用时调整。
      if (upd_sc_used_w) begin
        if (upd_sc_wrong_w) begin
          if (tc_q >= TC_MAX) begin
            tc_q     <= '0;
            thresh_q <= (thresh_q < SUM_W'($signed(THRESH_MAX))) ? (thresh_q + $signed(1)) : thresh_q;
          end else begin
            tc_q <= tc_q + $signed(1);
          end
        end else begin
          if (tc_q <= TC_MIN) begin
            tc_q     <= '0;
            thresh_q <= (thresh_q > SUM_W'($signed(THRESH_MIN))) ? (thresh_q - $signed(1)) : thresh_q;
          end else begin
            tc_q <= tc_q - $signed(1);
          end
        end
      end
    end
  end

endmodule
