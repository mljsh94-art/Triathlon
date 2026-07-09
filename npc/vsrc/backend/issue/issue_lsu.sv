// vsrc/backend/issue/issue_lsu.sv
// Thin wrapper: instantiates issue_load + issue_store, performs final
// arbitration between load/store candidates, output mux, grant mask
// distribution, STA/STD fire, STQ order query arbitration, and debug.
// External interface is UNCHANGED from pre-split version.
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

    // Stage 6A-2: independent ordinary-store complete sideband. This is a
    // consuming path for ready plain stores and does not occupy lsu_en[0:1].
    input  wire                           st_issue_ready_i,
    output wire                           st_issue_valid_o,
    output decode_pkg::uop_t              st_issue_uop_o,
    output wire              [DATA_W-1:0] st_issue_v1_o,
    output wire              [DATA_W-1:0] st_issue_v2_o,
    output wire              [ TAG_W-1:0] st_issue_dst_o,
    output wire              [  ST_W-1:0] st_issue_stq_id_o,

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
    input  wire                           stq_order_has_committed_store_i,

    // SV32 paging active (satp.MODE && !M-mode): when set, plain stores need
    // a TLB walk that the sideband path cannot provide — they must go through
    // the legacy (main) path which has MMU walk support.
    input  wire                           paging_active_i
);
  wire full_stall;
  assign issue_ready = ~full_stall;

  localparam int ISSUE_WIDTH = 2;

  function automatic logic is_spec_low_addr(input logic [DATA_W-1:0] addr);
    begin
      is_spec_low_addr = ((addr[DATA_W-1:12] == '0) || (&addr[DATA_W-1:12]));
    end
  endfunction

  // =========================================================
  // Sub-module wires
  // =========================================================

  // --- issue_load outputs ---
  wire [RS_DEPTH-1:0] load_rs_busy_wires;
  wire [RS_DEPTH-1:0] load_rs_ready_wires;
  wire [RS_DEPTH-1:0] load_rs_plain_load_wires;
  wire                load_full_stall_raw;
  wire [2:0]          load_dispatch_count;
  decode_pkg::uop_t   load_out_op_0, load_out_op_1;
  wire [DATA_W-1:0]   load_out_v1_0, load_out_v1_1;
  wire [DATA_W-1:0]   load_out_v2_0, load_out_v2_1;
  wire [TAG_W-1:0]    load_out_dst_0, load_out_dst_1;
  wire [ST_W-1:0]     load_out_st_id_0, load_out_st_id_1;
  logic [TAG_W-1:0]   load_rs_dst_tag[0:RS_DEPTH-1];
  wire                load_rs_load_order_query_valid;
  wire [DATA_W-1:0]   load_rs_load_order_query_addr;
  wire [DATA_W/8-1:0] load_rs_load_order_query_be;
  wire [TAG_W-1:0]    load_rs_load_order_query_rob_idx;
  wire                found_load0, found_load1;
  wire [$clog2(RS_DEPTH)-1:0] load_idx0, load_idx1;
  wire [TAG_W-1:0]    best_load_age0, best_load_age1;

  // --- issue_store outputs ---
  wire [RS_DEPTH-1:0] store_rs_busy_wires;
  wire [RS_DEPTH-1:0] store_rs_ready_wires;
  wire [RS_DEPTH-1:0] store_rs_plain_load_wires;
  wire [RS_DEPTH-1:0] store_rs_ready_store_wires;
  wire [RS_DEPTH-1:0] store_rs_blocking_ready_store_wires;
  wire                store_full_stall_raw;
  wire [2:0]          store_dispatch_count;
  decode_pkg::uop_t   store_out_op_0, store_out_op_1;
  wire [DATA_W-1:0]   store_out_v1_0, store_out_v1_1;
  wire [DATA_W-1:0]   store_out_v2_0, store_out_v2_1;
  wire [TAG_W-1:0]    store_out_dst_0, store_out_dst_1;
  wire [ST_W-1:0]     store_out_st_id_0, store_out_st_id_1;
  logic [TAG_W-1:0]   store_rs_dst_tag[0:RS_DEPTH-1];
  decode_pkg::uop_t   store_rs_store_op[0:RS_DEPTH-1];
  wire [RS_DEPTH-1:0] store_rs_store_busy;
  wire [TAG_W-1:0]    store_rs_store_dst_tag[0:RS_DEPTH-1];
  wire [DATA_W-1:0]   store_rs_store_v1[0:RS_DEPTH-1];
  wire                store_rs_store_r1[0:RS_DEPTH-1];
  wire [DATA_W-1:0]   store_rs_store_v2[0:RS_DEPTH-1];
  wire                store_rs_store_r2[0:RS_DEPTH-1];
  wire [ST_W-1:0]     store_rs_store_st_id[0:RS_DEPTH-1];
  wire                rs_sta_valid;
  decode_pkg::uop_t   rs_sta_uop;
  wire [DATA_W-1:0]   rs_sta_v1;
  wire [TAG_W-1:0]    rs_sta_dst;
  wire [ST_W-1:0]     rs_sta_st_id;
  wire                rs_std_valid;
  wire [DATA_W-1:0]   rs_std_data;
  wire [ST_W-1:0]     rs_std_st_id;
  wire                store_rs_load_order_query_valid;
  wire [DATA_W-1:0]   store_rs_load_order_query_addr;
  wire [DATA_W/8-1:0] store_rs_load_order_query_be;
  wire [TAG_W-1:0]    store_rs_load_order_query_rob_idx;
  wire                found_st_sideband;
  wire [$clog2(RS_DEPTH)-1:0] st_sideband_idx;
  wire [TAG_W-1:0]    best_st_sideband_age;
  wire                found_legacy0;
  wire [$clog2(RS_DEPTH)-1:0] legacy_idx0;
  wire [TAG_W-1:0]    best_legacy_age0;

  // --- Internal arbitration signals ---
  wire [RS_DEPTH-1:0] rs_busy_wires;
  wire [RS_DEPTH-1:0] rs_ready_wires;
  wire                load_full_stall;
  wire                store_full_stall;

  logic [ISSUE_WIDTH-1:0] issue_valid_raw;
  logic [$clog2(RS_DEPTH)-1:0] issue_rs_idx_raw[0:ISSUE_WIDTH-1];
  logic issue_rs_is_load_raw[0:ISSUE_WIDTH-1];
  logic [DATA_W-1:0] issue_v1_0, issue_v1_1;
  logic [DATA_W-1:0] issue_v2_0, issue_v2_1;
  logic [ TAG_W-1:0] issue_dst_0, issue_dst_1;
  logic [  ST_W-1:0] issue_st_id_0, issue_st_id_1;
  decode_pkg::uop_t issue_uop_0, issue_uop_1;
  wire [DATA_W-1:0] issue_effective_addr_0;
  wire [DATA_W-1:0] issue_effective_addr_1;
  wire              issue_blocked_low_addr_spec_0;
  wire              issue_blocked_low_addr_spec_1;
  wire              issue_pick_0;
  wire              issue_pick_1;
  wire              issue_pick_any;
  wire              issue_fire;
  wire              issue_base_allow;
  logic             st_issue_pick;
  wire              st_issue_fire;
  logic [$clog2(RS_DEPTH)-1:0] st_issue_rs_idx;
  wire              sta_base_allow;
  wire              std_base_allow;
  wire              rs_sta_fire;
  wire              rs_std_fire;

  wire              load_rs_query_chosen;
  wire              rs_load_order_query_valid;
  wire [DATA_W-1:0] rs_load_order_query_addr;
  wire [DATA_W/8-1:0] rs_load_order_query_be;
  wire [TAG_W-1:0]  rs_load_order_query_rob_idx;

  logic [RS_DEPTH-1:0] load_issue_grant_selected;
  logic [RS_DEPTH-1:0] store_issue_grant_selected;
  wire [RS_DEPTH-1:0]  load_grant_mask_wires;
  wire [RS_DEPTH-1:0]  store_grant_mask_wires;

  wire [$clog2(RS_DEPTH)-1:0] load_sel_idx_0;
  wire [$clog2(RS_DEPTH)-1:0] load_sel_idx_1;
  wire [$clog2(RS_DEPTH)-1:0] store_sel_idx_0;
  wire [$clog2(RS_DEPTH)-1:0] store_sel_idx_1;

  // =========================================================
  // Debug signals
  // =========================================================
  logic [63:0] dbg_sta_early_fire_q;
  logic [63:0] dbg_std_early_fire_q;
  logic [63:0] dbg_st_sideband_fire_q;
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

  // =========================================================
  // Stall / busy composites
  // =========================================================
  assign rs_busy_wires = load_rs_busy_wires | store_rs_busy_wires;
  assign rs_ready_wires = load_rs_ready_wires | store_rs_ready_wires;
  assign load_full_stall = (load_dispatch_count != 0) && load_full_stall_raw;
  assign store_full_stall = (store_dispatch_count != 0) && store_full_stall_raw;
  assign full_stall = load_full_stall || store_full_stall;

  // =========================================================
  // Issue pick logic
  // =========================================================
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
  assign rs_sta_fire = sta_base_allow && rs_sta_valid;
  assign rs_std_fire = std_base_allow && rs_std_valid;

  // =========================================================
  // STA / STD outputs
  // =========================================================
  assign sta_valid_o = rs_sta_fire;
  assign sta_uop_o = rs_sta_uop;
  assign sta_addr_o = rs_sta_v1 + rs_sta_uop.imm;
  assign sta_dst_o = rs_sta_dst;
  assign sta_stq_id_o = rs_sta_st_id;
  assign std_valid_o = rs_std_fire;
  assign std_data_o = rs_std_data;
  assign std_stq_id_o = rs_std_st_id;

  // =========================================================
  // STQ order query arbitration
  // =========================================================
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

  // =========================================================
  // LSU output assignments
  // =========================================================
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
  assign st_issue_fire = st_issue_pick && st_issue_ready_i && !flush_i && !mispred_block_i;
  assign st_issue_valid_o = st_issue_fire;
  assign st_issue_uop_o = store_rs_store_op[st_issue_rs_idx];
  assign st_issue_v1_o = store_rs_store_v1[st_issue_rs_idx];
  assign st_issue_v2_o = store_rs_store_v2[st_issue_rs_idx];
  assign st_issue_dst_o = store_rs_store_dst_tag[st_issue_rs_idx];
  assign st_issue_stq_id_o = store_rs_store_st_id[st_issue_rs_idx];

  // =========================================================
  // Debug: forwarded-full query analysis
  // =========================================================
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

  // =========================================================
  // Grant mask computation
  // =========================================================
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
    if (st_issue_fire) begin
      store_issue_grant_selected[st_issue_rs_idx] = 1'b1;
    end
  end

  assign load_grant_mask_wires = issue_base_allow ? load_issue_grant_selected : '0;
  assign store_grant_mask_wires = ((issue_base_allow || st_issue_fire) ? store_issue_grant_selected : '0);

  // =========================================================
  // sel_idx computation (RS read port selection)
  // =========================================================
  assign load_sel_idx_0 = issue_rs_is_load_raw[0] ? issue_rs_idx_raw[0] : '0;
  assign load_sel_idx_1 = issue_rs_is_load_raw[1] ? issue_rs_idx_raw[1] : '0;
  assign store_sel_idx_0 = issue_rs_is_load_raw[0] ? '0 : issue_rs_idx_raw[0];
  assign store_sel_idx_1 = issue_rs_is_load_raw[1] ? '0 : issue_rs_idx_raw[1];

  // =========================================================
  // Sub-module instantiation
  // =========================================================
  issue_load #(
      .Cfg   (Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(DATA_W),
      .TAG_W (TAG_W),
      .CDB_W (CDB_W),
      .ST_W  (ST_W)
  ) u_load_rs (
      .clk(clk),
      .rst_n(rst_n),
      .flush_i(flush_i),
      .rob_head_i(rob_head_i),
      .spec_low_addr_block_en_i(spec_low_addr_block_en_i),
      .dispatch_valid(dispatch_valid),
      .dispatch_op(dispatch_op),
      .dispatch_dst(dispatch_dst),
      .dispatch_v1(dispatch_v1),
      .dispatch_q1(dispatch_q1),
      .dispatch_r1(dispatch_r1),
      .dispatch_v2(dispatch_v2),
      .dispatch_q2(dispatch_q2),
      .dispatch_r2(dispatch_r2),
      .dispatch_st_id(dispatch_st_id),
      .cdb_valid(cdb_valid),
      .cdb_tag(cdb_tag),
      .cdb_val(cdb_val),
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
      .load_order_query_safe_i(load_rs_query_chosen ? stq_order_query_safe_i : 1'b0),
      .load_order_query_forward_full_i(load_rs_query_chosen ? stq_order_query_forward_full_i : 1'b0),
      .issue_grant_i(load_grant_mask_wires),
      .sel_idx_0_i(load_sel_idx_0),
      .sel_idx_1_i(load_sel_idx_1),
      .busy_o(load_rs_busy_wires),
      .ready_o(load_rs_ready_wires),
      .plain_load_o(load_rs_plain_load_wires),
      .full_stall_raw_o(load_full_stall_raw),
      .dispatch_count_o(load_dispatch_count),
      .out_op_0_o(load_out_op_0),
      .out_op_1_o(load_out_op_1),
      .out_v1_0_o(load_out_v1_0),
      .out_v1_1_o(load_out_v1_1),
      .out_v2_0_o(load_out_v2_0),
      .out_v2_1_o(load_out_v2_1),
      .out_dst_0_o(load_out_dst_0),
      .out_dst_1_o(load_out_dst_1),
      .out_st_id_0_o(load_out_st_id_0),
      .out_st_id_1_o(load_out_st_id_1),
      .dst_tag_o(load_rs_dst_tag),
      .load_order_query_valid_o(load_rs_load_order_query_valid),
      .load_order_query_addr_o(load_rs_load_order_query_addr),
      .load_order_query_be_o(load_rs_load_order_query_be),
      .load_order_query_rob_idx_o(load_rs_load_order_query_rob_idx),
      .found_load0_o(found_load0),
      .found_load1_o(found_load1),
      .load_idx0_o(load_idx0),
      .load_idx1_o(load_idx1),
      .best_load_age0_o(best_load_age0),
      .best_load_age1_o(best_load_age1)
  );

  issue_store #(
      .Cfg   (Cfg),
      .RS_DEPTH(RS_DEPTH),
      .DATA_W(DATA_W),
      .TAG_W (TAG_W),
      .CDB_W (CDB_W),
      .ST_W  (ST_W)
  ) u_rs (
      .clk(clk),
      .rst_n(rst_n),
      .flush_i(flush_i),
      .rob_head_i(rob_head_i),
      .spec_low_addr_block_en_i(spec_low_addr_block_en_i),
      .dispatch_valid(dispatch_valid),
      .dispatch_op(dispatch_op),
      .dispatch_dst(dispatch_dst),
      .dispatch_v1(dispatch_v1),
      .dispatch_q1(dispatch_q1),
      .dispatch_r1(dispatch_r1),
      .dispatch_v2(dispatch_v2),
      .dispatch_q2(dispatch_q2),
      .dispatch_r2(dispatch_r2),
      .dispatch_st_id(dispatch_st_id),
      .cdb_valid(cdb_valid),
      .cdb_tag(cdb_tag),
      .cdb_val(cdb_val),
      .issue_grant_i(store_grant_mask_wires),
      .sel_idx_0_i(store_sel_idx_0),
      .sel_idx_1_i(store_sel_idx_1),
      .sta_fire_i(rs_sta_fire),
      .std_fire_i(rs_std_fire),
      .load_order_query_safe_i((!load_rs_query_chosen) ? stq_order_query_safe_i : 1'b0),
      .load_order_query_forward_full_i((!load_rs_query_chosen) ? stq_order_query_forward_full_i : 1'b0),
      .busy_o(store_rs_busy_wires),
      .ready_o(store_rs_ready_wires),
      .plain_load_o(store_rs_plain_load_wires),
      .ready_store_o(store_rs_ready_store_wires),
      .blocking_ready_store_o(store_rs_blocking_ready_store_wires),
      .full_stall_raw_o(store_full_stall_raw),
      .dispatch_count_o(store_dispatch_count),
      .out_op_0_o(store_out_op_0),
      .out_op_1_o(store_out_op_1),
      .out_v1_0_o(store_out_v1_0),
      .out_v1_1_o(store_out_v1_1),
      .out_v2_0_o(store_out_v2_0),
      .out_v2_1_o(store_out_v2_1),
      .out_dst_0_o(store_out_dst_0),
      .out_dst_1_o(store_out_dst_1),
      .out_st_id_0_o(store_out_st_id_0),
      .out_st_id_1_o(store_out_st_id_1),
      .dst_tag_o(store_rs_dst_tag),
      .store_busy_o(store_rs_store_busy),
      .store_op_o(store_rs_store_op),
      .store_dst_tag_o(store_rs_store_dst_tag),
      .store_v1_o(store_rs_store_v1),
      .store_r1_o(store_rs_store_r1),
      .store_v2_o(store_rs_store_v2),
      .store_r2_o(store_rs_store_r2),
      .store_st_id_o(store_rs_store_st_id),
      .sta_valid_o(rs_sta_valid),
      .sta_uop_o(rs_sta_uop),
      .sta_v1_o(rs_sta_v1),
      .sta_dst_o(rs_sta_dst),
      .sta_st_id_o(rs_sta_st_id),
      .std_valid_o(rs_std_valid),
      .std_data_o(rs_std_data),
      .std_st_id_o(rs_std_st_id),
      .load_order_query_valid_o(store_rs_load_order_query_valid),
      .load_order_query_addr_o(store_rs_load_order_query_addr),
      .load_order_query_be_o(store_rs_load_order_query_be),
      .load_order_query_rob_idx_o(store_rs_load_order_query_rob_idx),
      .found_st_sideband_o(found_st_sideband),
      .st_sideband_idx_o(st_sideband_idx),
      .best_st_sideband_age_o(best_st_sideband_age),
      .found_legacy0_o(found_legacy0),
      .legacy_idx0_o(legacy_idx0),
      .best_legacy_age0_o(best_legacy_age0),
      .paging_active_i(paging_active_i)
  );

  // =========================================================
  // Output mux: select between load/store RS read ports
  // =========================================================
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

  // =========================================================
  // Final arbitration: combine load and store candidates
  // =========================================================
  // Sideband is "effective" only when paging is OFF (M-mode). When paging is
  // active, plain stores need a TLB walk that the sideband path cannot provide;
  // they must fall through to the legacy (main) path which has MMU support.
  wire st_sideband_effective = found_st_sideband && !paging_active_i;

  always_comb begin
    issue_valid_raw[0] = 1'b0;
    issue_valid_raw[1] = 1'b0;
    issue_rs_idx_raw[0] = '0;
    issue_rs_idx_raw[1] = '0;
    issue_rs_is_load_raw[0] = 1'b0;
    issue_rs_is_load_raw[1] = 1'b0;
    st_issue_rs_idx = st_sideband_idx;

    if (found_legacy0 && !st_sideband_effective && (!found_load0 || (best_legacy_age0 < best_load_age0))) begin
      issue_valid_raw[0] = 1'b1;
      issue_rs_idx_raw[0] = legacy_idx0;
      issue_rs_is_load_raw[0] = 1'b0;
    end else if (found_load0) begin
      issue_valid_raw[0] = 1'b1;
      issue_rs_idx_raw[0] = load_idx0;
      issue_rs_is_load_raw[0] = 1'b1;
      if (found_load1) begin
        issue_valid_raw[1] = 1'b1;
        issue_rs_idx_raw[1] = load_idx1;
        issue_rs_is_load_raw[1] = 1'b1;
      end
    end else if (found_legacy0 && !st_sideband_effective) begin
      issue_valid_raw[0] = 1'b1;
      issue_rs_idx_raw[0] = legacy_idx0;
      issue_rs_is_load_raw[0] = 1'b0;
    end

    st_issue_pick = st_sideband_effective;
  end

  // =========================================================
  // Free count (conservative: min of load and store)
  // =========================================================
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

  // =========================================================
  // Debug counters
  // =========================================================
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_sta_early_fire_q <= '0;
      dbg_std_early_fire_q <= '0;
      dbg_st_sideband_fire_q <= '0;
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
      if (st_issue_fire) begin
        dbg_st_sideband_fire_q <= dbg_st_sideband_fire_q + 64'd1;
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

  // =========================================================
  // Debug trace (synthesis excluded)
  // =========================================================
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
