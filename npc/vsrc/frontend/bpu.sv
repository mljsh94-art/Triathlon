import global_config_pkg::*;
module bpu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned BTB_ENTRIES = 64,
    parameter int unsigned BHT_ENTRIES = 128,
    parameter int unsigned RAS_DEPTH = 16,
    parameter bit BTB_HASH_ENABLE = 1'b1,
    parameter bit BHT_HASH_ENABLE = 1'b1,
    parameter bit USE_GSHARE = 1'b0,
    parameter bit USE_TAGE = 1'b0,
    parameter bit USE_SC_L = 1'b0,
    parameter bit USE_TOURNAMENT = 1'b1,
    parameter int unsigned GHR_BITS = 8,
    parameter int unsigned SC_L_ENTRIES = 512,
    parameter int unsigned SC_L_CONF_THRESH = 3,
    parameter bit SC_L_REQUIRE_DISAGREE = 1'b1,
    parameter bit SC_L_REQUIRE_BOTH_WEAK = 1'b1,
    parameter bit SC_L_BLOCK_ON_TAGE_HIT = 1'b1,
    parameter bit USE_LOOP = 1'b0,
    parameter int unsigned LOOP_ENTRIES = 64,
    parameter int unsigned LOOP_TAG_BITS = 10,
    parameter int unsigned LOOP_CONF_THRESH = 2,
    parameter bit USE_ITTAGE = 1'b0,
    parameter int unsigned ITTAGE_ENTRIES = 128,
    parameter int unsigned ITTAGE_TAG_BITS = 10,
    parameter int unsigned TAGE_OVERRIDE_MIN_PROVIDER = 0,
    parameter bit TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK = 1'b0,
    parameter int unsigned TAGE_TAG_BITS = 8,
    parameter int unsigned TAGE_HIST_LEN0 = 2,
    parameter int unsigned TAGE_HIST_LEN1 = 4,
    parameter int unsigned TAGE_HIST_LEN2 = 8,
    parameter int unsigned TAGE_HIST_LEN3 = 16,
    parameter int unsigned PATH_HIST_BITS = 16,
    parameter int unsigned TRACK_DEPTH = 16
) (
    input logic clk_i,
    input logic rst_i,

    input  ifu_to_bpu_t ifu_to_bpu_i,
    input  handshake_t  ifu_to_bpu_handshake_i,

    // Commit-time predictor update
    input logic                update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic                update_is_cond_i,
    input logic                update_taken_i,
    input logic [Cfg.PLEN-1:0] update_target_i,
    input logic                update_is_call_i,
    input logic                update_is_ret_i,
    input logic                update_is_rvc_i,
    input logic [Cfg.NRET-1:0] ras_update_valid_i,
    input logic [Cfg.NRET-1:0] ras_update_is_call_i,
    input logic [Cfg.NRET-1:0] ras_update_is_ret_i,
    input logic [Cfg.NRET-1:0] ras_update_is_rvc_i,
    input logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] ras_update_pc_i,
    input logic                flush_i,

    // from IFU
    output handshake_t  bpu_to_ifu_handshake_o,
    output bpu_to_ifu_t bpu_to_ifu_o
);

  localparam int unsigned SLOT_IDX_W = (Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1;
  localparam int unsigned BTB_IDX_W = (BTB_ENTRIES > 1) ? $clog2(BTB_ENTRIES) : 1;
  localparam int unsigned BHT_IDX_W = (BHT_ENTRIES > 1) ? $clog2(BHT_ENTRIES) : 1;
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  // RV32C instructions are 16-bit aligned. Predictor indexing/tagging must include pc[1].
  localparam int unsigned INSTR_ADDR_LSB = 1;
  localparam int unsigned BTB_TAG_W = Cfg.PLEN - BTB_IDX_W - INSTR_ADDR_LSB;
  localparam int unsigned RAS_CNT_W = (RAS_DEPTH > 0) ? $clog2(RAS_DEPTH + 1) : 1;
  localparam int unsigned GHR_W = (GHR_BITS > 0) ? GHR_BITS : 1;
  localparam int unsigned PATH_HIST_W = (PATH_HIST_BITS > 0) ? PATH_HIST_BITS : 1;
  localparam int unsigned TAGE_TRACK_DEPTH = (TRACK_DEPTH >= 2) ? TRACK_DEPTH : 2;
  localparam int unsigned TAGE_TRACK_PTR_W = (TAGE_TRACK_DEPTH > 1) ? $clog2(TAGE_TRACK_DEPTH) : 1;
  localparam int unsigned TAGE_TRACK_CNT_W = $clog2(TAGE_TRACK_DEPTH + 1);
  localparam logic [1:0] COND_PROVIDER_LEGACY = 2'd0;
  localparam logic [1:0] COND_PROVIDER_TAGE = 2'd1;
  localparam logic [1:0] COND_PROVIDER_SC = 2'd2;
  localparam logic [1:0] COND_PROVIDER_LOOP = 2'd3;
  logic [BTB_ENTRIES-1:0] btb_valid_q;
  logic [BTB_ENTRIES-1:0] btb_is_cond_q;
  logic [BTB_ENTRIES-1:0] btb_is_backward_q;
  logic [BTB_ENTRIES-1:0] btb_is_call_q;
  logic [BTB_ENTRIES-1:0] btb_is_ret_q;
  logic [BTB_ENTRIES-1:0] btb_use_ras_q;
  logic [BTB_ENTRIES-1:0] btb_is_rvc_q;
  logic [BTB_ENTRIES-1:0][BTB_TAG_W-1:0] btb_tag_q;
  logic [BTB_ENTRIES-1:0][Cfg.PLEN-1:0] btb_target_q;
  logic [BHT_ENTRIES-1:0][1:0] local_bht_q;
  logic [BHT_ENTRIES-1:0][1:0] global_bht_q;
  logic [BHT_ENTRIES-1:0][1:0] chooser_q;
  logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] arch_ras_stack_q;
  logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] spec_ras_stack_q;
  logic [RAS_CNT_W-1:0] arch_ras_count_q;
  logic [RAS_CNT_W-1:0] spec_ras_count_q;
  logic pred_event_valid_q;
  logic pred_event_is_call_q;
  logic pred_event_is_ret_q;
  logic pred_event_is_rvc_q;
  logic pred_event_is_cond_q;
  logic pred_event_taken_q;
  logic [Cfg.PLEN-1:0] pred_event_pc_q;
  logic [GHR_W-1:0] arch_ghr_q;
  logic [GHR_W-1:0] spec_ghr_q;
  logic [PATH_HIST_W-1:0] arch_path_hist_q;
  logic [PATH_HIST_W-1:0] spec_path_hist_q;
  logic [GHR_W-1:0] ghr_q;
  logic [PATH_HIST_W-1:0] ittage_predict_ctx_w;
  logic [63:0] dbg_cond_update_total_q;
  logic [63:0] dbg_cond_local_correct_q;
  logic [63:0] dbg_cond_global_correct_q;
  logic [63:0] dbg_cond_selected_correct_q;
  logic [63:0] dbg_cond_choose_local_q;
  logic [63:0] dbg_cond_choose_global_q;
  logic [63:0] dbg_tage_lookup_total_q;
  logic [63:0] dbg_tage_hit_total_q;
  logic [63:0] dbg_tage_override_total_q;
  logic [63:0] dbg_tage_override_correct_q;
  logic [63:0] dbg_sc_lookup_total_q;
  logic [63:0] dbg_sc_confident_total_q;
  logic [63:0] dbg_sc_override_total_q;
  logic [63:0] dbg_sc_override_correct_q;
  logic [63:0] dbg_loop_lookup_total_q;
  logic [63:0] dbg_loop_hit_total_q;
  logic [63:0] dbg_loop_confident_total_q;
  logic [63:0] dbg_loop_override_total_q;
  logic [63:0] dbg_loop_override_correct_q;
  logic [63:0] dbg_cond_provider_legacy_selected_q;
  logic [63:0] dbg_cond_provider_tage_selected_q;
  logic [63:0] dbg_cond_provider_sc_selected_q;
  logic [63:0] dbg_cond_provider_loop_selected_q;
  logic [63:0] dbg_cond_provider_legacy_correct_q;
  logic [63:0] dbg_cond_provider_tage_correct_q;
  logic [63:0] dbg_cond_provider_sc_correct_q;
  logic [63:0] dbg_cond_provider_loop_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_legacy_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_tage_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_sc_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_loop_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_any_correct_q;
  logic [TAGE_TRACK_DEPTH-1:0] tage_track_override_q;
  logic [TAGE_TRACK_DEPTH-1:0] tage_track_pred_taken_q;
  logic [TAGE_TRACK_PTR_W-1:0] tage_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] tage_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] tage_track_count_q;
  logic [TAGE_TRACK_DEPTH-1:0] sc_track_override_q;
  logic [TAGE_TRACK_DEPTH-1:0] sc_track_pred_taken_q;
  logic [TAGE_TRACK_PTR_W-1:0] sc_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] sc_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] sc_track_count_q;
  logic [TAGE_TRACK_DEPTH-1:0] loop_track_override_q;
  logic [TAGE_TRACK_DEPTH-1:0] loop_track_pred_taken_q;
  logic [TAGE_TRACK_PTR_W-1:0] loop_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] loop_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] loop_track_count_q;
  logic [TAGE_TRACK_DEPTH-1:0][1:0] cond_track_provider_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_selected_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_legacy_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_tage_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_sc_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_loop_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_tage_candidate_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_sc_candidate_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_loop_candidate_q;
  logic [TAGE_TRACK_PTR_W-1:0] cond_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] cond_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] cond_track_count_q;

  function automatic logic [BTB_IDX_W-1:0] btb_index(input logic [Cfg.PLEN-1:0] pc);
    logic [BTB_IDX_W-1:0] pc_idx;
    logic [BTB_IDX_W-1:0] fold_idx;
    begin
      pc_idx = pc[INSTR_ADDR_LSB +: BTB_IDX_W];
      fold_idx = '0;
      for (int i = INSTR_ADDR_LSB + BTB_IDX_W; i < Cfg.PLEN; i++) begin
        fold_idx[(i - (INSTR_ADDR_LSB + BTB_IDX_W)) % BTB_IDX_W] ^= pc[i];
      end
      btb_index = BTB_HASH_ENABLE ? (pc_idx ^ fold_idx) : pc_idx;
    end
  endfunction

  function automatic logic [BTB_TAG_W-1:0] btb_tag(input logic [Cfg.PLEN-1:0] pc);
    btb_tag = pc[Cfg.PLEN-1:INSTR_ADDR_LSB+BTB_IDX_W];
  endfunction

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

  function automatic logic [GHR_W-1:0] ghr_shift(input logic [GHR_W-1:0] hist,
                                                 input logic                 taken);
    begin
      ghr_shift = (hist << 1) | GHR_W'(taken);
    end
  endfunction

  function automatic logic [PATH_HIST_W-1:0] path_shift(input logic [PATH_HIST_W-1:0] hist,
                                                         input logic [Cfg.PLEN-1:0]      pc,
                                                         input logic                      taken);
    logic [PATH_HIST_W-1:0] pc_mix;
    begin
      pc_mix = '0;
      for (int i = 0; i < Cfg.PLEN; i++) begin
        pc_mix[i%PATH_HIST_W] ^= pc[i];
      end
      path_shift = {hist[PATH_HIST_W-2:0], taken} ^ pc_mix;
    end
  endfunction

  logic [Cfg.INSTR_PER_FETCH-1:0] predict_hit;
  logic [Cfg.INSTR_PER_FETCH-1:0] predict_taken;
  logic [Cfg.INSTR_PER_FETCH-1:0] predict_is_cond;
  logic [Cfg.INSTR_PER_FETCH-1:0] predict_is_call;
  logic [Cfg.INSTR_PER_FETCH-1:0] predict_is_ret;
  logic [Cfg.INSTR_PER_FETCH-1:0] predict_is_rvc;
  logic [Cfg.INSTR_PER_FETCH-1:0] predict_is_indirect;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] predict_pc;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] predict_target;
  logic [Cfg.INSTR_PER_FETCH-1:0] ittage_raw_hit_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] ittage_hit_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] ittage_target_w;
  logic [Cfg.PLEN-1:0] spec_ras_top_w;
  logic spec_ras_has_entry_w;
  logic [Cfg.PLEN-1:0] arch_ras_top_w;
  logic arch_ras_has_entry_w;
  logic [SLOT_IDX_W-1:0] pred_slot_idx_w;
  logic pred_slot_valid_w;
  logic pred_slot_is_call_w;
  logic pred_slot_is_ret_w;
  logic pred_slot_is_rvc_w;
  logic pred_slot_is_cond_w;
  logic pred_slot_taken_w;
  logic [Cfg.PLEN-1:0] pred_slot_pc_w;
  logic [Cfg.PLEN-1:0] pred_slot_target_w;
  logic [Cfg.PLEN-1:0] pred_npc_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] tage_hit_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] tage_taken_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] tage_strong_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][1:0] tage_provider_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] sc_taken_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] sc_confident_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] loop_hit_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] loop_taken_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] loop_confident_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] cond_taken_legacy_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] cond_tage_override_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] cond_sc_override_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] cond_loop_override_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] cond_tage_candidate_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] cond_sc_candidate_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] cond_loop_candidate_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][1:0] cond_selected_provider_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] cond_selected_taken_w;
`ifndef SYNTHESIS

`endif

  assign ghr_q = spec_ghr_q;
  always_comb begin
    ittage_predict_ctx_w = spec_path_hist_q;
    if (!flush_i && pred_event_valid_q && pred_event_is_cond_q) begin
      ittage_predict_ctx_w = path_shift(ittage_predict_ctx_w, pred_event_pc_q, pred_event_taken_q);
    end
  end

  tage #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(Cfg.INSTR_PER_FETCH),
      .GHR_BITS(GHR_BITS),
      .TABLE_ENTRIES(Cfg.BPU_BHT_ENTRIES),
      .TAG_BITS(TAGE_TAG_BITS),
      .HIST_LEN0(TAGE_HIST_LEN0),
      .HIST_LEN1(TAGE_HIST_LEN1),
      .HIST_LEN2(TAGE_HIST_LEN2),
      .HIST_LEN3(TAGE_HIST_LEN3)
  ) u_tage (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(ifu_to_bpu_i.pc),
      .predict_ghr_i(spec_ghr_q),
      .predict_hit_o(tage_hit_w),
      .predict_taken_o(tage_taken_w),
      .predict_strong_o(tage_strong_w),
      .predict_provider_o(tage_provider_w),
      .update_valid_i(update_valid_i && update_is_cond_i && USE_TAGE),
      .update_pc_i(update_pc_i),
      .update_ghr_i(arch_ghr_q),
      .update_taken_i(update_taken_i)
  );

  sc_l #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(Cfg.INSTR_PER_FETCH),
      .GHR_BITS(GHR_BITS),
      .ENTRIES(SC_L_ENTRIES),
      .CTR_BITS(4),
      .CONF_THRESH(SC_L_CONF_THRESH)
  ) u_sc_l (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(ifu_to_bpu_i.pc),
      .predict_ghr_i(spec_ghr_q),
      .predict_taken_o(sc_taken_w),
      .predict_confident_o(sc_confident_w),
      .update_valid_i(update_valid_i && update_is_cond_i && USE_SC_L),
      .update_pc_i(update_pc_i),
      .update_ghr_i(arch_ghr_q),
      .update_taken_i(update_taken_i)
  );

  loop_predictor #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(Cfg.INSTR_PER_FETCH),
      .ENTRIES(LOOP_ENTRIES),
      .TAG_BITS(LOOP_TAG_BITS),
      .CONF_THRESH(LOOP_CONF_THRESH)
  ) u_loop_predictor (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(ifu_to_bpu_i.pc),
      .predict_taken_o(loop_taken_w),
      .predict_confident_o(loop_confident_w),
      .predict_hit_o(loop_hit_w),
      .update_valid_i(update_valid_i && USE_LOOP),
      .update_pc_i(update_pc_i),
      .update_is_cond_i(update_is_cond_i),
      .update_taken_i(update_taken_i)
  );

  ittage #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(Cfg.INSTR_PER_FETCH),
      .ENTRIES(ITTAGE_ENTRIES),
      .TAG_BITS(ITTAGE_TAG_BITS),
      .PATH_HIST_BITS(PATH_HIST_W)
  ) u_ittage (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(ifu_to_bpu_i.pc),
      .predict_ctx_i(ittage_predict_ctx_w),
      .predict_hit_o(ittage_raw_hit_w),
      .predict_target_o(ittage_target_w),
      .update_valid_i(USE_ITTAGE && update_valid_i && !update_is_cond_i && update_taken_i &&
                      !update_is_call_i && !update_is_ret_i),
      .update_pc_i(update_pc_i),
      .update_ctx_i(ittage_predict_ctx_w),
      .update_target_i(update_target_i)
  );

  always_comb begin
    spec_ras_has_entry_w = (spec_ras_count_q != '0);
    spec_ras_top_w = '0;
    if (spec_ras_has_entry_w) begin
      spec_ras_top_w = spec_ras_stack_q[spec_ras_count_q-1];
    end
  end

  always_comb begin
    arch_ras_has_entry_w = (arch_ras_count_q != '0);
    arch_ras_top_w = '0;
    if (arch_ras_has_entry_w) begin
      arch_ras_top_w = arch_ras_stack_q[arch_ras_count_q-1];
    end
  end

  always_comb begin
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      logic [BTB_IDX_W-1:0] idx;
      logic [BHT_IDX_W-1:0] local_idx;
      logic [BHT_IDX_W-1:0] global_idx;
      logic [BHT_IDX_W-1:0] chooser_idx;
      logic [Cfg.PLEN-1:0] slot_pc;
      logic [1:0] local_ctr_pred;
      logic [1:0] global_ctr_pred;
      logic [1:0] selected_ctr_pred;
      logic local_taken_pred;
      logic global_taken_pred;
      logic cond_taken_pred;
      logic use_global_pred;
      logic local_legacy_strong;
      logic global_legacy_strong;
      logic local_global_disagree;
      logic selected_legacy_strong;
      logic tage_provider_ok;
      logic tage_allow_override;
      logic sc_allow_override;
      slot_pc = ifu_to_bpu_i.pc + Cfg.PLEN'(INSTR_BYTES * i);
      idx = btb_index(slot_pc);
      local_idx = bht_pc_index(slot_pc);
      global_idx = bht_global_index(slot_pc, spec_ghr_q);
      chooser_idx = local_idx;

      predict_pc[i] = slot_pc;
      predict_target[i] = btb_target_q[idx];
      predict_hit[i] = btb_valid_q[idx] && (btb_tag_q[idx] == btb_tag(slot_pc));
      predict_is_cond[i] = predict_hit[i] && btb_is_cond_q[idx];
      predict_is_call[i] = predict_hit[i] && btb_is_call_q[idx];
      predict_is_ret[i] = predict_hit[i] && btb_is_ret_q[idx];
      predict_is_rvc[i] = predict_hit[i] && btb_is_rvc_q[idx];
      predict_is_indirect[i] = predict_hit[i] && !btb_is_cond_q[idx] && !btb_is_call_q[idx] && !btb_is_ret_q[idx];
      ittage_hit_w[i] = USE_ITTAGE && predict_is_indirect[i] && ittage_raw_hit_w[i];

      local_ctr_pred = local_bht_q[local_idx];
      global_ctr_pred = global_bht_q[global_idx];
      local_taken_pred = local_ctr_pred[1] ||
                         ((local_ctr_pred == 2'b01) && btb_is_backward_q[idx]);
      global_taken_pred = global_ctr_pred[1] ||
                          ((global_ctr_pred == 2'b01) && btb_is_backward_q[idx]);
      use_global_pred = USE_GSHARE && (!USE_TOURNAMENT || chooser_q[chooser_idx][1]);
      selected_ctr_pred = use_global_pred ? global_ctr_pred : local_ctr_pred;
      local_legacy_strong = (local_ctr_pred == 2'b00) || (local_ctr_pred == 2'b11);
      global_legacy_strong = (global_ctr_pred == 2'b00) || (global_ctr_pred == 2'b11);
      local_global_disagree = (local_taken_pred != global_taken_pred);
      selected_legacy_strong = (selected_ctr_pred == 2'b00) || (selected_ctr_pred == 2'b11);
      cond_taken_pred = use_global_pred ? global_taken_pred : local_taken_pred;
      cond_taken_legacy_w[i] = cond_taken_pred;
      cond_tage_override_w[i] = 1'b0;
      cond_sc_override_w[i] = 1'b0;
      cond_loop_override_w[i] = 1'b0;
      cond_tage_candidate_w[i] = 1'b0;
      cond_sc_candidate_w[i] = 1'b0;
      cond_loop_candidate_w[i] = 1'b0;
      cond_selected_provider_w[i] = COND_PROVIDER_LEGACY;

      tage_provider_ok = (int'(tage_provider_w[i]) >= int'(TAGE_OVERRIDE_MIN_PROVIDER));
      tage_allow_override = USE_TAGE && tage_hit_w[i] && tage_strong_w[i] && tage_provider_ok;
      if (TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK && selected_legacy_strong) begin
        tage_allow_override = 1'b0;
      end
      cond_tage_candidate_w[i] = predict_is_cond[i] && tage_allow_override;

      if (tage_allow_override && (tage_taken_w[i] != cond_taken_legacy_w[i])) begin
        cond_tage_override_w[i] = 1'b1;
        cond_taken_pred = tage_taken_w[i];
        cond_selected_provider_w[i] = COND_PROVIDER_TAGE;
      end

      sc_allow_override = USE_SC_L && sc_confident_w[i];
      if (selected_legacy_strong) begin
        sc_allow_override = 1'b0;
      end
      if (SC_L_BLOCK_ON_TAGE_HIT && USE_TAGE && tage_hit_w[i]) begin
        sc_allow_override = 1'b0;
      end
      if (SC_L_REQUIRE_DISAGREE && !local_global_disagree) begin
        sc_allow_override = 1'b0;
      end
      if (SC_L_REQUIRE_BOTH_WEAK && (local_legacy_strong || global_legacy_strong)) begin
        sc_allow_override = 1'b0;
      end
      cond_sc_candidate_w[i] = predict_is_cond[i] && sc_allow_override;
      if (sc_allow_override && (sc_taken_w[i] != cond_taken_pred)) begin
        cond_sc_override_w[i] = 1'b1;
        cond_taken_pred = sc_taken_w[i];
        cond_selected_provider_w[i] = COND_PROVIDER_SC;
      end
      cond_loop_candidate_w[i] = USE_LOOP && predict_is_cond[i] && loop_confident_w[i];
      if (USE_LOOP && predict_is_cond[i] && loop_confident_w[i] &&
          (loop_taken_w[i] != cond_taken_pred)) begin
        cond_loop_override_w[i] = 1'b1;
        cond_taken_pred = loop_taken_w[i];
        cond_selected_provider_w[i] = COND_PROVIDER_LOOP;
      end
      cond_selected_taken_w[i] = cond_taken_pred;

      predict_taken[i] = 1'b0;
      if (predict_hit[i]) begin
        if (btb_is_ret_q[idx]) begin
          predict_taken[i] = 1'b1;
          if (spec_ras_has_entry_w) begin
            predict_target[i] = spec_ras_top_w;
          end
        end else if (!btb_is_cond_q[idx]) begin
          predict_taken[i] = 1'b1;
          if (predict_is_indirect[i] && ittage_hit_w[i]) begin
            predict_target[i] = ittage_target_w[i];
          end
        end else begin
          predict_taken[i] = cond_taken_pred;
        end
      end
    end
  end

  always_comb begin
    pred_slot_valid_w = 1'b0;
    pred_slot_idx_w = '0;
    pred_slot_is_call_w = 1'b0;
    pred_slot_is_ret_w = 1'b0;
    pred_slot_is_rvc_w = 1'b0;
    pred_slot_is_cond_w = 1'b0;
    pred_slot_taken_w = 1'b0;
    pred_slot_pc_w = '0;
    pred_slot_target_w = '0;
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      if (!pred_slot_valid_w && predict_taken[i]) begin
        pred_slot_valid_w = 1'b1;
        pred_slot_idx_w = SLOT_IDX_W'(i);
        pred_slot_is_call_w = predict_is_call[i];
        pred_slot_is_ret_w = predict_is_ret[i];
        pred_slot_is_rvc_w = predict_is_rvc[i];
        pred_slot_is_cond_w = predict_is_cond[i];
        pred_slot_taken_w = predict_taken[i];
        pred_slot_pc_w = predict_pc[i];
        pred_slot_target_w = predict_target[i];
      end
    end
  end

  assign pred_npc_w = pred_slot_valid_w ? pred_slot_target_w : (ifu_to_bpu_i.pc + Cfg.FETCH_WIDTH);

  assign bpu_to_ifu_o.pred_slot_valid = pred_slot_valid_w;
  assign bpu_to_ifu_o.pred_slot_idx = pred_slot_idx_w;
  assign bpu_to_ifu_o.pred_slot_target = pred_slot_target_w;
  assign bpu_to_ifu_o.npc = pred_npc_w;
  assign bpu_to_ifu_handshake_o.ready = 1'b1;
  assign bpu_to_ifu_handshake_o.valid = 1'b1;

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      btb_valid_q   <= '0;
      btb_is_cond_q <= '0;
      btb_is_backward_q <= '0;
      btb_is_call_q <= '0;
      btb_is_ret_q  <= '0;
      btb_use_ras_q <= '0;
      btb_is_rvc_q <= '0;
      btb_tag_q     <= '0;
      btb_target_q  <= '0;
      arch_ras_stack_q   <= '0;
      spec_ras_stack_q   <= '0;
      arch_ras_count_q   <= '0;
      spec_ras_count_q   <= '0;
      pred_event_valid_q <= 1'b0;
      pred_event_is_call_q <= 1'b0;
      pred_event_is_ret_q <= 1'b0;
      pred_event_is_rvc_q <= 1'b0;
      pred_event_is_cond_q <= 1'b0;
      pred_event_taken_q <= 1'b0;
      pred_event_pc_q <= '0;
      arch_ghr_q <= '0;
      spec_ghr_q <= '0;
      arch_path_hist_q <= '0;
      spec_path_hist_q <= '0;
      dbg_cond_update_total_q <= '0;
      dbg_cond_local_correct_q <= '0;
      dbg_cond_global_correct_q <= '0;
      dbg_cond_selected_correct_q <= '0;
      dbg_cond_choose_local_q <= '0;
      dbg_cond_choose_global_q <= '0;
      dbg_tage_lookup_total_q <= '0;
      dbg_tage_hit_total_q <= '0;
      dbg_tage_override_total_q <= '0;
      dbg_tage_override_correct_q <= '0;
      dbg_sc_lookup_total_q <= '0;
      dbg_sc_confident_total_q <= '0;
      dbg_sc_override_total_q <= '0;
      dbg_sc_override_correct_q <= '0;
      dbg_loop_lookup_total_q <= '0;
      dbg_loop_hit_total_q <= '0;
      dbg_loop_confident_total_q <= '0;
      dbg_loop_override_total_q <= '0;
      dbg_loop_override_correct_q <= '0;
      dbg_cond_provider_legacy_selected_q <= '0;
      dbg_cond_provider_tage_selected_q <= '0;
      dbg_cond_provider_sc_selected_q <= '0;
      dbg_cond_provider_loop_selected_q <= '0;
      dbg_cond_provider_legacy_correct_q <= '0;
      dbg_cond_provider_tage_correct_q <= '0;
      dbg_cond_provider_sc_correct_q <= '0;
      dbg_cond_provider_loop_correct_q <= '0;
      dbg_cond_selected_wrong_alt_legacy_correct_q <= '0;
      dbg_cond_selected_wrong_alt_tage_correct_q <= '0;
      dbg_cond_selected_wrong_alt_sc_correct_q <= '0;
      dbg_cond_selected_wrong_alt_loop_correct_q <= '0;
      dbg_cond_selected_wrong_alt_any_correct_q <= '0;
      tage_track_override_q <= '0;
      tage_track_pred_taken_q <= '0;
      tage_track_head_q <= '0;
      tage_track_tail_q <= '0;
      tage_track_count_q <= '0;
      sc_track_override_q <= '0;
      sc_track_pred_taken_q <= '0;
      sc_track_head_q <= '0;
      sc_track_tail_q <= '0;
      sc_track_count_q <= '0;
      loop_track_override_q <= '0;
      loop_track_pred_taken_q <= '0;
      loop_track_head_q <= '0;
      loop_track_tail_q <= '0;
      loop_track_count_q <= '0;
      cond_track_provider_q <= '0;
      cond_track_selected_taken_q <= '0;
      cond_track_legacy_taken_q <= '0;
      cond_track_tage_taken_q <= '0;
      cond_track_sc_taken_q <= '0;
      cond_track_loop_taken_q <= '0;
      cond_track_tage_candidate_q <= '0;
      cond_track_sc_candidate_q <= '0;
      cond_track_loop_candidate_q <= '0;
      cond_track_head_q <= '0;
      cond_track_tail_q <= '0;
      cond_track_count_q <= '0;
`ifndef SYNTHESIS
`endif
      for (int i = 0; i < BHT_ENTRIES; i++) begin
        local_bht_q[i] <= 2'b01;
        global_bht_q[i] <= 2'b01;
        chooser_q[i] <= 2'b01;
      end
    end else begin
      logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] arch_stack_n;
      logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] spec_stack_n;
      logic [RAS_CNT_W-1:0] arch_count_n;
      logic [RAS_CNT_W-1:0] spec_count_n;
      logic [BTB_IDX_W-1:0] up_btb_idx;
      logic [BHT_IDX_W-1:0] up_local_idx;
      logic [BHT_IDX_W-1:0] up_global_idx;
      logic [BHT_IDX_W-1:0] up_chooser_idx;
      logic do_btb_write;
      logic pred_fire_w;
      logic local_pred_before;
      logic global_pred_before;
      logic selected_pred_before;
      logic choose_global_before;
      logic local_correct;
      logic global_correct;
      logic selected_correct;
      logic [TAGE_TRACK_PTR_W-1:0] tage_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] tage_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] tage_count_n;
      logic [TAGE_TRACK_DEPTH-1:0] tage_override_n;
      logic [TAGE_TRACK_DEPTH-1:0] tage_pred_taken_n;
      logic [TAGE_TRACK_PTR_W-1:0] sc_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] sc_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] sc_count_n;
      logic [TAGE_TRACK_DEPTH-1:0] sc_override_n;
      logic [TAGE_TRACK_DEPTH-1:0] sc_pred_taken_n;
      logic [TAGE_TRACK_PTR_W-1:0] loop_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] loop_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] loop_count_n;
      logic [TAGE_TRACK_DEPTH-1:0] loop_override_n;
      logic [TAGE_TRACK_DEPTH-1:0] loop_pred_taken_n;
      logic tage_pop_override;
      logic tage_pop_pred_taken;
      logic tage_push_override;
      logic sc_pop_override;
      logic sc_pop_pred_taken;
      logic sc_push_override;
      logic loop_pop_override;
      logic loop_pop_pred_taken;
      logic loop_push_override;
      logic [TAGE_TRACK_PTR_W-1:0] cond_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] cond_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] cond_count_n;
      logic [TAGE_TRACK_DEPTH-1:0][1:0] cond_provider_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_selected_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_legacy_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_tage_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_sc_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_loop_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_tage_candidate_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_sc_candidate_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_loop_candidate_n;
      logic [1:0] cond_pop_provider;
      logic cond_pop_selected_taken;
      logic cond_pop_legacy_taken;
      logic cond_pop_tage_taken;
      logic cond_pop_sc_taken;
      logic cond_pop_loop_taken;
      logic cond_pop_tage_candidate;
      logic cond_pop_sc_candidate;
      logic cond_pop_loop_candidate;
      logic cond_selected_pred_correct;
      logic cond_alt_any_correct;
      logic [GHR_W-1:0] arch_ghr_n;
      logic [GHR_W-1:0] spec_ghr_n;
      logic [PATH_HIST_W-1:0] arch_path_hist_n;
      logic [PATH_HIST_W-1:0] spec_path_hist_n;

      arch_stack_n = arch_ras_stack_q;
      spec_stack_n = spec_ras_stack_q;
      arch_count_n = arch_ras_count_q;
      spec_count_n = spec_ras_count_q;
      arch_ghr_n = arch_ghr_q;
      spec_ghr_n = spec_ghr_q;
      arch_path_hist_n = arch_path_hist_q;
      spec_path_hist_n = spec_path_hist_q;
      tage_head_n = tage_track_head_q;
      tage_tail_n = tage_track_tail_q;
      tage_count_n = tage_track_count_q;
      tage_override_n = tage_track_override_q;
      tage_pred_taken_n = tage_track_pred_taken_q;
      sc_head_n = sc_track_head_q;
      sc_tail_n = sc_track_tail_q;
      sc_count_n = sc_track_count_q;
      sc_override_n = sc_track_override_q;
      sc_pred_taken_n = sc_track_pred_taken_q;
      loop_head_n = loop_track_head_q;
      loop_tail_n = loop_track_tail_q;
      loop_count_n = loop_track_count_q;
      loop_override_n = loop_track_override_q;
      loop_pred_taken_n = loop_track_pred_taken_q;
      cond_head_n = cond_track_head_q;
      cond_tail_n = cond_track_tail_q;
      cond_count_n = cond_track_count_q;
      cond_provider_n = cond_track_provider_q;
      cond_selected_taken_n = cond_track_selected_taken_q;
      cond_legacy_taken_n = cond_track_legacy_taken_q;
      cond_tage_taken_n = cond_track_tage_taken_q;
      cond_sc_taken_n = cond_track_sc_taken_q;
      cond_loop_taken_n = cond_track_loop_taken_q;
      cond_tage_candidate_n = cond_track_tage_candidate_q;
      cond_sc_candidate_n = cond_track_sc_candidate_q;
      cond_loop_candidate_n = cond_track_loop_candidate_q;
      tage_pop_override = 1'b0;
      tage_pop_pred_taken = 1'b0;
      tage_push_override = 1'b0;
      sc_pop_override = 1'b0;
      sc_pop_pred_taken = 1'b0;
      sc_push_override = 1'b0;
      loop_pop_override = 1'b0;
      loop_pop_pred_taken = 1'b0;
      loop_push_override = 1'b0;
      cond_pop_provider = COND_PROVIDER_LEGACY;
      cond_pop_selected_taken = 1'b0;
      cond_pop_legacy_taken = 1'b0;
      cond_pop_tage_taken = 1'b0;
      cond_pop_sc_taken = 1'b0;
      cond_pop_loop_taken = 1'b0;
      cond_pop_tage_candidate = 1'b0;
      cond_pop_sc_candidate = 1'b0;
      cond_pop_loop_candidate = 1'b0;
      cond_selected_pred_correct = 1'b0;
      cond_alt_any_correct = 1'b0;

      if (update_valid_i) begin
        up_btb_idx = btb_index(update_pc_i);
        up_local_idx = bht_pc_index(update_pc_i);
        up_global_idx = bht_global_index(update_pc_i, arch_ghr_q);
        up_chooser_idx = up_local_idx;
        do_btb_write = (!update_is_cond_i) || update_taken_i;

        if (do_btb_write) begin
          btb_valid_q[up_btb_idx] <= 1'b1;
          btb_is_cond_q[up_btb_idx] <= update_is_cond_i;
          btb_is_backward_q[up_btb_idx] <= update_is_cond_i && (update_target_i < update_pc_i);
          btb_is_call_q[up_btb_idx] <= update_is_call_i;
          btb_is_ret_q[up_btb_idx] <= update_is_ret_i;
          btb_is_rvc_q[up_btb_idx] <= update_is_rvc_i;
          if (update_is_ret_i) begin
            btb_use_ras_q[up_btb_idx] <= !arch_ras_has_entry_w || (arch_ras_top_w == update_target_i);
          end else begin
            btb_use_ras_q[up_btb_idx] <= 1'b0;
          end
          btb_tag_q[up_btb_idx] <= btb_tag(update_pc_i);
          btb_target_q[up_btb_idx] <= update_target_i;
        end

        if (update_is_cond_i) begin
          local_pred_before = local_bht_q[up_local_idx][1] ||
                              ((local_bht_q[up_local_idx] == 2'b01) &&
                               btb_is_backward_q[up_btb_idx]);
          global_pred_before = global_bht_q[up_global_idx][1] ||
                               ((global_bht_q[up_global_idx] == 2'b01) &&
                                btb_is_backward_q[up_btb_idx]);
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

          arch_ghr_n = ghr_shift(arch_ghr_n, update_taken_i);
          arch_path_hist_n = path_shift(arch_path_hist_n, update_pc_i, update_taken_i);
        end

        if (USE_TAGE && update_is_cond_i && (tage_count_n != '0)) begin
          tage_pop_override = tage_override_n[tage_head_n];
          tage_pop_pred_taken = tage_pred_taken_n[tage_head_n];
          tage_head_n = tage_head_n + TAGE_TRACK_PTR_W'(1);
          tage_count_n = tage_count_n - TAGE_TRACK_CNT_W'(1);
          if (tage_pop_override && (tage_pop_pred_taken == update_taken_i)) begin
            dbg_tage_override_correct_q <= dbg_tage_override_correct_q + 64'd1;
          end
        end
        if (USE_SC_L && update_is_cond_i && (sc_count_n != '0)) begin
          sc_pop_override = sc_override_n[sc_head_n];
          sc_pop_pred_taken = sc_pred_taken_n[sc_head_n];
          sc_head_n = sc_head_n + TAGE_TRACK_PTR_W'(1);
          sc_count_n = sc_count_n - TAGE_TRACK_CNT_W'(1);
          if (sc_pop_override && (sc_pop_pred_taken == update_taken_i)) begin
            dbg_sc_override_correct_q <= dbg_sc_override_correct_q + 64'd1;
          end
        end
        if (USE_LOOP && update_is_cond_i && (loop_count_n != '0)) begin
          loop_pop_override = loop_override_n[loop_head_n];
          loop_pop_pred_taken = loop_pred_taken_n[loop_head_n];
          loop_head_n = loop_head_n + TAGE_TRACK_PTR_W'(1);
          loop_count_n = loop_count_n - TAGE_TRACK_CNT_W'(1);
          if (loop_pop_override && (loop_pop_pred_taken == update_taken_i)) begin
            dbg_loop_override_correct_q <= dbg_loop_override_correct_q + 64'd1;
          end
        end
        if (update_is_cond_i && (cond_count_n != '0)) begin
          cond_pop_provider = cond_provider_n[cond_head_n];
          cond_pop_selected_taken = cond_selected_taken_n[cond_head_n];
          cond_pop_legacy_taken = cond_legacy_taken_n[cond_head_n];
          cond_pop_tage_taken = cond_tage_taken_n[cond_head_n];
          cond_pop_sc_taken = cond_sc_taken_n[cond_head_n];
          cond_pop_loop_taken = cond_loop_taken_n[cond_head_n];
          cond_pop_tage_candidate = cond_tage_candidate_n[cond_head_n];
          cond_pop_sc_candidate = cond_sc_candidate_n[cond_head_n];
          cond_pop_loop_candidate = cond_loop_candidate_n[cond_head_n];
          cond_head_n = cond_head_n + TAGE_TRACK_PTR_W'(1);
          cond_count_n = cond_count_n - TAGE_TRACK_CNT_W'(1);

          cond_selected_pred_correct = (cond_pop_selected_taken == update_taken_i);
          case (cond_pop_provider)
            COND_PROVIDER_TAGE: begin
              dbg_cond_provider_tage_selected_q <= dbg_cond_provider_tage_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_tage_correct_q <= dbg_cond_provider_tage_correct_q + 64'd1;
              end
            end
            COND_PROVIDER_SC: begin
              dbg_cond_provider_sc_selected_q <= dbg_cond_provider_sc_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_sc_correct_q <= dbg_cond_provider_sc_correct_q + 64'd1;
              end
            end
            COND_PROVIDER_LOOP: begin
              dbg_cond_provider_loop_selected_q <= dbg_cond_provider_loop_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_loop_correct_q <= dbg_cond_provider_loop_correct_q + 64'd1;
              end
            end
            default: begin
              dbg_cond_provider_legacy_selected_q <= dbg_cond_provider_legacy_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_legacy_correct_q <= dbg_cond_provider_legacy_correct_q + 64'd1;
              end
            end
          endcase

          if (!cond_selected_pred_correct) begin
            cond_alt_any_correct = 1'b0;
            if ((cond_pop_provider != COND_PROVIDER_LEGACY) &&
                (cond_pop_legacy_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_legacy_correct_q <=
                  dbg_cond_selected_wrong_alt_legacy_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_TAGE) &&
                cond_pop_tage_candidate &&
                (cond_pop_tage_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_tage_correct_q <=
                  dbg_cond_selected_wrong_alt_tage_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_SC) &&
                cond_pop_sc_candidate &&
                (cond_pop_sc_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_sc_correct_q <=
                  dbg_cond_selected_wrong_alt_sc_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_LOOP) &&
                cond_pop_loop_candidate &&
                (cond_pop_loop_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_loop_correct_q <=
                  dbg_cond_selected_wrong_alt_loop_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if (cond_alt_any_correct) begin
              dbg_cond_selected_wrong_alt_any_correct_q <=
                  dbg_cond_selected_wrong_alt_any_correct_q + 64'd1;
            end
          end
        end
      end

      for (int i = 0; i < Cfg.NRET; i++) begin
        if (ras_update_valid_i[i]) begin
          if (ras_update_is_call_i[i]) begin
            logic [Cfg.PLEN-1:0] call_ret_addr;
            call_ret_addr = ras_update_pc_i[i] +
                            (ras_update_is_rvc_i[i] ? Cfg.PLEN'(2) : Cfg.PLEN'(INSTR_BYTES));
            if (arch_count_n < RAS_DEPTH) begin
              arch_stack_n[arch_count_n] = call_ret_addr;
              arch_count_n = arch_count_n + 1'b1;
            end else begin
              for (int j = 0; j < RAS_DEPTH - 1; j++) begin
                arch_stack_n[j] = arch_stack_n[j+1];
              end
              arch_stack_n[RAS_DEPTH-1] = call_ret_addr;
              arch_count_n = RAS_DEPTH[RAS_CNT_W-1:0];
            end
          end else if (ras_update_is_ret_i[i]) begin
            if (arch_count_n != '0) begin
              arch_count_n = arch_count_n - 1'b1;
            end
          end
        end
      end

      if (flush_i) begin
        spec_stack_n = arch_stack_n;
        spec_count_n = arch_count_n;
        spec_path_hist_n = arch_path_hist_n;
      end else if (pred_event_valid_q && pred_event_is_call_q) begin
        logic [Cfg.PLEN-1:0] spec_ret_addr;
        spec_ret_addr = pred_event_pc_q +
                        (pred_event_is_rvc_q ? Cfg.PLEN'(2) : Cfg.PLEN'(INSTR_BYTES));
        if (spec_count_n < RAS_DEPTH) begin
          spec_stack_n[spec_count_n] = spec_ret_addr;
          spec_count_n = spec_count_n + 1'b1;
        end else begin
          for (int i = 0; i < RAS_DEPTH - 1; i++) begin
            spec_stack_n[i] = spec_stack_n[i+1];
          end
          spec_stack_n[RAS_DEPTH-1] = spec_ret_addr;
          spec_count_n = RAS_DEPTH[RAS_CNT_W-1:0];
        end
      end else if (pred_event_valid_q && pred_event_is_ret_q) begin
        if (spec_count_n != '0) begin
          spec_count_n = spec_count_n - 1'b1;
        end
      end

      if (flush_i) begin
        spec_ghr_n = arch_ghr_n;
        tage_head_n = '0;
        tage_tail_n = '0;
        tage_count_n = '0;
        tage_override_n = '0;
        tage_pred_taken_n = '0;
        sc_head_n = '0;
        sc_tail_n = '0;
        sc_count_n = '0;
        sc_override_n = '0;
        sc_pred_taken_n = '0;
        loop_head_n = '0;
        loop_tail_n = '0;
        loop_count_n = '0;
        loop_override_n = '0;
        loop_pred_taken_n = '0;
        cond_head_n = '0;
        cond_tail_n = '0;
        cond_count_n = '0;
        cond_provider_n = '0;
        cond_selected_taken_n = '0;
        cond_legacy_taken_n = '0;
        cond_tage_taken_n = '0;
        cond_sc_taken_n = '0;
        cond_loop_taken_n = '0;
        cond_tage_candidate_n = '0;
        cond_sc_candidate_n = '0;
        cond_loop_candidate_n = '0;
      end else if (pred_event_valid_q && pred_event_is_cond_q) begin
        spec_ghr_n = ghr_shift(spec_ghr_n, pred_event_taken_q);
        spec_path_hist_n = path_shift(spec_path_hist_n, pred_event_pc_q, pred_event_taken_q);
      end
      arch_ras_stack_q <= arch_stack_n;
      arch_ras_count_q <= arch_count_n;
      spec_ras_stack_q <= spec_stack_n;
      spec_ras_count_q <= spec_count_n;
      arch_ghr_q <= arch_ghr_n;
      spec_ghr_q <= spec_ghr_n;
      arch_path_hist_q <= arch_path_hist_n;
      spec_path_hist_q <= spec_path_hist_n;

      if (flush_i) begin
        pred_event_valid_q <= 1'b0;
        pred_event_is_call_q <= 1'b0;
        pred_event_is_ret_q <= 1'b0;
        pred_event_is_rvc_q <= 1'b0;
        pred_event_is_cond_q <= 1'b0;
        pred_event_taken_q <= 1'b0;
        pred_event_pc_q <= '0;
      end else begin
        // IFU consumes prediction when ready pulses (valid may be low in WAIT states).
        pred_fire_w = ifu_to_bpu_handshake_i.ready && pred_slot_valid_w;
        if (USE_TAGE && pred_fire_w && pred_slot_is_cond_w) begin
          dbg_tage_lookup_total_q <= dbg_tage_lookup_total_q + 64'd1;
          if (tage_hit_w[pred_slot_idx_w]) begin
            dbg_tage_hit_total_q <= dbg_tage_hit_total_q + 64'd1;
          end
          tage_push_override = cond_tage_override_w[pred_slot_idx_w];
          if (tage_push_override) begin
            dbg_tage_override_total_q <= dbg_tage_override_total_q + 64'd1;
          end
          if (tage_count_n < TAGE_TRACK_DEPTH) begin
            tage_override_n[tage_tail_n] = tage_push_override;
            tage_pred_taken_n[tage_tail_n] = pred_slot_taken_w;
            tage_tail_n = tage_tail_n + TAGE_TRACK_PTR_W'(1);
            tage_count_n = tage_count_n + TAGE_TRACK_CNT_W'(1);
          end
        end
        if (USE_SC_L && pred_fire_w && pred_slot_is_cond_w) begin
          dbg_sc_lookup_total_q <= dbg_sc_lookup_total_q + 64'd1;
          if (sc_confident_w[pred_slot_idx_w]) begin
            dbg_sc_confident_total_q <= dbg_sc_confident_total_q + 64'd1;
          end
          sc_push_override = cond_sc_override_w[pred_slot_idx_w];
          if (sc_push_override) begin
            dbg_sc_override_total_q <= dbg_sc_override_total_q + 64'd1;
          end
          if (sc_count_n < TAGE_TRACK_DEPTH) begin
            sc_override_n[sc_tail_n] = sc_push_override;
            sc_pred_taken_n[sc_tail_n] = pred_slot_taken_w;
            sc_tail_n = sc_tail_n + TAGE_TRACK_PTR_W'(1);
            sc_count_n = sc_count_n + TAGE_TRACK_CNT_W'(1);
          end
        end
        if (USE_LOOP && pred_fire_w && pred_slot_is_cond_w) begin
          dbg_loop_lookup_total_q <= dbg_loop_lookup_total_q + 64'd1;
          if (loop_hit_w[pred_slot_idx_w]) begin
            dbg_loop_hit_total_q <= dbg_loop_hit_total_q + 64'd1;
          end
          if (loop_confident_w[pred_slot_idx_w]) begin
            dbg_loop_confident_total_q <= dbg_loop_confident_total_q + 64'd1;
          end
          loop_push_override = cond_loop_override_w[pred_slot_idx_w];
          if (loop_push_override) begin
            dbg_loop_override_total_q <= dbg_loop_override_total_q + 64'd1;
          end
          if (loop_count_n < TAGE_TRACK_DEPTH) begin
            loop_override_n[loop_tail_n] = loop_push_override;
            loop_pred_taken_n[loop_tail_n] = pred_slot_taken_w;
            loop_tail_n = loop_tail_n + TAGE_TRACK_PTR_W'(1);
            loop_count_n = loop_count_n + TAGE_TRACK_CNT_W'(1);
          end
        end
        if (pred_fire_w && pred_slot_is_cond_w && (cond_count_n < TAGE_TRACK_DEPTH)) begin
          cond_provider_n[cond_tail_n] = cond_selected_provider_w[pred_slot_idx_w];
          cond_selected_taken_n[cond_tail_n] = cond_selected_taken_w[pred_slot_idx_w];
          cond_legacy_taken_n[cond_tail_n] = cond_taken_legacy_w[pred_slot_idx_w];
          cond_tage_taken_n[cond_tail_n] = tage_taken_w[pred_slot_idx_w];
          cond_sc_taken_n[cond_tail_n] = sc_taken_w[pred_slot_idx_w];
          cond_loop_taken_n[cond_tail_n] = loop_taken_w[pred_slot_idx_w];
          cond_tage_candidate_n[cond_tail_n] = cond_tage_candidate_w[pred_slot_idx_w];
          cond_sc_candidate_n[cond_tail_n] = cond_sc_candidate_w[pred_slot_idx_w];
          cond_loop_candidate_n[cond_tail_n] = cond_loop_candidate_w[pred_slot_idx_w];
          cond_tail_n = cond_tail_n + TAGE_TRACK_PTR_W'(1);
          cond_count_n = cond_count_n + TAGE_TRACK_CNT_W'(1);
        end
        pred_event_valid_q <= pred_fire_w;
        pred_event_is_call_q <= pred_fire_w && pred_slot_is_call_w;
        pred_event_is_ret_q <= pred_fire_w && pred_slot_is_ret_w;
        pred_event_is_rvc_q <= pred_fire_w && pred_slot_is_rvc_w;
        pred_event_is_cond_q <= pred_fire_w && pred_slot_is_cond_w;
        pred_event_taken_q <= pred_fire_w && pred_slot_taken_w;
        pred_event_pc_q <= pred_slot_pc_w;
      end
`ifndef SYNTHESIS

`endif
      tage_track_head_q <= tage_head_n;
      tage_track_tail_q <= tage_tail_n;
      tage_track_count_q <= tage_count_n;
      tage_track_override_q <= tage_override_n;
      tage_track_pred_taken_q <= tage_pred_taken_n;
      sc_track_head_q <= sc_head_n;
      sc_track_tail_q <= sc_tail_n;
      sc_track_count_q <= sc_count_n;
      sc_track_override_q <= sc_override_n;
      sc_track_pred_taken_q <= sc_pred_taken_n;
      loop_track_head_q <= loop_head_n;
      loop_track_tail_q <= loop_tail_n;
      loop_track_count_q <= loop_count_n;
      loop_track_override_q <= loop_override_n;
      loop_track_pred_taken_q <= loop_pred_taken_n;
      cond_track_head_q <= cond_head_n;
      cond_track_tail_q <= cond_tail_n;
      cond_track_count_q <= cond_count_n;
      cond_track_provider_q <= cond_provider_n;
      cond_track_selected_taken_q <= cond_selected_taken_n;
      cond_track_legacy_taken_q <= cond_legacy_taken_n;
      cond_track_tage_taken_q <= cond_tage_taken_n;
      cond_track_sc_taken_q <= cond_sc_taken_n;
      cond_track_loop_taken_q <= cond_loop_taken_n;
      cond_track_tage_candidate_q <= cond_tage_candidate_n;
      cond_track_sc_candidate_q <= cond_sc_candidate_n;
      cond_track_loop_candidate_q <= cond_loop_candidate_n;
    end
  end
endmodule : bpu
