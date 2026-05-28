// vsrc/test/tb_backend.sv
import config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;

module tb_backend (
    input logic clk_i,
    input logic rst_ni,
    input logic timer_irq_i,
    input logic ext_irq_i,
    input logic flush_from_backend,

    // Frontend -> backend
    input  logic                                         frontend_ibuf_valid,
    output logic                                         frontend_ibuf_ready,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] frontend_ibuf_instrs,
    input  logic [           Cfg.PLEN-1:0]               frontend_ibuf_pc,
    input  logic [Cfg.INSTR_PER_FETCH-1:0]               frontend_ibuf_slot_valid,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] frontend_ibuf_pred_npc,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] frontend_ibuf_ftq_id,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] frontend_ibuf_fetch_epoch,

    // D-Cache miss/refill/writeback interface
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

    // Expose commit/flush for test
    output logic [Cfg.NRET-1:0]                commit_valid_o,
    output logic [Cfg.NRET-1:0]                commit_we_o,
    output logic [Cfg.NRET-1:0][4:0]           commit_areg_o,
    output logic [Cfg.NRET-1:0][Cfg.XLEN-1:0]  commit_wdata_o,
    output logic                               bpu_update_valid_o,
    output logic [Cfg.PLEN-1:0]                bpu_update_pc_o,
    output logic                               bpu_update_is_cond_o,
    output logic                               bpu_update_taken_o,
    output logic [Cfg.PLEN-1:0]                bpu_update_target_o,
    output logic                               bpu_update_is_call_o,
    output logic                               bpu_update_is_ret_o,
    output logic                               bpu_update_is_rvc_o,
    output logic [Cfg.NRET-1:0]                bpu_ras_update_valid_o,
    output logic [Cfg.NRET-1:0]                bpu_ras_update_is_call_o,
    output logic [Cfg.NRET-1:0]                bpu_ras_update_is_ret_o,
    output logic [Cfg.NRET-1:0]                bpu_ras_update_is_rvc_o,
    output logic [Cfg.NRET-1:0][Cfg.PLEN-1:0]  bpu_ras_update_pc_o,
    output logic                               rob_flush_o,
    output logic [Cfg.PLEN-1:0]                rob_flush_pc_o,
    output logic                               dbg_dec_ready_o,
    output logic                               dbg_dec_valid_o,
    output logic                               dbg_ingress_dec_valid_o,
    output logic [((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] dbg_dec_uop0_ftq_id_o,
    output logic [2:0]                         dbg_dec_uop0_fetch_epoch_o,
    output logic [((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] dbg_bpu_update_ftq_id_o,
    output logic [2:0]                         dbg_bpu_update_fetch_epoch_o,
    output logic [7:0]                         dbg_cfg_ftq_id_bits_o,
    output logic [7:0]                         dbg_cfg_fetch_epoch_bits_o,
    output logic [7:0]                         dbg_cfg_instr_per_fetch_o,
    output logic [((Cfg.NRET > 1) ? $clog2(Cfg.NRET) : 1)-1:0] dbg_bpu_update_sel_idx_o,
    output logic                               dbg_ren_src_from_pending_o,
    output logic [2:0]                         dbg_ren_src_count_o,
    output logic                               dbg_lsu_req_ready_o,
    output logic                               dbg_lsu_issue_fire_o,
    output logic [3:0]                         dbg_lsu_grp_lane_busy_o,
    output logic                               dbg_mem_dep_replay_o,
    output logic [7:0]                         dbg_completion_q_count_o,
    output logic                               dbg_rob_head_complete_o,
    output logic                               dbg_rob_head_is_branch_o,
    output logic                               dbg_rob_head_is_jump_o,
    output logic                               dbg_alu_wb_head_hit_o,
    output logic                               dbg_alu_wb_head_hit_non_mispred_o,
    output logic                               dbg_bru_wb_head_hit_o,
    output logic                               dbg_bru_mispred_o,
    output logic                               dbg_cond_branch_wb_head_non_mispred_o,
    output logic [2:0]                         dbg_cond_branch_issue_count_o
);

  logic backend_flush_unused;
  logic [Cfg.PLEN-1:0] backend_redirect_pc_unused;
  backend #(
      .Cfg(global_config_pkg::Cfg)
  ) dut (
      .clk_i,
      .rst_ni,
      .timer_irq_i(timer_irq_i),
      .ext_irq_i(ext_irq_i),
      .flush_from_backend,
      .frontend_ibuf_valid,
      .frontend_ibuf_ready,
      .frontend_ibuf_instrs,
      .frontend_ibuf_pc,
      .frontend_ibuf_slot_valid,
      .frontend_ibuf_pred_npc,
      .frontend_ibuf_ftq_id(frontend_ibuf_ftq_id),
      .frontend_ibuf_fetch_epoch(frontend_ibuf_fetch_epoch),
      .backend_flush_o(backend_flush_unused),
      .backend_redirect_pc_o(backend_redirect_pc_unused),
      .bpu_update_valid_o(bpu_update_valid_o),
      .bpu_update_pc_o(bpu_update_pc_o),
      .bpu_update_is_cond_o(bpu_update_is_cond_o),
      .bpu_update_taken_o(bpu_update_taken_o),
      .bpu_update_target_o(bpu_update_target_o),
      .bpu_update_is_call_o(bpu_update_is_call_o),
      .bpu_update_is_ret_o(bpu_update_is_ret_o),
      .bpu_update_is_rvc_o(bpu_update_is_rvc_o),
      .bpu_ras_update_valid_o(bpu_ras_update_valid_o),
      .bpu_ras_update_is_call_o(bpu_ras_update_is_call_o),
      .bpu_ras_update_is_ret_o(bpu_ras_update_is_ret_o),
      .bpu_ras_update_is_rvc_o(bpu_ras_update_is_rvc_o),
      .bpu_ras_update_pc_o(bpu_ras_update_pc_o),
      .mmu_satp_o(),
      .mmu_priv_o(),
      .mmu_sum_o(),
      .mmu_mxr_o(),
      .mmu_sfence_vma_o(),
      .ifu_pte_ld_req_valid_i(1'b0),
      .ifu_pte_ld_req_ready_o(),
      .ifu_pte_ld_req_paddr_i('0),
      .ifu_pte_ld_rsp_valid_o(),
      .ifu_pte_ld_rsp_data_o(),
      .ifu_pte_st_req_valid_i(1'b0),
      .ifu_pte_st_req_ready_o(),
      .ifu_pte_st_req_paddr_i('0),
      .ifu_pte_st_req_data_i('0),
      .ifetch_fault_valid_i(1'b0),
      .ifetch_fault_ready_o(),
      .ifetch_fault_pc_i('0),
      .ifetch_fault_tval_i('0),
      .ifetch_fault_cause_i('0),

      .dcache_miss_req_valid_o,
      .dcache_miss_req_ready_i,
      .dcache_miss_req_paddr_o,
      .dcache_miss_req_victim_way_o,
      .dcache_miss_req_index_o,

      .dcache_refill_valid_i,
      .dcache_refill_ready_o,
      .dcache_refill_paddr_i,
      .dcache_refill_way_i,
      .dcache_refill_data_i,

      .dcache_wb_req_valid_o,
      .dcache_wb_req_ready_i,
      .dcache_wb_req_paddr_o,
      .dcache_wb_req_data_o
  );

  // Expose internal signals
  assign commit_valid_o = dut.commit_valid;
  assign commit_we_o    = dut.commit_we;
  assign commit_areg_o  = dut.commit_areg;
  assign commit_wdata_o = dut.commit_wdata;
  assign rob_flush_o    = dut.rob_flush;
  assign rob_flush_pc_o = dut.rob_flush_pc;
  assign dbg_dec_ready_o = dut.decode_backend_ready;
  assign dbg_dec_valid_o = dut.dec_valid;
  assign dbg_ingress_dec_valid_o = dut.ingress_dec_valid;
  assign dbg_dec_uop0_ftq_id_o = dut.dec_uops[0].ftq_id;
  assign dbg_dec_uop0_fetch_epoch_o = dut.dec_uops[0].fetch_epoch;
  assign dbg_bpu_update_ftq_id_o = dut.bpu_update_ftq_id_dbg;
  assign dbg_bpu_update_fetch_epoch_o = dut.bpu_update_fetch_epoch_dbg;
  assign dbg_cfg_ftq_id_bits_o = 8'(((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1));
  assign dbg_cfg_fetch_epoch_bits_o = 8'(3);
  assign dbg_cfg_instr_per_fetch_o = 8'(Cfg.INSTR_PER_FETCH);
  assign dbg_bpu_update_sel_idx_o = dut.bpu_update_sel_idx_dbg;
  assign dbg_ren_src_from_pending_o = dut.rename_src_from_pending;
  always_comb begin
    dbg_ren_src_count_o = '0;
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      if (dut.rename_src_valid[i]) begin
        dbg_ren_src_count_o++;
      end
    end
  end
  assign dbg_lsu_req_ready_o = dut.lsu_req_ready;
  assign dbg_lsu_issue_fire_o = dut.lsu_en & dut.lsu_req_ready;
  assign dbg_lsu_grp_lane_busy_o = {2'b0, dut.u_lsu_group.dbg_lane_busy};
  assign dbg_mem_dep_replay_o = dut.mem_dep_replay_valid;
  assign dbg_completion_q_count_o = dut.completion_q_count;
  // Observe ROB's effective head-complete (includes same-cycle ALU fast-visible path).
  assign dbg_rob_head_complete_o = !dut.rob_empty && dut.u_rob.head_fast_complete[0];
  assign dbg_rob_head_is_branch_o = !dut.rob_empty && dut.u_rob.rob_ram[dut.rob_head_ptr].is_branch;
  assign dbg_rob_head_is_jump_o = !dut.rob_empty && dut.u_rob.rob_ram[dut.rob_head_ptr].is_jump;
  assign dbg_alu_wb_head_hit_o =
      (dut.alu0_wb_valid && (dut.alu0_wb_tag == dut.rob_head_ptr)) ||
      (dut.alu1_wb_valid && (dut.alu1_wb_tag == dut.rob_head_ptr)) ||
      (dut.alu2_wb_valid && (dut.alu2_wb_tag == dut.rob_head_ptr)) ||
      (dut.alu3_wb_valid && (dut.alu3_wb_tag == dut.rob_head_ptr));
  assign dbg_alu_wb_head_hit_non_mispred_o =
      (dut.alu0_wb_valid && (dut.alu0_wb_tag == dut.rob_head_ptr) && !dut.alu0_mispred) ||
      (dut.alu1_wb_valid && (dut.alu1_wb_tag == dut.rob_head_ptr) && !dut.alu1_mispred) ||
      (dut.alu2_wb_valid && (dut.alu2_wb_tag == dut.rob_head_ptr) && !dut.alu2_mispred) ||
      (dut.alu3_wb_valid && (dut.alu3_wb_tag == dut.rob_head_ptr) && !dut.alu3_mispred);
  assign dbg_bru_wb_head_hit_o =
      dut.bru_wb_valid && (dut.bru_wb_tag == dut.rob_head_ptr);
  assign dbg_bru_mispred_o = dut.bru_mispred;
  assign dbg_cond_branch_wb_head_non_mispred_o =
      dbg_rob_head_is_branch_o &&
      !dbg_rob_head_is_jump_o &&
      (dbg_alu_wb_head_hit_non_mispred_o ||
       (dut.bru_wb_valid && (dut.bru_wb_tag == dut.rob_head_ptr) && !dut.bru_mispred));
  always_comb begin
    dbg_cond_branch_issue_count_o = '0;
    if (dut.bru_en && dut.bru_uop.is_branch && !dut.bru_uop.is_jump) begin
      dbg_cond_branch_issue_count_o++;
    end
    if (dut.alu0_en && dut.alu0_uop.is_branch && !dut.alu0_uop.is_jump) begin
      dbg_cond_branch_issue_count_o++;
    end
    if (dut.alu1_en && dut.alu1_uop.is_branch && !dut.alu1_uop.is_jump) begin
      dbg_cond_branch_issue_count_o++;
    end
    if (dut.alu2_en && dut.alu2_uop.is_branch && !dut.alu2_uop.is_jump) begin
      dbg_cond_branch_issue_count_o++;
    end
    if (dut.alu3_en && dut.alu3_uop.is_branch && !dut.alu3_uop.is_jump) begin
      dbg_cond_branch_issue_count_o++;
    end
  end

endmodule
