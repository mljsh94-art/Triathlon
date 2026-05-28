#include "Vtb_triathlon.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <unordered_map>

#define ANSI_RES_GRN "\x1b[32m"
#define ANSI_RES_RED "\x1b[31m"
#define ANSI_RES_RST "\x1b[0m"

static const int INSTR_PER_FETCH = 4;
static const int NRET = 4;
static const int XLEN = 32;
static const uint32_t LINE_BYTES = 32; // 256b / 8

#ifndef TRIATHLON_TRACE
#define TRIATHLON_TRACE 0
#endif

// -----------------------------------------------------------------------------
// Instruction encoders (RV32I)
// -----------------------------------------------------------------------------
static inline uint32_t enc_r(uint32_t funct7, uint32_t rs2, uint32_t rs1,
                             uint32_t funct3, uint32_t rd, uint32_t opcode) {
  return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) |
         (rd << 7) | opcode;
}

static inline uint32_t enc_i(int32_t imm, uint32_t rs1, uint32_t funct3,
                             uint32_t rd, uint32_t opcode) {
  uint32_t imm12 = static_cast<uint32_t>(imm) & 0xFFF;
  return (imm12 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode;
}

static inline uint32_t enc_s(int32_t imm, uint32_t rs2, uint32_t rs1,
                             uint32_t funct3, uint32_t opcode) {
  uint32_t imm12 = static_cast<uint32_t>(imm) & 0xFFF;
  uint32_t imm11_5 = (imm12 >> 5) & 0x7F;
  uint32_t imm4_0 = imm12 & 0x1F;
  return (imm11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) |
         (imm4_0 << 7) | opcode;
}

static inline uint32_t enc_b(int32_t imm, uint32_t rs2, uint32_t rs1,
                             uint32_t funct3, uint32_t opcode) {
  uint32_t imm13 = static_cast<uint32_t>(imm) & 0x1FFF;
  uint32_t bit12 = (imm13 >> 12) & 0x1;
  uint32_t bit11 = (imm13 >> 11) & 0x1;
  uint32_t bits10_5 = (imm13 >> 5) & 0x3F;
  uint32_t bits4_1 = (imm13 >> 1) & 0xF;
  return (bit12 << 31) | (bits10_5 << 25) | (rs2 << 20) | (rs1 << 15) |
         (funct3 << 12) | (bits4_1 << 8) | (bit11 << 7) | opcode;
}

static inline uint32_t insn_addi(uint32_t rd, uint32_t rs1, int32_t imm) {
  return enc_i(imm, rs1, 0x0, rd, 0x13);
}

static inline uint32_t insn_add(uint32_t rd, uint32_t rs1, uint32_t rs2) {
  return enc_r(0x00, rs2, rs1, 0x0, rd, 0x33);
}

static inline uint32_t insn_lw(uint32_t rd, uint32_t rs1, int32_t imm) {
  return enc_i(imm, rs1, 0x2, rd, 0x03);
}

static inline uint32_t insn_sw(uint32_t rs2, uint32_t rs1, int32_t imm) {
  return enc_s(imm, rs2, rs1, 0x2, 0x23);
}

static inline uint32_t insn_beq(uint32_t rs1, uint32_t rs2, int32_t imm) {
  return enc_b(imm, rs2, rs1, 0x0, 0x63);
}

static inline uint32_t insn_bne(uint32_t rs1, uint32_t rs2, int32_t imm) {
  return enc_b(imm, rs2, rs1, 0x1, 0x63);
}

static inline uint32_t insn_nop() { return insn_addi(0, 0, 0); }

// -----------------------------------------------------------------------------
// Unified memory + cache refill/writeback model
// -----------------------------------------------------------------------------
struct UnifiedMem {
  std::unordered_map<uint32_t, uint32_t> words;
  uint32_t default_insn = 0x00000013; // NOP

  void write_word(uint32_t addr, uint32_t data) { words[addr] = data; }

  uint32_t read_word(uint32_t addr) const {
    auto it = words.find(addr);
    if (it == words.end()) return default_insn;
    return it->second;
  }

  void fill_line(uint32_t line_addr, std::array<uint32_t, 8> &line) const {
    for (int i = 0; i < 8; i++) {
      line[i] = read_word(line_addr + 4 * i);
    }
  }

  void write_line(uint32_t line_addr, const std::array<uint32_t, 8> &line) {
    for (int i = 0; i < 8; i++) {
      write_word(line_addr + 4 * i, line[i]);
    }
  }
};

struct ICacheModel {
  bool pending = false;
  int delay = 0;
  uint32_t miss_addr = 0;
  uint32_t miss_way = 0;
  bool refill_pulse = false;
  std::array<uint32_t, 8> line_words{};
  UnifiedMem *mem = nullptr;

  void reset() {
    pending = false;
    delay = 0;
    miss_addr = 0;
    miss_way = 0;
    refill_pulse = false;
  }

  void drive(Vtb_triathlon *top) {
    top->icache_miss_req_ready_i = 1;
    if (refill_pulse) {
      top->icache_refill_valid_i = 1;
      top->icache_refill_paddr_i = miss_addr;
      top->icache_refill_way_i = miss_way;
      for (int i = 0; i < 8; i++) top->icache_refill_data_i[i] = line_words[i];
    } else {
      top->icache_refill_valid_i = 0;
      top->icache_refill_paddr_i = 0;
      top->icache_refill_way_i = 0;
      for (int i = 0; i < 8; i++) top->icache_refill_data_i[i] = 0;
    }
  }

  void observe(Vtb_triathlon *top) {
    if (!top->rst_ni) {
      reset();
      return;
    }

    if (refill_pulse) {
      refill_pulse = false;
    }

    if (!pending && top->icache_miss_req_valid_o) {
      pending = true;
      delay = 2;
      miss_addr = top->icache_miss_req_paddr_o;
      miss_way = top->icache_miss_req_victim_way_o;
      if (mem) mem->fill_line(miss_addr, line_words);
    }

    if (pending) {
      if (delay > 0) {
        delay--;
      } else if (top->icache_refill_ready_o) {
        refill_pulse = true;
        pending = false;
      }
    }
  }
};

struct DCacheModel {
  bool pending = false;
  int delay = 0;
  uint32_t miss_addr = 0;
  uint32_t miss_way = 0;
  bool refill_pulse = false;
  std::array<uint32_t, 8> line_words{};
  UnifiedMem *mem = nullptr;

  void reset() {
    pending = false;
    delay = 0;
    miss_addr = 0;
    miss_way = 0;
    refill_pulse = false;
  }

  void drive(Vtb_triathlon *top) {
    top->dcache_miss_req_ready_i = 1;
    top->dcache_wb_req_ready_i = 1;
    if (refill_pulse) {
      top->dcache_refill_valid_i = 1;
      top->dcache_refill_paddr_i = miss_addr;
      top->dcache_refill_way_i = miss_way;
      for (int i = 0; i < 8; i++) top->dcache_refill_data_i[i] = line_words[i];
    } else {
      top->dcache_refill_valid_i = 0;
      top->dcache_refill_paddr_i = 0;
      top->dcache_refill_way_i = 0;
      for (int i = 0; i < 8; i++) top->dcache_refill_data_i[i] = 0;
    }
  }

  void observe(Vtb_triathlon *top) {
    if (!top->rst_ni) {
      reset();
      return;
    }

    if (refill_pulse) {
      refill_pulse = false;
    }

    if (!pending && top->dcache_miss_req_valid_o) {
      pending = true;
      delay = 2;
      miss_addr = top->dcache_miss_req_paddr_o;
      miss_way = top->dcache_miss_req_victim_way_o;
      if (mem) mem->fill_line(miss_addr, line_words);
    }

    if (pending) {
      if (delay > 0) {
        delay--;
      } else if (top->dcache_refill_ready_o) {
        refill_pulse = true;
        pending = false;
      }
    }

    if (top->dcache_wb_req_valid_o && top->dcache_wb_req_ready_i) {
      std::array<uint32_t, 8> wb_line{};
      for (int i = 0; i < 8; i++) wb_line[i] = top->dcache_wb_req_data_o[i];
      if (mem) mem->write_line(top->dcache_wb_req_paddr_o, wb_line);
    }
  }
};

struct MemSystem {
  UnifiedMem mem;
  ICacheModel icache;
  DCacheModel dcache;

  void reset() {
    icache.reset();
    dcache.reset();
  }

  void drive(Vtb_triathlon *top) {
    top->timer_irq_i = 0;
    top->ext_irq_i = 0;
    icache.drive(top);
    dcache.drive(top);
  }

  void observe(Vtb_triathlon *top) {
    icache.observe(top);
    dcache.observe(top);
  }
};

// -----------------------------------------------------------------------------
// Test helpers
// -----------------------------------------------------------------------------
static void tick(Vtb_triathlon *top, MemSystem &mem) {
  mem.drive(top);
  top->clk_i = 0;
  top->eval();
  top->clk_i = 1;
  top->eval();
  mem.observe(top);
}

static void reset(Vtb_triathlon *top, MemSystem &mem) {
  top->rst_ni = 0;
  mem.reset();
  tick(top, mem);
  tick(top, mem);
  top->rst_ni = 1;
  tick(top, mem);
}

// Update commit information into the register file
static void update_commits(Vtb_triathlon *top, std::array<uint32_t, 32> &rf) {
  for (int i = 0; i < NRET; i++) {
    bool valid = (top->commit_valid_o >> i) & 0x1;
    bool we = (top->commit_we_o >> i) & 0x1;
    uint32_t rd = (top->commit_areg_o >> (i * 5)) & 0x1F;
    uint32_t data = top->commit_wdata_o[i];
    if (valid && we && rd != 0) {
      rf[rd] = data;
    }
  }
}

static void expect(bool cond, const char *msg) {
  if (!cond) {
    std::cout << "[ " << ANSI_RES_RED << "FAIL" << ANSI_RES_RST << " ] " << msg << "\n";
    std::exit(1);
  }
  std::cout << "[ " << ANSI_RES_GRN << "PASS" << ANSI_RES_RST << " ] " << msg << "\n";
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_triathlon *top = new Vtb_triathlon;
  MemSystem mem;
  mem.icache.mem = &mem.mem;
  mem.dcache.mem = &mem.mem;

  // Program: Fibonacci loop with load/store
  const uint32_t base_pc = 0x80000000u;
  // x1 = base (0x100)
  mem.mem.write_word(base_pc + 0, insn_addi(1, 0, 0x100));
  // x2 = n (load from memory)
  mem.mem.write_word(base_pc + 4, insn_lw(2, 1, 0));
  // a=0, b=1, i=0
  mem.mem.write_word(base_pc + 8, insn_addi(3, 0, 0));
  mem.mem.write_word(base_pc + 12, insn_addi(4, 0, 1));
  mem.mem.write_word(base_pc + 16, insn_addi(5, 0, 0));
  // loop:
  // if i == n goto done  (offset 0x18)
  mem.mem.write_word(base_pc + 20, insn_beq(5, 2, 0x18));
  // t = a + b
  mem.mem.write_word(base_pc + 24, insn_add(6, 3, 4));
  // a = b
  mem.mem.write_word(base_pc + 28, insn_addi(3, 4, 0));
  // b = t
  mem.mem.write_word(base_pc + 32, insn_addi(4, 6, 0));
  // i++
  mem.mem.write_word(base_pc + 36, insn_addi(5, 5, 1));
  // unconditional branch back to loop (offset -0x14)
  mem.mem.write_word(base_pc + 40, insn_beq(0, 0, -0x14));
  // done: store result a -> [base+4]
  mem.mem.write_word(base_pc + 44, insn_sw(3, 1, 4));
  // load back to verify store visibility
  mem.mem.write_word(base_pc + 48, insn_lw(7, 1, 4));
  mem.mem.write_word(base_pc + 52, insn_nop());
  mem.mem.write_word(base_pc + 56, insn_nop());

  // Initialize data memory
  mem.mem.write_word(0x100, 8);  // n = 8, fib(8)=21

  reset(top, mem);
  expect(static_cast<uint32_t>(top->dbg_lsu_free_count_o) ==
             static_cast<uint32_t>(top->dbg_free_lsu_o),
         "LSU debug free-count mirrors backend free-count without truncation");

  std::array<uint32_t, 32> rf{};
  bool ok = false;
  for (int i = 0; i < 2000; i++) {
    tick(top, mem);
    update_commits(top, rf);
    expect((top->dbg_pipe_bus_valid_o == 0) || (top->dbg_pipe_bus_valid_o == 1),
           "Debug pipe bus valid is boolean");
    expect((top->dbg_mem_bus_valid_o == 0) || (top->dbg_mem_bus_valid_o == 1),
           "Debug mem bus valid is boolean");
    if (top->backend_flush_o) {
      expect(top->backend_redirect_pc_o == top->dbg_retire_redirect_pc_o,
             "Retire redirect ctrl keeps backend redirect pc aligned");
    }
#if TRIATHLON_TRACE
    if (i < 50) {
      std::cout << "[trace] cycle=" << i << " commit_valid=0x" << std::hex
                << static_cast<uint32_t>(top->commit_valid_o)
                << " commit_we=0x" << static_cast<uint32_t>(top->commit_we_o)
                << std::dec << "\n";
    }
    if (top->backend_flush_o) {
      std::cout << "[trace] cycle=" << i << " flush redirect=0x" << std::hex
                << top->backend_redirect_pc_o << std::dec << "\n";
    }
    for (int k = 0; k < NRET; k++) {
      bool v = (top->commit_valid_o >> k) & 0x1;
      if (v) {
        uint32_t rd = (top->commit_areg_o >> (k * 5)) & 0x1F;
        uint32_t data = top->commit_wdata_o[k];
        uint32_t pc = top->commit_pc_o[k];
        std::cout << "[trace] cycle=" << i << " commit pc=0x" << std::hex << pc
                  << " rd=x" << rd << " data=0x" << data << std::dec << "\n";
      }
    }
#endif
    if (rf[7] == 21) {
      ok = true;
      break;
    }
  }

  expect(ok, "Triathlon runs Fibonacci loop with load/store");
  delete top;
  return 0;
}
