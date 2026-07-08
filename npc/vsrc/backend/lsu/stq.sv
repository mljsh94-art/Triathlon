// vsrc/backend/lsu/stq.sv
import config_pkg::*;
import decode_pkg::*;

module stq #(
    parameter int unsigned SB_DEPTH = 32,  // STQ 深度
    parameter int unsigned ROB_IDX_WIDTH = 6,
    parameter int unsigned DISPATCH_WIDTH = 4,
    parameter int unsigned COMMIT_WIDTH = 4,
    parameter int unsigned ECAUSE_WIDTH = 5
) (
    input logic clk_i,
    input logic rst_ni,

    // =======================================================
    // 1. Dispatch (From Rename) - 分配 STQ 條目
    // =======================================================
    input logic [DISPATCH_WIDTH-1:0] alloc_req_i,
    input logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] alloc_rob_idx_i,
    output logic alloc_ready_o,  // STQ 可接受本周期所有请求
    output logic [DISPATCH_WIDTH-1:0][$clog2(SB_DEPTH)-1:0] alloc_id_o,  // 分配到的 STQ ID（每条store）
    input logic alloc_fire_i,  // 真正执行分配（由上游控制）

    // =======================================================
    // 2. Execute fill ports - STA/STD split, currently driven together
    // =======================================================
    // STA writes address/op/ROB tag; STD writes store data. Stage 2 keeps
    // behavior equivalent by driving both ports from the old store execute path.
    input logic                                       sta_valid_i,
    input logic                [$clog2(SB_DEPTH)-1:0] sta_st_id_i,
    input logic                [        Cfg.PLEN-1:0] sta_addr_i,
    input decode_pkg::lsu_op_e                        sta_op_i,
    input logic                [   ROB_IDX_WIDTH-1:0] sta_rob_idx_i,

    input logic                                       std_valid_i,
    input logic                [$clog2(SB_DEPTH)-1:0] std_st_id_i,
    input logic                [        Cfg.XLEN-1:0] std_data_i,

    // Early STD writes store data and is allowed to target a different entry
    // from the full store execute STD in the same cycle.
    input logic                                       std_early_valid_i,
    input logic                [$clog2(SB_DEPTH)-1:0] std_early_st_id_i,
    input logic                [        Cfg.XLEN-1:0] std_early_data_i,

    // Early STA writes only address/op/tag and is allowed to target a different
    // entry from the full store execute STA in the same cycle.
    input logic                                       sta_early_valid_i,
    input logic                [$clog2(SB_DEPTH)-1:0] sta_early_st_id_i,
    input logic                [        Cfg.PLEN-1:0] sta_early_addr_i,
    input decode_pkg::lsu_op_e                        sta_early_op_i,
    input logic                [   ROB_IDX_WIDTH-1:0] sta_early_rob_idx_i,

    // =======================================================
    // 3. Commit (From ROB) - 標記為 "Senior Store"
    // =======================================================
    // ROB 只要發個信號，就不管了，不需要等 D-Cache
    input logic [COMMIT_WIDTH-1:0]                       commit_valid_i,
    input logic [COMMIT_WIDTH-1:0][$clog2(SB_DEPTH)-1:0] commit_st_id_i,

    // =======================================================
    // 4. D-Cache Interface (To L1 D$) - 後台寫入
    // =======================================================
    output logic dcache_req_valid_o,
    input logic dcache_req_ready_i,  // D-Cache 準備好接收寫請求
    output logic [Cfg.PLEN-1:0] dcache_req_addr_o,
    output logic [Cfg.XLEN-1:0] dcache_req_data_o,
    output decode_pkg::lsu_op_e dcache_req_op_o,

    // Order query for AMO: true when every older store-buffer entry has drained.
    input  logic                                      order_query_valid_i,
    input  logic               [$clog2(SB_DEPTH)-1:0] order_query_st_id_i,
    output logic                                      order_query_clear_o,

    // =======================================================
    // 4b. Store completion report (merged store_wb_q)
    // =======================================================
    // 当 store 在 lsu_group 解析完地址/准入完成时，按 st_id 把该条目标记为
    // executed，并写入「上报 ROB」所需的完成字段（异常/违例/SC 结果等）。
    // stq 用一个程序序扫描（从 head 起，最老的 executed && 未上报条目）驱动
    // 专用 store 写回口，上报后置 reported。
    input logic                       st_complete_valid_i,
    input logic [$clog2(SB_DEPTH)-1:0] st_complete_id_i,
    input logic [ROB_IDX_WIDTH-1:0]   st_complete_rob_idx_i,
    input logic [Cfg.XLEN-1:0]        st_complete_data_i,
    input logic                       st_complete_exception_i,
    input logic [ECAUSE_WIDTH-1:0]    st_complete_ecause_i,
    input logic                       st_complete_is_mispred_i,
    input logic [Cfg.PLEN-1:0]        st_complete_redirect_pc_i,
    input logic [Cfg.PLEN-1:0]        st_complete_pc_i,

    output logic                      st_wb_valid_o,
    output logic [ROB_IDX_WIDTH-1:0]  st_wb_rob_idx_o,
    output logic [Cfg.XLEN-1:0]       st_wb_data_o,
    output logic                      st_wb_exception_o,
    output logic [ECAUSE_WIDTH-1:0]   st_wb_ecause_o,
    output logic                      st_wb_is_mispred_o,
    output logic [Cfg.PLEN-1:0]       st_wb_redirect_pc_o,
    input  logic                      st_wb_fire_i,                 // 上报口本拍真正握手
    output logic [$clog2(SB_DEPTH+1)-1:0] st_unreported_count_o,    // executed && 未上报 计数

    // =======================================================
    // 5. Load Forwarding (From Load Unit) - 關鍵邏輯
    // =======================================================
    // load_be_i: 本次 load 需要的字節掩碼 (相對所在字)；轉發命中要求所有
    // 請求字節都被更老的 store 完全覆蓋 (byte-merge)。
    input  logic [   Cfg.XLEN/8-1:0] load_be_i,
    input  logic [     Cfg.PLEN-1:0] load_addr_i,
    input  logic [ROB_IDX_WIDTH-1:0] load_rob_idx_i,
    output logic                     load_hit_o,      // 在 STQ 中命中且數據完全覆蓋
    output logic [     Cfg.XLEN-1:0] load_data_o,     // 轉發的數據 (已對齊到字節 0)
    // 第二條獨立查詢口 (dcache-load-dual-issue Phase 2：副 lane 的 load)。
    // 與上面完全對稱，純組合、只讀，互不影響。
    input  logic [   Cfg.XLEN/8-1:0] load_be_i2,
    input  logic [     Cfg.PLEN-1:0] load_addr_i2,
    input  logic [ROB_IDX_WIDTH-1:0] load_rob_idx_i2,
    output logic                     load_hit_o2,
    output logic [     Cfg.XLEN-1:0] load_data_o2,

    // Observability/order-query port for issue-stage migration. It classifies
    // older STQ entries for one source-ready load candidate without affecting
    // forwarding or issue decisions yet.
    input  logic [   Cfg.XLEN/8-1:0] load_order_query_be_i,
    input  logic [     Cfg.PLEN-1:0] load_order_query_addr_i,
    input  logic [ROB_IDX_WIDTH-1:0] load_order_query_rob_idx_i,
    input  logic                     load_order_query_valid_i,
    output logic                     load_order_query_block_o,
    output logic                     load_order_query_addr_unknown_o,
    output logic                     load_order_query_overlap_o,
    output logic                     load_order_query_data_not_ready_o,
    output logic                     load_order_query_forward_full_o,
    output logic                     load_order_query_safe_o,
    output logic                     load_order_oldest_store_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] load_order_oldest_store_rob_idx_o,
    output logic                     load_order_has_committed_store_o,

    input  logic [ROB_IDX_WIDTH-1:0] rob_head_i,

    // =======================================================
    // 6. Control
    // =======================================================
    input logic flush_i
);

  // --- STQ Entry 定義 ---
  typedef struct packed {
    logic valid;       // 1 = 條目被佔用
    logic committed;   // 1 = 已退休 (Senior), 0 = 推測中 (Speculative)
    logic addr_valid;  // 1 = 地址已計算
    logic data_valid;  // 1 = 數據已計算

    logic [Cfg.PLEN-1:0] addr;
    logic [Cfg.XLEN-1:0] data;
    decode_pkg::lsu_op_e op;
    logic [ROB_IDX_WIDTH-1:0] rob_tag;

    // --- 完成上报 ROB (合并自 store_wb_q) ---
    logic executed;    // 1 = 已准入/解析完地址，待向 ROB 上报完成
    logic reported;    // 1 = 已通过 store 写回口上报 ROB
    logic exception;   // 上报字段：地址非对齐 / store page fault
    logic is_mispred;  // 上报字段：load-store 违例，需重定向
    logic [ECAUSE_WIDTH-1:0] ecause;
    logic [Cfg.XLEN-1:0] wb_data;       // 上报给 ROB 的数据 (trap tval / SC 结果 / 0)
    logic [Cfg.PLEN-1:0] redirect_pc;   // 违例重定向目标 PC
    logic [Cfg.PLEN-1:0] pc;            // store 自身 PC (诊断/对齐用)
  } stq_entry_t;

  stq_entry_t [SB_DEPTH-1:0] mem;

  localparam int unsigned BYTE_W = Cfg.XLEN / 8;
  localparam int unsigned BYTE_OFF_W = (BYTE_W <= 1) ? 1 : $clog2(BYTE_W);

  logic [63:0] dbg_load_order_query_total_q;
  logic [63:0] dbg_load_order_query_addr_unknown_q;
  logic [63:0] dbg_load_order_query_overlap_q;
  logic [63:0] dbg_load_order_query_data_not_ready_q;
  logic [63:0] dbg_load_order_query_forward_full_q;
  logic [63:0] dbg_load_order_query_safe_q;

  function automatic logic [ROB_IDX_WIDTH-1:0] rob_age(input logic [ROB_IDX_WIDTH-1:0] idx,
                                                       input logic [ROB_IDX_WIDTH-1:0] head);
    logic [ROB_IDX_WIDTH-1:0] diff;
    begin
      diff = idx - head;
      return diff;
    end
  endfunction

  always_comb begin
    logic found_oldest;
    logic [ROB_IDX_WIDTH-1:0] best_age;
    logic [ROB_IDX_WIDTH-1:0] age;

    found_oldest = 1'b0;
    best_age = {ROB_IDX_WIDTH{1'b1}};
    age = '0;
    load_order_oldest_store_valid_o = 1'b0;
    load_order_oldest_store_rob_idx_o = '0;
    load_order_has_committed_store_o = 1'b0;

    for (int i = 0; i < SB_DEPTH; i++) begin
      if (mem[i].valid) begin
        if (mem[i].committed) begin
          load_order_has_committed_store_o = 1'b1;
        end else begin
          age = rob_age(mem[i].rob_tag, rob_head_i);
          if (!found_oldest || (age < best_age)) begin
            found_oldest = 1'b1;
            best_age = age;
            load_order_oldest_store_valid_o = 1'b1;
            load_order_oldest_store_rob_idx_o = mem[i].rob_tag;
          end
        end
      end
    end
  end

  // Byte-enable mask of a buffered store, relative to its containing word.
  // SC_FAIL / 非 store op 返回 0，使其不参与转发覆盖。
  function automatic logic [BYTE_W-1:0] store_be_mask(input decode_pkg::lsu_op_e op,
                                                      input logic [Cfg.PLEN-1:0] addr);
    logic [BYTE_W-1:0] mask;
    logic [BYTE_OFF_W-1:0] off;
    begin
      mask = '0;
      off  = addr[BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_SB: mask[off] = 1'b1;
        decode_pkg::LSU_SH: begin
          for (int i = 0; i < 2; i++) begin
            if ((off + i) < BYTE_W) mask[off+i] = 1'b1;
          end
        end
        decode_pkg::LSU_SW, decode_pkg::LSU_SC, decode_pkg::LSU_AMO: begin
          for (int i = 0; i < 4; i++) begin
            if ((off + i) < BYTE_W) mask[off+i] = 1'b1;
          end
        end
        decode_pkg::LSU_SD: begin
          for (int i = 0; i < BYTE_W; i++) mask[i] = 1'b1;
        end
        default: mask = '0;
      endcase
      store_be_mask = mask;
    end
  endfunction

  // Place a buffered store's raw data at its byte offset inside the word.
  function automatic logic [Cfg.XLEN-1:0] store_aligned_data(input decode_pkg::lsu_op_e op,
                                                             input logic [Cfg.XLEN-1:0] data,
                                                             input logic [Cfg.PLEN-1:0] addr);
    logic [Cfg.XLEN-1:0] aligned;
    logic [BYTE_OFF_W-1:0] off;
    begin
      aligned = '0;
      off     = addr[BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_SB: begin
          if (off < BYTE_W) aligned[(8*off)+:8] = data[7:0];
        end
        decode_pkg::LSU_SH: begin
          if ((off + 1) < BYTE_W) aligned[(8*off)+:16] = data[15:0];
        end
        decode_pkg::LSU_SW, decode_pkg::LSU_SC, decode_pkg::LSU_AMO: begin
          if ((off + 3) < BYTE_W) aligned[(8*off)+:32] = data[31:0];
        end
        decode_pkg::LSU_SD: aligned = data;
        default: aligned = data;
      endcase
      store_aligned_data = aligned;
    end
  endfunction


  // 指針定義：
  // head_ptr: 指向最舊的條目 (隊頭，負責寫 D-Cache)
  // tail_ptr: 指向隊尾下一個空閒位置 (負責 Dispatch 分配)
  logic [$clog2(SB_DEPTH)-1:0] head_ptr;
  logic [$clog2(SB_DEPTH)-1:0] tail_ptr;

  // 計數器
  logic [$clog2(SB_DEPTH):0] count;

  // --- 辅助信号：本周期将提交的条目 (避免 flush 丢失同周期 commit) ---
  logic [SB_DEPTH-1:0] commit_set;
  always_comb begin
    commit_set = '0;
    for (int c = 0; c < COMMIT_WIDTH; c++) begin
      if (commit_valid_i[c]) begin
        commit_set[commit_st_id_i[c]] = 1'b1;
      end
    end
  end

  logic is_dummy_store;
  logic wb_fire;
  assign is_dummy_store = (mem[head_ptr].op == decode_pkg::LSU_SC_FAIL);
  assign wb_fire = mem[head_ptr].valid && mem[head_ptr].committed &&
                   mem[head_ptr].addr_valid && mem[head_ptr].data_valid &&
                   (dcache_req_ready_i || is_dummy_store);

  // --- 分配接口邏輯 ---
  logic [$clog2(SB_DEPTH):0] alloc_count;
  logic [$clog2(SB_DEPTH):0] drain_credit;
  assign drain_credit = wb_fire ? {{($clog2(SB_DEPTH)){1'b0}}, 1'b1} : '0;

  always_comb begin
    int off;
    alloc_count = 0;
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (alloc_req_i[i]) alloc_count++;
    end
    alloc_ready_o = (count + alloc_count <= SB_DEPTH + drain_credit);

    off = 0;
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (alloc_req_i[i]) begin
        alloc_id_o[i] = tail_ptr + $clog2(SB_DEPTH)'(off);
        off++;
      end else begin
        alloc_id_o[i] = '0;
      end
    end
  end

  // =======================================================
  // Main Sequential Logic
  // =======================================================
  logic [$clog2(SB_DEPTH):0] alloc_num;
  always_comb begin
    if (alloc_fire_i && alloc_ready_o) begin
      alloc_num = alloc_count;
    end else begin
      alloc_num = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_ptr <= '0;
      tail_ptr <= '0;
      count    <= '0;
      for (int i = 0; i < SB_DEPTH; i++) begin
        mem[i].valid      <= 1'b0;
        mem[i].committed  <= 1'b0;
        mem[i].addr_valid <= 1'b0;
        mem[i].data_valid <= 1'b0;
        mem[i].addr       <= '0;
        mem[i].data       <= '0;
        mem[i].op         <= decode_pkg::LSU_LW;
        mem[i].rob_tag    <= '0;
        mem[i].executed   <= 1'b0;
        mem[i].reported   <= 1'b0;
      end
    end else if (flush_i) begin
      int kept;
      kept = 0;

      for (int i = 0; i < SB_DEPTH; i++) begin
        mem[i].valid      <= 1'b0;
        mem[i].committed  <= 1'b0;
        mem[i].addr_valid <= 1'b0;
        mem[i].data_valid <= 1'b0;
        mem[i].rob_tag    <= '0;
        mem[i].executed   <= 1'b0;
        mem[i].reported   <= 1'b0;
      end

      for (int n = 0; n < SB_DEPTH; n++) begin
        logic [$clog2(SB_DEPTH)-1:0] src_idx;
        logic [$clog2(SB_DEPTH)-1:0] dst_idx;

        src_idx = head_ptr + $clog2(SB_DEPTH)'(n);
        if (mem[src_idx].valid && (mem[src_idx].committed || commit_set[src_idx])) begin
          dst_idx = head_ptr + $clog2(SB_DEPTH)'(kept);
          mem[dst_idx] <= mem[src_idx];
          mem[dst_idx].committed <= mem[src_idx].committed || commit_set[src_idx];
          kept++;
        end
      end

      tail_ptr <= head_ptr + $clog2(SB_DEPTH)'(kept);
      count    <= kept;
    end else begin

      // ------------------------------------
      // 1. Execute Fill (乱序写入，STA/STD 分口)
      // ------------------------------------
      if (sta_valid_i) begin
        mem[sta_st_id_i].addr       <= sta_addr_i;
        mem[sta_st_id_i].op         <= sta_op_i;
        mem[sta_st_id_i].rob_tag    <= sta_rob_idx_i;
        mem[sta_st_id_i].addr_valid <= 1'b1;
        if (sta_op_i == decode_pkg::LSU_SW || sta_op_i == decode_pkg::LSU_SC ||
            sta_op_i == decode_pkg::LSU_SC_FAIL) begin
`ifndef SYNTHESIS
          // $display("[SB] Store STA! id=%d addr=%x op=%d", sta_st_id_i, sta_addr_i, sta_op_i);
`endif
        end
      end

      if (std_valid_i) begin
        mem[std_st_id_i].data       <= std_data_i;
        mem[std_st_id_i].data_valid <= 1'b1;
      end

      if (std_early_valid_i && !(std_valid_i && (std_st_id_i == std_early_st_id_i))) begin
        mem[std_early_st_id_i].data       <= std_early_data_i;
        mem[std_early_st_id_i].data_valid <= 1'b1;
      end

      if (sta_early_valid_i && !(sta_valid_i && (sta_st_id_i == sta_early_st_id_i))) begin
        mem[sta_early_st_id_i].addr       <= sta_early_addr_i;
        mem[sta_early_st_id_i].op         <= sta_early_op_i;
        mem[sta_early_st_id_i].rob_tag    <= sta_early_rob_idx_i;
        mem[sta_early_st_id_i].addr_valid <= 1'b1;
      end

      // ------------------------------------
      // 2. D-Cache Writeback (出隊)
      // ------------------------------------
      // 條件：隊頭有效 + 已退休 + 地址數據都就緒 + Cache 準備好
      if (wb_fire) begin

        mem[head_ptr].valid      <= 1'b0;  // 真正釋放 STQ 空間
        mem[head_ptr].committed  <= 1'b0;
        mem[head_ptr].addr_valid <= 1'b0;
        mem[head_ptr].data_valid <= 1'b0;
        mem[head_ptr].rob_tag    <= '0;
        mem[head_ptr].executed   <= 1'b0;
        mem[head_ptr].reported   <= 1'b0;
        head_ptr                 <= head_ptr + 1;
        
        if (mem[head_ptr].op == decode_pkg::LSU_SW || mem[head_ptr].op == decode_pkg::LSU_SC || mem[head_ptr].op == decode_pkg::LSU_SC_FAIL) begin
`ifndef SYNTHESIS
          // $display("[SB] Store Writeback! addr=%x data=%x op=%d dummy=%b", mem[head_ptr].addr, mem[head_ptr].data, mem[head_ptr].op, is_dummy_store);
`endif
        end
      end

      // ------------------------------------
      // 3. Allocation (入隊)
      // ------------------------------------
      // 先出隊再入隊，允許滿 STQ 在同周期 drain 一項並分配到同一物理槽。
      if (alloc_fire_i && alloc_ready_o && alloc_count != 0) begin
        int off;
        off = 0;
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
          if (alloc_req_i[i]) begin
            logic [$clog2(SB_DEPTH)-1:0] idx;
            idx = tail_ptr + $clog2(SB_DEPTH)'(off);
            mem[idx].valid      <= 1'b1;
            mem[idx].committed  <= 1'b0;  // 默認為推測狀態
            mem[idx].addr_valid <= 1'b0;
            mem[idx].data_valid <= 1'b0;
            mem[idx].rob_tag    <= alloc_rob_idx_i[i];
            mem[idx].executed   <= 1'b0;  // 重置完成上报状态
            mem[idx].reported   <= 1'b0;
            off++;
          end
        end
        // 移動指針
        tail_ptr <= tail_ptr + $clog2(SB_DEPTH)'(off);
      end

      // ------------------------------------
      // 4. Commit (ROB 通知退休)
      // ------------------------------------
      // 支持同周期多條 store 退休
      for (int c = 0; c < COMMIT_WIDTH; c++) begin
        if (commit_valid_i[c]) begin
          mem[commit_st_id_i[c]].committed <= 1'b1;
        end
      end

      // ------------------------------------
      // 4b. Store 完成上报 (合并自 store_wb_q)
      // ------------------------------------
      // 准入完成：按 st_id 标记 executed 并写入完成字段。faulting store 不走
      // ex_valid 写 addr/data，但仍要在此写 rob_tag/异常以便上报。
      if (st_complete_valid_i) begin
        mem[st_complete_id_i].executed    <= 1'b1;
        mem[st_complete_id_i].reported    <= 1'b0;
        mem[st_complete_id_i].rob_tag     <= st_complete_rob_idx_i;
        mem[st_complete_id_i].wb_data     <= st_complete_data_i;
        mem[st_complete_id_i].exception   <= st_complete_exception_i;
        mem[st_complete_id_i].ecause      <= st_complete_ecause_i;
        mem[st_complete_id_i].is_mispred  <= st_complete_is_mispred_i;
        mem[st_complete_id_i].redirect_pc <= st_complete_redirect_pc_i;
        mem[st_complete_id_i].pc          <= st_complete_pc_i;
      end
      // 上报握手：把本拍被选中上报的最老条目置 reported。
      if (st_wb_fire_i && wb_sel_valid) begin
        mem[wb_sel_idx].reported <= 1'b1;
      end

      // ------------------------------------
      // 5. Count update (alloc + wb)
      // ------------------------------------
      if (alloc_num != 0 || wb_fire) begin
        count <= count + alloc_num - (wb_fire ? 1 : 0);
      end
    end
  end

  // =======================================================
  // Output Logic: D-Cache Request
  // =======================================================
  assign dcache_req_valid_o = mem[head_ptr].valid && 
                                mem[head_ptr].committed && 
                                mem[head_ptr].addr_valid && 
                                mem[head_ptr].data_valid &&
                                !is_dummy_store;

  assign dcache_req_addr_o = mem[head_ptr].addr;
  assign dcache_req_data_o = mem[head_ptr].data;
  assign dcache_req_op_o = mem[head_ptr].op;

  logic [$clog2(SB_DEPTH)-1:0] order_query_scan_idx;

  always_comb begin
    order_query_clear_o = 1'b1;
    order_query_scan_idx = head_ptr;

    if (order_query_valid_i) begin
      for (int n = 0; n < SB_DEPTH; n++) begin
        order_query_scan_idx = head_ptr + $clog2(SB_DEPTH)'(n);

        if (order_query_scan_idx == order_query_st_id_i) begin
          break;
        end

        if (mem[order_query_scan_idx].valid) begin
          order_query_clear_o = 1'b0;
          break;
        end
      end
    end
  end

  // =======================================================
  // Store completion writeback select (合并自 store_wb_q)
  // =======================================================
  // 从 head (最老) 起按程序序扫描，选出第一个 valid && executed && 未上报的
  // 条目驱动专用 store 写回口；同时统计未上报计数供准入/AMO 排序使用。
  logic [$clog2(SB_DEPTH)-1:0] wb_sel_idx;
  logic                         wb_sel_valid;

  always_comb begin
    logic [$clog2(SB_DEPTH+1)-1:0] cnt;
    wb_sel_valid = 1'b0;
    wb_sel_idx   = head_ptr;
    cnt          = '0;
    for (int n = 0; n < SB_DEPTH; n++) begin
      logic [$clog2(SB_DEPTH)-1:0] idx;
      idx = head_ptr + $clog2(SB_DEPTH)'(n);
      if (mem[idx].valid && mem[idx].executed && !mem[idx].reported) begin
        cnt = cnt + 1'b1;
        if (!wb_sel_valid) begin
          wb_sel_valid = 1'b1;
          wb_sel_idx   = idx;
        end
      end
    end
    st_unreported_count_o = cnt;
  end

  assign st_wb_valid_o       = wb_sel_valid;
  assign st_wb_rob_idx_o     = mem[wb_sel_idx].rob_tag;
  assign st_wb_data_o        = mem[wb_sel_idx].wb_data;
  assign st_wb_exception_o   = mem[wb_sel_idx].exception;
  assign st_wb_ecause_o      = mem[wb_sel_idx].ecause;
  assign st_wb_is_mispred_o  = mem[wb_sel_idx].is_mispred;
  assign st_wb_redirect_pc_o = mem[wb_sel_idx].redirect_pc;

  // =======================================================
  // Load-order query for issue-stage migration profiling
  // =======================================================
  always_comb begin
    logic [ROB_IDX_WIDTH-1:0] q_load_age;
    logic raw_addr_unknown;
    logic raw_overlap;
    logic raw_overlap_data_not_ready;
    logic [BYTE_W-1:0] covered_be;

    raw_addr_unknown = 1'b0;
    raw_overlap = 1'b0;
    raw_overlap_data_not_ready = 1'b0;
    covered_be = '0;
    q_load_age = rob_age(load_order_query_rob_idx_i, rob_head_i);

    for (int i = 0; i < SB_DEPTH; i++) begin
      logic [$clog2(SB_DEPTH)-1:0] idx;
      logic older_than_load;
      logic same_word;
      logic [BYTE_W-1:0] st_be;
      logic [BYTE_W-1:0] overlap_be;
      idx = tail_ptr - 1 - i[$clog2(SB_DEPTH)-1:0];
      older_than_load = mem[idx].committed ||
                        (rob_age(mem[idx].rob_tag, rob_head_i) < q_load_age);
      same_word = mem[idx].addr_valid &&
                  (mem[idx].addr[Cfg.PLEN-1:BYTE_OFF_W] ==
                   load_order_query_addr_i[Cfg.PLEN-1:BYTE_OFF_W]);
      st_be = store_be_mask(mem[idx].op, mem[idx].addr);
      overlap_be = st_be & load_order_query_be_i;

      if (load_order_query_valid_i && mem[idx].valid && older_than_load) begin
        if (!mem[idx].addr_valid) begin
          raw_addr_unknown = 1'b1;
        end else if (same_word && (|overlap_be)) begin
          raw_overlap = 1'b1;
          if (!mem[idx].data_valid) begin
            raw_overlap_data_not_ready = 1'b1;
          end else begin
            covered_be = covered_be | overlap_be;
          end
        end
      end
    end

    load_order_query_forward_full_o = load_order_query_valid_i && raw_overlap &&
                                      !raw_addr_unknown && !raw_overlap_data_not_ready &&
                                      ((covered_be & load_order_query_be_i) ==
                                       load_order_query_be_i) &&
                                      (load_order_query_be_i != '0);

    // Mutually-exclusive priority: unknown address first; otherwise an overlap
    // without data, then partial data-ready overlap, then full-cover forward,
    // then no-overlap safe. Full-cover can issue because ld_pipe suppresses
    // DCache and completes from STQ forwarding on stq_fwd_hit_i.
    load_order_query_addr_unknown_o = raw_addr_unknown;
    load_order_query_data_not_ready_o = !raw_addr_unknown && raw_overlap_data_not_ready;
    load_order_query_overlap_o = !raw_addr_unknown && raw_overlap &&
                                 !raw_overlap_data_not_ready &&
                                 !load_order_query_forward_full_o;
    load_order_query_block_o = load_order_query_addr_unknown_o ||
                               load_order_query_data_not_ready_o ||
                               load_order_query_overlap_o;
    load_order_query_safe_o = load_order_query_valid_i && !load_order_query_block_o;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dbg_load_order_query_total_q <= '0;
      dbg_load_order_query_addr_unknown_q <= '0;
      dbg_load_order_query_overlap_q <= '0;
      dbg_load_order_query_data_not_ready_q <= '0;
      dbg_load_order_query_forward_full_q <= '0;
      dbg_load_order_query_safe_q <= '0;
    end else begin
      if (load_order_query_valid_i) begin
        dbg_load_order_query_total_q <= dbg_load_order_query_total_q + 64'd1;
        if (load_order_query_addr_unknown_o) begin
          dbg_load_order_query_addr_unknown_q <= dbg_load_order_query_addr_unknown_q + 64'd1;
        end
        if (load_order_query_overlap_o) begin
          dbg_load_order_query_overlap_q <= dbg_load_order_query_overlap_q + 64'd1;
        end
        if (load_order_query_data_not_ready_o) begin
          dbg_load_order_query_data_not_ready_q <= dbg_load_order_query_data_not_ready_q + 64'd1;
        end
        if (load_order_query_forward_full_o) begin
          dbg_load_order_query_forward_full_q <= dbg_load_order_query_forward_full_q + 64'd1;
        end
        if (load_order_query_safe_o && !load_order_query_forward_full_o) begin
          dbg_load_order_query_safe_q <= dbg_load_order_query_safe_q + 64'd1;
        end
      end
    end
  end

  // =======================================================
  // Store-to-Load Forwarding Logic (唯一轉發源, byte-merge)
  // =======================================================
  // 策略：從最新分配的條目 (tail-1) 向最舊 (head) 掃描，對每個更老、同字、
  // 地址/數據就緒的 store 按字節合併 (年輕者優先填未覆蓋字節)。當 load 請求
  // 的所有字節都被覆蓋才算命中；輸出數據右移到字節 0，供 lane 直接提取。
  logic [ROB_IDX_WIDTH-1:0] load_age;
  logic [BYTE_OFF_W-1:0] load_off;

  always_comb begin
    logic [BYTE_W-1:0] covered_be;
    logic [Cfg.XLEN-1:0] merged_word;
    logic [BYTE_W-1:0] st_be;
    logic [Cfg.XLEN-1:0] st_aligned;

    load_hit_o = 1'b0;
    load_data_o = '0;
    covered_be = '0;
    merged_word = '0;

    load_age = rob_age(load_rob_idx_i, rob_head_i);
    load_off = load_addr_i[BYTE_OFF_W-1:0];

    // 邏輯順序：tail-1, tail-2, ..., head (年輕到年老)
    for (int i = 0; i < SB_DEPTH; i++) begin
      logic [$clog2(SB_DEPTH)-1:0] idx;
      logic older_than_load;
      logic same_word;
      idx = tail_ptr - 1 - i[$clog2(SB_DEPTH)-1:0];

      older_than_load = mem[idx].committed ||
                        (rob_age(mem[idx].rob_tag, rob_head_i) < load_age);
      same_word = (mem[idx].addr[Cfg.PLEN-1:BYTE_OFF_W] == load_addr_i[Cfg.PLEN-1:BYTE_OFF_W]);

      if (mem[idx].valid &&
          mem[idx].addr_valid &&
          mem[idx].data_valid &&
          same_word &&
          older_than_load) begin
        st_be = store_be_mask(mem[idx].op, mem[idx].addr);
        st_aligned = store_aligned_data(mem[idx].op, mem[idx].data, mem[idx].addr);
        for (int b = 0; b < BYTE_W; b++) begin
          if (load_be_i[b] && st_be[b] && !covered_be[b]) begin
            merged_word[(8*b)+:8] = st_aligned[(8*b)+:8];
            covered_be[b] = 1'b1;
          end
        end
      end
    end

    // 命中 = load 請求的所有字節都被覆蓋
    load_hit_o = ((covered_be & load_be_i) == load_be_i) && (load_be_i != '0);
    // 對齊到字節 0 (lane 的 extract_fwd 假設數據從 bit0 開始)
    load_data_o = merged_word >> (8 * load_off);
  end

  // 第二條查詢口：與上面完全對稱的獨立組合邏輯 (副 lane load)。
  logic [ROB_IDX_WIDTH-1:0] load_age2;
  logic [BYTE_OFF_W-1:0] load_off2;

  always_comb begin
    logic [BYTE_W-1:0] covered_be;
    logic [Cfg.XLEN-1:0] merged_word;
    logic [BYTE_W-1:0] st_be;
    logic [Cfg.XLEN-1:0] st_aligned;

    load_hit_o2 = 1'b0;
    load_data_o2 = '0;
    covered_be = '0;
    merged_word = '0;

    load_age2 = rob_age(load_rob_idx_i2, rob_head_i);
    load_off2 = load_addr_i2[BYTE_OFF_W-1:0];

    for (int i = 0; i < SB_DEPTH; i++) begin
      logic [$clog2(SB_DEPTH)-1:0] idx;
      logic older_than_load;
      logic same_word;
      idx = tail_ptr - 1 - i[$clog2(SB_DEPTH)-1:0];

      older_than_load = mem[idx].committed ||
                        (rob_age(mem[idx].rob_tag, rob_head_i) < load_age2);
      same_word = (mem[idx].addr[Cfg.PLEN-1:BYTE_OFF_W] == load_addr_i2[Cfg.PLEN-1:BYTE_OFF_W]);

      if (mem[idx].valid &&
          mem[idx].addr_valid &&
          mem[idx].data_valid &&
          same_word &&
          older_than_load) begin
        st_be = store_be_mask(mem[idx].op, mem[idx].addr);
        st_aligned = store_aligned_data(mem[idx].op, mem[idx].data, mem[idx].addr);
        for (int b = 0; b < BYTE_W; b++) begin
          if (load_be_i2[b] && st_be[b] && !covered_be[b]) begin
            merged_word[(8*b)+:8] = st_aligned[(8*b)+:8];
            covered_be[b] = 1'b1;
          end
        end
      end
    end

    load_hit_o2 = ((covered_be & load_be_i2) == load_be_i2) && (load_be_i2 != '0);
    load_data_o2 = merged_word >> (8 * load_off2);
  end

  // =======================================================
  // Phase 3 assertions (simulation only, ASSERT=1)
  // =======================================================
`ifndef SYNTHESIS
  logic stq_flush_prev_q;

  always_comb begin
    if (!flush_i) begin
      for (int c = 0; c < COMMIT_WIDTH; c++) begin
        if (commit_valid_i[c]) begin
          `NPC_ASSERT(mem[commit_st_id_i[c]].valid && !mem[commit_st_id_i[c]].committed,
                     "sb/commit_invalid_entry")
        end
      end

      if (sta_valid_i) begin
        `NPC_ASSERT(mem[sta_st_id_i].valid, "stq/sta_to_invalid")
      end
      if (std_valid_i) begin
        `NPC_ASSERT(mem[std_st_id_i].valid, "stq/std_to_invalid")
      end
      if (sta_early_valid_i) begin
        `NPC_ASSERT(mem[sta_early_st_id_i].valid, "stq/early_sta_to_invalid")
      end
      if (std_early_valid_i) begin
        `NPC_ASSERT(mem[std_early_st_id_i].valid, "stq/early_std_to_invalid")
      end

      if (alloc_fire_i && alloc_ready_o) begin
        for (int i0 = 0; i0 < DISPATCH_WIDTH; i0++) begin
          for (int i1 = i0 + 1; i1 < DISPATCH_WIDTH; i1++) begin
            if (alloc_req_i[i0] && alloc_req_i[i1] && (alloc_id_o[i0] == alloc_id_o[i1])) begin
              $warning("[sb] duplicate alloc id %0d in same cycle", alloc_id_o[i0]);
            end
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stq_flush_prev_q <= 1'b0;
    end else begin
      if (alloc_fire_i && alloc_ready_o && (alloc_count != 0) && !flush_i) begin
        automatic int off = 0;
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
          if (alloc_req_i[i]) begin
            logic [$clog2(SB_DEPTH)-1:0] idx;
            logic                         drains_this_idx;
            idx = tail_ptr + $clog2(SB_DEPTH)'(off);
            drains_this_idx = wb_fire && (idx == head_ptr);
            `NPC_ASSERT(!mem[idx].valid || drains_this_idx, "sb/alloc_over_valid")
            off++;
          end
        end
      end

      if (stq_flush_prev_q) begin
        for (int i = 0; i < SB_DEPTH; i++) begin
          if (mem[i].valid) begin
            `NPC_ASSERT(mem[i].committed, "sb/uncommitted_valid_after_flush")
          end
        end
      end

      stq_flush_prev_q <= flush_i;
    end
  end
`endif

endmodule
