// vsrc/test/tb_frontend.sv
import config_pkg::*;
import global_config_pkg::*;

module tb_frontend (
    input logic clk_i,
    input logic rst_ni,

    // ============================================
    // 1. 后端/IBuffer 接口 (To Backend)
    // ============================================
    output logic                                    ibuffer_valid_o,
    input  logic                                    ibuffer_ready_i,
    // 将 packed array 展平以便 C++ 访问 (4 * 32 = 128 bit)
    output logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] ibuffer_data_o,
    output logic [                    Cfg.PLEN-1:0] ibuffer_pc_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0]          ibuffer_slot_valid_o,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.PLEN-1:0] ibuffer_pred_npc_o,
    output logic [Cfg.INSTR_PER_FETCH*((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ibuffer_ftq_id_o,
    output logic [Cfg.INSTR_PER_FETCH*3-1:0] ibuffer_fetch_epoch_o,

    input logic                flush_i,
    input logic [Cfg.PLEN-1:0] redirect_pc_i,
    input logic                bpu_update_valid_i,
    input logic [Cfg.PLEN-1:0] bpu_update_pc_i,
    input logic                bpu_update_is_cond_i,
    input logic                bpu_update_taken_i,
    input logic [Cfg.PLEN-1:0] bpu_update_target_i,
    input logic                bpu_update_is_call_i,
    input logic                bpu_update_is_ret_i,
    input logic                bpu_update_is_rvc_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_valid_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_is_call_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_is_ret_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_is_rvc_i,
    input logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] bpu_ras_update_pc_i,

    // ============================================
    // 2. 存储器系统接口 (To Memory/L2/Bus)
    // ============================================
    output logic                                  miss_req_valid_o,
    input  logic                                  miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] miss_req_index_o,

    input  logic                                  refill_valid_i,
    output logic                                  refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] refill_data_i,

    // IFU debug (for frontend decoupling tests)
    output logic                                  dbg_ifu_req_valid_o,
    output logic                                  dbg_ifu_req_ready_o,
    output logic                                  dbg_ifu_req_fire_o,
    output logic [                  Cfg.PLEN-1:0] dbg_ifu_req_addr_o,
    output logic                                  dbg_ifu_rsp_valid_o,
    output logic                                  dbg_ifu_rsp_capture_o,
    output logic                                  dbg_ifu_ibuf_valid_o,
    output logic [                           3:0] dbg_ifu_outstanding_o,
    output logic [                           3:0] dbg_ifu_pending_o,
    output logic [                           3:0] dbg_ifu_inflight_o,
    output logic                                  dbg_ifu_drop_stale_rsp_o,
    output logic [((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] dbg_ibuf_ftq_id_slot0_o,
    output logic [2:0] dbg_ibuf_fetch_epoch_slot0_o,
    output logic dbg_ibuf_meta_uniform_o
);

  // 内部信号转换：将展平的 ibuffer_data_o 转回 frontend 需要的 packed 格式 (如果需要的话，或者直接连接)
  // frontend 的输出是 logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0]
  // SystemVerilog 的 packed array 和展平的 vector 在 bit 布局上通常是兼容的，可以直接 assign

  frontend #(
      .Cfg(Cfg)
  ) DUT (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .ibuffer_valid_o(ibuffer_valid_o),
      .ibuffer_ready_i(ibuffer_ready_i),
      .ibuffer_data_o (ibuffer_data_o),
      .ibuffer_pc_o   (ibuffer_pc_o),
      .ibuffer_slot_valid_o(ibuffer_slot_valid_o),
      .ibuffer_pred_npc_o(ibuffer_pred_npc_o),
      .ibuffer_ftq_id_o(ibuffer_ftq_id_o),
      .ibuffer_fetch_epoch_o(ibuffer_fetch_epoch_o),

      .flush_i      (flush_i),
      .redirect_pc_i(redirect_pc_i),
      .bpu_update_valid_i(bpu_update_valid_i),
      .bpu_update_pc_i(bpu_update_pc_i),
      .bpu_update_is_cond_i(bpu_update_is_cond_i),
      .bpu_update_taken_i(bpu_update_taken_i),
      .bpu_update_target_i(bpu_update_target_i),
      .bpu_update_is_call_i(bpu_update_is_call_i),
      .bpu_update_is_ret_i(bpu_update_is_ret_i),
      .bpu_update_is_rvc_i(bpu_update_is_rvc_i),
      .bpu_ras_update_valid_i(bpu_ras_update_valid_i),
      .bpu_ras_update_is_call_i(bpu_ras_update_is_call_i),
      .bpu_ras_update_is_ret_i(bpu_ras_update_is_ret_i),
      .bpu_ras_update_is_rvc_i(bpu_ras_update_is_rvc_i),
      .bpu_ras_update_pc_i(bpu_ras_update_pc_i),
      .mmu_satp_i('0),
      .mmu_priv_i(2'b11),
      .mmu_sum_i(1'b0),
      .mmu_mxr_i(1'b0),
      .mmu_sfence_vma_i(1'b0),
      .ifetch_fault_valid_o(),
      .ifetch_fault_ready_i(1'b1),
      .ifetch_fault_pc_o(),
      .ifetch_fault_tval_o(),
      .ifetch_fault_cause_o(),
      .pte_req_valid_o(),
      .pte_req_ready_i(1'b1),
      .pte_req_paddr_o(),
      .pte_rsp_valid_i(1'b0),
      .pte_rsp_data_i('0),
      .pte_upd_valid_o(),
      .pte_upd_ready_i(1'b1),
      .pte_upd_paddr_o(),
      .pte_upd_data_o(),

      .miss_req_valid_o     (miss_req_valid_o),
      .miss_req_ready_i     (miss_req_ready_i),
      .miss_req_paddr_o     (miss_req_paddr_o),
      .miss_req_victim_way_o(miss_req_victim_way_o),
      .miss_req_index_o     (miss_req_index_o),

      .refill_valid_i(refill_valid_i),
      .refill_ready_o(refill_ready_o),
      .refill_paddr_i(refill_paddr_i),
      .refill_way_i  (refill_way_i),
      .refill_data_i (refill_data_i)
  );

  assign dbg_ifu_req_valid_o = DUT.ifu2icache_req_handshake.valid;
  assign dbg_ifu_req_ready_o = DUT.icache2ifu_rsp_handshake.ready;
  assign dbg_ifu_req_fire_o = DUT.ifu2icache_req_handshake.valid & DUT.icache2ifu_rsp_handshake.ready;
  assign dbg_ifu_req_addr_o = DUT.ifu2icache_req_addr;
  assign dbg_ifu_rsp_valid_o = DUT.icache2ifu_rsp_handshake.valid;
  assign dbg_ifu_rsp_capture_o = DUT.i_ifu.rsp_capture_w;
  assign dbg_ifu_ibuf_valid_o = DUT.ibuffer_valid_o;
  assign dbg_ifu_outstanding_o = 4'(DUT.i_ifu.req_outstanding_w);
  assign dbg_ifu_pending_o = 4'(DUT.i_ifu.req_count_q);
  assign dbg_ifu_inflight_o = 4'(DUT.i_ifu.inf_count_q);
  assign dbg_ifu_drop_stale_rsp_o = DUT.i_ifu.drop_stale_rsp_w;
  assign dbg_ibuf_ftq_id_slot0_o = DUT.ibuffer_ftq_id_o[0];
  assign dbg_ibuf_fetch_epoch_slot0_o = DUT.ibuffer_fetch_epoch_o[0];
  always_comb begin
    dbg_ibuf_meta_uniform_o = 1'b1;
    for (int i = 1; i < Cfg.INSTR_PER_FETCH; i++) begin
      if (DUT.ibuffer_slot_valid_o[i]) begin
        if ((DUT.ibuffer_ftq_id_o[i] != DUT.ibuffer_ftq_id_o[0]) ||
            (DUT.ibuffer_fetch_epoch_o[i] != DUT.ibuffer_fetch_epoch_o[0])) begin
          dbg_ibuf_meta_uniform_o = 1'b0;
        end
      end
    end
  end

endmodule
