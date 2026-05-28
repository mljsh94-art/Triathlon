// vsrc/test/tb_execute.sv
import config_pkg::*;
import decode_pkg::*;

module tb_execute #(
    // [新增] 引入参数，默认使用 EmptyCfg (通常 XLEN=32)
    // 如果需要测试 64 位，可在 Verilator 中覆盖 Cfg 或 XLEN
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter XLEN = 32,
    parameter TAG_W = 6
) (
    input logic clk_i,
    input logic rst_ni,

    // 简单信号输入
    input logic [ XLEN-1:0] pc_i,         // [修改] 参数化位宽
    input logic [ XLEN-1:0] pred_npc_i,
    input logic [ XLEN-1:0] imm_i,        // [修改] 参数化位宽
    input logic [      4:0] alu_op_i,     // ALU OP 宽度通常固定，暂保持 5
    input logic [      2:0] br_op_i,      // BR OP 宽度通常固定，暂保持 3
    input logic             is_branch_i,
    input logic             is_jump_i,
    input logic             is_rvc_i,
    input logic [ XLEN-1:0] rs1_data_i,   // [修改] 参数化位宽
    input logic [ XLEN-1:0] rs2_data_i,   // [修改] 参数化位宽
    input logic [TAG_W-1:0] rob_tag_in,   // [修改] 参数化位宽
    input logic             has_rs2_i,

    // 输出结果
    output logic [ XLEN-1:0] alu_result_o,  // [修改] 参数化位宽
    output logic [TAG_W-1:0] rob_tag_out,   // [修改] 参数化位宽
    output logic             is_mispred_o,
    output logic [ XLEN-1:0] redirect_pc_o  // [修改] 参数化位宽
);

  decode_pkg::uop_t uop;

  // 构造 uop 结构体
  always_comb begin
    uop           = '0;
    // 这里的赋值会自动进行位宽截断或扩展，前提是 uop_t 定义使用了 Cfg.XLEN
    uop.pc        = pc_i;
    uop.pred_npc  = pred_npc_i;
    uop.imm       = imm_i;
    uop.alu_op    = decode_pkg::alu_op_e'(alu_op_i);
    uop.br_op     = decode_pkg::branch_op_e'(br_op_i);
    uop.is_branch = is_branch_i;
    uop.is_jump   = is_jump_i;
    uop.is_rvc    = is_rvc_i;
    uop.valid     = 1'b1;
    uop.has_rs2   = has_rs2_i;
  end

  // 实例化 DUT
  execute_alu #(
      .Cfg  (Cfg),    // [修改] 传递 Cfg
      .TAG_W(TAG_W),  // [修改] 传递 TAG_W
      .XLEN (XLEN),   // [修改] 显式传递 XLEN
      .PC_W (XLEN)    // [修改] 假设 PC 宽度与 XLEN 一致 (测试环境下)
  ) dut (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .alu_valid_i(1'b1),
      .uop_i      (uop),
      .rs1_data_i (rs1_data_i),
      .rs2_data_i (rs2_data_i),
      .rob_tag_i  (rob_tag_in),

      .alu_valid_o      (),              // 不需要测试 valid 输出
      .alu_rob_tag_o    (rob_tag_out),
      .alu_result_o     (alu_result_o),
      .alu_is_mispred_o (is_mispred_o),
      .alu_redirect_pc_o(redirect_pc_o)
  );

endmodule
