// vsrc/frontend/predictor/bpu_ftb.sv
// Fetch Target Buffer / BTB: per-16B-block 4-slot unified control-flow store,
// block-aligned index/tag, the predict-time lookup scan (cross-block fetch
// window) and commit-time training. Behavior is identical to the inline FTB
// that previously lived in bpu.sv: logic was moved out unchanged, only
// scope/wiring differs.
//
// Cond base 方向由 bpu.sv 顶层用 TAGE T0 计算；FTB 只导出 in-range 候选。
import global_config_pkg::*;
module bpu_ftb #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned BTB_ENTRIES = 64,
    parameter bit BTB_HASH_ENABLE = 1'b1
) (
    input logic clk_i,
    input logic rst_i,

    // Predict-time inputs.
    input logic [Cfg.PLEN-1:0] pc_reg_i,

    // Commit-time FTB training (from FTQ commit update).
    input logic                update_valid_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,
    input logic                update_taken_i,
    input logic [Cfg.PLEN-1:0] update_target_i,
    input logic                update_is_cond_i,
    input logic                update_is_call_i,
    input logic                update_is_ret_i,
    input logic                update_is_rvc_i,

    // Lookup pick outputs.
    output logic                          ftb_pick_valid_o,
    output logic                          ftb_pick_is_cond_o,
    output logic                          ftb_pick_is_call_o,
    output logic                          ftb_pick_is_ret_o,
    output logic                          ftb_pick_is_rvc_o,
    output logic                          ftb_pick_is_backward_o,
    output logic                          ftb_pick_is_indirect_o,
    output logic [global_config_pkg::PRED_SLOT_IDX_W-1:0] ftb_pick_end_idx_o,
    output logic [Cfg.PLEN-1:0]           ftb_pick_pc_o,
    output logic [Cfg.PLEN-1:0]           ftb_pick_target_o,

    // Candidate export (fixed 4 slots = 2 cond + 2 other). 顶层用 TAGE 方向做最终
    // pick；cond/jump 候选各 2 路按 in-range PC 升序导出（lane0 = 最早）。
    output logic [1:0]                                          cond_cand_valid_o,
    output logic [1:0][Cfg.PLEN-1:0]                            cond_cand_pc_o,
    output logic [1:0][global_config_pkg::PRED_SLOT_IDX_W-1:0]  cond_cand_end_idx_o,
    output logic [1:0]                                          cond_cand_is_rvc_o,
    output logic [1:0]                                          cond_cand_is_backward_o,
    output logic [1:0][Cfg.PLEN-1:0]                            cond_cand_target_o,
    output logic [1:0]                                          jump_cand_valid_o,
    output logic [1:0][Cfg.PLEN-1:0]                            jump_cand_pc_o,
    output logic [1:0][global_config_pkg::PRED_SLOT_IDX_W-1:0]  jump_cand_end_idx_o,
    output logic [1:0]                                          jump_cand_is_rvc_o,
    output logic [1:0]                                          jump_cand_is_call_o,
    output logic [1:0]                                          jump_cand_is_ret_o,
    output logic [1:0]                                          jump_cand_is_indirect_o,
    output logic [1:0][Cfg.PLEN-1:0]                            jump_cand_target_o,

    output logic [Cfg.PLEN-1:0]           cond_branch_pc_o,
    output logic [Cfg.PLEN-1:0]           jump_branch_pc_o,

    // Diagnostic snapshot outputs (consumed by bpu.sv counters/pred_snap).
    output logic       dbg_snap_ftb_cond_hit_o,
    output logic       dbg_snap_ftb_jump_hit_o,
    output logic       dbg_snap_ftb_cond_tag_miss_o,
    output logic       dbg_snap_ftb_jump_tag_miss_o,
    output logic       dbg_snap_ftb_any_valid_o,
    output logic       dbg_snap_ftb_tag_hit_o,
    output logic [2:0] dbg_snap_ftb_valid_count_o,
    output logic [2:0] dbg_snap_ftb_cond_count_o,
    output logic [2:0] dbg_snap_ftb_jump_count_o,
    output logic [2:0] dbg_snap_ftb_in_range_cond_count_o,
    output logic       dbg_snap_ftb_cond_in_range_o,
    output logic       dbg_snap_ftb_jump_in_range_o
);

  localparam int unsigned SLOT_IDX_W = global_config_pkg::PRED_SLOT_IDX_W;
  localparam int unsigned PRED_SLOT_COUNT = global_config_pkg::PRED_SLOT_COUNT;
  localparam logic [Cfg.PLEN-1:0] BLOCK_ALIGN_MASK = ~(Cfg.PLEN'(Cfg.FETCH_WIDTH - 1));
  localparam int unsigned BTB_IDX_W = (BTB_ENTRIES > 1) ? $clog2(BTB_ENTRIES) : 1;
  localparam int unsigned BLOCK_ADDR_LSB = $clog2(Cfg.FETCH_WIDTH);
  localparam int unsigned BTB_TAG_W = Cfg.PLEN - BTB_IDX_W - BLOCK_ADDR_LSB;
  localparam int unsigned FTB_SLOTS = 4;
  localparam int unsigned FTB_SLOT_IDX_W = (FTB_SLOTS > 1) ? $clog2(FTB_SLOTS) : 1;
  localparam int unsigned FTB_AGE_W = (FTB_SLOTS > 1) ? $clog2(FTB_SLOTS) : 1;
  localparam logic [FTB_AGE_W-1:0] FTB_AGE_MAX = FTB_AGE_W'(FTB_SLOTS - 1);

  // FTB storage：每个 16B fetch block 保留 4 个统一控制流槽，cond/jump 不再分 way。
  logic [BTB_ENTRIES-1:0][BTB_TAG_W-1:0] btb_tag_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_valid_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_is_cond_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_is_rvc_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_is_call_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_is_ret_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0] btb_slot_is_backward_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0][SLOT_IDX_W-1:0] btb_slot_offset_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0][Cfg.PLEN-1:0] btb_slot_target_q;
  logic [BTB_ENTRIES-1:0][FTB_SLOTS-1:0][FTB_AGE_W-1:0] btb_slot_age_q;

  wire [Cfg.PLEN-1:0] pc_reg_q = pc_reg_i;

  logic [Cfg.PLEN-1:0] aligned_base_w;
  logic scan_next_block_w;

  // Scan results (internal mirrors of the module outputs).
  logic [Cfg.PLEN-1:0] cond_branch_pc_w;
  logic [Cfg.PLEN-1:0] jump_branch_pc_w;
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

  // Candidate scan results：cond/jump 各 2 路，lane0 为 in-range 最早（PC 最小）。
  logic [1:0]                  cond_cand_valid_w;
  logic [1:0][Cfg.PLEN-1:0]    cond_cand_pc_w;
  logic [1:0][SLOT_IDX_W-1:0]  cond_cand_end_idx_w;
  logic [1:0]                  cond_cand_is_rvc_w;
  logic [1:0]                  cond_cand_is_backward_w;
  logic [1:0][Cfg.PLEN-1:0]    cond_cand_target_w;
  logic [1:0]                  jump_cand_valid_w;
  logic [1:0][Cfg.PLEN-1:0]    jump_cand_pc_w;
  logic [1:0][SLOT_IDX_W-1:0]  jump_cand_end_idx_w;
  logic [1:0]                  jump_cand_is_rvc_w;
  logic [1:0]                  jump_cand_is_call_w;
  logic [1:0]                  jump_cand_is_ret_w;
  logic [1:0]                  jump_cand_is_indirect_w;
  logic [1:0][Cfg.PLEN-1:0]    jump_cand_target_w;
  logic dbg_snap_ftb_cond_hit_w;
  logic dbg_snap_ftb_jump_hit_w;
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

  function automatic logic [BTB_IDX_W-1:0] btb_index(input logic [Cfg.PLEN-1:0] pc);
    logic [BTB_IDX_W-1:0] pc_idx;
    logic [BTB_IDX_W-1:0] fold_idx;
    begin
      pc_idx = pc[BLOCK_ADDR_LSB +: BTB_IDX_W];
      fold_idx = '0;
      for (int i = BLOCK_ADDR_LSB + BTB_IDX_W; i < Cfg.PLEN; i++) begin
        fold_idx[(i - (BLOCK_ADDR_LSB + BTB_IDX_W)) % BTB_IDX_W] ^= pc[i];
      end
      btb_index = BTB_HASH_ENABLE ? (pc_idx ^ fold_idx) : pc_idx;
    end
  endfunction

  function automatic logic [BTB_TAG_W-1:0] btb_tag(input logic [Cfg.PLEN-1:0] pc);
    btb_tag = pc[Cfg.PLEN-1:BLOCK_ADDR_LSB+BTB_IDX_W];
  endfunction

  // FTB 查询：用 16B 对齐的 block_base 索引 BTB；lookup 扫描 4 个统一 slot。
  assign aligned_base_w = pc_reg_q & BLOCK_ALIGN_MASK;
  assign scan_next_block_w = |pc_reg_q[BLOCK_ADDR_LSB-1:0];

  // FTB 预测：动态 fetch 窗口可能从 16B block 中间开始，因此窗口会跨到下一
  // 个 FTB block。lookup 扫描 fetch block 并导出 in-range 候选；cond 方向与
  // 最终 pick 由 bpu.sv 顶层用 TAGE 完成。内部 legacy pick 仅用于 jump（无条件 taken）。
  always_comb begin
    logic [BTB_IDX_W-1:0] pick_idx;
    logic any_valid;
    logic tag_hit;
    logic cond_hit_any;
    logic jump_hit_any;
    logic cond_in_range_any;
    logic jump_in_range_any;
    logic pick_valid;
    logic [FTB_SLOT_IDX_W-1:0] pick_slot;
    logic [Cfg.PLEN-1:0] pick_branch_pc;
    logic [SLOT_IDX_W-1:0] pick_end_idx;
    logic pick_is_cond;
    logic pick_is_call;
    logic pick_is_ret;
    logic pick_is_rvc;
    logic pick_is_backward;
    logic pick_is_indirect;
    logic cond_snap_set;
    logic jump_snap_set;
    logic [Cfg.PLEN-1:0] cond_snap_pc;
    logic [Cfg.PLEN-1:0] jump_snap_pc;

    cond_hit_any = 1'b0;
    jump_hit_any = 1'b0;
    cond_in_range_any = 1'b0;
    jump_in_range_any = 1'b0;
    dbg_snap_ftb_valid_count_w = '0;
    dbg_snap_ftb_cond_count_w = '0;
    dbg_snap_ftb_jump_count_w = '0;
    dbg_snap_ftb_in_range_cond_count_w = '0;
    pick_valid = 1'b0;
    pick_idx = '0;
    pick_slot = '0;
    pick_branch_pc = '0;
    pick_end_idx = '0;
    pick_is_cond = 1'b0;
    pick_is_call = 1'b0;
    pick_is_ret = 1'b0;
    pick_is_rvc = 1'b0;
    pick_is_backward = 1'b0;
    pick_is_indirect = 1'b0;
    cond_cand_valid_w = '0;
    cond_cand_pc_w = '0;
    cond_cand_end_idx_w = '0;
    cond_cand_is_rvc_w = '0;
    cond_cand_is_backward_w = '0;
    cond_cand_target_w = '0;
    jump_cand_valid_w = '0;
    jump_cand_pc_w = '0;
    jump_cand_end_idx_w = '0;
    jump_cand_is_rvc_w = '0;
    jump_cand_is_call_w = '0;
    jump_cand_is_ret_w = '0;
    jump_cand_is_indirect_w = '0;
    jump_cand_target_w = '0;
    cond_snap_set = 1'b0;
    jump_snap_set = 1'b0;
    cond_snap_pc = aligned_base_w;
    jump_snap_pc = aligned_base_w;
    cond_branch_pc_w = aligned_base_w;
    jump_branch_pc_w = aligned_base_w;
    any_valid = 1'b0;
    tag_hit = 1'b0;
    dbg_snap_ftb_cond_tag_miss_w = 1'b0;
    dbg_snap_ftb_jump_tag_miss_w = 1'b0;

    for (int b = 0; b < 2; b++) begin
      logic scan_block;
      logic [Cfg.PLEN-1:0] lookup_base;
      logic [BTB_IDX_W-1:0] lookup_idx;
      logic [BTB_TAG_W-1:0] lookup_tag;
      logic lookup_any_valid;
      logic lookup_tag_hit;

      scan_block = (b == 0) || scan_next_block_w;
      lookup_base = aligned_base_w + Cfg.PLEN'(b * Cfg.FETCH_WIDTH);
      lookup_idx = btb_index(lookup_base);
      lookup_tag = btb_tag(lookup_base);
      lookup_any_valid = |btb_slot_valid_q[lookup_idx];
      lookup_tag_hit = lookup_any_valid && (btb_tag_q[lookup_idx] == lookup_tag);

      if (scan_block) begin
        any_valid |= lookup_any_valid;
        tag_hit |= lookup_tag_hit;
        if (lookup_any_valid && !lookup_tag_hit) begin
          for (int s = 0; s < FTB_SLOTS; s++) begin
            if (btb_slot_valid_q[lookup_idx][s] && btb_slot_is_cond_q[lookup_idx][s]) begin
              dbg_snap_ftb_cond_tag_miss_w = 1'b1;
            end else if (btb_slot_valid_q[lookup_idx][s]) begin
              dbg_snap_ftb_jump_tag_miss_w = 1'b1;
            end
          end
        end
      end

      for (int s = 0; s < FTB_SLOTS; s++) begin
        logic slot_hit;
        logic slot_in_range;
        logic slot_carry_end;
        logic slot_taken_pred;
        logic [Cfg.PLEN-1:0] slot_pc;
        logic [Cfg.PLEN-1:0] slot_diff;
        logic [Cfg.PLEN-1:0] slot_start_rel;
        logic [Cfg.PLEN-1:0] slot_end_rel;
        logic [SLOT_IDX_W-1:0] slot_end_idx;

        slot_pc = lookup_base + (Cfg.PLEN'(btb_slot_offset_q[lookup_idx][s]) << 1);
        slot_diff = slot_pc - pc_reg_q;
        slot_start_rel = slot_diff >> 1;
        slot_end_rel = slot_start_rel +
                       (btb_slot_is_rvc_q[lookup_idx][s] ? Cfg.PLEN'(0) : Cfg.PLEN'(1));
        slot_hit = scan_block && lookup_tag_hit && btb_slot_valid_q[lookup_idx][s];
        if (slot_hit) begin
          dbg_snap_ftb_valid_count_w = dbg_snap_ftb_valid_count_w + 3'd1;
          if (btb_slot_is_cond_q[lookup_idx][s]) begin
            dbg_snap_ftb_cond_count_w = dbg_snap_ftb_cond_count_w + 3'd1;
          end else begin
            dbg_snap_ftb_jump_count_w = dbg_snap_ftb_jump_count_w + 3'd1;
          end
        end
        slot_carry_end = slot_hit && !btb_slot_is_rvc_q[lookup_idx][s] &&
                         ((slot_pc + Cfg.PLEN'(2)) == pc_reg_q);
        slot_end_idx = slot_carry_end ? '0 : slot_end_rel[SLOT_IDX_W-1:0];
        slot_in_range = slot_hit &&
                        (((slot_pc >= pc_reg_q) &&
                          (slot_end_rel <= Cfg.PLEN'(PRED_SLOT_COUNT - 1))) ||
                         slot_carry_end);
        slot_taken_pred = !btb_slot_is_cond_q[lookup_idx][s];

        if (slot_hit && btb_slot_is_cond_q[lookup_idx][s]) begin
          cond_hit_any = 1'b1;
          if (!cond_snap_set || (slot_pc < cond_snap_pc)) begin
            cond_snap_set = 1'b1;
            cond_snap_pc = slot_pc;
          end
          if (slot_in_range) begin
            cond_in_range_any = 1'b1;
            dbg_snap_ftb_in_range_cond_count_w = dbg_snap_ftb_in_range_cond_count_w + 3'd1;
          end
        end else if (slot_hit) begin
          jump_hit_any = 1'b1;
          if (!jump_snap_set || (slot_pc < jump_snap_pc)) begin
            jump_snap_set = 1'b1;
            jump_snap_pc = slot_pc;
          end
          if (slot_in_range) begin
            jump_in_range_any = 1'b1;
          end
        end

        if (slot_in_range && slot_taken_pred &&
            (!pick_valid || (slot_pc < pick_branch_pc))) begin
          pick_valid = 1'b1;
          pick_idx = lookup_idx;
          pick_slot = FTB_SLOT_IDX_W'(s);
          pick_branch_pc = slot_pc;
          pick_end_idx = slot_end_idx;
        end

        // ---- 候选导出：cond/jump 各保留 2 路 in-range 最早（PC 升序插入）----
        if (slot_in_range && btb_slot_is_cond_q[lookup_idx][s]) begin
          if (!cond_cand_valid_w[0] || (slot_pc < cond_cand_pc_w[0])) begin
            cond_cand_valid_w[1]       = cond_cand_valid_w[0];
            cond_cand_pc_w[1]          = cond_cand_pc_w[0];
            cond_cand_end_idx_w[1]     = cond_cand_end_idx_w[0];
            cond_cand_is_rvc_w[1]      = cond_cand_is_rvc_w[0];
            cond_cand_is_backward_w[1] = cond_cand_is_backward_w[0];
            cond_cand_target_w[1]      = cond_cand_target_w[0];
            cond_cand_valid_w[0]       = 1'b1;
            cond_cand_pc_w[0]          = slot_pc;
            cond_cand_end_idx_w[0]     = slot_end_idx;
            cond_cand_is_rvc_w[0]      = btb_slot_is_rvc_q[lookup_idx][s];
            cond_cand_is_backward_w[0] = btb_slot_is_backward_q[lookup_idx][s];
            cond_cand_target_w[0]      = btb_slot_target_q[lookup_idx][s];
          end else if (!cond_cand_valid_w[1] || (slot_pc < cond_cand_pc_w[1])) begin
            cond_cand_valid_w[1]       = 1'b1;
            cond_cand_pc_w[1]          = slot_pc;
            cond_cand_end_idx_w[1]     = slot_end_idx;
            cond_cand_is_rvc_w[1]      = btb_slot_is_rvc_q[lookup_idx][s];
            cond_cand_is_backward_w[1] = btb_slot_is_backward_q[lookup_idx][s];
            cond_cand_target_w[1]      = btb_slot_target_q[lookup_idx][s];
          end
        end else if (slot_in_range) begin
          if (!jump_cand_valid_w[0] || (slot_pc < jump_cand_pc_w[0])) begin
            jump_cand_valid_w[1]       = jump_cand_valid_w[0];
            jump_cand_pc_w[1]          = jump_cand_pc_w[0];
            jump_cand_end_idx_w[1]     = jump_cand_end_idx_w[0];
            jump_cand_is_rvc_w[1]      = jump_cand_is_rvc_w[0];
            jump_cand_is_call_w[1]     = jump_cand_is_call_w[0];
            jump_cand_is_ret_w[1]      = jump_cand_is_ret_w[0];
            jump_cand_is_indirect_w[1] = jump_cand_is_indirect_w[0];
            jump_cand_target_w[1]      = jump_cand_target_w[0];
            jump_cand_valid_w[0]       = 1'b1;
            jump_cand_pc_w[0]          = slot_pc;
            jump_cand_end_idx_w[0]     = slot_end_idx;
            jump_cand_is_rvc_w[0]      = btb_slot_is_rvc_q[lookup_idx][s];
            jump_cand_is_call_w[0]     = btb_slot_is_call_q[lookup_idx][s];
            jump_cand_is_ret_w[0]      = btb_slot_is_ret_q[lookup_idx][s];
            jump_cand_is_indirect_w[0] = !btb_slot_is_call_q[lookup_idx][s] &&
                                         !btb_slot_is_ret_q[lookup_idx][s];
            jump_cand_target_w[0]      = btb_slot_target_q[lookup_idx][s];
          end else if (!jump_cand_valid_w[1] || (slot_pc < jump_cand_pc_w[1])) begin
            jump_cand_valid_w[1]       = 1'b1;
            jump_cand_pc_w[1]          = slot_pc;
            jump_cand_end_idx_w[1]     = slot_end_idx;
            jump_cand_is_rvc_w[1]      = btb_slot_is_rvc_q[lookup_idx][s];
            jump_cand_is_call_w[1]     = btb_slot_is_call_q[lookup_idx][s];
            jump_cand_is_ret_w[1]      = btb_slot_is_ret_q[lookup_idx][s];
            jump_cand_is_indirect_w[1] = !btb_slot_is_call_q[lookup_idx][s] &&
                                         !btb_slot_is_ret_q[lookup_idx][s];
            jump_cand_target_w[1]      = btb_slot_target_q[lookup_idx][s];
          end
        end
      end
    end

    if (cond_snap_set) begin
      cond_branch_pc_w = cond_snap_pc;
    end
    if (jump_snap_set) begin
      jump_branch_pc_w = jump_snap_pc;
    end
    if (pick_valid && btb_slot_is_cond_q[pick_idx][pick_slot]) begin
      cond_branch_pc_w = pick_branch_pc;
    end
    if (pick_valid && !btb_slot_is_cond_q[pick_idx][pick_slot]) begin
      jump_branch_pc_w = pick_branch_pc;
    end

    pick_is_cond = pick_valid && btb_slot_is_cond_q[pick_idx][pick_slot];
    pick_is_call = pick_valid && !pick_is_cond && btb_slot_is_call_q[pick_idx][pick_slot];
    pick_is_ret = pick_valid && !pick_is_cond && btb_slot_is_ret_q[pick_idx][pick_slot];
    pick_is_rvc = pick_valid && btb_slot_is_rvc_q[pick_idx][pick_slot];
    pick_is_backward = pick_valid && btb_slot_is_backward_q[pick_idx][pick_slot];
    pick_is_indirect = pick_valid && !pick_is_cond && !pick_is_call && !pick_is_ret;
    ftb_pick_valid_w = pick_valid;
    ftb_pick_is_cond_w = pick_is_cond;
    ftb_pick_is_call_w = pick_is_call;
    ftb_pick_is_ret_w = pick_is_ret;
    ftb_pick_is_rvc_w = pick_is_rvc;
    ftb_pick_is_backward_w = pick_is_backward;
    ftb_pick_is_indirect_w = pick_is_indirect;
    ftb_pick_end_idx_w = pick_end_idx;
    ftb_pick_pc_w = pick_valid ? pick_branch_pc : '0;
    ftb_pick_target_w = pick_valid ? btb_slot_target_q[pick_idx][pick_slot] : '0;

    dbg_snap_ftb_cond_hit_w = cond_hit_any;
    dbg_snap_ftb_jump_hit_w = jump_hit_any;
    dbg_snap_ftb_any_valid_w = any_valid;
    dbg_snap_ftb_tag_hit_w = tag_hit;
    dbg_snap_ftb_cond_in_range_w = cond_in_range_any;
    dbg_snap_ftb_jump_in_range_w = jump_in_range_any;
  end

  assign ftb_pick_valid_o = ftb_pick_valid_w;
  assign ftb_pick_is_cond_o = ftb_pick_is_cond_w;
  assign ftb_pick_is_call_o = ftb_pick_is_call_w;
  assign ftb_pick_is_ret_o = ftb_pick_is_ret_w;
  assign ftb_pick_is_rvc_o = ftb_pick_is_rvc_w;
  assign ftb_pick_is_backward_o = ftb_pick_is_backward_w;
  assign ftb_pick_is_indirect_o = ftb_pick_is_indirect_w;
  assign ftb_pick_end_idx_o = ftb_pick_end_idx_w;
  assign ftb_pick_pc_o = ftb_pick_pc_w;
  assign ftb_pick_target_o = ftb_pick_target_w;
  assign cond_cand_valid_o = cond_cand_valid_w;
  assign cond_cand_pc_o = cond_cand_pc_w;
  assign cond_cand_end_idx_o = cond_cand_end_idx_w;
  assign cond_cand_is_rvc_o = cond_cand_is_rvc_w;
  assign cond_cand_is_backward_o = cond_cand_is_backward_w;
  assign cond_cand_target_o = cond_cand_target_w;
  assign jump_cand_valid_o = jump_cand_valid_w;
  assign jump_cand_pc_o = jump_cand_pc_w;
  assign jump_cand_end_idx_o = jump_cand_end_idx_w;
  assign jump_cand_is_rvc_o = jump_cand_is_rvc_w;
  assign jump_cand_is_call_o = jump_cand_is_call_w;
  assign jump_cand_is_ret_o = jump_cand_is_ret_w;
  assign jump_cand_is_indirect_o = jump_cand_is_indirect_w;
  assign jump_cand_target_o = jump_cand_target_w;
  assign cond_branch_pc_o = cond_branch_pc_w;
  assign jump_branch_pc_o = jump_branch_pc_w;
  assign dbg_snap_ftb_cond_hit_o = dbg_snap_ftb_cond_hit_w;
  assign dbg_snap_ftb_jump_hit_o = dbg_snap_ftb_jump_hit_w;
  assign dbg_snap_ftb_cond_tag_miss_o = dbg_snap_ftb_cond_tag_miss_w;
  assign dbg_snap_ftb_jump_tag_miss_o = dbg_snap_ftb_jump_tag_miss_w;
  assign dbg_snap_ftb_any_valid_o = dbg_snap_ftb_any_valid_w;
  assign dbg_snap_ftb_tag_hit_o = dbg_snap_ftb_tag_hit_w;
  assign dbg_snap_ftb_valid_count_o = dbg_snap_ftb_valid_count_w;
  assign dbg_snap_ftb_cond_count_o = dbg_snap_ftb_cond_count_w;
  assign dbg_snap_ftb_jump_count_o = dbg_snap_ftb_jump_count_w;
  assign dbg_snap_ftb_in_range_cond_count_o = dbg_snap_ftb_in_range_cond_count_w;
  assign dbg_snap_ftb_cond_in_range_o = dbg_snap_ftb_cond_in_range_w;
  assign dbg_snap_ftb_jump_in_range_o = dbg_snap_ftb_jump_in_range_w;

  // FTB 训练：BTB 按 16B 对齐 block_base 索引/打 tag；同 offset 更新、空槽插入、否则替换 LRU。
  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      btb_slot_valid_q <= '0;
      btb_slot_is_cond_q <= '0;
      btb_slot_is_rvc_q <= '0;
      btb_slot_is_call_q <= '0;
      btb_slot_is_ret_q <= '0;
      btb_slot_is_backward_q <= '0;
      btb_slot_offset_q <= '0;
      btb_slot_age_q <= '0;
      for (int e = 0; e < BTB_ENTRIES; e++) begin
        btb_tag_q[e] <= '0;
        for (int s = 0; s < FTB_SLOTS; s++) begin
          btb_slot_target_q[e][s] <= '0;
        end
      end
    end else begin
      logic [Cfg.PLEN-1:0] up_block_base;
      logic [BTB_IDX_W-1:0] up_btb_idx;
      logic [BTB_TAG_W-1:0] up_btb_tag;
      logic [SLOT_IDX_W-1:0] up_offset;
      logic up_do_ftb_train;
      logic up_tag_match;
      logic up_slot_found;
      logic up_empty_found;
      logic [FTB_SLOT_IDX_W-1:0] up_alloc_slot;
      logic [FTB_AGE_W-1:0] up_alloc_age;

      if (update_valid_i) begin
        up_block_base = update_pc_i & BLOCK_ALIGN_MASK;
        up_btb_idx = btb_index(up_block_base);
        up_btb_tag = btb_tag(up_block_base);
        up_offset = update_pc_i[SLOT_IDX_W:1];
        up_do_ftb_train = !update_is_cond_i || update_taken_i;
        up_tag_match = (|btb_slot_valid_q[up_btb_idx]) &&
                       (btb_tag_q[up_btb_idx] == up_btb_tag);
        up_slot_found = 1'b0;
        up_empty_found = 1'b0;
        up_alloc_slot = '0;
        up_alloc_age = '0;

        // FTB 4 槽训练：同 offset 更新，否则空槽插入，再否则替换 LRU。
        if (up_do_ftb_train) begin
          if (up_tag_match) begin
            for (int s = 0; s < FTB_SLOTS; s++) begin
              if (btb_slot_valid_q[up_btb_idx][s] &&
                  (btb_slot_offset_q[up_btb_idx][s] == up_offset) &&
                  !up_slot_found) begin
                up_slot_found = 1'b1;
                up_alloc_slot = FTB_SLOT_IDX_W'(s);
                up_alloc_age = btb_slot_age_q[up_btb_idx][s];
              end
            end
            if (!up_slot_found) begin
              for (int s = 0; s < FTB_SLOTS; s++) begin
                if (!btb_slot_valid_q[up_btb_idx][s] && !up_empty_found) begin
                  up_empty_found = 1'b1;
                  up_alloc_slot = FTB_SLOT_IDX_W'(s);
                end
              end
            end
            if (!up_slot_found && !up_empty_found) begin
              for (int s = 0; s < FTB_SLOTS; s++) begin
                if (btb_slot_age_q[up_btb_idx][s] >= up_alloc_age) begin
                  up_alloc_age = btb_slot_age_q[up_btb_idx][s];
                  up_alloc_slot = FTB_SLOT_IDX_W'(s);
                end
              end
            end
          end

          btb_tag_q[up_btb_idx] <= up_btb_tag;
          if (!up_tag_match) begin
            btb_slot_valid_q[up_btb_idx] <= '0;
            btb_slot_age_q[up_btb_idx] <= '0;
          end else begin
            for (int s = 0; s < FTB_SLOTS; s++) begin
              if (btb_slot_valid_q[up_btb_idx][s] &&
                  (FTB_SLOT_IDX_W'(s) != up_alloc_slot)) begin
                if (up_slot_found) begin
                  if (btb_slot_age_q[up_btb_idx][s] < up_alloc_age) begin
                    btb_slot_age_q[up_btb_idx][s] <= btb_slot_age_q[up_btb_idx][s] +
                                                     FTB_AGE_W'(1);
                  end
                end else if (btb_slot_age_q[up_btb_idx][s] != FTB_AGE_MAX) begin
                  btb_slot_age_q[up_btb_idx][s] <= btb_slot_age_q[up_btb_idx][s] +
                                                   FTB_AGE_W'(1);
                end
              end
            end
          end

          btb_slot_valid_q[up_btb_idx][up_alloc_slot] <= 1'b1;
          btb_slot_is_cond_q[up_btb_idx][up_alloc_slot] <= update_is_cond_i;
          btb_slot_is_rvc_q[up_btb_idx][up_alloc_slot] <= update_is_rvc_i;
          btb_slot_is_call_q[up_btb_idx][up_alloc_slot] <= update_is_call_i;
          btb_slot_is_ret_q[up_btb_idx][up_alloc_slot] <= update_is_ret_i;
          btb_slot_is_backward_q[up_btb_idx][up_alloc_slot] <=
              (update_target_i < update_pc_i);
          btb_slot_offset_q[up_btb_idx][up_alloc_slot] <= up_offset;
          btb_slot_target_q[up_btb_idx][up_alloc_slot] <= update_target_i;
          btb_slot_age_q[up_btb_idx][up_alloc_slot] <= '0;
        end
      end
    end
  end

endmodule : bpu_ftb
