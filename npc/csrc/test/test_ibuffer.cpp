// csrc/test_ibuffer.cpp
#include "Vtb_ibuffer.h"
#include "verilated.h"
#include <cassert>
#include <deque>
#include <iomanip>
#include <iostream>
#include <random>
#include <vector>

// --- 配置参数 (需与 SV 保持一致) ---
const int INSTR_PER_FETCH = 4; // Fetch 宽度
const int DECODE_WIDTH = 4;    // Decode 宽度
const int IB_DEPTH = 8;        // 测试模块中定义的深度
const int ILEN_BYTES = 4;      // 32-bit 指令

vluint64_t main_time = 0;

struct Instruction {
  uint32_t inst;
  uint32_t pc;
  uint8_t slot_valid;
  uint32_t pred_npc;
};

// C++ 端维护的 Golden Model
std::deque<Instruction> expected_queue;

void tick(Vtb_ibuffer *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

void reset(Vtb_ibuffer *top) {
  top->rst_ni = 0;
  top->flush_i = 0;
  top->fe_valid_i = 0;
  top->ibuf_ready_i = 0;
  // 清空输入数据
  for (int i = 0; i < INSTR_PER_FETCH; ++i)
    top->fe_instrs_i[i] = 0;
  top->fe_slot_valid_i = 0;
  for (int i = 0; i < INSTR_PER_FETCH; ++i) {
    top->fe_pred_npc_i[i] = 0;
  }
  top->fe_pc_i = 0;

  tick(top);
  tick(top);
  top->rst_ni = 1;
  expected_queue.clear();
  std::cout << "[Reset] Done." << std::endl;
}

// 辅助函数：设置输入 Fetch Group
void set_fetch_group(Vtb_ibuffer *top, uint32_t base_pc,
                     const std::vector<uint32_t> &instrs) {
  assert(instrs.size() == INSTR_PER_FETCH);
  top->fe_pc_i = base_pc;
  top->fe_slot_valid_i = 0;

  // Verilator 的宽端口通常是 uint32_t 数组 (WData)
  // fe_instrs_i 是 128 位 (4 * 32)
  // 假设它是 Little Endian: [0]是低位(Instr0), [3]是高位(Instr3)
  // 如果 SV 中是 packed [3:0][31:0]，则 instrs[0] 对应低位
  for (int i = 0; i < INSTR_PER_FETCH; ++i) {
    top->fe_instrs_i[i] = instrs[i];
    top->fe_slot_valid_i |= (1u << i);
    top->fe_pred_npc_i[i] = base_pc + (i + 1) * ILEN_BYTES;
  }
}

void set_fetch_group_mask(Vtb_ibuffer *top, uint32_t base_pc,
                          const std::vector<uint32_t> &instrs,
                          uint8_t slot_valid_mask) {
  assert(instrs.size() == INSTR_PER_FETCH);
  top->fe_pc_i = base_pc;
  top->fe_slot_valid_i = slot_valid_mask;
  for (int i = 0; i < INSTR_PER_FETCH; ++i) {
    top->fe_instrs_i[i] = instrs[i];
    top->fe_pred_npc_i[i] = base_pc + (i + 1) * ILEN_BYTES;
  }
}

// 辅助函数：从输出读取 Decode Group
std::vector<Instruction> get_decode_group(Vtb_ibuffer *top) {
  std::vector<Instruction> group;
  for (int i = 0; i < DECODE_WIDTH; ++i) {
    Instruction instr;
    // 同样假设展平后的映射关系
    instr.inst = top->ibuf_instrs_o[i];

    // PC 是 64 位 (PLEN=64 假设)，如果是 32 位则只需取低位
    // ibuf_pcs_o 是 [4 * PLEN]，在 C++ 中如果是 WData (uint32_t[])
    // 假设 PLEN=32，则 ibuf_pcs_o[i] 就是 PC
    // 假设 PLEN=64，则 ibuf_pcs_o[2*i] 和 [2*i+1] 组成 PC
    // 根据您的 config_pkg，PLEN 通常等于 XLEN/VLEN (32 或 64)
    // 这里为了兼容性，假设 PLEN=32 (常见测试配置) 或者 64
    // 您的 build_config_pkg 中: cfg.PLEN = user_cfg.VLEN (32)
    // 所以它是 32 位 PC。
    instr.pc = top->ibuf_pcs_o[i];
    instr.slot_valid = (top->ibuf_slot_valid_o >> i) & 0x1;
    instr.pred_npc = top->ibuf_pred_npc_o[i];

    group.push_back(instr);
  }
  return group;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_ibuffer *top = new Vtb_ibuffer;

  // 随机数生成器
  std::mt19937 rng(12345);
  std::uniform_int_distribution<uint32_t> dist_instr(0, 0xFFFFFFFF);
  std::uniform_int_distribution<int> dist_bool(0, 1);

  std::cout << "--- [START] IBuffer Verification ---" << std::endl;
  reset(top);

  // =========================================================
  // TDD RED/GREEN: Elastic output behavior checks
  // =========================================================
  // Case 1: Empty queue + FE valid + decode ready => same-cycle output (bypass)
  {
    const uint32_t base_pc = 0x80001000;
    const std::vector<uint32_t> instrs = {0x11111113, 0x22222223, 0x33333333,
                                          0x44444443};
    top->flush_i = 0;
    top->fe_valid_i = 1;
    top->ibuf_ready_i = 1;
    set_fetch_group_mask(top, base_pc, instrs, 0b0011); // 2 valid lanes
    top->clk_i = 0;
    top->eval();

    if (!top->fe_ready_o) {
      std::cerr << "[fail] expected FE ready for empty bypass case" << std::endl;
      delete top;
      return 1;
    }
    if (!top->ibuf_valid_o) {
      std::cerr << "[fail] expected same-cycle ibuf_valid in empty bypass case"
                << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_instrs_o[0] != instrs[0] || top->ibuf_pcs_o[0] != base_pc ||
        top->ibuf_slot_valid_o != 0b0011) {
      std::cerr << "[fail] bypass output mismatch in empty bypass case"
                << std::endl;
      delete top;
      return 1;
    }
    top->clk_i = 1;
    top->eval();
    main_time++;
  }

  // Case 2: Queue has 2 entries, FE provides 2 entries => same-cycle merge to 4
  //   cycle A: enqueue 2 entries while decode not ready.
  //   cycle B: decode ready + FE provides 2 more entries; expect 4-lane output:
  //            {old0, old1, new0, new1}
  {
    reset(top);
    const uint32_t old_pc = 0x80002000;
    const uint32_t new_pc = 0x80003000;
    const std::vector<uint32_t> old_instrs = {0xaaaa0013, 0xaaaa0023, 0xaaaa0033,
                                              0xaaaa0043};
    const std::vector<uint32_t> new_instrs = {0xbbbb0013, 0xbbbb0023, 0xbbbb0033,
                                              0xbbbb0043};

    top->flush_i = 0;
    top->fe_valid_i = 1;
    top->ibuf_ready_i = 0;
    set_fetch_group_mask(top, old_pc, old_instrs, 0b0011);
    top->clk_i = 0;
    top->eval();
    if (!top->fe_ready_o) {
      std::cerr << "[fail] expected FE ready when enqueueing partial bundle"
                << std::endl;
      delete top;
      return 1;
    }
    top->clk_i = 1;
    top->eval();
    main_time++;

    top->flush_i = 0;
    top->fe_valid_i = 1;
    top->ibuf_ready_i = 1;
    set_fetch_group_mask(top, new_pc, new_instrs, 0b0011);
    top->clk_i = 0;
    top->eval();

    if (!top->ibuf_valid_o) {
      std::cerr << "[fail] expected ibuf_valid in elastic-merge case" << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_slot_valid_o != 0b1111) {
      std::cerr << "[fail] expected full 4-lane slot_valid after merge, got 0x"
                << std::hex << static_cast<uint32_t>(top->ibuf_slot_valid_o)
                << std::dec << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_instrs_o[0] != old_instrs[0] ||
        top->ibuf_instrs_o[1] != old_instrs[1] ||
        top->ibuf_instrs_o[2] != new_instrs[0] ||
        top->ibuf_instrs_o[3] != new_instrs[1]) {
      std::cerr << "[fail] elastic merge lane content mismatch" << std::endl;
      delete top;
      return 1;
    }
    top->clk_i = 1;
    top->eval();
    main_time++;
  }

  // Case 3: RVC expansion in a single 32-bit slot.
  // slot0 = {c.nop, c.nop} should expand to two ADDI x0,x0,0 instructions.
  {
    reset(top);
    const uint32_t base_pc = 0x80004000;
    const std::vector<uint32_t> instrs = {0x00010001, 0, 0, 0};

    top->flush_i = 0;
    top->fe_valid_i = 1;
    top->ibuf_ready_i = 1;
    set_fetch_group_mask(top, base_pc, instrs, 0b0001);
    top->clk_i = 0;
    top->eval();

    if (!top->ibuf_valid_o) {
      std::cerr << "[fail] expected ibuf_valid in rvc expansion case"
                << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_slot_valid_o != 0b0011) {
      std::cerr << "[fail] expected two expanded slots in rvc case, got 0x"
                << std::hex << static_cast<uint32_t>(top->ibuf_slot_valid_o)
                << std::dec << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_instrs_o[0] != 0x00000013 || top->ibuf_instrs_o[1] != 0x00000013) {
      std::cerr << "[fail] rvc expansion opcode mismatch" << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_pcs_o[0] != base_pc || top->ibuf_pcs_o[1] != base_pc + 2) {
      std::cerr << "[fail] rvc expansion pc mismatch" << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_pred_npc_o[0] != base_pc + 2 || top->ibuf_pred_npc_o[1] != base_pc + 4) {
      std::cerr << "[fail] rvc expansion pred_npc mismatch" << std::endl;
      delete top;
      return 1;
    }

    top->clk_i = 1;
    top->eval();
    main_time++;
  }

  // Case 4: Mixed 16/32 stream where a 32-bit instruction high-halfword shares a
  // 32-bit fetch slot with the following compressed instruction.
  // Ensure parser consumes at halfword granularity instead of forwarding raw 32-bit slot.
  {
    reset(top);
    const uint32_t base_pc = 0x80005020;
    // Byte stream:
    //   0x00: c.nop (0x0001)
    //   0x02: addi x1, x0, 12 (0x00c00093)
    //   0x06: addi x2, x0, 1  (0x00100113)
    //   0x0a: c.nop (0x0001)
    const std::vector<uint32_t> instrs = {
        0x00930001, // bytes: 01 00 93 00
        0x011300c0, // bytes: c0 00 13 01
        0x00010010, // bytes: 10 00 01 00
        0x00000000,
    };

    top->flush_i = 0;
    top->fe_valid_i = 1;
    top->ibuf_ready_i = 1;
    set_fetch_group_mask(top, base_pc, instrs, 0b0111);
    top->clk_i = 0;
    top->eval();

    if (!top->ibuf_valid_o) {
      std::cerr << "[fail] expected ibuf_valid in mixed rvc/rv32 case" << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_slot_valid_o != 0b1111) {
      std::cerr << "[fail] expected 4 decoded instructions in mixed rvc/rv32 case, got 0x"
                << std::hex << static_cast<uint32_t>(top->ibuf_slot_valid_o)
                << std::dec << std::endl;
      delete top;
      return 1;
    }

    const uint32_t kExpInstr[4] = {0x00000013, 0x00c00093, 0x00100113, 0x00000013};
    const uint32_t kExpPc[4] = {base_pc + 0, base_pc + 2, base_pc + 6, base_pc + 10};
    const uint32_t kExpPredNpc[4] = {base_pc + 2, base_pc + 6, base_pc + 10, base_pc + 12};
    for (int i = 0; i < 4; ++i) {
      if (top->ibuf_instrs_o[i] != kExpInstr[i]) {
        std::cerr << "[fail] mixed rvc/rv32 inst mismatch at lane " << i << ", got 0x"
                  << std::hex << top->ibuf_instrs_o[i] << " expected 0x" << kExpInstr[i]
                  << std::dec << std::endl;
        delete top;
        return 1;
      }
      if (top->ibuf_pcs_o[i] != kExpPc[i]) {
        std::cerr << "[fail] mixed rvc/rv32 pc mismatch at lane " << i << ", got 0x"
                  << std::hex << top->ibuf_pcs_o[i] << " expected 0x" << kExpPc[i]
                  << std::dec << std::endl;
        delete top;
        return 1;
      }
      if (top->ibuf_pred_npc_o[i] != kExpPredNpc[i]) {
        std::cerr << "[fail] mixed rvc/rv32 pred_npc mismatch at lane " << i << ", got 0x"
                  << std::hex << top->ibuf_pred_npc_o[i] << " expected 0x" << kExpPredNpc[i]
                  << std::dec << std::endl;
        delete top;
        return 1;
      }
    }

    top->clk_i = 1;
    top->eval();
    main_time++;
  }

  // Case 5: non-NOP compressed control path.
  // slot0 = {c.ebreak, c.jr x1} => {ebreak, jalr x0,x1,0} after expansion.
  {
    reset(top);
    const uint32_t base_pc = 0x80006000;
    const std::vector<uint32_t> instrs = {0x90028082, 0, 0, 0};

    top->flush_i = 0;
    top->fe_valid_i = 1;
    top->ibuf_ready_i = 1;
    set_fetch_group_mask(top, base_pc, instrs, 0b0001);
    top->clk_i = 0;
    top->eval();

    if (!top->ibuf_valid_o) {
      std::cerr << "[fail] expected ibuf_valid in rvc control expansion case"
                << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_slot_valid_o != 0b0011) {
      std::cerr << "[fail] expected two expanded slots in rvc control case, got 0x"
                << std::hex << static_cast<uint32_t>(top->ibuf_slot_valid_o)
                << std::dec << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_instrs_o[0] != 0x00008067 || top->ibuf_instrs_o[1] != 0x00100073) {
      std::cerr << "[fail] rvc control expansion opcode mismatch" << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_pcs_o[0] != base_pc || top->ibuf_pcs_o[1] != base_pc + 2) {
      std::cerr << "[fail] rvc control expansion pc mismatch" << std::endl;
      delete top;
      return 1;
    }
    if (top->ibuf_pred_npc_o[0] != base_pc + 2 || top->ibuf_pred_npc_o[1] != base_pc + 4) {
      std::cerr << "[fail] rvc control expansion pred_npc mismatch" << std::endl;
      delete top;
      return 1;
    }

    top->clk_i = 1;
    top->eval();
    main_time++;
  }

  uint32_t current_fetch_pc = 0x80000000;
  int cycles = 100000;
  int accepted_instr_count = 0;
  int retired_instr_count = 0;

  for (int t = 0; t < cycles; ++t) {
    // --- 1. 驱动输入 (Frontend) ---
    bool try_fetch =
        (dist_bool(rng) ||
         expected_queue.size() < 4); // 随机尝试 Fetch，如果队列空则大概率 Fetch
    bool flush_now = (t > 50 && t % 200 == 0); // 周期性 Flush

    if (flush_now) {
      top->flush_i = 1;
      top->fe_valid_i = 0; // Flush 时通常前端无效
      expected_queue.clear();
      std::cout << "[" << main_time << "] FLUSH Asserted!" << std::endl;
    } else {
      top->flush_i = 0;
      top->fe_valid_i = try_fetch ? 1 : 0;

      if (try_fetch) {
        std::vector<uint32_t> instrs(INSTR_PER_FETCH);
        for (int i = 0; i < INSTR_PER_FETCH; ++i)
          instrs[i] = (dist_instr(rng) & ~0x3u) | 0x3u;
        set_fetch_group(top, current_fetch_pc, instrs);
      }
    }

    // --- 2. 驱动输入 (Backend) ---
    // 随机决定后端是否 Ready
    bool backend_ready = (dist_bool(rng) == 1);
    top->ibuf_ready_i = backend_ready;

    // --- 3. Evaluate (Rising Edge Logic) ---
    // 我们需要在时钟沿之前保存 inputs，tick 内部会 eval 组合逻辑 -> update
    // register 但为了正确模拟 handshake，我们需要知道 DUT
    // 在当前组合逻辑下的输出 (fe_ready_o, ibuf_valid_o)

    top->clk_i = 0;
    top->eval();

    // --- 4. 记分板逻辑 (Capture Fetch) ---
    if (!top->flush_i && top->fe_valid_i && top->fe_ready_o) {
      // 握手成功，将指令加入 Golden Model
      // 注意：因为上面已经 set_fetch_group 了，数据就在端口上
      for (int i = 0; i < INSTR_PER_FETCH; ++i) {
        Instruction instr;
        instr.inst = top->fe_instrs_i[i];
        instr.pc = current_fetch_pc + i * ILEN_BYTES;
        instr.slot_valid = (top->fe_slot_valid_i >> i) & 0x1;
        instr.pred_npc = top->fe_pred_npc_i[i];
        expected_queue.push_back(instr);
      }
      current_fetch_pc += INSTR_PER_FETCH * ILEN_BYTES;
      accepted_instr_count += INSTR_PER_FETCH;
      // std::cout << "  [Fetch] Accepted " << INSTR_PER_FETCH << " instrs." <<
      // std::endl;
    }

    // --- 5. 记分板逻辑 (Verify Decode) ---
    if (!top->flush_i && top->ibuf_valid_o && top->ibuf_ready_i) {
      // 后端握手成功，检查输出数据
      std::vector<Instruction> out_group = get_decode_group(top);

      assert(expected_queue.size() >= DECODE_WIDTH); // 确保有足够的数据

      for (int i = 0; i < DECODE_WIDTH; ++i) {
        Instruction expected = expected_queue.front();
        expected_queue.pop_front();
        Instruction actual = out_group[i];

        if (actual.inst != expected.inst || actual.pc != expected.pc) {
          std::cout << "[ERROR] Mismatch at time " << main_time << std::endl;
          std::cout << "  Expected: PC=0x" << std::hex << expected.pc
                    << " Inst=0x" << expected.inst << std::endl;
          std::cout << "  Actual:   PC=0x" << std::hex << actual.pc
                    << " Inst=0x" << actual.inst << std::endl;
          assert(false);
        }
        if (actual.slot_valid != expected.slot_valid ||
            actual.pred_npc != expected.pred_npc) {
          std::cout << "[ERROR] Metadata mismatch at time " << main_time
                    << std::endl;
          std::cout << "  Expected: valid=" << int(expected.slot_valid)
                    << " pred_npc=0x" << std::hex << expected.pred_npc
                    << std::endl;
          std::cout << "  Actual:   valid=" << int(actual.slot_valid)
                    << " pred_npc=0x" << std::hex << actual.pred_npc
                    << std::endl;
          assert(false);
        }
      }
      retired_instr_count += DECODE_WIDTH;
      // std::cout << "  [Decode] Retired " << DECODE_WIDTH << " instrs." <<
      // std::endl;
    }

    // --- 6. 检查 Flush 后的状态 ---
    if (top->flush_i) {
      // Flush 应该是组合逻辑生效 (fe_ready_o 可能变低或变高取决于实现，但
      // valid_o 必须为 0) 检查 ibuffer 是否立即响应 Flush (输出 valid 拉低)
      // ibuffer.sv 实现: assign ibuf_valid_o = (!flush_i) && ...
      assert(top->ibuf_valid_o == 0);
      // 指针复位是在时钟沿发生的，所以这里只是检查组合逻辑输出
    }

    // --- 7. Clock Tick ---
    // 这里 top->eval() 会更新时序逻辑 (Register Update)
    top->clk_i = 1;
    top->eval();
    main_time++;

    // --- 8. 边界情况检查 ---
    // 满状态检查: 如果队列里的预期指令数 >= IB_DEPTH (或者接近), fe_ready_o
    // 应该拉低 ibuffer.sv 逻辑: free_slots >= FETCH_WIDTH
    if (!top->flush_i && top->fe_valid_i) {
      if (expected_queue.size() > (IB_DEPTH - INSTR_PER_FETCH)) {
        // 空间不足以放一个完整的 Group
        if (top->fe_ready_o == 1) {
          std::cout << "[WARNING] IBuffer Full Check: Expected Size="
                    << expected_queue.size() << " Depth=" << IB_DEPTH
                    << " but fe_ready is 1." << std::endl;
          // 注意：这取决于具体的实现逻辑，如果允许溢出一点点或者计算方式不同，可能不是严格错误
          // 根据 ibuffer.sv: assign can_enq_group = (free_slots >= FETCH_WIDTH)
          assert(top->fe_ready_o == 0);
        }
      }
    }

    // 空状态检查
    if (!top->flush_i) {
      bool has_elastic_input = (top->fe_valid_i && top->fe_ready_o);
      if (expected_queue.empty() && !has_elastic_input) {
        if (top->ibuf_valid_o == 1) {
          std::cout << "[ERROR] IBuffer Empty Check: Expected Size="
                    << expected_queue.size() << " but ibuf_valid is 1."
                    << std::endl;
          assert(top->ibuf_valid_o == 0);
        }
      }
    }
  }

  std::cout << "--- Verification Statistics ---" << std::endl;
  std::cout << "Total Cycles: " << cycles << std::endl;
  std::cout << "Accepted Instructions: " << accepted_instr_count << std::endl;
  std::cout << "Retired Instructions:  " << retired_instr_count << std::endl;
  std::cout << "Final Queue Size:      " << expected_queue.size() << std::endl;

  if (expected_queue.size() > IB_DEPTH) {
    std::cout << "[WARNING] Model queue size exceeds hardware depth, possibly "
                 "due to loose full-check."
              << std::endl;
  }

  std::cout << "--- [PASSED] IBuffer verification successful! ---" << std::endl;

  delete top;
  return 0;
}
