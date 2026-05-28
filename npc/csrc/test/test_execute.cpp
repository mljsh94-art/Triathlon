#include "Vtb_execute.h"
#include "verilated.h"
#include <iostream>
#include <vector>
#include <cassert>
#include <cstdio>

// 颜色输出方便观察结果
#define ANSI_RES_RST  "\x1b[0m"
#define ANSI_RES_GRN  "\x1b[32m"
#define ANSI_RES_RED  "\x1b[31m"

struct TestCase {
    std::string name;
    uint8_t  alu_op;
    uint8_t  br_op;
    bool     is_branch;
    bool     is_jump;
    bool     has_rs2;
    uint32_t rs1;
    uint32_t rs2;
    uint32_t imm;
    uint32_t pc;
    uint32_t pred_npc;
    uint32_t expected_res;
    bool     expected_mispred;
    uint32_t expected_redir_pc;
    bool     is_rvc = false;
};

void run_test(Vtb_execute *top, const TestCase &tc) {
    top->alu_op_i    = tc.alu_op;
    top->br_op_i     = tc.br_op;
    top->is_branch_i = tc.is_branch;
    top->is_jump_i   = tc.is_jump;
    top->is_rvc_i    = tc.is_rvc;
    top->has_rs2_i   = tc.has_rs2;
    top->rs1_data_i  = tc.rs1;
    top->rs2_data_i  = tc.rs2;
    top->imm_i       = tc.imm;
    top->pc_i        = tc.pc;
    top->pred_npc_i  = tc.pred_npc;
    top->rob_tag_in  = 0x1F;

    top->eval();

    bool pass = true;
    if (top->alu_result_o != tc.expected_res) pass = false;
    if (top->is_mispred_o != tc.expected_mispred) pass = false;
    if (tc.expected_mispred && top->redirect_pc_o != tc.expected_redir_pc) pass = false;

    if (pass) {
        printf("[ " ANSI_RES_GRN "PASS" ANSI_RES_RST " ] %s\n", tc.name.c_str());
    } else {
        printf("[ " ANSI_RES_RED "FAIL" ANSI_RES_RST " ] %s\n", tc.name.c_str());
        printf("         Expected: Res=0x%08x, Mispred=%d, RedirPC=0x%08x\n", tc.expected_res, tc.expected_mispred, tc.expected_redir_pc);
        printf("         Actual:   Res=0x%08x, Mispred=%d, RedirPC=0x%08x\n", top->alu_result_o, top->is_mispred_o, top->redirect_pc_o);
        exit(1);
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_execute *top = new Vtb_execute;

    top->rst_ni = 0;
    top->eval();
    top->rst_ni = 1;
    top->eval();

    std::vector<TestCase> tests = {
        // --- 逻辑运算 ---
        {"AND", 6, 0, 0, 0, 1, 0x0F0F0F0F, 0xFFFF0000, 0, 0, 0x4, 0x0F0F0000, 0, 0},
        {"OR",  5, 0, 0, 0, 1, 0x0F0F0F0F, 0xFFFF0000, 0, 0, 0x4, 0xFFFF0F0F, 0, 0},
        {"XOR", 4, 0, 0, 0, 1, 0x55555555, 0xAAAAAAAA, 0, 0, 0x4, 0xFFFFFFFF, 0, 0},
        
        // --- 算术运算 ---
        {"ADD (Pos+Neg)", 0, 0, 0, 0, 1, 100, (uint32_t)-50, 0, 0, 0x4, 50, 0, 0},
        {"SUB (Over)",    1, 0, 0, 0, 1, 0, 1, 0, 0, 0x4, 0xFFFFFFFF, 0, 0},
        {"LUI",          10, 0, 0, 0, 0, 0, 0, 0x12345000, 0, 0x4, 0x12345000, 0, 0},
        {"AUIPC",        11, 0, 0, 0, 0, 0, 0, 0x1000, 0x80000000, 0x80000004, 0x80001000, 0, 0},

        // --- 移位运算 ---
        {"SLL", 7, 0, 0, 0, 1, 0x1, 5, 0, 0, 0x4, 0x20, 0, 0},
        {"SRL", 8, 0, 0, 0, 1, 0x80000000, 1, 0, 0, 0x4, 0x40000000, 0, 0},
        {"SRA", 9, 0, 0, 0, 1, 0x80000000, 1, 0, 0, 0x4, 0xC0000000, 0, 0},

        // --- 比较运算 ---
        {"SLT (True)",  2, 0, 0, 0, 1, (uint32_t)-1, 1, 0, 0, 0x4, 1, 0, 0},
        {"SLT (False)", 2, 0, 0, 0, 1, 1, (uint32_t)-1, 0, 0, 0x4, 0, 0, 0},
        {"SLTU (True)", 3, 0, 0, 0, 1, 1, (uint32_t)-1, 0, 0, 0x4, 1, 0, 0},

        // --- 分支逻辑 (假设预测是不跳，所以 Taken 就是 Mispred) ---
        {"BEQ_TK", 0, 0, 1, 0, 1, 100, 100, 0x40, 0x8000, 0x8004, 0, 1, 0x8040},
        {"BNE (NotTk)",  0, 1, 1, 0, 1, 100, 100, 0x40, 0x8000, 0x8004, 0, 0, 0},
        {"BLT (Taken)",  0, 2, 1, 0, 1, (uint32_t)-2, (uint32_t)-1, 0x10, 0x8000, 0x8004, 0, 1, 0x8010},
        {"BGEU (Taken)", 0, 5, 1, 0, 1, (uint32_t)-1, 100, 0x10, 0x8000, 0x8004, 0, 1, 0x8010},
        // compressed conditional branch (e.g. c.bnez) not-taken should fallthrough by +2
        {"CBNE_NotTk_Fallthrough2", 0, 1, 1, 0, 1, 1, 1, 0x40, 0x81004260, 0x81004262, 0, 0, 0, true},

        // --- 新增: 预测正确的控制流不应误判 ---
        {"BEQ_TK_PRED_OK", 0, 0, 1, 0, 1, 7, 7, 0x20, 0x9000, 0x9020, 0, 0, 0},
        {"JAL_PRED_OK",  0, 6, 0, 1, 0, 0, 0, 0x100, 0x8000, 0x8100, 0x8004, 0, 0},
        {"JALR_PRED_OK", 0, 7, 0, 1, 0, 0x9001, 0, 0x10, 0x8000, 0x9010, 0x8004, 0, 0},

        // --- 跳转逻辑 ---
        {"JAL",  0, 6, 0, 1, 0, 0, 0, 0x100, 0x8000, 0x8004, 0x8004, 1, 0x8100},
        {"JALR", 0, 7, 0, 1, 0, 0x9000, 0, 0x10, 0x8000, 0x8004, 0x8004, 1, 0x9010},


        {"ADDI",   0, 0, 0, 0, 0, 100, 0, (uint32_t)-20, 0, 0x4, 80, 0, 0},

        // SLTI (有符号比较立即数): -10 < 5 -> True (1)
        {"SLTI",   2, 0, 0, 0, 0, (uint32_t)-10, 0, 5, 0, 0x4, 1, 0, 0},

        // SLTIU (无符号比较立即数): -10 (大) < 5 (小) -> False (0)
        {"SLTIU",  3, 0, 0, 0, 0, (uint32_t)-10, 0, 5, 0, 0x4, 0, 0, 0},

        // XORI: 0xAAAAAA AA ^ 0x55555555 = 0xFFFFFFFF
        {"XORI",   4, 0, 0, 0, 0, 0xAAAAAAAA, 0, 0x55555555, 0, 0x4, 0xFFFFFFFF, 0, 0},

        // ORI: 0xF0F0F0F0 | 0x0F0F0F0F = 0xFFFFFFFF
        {"ORI",    5, 0, 0, 0, 0, 0xF0F0F0F0, 0, 0x0F0F0F0F, 0, 0x4, 0xFFFFFFFF, 0, 0},

        // ANDI: 0x12345678 & 0x00000FFF = 0x00000678
        {"ANDI",   6, 0, 0, 0, 0, 0x12345678, 0, 0x00000FFF, 0, 0x4, 0x00000678, 0, 0},

        // SLLI (立即数移位): 1 << 10 = 1024
        {"SLLI",   7, 0, 0, 0, 0, 1, 0, 10, 0, 0x4, 1024, 0, 0},

        // SRLI (立即数逻辑右移): 0x80000000 >> 2 = 0x20000000
        {"SRLI",   8, 0, 0, 0, 0, 0x80000000, 0, 2, 0, 0x4, 0x20000000, 0, 0},

        // SRAI (立即数算术右移): 0x80000000 >>> 2 = 0xE0000000
        {"SRAI",   9, 0, 0, 0, 0, 0x80000000, 0, 2, 0, 0x4, 0xE0000000, 0, 0}
    };

    std::cout << "Starting full instruction set verification..." << std::endl;
    for (const auto &test : tests) {
        run_test(top, test);
    }

    std::cout << ANSI_RES_GRN "--- [ALL TESTS PASSED] Total: " << tests.size() << " cases ---" << ANSI_RES_RST << std::endl;

    delete top;
    return 0;
}
