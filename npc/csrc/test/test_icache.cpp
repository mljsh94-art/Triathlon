// csrc/test_icache.cpp
#include "Vtb_icache.h"
#include "verilated.h"
#include <cassert>
#include <deque>
#include <iomanip>
#include <iostream>
#include <map>
#include <vector>

// =================================================================
// 常量定义 (应与配置匹配)
// =================================================================
// 这些值应与 Cfg 匹配
const int VLEN = 32;
const int ILEN = 32;
// 内部使用 64 位地址以避免 C++ 警告
const int PLEN = 64;
const int INSTR_PER_FETCH = 4;
// ICACHE_LINE_WIDTH 在 test_config_pkg 中是 256
const int LINE_WIDTH_BITS = 256;
const int LINE_WIDTH_BYTES = LINE_WIDTH_BITS / 8;     // 32 bytes
const int LINE_WIDTH_WORDS_32 = LINE_WIDTH_BITS / 32; // 8 words

// 仿真时间
vluint64_t main_time = 0;

// =================================================================
// 内存模拟器
// =================================================================

class SimulatedMemory {
private:
  // (Line 地址, Cache Line 数据块)
  std::map<uint64_t, std::vector<uint32_t>> memory_data;

  // 模拟状态机
  enum State { IDLE, WAIT_DELAY, SEND_REFILL };
  State state;
  int delay_counter;

  // 暂存当前的 Miss 请求信息
  uint64_t pending_addr;
  uint32_t pending_victim_way;
  int miss_req_count = 0;

public:
  SimulatedMemory()
      : state(IDLE), delay_counter(0), pending_addr(0), pending_victim_way(0) {}

  /**
   * @brief 在 tick() 开始时调用。处理内存响应（Refill）作为 DUT 的输入。
   * 替代了原来的 provide_response
   */
  void provide_refill(Vtb_icache *top) {
    // 1. 内存始终准备好接收 Miss 请求
    top->miss_req_ready_i = 1;

    // 2. 处理 Refill 逻辑
    top->refill_valid_i = 0; // 默认拉低

    if (state == WAIT_DELAY) {
      if (delay_counter > 0) {
        delay_counter--;
      } else {
        state = SEND_REFILL;
      }
    }

    if (state == SEND_REFILL) {
      // 发送 Refill 数据
      uint64_t line_addr = pending_addr & ~((uint64_t)LINE_WIDTH_BYTES - 1);

      std::cout << "[" << main_time
                << "] MEM: -> ICache: Refill Valid=1, Addr=0x" << std::hex
                << pending_addr << " Way=" << pending_victim_way << std::endl;

      top->refill_valid_i = 1;
      top->refill_paddr_i = pending_addr;     // 把请求的地址传回去
      top->refill_way_i = pending_victim_way; // 指定填充到哪个 Way

      // 填充数据
      if (memory_data.count(line_addr)) {
        const auto &data = memory_data[line_addr];
        for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i) {
          top->refill_data_i[i] = data[i];
        }
      } else {
        // 如果没有预加载数据，填充默认值
        for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i) {
          top->refill_data_i[i] = 0xBAD0BAD0;
        }
        std::cout << "        WARNING: No data preloaded for address 0x"
                  << std::hex << line_addr << std::endl;
      }

      // 检查 Cache 是否接收了 Refill (握手)
      // 注意：在组合逻辑中 refill_valid_i 设为 1 后，如果 DUT
      // 准备好，refill_ready_o 应该为 1 但由于是在 provide_refill (tick开始)
      // 调用，我们需要在下一次 tick 或 eval 后确认状态
      // 这里简化处理：假设只要我发了，Cache 处于 MISS_WAIT_REFILL 状态就会收
    }
  }

  /**
   * @brief 在 tick() 中 clk=0, eval() 之后调用。捕获 ICache 请求（Miss）。
   * 替代了原来的 capture_request
   */
  void capture_miss_req(Vtb_icache *top) {
    // 如果正在发送 Refill 且 Cache 接收了，则回到 IDLE
    if (state == SEND_REFILL && top->refill_ready_o) {
      state = IDLE;
      std::cout << "[" << main_time << "] MEM: Refill Accepted. State -> IDLE"
                << std::endl;
    }

    // 处理新的 Miss 请求
    // 只有当 ICache 发送 Miss 且模拟器处于 IDLE 时处理
    if (top->miss_req_valid_o && top->miss_req_ready_i && state == IDLE) {
      miss_req_count++;
      pending_addr = top->miss_req_paddr_o;
      pending_victim_way = top->miss_req_victim_way_o;

      // 地址对齐到 Cache Line 边界
      uint64_t line_addr = pending_addr & ~((uint64_t)LINE_WIDTH_BYTES - 1);

      std::cout << "[" << main_time << "] MEM: <- ICache: Miss Req, Addr=0x"
                << std::hex << pending_addr << " (Line Addr=0x" << line_addr
                << ")"
                << " VictimWay=" << std::dec << pending_victim_way << std::endl;

      state = WAIT_DELAY;
      delay_counter = 10; // 模拟 10 个周期的内存延迟
    }
  }

  /**
   * @brief 预加载内存数据到模拟器中
   */
  void preload_data(uint64_t addr, const std::vector<uint32_t> &data) {
    uint64_t line_addr = addr & ~((uint64_t)LINE_WIDTH_BYTES - 1);
    memory_data[line_addr] = data;
  }

  void reset_miss_req_count() { miss_req_count = 0; }
  int get_miss_req_count() const { return miss_req_count; }
};

/**
 * @brief 驱动一个完整的时钟周期，并处理内存接口时序
 * * @param top Verilator 顶层模块指针
 * @param memory 内存模拟器指针
 */
void tick(Vtb_icache *top, SimulatedMemory *memory) {
  // 1. 内存模拟器更新其输出信号 (refill_valid/data)
  memory->provide_refill(top);

  // 2. 时钟低电平
  top->clk_i = 0;
  top->eval(); // 组合逻辑计算出 miss_req_o

  // 3. 在时钟变高前，捕获ICache发出的 Miss 请求
  memory->capture_miss_req(top);
  main_time++;

  // 4. 时钟高电平 (触发寄存器更新)
  top->clk_i = 1;
  top->eval();
  main_time++;
}

struct CycleObs {
  bool req_ready = false;
  bool rsp_valid = false;
  uint32_t rsp_instr0 = 0;
};

CycleObs cycle_step_with_req(Vtb_icache *top, SimulatedMemory *memory,
                             bool req_valid, uint32_t req_pc) {
  top->ifu_req_valid_i = req_valid ? 1 : 0;
  top->ifu_req_pc_i = req_pc;

  memory->provide_refill(top);

  top->clk_i = 0;
  top->eval();

  CycleObs obs{};
  obs.req_ready = (top->ifu_rsp_ready_o != 0);
  obs.rsp_valid = (top->ifu_rsp_valid_o != 0);
  obs.rsp_instr0 = top->ifu_rsp_instrs_o[0];

  memory->capture_miss_req(top);
  main_time++;

  top->clk_i = 1;
  top->eval();
  main_time++;

  return obs;
}

// =================================================================
// 测试用例辅助函数
// =================================================================

/**
 * @brief 设置 IFU 请求 (新接口只包含 PC)
 */
void set_ifu_request(Vtb_icache *top, uint32_t pc) {
  top->ifu_req_valid_i = 1;
  top->ifu_req_pc_i = pc;
}

/**
 * @brief 清除 IFU 请求
 */
void clear_ifu_request(Vtb_icache *top) { top->ifu_req_valid_i = 0; }

/**
 * @brief 运行一个完整的测试场景
 */
bool run_test_case(Vtb_icache *top, SimulatedMemory *memory,
                   const char *test_name, uint32_t req_pc,
                   const std::vector<uint32_t> &expected_data) {

  std::cout << "\n--- Test Case: " << test_name << " ---" << std::endl;
  assert(expected_data.size() == INSTR_PER_FETCH);

  // 1. 发起 IFU 请求
  set_ifu_request(top, req_pc);

  int max_cycles = 200;
  bool done = false;

  for (int i = 0; i < max_cycles; ++i) {
    tick(top, memory);

    // 2. 检查 IFU 响应
    // 注意：现在的 icache 中，ifu_rsp_valid_o 指示数据有效
    if (top->ifu_rsp_valid_o) {
      std::cout << "[" << main_time
                << "] IFU: <- ICache: 'ifu_rsp_valid_o' = 1. Data received."
                << std::endl;
      done = true;
      for (int j = 0; j < INSTR_PER_FETCH; ++j) {
        if (top->ifu_rsp_instrs_o[j] != expected_data[j]) {
          std::cout << "    [ERROR] Instr " << j << " Fail. Got: 0x" << std::hex
                    << top->ifu_rsp_instrs_o[j] << " Expected: 0x"
                    << expected_data[j] << " at PC: 0x" << req_pc << std::endl;
          // 确保测试失败时停止
          assert(false);
        }
      }

      clear_ifu_request(top); // IFU 停止请求
      break;
    }
  }

  if (!done) {
    std::cout << "    [ERROR] Test failed: Timeout after " << max_cycles
              << " cycles." << std::endl;
    assert(false); // 超时也触发断言失败
  }

  return done;
}

bool run_back_to_back_hit_throughput_test(Vtb_icache *top, SimulatedMemory *memory) {
  std::cout << "\n--- Test Case: 6: Back-to-Back Hit Throughput ---" << std::endl;
  std::deque<uint32_t> reqs = {0x80000000, 0x80000010};
  std::vector<uint32_t> expected = {0x80000000, 0x80000010};
  std::vector<int> rsp_cycles;

  int max_cycles = 40;
  int logical_cycle = 0;
  int rsp_idx = 0;

  for (int i = 0; i < max_cycles; i++) {
    bool req_valid = !reqs.empty();
    uint32_t req_pc = req_valid ? reqs.front() : 0;
    CycleObs obs = cycle_step_with_req(top, memory, req_valid, req_pc);

    if (req_valid && obs.req_ready) {
      reqs.pop_front();
    }

    if (obs.rsp_valid && rsp_idx < static_cast<int>(expected.size()) &&
        obs.rsp_instr0 == expected[rsp_idx]) {
      rsp_cycles.push_back(logical_cycle);
      rsp_idx++;
    }

    logical_cycle++;
    if (rsp_idx == static_cast<int>(expected.size())) {
      break;
    }
  }

  if (rsp_cycles.size() != expected.size()) {
    std::cout << "    [ERROR] back-to-back hit response count mismatch. got="
              << rsp_cycles.size() << " expected=" << expected.size() << std::endl;
    assert(false);
  }

  int gap = rsp_cycles[1] - rsp_cycles[0];
  if (gap != 1) {
    std::cout << "    [ERROR] expected back-to-back responses (gap=1), got gap="
              << gap << " (rsp0_cycle=" << rsp_cycles[0]
              << ", rsp1_cycle=" << rsp_cycles[1] << ")" << std::endl;
    assert(false);
  }

  std::cout << "--- Test 6 PASSED ---" << std::endl;
  return true;
}

// =================================================================
// Main
// =================================================================

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_icache *top = new Vtb_icache;
  SimulatedMemory memory;

  std::cout << "--- [START] Running C++ test for ICache ---" << std::endl;

  // 1. 预加载内存数据
  // Line 1: 0x80000000 ~ 0x8000001F (Index 0x00)
  std::vector<uint32_t> line_data1(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    line_data1[i] = 0x80000000 + i * 4;
  memory.preload_data(0x80000000, line_data1);

  // Line 2: 0x80000020 ~ 0x8000003F (Index 0x01)
  std::vector<uint32_t> line_data2(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    line_data2[i] = 0x80000020 + i * 4;
  memory.preload_data(0x80000020, line_data2);

  // Line 3: 0x80000040 ~ 0x8000005F (Index 0x02)
  std::vector<uint32_t> line_data3(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    line_data3[i] = 0x80000040 + i * 4;
  memory.preload_data(0x80000040, line_data3);

  // --- 为置换测试预加载数据 ---
  // 地址的 [9:5] 位是 index。以下地址的 index 都为 1。
  // Tag = addr[31:10]
  // Addr A: 0x80000020 -> Index=1, Tag=0x20000
  // Addr B: 0x80000420 -> Index=1, Tag=0x20001
  // Addr C: 0x80000820 -> Index=1, Tag=0x20002
  // Addr D: 0x80000C20 -> Index=1, Tag=0x20003
  // Addr E: 0x80001020 -> Index=1, Tag=0x20004 (用于触发置换)

  uint32_t repl_addr_A = 0x80000020; // 已在 line_data2 中预加载
  uint32_t repl_addr_B = 0x80000420;
  uint32_t repl_addr_C = 0x80000820;
  uint32_t repl_addr_D = 0x80000C20;
  uint32_t repl_addr_E = 0x80001020;

  std::vector<uint32_t> repl_data_B(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    repl_data_B[i] = repl_addr_B + i * 4;
  memory.preload_data(repl_addr_B, repl_data_B);

  std::vector<uint32_t> repl_data_C(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    repl_data_C[i] = repl_addr_C + i * 4;
  memory.preload_data(repl_addr_C, repl_data_C);

  std::vector<uint32_t> repl_data_D(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    repl_data_D[i] = repl_addr_D + i * 4;
  memory.preload_data(repl_addr_D, repl_data_D);

  std::vector<uint32_t> repl_data_E(LINE_WIDTH_WORDS_32);
  for (int i = 0; i < LINE_WIDTH_WORDS_32; ++i)
    repl_data_E[i] = repl_addr_E + i * 4;
  memory.preload_data(repl_addr_E, repl_data_E);

  // 2. 复位
  top->rst_ni = 0;
  clear_ifu_request(top);
  top->ifu_req_flush_i = 0;
  memory.provide_refill(top);
  tick(top, &memory); // 确保复位期间有时钟沿
  top->rst_ni = 1;
  main_time++;
  std::cout << "[" << main_time << "] Reset complete." << std::endl;

  // =================================================================
  //  Test 1: 单行 Miss (Addr 0x80000000)
  // =================================================================
  memory.reset_miss_req_count();
  bool test1_passed = run_test_case(
      top, &memory, "1: Single Line Miss (0x80000000)", 0x80000000,
      {0x80000000, 0x80000004, 0x80000008, 0x8000000C});
  assert(test1_passed);
  if (memory.get_miss_req_count() != 1) {
    std::cout << "    [ERROR] expected single miss request, got "
              << memory.get_miss_req_count() << std::endl;
    assert(false);
  }
  std::cout << "--- Test 1 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 2: 单行 Hit (Addr 0x80000010, 仍在 Line 1)
  // =================================================================
  bool test2_passed =
      run_test_case(top, &memory, "2: Single Line Hit (0x80000010)", 0x80000010,
                    {0x80000010, 0x80000014, 0x80000018, 0x8000001C});
  assert(test2_passed);
  std::cout << "--- Test 2 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 2.5: 半字对齐取指 (Addr 0x80000002)
  // =================================================================
  bool test25_passed = run_test_case(
      top, &memory, "2.5: Halfword-Aligned Fetch (0x80000002)", 0x80000002,
      {0x00048000, 0x00088000, 0x000C8000, 0x00108000});
  assert(test25_passed);
  std::cout << "--- Test 2.5 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 2.6: 半字对齐取指 + 非零 start_slot (Addr 0x8000002A)
  // =================================================================
  bool test26_passed = run_test_case(
      top, &memory, "2.6: Halfword-Aligned Fetch (0x8000002A)", 0x8000002A,
      {0x002C8000, 0x00308000, 0x00348000, 0x00388000});
  assert(test26_passed);
  std::cout << "--- Test 2.6 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 3: 跨行 Hit-Miss (Addr 0x80000018 & 0x80000020)
  // =================================================================
  // Line 1 (0x80000000) Hit, Line 2 (0x80000020) Miss
  // 期望数据: 0x18, 0x1C (from Line 1), 0x20, 0x24 (from Line 2)
  bool test3_passed = run_test_case(
      top, &memory, "3: Cross-Line Hit-Miss (0x80000018)", 0x80000018,
      {0x80000018, 0x8000001C, 0x80000020, 0x80000024});
  assert(test3_passed);
  std::cout << "--- Test 3 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 4: 跨行 Hit-Miss (Addr 0x80000038 & 0x80000040)
  // =================================================================
  // Line 2 (0x80000020) Hit (Test 3 中已 Refill), Line 3 (0x80000040) Miss
  bool test4_passed = run_test_case(
      top, &memory, "4: Cross-Line Hit-Miss (0x80000038)", 0x80000038,
      {0x80000038, 0x8000003C, 0x80000040, 0x80000044});
  assert(test4_passed);
  std::cout << "--- Test 4 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 5: Cache Line Replacement
  // =================================================================
  std::cout << "\n--- Test Case: 5: Cache Line Replacement ---" << std::endl;
  // 1: 访问 Addr B, C, D，填满 Index=1 的所有 way (Addr A 已经在 Test 3 中加载)
  // 注意: 只需要请求每行的首地址即可触发 Refill
  run_test_case(
      top, &memory, "5.1: Fill Set 1 (Addr B)", repl_addr_B,
      {repl_addr_B, repl_addr_B + 4, repl_addr_B + 8, repl_addr_B + 12});
  tick(top, &memory);

  run_test_case(
      top, &memory, "5.2: Fill Set 1 (Addr C)", repl_addr_C,
      {repl_addr_C, repl_addr_C + 4, repl_addr_C + 8, repl_addr_C + 12});
  tick(top, &memory);

  run_test_case(
      top, &memory, "5.3: Fill Set 1 (Addr D)", repl_addr_D,
      {repl_addr_D, repl_addr_D + 4, repl_addr_D + 8, repl_addr_D + 12});
  tick(top, &memory);

  // 2: 访问 Addr E，这会替换掉 Set 1 中的某一个 Line
  std::cout << "--- Now requesting Addr E to trigger replacement ---"
            << std::endl;
  run_test_case(
      top, &memory, "5.4: Trigger Replacement (Addr E)", repl_addr_E,
      {repl_addr_E, repl_addr_E + 4, repl_addr_E + 8, repl_addr_E + 12});
  tick(top, &memory);

  // 3: 再次访问 Addr A (或 B,C,D 中的任何一个)。
  // 如果是随机替换或 LRU 近似，A 可能还在也可能不在。
  // 但由于我们只有 4 路，而我们访问了 A, B, C, D, E
  // (5个不同Tag)，必然有一个被踢出。 这里我们简单重新访问
  // A，验证它是否正确返回数据（无论是 Hit 还是 Miss+Refill，只要数据对就行）
  // 如果被踢出，ICache 将重新发起 Refill。
  std::cout << "--- Now requesting Addr A again ---" << std::endl;
  bool test5_passed = run_test_case(
      top, &memory, "5.5: Verify Replacement (Re-fetch Addr A)", 0x80000020,
      {0x80000020, 0x80000024, 0x80000028, 0x8000002C});
  assert(test5_passed);
  std::cout << "--- Test 5 PASSED ---" << std::endl;

  // 清理: 运行一个周期，清除状态
  tick(top, &memory);

  // =================================================================
  //  Test 6: Back-to-Back Hit Throughput
  // =================================================================
  bool test6_passed = run_back_to_back_hit_throughput_test(top, &memory);
  assert(test6_passed);

  std::cout << "\n--- [END] All tests PASSED for ICache ---" << std::endl;
  delete top;
  return 0;
}
