package core_contract_pkg;

  import global_config_pkg::*;

  // fe→be 交界 = frontend ibuffer 出队口（4-wide decode-ready 指令束）
  typedef struct packed {
    logic valid;
    logic ready;
    logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] instrs;
    logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] raw_instrs;
    logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] pcs;
    logic [Cfg.INSTR_PER_FETCH-1:0] slot_valid;
    logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] pred_npc;
    logic [Cfg.INSTR_PER_FETCH-1:0] is_rvc;
    logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.FTQ_DEPTH >= 2) ? $clog2(Cfg.FTQ_DEPTH) : 1)-1:0] ftq_id;
    logic [Cfg.INSTR_PER_FETCH-1:0][2:0] fetch_epoch;
  } fe_be_bundle_t;

endpackage : core_contract_pkg
