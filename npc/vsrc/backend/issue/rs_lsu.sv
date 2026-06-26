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
    output logic [   TAG_W-1:0] dst_tag_o[0:RS_DEPTH-1]
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

    for (int i = 0; i < RS_DEPTH; i++) begin
      if (issue_grant[i]) begin
        busy_d[i] = 1'b0;
      end else if (entry_wen[i]) begin
        busy_d[i]    = 1'b1;
        op_arr_d[i]  = in_op[i];
        dst_arr_d[i] = in_dst_tag[i];
        st_arr_d[i]  = in_st_id[i];

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
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= {RS_DEPTH{1'b0}};
    end else if (flush_i) begin
      busy <= {RS_DEPTH{1'b0}};
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
    end
  end

  // Load/store ordering: block loads behind older stores.
  always_comb begin
    for (int m = 0; m < RS_DEPTH; m++) begin
      logic block_load;
      logic src_ready;
      logic block_spec_low;
      logic [DATA_W-1:0] eff_addr;
      block_load = 1'b0;
      if (busy[m] && op_arr[m].is_load) begin
        for (int n = 0; n < RS_DEPTH; n++) begin
          if (busy[n] && op_arr[n].is_store) begin
            if (rob_age(dst_arr[n], rob_head_i) < rob_age(dst_arr[m], rob_head_i)) begin
              block_load = 1'b1;
            end
          end
        end
      end
      src_ready = (op_arr[m].has_rs1 ? r1_arr[m] : 1'b1) &&
                  (op_arr[m].has_rs2 ? r2_arr[m] : 1'b1);
      eff_addr = v1_arr[m] + op_arr[m].imm;
      block_spec_low = spec_low_addr_block_en_i &&
                       busy[m] &&
                       src_ready &&
                       is_spec_low_addr(eff_addr) &&
                       (dst_arr[m] != rob_head_i);
      ready_mask[m] = busy[m] && src_ready && !block_load && !block_spec_low;
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
