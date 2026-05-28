// vsrc/backend/regfile/arf.sv
import config_pkg::*;

module arf #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned COMMIT_WIDTH = Cfg.NRET
) (
    input logic clk_i,
    input logic rst_ni,

    // --- Commit Write Ports (From ROB) ---
    // 只有退休时才写入
    input logic [COMMIT_WIDTH-1:0]               we_i,
    input logic [COMMIT_WIDTH-1:0][         4:0] waddr_i,
    input logic [COMMIT_WIDTH-1:0][Cfg.XLEN-1:0] wdata_i,

    // --- Read Ports (For Issue/Operand Fetch) ---
    // 4-way issue 需要 8 个读端口 (rs1[4] + rs2[4])
    input logic [7:0][4:0] raddr_i,
    output logic [7:0][Cfg.XLEN-1:0] rdata_o
);

  // 32 个架构寄存器 (R0-R31)
  logic [Cfg.XLEN-1:0] regs[32];

  // --- 读逻辑 ---
  always_comb begin
    for (int i = 0; i < 8; i++) begin
      if (raddr_i[i] == 0) rdata_o[i] = '0;
      else rdata_o[i] = regs[raddr_i[i]];
    end
  end

  // --- 写逻辑 ---
  // 注意：如果有多个指令同时退休写同一个寄存器 (WAW)，
  // 必须保证最后一条指令的数据生效。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < 32; i++) regs[i] <= '0;
    end else begin
      for (int i = 0; i < COMMIT_WIDTH; i++) begin
        if (we_i[i] && waddr_i[i] != 0) begin
          regs[waddr_i[i]] <= wdata_i[i];
        end
      end
    end
  end

endmodule
