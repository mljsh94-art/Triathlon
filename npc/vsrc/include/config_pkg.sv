// vsrc/include/config_pkg.sv
package config_pkg;

  // ---------------
  // Global Config
  // ---------------
  // Instruction Length
  localparam int unsigned ILEN = 32;
  // Number of RETired instructions per cycle
  localparam int unsigned NRET = 4;


  typedef struct packed {
    // Number of instructions retired per cycle
    int unsigned NRET;
    // Number of instructions fetched per cycle
    int unsigned INSTR_PER_FETCH;
    // General Purpose Register Size (in bits)
    int unsigned XLEN;
    // Virtual address Size (in bits)
    int unsigned VLEN;
    // Instruction Length (in bits)
    int unsigned ILEN;
    // Reset vector
    int unsigned RESET_VECTOR;
    // Branch predictor mode: 1 enables gshare, 0 uses PC-only index
    int unsigned BPU_USE_GSHARE;
    // Branch predictor mode: 1 enables TAGE conditional predictor
    int unsigned BPU_USE_TAGE;
    // Branch predictor mode: 1 enables tournament chooser
    int unsigned BPU_USE_TOURNAMENT;
    // Branch predictor index hash controls
    int unsigned BPU_BTB_HASH_ENABLE;
    int unsigned BPU_BHT_HASH_ENABLE;
    // Branch predictor geometry controls
    int unsigned BPU_BTB_ENTRIES;
    int unsigned BPU_BHT_ENTRIES;
    int unsigned BPU_RAS_DEPTH;
    int unsigned BPU_GHR_BITS;
    // Statistical Corrector controls
    int unsigned BPU_USE_SC_L;
    int unsigned BPU_SC_L_ENTRIES;
    int unsigned BPU_SC_L_CONF_THRESH;
    int unsigned BPU_SC_L_REQUIRE_DISAGREE;
    int unsigned BPU_SC_L_REQUIRE_BOTH_WEAK;
    int unsigned BPU_SC_L_BLOCK_ON_TAGE_HIT;
    // Loop predictor controls
    int unsigned BPU_USE_LOOP;
    int unsigned BPU_LOOP_ENTRIES;
    int unsigned BPU_LOOP_TAG_BITS;
    int unsigned BPU_LOOP_CONF_THRESH;
    // ITTAGE indirect target predictor controls
    int unsigned BPU_USE_ITTAGE;
    int unsigned BPU_ITTAGE_ENTRIES;
    int unsigned BPU_ITTAGE_TAG_BITS;
    // TAGE override policy controls
    int unsigned BPU_TAGE_OVERRIDE_MIN_PROVIDER;
    int unsigned BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK;

    // Frontend micro-architecture toggles
    int unsigned ICACHE_HIT_PIPELINE_EN;
    int unsigned IFU_FETCHQ_BYPASS_EN;
    int unsigned IFU_REQ_DEPTH;
    int unsigned IFU_INF_DEPTH;
    int unsigned IFU_FQ_DEPTH;
    int unsigned FTQ_DEPTH;

    // Backend micro-architecture toggles
    int unsigned ENABLE_COMMIT_RAS_UPDATE;
    int unsigned DC_BANKS;
    int unsigned DC_MSHR_DEPTH;
    int unsigned DCACHE_MSHR_SIZE;
    int unsigned RENAME_PENDING_DEPTH;
    int unsigned ROB_DEPTH;
    int unsigned LSU_GROUP_SIZE;
    int unsigned SB_DEPTH;
    int unsigned IBUFFER_DEPTH;
    int unsigned ROB_MAX_COMMIT_BR;
    int unsigned ROB_MAX_COMMIT_ST;
    int unsigned ROB_MAX_COMMIT_LD;

    // BPU internal geometry controls
    int unsigned BPU_TAGE_TAG_BITS;
    int unsigned BPU_TAGE_HIST_LEN0;
    int unsigned BPU_TAGE_HIST_LEN1;
    int unsigned BPU_TAGE_HIST_LEN2;
    int unsigned BPU_TAGE_HIST_LEN3;
    int unsigned BPU_PATH_HIST_BITS;
    int unsigned BPU_TRACK_DEPTH;

    // ICache configuration
    // Instruction cache size (in bytes)
    int unsigned ICACHE_BYTE_SIZE;
    // Instruction cache associativity (number of ways)
    int unsigned ICACHE_SET_ASSOC;
    // Instruction cache line width
    int unsigned ICACHE_LINE_WIDTH;

    // DCache configuration
    // Data cache size (in bytes)
    int unsigned DCACHE_BYTE_SIZE;
    // Data cache associativity (number of ways)
    int unsigned DCACHE_SET_ASSOC;
    // Data cache line width (in bits)
    int unsigned DCACHE_LINE_WIDTH;

    // MMU TLB configuration
    int unsigned ITLB_ENTRIES;
    int unsigned DTLB_ENTRIES;

    int unsigned RS_DEPTH;

    int unsigned ALU_COUNT;

  } user_cfg_t;

  typedef struct packed {
    // Number of instructions retired per cycle
    int unsigned NRET;
    // General Purpose Register Size (in bits)
    int unsigned XLEN;
    // Virtual address Size (in bits)
    int unsigned VLEN;
    // Instruction Length (in bits)
    int unsigned ILEN;
    // Reset vector
    int unsigned RESET_VECTOR;
    // Physical address Size (in bits)
    int unsigned PLEN;
    // General Purpose Physical Register Size (in bits)
    int unsigned GPLEN;
    // Number of instructions fetched per cycle
    int unsigned INSTR_PER_FETCH;
    // Fetch width (in bits)
    int unsigned FETCH_WIDTH;
    // Branch predictor mode: 1 enables gshare, 0 uses PC-only index
    int unsigned BPU_USE_GSHARE;
    // Branch predictor mode: 1 enables TAGE conditional predictor
    int unsigned BPU_USE_TAGE;
    // Branch predictor mode: 1 enables tournament chooser
    int unsigned BPU_USE_TOURNAMENT;
    // Branch predictor index hash controls
    int unsigned BPU_BTB_HASH_ENABLE;
    int unsigned BPU_BHT_HASH_ENABLE;
    // Branch predictor geometry controls
    int unsigned BPU_BTB_ENTRIES;
    int unsigned BPU_BHT_ENTRIES;
    int unsigned BPU_RAS_DEPTH;
    int unsigned BPU_GHR_BITS;
    // Statistical Corrector controls
    int unsigned BPU_USE_SC_L;
    int unsigned BPU_SC_L_ENTRIES;
    int unsigned BPU_SC_L_CONF_THRESH;
    int unsigned BPU_SC_L_REQUIRE_DISAGREE;
    int unsigned BPU_SC_L_REQUIRE_BOTH_WEAK;
    int unsigned BPU_SC_L_BLOCK_ON_TAGE_HIT;
    // Loop predictor controls
    int unsigned BPU_USE_LOOP;
    int unsigned BPU_LOOP_ENTRIES;
    int unsigned BPU_LOOP_TAG_BITS;
    int unsigned BPU_LOOP_CONF_THRESH;
    // ITTAGE indirect target predictor controls
    int unsigned BPU_USE_ITTAGE;
    int unsigned BPU_ITTAGE_ENTRIES;
    int unsigned BPU_ITTAGE_TAG_BITS;
    // TAGE override policy controls
    int unsigned BPU_TAGE_OVERRIDE_MIN_PROVIDER;
    int unsigned BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK;

    // Frontend micro-architecture toggles
    int unsigned ICACHE_HIT_PIPELINE_EN;
    int unsigned IFU_FETCHQ_BYPASS_EN;
    int unsigned IFU_REQ_DEPTH;
    int unsigned IFU_INF_DEPTH;
    int unsigned IFU_FQ_DEPTH;
    int unsigned FTQ_DEPTH;
    int unsigned FTQ_ID_W;
    int unsigned FETCH_EPOCH_W;

    // Backend micro-architecture toggles
    int unsigned ENABLE_COMMIT_RAS_UPDATE;
    int unsigned DC_BANKS;
    int unsigned DC_MSHR_DEPTH;
    int unsigned DCACHE_MSHR_SIZE;
    int unsigned RENAME_PENDING_DEPTH;
    int unsigned ROB_DEPTH;
    int unsigned LSU_GROUP_SIZE;
    int unsigned SB_DEPTH;
    int unsigned IBUFFER_DEPTH;
    int unsigned ROB_MAX_COMMIT_BR;
    int unsigned ROB_MAX_COMMIT_ST;
    int unsigned ROB_MAX_COMMIT_LD;

    // BPU internal geometry controls
    int unsigned BPU_TAGE_TAG_BITS;
    int unsigned BPU_TAGE_HIST_LEN0;
    int unsigned BPU_TAGE_HIST_LEN1;
    int unsigned BPU_TAGE_HIST_LEN2;
    int unsigned BPU_TAGE_HIST_LEN3;
    int unsigned BPU_PATH_HIST_BITS;
    int unsigned BPU_TRACK_DEPTH;

    // ICache configuration
    int unsigned ICACHE_BYTE_SIZE;
    int unsigned ICACHE_SET_ASSOC;
    int unsigned ICACHE_SET_ASSOC_WIDTH;
    int unsigned ICACHE_INDEX_WIDTH;
    int unsigned ICACHE_TAG_WIDTH;
    int unsigned ICACHE_LINE_WIDTH;
    int unsigned ICACHE_OFFSET_WIDTH;
    int unsigned ICACHE_NUM_BANKS;
    int unsigned ICACHE_BANK_SEL_WIDTH;
    int unsigned ICACHE_NUM_SETS;

    // DCache configuration
    int unsigned DCACHE_BYTE_SIZE;
    int unsigned DCACHE_SET_ASSOC;
    int unsigned DCACHE_SET_ASSOC_WIDTH;
    int unsigned DCACHE_INDEX_WIDTH;
    int unsigned DCACHE_TAG_WIDTH;
    int unsigned DCACHE_LINE_WIDTH;
    int unsigned DCACHE_OFFSET_WIDTH;
    int unsigned DCACHE_NUM_BANKS;
    int unsigned DCACHE_BANK_SEL_WIDTH;
    int unsigned DCACHE_NUM_SETS;

    // MMU TLB configuration
    int unsigned ITLB_ENTRIES;
    int unsigned DTLB_ENTRIES;

    // Reservation Station configuration
    int unsigned RS_DEPTH;

    // Execute Station configuration
    int unsigned ALU_COUNT;
  } cfg_t;
  localparam cfg_t EmptyCfg = cfg_t'(0);

  // PMA: Physical Memory Attribute — MMIO region check
  // Everything outside the DRAM window is considered MMIO/Uncacheable.
  localparam logic [31:0] PMEM_BASE = 32'h80000000;
  localparam logic [31:0] PMEM_END  = 32'h88000000;

  function automatic logic is_mmio_addr(input logic [31:0] addr);
    return (addr < PMEM_BASE) || (addr >= PMEM_END);
  endfunction
endpackage
