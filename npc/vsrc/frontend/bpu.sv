import global_config_pkg::*;
import bpu_pkg::*;
module bpu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned BTB_ENTRIES = 64,
    parameter int unsigned BHT_ENTRIES = 128,
    parameter int unsigned RAS_DEPTH = 16,
    parameter bit BTB_HASH_ENABLE = 1'b1,
    parameter bit BHT_HASH_ENABLE = 1'b1,
    parameter bit USE_TAGE = 1'b0,
    parameter bit USE_SC = 1'b0,
    parameter int unsigned GHR_BITS = 8,
    parameter int unsigned SC_ENTRIES = 512,
    parameter int unsigned SC_CONF_THRESH = 3,
    parameter bit SC_REQUIRE_BOTH_WEAK = 1'b1,
    parameter bit SC_BLOCK_ON_TAGE_HIT = 1'b1,
    parameter bit USE_LOOP = 1'b0,
    parameter int unsigned LOOP_ENTRIES = 64,
    parameter int unsigned LOOP_TAG_BITS = 10,
    parameter int unsigned LOOP_CONF_THRESH = 2,
    parameter bit USE_ITTAGE = 1'b0,
    parameter int unsigned ITTAGE_ENTRIES = 128,
    parameter int unsigned ITTAGE_TAG_BITS = 10,
    parameter int unsigned TAGE_OVERRIDE_MIN_PROVIDER = 0,
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

    // Commit-time predictor update
  
    input logic                update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic                update_is_cond_i,
    input logic                update_taken_i,
    input logic [Cfg.PLEN-1:0] update_target_i,
    input logic                update_is_call_i,
    input logic                update_is_ret_i,
    input logic                update_is_rvc_i,
    input logic [global_config_pkg::FTQ_ID_W-1:0] update_ftq_id_i,
    input logic [FETCH_EPOCH_W-1:0] update_fetch_epoch_i,
    input logic [GHR_W-1:0] update_ghr_i,
    input logic [Cfg.NRET-1:0] ras_update_valid_i,
    input logic [Cfg.NRET-1:0] ras_update_is_call_i,
    input logic [Cfg.NRET-1:0] ras_update_is_ret_i,
    input logic [Cfg.NRET-1:0] ras_update_is_rvc_i,
    input logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] ras_update_pc_i,
    input logic                flush_i,
    input logic                redirect_valid_i,
    input logic [Cfg.PLEN-1:0] redirect_pc_i,

    // FTQ enqueue side
    output logic                    ftq_enq_valid_o,
    input  logic                    ftq_enq_ready_i,
    input  logic [global_config_pkg::FTQ_ID_W-1:0] ftq_enq_id_i,
    input  logic [FETCH_EPOCH_W-1:0] ftq_enq_epoch_i,
    output logic [Cfg.PLEN-1:0]     ftq_enq_pc_o,
    output logic                    ftq_enq_pred_slot_valid_o,
    output logic [SLOT_IDX_W-1:0]   ftq_enq_pred_slot_idx_o,
    output logic [Cfg.PLEN-1:0]     ftq_enq_pred_target_o,
    output logic [Cfg.PLEN-1:0]     ftq_enq_pred_npc_o,
    output logic [GHR_W-1:0]        ftq_enq_pred_ghr_o
);

  // FTB：pred_slot_idx 升级为 fetch block 内的半字 index（0~PRED_SLOT_COUNT-1）。
  localparam int unsigned SLOT_IDX_W = global_config_pkg::PRED_SLOT_IDX_W;
  localparam int unsigned PRED_SLOT_COUNT = global_config_pkg::PRED_SLOT_COUNT;
  // fetch block 16B 对齐掩码：block_base = pc & ~(FETCH_WIDTH-1)。
  localparam logic [Cfg.PLEN-1:0] BLOCK_ALIGN_MASK = ~(Cfg.PLEN'(Cfg.FETCH_WIDTH - 1));
  localparam int unsigned BTB_IDX_W = (BTB_ENTRIES > 1) ? $clog2(BTB_ENTRIES) : 1;
  // FTB/BTB entries are keyed by fetch-block base, not individual halfword PCs.
  localparam int unsigned BLOCK_ADDR_LSB = $clog2(Cfg.FETCH_WIDTH);
  localparam int unsigned BTB_TAG_W = Cfg.PLEN - BTB_IDX_W - BLOCK_ADDR_LSB;
  localparam int unsigned GHR_W = (GHR_BITS > 0) ? GHR_BITS : 1;
  localparam int unsigned PATH_HIST_W = (PATH_HIST_BITS > 0) ? PATH_HIST_BITS : 1;
  localparam logic [1:0] COND_PROVIDER_LEGACY = 2'd0;
  localparam logic [1:0] COND_PROVIDER_TAGE = 2'd1;
  localparam logic [1:0] COND_PROVIDER_SC = 2'd2;
  localparam logic [1:0] COND_PROVIDER_LOOP = 2'd3;
  localparam int unsigned FTB_SLOTS = 4;
  localparam int unsigned FTB_SLOT_IDX_W = (FTB_SLOTS > 1) ? $clog2(FTB_SLOTS) : 1;
  localparam int unsigned FTB_AGE_W = (FTB_SLOTS > 1) ? $clog2(FTB_SLOTS) : 1;
  localparam logic [FTB_AGE_W-1:0] FTB_AGE_MAX = FTB_AGE_W'(FTB_SLOTS - 1);
  logic [Cfg.PLEN-1:0] pc_reg_q;
  // FTB/BTB storage、index/tag、lookup 扫描与训练已抽到 u_ftb (bpu_ftb.sv)。
  // T0 base 存储与训练已并入 u_tage (tage.sv)；cond base 方向在顶层 pick 块计算。
  // RAS state (arch/spec stacks + counts) lives in u_ras (bpu_ras.sv).
  logic pred_event_valid_q;
  logic pred_event_is_call_q;
  logic pred_event_is_ret_q;
  logic pred_event_is_rvc_q;
  logic pred_event_is_cond_q;
  logic pred_event_taken_q;
  logic [Cfg.PLEN-1:0] pred_event_pc_q;
  // arch/spec GHR + path history、推测推进、commit 推进、flush 回滚与 ITTAGE path
  // context 生成已抽到 u_history (bpu_history.sv)。顶层只保留只读连线与 ghr_q 别名。
  logic [GHR_W-1:0] arch_ghr_q;
  logic [GHR_W-1:0] spec_ghr_q;
  logic [GHR_W-1:0] ghr_q;
  logic [PATH_HIST_W-1:0] ittage_predict_ctx_w;
  // dbg_cond_* 计数已迁入 u_tage T0 base 训练路径；tb 经 i_bpu.u_tage.dbg_cond_* 层级引用。
  // dbg_tage_*/dbg_sc_*/dbg_loop_*/dbg_cond_provider_*/dbg_ftb_*/dbg_ittage_* 计数器与
  // 各 provider 的 override 追踪 FIFO 已随 update 逻辑迁入 u_track (bpu_track.sv)；
  // tb 经 i_bpu.u_track.dbg_*_q 层级引用读取，dbg_bpu_* profile 签名不变。
  logic dbg_snap_ftb_cond_hit_w;
  logic dbg_snap_ftb_jump_hit_w;
  logic dbg_snap_ftb_pick_cond_w;
  logic dbg_snap_ftb_pick_jump_w;
  logic dbg_snap_ftb_cond_tag_miss_w;
  logic dbg_snap_ftb_jump_tag_miss_w;
  logic dbg_snap_ftb_any_valid_w;
  logic dbg_snap_ftb_tag_hit_w;
  logic [2:0] dbg_snap_ftb_valid_count_w;
  logic [2:0] dbg_snap_ftb_cond_count_w;
  logic [2:0] dbg_snap_ftb_jump_count_w;
  logic [2:0] dbg_snap_ftb_in_range_cond_count_w;
  logic dbg_snap_ftb_cond_in_range_w;
  logic dbg_snap_ftb_jump_in_range_w;
  logic dbg_snap_ftb_cond_taken_pred_w;
  logic dbg_snap_ftb_jump_indirect_w;
  logic dbg_snap_ittage_raw_hit_w;
  logic dbg_snap_ittage_use_w;
  // Profile：按 FTQ id 记录预测时刻 FTB 状态，供 mispredict 诊断细分。
  localparam int unsigned FTQ_DEPTH = global_config_pkg::FTQ_DEPTH;
  localparam int unsigned FTQ_ID_W = global_config_pkg::FTQ_ID_W;
  logic [FTQ_DEPTH-1:0] pred_snap_valid_q;
  logic [FTQ_DEPTH-1:0] pred_snap_cond_hit_q;
  logic [FTQ_DEPTH-1:0] pred_snap_jump_hit_q;
  logic [FTQ_DEPTH-1:0] pred_snap_cond_tag_miss_q;
  logic [FTQ_DEPTH-1:0] pred_snap_jump_tag_miss_q;
  logic [FTQ_DEPTH-1:0] pred_snap_any_valid_q;
  logic [FTQ_DEPTH-1:0] pred_snap_tag_hit_q;
  logic [FTQ_DEPTH-1:0][2:0] pred_snap_valid_count_q;
  logic [FTQ_DEPTH-1:0][2:0] pred_snap_cond_count_q;
  logic [FTQ_DEPTH-1:0][2:0] pred_snap_jump_count_q;
  logic [FTQ_DEPTH-1:0][2:0] pred_snap_in_range_cond_count_q;
  logic [FTQ_DEPTH-1:0] pred_snap_cond_in_range_q;
  logic [FTQ_DEPTH-1:0] pred_snap_jump_in_range_q;
  logic [FTQ_DEPTH-1:0] pred_snap_cond_taken_pred_q;
  logic [FTQ_DEPTH-1:0] pred_snap_pick_valid_q;
  logic [FTQ_DEPTH-1:0] pred_snap_pick_cond_q;
  logic [FTQ_DEPTH-1:0] pred_snap_pick_jump_q;
  logic [FTQ_DEPTH-1:0][Cfg.PLEN-1:0] pred_snap_pick_pc_q;
  logic [FTQ_DEPTH-1:0][Cfg.PLEN-1:0] pred_snap_fetch_pc_q;
  logic [FTQ_DEPTH-1:0][FETCH_EPOCH_W-1:0] pred_snap_fetch_epoch_q;
  logic [FTQ_DEPTH-1:0][Cfg.PLEN-1:0] pred_snap_cond_branch_pc_q;
  logic [FTQ_DEPTH-1:0][Cfg.PLEN-1:0] pred_snap_jump_branch_pc_q;
  logic pred_fire_comb_w;

  // base_pc_index / ctr_sat_inc/dec 已并入 u_tage T0 base (tage.sv)。
  // ghr_shift / path_shift 已随历史抽入 u_history (bpu_history.sv)。

  // FTB 单分支预测：原 [INSTR_PER_FETCH] per-slot 向量收敛为单分支标量。
  // 双槽各自还原的分支 PC：cond 槽喂 BHT/TAGE/SC/Loop，jump 槽喂 ITTAGE。
  logic [Cfg.PLEN-1:0] cond_branch_pc_w;
  logic [Cfg.PLEN-1:0] jump_branch_pc_w;
  logic predict_hit;
  logic predict_taken;
  logic predict_is_cond;
  logic predict_is_call;
  logic predict_is_ret;
  logic predict_is_rvc;
  logic predict_is_indirect;
  logic [Cfg.PLEN-1:0] predict_target;
  logic ftb_pick_valid_w;
  logic ftb_pick_is_cond_w;
  logic ftb_pick_is_call_w;
  logic ftb_pick_is_ret_w;
  logic ftb_pick_is_rvc_w;
  logic ftb_pick_is_backward_w;
  logic ftb_pick_is_indirect_w;
  logic [SLOT_IDX_W-1:0] ftb_pick_end_idx_w;
  logic [Cfg.PLEN-1:0] ftb_pick_pc_w;
  logic [Cfg.PLEN-1:0] ftb_pick_target_w;
  logic ittage_raw_hit_w;
  logic ittage_hit_w;
  logic [Cfg.PLEN-1:0] ittage_target_w;
  logic [Cfg.PLEN-1:0] spec_ras_top_w;
  logic spec_ras_has_entry_w;
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
  logic tage_hit_w;
  logic tage_taken_w;
  logic tage_strong_w;
  logic [1:0] tage_provider_w;
  logic [1:0] tage_useful_w;
  // TAGE 2-lane 读出（cond 候选 lane0/lane1），顶层 pick 后按 picked lane mux 成上面的单 lane。
  logic [1:0] tage_hit_lane_w;
  logic [1:0] tage_taken_lane_w;
  logic [1:0] tage_strong_lane_w;
  logic [1:0][1:0] tage_provider_lane_w;
  logic [1:0][1:0] tage_useful_lane_w;
  logic [1:0] tage_base_strong_lane_w;
  logic [1:0] tage_base_weak_lane_w;
  logic picked_cond_lane_w;
  // FTB 候选导出（2 cond + 2 jump）；cond base 方向由 u_tage T0 提供。
  logic [1:0] cond_cand_valid_w;
  logic [1:0][Cfg.PLEN-1:0] cond_cand_pc_w;
  logic [1:0][SLOT_IDX_W-1:0] cond_cand_end_idx_w;
  logic [1:0] cond_cand_is_rvc_w;
  logic [1:0] cond_cand_is_backward_w;
  logic [1:0][Cfg.PLEN-1:0] cond_cand_target_w;
  logic [1:0] jump_cand_valid_w;
  logic [1:0][Cfg.PLEN-1:0] jump_cand_pc_w;
  logic [1:0][SLOT_IDX_W-1:0] jump_cand_end_idx_w;
  logic [1:0] jump_cand_is_rvc_w;
  logic [1:0] jump_cand_is_call_w;
  logic [1:0] jump_cand_is_ret_w;
  logic [1:0] jump_cand_is_indirect_w;
  logic [1:0][Cfg.PLEN-1:0] jump_cand_target_w;
  // FTB legacy cond/jump branch PC（仅作 pick 无 cond/indirect 时的回退与 debug）。
  logic [Cfg.PLEN-1:0] ftb_cond_branch_pc_w;
  logic [Cfg.PLEN-1:0] ftb_jump_branch_pc_w;
  logic sc_taken_w;
  logic sc_confident_w;
  logic loop_hit_w;
  logic loop_taken_w;
  logic loop_confident_w;
  logic cond_taken_legacy_w;
  logic cond_tage_override_w;
  logic cond_sc_override_w;
  logic cond_loop_override_w;
  logic cond_tage_candidate_w;
  logic cond_sc_candidate_w;
  logic cond_loop_candidate_w;
  logic [1:0] cond_selected_provider_w;
  logic cond_selected_taken_w;

  // Bundle contract: predict/update 收口（逻辑不变，仅连线层）。
  predict_req_t  cond_pred_req_w;
  predict_req_t  jump_pred_req_w;
  predict_resp_t tage_pred_resp_w;
  predict_resp_t sc_pred_resp_w;
  predict_resp_t loop_pred_resp_w;
  predict_resp_t ittage_pred_resp_w;
  predict_resp_t pred_resp_w;
  logic [63:0] dbg_ftb_multi_ir_cond_earlier_non_pick_taken_q;

  function automatic logic ftb_branch_in_fetch_window(
      input logic [Cfg.PLEN-1:0] fetch_pc,
      input logic [Cfg.PLEN-1:0] branch_pc,
      input logic is_rvc
  );
    logic [Cfg.PLEN-1:0] diff;
    logic [Cfg.PLEN-1:0] start_rel;
    logic [Cfg.PLEN-1:0] end_rel;
    logic carry_end;
    diff = branch_pc - fetch_pc;
    start_rel = diff >> 1;
    end_rel = start_rel + (is_rvc ? Cfg.PLEN'(0) : Cfg.PLEN'(1));
    carry_end = !is_rvc && ((branch_pc + Cfg.PLEN'(2)) == fetch_pc);
    ftb_branch_in_fetch_window = ((branch_pc >= fetch_pc) &&
                                  (end_rel <= Cfg.PLEN'(PRED_SLOT_COUNT - 1))) ||
                                 carry_end;
  endfunction

  update_t       ftq_update_w;
  update_t       tage_update_w;
  update_t       sc_update_w;
  update_t       loop_update_w;
  update_t       ittage_update_w;

  // ghr_q 别名保持对外不变（tb_bpu/tb_bpu_phase5_red 经 i_BPU.ghr_q 读取）。
  assign ghr_q = spec_ghr_q;

  always_comb begin
    ftq_update_w.valid    = update_valid_i;
    ftq_update_w.pc       = update_pc_i;
    ftq_update_w.taken    = update_taken_i;
    ftq_update_w.target   = update_target_i;
    ftq_update_w.mispred  = 1'b0;
    ftq_update_w.is_cond  = update_is_cond_i;
    ftq_update_w.is_call  = update_is_call_i;
    ftq_update_w.is_ret   = update_is_ret_i;
    ftq_update_w.is_rvc   = update_is_rvc_i;
    ftq_update_w.meta.ghr  = update_ghr_i;
    ftq_update_w.meta.path = ittage_predict_ctx_w;

    tage_update_w = ftq_update_w;
    tage_update_w.valid = ftq_update_w.valid && ftq_update_w.is_cond;
    sc_update_w = ftq_update_w;
    sc_update_w.valid = ftq_update_w.valid && ftq_update_w.is_cond && USE_SC;
    loop_update_w = ftq_update_w;
    loop_update_w.valid = ftq_update_w.valid && USE_LOOP;
    ittage_update_w = ftq_update_w;
    ittage_update_w.valid = USE_ITTAGE && ftq_update_w.valid && !ftq_update_w.is_cond &&
                            ftq_update_w.taken && !ftq_update_w.is_call && !ftq_update_w.is_ret;
  end

  // TAGE 2-lane（仅 cond）：直接读 FTB 导出的 2 个 cond 候选 PC，共享 spec_ghr。
  // 折叠历史在子模块内每表算一次（不依赖 lane/PC），写端口仍单端口。
  tage #(
      .Cfg(Cfg),
      .LANES(2),
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
      .predict_pc_i(cond_cand_pc_w),
      .predict_ghr_i(spec_ghr_q),
      .predict_hit_o(tage_hit_lane_w),
      .predict_taken_o(tage_taken_lane_w),
      .predict_strong_o(tage_strong_lane_w),
      .predict_provider_o(tage_provider_lane_w),
      .predict_useful_o(tage_useful_lane_w),
      .predict_base_strong_o(tage_base_strong_lane_w),
      .predict_base_weak_o(tage_base_weak_lane_w),
      .update_valid_i(tage_update_w.valid),
      .tagged_en_i(USE_TAGE),
      .update_pc_i(tage_update_w.pc),
      .update_ghr_i(tage_update_w.meta.ghr),
      .update_taken_i(tage_update_w.taken),
      .dbg_cond_update_total_o(),
      .dbg_cond_local_correct_o(),
      .dbg_cond_global_correct_o(),
      .dbg_cond_selected_correct_o(),
      .dbg_cond_choose_local_o(),
      .dbg_cond_choose_global_o()
  );

  stat_corr #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(1),
      .GHR_BITS(GHR_BITS),
      .ENTRIES(SC_ENTRIES),
      .CTR_BITS(4),
      .CONF_THRESH(SC_CONF_THRESH)
  ) u_stat_corr (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(cond_pred_req_w.pc),
      .predict_ghr_i(cond_pred_req_w.ghr),
      .predict_taken_o(sc_taken_w),
      .predict_confident_o(sc_confident_w),
      .update_valid_i(sc_update_w.valid),
      .update_pc_i(sc_update_w.pc),
      .update_ghr_i(sc_update_w.meta.ghr),
      .update_taken_i(sc_update_w.taken)
  );

  loop_predictor #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(1),
      .ENTRIES(LOOP_ENTRIES),
      .TAG_BITS(LOOP_TAG_BITS),
      .CONF_THRESH(LOOP_CONF_THRESH)
  ) u_loop_predictor (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(cond_pred_req_w.pc),
      .predict_taken_o(loop_taken_w),
      .predict_confident_o(loop_confident_w),
      .predict_hit_o(loop_hit_w),
      .update_valid_i(loop_update_w.valid),
      .update_pc_i(loop_update_w.pc),
      .update_is_cond_i(loop_update_w.is_cond),
      .update_taken_i(loop_update_w.taken)
  );

  ittage #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(1),
      .ENTRIES(ITTAGE_ENTRIES),
      .TAG_BITS(ITTAGE_TAG_BITS),
      .PATH_HIST_BITS(PATH_HIST_W)
  ) u_ittage (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(jump_pred_req_w.pc),
      .predict_ctx_i(jump_pred_req_w.path),
      .predict_hit_o(ittage_raw_hit_w),
      .predict_target_o(ittage_target_w),
      .update_valid_i(ittage_update_w.valid),
      .update_pc_i(ittage_update_w.pc),
      .update_ctx_i(ittage_update_w.meta.path),
      .update_target_i(ittage_update_w.target)
  );

  bpu_ras #(
      .Cfg(Cfg),
      .RAS_DEPTH(RAS_DEPTH)
  ) u_ras (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .ras_update_valid_i(ras_update_valid_i),
      .ras_update_is_call_i(ras_update_is_call_i),
      .ras_update_is_ret_i(ras_update_is_ret_i),
      .ras_update_is_rvc_i(ras_update_is_rvc_i),
      .ras_update_pc_i(ras_update_pc_i),
      .flush_i(flush_i),
      .pred_event_valid_i(pred_event_valid_q),
      .pred_event_is_call_i(pred_event_is_call_q),
      .pred_event_is_ret_i(pred_event_is_ret_q),
      .pred_event_is_rvc_i(pred_event_is_rvc_q),
      .pred_event_pc_i(pred_event_pc_q),
      .spec_ras_top_o(spec_ras_top_w),
      .spec_ras_has_entry_o(spec_ras_has_entry_w),
      // arch_ras_* outputs are debug-only; TB reads them via u_ras hierarchy.
      .arch_ras_top_o(),
      .arch_ras_has_entry_o()
  );

  // 共享分支历史：arch/spec GHR + path。推测推进由寄存的 pred_event（与 u_ras 同源）
  // 驱动，commit 推进由 ftq_update 驱动，flush 时 spec<=arch 回滚。ITTAGE predict-time
  // path context 也在此生成。逻辑与原 bpu.sv 内联完全一致，仅作用域/连线不同。
  bpu_history #(
      .Cfg(Cfg),
      .GHR_BITS(GHR_BITS),
      .PATH_HIST_BITS(PATH_HIST_BITS)
  ) u_history (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .flush_i(flush_i),
      .update_valid_i(ftq_update_w.valid),
      .update_is_cond_i(ftq_update_w.is_cond),
      .update_taken_i(ftq_update_w.taken),
      .update_pc_i(ftq_update_w.pc),
      .pred_event_valid_i(pred_event_valid_q),
      .pred_event_is_cond_i(pred_event_is_cond_q),
      .pred_event_taken_i(pred_event_taken_q),
      .pred_event_pc_i(pred_event_pc_q),
      .arch_ghr_o(arch_ghr_q),
      .spec_ghr_o(spec_ghr_q),
      .ittage_predict_ctx_o(ittage_predict_ctx_w)
  );

  // FTB/BTB storage、index/tag、predict-time lookup 扫描与 commit-time 训练。
  bpu_ftb #(
      .Cfg(Cfg),
      .BTB_ENTRIES(BTB_ENTRIES),
      .BTB_HASH_ENABLE(BTB_HASH_ENABLE)
  ) u_ftb (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .pc_reg_i(pc_reg_q),
      .update_valid_i(ftq_update_w.valid),
      .update_pc_i(ftq_update_w.pc),
      .update_taken_i(ftq_update_w.taken),
      .update_target_i(ftq_update_w.target),
      .update_is_cond_i(ftq_update_w.is_cond),
      .update_is_call_i(ftq_update_w.is_call),
      .update_is_ret_i(ftq_update_w.is_ret),
      .update_is_rvc_i(ftq_update_w.is_rvc),
      // legacy pick 不再驱动顶层（顶层用 TAGE 方向自己 pick），保留 FTB 内部计算但不连出。
      .ftb_pick_valid_o(),
      .ftb_pick_is_cond_o(),
      .ftb_pick_is_call_o(),
      .ftb_pick_is_ret_o(),
      .ftb_pick_is_rvc_o(),
      .ftb_pick_is_backward_o(),
      .ftb_pick_is_indirect_o(),
      .ftb_pick_end_idx_o(),
      .ftb_pick_pc_o(),
      .ftb_pick_target_o(),
      // 候选导出（2 cond + 2 jump）；cond 方向由顶层 TAGE pick 计算。
      .cond_cand_valid_o(cond_cand_valid_w),
      .cond_cand_pc_o(cond_cand_pc_w),
      .cond_cand_end_idx_o(cond_cand_end_idx_w),
      .cond_cand_is_rvc_o(cond_cand_is_rvc_w),
      .cond_cand_is_backward_o(cond_cand_is_backward_w),
      .cond_cand_target_o(cond_cand_target_w),
      .jump_cand_valid_o(jump_cand_valid_w),
      .jump_cand_pc_o(jump_cand_pc_w),
      .jump_cand_end_idx_o(jump_cand_end_idx_w),
      .jump_cand_is_rvc_o(jump_cand_is_rvc_w),
      .jump_cand_is_call_o(jump_cand_is_call_w),
      .jump_cand_is_ret_o(jump_cand_is_ret_w),
      .jump_cand_is_indirect_o(jump_cand_is_indirect_w),
      .jump_cand_target_o(jump_cand_target_w),
      .cond_branch_pc_o(ftb_cond_branch_pc_w),
      .jump_branch_pc_o(ftb_jump_branch_pc_w),
      .dbg_snap_ftb_cond_hit_o(dbg_snap_ftb_cond_hit_w),
      .dbg_snap_ftb_jump_hit_o(dbg_snap_ftb_jump_hit_w),
      .dbg_snap_ftb_cond_tag_miss_o(dbg_snap_ftb_cond_tag_miss_w),
      .dbg_snap_ftb_jump_tag_miss_o(dbg_snap_ftb_jump_tag_miss_w),
      .dbg_snap_ftb_any_valid_o(dbg_snap_ftb_any_valid_w),
      .dbg_snap_ftb_tag_hit_o(dbg_snap_ftb_tag_hit_w),
      .dbg_snap_ftb_valid_count_o(dbg_snap_ftb_valid_count_w),
      .dbg_snap_ftb_cond_count_o(dbg_snap_ftb_cond_count_w),
      .dbg_snap_ftb_jump_count_o(dbg_snap_ftb_jump_count_w),
      .dbg_snap_ftb_in_range_cond_count_o(dbg_snap_ftb_in_range_cond_count_w),
      .dbg_snap_ftb_cond_in_range_o(dbg_snap_ftb_cond_in_range_w),
      .dbg_snap_ftb_jump_in_range_o(dbg_snap_ftb_jump_in_range_w)
  );

  // Override 追踪 FIFO（tage/sc/loop/cond）+ 全部 dbg_* 计数器。预测期由 pred_fire +
  // pred_slot/override sideband 入队并计数，commit 期由 update 出队比对正确性。逻辑与
  // 原 bpu.sv 内联 always_ff 完全一致，仅作用域/连线不同。
  bpu_track #(
      .USE_TAGE(USE_TAGE),
      .USE_SC(USE_SC),
      .USE_LOOP(USE_LOOP),
      .TRACK_DEPTH(TRACK_DEPTH)
  ) u_track (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .flush_i(flush_i),
      .update_valid_i(ftq_update_w.valid),
      .update_is_cond_i(ftq_update_w.is_cond),
      .update_taken_i(ftq_update_w.taken),
      .ittage_update_valid_i(ittage_update_w.valid),
      .pred_fire_i(pred_fire_comb_w),
      .pred_slot_is_cond_i(pred_slot_is_cond_w),
      .pred_slot_taken_i(pred_slot_taken_w),
      .tage_hit_i(tage_hit_w),
      .cond_tage_override_i(cond_tage_override_w),
      .sc_confident_i(sc_confident_w),
      .cond_sc_override_i(cond_sc_override_w),
      .loop_hit_i(loop_hit_w),
      .loop_confident_i(loop_confident_w),
      .cond_loop_override_i(cond_loop_override_w),
      .cond_selected_provider_i(cond_selected_provider_w),
      .cond_selected_taken_i(cond_selected_taken_w),
      .cond_taken_legacy_i(cond_taken_legacy_w),
      .tage_taken_i(tage_taken_w),
      .sc_taken_i(sc_taken_w),
      .loop_taken_i(loop_taken_w),
      .cond_tage_candidate_i(cond_tage_candidate_w),
      .cond_sc_candidate_i(cond_sc_candidate_w),
      .cond_loop_candidate_i(cond_loop_candidate_w),
      .dbg_snap_ftb_cond_hit_i(dbg_snap_ftb_cond_hit_w),
      .dbg_snap_ftb_jump_hit_i(dbg_snap_ftb_jump_hit_w),
      .dbg_snap_ftb_pick_cond_i(dbg_snap_ftb_pick_cond_w),
      .dbg_snap_ftb_pick_jump_i(dbg_snap_ftb_pick_jump_w),
      .dbg_snap_ftb_cond_tag_miss_i(dbg_snap_ftb_cond_tag_miss_w),
      .dbg_snap_ftb_jump_tag_miss_i(dbg_snap_ftb_jump_tag_miss_w),
      .dbg_snap_ftb_jump_indirect_i(dbg_snap_ftb_jump_indirect_w),
      .dbg_snap_ittage_raw_hit_i(dbg_snap_ittage_raw_hit_w),
      .dbg_snap_ittage_use_i(dbg_snap_ittage_use_w)
  );

  // ---- 顶层 pick：用 TAGE 2-lane 方向喂回，在 4 候选（2 cond + 2 jump）里选最早 in-range taken ----
  // cond 槽方向 = classic TAGE（命中用 provider/alt，否则 T0 base + backward 启发）；jump 无条件 taken。
  // 候选已由 FTB 保证 in-range 且各自按 PC 升序（lane0=最早），这里只比 4 个 PC 选最小 taken。
  always_comb begin
    logic [1:0] cond_dir;
    logic [3:0] cand_valid;
    logic [3:0] cand_taken;
    logic [3:0][Cfg.PLEN-1:0] cand_pc;
    int picked;
    int jl;
    logic picked_is_cond;
    int picked_cond_lane;

    for (int k = 0; k < 2; k++) begin
      cond_dir[k] = tage_hit_lane_w[k] ? tage_taken_lane_w[k] :
                    (tage_taken_lane_w[k] ||
                     (tage_base_weak_lane_w[k] && cond_cand_is_backward_w[k]));
    end

    cand_valid[0] = cond_cand_valid_w[0];
    cand_valid[1] = cond_cand_valid_w[1];
    cand_valid[2] = jump_cand_valid_w[0];
    cand_valid[3] = jump_cand_valid_w[1];
    cand_taken[0] = cond_cand_valid_w[0] && cond_dir[0];
    cand_taken[1] = cond_cand_valid_w[1] && cond_dir[1];
    cand_taken[2] = jump_cand_valid_w[0];
    cand_taken[3] = jump_cand_valid_w[1];
    cand_pc[0] = cond_cand_pc_w[0];
    cand_pc[1] = cond_cand_pc_w[1];
    cand_pc[2] = jump_cand_pc_w[0];
    cand_pc[3] = jump_cand_pc_w[1];

    picked = -1;
    for (int c = 0; c < 4; c++) begin
      if (cand_valid[c] && cand_taken[c] && ((picked < 0) || (cand_pc[c] < cand_pc[picked]))) begin
        picked = c;
      end
    end

    picked_is_cond    = (picked == 0) || (picked == 1);
    picked_cond_lane  = (picked == 1) ? 1 : 0;
    picked_cond_lane_w = (picked == 1);
    jl                = (picked == 3) ? 1 : 0;

    ftb_pick_valid_w       = (picked >= 0);
    ftb_pick_is_cond_w     = 1'b0;
    ftb_pick_is_call_w     = 1'b0;
    ftb_pick_is_ret_w      = 1'b0;
    ftb_pick_is_rvc_w      = 1'b0;
    ftb_pick_is_backward_w = 1'b0;
    ftb_pick_is_indirect_w = 1'b0;
    ftb_pick_end_idx_w     = '0;
    ftb_pick_pc_w          = '0;
    ftb_pick_target_w      = '0;

    if (picked_is_cond) begin
      ftb_pick_is_cond_w     = 1'b1;
      ftb_pick_is_rvc_w      = cond_cand_is_rvc_w[picked_cond_lane];
      ftb_pick_is_backward_w = cond_cand_is_backward_w[picked_cond_lane];
      ftb_pick_end_idx_w     = cond_cand_end_idx_w[picked_cond_lane];
      ftb_pick_pc_w          = cond_cand_pc_w[picked_cond_lane];
      ftb_pick_target_w      = cond_cand_target_w[picked_cond_lane];
    end else if (picked >= 0) begin
      ftb_pick_is_call_w     = jump_cand_is_call_w[jl];
      ftb_pick_is_ret_w      = jump_cand_is_ret_w[jl];
      ftb_pick_is_indirect_w = jump_cand_is_indirect_w[jl];
      ftb_pick_is_rvc_w      = jump_cand_is_rvc_w[jl];
      ftb_pick_end_idx_w     = jump_cand_end_idx_w[jl];
      ftb_pick_pc_w          = jump_cand_pc_w[jl];
      ftb_pick_target_w      = jump_cand_target_w[jl];
    end

    // picked cond lane 的 TAGE meta mux 给现有 override 逻辑（非 cond pick 时清零）。
    if (picked_is_cond) begin
      tage_hit_w      = tage_hit_lane_w[picked_cond_lane];
      tage_taken_w    = tage_taken_lane_w[picked_cond_lane];
      tage_strong_w   = tage_strong_lane_w[picked_cond_lane];
      tage_provider_w = tage_provider_lane_w[picked_cond_lane];
      tage_useful_w   = tage_useful_lane_w[picked_cond_lane];
    end else begin
      tage_hit_w      = 1'b0;
      tage_taken_w    = 1'b0;
      tage_strong_w   = 1'b0;
      tage_provider_w = '0;
      tage_useful_w   = '0;
    end

    // override 的 base = picked cond 的 classic TAGE 方向（SC/Loop 在其上叠加，优先级不变）。
    cond_taken_legacy_w = picked_is_cond ? cond_dir[picked_cond_lane] : 1'b0;

    // SC/Loop/BHT 单 lane，输入 picked cond PC（无 cond pick 时回退最早 cond 候选 / FTB 值）。
    if (picked_is_cond) begin
      cond_branch_pc_w = cond_cand_pc_w[picked_cond_lane];
    end else if (cond_cand_valid_w[0]) begin
      cond_branch_pc_w = cond_cand_pc_w[0];
    end else begin
      cond_branch_pc_w = ftb_cond_branch_pc_w;
    end

    // ITTAGE 单 lane，输入最早 in-range indirect 候选 PC。
    if (jump_cand_valid_w[0] && jump_cand_is_indirect_w[0]) begin
      jump_branch_pc_w = jump_cand_pc_w[0];
    end else if (jump_cand_valid_w[1] && jump_cand_is_indirect_w[1]) begin
      jump_branch_pc_w = jump_cand_pc_w[1];
    end else begin
      jump_branch_pc_w = ftb_jump_branch_pc_w;
    end

    // pick 相关 dbg snap：与顶层 TAGE 方向一致（不再由 FTB 内部 BHT 计算）。
    dbg_snap_ftb_cond_taken_pred_w =
        (cond_cand_valid_w[0] && cond_dir[0]) || (cond_cand_valid_w[1] && cond_dir[1]);
    dbg_snap_ftb_pick_cond_w = ftb_pick_valid_w && ftb_pick_is_cond_w;
    dbg_snap_ftb_pick_jump_w = ftb_pick_valid_w && !ftb_pick_is_cond_w;
    dbg_snap_ftb_jump_indirect_w = ftb_pick_valid_w && ftb_pick_is_indirect_w;
  end

  always_comb begin
    cond_pred_req_w.valid = !flush_i && !redirect_valid_i;
    cond_pred_req_w.pc    = cond_branch_pc_w;
    cond_pred_req_w.ghr   = spec_ghr_q;
    cond_pred_req_w.path  = '0;

    jump_pred_req_w.valid = !flush_i && !redirect_valid_i;
    jump_pred_req_w.pc    = jump_branch_pc_w;
    jump_pred_req_w.ghr   = '0;
    jump_pred_req_w.path  = ittage_predict_ctx_w;
  end

  always_comb begin
    logic legacy_strong;
    logic tage_provider_ok;
    logic tage_pred_nt_w;
    logic tage_strong_nt_w;
    logic tage_useful_ok_w;
    logic tage_nt_override_ok;
    logic tage_allow_override;
    logic sc_allow_override;

    // 预测期 legacy-strong sideband 由 u_tage T0 base 给出（3-bit 饱和强置信）。
    legacy_strong = ftb_pick_is_cond_w && tage_base_strong_lane_w[picked_cond_lane_w];

    cond_tage_override_w = 1'b0;
    cond_sc_override_w = 1'b0;
    cond_loop_override_w = 1'b0;
    cond_selected_provider_w = COND_PROVIDER_LEGACY;
    cond_selected_taken_w = cond_taken_legacy_w;

    tage_provider_ok = (int'(tage_provider_w) >= int'(TAGE_OVERRIDE_MIN_PROVIDER));
    tage_pred_nt_w = !tage_taken_w;
    tage_strong_nt_w = tage_strong_w && tage_pred_nt_w;
    tage_useful_ok_w = |tage_useful_w;
    // 净正区：3-bit signed strong-NT（ctr 饱和 -4）+ useful>0 + MIN_PROVIDER 门控。
    tage_nt_override_ok = tage_strong_nt_w;
    tage_allow_override = USE_TAGE && tage_hit_w && tage_nt_override_ok && tage_provider_ok &&
                          tage_useful_ok_w;
    cond_tage_candidate_w = ftb_pick_is_cond_w && tage_allow_override;

    sc_allow_override = USE_SC && sc_confident_w;
    if (legacy_strong) begin
      sc_allow_override = 1'b0;
    end
    if (SC_BLOCK_ON_TAGE_HIT && USE_TAGE && tage_hit_w) begin
      sc_allow_override = 1'b0;
    end
    if (SC_REQUIRE_BOTH_WEAK && legacy_strong) begin
      sc_allow_override = 1'b0;
    end
    cond_sc_candidate_w = ftb_pick_is_cond_w && sc_allow_override;
    cond_loop_candidate_w = USE_LOOP && ftb_pick_is_cond_w && loop_confident_w;

    // TAGE-SC-L 条件方向优先级：Loop > TAGE > SC > Legacy。
    // FTB 只 pick legacy-taken 槽；override 在更高优先级 provider 与 legacy 不一致时生效。
    if (cond_loop_candidate_w) begin
      cond_loop_override_w = (loop_taken_w != cond_taken_legacy_w);
      cond_selected_provider_w = COND_PROVIDER_LOOP;
      cond_selected_taken_w = loop_taken_w;
    end else if (cond_tage_candidate_w) begin
      cond_tage_override_w = 1'b1;
      cond_selected_provider_w = COND_PROVIDER_TAGE;
      cond_selected_taken_w = tage_taken_w;
    end else if (cond_sc_candidate_w) begin
      cond_sc_override_w = (sc_taken_w != cond_taken_legacy_w);
      cond_selected_provider_w = COND_PROVIDER_SC;
      cond_selected_taken_w = sc_taken_w;
    end

    ittage_hit_w = USE_ITTAGE && ftb_pick_is_indirect_w && ittage_raw_hit_w;
    predict_target = ftb_pick_target_w;
    if (ftb_pick_is_ret_w && spec_ras_has_entry_w) begin
      predict_target = spec_ras_top_w;
    end else if (ftb_pick_is_indirect_w && ittage_hit_w) begin
      predict_target = ittage_target_w;
    end

    predict_hit = ftb_pick_valid_w;
    if (ftb_pick_is_cond_w && predict_hit) begin
      predict_taken = cond_selected_taken_w;
    end else begin
      predict_taken = predict_hit;
    end
    predict_is_cond = ftb_pick_is_cond_w;
    predict_is_call = ftb_pick_is_call_w;
    predict_is_ret = ftb_pick_is_ret_w;
    predict_is_indirect = ftb_pick_is_indirect_w;
    predict_is_rvc = ftb_pick_is_rvc_w;

    // 下游 FTQ：只有"有效 taken"才需要重定向；override 成 NT 时按 fall-through 顺序前进。
    pred_slot_valid_w   = predict_hit && predict_taken;
    pred_slot_idx_w     = pred_slot_valid_w ? ftb_pick_end_idx_w : '0;
    pred_slot_is_call_w = pred_slot_valid_w && predict_is_call;
    pred_slot_is_ret_w  = pred_slot_valid_w && predict_is_ret;
    pred_slot_is_rvc_w  = pred_slot_valid_w && predict_is_rvc;
    // cond 事件用于历史/统计：与 taken 解耦，picked cond 无论翻不翻都记一次（方向见
    // pred_slot_taken_w）。picked-cond 集合不变，仅 taken 位随 override 改变。
    pred_slot_is_cond_w = predict_hit && predict_is_cond;
    pred_slot_taken_w   = predict_taken;
    pred_slot_pc_w      = predict_hit ? ftb_pick_pc_w : '0;
    pred_slot_target_w  = predict_target;

    dbg_snap_ittage_raw_hit_w = ittage_raw_hit_w;
    dbg_snap_ittage_use_w = ittage_hit_w;

    tage_pred_resp_w.hit           = tage_hit_w;
    tage_pred_resp_w.taken         = tage_taken_w;
    tage_pred_resp_w.target        = '0;
    tage_pred_resp_w.provider      = tage_provider_w;
    tage_pred_resp_w.meta.is_strong   = tage_strong_w;
    tage_pred_resp_w.meta.useful   = tage_useful_w;
    tage_pred_resp_w.meta.confident = 1'b0;
    tage_pred_resp_w.meta.loop_hit = 1'b0;
    tage_pred_resp_w.meta.is_backward = ftb_pick_is_backward_w;
    tage_pred_resp_w.meta.is_call  = ftb_pick_is_call_w;
    tage_pred_resp_w.meta.is_ret   = ftb_pick_is_ret_w;
    tage_pred_resp_w.meta.is_rvc   = ftb_pick_is_rvc_w;
    tage_pred_resp_w.meta.is_cond  = ftb_pick_is_cond_w;
    tage_pred_resp_w.meta.is_indirect = ftb_pick_is_indirect_w;

    sc_pred_resp_w.hit             = 1'b0;
    sc_pred_resp_w.taken           = sc_taken_w;
    sc_pred_resp_w.target          = '0;
    sc_pred_resp_w.provider        = COND_PROVIDER_SC;
    sc_pred_resp_w.meta.is_strong     = 1'b0;
    sc_pred_resp_w.meta.useful     = '0;
    sc_pred_resp_w.meta.confident  = sc_confident_w;
    sc_pred_resp_w.meta.loop_hit   = 1'b0;
    sc_pred_resp_w.meta.is_backward = ftb_pick_is_backward_w;
    sc_pred_resp_w.meta.is_call    = ftb_pick_is_call_w;
    sc_pred_resp_w.meta.is_ret     = ftb_pick_is_ret_w;
    sc_pred_resp_w.meta.is_rvc     = ftb_pick_is_rvc_w;
    sc_pred_resp_w.meta.is_cond    = ftb_pick_is_cond_w;
    sc_pred_resp_w.meta.is_indirect = ftb_pick_is_indirect_w;

    loop_pred_resp_w.hit           = loop_hit_w;
    loop_pred_resp_w.taken         = loop_taken_w;
    loop_pred_resp_w.target        = '0;
    loop_pred_resp_w.provider      = COND_PROVIDER_LOOP;
    loop_pred_resp_w.meta.is_strong   = 1'b0;
    loop_pred_resp_w.meta.useful   = '0;
    loop_pred_resp_w.meta.confident = loop_confident_w;
    loop_pred_resp_w.meta.loop_hit = loop_hit_w;
    loop_pred_resp_w.meta.is_backward = ftb_pick_is_backward_w;
    loop_pred_resp_w.meta.is_call  = ftb_pick_is_call_w;
    loop_pred_resp_w.meta.is_ret   = ftb_pick_is_ret_w;
    loop_pred_resp_w.meta.is_rvc   = ftb_pick_is_rvc_w;
    loop_pred_resp_w.meta.is_cond  = ftb_pick_is_cond_w;
    loop_pred_resp_w.meta.is_indirect = ftb_pick_is_indirect_w;

    ittage_pred_resp_w.hit         = ittage_raw_hit_w;
    ittage_pred_resp_w.taken       = ittage_hit_w;
    ittage_pred_resp_w.target      = ittage_target_w;
    ittage_pred_resp_w.provider    = '0;
    ittage_pred_resp_w.meta        = '0;

    pred_resp_w.hit                = predict_hit;
    pred_resp_w.taken              = predict_taken;
    pred_resp_w.target             = predict_target;
    pred_resp_w.provider           = cond_selected_provider_w;
    pred_resp_w.meta.is_strong        = tage_pred_resp_w.meta.is_strong;
    pred_resp_w.meta.useful        = tage_pred_resp_w.meta.useful;
    pred_resp_w.meta.confident     = sc_pred_resp_w.meta.confident | loop_pred_resp_w.meta.confident;
    pred_resp_w.meta.loop_hit      = loop_pred_resp_w.meta.loop_hit;
    pred_resp_w.meta.is_backward   = ftb_pick_is_backward_w;
    pred_resp_w.meta.is_call       = predict_is_call;
    pred_resp_w.meta.is_ret        = predict_is_ret;
    pred_resp_w.meta.is_rvc        = predict_is_rvc;
    pred_resp_w.meta.is_cond       = predict_is_cond;
    pred_resp_w.meta.is_indirect   = predict_is_indirect;
  end

  assign pred_fire_comb_w = ftq_enq_valid_o && ftq_enq_ready_i;
  assign pred_npc_w = pred_slot_valid_w ? pred_slot_target_w : (pc_reg_q + Cfg.FETCH_WIDTH);

  assign ftq_enq_valid_o = !flush_i && !redirect_valid_i;
  assign ftq_enq_pc_o = pc_reg_q;
  assign ftq_enq_pred_slot_valid_o = pred_slot_valid_w;
  assign ftq_enq_pred_slot_idx_o = pred_slot_idx_w;
  assign ftq_enq_pred_target_o = pred_slot_target_w;
  assign ftq_enq_pred_npc_o = pred_npc_w;
  assign ftq_enq_pred_ghr_o = spec_ghr_q;

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      pc_reg_q <= Cfg.PLEN'(Cfg.RESET_VECTOR);
      pred_event_valid_q <= 1'b0;
      pred_event_is_call_q <= 1'b0;
      pred_event_is_ret_q <= 1'b0;
      pred_event_is_rvc_q <= 1'b0;
      pred_event_is_cond_q <= 1'b0;
      pred_event_taken_q <= 1'b0;
      pred_event_pc_q <= '0;
      pred_snap_valid_q <= '0;
      pred_snap_cond_hit_q <= '0;
      pred_snap_jump_hit_q <= '0;
      pred_snap_cond_tag_miss_q <= '0;
      pred_snap_jump_tag_miss_q <= '0;
      pred_snap_any_valid_q <= '0;
      pred_snap_tag_hit_q <= '0;
      pred_snap_valid_count_q <= '0;
      pred_snap_cond_count_q <= '0;
      pred_snap_jump_count_q <= '0;
      pred_snap_in_range_cond_count_q <= '0;
      pred_snap_cond_in_range_q <= '0;
      pred_snap_jump_in_range_q <= '0;
      pred_snap_cond_taken_pred_q <= '0;
      pred_snap_pick_valid_q <= '0;
      pred_snap_pick_cond_q <= '0;
      pred_snap_pick_jump_q <= '0;
      pred_snap_pick_pc_q <= '0;
      pred_snap_fetch_pc_q <= '0;
      pred_snap_fetch_epoch_q <= '0;
      pred_snap_cond_branch_pc_q <= '0;
      pred_snap_jump_branch_pc_q <= '0;
      dbg_ftb_multi_ir_cond_earlier_non_pick_taken_q <= '0;
`ifndef SYNTHESIS
`endif
      // arch/spec GHR + path 复位已随历史迁入 u_history。
      // T0 base 复位已随存储迁入 u_tage。
      // dbg_* 计数器与 override 追踪 FIFO 复位已随逻辑迁入 u_track。
    end else begin
      logic pred_fire_w;

      pred_fire_w = ftq_enq_valid_o && ftq_enq_ready_i;

      if (redirect_valid_i) begin
        pc_reg_q <= redirect_pc_i;
      end else if (pred_fire_w) begin
        pc_reg_q <= pred_npc_w;
      end

      // FTB BTB 训练已移至 u_ftb；T0 base 训练与 cond 计数已移至 u_tage；FTB/ITTAGE
      // 训练计数与 override 追踪 FIFO 的出队/正确性比对已移至 u_track。
      // arch/spec GHR + path 推进、flush 回滚已移至 u_history。
      // RAS arch/spec push-pop now handled by u_ras (bpu_ras.sv)。

      if (flush_i) begin
        pred_event_valid_q <= 1'b0;
        pred_event_is_call_q <= 1'b0;
        pred_event_is_ret_q <= 1'b0;
        pred_event_is_rvc_q <= 1'b0;
        pred_event_is_cond_q <= 1'b0;
        pred_event_taken_q <= 1'b0;
        pred_event_pc_q <= '0;
        pred_snap_valid_q <= '0;
      end else begin
        // override 追踪 FIFO 入队与 dbg_* lookup/usage 计数已移至 u_track。
        pred_event_valid_q <= pred_fire_w;
        pred_event_is_call_q <= pred_fire_w && pred_slot_is_call_w;
        pred_event_is_ret_q <= pred_fire_w && pred_slot_is_ret_w;
        pred_event_is_rvc_q <= pred_fire_w && pred_slot_is_rvc_w;
        pred_event_is_cond_q <= pred_fire_w && pred_slot_is_cond_w;
        pred_event_taken_q <= pred_fire_w && pred_slot_taken_w;
        pred_event_pc_q <= pred_slot_pc_w;
        if (pred_fire_w) begin
          pred_snap_valid_q[ftq_enq_id_i] <= 1'b1;
          pred_snap_fetch_pc_q[ftq_enq_id_i] <= pc_reg_q;
          pred_snap_fetch_epoch_q[ftq_enq_id_i] <= ftq_enq_epoch_i;
          pred_snap_cond_branch_pc_q[ftq_enq_id_i] <= cond_branch_pc_w;
          pred_snap_jump_branch_pc_q[ftq_enq_id_i] <= jump_branch_pc_w;
          pred_snap_cond_hit_q[ftq_enq_id_i] <= dbg_snap_ftb_cond_hit_w;
          pred_snap_jump_hit_q[ftq_enq_id_i] <= dbg_snap_ftb_jump_hit_w;
          pred_snap_cond_tag_miss_q[ftq_enq_id_i] <= dbg_snap_ftb_cond_tag_miss_w;
          pred_snap_jump_tag_miss_q[ftq_enq_id_i] <= dbg_snap_ftb_jump_tag_miss_w;
          pred_snap_any_valid_q[ftq_enq_id_i] <= dbg_snap_ftb_any_valid_w;
          pred_snap_tag_hit_q[ftq_enq_id_i] <= dbg_snap_ftb_tag_hit_w;
          pred_snap_valid_count_q[ftq_enq_id_i] <= dbg_snap_ftb_valid_count_w;
          pred_snap_cond_count_q[ftq_enq_id_i] <= dbg_snap_ftb_cond_count_w;
          pred_snap_jump_count_q[ftq_enq_id_i] <= dbg_snap_ftb_jump_count_w;
          pred_snap_in_range_cond_count_q[ftq_enq_id_i] <= dbg_snap_ftb_in_range_cond_count_w;
          pred_snap_cond_in_range_q[ftq_enq_id_i] <= dbg_snap_ftb_cond_in_range_w;
          pred_snap_jump_in_range_q[ftq_enq_id_i] <= dbg_snap_ftb_jump_in_range_w;
          pred_snap_cond_taken_pred_q[ftq_enq_id_i] <= dbg_snap_ftb_cond_taken_pred_w;
          pred_snap_pick_valid_q[ftq_enq_id_i] <= ftb_pick_valid_w;
          pred_snap_pick_cond_q[ftq_enq_id_i] <= dbg_snap_ftb_pick_cond_w;
          pred_snap_pick_jump_q[ftq_enq_id_i] <= dbg_snap_ftb_pick_jump_w;
          pred_snap_pick_pc_q[ftq_enq_id_i] <= ftb_pick_pc_w;
        end

        if (update_valid_i && update_is_cond_i && update_taken_i) begin
          logic [FTQ_ID_W-1:0] upd_ftq;
          logic snap_valid;
          logic epoch_ok;
          logic [2:0] ir_cond_cnt;
          logic pick_valid;
          logic [Cfg.PLEN-1:0] snap_fetch_pc;
          logic [Cfg.PLEN-1:0] snap_pick_pc;
          logic [FETCH_EPOCH_W-1:0] snap_epoch;
          logic branch_in_window;
          logic count_event;

          upd_ftq = update_ftq_id_i;
          snap_valid = pred_snap_valid_q[upd_ftq];
          snap_epoch = pred_snap_fetch_epoch_q[upd_ftq];
          epoch_ok = snap_epoch == update_fetch_epoch_i;
          ir_cond_cnt = pred_snap_in_range_cond_count_q[upd_ftq];
          pick_valid = pred_snap_pick_valid_q[upd_ftq];
          snap_fetch_pc = pred_snap_fetch_pc_q[upd_ftq];
          snap_pick_pc = pred_snap_pick_pc_q[upd_ftq];
          branch_in_window =
              ftb_branch_in_fetch_window(snap_fetch_pc, update_pc_i, update_is_rvc_i);
          count_event = snap_valid && epoch_ok &&
                        (ir_cond_cnt >= 3'd2) &&
                        pick_valid &&
                        branch_in_window &&
                        (update_pc_i < snap_pick_pc);
          if (count_event) begin
            dbg_ftb_multi_ir_cond_earlier_non_pick_taken_q <=
                dbg_ftb_multi_ir_cond_earlier_non_pick_taken_q + 64'd1;
          end
        end
      end
    end
  end
endmodule : bpu
