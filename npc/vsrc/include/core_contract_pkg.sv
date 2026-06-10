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
    logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ftq_id;
    logic [Cfg.INSTR_PER_FETCH-1:0][2:0] fetch_epoch;
  } fe_be_bundle_t;

  // be→fe 控制侧带：flush / BPU 训练 / MMU 状态（不含 ifetch_fault / IFU PTE 遍历）
  typedef struct packed {
    logic flush;
    logic [Cfg.PLEN-1:0] redirect_pc;
    logic bpu_update_valid;
    logic [Cfg.PLEN-1:0] bpu_update_pc;
    logic bpu_update_is_cond;
    logic bpu_update_taken;
    logic [Cfg.PLEN-1:0] bpu_update_target;
    logic bpu_update_is_call;
    logic bpu_update_is_ret;
    logic bpu_update_is_rvc;
    logic [Cfg.NRET-1:0] bpu_ras_update_valid;
    logic [Cfg.NRET-1:0] bpu_ras_update_is_call;
    logic [Cfg.NRET-1:0] bpu_ras_update_is_ret;
    logic [Cfg.NRET-1:0] bpu_ras_update_is_rvc;
    logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] bpu_ras_update_pc;
    logic [31:0] mmu_satp;
    logic [1:0] mmu_priv;
    logic mmu_sum;
    logic mmu_mxr;
    logic mmu_sfence_vma;
  } be2fe_ctrl_if_t;

endpackage : core_contract_pkg
