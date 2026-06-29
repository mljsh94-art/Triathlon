// vsrc/frontend/predictor/bpu_bht.sv
// Legacy bimodal/tournament conditional predictor: local + global (gshare)
// 2-bit counter tables plus the per-PC tournament chooser. Owns the BHT/chooser
// storage, the pc/global index hash functions, the saturating counter helpers,
// the predict-time "legacy strong/disagree" sideband used to gate the SC
// override, and the commit-time tournament training (with its cond accuracy
// counters). Behavior is identical to the inline BHT that previously lived in
// bpu.sv: logic was moved out unchanged, only scope/wiring differs.
//
// The full counter arrays are exposed read-only so bpu_ftb can keep reading the
// legacy direction per slot during its lookup scan, exactly as before.
import global_config_pkg::*;
module bpu_bht #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned BHT_ENTRIES = 128,
    parameter bit BHT_HASH_ENABLE = 1'b1,
    parameter bit USE_GSHARE = 1'b0,
    parameter bit USE_TOURNAMENT = 1'b1,
    parameter int unsigned GHR_BITS = 8
) (
    input logic clk_i,
    input logic rst_i,

    // BHT counter arrays (read-only export; storage owned here).
    output logic [BHT_ENTRIES-1:0][1:0] local_bht_o,
    output logic [BHT_ENTRIES-1:0][1:0] global_bht_o,
    output logic [BHT_ENTRIES-1:0][1:0] chooser_o,

    // Predict-time legacy direction sideband (combinational) used by bpu.sv to
    // gate the statistical-corrector override.
    input  logic [Cfg.PLEN-1:0]                       predict_pc_i,
    input  logic [((GHR_BITS > 0) ? GHR_BITS : 1)-1:0] predict_ghr_i,
    input  logic                                      predict_is_backward_i,
    output logic                                      predict_local_legacy_strong_o,
    output logic                                      predict_global_legacy_strong_o,
    output logic                                      predict_local_global_disagree_o,
    output logic                                      predict_selected_legacy_strong_o,

    // Commit-time tournament training (from FTQ commit update).
    input logic                update_valid_i,
    input logic                update_is_cond_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic                update_taken_i,
    input logic [Cfg.PLEN-1:0] update_target_i,
    input logic [((GHR_BITS > 0) ? GHR_BITS : 1)-1:0] update_ghr_i,

    // Diagnostic cond accuracy counters (read via hierarchy by the testbench).
    output logic [63:0] dbg_cond_update_total_o,
    output logic [63:0] dbg_cond_local_correct_o,
    output logic [63:0] dbg_cond_global_correct_o,
    output logic [63:0] dbg_cond_selected_correct_o,
    output logic [63:0] dbg_cond_choose_local_o,
    output logic [63:0] dbg_cond_choose_global_o
);

  localparam int unsigned BHT_IDX_W = (BHT_ENTRIES > 1) ? $clog2(BHT_ENTRIES) : 1;
  // RV32C instructions are 16-bit aligned. BHT indexing must include pc[1].
  localparam int unsigned INSTR_ADDR_LSB = 1;
  localparam int unsigned GHR_W = (GHR_BITS > 0) ? GHR_BITS : 1;

  logic [BHT_ENTRIES-1:0][1:0] local_bht_q;
  logic [BHT_ENTRIES-1:0][1:0] global_bht_q;
  logic [BHT_ENTRIES-1:0][1:0] chooser_q;

  logic [63:0] dbg_cond_update_total_q;
  logic [63:0] dbg_cond_local_correct_q;
  logic [63:0] dbg_cond_global_correct_q;
  logic [63:0] dbg_cond_selected_correct_q;
  logic [63:0] dbg_cond_choose_local_q;
  logic [63:0] dbg_cond_choose_global_q;

  function automatic logic [BHT_IDX_W-1:0] bht_pc_index(input logic [Cfg.PLEN-1:0] pc);
    logic [BHT_IDX_W-1:0] pc_idx;
    logic [BHT_IDX_W-1:0] fold_idx;
    logic [BHT_IDX_W-1:0] mixed_pc_idx;
    begin
      pc_idx = pc[INSTR_ADDR_LSB+:BHT_IDX_W];
      fold_idx = '0;
      for (int i = INSTR_ADDR_LSB + BHT_IDX_W; i < Cfg.PLEN; i++) begin
        fold_idx[(i - (INSTR_ADDR_LSB + BHT_IDX_W)) % BHT_IDX_W] ^= pc[i];
      end
      mixed_pc_idx = BHT_HASH_ENABLE ? (pc_idx ^ fold_idx) : pc_idx;
      bht_pc_index = mixed_pc_idx;
    end
  endfunction

  function automatic logic [BHT_IDX_W-1:0] bht_global_index(input logic [Cfg.PLEN-1:0] pc,
                                                             input logic [GHR_W-1:0] ghr);
    logic [BHT_IDX_W-1:0] ghr_idx;
    begin
      ghr_idx = '0;
      for (int i = 0; i < BHT_IDX_W; i++) begin
        ghr_idx[i] = ghr[i%GHR_W];
      end
      bht_global_index = bht_pc_index(pc) ^ ghr_idx;
    end
  endfunction

  function automatic logic [1:0] sat_inc(input logic [1:0] val);
    if (val == 2'b11) sat_inc = val;
    else sat_inc = val + 2'b01;
  endfunction

  function automatic logic [1:0] sat_dec(input logic [1:0] val);
    if (val == 2'b00) sat_dec = val;
    else sat_dec = val - 2'b01;
  endfunction

  assign local_bht_o = local_bht_q;
  assign global_bht_o = global_bht_q;
  assign chooser_o = chooser_q;

  assign dbg_cond_update_total_o = dbg_cond_update_total_q;
  assign dbg_cond_local_correct_o = dbg_cond_local_correct_q;
  assign dbg_cond_global_correct_o = dbg_cond_global_correct_q;
  assign dbg_cond_selected_correct_o = dbg_cond_selected_correct_q;
  assign dbg_cond_choose_local_o = dbg_cond_choose_local_q;
  assign dbg_cond_choose_global_o = dbg_cond_choose_global_q;

  // Predict-time legacy direction sideband (gates SC override in bpu.sv).
  always_comb begin
    logic [BHT_IDX_W-1:0] local_idx;
    logic [BHT_IDX_W-1:0] global_idx;
    logic [1:0] local_ctr_pred;
    logic [1:0] global_ctr_pred;
    logic [1:0] selected_ctr_pred;
    logic local_taken_pred;
    logic global_taken_pred;
    logic use_global_pred;

    local_idx = bht_pc_index(predict_pc_i);
    global_idx = bht_global_index(predict_pc_i, predict_ghr_i);
    local_ctr_pred = local_bht_q[local_idx];
    global_ctr_pred = global_bht_q[global_idx];
    local_taken_pred = local_ctr_pred[1] ||
                       ((local_ctr_pred == 2'b01) && predict_is_backward_i);
    global_taken_pred = global_ctr_pred[1] ||
                        ((global_ctr_pred == 2'b01) && predict_is_backward_i);
    use_global_pred = USE_GSHARE && (!USE_TOURNAMENT || chooser_q[local_idx][1]);
    selected_ctr_pred = use_global_pred ? global_ctr_pred : local_ctr_pred;

    predict_local_legacy_strong_o = (local_ctr_pred == 2'b00) || (local_ctr_pred == 2'b11);
    predict_global_legacy_strong_o = (global_ctr_pred == 2'b00) || (global_ctr_pred == 2'b11);
    predict_local_global_disagree_o = (local_taken_pred != global_taken_pred);
    predict_selected_legacy_strong_o =
        (selected_ctr_pred == 2'b00) || (selected_ctr_pred == 2'b11);
  end

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      dbg_cond_update_total_q <= '0;
      dbg_cond_local_correct_q <= '0;
      dbg_cond_global_correct_q <= '0;
      dbg_cond_selected_correct_q <= '0;
      dbg_cond_choose_local_q <= '0;
      dbg_cond_choose_global_q <= '0;
      for (int i = 0; i < BHT_ENTRIES; i++) begin
        local_bht_q[i] <= 2'b01;
        global_bht_q[i] <= 2'b01;
        chooser_q[i] <= 2'b01;
      end
    end else begin
      logic [BHT_IDX_W-1:0] up_local_idx;
      logic [BHT_IDX_W-1:0] up_global_idx;
      logic [BHT_IDX_W-1:0] up_chooser_idx;
      logic local_pred_before;
      logic global_pred_before;
      logic selected_pred_before;
      logic choose_global_before;
      logic local_correct;
      logic global_correct;
      logic selected_correct;

      if (update_valid_i) begin
        up_local_idx = bht_pc_index(update_pc_i);
        up_global_idx = bht_global_index(update_pc_i, update_ghr_i);
        up_chooser_idx = up_local_idx;

        if (update_is_cond_i) begin
          local_pred_before = local_bht_q[up_local_idx][1] ||
                              ((local_bht_q[up_local_idx] == 2'b01) &&
                               (update_target_i < update_pc_i));
          global_pred_before = global_bht_q[up_global_idx][1] ||
                               ((global_bht_q[up_global_idx] == 2'b01) &&
                                (update_target_i < update_pc_i));
          choose_global_before = USE_GSHARE && (!USE_TOURNAMENT || chooser_q[up_chooser_idx][1]);
          selected_pred_before = choose_global_before ? global_pred_before : local_pred_before;
          local_correct = (local_pred_before == update_taken_i);
          global_correct = (global_pred_before == update_taken_i);
          selected_correct = (selected_pred_before == update_taken_i);

          dbg_cond_update_total_q <= dbg_cond_update_total_q + 64'd1;
          if (local_correct) begin
            dbg_cond_local_correct_q <= dbg_cond_local_correct_q + 64'd1;
          end
          if (global_correct) begin
            dbg_cond_global_correct_q <= dbg_cond_global_correct_q + 64'd1;
          end
          if (selected_correct) begin
            dbg_cond_selected_correct_q <= dbg_cond_selected_correct_q + 64'd1;
          end
          if (choose_global_before) begin
            dbg_cond_choose_global_q <= dbg_cond_choose_global_q + 64'd1;
          end else begin
            dbg_cond_choose_local_q <= dbg_cond_choose_local_q + 64'd1;
          end

          if (update_taken_i) begin
            local_bht_q[up_local_idx] <= sat_inc(local_bht_q[up_local_idx]);
            global_bht_q[up_global_idx] <= sat_inc(global_bht_q[up_global_idx]);
          end else begin
            local_bht_q[up_local_idx] <= sat_dec(local_bht_q[up_local_idx]);
            global_bht_q[up_global_idx] <= sat_dec(global_bht_q[up_global_idx]);
          end

          if (USE_GSHARE && USE_TOURNAMENT && (local_correct != global_correct)) begin
            if (global_correct) begin
              chooser_q[up_chooser_idx] <= sat_inc(chooser_q[up_chooser_idx]);
            end else begin
              chooser_q[up_chooser_idx] <= sat_dec(chooser_q[up_chooser_idx]);
            end
          end
        end
      end
    end
  end

endmodule : bpu_bht
