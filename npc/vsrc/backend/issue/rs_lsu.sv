module reservation_station_lsu #(
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

    input wire [ TAG_W-1:0] rob_head_i,
    input wire              spec_low_addr_block_en_i,

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

    // 握手信号
    output logic [RS_DEPTH-1:0] ready_mask,
    input  wire [RS_DEPTH-1:0] issue_grant,

    // Non-consuming store-address issue. A fired STA marks the RS entry but
    // does not clear it; the full store still issues later when data is ready.
    input  wire                 sta_fire_i,
    output logic                sta_valid_o,
    output decode_pkg::uop_t    sta_uop_o,
    output logic [DATA_W-1:0]   sta_v1_o,
    output logic [TAG_W-1:0]    sta_dst_tag_o,
    output logic [ST_W-1:0]     sta_st_id_o,

    // Non-consuming store-data issue. A fired STD marks the RS entry but does
    // not clear it; the full store still issues later through the LSU path.
    input  wire                 std_fire_i,
    output logic                std_valid_o,
    output logic [DATA_W-1:0]   std_data_o,
    output logic [ST_W-1:0]     std_st_id_o,

    // Migration path for load-store ordering to STQ. This picks the oldest
    // source-ready load that the local conservative RS check would block, then
    // lets STQ prove it safe using already-filled STA information.
    input  wire                 load_order_query_safe_i,
    input  wire                 load_order_query_forward_full_i,
    output logic                load_order_query_valid_o,
    output logic [DATA_W-1:0]   load_order_query_addr_o,
    output logic [DATA_W/8-1:0] load_order_query_be_o,
    output logic [TAG_W-1:0]    load_order_query_rob_idx_o,

    output wire [RS_DEPTH-1:0] busy_vector,

    // LSU 读取通道
    input  wire  [RS_IDX_W-1:0] sel_idx_0,
    input  wire  [RS_IDX_W-1:0] sel_idx_1,
    output decode_pkg::uop_t   out_op_0,
    output decode_pkg::uop_t   out_op_1,
    output logic [   TAG_W-1:0] out_dst_tag_0,
    output logic [   TAG_W-1:0] out_dst_tag_1,
    output logic [  DATA_W-1:0] out_v1_0,
    output logic [  DATA_W-1:0] out_v1_1,
    output logic [  DATA_W-1:0] out_v2_0,
    output logic [  DATA_W-1:0] out_v2_1,
    output logic [   ST_W-1:0]  out_st_id_0,
    output logic [   ST_W-1:0]  out_st_id_1,
    output logic [   TAG_W-1:0] dst_tag_o[0:RS_DEPTH-1],
    output logic [RS_DEPTH-1:0] plain_load_mask_o,
    output logic [RS_DEPTH-1:0] ready_store_mask_o,
    output logic [RS_DEPTH-1:0] blocking_ready_store_mask_o,
    output logic [RS_DEPTH-1:0] store_busy_o,
    output decode_pkg::uop_t store_op_o[0:RS_DEPTH-1],
    output logic [TAG_W-1:0] store_dst_tag_o[0:RS_DEPTH-1],
    output logic [DATA_W-1:0] store_v1_o[0:RS_DEPTH-1],
    output logic store_r1_o[0:RS_DEPTH-1],
    output logic [DATA_W-1:0] store_v2_o[0:RS_DEPTH-1],
    output logic store_r2_o[0:RS_DEPTH-1],
    output logic [ST_W-1:0] store_st_id_o[0:RS_DEPTH-1]
);

  // RS 存储阵列
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
  reg               [RS_DEPTH-1:0] sta_issued;
  reg               [RS_DEPTH-1:0] std_issued;

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
  logic             [RS_DEPTH-1:0] sta_issued_d;
  logic             [RS_DEPTH-1:0] std_issued_d;
  logic             [RS_IDX_W-1:0] sta_sel_idx;
  logic             [RS_IDX_W-1:0] std_sel_idx;

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
`ifndef SYNTHESIS
  localparam int unsigned RS_LSU_TRACE_BUDGET = 512;
  logic [31:0] rs_lsu_trace_cnt_q;
  logic rs_lsu_trace_en_q;
  initial begin
    rs_lsu_trace_en_q = $test$plusargs("npc_diag_trace");
  end
`endif

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
      // A source producer must be older than the consumer in ROB age space.
      // This filters false wakeups when ROB index aliases after wrap-around.
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

  function automatic logic is_plain_store_op(input decode_pkg::lsu_op_e op);
    begin
      unique case (op)
        decode_pkg::LSU_SB,
        decode_pkg::LSU_SH,
        decode_pkg::LSU_SW,
        decode_pkg::LSU_SD: is_plain_store_op = 1'b1;
        default:            is_plain_store_op = 1'b0;
      endcase
    end
  endfunction

  always_comb begin
    busy_d   = busy;
    op_arr_d = op_arr;
    dst_arr_d = dst_arr;
    v1_arr_d = v1_arr;
    q1_arr_d = q1_arr;
    r1_arr_d = r1_arr;
    v2_arr_d = v2_arr;
    q2_arr_d = q2_arr;
    r2_arr_d = r2_arr;
    st_arr_d = st_arr;
    sta_issued_d = sta_issued;
    std_issued_d = std_issued;

    for (int i = 0; i < RS_DEPTH; i++) begin
      if (issue_grant[i]) begin
        busy_d[i] = 1'b0;
        sta_issued_d[i] = 1'b0;
        std_issued_d[i] = 1'b0;
      end else if (entry_wen[i]) begin
        busy_d[i]    = 1'b1;
        op_arr_d[i]  = in_op[i];
        dst_arr_d[i] = in_dst_tag[i];
        st_arr_d[i]  = in_st_id[i];
        sta_issued_d[i] = 1'b0;
        std_issued_d[i] = 1'b0;

        v1_arr_d[i]  = in_v1[i];
        q1_arr_d[i]  = in_q1[i];
        r1_arr_d[i]  = in_r1[i];
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

    if (sta_fire_i && sta_valid_o) begin
      sta_issued_d[sta_sel_idx] = 1'b1;
    end
    if (std_fire_i && std_valid_o) begin
      std_issued_d[std_sel_idx] = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= {RS_DEPTH{1'b0}};
      sta_issued <= {RS_DEPTH{1'b0}};
      std_issued <= {RS_DEPTH{1'b0}};
    end else if (flush_i) begin
      busy <= {RS_DEPTH{1'b0}};
      sta_issued <= {RS_DEPTH{1'b0}};
      std_issued <= {RS_DEPTH{1'b0}};
    end else begin
      busy   <= busy_d;
      op_arr <= op_arr_d;
      dst_arr <= dst_arr_d;
      v1_arr <= v1_arr_d;
      q1_arr <= q1_arr_d;
      r1_arr <= r1_arr_d;
      v2_arr <= v2_arr_d;
      q2_arr <= q2_arr_d;
      r2_arr <= r2_arr_d;
      st_arr <= st_arr_d;
      sta_issued <= sta_issued_d;
      std_issued <= std_issued_d;
    end
  end

  always_comb begin
    logic found_sta;
    logic [TAG_W-1:0] best_sta_age;
    logic [TAG_W-1:0] age;
    logic [DATA_W-1:0] eff_addr;
    logic block_spec_low;

    found_sta = 1'b0;
    best_sta_age = {TAG_W{1'b1}};
    sta_sel_idx = '0;
    age = '0;
    eff_addr = '0;
    block_spec_low = 1'b0;

    for (int i = 0; i < RS_DEPTH; i++) begin
      age = rob_age(dst_arr[i], rob_head_i);
      eff_addr = v1_arr[i] + op_arr[i].imm;
      block_spec_low = spec_low_addr_block_en_i &&
                       is_spec_low_addr(eff_addr) &&
                       (dst_arr[i] != rob_head_i);
      if (busy[i] && op_arr[i].is_store && !op_arr[i].is_load &&
          is_plain_store_op(op_arr[i].lsu_op) && !sta_issued[i] &&
          (!op_arr[i].has_rs1 || r1_arr[i]) && !block_spec_low &&
          (!found_sta || (age < best_sta_age))) begin
        found_sta = 1'b1;
        best_sta_age = age;
        sta_sel_idx = i[RS_IDX_W-1:0];
      end
    end

    sta_valid_o = found_sta;
    sta_uop_o = op_arr[sta_sel_idx];
    sta_v1_o = v1_arr[sta_sel_idx];
    sta_dst_tag_o = dst_arr[sta_sel_idx];
    sta_st_id_o = st_arr[sta_sel_idx];
  end

  always_comb begin
    logic found_std;
    logic [TAG_W-1:0] best_std_age;
    logic [TAG_W-1:0] age;

    found_std = 1'b0;
    best_std_age = {TAG_W{1'b1}};
    std_sel_idx = '0;
    age = '0;

    for (int i = 0; i < RS_DEPTH; i++) begin
      age = rob_age(dst_arr[i], rob_head_i);
      if (busy[i] && op_arr[i].is_store && !op_arr[i].is_load &&
          is_plain_store_op(op_arr[i].lsu_op) && !std_issued[i] &&
          op_arr[i].has_rs2 && r2_arr[i] &&
          (!found_std || (age < best_std_age))) begin
        found_std = 1'b1;
        best_std_age = age;
        std_sel_idx = i[RS_IDX_W-1:0];
      end
    end

    std_valid_o = found_std;
    std_data_o = v2_arr[std_sel_idx];
    std_st_id_o = st_arr[std_sel_idx];
  end

  always_comb begin
    logic found_load_query;
    logic [TAG_W-1:0] best_load_query_age;
    logic [TAG_W-1:0] load_age;
    logic [TAG_W-1:0] store_age;
    logic [DATA_W-1:0] eff_addr;
    logic [DATA_W-1:0] store_eff_addr;
    logic [RS_BE_WIDTH-1:0] load_mask;
    logic [RS_BE_WIDTH-1:0] store_mask;
    logic block_spec_low;
    logic src_ready;
    logic conservative_block;
    logic stq_provable_block;
    logic strict_order_block;
    logic store_addr_ready;
    logic store_same_word;
    logic store_overlap;

    found_load_query = 1'b0;
    best_load_query_age = {TAG_W{1'b1}};
    load_age = '0;
    store_age = '0;
    eff_addr = '0;
    store_eff_addr = '0;
    load_mask = '0;
    store_mask = '0;
    block_spec_low = 1'b0;
    src_ready = 1'b0;
    conservative_block = 1'b0;
    stq_provable_block = 1'b0;
    strict_order_block = 1'b0;
    store_addr_ready = 1'b0;
    store_same_word = 1'b0;
    store_overlap = 1'b0;
    load_order_query_valid_o = 1'b0;
    load_order_query_addr_o = '0;
    load_order_query_be_o = '0;
    load_order_query_rob_idx_o = '0;

    for (int i = 0; i < RS_DEPTH; i++) begin
      load_age = rob_age(dst_arr[i], rob_head_i);
      eff_addr = v1_arr[i] + op_arr[i].imm;
      load_mask = load_be_mask(op_arr[i].lsu_op, eff_addr);
      block_spec_low = spec_low_addr_block_en_i &&
                       is_spec_low_addr(eff_addr) &&
                       (dst_arr[i] != rob_head_i);
      src_ready = (op_arr[i].has_rs1 ? r1_arr[i] : 1'b1) &&
                  (op_arr[i].has_rs2 ? r2_arr[i] : 1'b1);
      conservative_block = 1'b0;
      stq_provable_block = 1'b0;
      strict_order_block = 1'b0;
      store_addr_ready = 1'b0;
      store_same_word = 1'b0;
      store_overlap = 1'b0;

      if (busy[i] && op_arr[i].is_load && src_ready && !block_spec_low) begin
        for (int n = 0; n < RS_DEPTH; n++) begin
          store_age = rob_age(dst_arr[n], rob_head_i);
          store_eff_addr = v1_arr[n] + op_arr[n].imm;
          store_mask = store_be_mask(op_arr[n].lsu_op, store_eff_addr);
          if (busy[n] && op_arr[n].is_store && (store_age < load_age)) begin
            store_addr_ready = !op_arr[n].has_rs1 || r1_arr[n];
            store_same_word = store_addr_ready &&
                              (store_eff_addr[RS_PAGE_OFFSET_W-1:RS_BYTE_OFF_W] ==
                               eff_addr[RS_PAGE_OFFSET_W-1:RS_BYTE_OFF_W]);
            store_overlap = store_same_word && (|(store_mask & load_mask));
            stq_provable_block = stq_provable_block || !store_addr_ready || store_overlap;
            strict_order_block = strict_order_block ||
                                 is_store_misaligned(op_arr[n].lsu_op, store_eff_addr) ||
                                 is_strict_order_store(op_arr[n].lsu_op);
            conservative_block = conservative_block || stq_provable_block || strict_order_block;
          end
        end

        if (stq_provable_block && !strict_order_block &&
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
  end

  // Load/store ordering: block loads only behind older stores whose
  // address is unknown or whose known byte range may conflict with the load.
  always_comb begin
    dbg_rs_load_block_store_total_inc_w = '0;
    dbg_rs_load_block_store_addr_not_ready_inc_w = '0;
    dbg_rs_load_block_store_data_not_ready_inc_w = '0;
    dbg_rs_load_block_store_not_issued_inc_w = '0;
    load_order_override_ready_mask_w = '0;
    load_order_forward_full_ready_mask_w = '0;
    blocking_ready_store_mask_o = '0;

    for (int m = 0; m < RS_DEPTH; m++) begin
      logic block_load;
      logic src_ready;
      logic block_spec_low;
      logic best_store_found;
      logic best_store_addr_ready;
      logic best_store_data_ready;
      logic [RS_IDX_W-1:0] best_store_idx;
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

      block_load = 1'b0;
      best_store_found = 1'b0;
      best_store_addr_ready = 1'b1;
      best_store_data_ready = 1'b1;
      best_store_idx = '0;
      best_store_age = {TAG_W{1'b1}};
      load_age = rob_age(dst_arr[m], rob_head_i);
      store_age = '0;
      eff_addr = v1_arr[m] + op_arr[m].imm;
      store_eff_addr = '0;
      load_mask = load_be_mask(op_arr[m].lsu_op, eff_addr);
      store_mask = '0;
      store_addr_ready = 1'b0;
      store_data_ready = 1'b0;
      store_same_word = 1'b0;
      store_overlap = 1'b0;
      store_blocks_load = 1'b0;
      src_ready = (op_arr[m].has_rs1 ? r1_arr[m] : 1'b1) &&
                  (op_arr[m].has_rs2 ? r2_arr[m] : 1'b1);

      if (busy[m] && op_arr[m].is_load) begin
        for (int n = 0; n < RS_DEPTH; n++) begin
          store_age = rob_age(dst_arr[n], rob_head_i);
          store_blocks_load = 1'b0;
          store_addr_ready = !op_arr[n].has_rs1 || r1_arr[n];
          store_data_ready = !op_arr[n].has_rs2 || r2_arr[n];
          store_eff_addr = v1_arr[n] + op_arr[n].imm;
          store_mask = store_be_mask(op_arr[n].lsu_op, store_eff_addr);
          store_same_word = (store_eff_addr[RS_PAGE_OFFSET_W-1:RS_BYTE_OFF_W] ==
                             eff_addr[RS_PAGE_OFFSET_W-1:RS_BYTE_OFF_W]);
          store_overlap = store_same_word && (|(store_mask & load_mask));

          if (busy[n] && op_arr[n].is_store && (store_age < load_age)) begin
            store_blocks_load = !store_addr_ready ||
                                is_store_misaligned(op_arr[n].lsu_op, store_eff_addr) ||
                                is_strict_order_store(op_arr[n].lsu_op) ||
                                store_overlap;
            if (store_blocks_load) begin
              block_load = 1'b1;
              if (!best_store_found || (store_age < best_store_age)) begin
                best_store_found = 1'b1;
                best_store_age = store_age;
                best_store_addr_ready = store_addr_ready;
                best_store_data_ready = store_data_ready;
                best_store_idx = n[RS_IDX_W-1:0];
              end
            end
          end
        end
      end

      if (busy[m] && op_arr[m].is_load && src_ready && best_store_found) begin
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
          blocking_ready_store_mask_o[best_store_idx] = 1'b1;
        end
      end

      block_spec_low = spec_low_addr_block_en_i &&
                       busy[m] &&
                       src_ready &&
                       is_spec_low_addr(eff_addr) &&
                       (dst_arr[m] != rob_head_i);
      if (load_order_query_safe_i && load_order_query_valid_o &&
          (dst_arr[m] == load_order_query_rob_idx_o)) begin
        block_load = 1'b0;
        load_order_override_ready_mask_w[m] = 1'b1;
        if (load_order_query_forward_full_i) begin
          load_order_forward_full_ready_mask_w[m] = 1'b1;
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

  // Port 0
  assign out_op_0      = op_arr[sel_idx_0];
  assign out_dst_tag_0 = dst_arr[sel_idx_0];
  assign out_v1_0      = v1_arr[sel_idx_0];
  assign out_v2_0      = v2_arr[sel_idx_0];
  assign out_st_id_0   = st_arr[sel_idx_0];
  // Port 1
  assign out_op_1      = op_arr[sel_idx_1];
  assign out_dst_tag_1 = dst_arr[sel_idx_1];
  assign out_v1_1      = v1_arr[sel_idx_1];
  assign out_v2_1      = v2_arr[sel_idx_1];
  assign out_st_id_1   = st_arr[sel_idx_1];

  assign busy_vector   = busy;

  always_comb begin
    for (int i = 0; i < RS_DEPTH; i++) begin
      dst_tag_o[i] = dst_arr[i];
      plain_load_mask_o[i] = busy[i] && op_arr[i].is_load && !op_arr[i].is_store &&
                             (op_arr[i].lsu_op != decode_pkg::LSU_AMO) &&
                             (op_arr[i].lsu_op != decode_pkg::LSU_LR);
      ready_store_mask_o[i] = busy[i] && op_arr[i].is_store && ready_mask[i];
      store_busy_o[i] = busy[i] && op_arr[i].is_store;
      store_op_o[i] = op_arr[i];
      store_dst_tag_o[i] = dst_arr[i];
      store_v1_o[i] = v1_arr[i];
      store_r1_o[i] = r1_arr[i];
      store_v2_o[i] = v2_arr[i];
      store_r2_o[i] = r2_arr[i];
      store_st_id_o[i] = st_arr[i];
    end
  end

`ifndef SYNTHESIS
  function automatic logic watch_lsu_pc(input logic [31:0] pc);
    begin
      watch_lsu_pc = (pc == 32'hc074befe) ||
                     (pc == 32'hc076a580) ||
                     (pc == 32'hc076a584);
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs_lsu_trace_cnt_q <= '0;
    end else if (flush_i) begin
      rs_lsu_trace_cnt_q <= '0;
    end else if (rs_lsu_trace_en_q && (rs_lsu_trace_cnt_q < RS_LSU_TRACE_BUDGET)) begin
      int unsigned trace_inc;
      trace_inc = 0;
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (entry_wen[i] && watch_lsu_pc(in_op[i].pc) &&
            ((rs_lsu_trace_cnt_q + trace_inc) < RS_LSU_TRACE_BUDGET)) begin
          $display("[rs-lsu-enq] idx=%0d pc=%h dst=%0d sb=%0d in_v1=%h in_q1=%0d in_r1=%0d in_v2=%h in_q2=%0d in_r2=%0d grant=%0d busy_old=%0d",
                   i, in_op[i].pc, in_dst_tag[i], in_st_id[i],
                   in_v1[i], in_q1[i], in_r1[i], in_v2[i], in_q2[i], in_r2[i],
                   issue_grant[i], busy[i]);
          trace_inc++;
        end
        if (issue_grant[i] && busy[i] && watch_lsu_pc(op_arr[i].pc) &&
            ((rs_lsu_trace_cnt_q + trace_inc) < RS_LSU_TRACE_BUDGET)) begin
          $display("[rs-lsu-deq] idx=%0d pc=%h dst=%0d sb=%0d v1=%h q1=%0d r1=%0d v2=%h q2=%0d r2=%0d ready=%0d",
                   i, op_arr[i].pc, dst_arr[i], st_arr[i],
                   v1_arr[i], q1_arr[i], r1_arr[i], v2_arr[i], q2_arr[i], r2_arr[i], ready_mask[i]);
          trace_inc++;
        end
        if (entry_wen[i] && issue_grant[i] &&
            (watch_lsu_pc(in_op[i].pc) || (busy[i] && watch_lsu_pc(op_arr[i].pc))) &&
            ((rs_lsu_trace_cnt_q + trace_inc) < RS_LSU_TRACE_BUDGET)) begin
          $display("[rs-lsu-overlap] idx=%0d enq_pc=%h issue_pc=%h enq_dst=%0d issue_dst=%0d",
                   i, in_op[i].pc, op_arr[i].pc, in_dst_tag[i], dst_arr[i]);
          trace_inc++;
        end
      end
      if (trace_inc != 0) begin
        rs_lsu_trace_cnt_q <= rs_lsu_trace_cnt_q + trace_inc;
      end
    end
  end
`endif

endmodule
