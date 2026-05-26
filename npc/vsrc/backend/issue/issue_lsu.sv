// vsrc/backend/issue/issue_lsu.sv
import decode_pkg::*;

module issue_lsu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter RS_DEPTH = Cfg.RS_DEPTH,
    parameter DATA_W   = Cfg.XLEN,
    parameter TAG_W    = 6,
    parameter CDB_W    = 4,
    parameter SB_W     = 4
) (
    input wire clk,
    input wire rst_n,
    input wire flush_i,

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
    // Store Buffer ID
    input wire                   [  SB_W-1:0] dispatch_sb_id[0:3],

    input wire                   [ TAG_W-1:0] rob_head_i,
    input wire                                mispred_block_i,
    input wire                                spec_low_addr_block_en_i,

    input wire fu_ready_i,

    output wire issue_ready,
    output logic [$clog2(RS_DEPTH+1)-1:0] free_count_o,

    // CDB
    input wire [ CDB_W-1:0] cdb_valid,
    input wire [ TAG_W-1:0] cdb_tag  [0:CDB_W-1],
    input wire [DATA_W-1:0] cdb_val  [0:CDB_W-1],

    // LSU 输出
    output wire                           lsu_en,
    output decode_pkg::uop_t              lsu_uop,
    output wire              [DATA_W-1:0] lsu_v1,
    output wire              [DATA_W-1:0] lsu_v2,
    output wire              [ TAG_W-1:0] lsu_dst,
    output wire              [  SB_W-1:0] lsu_sb_id
);
  wire full_stall;
  assign issue_ready = ~full_stall;

  // A. Allocator <-> RS 之间的控制线
  wire [RS_DEPTH-1:0] rs_busy_wires;
  wire [RS_DEPTH-1:0] alloc_wen;
  wire [$clog2(RS_DEPTH)-1:0] routing_idx[0:3];

  // B. RS <-> Select Logic 之间的握手线
  wire [RS_DEPTH-1:0] rs_ready_wires;
  wire [RS_DEPTH-1:0] grant_mask_wires;

  // C. Select Logic -> LSU
  localparam int ISSUE_WIDTH = 2;
  logic [ISSUE_WIDTH-1:0] issue_valid_raw;
  logic [$clog2(RS_DEPTH)-1:0] issue_rs_idx_raw[0:ISSUE_WIDTH-1];
  wire [DATA_W-1:0] issue_v1_0;
  wire [DATA_W-1:0] issue_v1_1;
  wire [DATA_W-1:0] issue_v2_0;
  wire [DATA_W-1:0] issue_v2_1;
  wire [ TAG_W-1:0] issue_dst_0;
  wire [ TAG_W-1:0] issue_dst_1;
  wire [  SB_W-1:0] issue_sb_id_0;
  wire [  SB_W-1:0] issue_sb_id_1;
  decode_pkg::uop_t issue_uop_0;
  decode_pkg::uop_t issue_uop_1;
  wire [DATA_W-1:0] issue_effective_addr_0;
  wire [DATA_W-1:0] issue_effective_addr_1;
  wire              issue_blocked_low_addr_spec_0;
  wire              issue_blocked_low_addr_spec_1;
  wire              issue_pick_0;
  wire              issue_pick_1;
  wire              issue_pick_any;
  wire              issue_fire;
  wire              issue_base_allow;
  logic [RS_DEPTH-1:0] issue_grant_selected;
`ifndef SYNTHESIS
  localparam int unsigned LSU_ISSUE_TRACE_BUDGET = 256;
  logic [31:0] lsu_issue_trace_cnt_q;
  localparam int unsigned LSU_BLOCK_TRACE_BUDGET = 512;
  logic [31:0] lsu_block_trace_cnt_q;
  localparam int unsigned LSU_STALL_TRACE_BUDGET = 512;
  logic [31:0] lsu_stall_trace_cnt_q;
  logic lsu_trace_en_q;
  initial begin
    lsu_trace_en_q = $test$plusargs("npc_diag_trace");
  end
`endif

  function automatic logic is_spec_low_addr(input logic [DATA_W-1:0] addr);
    begin
      is_spec_low_addr = ((addr[DATA_W-1:12] == '0) || (&addr[DATA_W-1:12]));
    end
  endfunction

  function automatic logic [TAG_W-1:0] rob_age(
      input logic [TAG_W-1:0] idx, input logic [TAG_W-1:0] head);
    begin
      rob_age = idx - head;
    end
  endfunction

  logic [TAG_W-1:0] rs_dst_tag[0:RS_DEPTH-1];

`ifndef SYNTHESIS
  function automatic logic watch_lsu_pc(input logic [31:0] pc);
    begin
      watch_lsu_pc = (pc == 32'hc074befe) ||
                     (pc == 32'hc076a580) ||
                     (pc == 32'hc076a584) ||
                     (pc == 32'hc074c47e) ||
                     (pc == 32'hc074c480) ||
                     (pc == 32'hc074cf9e);
    end
  endfunction
`endif

  assign issue_effective_addr_0 = issue_v1_0 + issue_uop_0.imm;
  assign issue_effective_addr_1 = issue_v1_1 + issue_uop_1.imm;
  assign issue_blocked_low_addr_spec_0 = spec_low_addr_block_en_i &&
                                         issue_valid_raw[0] &&
                                         is_spec_low_addr(issue_effective_addr_0) &&
                                         (issue_dst_0 != rob_head_i);
  assign issue_blocked_low_addr_spec_1 = spec_low_addr_block_en_i &&
                                         issue_valid_raw[1] &&
                                         is_spec_low_addr(issue_effective_addr_1) &&
                                         (issue_dst_1 != rob_head_i);
  assign issue_pick_0 = issue_valid_raw[0] && !issue_blocked_low_addr_spec_0;
  assign issue_pick_1 = !issue_pick_0 && issue_valid_raw[1] && !issue_blocked_low_addr_spec_1;
  assign issue_pick_any = issue_pick_0 || issue_pick_1;
  assign issue_base_allow = fu_ready_i && !flush_i && !mispred_block_i;
  assign issue_fire = issue_base_allow && issue_pick_any;
  assign lsu_en = issue_fire;
  assign lsu_uop = issue_pick_1 ? issue_uop_1 : issue_uop_0;
  assign lsu_v1 = issue_pick_1 ? issue_v1_1 : issue_v1_0;
  assign lsu_v2 = issue_pick_1 ? issue_v2_1 : issue_v2_0;
  assign lsu_dst = issue_pick_1 ? issue_dst_1 : issue_dst_0;
  assign lsu_sb_id = issue_pick_1 ? issue_sb_id_1 : issue_sb_id_0;

  always_comb begin
    issue_grant_selected = '0;
    if (issue_pick_0) begin
      issue_grant_selected[issue_rs_idx_raw[0]] = 1'b1;
    end else if (issue_pick_1) begin
      issue_grant_selected[issue_rs_idx_raw[1]] = 1'b1;
    end
  end

  // Never let LSU issue in a flush cycle; otherwise wrong-path memory ops can escape.
  assign grant_mask_wires = issue_base_allow ? issue_grant_selected : '0;

  // D. Crossbar inputs
  decode_pkg::uop_t rs_in_op[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_dst[0:RS_DEPTH-1];
  logic [DATA_W-1:0] rs_in_v1[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_q1[0:RS_DEPTH-1];
  logic rs_in_r1[0:RS_DEPTH-1];
  logic [DATA_W-1:0] rs_in_v2[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_q2[0:RS_DEPTH-1];
  logic rs_in_r2[0:RS_DEPTH-1];
  logic [SB_W-1:0] rs_in_sb_id[0:RS_DEPTH-1];

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
      rs_in_op[k]    = 0;
      rs_in_dst[k]   = 0;
      rs_in_v1[k]    = 0;
      rs_in_q1[k]    = 0;
      rs_in_r1[k]    = 0;
      rs_in_v2[k]    = 0;
      rs_in_q2[k]    = 0;
      rs_in_r2[k]    = 0;
      rs_in_sb_id[k] = 0;
    end

    for (int i = 0; i < 4; i++) begin
      if (dispatch_valid[i]) begin
        rs_in_op[routing_idx[i]]    = dispatch_op[i];
        rs_in_dst[routing_idx[i]]   = dispatch_dst[i];
        rs_in_v1[routing_idx[i]]    = dispatch_v1[i];
        rs_in_q1[routing_idx[i]]    = dispatch_q1[i];
        rs_in_r1[routing_idx[i]]    = dispatch_r1[i];
        rs_in_v2[routing_idx[i]]    = dispatch_v2[i];
        rs_in_q2[routing_idx[i]]    = dispatch_q2[i];
        rs_in_r2[routing_idx[i]]    = dispatch_r2[i];
        rs_in_sb_id[routing_idx[i]] = dispatch_sb_id[i];
      end
    end
  end

  reservation_station_lsu #(
      .Cfg   (Cfg),
      .DATA_W(DATA_W),
      .TAG_W (TAG_W),
      .CDB_W (CDB_W),
      .SB_W  (SB_W)
  ) u_rs (
      .clk  (clk),
      .rst_n(rst_n),
      .flush_i(flush_i),

      .rob_head_i(rob_head_i),
      .spec_low_addr_block_en_i(spec_low_addr_block_en_i),

      .entry_wen (alloc_wen),
      .in_op     (rs_in_op),
      .in_dst_tag(rs_in_dst),
      .in_v1     (rs_in_v1),
      .in_q1     (rs_in_q1),
      .in_r1     (rs_in_r1),
      .in_v2     (rs_in_v2),
      .in_q2     (rs_in_q2),
      .in_r2     (rs_in_r2),
      .in_sb_id  (rs_in_sb_id),

      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_value(cdb_val),

      .busy_vector(rs_busy_wires),
      .ready_mask (rs_ready_wires),
      .issue_grant(grant_mask_wires),

      .sel_idx_0    (issue_rs_idx_raw[0]),
      .sel_idx_1    (issue_rs_idx_raw[1]),
      .out_op_0     (issue_uop_0),
      .out_op_1     (issue_uop_1),
      .out_v1_0     (issue_v1_0),
      .out_v1_1     (issue_v1_1),
      .out_v2_0     (issue_v2_0),
      .out_v2_1     (issue_v2_1),
      .out_dst_tag_0(issue_dst_0),
      .out_dst_tag_1(issue_dst_1),
      .out_sb_id_0  (issue_sb_id_0),
      .out_sb_id_1  (issue_sb_id_1),
      .dst_tag_o    (rs_dst_tag)
  );

  // Pick the oldest ready RS entries by ROB age, not RS physical index.
  always_comb begin
    logic found0;
    logic found1;
    logic [$clog2(RS_DEPTH)-1:0] pick_idx0;
    logic [$clog2(RS_DEPTH)-1:0] pick_idx1;
    logic [TAG_W-1:0] best_age0;
    logic [TAG_W-1:0] best_age1;

    issue_valid_raw[0] = 1'b0;
    issue_valid_raw[1] = 1'b0;
    pick_idx0 = '0;
    pick_idx1 = '0;
    found0 = 1'b0;
    found1 = 1'b0;
    best_age0 = {TAG_W{1'b1}};
    best_age1 = {TAG_W{1'b1}};

    for (int i = 0; i < RS_DEPTH; i++) begin
      if (rs_ready_wires[i]) begin
        automatic logic [TAG_W-1:0] age;
        age = rob_age(rs_dst_tag[i], rob_head_i);
        if (!found0 || (age < best_age0)) begin
          found0 = 1'b1;
          best_age0 = age;
          pick_idx0 = i[$clog2(RS_DEPTH)-1:0];
        end
      end
    end

    for (int i = 0; i < RS_DEPTH; i++) begin
      if (rs_ready_wires[i] && (i[$clog2(RS_DEPTH)-1:0] != pick_idx0)) begin
        automatic logic [TAG_W-1:0] age;
        age = rob_age(rs_dst_tag[i], rob_head_i);
        if (!found1 || (age < best_age1)) begin
          found1 = 1'b1;
          best_age1 = age;
          pick_idx1 = i[$clog2(RS_DEPTH)-1:0];
        end
      end
    end

    issue_valid_raw[0] = found0;
    issue_valid_raw[1] = found1;
    issue_rs_idx_raw[0] = pick_idx0;
    issue_rs_idx_raw[1] = pick_idx1;
  end

  // Free count for backpressure
  always_comb begin
    free_count_o = '0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (!rs_busy_wires[i]) free_count_o++;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk or negedge rst_n) begin
    logic watch_pc;
    logic watch_issue_slots;
    logic [31:0] issue_trace_inc;
    logic [31:0] block_trace_inc;
    logic [31:0] stall_trace_inc;
    watch_pc = watch_lsu_pc(lsu_uop.pc);
    watch_issue_slots = watch_lsu_pc(issue_uop_0.pc) || watch_lsu_pc(issue_uop_1.pc);
    issue_trace_inc = '0;
    block_trace_inc = '0;
    stall_trace_inc = '0;
    if (!rst_n) begin
      lsu_issue_trace_cnt_q <= '0;
      lsu_block_trace_cnt_q <= '0;
      lsu_stall_trace_cnt_q <= '0;
    end else if (lsu_trace_en_q) begin
      if (lsu_en && watch_pc &&
          ((lsu_issue_trace_cnt_q + issue_trace_inc) < LSU_ISSUE_TRACE_BUDGET)) begin
        $display("[issue-lsu] pc=%h rs1=%h rs2=%h imm=%h lsu_op=%0d is_ld=%0d is_st=%0d dst=%0d sb=%0d ftq=%0d epoch=%0d rvc=%0d flush=%0d fu_ready=%0d issue0_raw=%0d issue1_raw=%0d pick0=%0d pick1=%0d",
                 lsu_uop.pc, lsu_v1, lsu_v2, lsu_uop.imm, lsu_uop.lsu_op, lsu_uop.is_load, lsu_uop.is_store,
                 lsu_dst, lsu_sb_id, lsu_uop.ftq_id, lsu_uop.fetch_epoch, lsu_uop.is_rvc, flush_i, fu_ready_i,
                 issue_valid_raw[0], issue_valid_raw[1], issue_pick_0, issue_pick_1);
        issue_trace_inc = issue_trace_inc + 32'd1;
        if (flush_i &&
            ((lsu_issue_trace_cnt_q + issue_trace_inc) < LSU_ISSUE_TRACE_BUDGET)) begin
          $display("[issue-lsu-on-flush] pc=%h rs1=%h rs2=%h dst=%0d sb=%0d ftq=%0d epoch=%0d fu_ready=%0d issue0_raw=%0d issue1_raw=%0d",
                   lsu_uop.pc, lsu_v1, lsu_v2, lsu_dst, lsu_sb_id, lsu_uop.ftq_id, lsu_uop.fetch_epoch, fu_ready_i,
                   issue_valid_raw[0], issue_valid_raw[1]);
          issue_trace_inc = issue_trace_inc + 32'd1;
        end
      end
      if (issue_valid_raw[0] && issue_blocked_low_addr_spec_0 &&
          watch_lsu_pc(issue_uop_0.pc) &&
          ((lsu_block_trace_cnt_q + block_trace_inc) < LSU_BLOCK_TRACE_BUDGET)) begin
        $display("[issue-lsu-blocked] slot=0 pc=%h dst=%0d rob_head=%0d vaddr=%h flush=%0d mispred=%0d spec_low=%0d fu_ready=%0d issue_raw=%0d pick0=%0d pick1=%0d",
                 issue_uop_0.pc, issue_dst_0, rob_head_i, issue_effective_addr_0, flush_i, mispred_block_i,
                 issue_blocked_low_addr_spec_0, fu_ready_i, issue_valid_raw[0], issue_pick_0, issue_pick_1);
        block_trace_inc = block_trace_inc + 32'd1;
      end
      if (issue_valid_raw[1] && issue_blocked_low_addr_spec_1 &&
          watch_lsu_pc(issue_uop_1.pc) &&
          ((lsu_block_trace_cnt_q + block_trace_inc) < LSU_BLOCK_TRACE_BUDGET)) begin
        $display("[issue-lsu-blocked] slot=1 pc=%h dst=%0d rob_head=%0d vaddr=%h flush=%0d mispred=%0d spec_low=%0d fu_ready=%0d issue_raw=%0d pick0=%0d pick1=%0d",
                 issue_uop_1.pc, issue_dst_1, rob_head_i, issue_effective_addr_1, flush_i, mispred_block_i,
                 issue_blocked_low_addr_spec_1, fu_ready_i, issue_valid_raw[1], issue_pick_0, issue_pick_1);
        block_trace_inc = block_trace_inc + 32'd1;
      end
      if (watch_issue_slots && (|rs_ready_wires) && !issue_pick_any &&
          ((lsu_stall_trace_cnt_q + stall_trace_inc) < LSU_STALL_TRACE_BUDGET)) begin
        $display("[issue-lsu-stall] rs_ready=0x%h issue_raw=%0d/%0d idx=%0d/%0d pc=%h/%h dst=%0d/%0d blk=%0d/%0d rob_head=%0d spec_low_en=%0d fu_ready=%0d mispred=%0d flush=%0d",
                 rs_ready_wires, issue_valid_raw[0], issue_valid_raw[1], issue_rs_idx_raw[0], issue_rs_idx_raw[1],
                 issue_uop_0.pc, issue_uop_1.pc, issue_dst_0, issue_dst_1,
                 issue_blocked_low_addr_spec_0, issue_blocked_low_addr_spec_1,
                 rob_head_i, spec_low_addr_block_en_i, fu_ready_i, mispred_block_i, flush_i);
        stall_trace_inc = stall_trace_inc + 32'd1;
      end
      if (watch_issue_slots && issue_pick_any && !issue_base_allow &&
          ((lsu_stall_trace_cnt_q + stall_trace_inc) < LSU_STALL_TRACE_BUDGET)) begin
        $display("[issue-lsu-backpressure] pick=%0d/%0d raw=%0d/%0d pc=%h/%h dst=%0d/%0d fu_ready=%0d mispred=%0d flush=%0d rs_ready=0x%h",
                 issue_pick_0, issue_pick_1, issue_valid_raw[0], issue_valid_raw[1],
                 issue_uop_0.pc, issue_uop_1.pc, issue_dst_0, issue_dst_1,
                 fu_ready_i, mispred_block_i, flush_i, rs_ready_wires);
        stall_trace_inc = stall_trace_inc + 32'd1;
      end
      if (issue_trace_inc != 0) begin
        lsu_issue_trace_cnt_q <= lsu_issue_trace_cnt_q + issue_trace_inc;
      end
      if (block_trace_inc != 0) begin
        lsu_block_trace_cnt_q <= lsu_block_trace_cnt_q + block_trace_inc;
      end
      if (stall_trace_inc != 0) begin
        lsu_stall_trace_cnt_q <= lsu_stall_trace_cnt_q + stall_trace_inc;
      end
    end
  end
`endif

endmodule
