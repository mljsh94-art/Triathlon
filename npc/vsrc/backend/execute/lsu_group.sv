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
    parameter int unsigned      ECAUSE_WIDTH  = 5
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

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

    // Store-to-Load Forwarding (query)
    output logic [     Cfg.PLEN-1:0] sb_load_addr_o,
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
    output logic                     wb_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] wb_rob_idx_o,
    output logic [     Cfg.XLEN-1:0] wb_data_o,
    output logic                     wb_exception_o,
    output logic [ECAUSE_WIDTH-1:0]  wb_ecause_o,
    output logic                     wb_is_mispred_o,
    output logic [     Cfg.PLEN-1:0] wb_redirect_pc_o,
    input  logic                     wb_ready_i,

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
  localparam int unsigned LD_ID_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU);
  localparam int unsigned DBG_SEL_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU + 1);
  localparam int unsigned SQ_BE_WIDTH = Cfg.XLEN / 8;
  localparam int unsigned SQ_BYTE_OFF_W = (SQ_BE_WIDTH <= 1) ? 1 : $clog2(SQ_BE_WIDTH);
  localparam int unsigned STORE_WB_Q_DEPTH = (N_LSU < 2) ? 2 : N_LSU;
  localparam int unsigned STORE_WB_Q_IDX_W = (STORE_WB_Q_DEPTH <= 1) ? 1 : $clog2(STORE_WB_Q_DEPTH);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_LD_ADDR_MISALIGNED = ECAUSE_WIDTH'(4);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_ST_ADDR_MISALIGNED = ECAUSE_WIDTH'(6);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_LD_PAGE_FAULT = ECAUSE_WIDTH'(13);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_ST_PAGE_FAULT = ECAUSE_WIDTH'(15);
  localparam logic [1:0] MMU_ACCESS_LOAD  = 2'd1;
  localparam logic [1:0] MMU_ACCESS_STORE = 2'd2;
  localparam logic [1:0] MMU_ST_IDLE = 2'd0;
  localparam logic [1:0] MMU_ST_REQ = 2'd1;
  localparam logic [1:0] MMU_ST_WAIT = 2'd2;
`ifndef SYNTHESIS
  localparam int unsigned LSU_PF_LOG_BUDGET = 128;
  int unsigned lsu_pf_log_cnt_q;
  localparam int unsigned LSU_REQ_TRACE_LOG_BUDGET = 128;
  localparam int unsigned LSU_MMU_TRACE_LOG_BUDGET = 128;
  localparam int unsigned LSU_STALL_TRACE_LOG_BUDGET = 256;
  int unsigned lsu_req_trace_log_cnt_q;
  int unsigned lsu_mmu_trace_log_cnt_q;
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

  logic                [         N_LSU-1:0]                    ld_req_grant;
  logic                [LANE_SEL_WIDTH-1:0]                    ld_req_lane_idx;
  logic                                                        ld_req_grant_valid;
  logic                                                        ld_req_fire;
  logic                [LANE_SEL_WIDTH-1:0]                    ld_req_rr_q;

  logic                [         N_LSU-1:0]                    wb_grant;
  logic                [LANE_SEL_WIDTH-1:0]                    wb_lane_idx;
  logic                                                        wb_grant_valid;
  logic                                                        wb_fire;
  logic                                                        wb_sel_store;
  logic                [LANE_SEL_WIDTH-1:0]                    wb_rr_q;

  logic                                                        lq_alloc_valid;
  logic                                                        lq_alloc_ready;
  logic                                                        lq_pop_valid;
  logic                                                        lq_pop_ready;
  logic                                                        lq_full;
  logic                                                        lq_empty;

  logic                                                        sq_alloc_valid;
  logic                                                        sq_alloc_ready;
  logic                                                        sq_pop_valid;
  logic                                                        sq_pop_ready;
  logic                                                        sq_full;
  logic                                                        sq_empty;
  logic                                                        sq_fwd_query_valid;
  logic                                                        sq_fwd_query_hit;
  logic                [     Cfg.XLEN-1:0]                    sq_fwd_query_data;
  logic                [      Cfg.PLEN-1:0]                   sq_req_word_addr;
  logic                [      Cfg.XLEN-1:0]                   sq_store_data_aligned;
  logic                [     SQ_BE_WIDTH-1:0]                 sq_store_be;
  logic                [     SQ_BE_WIDTH-1:0]                 sq_load_be;
  logic                                                        sb_load_hit_mux;
  logic                [     Cfg.XLEN-1:0]                    sb_load_data_mux;
  logic                [     Cfg.XLEN-1:0]                    sq_fwd_data_rshift;
  logic                [      Cfg.XLEN-1:0]                   req_eff_addr_xlen;
  logic                [      Cfg.PLEN-1:0]                   req_eff_addr;

  logic                                                        req_is_load;
  logic                                                        req_is_store;
  logic                                                        req_is_amo;
  logic                                                        store_misaligned;
  logic                                                        store_page_fault;
  logic                                                        store_need_sq;
  logic                                                        store_req_ready;
  logic                                                        load_req_ready;
  logic                                                        req_has_force_fault;
  logic                [ECAUSE_WIDTH-1:0]                    req_force_ecause;
  logic                                                        req_accept_fire;
  logic                                                        req_accept_ready;
  logic                                                        req_need_mmu_walk;
  logic                                                        amo_inflight;
  logic                                                        amo_order_clear;
  logic                                                        req_ordered_load;
  logic                                                        translation_active;
  logic                [      Cfg.XLEN-1:0]                   req_in_eff_addr_xlen;
  logic                [      Cfg.PLEN-1:0]                   req_in_eff_addr;
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
  decode_pkg::uop_t                                            mmu_uop_q;
  logic                [      Cfg.XLEN-1:0]                   mmu_rs1_data_q;
  logic                [      Cfg.XLEN-1:0]                   mmu_rs2_data_q;
  logic                [ ROB_IDX_WIDTH-1:0]                   mmu_rob_tag_q;
  logic                [  SB_IDX_WIDTH-1:0]                   mmu_sb_id_q;
  logic                [      Cfg.PLEN-1:0]                   mmu_vaddr_q;
  logic                                                        mmu_req_ready;
  logic                                                        mmu_resp_valid;
  logic                [             31:0]                    mmu_resp_paddr;
  logic                                                        mmu_resp_page_fault;
  logic                                                        mmu_pte_req_valid;
  logic                [             31:0]                    mmu_pte_req_paddr;
  logic                                                        mmu_pte_upd_valid;
  logic                [             31:0]                    mmu_pte_upd_paddr;
  logic                [             31:0]                    mmu_pte_upd_data;
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

  logic rsp_id_in_range;
  logic [LANE_SEL_WIDTH-1:0] rsp_lane_idx;
  logic [N_LSU-1:0] lane_amo_valid_q;
  decode_pkg::amo_op_e lane_amo_op_q[N_LSU];
  logic [N_LSU-1:0][Cfg.XLEN-1:0] lane_amo_rs2_q;
  logic [N_LSU-1:0][SB_IDX_WIDTH-1:0] lane_amo_sb_id_q;
  logic [N_LSU-1:0][Cfg.PLEN-1:0] lane_amo_addr_q;
  logic amo_wb_fire;
  logic [Cfg.XLEN-1:0] amo_wb_new_data;
  function automatic logic [LANE_SEL_WIDTH-1:0] rr_next_idx(
      input logic [LANE_SEL_WIDTH-1:0] idx
  );
    begin
      if (N_LSU <= 1) begin
        rr_next_idx = '0;
      end else if (idx == LANE_SEL_WIDTH'(N_LSU - 1)) begin
        rr_next_idx = '0;
      end else begin
        rr_next_idx = idx + LANE_SEL_WIDTH'(1);
      end
    end
  endfunction

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

  function automatic logic [SQ_BE_WIDTH-1:0] store_be_mask(input decode_pkg::lsu_op_e op,
                                                            input logic [Cfg.PLEN-1:0] addr);
    logic [SQ_BE_WIDTH-1:0] mask;
    logic [SQ_BYTE_OFF_W-1:0] off;
    begin
      mask = '0;
      off = addr[SQ_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_SB: begin
          mask[off] = 1'b1;
        end
        decode_pkg::LSU_SH: begin
          for (int i = 0; i < 2; i++) begin
            if ((off + i) < SQ_BE_WIDTH) begin
              mask[off+i] = 1'b1;
            end
          end
        end
        decode_pkg::LSU_SW, decode_pkg::LSU_SC, decode_pkg::LSU_AMO: begin
          for (int i = 0; i < 4; i++) begin
            if ((off + i) < SQ_BE_WIDTH) begin
              mask[off+i] = 1'b1;
            end
          end
        end
        decode_pkg::LSU_SD: begin
          for (int i = 0; i < SQ_BE_WIDTH; i++) begin
            mask[i] = 1'b1;
          end
        end
        default: begin
          mask = '0;
        end
      endcase
      store_be_mask = mask;
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

  function automatic logic [Cfg.XLEN-1:0] store_aligned_data(
      input decode_pkg::lsu_op_e op,
      input logic [Cfg.XLEN-1:0] data,
      input logic [Cfg.PLEN-1:0] addr
  );
    logic [Cfg.XLEN-1:0] aligned;
    logic [SQ_BYTE_OFF_W-1:0] off;
    begin
      aligned = '0;
      off = addr[SQ_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_SB: begin
          if (off < SQ_BE_WIDTH) begin
            aligned[(8*off)+:8] = data[7:0];
          end
        end
        decode_pkg::LSU_SH: begin
          if ((off + 1) < SQ_BE_WIDTH) begin
            aligned[(8*off)+:16] = data[15:0];
          end
        end
        decode_pkg::LSU_SW, decode_pkg::LSU_SC, decode_pkg::LSU_AMO: begin
          if ((off + 3) < SQ_BE_WIDTH) begin
            aligned[(8*off)+:32] = data[31:0];
          end
        end
        decode_pkg::LSU_SD: begin
          aligned = data;
        end
        default: begin
          aligned = data;
        end
      endcase
      store_aligned_data = aligned;
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

  assign req_in_eff_addr_xlen = rs1_data_i + uop_i.imm;
  assign req_in_eff_addr = req_in_eff_addr_xlen[Cfg.PLEN-1:0];
  assign translation_active = mmu_satp_i[31] && (mmu_priv_i != 2'b11);
  assign req_need_mmu_walk = translation_active && (uop_i.is_load || uop_i.is_store) &&
                             !is_store_misaligned(uop_i.lsu_op, req_in_eff_addr) &&
                             !is_load_misaligned(uop_i.lsu_op, req_in_eff_addr);
  assign req_accept_ready = !pend_valid_q && (mmu_state_q == MMU_ST_IDLE);
  assign req_accept_fire = req_valid_i && req_accept_ready && req_need_mmu_walk;
`ifndef SYNTHESIS
  assign lsu_diag_pc_w = pend_valid_q ? pend_uop_q.pc : uop_i.pc;
  assign lsu_diag_stall_watch_w = lsu_diag_watch_pc(lsu_diag_pc_w);
  assign lsu_diag_stall_cond_w = lsu_diag_stall_watch_w && !flush_i &&
                                 ((pend_valid_q && (req_is_load || req_is_store) &&
                                   !load_alloc_fire && !store_req_fire) ||
                                  (req_valid_i && (uop_i.is_load || uop_i.is_store) && !req_ready_o));
`endif

  assign pte_req_valid_o = mmu_pte_req_valid;
  assign pte_req_paddr_o = mmu_pte_req_paddr;
  assign pte_upd_valid_o = mmu_pte_upd_valid;
  assign pte_upd_paddr_o = mmu_pte_upd_paddr;
  assign pte_upd_data_o = mmu_pte_upd_data;

  sv32_mmu #(
      .TLB_ENTRIES(Cfg.DTLB_ENTRIES)
  ) u_lsu_mmu (
      .clk_i,
      .rst_ni,
      .req_valid_i(mmu_state_q == MMU_ST_REQ),
      .req_vaddr_i({{(32-Cfg.PLEN){1'b0}}, mmu_vaddr_q}),
      .req_access_i(mmu_uop_q.is_store ? MMU_ACCESS_STORE : MMU_ACCESS_LOAD),
      .req_priv_i(mmu_priv_i),
      .req_sum_i(mmu_sum_i),
      .req_mxr_i(mmu_mxr_i),
      .satp_i(mmu_satp_i),
      .sfence_vma_i(mmu_sfence_vma_i),
      .req_ready_o(mmu_req_ready),
      .resp_valid_o(mmu_resp_valid),
      .resp_paddr_o(mmu_resp_paddr),
      .resp_page_fault_o(mmu_resp_page_fault),
      .pte_req_valid_o(mmu_pte_req_valid),
      .pte_req_ready_i(pte_req_ready_i),
      .pte_req_paddr_o(mmu_pte_req_paddr),
      .pte_rsp_valid_i(pte_rsp_valid_i),
      .pte_rsp_data_i(pte_rsp_data_i),
      .pte_upd_valid_o(mmu_pte_upd_valid),
      .pte_upd_ready_i(pte_upd_ready_i),
      .pte_upd_paddr_o(mmu_pte_upd_paddr),
      .pte_upd_data_o(mmu_pte_upd_data)
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
          .rs1_data_i('0),
          .rs2_data_i(pend_valid_q ? pend_rs2_data_q : rs2_data_i),
          .addr_override_valid_i(1'b1),
          .addr_override_i(req_eff_addr),
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
          .sb_load_hit_i(sb_load_hit_mux),
          .sb_load_data_i(sb_load_data_mux),

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
  // MMIO request arbitration (priority: lowest lane index)
  // ---------------------------------------------------------
  always_comb begin
    mmio_req_valid_o  = 1'b0;
    mmio_req_addr_o   = '0;
    mmio_req_op_o     = decode_pkg::LSU_LW;
    lane_mmio_req_ready = '0;
    lane_mmio_rsp_valid = '0;
    for (int i = 0; i < N_LSU; i++) begin
      if (!mmio_req_valid_o && lane_mmio_req_valid[i]) begin
        mmio_req_valid_o       = 1'b1;
        mmio_req_addr_o        = lane_mmio_req_addr[i];
        mmio_req_op_o          = lane_mmio_req_op[i];
        lane_mmio_req_ready[i] = mmio_req_ready_i;
        lane_mmio_rsp_valid[i] = mmio_rsp_valid_i;
      end
    end
  end

  assign state_q    = g_lanes[0].u_lane.state_q;
  assign req_tag_q  = g_lanes[0].u_lane.req_tag_q;
  assign req_addr_q = g_lanes[0].u_lane.req_addr_q;
  assign req_eff_addr_xlen = pend_valid_q ? {{(Cfg.XLEN-Cfg.PLEN){1'b0}}, pend_addr_q} : req_in_eff_addr_xlen;
  assign req_eff_addr = pend_valid_q ? pend_addr_q : req_in_eff_addr;
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
  assign store_need_sq = req_is_store && !store_misaligned && !store_page_fault;
  assign amo_inflight = |lane_amo_valid_q;
  assign amo_order_clear = (dbg_lane_busy == '0) && lq_empty && sq_empty &&
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
  assign sq_req_word_addr = {req_eff_addr[Cfg.PLEN-1:SQ_BYTE_OFF_W], {SQ_BYTE_OFF_W{1'b0}}};
  assign sq_store_be = store_be_mask(pend_valid_q ? pend_uop_q.lsu_op : uop_i.lsu_op, req_eff_addr);
  assign sq_load_be = load_be_mask(pend_valid_q ? pend_uop_q.lsu_op : uop_i.lsu_op, req_eff_addr);
  assign sq_store_data_aligned = store_aligned_data(
      pend_valid_q ? pend_uop_q.lsu_op : uop_i.lsu_op,
      pend_valid_q ? pend_rs2_data_q : rs2_data_i,
      req_eff_addr
  );
  assign sq_fwd_query_valid = load_alloc_fire && req_is_load;
  assign sq_fwd_data_rshift = sq_fwd_query_data >> (8 * req_eff_addr[SQ_BYTE_OFF_W-1:0]);
  assign sb_load_hit_mux = sb_load_hit_i || sq_fwd_query_hit;
  assign sb_load_data_mux = sq_fwd_query_hit ? sq_fwd_data_rshift : sb_load_data_i;
  assign sb_order_query_valid_o = req_is_amo;
  assign sb_order_query_sb_id_o = pend_valid_q ? pend_sb_id_q : sb_id_i;

  assign lq_alloc_valid = load_alloc_fire && req_is_load;
  assign sq_alloc_valid = store_req_fire && store_need_sq;

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
  // combinational feedback with issue selection.
  assign store_req_ready = ((store_wb_count_q < STORE_WB_Q_DEPTH) || (store_wb_head_valid && wb_ready_i)) &&
                           sq_alloc_ready;
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
    if (amo_wb_fire && !lane_wb_exception[wb_lane_idx]) begin
      sb_ex_valid_o = 1'b1;
      sb_ex_sb_id_o = lane_amo_sb_id_q[wb_lane_idx];
      sb_ex_addr_o = lane_amo_addr_q[wb_lane_idx];
      sb_ex_data_o = amo_wb_new_data;
      sb_ex_op_o = decode_pkg::LSU_SW;
      sb_ex_rob_idx_o = lane_wb_rob_idx[wb_lane_idx];
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

  always_comb begin
    ld_req_grant = '0;
    ld_req_lane_idx = '0;
    ld_req_grant_valid = 1'b0;
    for (int off = 0; off < N_LSU; off++) begin
      int unsigned idx;
      idx = $unsigned(ld_req_rr_q) + off;
      if (idx >= N_LSU) begin
        idx -= N_LSU;
      end
      if (!ld_req_grant_valid && lane_ld_req_valid[idx]) begin
        ld_req_grant_valid = 1'b1;
        ld_req_grant[idx] = 1'b1;
        ld_req_lane_idx = LANE_SEL_WIDTH'(idx);
      end
    end
  end

  assign ld_req_valid_o = ld_req_grant_valid;
  assign ld_req_id_o = LD_ID_WIDTH'(ld_req_lane_idx);
  assign rsp_lane_idx = LANE_SEL_WIDTH'(ld_rsp_id_i);
  assign rsp_id_in_range = ($unsigned(ld_rsp_id_i) < N_LSU);

  always_comb begin
    ld_req_addr_o = '0;
    ld_req_op_o = decode_pkg::LSU_LW;
    lane_ld_req_ready = '0;

    if (ld_req_grant_valid) begin
      ld_req_addr_o = lane_ld_req_addr[ld_req_lane_idx];
      ld_req_op_o = lane_ld_req_op[ld_req_lane_idx];
      lane_ld_req_ready[ld_req_lane_idx] = ld_req_ready_i;
    end
  end

  always_comb begin
    lane_ld_rsp_valid = '0;
    ld_rsp_ready_o = 1'b0;
    if (ld_rsp_valid_i && rsp_id_in_range) begin
      lane_ld_rsp_valid[rsp_lane_idx] = 1'b1;
      ld_rsp_ready_o = lane_ld_rsp_ready[rsp_lane_idx];
    end
  end

  always_comb begin
    wb_grant = '0;
    wb_lane_idx = '0;
    wb_grant_valid = 1'b0;
    for (int off = 0; off < N_LSU; off++) begin
      int unsigned idx;
      idx = $unsigned(wb_rr_q) + off;
      if (idx >= N_LSU) begin
        idx -= N_LSU;
      end
      if (!wb_grant_valid && lane_wb_valid[idx]) begin
        wb_grant_valid = 1'b1;
        wb_grant[idx] = 1'b1;
        wb_lane_idx = LANE_SEL_WIDTH'(idx);
      end
    end
  end

  always_comb begin
    wb_sel_store = store_wb_head_valid;
    wb_valid_o = store_wb_head_valid || wb_grant_valid;
    wb_rob_idx_o = '0;
    wb_data_o = '0;
    wb_exception_o = 1'b0;
    wb_ecause_o = '0;
    wb_is_mispred_o = 1'b0;
    wb_redirect_pc_o = '0;
    lane_wb_ready = '0;

    if (store_wb_head_valid) begin
      wb_rob_idx_o = store_wb_head_rob_idx;
      wb_data_o = store_wb_head_data;
      wb_exception_o = store_wb_head_exception;
      wb_ecause_o = store_wb_head_ecause;
      wb_is_mispred_o = store_wb_head_is_mispred;
      wb_redirect_pc_o = store_wb_head_redirect_pc;
    end else if (wb_grant_valid) begin
      wb_sel_store = 1'b0;
      wb_rob_idx_o = lane_wb_rob_idx[wb_lane_idx];
      wb_data_o = lane_wb_data[wb_lane_idx];
      wb_exception_o = lane_wb_exception[wb_lane_idx];
      wb_ecause_o = lane_wb_ecause[wb_lane_idx];
      wb_is_mispred_o = lane_wb_is_mispred[wb_lane_idx];
      wb_redirect_pc_o = lane_wb_redirect_pc[wb_lane_idx];
      lane_wb_ready[wb_lane_idx] = wb_ready_i;
    end
  end

  assign wb_fire = wb_valid_o && wb_ready_i;
  assign amo_wb_fire = wb_fire && !wb_sel_store && wb_grant_valid &&
                       lane_amo_valid_q[wb_lane_idx];
  assign amo_wb_new_data = amo_result(lane_amo_op_q[wb_lane_idx],
                                      lane_wb_data[wb_lane_idx],
                                      lane_amo_rs2_q[wb_lane_idx]);
  assign ld_req_fire = ld_req_grant_valid && ld_req_ready_i;
  assign lq_pop_valid = wb_fire && !wb_sel_store;
  assign sq_pop_valid = wb_fire && wb_sel_store && store_wb_head_has_sq;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pend_valid_q <= 1'b0;
      pend_uop_q <= '0;
      pend_rs2_data_q <= '0;
      pend_rob_tag_q <= '0;
      pend_sb_id_q <= '0;
      pend_addr_q <= '0;
      pend_force_fault_q <= 1'b0;
      pend_force_ecause_q <= '0;
      mmu_state_q <= MMU_ST_IDLE;
      mmu_uop_q <= '0;
      mmu_rs1_data_q <= '0;
      mmu_rs2_data_q <= '0;
      mmu_rob_tag_q <= '0;
      mmu_sb_id_q <= '0;
      mmu_vaddr_q <= '0;
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
      wb_rr_q <= '0;
      ld_req_rr_q <= '0;
      lane_amo_valid_q <= '0;
      for (int i = 0; i < N_LSU; i++) begin
        lane_amo_op_q[i] <= decode_pkg::AMO_NONE;
        lane_amo_rs2_q[i] <= '0;
        lane_amo_sb_id_q[i] <= '0;
        lane_amo_addr_q[i] <= '0;
      end
`ifndef SYNTHESIS
      lsu_pf_log_cnt_q <= '0;
      lsu_req_trace_log_cnt_q <= '0;
      lsu_mmu_trace_log_cnt_q <= '0;
      lsu_stall_trace_log_cnt_q <= '0;
      lsu_stall_streak_q <= '0;
`endif
    end else if (flush_i) begin
      pend_valid_q <= 1'b0;
      pend_uop_q <= '0;
      pend_rs2_data_q <= '0;
      pend_rob_tag_q <= '0;
      pend_sb_id_q <= '0;
      pend_addr_q <= '0;
      pend_force_fault_q <= 1'b0;
      pend_force_ecause_q <= '0;
      mmu_state_q <= MMU_ST_IDLE;
      mmu_uop_q <= '0;
      mmu_rs1_data_q <= '0;
      mmu_rs2_data_q <= '0;
      mmu_rob_tag_q <= '0;
      mmu_sb_id_q <= '0;
      mmu_vaddr_q <= '0;
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
      wb_rr_q <= '0;
      ld_req_rr_q <= '0;
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
                   (amo_wb_fire && !lane_wb_exception[wb_lane_idx])) begin
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
        lane_amo_valid_q[wb_lane_idx] <= 1'b0;
      end

      if (req_accept_fire) begin
`ifndef SYNTHESIS
        if (lsu_trace_en_q &&
            (lsu_req_trace_log_cnt_q < LSU_REQ_TRACE_LOG_BUDGET) &&
            lsu_diag_watch_pc(uop_i.pc)) begin
          $display("[lsu-req] pc=%h rs1=%h rs2=%h imm=%h eff=%h need_mmu=%0d is_ld=%0d is_st=%0d rob=%0d sb=%0d ftq=%0d epoch=%0d",
                   uop_i.pc, rs1_data_i, rs2_data_i, uop_i.imm, req_in_eff_addr, req_need_mmu_walk,
                   uop_i.is_load, uop_i.is_store, rob_tag_i, sb_id_i, uop_i.ftq_id, uop_i.fetch_epoch);
          lsu_req_trace_log_cnt_q <= lsu_req_trace_log_cnt_q + 1'b1;
        end
`endif
        if ((uop_i.is_load || uop_i.is_store) && !req_need_mmu_walk) begin
          pend_valid_q <= 1'b1;
          pend_uop_q <= uop_i;
          pend_rs2_data_q <= rs2_data_i;
          pend_rob_tag_q <= rob_tag_i;
          pend_sb_id_q <= sb_id_i;
          pend_addr_q <= req_in_eff_addr;
          pend_force_fault_q <= 1'b1;
          if (uop_i.is_load) begin
            pend_force_ecause_q <= EXC_LD_ADDR_MISALIGNED;
          end else begin
            pend_force_ecause_q <= EXC_ST_ADDR_MISALIGNED;
          end
        end else if (req_need_mmu_walk) begin
          mmu_state_q <= MMU_ST_REQ;
          mmu_uop_q <= uop_i;
          mmu_rs1_data_q <= rs1_data_i;
          mmu_rs2_data_q <= rs2_data_i;
          mmu_rob_tag_q <= rob_tag_i;
          mmu_sb_id_q <= sb_id_i;
          mmu_vaddr_q <= req_in_eff_addr;
        end else begin
          pend_valid_q <= 1'b1;
          pend_uop_q <= uop_i;
          pend_rs2_data_q <= rs2_data_i;
          pend_rob_tag_q <= rob_tag_i;
          pend_sb_id_q <= sb_id_i;
          pend_addr_q <= req_in_eff_addr;
          pend_force_fault_q <= 1'b0;
          pend_force_ecause_q <= '0;
        end
      end

      if (mmu_state_q == MMU_ST_REQ && mmu_req_ready) begin
        mmu_state_q <= MMU_ST_WAIT;
      end

      if (mmu_state_q == MMU_ST_WAIT && mmu_resp_valid) begin
        mmu_state_q <= MMU_ST_IDLE;
        pend_valid_q <= 1'b1;
        pend_uop_q <= mmu_uop_q;
        pend_rs2_data_q <= mmu_rs2_data_q;
        pend_rob_tag_q <= mmu_rob_tag_q;
        pend_sb_id_q <= mmu_sb_id_q;
        pend_addr_q <= mmu_resp_page_fault ? mmu_vaddr_q[Cfg.PLEN-1:0] :
                                            mmu_resp_paddr[Cfg.PLEN-1:0];
        pend_force_fault_q <= mmu_resp_page_fault;
        if (mmu_resp_page_fault && mmu_uop_q.is_store) begin
          pend_force_ecause_q <= EXC_ST_PAGE_FAULT;
        end else if (mmu_resp_page_fault && mmu_uop_q.is_load) begin
          pend_force_ecause_q <= EXC_LD_PAGE_FAULT;
        end else begin
          pend_force_ecause_q <= '0;
        end
`ifndef SYNTHESIS
        if (lsu_trace_en_q &&
            (lsu_mmu_trace_log_cnt_q < LSU_MMU_TRACE_LOG_BUDGET) &&
            lsu_diag_watch_pc(mmu_uop_q.pc)) begin
          $display("[lsu-mmu-rsp] pc=%h vaddr=%h paddr=%h pf=%0d satp=%h priv=%0d rob=%0d sb=%0d epoch=%0d flush=%0d",
                   mmu_uop_q.pc, mmu_vaddr_q, mmu_resp_paddr, mmu_resp_page_fault, mmu_satp_i, mmu_priv_i,
                   mmu_rob_tag_q, mmu_sb_id_q, mmu_uop_q.fetch_epoch, flush_i);
          lsu_mmu_trace_log_cnt_q <= lsu_mmu_trace_log_cnt_q + 1'b1;
        end
        if (lsu_trace_en_q && mmu_resp_page_fault) begin
          if (lsu_pf_log_cnt_q < LSU_PF_LOG_BUDGET) begin
            $display("[lsu-mmu-pf] pc=%h vaddr=%h satp=%h priv=%0d access=%0d sum=%0d mxr=%0d rob=%0d sb=%0d epoch=%0d flush=%0d",
                     mmu_uop_q.pc, mmu_vaddr_q, mmu_satp_i, mmu_priv_i,
                     mmu_uop_q.is_store ? MMU_ACCESS_STORE : MMU_ACCESS_LOAD,
                     mmu_sum_i, mmu_mxr_i, mmu_rob_tag_q, mmu_sb_id_q, mmu_uop_q.fetch_epoch, flush_i);
            lsu_pf_log_cnt_q <= lsu_pf_log_cnt_q + 1'b1;
          end
        end

`endif
      end

      if (load_alloc_fire || store_req_fire) begin
`ifndef SYNTHESIS
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
`endif
        pend_valid_q <= 1'b0;
      end

      if (store_req_fire) begin
        store_wb_valid_q[store_wb_tail_q] <= 1'b1;
        store_wb_rob_idx_q[store_wb_tail_q] <= pend_valid_q ? pend_rob_tag_q : rob_tag_i;
        store_wb_data_q[store_wb_tail_q] <= (store_misaligned || store_page_fault) ?
                                            Cfg.XLEN'(pend_valid_q ? pend_addr_q : req_in_eff_addr) :
                                            (is_sc && sc_fail) ? Cfg.XLEN'(1) : '0;
        store_wb_exception_q[store_wb_tail_q] <= store_misaligned || store_page_fault;
        store_wb_ecause_q[store_wb_tail_q] <= store_misaligned ? EXC_ST_ADDR_MISALIGNED :
                                              (store_page_fault ? EXC_ST_PAGE_FAULT : '0);
        store_wb_is_mispred_q[store_wb_tail_q] <= 1'b0;
        store_wb_redirect_pc_q[store_wb_tail_q] <= '0;
        store_wb_has_sq_q[store_wb_tail_q] <= !store_misaligned && !store_page_fault;
        store_wb_pc_q[store_wb_tail_q] <= pend_valid_q ? pend_uop_q.pc : uop_i.pc;
        store_wb_tail_q <= store_wbq_next_idx(store_wb_tail_q);
      end
      if (wb_fire && wb_sel_store) begin
        store_wb_valid_q[store_wb_head_q] <= 1'b0;
        store_wb_head_q <= store_wbq_next_idx(store_wb_head_q);
      end
      if (store_req_fire && !(wb_fire && wb_sel_store)) begin
        store_wb_count_q <= store_wb_count_q + 1'b1;
      end else if (!store_req_fire && (wb_fire && wb_sel_store)) begin
        store_wb_count_q <= store_wb_count_q - 1'b1;
      end
      if (wb_fire && !wb_sel_store && wb_grant_valid) begin
        wb_rr_q <= rr_next_idx(wb_lane_idx);
      end
`ifndef SYNTHESIS
      if (lsu_trace_en_q && wb_fire && wb_exception_o &&
          ((wb_ecause_o == EXC_LD_PAGE_FAULT) || (wb_ecause_o == EXC_ST_PAGE_FAULT))) begin
        if (lsu_pf_log_cnt_q < LSU_PF_LOG_BUDGET) begin
          $display("[lsu-wb-pf] rob=%0d data=%h ecause=%0d sel_store=%0d lane=%0d flush=%0d",
                   wb_rob_idx_o, wb_data_o, wb_ecause_o, wb_sel_store, wb_lane_idx, flush_i);
          lsu_pf_log_cnt_q <= lsu_pf_log_cnt_q + 1'b1;
        end
      end
`endif
      if (ld_req_fire) begin
        ld_req_rr_q <= rr_next_idx(ld_req_lane_idx);
      end
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
      .DEPTH(LQ_DEPTH)
  ) u_lq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .alloc_valid_i(lq_alloc_valid),
      .alloc_ready_o(lq_alloc_ready),
      .alloc_rob_tag_i(pend_valid_q ? pend_rob_tag_q : rob_tag_i),
      .pop_valid_i(lq_pop_valid),
      .pop_ready_o(lq_pop_ready),
      .head_valid_o(dbg_lq_head_valid_o),
      .head_rob_tag_o(dbg_lq_head_rob_tag_o),
      .count_o(dbg_lq_count_o),
      .full_o(lq_full),
      .empty_o(lq_empty)
  );

  sq #(
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .ADDR_WIDTH(Cfg.PLEN),
      .DATA_WIDTH(Cfg.XLEN),
      .DEPTH(SQ_DEPTH)
  ) u_sq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .alloc_valid_i(sq_alloc_valid),
      .alloc_ready_o(sq_alloc_ready),
      .alloc_rob_tag_i(pend_valid_q ? pend_rob_tag_q : rob_tag_i),
      .alloc_addr_i(sq_req_word_addr),
      .alloc_data_i(sq_store_data_aligned),
      .alloc_be_i(sq_store_be),
      .pop_valid_i(sq_pop_valid),
      .pop_ready_o(sq_pop_ready),
      .fwd_query_valid_i(sq_fwd_query_valid),
      .fwd_query_addr_i(sq_req_word_addr),
      .fwd_query_be_i(sq_load_be),
      .fwd_query_rob_tag_i(pend_valid_q ? pend_rob_tag_q : rob_tag_i),
      .rob_head_i(rob_head_i),
      .fwd_query_hit_o(sq_fwd_query_hit),
      .fwd_query_data_o(sq_fwd_query_data),
      .head_valid_o(dbg_sq_head_valid_o),
      .head_rob_tag_o(dbg_sq_head_rob_tag_o),
      .head_addr_o(),
      .head_data_o(),
      .head_be_o(),
      .count_o(dbg_sq_count_o),
      .full_o(sq_full),
      .empty_o(sq_empty)
  );

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
