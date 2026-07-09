// vsrc/backend/issue/issue_store.sv
// Store (and complex LSU) reservation station, allocator, crossbar,
// selection logic, and STA/STD early paths.
// Extracted from issue_lsu.sv — pure refactoring, no logic changes.
import decode_pkg::*;

module issue_store #(
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

    // 4-wide dispatch (module internally classifies non-plain-load ops)
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

    // Grant mask from wrapper
    input wire [RS_DEPTH-1:0] issue_grant_i,

    // RS read port index
    input wire [$clog2(RS_DEPTH)-1:0] sel_idx_0_i,
    input wire [$clog2(RS_DEPTH)-1:0] sel_idx_1_i,

    // STA/STD fire from wrapper
    input wire sta_fire_i,
    input wire std_fire_i,

    // Load order query (gated by wrapper)
    input wire load_order_query_safe_i,
    input wire load_order_query_forward_full_i,

    // --- Outputs ---
    output wire [RS_DEPTH-1:0] busy_o,
    output wire [RS_DEPTH-1:0] ready_o,
    output wire [RS_DEPTH-1:0] plain_load_o,
    output wire [RS_DEPTH-1:0] ready_store_o,
    output wire [RS_DEPTH-1:0] blocking_ready_store_o,
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

    // DST tag array
    output logic [TAG_W-1:0]   dst_tag_o[0:RS_DEPTH-1],

    // Store RS state exposed for load RS ordering
    output wire [RS_DEPTH-1:0]           store_busy_o,
    output decode_pkg::uop_t             store_op_o    [0:RS_DEPTH-1],
    output wire [ TAG_W-1:0]             store_dst_tag_o[0:RS_DEPTH-1],
    output wire [DATA_W-1:0]             store_v1_o    [0:RS_DEPTH-1],
    output wire                          store_r1_o    [0:RS_DEPTH-1],
    output wire [DATA_W-1:0]             store_v2_o    [0:RS_DEPTH-1],
    output wire                          store_r2_o    [0:RS_DEPTH-1],
    output wire [  ST_W-1:0]             store_st_id_o [0:RS_DEPTH-1],

    // STA/STD raw (fire determined by wrapper)
    output wire                sta_valid_o,
    output decode_pkg::uop_t   sta_uop_o,
    output wire [DATA_W-1:0]   sta_v1_o,
    output wire [ TAG_W-1:0]   sta_dst_o,
    output wire [  ST_W-1:0]   sta_st_id_o,
    output wire                std_valid_o,
    output wire [DATA_W-1:0]   std_data_o,
    output wire [  ST_W-1:0]   std_st_id_o,

    // Load order query
    output wire                load_order_query_valid_o,
    output wire [DATA_W-1:0]   load_order_query_addr_o,
    output wire [DATA_W/8-1:0] load_order_query_be_o,
    output wire [ TAG_W-1:0]   load_order_query_rob_idx_o,

    // Selection: sideband (plain store) + legacy (complex)
    output logic                          found_st_sideband_o,
    output logic [$clog2(RS_DEPTH)-1:0]   st_sideband_idx_o,
    output logic [TAG_W-1:0]              best_st_sideband_age_o,
    output logic                          found_legacy0_o,
    output logic [$clog2(RS_DEPTH)-1:0]   legacy_idx0_o,
    output logic [TAG_W-1:0]              best_legacy_age0_o
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

  function automatic logic is_plain_store_uop(input decode_pkg::uop_t op);
    begin
      is_plain_store_uop = op.is_store && !op.is_load &&
                           ((op.lsu_op == decode_pkg::LSU_SB) ||
                            (op.lsu_op == decode_pkg::LSU_SH) ||
                            (op.lsu_op == decode_pkg::LSU_SW) ||
                            (op.lsu_op == decode_pkg::LSU_SD));
    end
  endfunction

  function automatic logic [TAG_W-1:0] rob_age(
      input logic [TAG_W-1:0] idx, input logic [TAG_W-1:0] head);
    begin
      rob_age = idx - head;
    end
  endfunction

  // ---------------------------------------------------------------
  // Dispatch classification (non-plain-load → store RS)
  // ---------------------------------------------------------------
  logic [3:0] store_dispatch_valid;
  logic [1:0] store_dispatch_lane[0:3];

  always_comb begin
    store_dispatch_valid = '0;
    dispatch_count_o = '0;
    for (int i = 0; i < 4; i++) store_dispatch_lane[i] = '0;

    for (int i = 0; i < 4; i++) begin
      if (dispatch_valid[i] && !is_plain_load_uop(dispatch_op[i])) begin
        store_dispatch_valid[dispatch_count_o] = 1'b1;
        store_dispatch_lane[dispatch_count_o] = i[1:0];
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
      .instr_valid(store_dispatch_valid),
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
      if (store_dispatch_valid[p]) begin
        int unsigned src;
        src = store_dispatch_lane[p];
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
      .busy_vector(busy_o),
      .ready_mask (ready_o),
      .issue_grant(issue_grant_i),
      .sta_fire_i(sta_fire_i),
      .sta_valid_o(sta_valid_o),
      .sta_uop_o(sta_uop_o),
      .sta_v1_o(sta_v1_o),
      .sta_dst_tag_o(sta_dst_o),
      .sta_st_id_o(sta_st_id_o),
      .std_fire_i(std_fire_i),
      .std_valid_o(std_valid_o),
      .std_data_o(std_data_o),
      .std_st_id_o(std_st_id_o),
      .load_order_query_safe_i(load_order_query_safe_i),
      .load_order_query_forward_full_i(load_order_query_forward_full_i),
      .load_order_query_valid_o(load_order_query_valid_o),
      .load_order_query_addr_o(load_order_query_addr_o),
      .load_order_query_be_o(load_order_query_be_o),
      .load_order_query_rob_idx_o(load_order_query_rob_idx_o),
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
      .plain_load_mask_o(plain_load_o),
      .ready_store_mask_o(ready_store_o),
      .blocking_ready_store_mask_o(blocking_ready_store_o),
      .store_busy_o(store_busy_o),
      .store_op_o(store_op_o),
      .store_dst_tag_o(store_dst_tag_o),
      .store_v1_o(store_v1_o),
      .store_r1_o(store_r1_o),
      .store_v2_o(store_v2_o),
      .store_r2_o(store_r2_o),
      .store_st_id_o(store_st_id_o)
  );

  // ---------------------------------------------------------------
  // Selection: sideband (plain store) + legacy (complex/non-plain-store)
  // ---------------------------------------------------------------
  always_comb begin
    logic [TAG_W-1:0] age;
    found_st_sideband_o = 1'b0;
    st_sideband_idx_o = '0;
    best_st_sideband_age_o = {TAG_W{1'b1}};
    found_legacy0_o = 1'b0;
    legacy_idx0_o = '0;
    best_legacy_age0_o = {TAG_W{1'b1}};
    age = '0;

    for (int i = 0; i < RS_DEPTH; i++) begin
      age = rob_age(dst_tag_o[i], rob_head_i);
      if (ready_o[i] && is_plain_store_uop(store_op_o[i])) begin
        if (!found_st_sideband_o || (age < best_st_sideband_age_o)) begin
          found_st_sideband_o = 1'b1;
          best_st_sideband_age_o = age;
          st_sideband_idx_o = i[$clog2(RS_DEPTH)-1:0];
        end
      end else if (ready_o[i] && (!found_legacy0_o || (age < best_legacy_age0_o))) begin
        found_legacy0_o = 1'b1;
        best_legacy_age0_o = age;
        legacy_idx0_o = i[$clog2(RS_DEPTH)-1:0];
      end
    end
  end

endmodule
