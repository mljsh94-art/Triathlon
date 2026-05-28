// vsrc/test/tb_dcache.sv
import config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;

module tb_dcache #(
    parameter int unsigned TB_N_MSHR = (global_config_pkg::Cfg.DCACHE_MSHR_SIZE >= 1) ?
        global_config_pkg::Cfg.DCACHE_MSHR_SIZE : 1,
    parameter int unsigned TB_LD_ID_WIDTH = 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // Load Port
    input  logic                                                  ld_req_valid_i,
    output logic                                                  ld_req_ready_o,
    input  logic                [global_config_pkg::Cfg.PLEN-1:0] ld_req_addr_i,
    input  decode_pkg::lsu_op_e                                   ld_req_op_i,
    input  logic                             [TB_LD_ID_WIDTH-1:0] ld_req_id_i,

    output logic                                   ld_rsp_valid_o,
    input  logic                                   ld_rsp_ready_i,
    output logic [global_config_pkg::Cfg.XLEN-1:0] ld_rsp_data_o,
    output logic                                   ld_rsp_err_o,
    output logic                            [TB_LD_ID_WIDTH-1:0] ld_rsp_id_o,

    // Store Port
    input  logic                                                  st_req_valid_i,
    output logic                                                  st_req_ready_o,
    input  logic                [global_config_pkg::Cfg.PLEN-1:0] st_req_addr_i,
    input  logic                [global_config_pkg::Cfg.XLEN-1:0] st_req_data_i,
    input  decode_pkg::lsu_op_e                                   st_req_op_i,

    // Miss/Refill
    output logic                                                     miss_req_valid_o,
    input  logic                                                     miss_req_ready_i,
    output logic [                  global_config_pkg::Cfg.PLEN-1:0] miss_req_paddr_o,
    output logic [global_config_pkg::Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way_o,
    output logic [    global_config_pkg::Cfg.DCACHE_INDEX_WIDTH-1:0] miss_req_index_o,

    input  logic                                                     refill_valid_i,
    output logic                                                     refill_ready_o,
    input  logic [                  global_config_pkg::Cfg.PLEN-1:0] refill_paddr_i,
    input  logic [global_config_pkg::Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] refill_way_i,
    input  logic [     global_config_pkg::Cfg.DCACHE_LINE_WIDTH-1:0] refill_data_i,

    // Writeback
    output logic                                                wb_req_valid_o,
    input  logic                                                wb_req_ready_i,
    output logic [             global_config_pkg::Cfg.PLEN-1:0] wb_req_paddr_o,
    output logic [global_config_pkg::Cfg.DCACHE_LINE_WIDTH-1:0] wb_req_data_o
);

  dcache #(
      .Cfg(global_config_pkg::Cfg),
      .N_MSHR(TB_N_MSHR),
      .LD_PORT_ID_WIDTH(TB_LD_ID_WIDTH)
  ) dut (.*);

endmodule
