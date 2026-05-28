// vsrc/cache/sram.sv
// 1RW 单端口 SRAM
module sram #(
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned ADDR_WIDTH = 10
) (
    input logic clk_i,
    input logic rst_ni,

    input  logic                  we_i,     // 1: 写, 0: 读
    input  logic [ADDR_WIDTH-1:0] addr_i,   // 读写共用地址口
    input  logic [DATA_WIDTH-1:0] wdata_i,
    output logic [DATA_WIDTH-1:0] rdata_o
);

  // 简单建模，综合会推到 SRAM 宏
  logic [DATA_WIDTH-1:0] mem[0:(1<<ADDR_WIDTH)-1];

  // 同步读写；这里写优先 (write-first)，你可以按需要改成 read-first
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Reset must clear SRAM contents so cache valid/meta bits are deterministic.
      for (int i = 0; i < (1 << ADDR_WIDTH); i++) begin
        mem[i] = '0;
      end
      rdata_o <= '0;
    end else begin
      if (we_i) begin
        mem[addr_i] <= wdata_i;
      end
      // 同个时钟边沿读出 addr_i 地址的数据
      rdata_o <= mem[addr_i];
    end
  end

endmodule : sram
