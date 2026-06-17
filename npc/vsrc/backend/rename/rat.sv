// vsrc/backend/rename/rat.sv
// 适用于 Data-in-ROB 架构的 Speculative RAT
import config_pkg::*;

module rat #(
    parameter int unsigned ROB_DEPTH = 64,
    parameter int unsigned ROB_IDX_WIDTH = $clog2(ROB_DEPTH),  // 原 PHY_REG_ADDR_WIDTH
    parameter int unsigned DISPATCH_WIDTH = 4,
    parameter int unsigned AREG_NUM = 32
) (
    input logic clk_i,
    input logic rst_ni,

    // =========================================================
    // 1. Rename Stage: Source Lookup (读端口)
    // =========================================================
    // 输入：源寄存器逻辑号
    input logic [DISPATCH_WIDTH-1:0][4:0] rs1_idx_i,
    input logic [DISPATCH_WIDTH-1:0][4:0] rs2_idx_i,

    // 输出：告诉 Issue Queue 数据在哪里
    // in_rob_o = 1: 数据在 ROB 中 (Wait for CDB/WB), Tag = rob_idx_o
    // in_rob_o = 0: 数据在 ARF 中 (Ready), 直接读 ARF
    output logic [DISPATCH_WIDTH-1:0]                    rs1_in_rob_o,
    output logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] rs1_rob_idx_o,

    output logic [DISPATCH_WIDTH-1:0]                    rs2_in_rob_o,
    output logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] rs2_rob_idx_o,

    // =========================================================
    // 2. Dispatch Stage: Allocation (写端口)
    // =========================================================
    // 新指令进入 ROB，将其逻辑目标寄存器映射到新的 ROB ID
    input logic [DISPATCH_WIDTH-1:0]                    disp_we_i,      // 是否写寄存器
    input logic [DISPATCH_WIDTH-1:0][              4:0] disp_rd_idx_i,  // 逻辑目标寄存器
    input logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] disp_rob_idx_i, // 分配到的 ROB ID

    // =========================================================
    // 3. Commit Stage: Retirement Update (状态更新)
    // =========================================================
    // 当指令退休时，如果 RAT 还指向该 ROB ID，说明数据已进入 ARF，需更新 RAT 指向 ARF
    input logic [DISPATCH_WIDTH-1:0]                    commit_we_i,      // ROB commit_we
    input logic [DISPATCH_WIDTH-1:0][              4:0] commit_rd_idx_i,  // ROB commit_areg
    input logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] commit_rob_idx_i, // 退休指令的 ROB ID (Head Ptr)

    // =========================================================
    // 4. Recovery
    // =========================================================
    input logic flush_i  // 发生分支预测失败/异常，重置 RAT 指向 ARF
);

  // RAT 表项结构
  typedef struct packed {
    logic in_rob;  // 1: 映射到 ROB; 0: 映射到 ARF
    logic [ROB_IDX_WIDTH-1:0] tag;  // ROB ID
  } rat_entry_t;

  rat_entry_t map_table[AREG_NUM];
`ifndef SYNTHESIS
  localparam logic [4:0] RAT_WATCH_AREG = 5'd18;
  localparam int unsigned RAT_TRACE_BUDGET = 1024;
  logic [31:0] rat_trace_cnt_q;
  logic rat_trace_en_q;
  initial rat_trace_en_q = $test$plusargs("npc_diag_trace");
  function automatic logic watch_tag(input logic [ROB_IDX_WIDTH-1:0] tag);
    begin
      watch_tag = (tag == ROB_IDX_WIDTH'(22)) || (tag == ROB_IDX_WIDTH'(44));
    end
  endfunction
`endif

  // ---------------------------------------------------------
  // 1. Read Logic (Combinational)
  // ---------------------------------------------------------
  always_comb begin
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      // RS1
      if (rs1_idx_i[i] == '0) begin  // R0 恒为 0 (ARF)
        rs1_in_rob_o[i]  = 1'b0;
        rs1_rob_idx_o[i] = '0;
      end else begin
        rs1_in_rob_o[i]  = map_table[rs1_idx_i[i]].in_rob;
        rs1_rob_idx_o[i] = map_table[rs1_idx_i[i]].tag;
      end

      // RS2
      if (rs2_idx_i[i] == '0) begin
        rs2_in_rob_o[i]  = 1'b0;
        rs2_rob_idx_o[i] = '0;
      end else begin
        rs2_in_rob_o[i]  = map_table[rs2_idx_i[i]].in_rob;
        rs2_rob_idx_o[i] = map_table[rs2_idx_i[i]].tag;
      end
    end
  end

  // ---------------------------------------------------------
  // 2. Update Logic (Sequential)
  // ---------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // 复位：所有映射指向 ARF (in_rob = 0)
      for (int i = 0; i < AREG_NUM; i++) begin
        map_table[i].in_rob <= 1'b0;
        map_table[i].tag    <= '0;
      end
`ifndef SYNTHESIS
      rat_trace_cnt_q <= '0;
`endif
    end else if (flush_i) begin
      // 异常冲刷：所有推测状态失效，回退到 ARF (in_rob = 0)
      // 因为 ARF 总是保存着最新的 Committed 状态
      for (int i = 0; i < AREG_NUM; i++) begin
        map_table[i].in_rob <= 1'b0;
      end
`ifndef SYNTHESIS
      if (rat_trace_en_q &&
          (rat_trace_cnt_q < RAT_TRACE_BUDGET) && map_table[RAT_WATCH_AREG].in_rob &&
          watch_tag(map_table[RAT_WATCH_AREG].tag)) begin
        $display("[rat-watch-flush] areg=%0d old_in_rob=%0d old_tag=%0d", RAT_WATCH_AREG,
                 map_table[RAT_WATCH_AREG].in_rob, map_table[RAT_WATCH_AREG].tag);
        rat_trace_cnt_q <= rat_trace_cnt_q + 32'd1;
      end
`endif
    end else begin

      // --- A. Commit 更新 (将状态从 Speculative 改为 Committed) ---
      for (int i = 0; i < DISPATCH_WIDTH; i++) begin
        // 如果有一条指令退休，并且它写了寄存器
        if (commit_we_i[i] && commit_rd_idx_i[i] != '0) begin
          automatic logic [4:0] rd = commit_rd_idx_i[i];
          // 检查 RAT 是否仍指向这条刚退休的指令
          // 只有当 (in_rob == 1) 且 (tag == retiring_rob_id) 时才清除
          if (map_table[rd].in_rob && map_table[rd].tag == commit_rob_idx_i[i]) begin
            map_table[rd].in_rob <= 1'b0;  // 现在去 ARF 找这个数据
`ifndef SYNTHESIS
            if (rat_trace_en_q &&
                (rat_trace_cnt_q < RAT_TRACE_BUDGET) && (rd == RAT_WATCH_AREG) &&
                watch_tag(commit_rob_idx_i[i])) begin
              $display("[rat-watch-commit-clear] areg=%0d commit_tag=%0d old_in_rob=%0d old_tag=%0d",
                       rd, commit_rob_idx_i[i], map_table[rd].in_rob, map_table[rd].tag);
              rat_trace_cnt_q <= rat_trace_cnt_q + 32'd1;
            end
`endif
          end
        end
      end

      // --- B. Dispatch 更新 (建立新的 Speculative 映射) ---
      // 注意：Dispatch 必须覆盖 Commit 的更新 (如果在同一周期对同一寄存器操作)
      // 因为 Dispatch 是更新的指令 (Younger)，覆盖旧的退休状态。
      for (int i = 0; i < DISPATCH_WIDTH; i++) begin
        if (disp_we_i[i] && disp_rd_idx_i[i] != '0) begin
          map_table[disp_rd_idx_i[i]].in_rob <= 1'b1;
          map_table[disp_rd_idx_i[i]].tag    <= disp_rob_idx_i[i];
`ifndef SYNTHESIS
          if (rat_trace_en_q &&
              (rat_trace_cnt_q < RAT_TRACE_BUDGET) && (disp_rd_idx_i[i] == RAT_WATCH_AREG) &&
              (watch_tag(disp_rob_idx_i[i]) || watch_tag(map_table[disp_rd_idx_i[i]].tag))) begin
            $display("[rat-watch-disp] areg=%0d new_tag=%0d old_in_rob=%0d old_tag=%0d",
                     disp_rd_idx_i[i], disp_rob_idx_i[i],
                     map_table[disp_rd_idx_i[i]].in_rob, map_table[disp_rd_idx_i[i]].tag);
            rat_trace_cnt_q <= rat_trace_cnt_q + 32'd1;
          end
`endif
        end
      end
    end
  end

endmodule
