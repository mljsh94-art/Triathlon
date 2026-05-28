// vsrc/backend/retire/writeback.sv
import config_pkg::*;
import decode_pkg::*;

module writeback #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned WB_WIDTH = 4,  // CDB 宽度 (对应 ROB/IQ 的写回端口数)
    parameter int unsigned NUM_FUS = 5,  // 功能单元总数 (例: ALU0, ALU1, BRU, LSU, MULT)
    parameter int unsigned ROB_IDX_WIDTH = $clog2(64)
) (
    // =========================================================
    // 1. Inputs from Functional Units (FUs)
    // =========================================================
    // 所有的功能单元将结果发送到这里
    input logic [NUM_FUS-1:0]                    fu_valid_i,
    input logic [NUM_FUS-1:0][     Cfg.XLEN-1:0] fu_data_i,
    input logic [NUM_FUS-1:0][ROB_IDX_WIDTH-1:0] fu_rob_idx_i,

    // 异常与分支预测信息 (来自 BRU / LSU)
    input logic [NUM_FUS-1:0]               fu_exception_i,
    input logic [NUM_FUS-1:0][         4:0] fu_ecause_i,
    input logic [NUM_FUS-1:0]               fu_is_mispred_i,
    input logic [NUM_FUS-1:0][Cfg.PLEN-1:0] fu_redirect_pc_i,

    // =========================================================
    // 2. Outputs to Functional Units (Backpressure)
    // =========================================================
    // 如果某功能单元想写回但未获批准 (CDB 满)，该信号为 0，FU 必须保持输出并 Stall
    output logic [NUM_FUS-1:0] fu_ready_o,

    // =========================================================
    // 3. Outputs to completion path (CDB + completion queue ingress)
    // =========================================================
    // 打包好的写回信号，连接到 ROB 和 Issue Queue
    output logic [WB_WIDTH-1:0]                    wb_valid_o,
    output logic [WB_WIDTH-1:0][     Cfg.XLEN-1:0] wb_data_o,
    output logic [WB_WIDTH-1:0][ROB_IDX_WIDTH-1:0] wb_rob_idx_o,

    output logic [WB_WIDTH-1:0]               wb_exception_o,
    output logic [WB_WIDTH-1:0][         4:0] wb_ecause_o,
    output logic [WB_WIDTH-1:0]               wb_is_mispred_o,
    output logic [WB_WIDTH-1:0][Cfg.PLEN-1:0] wb_redirect_pc_o
);

  // =========================================================
  // Priority Arbitration Logic
  // =========================================================
  // 将 N 个 FU 的请求映射到 M 个 CDB 端口
  // 策略：固定优先级 (Fixed Priority)，索引小的 FU 优先
  // (也可以改为 Round-Robin 以避免饥饿，但固定优先级逻辑最简单)

  always_comb begin
    automatic int cdb_idx = 0;
    // 默认初始化
    wb_valid_o       = '0;
    wb_data_o        = '0;
    wb_rob_idx_o     = '0;
    wb_exception_o   = '0;
    wb_ecause_o      = '0;
    wb_is_mispred_o  = '0;
    wb_redirect_pc_o = '0;

    fu_ready_o       = '0;  // 默认所有 FU 都被阻塞

    // 临时变量：当前已分配的 CDB 端口索引


    // 遍历所有功能单元
    for (int i = 0; i < NUM_FUS; i++) begin
      if (fu_valid_i[i]) begin
        // 如果还有剩余的 CDB 端口
        if (cdb_idx < WB_WIDTH) begin
          // --- 授予写回权限 ---

          // 1. 路由数据到对应的 CDB 端口
          wb_valid_o[cdb_idx]       = 1'b1;
          wb_data_o[cdb_idx]        = fu_data_i[i];
          wb_rob_idx_o[cdb_idx]     = fu_rob_idx_i[i];

          wb_exception_o[cdb_idx]   = fu_exception_i[i];
          wb_ecause_o[cdb_idx]      = fu_ecause_i[i];
          wb_is_mispred_o[cdb_idx]  = fu_is_mispred_i[i];
          wb_redirect_pc_o[cdb_idx] = fu_redirect_pc_i[i];

          // 2. 告知 FU 发送成功
          fu_ready_o[i]             = 1'b1;

          // 3. 移动到下一个 CDB 端口
          cdb_idx++;
        end else begin
          // --- CDB 已满 ---
          // fu_ready_o[i] 保持为 0，功能单元需要在下一周期重试
        end
      end else begin
        // FU 没有请求，视为 Ready (不阻塞 pipeline)
        fu_ready_o[i] = 1'b1;
      end
    end
  end

endmodule
