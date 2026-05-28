import config_pkg::*;
import build_config_pkg::*;
import decode_pkg::*;  // [新增] 必须导入解码包以使用 uop_t

module tb_issue #(
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg,
    parameter RS_DEPTH = Cfg.RS_DEPTH,
    parameter DATA_W   = Cfg.ILEN,
    parameter TAG_W    = 6
) (
    input wire clk,
    input wire rst_n,
    input wire flush_i,

    // Dispatch 通道
    input wire              [       3:0] dispatch_valid,
    input decode_pkg::uop_t              dispatch_op   [0:3],  // [修复] 类型改为 uop_t
    input wire              [       3:0] dispatch_has_rs1,
    input wire              [       3:0] dispatch_has_rs2,
    input wire              [ TAG_W-1:0] dispatch_dst  [0:3],
    // Src1
    input wire              [DATA_W-1:0] dispatch_v1   [0:3],
    input wire              [ TAG_W-1:0] dispatch_q1   [0:3],
    input wire                           dispatch_r1   [0:3],
    // Src2
    input wire              [DATA_W-1:0] dispatch_v2   [0:3],
    input wire              [ TAG_W-1:0] dispatch_q2   [0:3],
    input wire                           dispatch_r2   [0:3],

    output wire issue_ready,
    output wire [$clog2(RS_DEPTH+1)-1:0] free_count_o,

    // CDB 通道
    input wire [       3:0] cdb_valid,
    input wire [ TAG_W-1:0] cdb_tag  [0:3],
    input wire [DATA_W-1:0] cdb_val  [0:3],

    // ALU 0 输出
    output wire alu0_en,
    output decode_pkg::uop_t alu0_uop,  // [修复] 类型改为 uop_t，名称改为 alu0_uop
    output wire [DATA_W-1:0] alu0_v1,
    output wire [DATA_W-1:0] alu0_v2,
    output wire [TAG_W-1:0] alu0_dst,

    // ALU 1 输出
    output wire alu1_en,
    output decode_pkg::uop_t alu1_uop,  // [修复] 类型改为 uop_t，名称改为 alu1_uop
    output wire [DATA_W-1:0] alu1_v1,
    output wire [DATA_W-1:0] alu1_v2,
    output wire [TAG_W-1:0] alu1_dst,

    // ALU 2 输出
    output wire alu2_en,
    output decode_pkg::uop_t alu2_uop,
    output wire [DATA_W-1:0] alu2_v1,
    output wire [DATA_W-1:0] alu2_v2,
    output wire [TAG_W-1:0] alu2_dst,

    // ALU 3 输出
    output wire alu3_en,
    output decode_pkg::uop_t alu3_uop,
    output wire [DATA_W-1:0] alu3_v1,
    output wire [DATA_W-1:0] alu3_v2,
    output wire [TAG_W-1:0] alu3_dst
);

  decode_pkg::uop_t dispatch_op_fixed[0:3];
  always_comb begin
    for (int i = 0; i < 4; i++) begin
      dispatch_op_fixed[i] = dispatch_op[i];
      dispatch_op_fixed[i].has_rs1 = dispatch_has_rs1[i];
      dispatch_op_fixed[i].has_rs2 = dispatch_has_rs2[i];
    end
  end

  // 实例化被测模块 (DUT)
  issue #(
      .Cfg(Cfg)
  ) u_issue (
      .clk  (clk),
      .rst_n(rst_n),
      .flush_i(flush_i),
      .rob_head_i('0),

      .dispatch_valid(dispatch_valid),
      .dispatch_op   (dispatch_op_fixed),     // 类型匹配：uop_t
      .dispatch_dst  (dispatch_dst),
      .dispatch_v1   (dispatch_v1),
      .dispatch_q1   (dispatch_q1),
      .dispatch_r1   (dispatch_r1),
      .dispatch_v2   (dispatch_v2),
      .dispatch_q2   (dispatch_q2),
      .dispatch_r2   (dispatch_r2),

      .issue_ready(issue_ready),
      .free_count_o(free_count_o),

      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_val  (cdb_val),

      .alu0_en (alu0_en),
      .alu0_uop(alu0_uop),  // [修复] 连接到 tb 的 alu0_uop
      .alu0_v1 (alu0_v1),
      .alu0_v2 (alu0_v2),
      .alu0_dst(alu0_dst),

      .alu1_en (alu1_en),
      .alu1_uop(alu1_uop),  // [修复] 连接到 tb 的 alu1_uop
      .alu1_v1 (alu1_v1),
      .alu1_v2 (alu1_v2),
      .alu1_dst(alu1_dst),

      .alu2_en (alu2_en),
      .alu2_uop(alu2_uop),
      .alu2_v1 (alu2_v1),
      .alu2_v2 (alu2_v2),
      .alu2_dst(alu2_dst),

      .alu3_en (alu3_en),
      .alu3_uop(alu3_uop),
      .alu3_v1 (alu3_v1),
      .alu3_v2 (alu3_v2),
      .alu3_dst(alu3_dst)
  );

endmodule
