import config_pkg::*;

module ftq #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned DEPTH = 16,
    parameter int unsigned EPOCH_W = 3
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // === BPU 写入端 (Enqueue) ===
    input  logic                    enq_valid_i,
    output logic                    enq_ready_o,     // FIFO 未满
    input  logic [Cfg.PLEN-1:0]    enq_pc_i,
    input  logic                    enq_pred_slot_valid_i,
    input  logic [SLOT_IDX_W-1:0]  enq_pred_slot_idx_i,
    input  logic [Cfg.PLEN-1:0]    enq_pred_target_i,
    input  logic [Cfg.PLEN-1:0]    enq_pred_npc_i,   // 预测的下一个 fetch block PC
    input  logic [EPOCH_W-1:0]     enq_epoch_i,

    // === IFU 读取端 (Dequeue) ===
    output logic                    deq_valid_o,     // FIFO 非空
    input  logic                    deq_ready_i,     // IFU 消费
    output logic [Cfg.PLEN-1:0]    deq_pc_o,
    output logic                    deq_pred_slot_valid_o,
    output logic [SLOT_IDX_W-1:0]  deq_pred_slot_idx_o,
    output logic [Cfg.PLEN-1:0]    deq_pred_target_o,
    output logic [Cfg.PLEN-1:0]    deq_pred_npc_o,
    output logic [EPOCH_W-1:0]     deq_epoch_o,
    output logic [ID_W-1:0]        deq_ftq_id_o,    // 条目 ID = head_ptr，传递给下游

    // === 状态 ===
    output logic [CNT_W-1:0]       count_o
);

  localparam int unsigned ID_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int unsigned SLOT_IDX_W = (Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1;
  localparam int unsigned CNT_W = (DEPTH > 1) ? $clog2(DEPTH + 1) : 1;
  localparam int unsigned PTR_W = ID_W;  // pointer width = log2(DEPTH)

  // --- FIFO 存储 ---
  logic [DEPTH-1:0][Cfg.PLEN-1:0]    pc_q;
  logic [DEPTH-1:0]                   pred_slot_valid_q;
  logic [DEPTH-1:0][SLOT_IDX_W-1:0]  pred_slot_idx_q;
  logic [DEPTH-1:0][Cfg.PLEN-1:0]    pred_target_q;
  logic [DEPTH-1:0][Cfg.PLEN-1:0]    pred_npc_q;
  logic [DEPTH-1:0][EPOCH_W-1:0]     epoch_q;

  // --- Head / Tail 指针与计数 ---
  logic [PTR_W-1:0] head_q;
  logic [PTR_W-1:0] tail_q;
  logic [CNT_W-1:0] count_q;

  // --- 满/空判断 ---
  logic full_w;
  logic empty_w;
  assign full_w  = (count_q == CNT_W'(DEPTH));
  assign empty_w = (count_q == CNT_W'(0));

  // --- 入队/出队握手 ---
  logic enq_fire_w;
  logic deq_fire_w;
  assign enq_ready_o = !full_w && !flush_i;
  assign deq_valid_o = !empty_w && !flush_i;
  assign enq_fire_w  = enq_valid_i && enq_ready_o;
  assign deq_fire_w  = deq_valid_o && deq_ready_i;

  // --- 出队端口：读 head 位置的数据 ---
  assign deq_pc_o              = pc_q[head_q];
  assign deq_pred_slot_valid_o = pred_slot_valid_q[head_q];
  assign deq_pred_slot_idx_o   = pred_slot_idx_q[head_q];
  assign deq_pred_target_o     = pred_target_q[head_q];
  assign deq_pred_npc_o        = pred_npc_q[head_q];
  assign deq_epoch_o           = epoch_q[head_q];
  assign deq_ftq_id_o          = head_q;  // FTQ ID = head pointer

  // --- 状态输出 ---
  assign count_o = count_q;

  // --- 指针递增函数 ---
  function automatic [PTR_W-1:0] ptr_inc(input [PTR_W-1:0] ptr);
    if (ptr == PTR_W'(DEPTH - 1)) begin
      ptr_inc = '0;
    end else begin
      ptr_inc = ptr + PTR_W'(1);
    end
  endfunction

  // --- 时序逻辑 ---
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q            <= '0;
      tail_q            <= '0;
      count_q           <= '0;
      pc_q              <= '0;
      pred_slot_valid_q <= '0;
      pred_slot_idx_q   <= '0;
      pred_target_q     <= '0;
      pred_npc_q        <= '0;
      epoch_q           <= '0;
    end else begin
      if (flush_i) begin
        // Flush: 清空所有条目，指针归零
        head_q  <= '0;
        tail_q  <= '0;
        count_q <= '0;
      end else begin
        // 入队：写入 tail 位置，推进 tail
        if (enq_fire_w) begin
          pc_q[tail_q]              <= enq_pc_i;
          pred_slot_valid_q[tail_q] <= enq_pred_slot_valid_i;
          pred_slot_idx_q[tail_q]   <= enq_pred_slot_idx_i;
          pred_target_q[tail_q]     <= enq_pred_target_i;
          pred_npc_q[tail_q]        <= enq_pred_npc_i;
          epoch_q[tail_q]           <= enq_epoch_i;
          tail_q                    <= ptr_inc(tail_q);
        end

        // 出队：推进 head
        if (deq_fire_w) begin
          head_q <= ptr_inc(head_q);
        end

        // 更新计数
        unique case ({enq_fire_w, deq_fire_w})
          2'b10:   count_q <= count_q + CNT_W'(1);
          2'b01:   count_q <= count_q - CNT_W'(1);
          default: begin /* 同时 enq+deq 或无操作，计数不变 */ end
        endcase
      end
    end
  end

endmodule
