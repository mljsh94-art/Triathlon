import config_pkg::*;

module tage #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned INSTR_PER_FETCH = Cfg.INSTR_PER_FETCH,
    parameter int unsigned GHR_BITS = 8,
    parameter int unsigned TABLE_ENTRIES = 128,
    parameter int unsigned TAG_BITS = 8,
    parameter int unsigned HIST_LEN0 = 2,
    parameter int unsigned HIST_LEN1 = 4,
    parameter int unsigned HIST_LEN2 = 6,
    parameter int unsigned HIST_LEN3 = 8
) (
    input logic clk_i,
    input logic rst_i,

    input  logic [Cfg.PLEN-1:0] predict_base_pc_i,
    input  logic [((GHR_BITS > 0) ? GHR_BITS : 1)-1:0] predict_ghr_i,
    output logic [INSTR_PER_FETCH-1:0] predict_hit_o,
    output logic [INSTR_PER_FETCH-1:0] predict_taken_o,
    output logic [INSTR_PER_FETCH-1:0] predict_strong_o,
    output logic [INSTR_PER_FETCH-1:0][1:0] predict_provider_o,

    input logic update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic [((GHR_BITS > 0) ? GHR_BITS : 1)-1:0] update_ghr_i,
    input logic update_taken_i
);

  localparam int unsigned NUM_TABLES = 4;
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  localparam int unsigned INSTR_ADDR_LSB = 1;
  localparam int unsigned IDX_W = (TABLE_ENTRIES > 1) ? $clog2(TABLE_ENTRIES) : 1;
  localparam int unsigned GHR_W = (GHR_BITS > 0) ? GHR_BITS : 1;
  localparam int unsigned SLOT_IDX_W = (INSTR_PER_FETCH > 1) ? $clog2(INSTR_PER_FETCH) : 1;

  logic [INSTR_PER_FETCH-1:0][IDX_W-1:0] pred_idx_t0, pred_idx_t1, pred_idx_t2, pred_idx_t3;
  logic [INSTR_PER_FETCH-1:0][TAG_BITS-1:0] pred_tag_t0, pred_tag_t1, pred_tag_t2, pred_tag_t3;
  logic [INSTR_PER_FETCH-1:0] hit_t0, hit_t1, hit_t2, hit_t3;
  logic [INSTR_PER_FETCH-1:0][1:0] ctr_t0, ctr_t1, ctr_t2, ctr_t3;

  logic [IDX_W-1:0] update_idx_t0, update_idx_t1, update_idx_t2, update_idx_t3;
  logic [TAG_BITS-1:0] update_tag_t0, update_tag_t1, update_tag_t2, update_tag_t3;
  logic upd_hit_t0, upd_hit_t1, upd_hit_t2, upd_hit_t3;

  logic upd_provider_hit;
  logic [1:0] upd_provider_idx;
  logic [1:0] upd_provider_ctr;
  logic upd_need_alloc;
  logic upd_alloc_valid;
  logic [1:0] upd_alloc_idx;

  logic upd_t0_valid, upd_t1_valid, upd_t2_valid, upd_t3_valid;
  logic upd_t0_alloc, upd_t1_alloc, upd_t2_alloc, upd_t3_alloc;

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

  always_comb begin
    for (int i = 0; i < INSTR_PER_FETCH; i++) begin
      logic [Cfg.PLEN-1:0] slot_pc;
      slot_pc = predict_base_pc_i + Cfg.PLEN'(INSTR_BYTES * i);

      pred_idx_t0[i] = fold_pc_idx(slot_pc, 1) ^ fold_hist_idx(predict_ghr_i, HIST_LEN0, 3);
      pred_idx_t1[i] = fold_pc_idx(slot_pc, 2) ^ fold_hist_idx(predict_ghr_i, HIST_LEN1, 5);
      pred_idx_t2[i] = fold_pc_idx(slot_pc, 4) ^ fold_hist_idx(predict_ghr_i, HIST_LEN2, 7);
      pred_idx_t3[i] = fold_pc_idx(slot_pc, 6) ^ fold_hist_idx(predict_ghr_i, HIST_LEN3, 11);

      pred_tag_t0[i] = fold_pc_tag(slot_pc, 1) ^ fold_hist_tag(predict_ghr_i, HIST_LEN0, 3);
      pred_tag_t1[i] = fold_pc_tag(slot_pc, 2) ^ fold_hist_tag(predict_ghr_i, HIST_LEN1, 5);
      pred_tag_t2[i] = fold_pc_tag(slot_pc, 4) ^ fold_hist_tag(predict_ghr_i, HIST_LEN2, 7);
      pred_tag_t3[i] = fold_pc_tag(slot_pc, 6) ^ fold_hist_tag(predict_ghr_i, HIST_LEN3, 11);
    end

    update_idx_t0 = fold_pc_idx(update_pc_i, 1) ^ fold_hist_idx(update_ghr_i, HIST_LEN0, 3);
    update_idx_t1 = fold_pc_idx(update_pc_i, 2) ^ fold_hist_idx(update_ghr_i, HIST_LEN1, 5);
    update_idx_t2 = fold_pc_idx(update_pc_i, 4) ^ fold_hist_idx(update_ghr_i, HIST_LEN2, 7);
    update_idx_t3 = fold_pc_idx(update_pc_i, 6) ^ fold_hist_idx(update_ghr_i, HIST_LEN3, 11);

    update_tag_t0 = fold_pc_tag(update_pc_i, 1) ^ fold_hist_tag(update_ghr_i, HIST_LEN0, 3);
    update_tag_t1 = fold_pc_tag(update_pc_i, 2) ^ fold_hist_tag(update_ghr_i, HIST_LEN1, 5);
    update_tag_t2 = fold_pc_tag(update_pc_i, 4) ^ fold_hist_tag(update_ghr_i, HIST_LEN2, 7);
    update_tag_t3 = fold_pc_tag(update_pc_i, 6) ^ fold_hist_tag(update_ghr_i, HIST_LEN3, 11);
  end

  tage_table #(
      .INSTR_PER_FETCH(INSTR_PER_FETCH),
      .ENTRIES(TABLE_ENTRIES),
      .TAG_BITS(TAG_BITS)
  ) u_tage_t0 (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_idx_i(pred_idx_t0),
      .predict_tag_i(pred_tag_t0),
      .predict_hit_o(hit_t0),
      .predict_ctr_o(ctr_t0),
      .update_valid_i(upd_t0_valid),
      .update_idx_i(update_idx_t0),
      .update_tag_i(update_tag_t0),
      .update_taken_i(update_taken_i),
      .update_alloc_i(upd_t0_alloc),
      .update_hit_o(upd_hit_t0)
  );

  tage_table #(
      .INSTR_PER_FETCH(INSTR_PER_FETCH),
      .ENTRIES(TABLE_ENTRIES),
      .TAG_BITS(TAG_BITS)
  ) u_tage_t1 (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_idx_i(pred_idx_t1),
      .predict_tag_i(pred_tag_t1),
      .predict_hit_o(hit_t1),
      .predict_ctr_o(ctr_t1),
      .update_valid_i(upd_t1_valid),
      .update_idx_i(update_idx_t1),
      .update_tag_i(update_tag_t1),
      .update_taken_i(update_taken_i),
      .update_alloc_i(upd_t1_alloc),
      .update_hit_o(upd_hit_t1)
  );

  tage_table #(
      .INSTR_PER_FETCH(INSTR_PER_FETCH),
      .ENTRIES(TABLE_ENTRIES),
      .TAG_BITS(TAG_BITS)
  ) u_tage_t2 (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_idx_i(pred_idx_t2),
      .predict_tag_i(pred_tag_t2),
      .predict_hit_o(hit_t2),
      .predict_ctr_o(ctr_t2),
      .update_valid_i(upd_t2_valid),
      .update_idx_i(update_idx_t2),
      .update_tag_i(update_tag_t2),
      .update_taken_i(update_taken_i),
      .update_alloc_i(upd_t2_alloc),
      .update_hit_o(upd_hit_t2)
  );

  tage_table #(
      .INSTR_PER_FETCH(INSTR_PER_FETCH),
      .ENTRIES(TABLE_ENTRIES),
      .TAG_BITS(TAG_BITS)
  ) u_tage_t3 (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_idx_i(pred_idx_t3),
      .predict_tag_i(pred_tag_t3),
      .predict_hit_o(hit_t3),
      .predict_ctr_o(ctr_t3),
      .update_valid_i(upd_t3_valid),
      .update_idx_i(update_idx_t3),
      .update_tag_i(update_tag_t3),
      .update_taken_i(update_taken_i),
      .update_alloc_i(upd_t3_alloc),
      .update_hit_o(upd_hit_t3)
  );

  always_comb begin
    for (int i = 0; i < INSTR_PER_FETCH; i++) begin
      predict_hit_o[i] = 1'b0;
      predict_taken_o[i] = 1'b0;
      predict_strong_o[i] = 1'b0;
      predict_provider_o[i] = '0;

      if (hit_t3[i]) begin
        predict_hit_o[i] = 1'b1;
        predict_provider_o[i] = 2'd3;
        predict_taken_o[i] = ctr_t3[i][1];
        predict_strong_o[i] = (ctr_t3[i] == 2'b00) || (ctr_t3[i] == 2'b11);
      end else if (hit_t2[i]) begin
        predict_hit_o[i] = 1'b1;
        predict_provider_o[i] = 2'd2;
        predict_taken_o[i] = ctr_t2[i][1];
        predict_strong_o[i] = (ctr_t2[i] == 2'b00) || (ctr_t2[i] == 2'b11);
      end else if (hit_t1[i]) begin
        predict_hit_o[i] = 1'b1;
        predict_provider_o[i] = 2'd1;
        predict_taken_o[i] = ctr_t1[i][1];
        predict_strong_o[i] = (ctr_t1[i] == 2'b00) || (ctr_t1[i] == 2'b11);
      end else if (hit_t0[i]) begin
        predict_hit_o[i] = 1'b1;
        predict_provider_o[i] = 2'd0;
        predict_taken_o[i] = ctr_t0[i][1];
        predict_strong_o[i] = (ctr_t0[i] == 2'b00) || (ctr_t0[i] == 2'b11);
      end
    end
  end

  always_comb begin
    upd_provider_hit = 1'b0;
    upd_provider_idx = '0;
    upd_provider_ctr = 2'b01;

    if (upd_hit_t3) begin
      upd_provider_hit = 1'b1;
      upd_provider_idx = 2'd3;
      upd_provider_ctr = ctr_t3[0];
    end else if (upd_hit_t2) begin
      upd_provider_hit = 1'b1;
      upd_provider_idx = 2'd2;
      upd_provider_ctr = ctr_t2[0];
    end else if (upd_hit_t1) begin
      upd_provider_hit = 1'b1;
      upd_provider_idx = 2'd1;
      upd_provider_ctr = ctr_t1[0];
    end else if (upd_hit_t0) begin
      upd_provider_hit = 1'b1;
      upd_provider_idx = 2'd0;
      upd_provider_ctr = ctr_t0[0];
    end

    upd_need_alloc = update_valid_i &&
                     (!upd_provider_hit || (upd_provider_ctr[1] != update_taken_i));

    upd_alloc_valid = 1'b0;
    upd_alloc_idx = '0;
    if (upd_need_alloc) begin
      if (!upd_hit_t3) begin
        upd_alloc_valid = 1'b1;
        upd_alloc_idx = 2'd3;
      end else if (!upd_hit_t2) begin
        upd_alloc_valid = 1'b1;
        upd_alloc_idx = 2'd2;
      end else if (!upd_hit_t1) begin
        upd_alloc_valid = 1'b1;
        upd_alloc_idx = 2'd1;
      end else if (!upd_hit_t0) begin
        upd_alloc_valid = 1'b1;
        upd_alloc_idx = 2'd0;
      end
    end

    upd_t0_valid = (update_valid_i && upd_provider_hit && (upd_provider_idx == 2'd0)) ||
                   (upd_alloc_valid && (upd_alloc_idx == 2'd0));
    upd_t1_valid = (update_valid_i && upd_provider_hit && (upd_provider_idx == 2'd1)) ||
                   (upd_alloc_valid && (upd_alloc_idx == 2'd1));
    upd_t2_valid = (update_valid_i && upd_provider_hit && (upd_provider_idx == 2'd2)) ||
                   (upd_alloc_valid && (upd_alloc_idx == 2'd2));
    upd_t3_valid = (update_valid_i && upd_provider_hit && (upd_provider_idx == 2'd3)) ||
                   (upd_alloc_valid && (upd_alloc_idx == 2'd3));

    upd_t0_alloc = upd_alloc_valid && (upd_alloc_idx == 2'd0);
    upd_t1_alloc = upd_alloc_valid && (upd_alloc_idx == 2'd1);
    upd_t2_alloc = upd_alloc_valid && (upd_alloc_idx == 2'd2);
    upd_t3_alloc = upd_alloc_valid && (upd_alloc_idx == 2'd3);
  end

endmodule
