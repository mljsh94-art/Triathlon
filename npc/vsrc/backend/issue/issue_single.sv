// vsrc/backend/issue/issue_single.sv
import decode_pkg::*;

module issue_single #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter RS_DEPTH = Cfg.RS_DEPTH,
    parameter DATA_W   = Cfg.XLEN,
    parameter TAG_W    = 6,
    parameter CDB_W    = 4,
    parameter bit COMB_WAKEUP_EN = 1'b1
) (
    input wire clk,
    input wire rst_n,
    input wire flush_i,

    input wire head_en_i,
    input wire [ TAG_W-1:0] head_tag_i,

    input wire                   [       3:0] dispatch_valid,
    input wire decode_pkg::uop_t              dispatch_op   [0:3],
    input wire                   [ TAG_W-1:0] dispatch_dst  [0:3],
    // Src1
    input wire                   [DATA_W-1:0] dispatch_v1   [0:3],
    input wire                   [ TAG_W-1:0] dispatch_q1   [0:3],
    input wire                                dispatch_r1   [0:3],
    // Src2
    input wire                   [DATA_W-1:0] dispatch_v2   [0:3],
    input wire                   [ TAG_W-1:0] dispatch_q2   [0:3],
    input wire                                dispatch_r2   [0:3],

    output wire issue_ready,  // RS 满了，停！
    output logic [$clog2(RS_DEPTH+1)-1:0] free_count_o,

    // 来自 CDB 的广播 (给 RS 监听用)
    input wire [ CDB_W-1:0] cdb_valid,
    input wire [ TAG_W-1:0] cdb_tag  [0:CDB_W-1],
    input wire [DATA_W-1:0] cdb_val  [0:CDB_W-1],
    input wire [ CDB_W-1:0] cdb_wakeup_mask,

    // FU 接口 (单发射)
    output wire                           fu_en,
    output decode_pkg::uop_t              fu_uop,
    output wire              [DATA_W-1:0] fu_v1,
    output wire              [DATA_W-1:0] fu_v2,
    output wire              [ TAG_W-1:0] fu_dst
);
  wire full_stall;
  assign issue_ready = ~full_stall;

  // A. Allocator <-> RS 之间的控制线
  wire [RS_DEPTH-1:0] rs_busy_wires;  // RS -> Alloc
  wire [RS_DEPTH-1:0] alloc_wen;  // Alloc -> RS (写使能)
  wire [$clog2(RS_DEPTH)-1:0] routing_idx[0:3];  // Alloc -> Crossbar

  // B. RS <-> Select Logic 之间的握手线
  wire [RS_DEPTH-1:0] rs_ready_wires;  // RS -> Select
  wire [RS_DEPTH-1:0] grant_mask_wires;  // Select -> RS

  // C. Select Logic -> FU 选择信号
  wire [$clog2(RS_DEPTH)-1:0] fu_sel;
  localparam int ISSUE_WIDTH = 1;
  wire [ISSUE_WIDTH-1:0] issue_valid;
  wire [$clog2(RS_DEPTH)-1:0] issue_rs_idx[0:ISSUE_WIDTH-1];

  assign fu_en  = issue_valid[0];
  assign fu_sel = issue_rs_idx[0];

  // D. Crossbar <-> RS 输入数据线
  decode_pkg::uop_t rs_in_op[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_dst[0:RS_DEPTH-1];
  logic [DATA_W-1:0] rs_in_v1[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_q1[0:RS_DEPTH-1];
  logic rs_in_r1[0:RS_DEPTH-1];
  logic [DATA_W-1:0] rs_in_v2[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_q2[0:RS_DEPTH-1];
  logic rs_in_r2[0:RS_DEPTH-1];

  // ==========================================
  // 模块 1: 分配器 (Allocator)
  // ==========================================
  rs_allocator #(
      .Cfg(Cfg)
  ) u_alloc (
      .rs_busy    (rs_busy_wires),
      .instr_valid(dispatch_valid),
      .entry_wen  (alloc_wen),
      .idx_map    (routing_idx),
      .full_stall (full_stall)
  );

  always_comb begin
    for (int k = 0; k < RS_DEPTH; k++) begin
      rs_in_op[k]  = 0;
      rs_in_dst[k] = 0;
      rs_in_v1[k]  = 0;
      rs_in_q1[k]  = 0;
      rs_in_r1[k]  = 0;
      rs_in_v2[k]  = 0;
      rs_in_q2[k]  = 0;
      rs_in_r2[k]  = 0;
    end

    for (int i = 0; i < 4; i++) begin
      if (dispatch_valid[i]) begin
        rs_in_op[routing_idx[i]]  = dispatch_op[i];
        rs_in_dst[routing_idx[i]] = dispatch_dst[i];
        rs_in_v1[routing_idx[i]]  = dispatch_v1[i];
        rs_in_q1[routing_idx[i]]  = dispatch_q1[i];
        rs_in_r1[routing_idx[i]]  = dispatch_r1[i];
        rs_in_v2[routing_idx[i]]  = dispatch_v2[i];
        rs_in_q2[routing_idx[i]]  = dispatch_q2[i];
        rs_in_r2[routing_idx[i]]  = dispatch_r2[i];
      end
    end
  end

  reservation_station #(
      .Cfg(Cfg),
      .DATA_W(DATA_W),
      .TAG_W (TAG_W),
      .CDB_W (CDB_W)
  ) u_rs (
      .clk  (clk),
      .rst_n(rst_n),
      .flush_i(flush_i),
      .head_en_i(head_en_i),
      .head_tag_i(head_tag_i),

      // 写端口
      .entry_wen (alloc_wen),
      .in_op     (rs_in_op),
      .in_dst_tag(rs_in_dst),
      .in_v1     (rs_in_v1),
      .in_q1     (rs_in_q1),
      .in_r1     (rs_in_r1),
      .in_v2     (rs_in_v2),
      .in_q2     (rs_in_q2),
      .in_r2     (rs_in_r2),

      // CDB 监听端口
      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_value(cdb_val),
      .comb_wakeup_en(COMB_WAKEUP_EN),
      .cdb_wakeup_mask(cdb_wakeup_mask),

      .busy_vector(rs_busy_wires),

      // 状态输出
      .ready_mask (rs_ready_wires),
      .issue_grant(grant_mask_wires),

      .sel_idx_0    (fu_sel),
      .out_op_0     (fu_uop),
      .out_v1_0     (fu_v1),
      .out_v2_0     (fu_v2),
      .out_dst_tag_0(fu_dst),

      .sel_idx_1    ('0),
      .out_op_1     (),
      .out_v1_1     (),
      .out_v2_1     (),
      .out_dst_tag_1(),

      .sel_idx_2    ('0),
      .out_op_2     (),
      .out_v1_2     (),
      .out_v2_2     (),
      .out_dst_tag_2(),

      .sel_idx_3    ('0),
      .out_op_3     (),
      .out_v1_3     (),
      .out_v2_3     (),
      .out_dst_tag_3()
  );

  // ==========================================
  // 模块 3: 选择逻辑 (Issue Select)
  // ==========================================
  issue_select #(
      .Cfg(Cfg),
      .ISSUE_WIDTH(ISSUE_WIDTH)
  ) u_select (
      .ready_mask      (rs_ready_wires),
      .issue_grant_mask(grant_mask_wires),
      .issue_valid     (issue_valid),
      .issue_rs_idx    (issue_rs_idx)
  );

  // Free count for backpressure
  always_comb begin
    free_count_o = '0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (!rs_busy_wires[i]) free_count_o++;
    end
  end

endmodule
