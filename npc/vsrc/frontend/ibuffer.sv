// vsrc/frontend/ibuffer.sv
// 纯 FIFO：接收 aligner 对齐条目，4-wide decode-ready 出队
module ibuffer #(
    parameter config_pkg::cfg_t Cfg          = config_pkg::EmptyCfg,
    parameter int unsigned      IB_DEPTH     = 32,
    parameter int unsigned      DECODE_WIDTH = Cfg.INSTR_PER_FETCH
) (
    input logic clk_i,
    input logic rst_ni,

    // 输入：aligner 对齐条目
    input  logic aln_valid_i,
    output logic aln_ready_o,
    input  global_config_pkg::ibuf_entry_t [global_config_pkg::FE_EXPAND_MAX-1:0] aln_entries_i,
    input  logic [$clog2(global_config_pkg::FE_EXPAND_MAX + 1)-1:0] aln_entry_count_i,

    // 输出：decode-ready 指令束
    output logic ibuf_valid_o,
    input  logic ibuf_ready_i,
    output logic [DECODE_WIDTH-1:0][Cfg.ILEN-1:0] ibuf_instrs_o,
    output logic [DECODE_WIDTH-1:0][Cfg.ILEN-1:0] ibuf_raw_instrs_o,
    output logic [DECODE_WIDTH-1:0][Cfg.PLEN-1:0] ibuf_pcs_o,
    output logic [DECODE_WIDTH-1:0] ibuf_slot_valid_o,
    output logic [DECODE_WIDTH-1:0][Cfg.PLEN-1:0] ibuf_pred_npc_o,
    output logic [DECODE_WIDTH-1:0] ibuf_is_rvc_o,
    output logic [DECODE_WIDTH-1:0][((Cfg.FTQ_DEPTH >= 2) ? $clog2(Cfg.FTQ_DEPTH) : 1)-1:0] ibuf_ftq_id_o,
    output logic [DECODE_WIDTH-1:0][global_config_pkg::PRED_GHR_W-1:0] ibuf_pred_ghr_o,
    output logic [DECODE_WIDTH-1:0][2:0] ibuf_fetch_epoch_o,

    input logic flush_i
);
  import global_config_pkg::ibuf_entry_t;
  import global_config_pkg::FE_EXPAND_MAX;

  localparam int unsigned PTR_W = $clog2(IB_DEPTH);
  localparam int unsigned CNT_W = $clog2(IB_DEPTH + 1);

  initial
    assert (IB_DEPTH > 0 && (IB_DEPTH & (IB_DEPTH - 1)) == 0)
    else $fatal(1, "IB_DEPTH must be a power of two.");

  ibuf_entry_t [IB_DEPTH-1:0] fifo_q;
  ibuf_entry_t [IB_DEPTH-1:0] fifo_d;

  logic [PTR_W-1:0] wr_ptr_q, wr_ptr_d;
  logic [PTR_W-1:0] rd_ptr_q, rd_ptr_d;
  logic [CNT_W-1:0] count_q, count_d;

  logic [CNT_W-1:0] free_slots;
  assign free_slots = IB_DEPTH[CNT_W-1:0] - count_q;

  logic can_enq_group;
  assign can_enq_group = (free_slots >= aln_entry_count_i);

  assign aln_ready_o = (!flush_i) && can_enq_group;

  logic [CNT_W-1:0] avail_count_w;
  logic [CNT_W-1:0] out_count_w;
  logic [CNT_W-1:0] pop_total_w;
  logic [CNT_W-1:0] pop_from_q_w;
  logic [CNT_W-1:0] consume_from_aln_w;
  logic [CNT_W-1:0] push_to_q_w;
  logic [CNT_W-1:0] aln_push_count_w;
  logic aln_fire_w;

  assign aln_fire_w = aln_valid_i && aln_ready_o;
  assign aln_push_count_w = aln_fire_w ? aln_entry_count_i : CNT_W'(0);
  assign avail_count_w = count_q + aln_push_count_w;
  assign out_count_w = (avail_count_w >= DECODE_WIDTH[CNT_W-1:0]) ? DECODE_WIDTH[CNT_W-1:0] : avail_count_w;
  assign ibuf_valid_o = (!flush_i) && (out_count_w != CNT_W'(0));
  assign pop_total_w = (ibuf_valid_o && ibuf_ready_i) ? out_count_w : CNT_W'(0);
  assign pop_from_q_w = (pop_total_w >= count_q) ? count_q : pop_total_w;
  assign consume_from_aln_w = pop_total_w - pop_from_q_w;
  assign push_to_q_w = aln_push_count_w - consume_from_aln_w;

  always_comb begin
    fifo_d   = fifo_q;
    wr_ptr_d = wr_ptr_q;
    rd_ptr_d = rd_ptr_q;
    count_d  = count_q;

    if (flush_i) begin
      wr_ptr_d = '0;
      rd_ptr_d = '0;
      count_d  = '0;
    end else begin
      if (push_to_q_w != CNT_W'(0)) begin : gen_enqueue
        for (int i = 0; i < FE_EXPAND_MAX; i++) begin
          if (CNT_W'(i) < push_to_q_w) begin
            fifo_d[PTR_W'(wr_ptr_q + PTR_W'(i))] =
                aln_entries_i[consume_from_aln_w + CNT_W'(i)];
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

  always_comb begin
    for (int j = 0; j < DECODE_WIDTH; j++) begin
      logic [PTR_W-1:0] ridx;
      logic [CNT_W-1:0] aln_idx;
      ridx = '0;
      aln_idx = '0;
      ibuf_instrs_o[j] = '0;
      ibuf_raw_instrs_o[j] = '0;
      ibuf_pcs_o[j] = '0;
      ibuf_slot_valid_o[j] = 1'b0;
      ibuf_pred_npc_o[j] = '0;
      ibuf_is_rvc_o[j] = 1'b0;
      ibuf_ftq_id_o[j] = '0;
      ibuf_fetch_epoch_o[j] = '0;
      ibuf_pred_ghr_o[j] = '0;

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
          ibuf_pred_ghr_o[j] = fifo_q[ridx].pred_ghr;
        end else begin
          aln_idx = CNT_W'(j) - count_q;
          ibuf_instrs_o[j] = aln_entries_i[aln_idx].instr;
          ibuf_raw_instrs_o[j] = aln_entries_i[aln_idx].raw_inst;
          ibuf_pcs_o[j] = aln_entries_i[aln_idx].pc;
          ibuf_slot_valid_o[j] = aln_entries_i[aln_idx].slot_valid;
          ibuf_pred_npc_o[j] = aln_entries_i[aln_idx].pred_npc;
          ibuf_is_rvc_o[j] = aln_entries_i[aln_idx].is_rvc;
          ibuf_ftq_id_o[j] = aln_entries_i[aln_idx].ftq_id;
          ibuf_fetch_epoch_o[j] = aln_entries_i[aln_idx].fetch_epoch;
          ibuf_pred_ghr_o[j] = aln_entries_i[aln_idx].pred_ghr;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr_q <= '0;
      rd_ptr_q <= '0;
      count_q  <= '0;
    end else begin
      wr_ptr_q <= wr_ptr_d;
      rd_ptr_q <= rd_ptr_d;
      count_q  <= count_d;
      fifo_q   <= fifo_d;
    end
  end

  // =========================================================
  // Phase 4 assertions (simulation only, ASSERT=1)
  // =========================================================
`ifndef SYNTHESIS
  always_comb begin
    if (!flush_i) begin
      `NPC_ASSERT(count_q <= IB_DEPTH, "ibuffer/count_overflow")
      `NPC_ASSERT(count_d <= IB_DEPTH, "ibuffer/count_next_overflow")

      if (ibuf_valid_o) begin
        for (int i = 1; i < DECODE_WIDTH; i++) begin
          if ((CNT_W'(i) < out_count_w) && ibuf_slot_valid_o[i]) begin
            `NPC_ASSERT(ibuf_slot_valid_o[i-1], "ibuffer/slot_valid_not_prefix")
          end
        end
      end
    end
  end
`endif

endmodule
