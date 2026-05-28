// csrc/test_issue.cpp
#include "Vtb_issue.h"
#include "verilated.h"
#include <cassert>
#include <iostream>
#include <vector>
#include <iomanip>

// =================================================================
// 配置参数
// =================================================================
const int INSTR_PER_FETCH = 4;
// uop_t 大约 100+ bits，Verilator 会映射为 VlWide<4> (4个32位字)
// 根据生成的头文件，这里通常假设宽度足以容纳。
const int UOP_WORDS = 4; 

vluint64_t main_time = 0;

void tick(Vtb_issue *top) {
    top->clk = 0;
    top->eval();
    main_time++;
    top->clk = 1;
    top->eval();
    main_time++;
}

// 辅助结构：用于定义一条要 Dispatch 的指令
struct DispatchInstr {
    bool valid;
    uint32_t op; // 我们将这个作为测试 ID 填入 uop_t 的低 32 位
    uint32_t dst_tag;
    uint32_t v1;
    uint32_t q1;
    bool r1;
    uint32_t v2;
    uint32_t q2;
    bool r2;
};

// 辅助函数：设置 Dispatch 输入端口
void set_dispatch(Vtb_issue *top, const std::vector<DispatchInstr>& instrs) {
    // 先清零
    top->dispatch_valid = 0;
    top->dispatch_has_rs1 = 0;
    top->dispatch_has_rs2 = 0;
    for (int i = 0; i < INSTR_PER_FETCH; ++i) {
        // 对于 VlWide 类型，需要对每个 word 清零
        for(int w = 0; w < UOP_WORDS; ++w) {
            top->dispatch_op[i][w] = 0;
        }
        top->dispatch_dst[i] = 0;
        top->dispatch_v1[i] = 0;
        top->dispatch_q1[i] = 0;
        top->dispatch_r1[i] = 0;
        top->dispatch_v2[i] = 0;
        top->dispatch_q2[i] = 0;
        top->dispatch_r2[i] = 0;
    }

    // 设置有效值
    uint8_t valid_mask = 0;
    for (size_t i = 0; i < instrs.size() && i < 4; ++i) {
        if (instrs[i].valid) {
            valid_mask |= (1 << i);
            // [修复] 将 op 写入 uop_t 的第一个 word，其余保持 0
            // 这里我们把 instrs[i].op 当作 uop 的 payload 或者是唯一标识符
            top->dispatch_op[i][0]  = instrs[i].op; 
            top->dispatch_has_rs1 |= (1u << i);
            top->dispatch_has_rs2 |= (1u << i);
            
            top->dispatch_dst[i] = instrs[i].dst_tag;
            top->dispatch_v1[i]  = instrs[i].v1;
            top->dispatch_q1[i]  = instrs[i].q1;
            top->dispatch_r1[i]  = instrs[i].r1;
            top->dispatch_v2[i]  = instrs[i].v2;
            top->dispatch_q2[i]  = instrs[i].q2;
            top->dispatch_r2[i]  = instrs[i].r2;
        }
    }
    top->dispatch_valid = valid_mask;
}

// 辅助函数：设置 CDB 广播
void set_cdb(Vtb_issue *top, const std::vector<std::pair<uint32_t, uint32_t>>& updates) {
    top->cdb_valid = 0;
    for(int i=0; i<4; ++i) {
        top->cdb_tag[i] = 0;
        top->cdb_val[i] = 0;
    }

    uint8_t valid_mask = 0;
    for (size_t i = 0; i < updates.size() && i < 4; ++i) {
        valid_mask |= (1 << i);
        top->cdb_tag[i] = updates[i].first;  // Tag
        top->cdb_val[i] = updates[i].second; // Value
    }
    top->cdb_valid = valid_mask;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_issue *top = new Vtb_issue;

    std::cout << "--- [START] Issue Stage Verification ---" << std::endl;

    // 1. 复位
    top->rst_n = 0;
    top->clk = 0;
    top->flush_i = 0;
    set_dispatch(top, {});
    set_cdb(top, {});
    tick(top);
    top->rst_n = 1;
    tick(top); // 等待复位释放

    std::cout << "[" << main_time << "] Reset complete. issue_ready = " << (int)top->issue_ready << std::endl;
    assert(top->issue_ready == 1 && "Should be ready after reset");

    // =================================================================
    // Test 1: 发射 2 条已就绪的指令 (Direct Issue)
    // =================================================================
    std::cout << "\n--- Test 1: Dispatch Ready Instructions ---" << std::endl;
    
    // 使用合法的十六进制数作为 ID
    uint32_t OP_ADD = 0xADD00001;
    uint32_t OP_SUB = 0x50B00002;

    std::vector<DispatchInstr> group1 = {
        {true, OP_ADD, 3, 100, 0, 1, 200, 0, 1}, // Op, DstTag, V1, Q1, R1, V2, Q2, R2
        {true, OP_SUB, 6, 300, 0, 1, 400, 0, 1}
    };
    set_dispatch(top, group1);
    
    // Tick 1: Dispatch Write -> RS Busy 变高
    tick(top); 
    
    // 撤销 Dispatch 请求
    set_dispatch(top, {});

    // 检查是否发射
    top->eval(); 
    
    bool executed_0 = false;
    bool executed_1 = false;

    // 我们给一点时间让它们发射
    for(int i=0; i<3; ++i) {
        // [修复] 端口名变为 alu0_uop, 且需要读取宽数据的第一个 word
        if (top->alu0_en) {
            uint32_t op_val = top->alu0_uop[0];
            std::cout << "  [Cycle " << i << "] ALU0 Fire! Op=0x" << std::hex << op_val << std::dec << std::endl;
            if (op_val == OP_ADD) executed_0 = true;
            if (op_val == OP_SUB) executed_1 = true;
        }
        if (top->alu1_en) {
            uint32_t op_val = top->alu1_uop[0];
            std::cout << "  [Cycle " << i << "] ALU1 Fire! Op=0x" << std::hex << op_val << std::endl;
            if (op_val == OP_ADD) executed_0 = true;
            if (op_val == OP_SUB) executed_1 = true;
        }
        tick(top);
    }

    assert(executed_0 && "Instr 0 failed to issue");
    assert(executed_1 && "Instr 1 failed to issue");
    std::cout << "--- Test 1 PASSED ---" << std::endl;


    // =================================================================
    // Test 2: 依赖等待测试 (Wait for CDB)
    // =================================================================
    std::cout << "\n--- Test 2: Dependency & CDB Wakeup ---" << std::endl;

    uint32_t OP_WAIT_A = 0x000000AA; // WAIT A
    uint32_t OP_WAIT_B = 0x000000BB; // WAIT B
    uint32_t DATA_10   = 0xDA7A0010; // DATA 10
    uint32_t DATA_11   = 0xDA7A0011; // DATA 11

    // 发射 2 条未就绪指令
    std::vector<DispatchInstr> group2 = {
        {true, OP_WAIT_A, 20, 0, 10, 0, 500, 0, 1}, // Src1 not ready (Wait Tag 10)
        {true, OP_WAIT_B, 21, 600, 0, 1, 0, 11, 0}  // Src2 not ready (Wait Tag 11)
    };
    set_dispatch(top, group2);
    tick(top);
    set_dispatch(top, {}); // Stop dispatch

    // 立即广播 CDB，验证 wakeup 后携带的数据是否正确。
    // 该实现允许同周期 dispatch+issue，这里不再强制“先等待几个周期”。

    // 模拟 CDB 广播 Tag 10 和 11
    std::cout << "  [Action] Broadcasting CDB Tag 10 and 11..." << std::endl;
    std::vector<std::pair<uint32_t, uint32_t>> cdb_data = {
        {10, DATA_10}, 
        {11, DATA_11}
    };
    set_cdb(top, cdb_data);
    
    tick(top); 
    set_cdb(top, {}); // Clear CDB

    bool checked_a = false;
    bool checked_b = false;

    for(int i=0; i<5; ++i) {
        top->eval();
        if (top->alu0_en) {
            uint32_t op_val = top->alu0_uop[0];
            if (op_val == OP_WAIT_A) {
                std::cout << "  ALU0 Issued Instr A. V1=" << std::hex << top->alu0_v1 << " (Expect " << DATA_10 << ")" << std::endl;
                assert(top->alu0_v1 == DATA_10); 
                checked_a = true;
            }
            if (op_val == OP_WAIT_B) {
                std::cout << "  ALU0 Issued Instr B. V2=" << std::hex << top->alu0_v2 << " (Expect " << DATA_11 << ")" << std::endl;
                assert(top->alu0_v2 == DATA_11);
                checked_b = true;
            }
        }
        if (top->alu1_en) {
             uint32_t op_val = top->alu1_uop[0];
             if (op_val == OP_WAIT_A) {
                std::cout << "  ALU1 Issued Instr A. V1=" << std::hex << top->alu1_v1 << std::endl;
                assert(top->alu1_v1 == DATA_10);
                checked_a = true;
            }
            if (op_val == OP_WAIT_B) {
                std::cout << "  ALU1 Issued Instr B. V2=" << std::hex << top->alu1_v2 << std::endl;
                assert(top->alu1_v2 == DATA_11);
                checked_b = true;
            }
        }
        tick(top);
    }

    assert(checked_a && checked_b && "Dependent instructions failed data check after CDB wakeup");
    std::cout << "--- Test 2 PASSED ---" << std::endl;

    // =================================================================
    // Test 3: RS 满状态与阻塞 (Full Stall)
    // =================================================================
    std::cout << "\n--- Test 3: RS Full Stall Check ---" << std::endl;
    
    uint32_t OP_STALL = 0x57A11000; // STALL
    // With ROB-age wakeup filtering, producer tag must be older than consumer tag.
    DispatchInstr stall_instr = {true, OP_STALL, 40, 0, 20, 0, 0, 20, 0};
    std::vector<DispatchInstr> batch(4, stall_instr); 

    // 按当前配置动态填满 RS（避免与可配置 RS_DEPTH 脱节）。
    int fill_batches = 0;
    const int max_fill_batches = 64; // 4 entries/batch -> supports RS up to 256
    while (top->issue_ready && fill_batches < max_fill_batches) {
        std::cout << "  Filling Batch " << fill_batches + 1
                  << " (Ready=" << (int)top->issue_ready << ")" << std::endl;
        set_dispatch(top, batch);
        tick(top);
        fill_batches++;
    }
    set_dispatch(top, {});
    assert(fill_batches > 0 && "RS should accept at least one batch before full");
    assert(fill_batches < max_fill_batches && "RS did not become full within safety bound");
    
    top->eval();
    std::cout << "  [Check] RS Full. issue_ready = " << (int)top->issue_ready << std::endl;
    assert(top->issue_ready == 0); // 必须为 0

    // 尝试在满的时候强行发射 (应该被忽略)
    std::cout << "  [Action] Attempting dispatch when FULL..." << std::endl;
    
    uint32_t OP_NEW = 0x000000FF; // NEW
    DispatchInstr new_instr = {true, OP_NEW, 50, 0, 0, 1, 0, 0, 1}; 
    set_dispatch(top, {new_instr, new_instr, new_instr, new_instr});
    tick(top);
    set_dispatch(top, {}); 

    for(int i=0; i<3; ++i) {
        if (top->alu0_en && top->alu0_uop[0] == OP_NEW) assert(false && "Dispatch accepted while RS FULL!");
        if (top->alu1_en && top->alu1_uop[0] == OP_NEW) assert(false && "Dispatch accepted while RS FULL!");
        tick(top);
    }
    std::cout << "  [Verified] No instructions accepted while FULL." << std::endl;

    // 释放一些空间
    std::cout << "  [Action] Releasing instructions via CDB Tag 20..." << std::endl;
    set_cdb(top, {{20, 0xDEADBEEF}});
    tick(top);
    set_cdb(top, {});

    int fired_count = 0;
    for(int i=0; i<20; ++i) {
        if (top->alu0_en) fired_count++;
        if (top->alu1_en) fired_count++;
        tick(top);
    }
    std::cout << "  [Info] Fired " << fired_count << " instructions after release." << std::endl;
    
    top->eval();
    std::cout << "  [Check] issue_ready = " << (int)top->issue_ready << std::endl;
    assert(top->issue_ready == 1);

    std::cout << "--- Test 3 PASSED ---" << std::endl;

    // =================================================================
    // Test 4: 高索引指令不应被低索引持续补充饿死 (Starvation)
    // =================================================================
    std::cout << "\n--- Test 4: High-index starvation check ---" << std::endl;

    // 清空 RS
    top->flush_i = 1;
    tick(top);
    top->flush_i = 0;
    tick(top);

    uint32_t OP_BLOCK = 0xB10C0001;
    uint32_t OP_SENTINEL = 0x51E70001;  // 目标：放在高索引，检查是否被饿死
    uint32_t OP_SPAM = 0x5A4D0001;      // 低索引持续补充流量
    uint32_t WAKE_TAG = 2;

    auto mk_block = [&](uint32_t op) {
      return DispatchInstr{true, op, 12, 0, WAKE_TAG, 0, 0, WAKE_TAG, 0};
    };
    auto mk_ready_spam = [&]() {
      return DispatchInstr{true, OP_SPAM, 13, 1, 0, 1, 2, 0, 1};
    };

    // 填满 RS：全部先阻塞；最后一批最后一条放 sentinel，尽量落到高索引。
    int fill_batches4 = 0;
    const int max_fill_batches4 = 64;
    bool sentinel_injected = false;
    while (top->issue_ready && fill_batches4 < max_fill_batches4) {
      std::vector<DispatchInstr> batch = {
          mk_block(OP_BLOCK), mk_block(OP_BLOCK), mk_block(OP_BLOCK), mk_block(OP_BLOCK)};
      if (!sentinel_injected && top->free_count_o <= 4) {
        batch[3] = mk_block(OP_SENTINEL);
        sentinel_injected = true;
      }
      set_dispatch(top, batch);
      tick(top);
      fill_batches4++;
      // 当 ready 变 0 说明已满；将最后一次真正填充的 batch 放 sentinel。
      if (!top->issue_ready) {
        break;
      }
    }
    set_dispatch(top, {});
    top->eval();
    assert(sentinel_injected && "Sentinel must be injected before RS becomes full");
    assert(top->issue_ready == 0 && "RS should be full before starvation test");

    // 唤醒所有阻塞项，使其全部 ready。
    set_cdb(top, {{WAKE_TAG, 0xABCD1234}});
    tick(top);
    set_cdb(top, {});

    bool sentinel_issued = false;
    const int stress_cycles = 200;
    for (int cyc = 0; cyc < stress_cycles; ++cyc) {
      // 只在可接收时补充低索引 ready 流量，制造持续竞争。
      if (top->issue_ready) {
        std::vector<DispatchInstr> spam = {
            mk_ready_spam(), mk_ready_spam(), mk_ready_spam(), mk_ready_spam()};
        set_dispatch(top, spam);
      } else {
        set_dispatch(top, {});
      }

      top->eval();
      if (top->alu0_en && top->alu0_uop[0] == OP_SENTINEL) sentinel_issued = true;
      if (top->alu1_en && top->alu1_uop[0] == OP_SENTINEL) sentinel_issued = true;
      if (top->alu2_en && top->alu2_uop[0] == OP_SENTINEL) sentinel_issued = true;
      if (top->alu3_en && top->alu3_uop[0] == OP_SENTINEL) sentinel_issued = true;

      tick(top);
      if (sentinel_issued) break;
    }
    set_dispatch(top, {});

    assert(sentinel_issued && "High-index ready instruction starved by fixed-priority issue select");
    std::cout << "--- Test 4 PASSED ---" << std::endl;

    std::cout << "\n--- [SUCCESS] All Issue Stage Tests Passed! ---" << std::endl;

    delete top;
    return 0;
}
