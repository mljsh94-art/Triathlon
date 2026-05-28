// 文件: npc/vsrc/test/tb_data_array.sv (修改版)
module tb_data_array #(
    parameter int unsigned NUM_WAYS_TEST = 4,
    parameter int unsigned NUM_BANKS_TEST = 4,
    parameter int unsigned SETS_PER_BANK_WIDTH_TEST = 8,
    parameter int unsigned BLOCK_WIDTH_TEST = 512
) (
    input logic clk_i,
    input logic rst_ni,

    // --- 读端口 A (用于 Line 1) ---
    input logic [SETS_PER_BANK_WIDTH_TEST-1:0] bank_addr_ra_i,
    input logic [$clog2(NUM_BANKS_TEST)-1:0] bank_sel_ra_i,
    output logic [NUM_WAYS_TEST-1:0][BLOCK_WIDTH_TEST-1:0] rdata_a_o,

    // --- 读端口 B (用于 Line 2) ---
    input logic [SETS_PER_BANK_WIDTH_TEST-1:0] bank_addr_rb_i,
    input logic [$clog2(NUM_BANKS_TEST)-1:0] bank_sel_rb_i,
    output logic [NUM_WAYS_TEST-1:0][BLOCK_WIDTH_TEST-1:0] rdata_b_o,

    // --- 写端口 ---
    input logic [SETS_PER_BANK_WIDTH_TEST-1:0] w_bank_addr_i,
    input logic [  $clog2(NUM_BANKS_TEST)-1:0] w_bank_sel_i,
    input logic [   NUM_WAYS_TEST-1:0] we_way_mask_i,
    input logic [BLOCK_WIDTH_TEST-1:0] wdata_i
);

  // --- 实例化 DUT ---
  data_array #(
      .NUM_WAYS(NUM_WAYS_TEST),
      .NUM_BANKS(NUM_BANKS_TEST),
      .SETS_PER_BANK_WIDTH(SETS_PER_BANK_WIDTH_TEST),
      .BLOCK_WIDTH(BLOCK_WIDTH_TEST)
  ) DUT (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      // 读端口 A
      .bank_addr_ra_i(bank_addr_ra_i),
      .bank_sel_ra_i(bank_sel_ra_i),
      .bank_sel_ra_o_i(bank_sel_ra_i),
      .rdata_a_o(rdata_a_o),

      // 读端口 B
      .bank_addr_rb_i(bank_addr_rb_i),
      .bank_sel_rb_i(bank_sel_rb_i),
      .bank_sel_rb_o_i(bank_sel_rb_i),
      .rdata_b_o(rdata_b_o),

      // 写端口
      .w_bank_addr_i(w_bank_addr_i),
      .w_bank_sel_i(w_bank_sel_i),
      .we_way_mask_i(we_way_mask_i),
      .wdata_i(wdata_i)
  );
endmodule
