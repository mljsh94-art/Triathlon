import config_pkg::*;

module loop_predictor #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned INSTR_PER_FETCH = Cfg.INSTR_PER_FETCH,
    parameter int unsigned ENTRIES = 64,
    parameter int unsigned TAG_BITS = 10,
    parameter int unsigned ITER_BITS = 8,
    parameter int unsigned CONF_BITS = 2,
    parameter int unsigned CONF_THRESH = 2
) (
    input logic clk_i,
    input logic rst_i,

    input logic [Cfg.PLEN-1:0] predict_base_pc_i,
    output logic [INSTR_PER_FETCH-1:0] predict_taken_o,
    output logic [INSTR_PER_FETCH-1:0] predict_confident_o,
    output logic [INSTR_PER_FETCH-1:0] predict_hit_o,

    input logic update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic update_is_cond_i,
    input logic update_taken_i
);
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  localparam int unsigned INSTR_ADDR_LSB = 1;
  localparam int unsigned IDX_W = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
  localparam logic [ITER_BITS-1:0] ITER_MAX = {ITER_BITS{1'b1}};
  localparam logic [CONF_BITS-1:0] CONF_MAX = {CONF_BITS{1'b1}};
  localparam logic [CONF_BITS-1:0] CONF_TH = CONF_BITS'(CONF_THRESH);

  logic [ENTRIES-1:0] valid_q;
  logic [ENTRIES-1:0][TAG_BITS-1:0] tag_q;
  logic [ENTRIES-1:0][ITER_BITS-1:0] trip_count_q;
  logic [ENTRIES-1:0][ITER_BITS-1:0] iter_count_q;
  logic [ENTRIES-1:0][CONF_BITS-1:0] conf_q;

  logic [INSTR_PER_FETCH-1:0][IDX_W-1:0] pred_idx_w;
  logic [INSTR_PER_FETCH-1:0][TAG_BITS-1:0] pred_tag_w;
  logic [IDX_W-1:0] up_idx_w;
  logic [TAG_BITS-1:0] up_tag_w;

  function automatic logic [IDX_W-1:0] idx_of(input logic [Cfg.PLEN-1:0] pc);
    logic [IDX_W-1:0] base;
    logic [IDX_W-1:0] fold;
    begin
      base = pc[INSTR_ADDR_LSB+:IDX_W];
      fold = '0;
      for (int i = INSTR_ADDR_LSB + IDX_W; i < Cfg.PLEN; i++) begin
        fold[(i - (INSTR_ADDR_LSB + IDX_W)) % IDX_W] ^= pc[i];
      end
      idx_of = base ^ fold;
    end
  endfunction

  function automatic logic [TAG_BITS-1:0] tag_of(input logic [Cfg.PLEN-1:0] pc);
    logic [TAG_BITS-1:0] tag_v;
    begin
      tag_v = '0;
      for (int i = INSTR_ADDR_LSB + IDX_W; i < Cfg.PLEN; i++) begin
        tag_v[(i - (INSTR_ADDR_LSB + IDX_W)) % TAG_BITS] ^= pc[i];
      end
      tag_of = tag_v;
    end
  endfunction

  always_comb begin
    for (int i = 0; i < INSTR_PER_FETCH; i++) begin
      logic [Cfg.PLEN-1:0] slot_pc;
      logic hit;
      logic confident;
      slot_pc = predict_base_pc_i + Cfg.PLEN'(INSTR_BYTES * i);
      pred_idx_w[i] = idx_of(slot_pc);
      pred_tag_w[i] = tag_of(slot_pc);

      hit = valid_q[pred_idx_w[i]] && (tag_q[pred_idx_w[i]] == pred_tag_w[i]);
      confident = hit &&
                  (trip_count_q[pred_idx_w[i]] != '0) &&
                  (conf_q[pred_idx_w[i]] >= CONF_TH);
      predict_hit_o[i] = hit;
      predict_confident_o[i] = confident;
      predict_taken_o[i] = confident && (iter_count_q[pred_idx_w[i]] < trip_count_q[pred_idx_w[i]]);
    end

    up_idx_w = idx_of(update_pc_i);
    up_tag_w = tag_of(update_pc_i);
  end

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      valid_q <= '0;
      tag_q <= '0;
      trip_count_q <= '0;
      iter_count_q <= '0;
      conf_q <= '0;
    end else if (update_valid_i && update_is_cond_i) begin
      logic hit;
      hit = valid_q[up_idx_w] && (tag_q[up_idx_w] == up_tag_w);

      if (hit) begin
        if (update_taken_i) begin
          if (iter_count_q[up_idx_w] != ITER_MAX) begin
            iter_count_q[up_idx_w] <= iter_count_q[up_idx_w] + ITER_BITS'(1);
          end
        end else begin
          if (iter_count_q[up_idx_w] != '0) begin
            if (trip_count_q[up_idx_w] == iter_count_q[up_idx_w]) begin
              if (conf_q[up_idx_w] != CONF_MAX) begin
                conf_q[up_idx_w] <= conf_q[up_idx_w] + CONF_BITS'(1);
              end
            end else begin
              trip_count_q[up_idx_w] <= iter_count_q[up_idx_w];
              conf_q[up_idx_w] <= '0;
            end
            iter_count_q[up_idx_w] <= '0;
          end else begin
            if (conf_q[up_idx_w] != '0) begin
              conf_q[up_idx_w] <= conf_q[up_idx_w] - CONF_BITS'(1);
            end
          end
        end
      end else if (update_taken_i) begin
        valid_q[up_idx_w] <= 1'b1;
        tag_q[up_idx_w] <= up_tag_w;
        trip_count_q[up_idx_w] <= '0;
        iter_count_q[up_idx_w] <= ITER_BITS'(1);
        conf_q[up_idx_w] <= '0;
      end
    end
  end

endmodule
