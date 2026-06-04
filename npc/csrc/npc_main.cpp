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

}  // namespace

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
      if (tfp) {
        tfp->close();
      }
      delete top;
      return 1;
    }
  }
  mem.mem.uart_stdout_enabled = !difftest.enabled();

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

      observer.on_commit_slot(cycles, top, mem, rf, slot);
      profile.record_commit(slot.pc, slot.inst, slot.decoded_inst, slot.is_rvc);

      if (!difftest.step_and_check(cycles, slot.pc, slot.decoded_inst, slot.rf_before, rf)) {
        std::cerr << "[difftest] stop on first mismatch\n";
        profile.emit_summary(cycles, top);
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
      if (difftest.enabled()) {
        npc::DUTCSRState dut_csr = {};
        dut_csr.mtvec = top->dbg_csr_mtvec_o;
        dut_csr.mepc = top->dbg_csr_mepc_o;
        dut_csr.mstatus = top->dbg_csr_mstatus_o;
        dut_csr.mcause = top->dbg_csr_mcause_o;
        if (!difftest.check_arch_state(cycles, rf, dut_csr)) {
          std::cerr << "[difftest] stop on arch-state mismatch\n";
          profile.emit_summary(cycles, top);
          if (tfp) {
            tfp->close();
          }
          delete top;
          return 1;
        }
      }
      no_commit_cycles = 0;
    } else {
      no_commit_cycles++;
      profile.on_no_commit_cycle(cycles, no_commit_cycles, top);
    }

    observer.end_of_cycle(cycles, top, mem, profile, rf, no_commit_cycles);
  }

  std::cerr << "TIMEOUT after " << args.max_cycles << " cycles\n";
  profile.emit_summary(args.max_cycles, top);
  if (tfp) {
    tfp->close();
  }
  delete top;
  return 1;
}
