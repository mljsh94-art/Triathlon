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

  typedef struct packed {
    logic valid;
    logic ready;
  } handshake_t;

  typedef struct packed {logic [Cfg.PLEN-1:0] pc;} ifu_to_bpu_t;

  typedef struct packed {
    logic [Cfg.PLEN-1:0] npc;
    logic                pred_slot_valid;
    logic [$clog2(Cfg.INSTR_PER_FETCH)-1:0] pred_slot_idx;
    logic [Cfg.PLEN-1:0] pred_slot_target;
  } bpu_to_ifu_t;

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
