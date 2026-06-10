// vsrc/frontend/frontend.sv
import global_config_pkg::*;
import core_contract_pkg::*;

module frontend #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk_i,
    input logic rst_ni,

    // ============================================
    // 1. 后端接口 (ibuffer 出队口 = decode-ready 束)
    // ============================================
    output fe_be_bundle_t fe2be_o,
    input  be2fe_ctrl_if_t be2fe_i,

    // IFetch fault sideband to backend
    output logic       ifetch_fault_valid_o,
    input logic        ifetch_fault_ready_i,
    output logic [Cfg.PLEN-1:0] ifetch_fault_pc_o,
    output logic [Cfg.PLEN-1:0] ifetch_fault_tval_o,
    output logic [4:0] ifetch_fault_cause_o,

    // IFU MMU page walk traffic (to backend dcache mux)
    output logic       pte_req_valid_o,
    input logic        pte_req_ready_i,
    output logic [31:0] pte_req_paddr_o,
    input logic        pte_rsp_valid_i,
    input logic [31:0] pte_rsp_data_i,
    output logic       pte_upd_valid_o,
    input logic        pte_upd_ready_i,
    output logic [31:0] pte_upd_paddr_o,
    output logic [31:0] pte_upd_data_o,

    // ============================================
    // 2. 存储器系统接口 (To Memory/L2/Bus)
    // ============================================
    output logic                                  miss_req_valid_o,
    input  logic                                  miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] miss_req_index_o,

    input  logic                                  refill_valid_i,
    output logic                                  refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] refill_data_i
);

  localparam int unsigned IBUFFER_DEPTH = (Cfg.IBUFFER_DEPTH >= Cfg.INSTR_PER_FETCH) ?
      Cfg.IBUFFER_DEPTH : 16;

  // --- IFU <-> BPU 互联信号 ---
  handshake_t ifu2bpu_handshake;
  handshake_t bpu2ifu_handshake;
  logic [Cfg.PLEN-1:0] ifu2bpu_pc;
  logic [Cfg.PLEN-1:0] bpu2ifu_predicted_pc;
  logic bpu2ifu_pred_slot_valid;
  logic [$clog2(Cfg.INSTR_PER_FETCH)-1:0] bpu2ifu_pred_slot_idx;
  logic [Cfg.PLEN-1:0] bpu2ifu_pred_target;

  ifu_to_bpu_t ifu_to_bpu_struct;
  bpu_to_ifu_t bpu_to_ifu_struct;

  // --- IFU <-> ICache 互联信号 ---
  handshake_t ifu2icache_req_handshake;
  handshake_t icache2ifu_rsp_handshake;
  logic [Cfg.VLEN-1:0] ifu2icache_req_addr;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] icache2ifu_rsp_data;
  logic flush_icache;

  // --- IFU -> aligner -> ibuffer 内部链路（扁平）---
  logic ifu_ibuf_valid;
  logic ifu_ibuf_ready;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ifu_ibuf_data;
  logic [Cfg.PLEN-1:0] ifu_ibuf_pc;
  logic [Cfg.INSTR_PER_FETCH-1:0] ifu_ibuf_slot_valid;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] ifu_ibuf_pred_npc;
  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ifu_ibuf_ftq_id;
  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] ifu_ibuf_fetch_epoch;

  logic [$clog2(FE_EXPAND_MAX + 1)-1:0] aln_entry_count;
  ibuf_entry_t [FE_EXPAND_MAX-1:0] aln_entries;
  logic ibuf_aln_ready;

  assign ifu_to_bpu_struct.pc = ifu2bpu_pc;
  assign bpu2ifu_predicted_pc = bpu_to_ifu_struct.npc;
  assign bpu2ifu_pred_slot_valid = bpu_to_ifu_struct.pred_slot_valid;
  assign bpu2ifu_pred_slot_idx = bpu_to_ifu_struct.pred_slot_idx;
  assign bpu2ifu_pred_target = bpu_to_ifu_struct.pred_slot_target;

  assign fe2be_o.valid = ibuffer_valid_w;
  assign fe2be_o.instrs = ibuffer_instrs_w;
  assign fe2be_o.raw_instrs = ibuffer_raw_instrs_w;
  assign fe2be_o.pcs = ibuffer_pcs_w;
  assign fe2be_o.slot_valid = ibuffer_slot_valid_w;
  assign fe2be_o.pred_npc = ibuffer_pred_npc_w;
  assign fe2be_o.is_rvc = ibuffer_is_rvc_w;
  assign fe2be_o.ftq_id = ibuffer_ftq_id_w;
  assign fe2be_o.fetch_epoch = ibuffer_fetch_epoch_w;

  logic ibuffer_valid_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ibuffer_instrs_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ibuffer_raw_instrs_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] ibuffer_pcs_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] ibuffer_slot_valid_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] ibuffer_pred_npc_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] ibuffer_is_rvc_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ibuffer_ftq_id_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] ibuffer_fetch_epoch_w;
  logic ibuffer_ready_w;

  assign ibuffer_ready_w = fe2be_o.ready;

  ifu #(
      .Cfg(Cfg)
  ) i_ifu (
      .clk(clk_i),
      .rst(~rst_ni),

      .ifu2bpu_handshake_o   (ifu2bpu_handshake),
      .bpu2ifu_handshake_i   (bpu2ifu_handshake),
      .ifu2bpu_pc_o          (ifu2bpu_pc),
      .bpu2ifu_predicted_pc_i(bpu2ifu_predicted_pc),
      .bpu2ifu_pred_slot_valid_i(bpu2ifu_pred_slot_valid),
      .bpu2ifu_pred_slot_idx_i(bpu2ifu_pred_slot_idx),
      .bpu2ifu_pred_target_i(bpu2ifu_pred_target),

      .ifu2icache_req_handshake_o(ifu2icache_req_handshake),
      .icache2ifu_rsp_handshake_i(icache2ifu_rsp_handshake),
      .ifu2icache_req_addr_o     (ifu2icache_req_addr),
      .icache2ifu_rsp_data_i     (icache2ifu_rsp_data),
      .flush_icache_o            (flush_icache),

      .ifu_ibuffer_rsp_valid_o(ifu_ibuf_valid),
      .ifu_ibuffer_rsp_pc_o   (ifu_ibuf_pc),
      .ibuffer_ifu_rsp_ready_i(ifu_ibuf_ready),
      .ifu_ibuffer_rsp_data_o (ifu_ibuf_data),
      .ifu_ibuffer_rsp_slot_valid_o(ifu_ibuf_slot_valid),
      .ifu_ibuffer_rsp_pred_npc_o(ifu_ibuf_pred_npc),
      .ifu_ibuffer_rsp_ftq_id_o(ifu_ibuf_ftq_id),
      .ifu_ibuffer_rsp_fetch_epoch_o(ifu_ibuf_fetch_epoch),

      .flush_i      (be2fe_i.flush),
      .redirect_pc_i(be2fe_i.redirect_pc),

      .mmu_satp_i(be2fe_i.mmu_satp),
      .mmu_priv_i(be2fe_i.mmu_priv),
      .mmu_sum_i(be2fe_i.mmu_sum),
      .mmu_mxr_i(be2fe_i.mmu_mxr),
      .mmu_sfence_vma_i(be2fe_i.mmu_sfence_vma),
      .pte_req_valid_o(pte_req_valid_o),
      .pte_req_ready_i(pte_req_ready_i),
      .pte_req_paddr_o(pte_req_paddr_o),
      .pte_rsp_valid_i(pte_rsp_valid_i),
      .pte_rsp_data_i(pte_rsp_data_i),
      .pte_upd_valid_o(pte_upd_valid_o),
      .pte_upd_ready_i(pte_upd_ready_i),
      .pte_upd_paddr_o(pte_upd_paddr_o),
      .pte_upd_data_o(pte_upd_data_o),
      .ifetch_fault_valid_o(ifetch_fault_valid_o),
      .ifetch_fault_ready_i(ifetch_fault_ready_i),
      .ifetch_fault_pc_o(ifetch_fault_pc_o),
      .ifetch_fault_tval_o(ifetch_fault_tval_o),
      .ifetch_fault_cause_o(ifetch_fault_cause_o)
  );

  instr_aligner #(
      .Cfg(Cfg)
  ) i_instr_aligner (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .flush_i(be2fe_i.flush),

      .fe_valid_i(ifu_ibuf_valid),
      .fe_ready_o(ifu_ibuf_ready),
      .fe_instrs_i(ifu_ibuf_data),
      .fe_pc_i(ifu_ibuf_pc),
      .fe_slot_valid_i(ifu_ibuf_slot_valid),
      .fe_pred_npc_i(ifu_ibuf_pred_npc),
      .fe_ftq_id_i(ifu_ibuf_ftq_id),
      .fe_fetch_epoch_i(ifu_ibuf_fetch_epoch),
      .ibuf_aln_ready_i(ibuf_aln_ready),

      .aln_entry_count_o(aln_entry_count),
      .aln_entries_o(aln_entries)
  );

  ibuffer #(
      .Cfg(Cfg),
      .IB_DEPTH(IBUFFER_DEPTH),
      .DECODE_WIDTH(Cfg.INSTR_PER_FETCH)
  ) i_ibuffer (
      .clk_i(clk_i),
      .rst_ni(rst_ni),

      .aln_valid_i(ifu_ibuf_valid),
      .aln_ready_o(ibuf_aln_ready),
      .aln_entries_i(aln_entries),
      .aln_entry_count_i(aln_entry_count),

      .ibuf_valid_o(ibuffer_valid_w),
      .ibuf_ready_i(ibuffer_ready_w),
      .ibuf_instrs_o(ibuffer_instrs_w),
      .ibuf_raw_instrs_o(ibuffer_raw_instrs_w),
      .ibuf_pcs_o(ibuffer_pcs_w),
      .ibuf_slot_valid_o(ibuffer_slot_valid_w),
      .ibuf_pred_npc_o(ibuffer_pred_npc_w),
      .ibuf_is_rvc_o(ibuffer_is_rvc_w),
      .ibuf_ftq_id_o(ibuffer_ftq_id_w),
      .ibuf_fetch_epoch_o(ibuffer_fetch_epoch_w),

      .flush_i(be2fe_i.flush)
  );

  bpu #(
      .Cfg(Cfg),
      .BTB_ENTRIES(Cfg.BPU_BTB_ENTRIES),
      .BHT_ENTRIES(Cfg.BPU_BHT_ENTRIES),
      .RAS_DEPTH(Cfg.BPU_RAS_DEPTH),
      .USE_GSHARE(Cfg.BPU_USE_GSHARE != 0),
      .USE_TAGE(Cfg.BPU_USE_TAGE != 0),
      .USE_SC_L(Cfg.BPU_USE_SC_L != 0),
      .USE_TOURNAMENT(Cfg.BPU_USE_TOURNAMENT != 0),
      .BTB_HASH_ENABLE(Cfg.BPU_BTB_HASH_ENABLE != 0),
      .BHT_HASH_ENABLE(Cfg.BPU_BHT_HASH_ENABLE != 0),
      .GHR_BITS(Cfg.BPU_GHR_BITS),
      .SC_L_ENTRIES(Cfg.BPU_SC_L_ENTRIES),
      .SC_L_CONF_THRESH(Cfg.BPU_SC_L_CONF_THRESH),
      .SC_L_REQUIRE_DISAGREE(Cfg.BPU_SC_L_REQUIRE_DISAGREE != 0),
      .SC_L_REQUIRE_BOTH_WEAK(Cfg.BPU_SC_L_REQUIRE_BOTH_WEAK != 0),
      .SC_L_BLOCK_ON_TAGE_HIT(Cfg.BPU_SC_L_BLOCK_ON_TAGE_HIT != 0),
      .USE_LOOP(Cfg.BPU_USE_LOOP != 0),
      .LOOP_ENTRIES(Cfg.BPU_LOOP_ENTRIES),
      .LOOP_TAG_BITS(Cfg.BPU_LOOP_TAG_BITS),
      .LOOP_CONF_THRESH(Cfg.BPU_LOOP_CONF_THRESH),
      .USE_ITTAGE(Cfg.BPU_USE_ITTAGE != 0),
      .ITTAGE_ENTRIES(Cfg.BPU_ITTAGE_ENTRIES),
      .ITTAGE_TAG_BITS(Cfg.BPU_ITTAGE_TAG_BITS),
      .TAGE_OVERRIDE_MIN_PROVIDER(Cfg.BPU_TAGE_OVERRIDE_MIN_PROVIDER),
      .TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK(Cfg.BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK != 0),
      .TAGE_TAG_BITS(Cfg.BPU_TAGE_TAG_BITS),
      .TAGE_HIST_LEN0(Cfg.BPU_TAGE_HIST_LEN0),
      .TAGE_HIST_LEN1(Cfg.BPU_TAGE_HIST_LEN1),
      .TAGE_HIST_LEN2(Cfg.BPU_TAGE_HIST_LEN2),
      .TAGE_HIST_LEN3(Cfg.BPU_TAGE_HIST_LEN3),
      .PATH_HIST_BITS(Cfg.BPU_PATH_HIST_BITS),
      .TRACK_DEPTH(Cfg.BPU_TRACK_DEPTH)
  ) i_bpu (
      .clk_i(clk_i),
      .rst_i(~rst_ni),

      .ifu_to_bpu_i          (ifu_to_bpu_struct),
      .ifu_to_bpu_handshake_i(ifu2bpu_handshake),
      .update_valid_i        (be2fe_i.bpu_update_valid),
      .update_pc_i           (be2fe_i.bpu_update_pc),
      .update_is_cond_i      (be2fe_i.bpu_update_is_cond),
      .update_taken_i        (be2fe_i.bpu_update_taken),
      .update_target_i       (be2fe_i.bpu_update_target),
      .update_is_call_i      (be2fe_i.bpu_update_is_call),
      .update_is_ret_i       (be2fe_i.bpu_update_is_ret),
      .update_is_rvc_i       (be2fe_i.bpu_update_is_rvc),
      .ras_update_valid_i    (be2fe_i.bpu_ras_update_valid),
      .ras_update_is_call_i  (be2fe_i.bpu_ras_update_is_call),
      .ras_update_is_ret_i   (be2fe_i.bpu_ras_update_is_ret),
      .ras_update_is_rvc_i   (be2fe_i.bpu_ras_update_is_rvc),
      .ras_update_pc_i       (be2fe_i.bpu_ras_update_pc),
      .flush_i               (be2fe_i.flush),
      .bpu_to_ifu_handshake_o(bpu2ifu_handshake),
      .bpu_to_ifu_o          (bpu_to_ifu_struct)
  );

  icache #(
      .Cfg(Cfg),
      .HIT_PIPELINE_EN(Cfg.ICACHE_HIT_PIPELINE_EN != 0)
  ) i_icache (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .ifu_req_handshake_i(ifu2icache_req_handshake),
      .ifu_rsp_handshake_o(icache2ifu_rsp_handshake),
      .ifu_req_pc_i       (ifu2icache_req_addr),
      .ifu_rsp_instrs_o   (icache2ifu_rsp_data),
      .ifu_req_flush_i    (flush_icache),

      .miss_req_valid_o     (miss_req_valid_o),
      .miss_req_ready_i     (miss_req_ready_i),
      .miss_req_paddr_o     (miss_req_paddr_o),
      .miss_req_victim_way_o(miss_req_victim_way_o),
      .miss_req_index_o     (miss_req_index_o),

      .refill_valid_i(refill_valid_i),
      .refill_ready_o(refill_ready_o),
      .refill_paddr_i(refill_paddr_i),
      .refill_way_i  (refill_way_i),
      .refill_data_i (refill_data_i)
  );

endmodule : frontend
