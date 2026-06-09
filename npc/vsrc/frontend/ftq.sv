import config_pkg::*;

module ftq #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned DEPTH = (Cfg.IFU_INF_DEPTH >= 2) ? Cfg.IFU_INF_DEPTH : 2,
    parameter int unsigned EPOCH_W = 3
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input  logic alloc_valid_i,
    output logic alloc_ready_o,
    output logic alloc_fire_o,
    output logic [((DEPTH > 1) ? $clog2(DEPTH) : 1)-1:0] alloc_id_o,
    input  logic [Cfg.PLEN-1:0] alloc_pc_i,
    input  logic alloc_pred_slot_valid_i,
    input  logic [((Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1)-1:0] alloc_pred_slot_idx_i,
    input  logic [Cfg.PLEN-1:0] alloc_pred_target_i,
    input  logic [EPOCH_W-1:0] alloc_epoch_i,

    input logic free_valid_i,
    input logic [((DEPTH > 1) ? $clog2(DEPTH) : 1)-1:0] free_id_i,

    input logic lookup_valid_i,
    input logic [((DEPTH > 1) ? $clog2(DEPTH) : 1)-1:0] lookup_id_i,
    output logic lookup_hit_o,
    output logic [Cfg.PLEN-1:0] lookup_pc_o,
    output logic lookup_pred_slot_valid_o,
    output logic [((Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1)-1:0] lookup_pred_slot_idx_o,
    output logic [Cfg.PLEN-1:0] lookup_pred_target_o,
    output logic [EPOCH_W-1:0] lookup_epoch_o,

    output logic [((DEPTH > 1) ? $clog2(DEPTH + 1) : 1)-1:0] count_o
);

  localparam int unsigned ID_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int unsigned SLOT_IDX_W = (Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1;
  localparam int unsigned CNT_W = (DEPTH > 1) ? $clog2(DEPTH + 1) : 1;

  logic [DEPTH-1:0] valid_q;
  logic [DEPTH-1:0][Cfg.PLEN-1:0] pc_q;
  logic [DEPTH-1:0] pred_slot_valid_q;
  logic [DEPTH-1:0][SLOT_IDX_W-1:0] pred_slot_idx_q;
  logic [DEPTH-1:0][Cfg.PLEN-1:0] pred_target_q;
  logic [DEPTH-1:0][EPOCH_W-1:0] epoch_q;

  logic alloc_found_w;
  logic [ID_W-1:0] alloc_idx_w;
  logic free_hit_w;
  logic [CNT_W-1:0] valid_count_w;

  always_comb begin
    alloc_found_w = 1'b0;
    alloc_idx_w = '0;
    for (int i = 0; i < DEPTH; i++) begin
      if (!alloc_found_w && !valid_q[i]) begin
        alloc_found_w = 1'b1;
        alloc_idx_w = ID_W'(i);
      end
    end
  end

  assign alloc_ready_o = flush_i ? 1'b1 : alloc_found_w;
  assign alloc_fire_o = alloc_valid_i && alloc_ready_o;
  assign alloc_id_o = flush_i ? '0 : alloc_idx_w;

  assign free_hit_w = !flush_i && free_valid_i && valid_q[free_id_i];

  assign lookup_hit_o = lookup_valid_i && valid_q[lookup_id_i];
  assign lookup_pc_o = pc_q[lookup_id_i];
  assign lookup_pred_slot_valid_o = pred_slot_valid_q[lookup_id_i];
  assign lookup_pred_slot_idx_o = pred_slot_idx_q[lookup_id_i];
  assign lookup_pred_target_o = pred_target_q[lookup_id_i];
  assign lookup_epoch_o = epoch_q[lookup_id_i];

  always_comb begin
    valid_count_w = '0;
    for (int i = 0; i < DEPTH; i++) begin
      if (valid_q[i]) begin
        valid_count_w++;
      end
    end
  end
  assign count_o = valid_count_w;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= '0;
      pc_q <= '0;
      pred_slot_valid_q <= '0;
      pred_slot_idx_q <= '0;
      pred_target_q <= '0;
      epoch_q <= '0;
    end else begin
      if (flush_i) begin
        valid_q <= '0;
        pc_q <= '0;
        pred_slot_valid_q <= '0;
        pred_slot_idx_q <= '0;
        pred_target_q <= '0;
        epoch_q <= '0;
      end

      if (free_hit_w) begin
        valid_q[free_id_i] <= 1'b0;
      end

      if (alloc_fire_o) begin
        valid_q[alloc_id_o] <= 1'b1;
        pc_q[alloc_id_o] <= alloc_pc_i;
        pred_slot_valid_q[alloc_id_o] <= alloc_pred_slot_valid_i;
        pred_slot_idx_q[alloc_id_o] <= alloc_pred_slot_idx_i;
        pred_target_q[alloc_id_o] <= alloc_pred_target_i;
        epoch_q[alloc_id_o] <= alloc_epoch_i;
      end
    end
  end

endmodule
