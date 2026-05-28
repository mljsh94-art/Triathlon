// vsrc/test/tb_icache.sv
import config_pkg::*;
import global_config_pkg::*;

module tb_icache (
    input logic clk_i,
    input logic rst_ni,

    // --- IFU Request (Input) ---
    input logic                ifu_req_valid_i,
    input logic [Cfg.VLEN-1:0] ifu_req_pc_i,
    input logic                ifu_req_flush_i,

    // --- IFU Response (Output) ---
    output logic                                         ifu_rsp_valid_o,
    // 注意: icache.sv 中 ifu_rsp_handshake_o.ready 是由 Cache 驱动为 1 的 (表示无反压/数据有效确认)
    // 我们在这里将其输出以便观察，尽管 Testbench 主要关注 valid 和 data
    output logic                                         ifu_rsp_ready_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ifu_rsp_instrs_o,

    // --- Miss Request (Output to Next Level Memory) ---
    output logic                                  miss_req_valid_o,
    input  logic                                  miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] miss_req_index_o,

    // --- Refill (Input from Next Level Memory) ---
    input  logic                                  refill_valid_i,
    output logic                                  refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] refill_data_i
);

  localparam config_pkg::cfg_t Cfg = global_config_pkg::Cfg;

  // 1. 构造结构体信号
  global_config_pkg::handshake_t ifu_req_handshake;
  global_config_pkg::handshake_t ifu_rsp_handshake;

  // 2. 信号映射
  // IFU Request
  assign ifu_req_handshake.valid = ifu_req_valid_i;
  assign ifu_req_handshake.ready = 1'b0; // Input struct's ready ignored by DUT usually, or driven by environment

  // IFU Response
  assign ifu_rsp_valid_o = ifu_rsp_handshake.valid;
  assign ifu_rsp_ready_o = ifu_rsp_handshake.ready;  // Driven by DUT

  // 3. 实例化 DUT
  icache #(
      .Cfg(Cfg),
      .HIT_PIPELINE_EN(1'b1)
  ) DUT (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      // IFU Interface
      .ifu_req_handshake_i(ifu_req_handshake),
      .ifu_rsp_handshake_o(ifu_rsp_handshake),
      .ifu_req_pc_i       (ifu_req_pc_i),
      .ifu_rsp_instrs_o   (ifu_rsp_instrs_o),
      .ifu_req_flush_i    (ifu_req_flush_i),

      // Miss Request Interface
      .miss_req_valid_o     (miss_req_valid_o),
      .miss_req_ready_i     (miss_req_ready_i),
      .miss_req_paddr_o     (miss_req_paddr_o),
      .miss_req_victim_way_o(miss_req_victim_way_o),
      .miss_req_index_o     (miss_req_index_o),

      // Refill Interface
      .refill_valid_i(refill_valid_i),
      .refill_ready_o(refill_ready_o),
      .refill_paddr_i(refill_paddr_i),
      .refill_way_i  (refill_way_i),
      .refill_data_i (refill_data_i)
  );

endmodule : tb_icache
