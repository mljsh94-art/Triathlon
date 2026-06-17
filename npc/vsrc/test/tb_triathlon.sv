// vsrc/test/tb_triathlon.sv
import config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;
import core_contract_pkg::*;
import debug_bus_pkg::*;

module tb_triathlon #(
    parameter int unsigned ROB_DEPTH = 64,
    parameter int unsigned ROB_IDX_W = $clog2(ROB_DEPTH),
    parameter int unsigned SB_DEPTH  = 16,
    parameter int unsigned SB_IDX_W  = $clog2(SB_DEPTH)
) (
    input logic clk_i,
    input logic rst_ni,
    input logic timer_irq_i,
    input logic ext_irq_i,

    // I-Cache miss/refill interface
    output logic                                  icache_miss_req_valid_o,
    input  logic                                  icache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] icache_miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] icache_miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] icache_miss_req_index_o,

    input  logic                                  icache_refill_valid_i,
    output logic                                  icache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] icache_refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] icache_refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] icache_refill_data_i,

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

    // MMIO Uncached Load interface
    output logic                               mmio_req_valid_o,
    input  logic                               mmio_req_ready_i,
    output logic [             Cfg.PLEN-1:0]   mmio_req_addr_o,
    output logic [$bits(decode_pkg::lsu_op_e)-1:0] mmio_req_op_o,

    input  logic                               mmio_rsp_valid_i,
    input  logic [           Cfg.XLEN-1:0]     mmio_rsp_data_i,

    // Expose commit signals for test
    output logic [Cfg.NRET-1:0]                commit_valid_o,
    output logic [Cfg.NRET-1:0]                commit_we_o,
    output logic [Cfg.NRET-1:0][4:0]           commit_areg_o,
    output logic [Cfg.NRET-1:0][Cfg.XLEN-1:0]  commit_wdata_o,
    output logic [Cfg.NRET-1:0][Cfg.PLEN-1:0]  commit_pc_o,
    output logic [Cfg.NRET-1:0][Cfg.PLEN-1:0]  commit_pred_npc_o,
    output logic [Cfg.NRET-1:0][Cfg.PLEN-1:0]  commit_actual_npc_o,
    output logic [Cfg.NRET-1:0][Cfg.ILEN-1:0]  commit_inst_o,
    output logic [Cfg.NRET-1:0][Cfg.ILEN-1:0]  commit_decoded_inst_o,
    output logic [Cfg.NRET-1:0]                commit_is_rvc_o,
    output logic [Cfg.NRET-1:0]                commit_is_branch_o,
    output logic [Cfg.NRET-1:0]                commit_is_jump_o,
    output logic [Cfg.NRET-1:0]                commit_is_call_o,
    output logic [Cfg.NRET-1:0]                commit_is_ret_o,
    output logic [Cfg.NRET-1:0][FTQ_ID_W-1:0]  commit_ftq_id_o,
    output logic [Cfg.NRET-1:0][FETCH_EPOCH_W-1:0] commit_fetch_epoch_o,
    output logic [Cfg.NRET-1:0]                commit_is_store_o,
    output logic [Cfg.NRET-1:0][SB_IDX_W-1:0]  commit_sb_id_o,
    output logic [Cfg.NRET-1:0]                commit_store_valid_o,
    output logic [Cfg.NRET-1:0][Cfg.PLEN-1:0]  commit_store_addr_o,
    output logic [Cfg.NRET-1:0][Cfg.XLEN-1:0]  commit_store_data_o,
    output logic [Cfg.NRET-1:0][$bits(decode_pkg::lsu_op_e)-1:0] commit_store_op_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mtvec_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mepc_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mstatus_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mcause_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mtval_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_sstatus_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_stvec_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_sepc_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_scause_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_stval_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_trap_tval_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_satp_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mscratch_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_sscratch_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mie_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mip_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_medeleg_o,
    output logic [Cfg.XLEN-1:0]                dbg_csr_mideleg_o,
    output logic [1:0]                         dbg_csr_priv_mode_o,
    output logic                               dbg_csr_irq_trap_o,
    output logic [Cfg.PLEN-1:0]                dbg_csr_irq_redirect_pc_o,
    output logic                               backend_flush_o,
    output logic [Cfg.PLEN-1:0]                backend_redirect_pc_o,
    output logic [Cfg.PLEN-1:0]                dbg_retire_redirect_pc_o,
    output logic                               dbg_rob_flush_o,
    output logic [4:0]                         dbg_rob_flush_cause_o,
    output logic                               dbg_rob_flush_is_mispred_o,
    output logic                               dbg_rob_flush_is_exception_o,
    output logic                               dbg_rob_flush_is_branch_o,
    output logic                               dbg_rob_flush_is_jump_o,
    output logic [Cfg.PLEN-1:0]                dbg_rob_flush_src_pc_o,

    // Debug (frontend/backend handshakes)
    output logic                               dbg_fe_valid_o,
    output logic                               dbg_fe_ready_o,
    output logic [Cfg.PLEN-1:0]                dbg_fe_pc_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] dbg_fe_instrs_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0]     dbg_fe_slot_valid_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] dbg_fe_pred_npc_o,
    output logic                               dbg_ifu_req_valid_o,
    output logic                               dbg_ifu_req_ready_o,
    output logic                               dbg_ifu_req_fire_o,
    output logic                               dbg_ifu_req_inflight_o,
    output logic                               dbg_ifu_rsp_valid_o,
    output logic                               dbg_ifu_rsp_capture_o,
    output logic                               dbg_ifu_drop_stale_rsp_o,
    output logic [2:0]                         dbg_icache_state_o,
    output logic [3:0]                         dbg_ifu_fq_count_o,
    output logic                               dbg_ifu_fq_full_o,
    output logic                               dbg_ifu_fq_empty_o,
    output logic                               dbg_ifu_fq_enq_fire_o,
    output logic                               dbg_ifu_fq_deq_fire_o,
    output logic                               dbg_ifu_fq_bypass_fire_o,
    output logic                               dbg_ifu_fq_enq_blocked_o,
    output logic                               dbg_ifu_ibuf_pop_o,
    output logic                               dbg_ifu_reqq_empty_o,
    output logic                               dbg_ifu_inf_full_o,
    output logic                               dbg_ifu_block_flush_o,
    output logic                               dbg_ifu_block_reqq_empty_o,
    output logic                               dbg_ifu_block_inf_full_o,
    output logic                               dbg_ifu_block_storage_budget_o,
    output logic                               dbg_ifu_fault_pending_o,
    output logic [1:0]                         dbg_ifu_mmu_state_o,
    output logic [2:0]                         dbg_ifu_mmu_core_state_o,
    output logic                               dbg_ifu_pte_req_valid_o,
    output logic                               dbg_ifu_pte_req_ready_o,
    output logic                               dbg_ifu_pte_rsp_valid_o,
    output logic                               dbg_ifu_pte_upd_valid_o,
    output logic                               dbg_ifu_pte_upd_ready_o,
    output logic                               dbg_mux_mmu_ld_inflight_o,
    output logic                               dbg_mux_mmu_ld_owner_o,
    output logic                               dbg_ifetch_fault_valid_o,
    output logic                               dbg_ifetch_fault_ready_o,
    output logic                               dbg_csr_en_o,
    output logic                               dbg_csr_ifetch_fault_inject_o,
    output logic                               dbg_dec_valid_o,
    output logic                               dbg_dec_ready_o,
    output logic                               dbg_rob_ready_o,
    output logic                               dbg_pipe_bus_valid_o,
    output logic                               dbg_pipe_bus_fe_valid_o,
    output logic                               dbg_pipe_bus_dec_valid_o,
    output logic                               dbg_pipe_bus_dec_ready_o,
    output logic                               dbg_pipe_bus_rob_ready_o,
    output logic                               dbg_mem_bus_valid_o,
    output logic                               dbg_mem_bus_lsu_issue_valid_o,
    output logic                               dbg_mem_bus_lsu_req_ready_o,
    output logic [7:0]                         dbg_cfg_instr_per_fetch_o,
    output logic [7:0]                         dbg_cfg_nret_o,
    output logic                               dbg_ren_src_from_pending_o,
    output logic [$clog2(Cfg.INSTR_PER_FETCH+1)-1:0] dbg_ren_src_count_o,
    output logic [$clog2(Cfg.INSTR_PER_FETCH+1)-1:0] dbg_ren_sel_count_o,
    output logic                               dbg_ren_fire_o,
    output logic                               dbg_ren_ready_o,
    // Debug (dispatch gate/capacity)
    output logic                               dbg_gate_alu_o,
    output logic                               dbg_gate_bru_o,
    output logic                               dbg_gate_lsu_o,
    output logic                               dbg_gate_mdu_o,
    output logic                               dbg_gate_csr_o,
    output logic [2:0]                         dbg_need_alu_o,
    output logic [2:0]                         dbg_need_bru_o,
    output logic [2:0]                         dbg_need_lsu_o,
    output logic [2:0]                         dbg_need_mdu_o,
    output logic [2:0]                         dbg_need_csr_o,
    output logic [$clog2(Cfg.RS_DEPTH+1)-1:0]  dbg_free_alu_o,
    output logic [$clog2(Cfg.RS_DEPTH+1)-1:0]  dbg_free_bru_o,
    output logic [$clog2(Cfg.RS_DEPTH+1)-1:0]  dbg_free_lsu_o,
    output logic [$clog2(Cfg.RS_DEPTH+1)-1:0]  dbg_free_csr_o,
    output logic                               dbg_alu_rs_ready_any_o,
    output logic                               dbg_alu_issue_any_o,
    output logic                               dbg_alu_ready_not_issued_o,
    output logic                               dbg_alu_wb_any_o,
    output logic                               dbg_alu_wb_head_hit_o,
    output logic                               dbg_bru_rs_ready_any_o,
    output logic                               dbg_bru_ready_not_issued_o,
    output logic                               dbg_bru_wb_head_hit_o,

    // Debug (LSU load path)
    output logic                               dbg_lsu_ld_req_valid_o,
    output logic                               dbg_lsu_ld_req_ready_o,
    output logic [Cfg.PLEN-1:0]                dbg_lsu_ld_req_addr_o,
    output logic                               dbg_lsu_ld_rsp_valid_o,
    output logic                               dbg_lsu_ld_rsp_ready_o,
    output logic [Cfg.XLEN-1:0]                dbg_lsu_ld_rsp_data_o,
    output logic                               dbg_lsu_ld_rsp_err_o,
    output logic [1:0]                         dbg_lsu_state_o,
    output logic                               dbg_lsu_ld_fire_o,
    output logic                               dbg_lsu_rsp_fire_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_inflight_tag_o,
    output logic [Cfg.PLEN-1:0]                dbg_lsu_inflight_addr_o,
    output logic                               dbg_lsu_issue_valid_o,
    output logic                               dbg_lsu_req_ready_o,
    output logic                               dbg_lsu_issue_ready_o,
    output logic                               dbg_lsu_issue_raw0_o,
    output logic                               dbg_lsu_issue_raw1_o,
    output logic                               dbg_lsu_issue_pick0_o,
    output logic                               dbg_lsu_issue_pick1_o,
    output logic                               dbg_lsu_issue_blk0_o,
    output logic                               dbg_lsu_issue_blk1_o,
    output logic [Cfg.PLEN-1:0]                dbg_lsu_sel_pc_o,
    output logic                               dbg_lsu_sel_is_load_o,
    output logic                               dbg_lsu_sel_is_store_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_sel_dst_o,
    output logic [$clog2(Cfg.RS_DEPTH+1)-1:0]  dbg_lsu_free_count_o,
    output logic [3:0]                         dbg_lsu_grp_lane_busy_o,
    output logic                               dbg_lsu_grp_alloc_fire_o,
    output logic [1:0]                         dbg_lsu_grp_alloc_lane_o,
    output logic [1:0]                         dbg_lsu_grp_ld_owner_o,
    output logic                               dbg_lsu_pend_valid_o,
    output logic [1:0]                         dbg_lsu_mmu_state_o,
    output logic                               dbg_lsu_load_req_ready_o,
    output logic                               dbg_lsu_store_req_ready_o,
    output logic                               dbg_lsu_lq_alloc_ready_o,
    output logic                               dbg_lsu_sq_alloc_ready_o,
    output logic [7:0]                         dbg_lsu_lq_count_o,
    output logic [7:0]                         dbg_lsu_sq_count_o,
    output logic [Cfg.RS_DEPTH-1:0]            dbg_lsu_rs_busy_o,
    output logic [Cfg.RS_DEPTH-1:0]            dbg_lsu_rs_ready_o,
    output logic [Cfg.RS_DEPTH-1:0]            dbg_lsu_rs_head_match_o,
    output logic                               dbg_lsu_rs_head_valid_o,
    output logic [$clog2(Cfg.RS_DEPTH)-1:0]    dbg_lsu_rs_head_idx_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_rs_head_dst_o,
    output logic                               dbg_lsu_rs_head_r1_ready_o,
    output logic                               dbg_lsu_rs_head_r2_ready_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_rs_head_q1_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_rs_head_q2_o,
    output logic                               dbg_lsu_rs_head_has_rs1_o,
    output logic                               dbg_lsu_rs_head_has_rs2_o,
    output logic                               dbg_lsu_rs_head_is_store_o,
    output logic                               dbg_lsu_rs_head_is_load_o,
    output logic [SB_IDX_W-1:0]                dbg_lsu_rs_head_sb_id_o,

    // Debug (Store buffer / D$ store path)
    output logic [3:0]                         dbg_sb_alloc_req_o,
    output logic                               dbg_sb_alloc_ready_o,
    output logic                               dbg_sb_alloc_fire_o,
    output logic                               dbg_sb_dcache_req_valid_o,
    output logic                               dbg_sb_dcache_req_ready_o,
    output logic [Cfg.PLEN-1:0]                dbg_sb_dcache_req_addr_o,
    output logic [Cfg.XLEN-1:0]                dbg_sb_dcache_req_data_o,
    output logic [$bits(decode_pkg::lsu_op_e)-1:0] dbg_sb_dcache_req_op_o,
    // Debug (D$ MSHR)
    output logic [7:0]                         dbg_dc_mshr_count_o,
    output logic                               dbg_dc_mshr_full_o,
    output logic                               dbg_dc_mshr_empty_o,
    output logic                               dbg_dc_mshr_alloc_ready_o,
    output logic                               dbg_dc_mshr_req_line_hit_o,
    output logic                               dbg_dc_store_wait_same_line_o,
    output logic                               dbg_dc_store_wait_mshr_full_o,

    // Debug (ROB head / count)
    output logic [$bits(decode_pkg::fu_e)-1:0] dbg_rob_head_fu_o,
    output logic                               dbg_rob_head_complete_o,
    output logic                               dbg_rob_head_is_store_o,
    output logic [Cfg.PLEN-1:0]                dbg_rob_head_pc_o,
    output logic [6:0]                         dbg_rob_count_o,
    output logic [ROB_IDX_W-1:0]               dbg_rob_head_ptr_o,
    output logic [ROB_IDX_W-1:0]               dbg_rob_tail_ptr_o,
    output logic                               dbg_rob_q2_valid_o,
    output logic [ROB_IDX_W-1:0]               dbg_rob_q2_idx_o,
    output logic [$bits(decode_pkg::fu_e)-1:0] dbg_rob_q2_fu_o,
    output logic                               dbg_rob_q2_complete_o,
    output logic                               dbg_rob_q2_is_store_o,
    output logic [Cfg.PLEN-1:0]                dbg_rob_q2_pc_o,

    // Debug (Store Buffer head / count)
    output logic [4:0]                         dbg_sb_count_o,
    output logic [3:0]                         dbg_sb_head_ptr_o,
    output logic [3:0]                         dbg_sb_tail_ptr_o,
    output logic                               dbg_sb_head_valid_o,
    output logic                               dbg_sb_head_committed_o,
    output logic                               dbg_sb_head_addr_valid_o,
    output logic                               dbg_sb_head_data_valid_o,
    output logic [Cfg.PLEN-1:0]                dbg_sb_head_addr_o,
    // Debug (BPU RAS)
    output logic [7:0]                         dbg_bpu_arch_ras_count_o,
    output logic [7:0]                         dbg_bpu_spec_ras_count_o,
    output logic [Cfg.PLEN-1:0]                dbg_bpu_arch_ras_top_o,
    output logic [Cfg.PLEN-1:0]                dbg_bpu_spec_ras_top_o,
    output logic [63:0]                        dbg_bpu_cond_update_total_o,
    output logic [63:0]                        dbg_bpu_cond_local_correct_o,
    output logic [63:0]                        dbg_bpu_cond_global_correct_o,
    output logic [63:0]                        dbg_bpu_cond_selected_correct_o,
    output logic [63:0]                        dbg_bpu_cond_choose_local_o,
    output logic [63:0]                        dbg_bpu_cond_choose_global_o,
    output logic [63:0]                        dbg_bpu_tage_lookup_total_o,
    output logic [63:0]                        dbg_bpu_tage_hit_total_o,
    output logic [63:0]                        dbg_bpu_tage_override_total_o,
    output logic [63:0]                        dbg_bpu_tage_override_correct_o,
    output logic [63:0]                        dbg_bpu_sc_lookup_total_o,
    output logic [63:0]                        dbg_bpu_sc_confident_total_o,
    output logic [63:0]                        dbg_bpu_sc_override_total_o,
    output logic [63:0]                        dbg_bpu_sc_override_correct_o,
    output logic [63:0]                        dbg_bpu_loop_lookup_total_o,
    output logic [63:0]                        dbg_bpu_loop_hit_total_o,
    output logic [63:0]                        dbg_bpu_loop_confident_total_o,
    output logic [63:0]                        dbg_bpu_loop_override_total_o,
    output logic [63:0]                        dbg_bpu_loop_override_correct_o,
    output logic [63:0]                        dbg_bpu_cond_provider_legacy_selected_o,
    output logic [63:0]                        dbg_bpu_cond_provider_tage_selected_o,
    output logic [63:0]                        dbg_bpu_cond_provider_sc_selected_o,
    output logic [63:0]                        dbg_bpu_cond_provider_loop_selected_o,
    output logic [63:0]                        dbg_bpu_cond_provider_legacy_correct_o,
    output logic [63:0]                        dbg_bpu_cond_provider_tage_correct_o,
    output logic [63:0]                        dbg_bpu_cond_provider_sc_correct_o,
    output logic [63:0]                        dbg_bpu_cond_provider_loop_correct_o,
    output logic [63:0]                        dbg_bpu_cond_selected_wrong_alt_legacy_correct_o,
    output logic [63:0]                        dbg_bpu_cond_selected_wrong_alt_tage_correct_o,
    output logic [63:0]                        dbg_bpu_cond_selected_wrong_alt_sc_correct_o,
    output logic [63:0]                        dbg_bpu_cond_selected_wrong_alt_loop_correct_o,
    output logic [63:0]                        dbg_bpu_cond_selected_wrong_alt_any_correct_o,
    output logic [63:0]                        dbg_bpu_ftb_lookup_total_o,
    output logic [63:0]                        dbg_bpu_ftb_cond_hit_total_o,
    output logic [63:0]                        dbg_bpu_ftb_jump_hit_total_o,
    output logic [63:0]                        dbg_bpu_ftb_cond_pick_total_o,
    output logic [63:0]                        dbg_bpu_ftb_jump_pick_total_o,
    output logic [63:0]                        dbg_bpu_ftb_cond_tag_miss_total_o,
    output logic [63:0]                        dbg_bpu_ftb_jump_tag_miss_total_o,
    output logic [63:0]                        dbg_bpu_ftb_train_cond_total_o,
    output logic [63:0]                        dbg_bpu_ftb_train_jump_total_o,
    output logic [63:0]                        dbg_bpu_ittage_lookup_total_o,
    output logic [63:0]                        dbg_bpu_ittage_hit_total_o,
    output logic [63:0]                        dbg_bpu_ittage_use_total_o,
    output logic [63:0]                        dbg_bpu_ittage_train_total_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_valid_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_cond_hit_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_jump_hit_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_cond_tag_miss_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_jump_tag_miss_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_any_valid_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_tag_hit_o,
    output logic [FTQ_DEPTH-1:0][2:0]          dbg_bpu_pred_snap_valid_count_o,
    output logic [FTQ_DEPTH-1:0][2:0]          dbg_bpu_pred_snap_cond_count_o,
    output logic [FTQ_DEPTH-1:0][2:0]          dbg_bpu_pred_snap_jump_count_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_cond_in_range_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_jump_in_range_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_cond_taken_pred_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_pick_cond_o,
    output logic [FTQ_DEPTH-1:0]               dbg_bpu_pred_snap_pick_jump_o,
    output logic [FTQ_DEPTH-1:0][Cfg.PLEN-1:0] dbg_bpu_pred_snap_fetch_pc_o,
    output logic [FTQ_DEPTH-1:0][FETCH_EPOCH_W-1:0] dbg_bpu_pred_snap_fetch_epoch_o,
    output logic [FTQ_DEPTH-1:0][Cfg.PLEN-1:0] dbg_bpu_pred_snap_cond_branch_pc_o,
    output logic [FTQ_DEPTH-1:0][Cfg.PLEN-1:0] dbg_bpu_pred_snap_jump_branch_pc_o,
    // Debug (BRU mispred info)
    output logic                               dbg_bru_mispred_o,
    output logic [Cfg.PLEN-1:0]                dbg_bru_pc_o,
    output logic [Cfg.XLEN-1:0]                dbg_bru_imm_o,
    output logic [$bits(decode_pkg::branch_op_e)-1:0] dbg_bru_op_o,
    output logic                               dbg_bru_is_jump_o,
    output logic                               dbg_bru_is_branch_o,
    output logic                               dbg_bru_valid_o,
    output logic                               dbg_bru_wb_valid_o,
    output logic [Cfg.PLEN-1:0]                dbg_bru_redirect_pc_o,
    output logic [Cfg.XLEN-1:0]                dbg_bru_v1_o,
    output logic [Cfg.XLEN-1:0]                dbg_bru_v2_o
);

  // localparams provided via module parameters

  triathlon #(
      .Cfg(global_config_pkg::Cfg)
  ) dut (
      .clk_i,
      .rst_ni,
      .timer_irq_i(timer_irq_i),
      .ext_irq_i(ext_irq_i),

      .icache_miss_req_valid_o,
      .icache_miss_req_ready_i,
      .icache_miss_req_paddr_o,
      .icache_miss_req_victim_way_o,
      .icache_miss_req_index_o,

      .icache_refill_valid_i,
      .icache_refill_ready_o,
      .icache_refill_paddr_i,
      .icache_refill_way_i,
      .icache_refill_data_i,

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
      .dcache_wb_req_data_o,

      .mmio_req_valid_o,
      .mmio_req_ready_i,
      .mmio_req_addr_o,
      .mmio_req_op_o,
      .mmio_rsp_valid_i,
      .mmio_rsp_data_i
  );

  // Expose backend commit signals
  assign commit_valid_o = dut.u_backend.commit_valid;
  assign commit_we_o    = dut.u_backend.commit_we;
  assign commit_areg_o  = dut.u_backend.commit_areg;
  assign commit_wdata_o = dut.u_backend.commit_wdata;
  assign commit_pc_o    = dut.u_backend.commit_pc;
  assign commit_pred_npc_o = dut.u_backend.commit_pred_npc;
  assign commit_actual_npc_o = dut.u_backend.commit_actual_npc;
  assign commit_inst_o  = dut.u_backend.commit_inst;
  assign commit_decoded_inst_o = dut.u_backend.commit_decoded_inst;
  assign commit_is_rvc_o = dut.u_backend.commit_is_rvc;
  assign commit_is_branch_o = dut.u_backend.commit_is_branch;
  assign commit_is_jump_o = dut.u_backend.commit_is_jump;
  assign commit_is_call_o = dut.u_backend.commit_is_call;
  assign commit_is_ret_o = dut.u_backend.commit_is_ret;
  assign commit_ftq_id_o = dut.u_backend.commit_ftq_id;
  assign commit_fetch_epoch_o = dut.u_backend.commit_fetch_epoch;
  assign commit_is_store_o = dut.u_backend.commit_is_store;
  assign commit_sb_id_o = dut.u_backend.commit_sb_id;
  assign dbg_csr_mtvec_o   = dut.u_backend.u_csr.csr_mtvec;
  assign dbg_csr_mepc_o    = dut.u_backend.u_csr.csr_mepc;
  assign dbg_csr_mstatus_o = dut.u_backend.u_csr.csr_mstatus;
  assign dbg_csr_mcause_o  = dut.u_backend.u_csr.csr_mcause;
  assign dbg_csr_mtval_o   = dut.u_backend.u_csr.csr_mtval;
  assign dbg_csr_sstatus_o = dut.u_backend.u_csr.csr_sstatus_view;
  assign dbg_csr_stvec_o   = dut.u_backend.u_csr.csr_stvec;
  assign dbg_csr_sepc_o    = dut.u_backend.u_csr.csr_sepc;
  assign dbg_csr_scause_o  = dut.u_backend.u_csr.csr_scause;
  assign dbg_csr_stval_o   = dut.u_backend.u_csr.csr_stval;
  assign dbg_csr_trap_tval_o = dut.u_backend.u_csr.trap_tval;
  assign dbg_csr_satp_o    = dut.u_backend.u_csr.csr_satp;
  assign dbg_csr_mscratch_o = dut.u_backend.u_csr.csr_mscratch;
  assign dbg_csr_sscratch_o = dut.u_backend.u_csr.csr_sscratch;
  assign dbg_csr_mie_o     = dut.u_backend.u_csr.csr_mie;
  assign dbg_csr_mip_o     = dut.u_backend.u_csr.csr_mip;
  assign dbg_csr_medeleg_o = dut.u_backend.u_csr.csr_medeleg;
  assign dbg_csr_mideleg_o = dut.u_backend.u_csr.csr_mideleg;
  assign dbg_csr_priv_mode_o = dut.u_backend.csr_priv_mode;
  assign dbg_csr_irq_trap_o = dut.u_backend.csr_irq_trap;
  assign dbg_csr_irq_redirect_pc_o = dut.u_backend.csr_irq_trap_redirect_pc;
  assign backend_flush_o = dut.be2fe.flush;
  assign backend_redirect_pc_o = dut.be2fe.redirect_pc;
  assign dbg_retire_redirect_pc_o = dut.u_backend.retire_redirect_pc_dbg;
  assign dbg_rob_flush_o = dut.u_backend.rob_flush;
  assign dbg_rob_flush_cause_o = dut.u_backend.rob_flush_cause;
  assign dbg_rob_flush_is_mispred_o = dut.u_backend.rob_flush_is_mispred;
  assign dbg_rob_flush_is_exception_o = dut.u_backend.rob_flush_is_exception;
  assign dbg_rob_flush_is_branch_o = dut.u_backend.rob_flush_is_branch;
  assign dbg_rob_flush_is_jump_o = dut.u_backend.rob_flush_is_jump;
  assign dbg_rob_flush_src_pc_o = dut.u_backend.rob_flush_src_pc;

  // Debug: frontend/backend handshakes
  assign dbg_fe_valid_o = dut.fe2be.valid;
  assign dbg_fe_ready_o = dut.fe2be.ready;
  assign dbg_fe_pc_o    = dut.fe2be.pcs[0];
  assign dbg_fe_instrs_o = dut.fe2be.instrs;
  assign dbg_fe_slot_valid_o = dut.fe2be.slot_valid;
  assign dbg_fe_pred_npc_o = dut.fe2be.pred_npc;
  assign dbg_ifu_req_valid_o = dut.u_frontend.i_ifu.req_issue_valid_w;
  assign dbg_ifu_req_ready_o = dut.u_frontend.icache2ifu_rsp_handshake.ready;
  assign dbg_ifu_req_fire_o = dut.u_frontend.i_ifu.req_issue_fire_w;
  assign dbg_ifu_req_inflight_o = (dut.u_frontend.i_ifu.inf_count_q != '0);
  assign dbg_ifu_rsp_valid_o = dut.u_frontend.icache2ifu_rsp_handshake.valid;
  assign dbg_ifu_rsp_capture_o = dut.u_frontend.i_ifu.rsp_capture_w;
  assign dbg_ifu_drop_stale_rsp_o = dut.u_frontend.i_ifu.drop_stale_rsp_w;
  assign dbg_icache_state_o = dut.u_frontend.i_icache.state_q;
  assign dbg_ifu_fq_count_o = dut.u_frontend.i_ifu.fq_count_q;
  assign dbg_ifu_fq_full_o = dut.u_frontend.i_ifu.fq_full_w;
  assign dbg_ifu_fq_empty_o = dut.u_frontend.i_ifu.fq_empty_w;
  assign dbg_ifu_fq_enq_fire_o = dut.u_frontend.i_ifu.rsp_push_fq_w;
  assign dbg_ifu_fq_deq_fire_o = dut.u_frontend.i_ifu.fq_deq_valid_w & dut.u_frontend.i_ifu.fq_deq_ready_w;
  assign dbg_ifu_fq_bypass_fire_o = dut.u_frontend.i_ifu.fq_empty_w &
                                     dut.u_frontend.i_ifu.fq_enq_valid_w &
                                     dut.u_frontend.i_ifu.fq_deq_ready_w;
  assign dbg_ifu_fq_enq_blocked_o = dut.u_frontend.i_ifu.fq_enq_valid_w & ~dut.u_frontend.i_ifu.fq_enq_ready_w;
  assign dbg_ifu_ibuf_pop_o = dut.u_frontend.i_ifu.ibuf_pop_w;
  assign dbg_ifu_reqq_empty_o = dut.u_frontend.i_ifu.req_fifo_empty_w;
  assign dbg_ifu_inf_full_o = dut.u_frontend.i_ifu.inf_fifo_full_w;
  assign dbg_ifu_block_flush_o = dut.u_frontend.i_ifu.req_block_flush_w;
  assign dbg_ifu_block_reqq_empty_o = dut.u_frontend.i_ifu.req_block_reqq_empty_w;
  assign dbg_ifu_block_inf_full_o = dut.u_frontend.i_ifu.req_block_inf_full_w;
  assign dbg_ifu_block_storage_budget_o = dut.u_frontend.i_ifu.req_block_storage_budget_w;
  assign dbg_ifu_fault_pending_o = dut.u_frontend.i_ifu.fault_pending_q;
  assign dbg_ifu_mmu_state_o = dut.u_frontend.i_ifu.mmu_state_q;
  assign dbg_ifu_mmu_core_state_o = dut.u_frontend.i_ifu.u_ifu_mmu.state_q;
  assign dbg_ifu_pte_req_valid_o = dut.ifu_pte_req_valid;
  assign dbg_ifu_pte_req_ready_o = dut.ifu_pte_req_ready;
  assign dbg_ifu_pte_rsp_valid_o = dut.ifu_pte_rsp_valid;
  assign dbg_ifu_pte_upd_valid_o = dut.ifu_pte_upd_valid;
  assign dbg_ifu_pte_upd_ready_o = dut.ifu_pte_upd_ready;
  assign dbg_mux_mmu_ld_inflight_o = dut.u_backend.u_mmu_dcache_mux.mmu_ld_inflight_q;
  assign dbg_mux_mmu_ld_owner_o = dut.u_backend.u_mmu_dcache_mux.mmu_ld_owner_q;
  assign dbg_ifetch_fault_valid_o = dut.ifetch_fault_valid;
  assign dbg_ifetch_fault_ready_o = dut.ifetch_fault_ready;
  assign dbg_csr_en_o = dut.u_backend.csr_en;
  assign dbg_csr_ifetch_fault_inject_o = dut.u_backend.csr_ifetch_fault_inject;
  assign dbg_dec_valid_o = dut.fe2be.valid;
  assign dbg_dec_ready_o = dut.fe2be.ready;
  assign dbg_rob_ready_o = dut.u_backend.rob_ready;
  pipe_dbg_t pipe_bus;
  mem_dbg_t mem_bus;
  assign pipe_bus.valid = 1'b1;
  assign pipe_bus.fe_valid = dbg_fe_valid_o;
  assign pipe_bus.dec_valid = dbg_dec_valid_o;
  assign pipe_bus.dec_ready = dbg_dec_ready_o;
  assign pipe_bus.rob_ready = dbg_rob_ready_o;
  assign mem_bus.valid = 1'b1;
  assign mem_bus.lsu_issue_valid = dut.u_backend.lsu_en;
  assign mem_bus.lsu_req_ready = dut.u_backend.lsu_req_ready;
  assign dbg_pipe_bus_valid_o = pipe_bus.valid;
  assign dbg_pipe_bus_fe_valid_o = pipe_bus.fe_valid;
  assign dbg_pipe_bus_dec_valid_o = pipe_bus.dec_valid;
  assign dbg_pipe_bus_dec_ready_o = pipe_bus.dec_ready;
  assign dbg_pipe_bus_rob_ready_o = pipe_bus.rob_ready;
  assign dbg_mem_bus_valid_o = mem_bus.valid;
  assign dbg_mem_bus_lsu_issue_valid_o = mem_bus.lsu_issue_valid;
  assign dbg_mem_bus_lsu_req_ready_o = mem_bus.lsu_req_ready;
  assign dbg_cfg_instr_per_fetch_o = 8'(Cfg.INSTR_PER_FETCH);
  assign dbg_cfg_nret_o = 8'(Cfg.NRET);
  assign dbg_ren_src_from_pending_o = dut.u_backend.rename_src_from_pending;
  assign dbg_ren_sel_count_o = dut.u_backend.rename_sel_count;
  assign dbg_ren_fire_o = dut.u_backend.rename_fire;
  assign dbg_ren_ready_o = dut.u_backend.rename_ready;

  always_comb begin
    dbg_ren_src_count_o = '0;
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      if (dut.u_backend.rename_src_valid[i]) begin
        dbg_ren_src_count_o++;
      end
    end
  end

  assign dbg_gate_alu_o = dut.u_backend.alu_can_accept;
  assign dbg_gate_bru_o = dut.u_backend.bru_can_accept;
  assign dbg_gate_lsu_o = dut.u_backend.lsu_can_accept;
  assign dbg_gate_mdu_o = dut.u_backend.mdu_can_accept;
  assign dbg_gate_csr_o = dut.u_backend.csr_can_accept;
  assign dbg_need_alu_o = dut.u_backend.alu_need_cnt;
  assign dbg_need_bru_o = dut.u_backend.bru_need_cnt;
  assign dbg_need_lsu_o = dut.u_backend.lsu_need_cnt;
  assign dbg_need_mdu_o = dut.u_backend.mdu_need_cnt;
  assign dbg_need_csr_o = dut.u_backend.csr_need_cnt;
  assign dbg_free_alu_o = dut.u_backend.alu_free_count;
  assign dbg_free_bru_o = dut.u_backend.bru_free_count;
  assign dbg_free_lsu_o = dut.u_backend.lsu_free_count;
  assign dbg_free_csr_o = dut.u_backend.csr_free_count;

  logic alu_rs_ready_any;
  logic alu_issue_any;
  logic alu_wb_any;
  logic alu_wb_head_hit;
  logic bru_rs_ready_any;
  logic bru_wb_head_hit;

  assign alu_rs_ready_any = |dut.u_backend.u_issue_alu.rs_ready_wires;
  assign alu_issue_any = dut.u_backend.alu0_en | dut.u_backend.alu1_en |
                         dut.u_backend.alu2_en | dut.u_backend.alu3_en;
  assign alu_wb_any = dut.u_backend.alu0_wb_valid | dut.u_backend.alu1_wb_valid |
                      dut.u_backend.alu2_wb_valid | dut.u_backend.alu3_wb_valid;
  assign alu_wb_head_hit =
      (dut.u_backend.alu0_wb_valid && (dut.u_backend.alu0_wb_tag == dut.u_backend.rob_head_ptr)) ||
      (dut.u_backend.alu1_wb_valid && (dut.u_backend.alu1_wb_tag == dut.u_backend.rob_head_ptr)) ||
      (dut.u_backend.alu2_wb_valid && (dut.u_backend.alu2_wb_tag == dut.u_backend.rob_head_ptr)) ||
      (dut.u_backend.alu3_wb_valid && (dut.u_backend.alu3_wb_tag == dut.u_backend.rob_head_ptr));

  assign bru_rs_ready_any = |dut.u_backend.u_issue_bru.rs_ready_wires;
  assign bru_wb_head_hit = dut.u_backend.bru_wb_valid &&
                           (dut.u_backend.bru_wb_tag == dut.u_backend.rob_head_ptr);

  assign dbg_alu_rs_ready_any_o = alu_rs_ready_any;
  assign dbg_alu_issue_any_o = alu_issue_any;
  assign dbg_alu_ready_not_issued_o = alu_rs_ready_any && !alu_issue_any;
  assign dbg_alu_wb_any_o = alu_wb_any;
  assign dbg_alu_wb_head_hit_o = alu_wb_head_hit;
  assign dbg_bru_rs_ready_any_o = bru_rs_ready_any;
  assign dbg_bru_ready_not_issued_o = bru_rs_ready_any && !dut.u_backend.bru_en;
  assign dbg_bru_wb_head_hit_o = bru_wb_head_hit;

  // Debug: LSU load path
  assign dbg_lsu_ld_req_valid_o = dut.u_backend.lsu_ld_req_valid;
  assign dbg_lsu_ld_req_ready_o = dut.u_backend.lsu_ld_req_ready;
  assign dbg_lsu_ld_req_addr_o  = dut.u_backend.lsu_ld_req_addr;
  assign dbg_lsu_ld_rsp_valid_o = dut.u_backend.lsu_ld_rsp_valid;
  assign dbg_lsu_ld_rsp_ready_o = dut.u_backend.lsu_ld_rsp_ready;
  assign dbg_lsu_ld_rsp_data_o  = dut.u_backend.lsu_ld_rsp_data;
  assign dbg_lsu_ld_rsp_err_o   = dut.u_backend.lsu_ld_rsp_err;
  assign dbg_lsu_state_o        = dut.u_backend.u_lsu_group.state_q;
  assign dbg_lsu_ld_fire_o      = dut.u_backend.lsu_ld_req_valid & dut.u_backend.lsu_ld_req_ready;
  assign dbg_lsu_rsp_fire_o     = dut.u_backend.lsu_ld_rsp_valid & dut.u_backend.lsu_ld_rsp_ready;
  assign dbg_lsu_inflight_tag_o = dut.u_backend.u_lsu_group.req_tag_q;
  assign dbg_lsu_inflight_addr_o = dut.u_backend.u_lsu_group.req_addr_q;
  assign dbg_lsu_issue_valid_o  = dut.u_backend.lsu_en;
  assign dbg_lsu_req_ready_o    = dut.u_backend.lsu_req_ready;
  assign dbg_lsu_issue_ready_o  = dut.u_backend.lsu_issue_ready;
  assign dbg_lsu_issue_raw0_o   = dut.u_backend.u_issue_lsu.issue_valid_raw[0];
  assign dbg_lsu_issue_raw1_o   = dut.u_backend.u_issue_lsu.issue_valid_raw[1];
  assign dbg_lsu_issue_pick0_o  = dut.u_backend.u_issue_lsu.issue_pick_0;
  assign dbg_lsu_issue_pick1_o  = dut.u_backend.u_issue_lsu.issue_pick_1;
  assign dbg_lsu_issue_blk0_o   = dut.u_backend.u_issue_lsu.issue_blocked_low_addr_spec_0;
  assign dbg_lsu_issue_blk1_o   = dut.u_backend.u_issue_lsu.issue_blocked_low_addr_spec_1;
  assign dbg_lsu_sel_pc_o       = dut.u_backend.lsu_uop.pc;
  assign dbg_lsu_sel_is_load_o  = dut.u_backend.lsu_uop.is_load;
  assign dbg_lsu_sel_is_store_o = dut.u_backend.lsu_uop.is_store;
  assign dbg_lsu_sel_dst_o      = dut.u_backend.lsu_dst;
  assign dbg_lsu_free_count_o   = dut.u_backend.lsu_free_count;
  assign dbg_lsu_grp_lane_busy_o = dut.u_backend.u_lsu_group.dbg_lane_busy;
  assign dbg_lsu_grp_alloc_fire_o = dut.u_backend.u_lsu_group.dbg_alloc_fire;
  assign dbg_lsu_grp_alloc_lane_o = dut.u_backend.u_lsu_group.dbg_alloc_lane;
  assign dbg_lsu_grp_ld_owner_o = dut.u_backend.u_lsu_group.dbg_ld_owner;
  assign dbg_lsu_pend_valid_o = dut.u_backend.u_lsu_group.pend_valid_q;
  assign dbg_lsu_mmu_state_o = dut.u_backend.u_lsu_group.mmu_state_q;
  assign dbg_lsu_load_req_ready_o = dut.u_backend.u_lsu_group.load_req_ready;
  assign dbg_lsu_store_req_ready_o = dut.u_backend.u_lsu_group.store_req_ready;
  assign dbg_lsu_lq_alloc_ready_o = dut.u_backend.u_lsu_group.lq_alloc_ready;
  assign dbg_lsu_sq_alloc_ready_o = dut.u_backend.u_lsu_group.sq_alloc_ready;
  assign dbg_lsu_lq_count_o = dut.u_backend.u_lsu_group.dbg_lq_count_o;
  assign dbg_lsu_sq_count_o = dut.u_backend.u_lsu_group.dbg_sq_count_o;
  assign dbg_lsu_rs_busy_o      = dut.u_backend.u_issue_lsu.u_rs.busy;
  assign dbg_lsu_rs_ready_o     = dut.u_backend.u_issue_lsu.u_rs.ready_mask;

  logic [Cfg.RS_DEPTH-1:0] lsu_rs_head_match;
  logic lsu_rs_head_found;
  logic [$clog2(Cfg.RS_DEPTH)-1:0] lsu_rs_head_idx;

  always_comb begin
    lsu_rs_head_match = '0;
    for (int i = 0; i < Cfg.RS_DEPTH; i++) begin
      if (dut.u_backend.u_issue_lsu.u_rs.busy[i] &&
          (dut.u_backend.u_issue_lsu.u_rs.dst_arr[i] == dut.u_backend.rob_head_ptr)) begin
        lsu_rs_head_match[i] = 1'b1;
      end
    end
  end

  always_comb begin
    lsu_rs_head_found = 1'b0;
    lsu_rs_head_idx = '0;
    for (int i = 0; i < Cfg.RS_DEPTH; i++) begin
      if (!lsu_rs_head_found && lsu_rs_head_match[i]) begin
        lsu_rs_head_found = 1'b1;
        lsu_rs_head_idx = i[$clog2(Cfg.RS_DEPTH)-1:0];
      end
    end
  end

  assign dbg_lsu_rs_head_match_o = lsu_rs_head_match;
  assign dbg_lsu_rs_head_valid_o = lsu_rs_head_found;
  assign dbg_lsu_rs_head_idx_o   = lsu_rs_head_idx;
  assign dbg_lsu_rs_head_dst_o   = lsu_rs_head_found
                                  ? dut.u_backend.u_issue_lsu.u_rs.dst_arr[lsu_rs_head_idx]
                                  : '0;
  assign dbg_lsu_rs_head_r1_ready_o = lsu_rs_head_found
                                     ? dut.u_backend.u_issue_lsu.u_rs.r1_arr[lsu_rs_head_idx]
                                     : 1'b0;
  assign dbg_lsu_rs_head_r2_ready_o = lsu_rs_head_found
                                     ? dut.u_backend.u_issue_lsu.u_rs.r2_arr[lsu_rs_head_idx]
                                     : 1'b0;
  assign dbg_lsu_rs_head_q1_o = lsu_rs_head_found
                              ? dut.u_backend.u_issue_lsu.u_rs.q1_arr[lsu_rs_head_idx]
                              : '0;
  assign dbg_lsu_rs_head_q2_o = lsu_rs_head_found
                              ? dut.u_backend.u_issue_lsu.u_rs.q2_arr[lsu_rs_head_idx]
                              : '0;
  assign dbg_lsu_rs_head_has_rs1_o = lsu_rs_head_found
                                   ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].has_rs1
                                   : 1'b0;
  assign dbg_lsu_rs_head_has_rs2_o = lsu_rs_head_found
                                   ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].has_rs2
                                   : 1'b0;
  assign dbg_lsu_rs_head_is_store_o = lsu_rs_head_found
                                    ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].is_store
                                    : 1'b0;
  assign dbg_lsu_rs_head_is_load_o = lsu_rs_head_found
                                   ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].is_load
                                   : 1'b0;
  assign dbg_lsu_rs_head_sb_id_o = lsu_rs_head_found
                                 ? dut.u_backend.u_issue_lsu.u_rs.sb_arr[lsu_rs_head_idx]
                                 : '0;

  // Debug: Store buffer / D$ store path
  assign dbg_sb_alloc_req_o = dut.u_backend.sb_alloc_req;
  assign dbg_sb_alloc_ready_o = dut.u_backend.sb_alloc_ready;
  assign dbg_sb_alloc_fire_o  = dut.u_backend.sb_alloc_fire;
  assign dbg_sb_dcache_req_valid_o = dut.u_backend.sb_dcache_req_valid;
  assign dbg_sb_dcache_req_ready_o = dut.u_backend.sb_dcache_req_ready;
  assign dbg_sb_dcache_req_addr_o  = dut.u_backend.sb_dcache_req_addr;
  assign dbg_sb_dcache_req_data_o  = dut.u_backend.sb_dcache_req_data;
  assign dbg_sb_dcache_req_op_o    = dut.u_backend.sb_dcache_req_op;
  always_comb begin
    commit_store_valid_o = '0;
    commit_store_addr_o  = '0;
    commit_store_data_o  = '0;
    commit_store_op_o    = '0;
    for (int i = 0; i < Cfg.NRET; i++) begin
      if (dut.u_backend.commit_valid[i] && dut.u_backend.commit_is_store[i]) begin
        commit_store_valid_o[i] =
            dut.u_backend.u_sb.mem[dut.u_backend.commit_sb_id[i]].addr_valid &&
            dut.u_backend.u_sb.mem[dut.u_backend.commit_sb_id[i]].data_valid;
        commit_store_addr_o[i] = dut.u_backend.u_sb.mem[dut.u_backend.commit_sb_id[i]].addr;
        commit_store_data_o[i] = dut.u_backend.u_sb.mem[dut.u_backend.commit_sb_id[i]].data;
        commit_store_op_o[i]   = dut.u_backend.u_sb.mem[dut.u_backend.commit_sb_id[i]].op;
      end
    end
  end
  assign dbg_dc_mshr_count_o = {4'b0, dut.u_backend.u_dcache.mshr_count};
  assign dbg_dc_mshr_full_o = dut.u_backend.u_dcache.mshr_full;
  assign dbg_dc_mshr_empty_o = dut.u_backend.u_dcache.mshr_empty;
  assign dbg_dc_mshr_alloc_ready_o = dut.u_backend.u_dcache.mshr_alloc_ready;
  assign dbg_dc_mshr_req_line_hit_o = dut.u_backend.u_dcache.mshr_req_line_hit;
  assign dbg_dc_store_wait_same_line_o =
      dut.u_backend.sb_dcache_req_valid &&
      !dut.u_backend.sb_dcache_req_ready &&
      dut.u_backend.u_dcache.mshr_req_line_hit;
  assign dbg_dc_store_wait_mshr_full_o =
      dut.u_backend.sb_dcache_req_valid &&
      !dut.u_backend.sb_dcache_req_ready &&
      !dut.u_backend.u_dcache.mshr_alloc_ready;

  // Debug: ROB head state
  assign dbg_rob_head_fu_o       = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].fu_type;
  assign dbg_rob_head_complete_o = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].complete;
  assign dbg_rob_head_is_store_o = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].is_store;
  assign dbg_rob_head_pc_o       = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].pc;
  assign dbg_rob_count_o         = dut.u_backend.u_rob.count_q;
  assign dbg_rob_head_ptr_o      = dut.u_backend.u_rob.head_ptr_q;
  assign dbg_rob_tail_ptr_o      = dut.u_backend.u_rob.tail_ptr_q;

  logic [ROB_IDX_W-1:0] rob_q2_idx;
  always_comb begin
    if (lsu_rs_head_found) begin
      rob_q2_idx = dut.u_backend.u_issue_lsu.u_rs.q2_arr[lsu_rs_head_idx];
    end else begin
      rob_q2_idx = '0;
    end
  end

  assign dbg_rob_q2_valid_o = lsu_rs_head_found;
  assign dbg_rob_q2_idx_o   = rob_q2_idx;
  assign dbg_rob_q2_fu_o    = lsu_rs_head_found
                              ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].fu_type
                              : '0;
  assign dbg_rob_q2_complete_o = lsu_rs_head_found
                                ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].complete
                                : 1'b0;
  assign dbg_rob_q2_is_store_o = lsu_rs_head_found
                                ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].is_store
                                : 1'b0;
  assign dbg_rob_q2_pc_o       = lsu_rs_head_found
                                ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].pc
                                : '0;

  // Debug: Store Buffer head state
  assign dbg_sb_count_o          = dut.u_backend.u_sb.count;
  assign dbg_sb_head_ptr_o       = dut.u_backend.u_sb.head_ptr;
  assign dbg_sb_tail_ptr_o       = dut.u_backend.u_sb.tail_ptr;
  assign dbg_sb_head_valid_o     = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].valid;
  assign dbg_sb_head_committed_o = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].committed;
  assign dbg_sb_head_addr_valid_o = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].addr_valid;
  assign dbg_sb_head_data_valid_o = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].data_valid;
  assign dbg_sb_head_addr_o      = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].addr;
  assign dbg_bpu_arch_ras_count_o = {3'b0, dut.u_frontend.i_bpu.arch_ras_count_q};
  assign dbg_bpu_spec_ras_count_o = {3'b0, dut.u_frontend.i_bpu.spec_ras_count_q};
  assign dbg_bpu_arch_ras_top_o = dut.u_frontend.i_bpu.arch_ras_top_w;
  assign dbg_bpu_spec_ras_top_o = dut.u_frontend.i_bpu.spec_ras_top_w;
  assign dbg_bpu_cond_update_total_o = dut.u_frontend.i_bpu.dbg_cond_update_total_q;
  assign dbg_bpu_cond_local_correct_o = dut.u_frontend.i_bpu.dbg_cond_local_correct_q;
  assign dbg_bpu_cond_global_correct_o = dut.u_frontend.i_bpu.dbg_cond_global_correct_q;
  assign dbg_bpu_cond_selected_correct_o = dut.u_frontend.i_bpu.dbg_cond_selected_correct_q;
  assign dbg_bpu_cond_choose_local_o = dut.u_frontend.i_bpu.dbg_cond_choose_local_q;
  assign dbg_bpu_cond_choose_global_o = dut.u_frontend.i_bpu.dbg_cond_choose_global_q;
  assign dbg_bpu_tage_lookup_total_o = dut.u_frontend.i_bpu.dbg_tage_lookup_total_q;
  assign dbg_bpu_tage_hit_total_o = dut.u_frontend.i_bpu.dbg_tage_hit_total_q;
  assign dbg_bpu_tage_override_total_o = dut.u_frontend.i_bpu.dbg_tage_override_total_q;
  assign dbg_bpu_tage_override_correct_o = dut.u_frontend.i_bpu.dbg_tage_override_correct_q;
  assign dbg_bpu_sc_lookup_total_o = dut.u_frontend.i_bpu.dbg_sc_lookup_total_q;
  assign dbg_bpu_sc_confident_total_o = dut.u_frontend.i_bpu.dbg_sc_confident_total_q;
  assign dbg_bpu_sc_override_total_o = dut.u_frontend.i_bpu.dbg_sc_override_total_q;
  assign dbg_bpu_sc_override_correct_o = dut.u_frontend.i_bpu.dbg_sc_override_correct_q;
  assign dbg_bpu_loop_lookup_total_o = dut.u_frontend.i_bpu.dbg_loop_lookup_total_q;
  assign dbg_bpu_loop_hit_total_o = dut.u_frontend.i_bpu.dbg_loop_hit_total_q;
  assign dbg_bpu_loop_confident_total_o = dut.u_frontend.i_bpu.dbg_loop_confident_total_q;
  assign dbg_bpu_loop_override_total_o = dut.u_frontend.i_bpu.dbg_loop_override_total_q;
  assign dbg_bpu_loop_override_correct_o = dut.u_frontend.i_bpu.dbg_loop_override_correct_q;
  assign dbg_bpu_cond_provider_legacy_selected_o =
      dut.u_frontend.i_bpu.dbg_cond_provider_legacy_selected_q;
  assign dbg_bpu_cond_provider_tage_selected_o =
      dut.u_frontend.i_bpu.dbg_cond_provider_tage_selected_q;
  assign dbg_bpu_cond_provider_sc_selected_o =
      dut.u_frontend.i_bpu.dbg_cond_provider_sc_selected_q;
  assign dbg_bpu_cond_provider_loop_selected_o =
      dut.u_frontend.i_bpu.dbg_cond_provider_loop_selected_q;
  assign dbg_bpu_cond_provider_legacy_correct_o =
      dut.u_frontend.i_bpu.dbg_cond_provider_legacy_correct_q;
  assign dbg_bpu_cond_provider_tage_correct_o =
      dut.u_frontend.i_bpu.dbg_cond_provider_tage_correct_q;
  assign dbg_bpu_cond_provider_sc_correct_o =
      dut.u_frontend.i_bpu.dbg_cond_provider_sc_correct_q;
  assign dbg_bpu_cond_provider_loop_correct_o =
      dut.u_frontend.i_bpu.dbg_cond_provider_loop_correct_q;
  assign dbg_bpu_cond_selected_wrong_alt_legacy_correct_o =
      dut.u_frontend.i_bpu.dbg_cond_selected_wrong_alt_legacy_correct_q;
  assign dbg_bpu_cond_selected_wrong_alt_tage_correct_o =
      dut.u_frontend.i_bpu.dbg_cond_selected_wrong_alt_tage_correct_q;
  assign dbg_bpu_cond_selected_wrong_alt_sc_correct_o =
      dut.u_frontend.i_bpu.dbg_cond_selected_wrong_alt_sc_correct_q;
  assign dbg_bpu_cond_selected_wrong_alt_loop_correct_o =
      dut.u_frontend.i_bpu.dbg_cond_selected_wrong_alt_loop_correct_q;
  assign dbg_bpu_cond_selected_wrong_alt_any_correct_o =
      dut.u_frontend.i_bpu.dbg_cond_selected_wrong_alt_any_correct_q;
  assign dbg_bpu_ftb_lookup_total_o = dut.u_frontend.i_bpu.dbg_ftb_lookup_total_q;
  assign dbg_bpu_ftb_cond_hit_total_o = dut.u_frontend.i_bpu.dbg_ftb_cond_hit_total_q;
  assign dbg_bpu_ftb_jump_hit_total_o = dut.u_frontend.i_bpu.dbg_ftb_jump_hit_total_q;
  assign dbg_bpu_ftb_cond_pick_total_o = dut.u_frontend.i_bpu.dbg_ftb_cond_pick_total_q;
  assign dbg_bpu_ftb_jump_pick_total_o = dut.u_frontend.i_bpu.dbg_ftb_jump_pick_total_q;
  assign dbg_bpu_ftb_cond_tag_miss_total_o = dut.u_frontend.i_bpu.dbg_ftb_cond_tag_miss_total_q;
  assign dbg_bpu_ftb_jump_tag_miss_total_o = dut.u_frontend.i_bpu.dbg_ftb_jump_tag_miss_total_q;
  assign dbg_bpu_ftb_train_cond_total_o = dut.u_frontend.i_bpu.dbg_ftb_train_cond_total_q;
  assign dbg_bpu_ftb_train_jump_total_o = dut.u_frontend.i_bpu.dbg_ftb_train_jump_total_q;
  assign dbg_bpu_ittage_lookup_total_o = dut.u_frontend.i_bpu.dbg_ittage_lookup_total_q;
  assign dbg_bpu_ittage_hit_total_o = dut.u_frontend.i_bpu.dbg_ittage_hit_total_q;
  assign dbg_bpu_ittage_use_total_o = dut.u_frontend.i_bpu.dbg_ittage_use_total_q;
  assign dbg_bpu_ittage_train_total_o = dut.u_frontend.i_bpu.dbg_ittage_train_total_q;
  assign dbg_bpu_pred_snap_valid_o = dut.u_frontend.i_bpu.pred_snap_valid_q;
  assign dbg_bpu_pred_snap_cond_hit_o = dut.u_frontend.i_bpu.pred_snap_cond_hit_q;
  assign dbg_bpu_pred_snap_jump_hit_o = dut.u_frontend.i_bpu.pred_snap_jump_hit_q;
  assign dbg_bpu_pred_snap_cond_tag_miss_o = dut.u_frontend.i_bpu.pred_snap_cond_tag_miss_q;
  assign dbg_bpu_pred_snap_jump_tag_miss_o = dut.u_frontend.i_bpu.pred_snap_jump_tag_miss_q;
  assign dbg_bpu_pred_snap_any_valid_o = dut.u_frontend.i_bpu.pred_snap_any_valid_q;
  assign dbg_bpu_pred_snap_tag_hit_o = dut.u_frontend.i_bpu.pred_snap_tag_hit_q;
  assign dbg_bpu_pred_snap_valid_count_o = dut.u_frontend.i_bpu.pred_snap_valid_count_q;
  assign dbg_bpu_pred_snap_cond_count_o = dut.u_frontend.i_bpu.pred_snap_cond_count_q;
  assign dbg_bpu_pred_snap_jump_count_o = dut.u_frontend.i_bpu.pred_snap_jump_count_q;
  assign dbg_bpu_pred_snap_cond_in_range_o = dut.u_frontend.i_bpu.pred_snap_cond_in_range_q;
  assign dbg_bpu_pred_snap_jump_in_range_o = dut.u_frontend.i_bpu.pred_snap_jump_in_range_q;
  assign dbg_bpu_pred_snap_cond_taken_pred_o = dut.u_frontend.i_bpu.pred_snap_cond_taken_pred_q;
  assign dbg_bpu_pred_snap_pick_cond_o = dut.u_frontend.i_bpu.pred_snap_pick_cond_q;
  assign dbg_bpu_pred_snap_pick_jump_o = dut.u_frontend.i_bpu.pred_snap_pick_jump_q;
  assign dbg_bpu_pred_snap_fetch_pc_o = dut.u_frontend.i_bpu.pred_snap_fetch_pc_q;
  assign dbg_bpu_pred_snap_fetch_epoch_o = dut.u_frontend.i_bpu.pred_snap_fetch_epoch_q;
  assign dbg_bpu_pred_snap_cond_branch_pc_o = dut.u_frontend.i_bpu.pred_snap_cond_branch_pc_q;
  assign dbg_bpu_pred_snap_jump_branch_pc_o = dut.u_frontend.i_bpu.pred_snap_jump_branch_pc_q;

  // Debug: BRU info (from backend execute)
  assign dbg_bru_mispred_o  = dut.u_backend.bru_mispred;
  assign dbg_bru_pc_o       = dut.u_backend.bru_uop.pc;
  assign dbg_bru_imm_o      = dut.u_backend.bru_uop.imm;
  assign dbg_bru_op_o       = dut.u_backend.bru_uop.br_op;
  assign dbg_bru_is_jump_o  = dut.u_backend.bru_uop.is_jump;
  assign dbg_bru_is_branch_o = dut.u_backend.bru_uop.is_branch;
  assign dbg_bru_valid_o    = dut.u_backend.bru_en;
  assign dbg_bru_wb_valid_o = dut.u_backend.bru_wb_valid;
  assign dbg_bru_redirect_pc_o = dut.u_backend.bru_redirect_pc;
  assign dbg_bru_v1_o = dut.u_backend.bru_v1;
  assign dbg_bru_v2_o = dut.u_backend.bru_v2;

endmodule
