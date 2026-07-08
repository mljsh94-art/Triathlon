module reservation_station_load #(
    parameter config_pkg::cfg_t Cfg      = config_pkg::EmptyCfg,
    parameter                   RS_DEPTH = Cfg.RS_DEPTH,
    parameter                   DATA_W   = Cfg.XLEN,
    parameter                   RS_IDX_W = $clog2(Cfg.RS_DEPTH),
    parameter                   TAG_W    = 6,
    parameter                   CDB_W    = 4,
    parameter                   ST_W     = 4
) (
    input wire clk,
    input wire rst_n,
    input wire flush_i,

    input wire [TAG_W-1:0] rob_head_i,
    input wire             spec_low_addr_block_en_i,

    input wire [RS_DEPTH-1:0] entry_wen,

    input decode_pkg::uop_t              in_op     [0:RS_DEPTH-1],
    input wire              [ TAG_W-1:0] in_dst_tag[0:RS_DEPTH-1],
    input wire              [DATA_W-1:0] in_v1     [0:RS_DEPTH-1],
    input wire              [ TAG_W-1:0] in_q1     [0:RS_DEPTH-1],
    input wire                           in_r1     [0:RS_DEPTH-1],
    input wire              [DATA_W-1:0] in_v2     [0:RS_DEPTH-1],
    input wire              [ TAG_W-1:0] in_q2     [0:RS_DEPTH-1],
    input wire                           in_r2     [0:RS_DEPTH-1],
    input wire              [  ST_W-1:0] in_st_id  [0:RS_DEPTH-1],

    input wire [ CDB_W-1:0] cdb_valid,
    input wire [ TAG_W-1:0] cdb_tag  [0:CDB_W-1],
    input wire [DATA_W-1:0] cdb_value[0:CDB_W-1],

    input wire [RS_DEPTH-1:0]      store_busy_i,
    input decode_pkg::uop_t        store_op_i     [0:RS_DEPTH-1],
    input wire [TAG_W-1:0]         store_dst_tag_i[0:RS_DEPTH-1],
    input wire [DATA_W-1:0]        store_v1_i     [0:RS_DEPTH-1],
    input wire                     store_r1_i     [0:RS_DEPTH-1],
    input wire [DATA_W-1:0]        store_v2_i     [0:RS_DEPTH-1],
    input wire                     store_r2_i     [0:RS_DEPTH-1],
    input wire                     stq_oldest_store_valid_i,
    input wire [TAG_W-1:0]         stq_oldest_store_rob_idx_i,
    input wire                     stq_has_committed_store_i,

    output logic [RS_DEPTH-1:0] ready_mask,
    input  wire  [RS_DEPTH-1:0] issue_grant,

    input  wire                 load_order_query_safe_i,
    input  wire                 load_order_query_forward_full_i,
    output logic                load_order_query_valid_o,
    output logic [DATA_W-1:0]   load_order_query_addr_o,
    output logic [DATA_W/8-1:0] load_order_query_be_o,
    output logic [TAG_W-1:0]    load_order_query_rob_idx_o,

    output wire [RS_DEPTH-1:0] busy_vector,

    input  wire  [RS_IDX_W-1:0] sel_idx_0,
    input  wire  [RS_IDX_W-1:0] sel_idx_1,
    output decode_pkg::uop_t    out_op_0,
    output decode_pkg::uop_t    out_op_1,
    output logic [   TAG_W-1:0] out_dst_tag_0,
    output logic [   TAG_W-1:0] out_dst_tag_1,
    output logic [  DATA_W-1:0] out_v1_0,
    output logic [  DATA_W-1:0] out_v1_1,
    output logic [  DATA_W-1:0] out_v2_0,
    output logic [  DATA_W-1:0] out_v2_1,
    output logic [   ST_W-1:0]  out_st_id_0,
    output logic [   ST_W-1:0]  out_st_id_1,
    output logic [   TAG_W-1:0] dst_tag_o[0:RS_DEPTH-1],
    output logic [RS_DEPTH-1:0] plain_load_mask_o
);

  reg               [RS_DEPTH-1:0] busy;
  decode_pkg::uop_t                op_arr [0:RS_DEPTH-1];
  reg               [   TAG_W-1:0] dst_arr[0:RS_DEPTH-1];
  reg               [  DATA_W-1:0] v1_arr [0:RS_DEPTH-1];
  reg               [   TAG_W-1:0] q1_arr [0:RS_DEPTH-1];
  reg                              r1_arr [0:RS_DEPTH-1];
  reg               [  DATA_W-1:0] v2_arr [0:RS_DEPTH-1];
  reg               [   TAG_W-1:0] q2_arr [0:RS_DEPTH-1];
  reg                              r2_arr [0:RS_DEPTH-1];
  reg               [   ST_W-1:0]  st_arr [0:RS_DEPTH-1];

  logic             [RS_DEPTH-1:0] busy_d;
  decode_pkg::uop_t                op_arr_d [0:RS_DEPTH-1];
  logic             [   TAG_W-1:0] dst_arr_d[0:RS_DEPTH-1];
  logic             [  DATA_W-1:0] v1_arr_d [0:RS_DEPTH-1];
  logic             [   TAG_W-1:0] q1_arr_d [0:RS_DEPTH-1];
  logic                            r1_arr_d [0:RS_DEPTH-1];
  logic             [  DATA_W-1:0] v2_arr_d [0:RS_DEPTH-1];
  logic             [   TAG_W-1:0] q2_arr_d [0:RS_DEPTH-1];
  logic                            r2_arr_d [0:RS_DEPTH-1];
  logic             [   ST_W-1:0]  st_arr_d [0:RS_DEPTH-1];

  logic [63:0] dbg_rs_load_block_store_total_q;
  logic [63:0] dbg_rs_load_block_store_addr_not_ready_q;
  logic [63:0] dbg_rs_load_block_store_data_not_ready_q;
  logic [63:0] dbg_rs_load_block_store_not_issued_q;
  logic [63:0] dbg_rs_load_order_override_ready_q;
  logic [63:0] dbg_rs_load_order_forward_full_ready_q;
  logic [63:0] dbg_rs_load_order_forward_full_issue_q;
  logic [63:0] dbg_rs_load_order_forward_full_not_issue_q;
  logic [63:0] dbg_rs_load_block_store_total_inc_w;
  logic [63:0] dbg_rs_load_block_store_addr_not_ready_inc_w;
  logic [63:0] dbg_rs_load_block_store_data_not_ready_inc_w;
  logic [63:0] dbg_rs_load_block_store_not_issued_inc_w;
  logic [RS_DEPTH-1:0] load_order_override_ready_mask_w;
  logic [RS_DEPTH-1:0] load_order_forward_full_ready_mask_w;

  function automatic logic [TAG_W-1:0] rob_age(
      input logic [TAG_W-1:0] idx, input logic [TAG_W-1:0] head);
    logic [TAG_W-1:0] diff;
    begin
      diff = idx - head;
      return diff;
    end
  endfunction

  function automatic logic cdb_can_wakeup(
      input logic [TAG_W-1:0] cdb_idx,
      input logic [TAG_W-1:0] consumer_idx
  );
    begin
      cdb_can_wakeup = (rob_age(cdb_idx, rob_head_i) < rob_age(consumer_idx, rob_head_i));
    end
  endfunction

  function automatic logic is_spec_low_addr(input logic [DATA_W-1:0] addr);
    begin
      is_spec_low_addr = ((addr[DATA_W-1:12] == '0) || (&addr[DATA_W-1:12]));
    end
  endfunction

  localparam int unsigned RS_BE_WIDTH = DATA_W / 8;
  localparam int unsigned RS_BYTE_OFF_W = (RS_BE_WIDTH > 1) ? $clog2(RS_BE_WIDTH) : 1;
  localparam int unsigned RS_PAGE_OFFSET_W = (DATA_W > 12) ? 12 : DATA_W;

  function automatic logic [RS_BE_WIDTH-1:0] load_be_mask(input decode_pkg::lsu_op_e op,
                                                           input logic [DATA_W-1:0] addr);
    logic [RS_BE_WIDTH-1:0] mask;
    logic [RS_BYTE_OFF_W-1:0] off;
    begin
      mask = '0;
      off = addr[RS_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_LB, decode_pkg::LSU_LBU: mask[off] = 1'b1;
        decode_pkg::LSU_LH, decode_pkg::LSU_LHU: begin
          for (int i = 0; i < 2; i++) begin
            if ((off + i) < RS_BE_WIDTH) mask[off+i] = 1'b1;
          end
        end
        decode_pkg::LSU_LW, decode_pkg::LSU_LWU, decode_pkg::LSU_LR,
        decode_pkg::LSU_AMO: begin
          for (int i = 0; i < 4; i++) begin
            if ((off + i) < RS_BE_WIDTH) mask[off+i] = 1'b1;
          end
        end
        decode_pkg::LSU_LD: begin
          for (int i = 0; i < RS_BE_WIDTH; i++) mask[i] = 1'b1;
        end
        default: mask = '0;
      endcase
      load_be_mask = mask;
    end
  endfunction

  function automatic logic [RS_BE_WIDTH-1:0] store_be_mask(input decode_pkg::lsu_op_e op,
                                                            input logic [DATA_W-1:0] addr);
    logic [RS_BE_WIDTH-1:0] mask;
    logic [RS_BYTE_OFF_W-1:0] off;
    begin
      mask = '0;
      off = addr[RS_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_SB: mask[off] = 1'b1;
        decode_pkg::LSU_SH: begin
          for (int i = 0; i < 2; i++) begin
            if ((off + i) < RS_BE_WIDTH) mask[off+i] = 1'b1;
          end
        end
        decode_pkg::LSU_SW, decode_pkg::LSU_SC, decode_pkg::LSU_AMO: begin
          for (int i = 0; i < 4; i++) begin
            if ((off + i) < RS_BE_WIDTH) mask[off+i] = 1'b1;
          end
        end
        decode_pkg::LSU_SD: begin
          for (int i = 0; i < RS_BE_WIDTH; i++) mask[i] = 1'b1;
        end
        default: mask = '0;
      endcase
      store_be_mask = mask;
    end
  endfunction

  function automatic logic is_store_misaligned(input decode_pkg::lsu_op_e op,
                                                input logic [DATA_W-1:0] addr);
    begin
      unique case (op)
        decode_pkg::LSU_SB: is_store_misaligned = 1'b0;
        decode_pkg::LSU_SH: is_store_misaligned = addr[0];
        decode_pkg::LSU_SW, decode_pkg::LSU_SC, decode_pkg::LSU_AMO: is_store_misaligned = |addr[1:0];
        decode_pkg::LSU_SD: is_store_misaligned = |addr[2:0];
        default: is_store_misaligned = 1'b0;
      endcase
    end
  endfunction

  function automatic logic is_strict_order_store(input decode_pkg::lsu_op_e op);
    begin
      is_strict_order_store = (op == decode_pkg::LSU_SC) || (op == decode_pkg::LSU_AMO);
    end
  endfunction

  function automatic logic stq_has_older_store(input logic [TAG_W-1:0] load_age);
    begin
      stq_has_older_store = stq_has_committed_store_i ||
                            (stq_oldest_store_valid_i &&
                             (rob_age(stq_oldest_store_rob_idx_i, rob_head_i) < load_age));
    end
  endfunction

  always_comb begin
    busy_d = busy;
    op_arr_d = op_arr;
    dst_arr_d = dst_arr;
    v1_arr_d = v1_arr;
    q1_arr_d = q1_arr;
    r1_arr_d = r1_arr;
    v2_arr_d = v2_arr;
    q2_arr_d = q2_arr;
    r2_arr_d = r2_arr;
    st_arr_d = st_arr;

    for (int i = 0; i < RS_DEPTH; i++) begin
      if (issue_grant[i]) begin
        busy_d[i] = 1'b0;
      end else if (entry_wen[i]) begin
        busy_d[i]    = 1'b1;
        op_arr_d[i]  = in_op[i];
        dst_arr_d[i] = in_dst_tag[i];
        st_arr_d[i]  = in_st_id[i];

        v1_arr_d[i] = in_v1[i];
        q1_arr_d[i] = in_q1[i];
        r1_arr_d[i] = in_r1[i];
        if (!in_r1[i]) begin
          for (int k = 0; k < CDB_W; k++) begin
            if (cdb_valid[k] && (cdb_tag[k] == in_q1[i]) &&
                cdb_can_wakeup(cdb_tag[k], in_dst_tag[i])) begin
              v1_arr_d[i] = cdb_value[k];
              r1_arr_d[i] = 1'b1;
            end
          end
        end

        v2_arr_d[i] = in_v2[i];
        q2_arr_d[i] = in_q2[i];
        r2_arr_d[i] = in_r2[i];
        if (!in_r2[i]) begin
          for (int k = 0; k < CDB_W; k++) begin
            if (cdb_valid[k] && (cdb_tag[k] == in_q2[i]) &&
                cdb_can_wakeup(cdb_tag[k], in_dst_tag[i])) begin
              v2_arr_d[i] = cdb_value[k];
              r2_arr_d[i] = 1'b1;
            end
          end
        end
      end else if (busy[i]) begin
        for (int k = 0; k < CDB_W; k++) begin
          if (cdb_valid[k]) begin
            if (!r1_arr[i] && (q1_arr[i] == cdb_tag[k]) &&
                cdb_can_wakeup(cdb_tag[k], dst_arr[i])) begin
              v1_arr_d[i] = cdb_value[k];
              r1_arr_d[i] = 1'b1;
            end
            if (!r2_arr[i] && (q2_arr[i] == cdb_tag[k]) &&
                cdb_can_wakeup(cdb_tag[k], dst_arr[i])) begin
              v2_arr_d[i] = cdb_value[k];
              r2_arr_d[i] = 1'b1;
            end
          end
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= {RS_DEPTH{1'b0}};
    end else if (flush_i) begin
      busy <= {RS_DEPTH{1'b0}};
    end else begin
      busy <= busy_d;
      op_arr <= op_arr_d;
      dst_arr <= dst_arr_d;
      v1_arr <= v1_arr_d;
      q1_arr <= q1_arr_d;
      r1_arr <= r1_arr_d;
      v2_arr <= v2_arr_d;
      q2_arr <= q2_arr_d;
      r2_arr <= r2_arr_d;
      st_arr <= st_arr_d;
    end
  end

  always_comb begin
    logic found_load_query;
    logic [TAG_W-1:0] best_load_query_age;
    logic [TAG_W-1:0] load_age;
    logic [DATA_W-1:0] eff_addr;
    logic [RS_BE_WIDTH-1:0] load_mask;
    logic block_spec_low;
    logic src_ready;

    found_load_query = 1'b0;
    best_load_query_age = {TAG_W{1'b1}};
    load_order_query_valid_o = 1'b0;
    load_order_query_addr_o = '0;
    load_order_query_be_o = '0;
    load_order_query_rob_idx_o = '0;

    // A load older than every valid STQ entry cannot violate store order and
    // does not need the single STQ query port. Query only the oldest ready load
    // that may have an older store in STQ.
    for (int i = 0; i < RS_DEPTH; i++) begin
      load_age = rob_age(dst_arr[i], rob_head_i);
      eff_addr = v1_arr[i] + op_arr[i].imm;
      load_mask = load_be_mask(op_arr[i].lsu_op, eff_addr);
      block_spec_low = spec_low_addr_block_en_i &&
                       is_spec_low_addr(eff_addr) &&
                       (dst_arr[i] != rob_head_i);
      src_ready = (op_arr[i].has_rs1 ? r1_arr[i] : 1'b1) &&
                  (op_arr[i].has_rs2 ? r2_arr[i] : 1'b1);

      if (busy[i] && src_ready && !block_spec_low && stq_has_older_store(load_age) &&
          (!found_load_query || (load_age < best_load_query_age))) begin
        found_load_query = 1'b1;
        best_load_query_age = load_age;
        load_order_query_valid_o = 1'b1;
        load_order_query_addr_o = eff_addr;
        load_order_query_be_o = load_mask;
        load_order_query_rob_idx_o = dst_arr[i];
      end
    end
  end

  always_comb begin
    dbg_rs_load_block_store_total_inc_w = '0;
    dbg_rs_load_block_store_addr_not_ready_inc_w = '0;
    dbg_rs_load_block_store_data_not_ready_inc_w = '0;
    dbg_rs_load_block_store_not_issued_inc_w = '0;
    load_order_override_ready_mask_w = '0;
    load_order_forward_full_ready_mask_w = '0;

    for (int m = 0; m < RS_DEPTH; m++) begin
      logic block_load;
      logic src_ready;
      logic block_spec_low;
      logic best_store_found;
      logic best_store_addr_ready;
      logic best_store_data_ready;
      logic [DATA_W-1:0] eff_addr;
      logic [DATA_W-1:0] store_eff_addr;
      logic [TAG_W-1:0] load_age;
      logic [TAG_W-1:0] store_age;
      logic [TAG_W-1:0] best_store_age;
      logic [RS_BE_WIDTH-1:0] load_mask;
      logic [RS_BE_WIDTH-1:0] store_mask;
      logic store_addr_ready;
      logic store_data_ready;
      logic store_same_word;
      logic store_overlap;
      logic store_blocks_load;
      logic stq_older_store;

      block_load = 1'b0;
      best_store_found = 1'b0;
      best_store_addr_ready = 1'b1;
      best_store_data_ready = 1'b1;
      best_store_age = {TAG_W{1'b1}};
      load_age = rob_age(dst_arr[m], rob_head_i);
      eff_addr = v1_arr[m] + op_arr[m].imm;
      load_mask = load_be_mask(op_arr[m].lsu_op, eff_addr);
      src_ready = (op_arr[m].has_rs1 ? r1_arr[m] : 1'b1) &&
                  (op_arr[m].has_rs2 ? r2_arr[m] : 1'b1);
      stq_older_store = stq_has_older_store(load_age);

      if (busy[m]) begin
        for (int n = 0; n < RS_DEPTH; n++) begin
          store_age = rob_age(store_dst_tag_i[n], rob_head_i);
          store_addr_ready = !store_op_i[n].has_rs1 || store_r1_i[n];
          store_data_ready = !store_op_i[n].has_rs2 || store_r2_i[n];
          store_eff_addr = store_v1_i[n] + store_op_i[n].imm;
          store_mask = store_be_mask(store_op_i[n].lsu_op, store_eff_addr);
          store_same_word = (store_eff_addr[RS_PAGE_OFFSET_W-1:RS_BYTE_OFF_W] ==
                             eff_addr[RS_PAGE_OFFSET_W-1:RS_BYTE_OFF_W]);
          store_overlap = store_same_word && (|(store_mask & load_mask));
          store_blocks_load = 1'b0;

          if (store_busy_i[n] && store_op_i[n].is_store && (store_age < load_age)) begin
            store_blocks_load = !store_addr_ready ||
                                is_store_misaligned(store_op_i[n].lsu_op, store_eff_addr) ||
                                is_strict_order_store(store_op_i[n].lsu_op) ||
                                store_overlap;
            if (store_blocks_load) begin
              block_load = 1'b1;
              if (!best_store_found || (store_age < best_store_age)) begin
                best_store_found = 1'b1;
                best_store_age = store_age;
                best_store_addr_ready = store_addr_ready;
                best_store_data_ready = store_data_ready;
              end
            end
          end
        end
      end

      if (busy[m] && src_ready && best_store_found) begin
        dbg_rs_load_block_store_total_inc_w = dbg_rs_load_block_store_total_inc_w + 64'd1;
        if (!best_store_addr_ready) begin
          dbg_rs_load_block_store_addr_not_ready_inc_w =
              dbg_rs_load_block_store_addr_not_ready_inc_w + 64'd1;
        end else if (!best_store_data_ready) begin
          dbg_rs_load_block_store_data_not_ready_inc_w =
              dbg_rs_load_block_store_data_not_ready_inc_w + 64'd1;
        end else begin
          dbg_rs_load_block_store_not_issued_inc_w =
              dbg_rs_load_block_store_not_issued_inc_w + 64'd1;
        end
      end

      block_spec_low = spec_low_addr_block_en_i &&
                       busy[m] &&
                       src_ready &&
                       is_spec_low_addr(eff_addr) &&
                       (dst_arr[m] != rob_head_i);
      if (busy[m] && src_ready && !block_spec_low) begin
        if (!stq_older_store) begin
          block_load = 1'b0;
        end else if (load_order_query_valid_o && (dst_arr[m] == load_order_query_rob_idx_o)) begin
          block_load = !load_order_query_safe_i;
          if (load_order_query_safe_i) begin
            load_order_override_ready_mask_w[m] = 1'b1;
            if (load_order_query_forward_full_i) begin
              load_order_forward_full_ready_mask_w[m] = 1'b1;
            end
          end
        end else begin
          block_load = 1'b1;
        end
      end

      ready_mask[m] = busy[m] && src_ready && !block_load && !block_spec_low;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_rs_load_block_store_total_q <= '0;
      dbg_rs_load_block_store_addr_not_ready_q <= '0;
      dbg_rs_load_block_store_data_not_ready_q <= '0;
      dbg_rs_load_block_store_not_issued_q <= '0;
      dbg_rs_load_order_override_ready_q <= '0;
      dbg_rs_load_order_forward_full_ready_q <= '0;
      dbg_rs_load_order_forward_full_issue_q <= '0;
      dbg_rs_load_order_forward_full_not_issue_q <= '0;
    end else begin
      dbg_rs_load_block_store_total_q <=
          dbg_rs_load_block_store_total_q + dbg_rs_load_block_store_total_inc_w;
      dbg_rs_load_block_store_addr_not_ready_q <=
          dbg_rs_load_block_store_addr_not_ready_q +
          dbg_rs_load_block_store_addr_not_ready_inc_w;
      dbg_rs_load_block_store_data_not_ready_q <=
          dbg_rs_load_block_store_data_not_ready_q +
          dbg_rs_load_block_store_data_not_ready_inc_w;
      dbg_rs_load_block_store_not_issued_q <=
          dbg_rs_load_block_store_not_issued_q + dbg_rs_load_block_store_not_issued_inc_w;
      dbg_rs_load_order_override_ready_q <=
          dbg_rs_load_order_override_ready_q + 64'($countones(load_order_override_ready_mask_w));
      dbg_rs_load_order_forward_full_ready_q <=
          dbg_rs_load_order_forward_full_ready_q +
          64'($countones(load_order_forward_full_ready_mask_w));
      dbg_rs_load_order_forward_full_issue_q <=
          dbg_rs_load_order_forward_full_issue_q +
          64'($countones(load_order_forward_full_ready_mask_w & issue_grant));
      dbg_rs_load_order_forward_full_not_issue_q <=
          dbg_rs_load_order_forward_full_not_issue_q +
          64'($countones(load_order_forward_full_ready_mask_w & ~issue_grant));
    end
  end

  assign out_op_0      = op_arr[sel_idx_0];
  assign out_dst_tag_0 = dst_arr[sel_idx_0];
  assign out_v1_0      = v1_arr[sel_idx_0];
  assign out_v2_0      = v2_arr[sel_idx_0];
  assign out_st_id_0   = st_arr[sel_idx_0];
  assign out_op_1      = op_arr[sel_idx_1];
  assign out_dst_tag_1 = dst_arr[sel_idx_1];
  assign out_v1_1      = v1_arr[sel_idx_1];
  assign out_v2_1      = v2_arr[sel_idx_1];
  assign out_st_id_1   = st_arr[sel_idx_1];

  assign busy_vector = busy;

  always_comb begin
    for (int i = 0; i < RS_DEPTH; i++) begin
      dst_tag_o[i] = dst_arr[i];
      plain_load_mask_o[i] = busy[i] && op_arr[i].is_load && !op_arr[i].is_store &&
                             (op_arr[i].lsu_op != decode_pkg::LSU_AMO) &&
                             (op_arr[i].lsu_op != decode_pkg::LSU_LR);
    end
  end

endmodule
