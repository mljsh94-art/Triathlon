// vsrc/backend/buffer/ibuffer.sv
module ibuffer #(
    parameter config_pkg::cfg_t Cfg          = config_pkg::EmptyCfg,
    // IBuffer 深度（存多少“单条指令”条目，而不是 fetch group 数）
    parameter int unsigned      IB_DEPTH     = 32,
    // 解码宽度（每拍给 decode 多少条）
    parameter int unsigned      DECODE_WIDTH = Cfg.INSTR_PER_FETCH
) (
    input logic clk_i,
    input logic rst_ni,

    // 来自 frontend（取指前端）的接口：fetch group
    input  logic                                         fe_valid_i,
    output logic                                         fe_ready_o,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] fe_instrs_i,
    input  logic [           Cfg.PLEN-1:0]               fe_pc_i,      // 该组第 0 条的 PC
    input  logic [Cfg.INSTR_PER_FETCH-1:0]               fe_slot_valid_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] fe_pred_npc_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] fe_ftq_id_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] fe_fetch_epoch_i,

    // 发往 decode 的接口：按 uop/指令粒度输出
    output logic                                  ibuf_valid_o,
    input  logic                                  ibuf_ready_i,
    output logic [DECODE_WIDTH-1:0][Cfg.ILEN-1:0] ibuf_instrs_o,
    output logic [DECODE_WIDTH-1:0][Cfg.ILEN-1:0] ibuf_raw_instrs_o,
    output logic [DECODE_WIDTH-1:0][Cfg.PLEN-1:0] ibuf_pcs_o,
    output logic [DECODE_WIDTH-1:0]               ibuf_slot_valid_o,
    output logic [DECODE_WIDTH-1:0][Cfg.PLEN-1:0] ibuf_pred_npc_o,
    output logic [DECODE_WIDTH-1:0]               ibuf_is_rvc_o,
    output logic [DECODE_WIDTH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ibuf_ftq_id_o,
    output logic [DECODE_WIDTH-1:0][2:0] ibuf_fetch_epoch_o,

    // flush：来自后端（比如 ROB 或 commit）
    input logic flush_i
);
  import global_config_pkg::ibuf_entry_t;
  localparam int unsigned FETCH_WIDTH = Cfg.INSTR_PER_FETCH;
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  localparam int unsigned FETCH_BYTES = FETCH_WIDTH * INSTR_BYTES;
  localparam int unsigned FE_EXPAND_MAX = FETCH_WIDTH * 2;
  localparam int unsigned PTR_W = $clog2(IB_DEPTH);
  localparam int unsigned CNT_W = $clog2(IB_DEPTH + 1);
  initial
    assert (IB_DEPTH > 0 && (IB_DEPTH & (IB_DEPTH - 1)) == 0)
    else $fatal(1, "IB_DEPTH must be a power of two.");

  // 存储单条指令的 FIFO
  ibuf_entry_t [IB_DEPTH-1:0] fifo_q;
  ibuf_entry_t [IB_DEPTH-1:0] fifo_d;

  logic [PTR_W-1:0] wr_ptr_q, wr_ptr_d;
  logic [PTR_W-1:0] rd_ptr_q, rd_ptr_d;
  logic [CNT_W-1:0] count_q, count_d;

  // 计算当前空间、输入有效条目数、可否接收
  logic [CNT_W-1:0] free_slots;
  logic [CNT_W-1:0] fe_valid_entry_count_w;
  assign free_slots = IB_DEPTH[CNT_W-1:0] - count_q;
  logic can_enq_group;
  assign can_enq_group = (free_slots >= fe_valid_entry_count_w);

  // 上游 ready：flush 时不接，空间不足时不接
  assign fe_ready_o = (!flush_i) && can_enq_group;

  logic [CNT_W-1:0] avail_count_w;
  logic [CNT_W-1:0] out_count_w;
  logic [CNT_W-1:0] pop_total_w;
  logic [CNT_W-1:0] pop_from_q_w;
  logic [CNT_W-1:0] consume_from_fe_w;
  logic [CNT_W-1:0] push_to_q_w;
  logic [CNT_W-1:0] fe_push_count_w;
  logic fe_fire_w;
  ibuf_entry_t [FE_EXPAND_MAX-1:0] fe_valid_entries_w;
  logic [FE_EXPAND_MAX-1:0][15:0] fe_hw_data_w;
  logic [FE_EXPAND_MAX-1:0][31:0] fe_hw_decoded_w;
  logic [FE_EXPAND_MAX-1:0][Cfg.PLEN-1:0] fe_hw_pc_w;
  logic [FE_EXPAND_MAX-1:0][15:0] fe_hw_slot_w;

  logic carry_valid_q;
  logic [15:0] carry_half_q;
  logic [Cfg.PLEN-1:0] carry_pc_q;
  logic carry_valid_next_w;
  logic [15:0] carry_half_next_w;
  logic [Cfg.PLEN-1:0] carry_pc_next_w;
`ifndef SYNTHESIS
  integer agent49_ibuf_log_fd;
  int unsigned agent49_ibuf_log_cnt;
  initial begin
    agent49_ibuf_log_fd = 0;
    agent49_ibuf_log_cnt = 0;
  end
`endif

  for (genvar i = 0; i < FE_EXPAND_MAX; i++) begin : gen_ibuf_rvc_dec
    compressed_decoder u_compressed_decoder (
        .instr_i({16'b0, fe_hw_data_w[i]}),
        .instr_o(fe_hw_decoded_w[i]),
        .is_compressed_o(),
        .is_illegal_o()
    );
  end

  assign fe_fire_w = fe_valid_i && fe_ready_o;
  assign fe_push_count_w = fe_fire_w ? fe_valid_entry_count_w : CNT_W'(0);
  assign avail_count_w = count_q + fe_push_count_w;
  assign out_count_w = (avail_count_w >= DECODE_WIDTH[CNT_W-1:0]) ? DECODE_WIDTH[CNT_W-1:0] : avail_count_w;
  assign ibuf_valid_o = (!flush_i) && (out_count_w != CNT_W'(0));
  assign pop_total_w = (ibuf_valid_o && ibuf_ready_i) ? out_count_w : CNT_W'(0);
  assign pop_from_q_w = (pop_total_w >= count_q) ? count_q : pop_total_w;
  assign consume_from_fe_w = pop_total_w - pop_from_q_w;
  assign push_to_q_w = fe_push_count_w - consume_from_fe_w;

  always_comb begin
    for (int i = 0; i < FE_EXPAND_MAX; i++) begin
      fe_hw_data_w[i] = '0;
      fe_hw_pc_w[i] = '0;
      fe_hw_slot_w[i] = '0;
    end
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      fe_hw_data_w[2*i] = fe_instrs_i[i][15:0];
      fe_hw_data_w[2*i+1] = fe_instrs_i[i][31:16];
      fe_hw_pc_w[2*i] = fe_pc_i + Cfg.PLEN'(INSTR_BYTES * i);
      fe_hw_pc_w[2*i+1] = fe_pc_i + Cfg.PLEN'(INSTR_BYTES * i + 2);
      fe_hw_slot_w[2*i] = 16'(i);
      fe_hw_slot_w[2*i+1] = 16'(i);
    end
  end

  // FE 输入按半字节流解析，支持 16/32 混合并展开为 32-bit 指令流。
  always_comb begin
    int unsigned wr_idx;
    int unsigned hw_count;
    int unsigned hw_idx;
    int unsigned slot_idx;
    logic use_halfword_path;
    logic [15:0] hw_data[FE_EXPAND_MAX-1:0];
    logic [Cfg.PLEN-1:0] hw_pc_arr[FE_EXPAND_MAX-1:0];
    logic [15:0] hw_slot_arr[FE_EXPAND_MAX-1:0];
    logic [7:0] hw_raw_idx_arr[FE_EXPAND_MAX-1:0];
    logic [15:0] half0;
    logic [15:0] half1;
    logic [31:0] instr32;
    logic [Cfg.PLEN-1:0] pc_cur;
    logic [Cfg.PLEN-1:0] pred_npc_slot;
    logic [Cfg.PLEN-1:0] fallthrough_npc;
    logic [Cfg.PLEN-1:0] slot_fallthrough_npc;
    logic is_low_half;
    logic stop_after_this;

    wr_idx = 0;
    hw_count = 0;
    hw_idx = 0;
    slot_idx = 0;
    use_halfword_path = carry_valid_q;
    half0 = '0;
    half1 = '0;
    instr32 = '0;
    pc_cur = '0;
    pred_npc_slot = '0;
    fallthrough_npc = '0;
    slot_fallthrough_npc = '0;
    is_low_half = 1'b0;
    stop_after_this = 1'b0;
    fe_valid_entry_count_w = '0;
    carry_valid_next_w = carry_valid_q;
    carry_half_next_w = carry_half_q;
    carry_pc_next_w = carry_pc_q;
    for (int i = 0; i < FE_EXPAND_MAX; i++) begin
      hw_data[i] = '0;
      hw_pc_arr[i] = '0;
      hw_slot_arr[i] = '0;
      hw_raw_idx_arr[i] = '0;
      fe_valid_entries_w[i].instr = '0;
      fe_valid_entries_w[i].raw_inst = '0;
      fe_valid_entries_w[i].pc = '0;
      fe_valid_entries_w[i].slot_valid = 1'b0;
      fe_valid_entries_w[i].pred_npc = '0;
      fe_valid_entries_w[i].is_rvc = 1'b0;
      fe_valid_entries_w[i].ftq_id = '0;
      fe_valid_entries_w[i].fetch_epoch = '0;
    end
    if (fe_valid_i) begin
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        if (fe_slot_valid_i[i]) begin
          if (fe_instrs_i[i][1:0] != 2'b11) begin
            use_halfword_path = 1'b1;
          end
          if (hw_count < FE_EXPAND_MAX) begin
            hw_data[hw_count] = fe_hw_data_w[2*i];
            hw_pc_arr[hw_count] = fe_hw_pc_w[2*i];
            hw_slot_arr[hw_count] = fe_hw_slot_w[2*i];
            hw_raw_idx_arr[hw_count] = 8'(2*i);
            hw_count++;
          end
          if (hw_count < FE_EXPAND_MAX) begin
            hw_data[hw_count] = fe_hw_data_w[2*i+1];
            hw_pc_arr[hw_count] = fe_hw_pc_w[2*i+1];
            hw_slot_arr[hw_count] = fe_hw_slot_w[2*i+1];
            hw_raw_idx_arr[hw_count] = 8'(2*i + 1);
            hw_count++;
          end
        end
      end

      if (!use_halfword_path) begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
          if (fe_slot_valid_i[i] && (wr_idx < FE_EXPAND_MAX)) begin
            fe_valid_entries_w[wr_idx].instr = fe_instrs_i[i];
            fe_valid_entries_w[wr_idx].raw_inst = fe_instrs_i[i];
            fe_valid_entries_w[wr_idx].pc = fe_pc_i + Cfg.PLEN'(INSTR_BYTES * i);
            fe_valid_entries_w[wr_idx].slot_valid = 1'b1;
            fe_valid_entries_w[wr_idx].pred_npc = fe_pred_npc_i[i];
            fe_valid_entries_w[wr_idx].is_rvc = 1'b0;
            fe_valid_entries_w[wr_idx].ftq_id = fe_ftq_id_i[i];
            fe_valid_entries_w[wr_idx].fetch_epoch = fe_fetch_epoch_i[i];
            wr_idx++;
          end
        end
        carry_valid_next_w = 1'b0;
        carry_half_next_w = '0;
        carry_pc_next_w = '0;
      end else begin
        if (carry_valid_q) begin
          if (hw_count >= 1) begin
            half1 = hw_data[0];
            instr32 = {half1, carry_half_q};
            fe_valid_entries_w[wr_idx].instr = instr32;
            fe_valid_entries_w[wr_idx].raw_inst = instr32;
            fe_valid_entries_w[wr_idx].pc = carry_pc_q;
            fe_valid_entries_w[wr_idx].slot_valid = 1'b1;
            fe_valid_entries_w[wr_idx].pred_npc = carry_pc_q + Cfg.PLEN'(4);
            fe_valid_entries_w[wr_idx].is_rvc = 1'b0;
            slot_idx = hw_slot_arr[0];
            fe_valid_entries_w[wr_idx].ftq_id = fe_ftq_id_i[slot_idx];
            fe_valid_entries_w[wr_idx].fetch_epoch = fe_fetch_epoch_i[slot_idx];
            wr_idx++;
            hw_idx = 1;
            carry_valid_next_w = 1'b0;
            carry_half_next_w = '0;
            carry_pc_next_w = '0;
          end
        end

        while ((hw_idx < hw_count) && (wr_idx < FE_EXPAND_MAX)) begin
          half0 = hw_data[hw_idx];
          pc_cur = hw_pc_arr[hw_idx];
          slot_idx = hw_slot_arr[hw_idx];
          pred_npc_slot = fe_pred_npc_i[slot_idx];
          is_low_half = !hw_raw_idx_arr[hw_idx][0];
          if (half0[1:0] != 2'b11) begin
            instr32 = fe_hw_decoded_w[hw_raw_idx_arr[hw_idx]];
            fallthrough_npc = pc_cur + Cfg.PLEN'(2);
            slot_fallthrough_npc = pc_cur + Cfg.PLEN'(INSTR_BYTES);
            // Legacy tests may drive per-slot pred_npc (+4) while IFU drives
            // per-halfword pred_npc (+2) for compressed slots. Treat both as
            // sequential and only stop on clearly non-sequential targets.
            stop_after_this =
                is_low_half && (pred_npc_slot != fallthrough_npc) &&
                (pred_npc_slot != slot_fallthrough_npc);
            fe_valid_entries_w[wr_idx].instr = instr32;
            fe_valid_entries_w[wr_idx].raw_inst = {16'b0, half0};
            fe_valid_entries_w[wr_idx].pc = pc_cur;
            fe_valid_entries_w[wr_idx].slot_valid = 1'b1;
            fe_valid_entries_w[wr_idx].pred_npc =
                (is_low_half && stop_after_this) ? pred_npc_slot : fallthrough_npc;
            fe_valid_entries_w[wr_idx].is_rvc = 1'b1;
            fe_valid_entries_w[wr_idx].ftq_id = fe_ftq_id_i[slot_idx];
            fe_valid_entries_w[wr_idx].fetch_epoch = fe_fetch_epoch_i[slot_idx];
            wr_idx++;
            hw_idx++;
            if (stop_after_this) begin
              // Predicted taken control in low halfword: drop following halfwords in this fetch group.
              hw_idx = hw_count;
              carry_valid_next_w = 1'b0;
              carry_half_next_w = '0;
              carry_pc_next_w = '0;
            end
          end else begin
            if (hw_idx + 1 < hw_count) begin
              half1 = hw_data[hw_idx + 1];
              instr32 = {half1, half0};
              fallthrough_npc = pc_cur + Cfg.PLEN'(4);
              stop_after_this = is_low_half && (pred_npc_slot != fallthrough_npc);
              fe_valid_entries_w[wr_idx].instr = instr32;
              fe_valid_entries_w[wr_idx].raw_inst = instr32;
              fe_valid_entries_w[wr_idx].pc = pc_cur;
              fe_valid_entries_w[wr_idx].slot_valid = 1'b1;
              fe_valid_entries_w[wr_idx].pred_npc = is_low_half ? pred_npc_slot : fallthrough_npc;
              fe_valid_entries_w[wr_idx].is_rvc = 1'b0;
              fe_valid_entries_w[wr_idx].ftq_id = fe_ftq_id_i[slot_idx];
              fe_valid_entries_w[wr_idx].fetch_epoch = fe_fetch_epoch_i[slot_idx];
              wr_idx++;
              hw_idx += 2;
              if (stop_after_this) begin
                // Predicted taken control in low halfword: drop following halfwords in this fetch group.
                hw_idx = hw_count;
                carry_valid_next_w = 1'b0;
                carry_half_next_w = '0;
                carry_pc_next_w = '0;
              end
            end else begin
              carry_valid_next_w = 1'b1;
              carry_half_next_w = half0;
              carry_pc_next_w = pc_cur;
              hw_idx = hw_count;
            end
          end
        end
      end
    end
    fe_valid_entry_count_w = CNT_W'(wr_idx);
  end

  // FIFO 控制逻辑
  always_comb begin
    fifo_d   = fifo_q;
    wr_ptr_d = wr_ptr_q;
    rd_ptr_d = rd_ptr_q;
    count_d  = count_q;

    if (flush_i) begin
      // flush：清空队列
      wr_ptr_d = '0;
      rd_ptr_d = '0;
      count_d  = '0;
    end else begin
      // 写入：仅写入未被当拍消费的 FE 有效条目
      if (push_to_q_w != CNT_W'(0)) begin : gen_enqueue
        for (int i = 0; i < FE_EXPAND_MAX; i++) begin
          if (CNT_W'(i) < push_to_q_w) begin
            fifo_d[PTR_W'(wr_ptr_q + PTR_W'(i))] =
                fe_valid_entries_w[consume_from_fe_w + CNT_W'(i)];
          end
        end

        wr_ptr_d = wr_ptr_q + PTR_W'(push_to_q_w);
      end : gen_enqueue

      if (pop_from_q_w != CNT_W'(0)) begin
        rd_ptr_d = rd_ptr_q + PTR_W'(pop_from_q_w);
      end

      count_d = count_q + push_to_q_w - pop_from_q_w;
    end
  end

  // 读出到下游（支持 partial bundle / elastic merge）
  always_comb begin
    for (int j = 0; j < DECODE_WIDTH; j++) begin
      logic [PTR_W-1:0] ridx;
      logic [CNT_W-1:0] fe_idx;
      ridx = '0;
      fe_idx = '0;
      ibuf_instrs_o[j] = '0;
      ibuf_raw_instrs_o[j] = '0;
      ibuf_pcs_o[j] = '0;
      ibuf_slot_valid_o[j] = 1'b0;
      ibuf_pred_npc_o[j] = '0;
      ibuf_is_rvc_o[j] = 1'b0;
      ibuf_ftq_id_o[j] = '0;
      ibuf_fetch_epoch_o[j] = '0;

      if (!flush_i && (CNT_W'(j) < out_count_w)) begin
        if (CNT_W'(j) < count_q) begin
          ridx = PTR_W'(rd_ptr_q + PTR_W'(j));
          ibuf_instrs_o[j] = fifo_q[ridx].instr;
          ibuf_raw_instrs_o[j] = fifo_q[ridx].raw_inst;
          ibuf_pcs_o[j] = fifo_q[ridx].pc;
          ibuf_slot_valid_o[j] = fifo_q[ridx].slot_valid;
          ibuf_pred_npc_o[j] = fifo_q[ridx].pred_npc;
          ibuf_is_rvc_o[j] = fifo_q[ridx].is_rvc;
          ibuf_ftq_id_o[j] = fifo_q[ridx].ftq_id;
          ibuf_fetch_epoch_o[j] = fifo_q[ridx].fetch_epoch;
        end else begin
          fe_idx = CNT_W'(j) - count_q;
          ibuf_instrs_o[j] = fe_valid_entries_w[fe_idx].instr;
          ibuf_raw_instrs_o[j] = fe_valid_entries_w[fe_idx].raw_inst;
          ibuf_pcs_o[j] = fe_valid_entries_w[fe_idx].pc;
          ibuf_slot_valid_o[j] = fe_valid_entries_w[fe_idx].slot_valid;
          ibuf_pred_npc_o[j] = fe_valid_entries_w[fe_idx].pred_npc;
          ibuf_is_rvc_o[j] = fe_valid_entries_w[fe_idx].is_rvc;
          ibuf_ftq_id_o[j] = fe_valid_entries_w[fe_idx].ftq_id;
          ibuf_fetch_epoch_o[j] = fe_valid_entries_w[fe_idx].fetch_epoch;
        end
      end
    end
  end

  // 寄存器更新
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr_q <= '0;
      rd_ptr_q <= '0;
      count_q  <= '0;
      carry_valid_q <= 1'b0;
      carry_half_q <= '0;
      carry_pc_q <= '0;
`ifndef SYNTHESIS
      agent49_ibuf_log_cnt <= 0;
`endif
    end else begin
      wr_ptr_q <= wr_ptr_d;
      rd_ptr_q <= rd_ptr_d;
      count_q  <= count_d;
      if (flush_i) begin
        carry_valid_q <= 1'b0;
        carry_half_q <= '0;
        carry_pc_q <= '0;
      end else if (fe_fire_w) begin
        carry_valid_q <= carry_valid_next_w;
        carry_half_q <= carry_half_next_w;
        carry_pc_q <= carry_pc_next_w;
      end
      // TODO: 优化为只写入被更新的那些位置
      fifo_q   <= fifo_d;
`ifndef SYNTHESIS
      // #region agent log
      if ((agent49_ibuf_log_cnt < 64) &&
          ((fe_fire_w && (fe_pc_i >= 32'hc0804e40) && (fe_pc_i <= 32'hc0804e80)) ||
           ((ibuf_valid_o && ibuf_ready_i) &&
            (((ibuf_pcs_o[0] >= 32'hc0804e40) && (ibuf_pcs_o[0] <= 32'hc0804e80)) ||
             ((ibuf_pcs_o[1] >= 32'hc0804e40) && (ibuf_pcs_o[1] <= 32'hc0804e80)) ||
             ((ibuf_pcs_o[2] >= 32'hc0804e40) && (ibuf_pcs_o[2] <= 32'hc0804e80)) ||
             ((ibuf_pcs_o[3] >= 32'hc0804e40) && (ibuf_pcs_o[3] <= 32'hc0804e80)))))) begin
        if (agent49_ibuf_log_fd == 0) begin
          agent49_ibuf_log_fd = $fopen("/mnt/e/vivado_project/OOOcpu_design/Triathlon/debug-49fa23.log", "a");
        end
        if (agent49_ibuf_log_fd != 0) begin
          $fdisplay(agent49_ibuf_log_fd,
                    "{\"sessionId\":\"49fa23\",\"runId\":\"illegal-halfword-pre\",\"hypothesisId\":\"H25,H26\",\"location\":\"ibuffer.sv:rvc-expand\",\"message\":\"misc-mem-init-ibuf-state\",\"data\":{\"feFire\":%0d,\"fePc\":\"0x%08h\",\"fe0\":\"0x%08h\",\"fe1\":\"0x%08h\",\"fe2\":\"0x%08h\",\"fe3\":\"0x%08h\",\"feSlotValid\":\"0x%0h\",\"entryCount\":%0d,\"carryValid\":%0d,\"carryHalf\":\"0x%04h\",\"e0Pc\":\"0x%08h\",\"e0Instr\":\"0x%08h\",\"e0Raw\":\"0x%08h\",\"e0Rvc\":%0d,\"e0Pred\":\"0x%08h\",\"e1Pc\":\"0x%08h\",\"e1Instr\":\"0x%08h\",\"e1Raw\":\"0x%08h\",\"e1Rvc\":%0d,\"e1Pred\":\"0x%08h\",\"e2Pc\":\"0x%08h\",\"e2Instr\":\"0x%08h\",\"e2Raw\":\"0x%08h\",\"e2Rvc\":%0d,\"e2Pred\":\"0x%08h\",\"e3Pc\":\"0x%08h\",\"e3Instr\":\"0x%08h\",\"e3Raw\":\"0x%08h\",\"e3Rvc\":%0d,\"e3Pred\":\"0x%08h\",\"out0Pc\":\"0x%08h\",\"out0Instr\":\"0x%08h\",\"out0Raw\":\"0x%08h\",\"out0Rvc\":%0d,\"out0Pred\":\"0x%08h\",\"out1Pc\":\"0x%08h\",\"out1Instr\":\"0x%08h\",\"out1Raw\":\"0x%08h\",\"out1Rvc\":%0d,\"out1Pred\":\"0x%08h\",\"out2Pc\":\"0x%08h\",\"out2Instr\":\"0x%08h\",\"out2Raw\":\"0x%08h\",\"out2Rvc\":%0d,\"out2Pred\":\"0x%08h\",\"out3Pc\":\"0x%08h\",\"out3Instr\":\"0x%08h\",\"out3Raw\":\"0x%08h\",\"out3Rvc\":%0d,\"out3Pred\":\"0x%08h\"},\"timestamp\":0}",
                    fe_fire_w, fe_pc_i, fe_instrs_i[0], fe_instrs_i[1], fe_instrs_i[2],
                    fe_instrs_i[3], fe_slot_valid_i, fe_valid_entry_count_w, carry_valid_q,
                    carry_half_q,
                    fe_valid_entries_w[0].pc, fe_valid_entries_w[0].instr,
                    fe_valid_entries_w[0].raw_inst, fe_valid_entries_w[0].is_rvc,
                    fe_valid_entries_w[0].pred_npc,
                    fe_valid_entries_w[1].pc, fe_valid_entries_w[1].instr,
                    fe_valid_entries_w[1].raw_inst, fe_valid_entries_w[1].is_rvc,
                    fe_valid_entries_w[1].pred_npc,
                    fe_valid_entries_w[2].pc, fe_valid_entries_w[2].instr,
                    fe_valid_entries_w[2].raw_inst, fe_valid_entries_w[2].is_rvc,
                    fe_valid_entries_w[2].pred_npc,
                    fe_valid_entries_w[3].pc, fe_valid_entries_w[3].instr,
                    fe_valid_entries_w[3].raw_inst, fe_valid_entries_w[3].is_rvc,
                    fe_valid_entries_w[3].pred_npc,
                    ibuf_pcs_o[0], ibuf_instrs_o[0], ibuf_raw_instrs_o[0],
                    ibuf_is_rvc_o[0], ibuf_pred_npc_o[0],
                    ibuf_pcs_o[1], ibuf_instrs_o[1], ibuf_raw_instrs_o[1],
                    ibuf_is_rvc_o[1], ibuf_pred_npc_o[1],
                    ibuf_pcs_o[2], ibuf_instrs_o[2], ibuf_raw_instrs_o[2],
                    ibuf_is_rvc_o[2], ibuf_pred_npc_o[2],
                    ibuf_pcs_o[3], ibuf_instrs_o[3], ibuf_raw_instrs_o[3],
                    ibuf_is_rvc_o[3], ibuf_pred_npc_o[3]);
          $fflush(agent49_ibuf_log_fd);
          agent49_ibuf_log_cnt <= agent49_ibuf_log_cnt + 1;
        end
      end
      // #endregion agent log
`endif
    end
  end

endmodule
