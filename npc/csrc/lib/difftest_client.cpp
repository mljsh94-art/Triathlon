#include "difftest_client.h"

#include "platform_contract.h"

#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <iostream>

namespace npc {

namespace {

bool addr_in_range(uint32_t addr, uint32_t base, uint32_t size) {
  return addr >= base && addr < (base + size);
}

}  // namespace

bool Difftest::init(const std::string &so_path,
                    const std::vector<uint32_t> &pmem_words,
                    uint32_t entry_pc) {
  handle_ = dlopen(so_path.c_str(), RTLD_LAZY);
  if (!handle_) {
    std::cerr << "[difftest] failed to load " << so_path << ": " << dlerror()
              << "\n";
    return false;
  }

  difftest_memcpy_ =
      reinterpret_cast<difftest_memcpy_t>(dlsym(handle_, "difftest_memcpy"));
  difftest_regcpy_ =
      reinterpret_cast<difftest_regcpy_t>(dlsym(handle_, "difftest_regcpy"));
  difftest_exec_ =
      reinterpret_cast<difftest_exec_t>(dlsym(handle_, "difftest_exec"));
  difftest_init_ =
      reinterpret_cast<difftest_init_t>(dlsym(handle_, "difftest_init"));
  difftest_raise_intr_ = reinterpret_cast<difftest_raise_intr_t>(
      dlsym(handle_, "difftest_raise_intr"));

  if (!difftest_memcpy_ || !difftest_regcpy_ || !difftest_exec_ ||
      !difftest_init_) {
    std::cerr << "[difftest] missing required symbols in " << so_path << "\n";
    return false;
  }

  difftest_init_(0);

  std::vector<uint8_t> pmem(kPmemSize, 0);
  size_t max_words = kPmemSize / sizeof(uint32_t);
  size_t word_cnt = pmem_words.size() < max_words ? pmem_words.size() : max_words;
  size_t copy_bytes = word_cnt * sizeof(uint32_t);
  if (copy_bytes > 0) {
    std::memcpy(pmem.data(), pmem_words.data(), copy_bytes);
  }
  difftest_memcpy_(kPmemBase, pmem.data(), pmem.size(), kDiffTestToRef);

  DUTCoreState boot = {};
  boot.pc = entry_pc;
  boot.priv = 3;
  boot.mstatus = 0x1800u;
  difftest_regcpy_(&boot, kDiffTestToRef);
  last_ref_state_ = boot;
  has_last_ref_state_ = true;

  enabled_ = true;
  return true;
}

bool Difftest::enabled() const { return enabled_; }

bool Difftest::step_and_check(uint64_t cycle, uint32_t pc, uint32_t inst,
                              const DUTCoreState &dut_after,
                              const std::array<uint32_t, 32> &rf_before,
                              const std::array<uint32_t, 32> &rf_after) {
  if (!enabled_) return true;

  DUTCoreState ref_before = {};
  difftest_regcpy_(&ref_before, kDiffTestToDut);
  if (ref_before.pc != pc) {
    DUTCoreState dut_before = dut_after;
    dut_before.pc = pc;
    report_mismatch(cycle, pc, inst, "pc_before", dut_before, ref_before);
    return false;
  }

  difftest_exec_(1);

  DUTCoreState ref_after = {};
  difftest_regcpy_(&ref_after, kDiffTestToDut);
  last_ref_state_ = ref_after;
  has_last_ref_state_ = true;

  uint32_t mmio_load_rd = 0;
  bool ignore_mmio_load_rd = decode_mmio_load_rd(inst, rf_before, mmio_load_rd);

  if (ignore_mmio_load_rd && mmio_load_rd != 0) {
    ref_after.gpr[mmio_load_rd] = rf_after[mmio_load_rd];
    difftest_regcpy_(&ref_after, kDiffTestToRef);
    last_ref_state_ = ref_after;
  }

  return check_arch_state(cycle, pc, inst, dut_after, ref_after,
                          ignore_mmio_load_rd, mmio_load_rd);
}

Difftest::~Difftest() { handle_ = nullptr; }

int32_t Difftest::sext12(uint32_t imm12) {
  return static_cast<int32_t>(imm12 << 20) >> 20;
}

bool Difftest::is_mmio_addr(uint32_t addr) {
  return addr_in_range(addr, kBootRomBase, kBootRomSize) ||
         addr_in_range(addr, kClintBase, 0x00010000u) ||
         addr_in_range(addr, kPlicBase, 0x00400000u) ||
         addr_in_range(addr, kVirtioBlkBase, kVirtioBlkSize) ||
         addr_in_range(addr, kUartTx, 8u) ||
         addr == kRtcPortLow || addr == kRtcPortHigh;
}

bool Difftest::decode_mmio_load_rd(uint32_t inst,
                                   const std::array<uint32_t, 32> &rf_before,
                                   uint32_t &rd_out) {
  uint32_t opcode = inst & 0x7fu;
  if (opcode != 0x03u) return false;

  uint32_t rd = (inst >> 7) & 0x1fu;
  uint32_t rs1 = (inst >> 15) & 0x1fu;
  uint32_t imm12 = (inst >> 20) & 0xfffu;
  int32_t imm = sext12(imm12);

  if (rs1 >= rf_before.size()) return false;
  uint32_t addr = rf_before[rs1] + static_cast<uint32_t>(imm);
  if (!is_mmio_addr(addr)) return false;
  if (rd == 0 || rd >= 32) return false;

  rd_out = rd;
  return true;
}

bool Difftest::check_arch_state(uint64_t cycle, uint32_t pc, uint32_t inst,
                                const DUTCoreState &dut_after,
                                const DUTCoreState &ref_after,
                                bool ignore_mmio_load_rd,
                                uint32_t mmio_load_rd) {
  for (int reg = 0; reg < 32; reg++) {
    if (ignore_mmio_load_rd && reg == static_cast<int>(mmio_load_rd)) continue;
    if (ref_after.gpr[reg] != dut_after.gpr[reg]) {
      char field[8];
      std::snprintf(field, sizeof(field), "x%d", reg);
      return report_mismatch(cycle, pc, inst, field, dut_after, ref_after);
    }
  }

#define CHECK_FIELD(name)                                                       \
  do {                                                                          \
    if (dut_after.name != ref_after.name) {                                     \
      return report_mismatch(cycle, pc, inst, #name, dut_after, ref_after);     \
    }                                                                           \
  } while (0)

  CHECK_FIELD(pc);
  CHECK_FIELD(priv);
  CHECK_FIELD(mstatus);
  CHECK_FIELD(sstatus);
  CHECK_FIELD(mepc);
  CHECK_FIELD(sepc);
  CHECK_FIELD(mcause);
  CHECK_FIELD(scause);
  CHECK_FIELD(mtval);
  CHECK_FIELD(stval);
  CHECK_FIELD(mtvec);
  CHECK_FIELD(stvec);
  CHECK_FIELD(mie);
  CHECK_FIELD(mip);
  CHECK_FIELD(medeleg);
  CHECK_FIELD(mideleg);
  CHECK_FIELD(satp);

#undef CHECK_FIELD

  return true;
}

void Difftest::dump_arch_state_compare(const DUTCoreState &dut,
                                       const DUTCoreState &ref) {
  auto print_u32 = [](const char *name, uint32_t dut_val, uint32_t ref_val) {
    if (dut_val == ref_val) {
      std::cerr << "  " << name << " = 0x" << std::hex << dut_val << std::dec
                << "\n";
    } else {
      std::cerr << "  " << name << " dut=0x" << std::hex << dut_val
                << " ref=0x" << ref_val << std::dec << " *\n";
    }
  };

  std::cerr << "[difftest] architectural state compare:\n";
  for (int reg = 0; reg < 32; reg++) {
    char name[8];
    std::snprintf(name, sizeof(name), "x%d", reg);
    print_u32(name, dut.gpr[reg], ref.gpr[reg]);
  }
  print_u32("pc", dut.pc, ref.pc);
  print_u32("priv", dut.priv, ref.priv);
  print_u32("mstatus", dut.mstatus, ref.mstatus);
  print_u32("sstatus", dut.sstatus, ref.sstatus);
  print_u32("mepc", dut.mepc, ref.mepc);
  print_u32("sepc", dut.sepc, ref.sepc);
  print_u32("mcause", dut.mcause, ref.mcause);
  print_u32("scause", dut.scause, ref.scause);
  print_u32("mtval", dut.mtval, ref.mtval);
  print_u32("stval", dut.stval, ref.stval);
  print_u32("mtvec", dut.mtvec, ref.mtvec);
  print_u32("stvec", dut.stvec, ref.stvec);
  print_u32("mie", dut.mie, ref.mie);
  print_u32("mip", dut.mip, ref.mip);
  print_u32("medeleg", dut.medeleg, ref.medeleg);
  print_u32("mideleg", dut.mideleg, ref.mideleg);
  print_u32("satp", dut.satp, ref.satp);
}

bool Difftest::report_mismatch(uint64_t cycle, uint32_t pc, uint32_t inst,
                               const char *field, const DUTCoreState &dut,
                               const DUTCoreState &ref) const {
  std::cerr << "[difftest] mismatch cycle=" << cycle << " pc=0x" << std::hex
            << pc << " inst=0x" << inst << std::dec << " field=" << field
            << "\n";
  dump_arch_state_compare(dut, ref);
  return false;
}

}  // namespace npc
