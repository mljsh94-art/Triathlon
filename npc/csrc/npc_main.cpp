#include "Vtb_triathlon.h"
#include "args_parser.h"
#include "boot_loader.h"
#include "difftest_client.h"
#include "linux_boot_stage.h"
#include "memory_models.h"
#include "profile_collector.h"
#include "trap_decode.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  npc::SimArgs args = npc::parse_args(argc, argv);

  if (args.img_path.empty()) {
    std::cerr << "Usage: " << argv[0]
              << " <IMG> [--max-cycles N] [-d REF_SO] [--trace [vcd]] [--commit-trace [START[:END]|START [END]]]"
              << " [--commit-trace-start N] [--commit-trace-end N]"
              << " [--bru-trace] [--fe-trace] [--stall-trace [N]] [--boot-handoff]"
              << " [--dtb <path>] [--firmware-load-base <addr>]"
              << " [--virtio-blk-image <path>]"
              << " [--progress [N]] [--progress-verbose] [--linux-early-debug]\n";
    return 1;
  }

  npc::MemSystem mem;
  uint32_t entry_pc = npc::kPmemBase;
  uint32_t firmware_base_for_watch = npc::kOpenSbiLoadBase;
  if (args.boot_handoff) {
    const uint32_t firmware_base = (args.firmware_load_base != 0)
                                       ? static_cast<uint32_t>(args.firmware_load_base)
                                       : npc::kOpenSbiLoadBase;
    firmware_base_for_watch = firmware_base;
    if (firmware_base == entry_pc) {
      std::ios::fmtflags f(std::cerr.flags());
      std::cerr << "[boot] firmware-load-base 0x" << std::hex << firmware_base
                << " overlaps reset trampoline at 0x" << entry_pc
                << std::dec << "\n";
      std::cerr.flags(f);
      return 1;
    }
    if ((firmware_base & 0x003fffffu) != 0u) {
      std::ios::fmtflags f(std::cerr.flags());
      std::cerr << "[boot] firmware-load-base 0x" << std::hex << firmware_base
                << " is not 4MiB aligned; RV32 Linux setup_vm() will hit BUG_ON.\n"
                << "[boot] use 0x80400000 (recommended) or another 0x400000-aligned address."
                << std::dec << "\n";
      std::cerr.flags(f);
      return 1;
    }
    if (!mem.mem.load_binary(args.img_path, firmware_base)) return 1;

    npc::BootHandoff handoff = npc::make_default_boot_handoff();
    if (!args.dtb_path.empty()) {
      if (!mem.mem.load_binary(args.dtb_path, handoff.dtb_addr)) return 1;
    } else {
      npc::install_minimal_dtb(mem.mem, handoff.dtb_addr);
    }
    npc::install_boot_handoff_stub(mem.mem, firmware_base, handoff, npc::kBootRomBase);
    npc::install_jump_stub(mem.mem, npc::kBootRomBase, entry_pc);
  } else {
    if (!mem.mem.load_binary(args.img_path, npc::kPmemBase)) return 1;
  }
  if (!args.virtio_blk_image.empty()) {
    if (!mem.mem.load_virtio_blk_image(args.virtio_blk_image)) return 1;
  }
  if (args.linux_early_debug && args.boot_handoff) {
    mem.mem.fw_text_watch_base = firmware_base_for_watch;
    mem.mem.fw_text_watch_limit = firmware_base_for_watch + 0x00040000u;
    mem.mem.fw_text_watch_enabled = true;
  }
  mem.icache.mem = &mem.mem;
  mem.dcache.mem = &mem.mem;

  auto *top = new Vtb_triathlon;
  VerilatedVcdC *tfp = nullptr;
  vluint64_t sim_time = 0;

#if VM_TRACE
  if (args.trace) {
    Verilated::traceEverOn(true);
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open(args.trace_path.c_str());
  }
#else
  if (args.trace) {
    std::cerr << "[warn] this binary is built without --trace support, ignore --trace\n";
  }
#endif

  npc::Difftest difftest;
  if (!args.difftest_so.empty()) {
    if (!difftest.init(args.difftest_so, mem.mem.pmem_words, entry_pc)) {
      if (tfp) tfp->close();
      delete top;
      return 1;
    }
  }
  mem.mem.uart_stdout_enabled = !difftest.enabled();

  npc::reset(top, mem, tfp, sim_time);
  auto make_low_mask = [](uint32_t width) -> uint32_t {
    if (width == 0u) return 0u;
    if (width >= 32u) return 0xFFFFFFFFu;
    return (1u << width) - 1u;
  };
  uint32_t cfg_instr_per_fetch = static_cast<uint32_t>(top->dbg_cfg_instr_per_fetch_o);
  if (cfg_instr_per_fetch == 0u || cfg_instr_per_fetch > 32u) {
    cfg_instr_per_fetch = 4u;
  }
  uint32_t cfg_commit_width = static_cast<uint32_t>(top->dbg_cfg_nret_o);
  if (cfg_commit_width == 0u || cfg_commit_width > 32u) {
    cfg_commit_width = 4u;
  }
  const uint32_t cfg_instr_mask = make_low_mask(cfg_instr_per_fetch);

  std::array<uint32_t, 32> rf{};
  uint64_t no_commit_cycles = 0;
  npc::ProfileCollector profile(args, cfg_instr_per_fetch, cfg_commit_width);
  uint32_t last_linux_wait_pc = 0xffffffffu;
  uint64_t last_linux_wait_log_cycle = 0;
  uint64_t last_uart_tx_bytes = 0;
  uint32_t last_flush_src_pc = 0xffffffffu;
  uint64_t last_flush_log_cycle = 0;
  uint64_t setup_vm_step_logs = 0;
  uint64_t create_pgd_step_logs = 0;
  uint64_t opensbi_step_logs = 0;
  uint64_t linux_reloc_step_logs = 0;
  uint64_t linux_fsctx_step_logs = 0;
  uint64_t linux_cgroup_step_logs = 0;
  uint64_t linux_bitops_step_logs = 0;
  uint64_t linux_reloc_bru_logs = 0;
  uint64_t linux_flush_any_logs = 0;
  uint64_t linux_pc_cross_logs = 0;
  uint64_t linux_opensbi_smode_logs = 0;
  uint64_t linux_satp_change_logs = 0;
  uint64_t linux_gp_write_logs = 0;
  uint64_t linux_exc_pair_step_logs = 0;
  uint64_t agent_priv_fault_logs = 0;
  uint64_t last_fw_text_write_count = 0;
  uint32_t last_commit_pc_seen = 0xffffffffu;
  uint32_t last_satp_seen = 0xffffffffu;
  constexpr uint64_t kSetupVmStepLogLimit = 4000;
  constexpr uint64_t kCreatePgdStepLogLimit = 4000;
  constexpr uint64_t kOpenSbiStepLogLimit = 1024;
  constexpr uint64_t kLinuxRelocStepLogLimit = 512;
  constexpr uint64_t kLinuxFsctxStepLogLimit = 256;
  constexpr uint64_t kLinuxCgroupStepLogLimit = 256;
  constexpr uint64_t kLinuxBitopsStepLogLimit = 128;
  constexpr uint64_t kLinuxRelocBruLogLimit = 256;
  constexpr uint64_t kLinuxFlushAnyLogLimit = 512;
  constexpr uint64_t kLinuxPcCrossLogLimit = 128;
  constexpr uint64_t kLinuxOpenSbiSModeLogLimit = 256;
  constexpr uint64_t kLinuxSatpChangeLogLimit = 128;
  constexpr uint64_t kLinuxGpWriteLogLimit = 256;
  constexpr uint64_t kLinuxExcPairLogLimit = 512;
  constexpr uint64_t kLinuxPtWriteLogLimit = 2048;
  constexpr uint64_t kAgentPrivFaultLogLimit = 32;
  constexpr uint32_t kLinuxRelocPcBegin = 0x80801040u;
  constexpr uint32_t kLinuxRelocPcEnd = 0x808010b0u;
  constexpr uint32_t kLinuxFsctxPcBegin = 0xc01d0660u;
  constexpr uint32_t kLinuxFsctxPcEnd = 0xc01d06e0u;
  constexpr uint32_t kLinuxCgroupPcBegin = 0xc00999b0u;
  constexpr uint32_t kLinuxCgroupPcEnd = 0xc0099a40u;
  constexpr uint32_t kLinuxBitopsPcBegin = 0xc03a0320u;
  constexpr uint32_t kLinuxBitopsPcEnd = 0xc03a0388u;
  constexpr uint32_t kLinuxExcPcA = 0xc076a580u;
  constexpr uint32_t kLinuxExcPcB = 0xc074befeu;
  constexpr uint32_t kLinuxPtWatchBase = 0x81002000u;
  constexpr uint32_t kLinuxPtWatchEnd = 0x81004000u;
  uint64_t linux_pt_write_logs = 0;
  npc::LinuxBootStageTracker linux_stages;

  auto commit_trace_active = [&](uint64_t cycle) {
    if (!args.commit_trace) return false;
    if (cycle < args.commit_trace_start) return false;
    if (args.commit_trace_end != 0 && cycle > args.commit_trace_end) return false;
    return true;
  };

  auto pte_flags = [](uint32_t pte) {
    std::string flags;
    flags.reserve(8);
    flags.push_back((pte & (1u << 0)) ? 'v' : '-');
    flags.push_back((pte & (1u << 1)) ? 'r' : '-');
    flags.push_back((pte & (1u << 2)) ? 'w' : '-');
    flags.push_back((pte & (1u << 3)) ? 'x' : '-');
    flags.push_back((pte & (1u << 4)) ? 'u' : '-');
    flags.push_back((pte & (1u << 5)) ? 'g' : '-');
    flags.push_back((pte & (1u << 6)) ? 'a' : '-');
    flags.push_back((pte & (1u << 7)) ? 'd' : '-');
    return flags;
  };

  auto pte_valid = [](uint32_t pte) {
    const bool v = (pte & 0x1u) != 0u;
    const bool r = (pte & 0x2u) != 0u;
    const bool w = (pte & 0x4u) != 0u;
    return v && !(w && !r);
  };

  auto pte_leaf = [](uint32_t pte) {
    return (pte & 0xau) != 0u;
  };

  auto emit_sv32_fault_walk = [&](uint64_t cycle, uint32_t cause, uint32_t src_pc,
                                 uint32_t fault_va) {
    if (cause != 12u && cause != 13u && cause != 15u) return;
    const uint32_t satp = top->dbg_csr_satp_o;
    const bool sv32_enabled = (satp & 0x80000000u) != 0u;
    const char *access = (cause == 12u) ? "exec" : ((cause == 13u) ? "load" : "store");

    const uint32_t root_base = (satp & 0x003fffffu) << 12;
    const uint32_t vpn1 = fault_va >> 22;
    const uint32_t vpn0 = (fault_va >> 12) & 0x3ffu;
    const uint32_t page_off = fault_va & 0xfffu;
    const uint32_t l1_addr = root_base + (vpn1 << 2);
    uint32_t l1_pte = 0;
    const bool l1_read = mem.mem.read_phys_u32(l1_addr, l1_pte);
    const bool l1_ok = l1_read && pte_valid(l1_pte);
    const bool l1_is_leaf = l1_ok && pte_leaf(l1_pte);

    uint32_t l0_base = 0;
    uint32_t l0_addr = 0;
    uint32_t l0_pte = 0;
    bool l0_read = false;
    bool l0_ok = false;
    bool l0_is_leaf = false;
    uint32_t resolved_pa = 0;
    bool resolved = false;

    if (l1_is_leaf) {
      const uint32_t ppn1 = (l1_pte >> 20) & 0xfffu;
      resolved_pa = (ppn1 << 22) | (vpn0 << 12) | page_off;
      resolved = true;
    } else if (l1_ok) {
      l0_base = ((l1_pte >> 10) & 0x003fffffu) << 12;
      l0_addr = l0_base + (vpn0 << 2);
      l0_read = mem.mem.read_phys_u32(l0_addr, l0_pte);
      l0_ok = l0_read && pte_valid(l0_pte);
      l0_is_leaf = l0_ok && pte_leaf(l0_pte);
      if (l0_is_leaf) {
        const uint32_t ppn = (l0_pte >> 10) & 0x003fffffu;
        resolved_pa = (ppn << 12) | page_off;
        resolved = true;
      }
    }

    std::ios::fmtflags f(std::cout.flags());
    std::cout << "[debug][sv32-fault-walk] cycle=" << cycle
              << " cause=0x" << std::hex << cause
              << " access=" << access
              << " src_pc=0x" << src_pc
              << " fault_va=0x" << fault_va
              << " satp=0x" << satp
              << " root_base=0x" << root_base
              << " vpn1=0x" << vpn1
              << " vpn0=0x" << vpn0
              << " off=0x" << page_off
              << " l1_addr=0x" << l1_addr
              << " l1_pte=0x" << l1_pte
              << std::dec
              << " sv32=" << static_cast<int>(sv32_enabled)
              << " l1_read=" << static_cast<int>(l1_read)
              << " l1_ok=" << static_cast<int>(l1_ok)
              << " l1_leaf=" << static_cast<int>(l1_is_leaf)
              << " l1_flags=" << pte_flags(l1_pte);
    if (l1_ok && !l1_is_leaf) {
      std::cout << " l0_base=0x" << std::hex << l0_base
                << " l0_addr=0x" << l0_addr
                << " l0_pte=0x" << l0_pte
                << std::dec
                << " l0_read=" << static_cast<int>(l0_read)
                << " l0_ok=" << static_cast<int>(l0_ok)
                << " l0_leaf=" << static_cast<int>(l0_is_leaf)
                << " l0_flags=" << pte_flags(l0_pte);
    }
    if (resolved) {
      std::cout << " resolved_pa=0x" << std::hex << resolved_pa << std::dec;
    }
    std::cout << "\n";
    std::cout.flags(f);
  };

  auto make_linux_stage_view = [&](uint64_t cycle, uint32_t slot, uint32_t pc, uint32_t inst,
                                   const std::array<uint32_t, 32> &regs) {
    npc::LinuxBootStageView view{};
    view.cycle = cycle;
    view.slot = slot;
    view.pc = pc;
    view.inst = inst;
    view.priv = static_cast<uint32_t>(top->dbg_csr_priv_mode_o);
    view.flush = top->backend_flush_o != 0;
    view.redirect_pc = top->backend_redirect_pc_o;
    view.satp = top->dbg_csr_satp_o;
    view.satp_old = last_satp_seen;
    view.stvec = top->dbg_csr_stvec_o;
    view.sepc = top->dbg_csr_sepc_o;
    view.scause = top->dbg_csr_scause_o;
    view.stval = top->dbg_csr_stval_o;
    view.mstatus = top->dbg_csr_mstatus_o;
    view.mepc = top->dbg_csr_mepc_o;
    view.mcause = top->dbg_csr_mcause_o;
    view.mtval = top->dbg_csr_stval_o;
    view.rob_flush_cause = static_cast<uint32_t>(top->dbg_rob_flush_cause_o);
    view.rf = &regs;
    return view;
  };

  for (uint64_t cycles = 0; cycles < args.max_cycles; cycles++) {
    mem.mem.set_time_us(cycles);
    npc::tick(top, mem, tfp, sim_time);
    profile.observe_cycle(top);

    if (top->dbg_sb_dcache_req_valid_o && top->dbg_sb_dcache_req_ready_o) {
      uint32_t addr = top->dbg_sb_dcache_req_addr_o;
      uint32_t data = top->dbg_sb_dcache_req_data_o;
      uint32_t op = top->dbg_sb_dcache_req_op_o;
      uint32_t aligned = addr & ~0x3u;
      bool watch_pt_write = args.linux_early_debug &&
                            (aligned >= kLinuxPtWatchBase) &&
                            (aligned < kLinuxPtWatchEnd) &&
                            (linux_pt_write_logs < kLinuxPtWriteLogLimit);
      uint32_t old_word = 0;
      if (watch_pt_write) {
        old_word = mem.mem.read_word(aligned);
      }
      mem.mem.write_store(addr, data, op);
      if (watch_pt_write) {
        uint32_t new_word = mem.mem.read_word(aligned);
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[debug][pt-write] cycle=" << cycles
                  << " addr=0x" << std::hex << addr
                  << " aligned=0x" << aligned
                  << " data=0x" << data
                  << " old=0x" << old_word
                  << " new=0x" << new_word
                  << " satp=0x" << top->dbg_csr_satp_o
                  << " rob_head_pc=0x" << top->dbg_rob_head_pc_o
                  << " c0=0x" << top->commit_pc_o[0]
                  << " c1=0x" << top->commit_pc_o[1]
                  << " c2=0x" << top->commit_pc_o[2]
                  << " c3=0x" << top->commit_pc_o[3]
                  << std::dec
                  << " op=" << op
                  << " priv=" << static_cast<int>(top->dbg_csr_priv_mode_o)
                  << " commit_v=0x" << std::hex << static_cast<uint32_t>(top->commit_valid_o)
                  << std::dec << "\n";
        std::cout.flags(f);
        linux_pt_write_logs++;
      }
      if (commit_trace_active(cycles)) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[stwb  ] cycle=" << cycles
                  << " addr=0x" << std::hex << addr
                  << " data=0x" << data
                  << std::dec
                  << " op=" << op
                  << ((addr == npc::kSeed4Addr) ? " <seed4>" : "")
                  << "\n";
        std::cout.flags(f);
      }
    }

    if (commit_trace_active(cycles) && top->dbg_lsu_ld_fire_o) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[ldreq ] cycle=" << cycles
                << " addr=0x" << std::hex << top->dbg_lsu_ld_req_addr_o
                << " tag=0x" << static_cast<uint32_t>(top->dbg_lsu_inflight_tag_o)
                << ((top->dbg_lsu_ld_req_addr_o == npc::kSeed4Addr) ? " <seed4>" : "")
                << std::dec << "\n";
      std::cout.flags(f);
    }

    if (commit_trace_active(cycles) && top->dbg_lsu_rsp_fire_o) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[ldrsp ] cycle=" << cycles
                << " addr=0x" << std::hex << top->dbg_lsu_inflight_addr_o
                << " tag=0x" << static_cast<uint32_t>(top->dbg_lsu_inflight_tag_o)
                << " data=0x" << top->dbg_lsu_ld_rsp_data_o
                << std::dec
                << " err=" << static_cast<int>(top->dbg_lsu_ld_rsp_err_o)
                << ((top->dbg_lsu_inflight_addr_o == npc::kSeed4Addr) ? " <seed4>" : "")
                << "\n";
      std::cout.flags(f);
    }

    profile.record_flush(cycles, top, mem.mem);

    if (!args.boot_handoff && top->backend_flush_o && top->dbg_rob_flush_o &&
        top->dbg_rob_flush_is_exception_o) {
      uint32_t src_pc = top->dbg_rob_flush_src_pc_o;
      uint32_t src_inst = mem.mem.read_word(src_pc);
      if (npc::is_ebreak_insn_word(src_inst, src_pc)) {
        uint32_t code = rf[10];
        if (code == 0) {
          std::cout << "HIT GOOD TRAP\n";
          double ipc = cycles ? static_cast<double>(profile.total_commits()) / static_cast<double>(cycles) : 0.0;
          double cpi = profile.total_commits() ? static_cast<double>(cycles) / static_cast<double>(profile.total_commits()) : 0.0;
          std::cout << "IPC=" << ipc << " CPI=" << cpi
                    << " cycles=" << cycles
                    << " commits=" << profile.total_commits() << "\n";
          profile.emit_summary(cycles, top);
          if (tfp) tfp->close();
          delete top;
          return 0;
        }
        std::cout << "HIT BAD TRAP (code=" << code << ")\n";
        profile.emit_summary(cycles, top);
        if (tfp) tfp->close();
        delete top;
        return 1;
      }
    }

    if (top->backend_flush_o && top->dbg_rob_flush_o &&
        top->dbg_rob_flush_is_exception_o) {
      uint32_t src_pc = top->dbg_rob_flush_src_pc_o;
      uint32_t src_inst = mem.mem.read_word(src_pc);
      if (args.linux_early_debug && !linux_stages.all_seen()) {
        npc::LinuxBootStageView flush_view = make_linux_stage_view(cycles, 0, src_pc, src_inst, rf);
        linux_stages.on_flush(flush_view, src_pc, src_inst, mem.mem);
      }
      if (args.linux_early_debug) {
        bool pc_changed = (src_pc != last_flush_src_pc);
        bool periodic_log = (cycles - last_flush_log_cycle >= 100000ull);
        if (pc_changed || periodic_log) {
          uint32_t flush_cause = static_cast<uint32_t>(top->dbg_rob_flush_cause_o);
          uint32_t trap_tval = top->dbg_csr_trap_tval_o;
          // #region agent log
          if (agent_priv_fault_logs < kAgentPrivFaultLogLimit &&
              flush_cause == 12 && top->dbg_csr_priv_mode_o == 1 &&
              trap_tval >= 0x90000000u && trap_tval < 0xc0000000u) {
            const uint32_t fault_va = trap_tval;
            const uint32_t satp = top->dbg_csr_satp_o;
            const uint32_t root_base = (satp & 0x003fffffu) << 12;
            const uint32_t vpn1 = fault_va >> 22;
            const uint32_t vpn0 = (fault_va >> 12) & 0x3ffu;
            const uint32_t l1_addr = root_base + (vpn1 << 2);
            const uint32_t l1_pte = mem.mem.read_word(l1_addr);
            const bool l1_valid = (l1_pte & 0x1u) != 0u && !((l1_pte & 0x4u) && !(l1_pte & 0x2u));
            const bool l1_leaf = (l1_pte & 0xau) != 0u;
            uint32_t l0_addr = 0;
            uint32_t l0_pte = 0;
            if (l1_valid && !l1_leaf) {
              l0_addr = ((l1_pte >> 10) << 12) + (vpn0 << 2);
              l0_pte = mem.mem.read_word(l0_addr);
            }
            std::ofstream("../debug-fd94f9.log", std::ios::app)
                << "{\"sessionId\":\"fd94f9\",\"runId\":\"priv-mismatch-flush\","
                << "\"hypothesisId\":\"H1-H3\","
                << "\"location\":\"npc/csrc/npc_main.cpp:flush_exception\","
                << "\"message\":\"S-mode instruction page fault on user virtual page\","
                << "\"timestamp\":" << cycles
                << ",\"data\":{\"cycle\":" << cycles
                << ",\"srcPc\":\"0x" << std::hex << src_pc
                << "\",\"faultVa\":\"0x" << fault_va
                << "\",\"satp\":\"0x" << satp
                << "\",\"mstatus\":\"0x" << top->dbg_csr_mstatus_o
                << "\",\"sepc\":\"0x" << top->dbg_csr_sepc_o
                << "\",\"stval\":\"0x" << top->dbg_csr_stval_o
                << "\",\"scause\":\"0x" << top->dbg_csr_scause_o
                << "\",\"l1Pte\":\"0x" << l1_pte
                << "\",\"l0Pte\":\"0x" << l0_pte
                << "\",\"l0User\":" << std::dec << static_cast<int>((l0_pte & 0x10u) != 0u)
                << ",\"l0Exec\":" << static_cast<int>((l0_pte & 0x8u) != 0u)
                << "}}\n";
            agent_priv_fault_logs++;
          }
          // #endregion
          std::ios::fmtflags f(std::cout.flags());
          std::cout << "[debug][flush-exc] cycle=" << cycles
                    << " src_pc=0x" << std::hex << src_pc
                    << " src_inst=0x" << src_inst
                    << " cause=0x" << flush_cause
                    << " trap_tval=0x" << trap_tval
                    << " mcause=0x" << top->dbg_csr_mcause_o
                    << " mepc=0x" << top->dbg_csr_mepc_o
                    << " mtval(aliased)=0x" << top->dbg_csr_stval_o
                    << " mstatus=0x" << top->dbg_csr_mstatus_o
                    << " scause=0x" << top->dbg_csr_scause_o
                    << " sepc=0x" << top->dbg_csr_sepc_o
                    << " stval=0x" << top->dbg_csr_stval_o
                    << " satp=0x" << top->dbg_csr_satp_o
                    << " priv=0x" << static_cast<uint32_t>(top->dbg_csr_priv_mode_o)
                    << std::dec << "\n";
          std::cout.flags(f);
          emit_sv32_fault_walk(cycles, flush_cause, src_pc, trap_tval);
          last_flush_src_pc = src_pc;
          last_flush_log_cycle = cycles;
        }
      }
    }

    if (args.linux_early_debug && top->backend_flush_o && top->dbg_rob_flush_o &&
        linux_flush_any_logs < kLinuxFlushAnyLogLimit) {
      uint32_t src_pc = top->dbg_rob_flush_src_pc_o;
      uint32_t redirect_pc = top->backend_redirect_pc_o;
      bool watch_flush = ((src_pc >= kLinuxRelocPcBegin && src_pc < kLinuxRelocPcEnd) ||
                          (src_pc >= kLinuxFsctxPcBegin && src_pc < kLinuxFsctxPcEnd) ||
                          (redirect_pc >= npc::kOpenSbiLoadBase &&
                           redirect_pc < (npc::kOpenSbiLoadBase + 0x00050000u)));
      if (watch_flush) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[debug][flush-any] cycle=" << cycles
                  << " src_pc=0x" << std::hex << src_pc
                  << " src_inst=0x" << mem.mem.read_word(src_pc)
                  << " backend_rdir=0x" << redirect_pc
                  << " retire_rdir=0x" << top->dbg_retire_redirect_pc_o
                  << " cause=0x" << static_cast<uint32_t>(top->dbg_rob_flush_cause_o)
                  << std::dec
                  << " is_exc=" << static_cast<int>(top->dbg_rob_flush_is_exception_o)
                  << " is_mispred=" << static_cast<int>(top->dbg_rob_flush_is_mispred_o)
                  << " is_branch=" << static_cast<int>(top->dbg_rob_flush_is_branch_o)
                  << " is_jump=" << static_cast<int>(top->dbg_rob_flush_is_jump_o)
                  << " priv=" << static_cast<int>(top->dbg_csr_priv_mode_o)
                  << "\n";
        std::cout.flags(f);
        linux_flush_any_logs++;
      }
    }

    if (args.bru_trace && top->dbg_bru_wb_valid_o) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[bruwb ] cycle=" << cycles
                << " pc=0x" << std::hex << top->dbg_bru_pc_o
                << " v1=0x" << top->dbg_bru_v1_o
                << " v2=0x" << top->dbg_bru_v2_o
                << " redirect=0x" << top->dbg_bru_redirect_pc_o
                << std::dec
                << " mispred=" << static_cast<int>(top->dbg_bru_mispred_o)
                << " is_jump=" << static_cast<int>(top->dbg_bru_is_jump_o)
                << " is_branch=" << static_cast<int>(top->dbg_bru_is_branch_o)
                << " op=" << static_cast<int>(top->dbg_bru_op_o)
                << "\n";
      std::cout.flags(f);
    }

    if (args.linux_early_debug && top->dbg_bru_wb_valid_o &&
        linux_reloc_bru_logs < kLinuxRelocBruLogLimit) {
      uint32_t bru_pc = top->dbg_bru_pc_o;
      if (bru_pc >= kLinuxRelocPcBegin && bru_pc < kLinuxRelocPcEnd) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[debug][bruwb-reloc] cycle=" << cycles
                  << " pc=0x" << std::hex << bru_pc
                  << " v1=0x" << top->dbg_bru_v1_o
                  << " v2=0x" << top->dbg_bru_v2_o
                  << " redirect=0x" << top->dbg_bru_redirect_pc_o
                  << " backend_rdir=0x" << top->backend_redirect_pc_o
                  << " retire_rdir=0x" << top->dbg_retire_redirect_pc_o
                  << std::dec
                  << " mispred=" << static_cast<int>(top->dbg_bru_mispred_o)
                  << " is_jump=" << static_cast<int>(top->dbg_bru_is_jump_o)
                  << " is_branch=" << static_cast<int>(top->dbg_bru_is_branch_o)
                  << " op=" << static_cast<int>(top->dbg_bru_op_o)
                  << " flush=" << static_cast<int>(top->backend_flush_o)
                  << "\n";
        std::cout.flags(f);
        linux_reloc_bru_logs++;
      }
    }

    uint32_t commit_this_cycle = 0;
    for (uint32_t i = 0; i < cfg_commit_width; i++) {
      bool valid = (top->commit_valid_o >> i) & 0x1;
      if (!valid) continue;
      commit_this_cycle++;

      std::array<uint32_t, 32> rf_before = rf;

      bool we = (top->commit_we_o >> i) & 0x1;
      uint32_t rd = (top->commit_areg_o >> (i * 5)) & 0x1F;
      uint32_t data = top->commit_wdata_o[i];
      if (we && rd != 0) {
        rf[rd] = data;
      }

      uint32_t pc = top->commit_pc_o[i];
      uint32_t inst = top->commit_inst_o[i];
      uint32_t decoded_inst = top->commit_decoded_inst_o[i];
      bool is_rvc = ((top->commit_is_rvc_o >> i) & 0x1) != 0;
      uint32_t satp_now = top->dbg_csr_satp_o;
      const bool satp_changed = (satp_now != last_satp_seen);
      if (satp_changed) {
        const uint32_t satp_old = last_satp_seen;
        last_satp_seen = satp_now;
        if (args.linux_early_debug && !linux_stages.all_seen()) {
          npc::LinuxBootStageView satp_view = make_linux_stage_view(cycles, i, pc, inst, rf);
          satp_view.satp_old = satp_old;
          satp_view.satp = satp_now;
          linux_stages.on_satp_change(satp_view, mem.mem);
        }

        if (args.linux_early_debug && linux_satp_change_logs < kLinuxSatpChangeLogLimit) {
          std::ios::fmtflags f(std::cout.flags());
          std::cout << "[debug][satp-change] cycle=" << cycles
                    << " slot=" << i
                    << " pc=0x" << std::hex << pc
                    << " inst=0x" << inst
                    << " satp_old=0x" << satp_old
                    << " satp_new=0x" << satp_now
                    << " stvec=0x" << top->dbg_csr_stvec_o
                    << " sepc=0x" << top->dbg_csr_sepc_o
                    << " mstatus=0x" << top->dbg_csr_mstatus_o
                    << " mepc=0x" << top->dbg_csr_mepc_o
                    << std::dec
                    << " priv=" << static_cast<int>(top->dbg_csr_priv_mode_o)
                    << " flush=" << static_cast<int>(top->backend_flush_o)
                    << " ra=0x" << std::hex << rf[1]
                    << " a0=0x" << rf[10]
                    << std::dec << "\n";
          std::cout.flags(f);
          linux_satp_change_logs++;
          if (satp_old != 0u) {
            uint32_t root_ppn = satp_old & 0x003fffffu;
            uint32_t root_base = root_ppn << 12;
            uint32_t vpn1 = pc >> 22;
            uint32_t vpn0 = (pc >> 12) & 0x3ffu;
            uint32_t l1_addr = root_base + (vpn1 << 2);
            uint32_t l1_pte = mem.mem.read_word(l1_addr);
            bool l1_valid = (l1_pte & 0x1u) != 0u;
            bool l1_leaf = (l1_pte & 0xau) != 0u;
            std::ios::fmtflags fw(std::cout.flags());
            std::cout << "[debug][pt-walk] cycle=" << cycles
                      << " pc=0x" << std::hex << pc
                      << " satp_old=0x" << satp_old
                      << " root_base=0x" << root_base
                      << " vpn1=0x" << vpn1
                      << " vpn0=0x" << vpn0
                      << " l1_addr=0x" << l1_addr
                      << " l1_pte=0x" << l1_pte
                      << std::dec
                      << " l1_valid=" << static_cast<int>(l1_valid)
                      << " l1_leaf=" << static_cast<int>(l1_leaf);
            if (l1_valid && !l1_leaf) {
              uint32_t l0_base = (l1_pte >> 10) << 12;
              uint32_t l0_addr = l0_base + (vpn0 << 2);
              uint32_t l0_pte = mem.mem.read_word(l0_addr);
              std::cout << " l0_base=0x" << std::hex << l0_base
                        << " l0_addr=0x" << l0_addr
                        << " l0_pte=0x" << l0_pte
                        << std::dec;
            }
            std::cout << "\n";
            std::cout.flags(fw);
          }
        }
      }
      if (args.linux_early_debug && !linux_stages.all_seen()) {
        linux_stages.on_commit(make_linux_stage_view(cycles, i, pc, inst, rf), mem.mem);
      }
      if (args.linux_early_debug) {
        if (we && rd == 3 && linux_gp_write_logs < kLinuxGpWriteLogLimit) {
          std::ios::fmtflags f(std::cout.flags());
          std::cout << "[debug][gp-write] cycle=" << cycles
                    << " slot=" << i
                    << " pc=0x" << std::hex << pc
                    << " inst=0x" << inst
                    << " gp_old=0x" << rf_before[3]
                    << " gp_new=0x" << rf[3]
                    << " satp=0x" << top->dbg_csr_satp_o
                    << std::dec
                    << " priv=" << static_cast<int>(top->dbg_csr_priv_mode_o)
                    << " flush=" << static_cast<int>(top->backend_flush_o)
                    << "\n";
          std::cout.flags(f);
          linux_gp_write_logs++;
        }
        bool cross_high_to_low = (last_commit_pc_seen >= 0xc0000000u) &&
                                 (pc < 0x90000000u);
        if (cross_high_to_low && linux_pc_cross_logs < kLinuxPcCrossLogLimit) {
          std::ios::fmtflags f(std::cout.flags());
          std::cout << "[debug][pc-cross] cycle=" << cycles
                    << " slot=" << i
                    << " prev_pc=0x" << std::hex << last_commit_pc_seen
                    << " pc=0x" << pc
                    << " inst=0x" << inst
                    << " satp=0x" << top->dbg_csr_satp_o
                    << " stvec=0x" << top->dbg_csr_stvec_o
                    << " sepc=0x" << top->dbg_csr_sepc_o
                    << " mstatus=0x" << top->dbg_csr_mstatus_o
                    << " mepc=0x" << top->dbg_csr_mepc_o
                    << " backend_rdir=0x" << top->backend_redirect_pc_o
                    << " retire_rdir=0x" << top->dbg_retire_redirect_pc_o
                    << std::dec
                    << " priv=" << static_cast<int>(top->dbg_csr_priv_mode_o)
                    << " flush=" << static_cast<int>(top->backend_flush_o)
                    << " rob_flush=" << static_cast<int>(top->dbg_rob_flush_o)
                    << " rob_flush_exc=" << static_cast<int>(top->dbg_rob_flush_is_exception_o)
                    << " rob_flush_mispred=" << static_cast<int>(top->dbg_rob_flush_is_mispred_o)
                    << " ra=0x" << std::hex << rf[1]
                    << " a0=0x" << rf[10]
                    << std::dec << "\n";
          std::cout.flags(f);
          linux_pc_cross_logs++;
        }
        bool opensbi_in_smode = (pc >= npc::kOpenSbiLoadBase) &&
                                (pc < (npc::kOpenSbiLoadBase + 0x00050000u)) &&
                                (top->dbg_csr_priv_mode_o != 3);
        if (opensbi_in_smode && linux_opensbi_smode_logs < kLinuxOpenSbiSModeLogLimit) {
          std::ios::fmtflags f(std::cout.flags());
          std::cout << "[debug][opensbi-smode] cycle=" << cycles
                    << " slot=" << i
                    << " pc=0x" << std::hex << pc
                    << " inst=0x" << inst
                    << " satp=0x" << top->dbg_csr_satp_o
                    << " stvec=0x" << top->dbg_csr_stvec_o
                    << " sepc=0x" << top->dbg_csr_sepc_o
                    << " mstatus=0x" << top->dbg_csr_mstatus_o
                    << " mepc=0x" << top->dbg_csr_mepc_o
                    << " backend_rdir=0x" << top->backend_redirect_pc_o
                    << " retire_rdir=0x" << top->dbg_retire_redirect_pc_o
                    << " ra=0x" << rf[1]
                    << " a0=0x" << rf[10]
                    << std::dec
                    << " priv=" << static_cast<int>(top->dbg_csr_priv_mode_o)
                    << " flush=" << static_cast<int>(top->backend_flush_o)
                    << "\n";
          std::cout.flags(f);
          linux_opensbi_smode_logs++;
        }
      }
      profile.record_commit(pc, inst, decoded_inst, is_rvc);
      if (args.linux_early_debug &&
          pc >= 0x810043b0u && pc < 0x81004430u &&
          setup_vm_step_logs < kSetupVmStepLogLimit) {
        std::ios::fmtflags f(std::cout.flags());
          std::cout << "[debug][setup-vm-step] cycle=" << cycles
                  << " slot=" << i
                  << " pc=0x" << std::hex << pc
                  << " inst=0x" << inst
                  << " we=" << std::dec << static_cast<uint32_t>(we)
                  << " rd=x" << static_cast<uint32_t>(rd)
                  << " wdata=0x" << std::hex << data
                  << " a0=0x" << rf[10]
                  << " a1=0x" << rf[11]
                  << " a2=0x" << rf[12]
                  << " a3=0x" << rf[13]
                  << " a4=0x" << rf[14]
                  << " a5=0x" << rf[15]
                  << " sp=0x" << rf[2]
                  << " ra=0x" << rf[1]
                  << " s0=0x" << rf[8]
                  << " s1=0x" << rf[9]
                  << " s2=0x" << rf[18]
                  << " s3=0x" << rf[19]
                  << std::dec << "\n";
        std::cout.flags(f);
        setup_vm_step_logs++;
      }
      if (args.linux_early_debug &&
          pc >= 0x81004230u && pc < 0x810042f0u &&
          create_pgd_step_logs < kCreatePgdStepLogLimit) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[debug][create-pgd-step] cycle=" << cycles
                  << " slot=" << i
                  << " pc=0x" << std::hex << pc
                  << " inst=0x" << inst
                  << " we=" << std::dec << static_cast<uint32_t>(we)
                  << " rd=x" << static_cast<uint32_t>(rd)
                  << " wdata=0x" << std::hex << data
                  << " a0=0x" << rf[10]
                  << " a1=0x" << rf[11]
                  << " a2=0x" << rf[12]
                  << " a3=0x" << rf[13]
                  << " a4=0x" << rf[14]
                  << " a5=0x" << rf[15]
                  << " s2=0x" << rf[18]
                  << " s3=0x" << rf[19]
                  << " s4=0x" << rf[20]
                  << std::dec << "\n";
        std::cout.flags(f);
        create_pgd_step_logs++;
      }
      if (args.linux_early_debug &&
          pc >= 0x804007e0u && pc < 0x80400820u &&
          opensbi_step_logs < kOpenSbiStepLogLimit) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[debug][opensbi-step] cycle=" << cycles
                  << " slot=" << i
                  << " pc=0x" << std::hex << pc
                  << " inst=0x" << inst
                  << " priv=0x" << static_cast<uint32_t>(top->dbg_csr_priv_mode_o)
                  << " satp=0x" << top->dbg_csr_satp_o
                  << " mstatus=0x" << top->dbg_csr_mstatus_o
                  << " mepc=0x" << top->dbg_csr_mepc_o
                  << " mtval(aliased)=0x" << top->dbg_csr_stval_o
                  << std::dec << "\n";
        std::cout.flags(f);
        opensbi_step_logs++;
      }
      if (args.linux_early_debug &&
          (pc == kLinuxExcPcA || pc == kLinuxExcPcB) &&
          linux_exc_pair_step_logs < kLinuxExcPairLogLimit) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[debug][linux-exc-pair-step] cycle=" << cycles
                  << " slot=" << i
                  << " pc=0x" << std::hex << pc
                  << " inst=0x" << inst
                  << " we=" << std::dec << static_cast<uint32_t>(we)
                  << " rd=x" << static_cast<uint32_t>(rd)
                  << " wdata=0x" << std::hex << data
                  << " ra=0x" << rf[1]
                  << " sp=0x" << rf[2]
                  << " gp=0x" << rf[3]
                  << " a0=0x" << rf[10]
                  << " a1=0x" << rf[11]
                  << " a2=0x" << rf[12]
                  << " a3=0x" << rf[13]
                  << " s0=0x" << rf[8]
                  << " s1=0x" << rf[9]
                  << " satp=0x" << top->dbg_csr_satp_o
                  << " sepc=0x" << top->dbg_csr_sepc_o
                  << " scause=0x" << top->dbg_csr_scause_o
                  << " stval=0x" << top->dbg_csr_stval_o
                  << std::dec
                  << " priv=" << static_cast<int>(top->dbg_csr_priv_mode_o)
                  << " flush=" << static_cast<int>(top->backend_flush_o)
                  << "\n";
        std::cout.flags(f);
        linux_exc_pair_step_logs++;
      }
      if (args.linux_early_debug) {
        bool in_reloc = (pc >= kLinuxRelocPcBegin && pc < kLinuxRelocPcEnd);
        bool in_fsctx = (pc >= kLinuxFsctxPcBegin && pc < kLinuxFsctxPcEnd);
        bool can_log_reloc = in_reloc && (linux_reloc_step_logs < kLinuxRelocStepLogLimit);
        bool can_log_fsctx = in_fsctx && (linux_fsctx_step_logs < kLinuxFsctxStepLogLimit);
        if (can_log_reloc || can_log_fsctx) {
          std::ios::fmtflags f(std::cout.flags());
          std::cout << "[debug][linux-step] cycle=" << cycles
                    << " tag=" << (in_reloc ? "reloc" : "fsctx")
                    << " slot=" << i
                    << " pc=0x" << std::hex << pc
                    << " inst=0x" << inst
                    << " ra=0x" << rf[1]
                    << " sp=0x" << rf[2]
                    << " gp=0x" << rf[3]
                    << " a0=0x" << rf[10]
                    << " a1=0x" << rf[11]
                    << " satp=0x" << top->dbg_csr_satp_o
                    << " stvec=0x" << top->dbg_csr_stvec_o
                    << " sepc=0x" << top->dbg_csr_sepc_o
                    << " scause=0x" << top->dbg_csr_scause_o
                    << " stval=0x" << top->dbg_csr_stval_o
                    << " mstatus=0x" << top->dbg_csr_mstatus_o
                    << " mepc=0x" << top->dbg_csr_mepc_o
                    << " mcause=0x" << top->dbg_csr_mcause_o
                    << " backend_rdir=0x" << top->backend_redirect_pc_o
                    << " retire_rdir=0x" << top->dbg_retire_redirect_pc_o
                    << std::dec
                    << " priv=" << static_cast<int>(top->dbg_csr_priv_mode_o)
                    << " flush=" << static_cast<int>(top->backend_flush_o)
                    << "\n";
          std::cout.flags(f);
          if (in_reloc) linux_reloc_step_logs++;
          if (in_fsctx) linux_fsctx_step_logs++;
        }
        bool in_cgroup = (pc >= kLinuxCgroupPcBegin && pc < kLinuxCgroupPcEnd);
        bool in_bitops = (pc >= kLinuxBitopsPcBegin && pc < kLinuxBitopsPcEnd);
        bool can_log_cgroup = in_cgroup && (linux_cgroup_step_logs < kLinuxCgroupStepLogLimit);
        bool can_log_bitops = in_bitops && (linux_bitops_step_logs < kLinuxBitopsStepLogLimit);
        if (can_log_cgroup || can_log_bitops) {
          std::ios::fmtflags f(std::cout.flags());
          std::cout << "[debug][linux-hotstep] cycle=" << cycles
                    << " tag=" << (in_cgroup ? "cgroup-init" : "bitops")
                    << " slot=" << i
                    << " pc=0x" << std::hex << pc
                    << " inst=0x" << inst
                    << " we=" << std::dec << static_cast<uint32_t>(we)
                    << " rd=x" << static_cast<uint32_t>(rd)
                    << " wdata=0x" << std::hex << data
                    << " a0=0x" << rf[10]
                    << " a1=0x" << rf[11]
                    << " a2=0x" << rf[12]
                    << " a3=0x" << rf[13]
                    << " a4=0x" << rf[14]
                    << " a5=0x" << rf[15]
                    << " s0=0x" << rf[8]
                    << " s1=0x" << rf[9]
                    << " s2=0x" << rf[18]
                    << " s3=0x" << rf[19]
                    << " satp=0x" << top->dbg_csr_satp_o
                    << " scause=0x" << top->dbg_csr_scause_o
                    << " stval=0x" << top->dbg_csr_stval_o
                    << std::dec
                    << " priv=" << static_cast<int>(top->dbg_csr_priv_mode_o)
                    << " flush=" << static_cast<int>(top->backend_flush_o)
                    << "\n";
          std::cout.flags(f);
          if (in_cgroup) linux_cgroup_step_logs++;
          if (in_bitops) linux_bitops_step_logs++;
        }
      }
      if (commit_trace_active(cycles)) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[commit] cycle=" << cycles
                  << " slot=" << i
                  << " pc=0x" << std::hex << pc
                  << " inst=0x" << inst
                  << " decoded=0x" << decoded_inst
                  << " rvc=" << std::dec << static_cast<int>(is_rvc)
                  << " we=" << std::dec << we
                  << " rd=x" << rd
                  << " data=0x" << std::hex << data
                  << " a0=0x" << rf[10]
                  << std::dec << "\n";
        std::cout.flags(f);
      }
      if (!difftest.step_and_check(cycles, pc, decoded_inst, rf_before, rf)) {
        std::cerr << "[difftest] stop on first mismatch\n";
        profile.emit_summary(cycles, top);
        if (tfp) tfp->close();
        delete top;
        return 1;
      }
      if ((npc::is_ebreak_insn_word(inst, pc) ||
           (is_rvc && decoded_inst == npc::kEbreakInsn)) &&
          !args.boot_handoff) {
        uint32_t code = rf[10];
        if (code == 0) {
          std::cout << "HIT GOOD TRAP\n";
          double ipc = cycles ? static_cast<double>(profile.total_commits()) / static_cast<double>(cycles) : 0.0;
          double cpi = profile.total_commits() ? static_cast<double>(cycles) / static_cast<double>(profile.total_commits()) : 0.0;
          std::cout << "IPC=" << ipc << " CPI=" << cpi
                    << " cycles=" << cycles
                    << " commits=" << profile.total_commits() << "\n";
          profile.emit_summary(cycles, top);
          if (tfp) tfp->close();
          delete top;
          return 0;
        }
        std::cout << "HIT BAD TRAP (code=" << code << ")\n";
        profile.emit_summary(cycles, top);
        if (tfp) tfp->close();
        delete top;
        return 1;
      }
      last_commit_pc_seen = pc;
    }

    profile.record_commit_width(commit_this_cycle);

    if (commit_this_cycle != 0) {
      profile.on_commit_cycle(cycles);
      if (difftest.enabled()) {
        npc::DUTCSRState dut_csr = {};
        dut_csr.mtvec = top->dbg_csr_mtvec_o;
        dut_csr.mepc = top->dbg_csr_mepc_o;
        dut_csr.mstatus = top->dbg_csr_mstatus_o;
        dut_csr.mcause = top->dbg_csr_mcause_o;
        if (!difftest.check_arch_state(cycles, rf, dut_csr)) {
          std::cerr << "[difftest] stop on arch-state mismatch\n";
          profile.emit_summary(cycles, top);
          if (tfp) tfp->close();
          delete top;
          return 1;
        }
      }
      no_commit_cycles = 0;
    } else {
      no_commit_cycles++;
      profile.on_no_commit_cycle(cycles, no_commit_cycles, top);
    }

    if (args.progress_interval > 0 && cycles != 0 &&
        (cycles % args.progress_interval == 0)) {
      const uint32_t last_pc = profile.last_commit_pc();
      std::ios::fmtflags f(std::cout.flags());
      const double ipc = cycles ? static_cast<double>(profile.total_commits()) /
                                      static_cast<double>(cycles)
                                : 0.0;
      if (!args.progress_verbose && !args.linux_early_debug) {
        std::cout << "[progress] cycle=" << cycles
                  << " commits=" << profile.total_commits()
                  << " ipc=" << ipc
                  << " no_commit=" << no_commit_cycles
                  << " last_pc=0x" << std::hex << last_pc
                  << " last_inst=0x" << profile.last_commit_inst()
                  << " last_rvc=" << std::dec
                  << static_cast<int>(profile.last_commit_is_rvc())
                  << "\n";
      } else {
        std::cout << "[progress] cycle=" << cycles
                << " commits=" << profile.total_commits()
                << " no_commit=" << no_commit_cycles
                << " last_pc=0x" << std::hex << last_pc
                << " last_inst=0x" << profile.last_commit_inst()
                << " last_decoded=0x" << profile.last_commit_decoded_inst()
                << " last_rvc=" << std::dec << static_cast<int>(profile.last_commit_is_rvc())
                << std::hex
                << " a0=0x" << rf[10]
                << " rob_head(pc/comp/is_store/fu)=0x" << top->dbg_rob_head_pc_o
                << "/" << std::dec
                << static_cast<int>(top->dbg_rob_head_complete_o) << "/"
                << static_cast<int>(top->dbg_rob_head_is_store_o) << "/0x"
                << std::hex << static_cast<uint32_t>(top->dbg_rob_head_fu_o)
                << " rob_cnt=" << std::dec
                << static_cast<uint32_t>(top->dbg_rob_count_o)
                << " rob_ptr(h/t)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_rob_head_ptr_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_rob_tail_ptr_o)
                << std::dec
                << " rob_q2(v/idx/fu/comp/st/pc)=" << std::dec
                << static_cast<int>(top->dbg_rob_q2_valid_o) << "/0x"
                << std::hex << static_cast<uint32_t>(top->dbg_rob_q2_idx_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_rob_q2_fu_o)
                << std::dec << "/" << static_cast<int>(top->dbg_rob_q2_complete_o)
                << "/" << static_cast<int>(top->dbg_rob_q2_is_store_o)
                << "/0x" << std::hex << static_cast<uint32_t>(top->dbg_rob_q2_pc_o)
                << " sb(cnt/h/t)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_sb_count_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_sb_head_ptr_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_sb_tail_ptr_o)
                << " sb_head(v/c/a/d/addr)=" << std::dec
                << static_cast<int>(top->dbg_sb_head_valid_o) << "/"
                << static_cast<int>(top->dbg_sb_head_committed_o) << "/"
                << static_cast<int>(top->dbg_sb_head_addr_valid_o) << "/"
                << static_cast<int>(top->dbg_sb_head_data_valid_o) << "/0x"
                << std::hex << top->dbg_sb_head_addr_o
                << " sb_dcache(v/r/addr)= " << std::dec
                << static_cast<int>(top->dbg_sb_dcache_req_valid_o) << "/"
                << static_cast<int>(top->dbg_sb_dcache_req_ready_o) << "/0x"
                << std::hex << top->dbg_sb_dcache_req_addr_o
                << " dc_mshr(cnt/full/empty)=" << std::dec
                << static_cast<uint32_t>(top->dbg_dc_mshr_count_o) << "/"
                << static_cast<int>(top->dbg_dc_mshr_full_o) << "/"
                << static_cast<int>(top->dbg_dc_mshr_empty_o)
                << " dc_mshr(alloc_rdy/line_hit)="
                << static_cast<int>(top->dbg_dc_mshr_alloc_ready_o) << "/"
                << static_cast<int>(top->dbg_dc_mshr_req_line_hit_o)
                << " dc_store_wait(same/full)="
                << static_cast<int>(top->dbg_dc_store_wait_same_line_o) << "/"
                << static_cast<int>(top->dbg_dc_store_wait_mshr_full_o)
                << " lsu_issue(v/r)=" << std::dec
                << static_cast<int>(top->dbg_lsu_issue_valid_o) << "/"
                << static_cast<int>(top->dbg_lsu_req_ready_o)
                << " lsu_issue_ready=" << static_cast<int>(top->dbg_lsu_issue_ready_o)
                << " lsu_issue(raw/pick/blk)=("
                << static_cast<int>(top->dbg_lsu_issue_raw0_o) << ","
                << static_cast<int>(top->dbg_lsu_issue_raw1_o) << ")/("
                << static_cast<int>(top->dbg_lsu_issue_pick0_o) << ","
                << static_cast<int>(top->dbg_lsu_issue_pick1_o) << ")/("
                << static_cast<int>(top->dbg_lsu_issue_blk0_o) << ","
                << static_cast<int>(top->dbg_lsu_issue_blk1_o) << ")"
                << " lsu_sel(pc/ld/st/dst)=0x" << std::hex
                << top->dbg_lsu_sel_pc_o << std::dec << "/"
                << static_cast<int>(top->dbg_lsu_sel_is_load_o) << "/"
                << static_cast<int>(top->dbg_lsu_sel_is_store_o) << "/0x"
                << std::hex << static_cast<uint32_t>(top->dbg_lsu_sel_dst_o) << std::dec
                << " lsu_free=" << static_cast<uint32_t>(top->dbg_lsu_free_count_o)
                << " lsu_rs(b/r)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_lsu_rs_busy_o) << "/0x"
                << static_cast<uint32_t>(top->dbg_lsu_rs_ready_o)
                << " lsu_rs_head(v/idx/dst)=" << std::dec
                << static_cast<int>(top->dbg_lsu_rs_head_valid_o) << "/0x"
                << std::hex << static_cast<uint32_t>(top->dbg_lsu_rs_head_idx_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_lsu_rs_head_dst_o)
                << " lsu_rs_head(rs1r/rs2r/has1/has2)=" << std::dec
                << static_cast<int>(top->dbg_lsu_rs_head_r1_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_r2_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_has_rs1_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_has_rs2_o)
                << " lsu_rs_head(q1/q2/sb)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_lsu_rs_head_q1_o) << "/0x"
                << static_cast<uint32_t>(top->dbg_lsu_rs_head_q2_o) << "/0x"
                << static_cast<uint32_t>(top->dbg_lsu_rs_head_sb_id_o)
                << " lsu_rs_head(ld/st)=" << std::dec
                << static_cast<int>(top->dbg_lsu_rs_head_is_load_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_is_store_o)
                << " lsu_ld(v/r/rsp)="
                << static_cast<int>(top->dbg_lsu_ld_req_valid_o) << "/"
                << static_cast<int>(top->dbg_lsu_ld_req_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_ld_rsp_valid_o)
                << " lsu_grp(req(ld/st)/alloc(lq/sq)/pend/mmu/lq/sq)="
                << static_cast<int>(top->dbg_lsu_load_req_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_store_req_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_lq_alloc_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_sq_alloc_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_pend_valid_o) << "/"
                << static_cast<uint32_t>(top->dbg_lsu_mmu_state_o) << "/"
                << static_cast<uint32_t>(top->dbg_lsu_lq_count_o) << "/"
                << static_cast<uint32_t>(top->dbg_lsu_sq_count_o)
                << " flush=" << static_cast<int>(top->backend_flush_o)
                << " dc_miss(v/r)="
                << static_cast<int>(top->dcache_miss_req_valid_o) << "/"
                << static_cast<int>(top->dcache_miss_req_ready_i)
                << std::dec << "\n";
      if (last_pc >= 0x800408c0u && last_pc < 0x80040900u) {
        std::cout << "[progress][trap-debug] cycle=" << cycles
                  << " last_pc=0x" << std::hex << last_pc
                  << " priv=0x" << static_cast<uint32_t>(top->dbg_csr_priv_mode_o)
                  << " mtvec=0x" << top->dbg_csr_mtvec_o
                  << " mepc=0x" << top->dbg_csr_mepc_o
                  << " mstatus=0x" << top->dbg_csr_mstatus_o
                  << " mcause=0x" << top->dbg_csr_mcause_o
                  << std::dec << "\n";
      }
      if (last_pc >= 0x804410c0u && last_pc < 0x80441140u) {
        const bool pc_changed = (last_pc != last_linux_wait_pc);
        const bool periodic_log = (cycles - last_linux_wait_log_cycle >= 1000000ull);
        if (pc_changed || periodic_log) {
          std::cout << "[progress][linux-wait-debug] cycle=" << cycles
                    << " last_pc=0x" << std::hex << last_pc
                    << " last_inst=0x" << profile.last_commit_inst()
                    << " priv=0x" << static_cast<uint32_t>(top->dbg_csr_priv_mode_o)
                    << " stvec=0x" << top->dbg_csr_stvec_o
                    << " sepc=0x" << top->dbg_csr_sepc_o
                    << " scause=0x" << top->dbg_csr_scause_o
                    << " stval=0x" << top->dbg_csr_stval_o
                    << " sstatus=0x" << top->dbg_csr_sstatus_o
                    << " satp=0x" << top->dbg_csr_satp_o
                    << " mtvec=0x" << top->dbg_csr_mtvec_o
                    << " mepc=0x" << top->dbg_csr_mepc_o
                    << " mstatus=0x" << top->dbg_csr_mstatus_o
                    << " mcause=0x" << top->dbg_csr_mcause_o
                    << std::dec << "\n";
          last_linux_wait_pc = last_pc;
          last_linux_wait_log_cycle = cycles;
        }
      }
      // #region agent log
      if (args.linux_early_debug && agent_priv_fault_logs < kAgentPrivFaultLogLimit &&
          top->dbg_csr_priv_mode_o == 1 && top->dbg_csr_scause_o == 12 &&
          top->dbg_csr_trap_tval_o >= 0x90000000u && top->dbg_csr_trap_tval_o < 0xc0000000u) {
        const uint32_t fault_va = top->dbg_csr_trap_tval_o;
        const uint32_t satp = top->dbg_csr_satp_o;
        const uint32_t root_base = (satp & 0x003fffffu) << 12;
        const uint32_t vpn1 = fault_va >> 22;
        const uint32_t vpn0 = (fault_va >> 12) & 0x3ffu;
        const uint32_t l1_addr = root_base + (vpn1 << 2);
        const uint32_t l1_pte = mem.mem.read_word(l1_addr);
        const bool l1_valid = (l1_pte & 0x1u) != 0u && !((l1_pte & 0x4u) && !(l1_pte & 0x2u));
        const bool l1_leaf = (l1_pte & 0xau) != 0u;
        uint32_t l0_addr = 0;
        uint32_t l0_pte = 0;
        if (l1_valid && !l1_leaf) {
          l0_addr = ((l1_pte >> 10) << 12) + (vpn0 << 2);
          l0_pte = mem.mem.read_word(l0_addr);
        }
        std::ofstream("debug-fd94f9.log", std::ios::app)
            << "{\"sessionId\":\"fd94f9\",\"runId\":\"priv-mismatch\",\"hypothesisId\":\"H1-H3\","
            << "\"location\":\"npc/csrc/npc_main.cpp:agent_priv_fault\","
            << "\"message\":\"S-mode instruction page fault on user virtual page\","
            << "\"timestamp\":" << cycles
            << ",\"data\":{\"cycle\":" << cycles
            << ",\"lastPc\":\"0x" << std::hex << last_pc
            << "\",\"faultVa\":\"0x" << fault_va
            << "\",\"satp\":\"0x" << satp
            << "\",\"mstatus\":\"0x" << top->dbg_csr_mstatus_o
            << "\",\"sepc\":\"0x" << top->dbg_csr_sepc_o
            << "\",\"stval\":\"0x" << top->dbg_csr_stval_o
            << "\",\"scause\":\"0x" << top->dbg_csr_scause_o
            << "\",\"l1Pte\":\"0x" << l1_pte
            << "\",\"l0Pte\":\"0x" << l0_pte
            << "\",\"l0User\":" << std::dec << static_cast<int>((l0_pte & 0x10u) != 0u)
            << ",\"l0Exec\":" << static_cast<int>((l0_pte & 0x8u) != 0u)
            << "}}\n";
        agent_priv_fault_logs++;
      }
      // #endregion
      if (args.linux_early_debug && last_pc >= 0x810042f2u && last_pc < 0x81004460u) {
        std::cout << "[debug][setup-vm] cycle=" << cycles
                  << " last_pc=0x" << std::hex << last_pc
                  << " last_inst=0x" << profile.last_commit_inst()
                  << " a0=0x" << rf[10]
                  << " a1=0x" << rf[11]
                  << " s2=0x" << rf[18]
                  << " s3=0x" << rf[19]
                  << " satp=0x" << top->dbg_csr_satp_o
                  << " stvec=0x" << top->dbg_csr_stvec_o
                  << " sepc=0x" << top->dbg_csr_sepc_o
                  << " scause=0x" << top->dbg_csr_scause_o
                  << " stval=0x" << top->dbg_csr_stval_o
                  << " mtvec=0x" << top->dbg_csr_mtvec_o
                  << " mepc=0x" << top->dbg_csr_mepc_o
                  << " mcause=0x" << top->dbg_csr_mcause_o
                  << " priv=0x" << static_cast<uint32_t>(top->dbg_csr_priv_mode_o)
                  << std::dec << "\n";
      }
      if (args.linux_early_debug) {
        uint64_t uart_total = mem.mem.uart_tx_bytes;
        uint64_t uart_delta = uart_total - last_uart_tx_bytes;
        uint64_t fw_writes = mem.mem.fw_text_write_count;
        uint64_t fw_delta = fw_writes - last_fw_text_write_count;
        std::cout << "[debug][uart] cycle=" << cycles
                  << " tx_total=" << uart_total
                  << " tx_delta=" << uart_delta
                  << " lcr=0x" << std::hex << static_cast<uint32_t>(mem.mem.uart_lcr)
                  << " ier=0x" << static_cast<uint32_t>(mem.mem.uart_ier)
                  << " lsr=0x" << static_cast<uint32_t>(mem.mem.uart_lsr)
                  << " last=0x" << static_cast<uint32_t>(mem.mem.uart_last_tx)
                  << " fw_writes=" << std::dec << fw_writes
                  << " fw_delta=" << fw_delta
                  << " fw_last_addr=0x" << std::hex << mem.mem.fw_text_last_write_addr
                  << " fw_last_data=0x" << mem.mem.fw_text_last_write_data
                  << " fw_word_0x80400800=0x" << mem.mem.read_word(0x80400800u)
                  << " fw_word_0x80400094=0x" << mem.mem.read_word(0x80400094u)
                  << std::dec << "\n";
        last_uart_tx_bytes = uart_total;
        last_fw_text_write_count = fw_writes;
      }
      }
      std::cout.flags(f);
    }

    if (args.fe_trace && top->dbg_fe_valid_o && top->dbg_fe_ready_o) {
      uint32_t base_pc = top->dbg_fe_pc_o;
      uint32_t mismatch_mask = 0;
      std::vector<uint32_t> fe_instrs(cfg_instr_per_fetch, 0);
      std::vector<uint32_t> mem_instrs(cfg_instr_per_fetch, 0);
      uint32_t slot_valid = static_cast<uint32_t>(top->dbg_fe_slot_valid_o) & cfg_instr_mask;
      for (uint32_t i = 0; i < cfg_instr_per_fetch; i++) {
        fe_instrs[i] = top->dbg_fe_instrs_o[i];
        mem_instrs[i] = mem.mem.read_word(base_pc + static_cast<uint32_t>(i * 4));
        if (fe_instrs[i] != mem_instrs[i]) {
          mismatch_mask |= (1u << i);
        }
      }
      if (mismatch_mask != 0 || slot_valid != cfg_instr_mask) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[fe   ] cycle=" << cycles
                  << " pc=0x" << std::hex << base_pc
                  << " slot_valid=0x" << slot_valid
                  << " mismatch=0x" << mismatch_mask
                  << " pred={";
        for (uint32_t i = 0; i < cfg_instr_per_fetch; i++) {
          if (i) std::cout << ",";
          std::cout << "0x" << static_cast<uint32_t>(top->dbg_fe_pred_npc_o[i]);
        }
        std::cout << "}"
                  << " fe={";
        for (uint32_t i = 0; i < cfg_instr_per_fetch; i++) {
          if (i) std::cout << ",";
          std::cout << "0x" << fe_instrs[i];
        }
        std::cout << "} mem={";
        for (uint32_t i = 0; i < cfg_instr_per_fetch; i++) {
          if (i) std::cout << ",";
          std::cout << "0x" << mem_instrs[i];
        }
        std::cout << "}" << std::dec << "\n";
        std::cout.flags(f);
      }
    }
  }

  std::cerr << "TIMEOUT after " << args.max_cycles << " cycles\n";
  profile.emit_summary(args.max_cycles, top);
  if (tfp) tfp->close();
  delete top;
  return 1;
}
