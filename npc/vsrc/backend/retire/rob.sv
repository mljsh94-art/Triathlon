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
    parameter int unsigned SB_DEPTH = 16,
    parameter int unsigned SB_IDX_WIDTH = $clog2(SB_DEPTH),
    parameter int unsigned MAX_COMMIT_BR = 1,
    parameter int unsigned MAX_COMMIT_ST = 1,
    parameter int unsigned MAX_COMMIT_LD = 2
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
  integer agent_rob_exc_log_fd;
  int unsigned agent_rob_exc_log_cnt;
  integer agent_rob_ctrl_log_fd;
  int unsigned agent_rob_ctrl_log_cnt;
  integer agent_late_head_log_fd;
  int unsigned agent_late_head_log_cnt;
  logic [PTR_WIDTH-1:0] agent_late_head_last_q;
  logic [$clog2(ROB_DEPTH+1)-1:0] agent_late_count_last_q;
  initial rob_trace_en_q = $test$plusargs("npc_diag_trace");
  initial rob_tag_trace_en_q = $test$plusargs("npc_diag_robtag");
  initial begin
    agent_rob_exc_log_fd = 0;
    agent_rob_exc_log_cnt = 0;
  end
  initial begin
    agent_rob_ctrl_log_fd = 0;
    agent_rob_ctrl_log_cnt = 0;
    agent_late_head_log_fd = 0;
    agent_late_head_log_cnt = 0;
    agent_late_head_last_q = '0;
    agent_late_count_last_q = '0;
  end

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

  always_comb begin
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      logic [PTR_WIDTH-1:0] idx;
      idx = head_ptr_q + i[PTR_WIDTH-1:0];
      head_fast_complete[i] = rob_ram[idx].complete;
      head_fast_data[i] = rob_ram[idx].data;
      head_fast_redirect_pc[i] = rob_ram[idx].redirect_pc;
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
            if (rob_ram[commit_rob_index_o[i]].exception) begin
              stop_commit   = 1'b1;
              // Precise sync exception is handled by CSR/trap path at commit head.
              sync_exception_valid_o = 1'b1;
              sync_exception_cause_o = rob_ram[commit_rob_index_o[i]].ecause;
              sync_exception_pc_o = rob_ram[commit_rob_index_o[i]].pc;
              sync_exception_tval_o = head_fast_data[i][Cfg.PLEN-1:0];
            end else if (rob_ram[commit_rob_index_o[i]].is_mispred) begin
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
    // #region agent log
    if (rst_ni && (agent_rob_exc_log_cnt < 128)) begin
      for (int k = 0; k < WB_WIDTH; k++) begin
        if (wb_valid_i[k] && wb_exception_i[k] &&
            ((wb_ecause_i[k] == 5'd13) || (wb_ecause_i[k] == 5'd15))) begin
          if (agent_rob_exc_log_fd == 0) begin
            agent_rob_exc_log_fd = $fopen("/mnt/e/vivado_project/OOOcpu_design/Triathlon/debug-e93a92.log", "a");
          end
          if (agent_rob_exc_log_fd != 0) begin
            $fdisplay(agent_rob_exc_log_fd,
                      "{\"sessionId\":\"e93a92\",\"runId\":\"rob-exception-trace\",\"hypothesisId\":\"H30,H31,H32,H33\",\"location\":\"rob.sv:exception-writeback\",\"message\":\"rob-exception-wb-state\",\"data\":{\"lane\":%0d,\"rob\":%0d,\"pc\":\"0x%08h\",\"valid\":%0d,\"complete\":%0d,\"oldException\":%0d,\"wbData\":\"0x%08h\",\"wbCause\":%0d,\"head\":%0d,\"tail\":%0d,\"count\":%0d,\"flushI\":%0d,\"flushO\":%0d,\"headPc\":\"0x%08h\"},\"timestamp\":0}",
                      k, wb_rob_index_i[k], rob_ram[wb_rob_index_i[k]].pc,
                      rob_ram[wb_rob_index_i[k]].valid, rob_ram[wb_rob_index_i[k]].complete,
                      rob_ram[wb_rob_index_i[k]].exception, wb_data_i[k], wb_ecause_i[k],
                      head_ptr_q, tail_ptr_q, count_q, flush_i, flush_o, rob_ram[head_ptr_q].pc);
            $fflush(agent_rob_exc_log_fd);
            agent_rob_exc_log_cnt <= agent_rob_exc_log_cnt + 1;
          end
        end
      end

      for (int i = 0; i < COMMIT_WIDTH; i++) begin
        logic [PTR_WIDTH-1:0] idx;
        idx = head_ptr_q + i[PTR_WIDTH-1:0];
        if ((count_q > i) && rob_ram[idx].complete && rob_ram[idx].exception &&
            ((rob_ram[idx].ecause == 5'd13) || (rob_ram[idx].ecause == 5'd15))) begin
          if (agent_rob_exc_log_fd == 0) begin
            agent_rob_exc_log_fd = $fopen("/mnt/e/vivado_project/OOOcpu_design/Triathlon/debug-e93a92.log", "a");
          end
          if (agent_rob_exc_log_fd != 0) begin
            $fdisplay(agent_rob_exc_log_fd,
                      "{\"sessionId\":\"e93a92\",\"runId\":\"rob-exception-trace\",\"hypothesisId\":\"H30,H31,H32,H33\",\"location\":\"rob.sv:exception-head\",\"message\":\"rob-exception-head-state\",\"data\":{\"slot\":%0d,\"rob\":%0d,\"pc\":\"0x%08h\",\"cause\":%0d,\"tval\":\"0x%08h\",\"head\":%0d,\"tail\":%0d,\"count\":%0d,\"stopCommit\":%0d,\"syncValid\":%0d,\"syncCause\":%0d,\"syncPc\":\"0x%08h\",\"syncTval\":\"0x%08h\",\"flushI\":%0d,\"flushO\":%0d},\"timestamp\":0}",
                      i, idx, rob_ram[idx].pc, rob_ram[idx].ecause, rob_ram[idx].data,
                      head_ptr_q, tail_ptr_q, count_q, stop_commit, sync_exception_valid_o,
                      sync_exception_cause_o, sync_exception_pc_o, sync_exception_tval_o,
                      flush_i, flush_o);
            $fflush(agent_rob_exc_log_fd);
            agent_rob_exc_log_cnt <= agent_rob_exc_log_cnt + 1;
          end
        end
      end
    end
    // #endregion agent log
  end

  always_ff @(posedge clk_i) begin
    // #region agent log
    if (rst_ni && (agent_late_head_log_cnt < 256) && (count_q != '0) &&
        (rob_ram[head_ptr_q].pc[31:28] == 4'hc) &&
        (flush_o || !head_fast_complete[0] || rob_ram[head_ptr_q].is_mispred ||
         rob_ram[head_ptr_q].exception || (count_q >= (ROB_DEPTH - COMMIT_WIDTH))) &&
        ((agent_late_head_log_cnt < 32) || flush_o ||
         (head_ptr_q != agent_late_head_last_q) || (count_q != agent_late_count_last_q))) begin
      automatic logic [PTR_WIDTH-1:0] idx0;
      automatic logic [PTR_WIDTH-1:0] idx1;
      automatic logic [PTR_WIDTH-1:0] idx2;
      automatic logic [PTR_WIDTH-1:0] idx3;
      idx0 = head_ptr_q;
      idx1 = head_ptr_q + PTR_WIDTH'(1);
      idx2 = head_ptr_q + PTR_WIDTH'(2);
      idx3 = head_ptr_q + PTR_WIDTH'(3);
      if (agent_late_head_log_fd == 0) begin
        agent_late_head_log_fd = $fopen("/mnt/e/vivado_project/OOOcpu_design/Triathlon/debug-61e984.log", "a");
      end
      if (agent_late_head_log_fd != 0) begin
        $fdisplay(agent_late_head_log_fd,
                  "{\"sessionId\":\"61e984\",\"runId\":\"late-fault-trace\",\"hypothesisId\":\"H60,H61,H62,H63\",\"location\":\"rob.sv:late-head\",\"message\":\"late-rob-head-state\",\"data\":{\"head\":%0d,\"tail\":%0d,\"count\":%0d,\"stopCommit\":%0d,\"flushI\":%0d,\"flushO\":%0d,\"flushPc\":\"0x%08h\",\"headFastComplete\":%0d,\"h0Pc\":\"0x%08h\",\"h0Valid\":%0d,\"h0Complete\":%0d,\"h0Fu\":%0d,\"h0Exception\":%0d,\"h0Cause\":%0d,\"h0Mispred\":%0d,\"h0Redirect\":\"0x%08h\",\"h1Pc\":\"0x%08h\",\"h1Valid\":%0d,\"h1Complete\":%0d,\"h1Fu\":%0d,\"h1Exception\":%0d,\"h1Mispred\":%0d,\"h2Pc\":\"0x%08h\",\"h2Valid\":%0d,\"h2Complete\":%0d,\"h2Fu\":%0d,\"h2Exception\":%0d,\"h2Mispred\":%0d,\"h3Pc\":\"0x%08h\",\"h3Valid\":%0d,\"h3Complete\":%0d,\"h3Fu\":%0d,\"h3Exception\":%0d,\"h3Mispred\":%0d},\"timestamp\":0}",
                  head_ptr_q, tail_ptr_q, count_q, stop_commit, flush_i, flush_o,
                  flush_pc_o, head_fast_complete[0],
                  rob_ram[idx0].pc, rob_ram[idx0].valid, rob_ram[idx0].complete,
                  rob_ram[idx0].fu_type, rob_ram[idx0].exception, rob_ram[idx0].ecause,
                  rob_ram[idx0].is_mispred, rob_ram[idx0].redirect_pc,
                  rob_ram[idx1].pc, rob_ram[idx1].valid, rob_ram[idx1].complete,
                  rob_ram[idx1].fu_type, rob_ram[idx1].exception, rob_ram[idx1].is_mispred,
                  rob_ram[idx2].pc, rob_ram[idx2].valid, rob_ram[idx2].complete,
                  rob_ram[idx2].fu_type, rob_ram[idx2].exception, rob_ram[idx2].is_mispred,
                  rob_ram[idx3].pc, rob_ram[idx3].valid, rob_ram[idx3].complete,
                  rob_ram[idx3].fu_type, rob_ram[idx3].exception, rob_ram[idx3].is_mispred);
        $fflush(agent_late_head_log_fd);
        agent_late_head_log_cnt <= agent_late_head_log_cnt + 1;
        agent_late_head_last_q <= head_ptr_q;
        agent_late_count_last_q <= count_q;
      end
    end
    // #endregion agent log
  end

  always_ff @(posedge clk_i) begin
    // #region agent log
    if (rst_ni && (agent_rob_ctrl_log_cnt < 160)) begin
      for (int k = 0; k < WB_WIDTH; k++) begin
        if (wb_valid_i[k] && wb_exception_i[k] &&
            ((wb_ecause_i[k] == 5'd13) || (wb_ecause_i[k] == 5'd15)) &&
            (agent_rob_ctrl_log_cnt < 160)) begin
          automatic int exc_slot;
          automatic int older_mispred_slot;
          automatic logic [PTR_WIDTH-1:0] older_mispred_idx;
          exc_slot = -1;
          older_mispred_slot = -1;
          older_mispred_idx = '0;
          for (int s = 0; s < ROB_DEPTH; s++) begin
            logic [PTR_WIDTH-1:0] scan_idx;
            scan_idx = head_ptr_q + PTR_WIDTH'(s);
            if ((s < count_q) && (scan_idx == wb_rob_index_i[k])) begin
              exc_slot = s;
            end
          end
          for (int s = 0; s < ROB_DEPTH; s++) begin
            logic [PTR_WIDTH-1:0] scan_idx;
            scan_idx = head_ptr_q + PTR_WIDTH'(s);
            if ((s < count_q) && (exc_slot >= 0) && (s < exc_slot) &&
                rob_ram[scan_idx].valid && rob_ram[scan_idx].complete &&
                rob_ram[scan_idx].is_mispred && (older_mispred_slot < 0)) begin
              older_mispred_slot = s;
              older_mispred_idx = scan_idx;
            end
          end
          // #region agent log
          if ((agent_rob_ctrl_log_cnt < 160) && rob_ram[wb_rob_index_i[k]].pc[31:24] == 8'hc0) begin
            if (agent_rob_ctrl_log_fd == 0) begin
              agent_rob_ctrl_log_fd = $fopen("/mnt/e/vivado_project/OOOcpu_design/Triathlon/debug-61e984.log", "a");
            end
            if (agent_rob_ctrl_log_fd != 0) begin
              $fdisplay(agent_rob_ctrl_log_fd,
                        "{\"sessionId\":\"61e984\",\"runId\":\"late-fault-trace\",\"hypothesisId\":\"H56,H57,H60\",\"location\":\"rob.sv:page-fault-writeback\",\"message\":\"late-rob-pagefault-wb-state\",\"data\":{\"lane\":%0d,\"rob\":%0d,\"pc\":\"0x%08h\",\"tval\":\"0x%08h\",\"cause\":%0d,\"excSlot\":%0d,\"olderMispred\":%0d,\"olderMispredSlot\":%0d,\"olderMispredRob\":%0d,\"olderMispredPc\":\"0x%08h\",\"olderRedirect\":\"0x%08h\",\"head\":%0d,\"tail\":%0d,\"count\":%0d,\"headPc\":\"0x%08h\",\"headComplete\":%0d,\"headException\":%0d,\"headCause\":%0d,\"flushI\":%0d,\"flushO\":%0d,\"flushPc\":\"0x%08h\"},\"timestamp\":0}",
                        k, wb_rob_index_i[k], rob_ram[wb_rob_index_i[k]].pc,
                        wb_data_i[k], wb_ecause_i[k], exc_slot, (older_mispred_slot >= 0),
                        older_mispred_slot, older_mispred_idx,
                        (older_mispred_slot >= 0) ? rob_ram[older_mispred_idx].pc : '0,
                        (older_mispred_slot >= 0) ? rob_ram[older_mispred_idx].redirect_pc : '0,
                        head_ptr_q, tail_ptr_q, count_q, rob_ram[head_ptr_q].pc,
                        head_fast_complete[0], rob_ram[head_ptr_q].exception,
                        rob_ram[head_ptr_q].ecause, flush_i, flush_o, flush_pc_o);
              $fflush(agent_rob_ctrl_log_fd);
              agent_rob_ctrl_log_cnt <= agent_rob_ctrl_log_cnt + 1;
            end
          end
          // #endregion agent log
        end
      end
    end
    // #endregion agent log
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

endmodule
