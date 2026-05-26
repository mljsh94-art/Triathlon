#pragma once

#include "platform_contract.h"

#include <array>
#include <cstdint>
#include <iomanip>
#include <iostream>

namespace npc {

inline constexpr uint32_t kLinuxLoadBase = 0x80400000u;
inline constexpr uint32_t kOpenSbiFirmwareBase = kPmemBase;
inline constexpr uint32_t kKernelTrapVecBase = 0xC0001000u;
inline constexpr uint32_t kKernelHighTextBase = 0xC0800000u;

struct LinuxBootStageView {
  uint64_t cycle = 0;
  uint32_t slot = 0;
  uint32_t pc = 0;
  uint32_t inst = 0;
  uint32_t priv = 0;
  bool flush = false;
  uint32_t redirect_pc = 0;
  uint32_t satp = 0;
  uint32_t satp_old = 0;
  uint32_t stvec = 0;
  uint32_t sepc = 0;
  uint32_t scause = 0;
  uint32_t stval = 0;
  uint32_t mstatus = 0;
  uint32_t mepc = 0;
  uint32_t mcause = 0;
  uint32_t mtval = 0;
  uint32_t rob_flush_cause = 0;
  uint32_t dtb_magic = 0;
  const std::array<uint32_t, 32> *rf = nullptr;
};

class LinuxBootStageTracker {
 public:
  template <typename MemT>
  void on_commit(const LinuxBootStageView &view, MemT &mem) {
    if (!view.rf) return;

    if (view.pc == kOpenSbiFirmwareBase && view.priv == 3u) {
      maybe_emit("opensbi-reset", "OpenSBI 复位入口 (M-mode @ 0x80000000)", view, mem, 0);
    }

    if (!linux_entered_ && view.priv == 3u && view.pc >= (kOpenSbiFirmwareBase + 0x00010000u) &&
        view.pc < kLinuxLoadBase) {
      maybe_emit("opensbi-init", "OpenSBI 固件主路径运行中 (M-mode)", view, mem, 1);
    }

    if (!linux_entered_ && view.priv == 3u && view.pc >= 0x80005200u && view.pc < 0x80005400u) {
      maybe_emit("opensbi-pre-jump", "OpenSBI 跳转 Linux 前 (hart_switch_mode 附近)", view, mem, 2);
    }

    if (!linux_entered_ && view.priv == 1u && view.pc >= kLinuxLoadBase && view.pc < kDtbBase) {
      linux_entered_ = true;
      maybe_emit("linux-handoff", "OpenSBI 已跳入 Linux 物理入口 (S-mode @ 0x80400000 区域)", view,
                   mem, 3);
    }

    if (view.priv == 1u && view.pc == kLinuxLoadBase) {
      maybe_emit("linux-head", "Linux Image 头入口 (_start / head.S)", view, mem, 4);
    }

    if (view.priv == 1u && view.pc >= 0x80401000u && view.pc < 0x80401200u) {
      maybe_emit("linux-decompress", "Linux 解压/早期 setup 代码 (0x804010xx)", view, mem, 5);
    }

    if (view.priv == 1u && view.pc == 0x804010d8u) {
      maybe_emit("linux-gp-init", "Linux 设置 gp (decompressor / early C setup)", view, mem, 6);
    }

    if (view.priv == 1u && view.pc >= kKernelTrapVecBase && view.pc < (kKernelTrapVecBase + 0x200u)) {
      maybe_emit("linux-trap-vec", "进入 fixmap trap 向量区 (0xc00010xx)", view, mem, 9);
    }

    if (view.priv == 1u && view.pc >= kKernelHighTextBase) {
      maybe_emit("linux-vtext", "进入内核高地址虚拟文本区 (>= 0xc0800000)", view, mem, 11);
    }

    if (view.priv == 3u && (*view.rf)[10] == kDtbBase) {
      maybe_emit("opensbi-dtb-a0", "OpenSBI 将 DTB 地址装入 a0 (0x87f00000)", view, mem, 12);
    }
    if (view.priv == 1u && (*view.rf)[11] == kDtbBase) {
      maybe_emit("linux-dtb-a1", "Linux S-mode 收到 DTB 指针 (a1 == 0x87f00000)", view, mem, 14);
    }
  }

  template <typename MemT>
  void on_satp_change(const LinuxBootStageView &view, MemT &mem) {
    if (!view.rf) return;
    if (view.satp_old == view.satp) return;

    if (view.satp != 0u && view.priv == 1u && view.pc >= kLinuxLoadBase && view.pc < 0x81000000u) {
      mmu_enabled_in_linux_ = true;
      maybe_emit("linux-mmu-enable", "Linux 开启 SV32 分页 (早期 init_pg_dir)", view, mem, 7);
    }

    if (view.priv == 1u && view.pc >= kKernelTrapVecBase && view.pc < (kKernelTrapVecBase + 0x100u) &&
        view.satp_old != 0u) {
      maybe_emit("linux-swap-pgdir", "trap 路径切换 satp (init_pg_dir -> swapper_pg_dir)", view, mem,
                   10);
    }
  }

  template <typename MemT>
  void on_flush(const LinuxBootStageView &view, uint32_t src_pc, uint32_t src_inst, MemT &mem) {
    if (!view.rf) return;

    if (mmu_enabled_in_linux_ && view.rob_flush_cause == 12u && src_pc >= 0x80401044u &&
        src_pc <= 0x80401050u) {
      maybe_emit("linux-first-ipf", "Linux 首次 instruction page fault (trampoline 开 MMU 后预期)", view,
                   mem, 8, src_pc, src_inst);
    }

    if (view.redirect_pc >= kKernelTrapVecBase &&
        view.redirect_pc < (kKernelTrapVecBase + 0x100u)) {
      maybe_emit("linux-trap-redirect", "异常重定向到 fixmap trap handler", view, mem, 13, src_pc,
                   src_inst);
    }
  }

 private:
  uint32_t seen_mask_ = 0;
  bool linux_entered_ = false;
  bool mmu_enabled_in_linux_ = false;

  template <typename MemT>
  void maybe_emit(const char *tag, const char *desc, const LinuxBootStageView &view, MemT &mem,
                  uint32_t bit, uint32_t src_pc = 0, uint32_t src_inst = 0) {
    if ((seen_mask_ & (1u << bit)) != 0u) return;
    seen_mask_ |= (1u << bit);

    const uint32_t dtb_magic = mem.read_word(kDtbBase);
    const bool fdt_ok = (dtb_magic == 0xedfe0dd0u);  // FDT big-endian magic as host LE word
    std::ios::fmtflags f(std::cout.flags());
    std::cout << "[linux-stage] cycle=" << view.cycle << " stage=" << tag << " desc=\"" << desc
              << "\" slot=" << view.slot << " pc=0x" << std::hex << view.pc << " inst=0x" << view.inst
              << std::dec << " priv=" << view.priv << " flush=" << static_cast<int>(view.flush)
              << " redirect=0x" << std::hex << view.redirect_pc << std::dec;
    if (src_pc != 0u || src_inst != 0u) {
      std::cout << " exc_pc=0x" << std::hex << src_pc << " exc_inst=0x" << src_inst << std::dec;
    }
    std::cout << " satp=0x" << std::hex << view.satp;
    if (view.satp_old != view.satp) {
      std::cout << " satp_old=0x" << view.satp_old;
    }
    std::cout << " stvec=0x" << view.stvec << " sepc=0x" << view.sepc << " scause=0x" << view.scause
              << " stval=0x" << view.stval << " mstatus=0x" << view.mstatus << " mepc=0x" << view.mepc
              << " mcause=0x" << view.mcause << " mtval=0x" << view.mtval << std::dec;
    if (view.rf) {
      std::cout << " a0=0x" << std::hex << (*view.rf)[10] << " a1=0x" << (*view.rf)[11]
                << " sp=0x" << (*view.rf)[2] << " gp=0x" << (*view.rf)[3] << " ra=0x" << (*view.rf)[1]
                << std::dec;
    }
    std::cout << " dtb_magic@87f00000=0x" << std::hex << dtb_magic;
    if (fdt_ok) {
      std::cout << " (FDT_OK)";
    }
    std::cout << std::dec << "\n";
    std::cout.flags(f);
  }
};

}  // namespace npc
