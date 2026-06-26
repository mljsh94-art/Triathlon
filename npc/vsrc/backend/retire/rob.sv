// vsrc/backend/retire/rob.sv
import config_pkg::*;
import decode_pkg::*;

module rob #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned ROB_DEPTH = 64,
    parameter int unsigned DISPATCH_WIDTH = Cfg.INSTR_PER_FETCH,
    parameter int unsigned COMMIT_WIDTH = Cfg.NRET,
    parameter int unsigned WB_WIDTH = 4,
    parameter int unsigned QUERY_WIDTH = DISPATCH_WIDTH * 2,
    // [新增] Store Buffer 参数
    parameter int unsigned SB_DEPTH = 32,
    parameter int unsigned SB_IDX_WIDTH = $clog2(SB_DEPTH),
    parameter int unsigned MAX_COMMIT_BR = 1,
    parameter int unsigned MAX_COMMIT_ST = 2,
    parameter int unsigned MAX_COMMIT_LD = 2,
    parameter int unsigned FAST_LSU_PORTS = 2
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // =========================================================
    // 1. Dispatch 阶段 (From Rename)
    // =========================================================
    input logic            [DISPATCH_WIDTH-1:0]               dispatch_valid_i,
    input logic            [DISPATCH_WIDTH-1:0][Cfg.PLEN-1:0] dispatch_pc_i,
    input logic            [DISPATCH_WIDTH-1:0][Cfg.ILEN-1:0] dispatch_inst_i,
    input logic            [DISPATCH_WIDTH-1:0][Cfg.ILEN-1:0] dispatch_decoded_inst_i,
    input decode_pkg::fu_e [DISPATCH_WIDTH-1:0]               dispatch_fu_type_i,
    input logic            [DISPATCH_WIDTH-1:0][         4:0] dispatch_areg_i,
    input logic            [DISPATCH_WIDTH-1:0]               dispatch_has_rd_i,
    input logic            [DISPATCH_WIDTH-1:0]               dispatch_is_branch_i,
    input logic            [DISPATCH_WIDTH-1:0]               dispatch_is_jump_i,
    input logic            [DISPATCH_WIDTH-1:0]               dispatch_is_call_i,
    input logic            [DISPATCH_WIDTH-1:0]               dispatch_is_ret_i,
    input logic            [DISPATCH_WIDTH-1:0]               dispatch_is_rvc_i,
    input logic            [DISPATCH_WIDTH-1:0][Cfg.PLEN-1:0] dispatch_pred_npc_i,
    input logic [DISPATCH_WIDTH-1:0][decode_pkg::FTQ_ID_W-1:0] dispatch_ftq_id_i,
    input logic [DISPATCH_WIDTH-1:0][decode_pkg::FETCH_EPOCH_W-1:0] dispatch_fetch_epoch_i,

    // [新增] 接收 Store Buffer ID
    // 只有当指令是 Store 时，这个信号才有效；否则忽略
    input logic [DISPATCH_WIDTH-1:0]                   dispatch_is_store_i,
    input logic [DISPATCH_WIDTH-1:0][SB_IDX_WIDTH-1:0] dispatch_sb_id_i,

    output logic rob_ready_o,
    output logic [DISPATCH_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] dispatch_rob_index_o,

    // =========================================================
    // 2. Writeback 阶段 (From completion queue / CDB)
    // =========================================================
    input logic [WB_WIDTH-1:0] wb_valid_i,
    input logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] wb_rob_index_i,
    input logic [WB_WIDTH-1:0][Cfg.XLEN-1:0] wb_data_i,

    input logic [WB_WIDTH-1:0] wb_exception_i,
    input logic [WB_WIDTH-1:0][4:0] wb_ecause_i,
    input logic [WB_WIDTH-1:0] wb_is_mispred_i,
    input logic [WB_WIDTH-1:0][Cfg.PLEN-1:0] wb_redirect_pc_i,
    input logic async_exception_valid_i,
    input logic [4:0] async_exception_cause_i,
    input logic [Cfg.PLEN-1:0] async_exception_pc_i,
    input logic [Cfg.PLEN-1:0] async_exception_redirect_pc_i,
    // Fast-visible path for ALU completion (combinational assist only).
    input logic [DISPATCH_WIDTH-1:0] fast_alu_valid_i,
    input logic [DISPATCH_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] fast_alu_rob_idx_i,
    input logic [DISPATCH_WIDTH-1:0][Cfg.XLEN-1:0] fast_alu_data_i,
    input logic [DISPATCH_WIDTH-1:0] fast_alu_is_mispred_i,
    input logic [DISPATCH_WIDTH-1:0][Cfg.PLEN-1:0] fast_alu_redirect_pc_i,
    input logic fast_bru_valid_i,
    input logic [$clog2(ROB_DEPTH)-1:0] fast_bru_rob_idx_i,
    input logic [Cfg.XLEN-1:0] fast_bru_data_i,
    input logic [Cfg.PLEN-1:0] fast_bru_redirect_pc_i,
    input logic fast_bru_can_commit_i,
    // Fast-visible path for LSU load completion (combinational assist only).
    input logic [FAST_LSU_PORTS-1:0] fast_lsu_valid_i,
    input logic [FAST_LSU_PORTS-1:0][$clog2(ROB_DEPTH)-1:0] fast_lsu_rob_idx_i,
    input logic [FAST_LSU_PORTS-1:0][Cfg.XLEN-1:0] fast_lsu_data_i,
    input logic [FAST_LSU_PORTS-1:0] fast_lsu_exception_i,
    input logic [FAST_LSU_PORTS-1:0][4:0] fast_lsu_ecause_i,
    input logic [FAST_LSU_PORTS-1:0] fast_lsu_is_mispred_i,
    input logic [FAST_LSU_PORTS-1:0][Cfg.PLEN-1:0] fast_lsu_redirect_pc_i,

    // =========================================================
    // 3. Commit 阶段 (To ARF & Controller & RAT & SB)
    // =========================================================
    output logic [COMMIT_WIDTH-1:0] commit_valid_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] commit_pc_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.ILEN-1:0] commit_inst_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.ILEN-1:0] commit_decoded_inst_o,

    // To ARF
    output logic [COMMIT_WIDTH-1:0]               commit_we_o,
    output logic [COMMIT_WIDTH-1:0][         4:0] commit_areg_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.XLEN-1:0] commit_wdata_o,

    // To RAT
    output logic [COMMIT_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] commit_rob_index_o,

    // To Store Buffer [修复核心]
    output logic [COMMIT_WIDTH-1:0] commit_is_store_o,
    // [新增] 告诉 Store Buffer 哪条指令退休了
    output logic [COMMIT_WIDTH-1:0][SB_IDX_WIDTH-1:0] commit_sb_id_o,
    output logic [COMMIT_WIDTH-1:0]                    commit_is_branch_o,
    output logic [COMMIT_WIDTH-1:0]                    commit_is_jump_o,
    output logic [COMMIT_WIDTH-1:0]                    commit_is_call_o,
    output logic [COMMIT_WIDTH-1:0]                    commit_is_ret_o,
    output logic [COMMIT_WIDTH-1:0]                    commit_is_rvc_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0]      commit_pred_npc_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0]      commit_actual_npc_o,
    output logic [COMMIT_WIDTH-1:0][decode_pkg::FTQ_ID_W-1:0] commit_ftq_id_o,
    output logic [COMMIT_WIDTH-1:0][decode_pkg::FETCH_EPOCH_W-1:0] commit_fetch_epoch_o,

    // Flush Interface
    output logic flush_o,
    output logic [Cfg.PLEN-1:0] flush_pc_o,
    output logic [4:0] flush_cause_o,
    output logic flush_is_mispred_o,
    output logic flush_is_exception_o,
    output logic flush_is_branch_o,
    output logic flush_is_jump_o,
    output logic [Cfg.PLEN-1:0] flush_src_pc_o,
    output logic sync_exception_valid_o,
    output logic [4:0] sync_exception_cause_o,
    output logic [Cfg.PLEN-1:0] sync_exception_pc_o,
    output logic [Cfg.PLEN-1:0] sync_exception_tval_o,

    // =========================================================
    // 4. Operand Query (To Issue/Rename)
    // =========================================================
    input  logic [QUERY_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] query_rob_idx_i,
    output logic [QUERY_WIDTH-1:0]                        query_ready_o,
    output logic [QUERY_WIDTH-1:0][         Cfg.XLEN-1:0] query_data_o,
    output logic [QUERY_WIDTH-1:0][decode_pkg::FETCH_EPOCH_W-1:0] query_fetch_epoch_o,
    output logic [QUERY_WIDTH-1:0][Cfg.PLEN-1:0] query_pc_o,
    output logic [QUERY_WIDTH-1:0] query_valid_o,
    output logic [QUERY_WIDTH-1:0] query_has_rd_o,
    output logic [QUERY_WIDTH-1:0][4:0] query_areg_o,

    output logic rob_empty_o,
    output logic rob_full_o,
    output logic [$clog2(ROB_DEPTH)-1:0] rob_head_o,
    output logic [Cfg.PLEN-1:0] rob_head_pc_o
);
  localparam int unsigned PTR_WIDTH = $clog2(ROB_DEPTH);
`ifndef SYNTHESIS
  localparam logic [Cfg.PLEN-1:0] DBG_PC_RET = 32'hc0803d60;
  localparam logic [Cfg.PLEN-1:0] DBG_PC_FAULT0 = 32'hc0803dae;
  localparam logic [Cfg.PLEN-1:0] DBG_PC_FAULT1 = 32'hc080ab72;
  localparam logic [PTR_WIDTH-1:0] DBG_ROB_TAG0 = PTR_WIDTH'(22);
  localparam logic [PTR_WIDTH-1:0] DBG_ROB_TAG1 = PTR_WIDTH'(44);
  localparam int unsigned ROB_TAG_TRACE_BUDGET = 256;
  logic [31:0] rob_tag_trace_cnt_q;
  logic rob_trace_en_q;
  logic rob_tag_trace_en_q;
  initial rob_trace_en_q = $test$plusargs("npc_diag_trace");
  initial rob_tag_trace_en_q = $test$plusargs("npc_diag_robtag");

  function automatic logic watch_kernel_pc(input logic [Cfg.PLEN-1:0] pc);
    begin
      watch_kernel_pc = (pc[31:28] == 4'hc);
    end
  endfunction

`endif

  typedef struct packed {
    logic valid;
    logic complete;
    logic exception;
    logic [4:0] ecause;
    logic is_mispred;
    logic [Cfg.PLEN-1:0] redirect_pc;
    decode_pkg::fu_e fu_type;
    logic [4:0] areg;
    logic has_rd;
    logic is_branch;
    logic is_jump;
    logic is_call;
    logic is_ret;
    logic is_rvc;
    logic [Cfg.PLEN-1:0] pred_npc;
    logic [Cfg.XLEN-1:0] data;
    logic [Cfg.PLEN-1:0] pc;
    logic [Cfg.ILEN-1:0] inst;
    logic [Cfg.ILEN-1:0] decoded_inst;
    logic [decode_pkg::FTQ_ID_W-1:0] ftq_id;
    logic [decode_pkg::FETCH_EPOCH_W-1:0] fetch_epoch;

    // [新增] 存储该指令对应的 Store Buffer ID
    logic is_store;
    logic [SB_IDX_WIDTH-1:0] sb_id;
  } rob_entry_t;

  rob_entry_t [ROB_DEPTH-1:0] rob_ram;

  logic [PTR_WIDTH-1:0] head_ptr_q, head_ptr_d;
  logic [PTR_WIDTH-1:0] tail_ptr_q, tail_ptr_d;
  logic [$clog2(ROB_DEPTH+1)-1:0] count_q, count_d;

  assign rob_full_o  = (count_q > (ROB_DEPTH - DISPATCH_WIDTH));
  assign rob_empty_o = (count_q == 0);
  assign rob_ready_o = !rob_full_o;

  always_comb begin
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      dispatch_rob_index_o[i] = tail_ptr_q + i[PTR_WIDTH-1:0];
    end
  end

  // =========================================================
  // Commit Logic
  // =========================================================
  logic stop_commit;
  logic [COMMIT_WIDTH-1:0] br_mask, st_mask, ld_mask;
  logic [COMMIT_WIDTH-1:0] commit_permitted_mask;
  logic [COMMIT_WIDTH-1:0] head_fast_complete;
  logic [COMMIT_WIDTH-1:0][Cfg.XLEN-1:0] head_fast_data;
  logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] head_fast_redirect_pc;
  logic [COMMIT_WIDTH-1:0] head_fast_exception;
  logic [COMMIT_WIDTH-1:0][4:0] head_fast_ecause;
  logic [COMMIT_WIDTH-1:0] head_fast_is_mispred;

  always_comb begin
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      logic [PTR_WIDTH-1:0] idx;
      idx = head_ptr_q + i[PTR_WIDTH-1:0];
      head_fast_complete[i] = rob_ram[idx].complete;
      head_fast_data[i] = rob_ram[idx].data;
      head_fast_redirect_pc[i] = rob_ram[idx].redirect_pc;
      head_fast_exception[i] = rob_ram[idx].exception;
      head_fast_ecause[i] = rob_ram[idx].ecause;
      head_fast_is_mispred[i] = rob_ram[idx].is_mispred;
      if (rob_ram[idx].fu_type == decode_pkg::FU_ALU) begin
        for (int a = 0; a < DISPATCH_WIDTH; a++) begin
          if (fast_alu_valid_i[a] && (fast_alu_rob_idx_i[a] == idx)) begin
            head_fast_complete[i] = 1'b1;
            head_fast_data[i] = fast_alu_data_i[a];
            head_fast_redirect_pc[i] = fast_alu_redirect_pc_i[a];
          end
        end
      end else if ((rob_ram[idx].fu_type == decode_pkg::FU_BRANCH) && !rob_ram[idx].is_jump) begin
        // Conditional branch may execute on ALU lanes. For correctness, only
        // enable same-cycle visibility on non-mispred branch WB.
        for (int a = 0; a < DISPATCH_WIDTH; a++) begin
          if (fast_alu_valid_i[a] &&
              !fast_alu_is_mispred_i[a] &&
              (fast_alu_rob_idx_i[a] == idx)) begin
            head_fast_complete[i] = 1'b1;
            head_fast_data[i] = fast_alu_data_i[a];
            head_fast_redirect_pc[i] = fast_alu_redirect_pc_i[a];
          end
        end
      end else if ((rob_ram[idx].fu_type == decode_pkg::FU_BRANCH) && rob_ram[idx].is_jump) begin
        if (fast_bru_valid_i &&
            fast_bru_can_commit_i &&
            (fast_bru_rob_idx_i == idx)) begin
          head_fast_complete[i] = 1'b1;
          head_fast_data[i] = fast_bru_data_i;
          head_fast_redirect_pc[i] = fast_bru_redirect_pc_i;
        end
      end else if (rob_ram[idx].fu_type == decode_pkg::FU_LSU) begin
        for (int p = 0; p < FAST_LSU_PORTS; p++) begin
          if (fast_lsu_valid_i[p] && (fast_lsu_rob_idx_i[p] == idx)) begin
            head_fast_complete[i] = 1'b1;
            head_fast_data[i] = fast_lsu_data_i[p];
            head_fast_redirect_pc[i] = fast_lsu_redirect_pc_i[p];
            head_fast_exception[i] = fast_lsu_exception_i[p];
            head_fast_ecause[i] = fast_lsu_ecause_i[p];
            head_fast_is_mispred[i] = fast_lsu_is_mispred_i[p];
          end
        end
      end
    end
  end

  always_comb begin
    automatic int cnt_br = 0;
    automatic int cnt_st = 0;
    automatic int cnt_ld = 0;

    stop_commit = 1'b0;
    flush_o = 1'b0;
    flush_pc_o = '0;
    flush_cause_o = '0;
    flush_is_mispred_o = 1'b0;
    flush_is_exception_o = 1'b0;
    flush_is_branch_o = 1'b0;
    flush_is_jump_o = 1'b0;
    flush_src_pc_o = '0;
    sync_exception_valid_o = 1'b0;
    sync_exception_cause_o = '0;
    sync_exception_pc_o = '0;
    sync_exception_tval_o = '0;

    commit_valid_o = '0;
    commit_pc_o    = '0;
    commit_inst_o  = '0;
    commit_decoded_inst_o = '0;
    commit_we_o    = '0;
    commit_areg_o  = '0;
    commit_wdata_o = '0;
    commit_is_store_o = '0;
    commit_sb_id_o    = '0; // 默认清零
    commit_is_branch_o = '0;
    commit_is_jump_o = '0;
    commit_is_call_o = '0;
    commit_is_ret_o = '0;
    commit_is_rvc_o = '0;
    commit_pred_npc_o = '0;
    commit_actual_npc_o = '0;
    commit_ftq_id_o = '0;
    commit_fetch_epoch_o = '0;
    commit_rob_index_o = '0;

    // External flush kills all in-flight state and suppresses same-cycle commit.
    if (flush_i) begin
      stop_commit = 1'b1;
      br_mask = '0;
      st_mask = '0;
      ld_mask = '0;
      commit_permitted_mask = '0;
    end else if (async_exception_valid_i) begin
      stop_commit = 1'b1;
      flush_o = 1'b1;
      flush_pc_o = async_exception_redirect_pc_i;
      flush_cause_o = async_exception_cause_i;
      flush_is_exception_o = 1'b1;
      flush_src_pc_o = async_exception_pc_i;
      br_mask = '0;
      st_mask = '0;
      ld_mask = '0;
      commit_permitted_mask = '0;
    end else begin
      // --- 1. Resource Check ---
      br_mask = '1;
      st_mask = '1;
      ld_mask = '1;

      for (int i = 0; i < COMMIT_WIDTH; i++) begin
        if (count_q > i) begin
          if (rob_ram[head_ptr_q+i[PTR_WIDTH-1:0]].fu_type == decode_pkg::FU_BRANCH) begin
            if (cnt_br >= MAX_COMMIT_BR) br_mask[i] = 1'b0;
            cnt_br++;
          end
          if (rob_ram[head_ptr_q+i[PTR_WIDTH-1:0]].is_store) begin
            if (cnt_st >= MAX_COMMIT_ST) st_mask[i] = 1'b0;
            cnt_st++;
          end
          if (rob_ram[head_ptr_q+i[PTR_WIDTH-1:0]].fu_type == decode_pkg::FU_LSU &&
              !rob_ram[head_ptr_q+i[PTR_WIDTH-1:0]].is_store) begin
            if (cnt_ld >= MAX_COMMIT_LD) ld_mask[i] = 1'b0;
            cnt_ld++;
          end
        end
      end
      commit_permitted_mask = br_mask & st_mask & ld_mask;

      // --- 2. Final Commit ---
      for (int i = 0; i < COMMIT_WIDTH; i++) begin
        commit_rob_index_o[i] = head_ptr_q + i[PTR_WIDTH-1:0];

        if ((count_q > i) && !stop_commit && commit_permitted_mask[i]) begin
          if (head_fast_complete[i]) begin
            if (head_fast_exception[i]) begin
              stop_commit   = 1'b1;
              // Precise sync exception is handled by CSR/trap path at commit head.
              sync_exception_valid_o = 1'b1;
              sync_exception_cause_o = head_fast_ecause[i];
              sync_exception_pc_o = rob_ram[commit_rob_index_o[i]].pc;
              sync_exception_tval_o = head_fast_data[i][Cfg.PLEN-1:0];
            end else if (head_fast_is_mispred[i]) begin
              // 分支/跳转误预测：先退休该指令，再触发 flush
              commit_valid_o[i] = 1'b1;
              commit_pc_o[i]    = rob_ram[commit_rob_index_o[i]].pc;
              commit_inst_o[i]  = rob_ram[commit_rob_index_o[i]].inst;
              commit_decoded_inst_o[i] = rob_ram[commit_rob_index_o[i]].decoded_inst;

              commit_areg_o[i]  = rob_ram[commit_rob_index_o[i]].areg;
              commit_wdata_o[i] = head_fast_data[i];
              if (rob_ram[commit_rob_index_o[i]].has_rd &&
                  rob_ram[commit_rob_index_o[i]].areg != 0) begin
                commit_we_o[i] = 1'b1;
              end

              commit_is_store_o[i] = rob_ram[commit_rob_index_o[i]].is_store;
              commit_sb_id_o[i]    = rob_ram[commit_rob_index_o[i]].sb_id;
              commit_is_branch_o[i] = rob_ram[commit_rob_index_o[i]].is_branch;
              commit_is_jump_o[i] = rob_ram[commit_rob_index_o[i]].is_jump;
              commit_is_call_o[i] = rob_ram[commit_rob_index_o[i]].is_call;
              commit_is_ret_o[i] = rob_ram[commit_rob_index_o[i]].is_ret;
              commit_is_rvc_o[i] = rob_ram[commit_rob_index_o[i]].is_rvc;
              commit_pred_npc_o[i] = rob_ram[commit_rob_index_o[i]].pred_npc;
              commit_actual_npc_o[i] = head_fast_redirect_pc[i];
              commit_ftq_id_o[i] = rob_ram[commit_rob_index_o[i]].ftq_id;
              commit_fetch_epoch_o[i] = rob_ram[commit_rob_index_o[i]].fetch_epoch;

              stop_commit          = 1'b1;
              flush_o              = 1'b1;
              flush_pc_o           = head_fast_redirect_pc[i];
              flush_is_mispred_o   = 1'b1;
              flush_is_branch_o    = rob_ram[commit_rob_index_o[i]].is_branch;
              flush_is_jump_o      = rob_ram[commit_rob_index_o[i]].is_jump;
              flush_src_pc_o       = rob_ram[commit_rob_index_o[i]].pc;
            end else begin
              // 正常退休
              commit_valid_o[i] = 1'b1;
              commit_pc_o[i]    = rob_ram[commit_rob_index_o[i]].pc;
              commit_inst_o[i]  = rob_ram[commit_rob_index_o[i]].inst;
              commit_decoded_inst_o[i] = rob_ram[commit_rob_index_o[i]].decoded_inst;

              commit_areg_o[i]  = rob_ram[commit_rob_index_o[i]].areg;
              commit_wdata_o[i] = head_fast_data[i];
              if (rob_ram[commit_rob_index_o[i]].has_rd &&
                  rob_ram[commit_rob_index_o[i]].areg != 0) begin
                commit_we_o[i] = 1'b1;
              end

              commit_is_store_o[i] = rob_ram[commit_rob_index_o[i]].is_store;
              commit_sb_id_o[i]    = rob_ram[commit_rob_index_o[i]].sb_id;
              commit_is_branch_o[i] = rob_ram[commit_rob_index_o[i]].is_branch;
              commit_is_jump_o[i] = rob_ram[commit_rob_index_o[i]].is_jump;
              commit_is_call_o[i] = rob_ram[commit_rob_index_o[i]].is_call;
              commit_is_ret_o[i] = rob_ram[commit_rob_index_o[i]].is_ret;
              commit_is_rvc_o[i] = rob_ram[commit_rob_index_o[i]].is_rvc;
              commit_pred_npc_o[i] = rob_ram[commit_rob_index_o[i]].pred_npc;
              commit_actual_npc_o[i] = head_fast_redirect_pc[i];
              commit_ftq_id_o[i] = rob_ram[commit_rob_index_o[i]].ftq_id;
              commit_fetch_epoch_o[i] = rob_ram[commit_rob_index_o[i]].fetch_epoch;
            end
          end else begin
            stop_commit = 1'b1;
          end
        end else begin
          stop_commit = 1'b1;
        end
      end
    end
  end

  // =========================================================
  // Operand Query (Combinational)
  // =========================================================
  always_comb begin
    for (int q = 0; q < QUERY_WIDTH; q++) begin
      query_ready_o[q] = rob_ram[query_rob_idx_i[q]].valid &&
                         rob_ram[query_rob_idx_i[q]].complete;
      query_data_o[q]  = rob_ram[query_rob_idx_i[q]].data;
      query_fetch_epoch_o[q] = rob_ram[query_rob_idx_i[q]].fetch_epoch;
      query_pc_o[q] = rob_ram[query_rob_idx_i[q]].pc;
      query_valid_o[q] = rob_ram[query_rob_idx_i[q]].valid;
      query_has_rd_o[q] = rob_ram[query_rob_idx_i[q]].has_rd;
      query_areg_o[q] = rob_ram[query_rob_idx_i[q]].areg;
      for (int a = 0; a < DISPATCH_WIDTH; a++) begin
        if (fast_alu_valid_i[a] && (fast_alu_rob_idx_i[a] == query_rob_idx_i[q])) begin
          query_ready_o[q] = 1'b1;
          query_data_o[q] = fast_alu_data_i[a];
        end
      end
      if (fast_bru_valid_i && fast_bru_can_commit_i && (fast_bru_rob_idx_i == query_rob_idx_i[q])) begin
        query_ready_o[q] = 1'b1;
        query_data_o[q] = fast_bru_data_i;
      end
      for (int p = 0; p < FAST_LSU_PORTS; p++) begin
        if (fast_lsu_valid_i[p] && !fast_lsu_exception_i[p] &&
            (fast_lsu_rob_idx_i[p] == query_rob_idx_i[q])) begin
          query_ready_o[q] = 1'b1;
          query_data_o[q] = fast_lsu_data_i[p];
        end
      end
    end
  end

  // ... Pointers Logic (Unchanged) ...
  logic [$clog2(DISPATCH_WIDTH+1)-1:0] dispatch_cnt;
  logic [  $clog2(COMMIT_WIDTH+1)-1:0] commit_cnt;
  always_comb begin
    dispatch_cnt = 0;
    if (rob_ready_o) begin
      for (int i = 0; i < DISPATCH_WIDTH; i++) begin
        if (dispatch_valid_i[i]) dispatch_cnt++;
      end
    end
    commit_cnt = 0;
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      if (commit_valid_o[i]) commit_cnt++;
    end
  end
  assign tail_ptr_d = tail_ptr_q + PTR_WIDTH'(dispatch_cnt);
  assign head_ptr_d = head_ptr_q + PTR_WIDTH'(commit_cnt);

  assign rob_head_o = head_ptr_q;
  assign rob_head_pc_o = rob_ram[head_ptr_q].pc;
  assign count_d    = count_q + dispatch_cnt - commit_cnt;

  // ... Sequential Logic ...
`ifndef SYNTHESIS
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rob_tag_trace_cnt_q <= '0;
    end else if (rob_trace_en_q) begin
      automatic int unsigned trace_inc;
      trace_inc = 0;

      for (int k = 0; k < WB_WIDTH; k++) begin
        if (wb_valid_i[k] && rob_ram[wb_rob_index_i[k]].valid &&
            ((rob_ram[wb_rob_index_i[k]].pc == DBG_PC_RET) ||
             (rob_ram[wb_rob_index_i[k]].pc == DBG_PC_FAULT0) ||
             (rob_ram[wb_rob_index_i[k]].pc == DBG_PC_FAULT1)) &&
            ((rob_tag_trace_cnt_q + trace_inc) < ROB_TAG_TRACE_BUDGET)) begin
          $display(
              "[rob-wb-watch] pc=%h rob=%0d wb_exc=%0d wb_ec=%0d wb_misp=%0d wb_redir=%h old_comp=%0d old_exc=%0d old_misp=%0d old_redir=%h",
              rob_ram[wb_rob_index_i[k]].pc, wb_rob_index_i[k], wb_exception_i[k], wb_ecause_i[k],
              wb_is_mispred_i[k], wb_redirect_pc_i[k], rob_ram[wb_rob_index_i[k]].complete,
              rob_ram[wb_rob_index_i[k]].exception, rob_ram[wb_rob_index_i[k]].is_mispred,
              rob_ram[wb_rob_index_i[k]].redirect_pc);
          trace_inc++;
        end

      end

      for (int i = 0; i < COMMIT_WIDTH; i++) begin
        if (commit_valid_o[i] &&
            ((commit_pc_o[i] == DBG_PC_RET) ||
             (commit_pc_o[i] == DBG_PC_FAULT0) ||
             (commit_pc_o[i] == DBG_PC_FAULT1)) &&
            ((rob_tag_trace_cnt_q + trace_inc) < ROB_TAG_TRACE_BUDGET)) begin
          $display(
              "[rob-commit-watch] pc=%h rob=%0d we=%0d actual_npc=%h is_mispred=%0d is_exc=%0d ec=%0d head=%0d tail=%0d cnt=%0d",
              commit_pc_o[i], commit_rob_index_o[i], commit_we_o[i], commit_actual_npc_o[i],
              rob_ram[commit_rob_index_o[i]].is_mispred, rob_ram[commit_rob_index_o[i]].exception,
              rob_ram[commit_rob_index_o[i]].ecause, head_ptr_q, tail_ptr_q, count_q);
          trace_inc++;
        end
      end

      if (flush_o &&
          ((flush_src_pc_o == DBG_PC_RET) ||
           (flush_src_pc_o == DBG_PC_FAULT0) ||
           (flush_src_pc_o == DBG_PC_FAULT1)) &&
          ((rob_tag_trace_cnt_q + trace_inc) < ROB_TAG_TRACE_BUDGET)) begin
        $display(
            "[rob-flush-watch] src_pc=%h flush_pc=%h is_mispred=%0d is_exc=%0d is_br=%0d is_j=%0d cause=%0d head=%0d tail=%0d cnt=%0d",
            flush_src_pc_o, flush_pc_o, flush_is_mispred_o, flush_is_exception_o,
            flush_is_branch_o, flush_is_jump_o, flush_cause_o, head_ptr_q, tail_ptr_q, count_q);
        trace_inc++;
      end

      if (rob_tag_trace_en_q && (rob_tag_trace_cnt_q < ROB_TAG_TRACE_BUDGET)) begin
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
          if (dispatch_valid_i[i]) begin
            logic [PTR_WIDTH-1:0] w_idx;
            w_idx = tail_ptr_q + i[PTR_WIDTH-1:0];
            if (((w_idx == DBG_ROB_TAG0) || (w_idx == DBG_ROB_TAG1)) &&
                watch_kernel_pc(dispatch_pc_i[i])) begin
              $display(
                  "[rob-tag-disp] tag=%0d slot=%0d pc=%h areg=%0d has_rd=%0d fu=%0d old_valid=%0d old_comp=%0d old_data=%h old_pc=%h flush_i=%0d flush_o=%0d head=%0d tail=%0d cnt=%0d",
                  w_idx, i, dispatch_pc_i[i], dispatch_areg_i[i], dispatch_has_rd_i[i],
                  dispatch_fu_type_i[i], rob_ram[w_idx].valid, rob_ram[w_idx].complete,
                  rob_ram[w_idx].data, rob_ram[w_idx].pc, flush_i, flush_o, head_ptr_q, tail_ptr_q,
                  count_q);
              trace_inc++;
            end
          end
        end

        for (int k = 0; k < WB_WIDTH; k++) begin
          if (wb_valid_i[k] &&
              ((wb_rob_index_i[k] == DBG_ROB_TAG0) || (wb_rob_index_i[k] == DBG_ROB_TAG1)) &&
              watch_kernel_pc(rob_ram[wb_rob_index_i[k]].pc)) begin
            $display(
                "[rob-tag-wb] tag=%0d lane=%0d wb_data=%h wb_exc=%0d wb_ec=%0d wb_misp=%0d wb_redir=%h old_valid=%0d old_comp=%0d old_data=%h old_pc=%h flush_i=%0d flush_o=%0d head=%0d tail=%0d cnt=%0d",
                wb_rob_index_i[k], k, wb_data_i[k], wb_exception_i[k], wb_ecause_i[k],
                wb_is_mispred_i[k], wb_redirect_pc_i[k], rob_ram[wb_rob_index_i[k]].valid,
                rob_ram[wb_rob_index_i[k]].complete, rob_ram[wb_rob_index_i[k]].data,
                rob_ram[wb_rob_index_i[k]].pc, flush_i, flush_o, head_ptr_q, tail_ptr_q, count_q);
            trace_inc++;
          end
        end

        for (int q = 0; q < QUERY_WIDTH; q++) begin
          logic [PTR_WIDTH-1:0] q_idx;
          logic ram_ready;
          logic [Cfg.XLEN-1:0] ram_data;
          logic fast_alu_hit;
          logic [Cfg.XLEN-1:0] fast_alu_data;
          logic fast_bru_hit;
          q_idx = query_rob_idx_i[q];
          if ((q_idx == DBG_ROB_TAG0) || (q_idx == DBG_ROB_TAG1)) begin
            ram_ready = rob_ram[q_idx].valid && rob_ram[q_idx].complete;
            ram_data = rob_ram[q_idx].data;
            fast_alu_hit = 1'b0;
            fast_alu_data = '0;
            for (int a = 0; a < DISPATCH_WIDTH; a++) begin
              if (fast_alu_valid_i[a] && (fast_alu_rob_idx_i[a] == q_idx)) begin
                fast_alu_hit = 1'b1;
                fast_alu_data = fast_alu_data_i[a];
              end
            end
            fast_bru_hit = fast_bru_valid_i && fast_bru_can_commit_i && (fast_bru_rob_idx_i == q_idx);
            if (query_ready_o[q] &&
                (watch_kernel_pc(rob_ram[q_idx].pc) ||
                 (query_data_o[q] == '0) ||
                 (fast_alu_hit && (fast_alu_data == '0)))) begin
              $display(
                  "[rob-tag-query] q=%0d tag=%0d q_ready=%0d q_data=%h ram_ready=%0d ram_data=%h ram_valid=%0d ram_comp=%0d ram_pc=%h fast_alu_hit=%0d fast_alu_data=%h fast_bru_hit=%0d fast_bru_data=%h head=%0d tail=%0d cnt=%0d",
                  q, q_idx, query_ready_o[q], query_data_o[q], ram_ready, ram_data,
                  rob_ram[q_idx].valid, rob_ram[q_idx].complete, rob_ram[q_idx].pc,
                  fast_alu_hit, fast_alu_data, fast_bru_hit, fast_bru_data_i, head_ptr_q, tail_ptr_q,
                  count_q);
              trace_inc++;
            end
          end
        end
      end

      if (trace_inc != 0) begin
        rob_tag_trace_cnt_q <= rob_tag_trace_cnt_q + trace_inc[31:0];
      end
    end
  end

  always_ff @(posedge clk_i) begin

  end
`endif

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_ptr_q <= '0;
      tail_ptr_q <= '0;
      count_q    <= '0;
      for (int i = 0; i < ROB_DEPTH; i++) begin
        rob_ram[i].valid <= 1'b0;
      end
    end else if (flush_i || flush_o) begin
      head_ptr_q <= '0;
      tail_ptr_q <= '0;
      count_q    <= '0;
      for (int i = 0; i < ROB_DEPTH; i++) begin
        rob_ram[i].valid <= 1'b0;
      end
    end else begin
      head_ptr_q <= head_ptr_d;
      tail_ptr_q <= tail_ptr_d;
      count_q    <= count_d;

      // 1. Dispatch 写入
      if (rob_ready_o) begin
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
          if (dispatch_valid_i[i]) begin
            logic [PTR_WIDTH-1:0] w_idx;
            w_idx = tail_ptr_q + i[PTR_WIDTH-1:0];

            rob_ram[w_idx].valid       <= 1'b1;
            rob_ram[w_idx].complete    <= 1'b0;
            rob_ram[w_idx].exception   <= 1'b0;
            rob_ram[w_idx].is_mispred  <= 1'b0;
            rob_ram[w_idx].redirect_pc <= '0;
            rob_ram[w_idx].ecause      <= '0;
            rob_ram[w_idx].fu_type     <= dispatch_fu_type_i[i];
            rob_ram[w_idx].areg        <= dispatch_areg_i[i];
            rob_ram[w_idx].has_rd      <= dispatch_has_rd_i[i];
            rob_ram[w_idx].is_branch   <= dispatch_is_branch_i[i];
            rob_ram[w_idx].is_jump     <= dispatch_is_jump_i[i];
            rob_ram[w_idx].is_call     <= dispatch_is_call_i[i];
            rob_ram[w_idx].is_ret      <= dispatch_is_ret_i[i];
            rob_ram[w_idx].is_rvc      <= dispatch_is_rvc_i[i];
            rob_ram[w_idx].pred_npc    <= dispatch_pred_npc_i[i];
            rob_ram[w_idx].pc          <= dispatch_pc_i[i];
            rob_ram[w_idx].inst        <= dispatch_inst_i[i];
            rob_ram[w_idx].decoded_inst <= dispatch_decoded_inst_i[i];
            rob_ram[w_idx].ftq_id      <= dispatch_ftq_id_i[i];
            rob_ram[w_idx].fetch_epoch <= dispatch_fetch_epoch_i[i];

            // [新增] 保存 SB ID
            rob_ram[w_idx].is_store    <= dispatch_is_store_i[i];
            rob_ram[w_idx].sb_id       <= dispatch_sb_id_i[i];
          end
        end
      end

      // 2. Writeback 写入 (保持不变)
      for (int k = 0; k < WB_WIDTH; k++) begin
        if (wb_valid_i[k]) begin
          logic [PTR_WIDTH-1:0] wb_idx = wb_rob_index_i[k];
          rob_ram[wb_idx].complete    <= 1'b1;
          rob_ram[wb_idx].exception   <= wb_exception_i[k];
          rob_ram[wb_idx].ecause      <= wb_ecause_i[k];
          rob_ram[wb_idx].data        <= wb_data_i[k];
          rob_ram[wb_idx].is_mispred  <= wb_is_mispred_i[k];
          rob_ram[wb_idx].redirect_pc <= wb_redirect_pc_i[k];
        end
      end

      // 3. Commit 后清理已退休 entry，避免 query 命中旧代数据
      for (int i = 0; i < COMMIT_WIDTH; i++) begin
        if (commit_valid_o[i]) begin
          rob_ram[commit_rob_index_o[i]].valid <= 1'b0;
        end
      end
    end
  end

  // =========================================================
  // Phase 1 P0 assertions (simulation only, ASSERT=1)
  // =========================================================
`ifndef SYNTHESIS
  logic flush_prev_q;
  logic [COMMIT_WIDTH-1:0] commit_valid_prev_q;
  logic [COMMIT_WIDTH-1:0][PTR_WIDTH-1:0] commit_tag_prev_q;
  logic commit_cycle_flush_prev_q;

  // Combinational invariants (skip reset cycle)
  always_comb begin
    if (rst_ni) begin
      if (flush_i) begin
        `NPC_ASSERT(!( |commit_valid_o), "rob/commit_during_flush_i")
      end else if (async_exception_valid_i) begin
        `NPC_ASSERT(!( |commit_valid_o), "rob/commit_during_async_exc")
      end else if (sync_exception_valid_o) begin
        `NPC_ASSERT(!flush_o, "rob/sync_exc_with_flush_o")
      end else begin
        `NPC_ASSERT(count_q <= ROB_DEPTH, "rob/count_overflow")

        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
          if (dispatch_valid_i[i] && rob_ready_o) begin
            `NPC_ASSERT(!rob_ram[tail_ptr_q + PTR_WIDTH'(i)].valid,
                       "rob/dispatch_over_valid")
          end
        end

        for (int i = 1; i < COMMIT_WIDTH; i++) begin
          if (commit_valid_o[i]) begin
            `NPC_ASSERT(commit_valid_o[i-1], "rob/commit_not_prefix")
          end
        end

        for (int i = 0; i < COMMIT_WIDTH; i++) begin
          if (commit_valid_o[i]) begin
            `NPC_ASSERT(commit_rob_index_o[i] == (head_ptr_q + i[PTR_WIDTH-1:0]),
                       "rob/commit_index_mismatch")
          end
        end

        if (flush_o && flush_is_mispred_o) begin
          logic [COMMIT_WIDTH-1:0] mispred_commit_mask;
          mispred_commit_mask = '0;
          for (int i = 0; i < COMMIT_WIDTH; i++) begin
            if (commit_valid_o[i] && rob_ram[commit_rob_index_o[i]].is_mispred) begin
              mispred_commit_mask[i] = 1'b1;
            end
          end
          `NPC_ASSERT(|commit_valid_o, "rob/mispred_without_commit")
          `NPC_ASSERT($countones(mispred_commit_mask) == 1, "rob/mispred_commit_count")
        end

        for (int k = 0; k < WB_WIDTH; k++) begin
          if (wb_valid_i[k]) begin
            `NPC_ASSERT(rob_ram[wb_rob_index_i[k]].valid, "rob/wb_to_invalid")
          end
        end

        for (int k0 = 0; k0 < WB_WIDTH; k0++) begin
          for (int k1 = k0 + 1; k1 < WB_WIDTH; k1++) begin
            if (wb_valid_i[k0] && wb_valid_i[k1]) begin
              `NPC_ASSERT(wb_rob_index_i[k0] != wb_rob_index_i[k1], "rob/wb_duplicate_tag")
            end
          end
        end

        for (int i = 0; i < COMMIT_WIDTH; i++) begin
          if (commit_valid_o[i]) begin
            `NPC_ASSERT(head_fast_complete[i], "rob/commit_without_complete")
            `NPC_ASSERT(rob_ram[commit_rob_index_o[i]].valid, "rob/commit_invalid_entry")
            `NPC_ASSERT(!(commit_valid_o[i] && head_fast_exception[i]),
                       "rob/commit_with_fast_exception")
          end
          if (commit_we_o[i]) begin
            `NPC_ASSERT(commit_valid_o[i] &&
                       (rob_ram[commit_rob_index_o[i]].areg != 5'd0) &&
                       rob_ram[commit_rob_index_o[i]].has_rd,
                       "rob/commit_we_invalid")
          end
          if (commit_valid_o[i] && commit_is_store_o[i]) begin
            `NPC_ASSERT(commit_sb_id_o[i] == rob_ram[commit_rob_index_o[i]].sb_id,
                       "rob/commit_sb_id_mismatch")
          end
        end

        for (int a = 0; a < DISPATCH_WIDTH; a++) begin
          if (fast_alu_valid_i[a]) begin
            `NPC_ASSERT(rob_ram[fast_alu_rob_idx_i[a]].valid, "rob/fast_alu_invalid_entry")
          end
        end
        if (fast_bru_valid_i) begin
          `NPC_ASSERT(rob_ram[fast_bru_rob_idx_i].valid, "rob/fast_bru_invalid_entry")
        end

        for (int q = 0; q < QUERY_WIDTH; q++) begin
          logic query_fast_hit;
          query_fast_hit = 1'b0;
          for (int a = 0; a < DISPATCH_WIDTH; a++) begin
            if (fast_alu_valid_i[a] && (fast_alu_rob_idx_i[a] == query_rob_idx_i[q])) begin
              query_fast_hit = 1'b1;
            end
          end
          if (fast_bru_valid_i && fast_bru_can_commit_i &&
              (fast_bru_rob_idx_i == query_rob_idx_i[q])) begin
            query_fast_hit = 1'b1;
          end
          for (int p = 0; p < FAST_LSU_PORTS; p++) begin
            if (fast_lsu_valid_i[p] && !fast_lsu_exception_i[p] &&
                (fast_lsu_rob_idx_i[p] == query_rob_idx_i[q])) begin
              query_fast_hit = 1'b1;
            end
          end
          if (query_ready_o[q] && !query_fast_hit) begin
            `NPC_ASSERT(rob_ram[query_rob_idx_i[q]].valid &&
                        rob_ram[query_rob_idx_i[q]].complete,
                        "rob/query_ready_without_complete")
          end
        end
      end
    end
  end

  // R10-R11: sequential invariants
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      flush_prev_q             <= 1'b0;
      commit_valid_prev_q      <= '0;
      commit_tag_prev_q        <= '0;
      commit_cycle_flush_prev_q <= 1'b0;
    end else begin
      if (!flush_i && (|dispatch_valid_i)) begin
        `NPC_ASSERT(rob_ready_o, "rob/dispatch_while_full")
      end

      if (flush_prev_q) begin
        `NPC_ASSERT(count_q == 0, "rob/count_after_flush")
        for (int i = 0; i < ROB_DEPTH; i++) begin
          `NPC_ASSERT(!rob_ram[i].valid, "rob/valid_after_flush")
        end
      end

      if (!commit_cycle_flush_prev_q) begin
        for (int i = 0; i < COMMIT_WIDTH; i++) begin
          if (commit_valid_prev_q[i]) begin
            `NPC_ASSERT(!rob_ram[commit_tag_prev_q[i]].valid,
                       "rob/entry_invalid_after_commit")
          end
        end
      end

      flush_prev_q              <= flush_i || flush_o;
      commit_valid_prev_q       <= commit_valid_o;
      commit_tag_prev_q         <= commit_rob_index_o;
      commit_cycle_flush_prev_q <= flush_i || flush_o;
    end
  end
`endif

endmodule
