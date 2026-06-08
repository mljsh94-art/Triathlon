import config_pkg::*;
import decode_pkg::*;
import core_contract_pkg::*;

module backend #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk_i,
    input logic rst_ni,
    input logic timer_irq_i,
    input logic ext_irq_i,
    input logic flush_from_backend,
    input logic frontend_ibuf_valid,
    output logic frontend_ibuf_ready,
    input logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] frontend_ibuf_instrs,
    input logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] frontend_ibuf_raw_instrs,
    input logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] frontend_ibuf_pcs,
    input logic [Cfg.INSTR_PER_FETCH-1:0] frontend_ibuf_slot_valid,
    input logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] frontend_ibuf_pred_npc,
    input logic [Cfg.INSTR_PER_FETCH-1:0] frontend_ibuf_is_rvc,
    input logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.FTQ_DEPTH >= 2) ? $clog2(Cfg.FTQ_DEPTH) : 1)-1:0] frontend_ibuf_ftq_id,
    input logic [Cfg.INSTR_PER_FETCH-1:0][2:0] frontend_ibuf_fetch_epoch,
    // Redirect/flush to frontend
    output logic backend_flush_o,
    output logic [Cfg.PLEN-1:0] backend_redirect_pc_o,
    output logic bpu_update_valid_o,
    output logic [Cfg.PLEN-1:0] bpu_update_pc_o,
    output logic bpu_update_is_cond_o,
    output logic bpu_update_taken_o,
    output logic [Cfg.PLEN-1:0] bpu_update_target_o,
    output logic bpu_update_is_call_o,
    output logic bpu_update_is_ret_o,
    output logic bpu_update_is_rvc_o,
    output logic [Cfg.NRET-1:0] bpu_ras_update_valid_o,
    output logic [Cfg.NRET-1:0] bpu_ras_update_is_call_o,
    output logic [Cfg.NRET-1:0] bpu_ras_update_is_ret_o,
    output logic [Cfg.NRET-1:0] bpu_ras_update_is_rvc_o,
    output logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] bpu_ras_update_pc_o,
    output logic [31:0] mmu_satp_o,
    output logic [1:0] mmu_priv_o,
    output logic mmu_sum_o,
    output logic mmu_mxr_o,
    output logic mmu_sfence_vma_o,
    input logic ifu_pte_ld_req_valid_i,
    output logic ifu_pte_ld_req_ready_o,
    input logic [31:0] ifu_pte_ld_req_paddr_i,
    output logic ifu_pte_ld_rsp_valid_o,
    output logic [31:0] ifu_pte_ld_rsp_data_o,
    input logic ifu_pte_st_req_valid_i,
    output logic ifu_pte_st_req_ready_o,
    input logic [31:0] ifu_pte_st_req_paddr_i,
    input logic [31:0] ifu_pte_st_req_data_i,
    input logic ifetch_fault_valid_i,
    output logic ifetch_fault_ready_o,
    input logic [Cfg.PLEN-1:0] ifetch_fault_pc_i,
    input logic [Cfg.PLEN-1:0] ifetch_fault_tval_i,
    input logic [4:0] ifetch_fault_cause_i,

    // D-Cache miss/refill/writeback interface (to memory system)
    output logic                                  dcache_miss_req_valid_o,
    input  logic                                  dcache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] dcache_miss_req_paddr_o,
    output logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_miss_req_victim_way_o,
    output logic [    Cfg.DCACHE_INDEX_WIDTH-1:0] dcache_miss_req_index_o,

    input  logic                                  dcache_refill_valid_i,
    output logic                                  dcache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] dcache_refill_paddr_i,
    input  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_refill_way_i,
    input  logic [     Cfg.DCACHE_LINE_WIDTH-1:0] dcache_refill_data_i,

    output logic                             dcache_wb_req_valid_o,
    input  logic                             dcache_wb_req_ready_i,
    output logic [             Cfg.PLEN-1:0] dcache_wb_req_paddr_o,
    output logic [Cfg.DCACHE_LINE_WIDTH-1:0] dcache_wb_req_data_o,

    // MMIO Uncached Load interface (bypass D-Cache)
    output logic                               mmio_req_valid_o,
    input  logic                               mmio_req_ready_i,
    output logic [             Cfg.PLEN-1:0]   mmio_req_addr_o,
    output decode_pkg::lsu_op_e                mmio_req_op_o,

    input  logic                               mmio_rsp_valid_i,
    input  logic [           Cfg.XLEN-1:0]     mmio_rsp_data_i
);

  localparam int unsigned DISPATCH_WIDTH = Cfg.INSTR_PER_FETCH;
  localparam int unsigned COMMIT_WIDTH = Cfg.NRET;
  localparam int unsigned ROB_DEPTH = (Cfg.ROB_DEPTH >= DISPATCH_WIDTH) ? Cfg.ROB_DEPTH : 64;
  localparam int unsigned ROB_IDX_WIDTH = $clog2(ROB_DEPTH);
  localparam int unsigned SB_DEPTH = (Cfg.SB_DEPTH >= 4) ? Cfg.SB_DEPTH : 16;
  localparam int unsigned SB_IDX_WIDTH = $clog2(SB_DEPTH);
  localparam int unsigned RS_DEPTH = Cfg.RS_DEPTH;
  localparam int unsigned WB_WIDTH = 7;
  localparam int unsigned NUM_FUS = 7;  // ALU0, ALU1, BRU, LSU, ALU2, ALU3, CSR
  localparam int unsigned LSU_GROUP_SIZE = (Cfg.LSU_GROUP_SIZE >= 1) ? Cfg.LSU_GROUP_SIZE : 1;
  localparam int unsigned LSU_LD_ID_WIDTH = (LSU_GROUP_SIZE <= 1) ? 1 : $clog2(LSU_GROUP_SIZE);
  localparam int unsigned DCACHE_LD_ID_WIDTH = LSU_LD_ID_WIDTH + 1;
  localparam int unsigned DCACHE_MSHR_SIZE = (Cfg.DCACHE_MSHR_SIZE >= 1) ? Cfg.DCACHE_MSHR_SIZE : 1;
  localparam int unsigned RENAME_PENDING_DEPTH_CFG = (Cfg.RENAME_PENDING_DEPTH > 0) ? Cfg.RENAME_PENDING_DEPTH :
      (DISPATCH_WIDTH * 2);
  localparam int unsigned RENAME_PENDING_DEPTH = (RENAME_PENDING_DEPTH_CFG >= DISPATCH_WIDTH) ?
      RENAME_PENDING_DEPTH_CFG : DISPATCH_WIDTH;
  localparam int unsigned RENAME_PENDING_CNT_W = $clog2(RENAME_PENDING_DEPTH + 1);
  localparam int unsigned FTQ_ID_W = decode_pkg::FTQ_ID_W;
  localparam int unsigned FETCH_EPOCH_W = decode_pkg::FETCH_EPOCH_W;
  localparam int unsigned COMMIT_SEL_W = (COMMIT_WIDTH > 1) ? $clog2(COMMIT_WIDTH) : 1;
  localparam int unsigned ROB_MAX_COMMIT_BR = (Cfg.ROB_MAX_COMMIT_BR >= 1) ? Cfg.ROB_MAX_COMMIT_BR : 1;
  localparam int unsigned ROB_MAX_COMMIT_ST = (Cfg.ROB_MAX_COMMIT_ST >= 1) ? Cfg.ROB_MAX_COMMIT_ST : 1;
  localparam int unsigned ROB_MAX_COMMIT_LD = (Cfg.ROB_MAX_COMMIT_LD >= 1) ? Cfg.ROB_MAX_COMMIT_LD : 2;
  localparam int unsigned LSU_LQ_DEPTH = (Cfg.ROB_DEPTH >= 16) ? 16 : Cfg.ROB_DEPTH;
  localparam int unsigned LSU_SQ_DEPTH = (Cfg.SB_DEPTH >= 16) ? 16 : Cfg.SB_DEPTH;
  localparam int unsigned MEM_DEP_STORE_DEPTH = 8;
  localparam int unsigned COMPLETION_Q_DEPTH = 32;
  // A2.2: 开启 commit-time call/ret 更新，配合 BPU speculative RAS 降低 return miss。
  localparam bit ENABLE_COMMIT_RAS_UPDATE = (Cfg.ENABLE_COMMIT_RAS_UPDATE != 0);
  fe_be_bundle_t frontend_ibuf_bus;

  assign frontend_ibuf_bus.valid = frontend_ibuf_valid;
  assign frontend_ibuf_bus.ready = frontend_ibuf_ready;
  assign frontend_ibuf_bus.instrs = frontend_ibuf_instrs;
  assign frontend_ibuf_bus.raw_instrs = frontend_ibuf_raw_instrs;
  assign frontend_ibuf_bus.pcs = frontend_ibuf_pcs;
  assign frontend_ibuf_bus.slot_valid = frontend_ibuf_slot_valid;
  assign frontend_ibuf_bus.pred_npc = frontend_ibuf_pred_npc;
  assign frontend_ibuf_bus.is_rvc = frontend_ibuf_is_rvc;
  assign frontend_ibuf_bus.ftq_id = frontend_ibuf_ftq_id;
  assign frontend_ibuf_bus.fetch_epoch = frontend_ibuf_fetch_epoch;

  generate
    if (Cfg.ROB_DEPTH < DISPATCH_WIDTH) begin : g_cfg_invalid_rob_depth
      initial begin
        $fatal(1, "backend config error: ROB_DEPTH(%0d) < INSTR_PER_FETCH(%0d)",
               Cfg.ROB_DEPTH, DISPATCH_WIDTH);
      end
    end
    if (Cfg.LSU_GROUP_SIZE < 1) begin : g_cfg_invalid_lsu_group_size
      initial begin
        $fatal(1, "backend config error: LSU_GROUP_SIZE(%0d) must be >= 1",
               Cfg.LSU_GROUP_SIZE);
      end
    end
    if (Cfg.SB_DEPTH < 4) begin : g_cfg_invalid_sb_depth
      initial begin
        $fatal(1, "backend config error: SB_DEPTH(%0d) must be >= 4", Cfg.SB_DEPTH);
      end
    end
    if (Cfg.IBUFFER_DEPTH < DISPATCH_WIDTH) begin : g_cfg_invalid_ibuf_depth
      initial begin
        $fatal(1, "backend config error: IBUFFER_DEPTH(%0d) < INSTR_PER_FETCH(%0d)",
               Cfg.IBUFFER_DEPTH, DISPATCH_WIDTH);
      end
    end
  endgenerate

  // =========================================================
  // Decode (fe→be decode-ready 束 → uops)
  // =========================================================
  logic backend_flush;
  logic dec_valid;
  logic [DISPATCH_WIDTH-1:0] dec_slot_valid;
  decode_pkg::uop_t [DISPATCH_WIDTH-1:0] dec_uops;
  logic decode_backend_ready;

  decoder #(
      .Cfg(Cfg),
      .DECODE_WIDTH(DISPATCH_WIDTH)
  ) u_decoder (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .ibuf2dec_valid_i (frontend_ibuf_valid),
      .dec2ibuf_ready_o (frontend_ibuf_ready),
      .ibuf_instrs_i    (frontend_ibuf_instrs),
      .ibuf_raw_instrs_i(frontend_ibuf_raw_instrs),
      .ibuf_pcs_i       (frontend_ibuf_pcs),
      .ibuf_slot_valid_i(frontend_ibuf_slot_valid),
      .ibuf_pred_npc_i  (frontend_ibuf_pred_npc),
      .ibuf_is_rvc_i    (frontend_ibuf_is_rvc),
      .ibuf_ftq_id_i    (frontend_ibuf_ftq_id),
      .ibuf_fetch_epoch_i(frontend_ibuf_fetch_epoch),

      .dec2backend_valid_o(dec_valid),
      .backend2dec_ready_i(decode_backend_ready),
      .dec_slot_valid_o   (dec_slot_valid),
      .dec_uops_o         (dec_uops)
  );

  // =========================================================
  // ROB
  // =========================================================
  logic                                           rob_ready;
  logic [  DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] rob_dispatch_rob_index;

  logic [    COMMIT_WIDTH-1:0]                    commit_valid;
  logic [    COMMIT_WIDTH-1:0][     Cfg.PLEN-1:0] commit_pc;
  logic [    COMMIT_WIDTH-1:0][     Cfg.ILEN-1:0] commit_inst;
  logic [    COMMIT_WIDTH-1:0][     Cfg.ILEN-1:0] commit_decoded_inst;
  logic [    COMMIT_WIDTH-1:0]                    commit_we;
  logic [    COMMIT_WIDTH-1:0][              4:0] commit_areg;
  logic [    COMMIT_WIDTH-1:0][     Cfg.XLEN-1:0] commit_wdata;
  logic [    COMMIT_WIDTH-1:0][ROB_IDX_WIDTH-1:0] commit_rob_index;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_store;
  logic [    COMMIT_WIDTH-1:0][ SB_IDX_WIDTH-1:0] commit_sb_id;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_branch;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_jump;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_call;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_ret;
  logic [    COMMIT_WIDTH-1:0]                    commit_is_rvc;
  logic [    COMMIT_WIDTH-1:0][     Cfg.PLEN-1:0] commit_actual_npc;
  logic [    COMMIT_WIDTH-1:0][    FTQ_ID_W-1:0]  commit_ftq_id;
  logic [    COMMIT_WIDTH-1:0][FETCH_EPOCH_W-1:0] commit_fetch_epoch;

  logic                                           rob_flush;
  logic [        Cfg.PLEN-1:0]                    rob_flush_pc;
  logic [                 4:0]                    rob_flush_cause;
  logic                                           rob_flush_is_mispred;
  logic                                           rob_flush_is_exception;
  logic                                           rob_flush_is_branch;
  logic                                           rob_flush_is_jump;
  logic [        Cfg.PLEN-1:0]                    rob_flush_src_pc;
  logic                                           csr_irq_trap;
  logic [                 4:0]                    csr_irq_trap_cause;
  logic [        Cfg.PLEN-1:0]                    csr_irq_trap_pc;
  logic [        Cfg.PLEN-1:0]                    csr_irq_trap_redirect_pc;
  logic                                           rob_sync_exception_valid;
  logic [                 4:0]                    rob_sync_exception_cause;
  logic [        Cfg.PLEN-1:0]                    rob_sync_exception_pc;
  logic [        Cfg.PLEN-1:0]                    rob_sync_exception_tval;
  logic                                           rob_sync_exception_pending_q;
  logic [                 4:0]                    rob_sync_exception_cause_q;
  logic [        Cfg.PLEN-1:0]                    rob_sync_exception_pc_q;
  logic [        Cfg.PLEN-1:0]                    rob_sync_exception_tval_q;
  logic [            FTQ_ID_W-1:0]                bpu_update_ftq_id_dbg;
  logic [       FETCH_EPOCH_W-1:0]                bpu_update_fetch_epoch_dbg;
  logic [         COMMIT_SEL_W-1:0]               bpu_update_sel_idx_dbg;
  logic [        Cfg.PLEN-1:0]                    retire_redirect_pc_dbg;

  // ROB operand query (late subscription fix)
  logic [DISPATCH_WIDTH*2-1:0][ROB_IDX_WIDTH-1:0] rob_query_idx;
  logic [DISPATCH_WIDTH*2-1:0]                    rob_query_ready;
  logic [DISPATCH_WIDTH*2-1:0][     Cfg.XLEN-1:0] rob_query_data;
  logic [DISPATCH_WIDTH*2-1:0][FETCH_EPOCH_W-1:0] rob_query_fetch_epoch;
  logic [DISPATCH_WIDTH*2-1:0][     Cfg.PLEN-1:0] rob_query_pc;
  logic [   ROB_IDX_WIDTH-1:0]                    rob_head_ptr;
  logic                                           rob_empty;
  logic [        Cfg.PLEN-1:0]                    rob_head_pc;

  rob #(
      .Cfg(Cfg),
      .ROB_DEPTH(ROB_DEPTH),
      .DISPATCH_WIDTH(DISPATCH_WIDTH),
      .COMMIT_WIDTH(COMMIT_WIDTH),
      .WB_WIDTH(WB_WIDTH),
      .QUERY_WIDTH(DISPATCH_WIDTH * 2),
      .SB_DEPTH(SB_DEPTH),
      .MAX_COMMIT_BR(ROB_MAX_COMMIT_BR),
      .MAX_COMMIT_ST(ROB_MAX_COMMIT_ST),
      .MAX_COMMIT_LD(ROB_MAX_COMMIT_LD)
  ) u_rob (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .flush_i(flush_from_backend),

      .dispatch_valid_i(rob_dispatch_valid),
      .dispatch_pc_i   (rob_dispatch_pc),
      .dispatch_inst_i (rob_dispatch_inst),
      .dispatch_decoded_inst_i(rob_dispatch_decoded_inst),
      .dispatch_fu_type_i(rob_dispatch_fu_type),
      .dispatch_areg_i (rob_dispatch_areg),
      .dispatch_has_rd_i(rob_dispatch_has_rd),
      .dispatch_is_branch_i(rob_dispatch_is_branch),
      .dispatch_is_jump_i(rob_dispatch_is_jump),
      .dispatch_is_call_i(rob_dispatch_is_call),
      .dispatch_is_ret_i(rob_dispatch_is_ret),
      .dispatch_is_rvc_i(rob_dispatch_is_rvc),
      .dispatch_ftq_id_i(rob_dispatch_ftq_id),
      .dispatch_fetch_epoch_i(rob_dispatch_fetch_epoch),
      .dispatch_is_store_i(rob_dispatch_is_store),
      .dispatch_sb_id_i(rob_dispatch_sb_id),

      .rob_ready_o(rob_ready),
      .dispatch_rob_index_o(rob_dispatch_rob_index),

      .wb_valid_i      (wb_valid),
      .wb_rob_index_i  (wb_rob_idx),
      .wb_data_i       (wb_data),
      .wb_exception_i  (wb_exception),
      .wb_ecause_i     (wb_ecause),
      .wb_is_mispred_i (wb_is_mispred),
      .wb_redirect_pc_i(wb_redirect_pc),
      .async_exception_valid_i(csr_irq_trap),
      .async_exception_cause_i(csr_irq_trap_cause),
      .async_exception_pc_i(csr_irq_trap_pc),
      .async_exception_redirect_pc_i(csr_irq_trap_redirect_pc),
      .fast_alu_valid_i({alu3_wb_valid, alu2_wb_valid, alu1_wb_valid, alu0_wb_valid}),
      .fast_alu_rob_idx_i({alu3_wb_tag, alu2_wb_tag, alu1_wb_tag, alu0_wb_tag}),
      .fast_alu_data_i({alu3_wb_data, alu2_wb_data, alu1_wb_data, alu0_wb_data}),
      .fast_alu_is_mispred_i({alu3_mispred, alu2_mispred, alu1_mispred, alu0_mispred}),
      .fast_alu_redirect_pc_i({alu3_redirect_pc, alu2_redirect_pc, alu1_redirect_pc, alu0_redirect_pc}),
      .fast_bru_valid_i(bru_wb_valid),
      .fast_bru_rob_idx_i(bru_wb_tag),
      .fast_bru_data_i(bru_wb_data),
      .fast_bru_redirect_pc_i(bru_redirect_pc),
      .fast_bru_can_commit_i(bru_wb_valid && !bru_mispred),

      .commit_valid_o     (commit_valid),
      .commit_pc_o        (commit_pc),
      .commit_inst_o      (commit_inst),
      .commit_decoded_inst_o(commit_decoded_inst),
      .commit_we_o        (commit_we),
      .commit_areg_o      (commit_areg),
      .commit_wdata_o     (commit_wdata),
      .commit_rob_index_o (commit_rob_index),
      .commit_is_store_o  (commit_is_store),
      .commit_sb_id_o     (commit_sb_id),
      .commit_is_branch_o (commit_is_branch),
      .commit_is_jump_o   (commit_is_jump),
      .commit_is_call_o   (commit_is_call),
      .commit_is_ret_o    (commit_is_ret),
      .commit_is_rvc_o    (commit_is_rvc),
      .commit_actual_npc_o(commit_actual_npc),
      .commit_ftq_id_o(commit_ftq_id),
      .commit_fetch_epoch_o(commit_fetch_epoch),

      .flush_o             (rob_flush),
      .flush_pc_o          (rob_flush_pc),
      .flush_cause_o       (rob_flush_cause),
      .flush_is_mispred_o  (rob_flush_is_mispred),
      .flush_is_exception_o(rob_flush_is_exception),
      .flush_is_branch_o   (rob_flush_is_branch),
      .flush_is_jump_o     (rob_flush_is_jump),
      .flush_src_pc_o      (rob_flush_src_pc),
      .sync_exception_valid_o(rob_sync_exception_valid),
      .sync_exception_cause_o(rob_sync_exception_cause),
      .sync_exception_pc_o(rob_sync_exception_pc),
      .sync_exception_tval_o(rob_sync_exception_tval),

      .query_rob_idx_i(rob_query_idx),
      .query_ready_o  (rob_query_ready),
      .query_data_o   (rob_query_data),
      .query_fetch_epoch_o(rob_query_fetch_epoch),
      .query_pc_o     (rob_query_pc),

      .rob_empty_o(rob_empty),
      .rob_full_o (),
      .rob_head_o (rob_head_ptr),
      .rob_head_pc_o(rob_head_pc)
  );

  retire_redirect_ctrl #(
      .Cfg(Cfg),
      .COMMIT_WIDTH(COMMIT_WIDTH),
      .FTQ_ID_W(FTQ_ID_W),
      .FETCH_EPOCH_W(FETCH_EPOCH_W),
      .COMMIT_SEL_W(COMMIT_SEL_W),
      .ENABLE_COMMIT_RAS_UPDATE(ENABLE_COMMIT_RAS_UPDATE)
  ) u_retire_redirect_ctrl (
      .flush_from_backend_i(flush_from_backend),
      .rob_flush_i(rob_flush),
      .rob_flush_pc_i(rob_flush_pc),

      .commit_valid_i(commit_valid),
      .commit_pc_i(commit_pc),
      .commit_is_branch_i(commit_is_branch),
      .commit_is_jump_i(commit_is_jump),
      .commit_is_call_i(commit_is_call),
      .commit_is_ret_i(commit_is_ret),
      .commit_is_rvc_i(commit_is_rvc),
      .commit_actual_npc_i(commit_actual_npc),
      .commit_ftq_id_i(commit_ftq_id),
      .commit_fetch_epoch_i(commit_fetch_epoch),

      .backend_flush_o(backend_flush),
      .backend_redirect_pc_o(backend_redirect_pc_o),
      .retire_redirect_pc_dbg_o(retire_redirect_pc_dbg),

      .bpu_update_valid_o(bpu_update_valid_o),
      .bpu_update_pc_o(bpu_update_pc_o),
      .bpu_update_is_cond_o(bpu_update_is_cond_o),
      .bpu_update_taken_o(bpu_update_taken_o),
      .bpu_update_target_o(bpu_update_target_o),
      .bpu_update_is_call_o(bpu_update_is_call_o),
      .bpu_update_is_ret_o(bpu_update_is_ret_o),
      .bpu_update_is_rvc_o(bpu_update_is_rvc_o),
      .bpu_update_ftq_id_dbg_o(bpu_update_ftq_id_dbg),
      .bpu_update_fetch_epoch_dbg_o(bpu_update_fetch_epoch_dbg),
      .bpu_update_sel_idx_dbg_o(bpu_update_sel_idx_dbg),

      .bpu_ras_update_valid_o(bpu_ras_update_valid_o),
      .bpu_ras_update_is_call_o(bpu_ras_update_is_call_o),
      .bpu_ras_update_is_ret_o(bpu_ras_update_is_ret_o),
      .bpu_ras_update_is_rvc_o(bpu_ras_update_is_rvc_o),
      .bpu_ras_update_pc_o(bpu_ras_update_pc_o)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rob_sync_exception_pending_q <= 1'b0;
      rob_sync_exception_cause_q <= '0;
      rob_sync_exception_pc_q <= '0;
      rob_sync_exception_tval_q <= '0;
    end else if (backend_flush) begin
      rob_sync_exception_pending_q <= 1'b0;
      rob_sync_exception_cause_q <= '0;
      rob_sync_exception_pc_q <= '0;
      rob_sync_exception_tval_q <= '0;
    end else if (!rob_sync_exception_pending_q && rob_sync_exception_valid) begin
      rob_sync_exception_pending_q <= 1'b1;
      rob_sync_exception_cause_q <= rob_sync_exception_cause;
      rob_sync_exception_pc_q <= rob_sync_exception_pc;
      rob_sync_exception_tval_q <= rob_sync_exception_tval;
    end else if (rob_sync_exception_pending_q && csr_irq_trap) begin
      rob_sync_exception_pending_q <= 1'b0;
      rob_sync_exception_cause_q <= '0;
      rob_sync_exception_pc_q <= '0;
      rob_sync_exception_tval_q <= '0;
    end
  end
  assign backend_flush_o = backend_flush;

`ifndef SYNTHESIS
  localparam logic [Cfg.PLEN-1:0] DBG_PC_RET = 32'hc0803d60;
  localparam logic [Cfg.PLEN-1:0] DBG_PC_FAULT0 = 32'hc0803dae;
  localparam logic [Cfg.PLEN-1:0] DBG_PC_FAULT1 = 32'hc080ab72;
  logic be_trace_en_q;
  initial be_trace_en_q = $test$plusargs("npc_diag_trace");

  always_ff @(posedge clk_i) begin
    if (rst_ni && be_trace_en_q) begin
      for (int i = 0; i < COMMIT_WIDTH; i++) begin
        if (commit_valid[i] &&
            ((commit_pc[i] == DBG_PC_RET) ||
             (commit_pc[i] == DBG_PC_FAULT0) ||
             (commit_pc[i] == DBG_PC_FAULT1))) begin
          $display(
              "[be-commit-watch] pc=%h slot=%0d is_ret=%0d is_br=%0d is_j=%0d actual_npc=%h rob_idx=%0d be_flush=%0d rob_flush=%0d rob_src=%h rob_pc=%h",
              commit_pc[i], i, commit_is_ret[i], commit_is_branch[i], commit_is_jump[i],
              commit_actual_npc[i], commit_rob_index[i], backend_flush, rob_flush, rob_flush_src_pc,
              rob_flush_pc);
        end
      end

      if (rob_flush && (rob_flush_src_pc == DBG_PC_RET)) begin
        $display(
            "[be-flush-watch] rob_flush=%0d backend_flush=%0d src_pc=%h flush_pc=%h mispred=%0d exc=%0d br=%0d j=%0d cause=%0d",
            rob_flush, backend_flush, rob_flush_src_pc, rob_flush_pc, rob_flush_is_mispred,
            rob_flush_is_exception, rob_flush_is_branch, rob_flush_is_jump, rob_flush_cause);
      end
    end
  end
`endif

  // =========================================================
  // Store Buffer (allocation + commit + forwarding)
  // =========================================================
  logic [DISPATCH_WIDTH-1:0] sb_alloc_req;
  logic sb_alloc_ready;
  logic [DISPATCH_WIDTH-1:0][SB_IDX_WIDTH-1:0] sb_alloc_id;
  logic sb_alloc_fire;

  // Store buffer -> D$ store port
  logic sb_dcache_req_valid;
  logic sb_dcache_req_ready;
  logic [Cfg.PLEN-1:0] sb_dcache_req_addr;
  logic [Cfg.XLEN-1:0] sb_dcache_req_data;
  decode_pkg::lsu_op_e sb_dcache_req_op;

  logic [COMMIT_WIDTH-1:0] sb_commit_valid;
  logic [COMMIT_WIDTH-1:0][SB_IDX_WIDTH-1:0] sb_commit_id;

  always_comb begin
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      sb_commit_valid[i] = commit_valid[i] && commit_is_store[i];
      sb_commit_id[i]    = commit_sb_id[i];
    end
  end

  // LSU <-> Store Buffer
  logic sb_ex_valid;
  logic [SB_IDX_WIDTH-1:0] sb_ex_sb_id;
  logic [Cfg.PLEN-1:0] sb_ex_addr;
  logic [Cfg.XLEN-1:0] sb_ex_data;
  decode_pkg::lsu_op_e sb_ex_op;
  logic [ROB_IDX_WIDTH-1:0] sb_ex_rob_idx;

  logic [Cfg.PLEN-1:0] sb_load_addr;
  logic [ROB_IDX_WIDTH-1:0] sb_load_rob_idx;
  logic sb_load_hit;
  logic [Cfg.XLEN-1:0] sb_load_data;

  store_buffer #(
      .SB_DEPTH     (SB_DEPTH),
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .DISPATCH_WIDTH(DISPATCH_WIDTH),
      .COMMIT_WIDTH (COMMIT_WIDTH)
  ) u_sb (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .alloc_req_i(sb_alloc_req),
      .alloc_ready_o(sb_alloc_ready),
      .alloc_id_o(sb_alloc_id),
      .alloc_fire_i(sb_alloc_fire),

      .ex_valid_i  (sb_ex_valid),
      .ex_sb_id_i  (sb_ex_sb_id),
      .ex_addr_i   (sb_ex_addr),
      .ex_data_i   (sb_ex_data),
      .ex_op_i     (sb_ex_op),
      .ex_rob_idx_i(sb_ex_rob_idx),

      .commit_valid_i(sb_commit_valid),
      .commit_sb_id_i(sb_commit_id),

      .dcache_req_valid_o(sb_dcache_req_valid),
      .dcache_req_ready_i(sb_dcache_req_ready),
      .dcache_req_addr_o (sb_dcache_req_addr),
      .dcache_req_data_o (sb_dcache_req_data),
      .dcache_req_op_o   (sb_dcache_req_op),

      .load_addr_i(sb_load_addr),
      .load_rob_idx_i(sb_load_rob_idx),
      .load_hit_o(sb_load_hit),
      .load_data_o(sb_load_data),

      .rob_head_i(rob_head_ptr),

      .flush_i(backend_flush)
  );

  // =========================================================
  // Rename
  // =========================================================
  logic                                                    rename_ready;

  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_valid;
  logic            [DISPATCH_WIDTH-1:0][     Cfg.PLEN-1:0] rob_dispatch_pc;
  logic            [DISPATCH_WIDTH-1:0][     Cfg.ILEN-1:0] rob_dispatch_inst;
  logic            [DISPATCH_WIDTH-1:0][     Cfg.ILEN-1:0] rob_dispatch_decoded_inst;
  decode_pkg::fu_e [DISPATCH_WIDTH-1:0]                    rob_dispatch_fu_type;
  logic            [DISPATCH_WIDTH-1:0][              4:0] rob_dispatch_areg;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_has_rd;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_branch;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_jump;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_call;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_ret;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_rvc;
  logic            [DISPATCH_WIDTH-1:0][    FTQ_ID_W-1:0]  rob_dispatch_ftq_id;
  logic            [DISPATCH_WIDTH-1:0][FETCH_EPOCH_W-1:0] rob_dispatch_fetch_epoch;
  logic            [DISPATCH_WIDTH-1:0]                    rob_dispatch_is_store;
  logic            [DISPATCH_WIDTH-1:0][ SB_IDX_WIDTH-1:0] rob_dispatch_sb_id;

  logic            [DISPATCH_WIDTH-1:0]                    issue_valid;
  logic            [DISPATCH_WIDTH-1:0]                    issue_rs1_in_rob;
  logic            [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_rs1_rob_idx;
  logic            [DISPATCH_WIDTH-1:0][              4:0] issue_rs1_idx;

  logic            [DISPATCH_WIDTH-1:0]                    issue_rs2_in_rob;
  logic            [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_rs2_rob_idx;
  logic            [DISPATCH_WIDTH-1:0][              4:0] issue_rs2_idx;

  logic            [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_rd_rob_idx;

  logic                                                    rob_ready_gated;
  logic            [DISPATCH_WIDTH-1:0]                    rs1_tag_allocated;
  logic            [DISPATCH_WIDTH-1:0]                    rs2_tag_allocated;
  logic            [DISPATCH_WIDTH-1:0]                    rename_src_valid;
  decode_pkg::uop_t [DISPATCH_WIDTH-1:0]                   rename_src_uops;
  logic            [DISPATCH_WIDTH-1:0]                    rename_sel_valid;
  decode_pkg::uop_t [DISPATCH_WIDTH-1:0]                   rename_sel_uops;
  logic            [DISPATCH_WIDTH-1:0]                    rename_left_valid;
  decode_pkg::uop_t [DISPATCH_WIDTH-1:0]                   rename_left_uops;
  logic            [RENAME_PENDING_DEPTH-1:0]              rename_pending_valid_q;
  logic            [RENAME_PENDING_DEPTH-1:0]              rename_pending_valid_d;
  decode_pkg::uop_t [RENAME_PENDING_DEPTH-1:0]             rename_pending_uops_q;
  decode_pkg::uop_t [RENAME_PENDING_DEPTH-1:0]             rename_pending_uops_d;
  logic            [RENAME_PENDING_CNT_W-1:0]              rename_pending_count_q;
  logic            [RENAME_PENDING_CNT_W-1:0]              rename_pending_count_d;
  logic                                                     rename_src_from_pending;
  logic [$clog2(DISPATCH_WIDTH+1)-1:0]                     rename_sel_count;
  logic                                                     rename_fire;

  logic [$clog2(RS_DEPTH+1)-1:0]                           alu_free_count;
  logic [$clog2(RS_DEPTH+1)-1:0]                           bru_free_count;
  logic [$clog2(RS_DEPTH+1)-1:0]                           lsu_free_count;
  logic [$clog2(RS_DEPTH+1)-1:0]                           csr_free_count;

  logic                                                     alu_issue_ready;
  logic                                                     bru_issue_ready;
  logic                                                     lsu_issue_ready;
  logic                                                     csr_issue_ready;

  logic                                                     alu_can_accept;
  logic                                                     bru_can_accept;
  logic                                                     lsu_can_accept;
  logic                                                     mdu_can_accept;
  logic                                                     csr_can_accept;
  logic                                                     lsu_issue_block_mispred;
  logic                                                     lsu_spec_low_addr_block_en;

  always_comb begin
    int left_k;
    int alu_budget;
    int bru_budget;
    int lsu_budget;
    int csr_budget;
    logic stop_accept;
    logic can_take;

    rename_src_from_pending = (rename_pending_count_q != '0);
    rename_sel_count = '0;

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (rename_src_from_pending) begin
        rename_src_valid[i] = rename_pending_valid_q[i];
        rename_src_uops[i]  = rename_pending_uops_q[i];
      end else begin
        rename_src_valid[i] = dec_slot_valid[i];
        rename_src_uops[i]  = dec_uops[i];
      end
      rename_sel_valid[i] = 1'b0;
      rename_sel_uops[i]  = rename_src_uops[i];
      rename_left_valid[i] = 1'b0;
      rename_left_uops[i]  = '0;
    end

    alu_budget = alu_free_count;
    bru_budget = bru_free_count;
    lsu_budget = lsu_free_count;
    csr_budget = csr_free_count;
    stop_accept = 1'b0;

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      can_take = 1'b0;
      if (!stop_accept && rename_src_valid[i]) begin
        unique case (rename_src_uops[i].fu)
          FU_ALU: begin
            can_take = (alu_budget > 0);
            if (can_take) alu_budget--;
          end
          FU_BRANCH: begin
            if (rename_src_uops[i].is_jump) begin
              can_take = (bru_budget > 0);
              if (can_take) bru_budget--;
            end else begin
              can_take = (alu_budget > 0);
              if (can_take) alu_budget--;
            end
          end
          FU_LSU: begin
            can_take = (lsu_budget > 0);
            if (can_take) lsu_budget--;
          end
          FU_MUL,
          FU_DIV: begin
            can_take = (alu_budget > 0);
            if (can_take) alu_budget--;
          end
          FU_CSR: begin
            can_take = (csr_budget > 0);
            if (can_take) csr_budget--;
          end
          default: begin
            can_take = (alu_budget > 0);
            if (can_take) alu_budget--;
          end
        endcase

        if (can_take) begin
          rename_sel_valid[i] = 1'b1;
          rename_sel_count++;
        end else begin
          stop_accept = 1'b1;
        end
      end else if (rename_src_valid[i] == 1'b0) begin
        stop_accept = 1'b1;
      end
    end

    left_k = 0;
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (rename_src_valid[i] && !rename_sel_valid[i]) begin
        rename_left_valid[left_k] = 1'b1;
        rename_left_uops[left_k] = rename_src_uops[i];
        left_k++;
      end
    end
  end

  always_comb begin
    int pending_tail;
    int pending_consume;
    logic [$clog2(DISPATCH_WIDTH+1)-1:0] dec_slot_count;
    logic [RENAME_PENDING_CNT_W-1:0] pending_free_slots;
    logic can_accept_decode_into_pending;

    rename_fire = rename_ready && (rename_sel_count != 0);
    pending_consume = 0;
    dec_slot_count = '0;
    pending_free_slots = '0;
    can_accept_decode_into_pending = 1'b0;
    pending_tail = 0;

    for (int i = 0; i < RENAME_PENDING_DEPTH; i++) begin
      rename_pending_valid_d[i] = 1'b0;
      rename_pending_uops_d[i] = '0;
    end
    rename_pending_count_d = '0;

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (dec_slot_valid[i]) begin
        dec_slot_count++;
      end
    end

    if (rename_src_from_pending) begin
      pending_consume = rename_fire ? int'(rename_sel_count) : 0;
      pending_tail = 0;
      for (int i = 0; i < RENAME_PENDING_DEPTH; i++) begin
        if ((i >= pending_consume) && rename_pending_valid_q[i]) begin
          rename_pending_valid_d[pending_tail] = 1'b1;
          rename_pending_uops_d[pending_tail] = rename_pending_uops_q[i];
          pending_tail++;
        end
      end
      rename_pending_count_d = RENAME_PENDING_CNT_W'(pending_tail);

      pending_free_slots = RENAME_PENDING_CNT_W'(RENAME_PENDING_DEPTH) - rename_pending_count_d;
      can_accept_decode_into_pending = (dec_slot_count <= pending_free_slots);
      decode_backend_ready = (!dec_valid) || can_accept_decode_into_pending;
      if (dec_valid && can_accept_decode_into_pending) begin
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
          if (dec_slot_valid[i]) begin
            rename_pending_valid_d[pending_tail] = 1'b1;
            rename_pending_uops_d[pending_tail] = dec_uops[i];
            pending_tail++;
          end
        end
        rename_pending_count_d = RENAME_PENDING_CNT_W'(pending_tail);
      end
    end else begin
      decode_backend_ready = rename_ready && (!dec_valid || (rename_sel_count != 0));
      if (rename_fire) begin
        pending_tail = 0;
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
          if (rename_left_valid[i]) begin
            rename_pending_valid_d[pending_tail] = 1'b1;
            rename_pending_uops_d[pending_tail] = rename_left_uops[i];
            pending_tail++;
          end
        end
        rename_pending_count_d = RENAME_PENDING_CNT_W'(pending_tail);
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rename_pending_valid_q <= '0;
      rename_pending_count_q <= '0;
      for (int i = 0; i < RENAME_PENDING_DEPTH; i++) begin
        rename_pending_uops_q[i] <= '0;
      end
    end else if (backend_flush) begin
      rename_pending_valid_q <= '0;
      rename_pending_count_q <= '0;
      for (int i = 0; i < RENAME_PENDING_DEPTH; i++) begin
        rename_pending_uops_q[i] <= '0;
      end
    end else begin
      rename_pending_valid_q <= rename_pending_valid_d;
      rename_pending_count_q <= rename_pending_count_d;
      for (int i = 0; i < RENAME_PENDING_DEPTH; i++) begin
        rename_pending_uops_q[i] <= rename_pending_uops_d[i];
      end
    end
  end

  rename #(
      .Cfg(Cfg),
      .ROB_DEPTH(ROB_DEPTH),
      .SB_DEPTH(SB_DEPTH)
  ) u_rename (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .dec_valid_i(rename_sel_valid),
      .dec_uops_i(rename_sel_uops),
      .rename_ready_o(rename_ready),

      .rob_dispatch_valid_o(rob_dispatch_valid),
      .rob_dispatch_pc_o   (rob_dispatch_pc),
      .rob_dispatch_inst_o (rob_dispatch_inst),
      .rob_dispatch_decoded_inst_o(rob_dispatch_decoded_inst),
      .rob_dispatch_fu_type_o(rob_dispatch_fu_type),
      .rob_dispatch_areg_o (rob_dispatch_areg),
      .rob_dispatch_has_rd_o(rob_dispatch_has_rd),
      .rob_dispatch_is_branch_o(rob_dispatch_is_branch),
      .rob_dispatch_is_jump_o(rob_dispatch_is_jump),
      .rob_dispatch_is_call_o(rob_dispatch_is_call),
      .rob_dispatch_is_ret_o(rob_dispatch_is_ret),
      .rob_dispatch_is_rvc_o(rob_dispatch_is_rvc),
      .rob_dispatch_ftq_id_o(rob_dispatch_ftq_id),
      .rob_dispatch_fetch_epoch_o(rob_dispatch_fetch_epoch),
      .rob_dispatch_is_store_o(rob_dispatch_is_store),
      .rob_dispatch_sb_id_o(rob_dispatch_sb_id),

      .rob_ready_i   (rob_ready),
      .rob_tail_ptr_i(rob_dispatch_rob_index[0]),

      .sb_alloc_req_o(sb_alloc_req),
      .sb_alloc_ready_i(sb_alloc_ready),
      .sb_alloc_id_i(sb_alloc_id),

      .issue_valid_o      (issue_valid),
      .issue_rs1_in_rob_o (issue_rs1_in_rob),
      .issue_rs1_rob_idx_o(issue_rs1_rob_idx),
      .issue_rs1_idx_o    (issue_rs1_idx),
      .issue_rs2_in_rob_o (issue_rs2_in_rob),
      .issue_rs2_rob_idx_o(issue_rs2_rob_idx),
      .issue_rs2_idx_o    (issue_rs2_idx),
      .issue_rd_rob_idx_o (issue_rd_rob_idx),

      .commit_valid_i  (commit_valid),
      .commit_areg_i   (commit_areg),
      .commit_rob_idx_i(commit_rob_index),

      .flush_i(backend_flush)
  );

  // Store Buffer allocation fires only when rename accepts the bundle.
  assign sb_alloc_fire = rename_fire && (|sb_alloc_req);

  // =========================================================
  // ARF (8 read ports)
  // =========================================================
  logic [7:0][4:0] arf_raddr;
  logic [7:0][Cfg.XLEN-1:0] arf_rdata;

  arf #(
      .Cfg(Cfg),
      .COMMIT_WIDTH(COMMIT_WIDTH)
  ) u_arf (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .we_i   (commit_we),
      .waddr_i(commit_areg),
      .wdata_i(commit_wdata),

      .raddr_i(arf_raddr),
      .rdata_o(arf_rdata)
  );

  // =========================================================
  // Operand Read (from ARF) + Tagging
  // =========================================================
  logic [DISPATCH_WIDTH-1:0][Cfg.XLEN-1:0] issue_v1;
  logic [DISPATCH_WIDTH-1:0][Cfg.XLEN-1:0] issue_v2;
  logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_q1;
  logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] issue_q2;
  logic [DISPATCH_WIDTH-1:0] issue_r1;
  logic [DISPATCH_WIDTH-1:0] issue_r2;
`ifndef SYNTHESIS
  localparam int unsigned BE_OPR_TRACE_BUDGET = 4096;
  logic [31:0] be_opr_trace_cnt_q;

`endif

  // Commit -> ARF read bypass (handles same-cycle commit/rename after flush)
  function automatic logic [Cfg.XLEN-1:0] arf_bypass(input logic [4:0] reg_idx,
                                                     input logic [Cfg.XLEN-1:0] arf_val);
    logic [Cfg.XLEN-1:0] val;
    begin
      val = arf_val;
      if (reg_idx != '0) begin
        for (int c = 0; c < COMMIT_WIDTH; c++) begin
          if (commit_we[c] && (commit_areg[c] == reg_idx)) begin
            val = commit_wdata[c];
          end
        end
      end
      return val;
    end
  endfunction

  always_comb begin
    // ARF read addresses
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      arf_raddr[i]       = issue_rs1_idx[i];
      arf_raddr[i+4]     = issue_rs2_idx[i];
      rob_query_idx[i]   = issue_rs1_rob_idx[i];
      rob_query_idx[i+4] = issue_rs2_rob_idx[i];
    end

    // Detect if a source tag is allocated in the same dispatch cycle
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      rs1_tag_allocated[i] = 1'b0;
      rs2_tag_allocated[i] = 1'b0;
      for (int j = 0; j < DISPATCH_WIDTH; j++) begin
        if (rob_dispatch_valid[j] && (issue_rs1_rob_idx[i] == rob_dispatch_rob_index[j])) begin
          rs1_tag_allocated[i] = 1'b1;
        end
        if (rob_dispatch_valid[j] && (issue_rs2_rob_idx[i] == rob_dispatch_rob_index[j])) begin
          rs2_tag_allocated[i] = 1'b1;
        end
      end
    end

    // Default outputs
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      issue_v1[i] = '0;
      issue_v2[i] = '0;
      issue_q1[i] = '0;
      issue_q2[i] = '0;
      issue_r1[i] = 1'b0;
      issue_r2[i] = 1'b0;

      if (issue_valid[i]) begin
        if (issue_rs1_in_rob[i]) begin
          if (rob_query_ready[i] && !rs1_tag_allocated[i] &&
              (rob_query_fetch_epoch[i] == rename_sel_uops[i].fetch_epoch)) begin
            issue_r1[i] = 1'b1;
            issue_v1[i] = rob_query_data[i];
          end else if (rob_query_ready[i] && !rs1_tag_allocated[i] &&
                       (rob_query_fetch_epoch[i] != rename_sel_uops[i].fetch_epoch)) begin
            // Guard against stale ROB-tag aliasing across flush epochs.
            issue_r1[i] = 1'b1;
            issue_v1[i] = arf_bypass(issue_rs1_idx[i], arf_rdata[i]);
          end else begin
            issue_r1[i] = 1'b0;
            issue_q1[i] = issue_rs1_rob_idx[i];
          end
        end else begin
          issue_r1[i] = 1'b1;
          issue_v1[i] = arf_bypass(issue_rs1_idx[i], arf_rdata[i]);
        end

        if (issue_rs2_in_rob[i]) begin
          if (rob_query_ready[i+4] && !rs2_tag_allocated[i] &&
              (rob_query_fetch_epoch[i+4] == rename_sel_uops[i].fetch_epoch)) begin
            issue_r2[i] = 1'b1;
            issue_v2[i] = rob_query_data[i+4];
          end else if (rob_query_ready[i+4] && !rs2_tag_allocated[i] &&
                       (rob_query_fetch_epoch[i+4] != rename_sel_uops[i].fetch_epoch)) begin
            issue_r2[i] = 1'b1;
            issue_v2[i] = arf_bypass(issue_rs2_idx[i], arf_rdata[i+4]);
          end else begin
            issue_r2[i] = 1'b0;
            issue_q2[i] = issue_rs2_rob_idx[i];
          end
        end else begin
          issue_r2[i] = 1'b1;
          issue_v2[i] = arf_bypass(issue_rs2_idx[i], arf_rdata[i+4]);
        end
      end
    end
  end

`ifndef SYNTHESIS
  function automatic logic watch_be_lsu_pc(input logic [31:0] pc);
    begin
      watch_be_lsu_pc = (pc == 32'hc074befe) ||
                        (pc == 32'hc039996c) ||  // bsearch: lw s1,36(sp)
                        (pc == 32'hc076a580) ||
                        (pc == 32'hc076a584);
    end
  endfunction

  function automatic logic watch_be_alu_pc(input logic [31:0] pc);
    begin
      watch_be_alu_pc = (pc == 32'hc0399942) ||  // bsearch: mv s1,a2
                        (pc == 32'hc039994c) ||  // bsearch: srli s3,s1,1
                        (pc == 32'hc0399950) ||  // bsearch: mul s2,s4,s3
                        (pc == 32'hc0399956) ||  // bsearch: addi s1,s1,-1
                        (pc == 32'hc0399958) ||  // bsearch: add s2,s2,s5
                        (pc == 32'hc039995a) ||  // bsearch: mv a1,s2
                        (pc == 32'hc0399964) ||  // bsearch: srli s1,s1,1
                        (pc == 32'hc0399986);    // bsearch: mv s1,s3
    end
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      be_opr_trace_cnt_q <= '0;
    end else if (be_trace_en_q && (be_opr_trace_cnt_q < BE_OPR_TRACE_BUDGET)) begin
      int unsigned trace_inc;
      trace_inc = 0;
      for (int i = 0; i < DISPATCH_WIDTH; i++) begin
        if (issue_valid[i] && (rename_sel_uops[i].fu == FU_LSU) &&
            watch_be_lsu_pc(rename_sel_uops[i].pc) &&
            ((be_opr_trace_cnt_q + trace_inc) < BE_OPR_TRACE_BUDGET)) begin
          $display("[be-opr-lsu] slot=%0d pc=%h rs1=%0d rs2=%0d rs1_in_rob=%0d rs1_idx=%0d rs1_tag=%0d rob_q1_ready=%0d rob_q1_data=%h rob_q1_epoch=%0d rob_q1_pc=%h rs1_tag_alloc=%0d arf_r1=%h issue_r1=%0d issue_v1=%h issue_q1=%0d rs2_in_rob=%0d rs2_idx=%0d rs2_tag=%0d rob_q2_ready=%0d rob_q2_data=%h rob_q2_epoch=%0d rob_q2_pc=%h rs2_tag_alloc=%0d arf_r2=%h issue_r2=%0d issue_v2=%h issue_q2=%0d dst=%0d ftq=%0d epoch=%0d flush=%0d",
                   i, rename_sel_uops[i].pc, rename_sel_uops[i].rs1, rename_sel_uops[i].rs2,
                   issue_rs1_in_rob[i], issue_rs1_idx[i], issue_rs1_rob_idx[i], rob_query_ready[i], rob_query_data[i], rob_query_fetch_epoch[i], rob_query_pc[i],
                   rs1_tag_allocated[i], arf_rdata[i], issue_r1[i], issue_v1[i], issue_q1[i],
                   issue_rs2_in_rob[i], issue_rs2_idx[i], issue_rs2_rob_idx[i], rob_query_ready[i+4], rob_query_data[i+4], rob_query_fetch_epoch[i+4], rob_query_pc[i+4],
                   rs2_tag_allocated[i], arf_rdata[i+4], issue_r2[i], issue_v2[i], issue_q2[i],
                   issue_rd_rob_idx[i], rename_sel_uops[i].ftq_id, rename_sel_uops[i].fetch_epoch, backend_flush);
          trace_inc++;
        end
        if (issue_valid[i] && (rename_sel_uops[i].fu == FU_ALU) &&
            watch_be_alu_pc(rename_sel_uops[i].pc) &&
            ((be_opr_trace_cnt_q + trace_inc) < BE_OPR_TRACE_BUDGET)) begin
          $display("[be-opr-alu] slot=%0d pc=%h rs1=%0d rs2=%0d rs1_in_rob=%0d rs1_idx=%0d rs1_tag=%0d rob_q1_ready=%0d rob_q1_data=%h rob_q1_epoch=%0d rob_q1_pc=%h rs1_tag_alloc=%0d arf_r1=%h issue_r1=%0d issue_v1=%h issue_q1=%0d rs2_in_rob=%0d rs2_idx=%0d rs2_tag=%0d rob_q2_ready=%0d rob_q2_data=%h rob_q2_epoch=%0d rob_q2_pc=%h rs2_tag_alloc=%0d arf_r2=%h issue_r2=%0d issue_v2=%h issue_q2=%0d dst=%0d ftq=%0d epoch=%0d flush=%0d",
                   i, rename_sel_uops[i].pc, rename_sel_uops[i].rs1, rename_sel_uops[i].rs2,
                   issue_rs1_in_rob[i], issue_rs1_idx[i], issue_rs1_rob_idx[i], rob_query_ready[i], rob_query_data[i], rob_query_fetch_epoch[i], rob_query_pc[i],
                   rs1_tag_allocated[i], arf_rdata[i], issue_r1[i], issue_v1[i], issue_q1[i],
                   issue_rs2_in_rob[i], issue_rs2_idx[i], issue_rs2_rob_idx[i], rob_query_ready[i+4], rob_query_data[i+4], rob_query_fetch_epoch[i+4], rob_query_pc[i+4],
                   rs2_tag_allocated[i], arf_rdata[i+4], issue_r2[i], issue_v2[i], issue_q2[i],
                   issue_rd_rob_idx[i], rename_sel_uops[i].ftq_id, rename_sel_uops[i].fetch_epoch, backend_flush);
          trace_inc++;
        end
      end
      if (trace_inc != 0) begin
        be_opr_trace_cnt_q <= be_opr_trace_cnt_q + trace_inc;
      end
    end

  end
`endif

  // =========================================================
  // FU Demux + Packing
  // =========================================================
  logic [2:0] alu_need_cnt;
  logic [2:0] bru_need_cnt;
  logic [2:0] lsu_need_cnt;
  logic [2:0] mdu_need_cnt;
  logic [2:0] csr_need_cnt;

  always_comb begin
    alu_need_cnt = 0;
    bru_need_cnt = 0;
    lsu_need_cnt = 0;
    mdu_need_cnt = 0;
    csr_need_cnt = 0;

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (rename_src_valid[i]) begin
        unique case (rename_src_uops[i].fu)
          FU_ALU:    alu_need_cnt++;
          FU_BRANCH: begin
            if (rename_src_uops[i].is_jump) begin
              bru_need_cnt++;
            end else begin
              alu_need_cnt++;
            end
          end
          FU_LSU:    lsu_need_cnt++;
          FU_MUL,
          FU_DIV: begin
            // Reuse ALU issue/execute path for M-extension ops.
            alu_need_cnt++;
            mdu_need_cnt++;
          end
          FU_CSR:    csr_need_cnt++;
          default:   alu_need_cnt++;
        endcase
      end
    end
  end

  // Packed dispatch arrays per FU
  logic [3:0] alu_dispatch_valid;
  decode_pkg::uop_t alu_dispatch_op[0:3];
  logic [ROB_IDX_WIDTH-1:0] alu_dispatch_dst[0:3];
  logic [Cfg.XLEN-1:0] alu_dispatch_v1[0:3];
  logic [ROB_IDX_WIDTH-1:0] alu_dispatch_q1[0:3];
  logic alu_dispatch_r1[0:3];
  logic [Cfg.XLEN-1:0] alu_dispatch_v2[0:3];
  logic [ROB_IDX_WIDTH-1:0] alu_dispatch_q2[0:3];
  logic alu_dispatch_r2[0:3];

  logic [3:0] bru_dispatch_valid;
  decode_pkg::uop_t bru_dispatch_op[0:3];
  logic [ROB_IDX_WIDTH-1:0] bru_dispatch_dst[0:3];
  logic [Cfg.XLEN-1:0] bru_dispatch_v1[0:3];
  logic [ROB_IDX_WIDTH-1:0] bru_dispatch_q1[0:3];
  logic bru_dispatch_r1[0:3];
  logic [Cfg.XLEN-1:0] bru_dispatch_v2[0:3];
  logic [ROB_IDX_WIDTH-1:0] bru_dispatch_q2[0:3];
  logic bru_dispatch_r2[0:3];

  logic [3:0] lsu_dispatch_valid;
  decode_pkg::uop_t lsu_dispatch_op[0:3];
  logic [ROB_IDX_WIDTH-1:0] lsu_dispatch_dst[0:3];
  logic [Cfg.XLEN-1:0] lsu_dispatch_v1[0:3];
  logic [ROB_IDX_WIDTH-1:0] lsu_dispatch_q1[0:3];
  logic lsu_dispatch_r1[0:3];
  logic [Cfg.XLEN-1:0] lsu_dispatch_v2[0:3];
  logic [ROB_IDX_WIDTH-1:0] lsu_dispatch_q2[0:3];
  logic lsu_dispatch_r2[0:3];
  logic [SB_IDX_WIDTH-1:0] lsu_dispatch_sb_id[0:3];

  logic [3:0] csr_dispatch_valid;
  decode_pkg::uop_t csr_dispatch_op[0:3];
  logic [ROB_IDX_WIDTH-1:0] csr_dispatch_dst[0:3];
  logic [Cfg.XLEN-1:0] csr_dispatch_v1[0:3];
  logic [ROB_IDX_WIDTH-1:0] csr_dispatch_q1[0:3];
  logic csr_dispatch_r1[0:3];
  logic [Cfg.XLEN-1:0] csr_dispatch_v2[0:3];
  logic [ROB_IDX_WIDTH-1:0] csr_dispatch_q2[0:3];
  logic csr_dispatch_r2[0:3];

  always_comb begin
    int alu_k;
    int bru_k;
    int lsu_k;
    int csr_k;

    // init
    alu_dispatch_valid = '0;
    bru_dispatch_valid = '0;
    lsu_dispatch_valid = '0;
    csr_dispatch_valid = '0;

    for (int k = 0; k < 4; k++) begin
      alu_dispatch_op[k] = '0;
      alu_dispatch_dst[k] = '0;
      alu_dispatch_v1[k] = '0;
      alu_dispatch_q1[k] = '0;
      alu_dispatch_r1[k] = 1'b0;
      alu_dispatch_v2[k] = '0;
      alu_dispatch_q2[k] = '0;
      alu_dispatch_r2[k] = 1'b0;

      bru_dispatch_op[k] = '0;
      bru_dispatch_dst[k] = '0;
      bru_dispatch_v1[k] = '0;
      bru_dispatch_q1[k] = '0;
      bru_dispatch_r1[k] = 1'b0;
      bru_dispatch_v2[k] = '0;
      bru_dispatch_q2[k] = '0;
      bru_dispatch_r2[k] = 1'b0;

      lsu_dispatch_op[k] = '0;
      lsu_dispatch_dst[k] = '0;
      lsu_dispatch_v1[k] = '0;
      lsu_dispatch_q1[k] = '0;
      lsu_dispatch_r1[k] = 1'b0;
      lsu_dispatch_v2[k] = '0;
      lsu_dispatch_q2[k] = '0;
      lsu_dispatch_r2[k] = 1'b0;
      lsu_dispatch_sb_id[k] = '0;

      csr_dispatch_op[k] = '0;
      csr_dispatch_dst[k] = '0;
      csr_dispatch_v1[k] = '0;
      csr_dispatch_q1[k] = '0;
      csr_dispatch_r1[k] = 1'b0;
      csr_dispatch_v2[k] = '0;
      csr_dispatch_q2[k] = '0;
      csr_dispatch_r2[k] = 1'b0;
    end

    alu_k = 0;
    bru_k = 0;
    lsu_k = 0;
    csr_k = 0;

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (issue_valid[i]) begin
        unique case (rename_sel_uops[i].fu)
          FU_ALU,
          FU_MUL,
          FU_DIV: begin
            alu_dispatch_valid[alu_k] = 1'b1;
            alu_dispatch_op[alu_k]    = rename_sel_uops[i];
            alu_dispatch_dst[alu_k]   = issue_rd_rob_idx[i];
            alu_dispatch_v1[alu_k]    = issue_v1[i];
            alu_dispatch_q1[alu_k]    = issue_q1[i];
            alu_dispatch_r1[alu_k]    = issue_r1[i];
            alu_dispatch_v2[alu_k]    = issue_v2[i];
            alu_dispatch_q2[alu_k]    = issue_q2[i];
            alu_dispatch_r2[alu_k]    = issue_r2[i];
            alu_k++;
          end
          FU_BRANCH: begin
            if (rename_sel_uops[i].is_jump) begin
              bru_dispatch_valid[bru_k] = 1'b1;
              bru_dispatch_op[bru_k]    = rename_sel_uops[i];
              bru_dispatch_dst[bru_k]   = issue_rd_rob_idx[i];
              bru_dispatch_v1[bru_k]    = issue_v1[i];
              bru_dispatch_q1[bru_k]    = issue_q1[i];
              bru_dispatch_r1[bru_k]    = issue_r1[i];
              bru_dispatch_v2[bru_k]    = issue_v2[i];
              bru_dispatch_q2[bru_k]    = issue_q2[i];
              bru_dispatch_r2[bru_k]    = issue_r2[i];
              bru_k++;
            end else begin
              alu_dispatch_valid[alu_k] = 1'b1;
              alu_dispatch_op[alu_k]    = rename_sel_uops[i];
              alu_dispatch_dst[alu_k]   = issue_rd_rob_idx[i];
              alu_dispatch_v1[alu_k]    = issue_v1[i];
              alu_dispatch_q1[alu_k]    = issue_q1[i];
              alu_dispatch_r1[alu_k]    = issue_r1[i];
              alu_dispatch_v2[alu_k]    = issue_v2[i];
              alu_dispatch_q2[alu_k]    = issue_q2[i];
              alu_dispatch_r2[alu_k]    = issue_r2[i];
              alu_k++;
            end
          end
          FU_LSU: begin
            lsu_dispatch_valid[lsu_k] = 1'b1;
            lsu_dispatch_op[lsu_k]    = rename_sel_uops[i];
            lsu_dispatch_dst[lsu_k]   = issue_rd_rob_idx[i];
            lsu_dispatch_v1[lsu_k]    = issue_v1[i];
            lsu_dispatch_q1[lsu_k]    = issue_q1[i];
            lsu_dispatch_r1[lsu_k]    = issue_r1[i];
            lsu_dispatch_v2[lsu_k]    = issue_v2[i];
            lsu_dispatch_q2[lsu_k]    = issue_q2[i];
            lsu_dispatch_r2[lsu_k]    = issue_r2[i];
            lsu_dispatch_sb_id[lsu_k] = rob_dispatch_sb_id[i];

            lsu_k++;
          end
          FU_CSR: begin
            csr_dispatch_valid[csr_k] = 1'b1;
            csr_dispatch_op[csr_k]    = rename_sel_uops[i];
            csr_dispatch_dst[csr_k]   = issue_rd_rob_idx[i];
            csr_dispatch_v1[csr_k]    = issue_v1[i];
            csr_dispatch_q1[csr_k]    = issue_q1[i];
            csr_dispatch_r1[csr_k]    = issue_r1[i];
            csr_dispatch_v2[csr_k]    = issue_v2[i];
            csr_dispatch_q2[csr_k]    = issue_q2[i];
            csr_dispatch_r2[csr_k]    = issue_r2[i];
            csr_k++;
          end
          default: begin
            alu_dispatch_valid[alu_k] = 1'b1;
            alu_dispatch_op[alu_k]    = rename_sel_uops[i];
            alu_dispatch_dst[alu_k]   = issue_rd_rob_idx[i];
            alu_dispatch_v1[alu_k]    = issue_v1[i];
            alu_dispatch_q1[alu_k]    = issue_q1[i];
            alu_dispatch_r1[alu_k]    = issue_r1[i];
            alu_dispatch_v2[alu_k]    = issue_v2[i];
            alu_dispatch_q2[alu_k]    = issue_q2[i];
            alu_dispatch_r2[alu_k]    = issue_r2[i];
            alu_k++;
          end
        endcase
      end
    end
  end

  // =========================================================
  // Issue Queues
  // =========================================================
  // CDB broadcast
  logic [WB_WIDTH-1:0] cdb_valid;
  logic [ROB_IDX_WIDTH-1:0] cdb_tag[0:WB_WIDTH-1];
  logic [Cfg.XLEN-1:0] cdb_val[0:WB_WIDTH-1];

  issue #(
      .Cfg   (Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(Cfg.XLEN),
      .TAG_W (ROB_IDX_WIDTH),
      .CDB_W (WB_WIDTH)
  ) u_issue_alu (
      .clk(clk_i),
      .rst_n(rst_ni),
      .flush_i(backend_flush),
      .rob_head_i(rob_head_ptr),

      .dispatch_valid(alu_dispatch_valid),
      .dispatch_op   (alu_dispatch_op),
      .dispatch_dst  (alu_dispatch_dst),
      .dispatch_v1   (alu_dispatch_v1),
      .dispatch_q1   (alu_dispatch_q1),
      .dispatch_r1   (alu_dispatch_r1),
      .dispatch_v2   (alu_dispatch_v2),
      .dispatch_q2   (alu_dispatch_q2),
      .dispatch_r2   (alu_dispatch_r2),

      .issue_ready (alu_issue_ready),
      .free_count_o(alu_free_count),

      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_val  (cdb_val),

      .alu0_en (alu0_en),
      .alu0_uop(alu0_uop),
      .alu0_v1 (alu0_v1),
      .alu0_v2 (alu0_v2),
      .alu0_dst(alu0_dst),

      .alu1_en (alu1_en),
      .alu1_uop(alu1_uop),
      .alu1_v1 (alu1_v1),
      .alu1_v2 (alu1_v2),
      .alu1_dst(alu1_dst),

      .alu2_en (alu2_en),
      .alu2_uop(alu2_uop),
      .alu2_v1 (alu2_v1),
      .alu2_v2 (alu2_v2),
      .alu2_dst(alu2_dst),

      .alu3_en (alu3_en),
      .alu3_uop(alu3_uop),
      .alu3_v1 (alu3_v1),
      .alu3_v2 (alu3_v2),
      .alu3_dst(alu3_dst)
  );

  issue_single #(
      .Cfg   (Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(Cfg.XLEN),
      .TAG_W (ROB_IDX_WIDTH),
      .CDB_W (WB_WIDTH),
      .COMB_WAKEUP_EN(1'b0)
  ) u_issue_bru (
      .clk(clk_i),
      .rst_n(rst_ni),
      .flush_i(backend_flush),
      .head_en_i(1'b0),
      .head_tag_i(rob_head_ptr),

      .dispatch_valid(bru_dispatch_valid),
      .dispatch_op   (bru_dispatch_op),
      .dispatch_dst  (bru_dispatch_dst),
      .dispatch_v1   (bru_dispatch_v1),
      .dispatch_q1   (bru_dispatch_q1),
      .dispatch_r1   (bru_dispatch_r1),
      .dispatch_v2   (bru_dispatch_v2),
      .dispatch_q2   (bru_dispatch_q2),
      .dispatch_r2   (bru_dispatch_r2),

      .issue_ready (bru_issue_ready),
      .free_count_o(bru_free_count),

      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_val  (cdb_val),
      .cdb_wakeup_mask({WB_WIDTH{1'b1}}),

      .fu_en (bru_en),
      .fu_uop(bru_uop),
      .fu_v1 (bru_v1),
      .fu_v2 (bru_v2),
      .fu_dst(bru_dst)
  );

  issue_lsu #(
      .Cfg   (Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(Cfg.XLEN),
      .TAG_W (ROB_IDX_WIDTH),
      .CDB_W (WB_WIDTH),
      .SB_W  (SB_IDX_WIDTH)
  ) u_issue_lsu (
      .clk(clk_i),
      .rst_n(rst_ni),
      .flush_i(backend_flush),

      .dispatch_valid(lsu_dispatch_valid),
      .dispatch_op   (lsu_dispatch_op),
      .dispatch_dst  (lsu_dispatch_dst),
      .dispatch_v1   (lsu_dispatch_v1),
      .dispatch_q1   (lsu_dispatch_q1),
      .dispatch_r1   (lsu_dispatch_r1),
      .dispatch_v2   (lsu_dispatch_v2),
      .dispatch_q2   (lsu_dispatch_q2),
      .dispatch_r2   (lsu_dispatch_r2),
      .dispatch_sb_id(lsu_dispatch_sb_id),

      .rob_head_i(rob_head_ptr),
      .mispred_block_i(lsu_issue_block_mispred),
      .spec_low_addr_block_en_i(lsu_spec_low_addr_block_en),

      .fu_ready_i(lsu_req_ready),

      .issue_ready (lsu_issue_ready),
      .free_count_o(lsu_free_count),

      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_val  (cdb_val),

      .lsu_en   (lsu_en),
      .lsu_uop  (lsu_uop),
      .lsu_v1   (lsu_v1),
      .lsu_v2   (lsu_v2),
      .lsu_dst  (lsu_dst),
      .lsu_sb_id(lsu_sb_id)
  );

  issue_single #(
      .Cfg   (Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(Cfg.XLEN),
      .TAG_W (ROB_IDX_WIDTH),
      .CDB_W (WB_WIDTH),
      .COMB_WAKEUP_EN(1'b0)
  ) u_issue_csr (
      .clk(clk_i),
      .rst_n(rst_ni),
      .flush_i(backend_flush),
      .head_en_i(1'b1),
      .head_tag_i(rob_head_ptr),

      .dispatch_valid(csr_dispatch_valid),
      .dispatch_op   (csr_dispatch_op),
      .dispatch_dst  (csr_dispatch_dst),
      .dispatch_v1   (csr_dispatch_v1),
      .dispatch_q1   (csr_dispatch_q1),
      .dispatch_r1   (csr_dispatch_r1),
      .dispatch_v2   (csr_dispatch_v2),
      .dispatch_q2   (csr_dispatch_q2),
      .dispatch_r2   (csr_dispatch_r2),

      .issue_ready (csr_issue_ready),
      .free_count_o(csr_free_count),

      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_val  (cdb_val),
      .cdb_wakeup_mask({WB_WIDTH{1'b1}} & ~(WB_WIDTH'(1) << 6)),

      .fu_en (csr_en),
      .fu_uop(csr_uop),
      .fu_v1 (csr_v1),
      .fu_v2 (csr_v2),
      .fu_dst(csr_dst)
  );

  // Backpressure calculation
  always_comb begin
    alu_can_accept = (alu_need_cnt == 0) ? 1'b1 : (alu_free_count >= alu_need_cnt);
    bru_can_accept = (bru_need_cnt == 0) ? 1'b1 : (bru_free_count >= bru_need_cnt);
    lsu_can_accept = (lsu_need_cnt == 0) ? 1'b1 : (lsu_free_count >= lsu_need_cnt);
    // M-extension ops are currently scheduled via ALU queues.
    mdu_can_accept = 1'b1;
    csr_can_accept = (csr_need_cnt == 0) ? 1'b1 : (csr_free_count >= csr_need_cnt);
  end

  assign rob_ready_gated = rob_ready & alu_can_accept & bru_can_accept & lsu_can_accept & mdu_can_accept & csr_can_accept;

  // =========================================================
  // Execute Units
  // =========================================================
  logic alu0_en, alu1_en, alu2_en, alu3_en;
  decode_pkg::uop_t alu0_uop, alu1_uop, alu2_uop, alu3_uop;
  logic [Cfg.XLEN-1:0] alu0_v1, alu0_v2, alu1_v1, alu1_v2, alu2_v1, alu2_v2, alu3_v1, alu3_v2;
  logic [ROB_IDX_WIDTH-1:0] alu0_dst, alu1_dst, alu2_dst, alu3_dst;

  logic alu0_wb_valid, alu1_wb_valid, alu2_wb_valid, alu3_wb_valid;
  logic [ROB_IDX_WIDTH-1:0] alu0_wb_tag, alu1_wb_tag, alu2_wb_tag, alu3_wb_tag;
  logic [Cfg.XLEN-1:0] alu0_wb_data, alu1_wb_data, alu2_wb_data, alu3_wb_data;
  logic alu0_mispred, alu1_mispred, alu2_mispred, alu3_mispred;
  logic [Cfg.PLEN-1:0] alu0_redirect_pc, alu1_redirect_pc, alu2_redirect_pc, alu3_redirect_pc;

  execute_alu #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN),
      .PC_W (Cfg.PLEN)
  ) u_alu0 (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(alu0_en),
      .uop_i      (alu0_uop),
      .rs1_data_i (alu0_v1),
      .rs2_data_i (alu0_v2),
      .rob_tag_i  (alu0_dst),

      .alu_valid_o      (alu0_wb_valid),
      .alu_rob_tag_o    (alu0_wb_tag),
      .alu_result_o     (alu0_wb_data),
      .alu_is_mispred_o (alu0_mispred),
      .alu_redirect_pc_o(alu0_redirect_pc)
  );

  execute_alu #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN),
      .PC_W (Cfg.PLEN)
  ) u_alu1 (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(alu1_en),
      .uop_i      (alu1_uop),
      .rs1_data_i (alu1_v1),
      .rs2_data_i (alu1_v2),
      .rob_tag_i  (alu1_dst),

      .alu_valid_o      (alu1_wb_valid),
      .alu_rob_tag_o    (alu1_wb_tag),
      .alu_result_o     (alu1_wb_data),
      .alu_is_mispred_o (alu1_mispred),
      .alu_redirect_pc_o(alu1_redirect_pc)
  );

  execute_alu #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN),
      .PC_W (Cfg.PLEN)
  ) u_alu2 (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(alu2_en),
      .uop_i      (alu2_uop),
      .rs1_data_i (alu2_v1),
      .rs2_data_i (alu2_v2),
      .rob_tag_i  (alu2_dst),

      .alu_valid_o      (alu2_wb_valid),
      .alu_rob_tag_o    (alu2_wb_tag),
      .alu_result_o     (alu2_wb_data),
      .alu_is_mispred_o (alu2_mispred),
      .alu_redirect_pc_o(alu2_redirect_pc)
  );

  execute_alu #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN),
      .PC_W (Cfg.PLEN)
  ) u_alu3 (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(alu3_en),
      .uop_i      (alu3_uop),
      .rs1_data_i (alu3_v1),
      .rs2_data_i (alu3_v2),
      .rob_tag_i  (alu3_dst),

      .alu_valid_o      (alu3_wb_valid),
      .alu_rob_tag_o    (alu3_wb_tag),
      .alu_result_o     (alu3_wb_data),
      .alu_is_mispred_o (alu3_mispred),
      .alu_redirect_pc_o(alu3_redirect_pc)
  );

  // BRU
  logic bru_en;
  decode_pkg::uop_t bru_uop;
  logic [Cfg.XLEN-1:0] bru_v1, bru_v2;
  logic [ROB_IDX_WIDTH-1:0] bru_dst;

  logic bru_wb_valid;
  logic [ROB_IDX_WIDTH-1:0] bru_wb_tag;
  logic [Cfg.XLEN-1:0] bru_wb_data;
  logic bru_mispred;
  logic [Cfg.PLEN-1:0] bru_redirect_pc;

  execute_alu #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN),
      .PC_W (Cfg.PLEN)
  ) u_bru (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(bru_en),
      .uop_i      (bru_uop),
      .rs1_data_i (bru_v1),
      .rs2_data_i (bru_v2),
      .rob_tag_i  (bru_dst),

      .alu_valid_o      (bru_wb_valid),
      .alu_rob_tag_o    (bru_wb_tag),
      .alu_result_o     (bru_wb_data),
      .alu_is_mispred_o (bru_mispred),
      .alu_redirect_pc_o(bru_redirect_pc)
  );

  // Block LSU issue in cycles where any branch/jump mispredict is resolved.
  // This prevents same-cycle wrong-path memory ops from escaping before flush.
  assign lsu_issue_block_mispred = alu0_mispred | alu1_mispred | alu2_mispred | alu3_mispred |
                                   bru_mispred;

  // LSU
  logic lsu_en;
  decode_pkg::uop_t lsu_uop;
  logic [Cfg.XLEN-1:0] lsu_v1, lsu_v2;
  logic [ROB_IDX_WIDTH-1:0] lsu_dst;
  logic [SB_IDX_WIDTH-1:0] lsu_sb_id;

  logic lsu_req_ready;
  logic lsu_wb_valid;
  logic [ROB_IDX_WIDTH-1:0] lsu_wb_tag;
  logic [Cfg.XLEN-1:0] lsu_wb_data;
  logic lsu_wb_exception;
  logic [4:0] lsu_wb_ecause;
  logic lsu_wb_is_mispred;
  logic [Cfg.PLEN-1:0] lsu_wb_redirect_pc;

  // LSU <-> D$
  logic lsu_ld_req_valid;
  logic lsu_ld_req_ready;
  logic [Cfg.PLEN-1:0] lsu_ld_req_addr;
  decode_pkg::lsu_op_e lsu_ld_req_op;
  logic [LSU_LD_ID_WIDTH-1:0] lsu_ld_req_id;

  logic lsu_ld_rsp_valid;
  logic lsu_ld_rsp_ready;
  logic [Cfg.XLEN-1:0] lsu_ld_rsp_data;
  logic lsu_ld_rsp_err;
  logic [LSU_LD_ID_WIDTH-1:0] lsu_ld_rsp_id;
  logic dcache_ld_req_valid;
  logic dcache_ld_req_ready;
  logic [Cfg.PLEN-1:0] dcache_ld_req_addr;
  decode_pkg::lsu_op_e dcache_ld_req_op;
  logic [DCACHE_LD_ID_WIDTH-1:0] dcache_ld_req_id;
  logic dcache_ld_rsp_valid;
  logic dcache_ld_rsp_ready;
  logic [Cfg.XLEN-1:0] dcache_ld_rsp_data;
  logic dcache_ld_rsp_err;
  logic [DCACHE_LD_ID_WIDTH-1:0] dcache_ld_rsp_id;
  logic dcache_st_req_valid;
  logic dcache_st_req_ready;
  logic [Cfg.PLEN-1:0] dcache_st_req_addr;
  logic [Cfg.XLEN-1:0] dcache_st_req_data;
  decode_pkg::lsu_op_e dcache_st_req_op;
  logic lsu_pte_req_valid;
  logic lsu_pte_req_ready;
  logic [31:0] lsu_pte_req_paddr;
  logic lsu_pte_rsp_valid;
  logic [31:0] lsu_pte_rsp_data;
  logic lsu_pte_upd_valid;
  logic lsu_pte_upd_ready;
  logic [31:0] lsu_pte_upd_paddr;
  logic [31:0] lsu_pte_upd_data;
  logic ifu_pte_req_valid;
  logic ifu_pte_req_ready;
  logic [31:0] ifu_pte_req_paddr;
  logic ifu_pte_rsp_valid;
  logic [31:0] ifu_pte_rsp_data;
  logic ifu_pte_upd_valid;
  logic ifu_pte_upd_ready;
  logic [31:0] ifu_pte_upd_paddr;
  logic [31:0] ifu_pte_upd_data;
  logic [$clog2(LSU_LQ_DEPTH + 1)-1:0] lsu_lq_count_dbg;
  logic lsu_lq_head_valid_dbg;
  logic [ROB_IDX_WIDTH-1:0] lsu_lq_head_rob_tag_dbg;
  logic [$clog2(LSU_SQ_DEPTH + 1)-1:0] lsu_sq_count_dbg;
  logic lsu_sq_head_valid_dbg;
  logic [ROB_IDX_WIDTH-1:0] lsu_sq_head_rob_tag_dbg;
  logic mem_dep_req_fire;
  logic [Cfg.XLEN-1:0] mem_dep_req_addr_xlen;
  logic [Cfg.PLEN-1:0] mem_dep_req_addr;
  logic mem_dep_replay_valid;
  logic [ROB_IDX_WIDTH-1:0] mem_dep_replay_rob_idx;
  logic mem_dep_bypass_allow;

  assign mem_dep_req_fire = lsu_en && lsu_req_ready;
  assign mem_dep_req_addr_xlen = lsu_v1 + lsu_uop.imm;
  assign mem_dep_req_addr = mem_dep_req_addr_xlen[Cfg.PLEN-1:0];
  assign ifu_pte_req_valid = ifu_pte_ld_req_valid_i;
  assign ifu_pte_req_paddr = ifu_pte_ld_req_paddr_i;
  assign ifu_pte_upd_valid = ifu_pte_st_req_valid_i;
  assign ifu_pte_upd_paddr = ifu_pte_st_req_paddr_i;
  assign ifu_pte_upd_data = ifu_pte_st_req_data_i;
  assign ifu_pte_ld_req_ready_o = ifu_pte_req_ready;
  assign ifu_pte_ld_rsp_valid_o = ifu_pte_rsp_valid;
  assign ifu_pte_ld_rsp_data_o = ifu_pte_rsp_data;
  assign ifu_pte_st_req_ready_o = ifu_pte_upd_ready;

  backend_mmu_dcache_mux #(
      .PLEN(Cfg.PLEN),
      .XLEN(Cfg.XLEN),
      .LSU_LD_ID_WIDTH(LSU_LD_ID_WIDTH)
  ) u_mmu_dcache_mux (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .flush_i(backend_flush),

      .lsu_ld_req_valid_i(lsu_ld_req_valid),
      .lsu_ld_req_ready_o(lsu_ld_req_ready),
      .lsu_ld_req_addr_i(lsu_ld_req_addr),
      .lsu_ld_req_op_i(lsu_ld_req_op),
      .lsu_ld_req_id_i(lsu_ld_req_id),
      .lsu_ld_rsp_valid_o(lsu_ld_rsp_valid),
      .lsu_ld_rsp_ready_i(lsu_ld_rsp_ready),
      .lsu_ld_rsp_data_o(lsu_ld_rsp_data),
      .lsu_ld_rsp_err_o(lsu_ld_rsp_err),
      .lsu_ld_rsp_id_o(lsu_ld_rsp_id),

      .pte_ld_req_valid_i(lsu_pte_req_valid),
      .pte_ld_req_ready_o(lsu_pte_req_ready),
      .pte_ld_req_paddr_i(lsu_pte_req_paddr),
      .pte_ld_rsp_valid_o(lsu_pte_rsp_valid),
      .pte_ld_rsp_data_o(lsu_pte_rsp_data),
      .ifu_pte_ld_req_valid_i(ifu_pte_req_valid),
      .ifu_pte_ld_req_ready_o(ifu_pte_req_ready),
      .ifu_pte_ld_req_paddr_i(ifu_pte_req_paddr),
      .ifu_pte_ld_rsp_valid_o(ifu_pte_rsp_valid),
      .ifu_pte_ld_rsp_data_o(ifu_pte_rsp_data),

      .sb_st_req_valid_i(sb_dcache_req_valid),
      .sb_st_req_ready_o(sb_dcache_req_ready),
      .sb_st_req_addr_i(sb_dcache_req_addr),
      .sb_st_req_data_i(sb_dcache_req_data),
      .sb_st_req_op_i(sb_dcache_req_op),

      .pte_st_req_valid_i(lsu_pte_upd_valid),
      .pte_st_req_ready_o(lsu_pte_upd_ready),
      .pte_st_req_paddr_i(lsu_pte_upd_paddr),
      .pte_st_req_data_i(lsu_pte_upd_data),
      .ifu_pte_st_req_valid_i(ifu_pte_upd_valid),
      .ifu_pte_st_req_ready_o(ifu_pte_upd_ready),
      .ifu_pte_st_req_paddr_i(ifu_pte_upd_paddr),
      .ifu_pte_st_req_data_i(ifu_pte_upd_data),

      .dcache_ld_req_valid_o(dcache_ld_req_valid),
      .dcache_ld_req_ready_i(dcache_ld_req_ready),
      .dcache_ld_req_addr_o(dcache_ld_req_addr),
      .dcache_ld_req_op_o(dcache_ld_req_op),
      .dcache_ld_req_id_o(dcache_ld_req_id),

      .dcache_ld_rsp_valid_i(dcache_ld_rsp_valid),
      .dcache_ld_rsp_ready_o(dcache_ld_rsp_ready),
      .dcache_ld_rsp_data_i(dcache_ld_rsp_data),
      .dcache_ld_rsp_err_i(dcache_ld_rsp_err),
      .dcache_ld_rsp_id_i(dcache_ld_rsp_id),

      .dcache_st_req_valid_o(dcache_st_req_valid),
      .dcache_st_req_ready_i(dcache_st_req_ready),
      .dcache_st_req_addr_o(dcache_st_req_addr),
      .dcache_st_req_data_o(dcache_st_req_data),
      .dcache_st_req_op_o(dcache_st_req_op)
  );

  mem_dep_predictor #(
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .ADDR_WIDTH(Cfg.PLEN),
      .STORE_DEPTH(MEM_DEP_STORE_DEPTH)
  ) u_mem_dep_predictor (
      .clk_i,
      .rst_ni,
      .flush_i(backend_flush),
      .req_fire_i(mem_dep_req_fire),
      .req_is_load_i(lsu_uop.is_load),
      .req_is_store_i(lsu_uop.is_store),
      .req_addr_i(mem_dep_req_addr),
      .req_rob_idx_i(lsu_dst),
      .bypass_allow_o(mem_dep_bypass_allow),
      .replay_valid_o(mem_dep_replay_valid),
      .replay_rob_idx_o(mem_dep_replay_rob_idx)
  );

  lsu_group #(
      .Cfg(Cfg),
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .SB_DEPTH(SB_DEPTH),
      .LQ_DEPTH(LSU_LQ_DEPTH),
      .SQ_DEPTH(LSU_SQ_DEPTH),
      .N_LSU(LSU_GROUP_SIZE)
  ) u_lsu_group (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .flush_i(backend_flush),

      .req_valid_i(lsu_en),
      .req_ready_o(lsu_req_ready),
      .uop_i      (lsu_uop),
      .rs1_data_i (lsu_v1),
      .rs2_data_i (lsu_v2),
      .rob_tag_i  (lsu_dst),
      .rob_head_i (rob_head_ptr),
      .sb_id_i    (lsu_sb_id),
      .mmu_satp_i(csr_satp_state),
      .mmu_priv_i(csr_priv_mode),
      .mmu_sum_i(csr_mstatus_sum),
      .mmu_mxr_i(csr_mstatus_mxr),
      .mmu_sfence_vma_i(csr_sfence_vma_flush),

      .sb_ex_valid_o(sb_ex_valid),
      .sb_ex_sb_id_o(sb_ex_sb_id),
      .sb_ex_addr_o (sb_ex_addr),
      .sb_ex_data_o (sb_ex_data),
      .sb_ex_op_o   (sb_ex_op),
      .sb_ex_rob_idx_o(sb_ex_rob_idx),

      .sb_load_addr_o(sb_load_addr),
      .sb_load_rob_idx_o(sb_load_rob_idx),
      .sb_load_hit_i(sb_load_hit),
      .sb_load_data_i(sb_load_data),

      .ld_req_valid_o(lsu_ld_req_valid),
      .ld_req_ready_i(lsu_ld_req_ready),
      .ld_req_addr_o (lsu_ld_req_addr),
      .ld_req_op_o   (lsu_ld_req_op),
      .ld_req_id_o   (lsu_ld_req_id),

      .ld_rsp_valid_i(lsu_ld_rsp_valid),
      .ld_rsp_id_i   (lsu_ld_rsp_id),
      .ld_rsp_ready_o(lsu_ld_rsp_ready),
      .ld_rsp_data_i (lsu_ld_rsp_data),
      .ld_rsp_err_i  (lsu_ld_rsp_err),

      .mmio_req_valid_o(mmio_req_valid_o),
      .mmio_req_ready_i(mmio_req_ready_i),
      .mmio_req_addr_o (mmio_req_addr_o),
      .mmio_req_op_o   (mmio_req_op_o),
      .mmio_rsp_valid_i(mmio_rsp_valid_i),
      .mmio_rsp_data_i (mmio_rsp_data_i),

      .pte_req_valid_o(lsu_pte_req_valid),
      .pte_req_ready_i(lsu_pte_req_ready),
      .pte_req_paddr_o(lsu_pte_req_paddr),
      .pte_rsp_valid_i(lsu_pte_rsp_valid),
      .pte_rsp_data_i(lsu_pte_rsp_data),
      .pte_upd_valid_o(lsu_pte_upd_valid),
      .pte_upd_ready_i(lsu_pte_upd_ready),
      .pte_upd_paddr_o(lsu_pte_upd_paddr),
      .pte_upd_data_o(lsu_pte_upd_data),

      .wb_valid_o      (lsu_wb_valid),
      .wb_rob_idx_o    (lsu_wb_tag),
      .wb_data_o       (lsu_wb_data),
      .wb_exception_o  (lsu_wb_exception),
      .wb_ecause_o     (lsu_wb_ecause),
      .wb_is_mispred_o (lsu_wb_is_mispred),
      .wb_redirect_pc_o(lsu_wb_redirect_pc),
      .wb_ready_i      (1'b1),

      .dbg_lq_count_o(lsu_lq_count_dbg),
      .dbg_lq_head_valid_o(lsu_lq_head_valid_dbg),
      .dbg_lq_head_rob_tag_o(lsu_lq_head_rob_tag_dbg),
      .dbg_sq_count_o(lsu_sq_count_dbg),
      .dbg_sq_head_valid_o(lsu_sq_head_valid_dbg),
      .dbg_sq_head_rob_tag_o(lsu_sq_head_rob_tag_dbg)
  );

  // CSR
  logic csr_en;
  decode_pkg::uop_t csr_uop;
  logic [Cfg.XLEN-1:0] csr_v1, csr_v2;
  logic [ROB_IDX_WIDTH-1:0] csr_dst;

  logic csr_wb_valid;
  logic [ROB_IDX_WIDTH-1:0] csr_wb_tag;
  logic [Cfg.XLEN-1:0] csr_wb_data;
  logic csr_wb_exception;
  logic [4:0] csr_wb_ecause;
  logic csr_wb_is_mispred;
  logic [Cfg.PLEN-1:0] csr_wb_redirect_pc;
  logic csr_irq_inject;
  logic csr_rob_exception_inject;
  logic csr_ifetch_fault_inject;
  logic csr_async_exception_inject;
  logic csr_exec_valid;
  decode_pkg::uop_t csr_exec_uop;
  logic [Cfg.XLEN-1:0] csr_exec_v1;
  logic [ROB_IDX_WIDTH-1:0] csr_exec_dst;
  logic [Cfg.PLEN-1:0] csr_exec_trap_pc;
  logic [4:0] csr_exec_async_ecause;
  logic [Cfg.PLEN-1:0] csr_exec_async_tval;
  logic [Cfg.XLEN-1:0] csr_satp_state;
  logic [1:0] csr_priv_mode;
  logic csr_mstatus_sum;
  logic csr_mstatus_mxr;
  logic csr_sfence_vma_flush;

  always_comb begin
    csr_rob_exception_inject = rob_sync_exception_pending_q && !csr_en;
    // An IFU instruction-fetch page fault may only be escalated to an architectural trap
    // when it is the next instruction to retire, i.e. the ROB is empty. Otherwise the
    // faulting fetch can be a wrong-path (BPU-mispredicted) speculative fetch — e.g. a
    // user VA fetched while the kernel page-fault handler runs in S-mode — and the older
    // in-flight instructions (the mispredicting branch) must resolve and squash it first.
    // Injecting it immediately preempts the running handler and live-locks.
    csr_ifetch_fault_inject = ifetch_fault_valid_i && rob_empty && !csr_en &&
                              !csr_rob_exception_inject;
    csr_async_exception_inject = csr_rob_exception_inject || csr_ifetch_fault_inject;
    csr_irq_inject = (timer_irq_i || ext_irq_i) && !rob_empty && !csr_en &&
                     !csr_rob_exception_inject && !csr_ifetch_fault_inject;
    csr_exec_valid = csr_en || csr_rob_exception_inject || csr_irq_inject ||
                     csr_ifetch_fault_inject;
    csr_exec_uop = csr_uop;
    csr_exec_v1 = csr_v1;
    csr_exec_dst = csr_dst;
    csr_exec_trap_pc = csr_uop.pc;
    csr_exec_async_ecause = rob_sync_exception_cause_q;
    csr_exec_async_tval = rob_sync_exception_tval_q;
    ifetch_fault_ready_o = csr_ifetch_fault_inject;

    if (csr_rob_exception_inject) begin
      csr_exec_uop = '0;
      csr_exec_v1 = '0;
      csr_exec_dst = rob_head_ptr;
      csr_exec_trap_pc = rob_sync_exception_pc_q;
      csr_exec_async_ecause = rob_sync_exception_cause_q;
      csr_exec_async_tval = rob_sync_exception_tval_q;
    end else if (csr_ifetch_fault_inject) begin
      csr_exec_uop = '0;
      csr_exec_v1 = '0;
      csr_exec_dst = rob_head_ptr;
      csr_exec_trap_pc = ifetch_fault_pc_i;
      csr_exec_async_ecause = ifetch_fault_cause_i;
      csr_exec_async_tval = ifetch_fault_tval_i;
    end else if (csr_irq_inject) begin
      csr_exec_uop = '0;
      csr_exec_v1 = '0;
      csr_exec_dst = rob_head_ptr;
      csr_exec_trap_pc = rob_head_pc;
      csr_exec_async_ecause = '0;
      csr_exec_async_tval = '0;
    end
  end

  execute_csr #(
      .Cfg  (Cfg),
      .TAG_W(ROB_IDX_WIDTH),
      .XLEN (Cfg.XLEN)
  ) u_csr (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .csr_valid_i(csr_exec_valid),
      .uop_i      (csr_exec_uop),
      .rs1_data_i (csr_exec_v1),
      .rob_tag_i  (csr_exec_dst),
      .interrupt_inject_i(csr_irq_inject),
      .async_exception_inject_i(csr_async_exception_inject),
      .async_exception_cause_i(csr_exec_async_ecause),
      .async_exception_tval_i(csr_exec_async_tval),
      .timer_irq_i(timer_irq_i),
      .external_irq_i(ext_irq_i),
      .trap_pc_i(csr_exec_trap_pc),

      .csr_valid_o  (csr_wb_valid),
      .csr_rob_tag_o(csr_wb_tag),
      .csr_result_o (csr_wb_data),
      .csr_exception_o(csr_wb_exception),
      .csr_ecause_o   (csr_wb_ecause),
      .csr_is_mispred_o(csr_wb_is_mispred),
      .csr_redirect_pc_o(csr_wb_redirect_pc),
      .irq_trap_o(csr_irq_trap),
      .irq_trap_cause_o(csr_irq_trap_cause),
      .irq_trap_pc_o(csr_irq_trap_pc),
      .irq_trap_redirect_pc_o(csr_irq_trap_redirect_pc),
      .satp_o(csr_satp_state),
      .priv_mode_o(csr_priv_mode),
      .mstatus_sum_o(csr_mstatus_sum),
      .mstatus_mxr_o(csr_mstatus_mxr),
      .sfence_vma_flush_o(csr_sfence_vma_flush)
  );

  assign mmu_satp_o = csr_satp_state;
  assign mmu_priv_o = csr_priv_mode;
  assign mmu_sum_o = csr_mstatus_sum;
  assign mmu_mxr_o = csr_mstatus_mxr;
  assign mmu_sfence_vma_o = csr_sfence_vma_flush;
  // Only apply speculative low-address LSU guard when address translation is active.
  assign lsu_spec_low_addr_block_en = csr_satp_state[31] && (csr_priv_mode != 2'b11);

  wire _unused_csr_state = &{
      1'b0,
      csr_satp_state[0],
      csr_priv_mode,
      csr_mstatus_sum,
      csr_mstatus_mxr,
      csr_sfence_vma_flush
  };

  // =========================================================
  // Writeback (CDB)
  // =========================================================
  logic [NUM_FUS-1:0] fu_valid;
  logic [NUM_FUS-1:0][Cfg.XLEN-1:0] fu_data;
  logic [NUM_FUS-1:0][ROB_IDX_WIDTH-1:0] fu_rob_idx;
  logic [NUM_FUS-1:0] fu_exception;
  logic [NUM_FUS-1:0][4:0] fu_ecause;
  logic [NUM_FUS-1:0] fu_is_mispred;
  logic [NUM_FUS-1:0][Cfg.PLEN-1:0] fu_redirect_pc;
  logic [NUM_FUS-1:0] fu_ready;

  always_comb begin
    fu_valid          = '0;
    fu_data           = '0;
    fu_rob_idx        = '0;
    fu_exception      = '0;
    fu_ecause         = '0;
    fu_is_mispred     = '0;
    fu_redirect_pc    = '0;

    fu_valid[0]       = alu0_wb_valid;
    fu_data[0]        = alu0_wb_data;
    fu_rob_idx[0]     = alu0_wb_tag;
    fu_is_mispred[0]  = alu0_mispred;
    fu_redirect_pc[0] = alu0_redirect_pc;

    fu_valid[1]       = alu1_wb_valid;
    fu_data[1]        = alu1_wb_data;
    fu_rob_idx[1]     = alu1_wb_tag;
    fu_is_mispred[1]  = alu1_mispred;
    fu_redirect_pc[1] = alu1_redirect_pc;

    fu_valid[2]       = bru_wb_valid;
    fu_data[2]        = bru_wb_data;
    fu_rob_idx[2]     = bru_wb_tag;
    fu_is_mispred[2]  = bru_mispred;
    fu_redirect_pc[2] = bru_redirect_pc;

    fu_valid[3]       = lsu_wb_valid;
    fu_data[3]        = lsu_wb_data;
    fu_rob_idx[3]     = lsu_wb_tag;
    fu_exception[3]   = lsu_wb_exception;
    fu_ecause[3]      = lsu_wb_ecause;
    fu_is_mispred[3]  = lsu_wb_is_mispred;
    fu_redirect_pc[3] = lsu_wb_redirect_pc;

    fu_valid[4]       = alu2_wb_valid;
    fu_data[4]        = alu2_wb_data;
    fu_rob_idx[4]     = alu2_wb_tag;
    fu_is_mispred[4]  = alu2_mispred;
    fu_redirect_pc[4] = alu2_redirect_pc;

    fu_valid[5]       = alu3_wb_valid;
    fu_data[5]        = alu3_wb_data;
    fu_rob_idx[5]     = alu3_wb_tag;
    fu_is_mispred[5]  = alu3_mispred;
    fu_redirect_pc[5] = alu3_redirect_pc;

    fu_valid[6]       = csr_wb_valid;
    fu_data[6]        = csr_wb_data;
    fu_rob_idx[6]     = csr_wb_tag;
    fu_exception[6]   = csr_wb_exception;
    fu_ecause[6]      = csr_wb_ecause;
    fu_is_mispred[6]  = csr_wb_is_mispred;
    fu_redirect_pc[6] = csr_wb_redirect_pc;
  end

  logic [WB_WIDTH-1:0]                    wb_raw_valid;
  logic [WB_WIDTH-1:0][     Cfg.XLEN-1:0] wb_raw_data;
  logic [WB_WIDTH-1:0][ROB_IDX_WIDTH-1:0] wb_raw_rob_idx;
  logic [WB_WIDTH-1:0]                    wb_raw_exception;
  logic [WB_WIDTH-1:0][              4:0] wb_raw_ecause;
  logic [WB_WIDTH-1:0]                    wb_raw_is_mispred;
  logic [WB_WIDTH-1:0][     Cfg.PLEN-1:0] wb_raw_redirect_pc;

  logic [WB_WIDTH-1:0]                    wb_valid;
  logic [WB_WIDTH-1:0][     Cfg.XLEN-1:0] wb_data;
  logic [WB_WIDTH-1:0][ROB_IDX_WIDTH-1:0] wb_rob_idx;
  logic [WB_WIDTH-1:0]                    wb_exception;
  logic [WB_WIDTH-1:0][              4:0] wb_ecause;
  logic [WB_WIDTH-1:0]                    wb_is_mispred;
  logic [WB_WIDTH-1:0][     Cfg.PLEN-1:0] wb_redirect_pc;
  logic [$clog2(COMPLETION_Q_DEPTH + 1)-1:0] completion_q_count;

  writeback #(
      .Cfg          (Cfg),
      .WB_WIDTH     (WB_WIDTH),
      .NUM_FUS      (NUM_FUS),
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH)
  ) u_wb (
      .fu_valid_i      (fu_valid),
      .fu_data_i       (fu_data),
      .fu_rob_idx_i    (fu_rob_idx),
      .fu_exception_i  (fu_exception),
      .fu_ecause_i     (fu_ecause),
      .fu_is_mispred_i (fu_is_mispred),
      .fu_redirect_pc_i(fu_redirect_pc),

      .fu_ready_o(fu_ready),

      .wb_valid_o      (wb_raw_valid),
      .wb_data_o       (wb_raw_data),
      .wb_rob_idx_o    (wb_raw_rob_idx),
      .wb_exception_o  (wb_raw_exception),
      .wb_ecause_o     (wb_raw_ecause),
      .wb_is_mispred_o (wb_raw_is_mispred),
      .wb_redirect_pc_o(wb_raw_redirect_pc)
  );

  completion_queue #(
      .Cfg(Cfg),
      .WB_WIDTH(WB_WIDTH),
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .DEPTH(COMPLETION_Q_DEPTH)
  ) u_completion_q (
      .clk_i,
      .rst_ni,
      .flush_i(flush_from_backend),
      .enq_valid_i(wb_raw_valid),
      .enq_data_i(wb_raw_data),
      .enq_rob_idx_i(wb_raw_rob_idx),
      .enq_exception_i(wb_raw_exception),
      .enq_ecause_i(wb_raw_ecause),
      .enq_is_mispred_i(wb_raw_is_mispred),
      .enq_redirect_pc_i(wb_raw_redirect_pc),
      .deq_valid_o(),
      .deq_data_o(),
      .deq_rob_idx_o(),
      .deq_exception_o(),
      .deq_ecause_o(),
      .deq_is_mispred_o(),
      .deq_redirect_pc_o(),
      .count_o(completion_q_count)
  );

  assign wb_valid = wb_raw_valid;
  assign wb_data = wb_raw_data;
  assign wb_rob_idx = wb_raw_rob_idx;
  assign wb_exception = wb_raw_exception;
  assign wb_ecause = wb_raw_ecause;
  assign wb_is_mispred = wb_raw_is_mispred;
  assign wb_redirect_pc = wb_raw_redirect_pc;

  always_comb begin
    for (int i = 0; i < WB_WIDTH; i++) begin
      cdb_valid[i] = wb_valid[i];
      cdb_tag[i]   = wb_rob_idx[i];
      cdb_val[i]   = wb_data[i];
    end
  end

  // =========================================================
  // D-Cache (Load/Store)
  // =========================================================
  dcache #(
      .Cfg(Cfg),
      .N_MSHR(DCACHE_MSHR_SIZE),
      .LD_PORT_ID_WIDTH(DCACHE_LD_ID_WIDTH)
  ) u_dcache (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .flush_i(backend_flush),

      // Load port (from LSU/MMU arbiter)
      .ld_req_valid_i(dcache_ld_req_valid),
      .ld_req_ready_o(dcache_ld_req_ready),
      .ld_req_addr_i (dcache_ld_req_addr),
      .ld_req_op_i   (dcache_ld_req_op),
      .ld_req_id_i   (dcache_ld_req_id),

      .ld_rsp_valid_o(dcache_ld_rsp_valid),
      .ld_rsp_ready_i(dcache_ld_rsp_ready),
      .ld_rsp_data_o (dcache_ld_rsp_data),
      .ld_rsp_err_o  (dcache_ld_rsp_err),
      .ld_rsp_id_o   (dcache_ld_rsp_id),

      // Store port (from SB/MMU arbiter)
      .st_req_valid_i(dcache_st_req_valid),
      .st_req_ready_o(dcache_st_req_ready),
      .st_req_addr_i (dcache_st_req_addr),
      .st_req_data_i (dcache_st_req_data),
      .st_req_op_i   (dcache_st_req_op),

      // Miss/Refill interface (to memory)
      .miss_req_valid_o     (dcache_miss_req_valid_o),
      .miss_req_ready_i     (dcache_miss_req_ready_i),
      .miss_req_paddr_o     (dcache_miss_req_paddr_o),
      .miss_req_victim_way_o(dcache_miss_req_victim_way_o),
      .miss_req_index_o     (dcache_miss_req_index_o),

      .refill_valid_i(dcache_refill_valid_i),
      .refill_ready_o(dcache_refill_ready_o),
      .refill_paddr_i(dcache_refill_paddr_i),
      .refill_way_i  (dcache_refill_way_i),
      .refill_data_i (dcache_refill_data_i),

      // Writeback
      .wb_req_valid_o(dcache_wb_req_valid_o),
      .wb_req_ready_i(dcache_wb_req_ready_i),
      .wb_req_paddr_o(dcache_wb_req_paddr_o),
      .wb_req_data_o (dcache_wb_req_data_o)
  );

endmodule
