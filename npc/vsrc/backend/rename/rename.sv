// vsrc/backend/rename/rename.sv
import config_pkg::*;
import decode_pkg::*;

module rename #(
    parameter config_pkg::cfg_t Cfg           = config_pkg::EmptyCfg,
    parameter int unsigned      ROB_DEPTH     = 64,
    parameter int unsigned      ROB_IDX_WIDTH = $clog2(ROB_DEPTH),
    parameter int unsigned      SB_DEPTH      = 32,                    // STQ 深度
    parameter int unsigned      ST_IDX_WIDTH  = $clog2(SB_DEPTH)
) (
    input logic clk_i,
    input logic rst_ni,

    // --- From Decoder ---
    input logic [Cfg.INSTR_PER_FETCH-1:0] dec_valid_i,
    input decode_pkg::uop_t [Cfg.INSTR_PER_FETCH-1:0] dec_uops_i,
    output logic rename_ready_o,  // 告诉 Decoder 可以发指令

    // --- To ROB (Dispatch Interface) ---
    output logic            [Cfg.INSTR_PER_FETCH-1:0]               rob_dispatch_valid_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] rob_dispatch_pc_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] rob_dispatch_inst_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] rob_dispatch_decoded_inst_o,
    output decode_pkg::fu_e [Cfg.INSTR_PER_FETCH-1:0]               rob_dispatch_fu_type_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0][         4:0] rob_dispatch_areg_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0]               rob_dispatch_has_rd_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0]               rob_dispatch_is_branch_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0]               rob_dispatch_is_jump_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0]               rob_dispatch_is_call_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0]               rob_dispatch_is_ret_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0]               rob_dispatch_is_rvc_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] rob_dispatch_pred_npc_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0][decode_pkg::FTQ_ID_W-1:0] rob_dispatch_ftq_id_o,
    output logic            [Cfg.INSTR_PER_FETCH-1:0][decode_pkg::FETCH_EPOCH_W-1:0] rob_dispatch_fetch_epoch_o,

    // [新增] 傳遞 Store 信息給 ROB
    output logic [Cfg.INSTR_PER_FETCH-1:0]                   rob_dispatch_is_store_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][ST_IDX_WIDTH-1:0] rob_dispatch_st_id_o,

    // 輸入 ROB 的狀態
    input logic rob_ready_i,
    input logic [ROB_IDX_WIDTH-1:0] rob_tail_ptr_i,

    // --- To STQ (Allocation Interface) [新增] ---
    output logic [Cfg.INSTR_PER_FETCH-1:0] st_alloc_req_o,  // 請求分配 STQ Entry (每条store一项)
    input logic st_alloc_ready_i,  // STQ 是否可接受本周期所有请求
    input logic [Cfg.INSTR_PER_FETCH-1:0][ST_IDX_WIDTH-1:0] st_alloc_id_i,  // 每条store对应的 STQ ID

    // --- To Issue Queue / Operand Read Logic ---
    output logic [Cfg.INSTR_PER_FETCH-1:0] issue_valid_o,

    // 源操作數 1 信息
    output logic [Cfg.INSTR_PER_FETCH-1:0] issue_rs1_in_rob_o,  // 1: 在 ROB, 0: 在 ARF
    output logic [Cfg.INSTR_PER_FETCH-1:0][ROB_IDX_WIDTH-1:0] issue_rs1_rob_idx_o,  // 如果在 ROB，這是 Tag
    output logic [Cfg.INSTR_PER_FETCH-1:0][4:0] issue_rs1_idx_o,        // [關鍵新增] 如果在 ARF，這是邏輯寄存器號

    // 源操作數 2 信息
    output logic [Cfg.INSTR_PER_FETCH-1:0]                    issue_rs2_in_rob_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][ROB_IDX_WIDTH-1:0] issue_rs2_rob_idx_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][              4:0] issue_rs2_idx_o,      // [關鍵新增] 用於讀 ARF

    // 目標 Tag (分配給這條指令的 ROB ID)
    output logic [Cfg.INSTR_PER_FETCH-1:0][ROB_IDX_WIDTH-1:0] issue_rd_rob_idx_o,

    // --- From ROB Commit (用於更新 RAT 狀態) ---
    input logic [Cfg.INSTR_PER_FETCH-1:0] commit_we_i,
    input logic [Cfg.INSTR_PER_FETCH-1:0][4:0] commit_areg_i,
    input logic [Cfg.INSTR_PER_FETCH-1:0][ROB_IDX_WIDTH-1:0] commit_rob_idx_i,

    input logic flush_i
);
  localparam int unsigned DISPATCH_WIDTH = Cfg.INSTR_PER_FETCH;

  // ---------------------------------------------------------
  // 0. Store 檢測與 Flush 屏蔽
  // ---------------------------------------------------------
  logic [DISPATCH_WIDTH-1:0] dec_valid_masked;
  logic [DISPATCH_WIDTH-1:0] store_mask;
  logic has_store;

  always_comb begin
    has_store  = 1'b0;
    store_mask = '0;
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      // 如果發生 Flush，屏蔽當前週期的輸入，防止錯誤指令進入 ROB
      dec_valid_masked[i] = dec_valid_i[i] && !flush_i;

      // 檢查是否有有效的 Store 指令需要分配 STQ
      if (dec_valid_masked[i] && dec_uops_i[i].is_store) begin
        has_store = 1'b1;
        store_mask[i] = 1'b1;
      end
    end
  end

  // ---------------------------------------------------------
  // 1. Ready & Handshake Logic (支持 STQ 反壓)
  // ---------------------------------------------------------
  // 發射條件：ROB 未滿 AND (沒有 Store指令 OR StoreBuffer 有空位)
  // 注意：這裡簡化假設一週期只能處理 1 條 Store。如果 decode 發來多條 store，
  // st_alloc 接口需要支持多寬度分配，否則這裡需要更復雜的串行化邏輯。
  assign rename_ready_o = rob_ready_i && (!has_store || st_alloc_ready_i);

  // 向 STQ 發起分配請求（每条 store 一项）
  assign st_alloc_req_o = store_mask;

  // ---------------------------------------------------------
  // 2. 生成新的 Tags (ROB ID 作為物理寄存器號)
  // ---------------------------------------------------------
  logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] new_tags;
  logic [DISPATCH_WIDTH-1:0] alloc_req;  // 是否寫寄存器 (需要更新 RAT)

  always_comb begin
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      // Tag = ROB Tail + Offset
      new_tags[i]  = (rob_tail_ptr_i + i) % ROB_DEPTH;

      // 只有寫有效寄存器 (rd != 0) 才更新 RAT
      alloc_req[i] = rename_ready_o && dec_valid_masked[i] && dec_uops_i[i].has_rd &&
                     (dec_uops_i[i].rd != 0);
    end
  end

  // ---------------------------------------------------------
  // 3. RAT 讀寫 (查表 + 更新)
  // ---------------------------------------------------------
  logic [DISPATCH_WIDTH-1:0] rat_rs1_in_rob, rat_rs2_in_rob;
  logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] rat_rs1_tag, rat_rs2_tag;

  // 輔助函數提取端口信號
  logic [DISPATCH_WIDTH-1:0][4:0] rs1_indices, rs2_indices, rd_indices;
  assign rs1_indices = get_rs1_indices(dec_uops_i);
  assign rs2_indices = get_rs2_indices(dec_uops_i);
  assign rd_indices  = get_rd_indices(dec_uops_i);

  rat #(
      .ROB_DEPTH(ROB_DEPTH),
      .DISPATCH_WIDTH(DISPATCH_WIDTH)
  ) u_rat (
      .clk_i,
      .rst_ni,
      // 讀端口
      .rs1_idx_i(rs1_indices),
      .rs2_idx_i(rs2_indices),
      .rs1_in_rob_o(rat_rs1_in_rob),
      .rs1_rob_idx_o(rat_rs1_tag),
      .rs2_in_rob_o(rat_rs2_in_rob),
      .rs2_rob_idx_o(rat_rs2_tag),

      // 寫端口 (Allocation)
      .disp_we_i(alloc_req),
      .disp_rd_idx_i(rd_indices),
      .disp_rob_idx_i(new_tags),

      // 提交端口 (Retirement)
      .commit_we_i(commit_we_i),
      .commit_rd_idx_i(commit_areg_i),
      .commit_rob_idx_i(commit_rob_idx_i),

      .flush_i(flush_i)
  );

  // ---------------------------------------------------------
  // 4. 組內依賴檢查 (Intra-group Dependency Check)
  // ---------------------------------------------------------
  // 處理同一週期發射的 4 條指令之間的 RAW 依賴
  logic [DISPATCH_WIDTH-1:0] final_rs1_in_rob, final_rs2_in_rob;
  logic [DISPATCH_WIDTH-1:0][ROB_IDX_WIDTH-1:0] final_rs1_tag, final_rs2_tag;

  always_comb begin
    // 默認來自 RAT 查找結果
    final_rs1_in_rob = rat_rs1_in_rob;
    final_rs1_tag    = rat_rs1_tag;
    final_rs2_in_rob = rat_rs2_in_rob;
    final_rs2_tag    = rat_rs2_tag;

    // 檢查前面的指令是否寫了我的源寄存器
    for (int i = 1; i < DISPATCH_WIDTH; i++) begin
      for (int j = 0; j < i; j++) begin
        // Check RS1
        if (alloc_req[j] && dec_uops_i[i].has_rs1 && (rs1_indices[i] == rd_indices[j])) begin
          final_rs1_in_rob[i] = 1'b1;  // 依賴於指令 j，數據肯定在 ROB
          final_rs1_tag[i]    = new_tags[j];  // 使用指令 j 分配到的 ROB ID
        end
        // Check RS2
        if (alloc_req[j] && dec_uops_i[i].has_rs2 && (rs2_indices[i] == rd_indices[j])) begin
          final_rs2_in_rob[i] = 1'b1;
          final_rs2_tag[i]    = new_tags[j];
        end
      end
    end
  end

  // ---------------------------------------------------------
  // 5. 輸出打包
  // ---------------------------------------------------------
  always_comb begin
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (rename_ready_o && dec_valid_masked[i]) begin
        // --- To ROB ---
        rob_dispatch_valid_o[i]    = 1'b1;
        rob_dispatch_pc_o[i]       = dec_uops_i[i].pc;
        rob_dispatch_inst_o[i]     = dec_uops_i[i].raw_inst;
        rob_dispatch_decoded_inst_o[i] = dec_uops_i[i].inst;
        rob_dispatch_fu_type_o[i]  = dec_uops_i[i].fu;
        rob_dispatch_areg_o[i]     = dec_uops_i[i].rd;
        rob_dispatch_has_rd_o[i]   = dec_uops_i[i].has_rd;
        rob_dispatch_is_branch_o[i] = dec_uops_i[i].is_branch;
        rob_dispatch_is_jump_o[i] = dec_uops_i[i].is_jump;
        rob_dispatch_is_call_o[i] = dec_uops_i[i].is_jump &&
            ((dec_uops_i[i].rd == 5'd1) || (dec_uops_i[i].rd == 5'd5));
        rob_dispatch_is_ret_o[i] = (dec_uops_i[i].br_op == decode_pkg::BR_JALR) &&
            (dec_uops_i[i].rd == 5'd0) &&
            ((dec_uops_i[i].rs1 == 5'd1) || (dec_uops_i[i].rs1 == 5'd5)) &&
            (dec_uops_i[i].imm == Cfg.XLEN'(0));
        rob_dispatch_is_rvc_o[i] = dec_uops_i[i].is_rvc;
        rob_dispatch_pred_npc_o[i] = dec_uops_i[i].pred_npc;
        rob_dispatch_ftq_id_o[i] = dec_uops_i[i].ftq_id;
        rob_dispatch_fetch_epoch_o[i] = dec_uops_i[i].fetch_epoch;

        // Store 信息傳遞
        rob_dispatch_is_store_o[i] = dec_uops_i[i].is_store;
        // 如果是 Store，攜帶分配到的 STQ ID；否則為 0
        if (dec_uops_i[i].is_store) begin
          rob_dispatch_st_id_o[i] = st_alloc_id_i[i];
        end else begin
          rob_dispatch_st_id_o[i] = '0;
        end

        // --- To Issue Queue / Backend Top ---
        issue_valid_o[i]       = 1'b1;

        // RS1
        issue_rs1_in_rob_o[i]  = final_rs1_in_rob[i];
        issue_rs1_rob_idx_o[i] = final_rs1_tag[i];
        issue_rs1_idx_o[i]     = rs1_indices[i];  // [新增] 用於讀 ARF

        // RS2
        issue_rs2_in_rob_o[i]  = final_rs2_in_rob[i];
        issue_rs2_rob_idx_o[i] = final_rs2_tag[i];
        issue_rs2_idx_o[i]     = rs2_indices[i];  // [新增] 用於讀 ARF

        // RD (Destination Tag)
        issue_rd_rob_idx_o[i]  = new_tags[i];

      end else begin
        // 氣泡 / 阻塞狀態清零
        rob_dispatch_valid_o[i]    = 0;
        rob_dispatch_pc_o[i]       = '0;
        rob_dispatch_inst_o[i]     = '0;
        rob_dispatch_decoded_inst_o[i] = '0;
        rob_dispatch_fu_type_o[i]  = decode_pkg::FU_NONE;
        rob_dispatch_areg_o[i]     = '0;
        rob_dispatch_has_rd_o[i]   = 1'b0;
        rob_dispatch_is_branch_o[i] = 1'b0;
        rob_dispatch_is_jump_o[i] = 1'b0;
        rob_dispatch_is_call_o[i] = 1'b0;
        rob_dispatch_is_ret_o[i] = 1'b0;
        rob_dispatch_is_rvc_o[i] = 1'b0;
        rob_dispatch_pred_npc_o[i] = '0;
        rob_dispatch_ftq_id_o[i] = '0;
        rob_dispatch_fetch_epoch_o[i] = '0;
        rob_dispatch_is_store_o[i] = 1'b0;
        rob_dispatch_st_id_o[i]    = '0;

        issue_valid_o[i]           = 0;
        issue_rs1_in_rob_o[i]      = 0;
        issue_rs1_rob_idx_o[i]     = '0;
        issue_rs1_idx_o[i]         = '0;

        issue_rs2_in_rob_o[i]      = 0;
        issue_rs2_rob_idx_o[i]     = '0;
        issue_rs2_idx_o[i]         = '0;

        issue_rd_rob_idx_o[i]      = '0;
      end
    end
  end

  // ---------------------------------------------------------
  // 輔助函數 (用於切片結構體數組)
  // ---------------------------------------------------------
  function automatic logic [DISPATCH_WIDTH-1:0][4:0] get_rs1_indices(
      decode_pkg::uop_t [DISPATCH_WIDTH-1:0] uops);
    for (int k = 0; k < DISPATCH_WIDTH; k++) get_rs1_indices[k] = uops[k].rs1;
  endfunction
  function automatic logic [DISPATCH_WIDTH-1:0][4:0] get_rs2_indices(
      decode_pkg::uop_t [DISPATCH_WIDTH-1:0] uops);
    for (int k = 0; k < DISPATCH_WIDTH; k++) get_rs2_indices[k] = uops[k].rs2;
  endfunction
  function automatic logic [DISPATCH_WIDTH-1:0][4:0] get_rd_indices(
      decode_pkg::uop_t [DISPATCH_WIDTH-1:0] uops);
    for (int k = 0; k < DISPATCH_WIDTH; k++) get_rd_indices[k] = uops[k].rd;
  endfunction

endmodule
