// vsrc/frontend/ifu.sv
/*
  Instruction Fetch Unit (decoupled)
  1. 与 BPU 握手产生下一拍请求 PC
  2. 用 request FIFO 将 BPU 预测与 ICache 请求解耦
  3. 用 inflight FIFO 跟踪已发射请求 metadata（替换单 inflight）
  4. 用可复用 bundle FIFO 将 ICache 响应与 IBuffer 消费解耦
*/
import global_config_pkg::*;
module ifu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk,   // 核心时钟信号
    input logic rst,   // 高电平复位信号 (ifu 内部逻辑使用)

    //--- 1.BPU握手接口 (分支预测交互，申请下一拍取指地址) ---
    output handshake_t                ifu2bpu_handshake_o,      // IFU 发送给 BPU 的请求有效/就绪握手信号
    input  handshake_t                bpu2ifu_handshake_i,      // BPU 返回给 IFU 的响应有效/就绪握手信号
    output logic       [Cfg.PLEN-1:0] ifu2bpu_pc_o,             // IFU 送给 BPU 进行查找和预测的当前 PC
    input  logic       [Cfg.PLEN-1:0] bpu2ifu_predicted_pc_i,   // BPU 预测的下一条取指包的 PC 目标
    input  logic                       bpu2ifu_pred_slot_valid_i,// 预测有效标志：表示预测出的跳转在这个取指包内确实存在
    input  logic [$clog2(Cfg.INSTR_PER_FETCH)-1:0] bpu2ifu_pred_slot_idx_i, // 指明是取指包中第几个槽位触发了跳转
    input  logic       [Cfg.PLEN-1:0] bpu2ifu_pred_target_i,    // 预测的跳转目标地址

    //--- 2.ICache请求接口 (缓存提货，获取指令数据) ---
    output handshake_t ifu2icache_req_handshake_o,  // 发送给 ICache 的取指请求握手 (valid/ready)
    input handshake_t icache2ifu_rsp_handshake_i,   // ICache 返回指令数据的响应握手 (valid/ready)
    output logic [Cfg.VLEN-1:0] ifu2icache_req_addr_o, // 发给 ICache 的取指地址 (物理/虚拟地址)
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] icache2ifu_rsp_data_i, // ICache 返回的一整组指令数据
    output logic flush_icache_o,                    // 冲刷 ICache 缓存 (如切换页表或发生 SFENCE.VMA 时)

    //--- 3.Ibuffer响应接口 (交付给后端译码阶段) ---
    output logic ifu_ibuffer_rsp_valid_o,           // 发送给 IBuffer 的交货有效信号
    input  logic                      ibuffer_ifu_rsp_ready_i, // 后端 IBuffer 反馈的就绪信号 (可签收)
    output logic [Cfg.PLEN-1:0] ifu_ibuffer_rsp_pc_o, // 这一包指令的起始虚拟 PC 地址
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ifu_ibuffer_rsp_data_o, // 发送给后端的指令数据包
    output logic [Cfg.INSTR_PER_FETCH-1:0] ifu_ibuffer_rsp_slot_valid_o, // 包内各指令槽位的有效性
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] ifu_ibuffer_rsp_pred_npc_o, // 携带的每条指令对应的预测下一拍 PC
    output logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ifu_ibuffer_rsp_ftq_id_o, // 指令对应分配的 FTQ ID
    output logic [Cfg.INSTR_PER_FETCH-1:0][2:0] ifu_ibuffer_rsp_fetch_epoch_o, // 当前取指所属的“时空代数” Epoch，用于识别/丢弃错路指令

    //--- 4.后端冲刷/重定向接口 (纠错机制) ---
    input logic                flush_i,       // 后端发起的流水线强行冲刷信号 (清除错路指令)
    input logic [Cfg.PLEN-1:0] redirect_pc_i, // 后端命令的重新定向新 PC 地址

    //--- 5.I-side MMU control + page table walker (虚拟地址翻译) ---
    input logic [31:0] mmu_satp_i,       // SATP 寄存器 (控制 MMU 开关及页表根地址)
    input logic [1:0]  mmu_priv_i,       // 当前 CPU 的特权模式级别 (U/S/M-mode)
    input logic        mmu_sum_i,        // SUM 位 (监管者是否可访问用户页面)
    input logic        mmu_mxr_i,        // MXR 位 (可执行是否可读)
    input logic        mmu_sfence_vma_i, // TLB 刷新指令指示
    output logic       pte_req_valid_o,  // 发起页表项读取的有效信号
    input logic        pte_req_ready_i,  // 内存就绪信号
    output logic [31:0] pte_req_paddr_o, // 页表项物理地址
    input logic        pte_rsp_valid_i,  // 内存页表项返回有效
    input logic [31:0] pte_rsp_data_i,   // 页表项数据
    output logic       pte_upd_valid_o,  // 页表项标志更新有效信号
    input logic        pte_upd_ready_i,  // 内存更新就绪
    output logic [31:0] pte_upd_paddr_o, // 待更新页表项物理地址
    output logic [31:0] pte_upd_data_o,  // 待更新页表项数据

    //--- 6.IFetch fault sideband (to backend) (取指异常上报) ---
    output logic       ifetch_fault_valid_o,   // 取指页面异常有效信号
    input logic        ifetch_fault_ready_i,   // 后端已准备接收异常
    output logic [Cfg.PLEN-1:0] ifetch_fault_pc_o,    // 发生页面错误的虚拟 PC 地址
    output logic [Cfg.PLEN-1:0] ifetch_fault_tval_o,  // 错误地址值
    output logic [4:0] ifetch_fault_cause_o    // 页面异常原因编码
);

  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  localparam int unsigned SLOT_IDX_W = (Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1;
  localparam int unsigned EPOCH_W = 3;
  localparam logic [1:0] PRIV_LVL_M = 2'b11;
  localparam logic [1:0] MMU_ACCESS_INSTR = 2'd0;
  localparam logic [4:0] EXC_INST_PAGE_FAULT = 5'd12;
  localparam int unsigned FTQ_DEPTH = (Cfg.IFU_INF_DEPTH >= 2) ? Cfg.IFU_INF_DEPTH : 2;
  localparam int unsigned FTQ_ID_W = (FTQ_DEPTH > 1) ? $clog2(FTQ_DEPTH) : 1;

  // Pending request FIFO (BPU generated).
  localparam int unsigned REQ_DEPTH =
      (Cfg.IFU_REQ_DEPTH >= 2) ? Cfg.IFU_REQ_DEPTH : ((Cfg.INSTR_PER_FETCH >= 2) ? Cfg.INSTR_PER_FETCH : 2);
  localparam int unsigned REQ_PTR_W = (REQ_DEPTH > 1) ? $clog2(REQ_DEPTH) : 1;
  localparam int unsigned REQ_CNT_W = $clog2(REQ_DEPTH + 1);

  // Inflight request FIFO (issued to ICache, waiting for response).
  localparam int unsigned INF_DEPTH =
      (Cfg.IFU_INF_DEPTH >= 2) ? Cfg.IFU_INF_DEPTH : REQ_DEPTH;
  localparam int unsigned INF_PTR_W = (INF_DEPTH > 1) ? $clog2(INF_DEPTH) : 1;
  localparam int unsigned INF_CNT_W = $clog2(INF_DEPTH + 1);

  // Fetch response queue to decouple ICache and IBuffer.
  localparam int unsigned FQ_DEPTH =
      (Cfg.IFU_FQ_DEPTH >= 2) ? Cfg.IFU_FQ_DEPTH : ((Cfg.INSTR_PER_FETCH >= 2) ? Cfg.INSTR_PER_FETCH : 2);
  localparam int unsigned FQ_CNT_W = $clog2(FQ_DEPTH + 1);
  localparam int unsigned FQ_DATA_W = Cfg.PLEN + (Cfg.INSTR_PER_FETCH * Cfg.ILEN) +
                                      Cfg.INSTR_PER_FETCH + (Cfg.INSTR_PER_FETCH * Cfg.PLEN) +
                                      (Cfg.INSTR_PER_FETCH * FTQ_ID_W) +
                                      (Cfg.INSTR_PER_FETCH * EPOCH_W);

  logic [Cfg.PLEN-1:0] pc_reg;
  logic [Cfg.PLEN-1:0] bpu_query_pc_w;
  logic [Cfg.PLEN-1:0] local_mmu_replay_pc_w;
  logic [EPOCH_W-1:0] fetch_epoch_q;
  logic [EPOCH_W-1:0] flush_next_epoch_w;

  // Pending FIFO metadata
  logic [REQ_DEPTH-1:0][Cfg.PLEN-1:0] req_pc_fifo_q;
  logic [REQ_DEPTH-1:0] req_pred_slot_valid_fifo_q;
  logic [REQ_DEPTH-1:0][SLOT_IDX_W-1:0] req_pred_slot_idx_fifo_q;
  logic [REQ_DEPTH-1:0][Cfg.PLEN-1:0] req_pred_target_fifo_q;
  logic [REQ_DEPTH-1:0][FTQ_ID_W-1:0] req_ftq_id_fifo_q;
  logic [REQ_DEPTH-1:0][EPOCH_W-1:0] req_epoch_fifo_q;
  logic [REQ_PTR_W-1:0] req_head_q;
  logic [REQ_PTR_W-1:0] req_tail_q;
  logic [REQ_CNT_W-1:0] req_count_q;
  logic [Cfg.PLEN-1:0] req_head_pc_w;
  logic req_head_pred_slot_valid_w;
  logic [SLOT_IDX_W-1:0] req_head_pred_slot_idx_w;
  logic [Cfg.PLEN-1:0] req_head_pred_target_w;
  logic [FTQ_ID_W-1:0] req_head_ftq_id_w;
  logic [EPOCH_W-1:0] req_head_epoch_w;

  // Inflight FIFO metadata
  logic [INF_DEPTH-1:0][Cfg.PLEN-1:0] inf_pc_fifo_q;
  logic [INF_DEPTH-1:0] inf_pred_slot_valid_fifo_q;
  logic [INF_DEPTH-1:0][SLOT_IDX_W-1:0] inf_pred_slot_idx_fifo_q;
  logic [INF_DEPTH-1:0][Cfg.PLEN-1:0] inf_pred_target_fifo_q;
  logic [INF_DEPTH-1:0][FTQ_ID_W-1:0] inf_ftq_id_fifo_q;
  logic [INF_DEPTH-1:0][EPOCH_W-1:0] inf_epoch_fifo_q;
  logic [INF_PTR_W-1:0] inf_head_q;
  logic [INF_PTR_W-1:0] inf_tail_q;
  logic [INF_CNT_W-1:0] inf_count_q;

  // Fetch response queue state exported from bundle FIFO instance.
  logic [FQ_CNT_W-1:0] fq_count_q;
  logic [FQ_DATA_W-1:0] fq_enq_data_w;
  logic [FQ_DATA_W-1:0] fq_deq_data_w;
  logic fq_enq_valid_w;
  logic fq_enq_ready_w;
  logic fq_deq_valid_w;
  logic fq_deq_ready_w;

  logic [Cfg.PLEN-1:0] inf_head_pc_w;
  logic inf_head_pred_slot_valid_w;
  logic [SLOT_IDX_W-1:0] inf_head_pred_slot_idx_w;
  logic [Cfg.PLEN-1:0] inf_head_pred_target_w;
  logic [FTQ_ID_W-1:0] inf_head_ftq_id_w;
  logic [EPOCH_W-1:0] inf_head_epoch_w;

  logic [Cfg.INSTR_PER_FETCH-1:0] rsp_slot_valid_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] rsp_pred_npc_w;
  logic [Cfg.INSTR_PER_FETCH-1:0] rsp_slot_compressed_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][FTQ_ID_W-1:0] rsp_ftq_id_w;
  logic [Cfg.INSTR_PER_FETCH-1:0][EPOCH_W-1:0] rsp_fetch_epoch_w;

  logic req_fifo_empty_w;
  logic req_fifo_full_w;
  logic inf_fifo_empty_w;
  logic inf_fifo_full_w;
  logic fq_empty_w;
  logic fq_full_w;

  logic can_accept_bpu_w;
  logic req_enq_fire_w;
  logic req_block_flush_w;
  logic req_block_reqq_empty_w;
  logic req_block_inf_full_w;
  logic req_block_storage_budget_w;

  logic can_issue_req_w;
  logic req_issue_valid_w;
  logic req_issue_fire_w;
  logic req_pop_w;
  logic translation_active_w;
  logic issue_need_mmu_w;
  logic issue_translation_ready_w;
  logic [Cfg.PLEN-1:0] issue_paddr_w;
  logic mmu_req_fire_w;
  logic mmu_resp_fire_w;
  logic fault_consume_w;
  logic ftq_free_valid_w;
  logic [FTQ_ID_W-1:0] ftq_free_id_w;

  logic rsp_capture_w;
  logic drop_stale_rsp_w;
  logic rsp_epoch_match_w;
  logic ibuf_pop_w;
  logic rsp_push_fq_w;

  logic [REQ_CNT_W:0] req_outstanding_w;
  logic [FQ_CNT_W:0] storage_budget_w;
  logic ftq_alloc_ready_w;
  logic ftq_alloc_fire_w;
  logic [FTQ_ID_W-1:0] ftq_alloc_id_w;
  logic [Cfg.PLEN-1:0] ftq_alloc_pc_w;
  logic [EPOCH_W-1:0] ftq_alloc_epoch_w;
  logic [((FTQ_DEPTH > 1) ? $clog2(FTQ_DEPTH + 1) : 1)-1:0] ftq_count_w;

  typedef enum logic [1:0] {
    MMU_ST_IDLE = 2'd0,
    MMU_ST_REQ = 2'd1,
    MMU_ST_WAIT = 2'd2,
    MMU_ST_READY = 2'd3
  } ifu_mmu_state_e;
  ifu_mmu_state_e mmu_state_q;
  logic [31:0] mmu_translated_paddr_q;
  logic mmu_req_ready_w;
  logic mmu_resp_valid_w;
  logic [31:0] mmu_resp_paddr_w;
  logic mmu_resp_page_fault_w;
  logic [31:0] mmu_satp_prev_q;
  logic satp_changed_w;
  logic local_mmu_flush_w;
  logic ifu_flush_w;
`ifndef SYNTHESIS
  localparam int unsigned IFU_PC_DBG_BUDGET = 256;
  logic [31:0] ifu_pc_dbg_cnt_q;
  localparam logic [31:0] IFU_AA_WIN_START = 32'hc080aa80;
  localparam logic [31:0] IFU_AA_WIN_END = 32'hc080add0;
  localparam int unsigned IFU_AA_DBG_BUDGET = 512;
  logic [31:0] ifu_aa_dbg_cnt_q;
  logic aa_req_watch_w;
  logic aa_inf_watch_w;
  logic ifu_diag_trace_en_q;
  logic ifu_bsearch_trace_en_q;
  initial ifu_diag_trace_en_q = $test$plusargs("npc_diag_trace");
  initial ifu_bsearch_trace_en_q = $test$plusargs("npc_diag_bsearch");

`endif

  logic fault_pending_q;
  logic [Cfg.PLEN-1:0] fault_pc_q;
  logic [Cfg.PLEN-1:0] fault_tval_q;

  function automatic [REQ_PTR_W-1:0] req_ptr_inc(input [REQ_PTR_W-1:0] ptr);
    if (ptr == REQ_PTR_W'(REQ_DEPTH - 1)) begin
      req_ptr_inc = '0;
    end else begin
      req_ptr_inc = ptr + REQ_PTR_W'(1);
    end
  endfunction

  function automatic [INF_PTR_W-1:0] inf_ptr_inc(input [INF_PTR_W-1:0] ptr);
    if (ptr == INF_PTR_W'(INF_DEPTH - 1)) begin
      inf_ptr_inc = '0;
    end else begin
      inf_ptr_inc = ptr + INF_PTR_W'(1);
    end
  endfunction

  assign req_fifo_empty_w = (req_count_q == REQ_CNT_W'(0));
  assign req_fifo_full_w = (req_count_q == REQ_CNT_W'(REQ_DEPTH));
  assign inf_fifo_empty_w = (inf_count_q == INF_CNT_W'(0));
  assign inf_fifo_full_w = (inf_count_q == INF_CNT_W'(INF_DEPTH));

  assign req_head_pc_w = req_pc_fifo_q[req_head_q];
  assign req_head_pred_slot_valid_w = req_pred_slot_valid_fifo_q[req_head_q];
  assign req_head_pred_slot_idx_w = req_pred_slot_idx_fifo_q[req_head_q];
  assign req_head_pred_target_w = req_pred_target_fifo_q[req_head_q];
  assign req_head_ftq_id_w = req_ftq_id_fifo_q[req_head_q];
  assign req_head_epoch_w = req_epoch_fifo_q[req_head_q];

  assign inf_head_pc_w = inf_pc_fifo_q[inf_head_q];
  assign inf_head_pred_slot_valid_w = inf_pred_slot_valid_fifo_q[inf_head_q];
  assign inf_head_pred_slot_idx_w = inf_pred_slot_idx_fifo_q[inf_head_q];
  assign inf_head_pred_target_w = inf_pred_target_fifo_q[inf_head_q];
  assign inf_head_ftq_id_w = inf_ftq_id_fifo_q[inf_head_q];
  assign inf_head_epoch_w = inf_epoch_fifo_q[inf_head_q];

  always_comb begin
    req_outstanding_w = {1'b0, req_count_q} + {{(REQ_CNT_W + 1 - (INF_CNT_W)){1'b0}}, inf_count_q};
    storage_budget_w = {1'b0, fq_count_q} + {{(FQ_CNT_W + 1 - (INF_CNT_W)){1'b0}}, inf_count_q};
  end
  assign flush_next_epoch_w = fetch_epoch_q + EPOCH_W'(1);
  assign satp_changed_w = (mmu_satp_i != mmu_satp_prev_q);
  assign local_mmu_flush_w = satp_changed_w || mmu_sfence_vma_i;
  assign ifu_flush_w = flush_i || local_mmu_flush_w;
  assign local_mmu_replay_pc_w =
      !inf_fifo_empty_w ? inf_head_pc_w :
      (!req_fifo_empty_w ? req_head_pc_w : pc_reg);

  // BPU side: enqueue requests into pending FIFO when space is available.
  assign bpu_query_pc_w = flush_i ? redirect_pc_i : pc_reg;
  assign can_accept_bpu_w = !local_mmu_flush_w &&
                            (flush_i ? 1'b1 : (!req_fifo_full_w || req_pop_w)) &&
                            ftq_alloc_ready_w;
  assign ifu2bpu_pc_o = bpu_query_pc_w;
  assign ifu2bpu_handshake_o.valid = can_accept_bpu_w;
  assign ifu2bpu_handshake_o.ready = can_accept_bpu_w && bpu2ifu_handshake_i.valid;
  assign req_enq_fire_w = ifu2bpu_handshake_o.valid && ifu2bpu_handshake_o.ready;
  assign ftq_alloc_pc_w = bpu_query_pc_w;
  assign ftq_alloc_epoch_w = flush_i ? flush_next_epoch_w : fetch_epoch_q;

  // ICache side: issue oldest pending request.
  assign translation_active_w = mmu_satp_i[31] && (mmu_priv_i != PRIV_LVL_M);
  assign issue_need_mmu_w = translation_active_w;
  assign issue_translation_ready_w = !issue_need_mmu_w || (mmu_state_q == MMU_ST_READY);
  assign issue_paddr_w = issue_need_mmu_w ? mmu_translated_paddr_q[Cfg.PLEN-1:0] : req_head_pc_w;

  assign rsp_epoch_match_w = !inf_fifo_empty_w && (inf_head_epoch_w == fetch_epoch_q);
  // During flush, IFU clears request/inflight queues. Incoming ICache responses in
  // that cycle must be ignored, otherwise a stale response may be captured and
  // consumed by the new control-flow epoch.
  assign rsp_capture_w = !ifu_flush_w && !inf_fifo_empty_w &&
                         icache2ifu_rsp_handshake_i.valid && rsp_epoch_match_w;
  assign drop_stale_rsp_w = !ifu_flush_w && icache2ifu_rsp_handshake_i.valid && (!rsp_epoch_match_w);

  // Conservative safety gate:
  // fq_count + inflight_count tracks worst-case buffered responses pressure.
  assign can_issue_req_w = !ifu_flush_w && !fault_pending_q && !req_fifo_empty_w && !inf_fifo_full_w &&
                           (storage_budget_w < (FQ_CNT_W + 1)'(FQ_DEPTH));
  assign req_block_flush_w = ifu_flush_w;
  assign req_block_reqq_empty_w = !ifu_flush_w && req_fifo_empty_w;
  assign req_block_inf_full_w = !ifu_flush_w && !req_fifo_empty_w && inf_fifo_full_w;
  assign req_block_storage_budget_w = !ifu_flush_w && !req_fifo_empty_w && !inf_fifo_full_w &&
                                      (storage_budget_w >= (FQ_CNT_W + 1)'(FQ_DEPTH));
  assign req_issue_valid_w = can_issue_req_w && issue_translation_ready_w;
  assign req_issue_fire_w = req_issue_valid_w && icache2ifu_rsp_handshake_i.ready;
  assign req_pop_w = req_issue_fire_w || fault_consume_w;

  assign mmu_req_fire_w = (mmu_state_q == MMU_ST_REQ) && mmu_req_ready_w;
  assign mmu_resp_fire_w = (mmu_state_q == MMU_ST_WAIT) && mmu_resp_valid_w;
  assign fault_consume_w = fault_pending_q && ifetch_fault_ready_i && !rsp_capture_w;

  assign flush_icache_o = ifu_flush_w;
  assign ifu2icache_req_handshake_o.valid = req_issue_valid_w;
  assign ifu2icache_req_handshake_o.ready = 1'b1;
  assign ifu2icache_req_addr_o = issue_paddr_w;

  assign ifetch_fault_valid_o = fault_pending_q;
  assign ifetch_fault_pc_o = fault_pc_q;
  assign ifetch_fault_tval_o = fault_tval_q;
  assign ifetch_fault_cause_o = EXC_INST_PAGE_FAULT;
`ifndef SYNTHESIS
  assign aa_req_watch_w = ifu_bsearch_trace_en_q ?
      ((req_head_pc_w >= 32'hc0399920) && (req_head_pc_w <= 32'hc03999b0)) :
      ((req_head_pc_w >= IFU_AA_WIN_START) && (req_head_pc_w <= IFU_AA_WIN_END));
  assign aa_inf_watch_w = ifu_bsearch_trace_en_q ?
      ((inf_head_pc_w >= 32'hc0399920) && (inf_head_pc_w <= 32'hc03999b0)) :
      ((inf_head_pc_w >= IFU_AA_WIN_START) && (inf_head_pc_w <= IFU_AA_WIN_END));
`endif

  // IBuffer dequeue and response push decisions via bundle FIFO.
  assign fq_enq_valid_w = rsp_capture_w;
  assign rsp_push_fq_w = fq_enq_valid_w && fq_enq_ready_w;
  assign fq_deq_ready_w = ibuffer_ifu_rsp_ready_i;
  assign ibuf_pop_w = !fq_empty_w && fq_deq_valid_w && fq_deq_ready_w;

  for (genvar i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin : gen_ifu_rvc_probe
    compressed_decoder u_compressed_decoder (
        .instr_i({16'b0, icache2ifu_rsp_data_i[i][15:0]}),
        .instr_o(),
        .is_compressed_o(rsp_slot_compressed_w[i]),
        .is_illegal_o()
    );
  end

  always_comb begin
    for (int i = 0; i < Cfg.INSTR_PER_FETCH; i++) begin
      logic [Cfg.PLEN-1:0] slot_pc;
      rsp_slot_valid_w[i] = 1'b1;
      slot_pc = inf_head_pc_w + Cfg.PLEN'(INSTR_BYTES * i);
      rsp_pred_npc_w[i] =
          slot_pc + Cfg.PLEN'(rsp_slot_compressed_w[i] ? 2 : INSTR_BYTES);
      rsp_ftq_id_w[i] = inf_head_ftq_id_w;
      rsp_fetch_epoch_w[i] = inf_head_epoch_w;
      if (inf_head_pred_slot_valid_w) begin
        rsp_slot_valid_w[i] = (i <= int'(inf_head_pred_slot_idx_w));
        if (i > int'(inf_head_pred_slot_idx_w)) begin
          rsp_pred_npc_w[i] = '0;
        end else if (i == int'(inf_head_pred_slot_idx_w)) begin
          rsp_pred_npc_w[i] = inf_head_pred_target_w;
        end
      end
    end
  end

  assign fq_enq_data_w = {inf_head_pc_w, icache2ifu_rsp_data_i, rsp_slot_valid_w, rsp_pred_npc_w,
                          rsp_ftq_id_w, rsp_fetch_epoch_w};
  assign {ifu_ibuffer_rsp_pc_o, ifu_ibuffer_rsp_data_o, ifu_ibuffer_rsp_slot_valid_o,
          ifu_ibuffer_rsp_pred_npc_o, ifu_ibuffer_rsp_ftq_id_o,
          ifu_ibuffer_rsp_fetch_epoch_o} = fq_deq_data_w;
  assign ifu_ibuffer_rsp_valid_o = fq_deq_valid_w;

  assign ftq_free_valid_w = fault_consume_w || rsp_capture_w;
  assign ftq_free_id_w = fault_consume_w ? req_head_ftq_id_w : inf_head_ftq_id_w;

  sv32_mmu u_ifu_mmu (
      .clk_i(clk),
      .rst_ni(~rst),
      .req_valid_i(mmu_state_q == MMU_ST_REQ),
      .req_vaddr_i({{(32-Cfg.PLEN){1'b0}}, req_head_pc_w}),
      .req_access_i(MMU_ACCESS_INSTR),
      .req_priv_i(mmu_priv_i),
      .req_sum_i(mmu_sum_i),
      .req_mxr_i(mmu_mxr_i),
      .satp_i(mmu_satp_i),
      .sfence_vma_i(mmu_sfence_vma_i),
      .req_ready_o(mmu_req_ready_w),
      .resp_valid_o(mmu_resp_valid_w),
      .resp_paddr_o(mmu_resp_paddr_w),
      .resp_page_fault_o(mmu_resp_page_fault_w),
      .pte_req_valid_o(pte_req_valid_o),
      .pte_req_ready_i(pte_req_ready_i),
      .pte_req_paddr_o(pte_req_paddr_o),
      .pte_rsp_valid_i(pte_rsp_valid_i),
      .pte_rsp_data_i(pte_rsp_data_i),
      .pte_upd_valid_o(pte_upd_valid_o),
      .pte_upd_ready_i(pte_upd_ready_i),
      .pte_upd_paddr_o(pte_upd_paddr_o),
      .pte_upd_data_o(pte_upd_data_o)
  );

  ftq #(
      .Cfg(Cfg),
      .DEPTH(FTQ_DEPTH),
      .EPOCH_W(EPOCH_W)
  ) u_ftq (
      .clk_i(clk),
      .rst_ni(~rst),
      .flush_i(ifu_flush_w),
      .alloc_valid_i(req_enq_fire_w),
      .alloc_ready_o(ftq_alloc_ready_w),
      .alloc_fire_o(ftq_alloc_fire_w),
      .alloc_id_o(ftq_alloc_id_w),
      .alloc_pc_i(ftq_alloc_pc_w),
      .alloc_pred_slot_valid_i(bpu2ifu_pred_slot_valid_i),
      .alloc_pred_slot_idx_i(bpu2ifu_pred_slot_idx_i),
      .alloc_pred_target_i(bpu2ifu_pred_target_i),
      .alloc_epoch_i(ftq_alloc_epoch_w),
      .free_valid_i(ftq_free_valid_w),
      .free_id_i(ftq_free_id_w),
      .lookup_valid_i(1'b0),
      .lookup_id_i('0),
      .lookup_hit_o(),
      .lookup_pc_o(),
      .lookup_pred_slot_valid_o(),
      .lookup_pred_slot_idx_o(),
      .lookup_pred_target_o(),
      .lookup_epoch_o(),
      .count_o(ftq_count_w)
  );

  bundle_fifo #(
      .DATA_W(FQ_DATA_W),
      .DEPTH(FQ_DEPTH),
      .BYPASS_EN(Cfg.IFU_FETCHQ_BYPASS_EN != 0)
  ) u_fetch_queue (
      .clk_i(clk),
      .rst_ni(~rst),
      .flush_i(ifu_flush_w),
      .enq_valid_i(fq_enq_valid_w),
      .enq_ready_o(fq_enq_ready_w),
      .enq_data_i(fq_enq_data_w),
      .deq_valid_o(fq_deq_valid_w),
      .deq_ready_i(fq_deq_ready_w),
      .deq_data_o(fq_deq_data_w),
      .count_o(fq_count_q),
      .full_o(fq_full_w),
      .empty_o(fq_empty_w)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_reg <= Cfg.PLEN'(Cfg.RESET_VECTOR);
      fetch_epoch_q <= '0;

      req_pc_fifo_q <= '0;
      req_pred_slot_valid_fifo_q <= '0;
      req_pred_slot_idx_fifo_q <= '0;
      req_pred_target_fifo_q <= '0;
      req_ftq_id_fifo_q <= '0;
      req_epoch_fifo_q <= '0;
      req_head_q <= '0;
      req_tail_q <= '0;
      req_count_q <= '0;

      inf_pc_fifo_q <= '0;
      inf_pred_slot_valid_fifo_q <= '0;
      inf_pred_slot_idx_fifo_q <= '0;
      inf_pred_target_fifo_q <= '0;
      inf_ftq_id_fifo_q <= '0;
      inf_epoch_fifo_q <= '0;
      inf_head_q <= '0;
      inf_tail_q <= '0;
      inf_count_q <= '0;
      mmu_state_q <= MMU_ST_IDLE;
      mmu_translated_paddr_q <= '0;
      mmu_satp_prev_q <= '0;
      fault_pending_q <= 1'b0;
      fault_pc_q <= '0;
      fault_tval_q <= '0;
`ifndef SYNTHESIS
      ifu_pc_dbg_cnt_q <= '0;
      ifu_aa_dbg_cnt_q <= '0;
`endif

    end else begin
      if (rsp_capture_w && !fq_enq_ready_w) begin
        $fatal(1, "[ifu] rsp captured while fetch queue not ready (response drop hazard)");
      end
      if (flush_i) begin
        fetch_epoch_q <= flush_next_epoch_w;

        req_head_q <= '0;
        if (req_enq_fire_w) begin
          req_pc_fifo_q['0] <= bpu_query_pc_w;
          req_pred_slot_valid_fifo_q['0] <= bpu2ifu_pred_slot_valid_i;
          req_pred_slot_idx_fifo_q['0] <= bpu2ifu_pred_slot_idx_i;
          req_pred_target_fifo_q['0] <= bpu2ifu_pred_target_i;
          req_ftq_id_fifo_q['0] <= ftq_alloc_id_w;
          req_epoch_fifo_q['0] <= flush_next_epoch_w;
          req_tail_q <= REQ_PTR_W'(1);
          req_count_q <= REQ_CNT_W'(1);
          pc_reg <= bpu2ifu_predicted_pc_i;
        end else begin
          req_tail_q <= '0;
          req_count_q <= '0;
          pc_reg <= redirect_pc_i;
        end

        inf_head_q <= '0;
        inf_tail_q <= '0;
        inf_count_q <= '0;
        mmu_state_q <= MMU_ST_IDLE;
        mmu_translated_paddr_q <= '0;
        fault_pending_q <= 1'b0;
        fault_pc_q <= '0;
        fault_tval_q <= '0;
      end else if (local_mmu_flush_w) begin
        // Drop stale fetch requests/responses when SATP or SFENCE.VMA changes translation context.
        // Replay the oldest outstanding virtual PC; keeping speculative pc_reg can
        // restart mid-instruction after the queue contents carrying RVC state are dropped.
        fetch_epoch_q <= flush_next_epoch_w;
        pc_reg <= local_mmu_replay_pc_w;
        req_head_q <= '0;
        req_tail_q <= '0;
        req_count_q <= '0;
        inf_head_q <= '0;
        inf_tail_q <= '0;
        inf_count_q <= '0;
        mmu_state_q <= MMU_ST_IDLE;
        mmu_translated_paddr_q <= '0;
        fault_pending_q <= 1'b0;
        fault_pc_q <= '0;
        fault_tval_q <= '0;
      end else begin
        if (req_enq_fire_w) begin
          req_pc_fifo_q[req_tail_q] <= pc_reg;
          req_pred_slot_valid_fifo_q[req_tail_q] <= bpu2ifu_pred_slot_valid_i;
          req_pred_slot_idx_fifo_q[req_tail_q] <= bpu2ifu_pred_slot_idx_i;
          req_pred_target_fifo_q[req_tail_q] <= bpu2ifu_pred_target_i;
          req_ftq_id_fifo_q[req_tail_q] <= ftq_alloc_id_w;
          req_epoch_fifo_q[req_tail_q] <= fetch_epoch_q;
          req_tail_q <= req_ptr_inc(req_tail_q);
          pc_reg <= bpu2ifu_predicted_pc_i;
        end

        if (!issue_need_mmu_w) begin
          mmu_state_q <= MMU_ST_IDLE;
        end else begin
          if ((mmu_state_q == MMU_ST_IDLE) && can_issue_req_w) begin
            mmu_state_q <= MMU_ST_REQ;
          end
          if (mmu_req_fire_w) begin
            mmu_state_q <= MMU_ST_WAIT;
          end
          if (mmu_resp_fire_w) begin
            if (mmu_resp_page_fault_w) begin
              mmu_state_q <= MMU_ST_IDLE;
              fault_pending_q <= 1'b1;
              fault_pc_q <= req_head_pc_w;
              fault_tval_q <= req_head_pc_w;
            end else begin
              mmu_state_q <= MMU_ST_READY;
              mmu_translated_paddr_q <= mmu_resp_paddr_w;
            end
          end
          if (req_issue_fire_w) begin
            mmu_state_q <= MMU_ST_IDLE;
          end
        end

        if (fault_consume_w) begin
          fault_pending_q <= 1'b0;
        end

        if (req_issue_fire_w) begin
          inf_pc_fifo_q[inf_tail_q] <= req_head_pc_w;
          inf_pred_slot_valid_fifo_q[inf_tail_q] <= req_head_pred_slot_valid_w;
          inf_pred_slot_idx_fifo_q[inf_tail_q] <= req_head_pred_slot_idx_w;
          inf_pred_target_fifo_q[inf_tail_q] <= req_head_pred_target_w;
          inf_ftq_id_fifo_q[inf_tail_q] <= req_head_ftq_id_w;
          inf_epoch_fifo_q[inf_tail_q] <= req_head_epoch_w;
          inf_tail_q <= inf_ptr_inc(inf_tail_q);
        end

        if (req_pop_w) begin
          req_head_q <= req_ptr_inc(req_head_q);
        end

        if (rsp_capture_w) begin
          inf_head_q <= inf_ptr_inc(inf_head_q);
        end

        unique case ({req_enq_fire_w, req_pop_w})
          2'b10: req_count_q <= req_count_q + REQ_CNT_W'(1);
          2'b01: req_count_q <= req_count_q - REQ_CNT_W'(1);
          default: begin
          end
        endcase

        unique case ({req_issue_fire_w, rsp_capture_w})
          2'b10: inf_count_q <= inf_count_q + INF_CNT_W'(1);
          2'b01: inf_count_q <= inf_count_q - INF_CNT_W'(1);
          default: begin
          end
        endcase
      end
      mmu_satp_prev_q <= mmu_satp_i;
    end
`ifdef TRIATHLON_VERBOSE
    $display("pc_reg: %h", pc_reg);
    $display("ifu_bpu(enq_v/enq_r/enq_fire): %0d/%0d/%0d", ifu2bpu_handshake_o.valid,
             ifu2bpu_handshake_o.ready, req_enq_fire_w);
    $display("ifu_req(v/r/fire): %0d/%0d/%0d", req_issue_valid_w,
             icache2ifu_rsp_handshake_i.ready, req_issue_fire_w);
    $display("ifu_rsp(v/cap/drop): %0d/%0d/%0d",
             icache2ifu_rsp_handshake_i.valid, rsp_capture_w, drop_stale_rsp_w);
    $display("ifu_epoch(fetch/head/match): %0d/%0d/%0d",
             fetch_epoch_q, inf_head_epoch_w, rsp_epoch_match_w);
    $display("ifu_reqq(pending/inflight/outstanding): %0d/%0d/%0d", req_count_q,
             inf_count_q, req_outstanding_w);
    $display("ifu_fq(cnt/full/empty): %0d/%0d/%0d", fq_count_q, fq_full_w, fq_empty_w);
    $display("ifu_ibuf(v/r/pop): %0d/%0d/%0d", ifu_ibuffer_rsp_valid_o,
             ibuffer_ifu_rsp_ready_i, ibuf_pop_w);
    $display("\n");
`endif
`ifndef SYNTHESIS

    if (ifu_diag_trace_en_q && req_issue_fire_w && (ifu_pc_dbg_cnt_q < IFU_PC_DBG_BUDGET) && (
        ((req_head_pc_w & 32'hfffff000) == 32'hc0800000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'hc0401000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'hc080a000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'hc0803000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'hc0787000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'hc0097000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'h8080a000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'h80803000) ||
        ((req_head_pc_w[31:28] == 4'hc) && (issue_paddr_w[31:28] == 4'h0)))) begin
      $display("[ifu-issue] pc=%h paddr=%h satp=%h priv=%0d need_mmu=%0d state=%0d mmu_paddr_q=%h epoch=%0d",
               req_head_pc_w, issue_paddr_w, mmu_satp_i, mmu_priv_i, issue_need_mmu_w, mmu_state_q,
               mmu_translated_paddr_q, req_head_epoch_w);
      ifu_pc_dbg_cnt_q <= ifu_pc_dbg_cnt_q + 32'd1;
    end
    if (ifu_diag_trace_en_q && mmu_resp_fire_w && (ifu_pc_dbg_cnt_q < IFU_PC_DBG_BUDGET) && (
        ((req_head_pc_w & 32'hfffff000) == 32'hc0800000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'hc0401000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'hc080a000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'hc0803000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'hc0787000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'hc0097000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'h8080a000) ||
        ((req_head_pc_w & 32'hfffff000) == 32'h80803000))) begin
      $display("[ifu-mmu-rsp] vaddr=%h paddr=%h pf=%0d satp=%h priv=%0d state=%0d",
               req_head_pc_w, mmu_resp_paddr_w, mmu_resp_page_fault_w, mmu_satp_i, mmu_priv_i,
               mmu_state_q);
      ifu_pc_dbg_cnt_q <= ifu_pc_dbg_cnt_q + 32'd1;
    end
    if (ifu_diag_trace_en_q && (flush_i || local_mmu_flush_w) &&
        (ifu_pc_dbg_cnt_q < IFU_PC_DBG_BUDGET) &&
        (((redirect_pc_i & 32'hf0000000) == 32'hc0000000) ||
         ((pc_reg & 32'hf0000000) == 32'hc0000000))) begin
      $display("[ifu-flush] flush_i=%0d local=%0d satp_changed=%0d sfence=%0d redir=%h pc_reg=%h req_cnt=%0d inf_cnt=%0d enq=%0d pred=%h epoch=%0d->%0d",
               flush_i, local_mmu_flush_w, satp_changed_w, mmu_sfence_vma_i, redirect_pc_i, pc_reg,
               req_count_q, inf_count_q, req_enq_fire_w, bpu2ifu_predicted_pc_i, fetch_epoch_q, flush_next_epoch_w);
      ifu_pc_dbg_cnt_q <= ifu_pc_dbg_cnt_q + 32'd1;
    end

    if (ifu_diag_trace_en_q && req_issue_fire_w && aa_req_watch_w &&
        (ifu_aa_dbg_cnt_q < IFU_AA_DBG_BUDGET)) begin
      $display("[ifu-aa-issue] vaddr=%h paddr=%h satp=%h priv=%0d need_mmu=%0d mmu_state=%0d epoch=%0d req_cnt=%0d inf_cnt=%0d",
               req_head_pc_w, issue_paddr_w, mmu_satp_i, mmu_priv_i, issue_need_mmu_w, mmu_state_q,
               req_head_epoch_w, req_count_q, inf_count_q);
      ifu_aa_dbg_cnt_q <= ifu_aa_dbg_cnt_q + 32'd1;
    end

    if (ifu_diag_trace_en_q && mmu_resp_fire_w && aa_req_watch_w &&
        (ifu_aa_dbg_cnt_q < IFU_AA_DBG_BUDGET)) begin
      $display("[ifu-aa-mmu-rsp] vaddr=%h paddr=%h pf=%0d satp=%h priv=%0d mmu_state=%0d",
               req_head_pc_w, mmu_resp_paddr_w, mmu_resp_page_fault_w, mmu_satp_i, mmu_priv_i, mmu_state_q);
      ifu_aa_dbg_cnt_q <= ifu_aa_dbg_cnt_q + 32'd1;
    end

    if (ifu_diag_trace_en_q && rsp_capture_w && aa_inf_watch_w &&
        (ifu_aa_dbg_cnt_q < IFU_AA_DBG_BUDGET)) begin
      $display("[ifu-aa-rsp] base_vaddr=%h satp=%h epoch=%0d inf_cnt=%0d",
               inf_head_pc_w, mmu_satp_i, inf_head_epoch_w, inf_count_q);
      for (int slot = 0; slot < Cfg.INSTR_PER_FETCH; slot++) begin
        logic [Cfg.PLEN-1:0] slot_vaddr;
        slot_vaddr = inf_head_pc_w + Cfg.PLEN'(INSTR_BYTES * slot);
        $display("[ifu-aa-rsp-slot] slot=%0d vaddr=%h inst=%h valid=%0d pred_npc=%h",
                 slot, slot_vaddr, icache2ifu_rsp_data_i[slot], rsp_slot_valid_w[slot], rsp_pred_npc_w[slot]);
      end
      ifu_aa_dbg_cnt_q <= ifu_aa_dbg_cnt_q + 32'd1;
    end
`endif
  end

endmodule : ifu
