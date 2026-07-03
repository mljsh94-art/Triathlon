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

    input logic [INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] predict_pc_i,
    output logic [INSTR_PER_FETCH-1:0] predict_taken_o,
    output logic [INSTR_PER_FETCH-1:0] predict_confident_o,
    output logic [INSTR_PER_FETCH-1:0] predict_hit_o,

    input logic flush_i,
    input logic predict_fire_i,
    input logic predict_spec_valid_i,
    input logic [Cfg.PLEN-1:0] predict_spec_pc_i,
    input logic predict_spec_taken_i,

    input logic update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic update_is_cond_i,
    input logic update_taken_i
);
  localparam int unsigned INSTR_ADDR_LSB = 1;
  localparam int unsigned IDX_W = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
  localparam logic [ITER_BITS-1:0] ITER_MAX = {ITER_BITS{1'b1}};
  localparam logic [CONF_BITS-1:0] CONF_MAX = {CONF_BITS{1'b1}};
  localparam logic [CONF_BITS-1:0] CONF_TH = CONF_BITS'(CONF_THRESH);

  logic [ENTRIES-1:0] valid_q;
  logic [ENTRIES-1:0][TAG_BITS-1:0] tag_q;
  logic [ENTRIES-1:0][ITER_BITS-1:0] trip_count_q;
  logic [ENTRIES-1:0][ITER_BITS-1:0] iter_count_q;
  logic [ENTRIES-1:0][ITER_BITS-1:0] spec_iter_count_q;
  logic [ENTRIES-1:0][CONF_BITS-1:0] conf_q;

  logic [INSTR_PER_FETCH-1:0][IDX_W-1:0] pred_idx_w;
  logic [INSTR_PER_FETCH-1:0][TAG_BITS-1:0] pred_tag_w;
  logic [IDX_W-1:0] up_idx_w;
  logic [TAG_BITS-1:0] up_tag_w;
  logic [IDX_W-1:0] pred_sel_idx_w;
  logic [TAG_BITS-1:0] pred_sel_tag_w;

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
      logic hit;
      logic confident;
      pred_idx_w[i] = idx_of(predict_pc_i[i]);
      pred_tag_w[i] = tag_of(predict_pc_i[i]);

      hit = valid_q[pred_idx_w[i]] && (tag_q[pred_idx_w[i]] == pred_tag_w[i]);
      confident = hit &&
                  (trip_count_q[pred_idx_w[i]] != '0) &&
                  (conf_q[pred_idx_w[i]] >= CONF_TH);
      predict_hit_o[i] = hit;
      predict_confident_o[i] = confident;
      predict_taken_o[i] =
          confident && (spec_iter_count_q[pred_idx_w[i]] < trip_count_q[pred_idx_w[i]]);
    end

    up_idx_w = idx_of(update_pc_i);
    up_tag_w = tag_of(update_pc_i);
    pred_sel_idx_w = idx_of(predict_spec_pc_i);
    pred_sel_tag_w = tag_of(predict_spec_pc_i);
  end

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      valid_q <= '0;
      tag_q <= '0;
      trip_count_q <= '0;
      iter_count_q <= '0;
      spec_iter_count_q <= '0;
      conf_q <= '0;
    end else begin
      logic hit;
      logic update_fire;
      logic pred_hit;
      logic [ITER_BITS-1:0] iter_next;
      logic [ITER_BITS-1:0] trip_next;
      logic [CONF_BITS-1:0] conf_next;
      logic valid_next;
      logic [TAG_BITS-1:0] tag_next;

      update_fire = update_valid_i && update_is_cond_i;
      hit = valid_q[up_idx_w] && (tag_q[up_idx_w] == up_tag_w);
      iter_next = iter_count_q[up_idx_w];
      trip_next = trip_count_q[up_idx_w];
      conf_next = conf_q[up_idx_w];
      valid_next = valid_q[up_idx_w];
      tag_next = tag_q[up_idx_w];

      if (update_fire) begin
        if (hit) begin
          if (update_taken_i) begin
            if (iter_count_q[up_idx_w] != ITER_MAX) begin
              iter_next = iter_count_q[up_idx_w] + ITER_BITS'(1);
            end
          end else begin
            if (iter_count_q[up_idx_w] != '0) begin
              if (trip_count_q[up_idx_w] == iter_count_q[up_idx_w]) begin
                if (conf_q[up_idx_w] != CONF_MAX) begin
                  conf_next = conf_q[up_idx_w] + CONF_BITS'(1);
                end
              end else begin
                trip_next = iter_count_q[up_idx_w];
                conf_next = '0;
              end
              iter_next = '0;
            end else begin
              if (conf_q[up_idx_w] != '0) begin
                conf_next = conf_q[up_idx_w] - CONF_BITS'(1);
              end
            end
          end
        end else if (update_taken_i) begin
          valid_next = 1'b1;
          tag_next = up_tag_w;
          trip_next = '0;
          iter_next = ITER_BITS'(1);
          conf_next = '0;
        end

        valid_q[up_idx_w] <= valid_next;
        tag_q[up_idx_w] <= tag_next;
        trip_count_q[up_idx_w] <= trip_next;
        iter_count_q[up_idx_w] <= iter_next;
        conf_q[up_idx_w] <= conf_next;
      end

      if (flush_i) begin
        spec_iter_count_q <= iter_count_q;
        if (update_fire) begin
          spec_iter_count_q[up_idx_w] <= iter_next;
        end
      end else begin
        if (update_fire && !hit && update_taken_i) begin
          spec_iter_count_q[up_idx_w] <= iter_next;
        end

        pred_hit = predict_fire_i && predict_spec_valid_i &&
                   valid_q[pred_sel_idx_w] && (tag_q[pred_sel_idx_w] == pred_sel_tag_w);
        if (pred_hit) begin
          if (predict_spec_taken_i) begin
            if (spec_iter_count_q[pred_sel_idx_w] != ITER_MAX) begin
              spec_iter_count_q[pred_sel_idx_w] <=
                  spec_iter_count_q[pred_sel_idx_w] + ITER_BITS'(1);
            end
          end else begin
            spec_iter_count_q[pred_sel_idx_w] <= '0;
          end
        end
      end
    end
  end

endmodule
