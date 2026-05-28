// 文件: csrc/test_tag_array.cpp (修改版)
#include "Vtb_tag_array.h" // 包含 Verilator 生成的模块头文件
#include "verilated.h"
#include <cassert>
#include <iomanip>
#include <iostream>

vluint64_t main_time = 0;

void tick(Vtb_tag_array *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

// (新) 辅助函数：从 VlWide 输出中提取指定 Way 的 Tag
// 我们假设 rdata_tag_a_o 和 rdata_tag_b_o 都是 VlWide 数组
// 这个函数现在接收 VlWide 数组的基指针
uint32_t get_tag(const uint32_t *rdata_tag_array, int way) {
  const int TAG_WIDTH = 20;
  const uint32_t MASK = (1U << TAG_WIDTH) - 1;

  // --- START: 复制自你原文件的 VlWide 提取逻辑 ---
  // (注意: 这段逻辑非常特定，如果 Verilator 打包方式改变，它可能会失败)
  if (way == 0) {
    return rdata_tag_array[0] & MASK;
  } else if (way == 1) {
    uint64_t combined =
        (uint64_t(rdata_tag_array[1]) << 32) | rdata_tag_array[0];
    return (combined >> 20) & MASK;
  } else if (way == 2) {
    uint64_t combined =
        (uint64_t(rdata_tag_array[1]) << 32) | rdata_tag_array[0];
    uint64_t combined2 =
        (uint64_t(rdata_tag_array[2]) << 32) | rdata_tag_array[1];
    uint64_t val = (combined2 << 8) | (combined >> 24);
    return (val >> 16) & MASK;
  } else if (way == 3) {
    uint64_t combined =
        (uint64_t(rdata_tag_array[2]) << 32) | rdata_tag_array[1];
    return (combined >> 28) & MASK;
  }
  // --- END: 复制的 VlWide 提取逻辑 ---

  return 0;
}

// (新) 辅助函数：获取指定 Way 的 Valid 位
// rdata_valid_a_o 和 rdata_valid_b_o 应该是简单的 4-bit 整数
bool get_valid(uint32_t rdata_valid_vector, int way) {
  return (rdata_valid_vector >> way) & 1;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_tag_array *top = new Vtb_tag_array;

  std::cout << "--- [START] Running C++ test for 2R1W TagArray ---"
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
  top->wdata_tag_i = 0;
  top->wdata_valid_i = 0;
  tick(top);
  top->rst_ni = 1;
  std::cout << "[" << main_time << "] Reset complete." << std::endl;

  // --- 测试 1: 写入特定 Way/Bank/Addr ---
  int test_bank = 1;
  int test_addr = 0x42;
  int test_way = 2;
  uint32_t test_tag = 0xABCD;
  bool test_valid = 1;

  std::cout << "--- Test 1: Write ---" << std::endl;
  top->w_bank_addr_i = test_addr; // 使用写端口
  top->w_bank_sel_i = test_bank;
  top->we_way_mask_i = (1 << test_way);
  top->wdata_tag_i = test_tag;
  top->wdata_valid_i = test_valid;
  tick(top);

  // 停止写入
  top->we_way_mask_i = 0;
  top->eval();

  // --- 测试 2: 同时读回写入的数据和未写入的数据 ---
  std::cout << "--- Test 2: Simultaneous Dual Read ---" << std::endl;
  int unwritten_bank = 3;
  int unwritten_addr = 0x88;
  int check_way = 1;

  // 设置两个独立的读请求
  top->bank_addr_ra_i = test_addr; // 端口 A 读写入的地址
  top->bank_sel_ra_i = test_bank;
  top->bank_addr_rb_i = unwritten_addr; // 端口 B 读未写入的地址
  top->bank_sel_rb_i = unwritten_bank;
  tick(top);

  // 检查 端口 A (读取写入的数据)
  uint32_t read_tag_a = get_tag(top->rdata_tag_a_o, test_way);
  bool read_valid_a = get_valid(top->rdata_valid_a_o, test_way);
  std::cout << "  Port A, Way " << test_way << " Tag:   0x" << std::hex
            << read_tag_a << " (Expected: 0x" << test_tag << ")" << std::endl;
  std::cout << "  Port A, Way " << test_way << " Valid: " << std::dec
            << read_valid_a << " (Expected: " << test_valid << ")" << std::endl;
  assert(read_tag_a == test_tag);
  assert(read_valid_a == test_valid);

  // 检查 端口 B (读取未写入的数据)
  uint32_t read_tag_b = get_tag(top->rdata_tag_b_o, check_way);
  bool read_valid_b = get_valid(top->rdata_valid_b_o, check_way);
  std::cout << "  Port B, Way " << check_way << " Tag:   0x" << std::hex
            << read_tag_b << " (Expected: 0x0)" << std::endl;
  std::cout << "  Port B, Way " << check_way << " Valid: " << std::dec
            << read_valid_b << " (Expected: 0)" << std::endl;
  assert(read_tag_b == 0);
  assert(read_valid_b == 0);

  std::cout << "--- [PASSED] All 2R1W TagArray checks passed! ---" << std::endl;

  delete top;
  return 0;
}