// vsrc/test/tb_decoder.sv
import config_pkg::*;
import decode_pkg::*;

module tb_decoder (
    input logic clk_i,
    input logic rst_ni,
    // 1. 输入：给 Decoder 的指令和 PC
    input logic [31:0] inst_i,
    input logic [31:0] pc_i,
    input logic [decode_pkg::FTQ_ID_W-1:0] ftq_id_i,
    input logic [decode_pkg::FETCH_EPOCH_W-1:0] fetch_epoch_i,

    // 2. 输出：拆开后的“检查点”信号 (供 C++ 读取)
    output logic        check_valid,
    output logic        check_illegal,
    output logic [ 4:0] check_rs1,
    output logic [ 4:0] check_rs2,
    output logic [ 4:0] check_rd,
    output logic [31:0] check_imm,
    output int          check_alu_op,    // 使用 int 方便 C++ 里的 enum 转换
    output int          check_lsu_op,
    output int          check_amo_op,
    output int          check_br_op,
    output int          check_fu_type,
    output logic        check_is_load,
    output logic        check_is_store,
    output logic        check_is_jump,
    output logic        check_is_fence,
    output logic        check_is_sfence_vma,
    output logic [31:0] check_pred_npc,
    output logic [decode_pkg::FTQ_ID_W-1:0] check_ftq_id,
    output logic [decode_pkg::FETCH_EPOCH_W-1:0] check_fetch_epoch
);
  localparam int DECODE_WIDTH = global_config_pkg::Cfg.INSTR_PER_FETCH;
  localparam int ILEN = global_config_pkg::Cfg.ILEN;
  // 内部信号
  uop_t [DECODE_WIDTH-1:0] dec_uops;  // 假设 decode width = 4
  logic [DECODE_WIDTH-1:0][ILEN-1:0] ibuf_instrs;
  logic [DECODE_WIDTH-1:0][ILEN-1:0] ibuf_raw_instrs;
  logic [DECODE_WIDTH-1:0][ILEN-1:0] ibuf_pcs;
  logic [DECODE_WIDTH-1:0] ibuf_slot_valid;
  logic [DECODE_WIDTH-1:0][31:0] ibuf_pred_npc;
  logic [DECODE_WIDTH-1:0] ibuf_is_rvc;
  logic [DECODE_WIDTH-1:0][decode_pkg::FTQ_ID_W-1:0] ibuf_ftq_id;
  logic [DECODE_WIDTH-1:0][decode_pkg::FETCH_EPOCH_W-1:0] ibuf_fetch_epoch;

  // 构造输入：只给第0路喂有效数据，其他给NOP
  assign ibuf_instrs[0] = inst_i;
  assign ibuf_raw_instrs[0] = inst_i;
  assign ibuf_pcs[0]    = pc_i;
  assign ibuf_slot_valid[0] = 1'b1;
  assign ibuf_pred_npc[0] = pc_i + 32'd4;
  assign ibuf_is_rvc[0] = 1'b0;
  assign ibuf_ftq_id[0] = ftq_id_i;
  assign ibuf_fetch_epoch[0] = fetch_epoch_i;

  for (genvar i = 1; i < DECODE_WIDTH; i++) begin : gen_nop_instrs
    assign ibuf_instrs[i] = 32'h00000013;  // NOP
    assign ibuf_raw_instrs[i] = 32'h00000013;  // NOP
    assign ibuf_pcs[i]    = pc_i + i * 4;
    assign ibuf_slot_valid[i] = 1'b0;
    assign ibuf_pred_npc[i] = '0;
    assign ibuf_is_rvc[i] = 1'b0;
    assign ibuf_ftq_id[i] = '0;
    assign ibuf_fetch_epoch[i] = '0;
  end

  // 实例化 DUT
  decoder #(
      .Cfg(global_config_pkg::Cfg)
  ) dut (
      .clk_i(1'b0),  // 组合逻辑不需要时钟，但为了兼容性留着
      .rst_ni(1'b1),
      .ibuf2dec_valid_i(1'b1),  // 始终有效
      .dec2ibuf_ready_o(),
      .ibuf_instrs_i(ibuf_instrs),
      .ibuf_raw_instrs_i(ibuf_raw_instrs),
      .ibuf_pcs_i(ibuf_pcs),
      .ibuf_slot_valid_i(ibuf_slot_valid),
      .ibuf_pred_npc_i(ibuf_pred_npc),
      .ibuf_is_rvc_i(ibuf_is_rvc),
      .ibuf_ftq_id_i(ibuf_ftq_id),
      .ibuf_fetch_epoch_i(ibuf_fetch_epoch),
      .dec2backend_valid_o(),
      .backend2dec_ready_i(1'b1),
      .dec_slot_valid_o(),
      .dec_uops_o(dec_uops)
  );

  // --- 核心步骤：拆包 (只拆第 0 路) ---
  assign check_valid    = dec_uops[0].valid;
  assign check_illegal  = dec_uops[0].illegal;
  assign check_rs1      = dec_uops[0].rs1;
  assign check_rs2      = dec_uops[0].rs2;
  assign check_rd       = dec_uops[0].rd;
  assign check_imm      = dec_uops[0].imm;  // 32位立即数
  assign check_alu_op   = dec_uops[0].alu_op;
  assign check_lsu_op   = dec_uops[0].lsu_op;
  assign check_amo_op   = dec_uops[0].amo_op;
  assign check_br_op    = dec_uops[0].br_op;
  assign check_fu_type  = dec_uops[0].fu;
  assign check_is_load  = dec_uops[0].is_load;
  assign check_is_store = dec_uops[0].is_store;
  assign check_is_jump  = dec_uops[0].is_jump;
  assign check_is_fence = dec_uops[0].is_fence;
  assign check_is_sfence_vma = dec_uops[0].is_sfence_vma;
  assign check_pred_npc = dec_uops[0].pred_npc;
  assign check_ftq_id = dec_uops[0].ftq_id;
  assign check_fetch_epoch = dec_uops[0].fetch_epoch;

endmodule
