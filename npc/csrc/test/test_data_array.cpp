// 文件: npc/csrc/test_data_array.cpp (修改版)
#include "Vtb_data_array.h" // 包含 Verilator 生成的模块头文件
#include "verilated.h"
#include <cassert>
#include <iomanip>
#include <iostream>
#include <vector>

const int NUM_WAYS = 4;
const int BLOCK_WIDTH_BITS = 512;
const int BLOCK_WIDTH_WORDS = (BLOCK_WIDTH_BITS + 31) / 32;

vluint64_t main_time = 0;

void tick(Vtb_data_array *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

// --- 辅助函数：处理 VlWide 数据 (与原文件相同) ---
void set_wide_data(uint32_t *dest, int num_words, uint32_t pattern_base) {
  for (int i = 0; i < num_words; ++i) {
    dest[i] = pattern_base + i;
  }
}

bool compare_wide_data(const uint32_t *actual, const uint32_t *expected,
                       int num_words) {
  for (int i = 0; i < num_words; ++i) {
    if (actual[i] != expected[i]) {
      return false;
    }
  }
  return true;
}

void print_wide_data(const uint32_t *data, int num_words) {
  std::cout << "0x";
  if (num_words > 1) {
    std::cout << std::hex << std::setw(8) << std::setfill('0')
              << data[num_words - 1] << "...";
  }
  std::cout << std::hex << std::setw(8) << std::setfill('0') << data[0];
}
// --- 辅助函数结束 ---

// (新) 辅助函数：从 rdata_a_o 中提取指定 way 的数据指针
const uint32_t *get_way_data_ptr_a(Vtb_data_array *top, int way) {
  return top->rdata_a_o + (way * BLOCK_WIDTH_WORDS);
}

// (新) 辅助函数：从 rdata_b_o 中提取指定 way 的数据指针
const uint32_t *get_way_data_ptr_b(Vtb_data_array *top, int way) {
  return top->rdata_b_o + (way * BLOCK_WIDTH_WORDS);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_data_array *top = new Vtb_data_array;

  std::cout << "--- [START] Running C++ test for 2R1W DataArray ---"
            << std::endl;

  // 1. 复位
  top->rst_ni = 0;
  top->bank_addr_ra_i = 0;
  top->bank_sel_ra_i = 0;
  top->bank_addr_rb_i = 0;
  top->bank_sel_rb_i = 0;
  top->w_bank_addr_i = 0;
  top->w_bank_sel_i = 0;
  top->we_way_mask_i = 0;

  std::vector<uint32_t> wdata_buffer(BLOCK_WIDTH_WORDS, 0);
  set_wide_data(wdata_buffer.data(), BLOCK_WIDTH_WORDS, 0);
  memcpy(top->wdata_i, wdata_buffer.data(),
         BLOCK_WIDTH_WORDS * sizeof(uint32_t));

  tick(top);
  top->rst_ni = 1;
  std::cout << "[" << main_time << "] Reset complete." << std::endl;

  // --- 测试数据准备 ---
  int test_bank = 2;
  int test_addr = 0x5A;
  int test_way = 1;
  uint32_t write_pattern = 0xA0A0A0A0;
  std::vector<uint32_t> expected_data(BLOCK_WIDTH_WORDS);
  set_wide_data(expected_data.data(), BLOCK_WIDTH_WORDS, write_pattern);

  // --- 测试 1: 写入特定 Way/Bank/Addr ---
  std::cout << "--- Test 1: Write ---" << std::endl;
  top->w_bank_addr_i = test_addr; // 使用写端口
  top->w_bank_sel_i = test_bank;
  top->we_way_mask_i = (1 << test_way);
  memcpy(top->wdata_i, expected_data.data(),
         BLOCK_WIDTH_WORDS * sizeof(uint32_t));
  tick(top);

  // 停止写入
  top->we_way_mask_i = 0;
  top->eval();

  // --- 测试 2: 同时读回写入的数据和未写入的数据 ---
  std::cout << "--- Test 2: Simultaneous Dual Read ---" << std::endl;
  int unwritten_bank = 1;
  int unwritten_addr = 0xCC;
  int other_way = 3;
  std::vector<uint32_t> zero_data(BLOCK_WIDTH_WORDS, 0); // 期望是 0

  // 设置两个独立的读请求
  top->bank_addr_ra_i = test_addr; // 端口 A 读写入的地址
  top->bank_sel_ra_i = test_bank;
  top->bank_addr_rb_i = unwritten_addr; // 端口 B 读未写入的地址
  top->bank_sel_rb_i = unwritten_bank;
  tick(top);

  // 检查 端口 A
  const uint32_t *read_data_a_ptr = get_way_data_ptr_a(top, test_way);
  std::cout << "  Port A, Way " << test_way << " Data: ";
  print_wide_data(read_data_a_ptr, BLOCK_WIDTH_WORDS);
  std::cout << " (Expected pattern: 0x" << std::hex << write_pattern << ")"
            << std::endl;
  assert(compare_wide_data(read_data_a_ptr, expected_data.data(),
                           BLOCK_WIDTH_WORDS));

  // 检查 端口 B
  const uint32_t *read_data_b_ptr = get_way_data_ptr_b(top, other_way);
  std::cout << "  Port B, Way " << other_way << " Data: ";
  print_wide_data(read_data_b_ptr, BLOCK_WIDTH_WORDS);
  std::cout << " (Expected pattern: 0x0)" << std::endl;
  assert(
      compare_wide_data(read_data_b_ptr, zero_data.data(), BLOCK_WIDTH_WORDS));

  std::cout << "--- [PASSED] All 2R1W DataArray checks passed! ---"
            << std::endl;

  delete top;
  return 0;
}