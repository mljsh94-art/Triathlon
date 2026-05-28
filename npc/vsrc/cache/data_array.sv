// vsrc/cache/data_array.sv
module data_array #(
    parameter int unsigned NUM_WAYS = 4,
    parameter int unsigned NUM_BANKS = 4,
    parameter int unsigned SETS_PER_BANK_WIDTH = 8,  // 每个Bank的Set数量的log2
    parameter int unsigned BLOCK_WIDTH = 512  // 缓存块的位宽 (例如 64 Bytes * 8 bits)
) (
    input logic clk_i,
    input logic rst_ni,

    // --- 读端口 A (用于 Line 1) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] bank_addr_ra_i,  // Bank内读地址 A (Index)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_ra_i,    // Bank选择 A (用于寻址)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_ra_o_i,  // Bank选择 A (用于读数输出mux)
    output logic [NUM_WAYS-1:0][BLOCK_WIDTH-1:0] rdata_a_o,  // 读数据 A (所有Way)

    // --- 读端口 B (用于 Line 2) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] bank_addr_rb_i,  // Bank内读地址 B (Index)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_rb_i,    // Bank选择 B (用于寻址)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_rb_o_i,  // Bank选择 B (用于读数输出mux)
    output logic [NUM_WAYS-1:0][BLOCK_WIDTH-1:0] rdata_b_o,  // 读数据 B (所有Way)

    // --- 写端口 (用于 Refill) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] w_bank_addr_i,  // Bank内写地址 (Index)
    input logic [  $clog2(NUM_BANKS)-1:0] w_bank_sel_i,   // Bank选择 (写)
    input logic [           NUM_WAYS-1:0] we_way_mask_i,  // 写使能掩码, 决定写哪一路
    input logic [        BLOCK_WIDTH-1:0] wdata_i         // 要写入的数据块
);

  localparam int unsigned SRAM_DATA_WIDTH = BLOCK_WIDTH;
  localparam int unsigned SRAM_ADDR_WIDTH = SETS_PER_BANK_WIDTH;

  // 每个 (way, bank) 一块单端口 SRAM 的读数据
  logic [SRAM_DATA_WIDTH-1:0]                      sram_rdata [NUM_WAYS][NUM_BANKS];

  // bank 级别控制信号
  logic [      NUM_BANKS-1:0]                      bank_we;
  logic [      NUM_BANKS-1:0][SRAM_ADDR_WIDTH-1:0] bank_addr;
  logic [      NUM_BANKS-1:0][SRAM_DATA_WIDTH-1:0] bank_wdata;

  // --- bank 级别仲裁 ---
  // 优先级：写 > 读A > 读B
  always_comb begin
    for (int b = 0; b < NUM_BANKS; b++) begin
      bank_we[b]    = 1'b0;
      bank_addr[b]  = '0;
      bank_wdata[b] = '0;
    end

    // 写
    if (|we_way_mask_i) begin
      bank_we[w_bank_sel_i]    = 1'b1;
      bank_addr[w_bank_sel_i]  = w_bank_addr_i;
      bank_wdata[w_bank_sel_i] = wdata_i;
    end

    // 读 A
    // 如果该 bank 本拍在写，则读 A 被写操作抢占，不应覆盖 bank_addr。
    begin
      int b = bank_sel_ra_i;
      if (!(|we_way_mask_i) || (w_bank_sel_i != bank_sel_ra_i)) begin
        bank_addr[b] = bank_addr_ra_i;
      end
    end

    // 读 B：
    // 1) 如果落在和 A 不同的 bank，则可以正常访问；
    // 2) 如果该 bank 本拍在写，则读 B 被写操作抢占；
    // 3) 如果 bank_sel_rb_i == bank_sel_ra_i，该 bank 本拍只能服务 A（或者写）。
    begin
      int b_rb = bank_sel_rb_i;
      int b_ra = bank_sel_ra_i;
      if (b_rb != b_ra) begin
        if (!(|we_way_mask_i) || (w_bank_sel_i != bank_sel_rb_i)) begin
          bank_addr[b_rb] = bank_addr_rb_i;
        end
      end
      // bank 冲突时，本拍 B 没被服务，读到的是上一拍的内容
    end
  end

  // --- 实例化 NUM_WAYS * NUM_BANKS 个 1RW SRAM ---
  genvar i, j;
  generate
    for (i = 0; i < NUM_WAYS; i = i + 1) begin : gen_ways
      for (j = 0; j < NUM_BANKS; j = j + 1) begin : gen_banks
        logic local_we;
        assign local_we = bank_we[j] && we_way_mask_i[i];

        sram #(
            .DATA_WIDTH(SRAM_DATA_WIDTH),
            .ADDR_WIDTH(SRAM_ADDR_WIDTH)
        ) data_sram_inst (
            .clk_i  (clk_i),
            .rst_ni (rst_ni),
            .we_i   (local_we),
            .addr_i (bank_addr[j]),
            .wdata_i(bank_wdata[j]),
            .rdata_o(sram_rdata[i][j])
        );
      end
    end
  endgenerate

  // --- 读数据选择 (Mux) ---
  always_comb begin
    for (int i = 0; i < NUM_WAYS; i++) begin
      // 从正确的Bank为Port A选择数据
      rdata_a_o[i] = sram_rdata[i][bank_sel_ra_o_i];
      // 从正确的Bank为Port B选择数据
      rdata_b_o[i] = sram_rdata[i][bank_sel_rb_o_i];
    end
  end

endmodule : data_array
