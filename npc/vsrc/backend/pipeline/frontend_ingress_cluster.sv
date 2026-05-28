import config_pkg::*;
import decode_pkg::*;

module frontend_ingress_cluster #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned DISPATCH_WIDTH = Cfg.INSTR_PER_FETCH,
    parameter int unsigned IBUFFER_DEPTH = (Cfg.IBUFFER_DEPTH >= Cfg.INSTR_PER_FETCH) ? Cfg.IBUFFER_DEPTH : 16
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input  logic                                         fe_valid_i,
    output logic                                         fe_ready_o,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] fe_instrs_i,
    input  logic [Cfg.PLEN-1:0]                          fe_pc_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0]               fe_slot_valid_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] fe_pred_npc_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] fe_ftq_id_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] fe_fetch_epoch_i,

    output logic dec_valid_o,
    output logic [DISPATCH_WIDTH-1:0] dec_slot_valid_o,
    output decode_pkg::uop_t [DISPATCH_WIDTH-1:0] dec_uops_o,
    input logic decode_ready_i,

    output logic ingress_dec_valid_o,
    output logic decode_ibuf_valid_o,
    output logic decode_ibuf_ready_o
);

  logic decode_ibuf_valid;
  logic decode_ibuf_ready;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] decode_ibuf_instrs;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] decode_ibuf_raw_instrs;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] decode_ibuf_pcs;
  logic [Cfg.INSTR_PER_FETCH-1:0] decode_ibuf_slot_valid;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] decode_ibuf_pred_npc;
  logic [Cfg.INSTR_PER_FETCH-1:0] decode_ibuf_is_rvc;
  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] decode_ibuf_ftq_id;
  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] decode_ibuf_fetch_epoch;

  ibuffer #(
      .Cfg         (Cfg),
      .IB_DEPTH    (IBUFFER_DEPTH),
      .DECODE_WIDTH(Cfg.INSTR_PER_FETCH)
  ) u_ibuffer (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .fe_valid_i     (fe_valid_i),
      .fe_ready_o     (fe_ready_o),
      .fe_instrs_i    (fe_instrs_i),
      .fe_pc_i        (fe_pc_i),
      .fe_slot_valid_i(fe_slot_valid_i),
      .fe_pred_npc_i  (fe_pred_npc_i),
      .fe_ftq_id_i(fe_ftq_id_i),
      .fe_fetch_epoch_i(fe_fetch_epoch_i),

      .ibuf_valid_o (decode_ibuf_valid),
      .ibuf_ready_i (decode_ibuf_ready),
      .ibuf_instrs_o(decode_ibuf_instrs),
      .ibuf_raw_instrs_o(decode_ibuf_raw_instrs),
      .ibuf_pcs_o   (decode_ibuf_pcs),
      .ibuf_slot_valid_o(decode_ibuf_slot_valid),
      .ibuf_pred_npc_o(decode_ibuf_pred_npc),
      .ibuf_is_rvc_o(decode_ibuf_is_rvc),
      .ibuf_ftq_id_o(decode_ibuf_ftq_id),
      .ibuf_fetch_epoch_o(decode_ibuf_fetch_epoch),

      .flush_i(flush_i)
  );

  decoder #(
      .Cfg(Cfg),
      .DECODE_WIDTH(DISPATCH_WIDTH)
  ) u_decoder (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .ibuf2dec_valid_i (decode_ibuf_valid),
      .dec2ibuf_ready_o (decode_ibuf_ready),
      .ibuf_instrs_i    (decode_ibuf_instrs),
      .ibuf_raw_instrs_i(decode_ibuf_raw_instrs),
      .ibuf_pcs_i       (decode_ibuf_pcs),
      .ibuf_slot_valid_i(decode_ibuf_slot_valid),
      .ibuf_pred_npc_i  (decode_ibuf_pred_npc),
      .ibuf_is_rvc_i    (decode_ibuf_is_rvc),
      .ibuf_ftq_id_i(decode_ibuf_ftq_id),
      .ibuf_fetch_epoch_i(decode_ibuf_fetch_epoch),

      .dec2backend_valid_o(dec_valid_o),
      .backend2dec_ready_i(decode_ready_i),
      .dec_slot_valid_o   (dec_slot_valid_o),
      .dec_uops_o         (dec_uops_o)
  );

  assign ingress_dec_valid_o = dec_valid_o;
  assign decode_ibuf_valid_o = decode_ibuf_valid;
  assign decode_ibuf_ready_o = decode_ibuf_ready;

endmodule
