// csrc/test_build_config.cpp
#include "Vtb_build_config.h" // 包含 Verilator 生成的模块头文件
#include "verilated.h"
#include <cassert>
#include <iostream>

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_build_config *top = new Vtb_build_config;

  std::cout << "--- [START] Running C++ test for build_config function ---"
            << std::endl;

  // 1. 设置输入值，直接访问独立的输入端口
  top->i_XLEN = 32;
  top->i_VLEN = 32;
  top->i_ILEN = 32;
  top->i_BPU_USE_TAGE = 1;
  top->i_BPU_BTB_HASH_ENABLE = 1;
  top->i_BPU_BHT_HASH_ENABLE = 1;
  top->i_BPU_BTB_ENTRIES = 1024;
  top->i_BPU_BHT_ENTRIES = 4096;
  top->i_BPU_TAGE_BASE_ENTRIES = 2048;
  top->i_BPU_RAS_DEPTH = 32;
  top->i_BPU_GHR_BITS = 16;
  top->i_BPU_USE_SC = 1;
  top->i_BPU_SC_ENTRIES = 1024;
  top->i_BPU_SC_CONF_THRESH = 3;
  top->i_BPU_SC_REQUIRE_BOTH_WEAK = 1;
  top->i_BPU_SC_BLOCK_ON_TAGE_HIT = 1;
  top->i_BPU_SC_NUM_TABLES = 4;
  top->i_BPU_SC_CTR_BITS = 6;
  top->i_BPU_SC_HIST1 = 8;
  top->i_BPU_SC_HIST2 = 16;
  top->i_BPU_SC_HIST3 = 32;
  top->i_BPU_SC_THRESH_INIT = 6;
  top->i_BPU_TAGE_WAYS = 2;
  top->i_BPU_USE_LOOP = 1;
  top->i_BPU_LOOP_ENTRIES = 128;
  top->i_BPU_LOOP_TAG_BITS = 12;
  top->i_BPU_LOOP_CONF_THRESH = 2;
  top->i_BPU_USE_ITTAGE = 1;
  top->i_BPU_ITTAGE_ENTRIES = 256;
  top->i_BPU_ITTAGE_TAG_BITS = 12;
  top->i_BPU_TAGE_OVERRIDE_MIN_PROVIDER = 2;
  top->i_BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK = 0;
  top->i_ICACHE_HIT_PIPELINE_EN = 1;
  top->i_IFU_FETCHQ_BYPASS_EN = 1;
  top->i_IFU_REQ_DEPTH = 8;
  top->i_IFU_INF_DEPTH = 8;
  top->i_IFU_FQ_DEPTH = 8;
  top->i_ENABLE_COMMIT_RAS_UPDATE = 1;
  top->i_DCACHE_MSHR_SIZE = 4;
  top->i_RENAME_PENDING_DEPTH = 16;
  top->i_INSTR_PER_FETCH = 4;
  top->i_ICACHE_BYTE_SIZE = 8192;
  top->i_ICACHE_SET_ASSOC = 8;
  top->i_ICACHE_LINE_WIDTH = 64;

  // 2. 执行模块逻辑
  top->eval();

  // 3. 计算预期结果
  int expected_plen = 32;
  int expected_assoc_width = 3;
  int expected_index_width = 7;
  int expected_tag_width = 22;

  // 4. 读取输出并验证，访问独立的输出端口
  std::cout << "Checking PLEN..." << std::endl;
  assert(top->o_PLEN == expected_plen);

  std::cout << "Checking ICACHE_SET_ASSOC_WIDTH..." << std::endl;
  assert(top->o_ICACHE_SET_ASSOC_WIDTH == expected_assoc_width);

  std::cout << "Checking BPU_USE_TAGE..." << std::endl;
  assert(top->o_BPU_USE_TAGE == 1);
  assert(top->o_BPU_BTB_HASH_ENABLE == 1);
  assert(top->o_BPU_BHT_HASH_ENABLE == 1);
  assert(top->o_BPU_BTB_ENTRIES == 1024);
  assert(top->o_BPU_BHT_ENTRIES == 4096);
  assert(top->o_BPU_TAGE_BASE_ENTRIES == 2048);
  assert(top->o_BPU_RAS_DEPTH == 32);
  assert(top->o_BPU_GHR_BITS == 16);
  assert(top->o_BPU_USE_SC == 1);
  assert(top->o_BPU_SC_ENTRIES == 1024);
  assert(top->o_BPU_SC_CONF_THRESH == 3);
  assert(top->o_BPU_SC_REQUIRE_BOTH_WEAK == 1);
  assert(top->o_BPU_SC_BLOCK_ON_TAGE_HIT == 1);
  assert(top->o_BPU_SC_NUM_TABLES == 4);
  assert(top->o_BPU_SC_CTR_BITS == 6);
  assert(top->o_BPU_SC_HIST1 == 8);
  assert(top->o_BPU_SC_HIST2 == 16);
  assert(top->o_BPU_SC_HIST3 == 16);  // capped by i_BPU_GHR_BITS=16
  assert(top->o_BPU_SC_THRESH_INIT == 6);
  assert(top->o_BPU_TAGE_WAYS == 2);
  assert(top->o_BPU_USE_LOOP == 1);
  assert(top->o_BPU_LOOP_ENTRIES == 128);
  assert(top->o_BPU_LOOP_TAG_BITS == 12);
  assert(top->o_BPU_LOOP_CONF_THRESH == 2);
  assert(top->o_BPU_USE_ITTAGE == 1);
  assert(top->o_BPU_ITTAGE_ENTRIES == 256);
  assert(top->o_BPU_ITTAGE_TAG_BITS == 12);
  assert(top->o_BPU_TAGE_OVERRIDE_MIN_PROVIDER == 2);
  assert(top->o_BPU_TAGE_OVERRIDE_REQUIRE_LEGACY_WEAK == 0);
  assert(top->o_ICACHE_HIT_PIPELINE_EN == 1);
  assert(top->o_IFU_FETCHQ_BYPASS_EN == 1);
  assert(top->o_IFU_REQ_DEPTH == 8);
  assert(top->o_IFU_INF_DEPTH == 8);
  assert(top->o_IFU_FQ_DEPTH == 8);
  assert(top->o_ENABLE_COMMIT_RAS_UPDATE == 1);
  assert(top->o_DCACHE_MSHR_SIZE == 4);
  assert(top->o_RENAME_PENDING_DEPTH == 16);

  std::cout << "Checking ICACHE_INDEX_WIDTH..." << std::endl;
  assert(top->o_ICACHE_INDEX_WIDTH == expected_index_width);

  std::cout << "Checking ICACHE_TAG_WIDTH..." << std::endl;
  assert(top->o_ICACHE_TAG_WIDTH == expected_tag_width);

  std::cout << "Checking metadata fields are wired..." << std::endl;
  assert(top->o_UOP_PRED_NPC == 0);
  assert(top->o_IBUF_SLOT_VALID == 0);
  assert(top->o_IBUF_PRED_NPC == 0);
  assert(top->o_FTQ_DEPTH == 8);
  assert(top->o_FTQ_ID_W == 3);
  assert(top->o_FETCH_EPOCH_W == 3);

  std::cout << "--- [PASSED] All checks passed successfully! ---" << std::endl;

  // 5. 清理
  delete top;
  return 0;
}
