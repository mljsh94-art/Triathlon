#include "Vtb_triathlon.h"
#include "args_parser.h"
#include "boot_loader.h"
#include "difftest_client.h"
#include "memory_models.h"
#include "profile_collector.h"
#include "sim_observer.h"
#include "sim_trap_exit.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <array>
#include <cstdint>
#include <iostream>

namespace {

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
              << " [--profile] [--profile-json <path>] [--bru-trace] [--fe-trace] [--stall-trace [N]] [--boot-handoff]"
              << " [--dtb <path>] [--firmware-load-base <addr>]"
              << " [--virtio-blk-image <path>]"
              << " [--progress [N]] [--progress-verbose] [--linux-early-debug]\n";
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
  }
  mem.mem.uart_stdout_enabled = !difftest.enabled();

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

  npc::reset(top, mem, tfp, sim_time);

  const uint32_t cfg_instr_per_fetch =
      probe_cfg_width(static_cast<uint32_t>(top->dbg_cfg_instr_per_fetch_o), 4u);
  const uint32_t cfg_commit_width =
      probe_cfg_width(static_cast<uint32_t>(top->dbg_cfg_nret_o), 4u);

  std::array<uint32_t, 32> rf{};
  uint64_t no_commit_cycles = 0;
  npc::ProfileCollector profile(args, cfg_instr_per_fetch, cfg_commit_width);
  npc::SimObserver observer(args, cfg_instr_per_fetch, cfg_commit_width);
  observer.configure_mem_watch(mem, firmware_base, args.boot_handoff);

  for (uint64_t cycles = 0; cycles < args.max_cycles; cycles++) {
    mem.mem.set_time_us(cycles);
    npc::tick(top, mem, tfp, sim_time);
    profile.observe_cycle(top);

    observer.service_store_buffer(cycles, top, mem);
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

      observer.on_commit_slot(cycles, top, mem, rf, slot);
      profile.record_commit(slot.pc, slot.inst, slot.decoded_inst, slot.is_rvc);

      npc::DUTCoreState dut_after =
          collect_dut_arch_state(top, rf, commit_next_pc(slot, slot.actual_npc));
      if (!difftest.step_and_check(cycles, slot.pc, slot.decoded_inst, dut_after,
                                   slot.rf_before, rf)) {
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
  }

  std::cerr << "TIMEOUT after " << args.max_cycles << " cycles\n";
  profile.emit_all_summaries(args.max_cycles, top);
  if (tfp) {
    tfp->close();
  }
  delete top;
  return 1;
}
