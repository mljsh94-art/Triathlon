import decode_pkg::*;

module tb_backend_mmu_dcache_mux (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input logic lsu_ld_req_valid_i,
    output logic lsu_ld_req_ready_o,
    input logic [31:0] lsu_ld_req_addr_i,
    input decode_pkg::lsu_op_e lsu_ld_req_op_i,
    input logic [1:0] lsu_ld_req_id_i,

    output logic lsu_ld_rsp_valid_o,
    input logic lsu_ld_rsp_ready_i,
    output logic [31:0] lsu_ld_rsp_data_o,
    output logic lsu_ld_rsp_err_o,
    output logic [1:0] lsu_ld_rsp_id_o,

    input logic pte_ld_req_valid_i,
    output logic pte_ld_req_ready_o,
    input logic [31:0] pte_ld_req_paddr_i,
    output logic pte_ld_rsp_valid_o,
    output logic [31:0] pte_ld_rsp_data_o,

    input logic ifu_pte_ld_req_valid_i,
    output logic ifu_pte_ld_req_ready_o,
    input logic [31:0] ifu_pte_ld_req_paddr_i,
    output logic ifu_pte_ld_rsp_valid_o,
    output logic [31:0] ifu_pte_ld_rsp_data_o,

    input logic sb_st_req_valid_i,
    output logic sb_st_req_ready_o,
    input logic [31:0] sb_st_req_addr_i,
    input logic [31:0] sb_st_req_data_i,
    input decode_pkg::lsu_op_e sb_st_req_op_i,

    input logic pte_st_req_valid_i,
    output logic pte_st_req_ready_o,
    input logic [31:0] pte_st_req_paddr_i,
    input logic [31:0] pte_st_req_data_i,

    input logic ifu_pte_st_req_valid_i,
    output logic ifu_pte_st_req_ready_o,
    input logic [31:0] ifu_pte_st_req_paddr_i,
    input logic [31:0] ifu_pte_st_req_data_i,

    output logic dcache_ld_req_valid_o,
    input logic dcache_ld_req_ready_i,
    output logic [31:0] dcache_ld_req_addr_o,
    output decode_pkg::lsu_op_e dcache_ld_req_op_o,
    output logic [2:0] dcache_ld_req_id_o,

    input logic dcache_ld_rsp_valid_i,
    output logic dcache_ld_rsp_ready_o,
    input logic [31:0] dcache_ld_rsp_data_i,
    input logic dcache_ld_rsp_err_i,
    input logic [2:0] dcache_ld_rsp_id_i,

    output logic dcache_st_req_valid_o,
    input logic dcache_st_req_ready_i,
    output logic [31:0] dcache_st_req_addr_o,
    output logic [31:0] dcache_st_req_data_o,
    output decode_pkg::lsu_op_e dcache_st_req_op_o
);

  backend_mmu_dcache_mux #(
      .PLEN(32),
      .XLEN(32),
      .LSU_LD_ID_WIDTH(2)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_i,

      .lsu_ld_req_valid_i,
      .lsu_ld_req_ready_o,
      .lsu_ld_req_addr_i,
      .lsu_ld_req_op_i,
      .lsu_ld_req_id_i,

      .lsu_ld_rsp_valid_o,
      .lsu_ld_rsp_ready_i,
      .lsu_ld_rsp_data_o,
      .lsu_ld_rsp_err_o,
      .lsu_ld_rsp_id_o,

      .pte_ld_req_valid_i,
      .pte_ld_req_ready_o,
      .pte_ld_req_paddr_i,
      .pte_ld_rsp_valid_o,
      .pte_ld_rsp_data_o,
      .ifu_pte_ld_req_valid_i,
      .ifu_pte_ld_req_ready_o,
      .ifu_pte_ld_req_paddr_i,
      .ifu_pte_ld_rsp_valid_o,
      .ifu_pte_ld_rsp_data_o,

      .sb_st_req_valid_i,
      .sb_st_req_ready_o,
      .sb_st_req_addr_i,
      .sb_st_req_data_i,
      .sb_st_req_op_i,

      .pte_st_req_valid_i,
      .pte_st_req_ready_o,
      .pte_st_req_paddr_i,
      .pte_st_req_data_i,
      .ifu_pte_st_req_valid_i,
      .ifu_pte_st_req_ready_o,
      .ifu_pte_st_req_paddr_i,
      .ifu_pte_st_req_data_i,

      .dcache_ld_req_valid_o,
      .dcache_ld_req_ready_i,
      .dcache_ld_req_addr_o,
      .dcache_ld_req_op_o,
      .dcache_ld_req_id_o,

      .dcache_ld_rsp_valid_i,
      .dcache_ld_rsp_ready_o,
      .dcache_ld_rsp_data_i,
      .dcache_ld_rsp_err_i,
      .dcache_ld_rsp_id_i,

      .dcache_st_req_valid_o,
      .dcache_st_req_ready_i,
      .dcache_st_req_addr_o,
      .dcache_st_req_data_o,
      .dcache_st_req_op_o
  );
endmodule
