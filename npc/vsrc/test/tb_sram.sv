// vsrc/test/tb_sram.sv
module tb_sram #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 8
) (
    input logic clk_i,
    input logic rst_ni,

    // --- 1RW 端口 ---
    input  logic                  we_i,     // 1: 写, 0: 读
    input  logic [ADDR_WIDTH-1:0] addr_i,   // 地址
    input  logic [DATA_WIDTH-1:0] wdata_i,  // 写数据
    output logic [DATA_WIDTH-1:0] rdata_o   // 读数据
);

  // 实例化 1RW SRAM
  sram #(
      .DATA_WIDTH(DATA_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) DUT (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .we_i   (we_i),
      .addr_i (addr_i),
      .wdata_i(wdata_i),
      .rdata_o(rdata_o)
  );

endmodule
