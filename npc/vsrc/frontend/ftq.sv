import config_pkg::*;
import global_config_pkg::PRED_SLOT_IDX_W;
import global_config_pkg::PRED_GHR_W;

module ftq #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned DEPTH = (Cfg.FTQ_DEPTH >= 2) ? Cfg.FTQ_DEPTH : 2,
    parameter int unsigned EPOCH_W = 3
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input  logic enq_valid_i,
    output logic enq_ready_o,
    input  logic [Cfg.PLEN-1:0] enq_pc_i,
  input  logic enq_pred_slot_valid_i,
  input  logic [PRED_SLOT_IDX_W-1:0] enq_pred_slot_idx_i,
  input  logic [Cfg.PLEN-1:0] enq_pred_target_i,
    input  logic [Cfg.PLEN-1:0] enq_pred_npc_i,
    input  logic [PRED_GHR_W-1:0] enq_pred_ghr_i,
    input  logic [EPOCH_W-1:0] enq_epoch_i,
    output logic [ID_W-1:0] enq_ftq_id_o,

    output logic deq_valid_o,
    input  logic deq_ready_i,
    output logic [Cfg.PLEN-1:0] deq_pc_o,
  output logic deq_pred_slot_valid_o,
  output logic [PRED_SLOT_IDX_W-1:0] deq_pred_slot_idx_o,
  output logic [Cfg.PLEN-1:0] deq_pred_target_o,
    output logic [Cfg.PLEN-1:0] deq_pred_npc_o,
    output logic [PRED_GHR_W-1:0] deq_pred_ghr_o,
    output logic [EPOCH_W-1:0] deq_epoch_o,
    output logic [((DEPTH > 1) ? $clog2(DEPTH) : 1)-1:0] deq_ftq_id_o,

    output logic [((DEPTH > 1) ? $clog2(DEPTH + 1) : 1)-1:0] count_o
);

  localparam int unsigned ID_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int unsigned SLOT_IDX_W = PRED_SLOT_IDX_W;
  localparam int unsigned CNT_W = (DEPTH > 1) ? $clog2(DEPTH + 1) : 1;

  logic [ID_W-1:0] head_q;
  logic [ID_W-1:0] tail_q;
  logic [CNT_W-1:0] count_q;
  logic [DEPTH-1:0][Cfg.PLEN-1:0] pc_q;
  logic [DEPTH-1:0] pred_slot_valid_q;
  logic [DEPTH-1:0][SLOT_IDX_W-1:0] pred_slot_idx_q;
  logic [DEPTH-1:0][Cfg.PLEN-1:0] pred_target_q;
  logic [DEPTH-1:0][Cfg.PLEN-1:0] pred_npc_q;
  logic [DEPTH-1:0][PRED_GHR_W-1:0] pred_ghr_q;
  logic [DEPTH-1:0][EPOCH_W-1:0] epoch_q;

  logic enq_fire_w;
  logic deq_fire_w;
  logic fifo_full_w;
  logic fifo_empty_w;

  function automatic [ID_W-1:0] ptr_inc(input [ID_W-1:0] ptr);
    if (ptr == ID_W'(DEPTH - 1)) begin
      ptr_inc = '0;
    end else begin
      ptr_inc = ptr + ID_W'(1);
    end
  endfunction

  assign fifo_empty_w = (count_q == CNT_W'(0));
  assign fifo_full_w  = (count_q == CNT_W'(DEPTH));
  assign enq_ready_o  = !flush_i && !fifo_full_w;
  assign deq_valid_o  = !flush_i && !fifo_empty_w;
  assign enq_fire_w   = enq_valid_i && enq_ready_o;
  assign deq_fire_w   = deq_valid_o && deq_ready_i;

  assign enq_ftq_id_o = tail_q;
  assign deq_pc_o = pc_q[head_q];
  assign deq_pred_slot_valid_o = pred_slot_valid_q[head_q];
  assign deq_pred_slot_idx_o = pred_slot_idx_q[head_q];
  assign deq_pred_target_o = pred_target_q[head_q];
  assign deq_pred_npc_o = pred_npc_q[head_q];
  assign deq_pred_ghr_o = pred_ghr_q[head_q];
  assign deq_epoch_o = epoch_q[head_q];
  assign deq_ftq_id_o = head_q;
  assign count_o = count_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      pc_q <= '0;
      pred_slot_valid_q <= '0;
      pred_slot_idx_q <= '0;
      pred_target_q <= '0;
      pred_npc_q <= '0;
      pred_ghr_q <= '0;
      epoch_q <= '0;
    end else begin
      if (flush_i) begin
        head_q <= '0;
        tail_q <= '0;
        count_q <= '0;
        pc_q <= '0;
        pred_slot_valid_q <= '0;
        pred_slot_idx_q <= '0;
        pred_target_q <= '0;
        pred_npc_q <= '0;
        pred_ghr_q <= '0;
        epoch_q <= '0;
      end else begin
        if (enq_fire_w) begin
          pc_q[tail_q] <= enq_pc_i;
          pred_slot_valid_q[tail_q] <= enq_pred_slot_valid_i;
          pred_slot_idx_q[tail_q] <= enq_pred_slot_idx_i;
          pred_target_q[tail_q] <= enq_pred_target_i;
          pred_npc_q[tail_q] <= enq_pred_npc_i;
          pred_ghr_q[tail_q] <= enq_pred_ghr_i;
          epoch_q[tail_q] <= enq_epoch_i;
          tail_q <= ptr_inc(tail_q);
        end

        if (deq_fire_w) begin
          head_q <= ptr_inc(head_q);
        end

        unique case ({enq_fire_w, deq_fire_w})
          2'b10: count_q <= count_q + CNT_W'(1);
          2'b01: count_q <= count_q - CNT_W'(1);
          default: begin
          end
        endcase
      end
    end
  end

endmodule
