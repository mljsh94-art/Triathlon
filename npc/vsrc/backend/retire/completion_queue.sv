import config_pkg::*;

module completion_queue #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned WB_WIDTH = 4,
    parameter int unsigned ROB_IDX_WIDTH = 6,
    parameter int unsigned DEPTH = 32
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input logic [WB_WIDTH-1:0] enq_valid_i,
    input logic [WB_WIDTH-1:0][Cfg.XLEN-1:0] enq_data_i,
    input logic [WB_WIDTH-1:0][ROB_IDX_WIDTH-1:0] enq_rob_idx_i,
    input logic [WB_WIDTH-1:0] enq_exception_i,
    input logic [WB_WIDTH-1:0][4:0] enq_ecause_i,
    input logic [WB_WIDTH-1:0] enq_is_mispred_i,
    input logic [WB_WIDTH-1:0][Cfg.PLEN-1:0] enq_redirect_pc_i,

    output logic [WB_WIDTH-1:0] deq_valid_o,
    output logic [WB_WIDTH-1:0][Cfg.XLEN-1:0] deq_data_o,
    output logic [WB_WIDTH-1:0][ROB_IDX_WIDTH-1:0] deq_rob_idx_o,
    output logic [WB_WIDTH-1:0] deq_exception_o,
    output logic [WB_WIDTH-1:0][4:0] deq_ecause_o,
    output logic [WB_WIDTH-1:0] deq_is_mispred_o,
    output logic [WB_WIDTH-1:0][Cfg.PLEN-1:0] deq_redirect_pc_o,

    output logic [$clog2(DEPTH + 1)-1:0] count_o
);

  localparam int unsigned CNT_WIDTH = $clog2(DEPTH + 1);

  logic [DEPTH-1:0] entry_valid_q, entry_valid_d;
  logic [DEPTH-1:0][Cfg.XLEN-1:0] entry_data_q, entry_data_d;
  logic [DEPTH-1:0][ROB_IDX_WIDTH-1:0] entry_rob_idx_q, entry_rob_idx_d;
  logic [DEPTH-1:0] entry_exception_q, entry_exception_d;
  logic [DEPTH-1:0][4:0] entry_ecause_q, entry_ecause_d;
  logic [DEPTH-1:0] entry_is_mispred_q, entry_is_mispred_d;
  logic [DEPTH-1:0][Cfg.PLEN-1:0] entry_redirect_pc_q, entry_redirect_pc_d;
  logic [CNT_WIDTH-1:0] count_q, count_d;
  assign count_o = count_q;

  always_comb begin
    deq_valid_o = '0;
    deq_data_o = '0;
    deq_rob_idx_o = '0;
    deq_exception_o = '0;
    deq_ecause_o = '0;
    deq_is_mispred_o = '0;
    deq_redirect_pc_o = '0;

    for (int i = 0; i < WB_WIDTH; i++) begin
      if (i < int'(count_q)) begin
        deq_valid_o[i] = entry_valid_q[i];
        deq_data_o[i] = entry_data_q[i];
        deq_rob_idx_o[i] = entry_rob_idx_q[i];
        deq_exception_o[i] = entry_exception_q[i];
        deq_ecause_o[i] = entry_ecause_q[i];
        deq_is_mispred_o[i] = entry_is_mispred_q[i];
        deq_redirect_pc_o[i] = entry_redirect_pc_q[i];
      end
    end
  end

  always_comb begin
    int deq_count;
    int write_idx;

    entry_valid_d = '0;
    entry_data_d = '0;
    entry_rob_idx_d = '0;
    entry_exception_d = '0;
    entry_ecause_d = '0;
    entry_is_mispred_d = '0;
    entry_redirect_pc_d = '0;
    count_d = '0;

    deq_count = (int'(count_q) > WB_WIDTH) ? WB_WIDTH : int'(count_q);
    write_idx = 0;

    for (int i = deq_count; i < int'(count_q); i++) begin
      entry_valid_d[write_idx] = entry_valid_q[i];
      entry_data_d[write_idx] = entry_data_q[i];
      entry_rob_idx_d[write_idx] = entry_rob_idx_q[i];
      entry_exception_d[write_idx] = entry_exception_q[i];
      entry_ecause_d[write_idx] = entry_ecause_q[i];
      entry_is_mispred_d[write_idx] = entry_is_mispred_q[i];
      entry_redirect_pc_d[write_idx] = entry_redirect_pc_q[i];
      write_idx++;
    end

    for (int i = 0; i < WB_WIDTH; i++) begin
      if (enq_valid_i[i] && (write_idx < DEPTH)) begin
        entry_valid_d[write_idx] = 1'b1;
        entry_data_d[write_idx] = enq_data_i[i];
        entry_rob_idx_d[write_idx] = enq_rob_idx_i[i];
        entry_exception_d[write_idx] = enq_exception_i[i];
        entry_ecause_d[write_idx] = enq_ecause_i[i];
        entry_is_mispred_d[write_idx] = enq_is_mispred_i[i];
        entry_redirect_pc_d[write_idx] = enq_redirect_pc_i[i];
        write_idx++;
      end
    end

    count_d = CNT_WIDTH'(write_idx);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      entry_valid_q <= '0;
      entry_data_q <= '0;
      entry_rob_idx_q <= '0;
      entry_exception_q <= '0;
      entry_ecause_q <= '0;
      entry_is_mispred_q <= '0;
      entry_redirect_pc_q <= '0;
      count_q <= '0;
    end else if (flush_i) begin
      entry_valid_q <= '0;
      entry_data_q <= '0;
      entry_rob_idx_q <= '0;
      entry_exception_q <= '0;
      entry_ecause_q <= '0;
      entry_is_mispred_q <= '0;
      entry_redirect_pc_q <= '0;
      count_q <= '0;
    end else begin
      entry_valid_q <= entry_valid_d;
      entry_data_q <= entry_data_d;
      entry_rob_idx_q <= entry_rob_idx_d;
      entry_exception_q <= entry_exception_d;
      entry_ecause_q <= entry_ecause_d;
      entry_is_mispred_q <= entry_is_mispred_d;
      entry_redirect_pc_q <= entry_redirect_pc_d;
      count_q <= count_d;
    end
  end

  initial begin
    assert (DEPTH > 0)
    else $fatal(1, "completion_queue DEPTH must be > 0");
  end

endmodule
