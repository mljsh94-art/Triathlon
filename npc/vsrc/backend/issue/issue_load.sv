// vsrc/backend/issue/issue_load.sv
// Load reservation station, allocator, crossbar, and selection logic.
// Extracted from issue_lsu.sv — pure refactoring, no logic changes.
import decode_pkg::*;

module issue_load #(
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
    input wire [TAG_W-1:0] rob_head_i,
    input wire             spec_low_addr_block_en_i,

    // 4-wide dispatch (module internally classifies plain loads)
    input wire                   [       3:0] dispatch_valid,
    input wire decode_pkg::uop_t              dispatch_op   [0:3],
    input wire                   [ TAG_W-1:0] dispatch_dst  [0:3],
    input wire                   [DATA_W-1:0] dispatch_v1   [0:3],
    input wire                   [ TAG_W-1:0] dispatch_q1   [0:3],
    input wire                                dispatch_r1   [0:3],
    input wire                   [DATA_W-1:0] dispatch_v2   [0:3],
    input wire                   [ TAG_W-1:0] dispatch_q2   [0:3],
    input wire                                dispatch_r2   [0:3],
    input wire                   [  ST_W-1:0] dispatch_st_id[0:3],

    // CDB
    input wire [ CDB_W-1:0] cdb_valid,
    input wire [ TAG_W-1:0] cdb_tag  [0:CDB_W-1],
    input wire [DATA_W-1:0] cdb_val  [0:CDB_W-1],

    // Store RS state (for load ordering in reservation_station_load)
    input wire [RS_DEPTH-1:0]          store_busy_i,
    input wire decode_pkg::uop_t       store_op_i     [0:RS_DEPTH-1],
    input wire [ TAG_W-1:0]            store_dst_tag_i[0:RS_DEPTH-1],
    input wire [DATA_W-1:0]            store_v1_i     [0:RS_DEPTH-1],
    input wire                         store_r1_i     [0:RS_DEPTH-1],
    input wire [DATA_W-1:0]            store_v2_i     [0:RS_DEPTH-1],
    input wire                         store_r2_i     [0:RS_DEPTH-1],

    // STQ ordering
    input wire             stq_oldest_store_valid_i,
    input wire [TAG_W-1:0] stq_oldest_store_rob_idx_i,
    input wire             stq_has_committed_store_i,
    input wire             load_order_query_safe_i,
    input wire             load_order_query_forward_full_i,

    // Grant mask (from wrapper after final arbitration)
    input wire [RS_DEPTH-1:0] issue_grant_i,

    // RS read port index (from wrapper's final arbitration)
    input wire [$clog2(RS_DEPTH)-1:0] sel_idx_0_i,
    input wire [$clog2(RS_DEPTH)-1:0] sel_idx_1_i,

    // --- Outputs ---
    output wire [RS_DEPTH-1:0] busy_o,
    output wire [RS_DEPTH-1:0] ready_o,
    output wire [RS_DEPTH-1:0] plain_load_o,
    output wire                full_stall_raw_o,
    output logic [2:0]         dispatch_count_o,

    // RS read outputs
    output decode_pkg::uop_t   out_op_0_o,
    output decode_pkg::uop_t   out_op_1_o,
    output wire [DATA_W-1:0]   out_v1_0_o,
    output wire [DATA_W-1:0]   out_v1_1_o,
    output wire [DATA_W-1:0]   out_v2_0_o,
    output wire [DATA_W-1:0]   out_v2_1_o,
    output wire [ TAG_W-1:0]   out_dst_0_o,
    output wire [ TAG_W-1:0]   out_dst_1_o,
    output wire [  ST_W-1:0]   out_st_id_0_o,
    output wire [  ST_W-1:0]   out_st_id_1_o,

    // DST tag array for selection
    output logic [TAG_W-1:0]   dst_tag_o[0:RS_DEPTH-1],

    // Load order query
    output wire                load_order_query_valid_o,
    output wire [DATA_W-1:0]   load_order_query_addr_o,
    output wire [DATA_W/8-1:0] load_order_query_be_o,
    output wire [ TAG_W-1:0]   load_order_query_rob_idx_o,

    // Selection results: top-2 oldest ready plain loads
    output logic                          found_load0_o,
    output logic                          found_load1_o,
    output logic [$clog2(RS_DEPTH)-1:0]   load_idx0_o,
    output logic [$clog2(RS_DEPTH)-1:0]   load_idx1_o,
    output logic [TAG_W-1:0]              best_load_age0_o,
    output logic [TAG_W-1:0]              best_load_age1_o
);

  // ---------------------------------------------------------------
  // Helper functions (identical to issue_lsu originals)
  // ---------------------------------------------------------------
  function automatic logic is_plain_load_uop(input decode_pkg::uop_t op);
    begin
      is_plain_load_uop = op.is_load && !op.is_store &&
                          (op.lsu_op != decode_pkg::LSU_AMO) &&
                          (op.lsu_op != decode_pkg::LSU_LR);
    end
  endfunction

  function automatic logic [TAG_W-1:0] rob_age(
      input logic [TAG_W-1:0] idx, input logic [TAG_W-1:0] head);
    begin
      rob_age = idx - head;
    end
  endfunction

  // ---------------------------------------------------------------
  // Dispatch classification (plain loads only)
  // ---------------------------------------------------------------
  logic [3:0] load_dispatch_valid;
  logic [1:0] load_dispatch_lane[0:3];

  always_comb begin
    load_dispatch_valid = '0;
    dispatch_count_o = '0;
    for (int i = 0; i < 4; i++) load_dispatch_lane[i] = '0;

    for (int i = 0; i < 4; i++) begin
      if (dispatch_valid[i] && is_plain_load_uop(dispatch_op[i])) begin
        load_dispatch_valid[dispatch_count_o] = 1'b1;
        load_dispatch_lane[dispatch_count_o] = i[1:0];
        dispatch_count_o = dispatch_count_o + 3'd1;
      end
    end
  end

  // ---------------------------------------------------------------
  // Allocator
  // ---------------------------------------------------------------
  wire [RS_DEPTH-1:0] alloc_wen;
  wire [$clog2(RS_DEPTH)-1:0] routing_idx[0:3];

  rs_allocator #(.Cfg(Cfg)) u_alloc (
      .rs_busy    (busy_o),
      .instr_valid(load_dispatch_valid),
      .entry_wen  (alloc_wen),
      .idx_map    (routing_idx),
      .full_stall (full_stall_raw_o)
  );

  // ---------------------------------------------------------------
  // Crossbar: route dispatch data to RS entries
  // ---------------------------------------------------------------
  decode_pkg::uop_t rs_in_op[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_dst[0:RS_DEPTH-1];
  logic [DATA_W-1:0] rs_in_v1[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_q1[0:RS_DEPTH-1];
  logic rs_in_r1[0:RS_DEPTH-1];
  logic [DATA_W-1:0] rs_in_v2[0:RS_DEPTH-1];
  logic [TAG_W-1:0] rs_in_q2[0:RS_DEPTH-1];
  logic rs_in_r2[0:RS_DEPTH-1];
  logic [ST_W-1:0] rs_in_st_id[0:RS_DEPTH-1];

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
      rs_in_st_id[k] = 0;
    end

    for (int p = 0; p < 4; p++) begin
      if (load_dispatch_valid[p]) begin
        int unsigned src;
        src = load_dispatch_lane[p];
        rs_in_op[routing_idx[p]]    = dispatch_op[src];
        rs_in_dst[routing_idx[p]]   = dispatch_dst[src];
        rs_in_v1[routing_idx[p]]    = dispatch_v1[src];
        rs_in_q1[routing_idx[p]]    = dispatch_q1[src];
        rs_in_r1[routing_idx[p]]    = dispatch_r1[src];
        rs_in_v2[routing_idx[p]]    = dispatch_v2[src];
        rs_in_q2[routing_idx[p]]    = dispatch_q2[src];
        rs_in_r2[routing_idx[p]]    = dispatch_r2[src];
        rs_in_st_id[routing_idx[p]] = dispatch_st_id[src];
      end
    end
  end

  // ---------------------------------------------------------------
  // Reservation Station
  // ---------------------------------------------------------------
  reservation_station_load #(
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
      .entry_wen (alloc_wen),
      .in_op     (rs_in_op),
      .in_dst_tag(rs_in_dst),
      .in_v1     (rs_in_v1),
      .in_q1     (rs_in_q1),
      .in_r1     (rs_in_r1),
      .in_v2     (rs_in_v2),
      .in_q2     (rs_in_q2),
      .in_r2     (rs_in_r2),
      .in_st_id  (rs_in_st_id),
      .cdb_valid(cdb_valid),
      .cdb_tag  (cdb_tag),
      .cdb_value(cdb_val),
      .store_busy_i(store_busy_i),
      .store_op_i(store_op_i),
      .store_dst_tag_i(store_dst_tag_i),
      .store_v1_i(store_v1_i),
      .store_r1_i(store_r1_i),
      .store_v2_i(store_v2_i),
      .store_r2_i(store_r2_i),
      .stq_oldest_store_valid_i(stq_oldest_store_valid_i),
      .stq_oldest_store_rob_idx_i(stq_oldest_store_rob_idx_i),
      .stq_has_committed_store_i(stq_has_committed_store_i),
      .ready_mask (ready_o),
      .issue_grant(issue_grant_i),
      .load_order_query_safe_i(load_order_query_safe_i),
      .load_order_query_forward_full_i(load_order_query_forward_full_i),
      .load_order_query_valid_o(load_order_query_valid_o),
      .load_order_query_addr_o(load_order_query_addr_o),
      .load_order_query_be_o(load_order_query_be_o),
      .load_order_query_rob_idx_o(load_order_query_rob_idx_o),
      .busy_vector(busy_o),
      .sel_idx_0(sel_idx_0_i),
      .sel_idx_1(sel_idx_1_i),
      .out_op_0(out_op_0_o),
      .out_op_1(out_op_1_o),
      .out_v1_0(out_v1_0_o),
      .out_v1_1(out_v1_1_o),
      .out_v2_0(out_v2_0_o),
      .out_v2_1(out_v2_1_o),
      .out_dst_tag_0(out_dst_0_o),
      .out_dst_tag_1(out_dst_1_o),
      .out_st_id_0(out_st_id_0_o),
      .out_st_id_1(out_st_id_1_o),
      .dst_tag_o(dst_tag_o),
      .plain_load_mask_o(plain_load_o)
  );

  // ---------------------------------------------------------------
  // Selection: top-2 oldest ready plain loads
  // ---------------------------------------------------------------
  always_comb begin
    logic [TAG_W-1:0] age;
    found_load0_o = 1'b0;
    found_load1_o = 1'b0;
    load_idx0_o = '0;
    load_idx1_o = '0;
    best_load_age0_o = {TAG_W{1'b1}};
    best_load_age1_o = {TAG_W{1'b1}};
    age = '0;

    for (int i = 0; i < RS_DEPTH; i++) begin
      age = rob_age(dst_tag_o[i], rob_head_i);
      if (ready_o[i] && plain_load_o[i]) begin
        if (!found_load0_o || (age < best_load_age0_o)) begin
          found_load1_o = found_load0_o;
          best_load_age1_o = best_load_age0_o;
          load_idx1_o = load_idx0_o;
          found_load0_o = 1'b1;
          best_load_age0_o = age;
          load_idx0_o = i[$clog2(RS_DEPTH)-1:0];
        end else if (!found_load1_o || (age < best_load_age1_o)) begin
          found_load1_o = 1'b1;
          best_load_age1_o = age;
          load_idx1_o = i[$clog2(RS_DEPTH)-1:0];
        end
      end
    end
  end

endmodule
