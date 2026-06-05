#pragma once

#include <cstdint>
#include <string>

namespace npc {

struct SimArgs {
  std::string img_path;
  uint64_t max_cycles = 600000000;
  std::string difftest_so;
  bool boot_handoff = false;
  std::string dtb_path;
  uint64_t firmware_load_base = 0;
  std::string virtio_blk_image;
  bool trace = false;
  std::string trace_path = "npc.vcd";
  bool commit_trace = false;
  uint64_t commit_trace_start = 0;
  uint64_t commit_trace_end = 0;  // 0 = no upper bound (until max_cycles)
  bool profile = false;
  std::string profile_json_path;
  bool fe_trace = false;
  bool bru_trace = false;
  bool stall_trace = false;
  uint64_t stall_threshold = 200;
  uint64_t progress_interval = 0;
  bool progress_verbose = false;
  bool linux_early_debug = false;
};

SimArgs parse_args(int argc, char **argv);

}  // namespace npc
