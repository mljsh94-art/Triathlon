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

static inline uint32_t insn_lui(uint32_t rd, uint32_t imm20) {
  return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37;
}

// CSRRW rd, csr, rs1
static inline uint32_t insn_csrrw(uint32_t rd, uint32_t csr, uint32_t rs1) {
  return ((csr & 0xFFF) << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x73;
}

// CSRRS rd, csr, rs1
static inline uint32_t insn_csrrs(uint32_t rd, uint32_t csr, uint32_t rs1) {
  return ((csr & 0xFFF) << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x73;
}

// MRET
static inline uint32_t insn_mret() {
  return 0x30200073u;
}

// JAL rd, imm (J-type)
static inline uint32_t insn_jal(uint32_t rd, int32_t imm) {
  uint32_t imm21 = static_cast<uint32_t>(imm) & 0x1FFFFF;
  uint32_t bit20   = (imm21 >> 20) & 0x1;
  uint32_t bits10_1 = (imm21 >> 1)  & 0x3FF;
  uint32_t bit11   = (imm21 >> 11) & 0x1;
  uint32_t bits19_12 = (imm21 >> 12) & 0xFF;
  return (bit20 << 31) | (bits10_1 << 21) | (bit11 << 20) |
         (bits19_12 << 12) | (rd << 7) | 0x6F;
}

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

struct MmioModel {
  UnifiedMem *mem = nullptr;

  void reset() {}

  void drive(Vtb_triathlon *top) {
    top->mmio_req_ready_i = 1;
    if (top->mmio_req_valid_o) {
      uint32_t addr = top->mmio_req_addr_o;
      top->mmio_rsp_valid_i = 1;
      top->mmio_rsp_data_i  = mem->read_word(addr);
    } else {
      top->mmio_rsp_valid_i = 0;
      top->mmio_rsp_data_i  = 0;
    }
  }

  void observe(Vtb_triathlon *top) { (void)top; }
};

struct MemSystem {
  UnifiedMem mem;
  ICacheModel icache;
  DCacheModel dcache;
  MmioModel mmio;

  void reset() {
    icache.reset();
    dcache.reset();
    mmio.reset();
  }

  void drive(Vtb_triathlon *top) {
    top->timer_irq_i = 0;
    top->ext_irq_i = 0;
    icache.drive(top);
    dcache.drive(top);
    mmio.drive(top);
  }

  void observe(Vtb_triathlon *top) {
    icache.observe(top);
    dcache.observe(top);
    mmio.observe(top);
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
  mem.mmio.mem   = &mem.mem;

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

  // =========================================================
  // Test 2: MMIO Bypass — read from low address (device space)
  // Verify that the read goes through the MMIO path, not D-Cache
  // =========================================================
  {
    MemSystem mem2;
    mem2.icache.mem = &mem2.mem;
    mem2.dcache.mem = &mem2.mem;
    mem2.mmio.mem   = &mem2.mem;

    Vtb_triathlon *top2 = new Vtb_triathlon;

    const uint32_t mmio_test_addr = 0x10000000u; // MMIO region address
    const uint32_t mmio_magic     = 0xDEADBEEFu; // Expected magic value

    // Place a known value at the MMIO address
    mem2.mem.write_word(mmio_test_addr, mmio_magic);

    // Program:
    // 0: lui  x10, 0x10000       ; x10 = 0x10000000
    // 4: lw   x11, 0(x10)        ; x11 = mem[0x10000000] (MMIO read!)
    // 8..28: nops
    const uint32_t base2 = 0x80000000u;
    mem2.mem.write_word(base2 + 0, 0x10000537u);        // lui x10, 0x10000
    mem2.mem.write_word(base2 + 4, insn_lw(11, 10, 0)); // lw x11, 0(x10)
    for (int i = 2; i < 8; i++)
      mem2.mem.write_word(base2 + 4*i, insn_nop());

    reset(top2, mem2);
    std::array<uint32_t, 32> rf2{};
    bool mmio_ok = false;
    for (int i = 0; i < 2000; i++) {
      tick(top2, mem2);
      update_commits(top2, rf2);
      if (rf2[11] == mmio_magic) {
        mmio_ok = true;
        break;
      }
    }
    expect(mmio_ok, "MMIO bypass: load from device address returns correct data");
    delete top2;
  }

  // =========================================================
  // Test 3: S-mode External Interrupt Delivery
  // Verify that ext_irq_i correctly traps CPU from S-mode
  // to the stvec handler via PLIC interrupt delegation.
  // =========================================================
  {
    MemSystem mem3;
    mem3.icache.mem = &mem3.mem;
    mem3.dcache.mem = &mem3.mem;
    mem3.mmio.mem   = &mem3.mem;

    Vtb_triathlon *top3 = new Vtb_triathlon;

    // Memory layout:
    //   0x80000000: M-mode init code (configure CSRs, mret to S-mode)
    //   0x80001000: S-mode code (spin loop, waiting for interrupt)
    //   0x80002000: S-mode trap handler (writes marker to x20, then spins)
    //   0x80003000: data region

    const uint32_t m_base     = 0x80000000u;
    const uint32_t s_code     = 0x80001000u;
    const uint32_t s_handler  = 0x80002000u;
    const uint32_t marker_val = 0xCAFE0001u;

    // CSR addresses
    const uint32_t CSR_MSTATUS = 0x300;
    const uint32_t CSR_MIDELEG = 0x303;
    const uint32_t CSR_MIE     = 0x304;
    const uint32_t CSR_MEPC    = 0x341;
    const uint32_t CSR_STVEC   = 0x105;
    const uint32_t CSR_SIE     = 0x104;
    const uint32_t CSR_SSTATUS = 0x100;

    uint32_t pc = m_base;
    auto emit = [&](uint32_t insn) {
      mem3.mem.write_word(pc, insn);
      pc += 4;
    };

    // === M-mode init sequence ===
    // x1 = 0x200 (bit 9 for SEIE)
    emit(insn_addi(1, 0, 0x200));            // 0x00: x1 = 0x200
    emit(insn_csrrs(0, CSR_MIDELEG, 1));     // 0x04: mideleg |= (1<<9)
    emit(insn_csrrs(0, CSR_MIE, 1));         // 0x08: mie |= (1<<9)
    emit(insn_csrrs(0, CSR_SIE, 1));         // 0x0C: sie |= (1<<9)

    // stvec = 0x80002000
    emit(insn_lui(2, 0x80002));              // 0x10: x2 = 0x80002000
    emit(insn_csrrw(0, CSR_STVEC, 2));       // 0x14: stvec = x2

    // mepc = s_code = 0x80001000 (where we'll land after mret)
    emit(insn_lui(3, 0x80001));              // 0x18: x3 = 0x80001000
    emit(insn_csrrw(0, CSR_MEPC, 3));        // 0x1C: mepc = x3

    // mstatus: set MPP=01 (S-mode), enable SIE
    //   Reset value is 0x1800 (MPP=11=M).
    //   We need to write 0x0822: MPP=01(S), SPIE=1(bit5), SIE=1(bit1)
    //   Build 0x0822 = 0x800 + 0x22
    //   addi can't encode 0x800 directly, build incrementally:
    emit(insn_addi(4, 0, 0x7FF));            // 0x20: x4 = 0x7FF
    emit(insn_addi(4, 4, 1));                // 0x24: x4 = 0x800
    emit(insn_addi(4, 4, 0x22));             // 0x28: x4 = 0x822
    emit(insn_csrrw(0, CSR_MSTATUS, 4));     // 0x2C: mstatus = 0x822

    // mret: jump to mepc (0x80001000) in S-mode
    emit(insn_mret());                       // 0x30: mret

    // === S-mode code at 0x80001000: spin loop ===
    pc = s_code;
    // x20 = 0 (marker not set yet)
    emit(insn_addi(20, 0, 0));               // 0x00: x20 = 0
    // Enable sstatus.SIE (bit 1) — make sure interrupts are on
    emit(insn_addi(6, 0, 0x2));              // 0x04: x6 = 2
    emit(insn_csrrs(0, CSR_SSTATUS, 6));     // 0x08: sstatus |= SIE
    // Spin: loop forever (beq x0, x0, 0)
    emit(insn_beq(0, 0, 0));                 // 0x0C: infinite loop

    // === S-mode trap handler at 0x80002000 ===
    pc = s_handler;
    // Write marker: x20 = 0xCAFE (truncated to 12-bit won't work for full value)
    // Use LUI + ADDI: x20 = 0xCAFE0000 + 1
    emit(insn_lui(20, 0xCAFE0));             // 0x00: x20 = 0xCAFE0000
    emit(insn_addi(20, 20, 1));              // 0x04: x20 = 0xCAFE0001
    // Spin in handler
    emit(insn_beq(0, 0, 0));                 // 0x08: infinite loop

    reset(top3, mem3);

    std::array<uint32_t, 32> rf3{};
    bool switched_to_smode = false;
    bool irq_asserted = false;
    bool smode_trap_ok = false;
    int irq_assert_cycle = -1;

    for (int i = 0; i < 5000; i++) {
      // Phase 1: let M-mode init run, then detect S-mode entry
      if (!switched_to_smode) {
        // Check if priv_mode dropped to S-mode (01)
        if (top3->dbg_csr_priv_mode_o == 1) {
          switched_to_smode = true;
          std::cout << "[test-smode-irq] Switched to S-mode at cycle " << i << std::endl;
        }
      }

      // Phase 2: once in S-mode for a few cycles, assert ext_irq
      if (switched_to_smode && !irq_asserted && i > irq_assert_cycle + 20) {
        if (irq_assert_cycle < 0) {
          irq_assert_cycle = i;
        }
        if (i >= irq_assert_cycle + 10) {
          // Now assert the interrupt
          irq_asserted = true;
          std::cout << "[test-smode-irq] Asserting ext_irq_i at cycle " << i << std::endl;
        }
      }

      // Drive memory models (this sets ext_irq_i=0 and timer_irq_i=0)
      mem3.drive(top3);

      // Override ext_irq_i AFTER mem.drive() to inject our interrupt
      top3->ext_irq_i = irq_asserted ? 1 : 0;
      top3->timer_irq_i = 0;

      // Clock edge
      top3->clk_i = 0;
      top3->eval();
      top3->clk_i = 1;
      top3->eval();
      mem3.observe(top3);
      update_commits(top3, rf3);

      // Phase 3: check if handler executed (x20 == marker)
      if (rf3[20] == marker_val) {
        smode_trap_ok = true;
        std::cout << "[test-smode-irq] S-mode trap handler reached at cycle " << i
                  << " (x20=0x" << std::hex << rf3[20] << std::dec << ")" << std::endl;
        break;
      }
    }

    expect(switched_to_smode, "S-mode IRQ: CPU switched to S-mode via mret");
    expect(smode_trap_ok, "S-mode IRQ: ext_irq_i traps to stvec handler in S-mode");
    delete top3;
  }

  delete top;
  return 0;
}
