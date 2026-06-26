// vsrc/test/tb_lsu.sv
import config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;

module tb_lsu #(
    parameter int unsigned TB_ROB_IDX_WIDTH = 6,
    parameter int unsigned TB_STQ_DEPTH = 32,
    parameter int unsigned TB_ST_IDX_WIDTH = $clog2(TB_STQ_DEPTH),
    parameter int unsigned TB_LSU_GROUP_SIZE = 2,
    parameter int unsigned TB_LD_ID_WIDTH = (TB_LSU_GROUP_SIZE <= 1) ? 1 : $clog2(TB_LSU_GROUP_SIZE),
    parameter int unsigned TB_LDQ_DEPTH = 8,
    parameter int unsigned TB_SQ_DEPTH = 8
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // Request interface
    input  logic req_valid_i,
    output logic req_ready_o,
    input  logic is_load_i,
    input  logic is_store_i,
    input  logic [3:0] lsu_op_i,
    input  logic [3:0] amo_op_i,
    input  logic [global_config_pkg::Cfg.XLEN-1:0] imm_i,
    input  logic [global_config_pkg::Cfg.XLEN-1:0] rs1_data_i,
    input  logic [global_config_pkg::Cfg.XLEN-1:0] rs2_data_i,
    input  logic [TB_ROB_IDX_WIDTH-1:0] rob_tag_i,
    input  logic [TB_ST_IDX_WIDTH-1:0] st_id_i,
    input  logic [31:0]                 mmu_satp_i,
    input  logic [1:0]                  mmu_priv_i,
    input  logic                        mmu_sum_i,
    input  logic                        mmu_mxr_i,
    input  logic                        mmu_sfence_vma_i,

    // Store buffer execute write
    output logic                        st_ex_valid_o,
    output logic [TB_ST_IDX_WIDTH-1:0]  st_ex_st_id_o,
    output logic [global_config_pkg::Cfg.PLEN-1:0] st_ex_addr_o,
    output logic [global_config_pkg::Cfg.XLEN-1:0] st_ex_data_o,
    output decode_pkg::lsu_op_e         st_ex_op_o,

    // Store-to-load forwarding
    output logic [global_config_pkg::Cfg.PLEN-1:0] stq_fwd_addr_o,
    input  logic                       stq_fwd_hit_i,
    input  logic [global_config_pkg::Cfg.XLEN-1:0] stq_fwd_data_i,

    // DCache load port
    output logic                       ld_req_valid_o,
    input  logic                       ld_req_ready_i,
    output logic [global_config_pkg::Cfg.PLEN-1:0] ld_req_addr_o,
    output decode_pkg::lsu_op_e        ld_req_op_o,
    output logic [TB_LD_ID_WIDTH-1:0]  ld_req_id_o,

    input  logic                       ld_rsp_valid_i,
    input  logic [TB_LD_ID_WIDTH-1:0]  ld_rsp_id_i,
    output logic                       ld_rsp_ready_o,
    input  logic [global_config_pkg::Cfg.XLEN-1:0] ld_rsp_data_i,
    input  logic                       ld_rsp_err_i,
    output logic                       pte_req_valid_o,
    input  logic                       pte_req_ready_i,
    output logic [31:0]                pte_req_paddr_o,
    input  logic                       pte_rsp_valid_i,
    input  logic [31:0]                pte_rsp_data_i,
    output logic                       pte_upd_valid_o,
    input  logic                       pte_upd_ready_i,
    output logic [31:0]                pte_upd_paddr_o,
    output logic [31:0]                pte_upd_data_o,

    // Writeback
    output logic                       wb_valid_o,
    output logic [TB_ROB_IDX_WIDTH-1:0] wb_rob_idx_o,
    output logic [global_config_pkg::Cfg.XLEN-1:0] wb_data_o,
    output logic                       wb_exception_o,
    output logic [4:0]                 wb_ecause_o,
    output logic                       wb_is_mispred_o,
    output logic [global_config_pkg::Cfg.PLEN-1:0] wb_redirect_pc_o,
    input  logic                       wb_ready_i,

    // Direct queue tests (Task 2 red/green)
    input  logic                          lq_test_alloc_valid_i,
    input  logic [TB_ROB_IDX_WIDTH-1:0]   lq_test_alloc_rob_tag_i,
    output logic                          lq_test_alloc_ready_o,
    // B2: free is associative by committing rob_idx (no head pop).
    input  logic                          lq_test_commit_valid_i,
    input  logic [TB_ROB_IDX_WIDTH-1:0]   lq_test_commit_rob_idx_i,
    output logic [$clog2(TB_LDQ_DEPTH + 1)-1:0] lq_test_count_o,
    output logic                          lq_test_head_valid_o,
    output logic [TB_ROB_IDX_WIDTH-1:0]   lq_test_head_rob_tag_o
);

  decode_pkg::uop_t uop;
  always_comb begin
    uop = '0;
    uop.valid    = 1'b1;
    uop.is_load  = is_load_i;
    uop.is_store = is_store_i;
    uop.lsu_op   = decode_pkg::lsu_op_e'(lsu_op_i);
    uop.amo_op   = decode_pkg::amo_op_e'(amo_op_i);
    uop.imm      = imm_i;
  end

  // Widened LSU writeback (experiment): the group now exposes LSU_WB_PORTS
  // CDB ports (LOAD load-lane ports + 1 store port). The unit-test harness
  // keeps a single-port observation interface (test_lsu.cpp), so reduce the
  // vector to a scalar (store port takes priority, matching the old mux), and
  // free every retiring port through the commit broadcast.
  localparam int unsigned TB_LOAD_WB_PORTS = 2;
  localparam int unsigned TB_LSU_WB_PORTS  = TB_LOAD_WB_PORTS + 1;
  localparam int unsigned TB_STORE_WB_PORT = TB_LOAD_WB_PORTS;

  logic [TB_LSU_WB_PORTS-1:0]                                  dut_wb_valid;
  logic [TB_LSU_WB_PORTS-1:0][TB_ROB_IDX_WIDTH-1:0]            dut_wb_rob_idx;
  logic [TB_LSU_WB_PORTS-1:0][global_config_pkg::Cfg.XLEN-1:0] dut_wb_data;
  logic [TB_LSU_WB_PORTS-1:0]                                  dut_wb_exception;
  logic [TB_LSU_WB_PORTS-1:0][4:0]                             dut_wb_ecause;
  logic [TB_LSU_WB_PORTS-1:0]                                  dut_wb_is_mispred;
  logic [TB_LSU_WB_PORTS-1:0][global_config_pkg::Cfg.PLEN-1:0] dut_wb_redirect_pc;

  always_comb begin
    wb_valid_o       = |dut_wb_valid;
    wb_rob_idx_o     = dut_wb_rob_idx[0];
    wb_data_o        = dut_wb_data[0];
    wb_exception_o   = dut_wb_exception[0];
    wb_ecause_o      = dut_wb_ecause[0];
    wb_is_mispred_o  = dut_wb_is_mispred[0];
    wb_redirect_pc_o = dut_wb_redirect_pc[0];
    // Last valid port wins => store port (highest index) takes priority.
    for (int p = 0; p < TB_LSU_WB_PORTS; p++) begin
      if (dut_wb_valid[p]) begin
        wb_rob_idx_o     = dut_wb_rob_idx[p];
        wb_data_o        = dut_wb_data[p];
        wb_exception_o   = dut_wb_exception[p];
        wb_ecause_o      = dut_wb_ecause[p];
        wb_is_mispred_o  = dut_wb_is_mispred[p];
        wb_redirect_pc_o = dut_wb_redirect_pc[p];
      end
    end
  end

  // The unit testbench has no ROB; free each LDQ entry as soon as its load
  // writes back so the datapath tests keep their original occupancy behavior.
  localparam int unsigned TB_COMMIT_WIDTH = 4;
  logic [TB_COMMIT_WIDTH-1:0]                    dut_commit_valid;
  logic [TB_COMMIT_WIDTH-1:0][TB_ROB_IDX_WIDTH-1:0] dut_commit_rob_idx;
  always_comb begin
    dut_commit_valid   = '0;
    dut_commit_rob_idx = '0;
    for (int p = 0; p < TB_LSU_WB_PORTS; p++) begin
      dut_commit_valid[p]   = dut_wb_valid[p] && wb_ready_i;
      dut_commit_rob_idx[p] = dut_wb_rob_idx[p];
    end
  end

  // --- Store 完成上报 FIFO（test-only，复刻原 lsu_group 内 store_wb_q）---
  // 真实设计里 store_wb_q 已并入 stq；本单元 tb 没有 stq（C++ 建模 STQ/转发），
  // 这里用一个等深 FIFO 接住 dut 的 st_complete_* 并喂回 st_wb_*，保持 store
  // 写回时序/行为与重构前一致。
  logic tb_st_complete_valid;
  logic [TB_ROB_IDX_WIDTH-1:0] tb_st_complete_rob_idx;
  logic [global_config_pkg::Cfg.XLEN-1:0] tb_st_complete_data;
  logic tb_st_complete_exception;
  logic [4:0] tb_st_complete_ecause;
  logic tb_st_complete_is_mispred;
  logic [global_config_pkg::Cfg.PLEN-1:0] tb_st_complete_redirect_pc;
  logic tb_st_wb_fire;
  logic tb_st_wb_valid;
  logic [TB_ROB_IDX_WIDTH-1:0] tb_st_wb_rob_idx;
  logic [global_config_pkg::Cfg.XLEN-1:0] tb_st_wb_data;
  logic tb_st_wb_exception;
  logic [4:0] tb_st_wb_ecause;
  logic tb_st_wb_is_mispred;
  logic [global_config_pkg::Cfg.PLEN-1:0] tb_st_wb_redirect_pc;
  logic [$clog2(TB_STQ_DEPTH+1)-1:0] tb_st_unreported_count;

  localparam int unsigned TB_SWBQ_DEPTH = TB_STQ_DEPTH;
  localparam int unsigned TB_SWBQ_IDX_W = $clog2(TB_SWBQ_DEPTH);
  logic [TB_SWBQ_DEPTH-1:0][TB_ROB_IDX_WIDTH-1:0] swbq_rob_idx;
  logic [TB_SWBQ_DEPTH-1:0][global_config_pkg::Cfg.XLEN-1:0] swbq_data;
  logic [TB_SWBQ_DEPTH-1:0] swbq_exception;
  logic [TB_SWBQ_DEPTH-1:0][4:0] swbq_ecause;
  logic [TB_SWBQ_DEPTH-1:0] swbq_is_mispred;
  logic [TB_SWBQ_DEPTH-1:0][global_config_pkg::Cfg.PLEN-1:0] swbq_redirect_pc;
  logic [TB_SWBQ_IDX_W-1:0] swbq_head, swbq_tail;
  logic [$clog2(TB_SWBQ_DEPTH+1)-1:0] swbq_count;

  assign tb_st_wb_valid       = (swbq_count != 0);
  assign tb_st_wb_rob_idx     = swbq_rob_idx[swbq_head];
  assign tb_st_wb_data        = swbq_data[swbq_head];
  assign tb_st_wb_exception   = swbq_exception[swbq_head];
  assign tb_st_wb_ecause      = swbq_ecause[swbq_head];
  assign tb_st_wb_is_mispred  = swbq_is_mispred[swbq_head];
  assign tb_st_wb_redirect_pc = swbq_redirect_pc[swbq_head];
  assign tb_st_unreported_count = ($clog2(TB_STQ_DEPTH+1))'(swbq_count);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      swbq_head <= '0;
      swbq_tail <= '0;
      swbq_count <= '0;
    end else if (flush_i) begin
      swbq_head <= '0;
      swbq_tail <= '0;
      swbq_count <= '0;
    end else begin
      if (tb_st_complete_valid) begin
        swbq_rob_idx[swbq_tail] <= tb_st_complete_rob_idx;
        swbq_data[swbq_tail] <= tb_st_complete_data;
        swbq_exception[swbq_tail] <= tb_st_complete_exception;
        swbq_ecause[swbq_tail] <= tb_st_complete_ecause;
        swbq_is_mispred[swbq_tail] <= tb_st_complete_is_mispred;
        swbq_redirect_pc[swbq_tail] <= tb_st_complete_redirect_pc;
        swbq_tail <= (swbq_tail == TB_SWBQ_IDX_W'(TB_SWBQ_DEPTH - 1)) ? '0 :
                     (swbq_tail + TB_SWBQ_IDX_W'(1));
      end
      if (tb_st_wb_fire) begin
        swbq_head <= (swbq_head == TB_SWBQ_IDX_W'(TB_SWBQ_DEPTH - 1)) ? '0 :
                     (swbq_head + TB_SWBQ_IDX_W'(1));
      end
      if (tb_st_complete_valid && !tb_st_wb_fire) begin
        swbq_count <= swbq_count + 1'b1;
      end else if (!tb_st_complete_valid && tb_st_wb_fire) begin
        swbq_count <= swbq_count - 1'b1;
      end
    end
  end

  lsu_group #(
      .Cfg(global_config_pkg::Cfg),
      .ROB_IDX_WIDTH(TB_ROB_IDX_WIDTH),
      .SB_DEPTH(TB_STQ_DEPTH),
      .LDQ_DEPTH(TB_LDQ_DEPTH),
      .SQ_DEPTH(TB_SQ_DEPTH),
      .N_LSU(TB_LSU_GROUP_SIZE),
      .COMMIT_WIDTH(TB_COMMIT_WIDTH),
      .LOAD_WB_PORTS(TB_LOAD_WB_PORTS),
      .LSU_WB_PORTS(TB_LSU_WB_PORTS)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_i,

      .commit_valid_i(dut_commit_valid),
      .commit_rob_idx_i(dut_commit_rob_idx),

      .req_valid_i,
      .req_ready_o,
      .uop_i(uop),
      .rs1_data_i,
      .rs2_data_i,
      .rob_tag_i,
      .rob_head_i('0),
      .st_id_i,
      .mmu_satp_i,
      .mmu_priv_i,
      .mmu_sum_i,
      .mmu_mxr_i,
      .mmu_sfence_vma_i,

      .st_ex_valid_o,
      .st_ex_st_id_o,
      .st_ex_addr_o,
      .st_ex_data_o,
      .st_ex_op_o,
      .st_ex_rob_idx_o(),

      .stq_fwd_addr_o,
      .stq_fwd_be_o(),
      .stq_fwd_rob_idx_o(),
      .stq_fwd_hit_i,
      .stq_fwd_data_i,
      .st_order_query_valid_o(),
      .st_order_query_st_id_o(),
      .st_order_query_clear_i(1'b1),

      // store_wb_q 已并入 stq；本 tb 无 stq，用下方小型完成上报 FIFO 复刻其
      // 可观测行为，喂回 st_wb_*。
      .st_complete_valid_o(tb_st_complete_valid),
      .st_complete_id_o(),
      .st_complete_rob_idx_o(tb_st_complete_rob_idx),
      .st_complete_data_o(tb_st_complete_data),
      .st_complete_exception_o(tb_st_complete_exception),
      .st_complete_ecause_o(tb_st_complete_ecause),
      .st_complete_is_mispred_o(tb_st_complete_is_mispred),
      .st_complete_redirect_pc_o(tb_st_complete_redirect_pc),
      .st_complete_pc_o(),
      .st_wb_fire_o(tb_st_wb_fire),
      .st_wb_valid_i(tb_st_wb_valid),
      .st_wb_rob_idx_i(tb_st_wb_rob_idx),
      .st_wb_data_i(tb_st_wb_data),
      .st_wb_exception_i(tb_st_wb_exception),
      .st_wb_ecause_i(tb_st_wb_ecause),
      .st_wb_is_mispred_i(tb_st_wb_is_mispred),
      .st_wb_redirect_pc_i(tb_st_wb_redirect_pc),
      .st_unreported_count_i(tb_st_unreported_count),

      .ld_req_valid_o,
      .ld_req_ready_i,
      .ld_req_addr_o,
      .ld_req_op_o,
      .ld_req_id_o,

      .ld_rsp_valid_i,
      .ld_rsp_id_i,
      .ld_rsp_ready_o,
      .ld_rsp_data_i,
      .ld_rsp_err_i,
      .mmio_req_valid_o(),
      .mmio_req_ready_i(1'b1),
      .mmio_req_addr_o(),
      .mmio_req_op_o(),
      .mmio_rsp_valid_i(1'b0),
      .mmio_rsp_data_i('0),
      .pte_req_valid_o,
      .pte_req_ready_i,
      .pte_req_paddr_o,
      .pte_rsp_valid_i,
      .pte_rsp_data_i,
      .pte_upd_valid_o,
      .pte_upd_ready_i,
      .pte_upd_paddr_o,
      .pte_upd_data_o,

      .wb_valid_o      (dut_wb_valid),
      .wb_rob_idx_o    (dut_wb_rob_idx),
      .wb_data_o       (dut_wb_data),
      .wb_exception_o  (dut_wb_exception),
      .wb_ecause_o     (dut_wb_ecause),
      .wb_is_mispred_o (dut_wb_is_mispred),
      .wb_redirect_pc_o(dut_wb_redirect_pc),
      .wb_ready_i      ({TB_LSU_WB_PORTS{wb_ready_i}}),

      .fast_lsu_valid_o(),
      .fast_lsu_rob_idx_o(),
      .fast_lsu_data_o(),
      .fast_lsu_exception_o(),
      .fast_lsu_ecause_o(),
      .fast_lsu_is_mispred_o(),
      .fast_lsu_redirect_pc_o(),

      .dbg_ldq_count_o(),
      .dbg_ldq_head_valid_o(),
      .dbg_ldq_head_rob_tag_o(),
      .dbg_sq_count_o(),
      .dbg_sq_head_valid_o(),
      .dbg_sq_head_rob_tag_o()
  );

  ldq #(
      .ROB_IDX_WIDTH(TB_ROB_IDX_WIDTH),
      .DEPTH(TB_LDQ_DEPTH),
      .COMMIT_WIDTH(1)
  ) u_ldq_test (
      .clk_i,
      .rst_ni,
      .flush_i,
      .alloc_valid_i(lq_test_alloc_valid_i),
      .alloc_ready_o(lq_test_alloc_ready_o),
      .alloc_rob_tag_i(lq_test_alloc_rob_tag_i),
      .alloc_pc_i('0),
      .alloc_paddr_i('0),
      .alloc_be_i('0),
      .commit_valid_i(lq_test_commit_valid_i),
      .commit_rob_idx_i(lq_test_commit_rob_idx_i),
      .exec_valid_i(1'b0),
      .exec_rob_tag_i('0),
      .st_query_valid_i(1'b0),
      .st_paddr_i('0),
      .st_be_i('0),
      .st_rob_tag_i('0),
      .rob_head_i('0),
      .violation_valid_o(),
      .violation_pc_o(),
      .violation_rob_idx_o(),
      .head_valid_o(lq_test_head_valid_o),
      .head_rob_tag_o(lq_test_head_rob_tag_o),
      .count_o(lq_test_count_o),
      .full_o(),
      .empty_o(),
      .inflight_empty_o()
  );

endmodule
