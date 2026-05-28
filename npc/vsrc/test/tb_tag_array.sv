// 文件: npc/vsrc/test/tb_tag_array.sv (修改版)
module tb_tag_array #(
    parameter int unsigned NUM_WAYS_TEST = 4,
    parameter int unsigned NUM_BANKS_TEST = 4,
    parameter int unsigned SETS_PER_BANK_WIDTH_TEST = 8,
    parameter int unsigned TAG_WIDTH_TEST = 20,
    parameter int unsigned VALID_WIDTH_TEST = 1
) (
    input logic clk_i,
    input logic rst_ni,

    // --- 读端口 A ---
    input logic [SETS_PER_BANK_WIDTH_TEST-1:0] bank_addr_ra_i,
    input logic [$clog2(NUM_BANKS_TEST)-1:0] bank_sel_ra_i,
    output logic [NUM_WAYS_TEST-1:0][TAG_WIDTH_TEST-1:0] rdata_tag_a_o,
    output logic [NUM_WAYS_TEST-1:0][VALID_WIDTH_TEST-1:0] rdata_valid_a_o,

    // --- 读端口 B ---
    input logic [SETS_PER_BANK_WIDTH_TEST-1:0] bank_addr_rb_i,
    input logic [$clog2(NUM_BANKS_TEST)-1:0] bank_sel_rb_i,
    output logic [NUM_WAYS_TEST-1:0][TAG_WIDTH_TEST-1:0] rdata_tag_b_o,
    output logic [NUM_WAYS_TEST-1:0][VALID_WIDTH_TEST-1:0] rdata_valid_b_o,

    // --- 写端口 ---
    input logic [SETS_PER_BANK_WIDTH_TEST-1:0] w_bank_addr_i,
    input logic [  $clog2(NUM_BANKS_TEST)-1:0] w_bank_sel_i,
    input logic [   NUM_WAYS_TEST-1:0] we_way_mask_i,
    input logic [  TAG_WIDTH_TEST-1:0] wdata_tag_i,
    input logic [VALID_WIDTH_TEST-1:0] wdata_valid_i
);

  // --- 实例化 DUT ---
  tag_array #(
      .NUM_WAYS(NUM_WAYS_TEST),
      .NUM_BANKS(NUM_BANKS_TEST),
      .SETS_PER_BANK_WIDTH(SETS_PER_BANK_WIDTH_TEST),
      .TAG_WIDTH(TAG_WIDTH_TEST),
      .VALID_WIDTH(VALID_WIDTH_TEST)
  ) DUT (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      // 读 A
      .bank_addr_ra_i (bank_addr_ra_i),
      .bank_sel_ra_i  (bank_sel_ra_i),
      .bank_sel_ra_o_i(bank_sel_ra_i),
      .rdata_tag_a_o  (rdata_tag_a_o),
      .rdata_valid_a_o(rdata_valid_a_o),

      // 读 B
      .bank_addr_rb_i (bank_addr_rb_i),
      .bank_sel_rb_i  (bank_sel_rb_i),
      .bank_sel_rb_o_i(bank_sel_rb_i),
      .rdata_tag_b_o  (rdata_tag_b_o),
      .rdata_valid_b_o(rdata_valid_b_o),

      // 写
      .w_bank_addr_i(w_bank_addr_i),
      .w_bank_sel_i (w_bank_sel_i),
      .we_way_mask_i(we_way_mask_i),
      .wdata_tag_i  (wdata_tag_i),
      .wdata_valid_i(wdata_valid_i)
  );
endmodule
