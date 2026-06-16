// vsrc/include/global_config_pkg.sv
// Global types for Triathlon
package global_config_pkg;

  import test_config_pkg::*;
  import config_pkg::*;
  import build_config_pkg::*;

  localparam config_pkg::cfg_t Cfg = build_config_pkg::build_config(test_config_pkg::TestCfg);
  localparam int unsigned FTQ_DEPTH = (Cfg.FTQ_DEPTH >= 2) ? Cfg.FTQ_DEPTH : 2;
  localparam int unsigned FTQ_ID_W = (Cfg.FTQ_ID_W >= 1) ? Cfg.FTQ_ID_W : 1;
  localparam int unsigned FETCH_EPOCH_W = (Cfg.FETCH_EPOCH_W >= 1) ? Cfg.FETCH_EPOCH_W : 3;
  localparam int unsigned FE_EXPAND_MAX = Cfg.INSTR_PER_FETCH * 2;
  // FTB 半字 slot：一个 fetch block 内的半字位置数（与译码宽度解耦）。
  // pred_slot_idx 由 word index(语义) 升级为 half-word index(0~PRED_SLOT_COUNT-1)。
  localparam int unsigned PRED_SLOT_COUNT = Cfg.INSTR_PER_FETCH * 2;
  localparam int unsigned PRED_SLOT_IDX_W = (PRED_SLOT_COUNT > 1) ? $clog2(PRED_SLOT_COUNT) : 1;

  typedef struct packed {
    logic valid;
    logic ready;
  } handshake_t;

  typedef struct packed {
    logic [Cfg.PLEN-1:0] pc;
    logic                pred_slot_valid;
    logic [PRED_SLOT_IDX_W-1:0] pred_slot_idx;
    logic [Cfg.PLEN-1:0] pred_target;
    logic [Cfg.PLEN-1:0] pred_npc;
    logic [FETCH_EPOCH_W-1:0] fetch_epoch;
    logic [FTQ_ID_W-1:0] ftq_id;
  } ftq_entry_t;

  typedef struct packed {
    logic                 slot_valid;
    logic [Cfg.ILEN-1:0] instr;
    logic [Cfg.ILEN-1:0] raw_inst;
    logic [Cfg.PLEN-1:0] pc;
    logic [Cfg.PLEN-1:0] pred_npc;
    logic                is_rvc;
    logic [FTQ_ID_W-1:0] ftq_id;
    logic [FETCH_EPOCH_W-1:0] fetch_epoch;
  } ibuf_entry_t;

endpackage : global_config_pkg
