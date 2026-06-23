// csrc/test_dcache.cpp
#include "Vtb_dcache.h"
#include <assert.h>
#include <iostream>
#include <vector>
#include <verilated.h>
#include <verilated_vcd_c.h>

#define MAX_SIM_TIME 10000
vluint64_t sim_time = 0;

// -------------------------------------------------------------------------
// Helper Functions
// -------------------------------------------------------------------------

void tick(Vtb_dcache *top, VerilatedVcdC *tfp) {
  top->flush_i = 0;
  top->clk_i = 0;
  top->eval();
#if VM_TRACE
  if (tfp) tfp->dump(sim_time);
#endif
  sim_time++;
  top->clk_i = 1;
  top->eval();
#if VM_TRACE
  if (tfp) tfp->dump(sim_time);
#endif
  sim_time++;
}

void reset(Vtb_dcache *top, VerilatedVcdC *tfp) {
  top->ld_req_id_i = 0;
  top->ld_rsp_ready_i = 0;
  top->rst_ni = 0;
  tick(top, tfp);
  tick(top, tfp);
  top->rst_ni = 1;
  tick(top, tfp);
}

// 等待直到 Cache 准备好接收请求
void wait_until_ready(Vtb_dcache *top, VerilatedVcdC *tfp, bool is_store) {
  while (sim_time < MAX_SIM_TIME) {
    if (is_store && top->st_req_ready_o)
      return;
    if (!is_store && top->ld_req_ready_o)
      return;
    tick(top, tfp);
  }
  std::cout << "Timeout waiting for ready!" << std::endl;
  exit(1);
}

// 处理缺失 (Miss) 和回写 (Writeback) 的通用函数
// 如果发生 Writeback，会自动处理并继续等待 Refill 请求
void handle_memory_interaction(Vtb_dcache *top, VerilatedVcdC *tfp,
                               uint32_t refill_data_val) {
  // 1. 检查是否先产生了 Writeback (Eviction) 请求
  // 注意：DUT 可能会在发出 miss_req 之前先发出 wb_req
  // 或者在状态机中先处理 WB。我们需要轮询直到出现 miss 或 wb。

  bool miss_handled = false;

  while (!miss_handled && sim_time < MAX_SIM_TIME) {
    // Case A: Writeback Request (脏行被逐出)
    if (top->wb_req_valid_o) {
      // std::cout << "  [Mem] Handling Writeback: Addr=" << std::hex <<
      // top->wb_req_paddr_o
      //           << " Data=" << top->wb_req_data_o[0] << std::endl;
      top->wb_req_ready_i = 1; // 模拟内存接收写回数据
      tick(top, tfp);
      top->wb_req_ready_i = 0;
      // Writeback 完成后，状态机通常会转去处理 Miss，继续循环
    }

    // Case B: Miss Request (需要从内存 Refill)
    else if (top->miss_req_valid_o) {
      // std::cout << "  [Mem] Handling Miss: Addr=" << std::hex <<
      // top->miss_req_paddr_o << std::endl;
      uint32_t req_addr = top->miss_req_paddr_o;
      uint32_t victim_way = top->miss_req_victim_way_o;

      top->miss_req_ready_i = 1; // 接受读请求
      tick(top, tfp);
      top->miss_req_ready_i = 0;

      // 模拟内存延迟
      tick(top, tfp);
      tick(top, tfp);

      // 发送 Refill 数据
      top->refill_valid_i = 1;
      top->refill_paddr_i = req_addr; // 必须匹配请求地址
      top->refill_way_i = victim_way; // 必须回传 victim way

      // 简单起见，填充整个 Cache Line 为重复的 32-bit 数据，或者根据地址生成
      // 注意：根据你的 Cache Line 宽度，这里可能需要填充 refill_data_i[1], [2]
      // 等
      for (int i = 0; i < 8; i++)
        top->refill_data_i[i] = refill_data_val;

      tick(top, tfp);
      top->refill_valid_i = 0;

      miss_handled = true; // Miss 处理完毕
    } else {
      // 既没有 WB 也没有 Miss，继续等待
      tick(top, tfp);
    }
  }
}

// 发起读请求并校验结果
void check_load(Vtb_dcache *top, VerilatedVcdC *tfp, uint32_t addr,
                uint32_t expected_data, int op, const char *msg) {
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = addr;
  top->ld_req_op_i = op;
  top->ld_req_id_i = 0;

  bool req_accepted = false;
  while (!req_accepted && sim_time < MAX_SIM_TIME) {
    if (top->ld_req_ready_o) {
      tick(top, tfp); // handshake
      req_accepted = true;
      break;
    } else if (top->miss_req_valid_o || top->wb_req_valid_o) {
      handle_memory_interaction(top, tfp, expected_data);
      continue;
    }
    tick(top, tfp);
  }
  top->ld_req_valid_i = 0;
  if (!req_accepted) {
    std::cout << "[FAIL] " << msg << " load request not accepted." << std::endl;
    assert(false);
  }

  // 检查是否 Hit 还是 Miss
  // 如果下一拍 miss_req_valid_o 拉高，说明 Miss 了
  // 但由于是组合逻辑输出，当前拍如果状态机跳转，输出可能已经变了。
  // 我们简单地循环等待 Response，中间夹杂处理 Memory 交互

  bool got_resp = false;
  while (!got_resp && sim_time < MAX_SIM_TIME) {
    if (top->ld_rsp_valid_o) {
      if (top->ld_rsp_id_o != 0) {
        std::cout << "[FAIL] " << msg << " unexpected ld_rsp_id=" << top->ld_rsp_id_o << std::endl;
        assert(false);
      }
      if (top->ld_rsp_data_o != expected_data) {
        std::cout << "[FAIL] " << msg << " Addr=" << std::hex << addr
                  << " Exp=" << expected_data << " Got=" << top->ld_rsp_data_o
                  << std::endl;
        assert(false);
      } else {
        std::cout << "[PASS] " << msg << std::endl;
      }
      top->ld_rsp_ready_i = 1; // 接收数据
      tick(top, tfp);
      top->ld_rsp_ready_i = 0;
      got_resp = true;
    } else if (top->miss_req_valid_o || top->wb_req_valid_o) {
      // 如果没有命中，需要处理内存填充
      // 假设内存里全是 0x88888888 用于区分，或者由调用者指定
      // 这里为了简单，如果 Miss，默认填充 expected_data (为了让 Load 成功)
      // 但在 Store Miss 测试中可能需要区分。
      handle_memory_interaction(top, tfp, expected_data);
    } else {
      tick(top, tfp);
    }
  }
  if (!got_resp) {
    std::cout << "[FAIL] " << msg << " load response timeout." << std::endl;
    assert(false);
  }
}

// 发起写请求
void send_store(Vtb_dcache *top, VerilatedVcdC *tfp, uint32_t addr,
                uint32_t data, int op) {
  top->st_req_valid_i = 1;
  top->st_req_addr_i = addr;
  top->st_req_data_i = data;
  top->st_req_op_i = op;

  bool req_accepted = false;
  while (!req_accepted && sim_time < MAX_SIM_TIME) {
    if (top->st_req_ready_o) {
      tick(top, tfp); // handshake
      req_accepted = true;
      break;
    } else if (top->miss_req_valid_o || top->wb_req_valid_o) {
      handle_memory_interaction(top, tfp, 0x00000000);
      continue;
    }
    tick(top, tfp);
  }
  top->st_req_valid_i = 0;
  if (!req_accepted) {
    std::cout << "[FAIL] store request not accepted at addr=0x" << std::hex << addr
              << std::endl;
    assert(false);
  }

  // 等待 Store 完成 (Store 可能触发 Miss/WB)
  // Store 完成的标志是状态机回到 IDLE。
  // 由于没有显式的 st_resp 信号，我们通过观察 ready
  // 信号恢复来判断，或者处理潜在的 Miss

  // 简单处理：只要不 Ready，就可能有内存交互
  int timeout = 0;
  while (!top->st_req_ready_o && timeout < 100) {
    if (top->miss_req_valid_o || top->wb_req_valid_o) {
      // Store Miss 时的 Refill 数据通常是旧内存数据
      // 我们填 0，这样如果 Store 成功，Load 回来的应该是新数据而不是 0
      handle_memory_interaction(top, tfp, 0x00000000);
    }
    tick(top, tfp);
    timeout++;
  }
}

void drain_background_traffic(Vtb_dcache *top, VerilatedVcdC *tfp,
                              uint32_t refill_data_val, int max_rounds = 8) {
  for (int r = 0; r < max_rounds; r++) {
    bool seen = false;
    for (int i = 0; i < 40; i++) {
      if (top->miss_req_valid_o || top->wb_req_valid_o) {
        handle_memory_interaction(top, tfp, refill_data_val);
        seen = true;
        break;
      }
      tick(top, tfp);
    }
    if (!seen) return;
  }
}

// -------------------------------------------------------------------------
// Main Test Bench
// -------------------------------------------------------------------------

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_dcache *top = new Vtb_dcache;
  VerilatedVcdC *tfp = nullptr;
#if VM_TRACE
  tfp = new VerilatedVcdC;
  Verilated::traceEverOn(true);
  top->trace(tfp, 99);
  tfp->open("dcache_trace.vcd");
#endif

  reset(top, tfp);

  // op codes (match decode_pkg.sv)
  const int OP_LB = 0, OP_LH = 1, OP_LW = 2, OP_LD = 3;
  const int OP_LBU = 4, OP_LHU = 5, OP_LWU = 6;
  const int OP_SB = 7, OP_SH = 8, OP_SW = 9, OP_SD = 10;

  std::cout << "--- Starting Enhanced D-Cache Tests ---" << std::endl;

  // ============================================================
  // Test 1: Basic Load Miss & Refill
  // ============================================================
  // 读 0x80001000, 期望 miss, refill 后得到 0x12345678
  check_load(top, tfp, 0x80001000, 0x12345678, OP_LW, "Case 1: Load Miss");

  // ============================================================
  // Test 2: Store Hit (Modify Data)
  // ============================================================
  // 写 0x80001000 (已在 Cache 中), 写入 0xDEADBEEF
  send_store(top, tfp, 0x80001000, 0xDEADBEEF, OP_SW);
  std::cout << "[INFO] Case 2: Store issued." << std::endl;

  // ============================================================
  // Test 3: Load Hit (Verify Store)
  // ============================================================
  // 读 0x80001000, 期望命中并返回 0xDEADBEEF
  check_load(top, tfp, 0x80001000, 0xDEADBEEF, OP_LW, "Case 3: Load Hit");

  // ============================================================
  // Test 4: Store Miss (Write Allocate)
  // ============================================================
  // 写一个不在 Cache 中的地址 0x80002000
  // 预期行为: Miss -> Refill (Old Mem=0) -> Cache Merge (New=0xCAFEBABE) ->
  // Idle
  std::cout << "[TEST] Case 4: Store Miss (Write Allocate)" << std::endl;
  send_store(top, tfp, 0x80002000, 0xCAFEBABE, OP_SW);
  drain_background_traffic(top, tfp, 0x00000000);

  // 验证: 读回来应该是 0xCAFEBABE，而不是 Refill 的 0x00000000
  check_load(top, tfp, 0x80002000, 0xCAFEBABE, OP_LW,
             "Case 4: Load after Store Miss");

  // ============================================================
  // Test 5: Sub-word Access (Byte/Half Operations)
  // ============================================================
  std::cout << "[TEST] Case 5: Sub-word Access" << std::endl;
  uint32_t base = 0x80003000;

  // 1. 初始化该行: 读一次触发 Miss Refill，填入全 0
  check_load(top, tfp, base, 0x00000000, OP_LW, "Case 5: Init line");

  // 2. 写入字节: base+0 = 0x11
  send_store(top, tfp, base + 0, 0x11, OP_SB);
  // 3. 写入半字: base+2 = 0x2233
  send_store(top, tfp, base + 2, 0x2233, OP_SH);

  // 4. 读取验证
  // Word 读取应为 0x22330011 (假设小端序，中间字节未变仍为0)
  check_load(top, tfp, base, 0x22330011, OP_LW, "Case 5: Mixed Size Read");

  // Byte 读取
  check_load(top, tfp, base, 0x11, OP_LBU, "Case 5: LBU check");

  // ============================================================
  // Test 6: Eviction / Capacity Miss (Verify Writeback)
  // ============================================================
  std::cout << "[TEST] Case 6: Forced Eviction (Capacity Thrashing)"
            << std::endl;
  // 这是一个基于概率的测试（因为使用了 LFSR 替换策略），
  // 但如果我们写入足够多的映射到同一 Index 的不同地址，必然会触发 Eviction。
  // 假设 Index Width = 6 (64 sets), Offset = 4 (16 bytes).
  // 我们固定 Index，不断改变 Tag。

  uint32_t alias_base = 0x90000000; // 高位不同，Index 相同(假设低位对齐)
  int conflict_count = 16;          // 远大于可能的 Way 数 (通常 2 或 4)

  // 1. 填满 Cache Set 并标记为 Dirty
  for (int i = 0; i < conflict_count; i++) {
    uint32_t addr =
        alias_base + (i * 0x10000); // 步长足够大以改变 Tag，保持 Index 不变
    // Store 会标记为 Dirty
    // Miss 处理时，handle_memory_interaction 会自动处理之前可能的 WB
    send_store(top, tfp, addr, i + 1, OP_SW);
  }

  // 2. 此时，之前的某些行肯定被踢出了。
  // 我们可以通过观测 handle_memory_interaction 中的打印来确认 WB 是否发生。
  // 或者在 Verilator 波形中查看 `wb_req_valid_o` 是否有脉冲。
  std::cout << "Case 6: Completed. Check waveform for 'wb_req_valid_o' pulses."
            << std::endl;

  // ============================================================
  // Test 7: Misalignment Check
  // ============================================================
  std::cout << "[TEST] Case 7: Misalignment" << std::endl;
  // 尝试读取非对齐地址 0x80001001 (Word access)
  wait_until_ready(top, tfp, false);
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = 0x80001001;
  top->ld_req_op_i = OP_LW;
  tick(top, tfp);
  top->ld_req_valid_i = 0;

  // 等待响应，期望 ld_rsp_err_o 为 1
  bool err_detected = false;
  for (int i = 0; i < 10; i++) {
    if (top->ld_rsp_valid_o) {
      if (top->ld_rsp_err_o)
        err_detected = true;
      break;
    }
    tick(top, tfp);
  }

  if (err_detected)
    std::cout << "[PASS] Case 7: Misalignment Error Detected." << std::endl;
  else
    std::cout << "[FAIL] Case 7: No Error on Misalignment." << std::endl;

  // ============================================================
  // Test 8: Non-blocking miss allocation (MSHR behavior)
  // ============================================================
  std::cout << "[TEST] Case 8: Non-blocking second miss before first refill"
            << std::endl;

  reset(top, tfp);
  top->miss_req_ready_i = 0;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 0;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;

  // First load miss request.
  wait_until_ready(top, tfp, false);
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = 0x80004000;
  top->ld_req_op_i = OP_LW;
  tick(top, tfp);
  top->ld_req_valid_i = 0;

  bool first_miss_seen = false;
  for (int i = 0; i < 30; i++) {
    if (top->wb_req_valid_o) {
      top->wb_req_ready_i = 1;
      tick(top, tfp);
      top->wb_req_ready_i = 0;
      continue;
    }
    if (top->miss_req_valid_o) {
      first_miss_seen = true;
      top->miss_req_ready_i = 1;
      tick(top, tfp); // handshake first miss
      top->miss_req_ready_i = 0;
      break;
    }
    tick(top, tfp);
  }
  if (!first_miss_seen) {
    std::cout << "[FAIL] Case 8: first miss request not observed." << std::endl;
    assert(false);
  }

  // Keep first miss outstanding (no refill yet), then issue second load miss.
  bool second_req_accepted = false;
  for (int i = 0; i < 30; i++) {
    if (top->ld_req_ready_o) {
      second_req_accepted = true;
      top->ld_req_valid_i = 1;
      top->ld_req_addr_i = 0x80005000;
      top->ld_req_op_i = OP_LW;
      tick(top, tfp); // handshake second request
      top->ld_req_valid_i = 0;
      break;
    }
    tick(top, tfp);
  }
  if (!second_req_accepted) {
    std::cout << "[FAIL] Case 8: second miss cannot be accepted while first miss "
                 "is pending."
              << std::endl;
    assert(false);
  }

  bool second_miss_seen = false;
  for (int i = 0; i < 30; i++) {
    if (top->wb_req_valid_o) {
      top->wb_req_ready_i = 1;
      tick(top, tfp);
      top->wb_req_ready_i = 0;
      continue;
    }
    if (top->miss_req_valid_o) {
      second_miss_seen = true;
      break;
    }
    tick(top, tfp);
  }
  if (!second_miss_seen) {
    std::cout << "[FAIL] Case 8: second miss request not issued before first "
                 "refill."
              << std::endl;
    assert(false);
  }
  std::cout << "[PASS] Case 8: Non-blocking miss path works." << std::endl;

  // ============================================================
  // Test 9: Store miss should not be blocked by pending load miss
  // ============================================================
  std::cout << "[TEST] Case 9: Store miss with pending load miss" << std::endl;

  reset(top, tfp);
  top->miss_req_ready_i = 1;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 1;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;

  // First load miss request.
  wait_until_ready(top, tfp, false);
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = 0x80006000;
  top->ld_req_op_i = OP_LW;
  tick(top, tfp);
  top->ld_req_valid_i = 0;

  int miss_fire_count = 0;
  for (int i = 0; i < 40; i++) {
    if (top->miss_req_valid_o && top->miss_req_ready_i) {
      miss_fire_count++;
      tick(top, tfp);
      break;
    }
    tick(top, tfp);
  }
  if (miss_fire_count < 1) {
    std::cout << "[FAIL] Case 9: first miss request not observed." << std::endl;
    assert(false);
  }

  // Keep first miss outstanding (no refill yet), then issue store miss.
  wait_until_ready(top, tfp, true);
  top->st_req_valid_i = 1;
  top->st_req_addr_i = 0x80007000;
  top->st_req_data_i = 0xA5A5A5A5;
  top->st_req_op_i = OP_SW;
  tick(top, tfp);
  top->st_req_valid_i = 0;

  bool second_store_miss_seen = false;
  for (int i = 0; i < 60; i++) {
    if (top->miss_req_valid_o && top->miss_req_ready_i) {
      miss_fire_count++;
      second_store_miss_seen = true;
      tick(top, tfp);
      break;
    }
    tick(top, tfp);
  }
  if (!second_store_miss_seen || miss_fire_count < 2) {
    std::cout << "[FAIL] Case 9: store miss request not issued while first load "
                 "miss is pending."
              << std::endl;
    assert(false);
  }
  std::cout << "[PASS] Case 9: Store miss non-blocking path works." << std::endl;

  // ============================================================
  // Test 10: Accept next load while previous load response is stalled
  // ============================================================
  std::cout << "[TEST] Case 10: Queue load req during response stall" << std::endl;

  reset(top, tfp);
  top->miss_req_ready_i = 1;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 1;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;

  const uint32_t case10_a = 0x80008000;
  const uint32_t case10_a_data = 0x11112222;

  // Warm up one line into cache (both requests hit the same line afterwards).
  check_load(top, tfp, case10_a, case10_a_data, OP_LW, "Case 10: Warmup A");

  // First load (A) -> let response become valid, but do not consume it yet.
  wait_until_ready(top, tfp, false);
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case10_a;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 1;
  tick(top, tfp);
  top->ld_req_valid_i = 0;
  top->ld_rsp_ready_i = 0;

  bool first_rsp_seen = false;
  for (int i = 0; i < 20; i++) {
    if (top->ld_rsp_valid_o) {
      first_rsp_seen = true;
      break;
    }
    tick(top, tfp);
  }
  if (!first_rsp_seen) {
    std::cout << "[FAIL] Case 10: first load response not observed." << std::endl;
    assert(false);
  }
  if (top->ld_rsp_data_o != case10_a_data || top->ld_rsp_id_o != 1) {
    std::cout << "[FAIL] Case 10: first response payload mismatch." << std::endl;
    assert(false);
  }

  // With the 1-cycle hit path a stalled hit response is presented in S_LOOKUP
  // for one cycle; the port only buffers the next request after it falls back to
  // S_RESP. Advance one cycle (response stays valid because ld_rsp_ready_i is 0)
  // so request B can be queued, exactly as the slow path always did.
  tick(top, tfp);
  if (!top->ld_rsp_valid_o || top->ld_rsp_data_o != case10_a_data ||
      top->ld_rsp_id_o != 1) {
    std::cout << "[FAIL] Case 10: first response not held across stall."
              << std::endl;
    assert(false);
  }

  // Response channel is stalled now.
  top->eval();

  // Second load (B) should still be accepted while first response is stalled.
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case10_a;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 0;
  top->eval();
  if (!top->ld_req_ready_o) {
    std::cout << "[FAIL] Case 10: second load not accepted during response stall."
              << std::endl;
    assert(false);
  }
  tick(top, tfp); // handshake second request
  top->ld_req_valid_i = 0;

  // Release first response.
  top->ld_rsp_ready_i = 1;
  tick(top, tfp);

  // Then second response should eventually arrive with id=0/data=A.
  bool second_rsp_seen = false;
  for (int i = 0; i < 30; i++) {
    if (top->ld_rsp_valid_o) {
      if (top->ld_rsp_id_o == 0) {
        if (top->ld_rsp_data_o != case10_a_data) {
          std::cout << "[FAIL] Case 10: second response payload mismatch."
                    << std::endl;
          assert(false);
        }
        tick(top, tfp); // consume second response
        second_rsp_seen = true;
        break;
      }
    }
    if (top->miss_req_valid_o || top->wb_req_valid_o) {
      handle_memory_interaction(top, tfp, case10_a_data);
      continue;
    }
    tick(top, tfp);
  }
  if (!second_rsp_seen) {
    std::cout << "[FAIL] Case 10: second response not observed." << std::endl;
    assert(false);
  }
  std::cout << "[PASS] Case 10: Load queueing during response stall works."
            << std::endl;

  // ============================================================
  // Test 11: Do not accept same-line load during miss LOOKUP cycle
  // ============================================================
  std::cout << "[TEST] Case 11: Block same-line load in miss LOOKUP" << std::endl;

  reset(top, tfp);
  top->miss_req_ready_i = 1;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 1;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;

  const uint32_t case11_addr = 0x80009000;

  // First load: make it miss.
  wait_until_ready(top, tfp, false);
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case11_addr;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 0;
  tick(top, tfp); // handshake first request; next cycle enters LOOKUP.
  top->ld_req_valid_i = 0;

  // In LOOKUP cycle, second same-line load must not be accepted.
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case11_addr;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 1;
  top->eval();
  if (top->ld_req_ready_o) {
    std::cout << "[FAIL] Case 11: second same-line load accepted in miss LOOKUP."
              << std::endl;
    assert(false);
  }
  top->ld_req_valid_i = 0;
  std::cout << "[PASS] Case 11: same-line load blocked in miss LOOKUP."
            << std::endl;

  // ============================================================
  // Test 12: Response ID/data pairing under response stall
  // ============================================================
  std::cout << "[TEST] Case 12: Keep ID/data pairing with stalled response"
            << std::endl;

  reset(top, tfp);
  top->miss_req_ready_i = 1;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 1;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;

  const uint32_t case12_a = 0x8000A000;
  const uint32_t case12_b = 0x8000B000;
  const uint32_t case12_a_data = 0xA1A2A3A4;
  const uint32_t case12_b_data = 0xB1B2B3B4;

  check_load(top, tfp, case12_a, case12_a_data, OP_LW, "Case 12: Warmup A");
  check_load(top, tfp, case12_b, case12_b_data, OP_LW, "Case 12: Warmup B");

  // First request A(id=1), then hold response channel.
  wait_until_ready(top, tfp, false);
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case12_a;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 1;
  tick(top, tfp);
  top->ld_req_valid_i = 0;
  top->ld_rsp_ready_i = 0;

  bool case12_first_rsp_seen = false;
  for (int i = 0; i < 30; i++) {
    if (top->ld_rsp_valid_o) {
      case12_first_rsp_seen = true;
      break;
    }
    tick(top, tfp);
  }
  if (!case12_first_rsp_seen) {
    std::cout << "[FAIL] Case 12: first response not observed." << std::endl;
    assert(false);
  }
  if (top->ld_rsp_id_o != 1 || top->ld_rsp_data_o != case12_a_data) {
    std::cout << "[FAIL] Case 12: first response payload mismatch."
              << " id=" << std::hex << static_cast<int>(top->ld_rsp_id_o)
              << " data=0x" << top->ld_rsp_data_o << std::endl;
    assert(false);
  }

  // 1-cycle hit path: move the stalled hit from S_LOOKUP into S_RESP so the next
  // request can be buffered (response is held while ld_rsp_ready_i is low).
  tick(top, tfp);
  if (!top->ld_rsp_valid_o || top->ld_rsp_id_o != 1 ||
      top->ld_rsp_data_o != case12_a_data) {
    std::cout << "[FAIL] Case 12: first response not held across stall."
              << std::endl;
    assert(false);
  }

  // While first response is stalled, second request B(id=0) must be accepted.
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case12_b;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 0;
  top->eval();
  if (!top->ld_req_ready_o) {
    std::cout << "[FAIL] Case 12: second request not accepted while stalled."
              << std::endl;
    assert(false);
  }
  tick(top, tfp);
  top->ld_req_valid_i = 0;

  // Consume first response.
  top->ld_rsp_ready_i = 1;
  tick(top, tfp);

  // Then second response must carry B(id=0,data=B).
  bool case12_second_rsp_seen = false;
  for (int i = 0; i < 40; i++) {
    if (top->ld_rsp_valid_o && top->ld_rsp_id_o == 0) {
      if (top->ld_rsp_data_o != case12_b_data) {
        std::cout << "[FAIL] Case 12: second response data mismatch. got=0x"
                  << std::hex << top->ld_rsp_data_o << " exp=0x"
                  << case12_b_data << std::endl;
        assert(false);
      }
      tick(top, tfp);
      case12_second_rsp_seen = true;
      break;
    }
    if (top->miss_req_valid_o || top->wb_req_valid_o) {
      handle_memory_interaction(top, tfp, case12_b_data);
      continue;
    }
    tick(top, tfp);
  }
  if (!case12_second_rsp_seen) {
    std::cout << "[FAIL] Case 12: second response not observed." << std::endl;
    assert(false);
  }
  std::cout << "[PASS] Case 12: ID/data pairing is preserved." << std::endl;

  // ============================================================
  // Test 12B: Response handoff should start next lookup without IDLE bubble
  // ============================================================
  std::cout << "[TEST] Case 12B: Response handoff no-bubble lookup" << std::endl;

  reset(top, tfp);
  top->miss_req_ready_i = 1;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 1;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;

  const uint32_t case14_addr = 0x8000C000;
  const uint32_t case14_data = 0xCC33AA55;

  // Warm one cache line so both requests are hit path.
  check_load(top, tfp, case14_addr, case14_data, OP_LW, "Case 12B: Warmup");

  // First hit request (id=1), wait until response is valid.
  wait_until_ready(top, tfp, false);
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case14_addr;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 1;
  tick(top, tfp);
  top->ld_req_valid_i = 0;

  bool case14_first_rsp_seen = false;
  for (int i = 0; i < 20; i++) {
    if (top->ld_rsp_valid_o) {
      case14_first_rsp_seen = true;
      break;
    }
    tick(top, tfp);
  }
  if (!case14_first_rsp_seen) {
    std::cout << "[FAIL] Case 12B: first response not observed." << std::endl;
    assert(false);
  }
  if (top->ld_rsp_data_o != case14_data || top->ld_rsp_id_o != 1) {
    std::cout << "[FAIL] Case 12B: first response payload mismatch." << std::endl;
    assert(false);
  }

  // On response consume cycle, inject second hit request (id=0) simultaneously.
  top->ld_rsp_ready_i = 1;
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case14_addr;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 0;
  top->eval();
  if (!top->ld_req_ready_o) {
    std::cout << "[FAIL] Case 12B: second request not accepted on handoff cycle."
              << std::endl;
    assert(false);
  }
  tick(top, tfp); // consume first response (A) + accept second request (B)
  top->ld_req_valid_i = 0;
  top->ld_rsp_ready_i = 0; // hold B's response to observe the single-cycle latency

  // With the lookup fast path the handoff lands directly in S_LOOKUP, so B's
  // response is already valid this very cycle (1-cycle hit latency, no bubble).
  top->eval();
  if (!top->ld_rsp_valid_o) {
    std::cout << "[FAIL] Case 12B: second response missing at single-cycle timing."
              << std::endl;
    assert(false);
  }
  if (top->ld_rsp_id_o != 0 || top->ld_rsp_data_o != case14_data) {
    std::cout << "[FAIL] Case 12B: second response payload mismatch."
              << " id=" << std::hex << static_cast<int>(top->ld_rsp_id_o)
              << " data=0x" << top->ld_rsp_data_o << std::endl;
    assert(false);
  }
  top->ld_rsp_ready_i = 1;
  tick(top, tfp);
  std::cout << "[PASS] Case 12B: Response handoff starts next lookup immediately."
            << std::endl;

  // ============================================================
  // Test 12C: Response handoff must predrive next lookup address
  // ============================================================
  std::cout << "[TEST] Case 12C: Response handoff cross-line no-stale-read"
            << std::endl;

  reset(top, tfp);
  top->miss_req_ready_i = 1;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 1;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;

  const uint32_t case12c_a = 0x8000D040;
  const uint32_t case12c_b = 0x8000D080;
  const uint32_t case12c_a_data = 0x11223344;
  const uint32_t case12c_b_data = 0x55667788;

  check_load(top, tfp, case12c_a, case12c_a_data, OP_LW, "Case 12C: Warmup A");
  check_load(top, tfp, case12c_b, case12c_b_data, OP_LW, "Case 12C: Warmup B");

  // First hit request A(id=1), wait until response is valid.
  wait_until_ready(top, tfp, false);
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case12c_a;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 1;
  tick(top, tfp);
  top->ld_req_valid_i = 0;

  bool case12c_first_rsp_seen = false;
  for (int i = 0; i < 20; i++) {
    if (top->ld_rsp_valid_o) {
      case12c_first_rsp_seen = true;
      break;
    }
    tick(top, tfp);
  }
  if (!case12c_first_rsp_seen) {
    std::cout << "[FAIL] Case 12C: first response not observed." << std::endl;
    assert(false);
  }
  if (top->ld_rsp_data_o != case12c_a_data || top->ld_rsp_id_o != 1) {
    std::cout << "[FAIL] Case 12C: first response payload mismatch." << std::endl;
    assert(false);
  }

  // On response consume cycle, inject second hit request to a different line B(id=0).
  top->ld_rsp_ready_i = 1;
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case12c_b;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 0;
  top->eval();
  if (!top->ld_req_ready_o) {
    std::cout << "[FAIL] Case 12C: second request not accepted on handoff cycle."
              << std::endl;
    assert(false);
  }
  tick(top, tfp); // consume first response (A) + accept second request (B)
  top->ld_req_valid_i = 0;
  top->ld_rsp_ready_i = 0; // hold B's response to observe the single-cycle latency

  // With the lookup fast path the predriven address means B is looked up the very
  // next cycle: B's response must be valid now and carry B's payload (not stale A).
  top->eval();
  if (!top->ld_rsp_valid_o) {
    std::cout << "[FAIL] Case 12C: second response missing at single-cycle timing."
              << std::endl;
    assert(false);
  }
  if (top->ld_rsp_id_o != 0 || top->ld_rsp_data_o != case12c_b_data) {
    std::cout << "[FAIL] Case 12C: stale or mismatched payload."
              << " id=" << std::hex << static_cast<int>(top->ld_rsp_id_o)
              << " data=0x" << top->ld_rsp_data_o << " exp=0x"
              << case12c_b_data << std::endl;
    assert(false);
  }
  top->ld_rsp_ready_i = 1;
  tick(top, tfp);
  std::cout << "[PASS] Case 12C: handoff cross-line read data is correct."
            << std::endl;

  // ============================================================
  // Test 12D: Sustained load hits return one response per cycle
  // ============================================================
  std::cout << "[TEST] Case 12D: Sustained hit throughput (1 load/cycle)"
            << std::endl;

  reset(top, tfp);
  top->miss_req_ready_i = 1;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 1;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;

  const uint32_t case12d_addr = 0x8000E000;
  const uint32_t case12d_data = 0x0F1E2D3C;

  // Warm the line so every subsequent load to it hits.
  check_load(top, tfp, case12d_addr, case12d_data, OP_LW, "Case 12D: Warmup");

  // Drive a continuous stream of hitting loads with the response channel ready.
  top->ld_rsp_ready_i = 1;
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case12d_addr;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 0;

  const int kStreamCycles = 16;
  int case12d_rsp_fire = 0;
  for (int i = 0; i < kStreamCycles; i++) {
    top->eval();
    if (top->ld_rsp_valid_o && top->ld_rsp_ready_i) {
      if (top->ld_rsp_data_o != case12d_data || top->ld_rsp_id_o != 0) {
        std::cout << "[FAIL] Case 12D: streamed response payload mismatch. data=0x"
                  << std::hex << top->ld_rsp_data_o
                  << " id=" << static_cast<int>(top->ld_rsp_id_o) << std::endl;
        assert(false);
      }
      case12d_rsp_fire++;
    }
    tick(top, tfp);
  }
  top->ld_req_valid_i = 0;

  // Steady state is one response per cycle. Over kStreamCycles we should observe
  // at least kStreamCycles-2 responses (allow a short pipeline fill margin).
  if (case12d_rsp_fire < kStreamCycles - 2) {
    std::cout << "[FAIL] Case 12D: sustained hit throughput too low. rsp_fire="
              << std::dec << case12d_rsp_fire << "/" << kStreamCycles << std::endl;
    assert(false);
  }
  std::cout << "[PASS] Case 12D: sustained load hits return ~1/cycle. rsp_fire="
            << std::dec << case12d_rsp_fire << "/" << kStreamCycles << std::endl;

  // ============================================================
  // Test 13: Reset must invalidate cache contents
  // ============================================================
  std::cout << "[TEST] Case 13: Reset invalidates cache lines" << std::endl;

  const uint32_t case13_addr = 0x80001234;
  const uint32_t case13_data = 0x13579BDF;

  // Populate one line first.
  reset(top, tfp);
  top->miss_req_ready_i = 1;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 1;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;
  check_load(top, tfp, case13_addr, case13_data, OP_LW, "Case 13: Warm line");

  // Reset DUT again. After reset, the same address must miss (cannot hit stale line).
  reset(top, tfp);
  top->miss_req_ready_i = 1;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 1;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;

  wait_until_ready(top, tfp, false);
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = case13_addr;
  top->ld_req_op_i = OP_LW;
  top->ld_req_id_i = 0;
  tick(top, tfp);  // handshake
  top->ld_req_valid_i = 0;

  bool case13_seen_miss = false;
  bool case13_seen_rsp_early = false;
  for (int i = 0; i < 20; i++) {
    if (top->miss_req_valid_o) {
      case13_seen_miss = true;
      break;
    }
    if (top->ld_rsp_valid_o) {
      case13_seen_rsp_early = true;
      break;
    }
    tick(top, tfp);
  }

  if (case13_seen_rsp_early || !case13_seen_miss) {
    std::cout << "[FAIL] Case 13: load hit stale cache line after reset."
              << std::endl;
    assert(false);
  }
  std::cout << "[PASS] Case 13: reset causes miss as expected." << std::endl;

  // Complete miss/refill and check response payload.
  handle_memory_interaction(top, tfp, case13_data);
  bool case13_rsp_ok = false;
  for (int i = 0; i < 30; i++) {
    if (top->ld_rsp_valid_o) {
      if (top->ld_rsp_data_o != case13_data || top->ld_rsp_id_o != 0) {
        std::cout << "[FAIL] Case 13: response payload mismatch after refill."
                  << std::endl;
        assert(false);
      }
      top->ld_rsp_ready_i = 1;
      tick(top, tfp);
      top->ld_rsp_ready_i = 0;
      case13_rsp_ok = true;
      break;
    }
    tick(top, tfp);
  }
  if (!case13_rsp_ok) {
    std::cout << "[FAIL] Case 13: no response after refill." << std::endl;
    assert(false);
  }

  // ============================================================
  // Test 14: Deep miss-under-miss capacity (12+ outstanding misses)
  // ============================================================
  std::cout << "[TEST] Case 14: 12+ outstanding misses before refill" << std::endl;

  reset(top, tfp);
  top->miss_req_ready_i = 1;
  top->refill_valid_i = 0;
  top->wb_req_ready_i = 1;
  top->ld_rsp_ready_i = 1;
  top->st_req_valid_i = 0;
  top->ld_req_valid_i = 0;

  constexpr int kTargetMisses = 12;
  int issued_load_misses = 0;
  int fired_miss_reqs = 0;
  int cycles = 0;

  while ((issued_load_misses < kTargetMisses || fired_miss_reqs < kTargetMisses) &&
         cycles < 2000) {
    top->eval();
    if (top->miss_req_valid_o && top->miss_req_ready_i) {
      fired_miss_reqs++;
    }

    if (issued_load_misses < kTargetMisses && top->ld_req_ready_o) {
      top->ld_req_valid_i = 1;
      top->ld_req_addr_i = 0x81000000 + static_cast<uint32_t>(issued_load_misses * 0x1000);
      top->ld_req_op_i = OP_LW;
      top->ld_req_id_i = static_cast<uint32_t>(issued_load_misses & 0x1);
      tick(top, tfp);
      top->ld_req_valid_i = 0;
      issued_load_misses++;
    } else {
      tick(top, tfp);
    }
    cycles++;
  }

  if (issued_load_misses < kTargetMisses || fired_miss_reqs < kTargetMisses) {
    std::cout << "[FAIL] Case 14: outstanding miss depth too shallow. issued="
              << issued_load_misses << " miss_fire=" << fired_miss_reqs << std::endl;
    assert(false);
  }
  std::cout << "[PASS] Case 14: dcache accepts >=12 outstanding misses."
            << std::endl;

  // Cleanup
  for (int i = 0; i < 20; i++)
    tick(top, tfp);
#if VM_TRACE
  if (tfp) tfp->close();
#endif
  delete tfp;
  delete top;
  return 0;
}
