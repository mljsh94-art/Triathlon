// vsrc/backend/lsu/lsu_group.sv
import config_pkg::*;
import decode_pkg::*;

module lsu_group #(
    parameter config_pkg::cfg_t Cfg           = config_pkg::EmptyCfg,
    parameter int unsigned      ROB_IDX_WIDTH = 6,
    parameter int unsigned      SB_DEPTH      = 32,
    parameter int unsigned      ST_IDX_WIDTH  = $clog2(SB_DEPTH),
    parameter int unsigned      LDQ_DEPTH      = 16,
    parameter int unsigned      SQ_DEPTH      = 16,
    parameter int unsigned      N_LSU         = 1,
    parameter int unsigned      COMMIT_WIDTH  = 4,
    parameter int unsigned      ECAUSE_WIDTH  = 5,
    // Writeback experiment: widen LSU completion to LSU_WB_PORTS CDB ports.
    // Ports [0 .. LOAD_WB_PORTS-1] carry load-lane writebacks (arbiter grants
    // up to LOAD_WB_PORTS distinct lanes per cycle); the final port carries the
    // store-writeback queue head. LSU_WB_PORTS = LOAD_WB_PORTS + 1.
    parameter int unsigned      LOAD_WB_PORTS = 2,
    parameter int unsigned      LSU_WB_PORTS  = LOAD_WB_PORTS + 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // ROB commit broadcast: used to free LDQ entries (loads live until retire).
    input logic [COMMIT_WIDTH-1:0]                    commit_valid_i,
    input logic [COMMIT_WIDTH-1:0][ROB_IDX_WIDTH-1:0] commit_rob_idx_i,

    // =========================================================
    // 1) Request from Issue/Execute
    // Dual dispatch lanes (port0/port1, dcache-load-dual-issue Phase 2): up
    // to 2 load/store candidates can arrive from issue_lsu in one cycle.
    // req_ready_o stays a SINGLE ready line with an "all or nothing"
    // contract: issue gates both lanes off one shared fu_ready_i (see
    // issue_base_allow in issue_lsu.sv), so req_ready_o is only asserted
    // when every candidate flagged by cand_valid_i this cycle can be
    // admitted (0, 1 or 2 of them). cand_valid_i mirrors the RS pick
    // *before* fu_ready_i gating and must be what req_ready_o's combinational
    // logic reads (never req_valid_i / lsu_en), or fu_ready_i <-> req_ready_o
    // would form a combinational loop (see issue_lsu.sv comment above
    // lsu_cand_v). 2x AGU + a dual alloc-grant + dual ldq alloc (see
    // dual_candidate_ok / dual_fire below) let the group actually admit both
    // candidates in one cycle when they are both plain loads that need no
    // MMU walk; anything else (a store, AMO, LR, misaligned access, or a
    // walk-needing candidate — see the MMU single-walk mutex comment above
    // dual_candidate_ok) still falls back to holding req_ready_o at 0 for the
    // whole pair (see req_ready_o below) so a flagged-but-unconsumed lane can
    // never be silently dropped, only deferred to a later cycle where port0
    // (sel_uop's tie-break winner) gets to admit alone.
    // =========================================================
    input  logic                                 req_valid_i [0:1],
    output logic                                 req_ready_o,
    // Raw RS picks from issue (pre port1 gating). Used to classify whether
    // port1 is a true dual-issue peer this cycle without a cand_valid loop.
    input  logic                                 pick_valid_i[0:1],
    // When both pick_valid_i lanes are set but the pair cannot use the dual
    // fast path (load+store, AMO, walk, ...), issue must not grant/fire port1.
    output logic                                 dual_port1_en_o,
    input  logic                                 cand_valid_i[0:1],
    input  decode_pkg::uop_t                     uop_i        [0:1],
    input  logic             [     Cfg.XLEN-1:0] rs1_data_i   [0:1],
    input  logic             [     Cfg.XLEN-1:0] rs2_data_i   [0:1],
    input  logic             [ROB_IDX_WIDTH-1:0] rob_tag_i    [0:1],
    input  logic             [ROB_IDX_WIDTH-1:0] rob_head_i,
    input  logic             [ ST_IDX_WIDTH-1:0] st_id_i      [0:1],
    input  logic             [            31:0]   mmu_satp_i,
    input  logic             [             1:0]   mmu_priv_i,
    input  logic                                 mmu_sum_i,
    input  logic                                 mmu_mxr_i,
    input  logic                                 mmu_sfence_vma_i,

    // =========================================================
    // 2) STQ interface (execute fill)
    // =========================================================
    output logic                                    st_ex_valid_o,
    output logic                [ ST_IDX_WIDTH-1:0] st_ex_st_id_o,
    output logic                [     Cfg.PLEN-1:0] st_ex_addr_o,
    output logic                [     Cfg.XLEN-1:0] st_ex_data_o,
    output decode_pkg::lsu_op_e                     st_ex_op_o,
    output logic                [ROB_IDX_WIDTH-1:0] st_ex_rob_idx_o,

    // Store-to-Load Forwarding (query) — stq 为唯一转发源
    // Port0/bus0 query: the single-consumption sel_uop/pend pipeline's load
    // (dispatch port mux — see "Dispatch port mux" comment below).
    output logic [     Cfg.PLEN-1:0] stq_fwd_addr_o,
    output logic [   Cfg.XLEN/8-1:0] stq_fwd_be_o,
    output logic [ROB_IDX_WIDTH-1:0] stq_fwd_rob_idx_o,
    input  logic                     stq_fwd_hit_i,
    input  logic [     Cfg.XLEN-1:0] stq_fwd_data_i,
    // Port1/bus1 query (dcache-load-dual-issue Phase 2, task lsu-group-mmu-fwd):
    // second, fully independent query for the dual-admission fast path's plain
    // load (see dual_fire below). Only meaningful the cycle dual_fire is
    // asserted; connects to stq's second query port (load_be_i2/addr_i2/
    // rob_idx_i2 -> load_hit_o2/data_o2).
    output logic [     Cfg.PLEN-1:0] stq_fwd_addr_o2,
    output logic [   Cfg.XLEN/8-1:0] stq_fwd_be_o2,
    output logic [ROB_IDX_WIDTH-1:0] stq_fwd_rob_idx_o2,
    input  logic                     stq_fwd_hit_i2,
    input  logic [     Cfg.XLEN-1:0] stq_fwd_data_i2,
    output logic                     st_order_query_valid_o,
    output logic [ ST_IDX_WIDTH-1:0] st_order_query_st_id_o,
    input  logic                     st_order_query_clear_i,

    // Store 完成上报 (store_wb_q 已并入 stq)：lsu_group 在 store 准入时把完成
    // 字段填入 stq 条目；stq 反向给出最老未上报 store 的写回内容，由本模块的
    // 专用 store 写回口 (STORE_WB_PORT) 上报 ROB。
    output logic                       st_complete_valid_o,
    output logic [ ST_IDX_WIDTH-1:0]   st_complete_id_o,
    output logic [ROB_IDX_WIDTH-1:0]   st_complete_rob_idx_o,
    output logic [     Cfg.XLEN-1:0]   st_complete_data_o,
    output logic                       st_complete_exception_o,
    output logic [ ECAUSE_WIDTH-1:0]   st_complete_ecause_o,
    output logic                       st_complete_is_mispred_o,
    output logic [     Cfg.PLEN-1:0]   st_complete_redirect_pc_o,
    output logic [     Cfg.PLEN-1:0]   st_complete_pc_o,
    output logic                       st_wb_fire_o,

    input  logic                       st_wb_valid_i,
    input  logic [ROB_IDX_WIDTH-1:0]   st_wb_rob_idx_i,
    input  logic [     Cfg.XLEN-1:0]   st_wb_data_i,
    input  logic                       st_wb_exception_i,
    input  logic [ ECAUSE_WIDTH-1:0]   st_wb_ecause_i,
    input  logic                       st_wb_is_mispred_i,
    input  logic [     Cfg.PLEN-1:0]   st_wb_redirect_pc_i,
    input  logic [$clog2(SB_DEPTH+1)-1:0] st_unreported_count_i,

    // =========================================================
    // 3) D-Cache Load interface
    // =========================================================
    output logic                               ld_req_valid_o,
    input  logic                               ld_req_ready_i,
    output logic                [Cfg.PLEN-1:0] ld_req_addr_o,
    output decode_pkg::lsu_op_e                ld_req_op_o,
    output logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0] ld_req_id_o,

    input  logic                ld_rsp_valid_i,
    input  logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0] ld_rsp_id_i,
    output logic                ld_rsp_ready_o,
    input  logic [Cfg.XLEN-1:0] ld_rsp_data_i,
    input  logic                ld_rsp_err_i,

    // Second DCache load lane ("port B"): hit-only bypass. Granted only to a
    // second, already in-flight lane (distinct DCache bank from port A's pick
    // this cycle); a miss is reported via ld_rsp_b_miss_* instead of
    // ld_rsp_b_valid_i, and the group internally re-issues that lane's load
    // on port A (see pb_retry_* below) — the ld_pipe lanes themselves stay
    // unaware of port B and never see a request "rejected".
    output logic                               ld_req_b_valid_o,
    input  logic                               ld_req_b_ready_i,
    output logic                [Cfg.PLEN-1:0] ld_req_b_addr_o,
    output decode_pkg::lsu_op_e                ld_req_b_op_o,
    output logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0] ld_req_b_id_o,

    input  logic                ld_rsp_b_valid_i,
    input  logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0] ld_rsp_b_id_i,
    output logic                ld_rsp_b_ready_o,
    input  logic [Cfg.XLEN-1:0] ld_rsp_b_data_i,
    input  logic                ld_rsp_b_err_i,

    input  logic                ld_rsp_b_miss_i,
    input  logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0] ld_rsp_b_miss_id_i,

    // =========================================================
    // 3b) MMIO Uncached Load interface (bypass D-Cache)
    // =========================================================
    output logic                               mmio_req_valid_o,
    input  logic                               mmio_req_ready_i,
    output logic                [Cfg.PLEN-1:0] mmio_req_addr_o,
    output decode_pkg::lsu_op_e                mmio_req_op_o,

    input  logic                               mmio_rsp_valid_i,
    input  logic [Cfg.XLEN-1:0]                mmio_rsp_data_i,

    output logic                pte_req_valid_o,
    input  logic                pte_req_ready_i,
    output logic [31:0]         pte_req_paddr_o,
    input  logic                pte_rsp_valid_i,
    input  logic [31:0]         pte_rsp_data_i,
    output logic                pte_upd_valid_o,
    input  logic                pte_upd_ready_i,
    output logic [31:0]         pte_upd_paddr_o,
    output logic [31:0]         pte_upd_data_o,

    // =========================================================
    // 4) Writeback to ROB/CDB
    // =========================================================
    output logic [LSU_WB_PORTS-1:0]                     wb_valid_o,
    output logic [LSU_WB_PORTS-1:0][ROB_IDX_WIDTH-1:0]  wb_rob_idx_o,
    output logic [LSU_WB_PORTS-1:0][     Cfg.XLEN-1:0]  wb_data_o,
    output logic [LSU_WB_PORTS-1:0]                     wb_exception_o,
    output logic [LSU_WB_PORTS-1:0][ECAUSE_WIDTH-1:0]   wb_ecause_o,
    output logic [LSU_WB_PORTS-1:0]                     wb_is_mispred_o,
    output logic [LSU_WB_PORTS-1:0][     Cfg.PLEN-1:0]  wb_redirect_pc_o,
    input  logic [LSU_WB_PORTS-1:0]                     wb_ready_i,

    // Combinational fast-complete assist for ROB (load writeback ports only).
    output logic [LOAD_WB_PORTS-1:0]                     fast_lsu_valid_o,
    output logic [LOAD_WB_PORTS-1:0][ROB_IDX_WIDTH-1:0] fast_lsu_rob_idx_o,
    output logic [LOAD_WB_PORTS-1:0][     Cfg.XLEN-1:0] fast_lsu_data_o,
    output logic [LOAD_WB_PORTS-1:0]                     fast_lsu_exception_o,
    output logic [LOAD_WB_PORTS-1:0][ECAUSE_WIDTH-1:0]  fast_lsu_ecause_o,
    output logic [LOAD_WB_PORTS-1:0]                     fast_lsu_is_mispred_o,
    output logic [LOAD_WB_PORTS-1:0][     Cfg.PLEN-1:0] fast_lsu_redirect_pc_o,

    // =========================================================
    // 5) Debug visibility for queue skeleton
    // =========================================================
    output logic [$clog2(LDQ_DEPTH + 1)-1:0] dbg_ldq_count_o,
    output logic                            dbg_ldq_head_valid_o,
    output logic [       ROB_IDX_WIDTH-1:0] dbg_ldq_head_rob_tag_o,
    output logic [$clog2(SQ_DEPTH + 1)-1:0] dbg_sq_count_o,
    output logic                            dbg_sq_head_valid_o,
    output logic [       ROB_IDX_WIDTH-1:0] dbg_sq_head_rob_tag_o
);

  localparam int unsigned LANE_SEL_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU);
  localparam int unsigned STORE_WB_PORT = LOAD_WB_PORTS;  // dedicated store wb port index
  localparam int unsigned DBG_SEL_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU + 1);
  localparam int unsigned SQ_BE_WIDTH = Cfg.XLEN / 8;
  localparam int unsigned SQ_BYTE_OFF_W = (SQ_BE_WIDTH <= 1) ? 1 : $clog2(SQ_BE_WIDTH);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_ST_ADDR_MISALIGNED = ECAUSE_WIDTH'(6);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_LD_PAGE_FAULT = ECAUSE_WIDTH'(13);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_ST_PAGE_FAULT = ECAUSE_WIDTH'(15);
  localparam logic [1:0] MMU_ST_IDLE = 2'd0;
`ifndef SYNTHESIS
  localparam int unsigned LSU_PF_LOG_BUDGET = 128;
  int unsigned lsu_pf_log_cnt_q;
  localparam int unsigned LSU_STALL_TRACE_LOG_BUDGET = 256;
  int unsigned lsu_stall_trace_log_cnt_q;
  logic [15:0] lsu_stall_streak_q;
  logic lsu_trace_en_q;
  initial lsu_trace_en_q = $test$plusargs("npc_diag_trace");
  // #region agent log
  integer agent_dbg_fd;
  initial agent_dbg_fd = $fopen("/mnt/d/sjj_ict2026/Triathlon/debug-0e02a7.log", "a");
  // #endregion

  function automatic logic lsu_diag_watch_pc(input logic [31:0] pc);
    begin
      // Keep the watch list strict to avoid diag log storms in long runs.
      lsu_diag_watch_pc = (pc == 32'hc074befe) ||  // cmp_ex_search + 0x8
                          (pc == 32'hc076a580) ||  // exception pair A
                          (pc == 32'hc076a584) ||  // adjacent hot load
                          (pc == 32'hc074c47e) ||  // hang window load (stack restore)
                          (pc == 32'hc074c480) ||  // hang window load (stack restore)
                          (pc == 32'hc074cf9e);    // hang window load
    end
  endfunction
`endif

  // Keep these debug names for existing testbench hierarchical probes.
  logic                [               2:0]                    state_q;
  logic                [ ROB_IDX_WIDTH-1:0]                    req_tag_q;
  logic                [      Cfg.PLEN-1:0]                    req_addr_q;
  logic                [         N_LSU-1:0]                    dbg_lane_busy;
  logic                                                        dbg_alloc_fire;
  logic                [ DBG_SEL_WIDTH-1:0]                    dbg_alloc_lane;
  logic                [ DBG_SEL_WIDTH-1:0]                    dbg_ld_owner;

  logic                [         N_LSU-1:0]                    lane_req_valid;
  logic                [         N_LSU-1:0]                    lane_req_ready;

  logic                [         N_LSU-1:0]                    lane_st_ex_valid;
  logic                [         N_LSU-1:0][ ST_IDX_WIDTH-1:0] lane_st_ex_st_id;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_st_ex_addr;
  logic                [         N_LSU-1:0][     Cfg.XLEN-1:0] lane_st_ex_data;
  decode_pkg::lsu_op_e                                         lane_st_ex_op        [N_LSU];
  logic                [         N_LSU-1:0][ROB_IDX_WIDTH-1:0] lane_st_ex_rob_idx;

  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_stq_fwd_addr;
  logic                [         N_LSU-1:0][ROB_IDX_WIDTH-1:0] lane_stq_fwd_rob_idx;

  logic                [         N_LSU-1:0]                    lane_ld_req_valid;
  logic                [         N_LSU-1:0]                    lane_ld_req_ready;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_ld_req_addr;
  decode_pkg::lsu_op_e                                         lane_ld_req_op       [N_LSU];

  // Accept-to-DCache bypass for clean cacheable loads. These live requests are
  // OR'd into the arbiter input for the accept cycle only; if the DCache does
  // not take them, the owning ld_pipe falls back to its registered S_LD_REQ.
  logic                [         N_LSU-1:0]                    lane_accept_dcache_load;
  logic                [         N_LSU-1:0]                    lane_accept_dcache_candidate;
  logic                [         N_LSU-1:0]                    lane_accept_dcache_valid;
  logic                [         N_LSU-1:0]                    lane_accept_dcache_fire;
  logic                [         N_LSU-1:0]                    lane_accept_dcache_fallback;
  logic                [         N_LSU-1:0]                    lane_accept_dcache_suppress_stq;
  logic                [         N_LSU-1:0]                    lane_accept_dcache_suppress_mmio;
  logic                [         N_LSU-1:0]                    lane_accept_dcache_suppress_complex;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_accept_dcache_addr;
  decode_pkg::lsu_op_e                                         lane_accept_dcache_op [N_LSU];

  // Raw per-lane request straight from each ld_pipe. lane_ld_req_valid/
  // addr/op above are the arbiter-facing signals after accept-bypass and
  // port-B-retry overrides are applied below.
  logic                [         N_LSU-1:0]                    lane_ld_req_valid_pipe;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_ld_req_addr_pipe;
  decode_pkg::lsu_op_e                                         lane_ld_req_op_pipe  [N_LSU];

  logic                [         N_LSU-1:0]                    lane_ld_rsp_valid;
  logic                [         N_LSU-1:0]                    lane_ld_rsp_ready;
  logic                [         N_LSU-1:0]                    lane_ld_rsp_b_miss;

  // Port-B miss -> port-A retry shim (see the "Port B miss retry" block near
  // the arbiter instantiation). Single-entry: dcache port B has only one
  // outstanding probe at a time, and a new probe is gated off while a retry
  // is pending, so at most one retry is ever in flight.
  logic                                                        pb_retry_valid_q;
  logic                [LANE_SEL_WIDTH-1:0]                    pb_retry_lane_q;
  logic                [     Cfg.PLEN-1:0]                     pb_retry_addr_q;
  decode_pkg::lsu_op_e                                         pb_retry_op_q;
  logic                                                        arb_ld_req_b_valid;
  logic                [     Cfg.PLEN-1:0]                     arb_ld_req_b_addr;
  decode_pkg::lsu_op_e                                         arb_ld_req_b_op;
  logic                [LANE_SEL_WIDTH-1:0]                    arb_ld_req_b_id;
  logic                                                        ld_req_b_ready_gated;
  logic                                                        pb_retry_block_b;
  logic                                                        pb_retry_miss_pulse;
  logic                [LANE_SEL_WIDTH-1:0]                    pb_retry_miss_lane;
  logic                                                        pb_retry_grant_fire;

  logic                [         N_LSU-1:0]                    lane_wb_valid;
  logic                [         N_LSU-1:0][ROB_IDX_WIDTH-1:0] lane_wb_rob_idx;
  logic                [         N_LSU-1:0][     Cfg.XLEN-1:0] lane_wb_data;
  logic                [         N_LSU-1:0]                    lane_wb_exception;
  logic                [         N_LSU-1:0][ECAUSE_WIDTH-1:0] lane_wb_ecause;
  logic                [         N_LSU-1:0]                    lane_wb_is_mispred;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_wb_redirect_pc;
  logic                [         N_LSU-1:0]                    lane_wb_ready;

  logic                [         N_LSU-1:0]                    lane_fast_lsu_valid;
  logic                [         N_LSU-1:0][ROB_IDX_WIDTH-1:0] lane_fast_lsu_rob_idx;
  logic                [         N_LSU-1:0][     Cfg.XLEN-1:0] lane_fast_lsu_data;
  logic                [         N_LSU-1:0]                    lane_fast_lsu_exception;
  logic                [         N_LSU-1:0][ECAUSE_WIDTH-1:0] lane_fast_lsu_ecause;
  logic                [         N_LSU-1:0]                    lane_fast_lsu_is_mispred;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_fast_lsu_redirect_pc;

  // Per-lane MMIO interface signals
  logic                [         N_LSU-1:0]                    lane_mmio_req_valid;
  logic                [         N_LSU-1:0]                    lane_mmio_req_ready;
  logic                [         N_LSU-1:0][     Cfg.PLEN-1:0] lane_mmio_req_addr;
  decode_pkg::lsu_op_e                                         lane_mmio_req_op     [N_LSU];
  logic                [         N_LSU-1:0]                    lane_mmio_rsp_valid;

  logic                [         N_LSU-1:0]                    alloc_grant;
  logic                [LANE_SEL_WIDTH-1:0]                    alloc_lane_idx;
  logic                                                        load_alloc_fire;
  logic                                                        store_req_fire;

  // DCache load request / writeback lane selection now live in lsu_arbiter;
  // the group fans the up-to-LOAD_WB_PORTS granted lanes onto the load
  // writeback ports and drives the dedicated store-writeback port separately.
  logic                [LOAD_WB_PORTS-1:0][LANE_SEL_WIDTH-1:0] wb_lane_idx;
  logic                [LOAD_WB_PORTS-1:0]                     wb_grant_valid;
  logic                [LOAD_WB_PORTS-1:0]                     wb_port_fire;
  logic                [LOAD_WB_PORTS-1:0]                     wb_pop_w;
  logic                                                        store_wb_fire;
  logic                                                        amo_wb_fire;
  logic                [LANE_SEL_WIDTH-1:0]                    amo_wb_lane;

  // ldq alloc port0 = bus0 (single-consumption pipeline, port0/pend);
  // port1 = the dual-admission fast path's second, plain-load-only lane.
  logic                [0:1]                                   ldq_alloc_valid;
  logic                [0:1][ROB_IDX_WIDTH-1:0]                 ldq_alloc_rob_tag;
  logic                [0:1][      Cfg.PLEN-1:0]                ldq_alloc_pc;
  logic                [0:1][      Cfg.PLEN-1:0]                ldq_alloc_paddr;
  logic                [0:1][     SQ_BE_WIDTH-1:0]              ldq_alloc_be;
  logic                                                        ldq_alloc_ready;
  logic                                                        ldq_full;
  logic                                                        ldq_empty;
  logic                                                        ldq_inflight_empty;
  logic                [LOAD_WB_PORTS-1:0]                     ldq_exec_valid;
  logic                [LOAD_WB_PORTS-1:0][ROB_IDX_WIDTH-1:0] ldq_exec_rob_tag;
  logic                                                        ldq_st_query_valid;
  logic                [      Cfg.PLEN-1:0]                   ldq_st_paddr;
  logic                [     SQ_BE_WIDTH-1:0]                 ldq_st_be;
  logic                [ ROB_IDX_WIDTH-1:0]                   ldq_st_rob_tag;
  logic                                                        ldq_violation_valid;
  logic                [      Cfg.PLEN-1:0]                   ldq_violation_pc;
  logic                [ ROB_IDX_WIDTH-1:0]                   lq_violation_rob_idx;

  // Store-queue debug/ordering remnants: the dedicated `sq` structure was
  // removed (forwarding now lives solely in stq). These signals are
  // kept as store_wb-derived debug/diag aliases so existing hierarchical
  // probes (tb/profiler) keep resolving.
  logic                                                        sq_alloc_ready;
  logic                                                        sq_full;
  logic                                                        sq_empty;
  logic                [     SQ_BE_WIDTH-1:0]                 load_fwd_be;
  // Byte-enable mask for the dual-admission fast path's port1 (bus1) load —
  // mirrors load_fwd_be but computed off port1's own uop/AGU output, never
  // pend/sel_uop. Feeds both stq_fwd_be_o2 and ldq_alloc_be[1].
  logic                [     SQ_BE_WIDTH-1:0]                 load_fwd_be_p1;
  logic                [      Cfg.XLEN-1:0]                   req_eff_addr_xlen;
  logic                [      Cfg.PLEN-1:0]                   req_eff_addr;

  // ---------------------------------------------------------------
  // Dispatch port mux ("bus0"): the MMU/pend/store/AMO/LR admission pipeline
  // below is single-consumption, one candidate ("sel_*") at a time. `sel_*`
  // picks the candidate payload — preferring port0, falling back to port1 —
  // the same way the old scalar `uop_i`/etc. were always "live" regardless
  // of grant; it must be driven from cand_valid_i (pre-fu_ready_i) so the
  // combinational req_ready_o logic below never depends on req_valid_i and
  // creates a loop through issue's fu_ready_i. `req_valid_or` is the actual
  // (post-grant) request-present signal used to gate real admission side
  // effects (MMU walk latch, alloc fire, ...); whenever it is asserted the
  // active port is guaranteed to agree with `sel_*`'s pick, because
  // req_ready_o (below) never admits both ports through *this* bus in the
  // same cycle. A second candidate can still be admitted the same cycle
  // through the separate dual-admission fast path ("bus1", see
  // dual_candidate_ok/dual_fire) when it's a plain load needing no walk.
  // ---------------------------------------------------------------
  logic                                                        req_valid_or;
  decode_pkg::uop_t                                            sel_uop;
  logic                [      Cfg.XLEN-1:0]                   sel_rs1_data;
  logic                [      Cfg.XLEN-1:0]                   sel_rs2_data;
  logic                [ ROB_IDX_WIDTH-1:0]                   sel_rob_tag;
  logic                [  ST_IDX_WIDTH-1:0]                   sel_st_id;
  logic                                                        cand_two_valid;

  logic                                                        req_is_load;
  logic                                                        req_is_store;
  logic                                                        req_is_amo;
  logic                                                        store_misaligned;
  logic                                                        store_page_fault;
  logic                                                        store_req_ready;
  logic                                                        load_req_ready;
  logic                                                        req_has_force_fault;
  logic                [ECAUSE_WIDTH-1:0]                    req_force_ecause;
  logic                                                        req_need_mmu_walk;
  logic                                                        amo_inflight;
  logic                                                        amo_order_clear;
  logic                                                        req_ordered_load;
  logic                [      Cfg.XLEN-1:0]                   req_in_eff_addr_xlen;
  logic                [      Cfg.PLEN-1:0]                   req_in_eff_addr;
  logic                                                        agu_is_load;
  logic                                                        agu_is_store;
  logic                                                        agu_misaligned;
  logic                                                        lane_misaligned;
  decode_pkg::uop_t                                            selected_uop;
  decode_pkg::uop_t                                            lane_uop;
  logic                [      Cfg.XLEN-1:0]                   selected_rs2_data;

  // ---------------------------------------------------------------
  // Dual-admission fast path (dcache-load-dual-issue Phase 2, step 2 of 4):
  // 2x AGU decode port0/port1 independently (no pre-mux), enabling a second,
  // fully separate admission this cycle for a *plain* load pair that neither
  // needs a page-table walk (translation_active_w mirrors lsu_mmu's own
  // need_walk test, computed here without touching the single MMU/DTLB
  // instance) nor is misaligned/AMO/LR (those keep going through the single
  // -consumption sel_uop/pend pipeline, admitted at most one per cycle).
  // Port0's own admission still flows through the existing sel_uop/AGU/MMU
  // pipeline below unchanged; port1 gets a parallel "bus1" broadcast that a
  // second, distinct free ld_pipe lane + a second free ldq slot pick up in
  // the same cycle.
  //
  // MMU single-walk mutex (dcache-load-dual-issue task lsu-group-mmu-fwd):
  // u_lsu_mmu/DTLB stay a single instance with one outstanding walk, fed
  // solely by sel_uop (which is always port0's uop when cand_two_valid, since
  // cand_valid_i[0] wins ties in the "Dispatch port mux" below) — port1 never
  // reaches the MMU directly. dual_candidate_ok therefore requires
  // !req_p0_need_walk && !req_p1_need_walk: whenever *either* side would need
  // a walk, the pair is simply never dual-admitted. In that case req_ready_o
  // (below) applies its normal all-or-nothing rule and holds at 0 for the
  // *whole* pair this cycle — not just port1 — because issue's single
  // fu_ready_i clears both RS entries together the instant req_ready_o=1
  // (see the req_ready_o port comment above); admitting port0 alone here
  // would silently drop port1's candidate. Both candidates simply retry next
  // cycle: port0 keeps winning the sel_uop tie-break, so it is what actually
  // enters the walk as soon as the pair's shape allows single-port admission
  // (e.g. once cand_valid_i[1] no longer holds, or dual_candidate_ok's other
  // gates open up) — i.e. "port0 priority, port1 backs off and retries".
  // ---------------------------------------------------------------
  logic                [      Cfg.XLEN-1:0]                   req_p0_eff_addr_xlen;
  logic                [      Cfg.PLEN-1:0]                   req_p0_eff_addr;
  logic                                                        req_p0_is_load;
  logic                                                        req_p0_is_store;
  logic                                                        req_p0_misaligned;
  logic                [      Cfg.XLEN-1:0]                   req_p1_eff_addr_xlen;
  logic                [      Cfg.PLEN-1:0]                   req_p1_eff_addr;
  logic                                                        req_p1_is_load;
  logic                                                        req_p1_is_store;
  logic                                                        req_p1_misaligned;
  logic                                                        translation_active_w;
  logic                                                        req_p0_need_walk;
  logic                                                        req_p1_need_walk;
  logic                                                        req_p0_plain_load;
  logic                                                        req_p1_plain_load;
  logic                                                        dual_pick_pair_w;
  logic                                                        dual_pair_shape_ok;
  logic                                                        dual_pair_wanted;
  logic                                                        dual_pair_active;
  logic                                                        dual_candidate_ok;
  logic                                                        dual_fire;
  logic [63:0]                                                 dbg_dual_pick_pair_q;
  logic [63:0]                                                 dbg_dual_block_shape_q;
  logic [63:0]                                                 dbg_dual_pair_wanted_q;
  logic [63:0]                                                 dbg_dual_candidate_ok_q;
  logic [63:0]                                                 dbg_dual_fire_q;
  logic [63:0]                                                 dbg_dual_block_ldq_q;
  logic [63:0]                                                 dbg_dual_block_p0_lane_q;
  logic [63:0]                                                 dbg_dual_block_p1_lane_q;
  logic [63:0]                                                 dbg_dual_shape_block_pend_q;
  logic [63:0]                                                 dbg_dual_shape_block_mmu_busy_q;
  logic [63:0]                                                 dbg_dual_shape_block_amo_inflight_q;
  logic [63:0]                                                 dbg_dual_shape_block_p0_not_plain_q;
  logic [63:0]                                                 dbg_dual_shape_block_p1_not_plain_q;
  logic [63:0]                                                 dbg_dual_shape_block_p0_walk_q;
  logic [63:0]                                                 dbg_dual_shape_block_p1_walk_q;
  logic                [         N_LSU-1:0]                    alloc_grant_p1;
  logic                [LANE_SEL_WIDTH-1:0]                    alloc_lane_idx_p1;
  logic                                                        load_req_ready_p1;
  decode_pkg::uop_t                                            bus1_uop;
  logic                [      Cfg.XLEN-1:0]                   bus1_rs2_data;
  logic                [      Cfg.PLEN-1:0]                   bus1_eff_addr;
  logic                [ ROB_IDX_WIDTH-1:0]                   bus1_rob_tag;
  logic                [  ST_IDX_WIDTH-1:0]                   bus1_st_id;
  logic                [$clog2(LDQ_DEPTH + 1)-1:0]             ldq_free_count;

  logic                                                        pend_valid_q;
  decode_pkg::uop_t                                            pend_uop_q;
  logic                [      Cfg.XLEN-1:0]                   pend_rs2_data_q;
  logic                [ ROB_IDX_WIDTH-1:0]                   pend_rob_tag_q;
  logic                [  ST_IDX_WIDTH-1:0]                   pend_st_id_q;
  logic                [      Cfg.PLEN-1:0]                   pend_addr_q;
  logic                                                        pend_force_fault_q;
  logic                [ECAUSE_WIDTH-1:0]                    pend_force_ecause_q;

  logic                [             1:0]                     mmu_state_q;
`ifndef SYNTHESIS
  logic                [             31:0]                    lsu_diag_pc_w;
  logic                                                        lsu_diag_stall_watch_w;
  logic                                                        lsu_diag_stall_cond_w;
`endif

  // store_wb_q 已并入 stq：下列 head 别名直接由 stq 的 store 写回口驱动，
  // 保留命名以便 tb_triathlon 的层级探针 (store_wb_head_valid / _rob_idx) 解析。
  logic store_wb_head_valid;
  logic [ROB_IDX_WIDTH-1:0] store_wb_head_rob_idx;

  logic rsp_id_in_range;  // dbg-only: load response id within lane range
  logic [N_LSU-1:0] lane_amo_valid_q;
  decode_pkg::amo_op_e lane_amo_op_q[N_LSU];
  logic [N_LSU-1:0][Cfg.XLEN-1:0] lane_amo_rs2_q;
  logic [N_LSU-1:0][ST_IDX_WIDTH-1:0] lane_amo_st_id_q;
  logic [N_LSU-1:0][Cfg.PLEN-1:0] lane_amo_addr_q;
  logic [Cfg.XLEN-1:0] amo_wb_new_data;

  function automatic logic [SQ_BE_WIDTH-1:0] load_be_mask(input decode_pkg::lsu_op_e op,
                                                           input logic [Cfg.PLEN-1:0] addr);
    logic [SQ_BE_WIDTH-1:0] mask;
    logic [SQ_BYTE_OFF_W-1:0] off;
    begin
      mask = '0;
      off = addr[SQ_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_LB, decode_pkg::LSU_LBU: begin
          mask[off] = 1'b1;
        end
        decode_pkg::LSU_LH, decode_pkg::LSU_LHU: begin
          for (int i = 0; i < 2; i++) begin
            if ((off + i) < SQ_BE_WIDTH) begin
              mask[off+i] = 1'b1;
            end
          end
        end
        decode_pkg::LSU_LW, decode_pkg::LSU_LWU, decode_pkg::LSU_LR, decode_pkg::LSU_AMO: begin
          for (int i = 0; i < 4; i++) begin
            if ((off + i) < SQ_BE_WIDTH) begin
              mask[off+i] = 1'b1;
            end
          end
        end
        decode_pkg::LSU_LD: begin
          for (int i = 0; i < SQ_BE_WIDTH; i++) begin
            mask[i] = 1'b1;
          end
        end
        default: begin
          mask = '0;
        end
      endcase
      load_be_mask = mask;
    end
  endfunction

  // Byte-enable mask of a resolving store, relative to its containing word.
  // Mirrors stq's store_be_mask: used to drive the LDQ violation CAM
  // (overlap = same word address AND intersecting byte mask). SC_FAIL / non
  // store ops return 0 so they never trigger a violation.
  function automatic logic [SQ_BE_WIDTH-1:0] store_be_mask(input decode_pkg::lsu_op_e op,
                                                           input logic [Cfg.PLEN-1:0] addr);
    logic [SQ_BE_WIDTH-1:0] mask;
    logic [SQ_BYTE_OFF_W-1:0] off;
    begin
      mask = '0;
      off  = addr[SQ_BYTE_OFF_W-1:0];
      unique case (op)
        decode_pkg::LSU_SB: mask[off] = 1'b1;
        decode_pkg::LSU_SH: begin
          for (int i = 0; i < 2; i++) begin
            if ((off + i) < SQ_BE_WIDTH) mask[off+i] = 1'b1;
          end
        end
        decode_pkg::LSU_SW, decode_pkg::LSU_SC, decode_pkg::LSU_AMO: begin
          for (int i = 0; i < 4; i++) begin
            if ((off + i) < SQ_BE_WIDTH) mask[off+i] = 1'b1;
          end
        end
        decode_pkg::LSU_SD: begin
          for (int i = 0; i < SQ_BE_WIDTH; i++) mask[i] = 1'b1;
        end
        default: mask = '0;
      endcase
      store_be_mask = mask;
    end
  endfunction

  function automatic logic is_store_misaligned(input decode_pkg::lsu_op_e op,
                                                input logic [Cfg.PLEN-1:0] addr);
    begin
      unique case (op)
        decode_pkg::LSU_SB: is_store_misaligned = 1'b0;
        decode_pkg::LSU_SH: is_store_misaligned = addr[0];
        decode_pkg::LSU_SW, decode_pkg::LSU_SC, decode_pkg::LSU_AMO: is_store_misaligned = |addr[1:0];
        decode_pkg::LSU_SD: is_store_misaligned = |addr[2:0];
        default:            is_store_misaligned = 1'b0;
      endcase
    end
  endfunction

  function automatic logic is_load_misaligned(input decode_pkg::lsu_op_e op,
                                               input logic [Cfg.PLEN-1:0] addr);
    begin
      unique case (op)
        decode_pkg::LSU_LB, decode_pkg::LSU_LBU: is_load_misaligned = 1'b0;
        decode_pkg::LSU_LH, decode_pkg::LSU_LHU: is_load_misaligned = addr[0];
        decode_pkg::LSU_LW, decode_pkg::LSU_LWU, decode_pkg::LSU_LR,
        decode_pkg::LSU_AMO: is_load_misaligned = |addr[1:0];
        decode_pkg::LSU_LD: is_load_misaligned = |addr[2:0];
        default: is_load_misaligned = 1'b0;
      endcase
    end
  endfunction

  function automatic logic [Cfg.XLEN-1:0] amo_result(input decode_pkg::amo_op_e op,
                                                     input logic [Cfg.XLEN-1:0] old_val,
                                                     input logic [Cfg.XLEN-1:0] operand);
    logic signed [31:0] old_s;
    logic signed [31:0] operand_s;
    logic [31:0] old_w;
    logic [31:0] operand_w;
    logic [31:0] res_w;
    begin
      old_w = old_val[31:0];
      operand_w = operand[31:0];
      old_s = old_w;
      operand_s = operand_w;
      unique case (op)
        decode_pkg::AMO_SWAP: res_w = operand_w;
        decode_pkg::AMO_ADD:  res_w = old_w + operand_w;
        decode_pkg::AMO_XOR:  res_w = old_w ^ operand_w;
        decode_pkg::AMO_AND:  res_w = old_w & operand_w;
        decode_pkg::AMO_OR:   res_w = old_w | operand_w;
        decode_pkg::AMO_MIN:  res_w = (old_s < operand_s) ? old_w : operand_w;
        decode_pkg::AMO_MAX:  res_w = (old_s > operand_s) ? old_w : operand_w;
        decode_pkg::AMO_MINU: res_w = (old_w < operand_w) ? old_w : operand_w;
        decode_pkg::AMO_MAXU: res_w = (old_w > operand_w) ? old_w : operand_w;
        default:              res_w = old_w;
      endcase
      if (Cfg.XLEN == 32) begin
        amo_result = res_w;
      end else begin
        amo_result = {{(Cfg.XLEN - 32) {res_w[31]}}, res_w};
      end
    end
  endfunction

  // Port mux: see the "Dispatch port mux" comment on the signal declarations
  // above. cand_valid_i[0] wins ties so a lone port1 candidate (e.g. port0
  // blocked by spec_low_addr while port1 isn't) still flows through.
  always_comb begin
    req_valid_or   = req_valid_i[0] || req_valid_i[1];
    cand_two_valid = cand_valid_i[0] && cand_valid_i[1];
    if (cand_valid_i[0]) begin
      sel_uop      = uop_i[0];
      sel_rs1_data = rs1_data_i[0];
      sel_rs2_data = rs2_data_i[0];
      sel_rob_tag  = rob_tag_i[0];
      sel_st_id    = st_id_i[0];
    end else begin
      sel_uop      = uop_i[1];
      sel_rs1_data = rs1_data_i[1];
      sel_rs2_data = rs2_data_i[1];
      sel_rob_tag  = rob_tag_i[1];
      sel_st_id    = st_id_i[1];
    end
  end

  always_comb begin
    selected_uop = pend_valid_q ? pend_uop_q : sel_uop;
    selected_rs2_data = pend_valid_q ? pend_rs2_data_q : sel_rs2_data;
    lane_uop = selected_uop;
    if (lane_uop.lsu_op == decode_pkg::LSU_AMO) begin
      lane_uop.is_load  = 1'b1;
      lane_uop.is_store = 1'b0;
    end
  end

  // Two independent, unconditional AGU instances (port0/port1): unlike the
  // old single u_agu (fed the post-mux sel_uop/sel_rs1_data), these decode
  // both candidates every cycle regardless of grant, so the dual-admission
  // fast path below never waits on an extra AGU cycle. The single-consumption
  // pipeline (req_in_eff_addr/agu_is_load/agu_is_store/agu_misaligned) is
  // recovered by post-muxing the two outputs the same way sel_uop already
  // does (cand_valid_i[0] wins ties) — behaviourally identical to the old
  // pre-mux-then-AGU arrangement.
  lsu_agu #(
      .Cfg(Cfg)
  ) u_agu_p0 (
      .uop_i(uop_i[0]),
      .rs1_data_i(rs1_data_i[0]),
      .eff_addr_xlen_o(req_p0_eff_addr_xlen),
      .eff_addr_o(req_p0_eff_addr),
      .is_load_o(req_p0_is_load),
      .is_store_o(req_p0_is_store),
      .is_amo_o(),
      .misaligned_o(req_p0_misaligned)
  );

  lsu_agu #(
      .Cfg(Cfg)
  ) u_agu_p1 (
      .uop_i(uop_i[1]),
      .rs1_data_i(rs1_data_i[1]),
      .eff_addr_xlen_o(req_p1_eff_addr_xlen),
      .eff_addr_o(req_p1_eff_addr),
      .is_load_o(req_p1_is_load),
      .is_store_o(req_p1_is_store),
      .is_amo_o(),
      .misaligned_o(req_p1_misaligned)
  );

  assign req_in_eff_addr_xlen = cand_valid_i[0] ? req_p0_eff_addr_xlen : req_p1_eff_addr_xlen;
  assign req_in_eff_addr      = cand_valid_i[0] ? req_p0_eff_addr : req_p1_eff_addr;
  assign agu_is_load           = cand_valid_i[0] ? req_p0_is_load : req_p1_is_load;
  assign agu_is_store          = cand_valid_i[0] ? req_p0_is_store : req_p1_is_store;
  assign agu_misaligned        = cand_valid_i[0] ? req_p0_misaligned : req_p1_misaligned;

  // translation_active_w mirrors lsu_mmu's private `translation_active`
  // (satp.MODE set and not M-mode) purely to let the dual-admission path
  // classify both candidates' need-walk status without a second MMU/DTLB
  // instance. It does not replace or duplicate the actual walk (still solely
  // owned by u_lsu_mmu below).
  assign translation_active_w = mmu_satp_i[31] && (mmu_priv_i != 2'b11);
  assign req_p0_need_walk = translation_active_w && (req_p0_is_load || req_p0_is_store) && !req_p0_misaligned;
  assign req_p1_need_walk = translation_active_w && (req_p1_is_load || req_p1_is_store) && !req_p1_misaligned;
  assign req_p0_plain_load = uop_i[0].is_load && !uop_i[0].is_store &&
                             (uop_i[0].lsu_op != decode_pkg::LSU_AMO) &&
                             (uop_i[0].lsu_op != decode_pkg::LSU_LR);
  assign req_p1_plain_load = uop_i[1].is_load && !uop_i[1].is_store &&
                             (uop_i[1].lsu_op != decode_pkg::LSU_AMO) &&
                             (uop_i[1].lsu_op != decode_pkg::LSU_LR);

  assign bus1_uop      = uop_i[1];
  assign bus1_rs2_data = rs2_data_i[1];
  assign bus1_eff_addr = req_p1_eff_addr;
  assign bus1_rob_tag  = rob_tag_i[1];
  assign bus1_st_id    = st_id_i[1];

`ifndef SYNTHESIS
  assign lsu_diag_pc_w = pend_valid_q ? pend_uop_q.pc : sel_uop.pc;
  assign lsu_diag_stall_watch_w = lsu_diag_watch_pc(lsu_diag_pc_w);
  assign lsu_diag_stall_cond_w = lsu_diag_stall_watch_w && !flush_i &&
                                 ((pend_valid_q && (req_is_load || req_is_store) &&
                                   !load_alloc_fire && !store_req_fire) ||
                                  (req_valid_or && (sel_uop.is_load || sel_uop.is_store) && !req_ready_o));
`endif

  // Unique address-translation entry point: owns the sv32 MMU and the MMU
  // wrapper FSM + pend buffering that used to be inlined here. A walk-needing
  // request is latched and resolved through req -> pend handshake; non-walk
  // requests are reported via need_walk=0 and handled on the dispatch bypass.
  lsu_mmu #(
      .Cfg(Cfg),
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .ST_IDX_WIDTH(ST_IDX_WIDTH),
      .ECAUSE_WIDTH(ECAUSE_WIDTH)
  ) u_lsu_mmu (
      .clk_i,
      .rst_ni,
      .flush_i,

      .req_valid_i(req_valid_or),
      .uop_i(sel_uop),
      .rs1_data_i(sel_rs1_data),
      .rs2_data_i(sel_rs2_data),
      .rob_tag_i(sel_rob_tag),
      .st_id_i(sel_st_id),
      .req_vaddr_i(req_in_eff_addr),
      .req_is_load_i(agu_is_load),
      .req_is_store_i(agu_is_store),
      .req_misaligned_i(agu_misaligned),

      .mmu_satp_i(mmu_satp_i),
      .mmu_priv_i(mmu_priv_i),
      .mmu_sum_i(mmu_sum_i),
      .mmu_mxr_i(mmu_mxr_i),
      .mmu_sfence_vma_i(mmu_sfence_vma_i),

      .pte_req_valid_o(pte_req_valid_o),
      .pte_req_ready_i(pte_req_ready_i),
      .pte_req_paddr_o(pte_req_paddr_o),
      .pte_rsp_valid_i(pte_rsp_valid_i),
      .pte_rsp_data_i(pte_rsp_data_i),
      .pte_upd_valid_o(pte_upd_valid_o),
      .pte_upd_ready_i(pte_upd_ready_i),
      .pte_upd_paddr_o(pte_upd_paddr_o),
      .pte_upd_data_o(pte_upd_data_o),

      .need_walk_o(req_need_mmu_walk),
      .accept_ready_o(),
      .mmu_state_o(mmu_state_q),

      .pend_consume_i(load_alloc_fire || store_req_fire),
      .pend_valid_o(pend_valid_q),
      .pend_uop_o(pend_uop_q),
      .pend_rs2_data_o(pend_rs2_data_q),
      .pend_rob_tag_o(pend_rob_tag_q),
      .pend_st_id_o(pend_st_id_q),
      .pend_addr_o(pend_addr_q),
      .pend_force_fault_o(pend_force_fault_q),
      .pend_force_ecause_o(pend_force_ecause_q)
  );

  generate
    for (genvar gi = 0; gi < N_LSU; gi++) begin : g_ld_pipes
      // Per-lane DCache response data mux: at most one of port A / port B is
      // valid for this lane in a given cycle (arbiter grants distinct lanes
      // to A/B), so select the matching bus by id.
      logic lane_ld_rsp_from_a_w;
      logic [Cfg.XLEN-1:0] lane_ld_rsp_data_w;
      logic lane_ld_rsp_err_w;
      assign lane_ld_rsp_from_a_w = ld_rsp_valid_i && (ld_rsp_id_i == LANE_SEL_WIDTH'(gi));
      assign lane_ld_rsp_data_w = lane_ld_rsp_from_a_w ? ld_rsp_data_i : ld_rsp_b_data_i;
      assign lane_ld_rsp_err_w = lane_ld_rsp_from_a_w ? ld_rsp_err_i : ld_rsp_b_err_i;

      // Dual-admission fast path: this lane is the port1 (bus1) target this
      // cycle iff dual_fire granted it that lane. lane_uop / sel_*-derived
      // signals below remain bus0's broadcast (port0, or pend/single path).
      logic lane_use_bus1;
      assign lane_use_bus1 = dual_fire && (alloc_lane_idx_p1 == LANE_SEL_WIDTH'(gi));

      // Per-lane STQ forward-query response mux: a lane driven by bus1 this
      // cycle must see bus1's own query result (stq_fwd_hit_i2/data_i2), never
      // bus0's — otherwise it would apply the wrong load's forwarding hit/data
      // (see the top-level "MMU 单 walk 互斥/stq 双查询口" port comments).
      logic lane_stq_fwd_hit_w;
      logic [Cfg.XLEN-1:0] lane_stq_fwd_data_w;
      assign lane_stq_fwd_hit_w  = lane_use_bus1 ? stq_fwd_hit_i2 : stq_fwd_hit_i;
      assign lane_stq_fwd_data_w = lane_use_bus1 ? stq_fwd_data_i2 : stq_fwd_data_i;

      ld_pipe #(
          .Cfg(Cfg),
          .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
          .SB_DEPTH(SB_DEPTH),
          .ST_IDX_WIDTH(ST_IDX_WIDTH),
          .ECAUSE_WIDTH(ECAUSE_WIDTH)
      ) u_ld_pipe (
          .clk_i,
          .rst_ni,
          .flush_i,

          .req_valid_i(lane_req_valid[gi]),
          .req_ready_o(lane_req_ready[gi]),
          .uop_i(lane_use_bus1 ? bus1_uop : lane_uop),
          .rs2_data_i(lane_use_bus1 ? bus1_rs2_data : (pend_valid_q ? pend_rs2_data_q : sel_rs2_data)),
          .eff_addr_i(lane_use_bus1 ? bus1_eff_addr : req_eff_addr),
          .misaligned_i(lane_use_bus1 ? req_p1_misaligned : lane_misaligned),
          .force_exception_i(lane_use_bus1 ? 1'b0 : req_has_force_fault),
          .force_ecause_i(lane_use_bus1 ? '0 : req_force_ecause),
          .rob_tag_i(lane_use_bus1 ? bus1_rob_tag : (pend_valid_q ? pend_rob_tag_q : sel_rob_tag)),
          .st_id_i(lane_use_bus1 ? bus1_st_id : (pend_valid_q ? pend_st_id_q : sel_st_id)),

          .st_ex_valid_o(lane_st_ex_valid[gi]),
          .st_ex_st_id_o(lane_st_ex_st_id[gi]),
          .st_ex_addr_o(lane_st_ex_addr[gi]),
          .st_ex_data_o(lane_st_ex_data[gi]),
          .st_ex_op_o(lane_st_ex_op[gi]),
          .st_ex_rob_idx_o(lane_st_ex_rob_idx[gi]),

          .stq_fwd_addr_o(lane_stq_fwd_addr[gi]),
          .stq_fwd_rob_idx_o(lane_stq_fwd_rob_idx[gi]),
          .stq_fwd_hit_i(lane_stq_fwd_hit_w),
          .stq_fwd_data_i(lane_stq_fwd_data_w),

          .ld_req_valid_o(lane_ld_req_valid_pipe[gi]),
          .ld_req_ready_i(lane_ld_req_ready[gi]),
          .accept_dcache_fire_i(lane_accept_dcache_fire[gi]),
          .ld_req_addr_o(lane_ld_req_addr_pipe[gi]),
          .ld_req_op_o(lane_ld_req_op_pipe[gi]),

          .ld_rsp_valid_i(lane_ld_rsp_valid[gi]),
          .ld_rsp_ready_o(lane_ld_rsp_ready[gi]),
          .ld_rsp_data_i(lane_ld_rsp_data_w),
          .ld_rsp_err_i(lane_ld_rsp_err_w),

          // MMIO bypass
          .rob_head_i(rob_head_i),
          .mmio_req_valid_o(lane_mmio_req_valid[gi]),
          .mmio_req_ready_i(lane_mmio_req_ready[gi]),
          .mmio_req_addr_o(lane_mmio_req_addr[gi]),
          .mmio_req_op_o(lane_mmio_req_op[gi]),
          .mmio_rsp_valid_i(lane_mmio_rsp_valid[gi]),
          .mmio_rsp_data_i(mmio_rsp_data_i),

          .wb_valid_o(lane_wb_valid[gi]),
          .wb_rob_idx_o(lane_wb_rob_idx[gi]),
          .wb_data_o(lane_wb_data[gi]),
          .wb_exception_o(lane_wb_exception[gi]),
          .wb_ecause_o(lane_wb_ecause[gi]),
          .wb_is_mispred_o(lane_wb_is_mispred[gi]),
          .wb_redirect_pc_o(lane_wb_redirect_pc[gi]),
          .wb_ready_i(lane_wb_ready[gi]),

          .fast_lsu_valid_o(lane_fast_lsu_valid[gi]),
          .fast_lsu_rob_idx_o(lane_fast_lsu_rob_idx[gi]),
          .fast_lsu_data_o(lane_fast_lsu_data[gi]),
          .fast_lsu_exception_o(lane_fast_lsu_exception[gi]),
          .fast_lsu_ecause_o(lane_fast_lsu_ecause[gi]),
          .fast_lsu_is_mispred_o(lane_fast_lsu_is_mispred[gi]),
          .fast_lsu_redirect_pc_o(lane_fast_lsu_redirect_pc[gi])
      );

      assign dbg_lane_busy[gi] = lane_ld_req_valid_pipe[gi] |
                                 (pb_retry_valid_q && (pb_retry_lane_q == LANE_SEL_WIDTH'(gi))) |
                                 lane_ld_rsp_ready[gi] | lane_wb_valid[gi] |
                                 lane_mmio_req_valid[gi];
    end
  endgenerate

  // Arbiter-facing DCache load request = registered per-lane requests, OR'd
  // with accept-cycle clean-load bypasses and the single in-flight port-B-miss
  // retry. The live bypass is intentionally not counted in dbg_lane_busy above,
  // so it cannot feed back into LSU admission/AMO ordering ready logic.
  always_comb begin
    lane_ld_req_valid = lane_ld_req_valid_pipe | lane_accept_dcache_valid;
    lane_ld_req_addr  = lane_ld_req_addr_pipe;
    lane_ld_req_op    = lane_ld_req_op_pipe;
    for (int i = 0; i < N_LSU; i++) begin
      if (lane_accept_dcache_valid[i]) begin
        lane_ld_req_addr[i] = lane_accept_dcache_addr[i];
        lane_ld_req_op[i]   = lane_accept_dcache_op[i];
      end
    end
    if (pb_retry_valid_q) begin
      lane_ld_req_valid[pb_retry_lane_q] = 1'b1;
      lane_ld_req_addr[pb_retry_lane_q]  = pb_retry_addr_q;
      lane_ld_req_op[pb_retry_lane_q]    = pb_retry_op_q;
    end
  end

  assign lane_accept_dcache_fire = lane_accept_dcache_valid & lane_ld_req_ready;
  assign lane_accept_dcache_fallback = lane_accept_dcache_valid & ~lane_ld_req_ready;

  // ---------------------------------------------------------
  // Shared-resource arbitration (DCache req RR / MMIO / WB lane RR)
  // ---------------------------------------------------------
  lsu_arbiter #(
      .Cfg(Cfg),
      .N_LSU(N_LSU),
      .N_WB(LOAD_WB_PORTS)
  ) u_arbiter (
      .clk_i,
      .rst_ni,
      .flush_i,

      .lane_ld_req_valid_i(lane_ld_req_valid),
      .lane_ld_req_addr_i(lane_ld_req_addr),
      .lane_ld_req_op_i(lane_ld_req_op),
      .lane_ld_req_ready_o(lane_ld_req_ready),
      .ld_req_valid_o(ld_req_valid_o),
      .ld_req_ready_i(ld_req_ready_i),
      .ld_req_addr_o(ld_req_addr_o),
      .ld_req_op_o(ld_req_op_o),
      .ld_req_id_o(ld_req_id_o),

      .ld_req_b_valid_o(arb_ld_req_b_valid),
      .ld_req_b_ready_i(ld_req_b_ready_gated),
      .ld_req_b_addr_o(arb_ld_req_b_addr),
      .ld_req_b_op_o(arb_ld_req_b_op),
      .ld_req_b_id_o(arb_ld_req_b_id),

      .ld_rsp_valid_i(ld_rsp_valid_i),
      .ld_rsp_id_i(ld_rsp_id_i),
      .ld_rsp_ready_o(ld_rsp_ready_o),
      .ld_rsp_b_valid_i(ld_rsp_b_valid_i),
      .ld_rsp_b_id_i(ld_rsp_b_id_i),
      .ld_rsp_b_ready_o(ld_rsp_b_ready_o),
      .ld_rsp_b_miss_i(ld_rsp_b_miss_i),
      .ld_rsp_b_miss_id_i(ld_rsp_b_miss_id_i),
      .lane_ld_rsp_b_miss_o(lane_ld_rsp_b_miss),
      .lane_ld_rsp_ready_i(lane_ld_rsp_ready),
      .lane_ld_rsp_valid_o(lane_ld_rsp_valid),

      .lane_mmio_req_valid_i(lane_mmio_req_valid),
      .lane_mmio_req_addr_i(lane_mmio_req_addr),
      .lane_mmio_req_op_i(lane_mmio_req_op),
      .lane_mmio_req_ready_o(lane_mmio_req_ready),
      .lane_mmio_rsp_valid_o(lane_mmio_rsp_valid),
      .mmio_req_valid_o(mmio_req_valid_o),
      .mmio_req_ready_i(mmio_req_ready_i),
      .mmio_req_addr_o(mmio_req_addr_o),
      .mmio_req_op_o(mmio_req_op_o),
      .mmio_rsp_valid_i(mmio_rsp_valid_i),

      .lane_wb_valid_i(lane_wb_valid),
      .wb_pop_i(wb_pop_w),
      .wb_grant_valid_o(wb_grant_valid),
      .wb_lane_idx_o(wb_lane_idx)
  );

  // ---------------------------------------------------------
  // Port-B miss retry: dcache's hit-only bypass may accept a probe and then
  // report a miss instead of data (ld_rsp_b_miss_*). At that point the
  // owning lane's ld_pipe has already advanced past S_LD_REQ (it saw
  // ld_req_ready fire when port B accepted the probe) and is blocked in
  // S_LD_RSP waiting for a ld_rsp_valid_i that will never come from port B.
  // Recover transparently: latch the lane + its still-stable address/op
  // (ld_pipe keeps driving them combinationally regardless of state) and
  // force that lane's request valid again next cycle, single-entry, until
  // it wins a *port-A* grant (guaranteed to eventually complete). New port-B
  // probes are gated off while a retry is outstanding so the one register
  // is never overrun.
  // ---------------------------------------------------------
  always_comb begin
    pb_retry_miss_pulse = |lane_ld_rsp_b_miss;
    pb_retry_miss_lane  = '0;
    for (int i = 0; i < N_LSU; i++) begin
      if (lane_ld_rsp_b_miss[i]) begin
        pb_retry_miss_lane = LANE_SEL_WIDTH'(i);
      end
    end
  end

  assign pb_retry_block_b = pb_retry_valid_q || pb_retry_miss_pulse;
  assign ld_req_b_ready_gated = ld_req_b_ready_i && !pb_retry_block_b;
  assign ld_req_b_valid_o = arb_ld_req_b_valid && !pb_retry_block_b;
  assign ld_req_b_addr_o  = arb_ld_req_b_addr;
  assign ld_req_b_op_o    = arb_ld_req_b_op;
  assign ld_req_b_id_o    = arb_ld_req_b_id;

  // Retry request is forced valid only for pb_retry_lane_q, and port B is
  // gated off whenever a retry is pending, so a ready grant for that lane can
  // only have come from port A.
  assign pb_retry_grant_fire = pb_retry_valid_q && lane_ld_req_ready[pb_retry_lane_q];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pb_retry_valid_q <= 1'b0;
      pb_retry_lane_q  <= '0;
      pb_retry_addr_q  <= '0;
      pb_retry_op_q    <= decode_pkg::LSU_LW;
    end else if (flush_i) begin
      pb_retry_valid_q <= 1'b0;
    end else begin
      if (pb_retry_grant_fire) begin
        pb_retry_valid_q <= 1'b0;
      end
      // Mutually exclusive with the grant-fire clear above: a new miss can
      // only be latched while ld_req_b_ready_gated allowed a fresh probe,
      // i.e. while pb_retry_valid_q was already 0 this cycle.
      if (pb_retry_miss_pulse) begin
        pb_retry_valid_q <= 1'b1;
        pb_retry_lane_q  <= pb_retry_miss_lane;
        pb_retry_addr_q  <= lane_ld_req_addr_pipe[pb_retry_miss_lane];
        pb_retry_op_q    <= lane_ld_req_op_pipe[pb_retry_miss_lane];
      end
    end
  end

  assign state_q    = g_ld_pipes[0].u_ld_pipe.state_q;
  assign req_tag_q  = g_ld_pipes[0].u_ld_pipe.req_tag_q;
  assign req_addr_q = g_ld_pipes[0].u_ld_pipe.req_addr_q;
  assign req_eff_addr_xlen = pend_valid_q ? {{(Cfg.XLEN-Cfg.PLEN){1'b0}}, pend_addr_q} : req_in_eff_addr_xlen;
  assign req_eff_addr = pend_valid_q ? pend_addr_q : req_in_eff_addr;
  // Alignment for the address actually handed to the lane (selected/pend path).
  // Equivalent to the lane's former internal is_misaligned(lane_uop, eff_addr).
  assign lane_misaligned = is_store_misaligned(lane_uop.lsu_op, req_eff_addr) |
                           is_load_misaligned(lane_uop.lsu_op, req_eff_addr);
  assign req_is_amo = selected_uop.lsu_op == decode_pkg::LSU_AMO;
  assign req_is_load = pend_valid_q ? selected_uop.is_load :
                       (!req_need_mmu_walk && req_valid_or && sel_uop.is_load);
  assign req_is_store = (pend_valid_q ? selected_uop.is_store :
                        (!req_need_mmu_walk && req_valid_or && sel_uop.is_store)) &&
                        !req_is_amo;
  assign req_has_force_fault = pend_valid_q ? pend_force_fault_q : 1'b0;
  assign req_force_ecause = pend_valid_q ? pend_force_ecause_q : '0;
  assign store_misaligned = pend_valid_q ? (req_is_store && req_has_force_fault &&
                                            (req_force_ecause == EXC_ST_ADDR_MISALIGNED)) :
                            (req_is_store && is_store_misaligned(sel_uop.lsu_op, req_eff_addr));
  assign store_page_fault = pend_valid_q ? (req_is_store && req_has_force_fault &&
                                            (req_force_ecause == EXC_ST_PAGE_FAULT)) : 1'b0;
  assign amo_inflight = |lane_amo_valid_q;
  // stq 的「未上报 store 计数」==0 蕴含所有已准入 store 已上报 ROB。
  // LDQ 现持有 load 到提交，AMO 排序只需所有更老 load 已执行 (读完内存)，
  // 故用 inflight_empty（无未写回 load）而非 empty（无任何在飞 load）。
  assign amo_order_clear = (dbg_lane_busy == '0) && ldq_inflight_empty &&
                           (st_unreported_count_i == '0) && st_order_query_clear_i;
  // store 写回 head 别名：直接由 stq 的 store 写回口驱动。
  assign store_wb_head_valid = st_wb_valid_i;
  assign store_wb_head_rob_idx = st_wb_rob_idx_i;
  // 转发的字节掩码：交给 stq 做 byte-merge，命中即返回对齐到字节 0 的数据。
  // 仅在本周期有 load 准入时驱动 (否则 be=0，stq 自然不命中)。
  assign load_fwd_be = load_be_mask(pend_valid_q ? pend_uop_q.lsu_op : sel_uop.lsu_op, req_eff_addr);
  assign load_fwd_be_p1 = load_be_mask(uop_i[1].lsu_op, req_p1_eff_addr);
  assign st_order_query_valid_o = req_is_amo;
  assign st_order_query_st_id_o = pend_valid_q ? pend_st_id_q : sel_st_id;

  assign ldq_alloc_valid[0]    = load_alloc_fire && req_is_load;
  assign ldq_alloc_rob_tag[0]  = pend_valid_q ? pend_rob_tag_q : sel_rob_tag;
  assign ldq_alloc_pc[0]       = pend_valid_q ? pend_uop_q.pc : sel_uop.pc;
  assign ldq_alloc_paddr[0]    = req_eff_addr;
  assign ldq_alloc_be[0]       = load_fwd_be;

  // Dual-admission fast path only ever admits a plain load (see
  // dual_candidate_ok / req_p1_plain_load), so port1's alloc payload is
  // always sourced straight from port1's own uop/AGU output, never pend.
  assign ldq_alloc_valid[1]    = dual_fire;
  assign ldq_alloc_rob_tag[1]  = rob_tag_i[1];
  assign ldq_alloc_pc[1]       = uop_i[1].pc;
  assign ldq_alloc_paddr[1]    = req_p1_eff_addr;
  assign ldq_alloc_be[1]       = load_fwd_be_p1;

  // B2: load writeback marks the matching LDQ entry executed (no longer pops).
  // The entry is freed later, when the ROB commits the load (commit_*_i).
  // One exec port per granted load-writeback port; the LDQ observes all of them
  // so the disambiguation CAM never misses a same-cycle retiring load.
  always_comb begin
    for (int p = 0; p < LOAD_WB_PORTS; p++) begin
      ldq_exec_valid[p]   = wb_port_fire[p];
      ldq_exec_rob_tag[p] = lane_wb_rob_idx[wb_lane_idx[p]];
    end
  end

  // B3: drive the LDQ store->load violation CAM the cycle a store resolves its
  // physical address (store_req_fire). Only stores that actually write memory
  // can alias a younger load: skip faulting stores and a failed SC (which
  // commits a dummy store writing no bytes). AMO is serialized on the single
  // lane (amo_inflight blocks younger loads from executing concurrently), so
  // its store side needs no CAM here.
  assign ldq_st_query_valid = store_req_fire && req_is_store &&
                             !store_misaligned && !store_page_fault &&
                             !(is_sc && sc_fail);
  assign ldq_st_paddr       = req_eff_addr;
  assign ldq_st_be          = store_be_mask(selected_uop.lsu_op, req_eff_addr);
  assign ldq_st_rob_tag     = pend_valid_q ? pend_rob_tag_q : sel_rob_tag;

  logic res_valid_q;
  logic [Cfg.PLEN-1:0] res_addr_q;
  logic is_sc;
  logic sc_success;
  logic sc_fail;
  assign is_sc = selected_uop.lsu_op == decode_pkg::LSU_SC;
  assign sc_success = is_sc && res_valid_q && (res_addr_q == req_eff_addr);
  assign sc_fail = is_sc && !sc_success;

  logic req_is_lr;
  assign req_is_lr = selected_uop.lsu_op == decode_pkg::LSU_LR;
  assign req_ordered_load = req_is_lr || req_is_amo;

  always_comb begin
    load_req_ready = 1'b0;
    alloc_grant = '0;
    alloc_lane_idx = '0;
    for (int i = 0; i < N_LSU; i++) begin
      if (!load_req_ready && lane_req_ready[i] && ldq_alloc_ready) begin
        if ((!req_ordered_load || amo_order_clear) && (!req_is_amo || !amo_inflight)) begin
          load_req_ready = 1'b1;
          alloc_grant[i] = 1'b1;
          alloc_lane_idx = LANE_SEL_WIDTH'(i);
        end
      end
    end
  end

  // Dual-admission fast path, port1 grant: only evaluated once bus0/port0's
  // own grant (above) has already picked alloc_lane_idx, and only usable
  // when both candidates are eligible (dual_candidate_ok). Picks a second,
  // distinct free ld_pipe lane so port0 and port1 fire into different lanes
  // in the same cycle; ldq's second alloc port (free_count_o >= 2, checked
  // in dual_candidate_ok) is what makes that safe on the ldq side.
  assign dual_pick_pair_w = pick_valid_i[0] && pick_valid_i[1];
  assign dual_pair_shape_ok = !pend_valid_q && (mmu_state_q == MMU_ST_IDLE) &&
                              !amo_inflight && req_p0_plain_load && req_p1_plain_load &&
                              !req_p0_need_walk && !req_p1_need_walk;
  // Both RS picks want dual issue this cycle (shape/mmu/amo gates only).
  assign dual_pair_wanted = pick_valid_i[0] && pick_valid_i[1] && dual_pair_shape_ok;
  // Only treat the pair as "active" when two distinct ld_pipe lanes are actually
  // available — otherwise req_ready_o would hold at 0 and block port0 alone, which
  // deadlocks when other lanes are stuck in S_MMIO_WAIT_ROB (CoreMark hang).
  assign dual_candidate_ok = dual_pair_wanted && (ldq_free_count >= 2);
  always_comb begin
    load_req_ready_p1 = 1'b0;
    alloc_grant_p1 = '0;
    alloc_lane_idx_p1 = '0;
    if (dual_candidate_ok && load_req_ready) begin
      for (int i = 0; i < N_LSU; i++) begin
        if (!load_req_ready_p1 && lane_req_ready[i] && (LANE_SEL_WIDTH'(i) != alloc_lane_idx)) begin
          load_req_ready_p1 = 1'b1;
          alloc_grant_p1[i] = 1'b1;
          alloc_lane_idx_p1 = LANE_SEL_WIDTH'(i);
        end
      end
    end
  end
  assign dual_fire = load_req_ready && load_req_ready_p1;
  assign dual_pair_active = dual_fire && dual_pair_wanted;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dbg_dual_pick_pair_q <= '0;
      dbg_dual_block_shape_q <= '0;
      dbg_dual_pair_wanted_q <= '0;
      dbg_dual_candidate_ok_q <= '0;
      dbg_dual_fire_q <= '0;
      dbg_dual_block_ldq_q <= '0;
      dbg_dual_block_p0_lane_q <= '0;
      dbg_dual_block_p1_lane_q <= '0;
      dbg_dual_shape_block_pend_q <= '0;
      dbg_dual_shape_block_mmu_busy_q <= '0;
      dbg_dual_shape_block_amo_inflight_q <= '0;
      dbg_dual_shape_block_p0_not_plain_q <= '0;
      dbg_dual_shape_block_p1_not_plain_q <= '0;
      dbg_dual_shape_block_p0_walk_q <= '0;
      dbg_dual_shape_block_p1_walk_q <= '0;
    end else begin
      if (dual_pick_pair_w) dbg_dual_pick_pair_q <= dbg_dual_pick_pair_q + 64'd1;
      if (dual_pick_pair_w && !dual_pair_shape_ok) begin
        dbg_dual_block_shape_q <= dbg_dual_block_shape_q + 64'd1;
        if (pend_valid_q) begin
          dbg_dual_shape_block_pend_q <= dbg_dual_shape_block_pend_q + 64'd1;
        end
        if (mmu_state_q != MMU_ST_IDLE) begin
          dbg_dual_shape_block_mmu_busy_q <= dbg_dual_shape_block_mmu_busy_q + 64'd1;
        end
        if (amo_inflight) begin
          dbg_dual_shape_block_amo_inflight_q <= dbg_dual_shape_block_amo_inflight_q + 64'd1;
        end
        if (!req_p0_plain_load) begin
          dbg_dual_shape_block_p0_not_plain_q <= dbg_dual_shape_block_p0_not_plain_q + 64'd1;
        end
        if (!req_p1_plain_load) begin
          dbg_dual_shape_block_p1_not_plain_q <= dbg_dual_shape_block_p1_not_plain_q + 64'd1;
        end
        if (req_p0_need_walk) begin
          dbg_dual_shape_block_p0_walk_q <= dbg_dual_shape_block_p0_walk_q + 64'd1;
        end
        if (req_p1_need_walk) begin
          dbg_dual_shape_block_p1_walk_q <= dbg_dual_shape_block_p1_walk_q + 64'd1;
        end
      end
      if (dual_pair_wanted) dbg_dual_pair_wanted_q <= dbg_dual_pair_wanted_q + 64'd1;
      if (dual_candidate_ok) dbg_dual_candidate_ok_q <= dbg_dual_candidate_ok_q + 64'd1;
      if (dual_fire) dbg_dual_fire_q <= dbg_dual_fire_q + 64'd1;
      if (dual_pair_wanted && (ldq_free_count < 2)) begin
        dbg_dual_block_ldq_q <= dbg_dual_block_ldq_q + 64'd1;
      end
      if (dual_candidate_ok && !load_req_ready) begin
        dbg_dual_block_p0_lane_q <= dbg_dual_block_p0_lane_q + 64'd1;
      end
      if (dual_candidate_ok && load_req_ready && !load_req_ready_p1) begin
        dbg_dual_block_p1_lane_q <= dbg_dual_block_p1_lane_q + 64'd1;
      end
    end
  end
  // Port1 co-issue only when dual_fire is real; otherwise serialize through port0.
  assign dual_port1_en_o = !pick_valid_i[0] || !pick_valid_i[1] || dual_fire;

  // Keep store admission independent from selected-uop decode details to avoid
  // combinational feedback with issue selection. Admission now gated solely by
  // stq 的未上报 store 计数（专用上报口每拍排空 1 个，恒可推进）。
  assign store_req_ready = (st_unreported_count_i < ($clog2(SB_DEPTH+1))'(SB_DEPTH)) ||
                           (st_wb_valid_i && wb_ready_i[STORE_WB_PORT]);
  // Debug/diag aliases for the removed `sq` (stq store-wb derived).
  assign sq_alloc_ready = store_req_ready;
  assign sq_full = !store_req_ready;
  assign sq_empty = (st_unreported_count_i == '0);
  // req_ready_o: single "can admit every cand_valid_i-flagged candidate this
  // cycle" line (see the port-declaration comment). single_port_ready first
  // computes exactly the single-request admission test against the
  // *candidate* view (sel_uop, driven off cand_valid_i, never req_valid_i —
  // this is what breaks the fu_ready_i <-> req_ready_o combinational loop);
  // with cand_two_valid, sel_uop is always port0's uop (cand_valid_i[0] wins
  // ties), so single_port_ready here doubles as "can port0 admit". When both
  // candidates are present, req_ready_o additionally requires dual_fire —
  // i.e. port1 also found a free lane this cycle (dual_candidate_ok gate +
  // alloc_grant_p1 above). If dual_fire doesn't fire (e.g. one candidate
  // needs a walk, is a store/AMO/LR, or lanes/ldq slots are short), neither
  // candidate is claimed ready — the RS holds both and retries the whole
  // pair next cycle. This can never drop a candidate, only defer it.
  always_comb begin
    logic single_port_ready;
    single_port_ready = 1'b0;
    if (pend_valid_q || (mmu_state_q != MMU_ST_IDLE) || amo_inflight) begin
      single_port_ready = 1'b0;
    end else if (req_need_mmu_walk) begin
      single_port_ready = (sel_uop.lsu_op != decode_pkg::LSU_AMO) || amo_order_clear;
    end else if (sel_uop.is_load) begin
      single_port_ready = load_req_ready;
    end else if (sel_uop.is_store) begin
      single_port_ready = store_req_ready;
    end
    req_ready_o = single_port_ready && (!dual_pair_active || dual_fire);
  end

  assign load_alloc_fire = ((pend_valid_q) || (!req_need_mmu_walk && req_valid_or && (mmu_state_q == MMU_ST_IDLE))) &&
                           req_is_load && load_req_ready;
  assign store_req_fire = ((pend_valid_q) || (!req_need_mmu_walk && req_valid_or && (mmu_state_q == MMU_ST_IDLE))) &&
                          req_is_store && store_req_ready;
  assign dbg_alloc_fire = load_alloc_fire | store_req_fire;

  always_comb begin
    lane_req_valid = '0;
    for (int i = 0; i < N_LSU; i++) begin
      lane_req_valid[i] = (load_alloc_fire && alloc_grant[i]) || (dual_fire && alloc_grant_p1[i]);
    end
  end

  always_comb begin
    lane_accept_dcache_load             = lane_req_valid;
    lane_accept_dcache_candidate        = '0;
    lane_accept_dcache_valid            = '0;
    lane_accept_dcache_suppress_stq     = '0;
    lane_accept_dcache_suppress_mmio    = '0;
    lane_accept_dcache_suppress_complex = lane_req_valid;
    lane_accept_dcache_addr             = '0;
    for (int i = 0; i < N_LSU; i++) begin
      logic bus_candidate;
      logic bus_stq_hit;
      logic bus_mmio;
      logic [Cfg.PLEN-1:0] bus_addr;
      decode_pkg::lsu_op_e bus_op;

      bus_candidate = 1'b0;
      bus_stq_hit   = 1'b0;
      bus_mmio      = 1'b0;
      bus_addr      = '0;
      bus_op        = decode_pkg::LSU_LW;

      if (load_alloc_fire && alloc_grant[i]) begin
        bus_addr      = req_eff_addr;
        bus_op        = selected_uop.lsu_op;
        bus_candidate = !req_ordered_load && !lane_misaligned && !req_has_force_fault;
        bus_stq_hit   = stq_fwd_hit_i;
        bus_mmio      = config_pkg::is_mmio_addr({{(32-Cfg.PLEN){1'b0}}, req_eff_addr});
      end
      if (dual_fire && alloc_grant_p1[i]) begin
        bus_addr      = req_p1_eff_addr;
        bus_op        = uop_i[1].lsu_op;
        bus_candidate = !req_p1_misaligned;
        bus_stq_hit   = stq_fwd_hit_i2;
        bus_mmio      = config_pkg::is_mmio_addr({{(32-Cfg.PLEN){1'b0}}, req_p1_eff_addr});
      end

      lane_accept_dcache_candidate[i]        = lane_req_valid[i] && bus_candidate;
      lane_accept_dcache_suppress_complex[i] = lane_req_valid[i] && !bus_candidate;
      lane_accept_dcache_suppress_stq[i]     = lane_req_valid[i] && bus_candidate && bus_stq_hit;
      lane_accept_dcache_suppress_mmio[i]    = lane_req_valid[i] && bus_candidate && !bus_stq_hit && bus_mmio;
      lane_accept_dcache_valid[i]            = lane_req_valid[i] && bus_candidate && !bus_stq_hit && !bus_mmio;
      lane_accept_dcache_addr[i]             = bus_addr;
      lane_accept_dcache_op[i]               = bus_op;
    end
  end

  always_comb begin
    st_ex_valid_o = store_req_fire && !store_misaligned && !store_page_fault;
    st_ex_st_id_o = pend_valid_q ? pend_st_id_q : sel_st_id;
    st_ex_addr_o = req_eff_addr;
    st_ex_data_o = selected_rs2_data;
    st_ex_op_o = sc_fail ? decode_pkg::LSU_SC_FAIL :
                 is_sc ? decode_pkg::LSU_SW : 
                 selected_uop.lsu_op;
    st_ex_rob_idx_o = pend_valid_q ? pend_rob_tag_q : sel_rob_tag;
    if (amo_wb_fire && !lane_wb_exception[amo_wb_lane]) begin
      st_ex_valid_o = 1'b1;
      st_ex_st_id_o = lane_amo_st_id_q[amo_wb_lane];
      st_ex_addr_o = lane_amo_addr_q[amo_wb_lane];
      st_ex_data_o = amo_wb_new_data;
      st_ex_op_o = decode_pkg::LSU_SW;
      st_ex_rob_idx_o = lane_wb_rob_idx[amo_wb_lane];
    end
    for (int i = 0; i < N_LSU; i++) begin
      if (lane_st_ex_valid[i] && !st_ex_valid_o) begin
        st_ex_valid_o = 1'b1;
        st_ex_st_id_o = lane_st_ex_st_id[i];
        st_ex_addr_o = lane_st_ex_addr[i];
        st_ex_data_o = lane_st_ex_data[i];
        st_ex_op_o = lane_st_ex_op[i];
        st_ex_rob_idx_o = lane_st_ex_rob_idx[i];
      end
    end
  end

  // STQ forward-query outputs, split into 2 fully independent buses
  // (dcache-load-dual-issue Phase 2, task lsu-group-mmu-fwd): bus0 always
  // carries the single-consumption sel_uop/pend pipeline's load (indexed by
  // alloc_lane_idx, valid iff load_alloc_fire); bus1 carries the
  // dual-admission fast path's second, plain load (indexed by
  // alloc_lane_idx_p1, valid iff dual_fire). Indexing directly by these
  // lane-select registers (rather than scanning lane_req_valid) keeps the two
  // buses from colliding when both fire the same cycle — with a single shared
  // wire and a scan-and-overwrite loop, whichever lane had the higher index
  // would silently clobber the other's query.
  always_comb begin
    stq_fwd_addr_o    = '0;
    stq_fwd_be_o      = '0;
    stq_fwd_rob_idx_o = '0;
    if (load_alloc_fire) begin
      stq_fwd_addr_o    = lane_stq_fwd_addr[alloc_lane_idx];
      stq_fwd_be_o      = load_fwd_be;
      stq_fwd_rob_idx_o = lane_stq_fwd_rob_idx[alloc_lane_idx];
    end

    stq_fwd_addr_o2    = '0;
    stq_fwd_be_o2      = '0;
    stq_fwd_rob_idx_o2 = '0;
    if (dual_fire) begin
      stq_fwd_addr_o2    = lane_stq_fwd_addr[alloc_lane_idx_p1];
      stq_fwd_be_o2      = load_fwd_be_p1;
      stq_fwd_rob_idx_o2 = lane_stq_fwd_rob_idx[alloc_lane_idx_p1];
    end
  end

  // DCache load request RR, load response routing and writeback lane RR are
  // owned by u_arbiter above; the group fans the up-to-LOAD_WB_PORTS granted
  // lanes onto the load writeback ports and drives the store-writeback port
  // independently. Each port is 1:1 with a CDB port (wb_ready_i is held high),
  // so a granted lane and a queued store can complete in the same cycle.
  always_comb begin
    lane_wb_ready = '0;

    // Load writeback ports [0 .. LOAD_WB_PORTS-1]: arbiter-granted lanes.
    for (int p = 0; p < LOAD_WB_PORTS; p++) begin
      wb_valid_o[p]       = wb_grant_valid[p];
      wb_rob_idx_o[p]     = lane_wb_rob_idx[wb_lane_idx[p]];
      wb_data_o[p]        = lane_wb_data[wb_lane_idx[p]];
      wb_exception_o[p]   = lane_wb_exception[wb_lane_idx[p]];
      wb_ecause_o[p]      = lane_wb_ecause[wb_lane_idx[p]];
      wb_is_mispred_o[p]  = lane_wb_is_mispred[wb_lane_idx[p]];
      wb_redirect_pc_o[p] = lane_wb_redirect_pc[wb_lane_idx[p]];
      if (wb_grant_valid[p]) begin
        lane_wb_ready[wb_lane_idx[p]] = wb_ready_i[p];
      end
    end

    // Dedicated store writeback port [STORE_WB_PORT]: sourced from stq's
    // oldest-unreported store completion (store_wb_q merged into stq).
    wb_valid_o[STORE_WB_PORT]       = st_wb_valid_i;
    wb_rob_idx_o[STORE_WB_PORT]     = st_wb_rob_idx_i;
    wb_data_o[STORE_WB_PORT]        = st_wb_data_i;
    wb_exception_o[STORE_WB_PORT]   = st_wb_exception_i;
    wb_ecause_o[STORE_WB_PORT]      = st_wb_ecause_i;
    wb_is_mispred_o[STORE_WB_PORT]  = st_wb_is_mispred_i;
    wb_redirect_pc_o[STORE_WB_PORT] = st_wb_redirect_pc_i;
  end

  // Load writeback ports only; store-writeback head uses the slow ROB.complete path.
  always_comb begin
    for (int p = 0; p < LOAD_WB_PORTS; p++) begin
      fast_lsu_valid_o[p]       = wb_grant_valid[p] && lane_fast_lsu_valid[wb_lane_idx[p]];
      fast_lsu_rob_idx_o[p]     = lane_fast_lsu_rob_idx[wb_lane_idx[p]];
      fast_lsu_data_o[p]        = lane_fast_lsu_data[wb_lane_idx[p]];
      fast_lsu_exception_o[p]   = lane_fast_lsu_exception[wb_lane_idx[p]];
      fast_lsu_ecause_o[p]      = lane_fast_lsu_ecause[wb_lane_idx[p]];
      fast_lsu_is_mispred_o[p]  = lane_fast_lsu_is_mispred[wb_lane_idx[p]];
      fast_lsu_redirect_pc_o[p] = lane_fast_lsu_redirect_pc[wb_lane_idx[p]];
    end
  end

  // Per-port writeback fire + arbiter pointer-advance feedback.
  always_comb begin
    for (int p = 0; p < LOAD_WB_PORTS; p++) begin
      wb_port_fire[p] = wb_grant_valid[p] && wb_ready_i[p];
      wb_pop_w[p]     = wb_port_fire[p];
    end
  end
  assign store_wb_fire = wb_valid_o[STORE_WB_PORT] && wb_ready_i[STORE_WB_PORT];
  assign st_wb_fire_o  = store_wb_fire;

  // Store 完成上报 fill：在 store 准入 (store_req_fire，纯 store) 当拍把完成
  // 字段填入对应 stq 条目，等价于原 store_wb_q 的 push。faulting store 也在此
  // 上报（携带异常 ecause + 故障地址作为 tval）。
  assign st_complete_valid_o     = store_req_fire;
  assign st_complete_id_o        = pend_valid_q ? pend_st_id_q : sel_st_id;
  assign st_complete_rob_idx_o   = pend_valid_q ? pend_rob_tag_q : sel_rob_tag;
  assign st_complete_data_o      = (store_misaligned || store_page_fault) ?
                                   Cfg.XLEN'(req_eff_addr) :
                                   (is_sc && sc_fail) ? Cfg.XLEN'(1) : '0;
  assign st_complete_exception_o = store_misaligned || store_page_fault;
  assign st_complete_ecause_o    = store_misaligned ? EXC_ST_ADDR_MISALIGNED :
                                   (store_page_fault ? EXC_ST_PAGE_FAULT : '0);
  // load-store 违例：年轻 load 已乱序执行并别名该 store，记在完成上报里；store
  // 退休时 ROB 按 is_mispred 处理（提交该 store 后冲刷并重定向到违例 load PC）。
  assign st_complete_is_mispred_o   = ldq_violation_valid;
  assign st_complete_redirect_pc_o  = ldq_violation_pc;
  assign st_complete_pc_o           = pend_valid_q ? pend_uop_q.pc : sel_uop.pc;

  // AMO completes on whichever granted load port carries the (single, due to
  // amo_inflight serialization) in-flight AMO lane.
  always_comb begin
    amo_wb_fire = 1'b0;
    amo_wb_lane = '0;
    for (int p = 0; p < LOAD_WB_PORTS; p++) begin
      if (wb_port_fire[p] && lane_amo_valid_q[wb_lane_idx[p]]) begin
        amo_wb_fire = 1'b1;
        amo_wb_lane = wb_lane_idx[p];
      end
    end
  end
  assign amo_wb_new_data = amo_result(lane_amo_op_q[amo_wb_lane],
                                      lane_wb_data[amo_wb_lane],
                                      lane_amo_rs2_q[amo_wb_lane]);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lane_amo_valid_q <= '0;
      for (int i = 0; i < N_LSU; i++) begin
        lane_amo_op_q[i] <= decode_pkg::AMO_NONE;
        lane_amo_rs2_q[i] <= '0;
        lane_amo_st_id_q[i] <= '0;
        lane_amo_addr_q[i] <= '0;
      end
`ifndef SYNTHESIS
      lsu_pf_log_cnt_q <= '0;
      lsu_stall_trace_log_cnt_q <= '0;
      lsu_stall_streak_q <= '0;
`endif
    end else if (flush_i) begin
      res_valid_q <= 1'b0;
      res_addr_q <= '0;
      lane_amo_valid_q <= '0;
      for (int i = 0; i < N_LSU; i++) begin
        lane_amo_op_q[i] <= decode_pkg::AMO_NONE;
        lane_amo_rs2_q[i] <= '0;
        lane_amo_st_id_q[i] <= '0;
        lane_amo_addr_q[i] <= '0;
      end
    end else begin
      if (flush_i) begin
        res_valid_q <= 1'b0;
      end else if (load_alloc_fire && (pend_valid_q ? pend_uop_q.lsu_op : sel_uop.lsu_op) == decode_pkg::LSU_LR) begin
        res_valid_q <= 1'b1;
        res_addr_q <= req_eff_addr;
      end else if ((store_req_fire && (is_sc || (!store_misaligned && !store_page_fault))) ||
                   (amo_wb_fire && !lane_wb_exception[amo_wb_lane])) begin
        res_valid_q <= 1'b0;
      end

      if (load_alloc_fire && req_is_amo) begin
        lane_amo_valid_q[alloc_lane_idx] <= 1'b1;
        lane_amo_op_q[alloc_lane_idx] <= selected_uop.amo_op;
        lane_amo_rs2_q[alloc_lane_idx] <= selected_rs2_data;
        lane_amo_st_id_q[alloc_lane_idx] <= pend_valid_q ? pend_st_id_q : sel_st_id;
        lane_amo_addr_q[alloc_lane_idx] <= req_eff_addr;
      end

      if (amo_wb_fire) begin
        lane_amo_valid_q[amo_wb_lane] <= 1'b0;
      end

`ifndef SYNTHESIS
      if (load_alloc_fire || store_req_fire) begin
        if (lsu_trace_en_q && req_has_force_fault) begin
          if (lsu_pf_log_cnt_q < LSU_PF_LOG_BUDGET) begin
            $display("[lsu-force-fault] pc=%h addr=%h is_ld=%0d is_st=%0d ecause=%0d rob=%0d pend=%0d epoch=%0d flush=%0d",
                     pend_valid_q ? pend_uop_q.pc : sel_uop.pc,
                     pend_valid_q ? pend_addr_q : req_in_eff_addr,
                     req_is_load, req_is_store, req_force_ecause,
                     pend_valid_q ? pend_rob_tag_q : sel_rob_tag, pend_valid_q,
                     pend_valid_q ? pend_uop_q.fetch_epoch : sel_uop.fetch_epoch, flush_i);
            lsu_pf_log_cnt_q <= lsu_pf_log_cnt_q + 1'b1;
          end
        end
      end
`endif

      // store_wb_q 已并入 stq：store 准入的完成上报通过 st_complete_* 输出在
      // 当拍写入 stq 条目（见上方 assign），无需在此维护 FIFO。

`ifndef SYNTHESIS
      for (int p = 0; p < LSU_WB_PORTS; p++) begin
        if (lsu_trace_en_q && wb_valid_o[p] && wb_ready_i[p] && wb_exception_o[p] &&
            ((wb_ecause_o[p] == EXC_LD_PAGE_FAULT) || (wb_ecause_o[p] == EXC_ST_PAGE_FAULT))) begin
          if (lsu_pf_log_cnt_q < LSU_PF_LOG_BUDGET) begin
            $display("[lsu-wb-pf] port=%0d rob=%0d data=%h ecause=%0d is_store_port=%0d flush=%0d",
                     p, wb_rob_idx_o[p], wb_data_o[p], wb_ecause_o[p],
                     (p == STORE_WB_PORT), flush_i);
            lsu_pf_log_cnt_q <= lsu_pf_log_cnt_q + 1'b1;
          end
        end
      end
`endif
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i or negedge rst_ni) begin
    logic [15:0] next_streak;
    logic should_log;
    if (!rst_ni) begin
      lsu_stall_streak_q <= '0;
    end else if (flush_i) begin
      lsu_stall_streak_q <= '0;
    end else if (!lsu_trace_en_q) begin
      lsu_stall_streak_q <= '0;
    end else if (lsu_diag_stall_cond_w) begin
      next_streak = (lsu_stall_streak_q == 16'hffff) ? 16'hffff : (lsu_stall_streak_q + 16'd1);
      should_log = (next_streak == 16'd1) || (next_streak[9:0] == 10'd0);
      lsu_stall_streak_q <= next_streak;
      if ((lsu_stall_trace_log_cnt_q < LSU_STALL_TRACE_LOG_BUDGET) && should_log) begin
        $display("[lsu-stall] pc=%h streak=%0d pend=%0d mmu_state=%0d req(v/r)=%0d/%0d need_mmu=%0d req_is(ld/st)=%0d/%0d load_rdy=%0d store_rdy=%0d ldq_alloc=%0d stq_alloc=%0d ldq(cnt/full)=%0d/%0d stq(cnt/full)=%0d/%0d wb_cnt=%0d ld_pipe_req_ready=0x%h ld_pipe_ld_req_valid=0x%h ld_pipe_ld_rsp_ready=0x%h ld_rsp(v/r)=%0d/%0d",
                 lsu_diag_pc_w, next_streak, pend_valid_q, mmu_state_q,
                 req_valid_or, req_ready_o, req_need_mmu_walk, req_is_load, req_is_store,
                 load_req_ready, store_req_ready, ldq_alloc_ready, sq_alloc_ready,
                 dbg_ldq_count_o, ldq_full, dbg_sq_count_o, sq_full, st_unreported_count_i,
                 lane_req_ready, lane_ld_req_valid, lane_ld_rsp_ready,
                 ld_rsp_valid_i, ld_rsp_ready_o);
        lsu_stall_trace_log_cnt_q <= lsu_stall_trace_log_cnt_q + 1'b1;
      end
    end else begin
      lsu_stall_streak_q <= '0;
    end
    // #region agent log
    if (dual_pair_wanted && load_req_ready && !req_ready_o && !flush_i) begin
      $fwrite(agent_dbg_fd,
              "{\"sessionId\":\"0e02a7\",\"hypothesisId\":\"A\",\"location\":\"lsu_group.sv:dual_gate\",\"message\":\"dual_wanted_req_not_ready\",\"data\":{\"dual_fire\":%0d,\"load_req_ready_p1\":%0d,\"dual_pair_active\":%0d,\"rob_head\":%0d,\"ldq_free\":%0d},\"timestamp\":%0d}\n",
              dual_fire, load_req_ready_p1, dual_pair_active, rob_head_i, ldq_free_count, $time);
      $fflush(agent_dbg_fd);
    end
    // #endregion
  end
`endif

  ldq #(
      .ROB_IDX_WIDTH(ROB_IDX_WIDTH),
      .DEPTH(LDQ_DEPTH),
      .PLEN(Cfg.PLEN),
      .BE_WIDTH(SQ_BE_WIDTH),
      .COMMIT_WIDTH(COMMIT_WIDTH),
      .N_EXEC(LOAD_WB_PORTS)
  ) u_ldq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .alloc_valid_i(ldq_alloc_valid),
      .alloc_ready_o(ldq_alloc_ready),
      .free_count_o(ldq_free_count),
      .alloc_rob_tag_i(ldq_alloc_rob_tag),
      .alloc_pc_i(ldq_alloc_pc),
      .alloc_paddr_i(ldq_alloc_paddr),
      .alloc_be_i(ldq_alloc_be),
      .commit_valid_i(commit_valid_i),
      .commit_rob_idx_i(commit_rob_idx_i),
      .exec_valid_i(ldq_exec_valid),
      .exec_rob_tag_i(ldq_exec_rob_tag),
      .st_query_valid_i(ldq_st_query_valid),
      .st_paddr_i(ldq_st_paddr),
      .st_be_i(ldq_st_be),
      .st_rob_tag_i(ldq_st_rob_tag),
      .rob_head_i(rob_head_i),
      .violation_valid_o(ldq_violation_valid),
      .violation_pc_o(ldq_violation_pc),
      .violation_rob_idx_o(lq_violation_rob_idx),
      .head_valid_o(dbg_ldq_head_valid_o),
      .head_rob_tag_o(dbg_ldq_head_rob_tag_o),
      .count_o(dbg_ldq_count_o),
      .full_o(ldq_full),
      .empty_o(ldq_empty),
      .inflight_empty_o(ldq_inflight_empty)
  );

  // The dedicated `sq` was removed: store-to-load forwarding now lives solely
  // in stq, and AMO ordering / store admission rely on stq 的未上报 store 计数。
  // Debug ports are derived from stq's store-wb interface so existing probes
  // stay meaningful.
  assign dbg_sq_count_o = ($clog2(SQ_DEPTH + 1))'(st_unreported_count_i);
  assign dbg_sq_head_valid_o = store_wb_head_valid;
  assign dbg_sq_head_rob_tag_o = store_wb_head_rob_idx;

  assign rsp_id_in_range = ($unsigned(ld_rsp_id_i) < N_LSU);

  always_comb begin
    dbg_alloc_lane = load_alloc_fire ? DBG_SEL_WIDTH'(alloc_lane_idx + 1'b1) : '0;
    dbg_ld_owner = '0;

    // Prefer the response lane in current cycle; fallback to first lane waiting response.
    if (ld_rsp_valid_i && rsp_id_in_range) begin
      dbg_ld_owner = DBG_SEL_WIDTH'(ld_rsp_id_i + 1'b1);
    end else begin
      for (int i = 0; i < N_LSU; i++) begin
        if (dbg_ld_owner == '0 && lane_ld_rsp_ready[i]) begin
          dbg_ld_owner = DBG_SEL_WIDTH'(i + 1);
        end
      end
    end
  end

  initial begin
    if (N_LSU < 1) begin
      $error("lsu_group: N_LSU must be >= 1, got %0d", N_LSU);
    end
  end

endmodule
