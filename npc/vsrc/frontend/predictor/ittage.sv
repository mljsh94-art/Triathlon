import config_pkg::*;

module ittage #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned INSTR_PER_FETCH = Cfg.INSTR_PER_FETCH,
    parameter int unsigned ENTRIES = 128,
    parameter int unsigned TAG_BITS = 10,
    parameter int unsigned PATH_HIST_BITS = 16,
    parameter int unsigned CONF_BITS = 2,
    parameter int unsigned USEFUL_BITS = 2,
    parameter int unsigned CONF_PRED_THRESHOLD = 1
) (
    input logic clk_i,
    input logic rst_i,

    input logic [Cfg.PLEN-1:0] predict_base_pc_i,
    input logic [PATH_HIST_BITS-1:0] predict_ctx_i,
    output logic [INSTR_PER_FETCH-1:0] predict_hit_o,
    output logic [INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] predict_target_o,

    input logic update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic [PATH_HIST_BITS-1:0] update_ctx_i,
    input logic [Cfg.PLEN-1:0] update_target_i
);
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  localparam int unsigned INSTR_ADDR_LSB = 1;
  localparam int unsigned IDX_W = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
  localparam int unsigned TAG_W = (TAG_BITS > 0) ? TAG_BITS : 1;
  localparam int unsigned CONF_W = (CONF_BITS > 0) ? CONF_BITS : 1;
  localparam int unsigned USEFUL_W = (USEFUL_BITS > 0) ? USEFUL_BITS : 1;
  localparam int unsigned CONF_MAX_U = (1 << CONF_W) - 1;
  localparam logic [CONF_W-1:0] CONF_MAX = {CONF_W{1'b1}};
  localparam logic [USEFUL_W-1:0] USEFUL_MAX = {USEFUL_W{1'b1}};
  localparam logic [CONF_W-1:0] CONF_THRESH =
      (CONF_PRED_THRESHOLD > CONF_MAX_U) ? CONF_W'(CONF_MAX_U) : CONF_W'(CONF_PRED_THRESHOLD);

  logic [ENTRIES-1:0] valid_q;
  logic [ENTRIES-1:0][TAG_W-1:0] tag_q;
  logic [ENTRIES-1:0][Cfg.PLEN-1:0] target_q;
  logic [ENTRIES-1:0][CONF_W-1:0] conf_q;
  logic [ENTRIES-1:0][USEFUL_W-1:0] useful_q;

  logic [INSTR_PER_FETCH-1:0][IDX_W-1:0] pred_idx_w;
  logic [INSTR_PER_FETCH-1:0][TAG_W-1:0] pred_tag_w;
  logic [IDX_W-1:0] update_idx_w;
  logic [TAG_W-1:0] update_tag_w;
  logic update_match_w;

  function automatic logic [CONF_W-1:0] sat_inc_conf(input logic [CONF_W-1:0] v);
    if (v == CONF_MAX) sat_inc_conf = v;
    else sat_inc_conf = v + CONF_W'(1);
  endfunction

  function automatic logic [CONF_W-1:0] sat_dec_conf(input logic [CONF_W-1:0] v);
    if (v == '0) sat_dec_conf = v;
    else sat_dec_conf = v - CONF_W'(1);
  endfunction

  function automatic logic [USEFUL_W-1:0] sat_inc_useful(input logic [USEFUL_W-1:0] v);
    if (v == USEFUL_MAX) sat_inc_useful = v;
    else sat_inc_useful = v + USEFUL_W'(1);
  endfunction

  function automatic logic [USEFUL_W-1:0] sat_dec_useful(input logic [USEFUL_W-1:0] v);
    if (v == '0) sat_dec_useful = v;
    else sat_dec_useful = v - USEFUL_W'(1);
  endfunction

  function automatic logic [IDX_W-1:0] index_of(input logic [Cfg.PLEN-1:0] pc,
                                                 input logic [PATH_HIST_BITS-1:0] ctx);
    logic [IDX_W-1:0] pc_idx;
    logic [IDX_W-1:0] fold_idx;
    logic [IDX_W-1:0] ctx_idx;
    begin
      pc_idx = pc[INSTR_ADDR_LSB+:IDX_W];
      fold_idx = '0;
      for (int i = INSTR_ADDR_LSB + IDX_W; i < Cfg.PLEN; i++) begin
        fold_idx[(i - (INSTR_ADDR_LSB + IDX_W)) % IDX_W] ^= pc[i];
      end
      ctx_idx = '0;
      for (int i = 0; i < IDX_W; i++) begin
        ctx_idx[i] = ctx[i%PATH_HIST_BITS];
      end
      index_of = pc_idx ^ fold_idx ^ ctx_idx;
    end
  endfunction

  function automatic logic [TAG_W-1:0] tag_of(input logic [Cfg.PLEN-1:0] pc,
                                               input logic [PATH_HIST_BITS-1:0] ctx);
    logic [TAG_W-1:0] tag_v;
    begin
      tag_v = '0;
      for (int i = INSTR_ADDR_LSB + IDX_W; i < Cfg.PLEN; i++) begin
        tag_v[(i - (INSTR_ADDR_LSB + IDX_W)) % TAG_W] ^= pc[i];
      end
      for (int i = 0; i < PATH_HIST_BITS; i++) begin
        tag_v[i%TAG_W] ^= ctx[i];
      end
      tag_of = tag_v;
    end
  endfunction

  always_comb begin
    for (int i = 0; i < INSTR_PER_FETCH; i++) begin
      logic [Cfg.PLEN-1:0] slot_pc;
      slot_pc = predict_base_pc_i + Cfg.PLEN'(INSTR_BYTES * i);
      pred_idx_w[i] = index_of(slot_pc, predict_ctx_i);
      pred_tag_w[i] = tag_of(slot_pc, predict_ctx_i);
      predict_hit_o[i] = valid_q[pred_idx_w[i]] &&
                         (tag_q[pred_idx_w[i]] == pred_tag_w[i]) &&
                         (conf_q[pred_idx_w[i]] >= CONF_THRESH);
      predict_target_o[i] = target_q[pred_idx_w[i]];
    end

    update_idx_w = index_of(update_pc_i, update_ctx_i);
    update_tag_w = tag_of(update_pc_i, update_ctx_i);
    update_match_w = valid_q[update_idx_w] && (tag_q[update_idx_w] == update_tag_w);
  end

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      valid_q <= '0;
      tag_q <= '0;
      target_q <= '0;
      conf_q <= '0;
      useful_q <= '0;
    end else if (update_valid_i) begin
      if (update_match_w) begin
        if (target_q[update_idx_w] == update_target_i) begin
          conf_q[update_idx_w] <= sat_inc_conf(conf_q[update_idx_w]);
          useful_q[update_idx_w] <= sat_inc_useful(useful_q[update_idx_w]);
        end else begin
          target_q[update_idx_w] <= update_target_i;
          conf_q[update_idx_w] <= sat_dec_conf(conf_q[update_idx_w]);
          useful_q[update_idx_w] <= sat_dec_useful(useful_q[update_idx_w]);
        end
      end else if (!valid_q[update_idx_w] || (useful_q[update_idx_w] == '0)) begin
        valid_q[update_idx_w] <= 1'b1;
        tag_q[update_idx_w] <= update_tag_w;
        target_q[update_idx_w] <= update_target_i;
        conf_q[update_idx_w] <= '0;
        useful_q[update_idx_w] <= '0;
      end else begin
        useful_q[update_idx_w] <= sat_dec_useful(useful_q[update_idx_w]);
      end
    end
  end

endmodule
