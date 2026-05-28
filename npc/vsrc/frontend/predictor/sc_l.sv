import config_pkg::*;

module sc_l #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned INSTR_PER_FETCH = Cfg.INSTR_PER_FETCH,
    parameter int unsigned GHR_BITS = 8,
    parameter int unsigned ENTRIES = 512,
    parameter int unsigned CTR_BITS = 4,
    parameter int unsigned CONF_THRESH = 3
) (
    input logic clk_i,
    input logic rst_i,

    input  logic [Cfg.PLEN-1:0] predict_base_pc_i,
    input  logic [((GHR_BITS > 0) ? GHR_BITS : 1)-1:0] predict_ghr_i,
    output logic [INSTR_PER_FETCH-1:0] predict_taken_o,
    output logic [INSTR_PER_FETCH-1:0] predict_confident_o,

    input logic update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic [((GHR_BITS > 0) ? GHR_BITS : 1)-1:0] update_ghr_i,
    input logic update_taken_i
);
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  localparam int unsigned INSTR_ADDR_LSB = 1;
  localparam int unsigned IDX_W = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
  localparam int unsigned GHR_W = (GHR_BITS > 0) ? GHR_BITS : 1;
  localparam logic signed [CTR_BITS-1:0] SC_MAX =
      {1'b0, {(CTR_BITS - 1) {1'b1}}};
  localparam logic signed [CTR_BITS-1:0] SC_MIN =
      {1'b1, {(CTR_BITS - 1) {1'b0}}};
  localparam logic signed [CTR_BITS-1:0] SC_THRESH = $signed(CONF_THRESH);

  logic [INSTR_PER_FETCH-1:0][IDX_W-1:0] pred_idx_w;
  logic [IDX_W-1:0] update_idx_w;
  logic signed [CTR_BITS-1:0] ctr_q [ENTRIES-1:0];

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
                                                     input int unsigned salt);
    logic [IDX_W-1:0] out_v;
    begin
      out_v = IDX_W'(salt * 13);
      for (int i = 0; i < GHR_W; i++) begin
        out_v[(i+salt)%IDX_W] ^= hist[i];
      end
      fold_hist_idx = out_v;
    end
  endfunction

  function automatic logic signed [CTR_BITS-1:0] sat_inc(input logic signed [CTR_BITS-1:0] val);
    if (val == SC_MAX) sat_inc = val;
    else sat_inc = val + $signed(1);
  endfunction

  function automatic logic signed [CTR_BITS-1:0] sat_dec(input logic signed [CTR_BITS-1:0] val);
    if (val == SC_MIN) sat_dec = val;
    else sat_dec = val - $signed(1);
  endfunction

  always_comb begin
    for (int i = 0; i < INSTR_PER_FETCH; i++) begin
      logic [Cfg.PLEN-1:0] slot_pc;
      logic signed [CTR_BITS-1:0] ctr_v;

      slot_pc = predict_base_pc_i + Cfg.PLEN'(INSTR_BYTES * i);
      pred_idx_w[i] = fold_pc_idx(slot_pc, 3) ^ fold_hist_idx(predict_ghr_i, 5);
      ctr_v = ctr_q[pred_idx_w[i]];

      predict_taken_o[i] = (ctr_v >= $signed(0));
      predict_confident_o[i] = (ctr_v >= SC_THRESH) || (ctr_v <= -SC_THRESH);
    end

    update_idx_w = fold_pc_idx(update_pc_i, 3) ^ fold_hist_idx(update_ghr_i, 5);
  end

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      for (int i = 0; i < ENTRIES; i++) begin
        ctr_q[i] = '0;
      end
    end else if (update_valid_i) begin
      if (update_taken_i) begin
        ctr_q[update_idx_w] <= sat_inc(ctr_q[update_idx_w]);
      end else begin
        ctr_q[update_idx_w] <= sat_dec(ctr_q[update_idx_w]);
      end
    end
  end

endmodule
