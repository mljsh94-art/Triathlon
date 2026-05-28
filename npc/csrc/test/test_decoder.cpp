#include "Vtb_decoder.h"
#include "verilated.h"
#include <cassert>
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <vector>

// ============================================================================
// 1. 枚举定义 (必须严格与 npc/vsrc/include/decode_pkg.sv 保持一致)
// ============================================================================

// ALU 操作码
enum AluOp {
  ALU_ADD = 0,
  ALU_SUB,
  ALU_SLT,
  ALU_SLTU,
  ALU_XOR,
  ALU_OR,
  ALU_AND,
  ALU_SLL,
  ALU_SRL,
  ALU_SRA,
  ALU_LUI,
  ALU_AUIPC,
  ALU_NOP,
  ALU_MUL,
  ALU_MULH,
  ALU_MULHSU,
  ALU_MULHU,
  ALU_DIV,
  ALU_DIVU,
  ALU_REM,
  ALU_REMU
};

// 功能单元类型
enum FuType { FU_NONE = 0, FU_ALU, FU_BRANCH, FU_LSU, FU_MUL, FU_DIV, FU_CSR };

// 分支操作码
enum BrOp { BR_EQ = 0, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU, BR_JAL, BR_JALR };

// LSU 操作码
enum LsuOp {
  LSU_LB = 0,
  LSU_LH,
  LSU_LW,
  LSU_LD,
  LSU_LBU,
  LSU_LHU,
  LSU_LWU,
  LSU_SB,
  LSU_SH,
  LSU_SW,
  LSU_SD,
  LSU_LR,
  LSU_SC,
  LSU_SC_FAIL,
  LSU_AMO
};

enum AmoOp {
  AMO_NONE = 0,
  AMO_SWAP,
  AMO_ADD,
  AMO_XOR,
  AMO_AND,
  AMO_OR,
  AMO_MIN,
  AMO_MAX,
  AMO_MINU,
  AMO_MAXU
};

// ============================================================================
// 2. C++ 参考模型 (Golden Model)
// ============================================================================

struct GoldenInfo {
  bool valid;
  bool illegal;
  uint32_t imm;
  int alu_op;
  int lsu_op;
  int amo_op;
  int br_op;
  int fu_type;
  int rs1, rs2, rd;
  bool has_rs1, has_rs2, has_rd;
  bool is_load, is_store, is_branch, is_jump, is_csr, is_fence;
  bool is_sfence_vma;
};

struct DirectedCase {
  const char *name;
  uint32_t inst;
  bool illegal;
  int fu_type;
  bool is_fence;
  bool is_sfence_vma;
  bool is_load;
  bool is_store;
  int lsu_op;
  int amo_op;
};

uint32_t encode_amo_w(uint32_t funct5, uint32_t rd, uint32_t rs1, uint32_t rs2,
                      uint32_t aq = 0, uint32_t rl = 0) {
  return ((funct5 & 0x1F) << 27) | ((aq & 0x1) << 26) | ((rl & 0x1) << 25) |
         ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | (0x2u << 12) |
         ((rd & 0x1F) << 7) | 0x2Fu;
}

void run_directed_case(Vtb_decoder *top, const DirectedCase &tc) {
  top->inst_i = tc.inst;
  top->pc_i = 0x80000000u;
  top->ftq_id_i = 0;
  top->fetch_epoch_i = 0;
  top->eval();

  bool mismatch = false;
  if ((bool)top->check_illegal != tc.illegal)
    mismatch = true;
  if (top->check_fu_type != tc.fu_type)
    mismatch = true;
  if ((bool)top->check_is_fence != tc.is_fence)
    mismatch = true;
  if ((bool)top->check_is_sfence_vma != tc.is_sfence_vma)
    mismatch = true;
  if ((bool)top->check_is_load != tc.is_load)
    mismatch = true;
  if ((bool)top->check_is_store != tc.is_store)
    mismatch = true;
  if ((tc.is_load || tc.is_store) && top->check_lsu_op != tc.lsu_op)
    mismatch = true;
  if ((tc.is_load && tc.is_store) && top->check_amo_op != tc.amo_op)
    mismatch = true;

  if (mismatch) {
    std::cout << "[DIRECTED][FAIL] " << tc.name << " inst=0x" << std::hex
              << tc.inst << std::dec << std::endl;
    std::cout << "  illegal: expect=" << tc.illegal
              << " got=" << (int)top->check_illegal << std::endl;
    std::cout << "  fu_type: expect=" << tc.fu_type
              << " got=" << top->check_fu_type << std::endl;
    std::cout << "  is_fence: expect=" << tc.is_fence
              << " got=" << (int)top->check_is_fence << std::endl;
    std::cout << "  is_sfence_vma: expect=" << tc.is_sfence_vma
              << " got=" << (int)top->check_is_sfence_vma << std::endl;
    std::cout << "  is_load: expect=" << tc.is_load
              << " got=" << (int)top->check_is_load << std::endl;
    std::cout << "  is_store: expect=" << tc.is_store
              << " got=" << (int)top->check_is_store << std::endl;
    std::cout << "  lsu_op: expect=" << tc.lsu_op
              << " got=" << top->check_lsu_op << std::endl;
    std::cout << "  amo_op: expect=" << tc.amo_op
              << " got=" << top->check_amo_op << std::endl;
    assert(false);
  }
}

// 符号扩展辅助函数
int32_t sext(uint32_t val, int bits) {
  if (val & (1 << (bits - 1))) {
    return val | (0xFFFFFFFF << bits);
  }
  return val;
}

GoldenInfo decode_reference(uint32_t inst, uint32_t pc) {
  GoldenInfo info = {};
  // 默认值初始化
  info.valid = true;
  info.illegal = false;
  info.alu_op = ALU_NOP;
  info.lsu_op = LSU_LW; // 默认值，防止未初始化
  info.amo_op = AMO_NONE;
  info.br_op = BR_EQ;   // 默认值
  info.fu_type = FU_ALU;

  // 提取字段
  uint32_t opcode = inst & 0x7F;
  uint32_t rd = (inst >> 7) & 0x1F;
  uint32_t funct3 = (inst >> 12) & 0x7;
  uint32_t rs1 = (inst >> 15) & 0x1F;
  uint32_t rs2 = (inst >> 20) & 0x1F;
  uint32_t funct7 = (inst >> 25) & 0x7F;

  info.rs1 = rs1;
  info.rs2 = rs2;
  info.rd = rd;

  switch (opcode) {
  // -------------------------
  // LUI (U-Type)
  // -------------------------
  case 0x37:
    info.fu_type = FU_ALU;
    info.alu_op = ALU_LUI;
    info.has_rd = (rd != 0);
    info.imm = inst & 0xFFFFF000; // U-Type 立即数直接是高 20 位
    break;

  // -------------------------
  // FENCE / FENCE.I (MISC-MEM)
  // -------------------------
  case 0x0F:
    info.fu_type = FU_ALU;
    info.is_fence = true;
    if (!(funct3 == 0 || funct3 == 1)) {
      info.illegal = true;
    }
    break;

  // -------------------------
  // AUIPC (U-Type)
  // -------------------------
  case 0x17:
    info.fu_type = FU_ALU;
    info.alu_op = ALU_AUIPC;
    info.has_rd = (rd != 0);
    info.imm = inst & 0xFFFFF000;
    break;

  // -------------------------
  // JAL (J-Type)
  // -------------------------
  case 0x6F: {
    info.fu_type = FU_BRANCH;
    info.br_op = BR_JAL;
    info.is_jump = true;
    info.is_branch = true;
    info.has_rd = (rd != 0);
    // J-Type 立即数乱序拼接
    uint32_t imm20 = (inst >> 31) & 1;
    uint32_t imm10_1 = (inst >> 21) & 0x3FF;
    uint32_t imm11 = (inst >> 20) & 1;
    uint32_t imm19_12 = (inst >> 12) & 0xFF;
    uint32_t imm_val =
        (imm20 << 20) | (imm19_12 << 12) | (imm11 << 11) | (imm10_1 << 1);
    info.imm = sext(imm_val, 21);
    break;
  }

  // -------------------------
  // JALR (I-Type)
  // -------------------------
  case 0x67:
    info.fu_type = FU_BRANCH;
    info.br_op = BR_JALR;
    info.is_jump = true;
    info.is_branch = true;
    info.has_rs1 = true;
    info.has_rd = (rd != 0);
    info.imm = sext((inst >> 20), 12);
    break;

  // -------------------------
  // BRANCH (B-Type)
  // -------------------------
  case 0x63: {
    info.fu_type = FU_BRANCH;
    info.is_branch = true;
    info.has_rs1 = true;
    info.has_rs2 = true;
    // B-Type 立即数拼接
    uint32_t imm12 = (inst >> 31) & 1;
    uint32_t imm10_5 = (inst >> 25) & 0x3F;
    uint32_t imm4_1 = (inst >> 8) & 0xF;
    uint32_t imm11 = (inst >> 7) & 1;
    uint32_t imm_val =
        (imm12 << 12) | (imm11 << 11) | (imm10_5 << 5) | (imm4_1 << 1);
    info.imm = sext(imm_val, 13);

    switch (funct3) {
    case 0:
      info.br_op = BR_EQ;
      break;
    case 1:
      info.br_op = BR_NE;
      break;
    case 4:
      info.br_op = BR_LT;
      break;
    case 5:
      info.br_op = BR_GE;
      break;
    case 6:
      info.br_op = BR_LTU;
      break;
    case 7:
      info.br_op = BR_GEU;
      break;
    default:
      info.illegal = true;
      break;
    }
    break;
  }

  // -------------------------
  // LOAD (I-Type)
  // -------------------------
  case 0x03:
    info.fu_type = FU_LSU;
    info.is_load = true;
    info.has_rs1 = true;
    info.has_rd = (rd != 0);
    info.imm = sext((inst >> 20), 12);
    switch (funct3) {
    case 0:
      info.lsu_op = LSU_LB;
      break;
    case 1:
      info.lsu_op = LSU_LH;
      break;
    case 2:
      info.lsu_op = LSU_LW;
      break;
    case 3:
      info.lsu_op = LSU_LD;
      break;
    case 4:
      info.lsu_op = LSU_LBU;
      break;
    case 5:
      info.lsu_op = LSU_LHU;
      break;
    case 6:
      info.lsu_op = LSU_LWU;
      break;
    default:
      info.illegal = true;
      break;
    }
    break;

  // -------------------------
  // STORE (S-Type)
  // -------------------------
  case 0x23:
    info.fu_type = FU_LSU;
    info.is_store = true;
    info.has_rs1 = true;
    info.has_rs2 = true;
    // S-Type 立即数拼接
    info.imm = sext(((inst >> 25) << 5) | ((inst >> 7) & 0x1F), 12);
    switch (funct3) {
    case 0:
      info.lsu_op = LSU_SB;
      break;
    case 1:
      info.lsu_op = LSU_SH;
      break;
    case 2:
      info.lsu_op = LSU_SW;
      break;
    case 3:
      info.lsu_op = LSU_SD;
      break;
    default:
      info.illegal = true;
      break;
    }
    break;

  // -------------------------
  // OP-IMM (I-Type)
  // -------------------------
  case 0x13:
    info.fu_type = FU_ALU;
    info.has_rs1 = true;
    info.has_rd = (rd != 0);
    info.imm = sext((inst >> 20), 12);
    switch (funct3) {
    case 0:
      info.alu_op = ALU_ADD;
      break; // ADDI
    case 2:
      info.alu_op = ALU_SLT;
      break; // SLTI
    case 3:
      info.alu_op = ALU_SLTU;
      break; // SLTIU
    case 4:
      info.alu_op = ALU_XOR;
      break; // XORI
    case 6:
      info.alu_op = ALU_OR;
      break; // ORI
    case 7:
      info.alu_op = ALU_AND;
      break; // ANDI
    case 1:
      info.alu_op = ALU_SLL;
      break; // SLLI
    case 5:
      if ((inst >> 30) & 1)
        info.alu_op = ALU_SRA; // SRAI
      else
        info.alu_op = ALU_SRL; // SRLI
      break;
    default:
      info.illegal = true;
      break;
    }
    break;

  // -------------------------
  // OP-IMM-32 (RV64I W-Type)
  // -------------------------
  case 0x1B:
    info.fu_type = FU_ALU;
    info.has_rs1 = true;
    info.has_rd = (rd != 0);
    info.imm = sext((inst >> 20), 12);
    switch (funct3) {
    case 0:
      info.alu_op = ALU_ADD; // ADDIW
      break;
    case 1:
      info.alu_op = ALU_SLL; // SLLIW
      break;
    case 5:
      if ((inst >> 30) & 1)
        info.alu_op = ALU_SRA; // SRAIW
      else
        info.alu_op = ALU_SRL; // SRLIW
      break;
    default:
      info.illegal = true;
      break;
    }
    break;

  // -------------------------
  // OP (R-Type)
  // -------------------------
  case 0x33:
    info.fu_type = FU_ALU;
    info.has_rs1 = true;
    info.has_rs2 = true;
    info.has_rd = (rd != 0);

    // M-Extension (funct7 = 0x01)
    if (funct7 == 1) {
      switch (funct3) {
      case 0:
        info.alu_op = ALU_MUL;
        info.fu_type = FU_MUL;
        break;
      case 1:
        info.alu_op = ALU_MULH;
        info.fu_type = FU_MUL;
        break;
      case 2:
        info.alu_op = ALU_MULHSU;
        info.fu_type = FU_MUL;
        break;
      case 3:
        info.alu_op = ALU_MULHU;
        info.fu_type = FU_MUL;
        break;
      case 4:
        info.alu_op = ALU_DIV;
        info.fu_type = FU_DIV;
        break;
      case 5:
        info.alu_op = ALU_DIVU;
        info.fu_type = FU_DIV;
        break;
      case 6:
        info.alu_op = ALU_REM;
        info.fu_type = FU_DIV;
        break;
      case 7:
        info.alu_op = ALU_REMU;
        info.fu_type = FU_DIV;
        break;
      }
    }
    // Standard ALU (funct7 必须是 0x00 或 0x20)
    else if (funct7 == 0x00) {
      // funct7 为 0 时，支持所有 funct3
      switch (funct3) {
      case 0:
        info.alu_op = ALU_ADD;
        break;
      case 1:
        info.alu_op = ALU_SLL;
        break;
      case 2:
        info.alu_op = ALU_SLT;
        break;
      case 3:
        info.alu_op = ALU_SLTU;
        break;
      case 4:
        info.alu_op = ALU_XOR;
        break;
      case 5:
        info.alu_op = ALU_SRL;
        break;
      case 6:
        info.alu_op = ALU_OR;
        break;
      case 7:
        info.alu_op = ALU_AND;
        break;
      }
    } else if (funct7 == 0x20) {
      // funct7 为 0x20 时，仅支持 SUB (0) 和 SRA (5)
      switch (funct3) {
      case 0:
        info.alu_op = ALU_SUB;
        break;
      case 5:
        info.alu_op = ALU_SRA;
        break;
      default:
        info.illegal = true;
        break; // <--- 关键修正：其他情况非法
      }
    } else {
      // 其他 funct7 值非法
      info.illegal = true;
    }
    break;

  // -------------------------
  // OP-32 (RV64I W-Type)
  // -------------------------
  case 0x3B:
    info.fu_type = FU_ALU;
    info.has_rs1 = true;
    info.has_rs2 = true;
    info.has_rd = (rd != 0);

    if (funct7 == 0x00) {
      switch (funct3) {
      case 0:
        info.alu_op = ALU_ADD; // ADDW
        break;
      case 1:
        info.alu_op = ALU_SLL; // SLLW
        break;
      case 5:
        info.alu_op = ALU_SRL; // SRLW
        break;
      default:
        info.illegal = true;
        break;
      }
    } else if (funct7 == 0x20) {
      switch (funct3) {
      case 0:
        info.alu_op = ALU_SUB; // SUBW
        break;
      case 5:
        info.alu_op = ALU_SRA; // SRAW
        break;
      default:
        info.illegal = true;
        break;
      }
    } else {
      info.illegal = true;
    }
    break;

  // -------------------------
  // AMO/LR/SC (A extension, word form)
  // -------------------------
  case 0x2F: {
    uint32_t funct5 = (inst >> 27) & 0x1F;
    info.fu_type = FU_LSU;
    info.has_rs1 = true;
    info.has_rd = (rd != 0);
    if (funct3 != 2) {
      info.illegal = true;
      break;
    }
    switch (funct5) {
    case 0x02: // LR.W
      if (rs2 != 0) {
        info.illegal = true;
      } else {
        info.is_load = true;
        info.lsu_op = LSU_LR;
      }
      break;
    case 0x03: // SC.W
      info.has_rs2 = true;
      info.is_store = true;
      info.lsu_op = LSU_SC;
      break;
    case 0x01: // AMOSWAP.W
      info.has_rs2 = true;
      info.is_load = true;
      info.is_store = true;
      info.lsu_op = LSU_AMO;
      info.amo_op = AMO_SWAP;
      break;
    case 0x00: // AMOADD.W
      info.has_rs2 = true;
      info.is_load = true;
      info.is_store = true;
      info.lsu_op = LSU_AMO;
      info.amo_op = AMO_ADD;
      break;
    case 0x04: // AMOXOR.W
      info.has_rs2 = true;
      info.is_load = true;
      info.is_store = true;
      info.lsu_op = LSU_AMO;
      info.amo_op = AMO_XOR;
      break;
    case 0x0C: // AMOAND.W
      info.has_rs2 = true;
      info.is_load = true;
      info.is_store = true;
      info.lsu_op = LSU_AMO;
      info.amo_op = AMO_AND;
      break;
    case 0x08: // AMOOR.W
      info.has_rs2 = true;
      info.is_load = true;
      info.is_store = true;
      info.lsu_op = LSU_AMO;
      info.amo_op = AMO_OR;
      break;
    case 0x10: // AMOMIN.W
      info.has_rs2 = true;
      info.is_load = true;
      info.is_store = true;
      info.lsu_op = LSU_AMO;
      info.amo_op = AMO_MIN;
      break;
    case 0x14: // AMOMAX.W
      info.has_rs2 = true;
      info.is_load = true;
      info.is_store = true;
      info.lsu_op = LSU_AMO;
      info.amo_op = AMO_MAX;
      break;
    case 0x18: // AMOMINU.W
      info.has_rs2 = true;
      info.is_load = true;
      info.is_store = true;
      info.lsu_op = LSU_AMO;
      info.amo_op = AMO_MINU;
      break;
    case 0x1C: // AMOMAXU.W
      info.has_rs2 = true;
      info.is_load = true;
      info.is_store = true;
      info.lsu_op = LSU_AMO;
      info.amo_op = AMO_MAXU;
      break;
    default:
      info.illegal = true;
      break;
    }
    break;
  }

  // -------------------------
  // SYSTEM (CSR)
  // -------------------------
  case 0x73:
    if (funct3 == 0) {
      info.fu_type = FU_CSR;
      info.is_csr = false;
      // PRIV 指令: ECALL, EBREAK, MRET, SRET, WFI
      // 必须严格检查立即数，以匹配 decoder.sv 的行为
      uint32_t sys_imm = (inst >> 20) & 0xFFF;
      if (sys_imm == 0x000) {        /* ECALL */
      } else if (sys_imm == 0x001) { /* EBREAK */
      } else if (sys_imm == 0x302) { /* MRET */
      } else if (sys_imm == 0x102) { /* SRET */
      } else if (sys_imm == 0x105) { /* WFI */
      } else if (sys_imm == 0x120) { /* SFENCE.VMA */
        info.is_sfence_vma = true;
      } else {
        info.illegal = true; // 其他情况非法
      }
    } else if (funct3 == 1 || funct3 == 2 || funct3 == 3 || funct3 == 5 ||
               funct3 == 6 || funct3 == 7) {
      info.fu_type = FU_CSR;
      info.is_csr = true;
      info.has_rd = (rd != 0);
      if (funct3 == 1 || funct3 == 2 || funct3 == 3) {
        info.has_rs1 = true;
      } else {
        info.has_rs1 = false; // 立即数形式
        info.imm = rs1;       // CSR*I: zimm[4:0] 由 rs1 字段承载
      }
    } else {
      info.illegal = true;
    }
    break;

  default:
    info.illegal = true;
    break;
  }

  return info;
}

// ============================================================================
// 3. 随机指令生成器
// ============================================================================

uint32_t generate_random_inst() {
  // 随机选择一种类型 (简单加权)
  int type = rand() % 9;

  uint32_t opcode = 0;
  uint32_t funct3 = rand() % 8;
  uint32_t funct7 = 0;
  uint32_t rs1 = rand() % 32;
  uint32_t rs2 = rand() % 32;
  uint32_t rd = rand() % 32;
  uint32_t imm = 0;

  switch (type) {
  case 0: // OP-IMM (e.g., ADDI)
    opcode = 0x13;
    imm = rand() & 0xFFF;
    if (funct3 == 1 || funct3 == 5) {
      if (funct3 == 1) { // SLLI
        imm &= 0x1F;     // shamt for RV32I is 5 bits. inst[31:25] must be 0.
      } else if (funct3 == 5) { // SRLI/SRAI
        imm = rand() & 0x1F;    // 5-bit shamt
        if (rand() % 2) {       // Randomly generate SRAI
          // For SRAI, inst[30] must be 1. The immediate field is inst[31:20].
          // So we set bit 10 of the 12-bit immediate.
          imm |= (1 << 10);
        }
      }
    }
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode;

  case 1: // OP (e.g., ADD)
    opcode = 0x33;
    if (rand() % 2)
      funct7 = 0x20; // SUB/SRA
    if (rand() % 5 == 0)
      funct7 = 0x01; // M-Ext
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) |
           (rd << 7) | opcode;

  case 2: // LUI
    opcode = 0x37;
    imm = rand() & 0xFFFFF;
    return (imm << 12) | (rd << 7) | opcode;

  case 3: // BRANCH
    opcode = 0x63;
    imm = rand() & 0x1FFF; // 13-bit (bit 0 is 0)
    // 重新打包 B-Type imm
    {
      uint32_t imm12 = (imm >> 12) & 1;
      uint32_t imm10_5 = (imm >> 5) & 0x3F;
      uint32_t imm4_1 = (imm >> 1) & 0xF;
      uint32_t imm11 = (imm >> 11) & 1;
      return (imm12 << 31) | (imm10_5 << 25) | (rs2 << 20) | (rs1 << 15) |
             (funct3 << 12) | (imm4_1 << 8) | (imm11 << 7) | opcode;
    }

  case 4: // LOAD
    opcode = 0x03;
    imm = rand() & 0xFFF;
    if (funct3 > 6)
      funct3 = 2; // LW
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode;

  case 5: // STORE
    opcode = 0x23;
    imm = rand() & 0xFFF;
    if (funct3 > 2)
      funct3 = 2; // SW
    // S-Type imm packing
    {
      uint32_t imm11_5 = (imm >> 5) & 0x7F;
      uint32_t imm4_0 = imm & 0x1F;
      return (imm11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) |
             (imm4_0 << 7) | opcode;
    }

  case 6: // JAL
    opcode = 0x6F;
    imm = rand() & 0x1FFFFF;
    // J-Type imm packing
    {
      uint32_t imm20 = (imm >> 20) & 1;
      uint32_t imm10_1 = (imm >> 1) & 0x3FF;
      uint32_t imm11 = (imm >> 11) & 1;
      uint32_t imm19_12 = (imm >> 12) & 0xFF;
      return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) |
             (imm19_12 << 12) | (rd << 7) | opcode;
    }

  case 7: // FENCE
    opcode = 0x0F;
    funct3 = 0;
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode;

  default: // Random junk (check illegal)
    return (uint32_t)rand();
  }
}

// ============================================================================
// 4. Main 测试逻辑
// ============================================================================

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_decoder *top = new Vtb_decoder;

  // 初始化种子
  srand(time(NULL));

  std::cout << "--- [START] Decoder Randomized Verification ---" << std::endl;

  // 复位
  top->clk_i = 0;
  top->rst_ni = 0;
  top->eval();
  top->rst_ni = 1;
  top->eval();

  std::vector<DirectedCase> directed_cases = {
      {"LR.W legal", encode_amo_w(0x02, 10, 11, 0), false, FU_LSU, false,
       false, true, false, LSU_LR, AMO_NONE},
      {"SC.W legal", encode_amo_w(0x03, 5, 6, 7), false, FU_LSU, false, false,
       false, true, LSU_SC, AMO_NONE},
      {"LR.W rs2 illegal", encode_amo_w(0x02, 10, 11, 1), true, FU_CSR, false,
       false, false, false, LSU_LW, AMO_NONE},
      {"AMOSWAP.W legal", encode_amo_w(0x01, 3, 4, 8), false, FU_LSU, false,
       false, true, true, LSU_AMO, AMO_SWAP},
      {"AMOADD.W aqrl legal", encode_amo_w(0x00, 3, 4, 8, 1, 1), false, FU_LSU,
       false, false, true, true, LSU_AMO, AMO_ADD},
      {"AMOMAXU.W legal", encode_amo_w(0x1C, 3, 4, 8), false, FU_LSU, false,
       false, true, true, LSU_AMO, AMO_MAXU},
      {"AMO bad funct3 illegal", encode_amo_w(0x00, 3, 4, 8) ^ (1u << 12), true,
       FU_CSR, false, false, false, false, LSU_LW, AMO_NONE},
      {"FENCE.I marker", (0x001u << 12) | 0x0Fu, false, FU_ALU, true, false,
       false, false, LSU_LW, AMO_NONE},
      {"ECALL as CSR-FU", 0x00000073u, false, FU_CSR, false, false, false,
       false, LSU_LW, AMO_NONE},
      {"MRET as CSR-FU", 0x30200073u, false, FU_CSR, false, false, false,
       false, LSU_LW, AMO_NONE},
      {"WFI as CSR-FU", 0x10500073u, false, FU_CSR, false, false, false,
       false, LSU_LW, AMO_NONE},
      {"SFENCE.VMA as CSR-FU", 0x12000073u, false, FU_CSR, false, true, false,
       false, LSU_LW, AMO_NONE},
  };

  for (const auto &tc : directed_cases) {
    run_directed_case(top, tc);
  }

  const int NUM_TESTS = 20000;
  int passed = 0;

  for (int i = 0; i < NUM_TESTS; ++i) {
    // 1. 生成指令
    uint32_t inst = generate_random_inst();
    uint32_t pc = 0x80000000 + i * 4;
    uint32_t ftq_id = static_cast<uint32_t>(i) & 0x7u;
    uint32_t fetch_epoch = (static_cast<uint32_t>(i) >> 3) & 0x7u;

    // 2. 驱动 DUT
    top->inst_i = inst;
    top->pc_i = pc;
    top->ftq_id_i = ftq_id;
    top->fetch_epoch_i = fetch_epoch;
    top->eval(); // 纯组合逻辑

    // 3. 获取 Golden Reference
    GoldenInfo ref = decode_reference(inst, pc);

    // 4. 对比检查
    bool mismatch = false;

    // 检查 Illegal
    if ((bool)top->check_illegal != ref.illegal) {
      std::cout << "[ERROR] Illegal mismatch! Ref=" << ref.illegal
                << " DUT=" << (int)top->check_illegal << std::endl;
      mismatch = true;
    }

    // 如果是 illegal 指令，后续字段可能无意义，跳过检查
    if (!ref.illegal) {
      if (top->check_imm != ref.imm) {
        std::cout << "[ERROR] Imm mismatch! Ref=0x" << std::hex << ref.imm
                  << " DUT=0x" << top->check_imm << std::endl;
        mismatch = true;
      }
      if (top->check_alu_op != ref.alu_op) {
        std::cout << "[ERROR] ALU_OP mismatch! Ref=" << std::dec << ref.alu_op
                  << " DUT=" << top->check_alu_op << std::endl;
        mismatch = true;
      }
      if (top->check_fu_type != ref.fu_type) {
        std::cout << "[ERROR] FU_TYPE mismatch! Ref=" << ref.fu_type
                  << " DUT=" << top->check_fu_type << std::endl;
        mismatch = true;
      }
      if (top->check_is_load != ref.is_load) {
        std::cout << "[ERROR] is_load mismatch!" << std::endl;
        mismatch = true;
      }
      if (top->check_is_store != ref.is_store) {
        std::cout << "[ERROR] is_store mismatch!" << std::endl;
        mismatch = true;
      }
      if (top->check_is_fence != ref.is_fence) {
        std::cout << "[ERROR] is_fence mismatch!" << std::endl;
        mismatch = true;
      }
      if (top->check_is_sfence_vma != ref.is_sfence_vma) {
        std::cout << "[ERROR] is_sfence_vma mismatch!" << std::endl;
        mismatch = true;
      }
      // 检查寄存器索引 (确保解码器正确提取了 rs1/rs2/rd)
      if (ref.fu_type != FU_BRANCH &&
          ref.fu_type != FU_LSU) { // 简单逻辑：非特殊情况都查
        if (top->check_rd != ref.rd && ref.has_rd) {
          std::cout << "[ERROR] RD mismatch!" << std::endl;
          mismatch = true;
        }
      }
      // 检查所有相关的解码字段
      if (ref.has_rs1 && top->check_rs1 != ref.rs1) {
        std::cout << "[ERROR] RS1 mismatch! Ref=" << std::dec << ref.rs1
                  << " DUT=" << (int)top->check_rs1 << std::endl;
        mismatch = true;
      }
      if (ref.has_rs2 && top->check_rs2 != ref.rs2) {
        std::cout << "[ERROR] RS2 mismatch! Ref=" << std::dec << ref.rs2
                  << " DUT=" << (int)top->check_rs2 << std::endl;
        mismatch = true;
      }
      if (ref.has_rd && top->check_rd != ref.rd) {
        std::cout << "[ERROR] RD mismatch! Ref=" << std::dec << ref.rd
                  << " DUT=" << (int)top->check_rd << std::endl;
        mismatch = true;
      }
      if ((ref.is_load || ref.is_store) && top->check_lsu_op != ref.lsu_op) {
        std::cout << "[ERROR] LSU_OP mismatch! Ref=" << std::dec << ref.lsu_op
                  << " DUT=" << top->check_lsu_op << std::endl;
        mismatch = true;
      }
      if ((ref.is_load && ref.is_store) && top->check_amo_op != ref.amo_op) {
        std::cout << "[ERROR] AMO_OP mismatch! Ref=" << std::dec << ref.amo_op
                  << " DUT=" << top->check_amo_op << std::endl;
        mismatch = true;
      }
      if (ref.is_branch && top->check_br_op != ref.br_op) {
        std::cout << "[ERROR] BR_OP mismatch! Ref=" << std::dec << ref.br_op
                  << " DUT=" << top->check_br_op << std::endl;
        mismatch = true;
      }
      if (top->check_is_jump != ref.is_jump) {
        std::cout << "[ERROR] is_jump mismatch! Ref=" << ref.is_jump
                  << " DUT=" << (int)top->check_is_jump << std::endl;
        mismatch = true;
      }
      if (top->check_pred_npc != (pc + 4)) {
        std::cout << "[ERROR] pred_npc mismatch! Ref=0x" << std::hex << (pc + 4)
                  << " DUT=0x" << top->check_pred_npc << std::endl;
        mismatch = true;
      }
      if (static_cast<uint32_t>(top->check_ftq_id) != ftq_id) {
        std::cout << "[ERROR] ftq_id mismatch! Ref=" << std::dec << ftq_id
                  << " DUT=" << static_cast<uint32_t>(top->check_ftq_id)
                  << std::endl;
        mismatch = true;
      }
      if (static_cast<uint32_t>(top->check_fetch_epoch) != fetch_epoch) {
        std::cout << "[ERROR] fetch_epoch mismatch! Ref=" << std::dec
                  << fetch_epoch << " DUT="
                  << static_cast<uint32_t>(top->check_fetch_epoch)
                  << std::endl;
        mismatch = true;
      }
    }

    if (mismatch) {
      std::cout << "  Instruction: 0x" << std::hex << inst << std::endl;
      std::cout << "  Iteration: " << std::dec << i << std::endl;
      assert(false); // 停止仿真
    }

    passed++;
  }

  std::cout << "--- [PASSED] Checked " << passed << " instructions. ---"
            << std::endl;

  delete top;
  return 0;
}
