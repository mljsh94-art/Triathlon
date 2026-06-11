#include "difftest_client.h"

#include "platform_contract.h"

#include <cstddef>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <iomanip>
#include <iostream>

namespace npc {

namespace {

constexpr uint32_t kAgentWatchPcStart = 0x00013fd0u;
constexpr uint32_t kAgentWatchPcEnd = 0x00014010u;

bool addr_in_range(uint32_t addr, uint32_t base, uint32_t size) {
  return addr >= base && addr < (base + size);
}

void agent_log_difftest_step(uint64_t cycle, uint32_t pc, uint32_t inst,
                             const DUTCoreState &ref_before,
                             const DUTCoreState &ref_after,
                             const DUTCoreState &dut_after,
                             bool skip_ref_exec, bool trap_sync,
                             bool ignore_mmio_load_rd,
                             uint32_t mmio_load_rd,
                             bool inst_is_mmio_store,
                             bool commit_is_mmio_store,
                             bool dut_override_csr,
                             bool linux_atomic_override,
                             bool retire_fetch_override) {
  if (pc < kAgentWatchPcStart || pc > kAgentWatchPcEnd) return;

  // #region agent log
  std::ofstream log("debug-702aba.log", std::ios::app);
  log << "{\"sessionId\":\"702aba\",\"runId\":\"difftest-cross-page\","
      << "\"hypothesisId\":\"H3-H4\","
      << "\"location\":\"npc/csrc/lib/difftest_client.cpp:agent_log_difftest_step\","
      << "\"message\":\"ref step around failing page-boundary instruction\","
      << "\"timestamp\":" << cycle << ",\"data\":{"
      << "\"cycle\":" << cycle
      << ",\"pc\":\"0x" << std::hex << pc
      << "\",\"inst\":\"0x" << inst
      << "\",\"ref_before_pc\":\"0x" << ref_before.pc
      << "\",\"ref_after_pc\":\"0x" << ref_after.pc
      << "\",\"dut_after_pc\":\"0x" << dut_after.pc
      << "\",\"ref_before_x15\":\"0x" << ref_before.gpr[15]
      << "\",\"ref_after_x15\":\"0x" << ref_after.gpr[15]
      << "\",\"dut_after_x15\":\"0x" << dut_after.gpr[15]
      << "\",\"ref_after_x9\":\"0x" << ref_after.gpr[9]
      << "\",\"dut_after_x9\":\"0x" << dut_after.gpr[9]
      << std::dec
      << "\",\"skip_ref_exec\":" << (skip_ref_exec ? 1 : 0)
      << ",\"trap_sync\":" << (trap_sync ? 1 : 0)
      << ",\"ignore_mmio_load_rd\":" << (ignore_mmio_load_rd ? 1 : 0)
      << ",\"mmio_load_rd\":" << mmio_load_rd
      << ",\"inst_is_mmio_store\":" << (inst_is_mmio_store ? 1 : 0)
      << ",\"commit_is_mmio_store\":" << (commit_is_mmio_store ? 1 : 0)
      << ",\"dut_override_csr\":" << (dut_override_csr ? 1 : 0)
      << ",\"linux_atomic_override\":" << (linux_atomic_override ? 1 : 0)
      << ",\"retire_fetch_override\":" << (retire_fetch_override ? 1 : 0)
      << ",\"priv\":" << dut_after.priv
      << "}}\n";
  // #endregion
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
                              const std::array<uint32_t, 32> &rf_after,
                              const DifftestStoreCommit &store_commit,
                              bool trap_sync, bool retire_fetch_override) {
  if (!enabled_) return true;

  DUTCoreState ref_before = {};
  difftest_regcpy_(&ref_before, kDiffTestToDut);
  if (ref_before.pc != pc) {
    uint32_t mtvec_base = dut_after.mtvec & ~0x3u;
    uint32_t stvec_base = dut_after.stvec & ~0x3u;
    bool dut_mmode_trap =
        dut_after.priv == 3u &&
        dut_after.mepc == ref_before.pc && pc == mtvec_base;
    bool dut_smode_trap =
        dut_after.priv == 1u && dut_after.sepc == ref_before.pc &&
        pc == stvec_base;
    if (dut_mmode_trap || dut_smode_trap) {
      DUTCoreState trap_before = dut_after;
      for (size_t reg = 0; reg < rf_before.size(); reg++) {
        trap_before.gpr[reg] = rf_before[reg];
      }
      trap_before.gpr[0] = 0;
      trap_before.pc = pc;
      difftest_regcpy_(&trap_before, kDiffTestToRef);
      ref_before = trap_before;
    } else {
      DUTCoreState dut_before = dut_after;
      dut_before.pc = pc;
      report_mismatch(cycle, pc, inst, "pc_before", dut_before, ref_before);
      return false;
    }
  }

  uint32_t mmio_load_rd = 0;
  uint32_t mmio_load_addr = 0;
  bool ignore_mmio_load_rd =
      decode_mmio_load_rd(inst, rf_before, mmio_load_rd, mmio_load_addr);

  uint32_t store_decode_addr = 0;
  bool inst_is_mmio_store =
      decode_store_addr(inst, rf_before, store_decode_addr) &&
      is_mmio_addr(store_decode_addr);
  bool commit_is_mmio_store = store_commit.valid && is_mmio_addr(store_commit.addr);
  bool linux_atomic_override =
      is_atomic_mem_inst(inst) && dut_after.satp != 0u &&
      (dut_after.priv == 0u || dut_after.priv == 1u);
  bool dut_override_csr = is_dut_override_csr_inst(inst);
  bool skip_ref_exec = trap_sync || ignore_mmio_load_rd || inst_is_mmio_store ||
                       commit_is_mmio_store || dut_override_csr ||
                       linux_atomic_override || retire_fetch_override;

  if (!skip_ref_exec) {
    difftest_exec_(1);
  }

  DUTCoreState ref_after = {};
  difftest_regcpy_(&ref_after, kDiffTestToDut);
  last_ref_state_ = ref_after;
  has_last_ref_state_ = true;

  if (skip_ref_exec) {
    ref_after = dut_after;
    difftest_regcpy_(&ref_after, kDiffTestToRef);
    last_ref_state_ = ref_after;
    sync_store_commit_to_ref(store_commit);
  } else {
    sync_store_commit_to_ref(store_commit);
  }

  sync_platform_mip_to_ref(ref_after, dut_after);

  agent_log_difftest_step(cycle, pc, inst, ref_before, ref_after, dut_after,
                          skip_ref_exec, trap_sync, ignore_mmio_load_rd,
                          mmio_load_rd, inst_is_mmio_store, commit_is_mmio_store,
                          dut_override_csr, linux_atomic_override,
                          retire_fetch_override);

  return check_arch_state(cycle, pc, inst, dut_after, ref_after,
                          ignore_mmio_load_rd, mmio_load_rd);
}

Difftest::~Difftest() { handle_ = nullptr; }

void Difftest::sync_platform_mip_to_ref(DUTCoreState &ref_after,
                                        const DUTCoreState &dut_after) {
  if (ref_after.mip == dut_after.mip) return;

  ref_after.mip = dut_after.mip;
  difftest_regcpy_(&ref_after, kDiffTestToRef);
  last_ref_state_ = ref_after;
}

void Difftest::sync_store_commit_to_ref(
    const DifftestStoreCommit &store_commit) {
  if (store_commit.valid) {
    size_t size = lsu_store_size(store_commit.op);
    if (size != 0) {
      uint32_t payload =
          store_payload(store_commit.data, store_commit.op, store_commit.addr);
      difftest_memcpy_(store_commit.addr, &payload, size, kDiffTestToRef);
    }
  }
}

int32_t Difftest::sext12(uint32_t imm12) {
  return static_cast<int32_t>(imm12 << 20) >> 20;
}

bool Difftest::is_mmio_addr(uint32_t addr) {
  return !addr_in_range(addr, kPmemBase, kPmemSize) ||
         addr_in_range(addr, kBootRomBase, kBootRomSize) ||
         addr_in_range(addr, kClintBase, 0x00010000u) ||
         addr_in_range(addr, kPlicBase, 0x00400000u) ||
         addr_in_range(addr, kVirtioBlkBase, kVirtioBlkSize) ||
         addr_in_range(addr, kUartTx, 8u) ||
         addr == kRtcPortLow || addr == kRtcPortHigh;
}

bool Difftest::decode_mmio_load_rd(uint32_t inst,
                                   const std::array<uint32_t, 32> &rf_before,
                                   uint32_t &rd_out,
                                   uint32_t &addr_out) {
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
  addr_out = addr;
  return true;
}

bool Difftest::decode_store_addr(uint32_t inst,
                                 const std::array<uint32_t, 32> &rf_before,
                                 uint32_t &addr_out) {
  uint32_t opcode = inst & 0x7fu;
  if (opcode != 0x23u) return false;

  uint32_t rs1 = (inst >> 15) & 0x1fu;
  uint32_t imm12 = ((inst >> 20) & 0xfe0u) | ((inst >> 7) & 0x1fu);
  int32_t imm = sext12(imm12);

  if (rs1 >= rf_before.size()) return false;
  addr_out = rf_before[rs1] + static_cast<uint32_t>(imm);
  return true;
}

bool Difftest::is_dut_override_csr_inst(uint32_t inst) {
  uint32_t opcode = inst & 0x7fu;
  if (opcode != 0x73u) return false;

  uint32_t funct3 = (inst >> 12) & 0x7u;
  if (funct3 == 0u) return false;

  uint32_t csr = (inst >> 20) & 0xfffu;
  if (csr == 0xB00u || csr == 0xB02u || csr == 0xB80u ||
      csr == 0xB82u || csr == 0xC00u || csr == 0xC01u ||
      csr == 0xC02u || csr == 0xC80u || csr == 0xC81u ||
      csr == 0xC82u) {
    return true;
  }

  // Keep Spike from modeling CSR state that the RTL intentionally treats as a
  // probe-only zero value. OpenSBI touches PMP before Linux handoff.
  return (csr >= 0x3A0u && csr <= 0x3EFu) ||  // pmpcfg*/pmpaddr*
         (csr >= 0xF11u && csr <= 0xF14u) ||  // mvendorid/marchid/mimpid/mhartid
         csr == 0x7A0u ||                     // tselect
         csr == 0xFB0u ||                     // mconfigptr
         csr == 0x30Au || csr == 0x31Au;      // menvcfg/menvcfgh
}

bool Difftest::is_atomic_mem_inst(uint32_t inst) {
  uint32_t opcode = inst & 0x7fu;
  if (opcode != 0x2Fu) return false;

  uint32_t funct3 = (inst >> 12) & 0x7u;
  return funct3 == 0x2u;  // RV32A .W LR/SC/AMO family
}

size_t Difftest::lsu_store_size(uint32_t op) {
  constexpr uint32_t kLsuSb = 7;
  constexpr uint32_t kLsuSh = 8;
  constexpr uint32_t kLsuSw = 9;
  constexpr uint32_t kLsuSc = 12;
  constexpr uint32_t kLsuScFail = 13;
  constexpr uint32_t kLsuAmo = 14;

  switch (op) {
    case kLsuSb:
      return 1;
    case kLsuSh:
      return 2;
    case kLsuSw:
    case kLsuSc:
    case kLsuAmo:
      return 4;
    case kLsuScFail:
      return 0;
    default:
      return 0;
  }
}

uint32_t Difftest::store_payload(uint32_t data, uint32_t op, uint32_t /*addr*/) {
  constexpr uint32_t kLsuSb = 7;
  constexpr uint32_t kLsuSh = 8;

  if (op == kLsuSb) {
    return data & 0xffu;
  }
  if (op == kLsuSh) {
    return data & 0xffffu;
  }
  return data;
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
