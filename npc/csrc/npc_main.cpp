#include "Vtb_triathlon.h"
#include "args_parser.h"
#include "boot_loader.h"
#include "difftest_client.h"
#include "memory_models.h"
#include "profile_collector.h"
#include "sim_observer.h"
#include "sim_snapshot.h"
#include "sim_trap_exit.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>

namespace {

constexpr uint32_t kAgentWatchPcStart = 0x00013fd0u;
constexpr uint32_t kAgentWatchPcEnd = 0x00014010u;

struct AgentSv32Walk {
  bool enabled = false;
  bool l1_read = false;
  bool l1_ok = false;
  bool l1_leaf = false;
  bool l0_read = false;
  bool l0_ok = false;
  bool l0_leaf = false;
  bool resolved = false;
  uint32_t l1_addr = 0;
  uint32_t l1_pte = 0;
  uint32_t l0_addr = 0;
  uint32_t l0_pte = 0;
  uint32_t pa = 0;
};

bool agent_pte_valid(uint32_t pte) {
  const bool v = (pte & 0x1u) != 0u;
  const bool r = (pte & 0x2u) != 0u;
  const bool w = (pte & 0x4u) != 0u;
  return v && !(w && !r);
}

bool agent_pte_leaf(uint32_t pte) { return (pte & 0xau) != 0u; }

AgentSv32Walk agent_sv32_translate(const npc::UnifiedMem &mem, uint32_t satp,
                                   uint32_t va) {
  AgentSv32Walk walk{};
  walk.enabled = (satp & 0x80000000u) != 0u;
  if (!walk.enabled) {
    walk.pa = va;
    walk.resolved = true;
    return walk;
  }

  const uint32_t root_base = (satp & 0x003fffffu) << 12;
  const uint32_t vpn1 = va >> 22;
  const uint32_t vpn0 = (va >> 12) & 0x3ffu;
  const uint32_t page_off = va & 0xfffu;
  walk.l1_addr = root_base + (vpn1 << 2);
  walk.l1_read = mem.read_phys_u32(walk.l1_addr, walk.l1_pte);
  walk.l1_ok = walk.l1_read && agent_pte_valid(walk.l1_pte);
  walk.l1_leaf = walk.l1_ok && agent_pte_leaf(walk.l1_pte);
  if (walk.l1_leaf) {
    const uint32_t ppn1 = (walk.l1_pte >> 20) & 0xfffu;
    walk.pa = (ppn1 << 22) | (vpn0 << 12) | page_off;
    walk.resolved = true;
    return walk;
  }
  if (!walk.l1_ok) return walk;

  const uint32_t l0_base = ((walk.l1_pte >> 10) & 0x003fffffu) << 12;
  walk.l0_addr = l0_base + (vpn0 << 2);
  walk.l0_read = mem.read_phys_u32(walk.l0_addr, walk.l0_pte);
  walk.l0_ok = walk.l0_read && agent_pte_valid(walk.l0_pte);
  walk.l0_leaf = walk.l0_ok && agent_pte_leaf(walk.l0_pte);
  if (walk.l0_leaf) {
    const uint32_t ppn = (walk.l0_pte >> 10) & 0x003fffffu;
    walk.pa = (ppn << 12) | page_off;
    walk.resolved = true;
  }
  return walk;
}

uint16_t agent_read_u16_if_resolved(const npc::UnifiedMem &mem,
                                    const AgentSv32Walk &walk) {
  uint16_t value = 0;
  if (!walk.resolved) return value;
  mem.read_phys_u16(walk.pa, value);
  return value;
}

bool read_retire_fetch_truth(Vtb_triathlon *top, npc::MemSystem &mem,
                             uint32_t pc, uint32_t &mem_raw) {
  const auto low_walk = agent_sv32_translate(mem.mem, top->dbg_csr_satp_o, pc);
  const auto high_walk = agent_sv32_translate(mem.mem, top->dbg_csr_satp_o, pc + 2u);
  if (!low_walk.resolved || !high_walk.resolved) return false;

  const uint16_t low_half = agent_read_u16_if_resolved(mem.mem, low_walk);
  const uint16_t high_half = agent_read_u16_if_resolved(mem.mem, high_walk);
  mem_raw = static_cast<uint32_t>(low_half) | (static_cast<uint32_t>(high_half) << 16);
  return true;
}

void agent_log_commit_fetch(uint64_t cycle, const npc::CommitSlot &slot,
                            Vtb_triathlon *top, npc::MemSystem &mem,
                            const std::array<uint32_t, 32> &rf) {
  if (slot.pc < kAgentWatchPcStart || slot.pc > kAgentWatchPcEnd) return;

  const auto low_walk = agent_sv32_translate(mem.mem, top->dbg_csr_satp_o, slot.pc);
  const auto high_walk = agent_sv32_translate(mem.mem, top->dbg_csr_satp_o, slot.pc + 2u);
  const uint16_t low_half = agent_read_u16_if_resolved(mem.mem, low_walk);
  const uint16_t high_half = agent_read_u16_if_resolved(mem.mem, high_walk);
  const uint32_t mem_raw = static_cast<uint32_t>(low_half) |
                           (static_cast<uint32_t>(high_half) << 16);

  // #region agent log
  std::ofstream log("debug-702aba.log", std::ios::app);
  log << "{\"sessionId\":\"702aba\",\"runId\":\"difftest-cross-page\","
      << "\"hypothesisId\":\"H1-H2-H5\","
      << "\"location\":\"npc/csrc/npc_main.cpp:agent_log_commit_fetch\","
      << "\"message\":\"commit fetch truth near failing page boundary\","
      << "\"timestamp\":" << cycle << ",\"data\":{"
      << "\"cycle\":" << cycle
      << ",\"slot\":" << slot.slot
      << ",\"pc\":\"0x" << std::hex << slot.pc
      << "\",\"raw_inst\":\"0x" << slot.inst
      << "\",\"decoded_inst\":\"0x" << slot.decoded_inst
      << "\",\"actual_npc\":\"0x" << slot.actual_npc
      << "\",\"satp\":\"0x" << top->dbg_csr_satp_o
      << "\",\"pa_low\":\"0x" << low_walk.pa
      << "\",\"pa_high\":\"0x" << high_walk.pa
      << "\",\"l0_pte_low\":\"0x" << low_walk.l0_pte
      << "\",\"l0_pte_high\":\"0x" << high_walk.l0_pte
      << "\",\"mem_low16\":\"0x" << low_half
      << "\",\"mem_high16\":\"0x" << high_half
      << "\",\"mem_raw32\":\"0x" << mem_raw
      << "\",\"wdata\":\"0x" << slot.data
      << "\",\"rf_before_x15\":\"0x" << slot.rf_before[15]
      << "\",\"rf_after_x15\":\"0x" << rf[15]
      << std::dec
      << "\",\"we\":" << (slot.we ? 1 : 0)
      << ",\"rd\":" << slot.rd
      << ",\"is_rvc\":" << (slot.is_rvc ? 1 : 0)
      << ",\"priv\":" << static_cast<uint32_t>(top->dbg_csr_priv_mode_o)
      << ",\"low_resolved\":" << (low_walk.resolved ? 1 : 0)
      << ",\"high_resolved\":" << (high_walk.resolved ? 1 : 0)
      << "}}\n";
  // #endregion
}

uint32_t probe_cfg_width(uint32_t value, uint32_t fallback) {
  if (value == 0u || value > 32u) {
    return fallback;
  }
  return value;
}

uint32_t commit_next_pc(const npc::CommitSlot &slot, uint32_t actual_npc) {
  if (actual_npc != 0u) {
    return actual_npc;
  }
  return slot.pc + (slot.is_rvc ? 2u : 4u);
}

npc::DUTCoreState collect_dut_arch_state(Vtb_triathlon *top,
                                         const std::array<uint32_t, 32> &rf,
                                         uint32_t pc_after) {
  npc::DUTCoreState state = {};
  for (size_t i = 0; i < rf.size(); i++) {
    state.gpr[i] = rf[i];
  }
  state.gpr[0] = 0;
  state.pc = pc_after;
  state.priv = top->dbg_csr_priv_mode_o;
  state.mstatus = top->dbg_csr_mstatus_o;
  state.sstatus = top->dbg_csr_sstatus_o;
  state.mepc = top->dbg_csr_mepc_o;
  state.sepc = top->dbg_csr_sepc_o;
  state.mcause = top->dbg_csr_mcause_o;
  state.scause = top->dbg_csr_scause_o;
  state.mtval = top->dbg_csr_mtval_o;
  state.stval = top->dbg_csr_stval_o;
  state.mtvec = top->dbg_csr_mtvec_o;
  state.stvec = top->dbg_csr_stvec_o;
  state.mscratch = top->dbg_csr_mscratch_o;
  state.sscratch = top->dbg_csr_sscratch_o;
  state.mie = top->dbg_csr_mie_o;
  state.mip = top->dbg_csr_mip_o;
  state.medeleg = top->dbg_csr_medeleg_o;
  state.mideleg = top->dbg_csr_mideleg_o;
  state.satp = top->dbg_csr_satp_o;
  return state;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  npc::SimArgs args = npc::parse_args(argc, argv);

  if (args.img_path.empty()) {
    std::cerr << "Usage: " << argv[0]
              << " <IMG> [--max-cycles N] [-d REF_SO] [--trace [vcd]] [--commit-trace [START[:END]|START [END]]]"
              << " [--commit-trace-start N] [--commit-trace-end N]"
              << " [--commit-ring N] [--profile] [--profile-json <path>] [--bru-trace] [--fe-trace] [--stall-trace [N]] [--boot-handoff]"
              << " [--dtb <path>] [--firmware-load-base <addr>]"
              << " [--virtio-blk-image <path>]"
              << " [--progress [N]] [--progress-verbose] [--linux-early-debug]"
              << " [--snapshot-interval N] [--snapshot-dir PATH] [--snapshot-keep K]"
              << " [--snapshot-restore PATH]\n";
    return 1;
  }

  npc::MemSystem mem;
  uint32_t entry_pc = npc::kPmemBase;
  uint32_t firmware_base = npc::kOpenSbiLoadBase;
  if (args.boot_handoff) {
    firmware_base = (args.firmware_load_base != 0)
                        ? static_cast<uint32_t>(args.firmware_load_base)
                        : npc::kOpenSbiLoadBase;
    if (firmware_base == entry_pc) {
      std::cerr << "[boot] firmware-load-base overlaps reset trampoline at 0x"
                << std::hex << entry_pc << std::dec << "\n";
      return 1;
    }
    if ((firmware_base & 0x003fffffu) != 0u) {
      std::cerr << "[boot] firmware-load-base must be 4MiB aligned (use 0x80400000)\n";
      return 1;
    }
    if (!mem.mem.load_binary(args.img_path, firmware_base)) {
      return 1;
    }

    npc::BootHandoff handoff = npc::make_default_boot_handoff();
    if (!args.dtb_path.empty()) {
      if (!mem.mem.load_binary(args.dtb_path, handoff.dtb_addr)) {
        return 1;
      }
    } else {
      npc::install_minimal_dtb(mem.mem, handoff.dtb_addr);
    }
    npc::install_boot_handoff_stub(mem.mem, firmware_base, handoff, npc::kBootRomBase);
    npc::install_jump_stub(mem.mem, npc::kBootRomBase, entry_pc);
  } else if (!mem.mem.load_binary(args.img_path, npc::kPmemBase)) {
    return 1;
  }
  if (!args.virtio_blk_image.empty() && !mem.mem.load_virtio_blk_image(args.virtio_blk_image)) {
    return 1;
  }

  mem.icache.mem = &mem.mem;
  mem.dcache.mem = &mem.mem;
  mem.mmio.mem = &mem.mem;

  npc::Difftest difftest;
  if (!args.difftest_so.empty()) {
    if (!difftest.init(args.difftest_so, mem.mem.pmem_words, entry_pc)) {
      return 1;
    }
    if (!args.commit_ring_explicit) {
      args.commit_ring_size = 64;
    }
  }

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

  npc::SnapshotMeta snapshot_meta =
      npc::make_snapshot_meta(args, entry_pc, firmware_base, difftest.enabled());

  std::array<uint32_t, 32> rf{};
  uint64_t no_commit_cycles = 0;
  uint64_t start_cycle = 0;
  if (!args.snapshot_restore_path.empty()) {
    uint64_t restored_cycle = 0;
    if (!npc::restore_snapshot(args.snapshot_restore_path, top, mem, difftest,
                               snapshot_meta, rf, restored_cycle, sim_time,
                               no_commit_cycles)) {
      if (tfp) {
        tfp->close();
      }
      delete top;
      return 1;
    }
    start_cycle = restored_cycle + 1u;
  } else {
    npc::reset(top, mem, tfp, sim_time);
  }

  const uint32_t cfg_instr_per_fetch =
      probe_cfg_width(static_cast<uint32_t>(top->dbg_cfg_instr_per_fetch_o), 4u);
  const uint32_t cfg_commit_width =
      probe_cfg_width(static_cast<uint32_t>(top->dbg_cfg_nret_o), 4u);

  npc::ProfileCollector profile(args, cfg_instr_per_fetch, cfg_commit_width);
  npc::SimObserver observer(args, cfg_instr_per_fetch, cfg_commit_width);
  observer.configure_mem_watch(mem, firmware_base, args.boot_handoff);

  for (uint64_t cycles = start_cycle; cycles < args.max_cycles; cycles++) {
    mem.mem.set_time_us(cycles);
    npc::tick(top, mem, tfp, sim_time);
    profile.observe_cycle(top);

    observer.service_stq(cycles, top, mem);
    profile.record_flush(cycles, top, mem.mem);

    if (auto exit_code = npc::try_ebreak_on_exception_flush(args, top, mem.mem, rf, cycles,
                                                            profile)) {
      if (tfp) {
        tfp->close();
      }
      delete top;
      return *exit_code;
    }

    observer.after_flush(cycles, top, mem, rf);
    observer.after_bru_writeback(cycles, top);

    uint32_t commit_this_cycle = 0;
    for (uint32_t i = 0; i < cfg_commit_width; i++) {
      if (((top->commit_valid_o >> i) & 0x1) == 0) {
        continue;
      }
      commit_this_cycle++;

      npc::CommitSlot slot{};
      slot.slot = i;
      slot.rf_before = rf;
      slot.we = (top->commit_we_o >> i) & 0x1;
      slot.rd = (top->commit_areg_o >> (i * 5)) & 0x1F;
      slot.data = top->commit_wdata_o[i];
      if (slot.we && slot.rd != 0) {
        rf[slot.rd] = slot.data;
      }
      slot.pc = top->commit_pc_o[i];
      slot.inst = top->commit_inst_o[i];
      slot.decoded_inst = top->commit_decoded_inst_o[i];
      slot.is_rvc = ((top->commit_is_rvc_o >> i) & 0x1) != 0;
      slot.actual_npc = top->commit_actual_npc_o[i];

      npc::DifftestStoreCommit store_commit{};
      bool is_store_commit = ((top->commit_is_store_o >> i) & 0x1) != 0;
      bool store_data_valid = ((top->commit_store_valid_o >> i) & 0x1) != 0;
      if (is_store_commit && store_data_valid) {
        store_commit.valid = true;
        store_commit.addr = top->commit_store_addr_o[i];
        store_commit.data = top->commit_store_data_o[i];
        store_commit.op = (top->commit_store_op_o >> (i * 4)) & 0xfu;
      }
      uint32_t retire_mem_raw = 0;
      bool retire_fetch_override =
          read_retire_fetch_truth(top, mem, slot.pc, retire_mem_raw) &&
          !slot.is_rvc && (retire_mem_raw != slot.decoded_inst);
      bool trap_sync = top->dbg_csr_irq_trap_o != 0;

      observer.on_commit_slot(cycles, top, mem, rf, slot, store_commit.valid,
                              store_commit.addr, store_commit.data, store_commit.op,
                              trap_sync, retire_fetch_override);
      agent_log_commit_fetch(cycles, slot, top, mem, rf);
      profile.record_commit(slot.pc, slot.inst, slot.decoded_inst, slot.is_rvc);

      npc::DUTCoreState dut_after =
          collect_dut_arch_state(top, rf, commit_next_pc(slot, slot.actual_npc));
      if (!difftest.step_and_check(cycles, slot.pc, slot.decoded_inst, dut_after,
                                   slot.rf_before, rf, store_commit, trap_sync,
                                   retire_fetch_override)) {
        observer.dump_commit_ring(std::cerr);
        uint64_t snap_cycle = 0;
        std::string nearest =
            npc::nearest_snapshot_before_or_at(args.snapshot_dir, cycles, &snap_cycle);
        if (!nearest.empty()) {
          std::cerr << "[snapshot] nearest=" << nearest << " cycle=" << snap_cycle
                    << " (restore: --snapshot-restore=" << nearest << ")\n";
        }
        std::cerr << "[difftest] stop on first mismatch\n";
        profile.emit_all_summaries(cycles, top);
        if (tfp) {
          tfp->close();
        }
        delete top;
        return 1;
      }
      if (auto exit_code = npc::try_ebreak_on_commit(args, slot.inst, slot.pc, slot.decoded_inst,
                                                     slot.is_rvc, rf, cycles, profile, top)) {
        if (tfp) {
          tfp->close();
        }
        delete top;
        return *exit_code;
      }
    }

    profile.record_commit_width(commit_this_cycle);
    if (commit_this_cycle != 0) {
      profile.on_commit_cycle(cycles);
      no_commit_cycles = 0;
    } else {
      no_commit_cycles++;
      profile.on_no_commit_cycle(cycles, no_commit_cycles, top);
    }

    observer.end_of_cycle(cycles, top, mem, profile, rf, no_commit_cycles);
    if (args.snapshot_interval != 0 && cycles != 0 &&
        (cycles % args.snapshot_interval) == 0) {
      std::string path = npc::snapshot_path_for_cycle(args.snapshot_dir, cycles);
      if (!npc::capture_snapshot(path, top, mem, difftest, snapshot_meta, rf, cycles,
                                 sim_time, no_commit_cycles)) {
        if (tfp) {
          tfp->close();
        }
        delete top;
        return 1;
      }
      npc::rotate_snapshots(args.snapshot_dir, args.snapshot_keep);
    }
  }

  std::cerr << "TIMEOUT after " << args.max_cycles << " cycles\n";
  profile.emit_all_summaries(args.max_cycles, top);
  if (tfp) {
    tfp->close();
  }
  delete top;
  return 1;
}
