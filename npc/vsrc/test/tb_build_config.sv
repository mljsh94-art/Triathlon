// vsrc/test/tb_build_config.sv
import config_pkg::*;
import build_config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;

module tb_build_config (
    // --- 输入端口  ---
    input int unsigned i_INSTR_PER_FETCH,
    input int unsigned i_XLEN,
    input int unsigned i_VLEN,
    input int unsigned i_ILEN,
    input int unsigned i_BPU_USE_TAGE,
    input int unsigned i_BPU_BTB_HASH_ENABLE,
    input int unsigned i_BPU_BHT_HASH_ENABLE,
    input int unsigned i_BPU_BTB_ENTRIES,
    input int unsigned i_BPU_BHT_ENTRIES,
    input int unsigned i_BPU_TAGE_BASE_ENTRIES,
    input int unsigned i_BPU_RAS_DEPTH,
    input int unsigned i_BPU_GHR_BITS,
    input int unsigned i_BPU_USE_SC,
    input int unsigned i_BPU_SC_ENTRIES,
    input int unsigned i_BPU_SC_CONF_THRESH,
    input int unsigned i_BPU_SC_REQUIRE_BOTH_WEAK,
    input int unsigned i_BPU_SC_BLOCK_ON_TAGE_HIT,
    input int unsigned i_BPU_SC_NUM_TABLES,
    input int unsigned i_BPU_SC_CTR_BITS,
    input int unsigned i_BPU_SC_HIST1,
    input int unsigned i_BPU_SC_HIST2,
    input int unsigned i_BPU_SC_HIST3,
    input int unsigned i_BPU_SC_THRESH_INIT,
    input int unsigned i_BPU_TAGE_WAYS,
    input int unsigned i_BPU_USE_LOOP,
    input int unsigned i_BPU_LOOP_ENTRIES,
    input int unsigned i_BPU_LOOP_TAG_BITS,
    input int unsigned i_BPU_LOOP_CONF_THRESH,
    input int unsigned i_BPU_USE_ITTAGE,
    input int unsigned i_BPU_ITTAGE_ENTRIES,
    input int unsigned i_BPU_ITTAGE_TAG_BITS,
    input int unsigned i_BPU_TAGE_OVERRIDE_MIN_PROVIDER,
    input int unsigned i_BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK,
    input int unsigned i_ICACHE_HIT_PIPELINE_EN,
    input int unsigned i_IFU_FETCHQ_BYPASS_EN,
    input int unsigned i_IFU_REQ_DEPTH,
    input int unsigned i_IFU_INF_DEPTH,
    input int unsigned i_IFU_FQ_DEPTH,
    input int unsigned i_ENABLE_COMMIT_RAS_UPDATE,
    input int unsigned i_DCACHE_MSHR_SIZE,
    input int unsigned i_RENAME_PENDING_DEPTH,
    input int unsigned i_ICACHE_BYTE_SIZE,
    input int unsigned i_ICACHE_SET_ASSOC,
    input int unsigned i_ICACHE_LINE_WIDTH,

    // --- 输出端口  ---
    output int unsigned o_XLEN,
    output int unsigned o_VLEN,
    output int unsigned o_ILEN,
    output int unsigned o_PLEN,
    output int unsigned o_GPLEN,
    output int unsigned o_INSTR_PER_FETCH,
    output int unsigned o_BPU_USE_TAGE,
    output int unsigned o_BPU_BTB_HASH_ENABLE,
    output int unsigned o_BPU_BHT_HASH_ENABLE,
    output int unsigned o_BPU_BTB_ENTRIES,
    output int unsigned o_BPU_BHT_ENTRIES,
    output int unsigned o_BPU_TAGE_BASE_ENTRIES,
    output int unsigned o_BPU_RAS_DEPTH,
    output int unsigned o_BPU_GHR_BITS,
    output int unsigned o_BPU_USE_SC,
    output int unsigned o_BPU_SC_ENTRIES,
    output int unsigned o_BPU_SC_CONF_THRESH,
    output int unsigned o_BPU_SC_REQUIRE_BOTH_WEAK,
    output int unsigned o_BPU_SC_BLOCK_ON_TAGE_HIT,
    output int unsigned o_BPU_SC_NUM_TABLES,
    output int unsigned o_BPU_SC_CTR_BITS,
    output int unsigned o_BPU_SC_HIST1,
    output int unsigned o_BPU_SC_HIST2,
    output int unsigned o_BPU_SC_HIST3,
    output int unsigned o_BPU_SC_THRESH_INIT,
    output int unsigned o_BPU_TAGE_WAYS,
    output int unsigned o_BPU_USE_LOOP,
    output int unsigned o_BPU_LOOP_ENTRIES,
    output int unsigned o_BPU_LOOP_TAG_BITS,
    output int unsigned o_BPU_LOOP_CONF_THRESH,
    output int unsigned o_BPU_USE_ITTAGE,
    output int unsigned o_BPU_ITTAGE_ENTRIES,
    output int unsigned o_BPU_ITTAGE_TAG_BITS,
    output int unsigned o_BPU_TAGE_OVERRIDE_MIN_PROVIDER,
    output int unsigned o_BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK,
    output int unsigned o_ICACHE_HIT_PIPELINE_EN,
    output int unsigned o_IFU_FETCHQ_BYPASS_EN,
    output int unsigned o_IFU_REQ_DEPTH,
    output int unsigned o_IFU_INF_DEPTH,
    output int unsigned o_IFU_FQ_DEPTH,
    output int unsigned o_ENABLE_COMMIT_RAS_UPDATE,
    output int unsigned o_DCACHE_MSHR_SIZE,
    output int unsigned o_RENAME_PENDING_DEPTH,
    output int unsigned o_ICACHE_BYTE_SIZE,
    output int unsigned o_ICACHE_SET_ASSOC,
    output int unsigned o_ICACHE_SET_ASSOC_WIDTH,
    output int unsigned o_ICACHE_INDEX_WIDTH,
    output int unsigned o_ICACHE_TAG_WIDTH,
    output int unsigned o_ICACHE_LINE_WIDTH,
    output int unsigned o_ICACHE_OFFSET_WIDTH,
    output int unsigned o_FTQ_DEPTH,
    output int unsigned o_FTQ_ID_W,
    output int unsigned o_FETCH_EPOCH_W,

    // Metadata field existence checks
    output logic [31:0] o_UOP_PRED_NPC,
    output logic        o_IBUF_SLOT_VALID,
    output logic [31:0] o_IBUF_PRED_NPC
);

  // 1. 在模块内部，将输入的扁平信号打包成 user_cfg_t 结构体
  user_cfg_t user_cfg_in;
  assign user_cfg_in.XLEN              = i_XLEN;
  assign user_cfg_in.VLEN              = i_VLEN;
  assign user_cfg_in.ILEN              = i_ILEN;
  assign user_cfg_in.BPU_USE_TAGE      = i_BPU_USE_TAGE;
  assign user_cfg_in.BPU_BTB_HASH_ENABLE = i_BPU_BTB_HASH_ENABLE;
  assign user_cfg_in.BPU_BHT_HASH_ENABLE = i_BPU_BHT_HASH_ENABLE;
  assign user_cfg_in.BPU_BTB_ENTRIES = i_BPU_BTB_ENTRIES;
  assign user_cfg_in.BPU_BHT_ENTRIES = i_BPU_BHT_ENTRIES;
  assign user_cfg_in.BPU_TAGE_BASE_ENTRIES = i_BPU_TAGE_BASE_ENTRIES;
  assign user_cfg_in.BPU_RAS_DEPTH = i_BPU_RAS_DEPTH;
  assign user_cfg_in.BPU_GHR_BITS = i_BPU_GHR_BITS;
  assign user_cfg_in.BPU_USE_SC = i_BPU_USE_SC;
  assign user_cfg_in.BPU_SC_ENTRIES = i_BPU_SC_ENTRIES;
  assign user_cfg_in.BPU_SC_CONF_THRESH = i_BPU_SC_CONF_THRESH;
  assign user_cfg_in.BPU_SC_REQUIRE_BOTH_WEAK = i_BPU_SC_REQUIRE_BOTH_WEAK;
  assign user_cfg_in.BPU_SC_BLOCK_ON_TAGE_HIT = i_BPU_SC_BLOCK_ON_TAGE_HIT;
  assign user_cfg_in.BPU_SC_NUM_TABLES = i_BPU_SC_NUM_TABLES;
  assign user_cfg_in.BPU_SC_CTR_BITS = i_BPU_SC_CTR_BITS;
  assign user_cfg_in.BPU_SC_HIST1 = i_BPU_SC_HIST1;
  assign user_cfg_in.BPU_SC_HIST2 = i_BPU_SC_HIST2;
  assign user_cfg_in.BPU_SC_HIST3 = i_BPU_SC_HIST3;
  assign user_cfg_in.BPU_SC_THRESH_INIT = i_BPU_SC_THRESH_INIT;
  assign user_cfg_in.BPU_TAGE_WAYS = i_BPU_TAGE_WAYS;
  assign user_cfg_in.BPU_USE_LOOP = i_BPU_USE_LOOP;
  assign user_cfg_in.BPU_LOOP_ENTRIES = i_BPU_LOOP_ENTRIES;
  assign user_cfg_in.BPU_LOOP_TAG_BITS = i_BPU_LOOP_TAG_BITS;
  assign user_cfg_in.BPU_LOOP_CONF_THRESH = i_BPU_LOOP_CONF_THRESH;
  assign user_cfg_in.BPU_USE_ITTAGE = i_BPU_USE_ITTAGE;
  assign user_cfg_in.BPU_ITTAGE_ENTRIES = i_BPU_ITTAGE_ENTRIES;
  assign user_cfg_in.BPU_ITTAGE_TAG_BITS = i_BPU_ITTAGE_TAG_BITS;
  assign user_cfg_in.BPU_TAGE_OVERRIDE_MIN_PROVIDER = i_BPU_TAGE_OVERRIDE_MIN_PROVIDER;
  assign user_cfg_in.BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK =
      i_BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK;
  assign user_cfg_in.ICACHE_HIT_PIPELINE_EN = i_ICACHE_HIT_PIPELINE_EN;
  assign user_cfg_in.IFU_FETCHQ_BYPASS_EN = i_IFU_FETCHQ_BYPASS_EN;
  assign user_cfg_in.IFU_REQ_DEPTH = i_IFU_REQ_DEPTH;
  assign user_cfg_in.IFU_INF_DEPTH = i_IFU_INF_DEPTH;
  assign user_cfg_in.IFU_FQ_DEPTH = i_IFU_FQ_DEPTH;
  assign user_cfg_in.ENABLE_COMMIT_RAS_UPDATE = i_ENABLE_COMMIT_RAS_UPDATE;
  assign user_cfg_in.DCACHE_MSHR_SIZE = i_DCACHE_MSHR_SIZE;
  assign user_cfg_in.RENAME_PENDING_DEPTH = i_RENAME_PENDING_DEPTH;
  assign user_cfg_in.INSTR_PER_FETCH   = i_INSTR_PER_FETCH;
  assign user_cfg_in.ICACHE_BYTE_SIZE  = i_ICACHE_BYTE_SIZE;
  assign user_cfg_in.ICACHE_SET_ASSOC  = i_ICACHE_SET_ASSOC;
  assign user_cfg_in.ICACHE_LINE_WIDTH = i_ICACHE_LINE_WIDTH;

  // 2. 调用函数
  cfg_t cfg_out;
  assign cfg_out                  = build_config(user_cfg_in);

  // Compile-time field existence checks for new metadata plumbing.
  decode_pkg::uop_t uop_probe;
  global_config_pkg::ibuf_entry_t ibuf_probe;

  // 3. 将输出的 cfg_t 结构体解包到独立的输出端口
  assign o_XLEN                   = cfg_out.XLEN;
  assign o_VLEN                   = cfg_out.VLEN;
  assign o_ILEN                   = cfg_out.ILEN;
  assign o_PLEN                   = cfg_out.PLEN;
  assign o_GPLEN                  = cfg_out.GPLEN;
  assign o_INSTR_PER_FETCH        = cfg_out.INSTR_PER_FETCH;
  assign o_BPU_USE_TAGE           = cfg_out.BPU_USE_TAGE;
  assign o_BPU_BTB_HASH_ENABLE    = cfg_out.BPU_BTB_HASH_ENABLE;
  assign o_BPU_BHT_HASH_ENABLE    = cfg_out.BPU_BHT_HASH_ENABLE;
  assign o_BPU_BTB_ENTRIES        = cfg_out.BPU_BTB_ENTRIES;
  assign o_BPU_BHT_ENTRIES        = cfg_out.BPU_BHT_ENTRIES;
  assign o_BPU_TAGE_BASE_ENTRIES = cfg_out.BPU_TAGE_BASE_ENTRIES;
  assign o_BPU_RAS_DEPTH          = cfg_out.BPU_RAS_DEPTH;
  assign o_BPU_GHR_BITS           = cfg_out.BPU_GHR_BITS;
  assign o_BPU_USE_SC           = cfg_out.BPU_USE_SC;
  assign o_BPU_SC_ENTRIES       = cfg_out.BPU_SC_ENTRIES;
  assign o_BPU_SC_CONF_THRESH   = cfg_out.BPU_SC_CONF_THRESH;
  assign o_BPU_SC_REQUIRE_BOTH_WEAK = cfg_out.BPU_SC_REQUIRE_BOTH_WEAK;
  assign o_BPU_SC_BLOCK_ON_TAGE_HIT = cfg_out.BPU_SC_BLOCK_ON_TAGE_HIT;
  assign o_BPU_SC_NUM_TABLES       = cfg_out.BPU_SC_NUM_TABLES;
  assign o_BPU_SC_CTR_BITS         = cfg_out.BPU_SC_CTR_BITS;
  assign o_BPU_SC_HIST1            = cfg_out.BPU_SC_HIST1;
  assign o_BPU_SC_HIST2            = cfg_out.BPU_SC_HIST2;
  assign o_BPU_SC_HIST3            = cfg_out.BPU_SC_HIST3;
  assign o_BPU_SC_THRESH_INIT      = cfg_out.BPU_SC_THRESH_INIT;
  assign o_BPU_TAGE_WAYS           = cfg_out.BPU_TAGE_WAYS;
  assign o_BPU_USE_LOOP = cfg_out.BPU_USE_LOOP;
  assign o_BPU_LOOP_ENTRIES = cfg_out.BPU_LOOP_ENTRIES;
  assign o_BPU_LOOP_TAG_BITS = cfg_out.BPU_LOOP_TAG_BITS;
  assign o_BPU_LOOP_CONF_THRESH = cfg_out.BPU_LOOP_CONF_THRESH;
  assign o_BPU_USE_ITTAGE = cfg_out.BPU_USE_ITTAGE;
  assign o_BPU_ITTAGE_ENTRIES = cfg_out.BPU_ITTAGE_ENTRIES;
  assign o_BPU_ITTAGE_TAG_BITS = cfg_out.BPU_ITTAGE_TAG_BITS;
  assign o_BPU_TAGE_OVERRIDE_MIN_PROVIDER = cfg_out.BPU_TAGE_OVERRIDE_MIN_PROVIDER;
  assign o_BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK = cfg_out.BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK;
  assign o_ICACHE_HIT_PIPELINE_EN = cfg_out.ICACHE_HIT_PIPELINE_EN;
  assign o_IFU_FETCHQ_BYPASS_EN   = cfg_out.IFU_FETCHQ_BYPASS_EN;
  assign o_IFU_REQ_DEPTH          = cfg_out.IFU_REQ_DEPTH;
  assign o_IFU_INF_DEPTH          = cfg_out.IFU_INF_DEPTH;
  assign o_IFU_FQ_DEPTH           = cfg_out.IFU_FQ_DEPTH;
  assign o_ENABLE_COMMIT_RAS_UPDATE = cfg_out.ENABLE_COMMIT_RAS_UPDATE;
  assign o_DCACHE_MSHR_SIZE         = cfg_out.DCACHE_MSHR_SIZE;
  assign o_RENAME_PENDING_DEPTH     = cfg_out.RENAME_PENDING_DEPTH;
  assign o_ICACHE_BYTE_SIZE       = cfg_out.ICACHE_BYTE_SIZE;
  assign o_ICACHE_SET_ASSOC       = cfg_out.ICACHE_SET_ASSOC;
  assign o_ICACHE_SET_ASSOC_WIDTH = cfg_out.ICACHE_SET_ASSOC_WIDTH;
  assign o_ICACHE_INDEX_WIDTH     = cfg_out.ICACHE_INDEX_WIDTH;
  assign o_ICACHE_TAG_WIDTH       = cfg_out.ICACHE_TAG_WIDTH;
  assign o_ICACHE_LINE_WIDTH      = cfg_out.ICACHE_LINE_WIDTH;
  assign o_ICACHE_OFFSET_WIDTH    = cfg_out.ICACHE_OFFSET_WIDTH;
  assign o_FTQ_DEPTH              = cfg_out.FTQ_DEPTH;
  assign o_FTQ_ID_W               = cfg_out.FTQ_ID_W;
  assign o_FETCH_EPOCH_W          = cfg_out.FETCH_EPOCH_W;
  assign o_UOP_PRED_NPC           = uop_probe.pred_npc;
  assign o_IBUF_SLOT_VALID        = ibuf_probe.slot_valid;
  assign o_IBUF_PRED_NPC          = ibuf_probe.pred_npc;

endmodule
