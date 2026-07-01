// vsrc/include/build_config_pkg.sv
package build_config_pkg;

  import config_pkg::*;

  function automatic config_pkg::cfg_t build_config(config_pkg::user_cfg_t user_cfg);
    // TODO
    config_pkg::cfg_t cfg;
    // Global
    cfg.NRET = user_cfg.NRET;
    cfg.INSTR_PER_FETCH = user_cfg.INSTR_PER_FETCH;
    cfg.XLEN = user_cfg.XLEN;
    cfg.VLEN = user_cfg.VLEN;
    cfg.PLEN = user_cfg.VLEN;  // 假设物理地址大小等于虚拟地址大小
    cfg.ILEN = user_cfg.ILEN;
    cfg.RESET_VECTOR = (user_cfg.RESET_VECTOR != 0) ? user_cfg.RESET_VECTOR : 32'h80000000;
    cfg.FETCH_WIDTH = user_cfg.INSTR_PER_FETCH * user_cfg.ILEN / 8;
    cfg.BPU_USE_TAGE = user_cfg.BPU_USE_TAGE;
    cfg.BPU_BTB_HASH_ENABLE = user_cfg.BPU_BTB_HASH_ENABLE;
    cfg.BPU_BHT_HASH_ENABLE = user_cfg.BPU_BHT_HASH_ENABLE;
    cfg.BPU_BTB_ENTRIES = (user_cfg.BPU_BTB_ENTRIES >= 16) ? user_cfg.BPU_BTB_ENTRIES : 512;
    cfg.BPU_BHT_ENTRIES = (user_cfg.BPU_BHT_ENTRIES >= 32) ? user_cfg.BPU_BHT_ENTRIES : 512;
    cfg.BPU_TAGE_BASE_ENTRIES = (user_cfg.BPU_TAGE_BASE_ENTRIES >= 32) ?
        user_cfg.BPU_TAGE_BASE_ENTRIES : 1024;
    cfg.BPU_RAS_DEPTH = (user_cfg.BPU_RAS_DEPTH >= 4) ? user_cfg.BPU_RAS_DEPTH : 16;
    cfg.BPU_GHR_BITS = (user_cfg.BPU_GHR_BITS >= 4) ? user_cfg.BPU_GHR_BITS : 8;
    cfg.BPU_USE_SC = user_cfg.BPU_USE_SC;
    cfg.BPU_SC_ENTRIES = (user_cfg.BPU_SC_ENTRIES >= 64) ? user_cfg.BPU_SC_ENTRIES : 512;
    cfg.BPU_SC_CONF_THRESH = (user_cfg.BPU_SC_CONF_THRESH <= 7) ?
        user_cfg.BPU_SC_CONF_THRESH : 3;
    cfg.BPU_SC_REQUIRE_BOTH_WEAK = (user_cfg.BPU_SC_REQUIRE_BOTH_WEAK != 0) ? 1 : 0;
    cfg.BPU_SC_BLOCK_ON_TAGE_HIT = (user_cfg.BPU_SC_BLOCK_ON_TAGE_HIT != 0) ? 1 : 0;
    cfg.BPU_SC_NUM_TABLES = (user_cfg.BPU_SC_NUM_TABLES >= 2 && user_cfg.BPU_SC_NUM_TABLES <= 8) ?
        user_cfg.BPU_SC_NUM_TABLES : 4;
    cfg.BPU_SC_CTR_BITS = (user_cfg.BPU_SC_CTR_BITS >= 4 && user_cfg.BPU_SC_CTR_BITS <= 8) ?
        user_cfg.BPU_SC_CTR_BITS : 6;
    cfg.BPU_SC_HIST1 = (user_cfg.BPU_SC_HIST1 >= 1) ? user_cfg.BPU_SC_HIST1 : 8;
    cfg.BPU_SC_HIST2 = (user_cfg.BPU_SC_HIST2 >= cfg.BPU_SC_HIST1) ? user_cfg.BPU_SC_HIST2 : 16;
    cfg.BPU_SC_HIST3 = (user_cfg.BPU_SC_HIST3 >= cfg.BPU_SC_HIST2) ? user_cfg.BPU_SC_HIST3 : 32;
    if (cfg.BPU_SC_HIST3 > cfg.BPU_GHR_BITS) cfg.BPU_SC_HIST3 = cfg.BPU_GHR_BITS;
    cfg.BPU_SC_THRESH_INIT = (user_cfg.BPU_SC_THRESH_INIT >= 1) ? user_cfg.BPU_SC_THRESH_INIT :
        ((user_cfg.BPU_SC_CONF_THRESH >= 1) ? user_cfg.BPU_SC_CONF_THRESH : 6);
    cfg.BPU_TAGE_WAYS = (user_cfg.BPU_TAGE_WAYS >= 1 && user_cfg.BPU_TAGE_WAYS <= 4) ?
        user_cfg.BPU_TAGE_WAYS : 2;
    cfg.BPU_USE_LOOP = (user_cfg.BPU_USE_LOOP != 0) ? 1 : 0;
    cfg.BPU_LOOP_ENTRIES = (user_cfg.BPU_LOOP_ENTRIES >= 16) ? user_cfg.BPU_LOOP_ENTRIES : 64;
    cfg.BPU_LOOP_TAG_BITS = (user_cfg.BPU_LOOP_TAG_BITS >= 4) ? user_cfg.BPU_LOOP_TAG_BITS : 10;
    cfg.BPU_LOOP_CONF_THRESH = (user_cfg.BPU_LOOP_CONF_THRESH <= 3) ?
        user_cfg.BPU_LOOP_CONF_THRESH : 2;
    cfg.BPU_USE_ITTAGE = (user_cfg.BPU_USE_ITTAGE != 0) ? 1 : 0;
    cfg.BPU_ITTAGE_ENTRIES = (user_cfg.BPU_ITTAGE_ENTRIES >= 16) ?
        user_cfg.BPU_ITTAGE_ENTRIES : 128;
    cfg.BPU_ITTAGE_TAG_BITS = (user_cfg.BPU_ITTAGE_TAG_BITS >= 4) ?
        user_cfg.BPU_ITTAGE_TAG_BITS : 10;
    cfg.BPU_TAGE_OVERRIDE_MIN_PROVIDER = (user_cfg.BPU_TAGE_OVERRIDE_MIN_PROVIDER <= 3) ?
        user_cfg.BPU_TAGE_OVERRIDE_MIN_PROVIDER : 3;
    cfg.BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK = user_cfg.BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK;
    cfg.ICACHE_HIT_PIPELINE_EN = user_cfg.ICACHE_HIT_PIPELINE_EN;
    cfg.IFU_FETCHQ_BYPASS_EN = user_cfg.IFU_FETCHQ_BYPASS_EN;
    cfg.IFU_REQ_DEPTH = user_cfg.IFU_REQ_DEPTH;
    cfg.IFU_INF_DEPTH = user_cfg.IFU_INF_DEPTH;
    cfg.IFU_FQ_DEPTH = user_cfg.IFU_FQ_DEPTH;
    cfg.FTQ_DEPTH = (user_cfg.FTQ_DEPTH >= 2) ? user_cfg.FTQ_DEPTH : 16;
    cfg.FTQ_ID_W = (cfg.FTQ_DEPTH > 1) ? $clog2(cfg.FTQ_DEPTH) : 1;
    cfg.FETCH_EPOCH_W = 3;
    cfg.ENABLE_COMMIT_RAS_UPDATE = user_cfg.ENABLE_COMMIT_RAS_UPDATE;
    cfg.DC_BANKS = (user_cfg.DC_BANKS >= 1) ? user_cfg.DC_BANKS : 4;
    cfg.DC_MSHR_DEPTH = (user_cfg.DC_MSHR_DEPTH >= 1) ? user_cfg.DC_MSHR_DEPTH :
        ((user_cfg.DCACHE_MSHR_SIZE >= 1) ? user_cfg.DCACHE_MSHR_SIZE : 8);
    cfg.DCACHE_MSHR_SIZE = cfg.DC_MSHR_DEPTH;
    cfg.RENAME_PENDING_DEPTH = (user_cfg.RENAME_PENDING_DEPTH > 0) ? user_cfg.RENAME_PENDING_DEPTH :
        (user_cfg.INSTR_PER_FETCH * 4);
    cfg.ROB_DEPTH = (user_cfg.ROB_DEPTH >= user_cfg.INSTR_PER_FETCH) ? user_cfg.ROB_DEPTH : 64;
    cfg.LSU_GROUP_SIZE = (user_cfg.LSU_GROUP_SIZE >= 1) ? user_cfg.LSU_GROUP_SIZE : 1;
    cfg.SB_DEPTH = (user_cfg.SB_DEPTH >= 4) ? user_cfg.SB_DEPTH : 32;
    cfg.IBUFFER_DEPTH = (user_cfg.IBUFFER_DEPTH >= user_cfg.INSTR_PER_FETCH) ?
        user_cfg.IBUFFER_DEPTH : 16;
    cfg.ROB_MAX_COMMIT_BR = (user_cfg.ROB_MAX_COMMIT_BR >= 1) ? user_cfg.ROB_MAX_COMMIT_BR : 1;
    cfg.ROB_MAX_COMMIT_ST = (user_cfg.ROB_MAX_COMMIT_ST >= 1) ? user_cfg.ROB_MAX_COMMIT_ST : 2;
    cfg.ROB_MAX_COMMIT_LD = (user_cfg.ROB_MAX_COMMIT_LD >= 1) ? user_cfg.ROB_MAX_COMMIT_LD : 2;
    cfg.BPU_TAGE_TAG_BITS = (user_cfg.BPU_TAGE_TAG_BITS >= 4) ? user_cfg.BPU_TAGE_TAG_BITS : 8;
    cfg.BPU_TAGE_HIST_LEN0 = (user_cfg.BPU_TAGE_HIST_LEN0 >= 1) ? user_cfg.BPU_TAGE_HIST_LEN0 : 2;
    cfg.BPU_TAGE_HIST_LEN1 = (user_cfg.BPU_TAGE_HIST_LEN1 >= cfg.BPU_TAGE_HIST_LEN0) ?
        user_cfg.BPU_TAGE_HIST_LEN1 : 4;
    cfg.BPU_TAGE_HIST_LEN2 = (user_cfg.BPU_TAGE_HIST_LEN2 >= cfg.BPU_TAGE_HIST_LEN1) ?
        user_cfg.BPU_TAGE_HIST_LEN2 : 8;
    cfg.BPU_TAGE_HIST_LEN3 = (user_cfg.BPU_TAGE_HIST_LEN3 >= cfg.BPU_TAGE_HIST_LEN2) ?
        user_cfg.BPU_TAGE_HIST_LEN3 : 16;
    cfg.BPU_PATH_HIST_BITS = (user_cfg.BPU_PATH_HIST_BITS >= 4) ? user_cfg.BPU_PATH_HIST_BITS : 16;
    cfg.BPU_TRACK_DEPTH = (user_cfg.BPU_TRACK_DEPTH >= 2) ? user_cfg.BPU_TRACK_DEPTH : 16;

    // ICache 配置
    cfg.ICACHE_BYTE_SIZE = user_cfg.ICACHE_BYTE_SIZE;
    cfg.ICACHE_SET_ASSOC = user_cfg.ICACHE_SET_ASSOC;
    cfg.ICACHE_LINE_WIDTH = user_cfg.ICACHE_LINE_WIDTH;
    cfg.ICACHE_SET_ASSOC_WIDTH = user_cfg.ICACHE_SET_ASSOC > 1 ? $clog2(user_cfg.ICACHE_SET_ASSOC) :
        user_cfg.ICACHE_SET_ASSOC;
    cfg.ICACHE_INDEX_WIDTH = $clog2(
        user_cfg.ICACHE_BYTE_SIZE * 8 / user_cfg.ICACHE_SET_ASSOC / user_cfg.ICACHE_LINE_WIDTH);
    cfg.ICACHE_OFFSET_WIDTH = $clog2(user_cfg.ICACHE_LINE_WIDTH / 8);
    cfg.ICACHE_TAG_WIDTH = cfg.PLEN - cfg.ICACHE_INDEX_WIDTH - cfg.ICACHE_OFFSET_WIDTH;
    cfg.ICACHE_NUM_BANKS = 4;  // 固定为4个Bank
    cfg.ICACHE_BANK_SEL_WIDTH = $clog2(cfg.ICACHE_NUM_BANKS);
    cfg.ICACHE_NUM_SETS = (user_cfg.ICACHE_BYTE_SIZE * 8) / user_cfg.ICACHE_SET_ASSOC / user_cfg.ICACHE_LINE_WIDTH;

    // DCache 配置
    cfg.DCACHE_BYTE_SIZE = user_cfg.DCACHE_BYTE_SIZE;
    cfg.DCACHE_SET_ASSOC = user_cfg.DCACHE_SET_ASSOC;
    cfg.DCACHE_LINE_WIDTH = user_cfg.DCACHE_LINE_WIDTH;
    cfg.DCACHE_SET_ASSOC_WIDTH = user_cfg.DCACHE_SET_ASSOC > 1 ? $clog2(user_cfg.DCACHE_SET_ASSOC) :
        user_cfg.DCACHE_SET_ASSOC;
    cfg.DCACHE_INDEX_WIDTH = $clog2(
        user_cfg.DCACHE_BYTE_SIZE * 8 / user_cfg.DCACHE_SET_ASSOC / user_cfg.DCACHE_LINE_WIDTH);
    cfg.DCACHE_OFFSET_WIDTH = $clog2(user_cfg.DCACHE_LINE_WIDTH / 8);
    cfg.DCACHE_TAG_WIDTH = cfg.PLEN - cfg.DCACHE_INDEX_WIDTH - cfg.DCACHE_OFFSET_WIDTH;
    cfg.DCACHE_NUM_BANKS = cfg.DC_BANKS;
    cfg.DCACHE_BANK_SEL_WIDTH = $clog2(cfg.DCACHE_NUM_BANKS);
    cfg.DCACHE_NUM_SETS = (user_cfg.DCACHE_BYTE_SIZE * 8) / user_cfg.DCACHE_SET_ASSOC / user_cfg.DCACHE_LINE_WIDTH;

    // MMU TLB 配置
    cfg.ITLB_ENTRIES = (user_cfg.ITLB_ENTRIES >= 4) ? user_cfg.ITLB_ENTRIES : 8;
    cfg.DTLB_ENTRIES = (user_cfg.DTLB_ENTRIES >= 4) ? user_cfg.DTLB_ENTRIES : 8;

    // RS 配置
    cfg.RS_DEPTH = user_cfg.RS_DEPTH;

    // ALU 配置
    cfg.ALU_COUNT = user_cfg.ALU_COUNT;
    return cfg;
  endfunction
endpackage
