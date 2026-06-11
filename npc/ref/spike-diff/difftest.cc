// Spike rv32imac Sv32 difftest reference wrapper for Triathlon.
// Exports NEMU-compatible difftest_* symbols as a shared library.

#include "difftest_arch.h"

#include "encoding.h"
#include "sim.h"
#include "trap.h"

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr reg_t kPmemBase = 0x80000000u;
constexpr reg_t kPmemSize = 0x08000000u;

#define __EXPORT extern "C" __attribute__((visibility("default")))

static std::vector<std::pair<reg_t, mem_t *>> difftest_mem;
static std::vector<std::pair<reg_t, abstract_device_t *>> difftest_plugin_devices;
static std::vector<std::string> difftest_htif_args;
static std::vector<int> difftest_hartids = {0};

static debug_module_config_t difftest_dm_config = {
    .progbufsize = 2,
    .max_bus_master_bits = 0,
    .require_authentication = false,
    .abstract_rti = 0,
    .support_hasel = true,
    .support_abstract_csr_access = true,
    .support_haltgroups = true,
    .support_impebreak = true,
};

static sim_t *s = nullptr;
static processor_t *p = nullptr;
static state_t *state = nullptr;

static void diff_get_regs(void *buf) {
  auto *ctx = static_cast<npc::DUTCoreState *>(buf);
  for (int i = 0; i < 32; i++) {
    ctx->gpr[i] = static_cast<uint32_t>(state->XPR[i]);
  }
  ctx->pc = static_cast<uint32_t>(state->pc);
  ctx->priv = static_cast<uint32_t>(state->prv);
  ctx->mstatus = static_cast<uint32_t>(p->get_csr(CSR_MSTATUS));
  ctx->sstatus = static_cast<uint32_t>(p->get_csr(CSR_SSTATUS));
  ctx->mepc = static_cast<uint32_t>(p->get_csr(CSR_MEPC));
  ctx->sepc = static_cast<uint32_t>(p->get_csr(CSR_SEPC));
  ctx->mcause = static_cast<uint32_t>(p->get_csr(CSR_MCAUSE));
  ctx->scause = static_cast<uint32_t>(p->get_csr(CSR_SCAUSE));
  ctx->mtval = static_cast<uint32_t>(p->get_csr(CSR_MTVAL));
  ctx->stval = static_cast<uint32_t>(p->get_csr(CSR_STVAL));
  ctx->mtvec = static_cast<uint32_t>(p->get_csr(CSR_MTVEC));
  ctx->stvec = static_cast<uint32_t>(p->get_csr(CSR_STVEC));
  ctx->mie = static_cast<uint32_t>(p->get_csr(CSR_MIE));
  ctx->mip = static_cast<uint32_t>(p->get_csr(CSR_MIP));
  ctx->medeleg = static_cast<uint32_t>(p->get_csr(CSR_MEDELEG));
  ctx->mideleg = static_cast<uint32_t>(p->get_csr(CSR_MIDELEG));
  ctx->satp = static_cast<uint32_t>(p->get_csr(CSR_SATP));
}

static void diff_set_regs(void *buf) {
  auto *ctx = static_cast<npc::DUTCoreState *>(buf);
  for (int i = 0; i < 32; i++) {
    state->XPR.write(i, static_cast<reg_t>(ctx->gpr[i]));
  }
  state->pc = ctx->pc;
  p->set_privilege(ctx->priv);
  p->set_csr(CSR_MSTATUS, ctx->mstatus);
  p->set_csr(CSR_SSTATUS, ctx->sstatus);
  p->set_csr(CSR_MEPC, ctx->mepc);
  p->set_csr(CSR_SEPC, ctx->sepc);
  p->set_csr(CSR_MCAUSE, ctx->mcause);
  p->set_csr(CSR_SCAUSE, ctx->scause);
  p->set_csr(CSR_MTVAL, ctx->mtval);
  p->set_csr(CSR_STVAL, ctx->stval);
  p->set_csr(CSR_MTVEC, ctx->mtvec);
  p->set_csr(CSR_STVEC, ctx->stvec);
  p->set_csr(CSR_MIE, ctx->mie);
  p->set_csr(CSR_MIP, ctx->mip);
  p->set_csr(CSR_MEDELEG, ctx->medeleg);
  p->set_csr(CSR_MIDELEG, ctx->mideleg);
  p->set_csr(CSR_SATP, ctx->satp);
}

static void diff_memcpy(reg_t dest, void *src, size_t n) {
  mmu_t *mmu = p->get_mmu();
  auto *bytes = static_cast<uint8_t *>(src);
  for (size_t i = 0; i < n; i++) {
    mmu->store_uint8(dest + i, bytes[i]);
  }
}

}  // namespace

__EXPORT void difftest_init(int /*port*/) {
  if (s != nullptr) {
    return;
  }

  difftest_htif_args.push_back("");
  difftest_mem.emplace_back(kPmemBase, new mem_t(kPmemSize));

  s = new sim_t("RV32IMAC", "MSU", DEFAULT_VARCH, 1, false, false, 0, 0, nullptr,
                reg_t(-1), difftest_mem, difftest_plugin_devices, difftest_htif_args,
                difftest_hartids, difftest_dm_config, nullptr, false, nullptr,
#ifdef HAVE_BOOST_ASIO
                nullptr, nullptr,
#endif
                nullptr);

  p = s->get_core(0);
  state = p->get_state();
}

__EXPORT void difftest_memcpy(uint32_t addr, void *buf, size_t n, bool direction) {
  assert(s != nullptr && p != nullptr);
  if (direction == npc::kDiffTestToRef) {
    diff_memcpy(addr, buf, n);
  } else {
    assert(false && "difftest_memcpy FROM_REF not implemented");
  }
}

__EXPORT void difftest_regcpy(void *dut, bool direction) {
  assert(s != nullptr && p != nullptr);
  if (direction == npc::kDiffTestToRef) {
    diff_set_regs(dut);
  } else {
    diff_get_regs(dut);
  }
}

__EXPORT void difftest_exec(uint64_t n) {
  assert(p != nullptr);
  p->step(n);
}

__EXPORT void difftest_raise_intr(uint64_t cause) {
  assert(p != nullptr && state != nullptr);
  trap_t t(static_cast<reg_t>(cause));
  p->take_trap_public(t, state->pc);
}

static_assert(sizeof(npc::DUTCoreState) == (32 + 1 + 16) * sizeof(uint32_t),
              "wrapper DUTCoreState layout drift");
