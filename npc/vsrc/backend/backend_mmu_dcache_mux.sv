import decode_pkg::*;

module backend_mmu_dcache_mux #(
    parameter int unsigned PLEN            = 32,
    parameter int unsigned XLEN            = 32,
    parameter int unsigned LSU_LD_ID_WIDTH = 1
) (
    input  logic                               clk_i,
    input  logic                               rst_ni,
    input  logic                               flush_i,

    input  logic                               lsu_ld_req_valid_i,
    output logic                               lsu_ld_req_ready_o,
    input  logic [PLEN-1:0]                    lsu_ld_req_addr_i,
    input  decode_pkg::lsu_op_e                lsu_ld_req_op_i,
    input  logic [LSU_LD_ID_WIDTH-1:0]         lsu_ld_req_id_i,

    output logic                               lsu_ld_rsp_valid_o,
    input  logic                               lsu_ld_rsp_ready_i,
    output logic [XLEN-1:0]                    lsu_ld_rsp_data_o,
    output logic                               lsu_ld_rsp_err_o,
    output logic [LSU_LD_ID_WIDTH-1:0]         lsu_ld_rsp_id_o,

    // Second LSU load lane ("port B"): dedicated hit-only DCache bypass, never
    // carries MMU walk traffic (page-table walks stay on port A above).
    input  logic                               lsu_ld_req_b_valid_i,
    output logic                               lsu_ld_req_b_ready_o,
    input  logic [PLEN-1:0]                    lsu_ld_req_b_addr_i,
    input  decode_pkg::lsu_op_e                lsu_ld_req_b_op_i,
    input  logic [LSU_LD_ID_WIDTH-1:0]         lsu_ld_req_b_id_i,

    output logic                               lsu_ld_rsp_b_valid_o,
    input  logic                               lsu_ld_rsp_b_ready_i,
    output logic [XLEN-1:0]                    lsu_ld_rsp_b_data_o,
    output logic                               lsu_ld_rsp_b_err_o,
    output logic [LSU_LD_ID_WIDTH-1:0]         lsu_ld_rsp_b_id_o,

    // Port B miss reject: DCache accepted no MSHR/refill on this lane, so the
    // requester must retry the same load on port A. Unconditional pulse, no
    // ready handshake (mirrors dcache.sv's ld_rsp_b_miss_o).
    output logic                               lsu_ld_rsp_b_miss_o,
    output logic [LSU_LD_ID_WIDTH-1:0]         lsu_ld_rsp_b_miss_id_o,

    input  logic                               pte_ld_req_valid_i,
    output logic                               pte_ld_req_ready_o,
    input  logic [31:0]                        pte_ld_req_paddr_i,
    output logic                               pte_ld_rsp_valid_o,
    output logic [31:0]                        pte_ld_rsp_data_o,

    input  logic                               ifu_pte_ld_req_valid_i,
    output logic                               ifu_pte_ld_req_ready_o,
    input  logic [31:0]                        ifu_pte_ld_req_paddr_i,
    output logic                               ifu_pte_ld_rsp_valid_o,
    output logic [31:0]                        ifu_pte_ld_rsp_data_o,

    input  logic                               st_dcache_req_valid_i,
    output logic                               st_dcache_req_ready_o,
    input  logic [PLEN-1:0]                    st_dcache_req_addr_i,
    input  logic [XLEN-1:0]                    st_dcache_req_data_i,
    input  decode_pkg::lsu_op_e                st_dcache_req_op_i,

    input  logic                               pte_st_req_valid_i,
    output logic                               pte_st_req_ready_o,
    input  logic [31:0]                        pte_st_req_paddr_i,
    input  logic [31:0]                        pte_st_req_data_i,

    input  logic                               ifu_pte_st_req_valid_i,
    output logic                               ifu_pte_st_req_ready_o,
    input  logic [31:0]                        ifu_pte_st_req_paddr_i,
    input  logic [31:0]                        ifu_pte_st_req_data_i,

    output logic                               dcache_ld_req_valid_o,
    input  logic                               dcache_ld_req_ready_i,
    output logic [PLEN-1:0]                    dcache_ld_req_addr_o,
    output decode_pkg::lsu_op_e                dcache_ld_req_op_o,
    output logic [LSU_LD_ID_WIDTH:0]           dcache_ld_req_id_o,

    input  logic                               dcache_ld_rsp_valid_i,
    output logic                               dcache_ld_rsp_ready_o,
    input  logic [XLEN-1:0]                    dcache_ld_rsp_data_i,
    input  logic                               dcache_ld_rsp_err_i,
    input  logic [LSU_LD_ID_WIDTH:0]           dcache_ld_rsp_id_i,

    // DCache port B (hit-only bypass, wired to lsu_ld_req_b_*/lsu_ld_rsp_b_*
    // above). id keeps the same width as port A's MMU-tagged id for LD_PORT_ID_WIDTH
    // parity in dcache.sv, but the MMU bit is always driven low (port B never
    // carries walk traffic).
    output logic                               dcache_ld_req_b_valid_o,
    input  logic                               dcache_ld_req_b_ready_i,
    output logic [PLEN-1:0]                    dcache_ld_req_b_addr_o,
    output decode_pkg::lsu_op_e                dcache_ld_req_b_op_o,
    output logic [LSU_LD_ID_WIDTH:0]           dcache_ld_req_b_id_o,

    input  logic                               dcache_ld_rsp_b_valid_i,
    output logic                               dcache_ld_rsp_b_ready_o,
    input  logic [XLEN-1:0]                    dcache_ld_rsp_b_data_i,
    input  logic                               dcache_ld_rsp_b_err_i,
    input  logic [LSU_LD_ID_WIDTH:0]           dcache_ld_rsp_b_id_i,

    input  logic                               dcache_ld_rsp_b_miss_i,
    input  logic [LSU_LD_ID_WIDTH:0]           dcache_ld_rsp_b_miss_id_i,

    output logic                               dcache_st_req_valid_o,
    input  logic                               dcache_st_req_ready_i,
    output logic [PLEN-1:0]                    dcache_st_req_addr_o,
    output logic [XLEN-1:0]                    dcache_st_req_data_o,
    output decode_pkg::lsu_op_e                dcache_st_req_op_o
);

  localparam logic MMU_OWNER_LSU = 1'b0;
  localparam logic MMU_OWNER_IFU = 1'b1;

  logic ld_sel_lsu_pte;
  logic ld_sel_ifu_pte;
  logic ld_sel_lsu;
  logic ld_rsp_is_mmu;
  logic ld_rsp_is_lsu;

  logic st_sel_lsu_pte;
  logic st_sel_ifu_pte;
  logic st_sel_stq;

  logic mmu_ld_inflight_q;
  logic mmu_ld_owner_q;
  logic mmu_ld_issue_fire;
  logic mmu_ld_rsp_fire;

  // Prioritize MMU page walk traffic so translation latency does not starve
  // behind normal LSU/SB traffic. LSU-side MMU has higher priority than IFU-side.
  assign ld_sel_lsu_pte = !mmu_ld_inflight_q && pte_ld_req_valid_i;
  assign ld_sel_ifu_pte = !mmu_ld_inflight_q && !ld_sel_lsu_pte && ifu_pte_ld_req_valid_i;
  assign ld_sel_lsu = !ld_sel_lsu_pte && !ld_sel_ifu_pte && lsu_ld_req_valid_i;

  assign dcache_ld_req_valid_o = ld_sel_lsu_pte || ld_sel_ifu_pte || ld_sel_lsu;
  assign dcache_ld_req_addr_o = ld_sel_lsu_pte ? pte_ld_req_paddr_i[PLEN-1:0] :
                                ld_sel_ifu_pte ? ifu_pte_ld_req_paddr_i[PLEN-1:0] :
                                lsu_ld_req_addr_i;
  assign dcache_ld_req_op_o = (ld_sel_lsu_pte || ld_sel_ifu_pte) ? decode_pkg::LSU_LWU : lsu_ld_req_op_i;
  assign dcache_ld_req_id_o = (ld_sel_lsu_pte || ld_sel_ifu_pte) ? {1'b1, {LSU_LD_ID_WIDTH{1'b0}}} :
                                                              {1'b0, lsu_ld_req_id_i};

  assign pte_ld_req_ready_o = ld_sel_lsu_pte && dcache_ld_req_ready_i;
  assign ifu_pte_ld_req_ready_o = ld_sel_ifu_pte && dcache_ld_req_ready_i;
  assign lsu_ld_req_ready_o = ld_sel_lsu && dcache_ld_req_ready_i;

  assign ld_rsp_is_mmu = dcache_ld_rsp_valid_i && dcache_ld_rsp_id_i[LSU_LD_ID_WIDTH];
  assign ld_rsp_is_lsu = dcache_ld_rsp_valid_i && !dcache_ld_rsp_id_i[LSU_LD_ID_WIDTH];

  assign pte_ld_rsp_valid_o = ld_rsp_is_mmu && (mmu_ld_owner_q == MMU_OWNER_LSU);
  assign pte_ld_rsp_data_o = dcache_ld_rsp_data_i[31:0];
  assign ifu_pte_ld_rsp_valid_o = ld_rsp_is_mmu && (mmu_ld_owner_q == MMU_OWNER_IFU);
  assign ifu_pte_ld_rsp_data_o = dcache_ld_rsp_data_i[31:0];

  assign lsu_ld_rsp_valid_o = ld_rsp_is_lsu;
  assign lsu_ld_rsp_data_o = dcache_ld_rsp_data_i;
  assign lsu_ld_rsp_err_o = dcache_ld_rsp_err_i;
  assign lsu_ld_rsp_id_o = dcache_ld_rsp_id_i[LSU_LD_ID_WIDTH-1:0];

  // MMU response path is single-outstanding and is accepted unconditionally.
  assign dcache_ld_rsp_ready_o = ld_rsp_is_lsu ? lsu_ld_rsp_ready_i : 1'b1;

  assign mmu_ld_issue_fire = dcache_ld_req_valid_o && dcache_ld_req_ready_i && (ld_sel_lsu_pte || ld_sel_ifu_pte);
  assign mmu_ld_rsp_fire = ld_rsp_is_mmu && dcache_ld_rsp_ready_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mmu_ld_inflight_q <= 1'b0;
      mmu_ld_owner_q <= MMU_OWNER_LSU;
    end else if (flush_i) begin
      mmu_ld_inflight_q <= 1'b0;
      mmu_ld_owner_q <= MMU_OWNER_LSU;
    end else begin
      if (mmu_ld_rsp_fire) begin
        mmu_ld_inflight_q <= 1'b0;
      end
      if (mmu_ld_issue_fire) begin
        mmu_ld_inflight_q <= 1'b1;
        mmu_ld_owner_q <= ld_sel_ifu_pte ? MMU_OWNER_IFU : MMU_OWNER_LSU;
      end
    end
  end

  // Port B: pure passthrough between the second LSU load lane and the DCache
  // hit-only bypass port. No MMU/store sharing, so no arbitration is needed
  // here; only the id width is padded to match dcache's shared LD_PORT_ID_WIDTH.
  assign dcache_ld_req_b_valid_o = lsu_ld_req_b_valid_i;
  assign dcache_ld_req_b_addr_o  = lsu_ld_req_b_addr_i;
  assign dcache_ld_req_b_op_o    = lsu_ld_req_b_op_i;
  assign dcache_ld_req_b_id_o    = {1'b0, lsu_ld_req_b_id_i};
  assign lsu_ld_req_b_ready_o    = dcache_ld_req_b_ready_i;

  assign lsu_ld_rsp_b_valid_o    = dcache_ld_rsp_b_valid_i;
  assign lsu_ld_rsp_b_data_o     = dcache_ld_rsp_b_data_i;
  assign lsu_ld_rsp_b_err_o      = dcache_ld_rsp_b_err_i;
  assign lsu_ld_rsp_b_id_o       = dcache_ld_rsp_b_id_i[LSU_LD_ID_WIDTH-1:0];
  assign dcache_ld_rsp_b_ready_o = lsu_ld_rsp_b_ready_i;

  assign lsu_ld_rsp_b_miss_o     = dcache_ld_rsp_b_miss_i;
  assign lsu_ld_rsp_b_miss_id_o  = dcache_ld_rsp_b_miss_id_i[LSU_LD_ID_WIDTH-1:0];

  assign st_sel_lsu_pte = pte_st_req_valid_i;
  assign st_sel_ifu_pte = !st_sel_lsu_pte && ifu_pte_st_req_valid_i;
  assign st_sel_stq = !st_sel_lsu_pte && !st_sel_ifu_pte && st_dcache_req_valid_i;

  assign dcache_st_req_valid_o = st_sel_lsu_pte || st_sel_ifu_pte || st_sel_stq;
  assign dcache_st_req_addr_o = st_sel_lsu_pte ? pte_st_req_paddr_i[PLEN-1:0] :
                                st_sel_ifu_pte ? ifu_pte_st_req_paddr_i[PLEN-1:0] :
                                st_dcache_req_addr_i;
  assign dcache_st_req_data_o = st_sel_lsu_pte ? {{(XLEN-32){1'b0}}, pte_st_req_data_i} :
                                st_sel_ifu_pte ? {{(XLEN-32){1'b0}}, ifu_pte_st_req_data_i} :
                                st_dcache_req_data_i;
  assign dcache_st_req_op_o = (st_sel_lsu_pte || st_sel_ifu_pte) ? decode_pkg::LSU_SW : st_dcache_req_op_i;

  assign pte_st_req_ready_o = st_sel_lsu_pte && dcache_st_req_ready_i;
  assign ifu_pte_st_req_ready_o = st_sel_ifu_pte && dcache_st_req_ready_i;
  assign st_dcache_req_ready_o = st_sel_stq && dcache_st_req_ready_i;

endmodule
