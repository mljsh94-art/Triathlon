// vsrc/backend/lsu/lsu_mmu.sv
import config_pkg::*;
import decode_pkg::*;

// Unique address-translation entry point for the LSU.
//
// Encapsulates the sv32 MMU (+ DTLB) together with the wrapper FSM that
// previously lived inside lsu_group as the `pend_* / mmu_state_q` always_ff.
// The block exposes a single request -> resolved (pend) handshake:
//
//   * A request that does NOT need a page-table walk (translation off, M-mode,
//     or misaligned) is reported back combinationally as `need_walk_o = 0` and
//     is handled directly by the dispatch logic in lsu_group (bypass path).
//   * A request that needs a walk is latched here, driven through the MMU FSM,
//     and its resolved physical address (or page-fault info) is parked in the
//     `pend_*` registers for one cycle until the dispatcher consumes it
//     (`pend_consume_i`).
//
// This removes the two-stage admission coupling (MMU FSM + pend buffering)
// from lsu_group and makes translation the only owner of the MMU.
module lsu_mmu #(
    parameter config_pkg::cfg_t Cfg           = config_pkg::EmptyCfg,
    parameter int unsigned      ROB_IDX_WIDTH = 6,
    parameter int unsigned      ST_IDX_WIDTH  = 5,
    parameter int unsigned      ECAUSE_WIDTH  = 5
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // =========================================================
    // Request channel (from issue, post-AGU)
    // =========================================================
    input  logic                     req_valid_i,
    input  decode_pkg::uop_t         uop_i,
    input  logic [     Cfg.XLEN-1:0] rs1_data_i,
    input  logic [     Cfg.XLEN-1:0] rs2_data_i,
    input  logic [ROB_IDX_WIDTH-1:0] rob_tag_i,
    input  logic [ ST_IDX_WIDTH-1:0] st_id_i,
    input  logic [     Cfg.PLEN-1:0] req_vaddr_i,
    input  logic                     req_is_load_i,
    input  logic                     req_is_store_i,
    input  logic                     req_misaligned_i,

    // =========================================================
    // MMU configuration (from CSR)
    // =========================================================
    input logic [31:0] mmu_satp_i,
    input logic [ 1:0] mmu_priv_i,
    input logic        mmu_sum_i,
    input logic        mmu_mxr_i,
    input logic        mmu_sfence_vma_i,

    // =========================================================
    // PTE memory interface (passthrough to D-side memory)
    // =========================================================
    output logic        pte_req_valid_o,
    input  logic        pte_req_ready_i,
    output logic [31:0] pte_req_paddr_o,
    input  logic        pte_rsp_valid_i,
    input  logic [31:0] pte_rsp_data_i,
    output logic        pte_upd_valid_o,
    input  logic        pte_upd_ready_i,
    output logic [31:0] pte_upd_paddr_o,
    output logic [31:0] pte_upd_data_o,

    // =========================================================
    // Translation status (combinational, consumed by dispatch)
    // =========================================================
    output logic       need_walk_o,     // req needs a page-table walk
    output logic       accept_ready_o,  // can latch a new walk (!pend && idle)
    output logic [1:0] mmu_state_o,     // wrapper FSM state (IDLE/REQ/WAIT)

    // =========================================================
    // Resolved request (pend) output + consume handshake
    // =========================================================
    input  logic                     pend_consume_i,  // dispatcher took the pend req
    output logic                     pend_valid_o,
    output decode_pkg::uop_t         pend_uop_o,
    output logic [     Cfg.XLEN-1:0] pend_rs2_data_o,
    output logic [ROB_IDX_WIDTH-1:0] pend_rob_tag_o,
    output logic [ ST_IDX_WIDTH-1:0] pend_st_id_o,
    output logic [     Cfg.PLEN-1:0] pend_addr_o,
    output logic                     pend_force_fault_o,
    output logic [ ECAUSE_WIDTH-1:0] pend_force_ecause_o
);

  localparam logic [ECAUSE_WIDTH-1:0] EXC_LD_ADDR_MISALIGNED = ECAUSE_WIDTH'(4);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_ST_ADDR_MISALIGNED = ECAUSE_WIDTH'(6);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_LD_PAGE_FAULT = ECAUSE_WIDTH'(13);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_ST_PAGE_FAULT = ECAUSE_WIDTH'(15);
  localparam logic [1:0] MMU_ACCESS_LOAD = 2'd1;
  localparam logic [1:0] MMU_ACCESS_STORE = 2'd2;
  localparam logic [1:0] MMU_ST_IDLE = 2'd0;
  localparam logic [1:0] MMU_ST_REQ = 2'd1;
  localparam logic [1:0] MMU_ST_WAIT = 2'd2;

  // -------------------------------------------------------------------------
  // pend (resolved request) registers
  // -------------------------------------------------------------------------
  logic                     pend_valid_q;
  decode_pkg::uop_t         pend_uop_q;
  logic [     Cfg.XLEN-1:0] pend_rs2_data_q;
  logic [ROB_IDX_WIDTH-1:0] pend_rob_tag_q;
  logic [ ST_IDX_WIDTH-1:0] pend_st_id_q;
  logic [     Cfg.PLEN-1:0] pend_addr_q;
  logic                     pend_force_fault_q;
  logic [ ECAUSE_WIDTH-1:0] pend_force_ecause_q;

  // -------------------------------------------------------------------------
  // MMU wrapper FSM registers
  // -------------------------------------------------------------------------
  logic [             1:0] mmu_state_q;
  decode_pkg::uop_t        mmu_uop_q;
  logic [     Cfg.XLEN-1:0] mmu_rs2_data_q;
  logic [ROB_IDX_WIDTH-1:0] mmu_rob_tag_q;
  logic [ ST_IDX_WIDTH-1:0] mmu_stq_id_q;
  logic [     Cfg.PLEN-1:0] mmu_vaddr_q;

  logic        mmu_req_ready;
  logic        mmu_resp_valid;
  logic [31:0] mmu_resp_paddr;
  logic        mmu_resp_page_fault;

  logic        translation_active;
  logic        need_walk;
  logic        accept_ready;
  logic        accept_fire;

`ifndef SYNTHESIS
  localparam int unsigned LSU_PF_LOG_BUDGET = 128;
  localparam int unsigned LSU_REQ_TRACE_LOG_BUDGET = 128;
  localparam int unsigned LSU_MMU_TRACE_LOG_BUDGET = 128;
  int unsigned lsu_pf_log_cnt_q;
  int unsigned lsu_req_trace_log_cnt_q;
  int unsigned lsu_mmu_trace_log_cnt_q;
  logic        lsu_trace_en_q;
  initial lsu_trace_en_q = $test$plusargs("npc_diag_trace");

  function automatic logic lsu_diag_watch_pc(input logic [31:0] pc);
    begin
      lsu_diag_watch_pc = (pc == 32'hc074befe) ||  // cmp_ex_search + 0x8
                          (pc == 32'hc076a580) ||  // exception pair A
                          (pc == 32'hc076a584) ||  // adjacent hot load
                          (pc == 32'hc074c47e) ||  // hang window load (stack restore)
                          (pc == 32'hc074c480) ||  // hang window load (stack restore)
                          (pc == 32'hc074cf9e);    // hang window load
    end
  endfunction
`endif

  // -------------------------------------------------------------------------
  // Translation classification (combinational)
  // -------------------------------------------------------------------------
  assign translation_active = mmu_satp_i[31] && (mmu_priv_i != 2'b11);
  assign need_walk = translation_active && (req_is_load_i || req_is_store_i) && !req_misaligned_i;
  assign accept_ready = !pend_valid_q && (mmu_state_q == MMU_ST_IDLE);
  assign accept_fire = req_valid_i && accept_ready && need_walk;

  assign need_walk_o = need_walk;
  assign accept_ready_o = accept_ready;
  assign mmu_state_o = mmu_state_q;

  assign pend_valid_o = pend_valid_q;
  assign pend_uop_o = pend_uop_q;
  assign pend_rs2_data_o = pend_rs2_data_q;
  assign pend_rob_tag_o = pend_rob_tag_q;
  assign pend_st_id_o = pend_st_id_q;
  assign pend_addr_o = pend_addr_q;
  assign pend_force_fault_o = pend_force_fault_q;
  assign pend_force_ecause_o = pend_force_ecause_q;

  // -------------------------------------------------------------------------
  // sv32 MMU (+ DTLB)
  // -------------------------------------------------------------------------
  sv32_mmu #(
      .TLB_ENTRIES(Cfg.DTLB_ENTRIES)
  ) u_lsu_mmu (
      .clk_i,
      .rst_ni,
      .req_valid_i(mmu_state_q == MMU_ST_REQ),
      .req_vaddr_i({{(32 - Cfg.PLEN) {1'b0}}, mmu_vaddr_q}),
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
      .pte_req_valid_o(pte_req_valid_o),
      .pte_req_ready_i(pte_req_ready_i),
      .pte_req_paddr_o(pte_req_paddr_o),
      .pte_rsp_valid_i(pte_rsp_valid_i),
      .pte_rsp_data_i(pte_rsp_data_i),
      .pte_upd_valid_o(pte_upd_valid_o),
      .pte_upd_ready_i(pte_upd_ready_i),
      .pte_upd_paddr_o(pte_upd_paddr_o),
      .pte_upd_data_o(pte_upd_data_o)
  );

  // -------------------------------------------------------------------------
  // Wrapper FSM + pend buffering
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pend_valid_q <= 1'b0;
      pend_uop_q <= '0;
      pend_rs2_data_q <= '0;
      pend_rob_tag_q <= '0;
      pend_st_id_q <= '0;
      pend_addr_q <= '0;
      pend_force_fault_q <= 1'b0;
      pend_force_ecause_q <= '0;
      mmu_state_q <= MMU_ST_IDLE;
      mmu_uop_q <= '0;
      mmu_rs2_data_q <= '0;
      mmu_rob_tag_q <= '0;
      mmu_stq_id_q <= '0;
      mmu_vaddr_q <= '0;
`ifndef SYNTHESIS
      lsu_pf_log_cnt_q <= '0;
      lsu_req_trace_log_cnt_q <= '0;
      lsu_mmu_trace_log_cnt_q <= '0;
`endif
    end else if (flush_i) begin
      pend_valid_q <= 1'b0;
      pend_uop_q <= '0;
      pend_rs2_data_q <= '0;
      pend_rob_tag_q <= '0;
      pend_st_id_q <= '0;
      pend_addr_q <= '0;
      pend_force_fault_q <= 1'b0;
      pend_force_ecause_q <= '0;
      mmu_state_q <= MMU_ST_IDLE;
      mmu_uop_q <= '0;
      mmu_rs2_data_q <= '0;
      mmu_rob_tag_q <= '0;
      mmu_stq_id_q <= '0;
      mmu_vaddr_q <= '0;
    end else begin
      if (accept_fire) begin
`ifndef SYNTHESIS
        if (lsu_trace_en_q &&
            (lsu_req_trace_log_cnt_q < LSU_REQ_TRACE_LOG_BUDGET) &&
            lsu_diag_watch_pc(uop_i.pc)) begin
          $display("[lsu-req] pc=%h rs1=%h rs2=%h imm=%h eff=%h need_mmu=%0d is_ld=%0d is_st=%0d rob=%0d sb=%0d ftq=%0d epoch=%0d",
                   uop_i.pc, rs1_data_i, rs2_data_i, uop_i.imm, req_vaddr_i, need_walk,
                   uop_i.is_load, uop_i.is_store, rob_tag_i, st_id_i, uop_i.ftq_id, uop_i.fetch_epoch);
          lsu_req_trace_log_cnt_q <= lsu_req_trace_log_cnt_q + 1'b1;
        end
`endif
        // accept_fire implies need_walk, so always start an MMU walk.
        mmu_state_q <= MMU_ST_REQ;
        mmu_uop_q <= uop_i;
        mmu_rs2_data_q <= rs2_data_i;
        mmu_rob_tag_q <= rob_tag_i;
        mmu_stq_id_q <= st_id_i;
        mmu_vaddr_q <= req_vaddr_i;
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
        pend_st_id_q <= mmu_stq_id_q;
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
                   mmu_rob_tag_q, mmu_stq_id_q, mmu_uop_q.fetch_epoch, flush_i);
          lsu_mmu_trace_log_cnt_q <= lsu_mmu_trace_log_cnt_q + 1'b1;
        end
        if (lsu_trace_en_q && mmu_resp_page_fault) begin
          if (lsu_pf_log_cnt_q < LSU_PF_LOG_BUDGET) begin
            $display("[lsu-mmu-pf] pc=%h vaddr=%h satp=%h priv=%0d access=%0d sum=%0d mxr=%0d rob=%0d sb=%0d epoch=%0d flush=%0d",
                     mmu_uop_q.pc, mmu_vaddr_q, mmu_satp_i, mmu_priv_i,
                     mmu_uop_q.is_store ? MMU_ACCESS_STORE : MMU_ACCESS_LOAD,
                     mmu_sum_i, mmu_mxr_i, mmu_rob_tag_q, mmu_stq_id_q, mmu_uop_q.fetch_epoch, flush_i);
            lsu_pf_log_cnt_q <= lsu_pf_log_cnt_q + 1'b1;
          end
        end
`endif
      end

      // Dispatcher consumed the resolved request: free the pend slot.
      if (pend_consume_i) begin
        pend_valid_q <= 1'b0;
      end
    end
  end

endmodule
