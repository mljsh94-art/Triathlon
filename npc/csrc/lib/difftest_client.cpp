#include "difftest_client.h"

#include <cstring>
#include <dlfcn.h>
#include <iostream>

namespace npc {

namespace {

constexpr uint32_t kPmemBase = 0x80000000u;
constexpr uint32_t kPmemSize = 0x08000000u;
constexpr uint32_t kMmioBase = 0xA0000000u;
constexpr uint32_t kMmioEnd = 0xAFFFFFFFu;

}  // namespace

bool Difftest::init(const std::string &so_path,
                    const std::vector<uint32_t> &pmem_words,
                    uint32_t entry_pc) {
  handle_ = dlopen(so_path.c_str(), RTLD_LAZY);
  if (!handle_) {
    std::cerr << "[difftest] dlopen failed: " << dlerror() << "\n";
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

  if (!difftest_memcpy_ || !difftest_regcpy_ || !difftest_exec_ ||
      !difftest_init_) {
    std::cerr << "[difftest] dlsym failed: missing required symbols\n";
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
  difftest_memcpy_(kPmemBase, pmem.data(), pmem.size(), kToRef);

  DifftestCPUState boot = {};
  boot.pc = entry_pc;
  boot.csr.mstatus = 0x1800u;
  boot.csr.mtvec = 0x0u;
  boot.csr.mepc = 0x0u;
  boot.csr.mcause = 0x0u;
  difftest_regcpy_(&boot, kToRef);
  last_ref_state_ = boot;
  has_last_ref_state_ = true;

  enabled_ = true;
  std::cout << "[difftest] enabled, image bytes copied=" << pmem.size() << "\n";
  return true;
}

bool Difftest::enabled() const { return enabled_; }

bool Difftest::step_and_check(uint64_t cycle, uint32_t pc, uint32_t inst,
                              const std::array<uint32_t, 32> &rf_before,
                              const std::array<uint32_t, 32> &rf_after) {
  if (!enabled_) return true;

  DifftestCPUState ref_before = {};
  difftest_regcpy_(&ref_before, kToDut);
  if (ref_before.pc != pc) {
    std::cerr << "[difftest] pc mismatch before exec at cycle " << cycle
              << " commit_pc=0x" << std::hex << pc << " ref_pc=0x"
              << ref_before.pc << std::dec << "\n";
    return false;
  }

  difftest_exec_(1);

  DifftestCPUState ref_after = {};
  difftest_regcpy_(&ref_after, kToDut);
  last_ref_state_ = ref_after;
  has_last_ref_state_ = true;

  uint32_t mmio_load_rd = 0;
  bool ignore_mmio_load_rd = decode_mmio_load_rd(inst, rf_before, mmio_load_rd);

  for (int reg = 0; reg < 32; reg++) {
    if (ignore_mmio_load_rd && reg == static_cast<int>(mmio_load_rd)) continue;
    if (ref_after.gpr[reg] != rf_after[reg]) {
      std::cerr << "[difftest] x" << reg << " mismatch at cycle " << cycle
                << " pc=0x" << std::hex << pc << " inst=0x" << inst
                << ": dut=0x" << rf_after[reg] << " ref=0x" << ref_after.gpr[reg]
                << std::dec << "\n";
      return false;
    }
  }

  if (ignore_mmio_load_rd && mmio_load_rd != 0) {
    ref_after.gpr[mmio_load_rd] = rf_after[mmio_load_rd];
    difftest_regcpy_(&ref_after, kToRef);
    last_ref_state_ = ref_after;
  }

  return true;
}

bool Difftest::check_arch_state(uint64_t cycle,
                                const std::array<uint32_t, 32> &rf_after,
                                const DUTCSRState &dut_csr) {
  if (!enabled_ || !has_last_ref_state_) return true;

  for (int reg = 0; reg < 32; reg++) {
    if (last_ref_state_.gpr[reg] != rf_after[reg]) {
      std::cerr << "[difftest] x" << reg << " mismatch at cycle-end " << cycle
                << ": dut=0x" << std::hex << rf_after[reg] << " ref=0x"
                << last_ref_state_.gpr[reg] << std::dec << "\n";
      return false;
    }
  }

  if (last_ref_state_.csr.mtvec != dut_csr.mtvec) {
    std::cerr << "[difftest] mtvec mismatch at cycle-end " << cycle
              << ": dut=0x" << std::hex << dut_csr.mtvec << " ref=0x"
              << last_ref_state_.csr.mtvec << std::dec << "\n";
    return false;
  }
  if (last_ref_state_.csr.mepc != dut_csr.mepc) {
    std::cerr << "[difftest] mepc mismatch at cycle-end " << cycle
              << ": dut=0x" << std::hex << dut_csr.mepc << " ref=0x"
              << last_ref_state_.csr.mepc << std::dec << "\n";
    return false;
  }
  if (last_ref_state_.csr.mstatus != dut_csr.mstatus) {
    std::cerr << "[difftest] mstatus mismatch at cycle-end " << cycle
              << ": dut=0x" << std::hex << dut_csr.mstatus << " ref=0x"
              << last_ref_state_.csr.mstatus << std::dec << "\n";
    return false;
  }
  if (last_ref_state_.csr.mcause != dut_csr.mcause) {
    std::cerr << "[difftest] mcause mismatch at cycle-end " << cycle
              << ": dut=0x" << std::hex << dut_csr.mcause << " ref=0x"
              << last_ref_state_.csr.mcause << std::dec << "\n";
    return false;
  }

  return true;
}

Difftest::~Difftest() { handle_ = nullptr; }

int32_t Difftest::sext12(uint32_t imm12) {
  return static_cast<int32_t>(imm12 << 20) >> 20;
}

bool Difftest::is_mmio_addr(uint32_t addr) {
  return addr >= kMmioBase && addr <= kMmioEnd;
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

}  // namespace npc
