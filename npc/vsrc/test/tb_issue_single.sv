import config_pkg::*;
import build_config_pkg::*;
import decode_pkg::*;

module tb_issue_single #(
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg,
    parameter RS_DEPTH = Cfg.RS_DEPTH,
    parameter DATA_W = Cfg.ILEN,
    parameter TAG_W = 6,
    parameter CDB_W = 4
) (
    input wire clk,
    input wire rst_n,
    input wire flush_i,

    input wire head_en_i,
    input wire [TAG_W-1:0] head_tag_i,

    input wire [3:0] dispatch_valid,
    input decode_pkg::uop_t dispatch_op[0:3],
    input wire [3:0] dispatch_has_rs1,
    input wire [3:0] dispatch_has_rs2,
    input wire [TAG_W-1:0] dispatch_dst[0:3],
    input wire [DATA_W-1:0] dispatch_v1[0:3],
    input wire [TAG_W-1:0] dispatch_q1[0:3],
    input wire dispatch_r1[0:3],
    input wire [DATA_W-1:0] dispatch_v2[0:3],
    input wire [TAG_W-1:0] dispatch_q2[0:3],
    input wire dispatch_r2[0:3],

    output wire issue_ready,
    output wire [$clog2(RS_DEPTH+1)-1:0] free_count_o,

    input wire [CDB_W-1:0] cdb_valid,
    input wire [TAG_W-1:0] cdb_tag[0:CDB_W-1],
    input wire [DATA_W-1:0] cdb_val[0:CDB_W-1],
    input wire [CDB_W-1:0] cdb_wakeup_mask,

    output wire fu_en,
    output decode_pkg::uop_t fu_uop,
    output wire [DATA_W-1:0] fu_v1,
    output wire [DATA_W-1:0] fu_v2,
    output wire [TAG_W-1:0] fu_dst
);

  decode_pkg::uop_t dispatch_op_fixed[0:3];
  always_comb begin
    for (int i = 0; i < 4; i++) begin
      dispatch_op_fixed[i] = dispatch_op[i];
      dispatch_op_fixed[i].has_rs1 = dispatch_has_rs1[i];
      dispatch_op_fixed[i].has_rs2 = dispatch_has_rs2[i];
    end
  end

  issue_single #(
      .Cfg(Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(DATA_W),
      .TAG_W(TAG_W),
      .CDB_W(CDB_W)
  ) u_issue_single (
      .clk(clk),
      .rst_n(rst_n),
      .flush_i(flush_i),

      .head_en_i(head_en_i),
      .head_tag_i(head_tag_i),

      .dispatch_valid(dispatch_valid),
      .dispatch_op(dispatch_op_fixed),
      .dispatch_dst(dispatch_dst),
      .dispatch_v1(dispatch_v1),
      .dispatch_q1(dispatch_q1),
      .dispatch_r1(dispatch_r1),
      .dispatch_v2(dispatch_v2),
      .dispatch_q2(dispatch_q2),
      .dispatch_r2(dispatch_r2),

      .issue_ready(issue_ready),
      .free_count_o(free_count_o),

      .cdb_valid(cdb_valid),
      .cdb_tag(cdb_tag),
      .cdb_val(cdb_val),
      .cdb_wakeup_mask(cdb_wakeup_mask),

      .fu_en(fu_en),
      .fu_uop(fu_uop),
      .fu_v1(fu_v1),
      .fu_v2(fu_v2),
      .fu_dst(fu_dst)
  );

endmodule
