// vsrc/backend/issue/issue_lsu.sv
import decode_pkg::*;

module issue_lsu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter RS_DEPTH = Cfg.RS_DEPTH,
    parameter DATA_W   = Cfg.XLEN,
    parameter TAG_W    = 6,
    parameter CDB_W    = 4,
    parameter ST_W     = 4
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
    // STQ ID
    input wire                   [  ST_W-1:0] dispatch_st_id[0:3],

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

    // LSU 输出（双口：每拍最多投放 2 条 load/store）
    output wire                           lsu_en     [0:1],
    output decode_pkg::uop_t              lsu_uop    [0:1],
    output wire              [DATA_W-1:0] lsu_v1     [0:1],
    output wire              [DATA_W-1:0] lsu_v2     [0:1],
    output wire              [ TAG_W-1:0] lsu_dst    [0:1],
    output wire              [  ST_W-1:0] lsu_stq_id [0:1],
    // 预门控候选有效（不含 fu_ready_i）：供 lsu_group 计算 req_ready_o 使用，
    // 避免 fu_ready_i 与 lsu_group 自身输出的 req_ready_o 构成组合环。
    // lsu_en[k] = lsu_cand_v[k] && issue_base_allow；lsu_uop[k] 仅在
    // lsu_cand_v[k] 为真时内容有意义（否则可能是 RS 陈旧/无关条目）。
    output wire                           lsu_cand_v [0:1],
    // Raw RS picks (pre port1 gating), forwarded to lsu_group for dual/shape
    // classification without a cand_valid_i combinational loop.
    output wire                           lsu_pick_v [0:1],
    // From lsu_group: port1 may only co-issue when the pair matches the dual
    // fast-path shape; otherwise serialize through port0 alone.
    input  wire                           dual_port1_en_i,

    // Non-consuming STA-only path for ordinary stores. This writes STQ addr
    // early but leaves the RS entry resident until full store issue.
    input  wire                           sta_ready_i,
    output wire                           sta_valid_o,
    output decode_pkg::uop_t              sta_uop_o,
    output wire              [DATA_W-1:0] sta_addr_o,
    output wire              [ TAG_W-1:0] sta_dst_o,
    output wire              [  ST_W-1:0] sta_stq_id_o,

    output wire                           std_valid_o,
    output wire              [DATA_W-1:0] std_data_o,
    output wire              [  ST_W-1:0] std_stq_id_o,

    output wire                           stq_order_query_valid_o,
    output wire              [DATA_W-1:0] stq_order_query_addr_o,
    output wire          [DATA_W/8-1:0]   stq_order_query_be_o,
    output wire              [ TAG_W-1:0] stq_order_query_rob_idx_o,
    input  wire                           stq_order_query_safe_i,
    input  wire                           stq_order_query_forward_full_i,
    input  wire                           stq_order_oldest_store_valid_i,
    input  wire              [ TAG_W-1:0] stq_order_oldest_store_rob_idx_i,
    input  wire                           stq_order_has_committed_store_i
);
  wire full_stall;
  assign issue_ready = ~full_stall;

  localparam int ISSUE_WIDTH = 2;

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

  function automatic logic is_plain_load_uop(input decode_pkg::uop_t op);
    begin
      is_plain_load_uop = op.is_load && !op.is_store &&
                          (op.lsu_op != decode_pkg::LSU_AMO) &&
                          (op.lsu_op != decode_pkg::LSU_LR);
    end
  endfunction

  // A. Split allocator <-> RS control.
  wire [RS_DEPTH-1:0] load_rs_busy_wires;
  wire [RS_DEPTH-1:0] store_rs_busy_wires;
  wire [RS_DEPTH-1:0] rs_busy_wires;
  wire [RS_DEPTH-1:0] load_alloc_wen;
  wire [RS_DEPTH-1:0] store_alloc_wen;
  wire [$clog2(RS_DEPTH)-1:0] load_routing_idx[0:3];
  wire [$clog2(RS_DEPTH)-1:0] store_routing_idx[0:3];
  logic [3:0] load_dispatch_valid;
  logic [3:0] store_dispatch_valid;
  logic [1:0] load_dispatch_lane[0:3];
  logic [1:0] store_dispatch_lane[0:3];
  logic [2:0] load_dispatch_count;
  logic [2:0] store_dispatch_count;
  wire load_full_stall_raw;
  wire store_full_stall_raw;
  wire load_full_stall;
  wire store_full_stall;

  // B. RS <-> Select Logic.
  wire [RS_DEPTH-1:0] load_rs_ready_wires;
  wire [RS_DEPTH-1:0] store_rs_ready_wires;
  wire [RS_DEPTH-1:0] rs_ready_wires;
  wire [RS_DEPTH-1:0] load_rs_plain_load_wires;
  wire [RS_DEPTH-1:0] store_rs_plain_load_wires;
  wire [RS_DEPTH-1:0] store_rs_ready_store_wires;
  wire [RS_DEPTH-1:0] store_rs_blocking_ready_store_wires;
  logic [RS_DEPTH-1:0] load_issue_grant_selected;
  logic [RS_DEPTH-1:0] store_issue_grant_selected;
  wire [RS_DEPTH-1:0] load_grant_mask_wires;
  wire [RS_DEPTH-1:0] store_grant_mask_wires;

  // C. Select Logic -> LSU.
  logic [ISSUE_WIDTH-1:0] issue_valid_raw;
  logic [$clog2(RS_DEPTH)-1:0] issue_rs_idx_raw[0:ISSUE_WIDTH-1];
  logic issue_rs_is_load_raw[0:ISSUE_WIDTH-1];
  logic [DATA_W-1:0] issue_v1_0;
  logic [DATA_W-1:0] issue_v1_1;
  logic [DATA_W-1:0] issue_v2_0;
  logic [DATA_W-1:0] issue_v2_1;
  logic [ TAG_W-1:0] issue_dst_0;
  logic [ TAG_W-1:0] issue_dst_1;
  logic [  ST_W-1:0] issue_st_id_0;
  logic [  ST_W-1:0] issue_st_id_1;
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
  wire              sta_base_allow;
  wire              std_base_allow;

  wire rs_sta_valid;
  wire rs_sta_fire;
  decode_pkg::uop_t rs_sta_uop;
  wire [DATA_W-1:0] rs_sta_v1;
  wire [TAG_W-1:0] rs_sta_dst;
  wire [ST_W-1:0] rs_sta_st_id;
  wire [DATA_W-1:0] rs_sta_addr;
  wire rs_std_valid;
  wire rs_std_fire;
  wire [DATA_W-1:0] rs_std_data;
  wire [ST_W-1:0] rs_std_st_id;

  wire load_rs_load_order_query_valid;
  wire [DATA_W-1:0] load_rs_load_order_query_addr;
  wire [DATA_W/8-1:0] load_rs_load_order_query_be;
  wire [TAG_W-1:0] load_rs_load_order_query_rob_idx;
  wire store_rs_load_order_query_valid;
  wire [DATA_W-1:0] store_rs_load_order_query_addr;
  wire [DATA_W/8-1:0] store_rs_load_order_query_be;
  wire [TAG_W-1:0] store_rs_load_order_query_rob_idx;
  wire rs_load_order_query_valid;
  wire [DATA_W-1:0] rs_load_order_query_addr;
  wire [DATA_W/8-1:0] rs_load_order_query_be;
  wire [TAG_W-1:0] rs_load_order_query_rob_idx;
  wire load_rs_query_chosen;

  decode_pkg::uop_t store_rs_store_op[0:RS_DEPTH-1];
  wire [RS_DEPTH-1:0] store_rs_store_busy;
  wire [TAG_W-1:0] store_rs_store_dst_tag[0:RS_DEPTH-1];
  wire [DATA_W-1:0] store_rs_store_v1[0:RS_DEPTH-1];
  wire store_rs_store_r1[0:RS_DEPTH-1];
  wire [DATA_W-1:0] store_rs_store_v2[0:RS_DEPTH-1];
  wire store_rs_store_r2[0:RS_DEPTH-1];

  decode_pkg::uop_t load_out_op_0;
  decode_pkg::uop_t load_out_op_1;
  wire [DATA_W-1:0] load_out_v1_0;
  wire [DATA_W-1:0] load_out_v1_1;
  wire [DATA_W-1:0] load_out_v2_0;
  wire [DATA_W-1:0] load_out_v2_1;
  wire [TAG_W-1:0] load_out_dst_0;
  wire [TAG_W-1:0] load_out_dst_1;
  wire [ST_W-1:0] load_out_st_id_0;
  wire [ST_W-1:0] load_out_st_id_1;
  logic [TAG_W-1:0] load_rs_dst_tag[0:RS_DEPTH-1];

  decode_pkg::uop_t store_out_op_0;
  decode_pkg::uop_t store_out_op_1;
  wire [DATA_W-1:0] store_out_v1_0;
  wire [DATA_W-1:0] store_out_v1_1;
  wire [DATA_W-1:0] store_out_v2_0;
  wire [DATA_W-1:0] store_out_v2_1;
  wire [TAG_W-1:0] store_out_dst_0;
  wire [TAG_W-1:0] store_out_dst_1;
  wire [ST_W-1:0] store_out_st_id_0;
  wire [ST_W-1:0] store_out_st_id_1;
  logic [TAG_W-1:0] store_rs_dst_tag[0:RS_DEPTH-1];
  wire [$clog2(RS_DEPTH)-1:0] load_sel_idx_0;
  wire [$clog2(RS_DEPTH)-1:0] load_sel_idx_1;
  wire [$clog2(RS_DEPTH)-1:0] store_sel_idx_0;
  wire [$clog2(RS_DEPTH)-1:0] store_sel_idx_1;

  logic [63:0] dbg_sta_early_fire_q;
  logic [63:0] dbg_std_early_fire_q;
  logic [63:0] dbg_dispatch_load_q;
  logic [63:0] dbg_dispatch_store_q;
  logic [63:0] dbg_dispatch_both_q;
  logic [63:0] dbg_dispatch_other_q;
  logic [63:0] dbg_dispatch_load_block_full_q;
  logic [63:0] dbg_dispatch_store_block_full_q;
  logic [63:0] dbg_dispatch_both_block_full_q;
  logic [63:0] dbg_dispatch_other_block_full_q;
  logic [2:0] dbg_dispatch_load_inc_w;
  logic [2:0] dbg_dispatch_store_inc_w;
  logic [2:0] dbg_dispatch_both_inc_w;
  logic [2:0] dbg_dispatch_other_inc_w;
  logic [2:0] dbg_dispatch_load_block_full_inc_w;
  logic [2:0] dbg_dispatch_store_block_full_inc_w;
  logic [2:0] dbg_dispatch_both_block_full_inc_w;
  logic [2:0] dbg_dispatch_other_block_full_inc_w;
  logic [63:0] dbg_ff_query_active_q;
  logic [63:0] dbg_ff_query_issue_q;
  logic [63:0] dbg_ff_query_not_issue_q;
  logic [63:0] dbg_ff_not_issue_base_block_q;
  logic [63:0] dbg_ff_not_issue_p1_gated_q;
  logic [63:0] dbg_ff_not_issue_low_addr_q;
  logic [63:0] dbg_ff_not_issue_not_selected_q;
  logic [63:0] dbg_ff_not_issue_selected_other_q;
  wire dbg_ff_query_active;
  wire dbg_ff_sel0;
  wire dbg_ff_sel1;
  wire dbg_ff_issue;
  wire dbg_ff_low_addr;
  wire dbg_ff_p1_gated;
  wire dbg_ff_not_selected;
  wire dbg_ff_selected_other;

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

  assign rs_busy_wires = load_rs_busy_wires | store_rs_busy_wires;
  assign rs_ready_wires = load_rs_ready_wires | store_rs_ready_wires;
  assign load_full_stall = (load_dispatch_count != 0) && load_full_stall_raw;
  assign store_full_stall = (store_dispatch_count != 0) && store_full_stall_raw;
  assign full_stall = load_full_stall || store_full_stall;

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
  assign issue_pick_1 = issue_valid_raw[1] && !issue_blocked_low_addr_spec_1;
  assign issue_pick_any = issue_pick_0 || issue_pick_1;
  assign issue_base_allow = fu_ready_i && !flush_i && !mispred_block_i;
  assign sta_base_allow = !flush_i && !mispred_block_i && sta_ready_i;
  assign std_base_allow = !flush_i && !mispred_block_i;
  assign issue_fire = issue_base_allow && issue_pick_any;
  assign rs_sta_addr = rs_sta_v1 + rs_sta_uop.imm;
  assign rs_sta_fire = sta_base_allow && rs_sta_valid;
  assign rs_std_fire = std_base_allow && rs_std_valid;
  assign sta_valid_o = rs_sta_fire;
  assign sta_uop_o = rs_sta_uop;
  assign sta_addr_o = rs_sta_addr;
  assign sta_dst_o = rs_sta_dst;
  assign sta_stq_id_o = rs_sta_st_id;
  assign std_valid_o = rs_std_fire;
  assign std_data_o = rs_std_data;
  assign std_stq_id_o = rs_std_st_id;

  assign load_rs_query_chosen = load_rs_load_order_query_valid;
  assign rs_load_order_query_valid = load_rs_query_chosen ? load_rs_load_order_query_valid :
                                                            store_rs_load_order_query_valid;
  assign rs_load_order_query_addr = load_rs_query_chosen ? load_rs_load_order_query_addr :
                                                           store_rs_load_order_query_addr;
  assign rs_load_order_query_be = load_rs_query_chosen ? load_rs_load_order_query_be :
                                                         store_rs_load_order_query_be;
  assign rs_load_order_query_rob_idx = load_rs_query_chosen ? load_rs_load_order_query_rob_idx :
                                                              store_rs_load_order_query_rob_idx;
  assign stq_order_query_valid_o = !flush_i && !mispred_block_i && rs_load_order_query_valid;
  assign stq_order_query_addr_o = rs_load_order_query_addr;
  assign stq_order_query_be_o = rs_load_order_query_be;
  assign stq_order_query_rob_idx_o = rs_load_order_query_rob_idx;

  assign lsu_pick_v[0] = issue_pick_0;
  assign lsu_pick_v[1] = issue_pick_1;
  assign lsu_en[0] = issue_base_allow && issue_pick_0;
  assign lsu_en[1] = issue_base_allow && issue_pick_1 && dual_port1_en_i;
  assign lsu_uop[0] = issue_uop_0;
  assign lsu_uop[1] = issue_uop_1;
  assign lsu_v1[0] = issue_v1_0;
  assign lsu_v1[1] = issue_v1_1;
  assign lsu_v2[0] = issue_v2_0;
  assign lsu_v2[1] = issue_v2_1;
  assign lsu_dst[0] = issue_dst_0;
  assign lsu_dst[1] = issue_dst_1;
  assign lsu_stq_id[0] = issue_st_id_0;
  assign lsu_stq_id[1] = issue_st_id_1;
  assign lsu_cand_v[0] = issue_pick_0;
  assign lsu_cand_v[1] = issue_pick_1 && dual_port1_en_i;

  assign dbg_ff_query_active = stq_order_query_valid_o && stq_order_query_safe_i &&
                               stq_order_query_forward_full_i;
  assign dbg_ff_sel0 = dbg_ff_query_active && issue_valid_raw[0] &&
                       (issue_dst_0 == rs_load_order_query_rob_idx);
  assign dbg_ff_sel1 = dbg_ff_query_active && issue_valid_raw[1] &&
                       (issue_dst_1 == rs_load_order_query_rob_idx);
  assign dbg_ff_issue = issue_base_allow &&
                        ((dbg_ff_sel0 && issue_pick_0) ||
                         (dbg_ff_sel1 && issue_pick_1 && dual_port1_en_i));
  assign dbg_ff_low_addr = (dbg_ff_sel0 && issue_blocked_low_addr_spec_0) ||
                           (dbg_ff_sel1 && issue_blocked_low_addr_spec_1);
  assign dbg_ff_p1_gated = dbg_ff_query_active && issue_base_allow && !dbg_ff_issue &&
                           !dbg_ff_low_addr && dbg_ff_sel1 && issue_pick_1 &&
                           !dual_port1_en_i;
  assign dbg_ff_not_selected = dbg_ff_query_active && issue_base_allow && !dbg_ff_issue &&
                               !dbg_ff_low_addr && !dbg_ff_p1_gated &&
                               !dbg_ff_sel0 && !dbg_ff_sel1;
  assign dbg_ff_selected_other = dbg_ff_query_active && issue_base_allow && !dbg_ff_issue &&
                                 !dbg_ff_low_addr && !dbg_ff_p1_gated &&
                                 !dbg_ff_not_selected;

  always_comb begin
    load_issue_grant_selected = '0;
    store_issue_grant_selected = '0;
    if (issue_pick_0) begin
      if (issue_rs_is_load_raw[0]) load_issue_grant_selected[issue_rs_idx_raw[0]] = 1'b1;
      else store_issue_grant_selected[issue_rs_idx_raw[0]] = 1'b1;
    end
    if (issue_pick_1 && dual_port1_en_i) begin
      if (issue_rs_is_load_raw[1]) load_issue_grant_selected[issue_rs_idx_raw[1]] = 1'b1;
      else store_issue_grant_selected[issue_rs_idx_raw[1]] = 1'b1;
    end
  end

  assign load_grant_mask_wires = issue_base_allow ? load_issue_grant_selected : '0;
  assign store_grant_mask_wires = issue_base_allow ? store_issue_grant_selected : '0;

  // D. Split crossbar inputs.
  decode_pkg::uop_t load_rs_in_op[0:RS_DEPTH-1];
  logic [TAG_W-1:0] load_rs_in_dst[0:RS_DEPTH-1];
  logic [DATA_W-1:0] load_rs_in_v1[0:RS_DEPTH-1];
  logic [TAG_W-1:0] load_rs_in_q1[0:RS_DEPTH-1];
  logic load_rs_in_r1[0:RS_DEPTH-1];
  logic [DATA_W-1:0] load_rs_in_v2[0:RS_DEPTH-1];
  logic [TAG_W-1:0] load_rs_in_q2[0:RS_DEPTH-1];
  logic load_rs_in_r2[0:RS_DEPTH-1];
  logic [ST_W-1:0] load_rs_in_st_id[0:RS_DEPTH-1];

  decode_pkg::uop_t store_rs_in_op[0:RS_DEPTH-1];
  logic [TAG_W-1:0] store_rs_in_dst[0:RS_DEPTH-1];
  logic [DATA_W-1:0] store_rs_in_v1[0:RS_DEPTH-1];
  logic [TAG_W-1:0] store_rs_in_q1[0:RS_DEPTH-1];
  logic store_rs_in_r1[0:RS_DEPTH-1];
  logic [DATA_W-1:0] store_rs_in_v2[0:RS_DEPTH-1];
  logic [TAG_W-1:0] store_rs_in_q2[0:RS_DEPTH-1];
  logic store_rs_in_r2[0:RS_DEPTH-1];
  logic [ST_W-1:0] store_rs_in_st_id[0:RS_DEPTH-1];

  rs_allocator #(.Cfg(Cfg)) u_load_alloc (
      .rs_busy    (load_rs_busy_wires),
      .instr_valid(load_dispatch_valid),
      .entry_wen  (load_alloc_wen),
      .idx_map    (load_routing_idx),
      .full_stall (load_full_stall_raw)
  );

  rs_allocator #(.Cfg(Cfg)) u_store_alloc (
      .rs_busy    (store_rs_busy_wires),
      .instr_valid(store_dispatch_valid),
      .entry_wen  (store_alloc_wen),
      .idx_map    (store_routing_idx),
      .full_stall (store_full_stall_raw)
  );

  always_comb begin
    load_dispatch_valid = '0;
    store_dispatch_valid = '0;
    load_dispatch_count = '0;
    store_dispatch_count = '0;
    for (int i = 0; i < 4; i++) begin
      load_dispatch_lane[i] = '0;
      store_dispatch_lane[i] = '0;
    end

    for (int i = 0; i < 4; i++) begin
      if (dispatch_valid[i]) begin
        if (is_plain_load_uop(dispatch_op[i])) begin
          load_dispatch_valid[load_dispatch_count] = 1'b1;
          load_dispatch_lane[load_dispatch_count] = i[1:0];
          load_dispatch_count = load_dispatch_count + 3'd1;
        end else begin
          store_dispatch_valid[store_dispatch_count] = 1'b1;
          store_dispatch_lane[store_dispatch_count] = i[1:0];
          store_dispatch_count = store_dispatch_count + 3'd1;
        end
      end
    end
  end

  always_comb begin
    dbg_dispatch_load_inc_w = '0;
    dbg_dispatch_store_inc_w = '0;
    dbg_dispatch_both_inc_w = '0;
    dbg_dispatch_other_inc_w = '0;
    dbg_dispatch_load_block_full_inc_w = '0;
    dbg_dispatch_store_block_full_inc_w = '0;
    dbg_dispatch_both_block_full_inc_w = '0;
    dbg_dispatch_other_block_full_inc_w = '0;

    for (int i = 0; i < 4; i++) begin
      if (dispatch_valid[i]) begin
        if (dispatch_op[i].is_load && !dispatch_op[i].is_store) begin
          dbg_dispatch_load_inc_w = dbg_dispatch_load_inc_w + 3'd1;
          if (full_stall) dbg_dispatch_load_block_full_inc_w =
              dbg_dispatch_load_block_full_inc_w + 3'd1;
        end else if (dispatch_op[i].is_store && !dispatch_op[i].is_load) begin
          dbg_dispatch_store_inc_w = dbg_dispatch_store_inc_w + 3'd1;
          if (full_stall) dbg_dispatch_store_block_full_inc_w =
              dbg_dispatch_store_block_full_inc_w + 3'd1;
        end else if (dispatch_op[i].is_load && dispatch_op[i].is_store) begin
          dbg_dispatch_both_inc_w = dbg_dispatch_both_inc_w + 3'd1;
          if (full_stall) dbg_dispatch_both_block_full_inc_w =
              dbg_dispatch_both_block_full_inc_w + 3'd1;
        end else begin
          dbg_dispatch_other_inc_w = dbg_dispatch_other_inc_w + 3'd1;
          if (full_stall) dbg_dispatch_other_block_full_inc_w =
              dbg_dispatch_other_block_full_inc_w + 3'd1;
        end
      end
    end
  end

  always_comb begin
    for (int k = 0; k < RS_DEPTH; k++) begin
      load_rs_in_op[k]    = 0;
      load_rs_in_dst[k]   = 0;
      load_rs_in_v1[k]    = 0;
      load_rs_in_q1[k]    = 0;
      load_rs_in_r1[k]    = 0;
      load_rs_in_v2[k]    = 0;
      load_rs_in_q2[k]    = 0;
      load_rs_in_r2[k]    = 0;
      load_rs_in_st_id[k] = 0;
      store_rs_in_op[k]    = 0;
      store_rs_in_dst[k]   = 0;
      store_rs_in_v1[k]    = 0;
      store_rs_in_q1[k]    = 0;
      store_rs_in_r1[k]    = 0;
      store_rs_in_v2[k]    = 0;
      store_rs_in_q2[k]    = 0;
      store_rs_in_r2[k]    = 0;
      store_rs_in_st_id[k] = 0;
    end

    for (int p = 0; p < 4; p++) begin
      if (load_dispatch_valid[p]) begin
        int unsigned src;
        src = load_dispatch_lane[p];
        load_rs_in_op[load_routing_idx[p]]    = dispatch_op[src];
        load_rs_in_dst[load_routing_idx[p]]   = dispatch_dst[src];
        load_rs_in_v1[load_routing_idx[p]]    = dispatch_v1[src];
        load_rs_in_q1[load_routing_idx[p]]    = dispatch_q1[src];
        load_rs_in_r1[load_routing_idx[p]]    = dispatch_r1[src];
        load_rs_in_v2[load_routing_idx[p]]    = dispatch_v2[src];
        load_rs_in_q2[load_routing_idx[p]]    = dispatch_q2[src];
        load_rs_in_r2[load_routing_idx[p]]    = dispatch_r2[src];
        load_rs_in_st_id[load_routing_idx[p]] = dispatch_st_id[src];
      end
      if (store_dispatch_valid[p]) begin
        int unsigned src;
        src = store_dispatch_lane[p];
        store_rs_in_op[store_routing_idx[p]]    = dispatch_op[src];
        store_rs_in_dst[store_routing_idx[p]]   = dispatch_dst[src];
        store_rs_in_v1[store_routing_idx[p]]    = dispatch_v1[src];
        store_rs_in_q1[store_routing_idx[p]]    = dispatch_q1[src];
        store_rs_in_r1[store_routing_idx[p]]    = dispatch_r1[src];
        store_rs_in_v2[store_routing_idx[p]]    = dispatch_v2[src];
        store_rs_in_q2[store_routing_idx[p]]    = dispatch_q2[src];
        store_rs_in_r2[store_routing_idx[p]]    = dispatch_r2[src];
        store_rs_in_st_id[store_routing_idx[p]] = dispatch_st_id[src];
      end
    end
  end

  assign load_sel_idx_0 = issue_rs_is_load_raw[0] ? issue_rs_idx_raw[0] : '0;
  assign load_sel_idx_1 = issue_rs_is_load_raw[1] ? issue_rs_idx_raw[1] : '0;
  assign store_sel_idx_0 = issue_rs_is_load_raw[0] ? '0 : issue_rs_idx_raw[0];
  assign store_sel_idx_1 = issue_rs_is_load_raw[1] ? '0 : issue_rs_idx_raw[1];

  reservation_station_load #(
      .Cfg   (Cfg),
      .DATA_W(DATA_W),
      .TAG_W (TAG_W),
      .CDB_W (CDB_W),
      .ST_W  (ST_W)
  ) u_load_rs (
      .clk  (clk),
      .rst_n(rst_n),
      .flush_i(flush_i),
      .rob_head_i(rob_head_i),
      .spec_low_addr_block_en_i(spec_low_addr_block_en_i),
      .entry_wen (load_alloc_wen),
      .in_op     (load_rs_in_op),
      .in_dst_tag(load_rs_in_dst),
      .in_v1     (load_rs_in_v1),
      .in_q1     (load_rs_in_q1),
      .in_r1     (load_rs_in_r1),
      .in_v2     (load_rs_in_v2),
      .in_q2     (load_rs_in_q2),
      .in_r2     (load_rs_in_r2),
      .in_st_id  (load_rs_in_st_id),
      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_value(cdb_val),
      .store_busy_i(store_rs_store_busy),
      .store_op_i(store_rs_store_op),
      .store_dst_tag_i(store_rs_store_dst_tag),
      .store_v1_i(store_rs_store_v1),
      .store_r1_i(store_rs_store_r1),
      .store_v2_i(store_rs_store_v2),
      .store_r2_i(store_rs_store_r2),
      .stq_oldest_store_valid_i(stq_order_oldest_store_valid_i),
      .stq_oldest_store_rob_idx_i(stq_order_oldest_store_rob_idx_i),
      .stq_has_committed_store_i(stq_order_has_committed_store_i),
      .ready_mask (load_rs_ready_wires),
      .issue_grant(load_grant_mask_wires),
      .load_order_query_safe_i(load_rs_query_chosen ? stq_order_query_safe_i : 1'b0),
      .load_order_query_forward_full_i(load_rs_query_chosen ? stq_order_query_forward_full_i : 1'b0),
      .load_order_query_valid_o(load_rs_load_order_query_valid),
      .load_order_query_addr_o(load_rs_load_order_query_addr),
      .load_order_query_be_o(load_rs_load_order_query_be),
      .load_order_query_rob_idx_o(load_rs_load_order_query_rob_idx),
      .busy_vector(load_rs_busy_wires),
      .sel_idx_0(load_sel_idx_0),
      .sel_idx_1(load_sel_idx_1),
      .out_op_0(load_out_op_0),
      .out_op_1(load_out_op_1),
      .out_v1_0(load_out_v1_0),
      .out_v1_1(load_out_v1_1),
      .out_v2_0(load_out_v2_0),
      .out_v2_1(load_out_v2_1),
      .out_dst_tag_0(load_out_dst_0),
      .out_dst_tag_1(load_out_dst_1),
      .out_st_id_0(load_out_st_id_0),
      .out_st_id_1(load_out_st_id_1),
      .dst_tag_o(load_rs_dst_tag),
      .plain_load_mask_o(load_rs_plain_load_wires)
  );

  reservation_station_lsu #(
      .Cfg   (Cfg),
      .DATA_W(DATA_W),
      .TAG_W (TAG_W),
      .CDB_W (CDB_W),
      .ST_W  (ST_W)
  ) u_rs (
      .clk  (clk),
      .rst_n(rst_n),
      .flush_i(flush_i),
      .rob_head_i(rob_head_i),
      .spec_low_addr_block_en_i(spec_low_addr_block_en_i),
      .entry_wen (store_alloc_wen),
      .in_op     (store_rs_in_op),
      .in_dst_tag(store_rs_in_dst),
      .in_v1     (store_rs_in_v1),
      .in_q1     (store_rs_in_q1),
      .in_r1     (store_rs_in_r1),
      .in_v2     (store_rs_in_v2),
      .in_q2     (store_rs_in_q2),
      .in_r2     (store_rs_in_r2),
      .in_st_id  (store_rs_in_st_id),
      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_value(cdb_val),
      .busy_vector(store_rs_busy_wires),
      .ready_mask (store_rs_ready_wires),
      .issue_grant(store_grant_mask_wires),
      .sta_fire_i(rs_sta_fire),
      .sta_valid_o(rs_sta_valid),
      .sta_uop_o(rs_sta_uop),
      .sta_v1_o(rs_sta_v1),
      .sta_dst_tag_o(rs_sta_dst),
      .sta_st_id_o(rs_sta_st_id),
      .std_fire_i(rs_std_fire),
      .std_valid_o(rs_std_valid),
      .std_data_o(rs_std_data),
      .std_st_id_o(rs_std_st_id),
      .load_order_query_safe_i((!load_rs_query_chosen) ? stq_order_query_safe_i : 1'b0),
      .load_order_query_forward_full_i((!load_rs_query_chosen) ? stq_order_query_forward_full_i : 1'b0),
      .load_order_query_valid_o(store_rs_load_order_query_valid),
      .load_order_query_addr_o(store_rs_load_order_query_addr),
      .load_order_query_be_o(store_rs_load_order_query_be),
      .load_order_query_rob_idx_o(store_rs_load_order_query_rob_idx),
      .sel_idx_0(store_sel_idx_0),
      .sel_idx_1(store_sel_idx_1),
      .out_op_0(store_out_op_0),
      .out_op_1(store_out_op_1),
      .out_v1_0(store_out_v1_0),
      .out_v1_1(store_out_v1_1),
      .out_v2_0(store_out_v2_0),
      .out_v2_1(store_out_v2_1),
      .out_dst_tag_0(store_out_dst_0),
      .out_dst_tag_1(store_out_dst_1),
      .out_st_id_0(store_out_st_id_0),
      .out_st_id_1(store_out_st_id_1),
      .dst_tag_o(store_rs_dst_tag),
      .plain_load_mask_o(store_rs_plain_load_wires),
      .ready_store_mask_o(store_rs_ready_store_wires),
      .blocking_ready_store_mask_o(store_rs_blocking_ready_store_wires),
      .store_busy_o(store_rs_store_busy),
      .store_op_o(store_rs_store_op),
      .store_dst_tag_o(store_rs_store_dst_tag),
      .store_v1_o(store_rs_store_v1),
      .store_r1_o(store_rs_store_r1),
      .store_v2_o(store_rs_store_v2),
      .store_r2_o(store_rs_store_r2)
  );

  always_comb begin
    if (issue_rs_is_load_raw[0]) begin
      issue_uop_0 = load_out_op_0;
      issue_v1_0 = load_out_v1_0;
      issue_v2_0 = load_out_v2_0;
      issue_dst_0 = load_out_dst_0;
      issue_st_id_0 = load_out_st_id_0;
    end else begin
      issue_uop_0 = store_out_op_0;
      issue_v1_0 = store_out_v1_0;
      issue_v2_0 = store_out_v2_0;
      issue_dst_0 = store_out_dst_0;
      issue_st_id_0 = store_out_st_id_0;
    end

    if (issue_rs_is_load_raw[1]) begin
      issue_uop_1 = load_out_op_1;
      issue_v1_1 = load_out_v1_1;
      issue_v2_1 = load_out_v2_1;
      issue_dst_1 = load_out_dst_1;
      issue_st_id_1 = load_out_st_id_1;
    end else begin
      issue_uop_1 = store_out_op_1;
      issue_v1_1 = store_out_v1_1;
      issue_v2_1 = store_out_v2_1;
      issue_dst_1 = store_out_dst_1;
      issue_st_id_1 = store_out_st_id_1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_sta_early_fire_q <= '0;
      dbg_std_early_fire_q <= '0;
      dbg_dispatch_load_q <= '0;
      dbg_dispatch_store_q <= '0;
      dbg_dispatch_both_q <= '0;
      dbg_dispatch_other_q <= '0;
      dbg_dispatch_load_block_full_q <= '0;
      dbg_dispatch_store_block_full_q <= '0;
      dbg_dispatch_both_block_full_q <= '0;
      dbg_dispatch_other_block_full_q <= '0;
      dbg_ff_query_active_q <= '0;
      dbg_ff_query_issue_q <= '0;
      dbg_ff_query_not_issue_q <= '0;
      dbg_ff_not_issue_base_block_q <= '0;
      dbg_ff_not_issue_p1_gated_q <= '0;
      dbg_ff_not_issue_low_addr_q <= '0;
      dbg_ff_not_issue_not_selected_q <= '0;
      dbg_ff_not_issue_selected_other_q <= '0;
    end else begin
      if (rs_sta_fire) begin
        dbg_sta_early_fire_q <= dbg_sta_early_fire_q + 64'd1;
      end
      if (rs_std_fire) begin
        dbg_std_early_fire_q <= dbg_std_early_fire_q + 64'd1;
      end
      dbg_dispatch_load_q <= dbg_dispatch_load_q + 64'(dbg_dispatch_load_inc_w);
      dbg_dispatch_store_q <= dbg_dispatch_store_q + 64'(dbg_dispatch_store_inc_w);
      dbg_dispatch_both_q <= dbg_dispatch_both_q + 64'(dbg_dispatch_both_inc_w);
      dbg_dispatch_other_q <= dbg_dispatch_other_q + 64'(dbg_dispatch_other_inc_w);
      dbg_dispatch_load_block_full_q <=
          dbg_dispatch_load_block_full_q + 64'(dbg_dispatch_load_block_full_inc_w);
      dbg_dispatch_store_block_full_q <=
          dbg_dispatch_store_block_full_q + 64'(dbg_dispatch_store_block_full_inc_w);
      dbg_dispatch_both_block_full_q <=
          dbg_dispatch_both_block_full_q + 64'(dbg_dispatch_both_block_full_inc_w);
      dbg_dispatch_other_block_full_q <=
          dbg_dispatch_other_block_full_q + 64'(dbg_dispatch_other_block_full_inc_w);
      if (dbg_ff_query_active) begin
        dbg_ff_query_active_q <= dbg_ff_query_active_q + 64'd1;
        if (dbg_ff_issue) begin
          dbg_ff_query_issue_q <= dbg_ff_query_issue_q + 64'd1;
        end else begin
          dbg_ff_query_not_issue_q <= dbg_ff_query_not_issue_q + 64'd1;
        end
      end
      if (dbg_ff_query_active && !dbg_ff_issue) begin
        if (!issue_base_allow) begin
          dbg_ff_not_issue_base_block_q <= dbg_ff_not_issue_base_block_q + 64'd1;
        end else if (dbg_ff_low_addr) begin
          dbg_ff_not_issue_low_addr_q <= dbg_ff_not_issue_low_addr_q + 64'd1;
        end else if (dbg_ff_p1_gated) begin
          dbg_ff_not_issue_p1_gated_q <= dbg_ff_not_issue_p1_gated_q + 64'd1;
        end else if (dbg_ff_not_selected) begin
          dbg_ff_not_issue_not_selected_q <= dbg_ff_not_issue_not_selected_q + 64'd1;
        end else begin
          dbg_ff_not_issue_selected_other_q <= dbg_ff_not_issue_selected_other_q + 64'd1;
        end
      end
    end
  end

  // Pick port0 by ROB age across load_rs and store/complex RS. If no ready
  // store exists, rematch the two oldest ready plain loads from load_rs.
  always_comb begin
    logic found0;
    logic found1;
    logic found_load0;
    logic found_load1;
    logic found_blocking_store1;
    logic load_load_rematch;
    logic [$clog2(RS_DEPTH)-1:0] pick_idx0;
    logic [$clog2(RS_DEPTH)-1:0] pick_idx1;
    logic pick_is_load0;
    logic pick_is_load1;
    logic [$clog2(RS_DEPTH)-1:0] load_idx0;
    logic [$clog2(RS_DEPTH)-1:0] load_idx1;
    logic [$clog2(RS_DEPTH)-1:0] blocking_store_idx1;
    logic [TAG_W-1:0] best_age0;
    logic [TAG_W-1:0] best_age1;
    logic [TAG_W-1:0] best_load_age0;
    logic [TAG_W-1:0] best_load_age1;
    logic [TAG_W-1:0] best_blocking_store_age1;
    logic [TAG_W-1:0] age;

    issue_valid_raw[0] = 1'b0;
    issue_valid_raw[1] = 1'b0;
    issue_rs_idx_raw[0] = '0;
    issue_rs_idx_raw[1] = '0;
    issue_rs_is_load_raw[0] = 1'b0;
    issue_rs_is_load_raw[1] = 1'b0;
    pick_idx0 = '0;
    pick_idx1 = '0;
    pick_is_load0 = 1'b0;
    pick_is_load1 = 1'b0;
    load_idx0 = '0;
    load_idx1 = '0;
    blocking_store_idx1 = '0;
    found0 = 1'b0;
    found1 = 1'b0;
    found_load0 = 1'b0;
    found_load1 = 1'b0;
    found_blocking_store1 = 1'b0;
    load_load_rematch = 1'b0;
    best_age0 = {TAG_W{1'b1}};
    best_age1 = {TAG_W{1'b1}};
    best_load_age0 = {TAG_W{1'b1}};
    best_load_age1 = {TAG_W{1'b1}};
    best_blocking_store_age1 = {TAG_W{1'b1}};
    age = '0;

    for (int i = 0; i < RS_DEPTH; i++) begin
      age = rob_age(store_rs_dst_tag[i], rob_head_i);
      if (store_rs_ready_wires[i] && (!found0 || (age < best_age0))) begin
        found0 = 1'b1;
        best_age0 = age;
        pick_idx0 = i[$clog2(RS_DEPTH)-1:0];
        pick_is_load0 = 1'b0;
      end
      age = rob_age(load_rs_dst_tag[i], rob_head_i);
      if (load_rs_ready_wires[i] && (!found0 || (age < best_age0))) begin
        found0 = 1'b1;
        best_age0 = age;
        pick_idx0 = i[$clog2(RS_DEPTH)-1:0];
        pick_is_load0 = 1'b1;
      end

      if (load_rs_ready_wires[i] && load_rs_plain_load_wires[i]) begin
        if (!found_load0 || (age < best_load_age0)) begin
          found_load1 = found_load0;
          best_load_age1 = best_load_age0;
          load_idx1 = load_idx0;
          found_load0 = 1'b1;
          best_load_age0 = age;
          load_idx0 = i[$clog2(RS_DEPTH)-1:0];
        end else if (!found_load1 || (age < best_load_age1)) begin
          found_load1 = 1'b1;
          best_load_age1 = age;
          load_idx1 = i[$clog2(RS_DEPTH)-1:0];
        end
      end
    end

    load_load_rematch = found_load0 && found_load1 && !(|store_rs_ready_store_wires);

    if (load_load_rematch) begin
      found0 = 1'b1;
      found1 = 1'b1;
      pick_idx0 = load_idx0;
      pick_idx1 = load_idx1;
      pick_is_load0 = 1'b1;
      pick_is_load1 = 1'b1;
    end else begin
      for (int i = 0; i < RS_DEPTH; i++) begin
        age = rob_age(store_rs_dst_tag[i], rob_head_i);
        if (store_rs_ready_wires[i] && store_rs_blocking_ready_store_wires[i] &&
            !(found0 && !pick_is_load0 && (i[$clog2(RS_DEPTH)-1:0] == pick_idx0)) &&
            (!found_blocking_store1 || (age < best_blocking_store_age1))) begin
          found_blocking_store1 = 1'b1;
          best_blocking_store_age1 = age;
          blocking_store_idx1 = i[$clog2(RS_DEPTH)-1:0];
        end
      end

      if (found_blocking_store1) begin
        found1 = 1'b1;
        pick_idx1 = blocking_store_idx1;
        pick_is_load1 = 1'b0;
      end else begin
        for (int i = 0; i < RS_DEPTH; i++) begin
          age = rob_age(load_rs_dst_tag[i], rob_head_i);
          if (load_rs_ready_wires[i] && load_rs_plain_load_wires[i] &&
              !(found0 && pick_is_load0 && (i[$clog2(RS_DEPTH)-1:0] == pick_idx0)) &&
              (!found1 || (age < best_age1))) begin
            found1 = 1'b1;
            best_age1 = age;
            pick_idx1 = i[$clog2(RS_DEPTH)-1:0];
            pick_is_load1 = 1'b1;
          end
        end

        if (!found1) begin
          for (int i = 0; i < RS_DEPTH; i++) begin
            age = rob_age(store_rs_dst_tag[i], rob_head_i);
            if (store_rs_ready_wires[i] &&
                !(found0 && !pick_is_load0 && (i[$clog2(RS_DEPTH)-1:0] == pick_idx0)) &&
                (!found1 || (age < best_age1))) begin
              found1 = 1'b1;
              best_age1 = age;
              pick_idx1 = i[$clog2(RS_DEPTH)-1:0];
              pick_is_load1 = 1'b0;
            end
            age = rob_age(load_rs_dst_tag[i], rob_head_i);
            if (load_rs_ready_wires[i] &&
                !(found0 && pick_is_load0 && (i[$clog2(RS_DEPTH)-1:0] == pick_idx0)) &&
                (!found1 || (age < best_age1))) begin
              found1 = 1'b1;
              best_age1 = age;
              pick_idx1 = i[$clog2(RS_DEPTH)-1:0];
              pick_is_load1 = 1'b1;
            end
          end
        end
      end
    end

    issue_valid_raw[0] = found0;
    issue_valid_raw[1] = found1;
    issue_rs_idx_raw[0] = pick_idx0;
    issue_rs_idx_raw[1] = pick_idx1;
    issue_rs_is_load_raw[0] = pick_is_load0;
    issue_rs_is_load_raw[1] = pick_is_load1;
  end

  // Report a conservative shared budget to the existing backend dispatcher.
  always_comb begin
    logic [$clog2(RS_DEPTH+1)-1:0] load_free_count;
    logic [$clog2(RS_DEPTH+1)-1:0] store_free_count;
    load_free_count = '0;
    store_free_count = '0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (!load_rs_busy_wires[i]) load_free_count++;
      if (!store_rs_busy_wires[i]) store_free_count++;
    end
    free_count_o = (load_free_count < store_free_count) ? load_free_count : store_free_count;
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk or negedge rst_n) begin
    logic watch_pc;
    logic watch_issue_slots;
    logic [31:0] issue_trace_inc;
    logic [31:0] block_trace_inc;
    logic [31:0] stall_trace_inc;
    watch_pc = watch_lsu_pc(issue_uop_0.pc) || watch_lsu_pc(issue_uop_1.pc);
    watch_issue_slots = watch_pc;
    issue_trace_inc = '0;
    block_trace_inc = '0;
    stall_trace_inc = '0;
    if (!rst_n) begin
      lsu_issue_trace_cnt_q <= '0;
      lsu_block_trace_cnt_q <= '0;
      lsu_stall_trace_cnt_q <= '0;
    end else if (lsu_trace_en_q) begin
      if (lsu_en[0] && watch_lsu_pc(issue_uop_0.pc) &&
          ((lsu_issue_trace_cnt_q + issue_trace_inc) < LSU_ISSUE_TRACE_BUDGET)) begin
        $display("[issue-lsu] slot=0 pc=%h rs1=%h rs2=%h imm=%h lsu_op=%0d is_ld=%0d is_st=%0d dst=%0d sb=%0d ftq=%0d epoch=%0d rvc=%0d flush=%0d fu_ready=%0d issue0_raw=%0d issue1_raw=%0d pick0=%0d pick1=%0d",
                 issue_uop_0.pc, lsu_v1[0], lsu_v2[0], issue_uop_0.imm, issue_uop_0.lsu_op, issue_uop_0.is_load, issue_uop_0.is_store,
                 lsu_dst[0], lsu_stq_id[0], issue_uop_0.ftq_id, issue_uop_0.fetch_epoch, issue_uop_0.is_rvc, flush_i, fu_ready_i,
                 issue_valid_raw[0], issue_valid_raw[1], issue_pick_0, issue_pick_1);
        issue_trace_inc = issue_trace_inc + 32'd1;
        if (flush_i &&
            ((lsu_issue_trace_cnt_q + issue_trace_inc) < LSU_ISSUE_TRACE_BUDGET)) begin
          $display("[issue-lsu-on-flush] slot=0 pc=%h rs1=%h rs2=%h dst=%0d sb=%0d ftq=%0d epoch=%0d fu_ready=%0d issue0_raw=%0d issue1_raw=%0d",
                   issue_uop_0.pc, lsu_v1[0], lsu_v2[0], lsu_dst[0], lsu_stq_id[0], issue_uop_0.ftq_id, issue_uop_0.fetch_epoch, fu_ready_i,
                   issue_valid_raw[0], issue_valid_raw[1]);
          issue_trace_inc = issue_trace_inc + 32'd1;
        end
      end
      if (lsu_en[1] && watch_lsu_pc(issue_uop_1.pc) &&
          ((lsu_issue_trace_cnt_q + issue_trace_inc) < LSU_ISSUE_TRACE_BUDGET)) begin
        $display("[issue-lsu] slot=1 pc=%h rs1=%h rs2=%h imm=%h lsu_op=%0d is_ld=%0d is_st=%0d dst=%0d sb=%0d ftq=%0d epoch=%0d rvc=%0d flush=%0d fu_ready=%0d issue0_raw=%0d issue1_raw=%0d pick0=%0d pick1=%0d",
                 issue_uop_1.pc, lsu_v1[1], lsu_v2[1], issue_uop_1.imm, issue_uop_1.lsu_op, issue_uop_1.is_load, issue_uop_1.is_store,
                 lsu_dst[1], lsu_stq_id[1], issue_uop_1.ftq_id, issue_uop_1.fetch_epoch, issue_uop_1.is_rvc, flush_i, fu_ready_i,
                 issue_valid_raw[0], issue_valid_raw[1], issue_pick_0, issue_pick_1);
        issue_trace_inc = issue_trace_inc + 32'd1;
        if (flush_i &&
            ((lsu_issue_trace_cnt_q + issue_trace_inc) < LSU_ISSUE_TRACE_BUDGET)) begin
          $display("[issue-lsu-on-flush] slot=1 pc=%h rs1=%h rs2=%h dst=%0d sb=%0d ftq=%0d epoch=%0d fu_ready=%0d issue0_raw=%0d issue1_raw=%0d",
                   issue_uop_1.pc, lsu_v1[1], lsu_v2[1], lsu_dst[1], lsu_stq_id[1], issue_uop_1.ftq_id, issue_uop_1.fetch_epoch, fu_ready_i,
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
