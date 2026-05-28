module tb_bundle_fifo (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,

    input  logic        enq_valid_i,
    output logic        enq_ready_o,
    input  logic [31:0] enq_data_i,

    output logic        deq_valid_o,
    input  logic        deq_ready_i,
    output logic [31:0] deq_data_o,

    output logic [3:0]  dbg_count_o,
    output logic        dbg_full_o,
    output logic        dbg_empty_o
);

  bundle_fifo #(
      .DATA_W(32),
      .DEPTH(4),
      .BYPASS_EN(1)
  ) dut (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .flush_i(flush_i),
      .enq_valid_i(enq_valid_i),
      .enq_ready_o(enq_ready_o),
      .enq_data_i(enq_data_i),
      .deq_valid_o(deq_valid_o),
      .deq_ready_i(deq_ready_i),
      .deq_data_o(deq_data_o),
      .count_o(dbg_count_o),
      .full_o(dbg_full_o),
      .empty_o(dbg_empty_o)
  );

endmodule
