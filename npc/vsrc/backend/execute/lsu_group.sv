// vsrc/backend/execute/lsu_group.sv
import config_pkg::*;
import decode_pkg::*;

module lsu_group #(
    parameter config_pkg::cfg_t Cfg           = config_pkg::EmptyCfg,
    parameter int unsigned      ROB_IDX_WIDTH = 6,
    parameter int unsigned      SB_DEPTH      = 32,
    parameter int unsigned      SB_IDX_WIDTH  = $clog2(SB_DEPTH),
    parameter int unsigned      LQ_DEPTH      = 16,
    parameter int unsigned      SQ_DEPTH      = 16,
    parameter int unsigned      N_LSU         = 1,
    parameter int unsigned      COMMIT_WIDTH  = 4,
    parameter int unsigned      ECAUSE_WIDTH  = 5,
    // Writeback experiment: widen LSU completion to LSU_WB_PORTS CDB ports.
    // Ports [0 .. LOAD_WB_PORTS-1] carry load-lane writebacks (arbiter grants
    // up to LOAD_WB_PORTS distinct lanes per cycle); the final port carries the
    // store-writeback queue head. LSU_WB_PORTS = LOAD_WB_PORTS + 1.
    parameter int unsigned      LOAD_WB_PORTS = 2,
    parameter int unsigned      LSU_WB_PORTS  = LOAD_WB_PORTS + 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // ROB commit broadcast: used to free LQ entries (loads live until retire).
    input logic [COMMIT_WIDTH-1:0]                    commit_valid_i,
    input logic [COMMIT_WIDTH-1:0][ROB_IDX_WIDTH-1:0] commit_rob_idx_i,

    // =========================================================
    // 1) Request from Issue/Execute
    // =========================================================
    input  logic                                 req_valid_i,
    output logic                                 req_ready_o,
    input  decode_pkg::uop_t                     uop_i,
    input  logic             [     Cfg.XLEN-1:0] rs1_data_i,
    input  logic             [     Cfg.XLEN-1:0] rs2_data_i,
    input  logic             [ROB_IDX_WIDTH-1:0] rob_tag_i,
    input  logic             [ROB_IDX_WIDTH-1:0] rob_head_i,
    input  logic             [ SB_IDX_WIDTH-1:0] sb_id_i,
    input  logic             [            31:0]   mmu_satp_i,
    input  logic             [             1:0]   mmu_priv_i,
    input  logic                                 mmu_sum_i,
    input  logic                                 mmu_mxr_i,
    input  logic                                 mmu_sfence_vma_i,

    // =========================================================
    // 2) Store Buffer interface (execute fill)
    // =========================================================
    output logic                                    sb_ex_valid_o,
    output logic                [ SB_IDX_WIDTH-1:0] sb_ex_sb_id_o,
    output logic                [     Cfg.PLEN-1:0] sb_ex_addr_o,
    output logic                [     Cfg.XLEN-1:0] sb_ex_data_o,
    output decode_pkg::lsu_op_e                     sb_ex_op_o,
    output logic                [ROB_IDX_WIDTH-1:0] sb_ex_rob_idx_o,

    // Store-to-Load Forwarding (query) — store_buffer 为唯一转发源
    output logic [     Cfg.PLEN-1:0] sb_load_addr_o,
    output logic [   Cfg.XLEN/8-1:0] sb_load_be_o,
    output logic [ROB_IDX_WIDTH-1:0] sb_load_rob_idx_o,
    input  logic                     sb_load_hit_i,
    input  logic [     Cfg.XLEN-1:0] sb_load_data_i,
    output logic                     sb_order_query_valid_o,
    output logic [ SB_IDX_WIDTH-1:0] sb_order_query_sb_id_o,
    input  logic                     sb_order_query_clear_i,

    // =========================================================
    // 3) D-Cache Load interface
    // =========================================================
    output logic                               ld_req_valid_o,
    input  logic                               ld_req_ready_i,
    output logic                [Cfg.PLEN-1:0] ld_req_addr_o,
    output decode_pkg::lsu_op_e                ld_req_op_o,
    output logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0] ld_req_id_o,

    input  logic                ld_rsp_valid_i,
    input  logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0] ld_rsp_id_i,
    output logic                ld_rsp_ready_o,
    input  logic [Cfg.XLEN-1:0] ld_rsp_data_i,
    input  logic                ld_rsp_err_i,

    // =========================================================
    // 3b) MMIO Uncached Load interface (bypass D-Cache)
    // =========================================================
    output logic                               mmio_req_valid_o,
    input  logic                               mmio_req_ready_i,
    output logic                [Cfg.PLEN-1:0] mmio_req_addr_o,
    output decode_pkg::lsu_op_e                mmio_req_op_o,

    input  logic                               mmio_rsp_valid_i,
    input  logic [Cfg.XLEN-1:0]                mmio_rsp_data_i,

    output logic                pte_req_valid_o,
    input  logic                pte_req_ready_i,
    output logic [31:0]         pte_req_paddr_o,
    input  logic                pte_rsp_valid_i,
    input  logic [31:0]         pte_rsp_data_i,
    output logic                pte_upd_valid_o,
    input  logic                pte_upd_ready_i,
    output logic [31:0]         pte_upd_paddr_o,
    output logic [31:0]         pte_upd_data_o,

    // =========================================================
    // 4) Writeback to ROB/CDB
    // =========================================================
    output logic [LSU_WB_PORTS-1:0]                     wb_valid_o,
    output logic [LSU_WB_PORTS-1:0][ROB_IDX_WIDTH-1:0]  wb_rob_idx_o,
    output logic [LSU_WB_PORTS-1:0][     Cfg.XLEN-1:0]  wb_data_o,
    output logic [LSU_WB_PORTS-1:0]                     wb_exception_o,
    output logic [LSU_WB_PORTS-1:0][ECAUSE_WIDTH-1:0]   wb_ecause_o,
    output logic [LSU_WB_PORTS-1:0]                     wb_is_mispred_o,
    output logic [LSU_WB_PORTS-1:0][     Cfg.PLEN-1:0]  wb_redirect_pc_o,
    input  logic [LSU_WB_PORTS-1:0]                     wb_ready_i,

    // =========================================================
    // 5) Debug visibility for queue skeleton
    // =========================================================
    output logic [$clog2(LQ_DEPTH + 1)-1:0] dbg_lq_count_o,
    output logic                            dbg_lq_head_valid_o,
    output logic [       ROB_IDX_WIDTH-1:0] dbg_lq_head_rob_tag_o,
    output logic [$clog2(SQ_DEPTH + 1)-1:0] dbg_sq_count_o,
    output logic                            dbg_sq_head_valid_o,
    output logic [       ROB_IDX_WIDTH-1:0] dbg_sq_head_rob_tag_o
);

  localparam int unsigned LANE_SEL_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU);
  localparam int unsigned STORE_WB_PORT = LOAD_WB_PORTS;  // dedicated store wb port index
  localparam int unsigned DBG_SEL_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU + 1);
  localparam int unsigned SQ_BE_WIDTH = Cfg.XLEN / 8;
  localparam int unsigned SQ_BYTE_OFF_W = (SQ_BE_WIDTH <= 1) ? 1 : $clog2(SQ_BE_WIDTH);
  localparam int unsigned STORE_WB_Q_DEPTH = (N_LSU < 2) ? 2 : N_LSU;
  localparam int unsigned STORE_WB_Q_IDX_W = (STORE_WB_Q_DEPTH <= 1) ? 1 : $clog2(STORE_WB_Q_DEPTH);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_ST_ADDR_MISALIGNED = ECAUSE_WIDTH'(6);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_LD_PAGE_FAULT = ECAUSE_WIDTH'(13);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_ST_PAGE_FAULT = ECAUSE_WIDTH'(15);
  localparam logic [1:0] MMU_ST_IDLE = 2'd0;
`ifndef SYNTHESIS
  localparam int unsigned LSU_PF_LOG_BUDGET = 128;
  int unsigned lsu_pf_log_cnt_q;
  localparam int unsigned LSU_STALL_TRACE_LOG_BUDGET = 256;
  int unsigned lsu_stall_trace_log_cnt_q;
  logic [15:0] lsu_stall_streak_q;
  logic lsu_trace_en_q;
  initial lsu_trace_en_q = $test$plusargs("npc_diag_trace");

  function automatic logic lsu_diag_watch_pc(input logic [31:0] pc);
    begin
      // Keep the watch list strict to avoid diag log storms in long runs.
      lsu_diag_watch_pc = (pc == 32'hc074befe) ||  // cmp_ex_search + 0x8
                          (pc == 32'hc076a580) ||  // exception pair A
                          (pc == 32'hc076a584) ||  // adjacent hot load
                          (pc == 32'hc074c47e) ||  // hang window load (stack restore)
                          (pc == 32'hc074c480) ||  // hang window load (stack restore)
                          (pc == 32'hc074cf9e);    // hang window load
    end
  endfunction
`endif

  // Keep these debug names for existing testbench hierarchical probes.
  logic                [               2:0]                    state_q;
  logic                [ ROB_IDX_WIDTH-1:0]                    req_tag_q;
  logic                [      Cfg.PLEN-1:0]                    req_addr_q;
  logic                [         N_LSU-1:0]                    dbg_lane_busy;
  logic                                                        dbg_alloc_fire;
  logic                [ DBG_SEL_WIDTH-1:0]                    dbg_alloc_lane;
  logic                [ DBG_SEL_WIDTH-1:0]                    dbg_ld_owner;

  logic                [         N_LSU-1:0]                    lane_req_valid;
  logic                [         N_LSU-1:0]                    lane_req_ready;

  logic                [         N_LSU-1:0]                    lane_sb_ex_valid;
  logic                [         N_LSU-1:0][ SB_IDX_WIDTH-1:0] lane_sb_ex_sb_id;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_sb_ex_addr;
  logic                [         N_LSU-1:0][     Cfg.XLEN-1:0] lane_sb_ex_data;
  decode_pkg::lsu_op_e                                         lane_sb_ex_op        [N_LSU];
  logic                [         N_LSU-1:0][ROB_IDX_WIDTH-1:0] lane_sb_ex_rob_idx;

  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_sb_load_addr;
  logic                [         N_LSU-1:0][ROB_IDX_WIDTH-1:0] lane_sb_load_rob_idx;

  logic                [         N_LSU-1:0]                    lane_ld_req_valid;
  logic                [         N_LSU-1:0]                    lane_ld_req_ready;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_ld_req_addr;
  decode_pkg::lsu_op_e                                         lane_ld_req_op       [N_LSU];

  logic                [         N_LSU-1:0]                    lane_ld_rsp_valid;
  logic                [         N_LSU-1:0]                    lane_ld_rsp_ready;

  logic                [         N_LSU-1:0]                    lane_wb_valid;
  logic                [         N_LSU-1:0][ROB_IDX_WIDTH-1:0] lane_wb_rob_idx;
  logic                [         N_LSU-1:0][     Cfg.XLEN-1:0] lane_wb_data;
  logic                [         N_LSU-1:0]                    lane_wb_exception;
  logic                [         N_LSU-1:0][ECAUSE_WIDTH-1:0] lane_wb_ecause;
  logic                [         N_LSU-1:0]                    lane_wb_is_mispred;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_wb_redirect_pc;
  logic                [         N_LSU-1:0]                    lane_wb_ready;

  // Per-lane MMIO interface signals
  logic                [         N_LSU-1:0]                    lane_mmio_req_valid;
  logic                [         N_LSU-1:0]                    lane_mmio_req_ready;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_mmio_req_addr;
  decode_pkg::lsu_op_e                                         lane_mmio_req_op     [N_LSU];
  logic                [         N_LSU-1:0]                    lane_mmio_rsp_valid;

  logic                [         N_LSU-1:0]                    alloc_grant;
  logic                [LANE_SEL_WIDTH-1:0]                    alloc_lane_idx;
  logic                                                        load_alloc_fire;
  logic                                                        store_req_fire;

  // DCache load request / writeback lane selection now live in lsu_arbiter;
  // the group fans the up-to-LOAD_WB_PORTS granted lanes onto the load
  // writeback ports and drives the dedicated store-writeback port separately.
  logic                [LOAD_WB_PORTS-1:0][LANE_SEL_WIDTH-1:0] wb_lane_idx;
  logic                [LOAD_WB_PORTS-1:0]                     wb_grant_valid;
  logic                [LOAD_WB_PORTS-1:0]                     wb_port_fire;
  logic                [LOAD_WB_PORTS-1:0]                     wb_pop_w;
  logic                                                        store_wb_fire;
  logic                                                        amo_wb_fire;
  logic                [LANE_SEL_WIDTH-1:0]                    amo_wb_lane;

  logic                                                        lq_alloc_valid;
  logic                                                        lq_alloc_ready;
  logic                                                        lq_full;
  logic                                                        lq_empty;
  logic                                                        lq_inflight_empty;
  logic                [LOAD_WB_PORTS-1:0]                     lq_exec_valid;
  logic                [LOAD_WB_PORTS-1:0][ROB_IDX_WIDTH-1:0] lq_exec_rob_tag;
  logic                                                        lq_st_query_valid;
  logic                [      Cfg.PLEN-1:0]                   lq_st_paddr;
  logic                [     SQ_BE_WIDTH-1:0]                 lq_st_be;
  logic                [ ROB_IDX_WIDTH-1:0]                   lq_st_rob_tag;
  logic                                                        lq_violation_valid;
  logic                [      Cfg.PLEN-1:0]                   lq_violation_pc;
  logic                [ ROB_IDX_WIDTH-1:0]                   lq_violation_rob_idx;

  // Store-queue debug/ordering remnants: the dedicated `sq` structure was
  // removed (forwarding now lives solely in store_buffer). These signals are
  // kept as store_wb-derived debug/diag aliases so existing hierarchical
  // probes (tb/profiler) keep resolving.
  logic                                                        sq_alloc_ready;
  logic                                                        sq_full;
  logic                                                        sq_empty;
  logic                [     SQ_BE_WIDTH-1:0]                 load_fwd_be;
  logic                [      Cfg.XLEN-1:0]                   req_eff_addr_xlen;
  logic                [      Cfg.PLEN-1:0]                   req_eff_addr;

  logic                                                        req_is_load;
  logic                                                        req_is_store;
  logic                                                        req_is_amo;
  logic                                                        store_misaligned;
  logic                                                        store_page_fault;
  logic                                                        store_req_ready;
  logic                                                        load_req_ready;
  logic                                                        req_has_force_fault;
  logic                [ECAUSE_WIDTH-1:0]                    req_force_ecause;
  logic                                                        req_need_mmu_walk;
  logic                                                        amo_inflight;
  logic                                                        amo_order_clear;
  logic                                                        req_ordered_load;
  logic                [      Cfg.XLEN-1:0]                   req_in_eff_addr_xlen;
  logic                [      Cfg.PLEN-1:0]                   req_in_eff_addr;
  logic                                                        agu_is_load;
  logic                                                        agu_is_store;
  logic                                                        agu_misaligned;
  logic                                                        lane_misaligned;
  decode_pkg::uop_t                                            selected_uop;
  decode_pkg::uop_t                                            lane_uop;
  logic                [      Cfg.XLEN-1:0]                   selected_rs2_data;

  logic                                                        pend_valid_q;
  decode_pkg::uop_t                                            pend_uop_q;
  logic                [      Cfg.XLEN-1:0]                   pend_rs2_data_q;
  logic                [ ROB_IDX_WIDTH-1:0]                   pend_rob_tag_q;
  logic                [  SB_IDX_WIDTH-1:0]                   pend_sb_id_q;
  logic                [      Cfg.PLEN-1:0]                   pend_addr_q;
  logic                                                        pend_force_fault_q;
  logic                [ECAUSE_WIDTH-1:0]                    pend_force_ecause_q;

  logic                [             1:0]                     mmu_state_q;
`ifndef SYNTHESIS
  logic                [             31:0]                    lsu_diag_pc_w;
  logic                                                        lsu_diag_stall_watch_w;
  logic                                                        lsu_diag_stall_cond_w;
`endif

  logic [STORE_WB_Q_DEPTH-1:0] store_wb_valid_q;
  logic [STORE_WB_Q_DEPTH-1:0][ROB_IDX_WIDTH-1:0] store_wb_rob_idx_q;
  logic [STORE_WB_Q_DEPTH-1:0][Cfg.XLEN-1:0] store_wb_data_q;
  logic [STORE_WB_Q_DEPTH-1:0] store_wb_exception_q;
  logic [STORE_WB_Q_DEPTH-1:0][ECAUSE_WIDTH-1:0] store_wb_ecause_q;
  logic [STORE_WB_Q_DEPTH-1:0] store_wb_is_mispred_q;
  logic [STORE_WB_Q_DEPTH-1:0][Cfg.PLEN-1:0] store_wb_redirect_pc_q;
  logic [STORE_WB_Q_DEPTH-1:0] store_wb_has_sq_q;
  logic [STORE_WB_Q_DEPTH-1:0][Cfg.PLEN-1:0] store_wb_pc_q;
  logic [STORE_WB_Q_IDX_W-1:0] store_wb_head_q, store_wb_tail_q;
  logic [$clog2(STORE_WB_Q_DEPTH+1)-1:0] store_wb_count_q;
  logic store_wb_head_valid;
  logic [ROB_IDX_WIDTH-1:0] store_wb_head_rob_idx;
  logic [Cfg.XLEN-1:0] store_wb_head_data;
  logic store_wb_head_exception;
  logic [ECAUSE_WIDTH-1:0] store_wb_head_ecause;
  logic store_wb_head_is_mispred;
  logic [Cfg.PLEN-1:0] store_wb_head_redirect_pc;
  logic store_wb_head_has_sq;
  logic [Cfg.PLEN-1:0] store_wb_head_pc;

  logic rsp_id_in_range;  // dbg-only: load response id within lane range
  logic [N_LSU-1:0] lane_amo_valid_q;
  decode_pkg::amo_op_e lane_amo_op_q[N_LSU];
  logic [N_LSU-1:0][Cfg.XLEN-1:0] lane_amo_rs2_q;
  logic [N_LSU-1:0][SB_IDX_WIDTH-1:0] lane_amo_sb_id_q;
  logic [N_LSU-1:0][Cfg.PLEN-1:0] lane_amo_addr_q;
  logic [Cfg.XLEN-1:0] amo_wb_new_data;

  function automatic logic [STORE_WB_Q_IDX_W-1:0] store_wbq_next_idx(
      input logic [STORE_WB_Q_IDX_W-1:0] idx
  );
    begin
      if (STORE_WB_Q_DEPTH <= 1) begin
        store_wbq_next_idx = '0;
      end else if (idx == STORE_WB_Q_IDX_W'(STORE_WB_Q_DEPTH - 1)) begin
        store_wbq_next_idx = '0;
      end else begin
        store_wbq_next_idx = idx + STORE_WB_Q_IDX_W'(1);
      end
    end
  endfunction

  function automatic logic [SQ_BE_WIDTH-1:0] load_be_mask(input decode_pkg::lsu_op_e op,
                                                           input logic [Cfg.PLEN-1:0] addr);
    logic [SQ_BE_WIDTH-1:0] mask;
    logic [SQ_BYTE_OFF_W-1:0] off;
    begin
      mask = '0;
      off = addr[SQ_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_LB, decode_pkg::LSU_LBU: begin
          mask[off] = 1'b1;
        end
        decode_pkg::LSU_LH, decode_pkg::LSU_LHU: begin
          for (int i = 0; i < 2; i++) begin
            if ((off + i) < SQ_BE_WIDTH) begin
              mask[off+i] = 1'b1;
            end
          end
        end
        decode_pkg::LSU_LW, decode_pkg::LSU_LWU, decode_pkg::LSU_LR, decode_pkg::LSU_AMO: begin
          for (int i = 0; i < 4; i++) begin
            if ((off + i) < SQ_BE_WIDTH) begin
              mask[off+i] = 1'b1;
            end
          end
        end
        decode_pkg::LSU_LD: begin
          for (int i = 0; i < SQ_BE_WIDTH; i++) begin
            mask[i] = 1'b1;
          end
        end
        default: begin
          mask = '0;
        end
      endcase
      load_be_mask = mask;
    end
  endfunction

  // Byte-enable mask of a resolving store, relative to its containing word.
  // Mirrors store_buffer's store_be_mask: used to drive the LQ violation CAM
  // (overlap = same word address AND intersecting byte mask). SC_FAIL / non
  // store ops return 0 so they never trigger a violation.
  function automatic logic [SQ_BE_WIDTH-1:0] store_be_mask(input decode_pkg::lsu_op_e op,
                                                           input logic [Cfg.PLEN-1:0] addr);
    logic [SQ_BE_WIDTH-1:0] mask;
    logic [SQ_BYTE_OFF_W-1:0] off;
    begin
      mask = '0;
      off  = addr[SQ_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_SB: mask[off] = 1'b1;
        decode_pkg::LSU_SH: begin
          for (int i = 0; i < 2; i++) begin
            if ((off + i) < SQ_BE_WIDTH) mask[off+i] = 1'b1;
          end
        end
        decode_pkg::LSU_SW, decode_pkg::LSU_SC, decode_pkg::LSU_AMO: begin
          for (int i = 0; i < 4; i++) begin
            if ((off + i) < SQ_BE_WIDTH) mask[off+i] = 1'b1;
          end
        end
        decode_pkg::LSU_SD: begin
          for (int i = 0; i < SQ_BE_WIDTH; i++) mask[i] = 1'b1;
        end
        default: mask = '0;
      endcase
      store_be_mask = mask;
    end
  endfunction

  function automatic logic is_store_misaligned(input decode_pkg::lsu_op_e op,
                                                input logic [Cfg.PLEN-1:0] addr);
    begin
      unique case (op)
        decode_pkg::LSU_SB: is_store_misaligned = 1'b0;
        decode_pkg::LSU_SH: is_store_misaligned = addr[0];
        decode_pkg::LSU_SW, decode_pkg::LSU_SC, decode_pkg::LSU_AMO: is_store_misaligned = |addr[1:0];
        decode_pkg::LSU_SD: is_store_misaligned = |addr[2:0];
        default:            is_store_misaligned = 1'b0;
      endcase
    end
  endfunction

  function automatic logic is_load_misaligned(input decode_pkg::lsu_op_e op,
                                               input logic [Cfg.PLEN-1:0] addr);
    begin
      unique case (op)
        decode_pkg::LSU_LB, decode_pkg::LSU_LBU: is_load_misaligned = 1'b0;
        decode_pkg::LSU_LH, decode_pkg::LSU_LHU: is_load_misaligned = addr[0];
        decode_pkg::LSU_LW, decode_pkg::LSU_LWU, decode_pkg::LSU_LR,
        decode_pkg::LSU_AMO: is_load_misaligned = |addr[1:0];
        decode_pkg::LSU_LD: is_load_misaligned = |addr[2:0];
        default: is_load_misaligned = 1'b0;
      endcase
    end
  endfunction

  function automatic logic [Cfg.XLEN-1:0] amo_result(input decode_pkg::amo_op_e op,
                                                     input logic [Cfg.XLEN-1:0] old_val,
                                                     input logic [Cfg.XLEN-1:0] operand);
    logic signed [31:0] old_s;
    logic signed [31:0] operand_s;
    logic [31:0] old_w;
    logic [31:0] operand_w;
    logic [31:0] res_w;
    begin
      old_w = old_val[31:0];
      operand_w = operand[31:0];
      old_s = old_w;
      operand_s = operand_w;
      unique case (op)
        decode_pkg::AMO_SWAP: res_w = operand_w;
        decode_pkg::AMO_ADD:  res_w = old_w + operand_w;
        decode_pkg::AMO_XOR:  res_w = old_w ^ operand_w;
        decode_pkg::AMO_AND:  res_w = old_w & operand_w;
        decode_pkg::AMO_OR:   res_w = old_w | operand_w;
        decode_pkg::AMO_MIN:  res_w = (old_s < operand_s) ? old_w : operand_w;
        decode_pkg::AMO_MAX:  res_w = (old_s > operand_s) ? old_w : operand_w;
        decode_pkg::AMO_MINU: res_w = (old_w < operand_w) ? old_w : operand_w;
        decode_pkg::AMO_MAXU: res_w = (old_w > operand_w) ? old_w : operand_w;
        default:              res_w = old_w;
      endcase
      if (Cfg.XLEN == 32) begin
        amo_result = res_w;
      end else begin
        amo_result = {{(Cfg.XLEN - 32) {res_w[31]}}, res_w};
      end
    end
  endfunction

  always_comb begin
    selected_uop = pend_valid_q ? pend_uop_q : uop_i;
    selected_rs2_data = pend_valid_q ? pend_rs2_data_q : rs2_data_i;
    lane_uop = selected_uop;
    if (lane_uop.lsu_op == decode_pkg::LSU_AMO) begin
      lane_uop.is_load  = 1'b1;
      lane_uop.is_store = 1'b0;
    end
  end

  lsu_agu #(
      .Cfg(Cfg)
  ) u_agu (
      .uop_i(uop_i),
      .rs1_data_i(rs1_data_i),
      .eff_addr_xlen_o(req_in_eff_addr_xlen),
      .eff_addr_o(req_in_eff_addr),
      .is_load_o(agu_is_load),
      .is_store_o(agu_is_store),
      .is_amo_o(),
      .misaligned_o(agu_misaligned)
  );
`ifndef SYNTHESIS
  assign lsu_diag_pc_w = pend_valid_q ? pend_uop_q.pc : uop_i.pc;
  assign lsu_diag_stall_watch_w = lsu_diag_watch_pc(lsu_diag_pc_w);
  assign lsu_diag_stall_cond_w = lsu_diag_stall_watch_w && !flush_i &&
                                 ((pend_valid_q && (req_is_load || req_is_store) &&
                                   !load_alloc_fire && !store_req_fire) ||
                                  (req_valid_i && (uop_i.is_load || uop_i.is_store) && !req_ready_o));
`endif

  // Unique address-translation entry point: owns the sv32 MMU and the MMU
  // wrapper FSM + pend buffering that used to be inlined here. A walk-needing
  // request is latched and resolved through req -> pend handshake; non-walk
  // requests are reported via need_walk=0 and handled on the dispatch bypass.
  lsu_translate #(
      .Cfg(Cfg),
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .SB_IDX_WIDTH(SB_IDX_WIDTH),
      .ECAUSE_WIDTH(ECAUSE_WIDTH)
  ) u_translate (
      .clk_i,
      .rst_ni,
      .flush_i,

      .req_valid_i(req_valid_i),
      .uop_i(uop_i),
      .rs1_data_i(rs1_data_i),
      .rs2_data_i(rs2_data_i),
      .rob_tag_i(rob_tag_i),
      .sb_id_i(sb_id_i),
      .req_vaddr_i(req_in_eff_addr),
      .req_is_load_i(agu_is_load),
      .req_is_store_i(agu_is_store),
      .req_misaligned_i(agu_misaligned),

      .mmu_satp_i(mmu_satp_i),
      .mmu_priv_i(mmu_priv_i),
      .mmu_sum_i(mmu_sum_i),
      .mmu_mxr_i(mmu_mxr_i),
      .mmu_sfence_vma_i(mmu_sfence_vma_i),

      .pte_req_valid_o(pte_req_valid_o),
      .pte_req_ready_i(pte_req_ready_i),
      .pte_req_paddr_o(pte_req_paddr_o),
      .pte_rsp_valid_i(pte_rsp_valid_i),
      .pte_rsp_data_i(pte_rsp_data_i),
      .pte_upd_valid_o(pte_upd_valid_o),
      .pte_upd_ready_i(pte_upd_ready_i),
      .pte_upd_paddr_o(pte_upd_paddr_o),
      .pte_upd_data_o(pte_upd_data_o),

      .need_walk_o(req_need_mmu_walk),
      .accept_ready_o(),
      .mmu_state_o(mmu_state_q),

      .pend_consume_i(load_alloc_fire || store_req_fire),
      .pend_valid_o(pend_valid_q),
      .pend_uop_o(pend_uop_q),
      .pend_rs2_data_o(pend_rs2_data_q),
      .pend_rob_tag_o(pend_rob_tag_q),
      .pend_sb_id_o(pend_sb_id_q),
      .pend_addr_o(pend_addr_q),
      .pend_force_fault_o(pend_force_fault_q),
      .pend_force_ecause_o(pend_force_ecause_q)
  );

  generate
    for (genvar gi = 0; gi < N_LSU; gi++) begin : g_lanes
      lsu_lane #(
          .Cfg(Cfg),
          .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
          .SB_DEPTH(SB_DEPTH),
          .SB_IDX_WIDTH(SB_IDX_WIDTH),
          .ECAUSE_WIDTH(ECAUSE_WIDTH)
      ) u_lane (
          .clk_i,
          .rst_ni,
          .flush_i,

          .req_valid_i(lane_req_valid[gi]),
          .req_ready_o(lane_req_ready[gi]),
          .uop_i(lane_uop),
          .rs2_data_i(pend_valid_q ? pend_rs2_data_q : rs2_data_i),
          .eff_addr_i(req_eff_addr),
          .misaligned_i(lane_misaligned),
          .force_exception_i(req_has_force_fault),
          .force_ecause_i(req_force_ecause),
          .rob_tag_i(pend_valid_q ? pend_rob_tag_q : rob_tag_i),
          .sb_id_i(pend_valid_q ? pend_sb_id_q : sb_id_i),

          .sb_ex_valid_o(lane_sb_ex_valid[gi]),
          .sb_ex_sb_id_o(lane_sb_ex_sb_id[gi]),
          .sb_ex_addr_o(lane_sb_ex_addr[gi]),
          .sb_ex_data_o(lane_sb_ex_data[gi]),
          .sb_ex_op_o(lane_sb_ex_op[gi]),
          .sb_ex_rob_idx_o(lane_sb_ex_rob_idx[gi]),

          .sb_load_addr_o(lane_sb_load_addr[gi]),
          .sb_load_rob_idx_o(lane_sb_load_rob_idx[gi]),
          .sb_load_hit_i(sb_load_hit_i),
          .sb_load_data_i(sb_load_data_i),

          .ld_req_valid_o(lane_ld_req_valid[gi]),
          .ld_req_ready_i(lane_ld_req_ready[gi]),
          .ld_req_addr_o(lane_ld_req_addr[gi]),
          .ld_req_op_o(lane_ld_req_op[gi]),

          .ld_rsp_valid_i(lane_ld_rsp_valid[gi]),
          .ld_rsp_ready_o(lane_ld_rsp_ready[gi]),
          .ld_rsp_data_i,
          .ld_rsp_err_i,

          // MMIO bypass
          .rob_head_i(rob_head_i),
          .mmio_req_valid_o(lane_mmio_req_valid[gi]),
          .mmio_req_ready_i(lane_mmio_req_ready[gi]),
          .mmio_req_addr_o(lane_mmio_req_addr[gi]),
          .mmio_req_op_o(lane_mmio_req_op[gi]),
          .mmio_rsp_valid_i(lane_mmio_rsp_valid[gi]),
          .mmio_rsp_data_i(mmio_rsp_data_i),

          .wb_valid_o(lane_wb_valid[gi]),
          .wb_rob_idx_o(lane_wb_rob_idx[gi]),
          .wb_data_o(lane_wb_data[gi]),
          .wb_exception_o(lane_wb_exception[gi]),
          .wb_ecause_o(lane_wb_ecause[gi]),
          .wb_is_mispred_o(lane_wb_is_mispred[gi]),
          .wb_redirect_pc_o(lane_wb_redirect_pc[gi]),
          .wb_ready_i(lane_wb_ready[gi])
      );

      assign dbg_lane_busy[gi] = lane_ld_req_valid[gi] | lane_ld_rsp_ready[gi] | lane_wb_valid[gi] | lane_mmio_req_valid[gi];
    end
  endgenerate

  // ---------------------------------------------------------
  // Shared-resource arbitration (DCache req RR / MMIO / WB lane RR)
  // ---------------------------------------------------------
  lsu_arbiter #(
      .Cfg(Cfg),
      .N_LSU(N_LSU),
      .N_WB(LOAD_WB_PORTS)
  ) u_arbiter (
      .clk_i,
      .rst_ni,
      .flush_i,

      .lane_ld_req_valid_i(lane_ld_req_valid),
      .lane_ld_req_addr_i(lane_ld_req_addr),
      .lane_ld_req_op_i(lane_ld_req_op),
      .lane_ld_req_ready_o(lane_ld_req_ready),
      .ld_req_valid_o(ld_req_valid_o),
      .ld_req_ready_i(ld_req_ready_i),
      .ld_req_addr_o(ld_req_addr_o),
      .ld_req_op_o(ld_req_op_o),
      .ld_req_id_o(ld_req_id_o),

      .ld_rsp_valid_i(ld_rsp_valid_i),
      .ld_rsp_id_i(ld_rsp_id_i),
      .ld_rsp_ready_o(ld_rsp_ready_o),
      .lane_ld_rsp_ready_i(lane_ld_rsp_ready),
      .lane_ld_rsp_valid_o(lane_ld_rsp_valid),

      .lane_mmio_req_valid_i(lane_mmio_req_valid),
      .lane_mmio_req_addr_i(lane_mmio_req_addr),
      .lane_mmio_req_op_i(lane_mmio_req_op),
      .lane_mmio_req_ready_o(lane_mmio_req_ready),
      .lane_mmio_rsp_valid_o(lane_mmio_rsp_valid),
      .mmio_req_valid_o(mmio_req_valid_o),
      .mmio_req_ready_i(mmio_req_ready_i),
      .mmio_req_addr_o(mmio_req_addr_o),
      .mmio_req_op_o(mmio_req_op_o),
      .mmio_rsp_valid_i(mmio_rsp_valid_i),

      .lane_wb_valid_i(lane_wb_valid),
      .wb_pop_i(wb_pop_w),
      .wb_grant_valid_o(wb_grant_valid),
      .wb_lane_idx_o(wb_lane_idx)
  );

  assign state_q    = g_lanes[0].u_lane.state_q;
  assign req_tag_q  = g_lanes[0].u_lane.req_tag_q;
  assign req_addr_q = g_lanes[0].u_lane.req_addr_q;
  assign req_eff_addr_xlen = pend_valid_q ? {{(Cfg.XLEN-Cfg.PLEN){1'b0}}, pend_addr_q} : req_in_eff_addr_xlen;
  assign req_eff_addr = pend_valid_q ? pend_addr_q : req_in_eff_addr;
  // Alignment for the address actually handed to the lane (selected/pend path).
  // Equivalent to the lane's former internal is_misaligned(lane_uop, eff_addr).
  assign lane_misaligned = is_store_misaligned(lane_uop.lsu_op, req_eff_addr) |
                           is_load_misaligned(lane_uop.lsu_op, req_eff_addr);
  assign req_is_amo = selected_uop.lsu_op == decode_pkg::LSU_AMO;
  assign req_is_load = pend_valid_q ? selected_uop.is_load :
                       (!req_need_mmu_walk && req_valid_i && uop_i.is_load);
  assign req_is_store = (pend_valid_q ? selected_uop.is_store :
                        (!req_need_mmu_walk && req_valid_i && uop_i.is_store)) &&
                        !req_is_amo;
  assign req_has_force_fault = pend_valid_q ? pend_force_fault_q : 1'b0;
  assign req_force_ecause = pend_valid_q ? pend_force_ecause_q : '0;
  assign store_misaligned = pend_valid_q ? (req_is_store && req_has_force_fault &&
                                            (req_force_ecause == EXC_ST_ADDR_MISALIGNED)) :
                            (req_is_store && is_store_misaligned(uop_i.lsu_op, req_eff_addr));
  assign store_page_fault = pend_valid_q ? (req_is_store && req_has_force_fault &&
                                            (req_force_ecause == EXC_ST_PAGE_FAULT)) : 1'b0;
  assign amo_inflight = |lane_amo_valid_q;
  // store_wb_count_q==0 蕴含所有已准入 store 已写回 (sq_empty 等价项已去除)。
  // LQ 现持有 load 到提交，AMO 排序只需所有更老 load 已执行 (读完内存)，
  // 故用 inflight_empty（无未写回 load）而非 empty（无任何在飞 load）。
  assign amo_order_clear = (dbg_lane_busy == '0) && lq_inflight_empty &&
                           (store_wb_count_q == '0) && sb_order_query_clear_i;
  assign store_wb_head_valid = (store_wb_count_q != 0);
  assign store_wb_head_rob_idx = store_wb_rob_idx_q[store_wb_head_q];
  assign store_wb_head_data = store_wb_data_q[store_wb_head_q];
  assign store_wb_head_exception = store_wb_exception_q[store_wb_head_q];
  assign store_wb_head_ecause = store_wb_ecause_q[store_wb_head_q];
  assign store_wb_head_is_mispred = store_wb_is_mispred_q[store_wb_head_q];
  assign store_wb_head_redirect_pc = store_wb_redirect_pc_q[store_wb_head_q];
  assign store_wb_head_has_sq = store_wb_has_sq_q[store_wb_head_q];
  assign store_wb_head_pc = store_wb_pc_q[store_wb_head_q];
  // 转发的字节掩码：交给 store_buffer 做 byte-merge，命中即返回对齐到字节 0 的数据。
  // 仅在本周期有 load 准入时驱动 (否则 be=0，store_buffer 自然不命中)。
  assign load_fwd_be = load_be_mask(pend_valid_q ? pend_uop_q.lsu_op : uop_i.lsu_op, req_eff_addr);
  assign sb_load_be_o = (load_alloc_fire && req_is_load) ? load_fwd_be : '0;
  assign sb_order_query_valid_o = req_is_amo;
  assign sb_order_query_sb_id_o = pend_valid_q ? pend_sb_id_q : sb_id_i;

  assign lq_alloc_valid = load_alloc_fire && req_is_load;

  // B2: load writeback marks the matching LQ entry executed (no longer pops).
  // The entry is freed later, when the ROB commits the load (commit_*_i).
  // One exec port per granted load-writeback port; the LQ observes all of them
  // so the disambiguation CAM never misses a same-cycle retiring load.
  always_comb begin
    for (int p = 0; p < LOAD_WB_PORTS; p++) begin
      lq_exec_valid[p]   = wb_port_fire[p];
      lq_exec_rob_tag[p] = lane_wb_rob_idx[wb_lane_idx[p]];
    end
  end

  // B3: drive the LQ store->load violation CAM the cycle a store resolves its
  // physical address (store_req_fire). Only stores that actually write memory
  // can alias a younger load: skip faulting stores and a failed SC (which
  // commits a dummy store writing no bytes). AMO is serialized on the single
  // lane (amo_inflight blocks younger loads from executing concurrently), so
  // its store side needs no CAM here.
  assign lq_st_query_valid = store_req_fire && req_is_store &&
                             !store_misaligned && !store_page_fault &&
                             !(is_sc && sc_fail);
  assign lq_st_paddr       = req_eff_addr;
  assign lq_st_be          = store_be_mask(selected_uop.lsu_op, req_eff_addr);
  assign lq_st_rob_tag     = pend_valid_q ? pend_rob_tag_q : rob_tag_i;

  logic res_valid_q;
  logic [Cfg.PLEN-1:0] res_addr_q;
  logic is_sc;
  logic sc_success;
  logic sc_fail;
  assign is_sc = selected_uop.lsu_op == decode_pkg::LSU_SC;
  assign sc_success = is_sc && res_valid_q && (res_addr_q == req_eff_addr);
  assign sc_fail = is_sc && !sc_success;

  logic req_is_lr;
  assign req_is_lr = selected_uop.lsu_op == decode_pkg::LSU_LR;
  assign req_ordered_load = req_is_lr || req_is_amo;

  always_comb begin
    load_req_ready = 1'b0;
    alloc_grant = '0;
    alloc_lane_idx = '0;
    for (int i = 0; i < N_LSU; i++) begin
      if (!load_req_ready && lane_req_ready[i] && lq_alloc_ready) begin
        if ((!req_ordered_load || amo_order_clear) && (!req_is_amo || !amo_inflight)) begin
          load_req_ready = 1'b1;
          alloc_grant[i] = 1'b1;
          alloc_lane_idx = LANE_SEL_WIDTH'(i);
        end
      end
    end
  end

  // Keep store admission independent from selected-uop decode details to avoid
  // combinational feedback with issue selection. Admission now gated solely by
  // the store writeback queue (the deep `sq` backpressure was never binding).
  assign store_req_ready = (store_wb_count_q < STORE_WB_Q_DEPTH) ||
                           (store_wb_head_valid && wb_ready_i[STORE_WB_PORT]);
  // Debug/diag aliases for the removed `sq` (store_wb-derived).
  assign sq_alloc_ready = store_req_ready;
  assign sq_full = !store_req_ready;
  assign sq_empty = (store_wb_count_q == '0);
  always_comb begin
    req_ready_o = 1'b0;
    if (pend_valid_q || (mmu_state_q != MMU_ST_IDLE) || amo_inflight) begin
      req_ready_o = 1'b0;
    end else if (req_need_mmu_walk) begin
      req_ready_o = (uop_i.lsu_op != decode_pkg::LSU_AMO) || amo_order_clear;
    end else if (uop_i.is_load) begin
      req_ready_o = load_req_ready;
    end else if (uop_i.is_store) begin
      req_ready_o = store_req_ready;
    end
  end

  assign load_alloc_fire = ((pend_valid_q) || (!req_need_mmu_walk && req_valid_i && (mmu_state_q == MMU_ST_IDLE))) &&
                           req_is_load && load_req_ready;
  assign store_req_fire = ((pend_valid_q) || (!req_need_mmu_walk && req_valid_i && (mmu_state_q == MMU_ST_IDLE))) &&
                          req_is_store && store_req_ready;
  assign dbg_alloc_fire = load_alloc_fire | store_req_fire;

  always_comb begin
    lane_req_valid = '0;
    for (int i = 0; i < N_LSU; i++) begin
      lane_req_valid[i] = load_alloc_fire && alloc_grant[i];
    end
  end

  always_comb begin
    sb_ex_valid_o = store_req_fire && !store_misaligned && !store_page_fault;
    sb_ex_sb_id_o = pend_valid_q ? pend_sb_id_q : sb_id_i;
    sb_ex_addr_o = req_eff_addr;
    sb_ex_data_o = selected_rs2_data;
    sb_ex_op_o = sc_fail ? decode_pkg::LSU_SC_FAIL :
                 is_sc ? decode_pkg::LSU_SW : 
                 selected_uop.lsu_op;
    sb_ex_rob_idx_o = pend_valid_q ? pend_rob_tag_q : rob_tag_i;
    sb_load_addr_o = '0;
    sb_load_rob_idx_o = '0;
    if (amo_wb_fire && !lane_wb_exception[amo_wb_lane]) begin
      sb_ex_valid_o = 1'b1;
      sb_ex_sb_id_o = lane_amo_sb_id_q[amo_wb_lane];
      sb_ex_addr_o = lane_amo_addr_q[amo_wb_lane];
      sb_ex_data_o = amo_wb_new_data;
      sb_ex_op_o = decode_pkg::LSU_SW;
      sb_ex_rob_idx_o = lane_wb_rob_idx[amo_wb_lane];
    end
    for (int i = 0; i < N_LSU; i++) begin
      if (lane_sb_ex_valid[i] && !sb_ex_valid_o) begin
        sb_ex_valid_o = 1'b1;
        sb_ex_sb_id_o = lane_sb_ex_sb_id[i];
        sb_ex_addr_o = lane_sb_ex_addr[i];
        sb_ex_data_o = lane_sb_ex_data[i];
        sb_ex_op_o = lane_sb_ex_op[i];
        sb_ex_rob_idx_o = lane_sb_ex_rob_idx[i];
      end
      if (lane_req_valid[i]) begin
        sb_load_addr_o = lane_sb_load_addr[i];
        sb_load_rob_idx_o = lane_sb_load_rob_idx[i];
      end
    end
  end

  // DCache load request RR, load response routing and writeback lane RR are
  // owned by u_arbiter above; the group fans the up-to-LOAD_WB_PORTS granted
  // lanes onto the load writeback ports and drives the store-writeback port
  // independently. Each port is 1:1 with a CDB port (wb_ready_i is held high),
  // so a granted lane and a queued store can complete in the same cycle.
  always_comb begin
    lane_wb_ready = '0;

    // Load writeback ports [0 .. LOAD_WB_PORTS-1]: arbiter-granted lanes.
    for (int p = 0; p < LOAD_WB_PORTS; p++) begin
      wb_valid_o[p]       = wb_grant_valid[p];
      wb_rob_idx_o[p]     = lane_wb_rob_idx[wb_lane_idx[p]];
      wb_data_o[p]        = lane_wb_data[wb_lane_idx[p]];
      wb_exception_o[p]   = lane_wb_exception[wb_lane_idx[p]];
      wb_ecause_o[p]      = lane_wb_ecause[wb_lane_idx[p]];
      wb_is_mispred_o[p]  = lane_wb_is_mispred[wb_lane_idx[p]];
      wb_redirect_pc_o[p] = lane_wb_redirect_pc[wb_lane_idx[p]];
      if (wb_grant_valid[p]) begin
        lane_wb_ready[wb_lane_idx[p]] = wb_ready_i[p];
      end
    end

    // Dedicated store writeback port [STORE_WB_PORT].
    wb_valid_o[STORE_WB_PORT]       = store_wb_head_valid;
    wb_rob_idx_o[STORE_WB_PORT]     = store_wb_head_rob_idx;
    wb_data_o[STORE_WB_PORT]        = store_wb_head_data;
    wb_exception_o[STORE_WB_PORT]   = store_wb_head_exception;
    wb_ecause_o[STORE_WB_PORT]      = store_wb_head_ecause;
    wb_is_mispred_o[STORE_WB_PORT]  = store_wb_head_is_mispred;
    wb_redirect_pc_o[STORE_WB_PORT] = store_wb_head_redirect_pc;
  end

  // Per-port writeback fire + arbiter pointer-advance feedback.
  always_comb begin
    for (int p = 0; p < LOAD_WB_PORTS; p++) begin
      wb_port_fire[p] = wb_grant_valid[p] && wb_ready_i[p];
      wb_pop_w[p]     = wb_port_fire[p];
    end
  end
  assign store_wb_fire = wb_valid_o[STORE_WB_PORT] && wb_ready_i[STORE_WB_PORT];

  // AMO completes on whichever granted load port carries the (single, due to
  // amo_inflight serialization) in-flight AMO lane.
  always_comb begin
    amo_wb_fire = 1'b0;
    amo_wb_lane = '0;
    for (int p = 0; p < LOAD_WB_PORTS; p++) begin
      if (wb_port_fire[p] && lane_amo_valid_q[wb_lane_idx[p]]) begin
        amo_wb_fire = 1'b1;
        amo_wb_lane = wb_lane_idx[p];
      end
    end
  end
  assign amo_wb_new_data = amo_result(lane_amo_op_q[amo_wb_lane],
                                      lane_wb_data[amo_wb_lane],
                                      lane_amo_rs2_q[amo_wb_lane]);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      store_wb_valid_q <= '0;
      store_wb_rob_idx_q <= '0;
      store_wb_data_q <= '0;
      store_wb_exception_q <= '0;
      store_wb_ecause_q <= '0;
      store_wb_is_mispred_q <= '0;
      store_wb_redirect_pc_q <= '0;
      store_wb_has_sq_q <= '0;
      store_wb_pc_q <= '0;
      store_wb_head_q <= '0;
      store_wb_tail_q <= '0;
      store_wb_count_q <= '0;
      lane_amo_valid_q <= '0;
      for (int i = 0; i < N_LSU; i++) begin
        lane_amo_op_q[i] <= decode_pkg::AMO_NONE;
        lane_amo_rs2_q[i] <= '0;
        lane_amo_sb_id_q[i] <= '0;
        lane_amo_addr_q[i] <= '0;
      end
`ifndef SYNTHESIS
      lsu_pf_log_cnt_q <= '0;
      lsu_stall_trace_log_cnt_q <= '0;
      lsu_stall_streak_q <= '0;
`endif
    end else if (flush_i) begin
      store_wb_valid_q <= '0;
      store_wb_rob_idx_q <= '0;
      store_wb_data_q <= '0;
      store_wb_exception_q <= '0;
      store_wb_ecause_q <= '0;
      store_wb_is_mispred_q <= '0;
      store_wb_redirect_pc_q <= '0;
      store_wb_has_sq_q <= '0;
      store_wb_pc_q <= '0;
      store_wb_head_q <= '0;
      store_wb_tail_q <= '0;
      store_wb_count_q <= '0;
      res_valid_q <= 1'b0;
      res_addr_q <= '0;
      lane_amo_valid_q <= '0;
      for (int i = 0; i < N_LSU; i++) begin
        lane_amo_op_q[i] <= decode_pkg::AMO_NONE;
        lane_amo_rs2_q[i] <= '0;
        lane_amo_sb_id_q[i] <= '0;
        lane_amo_addr_q[i] <= '0;
      end
    end else begin
      if (flush_i) begin
        res_valid_q <= 1'b0;
      end else if (load_alloc_fire && (pend_valid_q ? pend_uop_q.lsu_op : uop_i.lsu_op) == decode_pkg::LSU_LR) begin
        res_valid_q <= 1'b1;
        res_addr_q <= req_eff_addr;
      end else if ((store_req_fire && (is_sc || (!store_misaligned && !store_page_fault))) ||
                   (amo_wb_fire && !lane_wb_exception[amo_wb_lane])) begin
        res_valid_q <= 1'b0;
      end

      if (load_alloc_fire && req_is_amo) begin
        lane_amo_valid_q[alloc_lane_idx] <= 1'b1;
        lane_amo_op_q[alloc_lane_idx] <= selected_uop.amo_op;
        lane_amo_rs2_q[alloc_lane_idx] <= selected_rs2_data;
        lane_amo_sb_id_q[alloc_lane_idx] <= pend_valid_q ? pend_sb_id_q : sb_id_i;
        lane_amo_addr_q[alloc_lane_idx] <= req_eff_addr;
      end

      if (amo_wb_fire) begin
        lane_amo_valid_q[amo_wb_lane] <= 1'b0;
      end

`ifndef SYNTHESIS
      if (load_alloc_fire || store_req_fire) begin
        if (lsu_trace_en_q && req_has_force_fault) begin
          if (lsu_pf_log_cnt_q < LSU_PF_LOG_BUDGET) begin
            $display("[lsu-force-fault] pc=%h addr=%h is_ld=%0d is_st=%0d ecause=%0d rob=%0d pend=%0d epoch=%0d flush=%0d",
                     pend_valid_q ? pend_uop_q.pc : uop_i.pc,
                     pend_valid_q ? pend_addr_q : req_in_eff_addr,
                     req_is_load, req_is_store, req_force_ecause,
                     pend_valid_q ? pend_rob_tag_q : rob_tag_i, pend_valid_q,
                     pend_valid_q ? pend_uop_q.fetch_epoch : uop_i.fetch_epoch, flush_i);
            lsu_pf_log_cnt_q <= lsu_pf_log_cnt_q + 1'b1;
          end
        end
      end
`endif

      if (store_req_fire) begin
        store_wb_valid_q[store_wb_tail_q] <= 1'b1;
        store_wb_rob_idx_q[store_wb_tail_q] <= pend_valid_q ? pend_rob_tag_q : rob_tag_i;
        store_wb_data_q[store_wb_tail_q] <= (store_misaligned || store_page_fault) ?
                                            Cfg.XLEN'(pend_valid_q ? pend_addr_q : req_in_eff_addr) :
                                            (is_sc && sc_fail) ? Cfg.XLEN'(1) : '0;
        store_wb_exception_q[store_wb_tail_q] <= store_misaligned || store_page_fault;
        store_wb_ecause_q[store_wb_tail_q] <= store_misaligned ? EXC_ST_ADDR_MISALIGNED :
                                              (store_page_fault ? EXC_ST_PAGE_FAULT : '0);
        // B3: a store->load ordering violation (younger executed load aliased
        // this store) is recorded on the store's writeback. When the store
        // retires, the ROB treats is_mispred generically: it commits the store
        // then flushes younger entries and redirects fetch to the violating
        // load's PC so it (and everything after) re-executes.
        store_wb_is_mispred_q[store_wb_tail_q] <= lq_violation_valid;
        store_wb_redirect_pc_q[store_wb_tail_q] <= lq_violation_pc;
        store_wb_has_sq_q[store_wb_tail_q] <= !store_misaligned && !store_page_fault;
        store_wb_pc_q[store_wb_tail_q] <= pend_valid_q ? pend_uop_q.pc : uop_i.pc;
        store_wb_tail_q <= store_wbq_next_idx(store_wb_tail_q);
      end
      if (store_wb_fire) begin
        store_wb_valid_q[store_wb_head_q] <= 1'b0;
        store_wb_head_q <= store_wbq_next_idx(store_wb_head_q);
      end
      if (store_req_fire && !store_wb_fire) begin
        store_wb_count_q <= store_wb_count_q + 1'b1;
      end else if (!store_req_fire && store_wb_fire) begin
        store_wb_count_q <= store_wb_count_q - 1'b1;
      end
`ifndef SYNTHESIS
      for (int p = 0; p < LSU_WB_PORTS; p++) begin
        if (lsu_trace_en_q && wb_valid_o[p] && wb_ready_i[p] && wb_exception_o[p] &&
            ((wb_ecause_o[p] == EXC_LD_PAGE_FAULT) || (wb_ecause_o[p] == EXC_ST_PAGE_FAULT))) begin
          if (lsu_pf_log_cnt_q < LSU_PF_LOG_BUDGET) begin
            $display("[lsu-wb-pf] port=%0d rob=%0d data=%h ecause=%0d is_store_port=%0d flush=%0d",
                     p, wb_rob_idx_o[p], wb_data_o[p], wb_ecause_o[p],
                     (p == STORE_WB_PORT), flush_i);
            lsu_pf_log_cnt_q <= lsu_pf_log_cnt_q + 1'b1;
          end
        end
      end
`endif
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i or negedge rst_ni) begin
    logic [15:0] next_streak;
    logic should_log;
    if (!rst_ni) begin
      lsu_stall_streak_q <= '0;
    end else if (flush_i) begin
      lsu_stall_streak_q <= '0;
    end else if (!lsu_trace_en_q) begin
      lsu_stall_streak_q <= '0;
    end else if (lsu_diag_stall_cond_w) begin
      next_streak = (lsu_stall_streak_q == 16'hffff) ? 16'hffff : (lsu_stall_streak_q + 16'd1);
      should_log = (next_streak == 16'd1) || (next_streak[9:0] == 10'd0);
      lsu_stall_streak_q <= next_streak;
      if ((lsu_stall_trace_log_cnt_q < LSU_STALL_TRACE_LOG_BUDGET) && should_log) begin
        $display("[lsu-stall] pc=%h streak=%0d pend=%0d mmu_state=%0d req(v/r)=%0d/%0d need_mmu=%0d req_is(ld/st)=%0d/%0d load_rdy=%0d store_rdy=%0d lq_alloc=%0d sq_alloc=%0d lq(cnt/full)=%0d/%0d sq(cnt/full)=%0d/%0d wb_cnt=%0d lane_req_ready=0x%h lane_ld_req_valid=0x%h lane_ld_rsp_ready=0x%h ld_rsp(v/r)=%0d/%0d",
                 lsu_diag_pc_w, next_streak, pend_valid_q, mmu_state_q,
                 req_valid_i, req_ready_o, req_need_mmu_walk, req_is_load, req_is_store,
                 load_req_ready, store_req_ready, lq_alloc_ready, sq_alloc_ready,
                 dbg_lq_count_o, lq_full, dbg_sq_count_o, sq_full, store_wb_count_q,
                 lane_req_ready, lane_ld_req_valid, lane_ld_rsp_ready,
                 ld_rsp_valid_i, ld_rsp_ready_o);
        lsu_stall_trace_log_cnt_q <= lsu_stall_trace_log_cnt_q + 1'b1;
      end
    end else begin
      lsu_stall_streak_q <= '0;
    end
  end
`endif

  lq #(
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .DEPTH(LQ_DEPTH),
      .PLEN(Cfg.PLEN),
      .BE_WIDTH(SQ_BE_WIDTH),
      .COMMIT_WIDTH(COMMIT_WIDTH),
      .N_EXEC(LOAD_WB_PORTS)
  ) u_lq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .alloc_valid_i(lq_alloc_valid),
      .alloc_ready_o(lq_alloc_ready),
      .alloc_rob_tag_i(pend_valid_q ? pend_rob_tag_q : rob_tag_i),
      .alloc_pc_i(pend_valid_q ? pend_uop_q.pc : uop_i.pc),
      .alloc_paddr_i(req_eff_addr),
      .alloc_be_i(load_fwd_be),
      .commit_valid_i(commit_valid_i),
      .commit_rob_idx_i(commit_rob_idx_i),
      .exec_valid_i(lq_exec_valid),
      .exec_rob_tag_i(lq_exec_rob_tag),
      .st_query_valid_i(lq_st_query_valid),
      .st_paddr_i(lq_st_paddr),
      .st_be_i(lq_st_be),
      .st_rob_tag_i(lq_st_rob_tag),
      .rob_head_i(rob_head_i),
      .violation_valid_o(lq_violation_valid),
      .violation_pc_o(lq_violation_pc),
      .violation_rob_idx_o(lq_violation_rob_idx),
      .head_valid_o(dbg_lq_head_valid_o),
      .head_rob_tag_o(dbg_lq_head_rob_tag_o),
      .count_o(dbg_lq_count_o),
      .full_o(lq_full),
      .empty_o(lq_empty),
      .inflight_empty_o(lq_inflight_empty)
  );

  // The dedicated `sq` was removed: store-to-load forwarding now lives solely
  // in store_buffer, and AMO ordering / store admission rely on store_wb_q.
  // Debug ports are driven from store_wb_q so existing probes stay meaningful.
  assign dbg_sq_count_o = ($clog2(SQ_DEPTH + 1))'(store_wb_count_q);
  assign dbg_sq_head_valid_o = store_wb_head_valid;
  assign dbg_sq_head_rob_tag_o = store_wb_head_rob_idx;

  assign rsp_id_in_range = ($unsigned(ld_rsp_id_i) < N_LSU);

  always_comb begin
    dbg_alloc_lane = load_alloc_fire ? DBG_SEL_WIDTH'(alloc_lane_idx + 1'b1) : '0;
    dbg_ld_owner = '0;

    // Prefer the response lane in current cycle; fallback to first lane waiting response.
    if (ld_rsp_valid_i && rsp_id_in_range) begin
      dbg_ld_owner = DBG_SEL_WIDTH'(ld_rsp_id_i + 1'b1);
    end else begin
      for (int i = 0; i < N_LSU; i++) begin
        if (dbg_ld_owner == '0 && lane_ld_rsp_ready[i]) begin
          dbg_ld_owner = DBG_SEL_WIDTH'(i + 1);
        end
      end
    end
  end

  initial begin
    if (N_LSU < 1) begin
      $error("lsu_group: N_LSU must be >= 1, got %0d", N_LSU);
    end
  end

endmodule
