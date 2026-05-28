// vsrc/backend/issue/issue.sv
import decode_pkg::*;
module issue #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter RS_DEPTH = Cfg.RS_DEPTH,
    parameter DATA_W   = Cfg.XLEN,
    parameter TAG_W    = 6,
    parameter CDB_W    = 4
) (
    input wire clk,
    input wire rst_n,
    input wire flush_i,
    input wire [ TAG_W-1:0] rob_head_i,

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

    output wire issue_ready,  // 给流水线前端：RS满了，停！
    output logic [$clog2(RS_DEPTH+1)-1:0] free_count_o,

    // 来自 CDB 的广播 (给 RS 监听用)
    input wire [ CDB_W-1:0] cdb_valid,
    input wire [ TAG_W-1:0] cdb_tag  [0:CDB_W-1],
    input wire [DATA_W-1:0] cdb_val  [0:CDB_W-1],

    // ALU 0 接口
    output wire                           alu0_en,
    output decode_pkg::uop_t              alu0_uop,
    output wire              [DATA_W-1:0] alu0_v1,
    output wire              [DATA_W-1:0] alu0_v2,
    output wire              [ TAG_W-1:0] alu0_dst,

    // ALU 1 接口
    output wire                           alu1_en,
    output decode_pkg::uop_t              alu1_uop,
    output wire              [DATA_W-1:0] alu1_v1,
    output wire              [DATA_W-1:0] alu1_v2,
    output wire              [ TAG_W-1:0] alu1_dst,

    // ALU 2 接口
    output wire                           alu2_en,
    output decode_pkg::uop_t              alu2_uop,
    output wire              [DATA_W-1:0] alu2_v1,
    output wire              [DATA_W-1:0] alu2_v2,
    output wire              [ TAG_W-1:0] alu2_dst,

    // ALU 3 接口
    output wire                           alu3_en,
    output decode_pkg::uop_t              alu3_uop,
    output wire              [DATA_W-1:0] alu3_v1,
    output wire              [DATA_W-1:0] alu3_v2,
    output wire              [ TAG_W-1:0] alu3_dst
);
`ifndef SYNTHESIS
  localparam int unsigned ISSUE_TRACE_BUDGET = 256;
  logic [31:0] issue_trace_cnt_q;
  logic issue_diag_trace_en_q;
  logic issue_bsearch_trace_en_q;
  initial issue_diag_trace_en_q = $test$plusargs("npc_diag_trace");
  initial issue_bsearch_trace_en_q = $test$plusargs("npc_diag_bsearch");

  function automatic logic watch_bsearch_pc(input logic [Cfg.PLEN-1:0] pc);
    begin
      watch_bsearch_pc = (pc == 32'hc0399942) ||  // bsearch: mv s1,a2
                         (pc == 32'hc039994c) ||  // bsearch: srli s3,s1,1
                         (pc == 32'hc0399950) ||  // bsearch: mul s2,s4,s3
                         (pc == 32'hc0399956) ||  // bsearch: addi s1,s1,-1
                         (pc == 32'hc0399958) ||  // bsearch: add s2,s2,s5
                         (pc == 32'hc039995a) ||  // bsearch: mv a1,s2
                         (pc == 32'hc0399964) ||  // bsearch: srli s1,s1,1
                         (pc == 32'hc0399986);    // bsearch: mv s1,s3
    end
  endfunction
`endif

  wire full_stall;
  assign issue_ready = ~full_stall;
  // A. Allocator <-> RS 之间的控制线
  wire [RS_DEPTH-1:0] rs_busy_wires;  // RS -> Alloc
  wire [RS_DEPTH-1:0] alloc_wen;  // Alloc -> RS (写使能)
  wire [$clog2(RS_DEPTH)-1:0] routing_idx[0:3];  // Alloc -> Crossbar (路由地址)

  // B. RS <-> Select Logic 之间的握手线
  wire [RS_DEPTH-1:0] rs_ready_wires;  // RS -> Select
  logic [RS_DEPTH-1:0] grant_mask_wires;  // Select -> RS (清除Busy)

  // C. Select Logic -> ALU Mux 的选择信号
  wire [$clog2(RS_DEPTH)-1:0] alu0_sel;
  wire [$clog2(RS_DEPTH)-1:0] alu1_sel;
  wire [$clog2(RS_DEPTH)-1:0] alu2_sel;
  wire [$clog2(RS_DEPTH)-1:0] alu3_sel;
  localparam int ISSUE_WIDTH = Cfg.INSTR_PER_FETCH;
  localparam int RS_IDX_W = $clog2(RS_DEPTH);
  logic [ISSUE_WIDTH-1:0] issue_valid;
  logic [$clog2(RS_DEPTH)-1:0] issue_rs_idx[0:ISSUE_WIDTH-1];
  logic [RS_DEPTH-1:0] select_mask_stage[0:ISSUE_WIDTH];
  logic [RS_DEPTH-1:0] select_grant_stage[0:ISSUE_WIDTH-1];
  logic [$clog2(RS_DEPTH)-1:0] rr_base_q, rr_base_d;

  assign alu0_en  = issue_valid[0];
  assign alu1_en  = issue_valid[1];
  assign alu2_en  = issue_valid[2];
  assign alu3_en  = issue_valid[3];
  assign alu0_sel = issue_rs_idx[0];
  assign alu1_sel = issue_rs_idx[1];
  assign alu2_sel = issue_rs_idx[2];
  assign alu3_sel = issue_rs_idx[3];

  function automatic logic [RS_DEPTH-1:0] find_first_one_from_base(
      input logic [RS_DEPTH-1:0] in_vec,
      input logic [RS_IDX_W-1:0] base
  );
    logic [RS_DEPTH-1:0] out_vec;
    logic found;
    begin
      out_vec = '0;
      found = 1'b0;
      for (int off = 0; off < RS_DEPTH; off++) begin
        int unsigned idx_int;
        logic [RS_IDX_W-1:0] idx;
        idx_int = base + off;
        if (idx_int >= RS_DEPTH) idx_int -= RS_DEPTH;
        idx = RS_IDX_W'(idx_int);
        if (in_vec[idx] && !found) begin
          out_vec[idx] = 1'b1;
          found = 1'b1;
        end
      end
      return out_vec;
    end
  endfunction

  // D. Crossbar <-> RS 输入数据线 (16组宽总线)
  // 这些是在 always_comb 里被驱动的
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

    for (int slot = 0; slot < ISSUE_WIDTH; slot++) begin
      if (dispatch_valid[slot]) begin
        rs_in_op[routing_idx[slot]]  = dispatch_op[slot];
        rs_in_dst[routing_idx[slot]] = dispatch_dst[slot];
        rs_in_v1[routing_idx[slot]]  = dispatch_v1[slot];
        rs_in_q1[routing_idx[slot]]  = dispatch_q1[slot];
        rs_in_r1[routing_idx[slot]]  = dispatch_r1[slot];
        rs_in_v2[routing_idx[slot]]  = dispatch_v2[slot];
        rs_in_q2[routing_idx[slot]]  = dispatch_q2[slot];
        rs_in_r2[routing_idx[slot]]  = dispatch_r2[slot];
      end
    end
  end

  reservation_station #(
      .Cfg(Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(DATA_W),
      .TAG_W(TAG_W),
      .CDB_W(CDB_W)
  ) u_rs (
      .clk(clk),
      .rst_n(rst_n),
      .flush_i(flush_i),
      .head_en_i(1'b0),
      .head_tag_i(rob_head_i),

      // 写端口 (连接 Crossbar 的结果)
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
      .comb_wakeup_en(1'b0),
      .cdb_wakeup_mask({CDB_W{1'b1}}),

      .busy_vector(rs_busy_wires),

      // 状态输出
      .ready_mask (rs_ready_wires),
      .issue_grant(grant_mask_wires),

      .sel_idx_0    (alu0_sel),
      .out_op_0     (alu0_uop),  // <--- 修改这里
      .out_v1_0     (alu0_v1),
      .out_v2_0     (alu0_v2),
      .out_dst_tag_0(alu0_dst),

      .sel_idx_1    (alu1_sel),
      .out_op_1     (alu1_uop),  // <--- 修改这里
      .out_v1_1     (alu1_v1),
      .out_v2_1     (alu1_v2),
      .out_dst_tag_1(alu1_dst),

      .sel_idx_2    (alu2_sel),
      .out_op_2     (alu2_uop),
      .out_v1_2     (alu2_v1),
      .out_v2_2     (alu2_v2),
      .out_dst_tag_2(alu2_dst),

      .sel_idx_3    (alu3_sel),
      .out_op_3     (alu3_uop),
      .out_v1_3     (alu3_v1),
      .out_v2_3     (alu3_v2),
      .out_dst_tag_3(alu3_dst)
  );

  // ==========================================
  // 模块 3: 选择逻辑 (Round-Robin from base)
  // ==========================================
  always_comb begin
    select_mask_stage[0] = rs_ready_wires;
    grant_mask_wires = '0;
    for (int j = 0; j < ISSUE_WIDTH; j++) begin
      select_grant_stage[j] = find_first_one_from_base(select_mask_stage[j], rr_base_q);
      select_mask_stage[j+1] = select_mask_stage[j] & ~select_grant_stage[j];
      grant_mask_wires |= select_grant_stage[j];

      issue_valid[j] = |select_grant_stage[j];
      issue_rs_idx[j] = '0;
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (select_grant_stage[j][i]) begin
          issue_rs_idx[j] = i[RS_IDX_W-1:0];
        end
      end
    end
  end

  always_comb begin
    logic any_issue;
    logic [RS_IDX_W-1:0] last_issue_idx;
    any_issue = 1'b0;
    last_issue_idx = rr_base_q;
    for (int j = 0; j < ISSUE_WIDTH; j++) begin
      if (issue_valid[j]) begin
        any_issue = 1'b1;
        last_issue_idx = issue_rs_idx[j];
      end
    end

    rr_base_d = rr_base_q;
    if (any_issue) begin
      if (last_issue_idx == RS_DEPTH - 1) begin
        rr_base_d = '0;
      end else begin
        rr_base_d = last_issue_idx + RS_IDX_W'(1);
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rr_base_q <= '0;
    end else if (flush_i) begin
      rr_base_q <= '0;
    end else begin
      rr_base_q <= rr_base_d;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      issue_trace_cnt_q <= '0;
    end else if (issue_diag_trace_en_q && issue_bsearch_trace_en_q &&
                 (issue_trace_cnt_q < ISSUE_TRACE_BUDGET)) begin
      int trace_inc;
      trace_inc = 0;
      for (int j = 0; j < ISSUE_WIDTH; j++) begin
        logic [RS_IDX_W-1:0] idx;
        logic [Cfg.PLEN-1:0] pc;
        logic [TAG_W-1:0] dst;
        logic [DATA_W-1:0] v1;
        logic [DATA_W-1:0] v2;
        idx = issue_rs_idx[j];
        pc  = alu0_uop.pc;
        dst = alu0_dst;
        v1  = alu0_v1;
        v2  = alu0_v2;
        if (j == 1) begin
          pc  = alu1_uop.pc;
          dst = alu1_dst;
          v1  = alu1_v1;
          v2  = alu1_v2;
        end else if (j == 2) begin
          pc  = alu2_uop.pc;
          dst = alu2_dst;
          v1  = alu2_v1;
          v2  = alu2_v2;
        end else if (j == 3) begin
          pc  = alu3_uop.pc;
          dst = alu3_dst;
          v1  = alu3_v1;
          v2  = alu3_v2;
        end
        if ((issue_trace_cnt_q + trace_inc) < ISSUE_TRACE_BUDGET &&
            issue_valid[j] && watch_bsearch_pc(pc)) begin
          $display("[issue-alu-pick] slot=%0d idx=%0d pc=%h dst=%0d v1=%h v2=%h rr_base=%0d ready=%b grant=%b",
                   j, idx, pc, dst, v1, v2, rr_base_q, rs_ready_wires, grant_mask_wires);
          trace_inc++;
        end
      end
      if (trace_inc != 0) begin
        issue_trace_cnt_q <= issue_trace_cnt_q + trace_inc[31:0];
      end
    end
  end
`endif

  // Free count for backpressure
  always_comb begin
    free_count_o = '0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (!rs_busy_wires[i]) free_count_o++;
    end
  end

endmodule
