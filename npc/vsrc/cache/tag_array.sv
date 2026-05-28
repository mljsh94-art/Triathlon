// vsrc/cache/tag_array.sv
// 2R1W Tag Array Module（外部接口保持 2R1W 语义，但内部是 multi-bank + 单端口 SRAM） 
module tag_array #(
    parameter int unsigned NUM_WAYS = 4,
    parameter int unsigned NUM_BANKS = 4,
    parameter int unsigned SETS_PER_BANK_WIDTH = 8,  // 每个Bank的Set数量的log2, 比如 256组/Bank -> 8
    parameter int unsigned TAG_WIDTH = 20,  // Tag的位宽
    parameter int unsigned VALID_WIDTH = 1  // 有效位的位宽 (可以扩展为 Dirty+Valid 等元数据)
) (
    input logic clk_i,
    input logic rst_ni,

    // --- 读端口 A (用于 Line 1) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] bank_addr_ra_i,  // Bank内读地址 A (Index)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_ra_i,    // Bank选择 A (用于寻址)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_ra_o_i,  // Bank选择 A (用于读数输出mux)
    output logic [NUM_WAYS-1:0][TAG_WIDTH-1:0] rdata_tag_a_o,  // 读出的Tag A
    output logic [NUM_WAYS-1:0][VALID_WIDTH-1:0] rdata_valid_a_o,  // 读出的Valid A

    // --- 读端口 B (用于 Line 2) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] bank_addr_rb_i,  // Bank内读地址 B (Index)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_rb_i,    // Bank选择 B (用于寻址)
    input logic [$clog2(NUM_BANKS)-1:0] bank_sel_rb_o_i,  // Bank选择 B (用于读数输出mux)
    output logic [NUM_WAYS-1:0][TAG_WIDTH-1:0] rdata_tag_b_o,  // 读出的Tag B
    output logic [NUM_WAYS-1:0][VALID_WIDTH-1:0] rdata_valid_b_o,  // 读出的Valid B

    // --- 写端口 (用于 Refill) ---
    input logic [SETS_PER_BANK_WIDTH-1:0] w_bank_addr_i,  // Bank内写地址 (Index)
    input logic [  $clog2(NUM_BANKS)-1:0] w_bank_sel_i,   // Bank选择 (写)
    input logic [           NUM_WAYS-1:0] we_way_mask_i,  // 写使能掩码
    input logic [          TAG_WIDTH-1:0] wdata_tag_i,    // 要写入的Tag
    input logic [        VALID_WIDTH-1:0] wdata_valid_i   // 要写入的Valid
);

  // 每个SRAM存储的数据 = Tag + Valids
  localparam int unsigned SRAM_DATA_WIDTH = TAG_WIDTH + VALID_WIDTH;
  localparam int unsigned SRAM_ADDR_WIDTH = SETS_PER_BANK_WIDTH;

  // 待写入的数据
  logic [SRAM_DATA_WIDTH-1:0] sram_wdata;
  assign sram_wdata = {wdata_tag_i, wdata_valid_i};

  // 每个 (way, bank) 一块单端口 SRAM 的读数据
  logic [SRAM_DATA_WIDTH-1:0]                      sram_rdata [NUM_WAYS][NUM_BANKS];

  // 对每个 bank 的公共控制信号（所有 way 共用同一个 addr/we/wdata）
  logic [      NUM_BANKS-1:0]                      bank_we;
  logic [      NUM_BANKS-1:0][SRAM_ADDR_WIDTH-1:0] bank_addr;
  logic [      NUM_BANKS-1:0][SRAM_DATA_WIDTH-1:0] bank_wdata;

  // --- bank 级别仲裁 ---
  // 优先级：写 > 读A > 读B
  always_comb begin
    // 默认值
    for (int b = 0; b < NUM_BANKS; b++) begin
      bank_we[b]    = 1'b0;
      bank_addr[b]  = '0;
      bank_wdata[b] = '0;
    end

    // 写（高优先级）
    if (|we_way_mask_i) begin
      bank_we[w_bank_sel_i]    = 1'b1;
      bank_addr[w_bank_sel_i]  = w_bank_addr_i;
      bank_wdata[w_bank_sel_i] = sram_wdata;
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
      // 同一 bank 的情况下，本拍 B 实际被饿死，读到的是上一拍的内容；
      // 外部使用时应保证不依赖这种冲突场景下 B 的读结果。
    end
  end

  // --- 实例化 NUM_WAYS * NUM_BANKS 个 1RW SRAM ---
  genvar i, j;
  generate
    for (i = 0; i < NUM_WAYS; i = i + 1) begin : gen_ways
      for (j = 0; j < NUM_BANKS; j = j + 1) begin : gen_banks
        // 对每个 (way, bank)，只有当该 way 被选中且该 bank 需要写时，才拉高 we
        logic local_we;
        assign local_we = bank_we[j] && we_way_mask_i[i];

        sram #(
            .DATA_WIDTH(SRAM_DATA_WIDTH),
            .ADDR_WIDTH(SRAM_ADDR_WIDTH)
        ) tag_sram_inst (
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
      // A 端口：从 bank_sel_ra_o_i 对应的Bank选择数据
      {rdata_tag_a_o[i], rdata_valid_a_o[i]} = sram_rdata[i][bank_sel_ra_o_i];

      // B 端口：从 bank_sel_rb_o_i 对应的Bank选择数据
      {rdata_tag_b_o[i], rdata_valid_b_o[i]} = sram_rdata[i][bank_sel_rb_o_i];
    end
  end

endmodule : tag_array

