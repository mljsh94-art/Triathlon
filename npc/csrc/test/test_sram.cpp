// csrc/test_sram.cpp
#include "Vtb_sram.h"
#include "verilated.h"
#include <cassert>
#include <iostream>

vluint64_t main_time = 0;

void tick(Vtb_sram *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_sram *top = new Vtb_sram;

  std::cout << "--- [START] Running C++ test for 1RW SRAM (32-bit) ---"
            << std::endl;

  // 1. 初始化与复位
  top->rst_ni = 0;
  top->we_i = 0;
  top->addr_i = 0;
  top->wdata_i = 0;
  tick(top);
  top->rst_ni = 1;
  std::cout << "[" << main_time << "] Reset complete." << std::endl;

  // --- 测试 1: 写入数据 ---
  std::cout << "--- Test 1: Write ---" << std::endl;

  // 写入地址 5
  top->we_i = 1;
  top->addr_i = 5;
  top->wdata_i = 0xCAFEBABE; // 32-bit Hex
  std::cout << "[" << main_time << "] Writing 0xCAFEBABE to addr=5"
            << std::endl;
  tick(top);

  // 写入地址 10
  top->addr_i = 10;
  top->wdata_i = 0xDEADBEEF; // 32-bit Hex
  std::cout << "[" << main_time << "] Writing 0xDEADBEEF to addr=10"
            << std::endl;
  tick(top);

  // 停止写入
  top->we_i = 0;

  // --- 测试 2: 读取数据 ---
  std::cout << "--- Test 2: Read ---" << std::endl;

  // 读取地址 5
  top->addr_i = 5;
  // 同步读：设置地址后需要 tick 一次才能读到数据
  tick(top);

  std::cout << "[" << main_time << "] Read Addr 5. Got: " << std::hex
            << top->rdata_o << " (Expected: 0xcafebabe)" << std::endl;
  assert(top->rdata_o == 0xCAFEBABE);

  // 读取地址 10
  top->addr_i = 10;
  tick(top);

  std::cout << "[" << main_time << "] Read Addr 10. Got: " << std::hex
            << top->rdata_o << " (Expected: 0xdeadbeef)" << std::endl;
  assert(top->rdata_o == 0xDEADBEEF);

  // 读取未写入的地址 (地址 0)
  top->addr_i = 0;
  tick(top);

  std::cout << "[" << main_time << "] Read Addr 0. Got: " << std::hex
            << top->rdata_o << std::endl;

  std::cout << "--- [PASSED] All 1RW SRAM checks passed! ---" << std::endl;

  delete top;
  return 0;
}