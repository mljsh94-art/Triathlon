// vsrc/frontend/instr_aligner.sv
// RVC 半字展开：IFU fetch group → ≤FE_EXPAND_MAX 条对齐 ibuf_entry_t
module instr_aligner #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // 输入：IFU fetch group
    input  logic fe_valid_i,
    output logic fe_ready_o,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] fe_instrs_i,
    input  logic [Cfg.PLEN-1:0] fe_pc_i,
    // 预测元数据按半字粒度（PRED_SLOT_COUNT）传入
    input  logic [global_config_pkg::PRED_SLOT_COUNT-1:0] fe_slot_valid_i,
    input  logic [global_config_pkg::PRED_SLOT_COUNT-1:0][Cfg.PLEN-1:0] fe_pred_npc_i,
    input  logic [global_config_pkg::PRED_SLOT_COUNT-1:0] fe_pred_taken_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.FTQ_DEPTH >= 2) ? $clog2(Cfg.FTQ_DEPTH) : 1)-1:0] fe_ftq_id_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] fe_fetch_epoch_i,
    input  logic ibuf_aln_ready_i,

    // 输出：对齐条目
    output logic [$clog2(global_config_pkg::FE_EXPAND_MAX + 1)-1:0] aln_entry_count_o,
    output global_config_pkg::ibuf_entry_t [global_config_pkg::FE_EXPAND_MAX-1:0] aln_entries_o
);
  import global_config_pkg::ibuf_entry_t;
  import global_config_pkg::FE_EXPAND_MAX;
  import global_config_pkg::PRED_SLOT_COUNT;

  localparam int unsigned FETCH_WIDTH = Cfg.INSTR_PER_FETCH;
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;
  localparam int unsigned CNT_W = $clog2(FE_EXPAND_MAX + 1);

  logic [CNT_W-1:0] entry_count_w;
  ibuf_entry_t [FE_EXPAND_MAX-1:0] entries_w;

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

  logic fe_fire_w;
  assign fe_fire_w = fe_valid_i && fe_ready_o;

  for (genvar i = 0; i < FE_EXPAND_MAX; i++) begin : gen_aln_rvc_dec
    compressed_decoder u_compressed_decoder (
        .instr_i({16'b0, fe_hw_data_w[i]}),
        .instr_o(fe_hw_decoded_w[i]),
        .is_compressed_o(),
        .is_illegal_o()
    );
  end

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

  always_comb begin
    int unsigned wr_idx;
    int unsigned hw_count;
    int unsigned hw_idx;
    int unsigned word_idx;
    int unsigned raw_idx;
    int unsigned raw_end;
    logic [15:0] hw_data[FE_EXPAND_MAX-1:0];
    logic [Cfg.PLEN-1:0] hw_pc_arr[FE_EXPAND_MAX-1:0];
    logic [15:0] hw_word_idx_arr[FE_EXPAND_MAX-1:0];
    logic [7:0] hw_raw_idx_arr[FE_EXPAND_MAX-1:0];
    logic [15:0] half0;
    logic [15:0] half1;
    logic [31:0] instr32;
    logic [Cfg.PLEN-1:0] pc_cur;
    logic taken_here;

    wr_idx = 0;
    hw_count = 0;
    hw_idx = 0;
    word_idx = 0;
    raw_idx = 0;
    raw_end = 0;
    half0 = '0;
    half1 = '0;
    instr32 = '0;
    pc_cur = '0;
    taken_here = 1'b0;
    carry_valid_next_w = carry_valid_q;
    carry_half_next_w = carry_half_q;
    carry_pc_next_w = carry_pc_q;
    for (int i = 0; i < FE_EXPAND_MAX; i++) begin
      hw_data[i] = '0;
      hw_pc_arr[i] = '0;
      hw_word_idx_arr[i] = '0;
      hw_raw_idx_arr[i] = '0;
      entries_w[i].instr = '0;
      entries_w[i].raw_inst = '0;
      entries_w[i].pc = '0;
      entries_w[i].slot_valid = 1'b0;
      entries_w[i].pred_npc = '0;
      entries_w[i].is_rvc = 1'b0;
      entries_w[i].ftq_id = '0;
      entries_w[i].fetch_epoch = '0;
    end
    if (fe_valid_i) begin
      // 半字收集：按 half-word slot_valid（h<=pred_slot_idx）挑选有效半字进入展开流。
      for (int h = 0; h < PRED_SLOT_COUNT; h++) begin
        if (fe_slot_valid_i[h] && (hw_count < FE_EXPAND_MAX)) begin
          hw_data[hw_count] = fe_hw_data_w[h];
          hw_pc_arr[hw_count] = fe_hw_pc_w[h];
          hw_word_idx_arr[hw_count] = fe_hw_slot_w[h];
          hw_raw_idx_arr[hw_count] = 8'(h);
          hw_count++;
        end
      end

      // 跨 group 的 32-bit carry 指令：低半字来自上一拍，当前 slot0 是高半字。
      // 若 BPU 对 pc-2 的分支命中，预测元数据标在当前 slot0。
      if (carry_valid_q && (hw_count >= 1)) begin
        half1 = hw_data[0];
        instr32 = {half1, carry_half_q};
        word_idx = hw_word_idx_arr[0];
        raw_idx = hw_raw_idx_arr[0];
        taken_here = fe_pred_taken_i[raw_idx];
        entries_w[wr_idx].instr = instr32;
        entries_w[wr_idx].raw_inst = instr32;
        entries_w[wr_idx].pc = carry_pc_q;
        entries_w[wr_idx].slot_valid = 1'b1;
        entries_w[wr_idx].pred_npc =
            taken_here ? fe_pred_npc_i[raw_idx] : (carry_pc_q + Cfg.PLEN'(4));
        entries_w[wr_idx].is_rvc = 1'b0;
        entries_w[wr_idx].ftq_id = fe_ftq_id_i[word_idx];
        entries_w[wr_idx].fetch_epoch = fe_fetch_epoch_i[word_idx];
        wr_idx++;
        hw_idx = 1;
        carry_valid_next_w = 1'b0;
        carry_half_next_w = '0;
        carry_pc_next_w = '0;
      end

      while ((hw_idx < hw_count) && (wr_idx < FE_EXPAND_MAX)) begin
        half0 = hw_data[hw_idx];
        pc_cur = hw_pc_arr[hw_idx];
        word_idx = hw_word_idx_arr[hw_idx];
        raw_idx = hw_raw_idx_arr[hw_idx];
        if (half0[1:0] != 2'b11) begin
          // RVC：末半字即自身。
          raw_end = raw_idx;
          taken_here = fe_pred_taken_i[raw_end];
          instr32 = fe_hw_decoded_w[raw_idx];
          entries_w[wr_idx].instr = instr32;
          entries_w[wr_idx].raw_inst = {16'b0, half0};
          entries_w[wr_idx].pc = pc_cur;
          entries_w[wr_idx].slot_valid = 1'b1;
          entries_w[wr_idx].pred_npc =
              taken_here ? fe_pred_npc_i[raw_end] : (pc_cur + Cfg.PLEN'(2));
          entries_w[wr_idx].is_rvc = 1'b1;
          entries_w[wr_idx].ftq_id = fe_ftq_id_i[word_idx];
          entries_w[wr_idx].fetch_epoch = fe_fetch_epoch_i[word_idx];
          wr_idx++;
          hw_idx++;
          if (taken_here) begin
            hw_idx = hw_count;
            carry_valid_next_w = 1'b0;
            carry_half_next_w = '0;
            carry_pc_next_w = '0;
          end
        end else begin
          if (hw_idx + 1 < hw_count) begin
            // 32-bit：末半字为高半字，pred_taken 标在高半字（末半字约定）。
            half1 = hw_data[hw_idx + 1];
            raw_end = hw_raw_idx_arr[hw_idx + 1];
            taken_here = fe_pred_taken_i[raw_end];
            instr32 = {half1, half0};
            entries_w[wr_idx].instr = instr32;
            entries_w[wr_idx].raw_inst = instr32;
            entries_w[wr_idx].pc = pc_cur;
            entries_w[wr_idx].slot_valid = 1'b1;
            entries_w[wr_idx].pred_npc =
                taken_here ? fe_pred_npc_i[raw_end] : (pc_cur + Cfg.PLEN'(4));
            entries_w[wr_idx].is_rvc = 1'b0;
            entries_w[wr_idx].ftq_id = fe_ftq_id_i[word_idx];
            entries_w[wr_idx].fetch_epoch = fe_fetch_epoch_i[word_idx];
            wr_idx++;
            hw_idx += 2;
            if (taken_here) begin
              hw_idx = hw_count;
              carry_valid_next_w = 1'b0;
              carry_half_next_w = '0;
              carry_pc_next_w = '0;
            end
          end else begin
            // 32-bit 指令尾半字落在 group 边界 → carry 到下一拍。
            carry_valid_next_w = 1'b1;
            carry_half_next_w = half0;
            carry_pc_next_w = pc_cur;
            hw_idx = hw_count;
          end
        end
      end
    end
    entry_count_w = CNT_W'(wr_idx);
  end

  assign aln_entry_count_o = entry_count_w;
  assign aln_entries_o = entries_w;
  assign fe_ready_o = (!flush_i) && ibuf_aln_ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      carry_valid_q <= 1'b0;
      carry_half_q <= '0;
      carry_pc_q <= '0;
    end else begin
      if (flush_i) begin
        carry_valid_q <= 1'b0;
        carry_half_q <= '0;
        carry_pc_q <= '0;
      end else if (fe_fire_w) begin
        carry_valid_q <= carry_valid_next_w;
        carry_half_q <= carry_half_next_w;
        carry_pc_q <= carry_pc_next_w;
      end
    end
  end

endmodule
