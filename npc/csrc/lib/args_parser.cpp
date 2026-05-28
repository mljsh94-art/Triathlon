#include "args_parser.h"

namespace npc {

namespace {

bool parse_u64(const std::string &s, uint64_t &out) {
  try {
    size_t idx = 0;
    out = std::stoull(s, &idx, 0);
    return idx == s.size();
  } catch (...) {
    return false;
  }
}

bool parse_commit_trace_range(const std::string &spec, uint64_t &start, uint64_t &end) {
  const size_t colon = spec.find(':');
  if (colon == std::string::npos) {
    uint64_t v = 0;
    if (!parse_u64(spec, v)) return false;
    start = v;
    end = v;
    return true;
  }
  if (colon == 0 || colon + 1 >= spec.size()) return false;
  uint64_t lo = 0;
  uint64_t hi = 0;
  if (!parse_u64(spec.substr(0, colon), lo)) return false;
  if (!parse_u64(spec.substr(colon + 1), hi)) return false;
  if (lo > hi) return false;
  start = lo;
  end = hi;
  return true;
}

}  // namespace

SimArgs parse_args(int argc, char **argv) {
  SimArgs args;
  for (int i = 1; i < argc; i++) {
    std::string arg = argv[i];

    if (arg == "-d") {
      if (i + 1 < argc) {
        args.difftest_so = argv[i + 1];
        i++;
      }
      continue;
    }
    if (arg == "--boot-handoff") {
      args.boot_handoff = true;
      continue;
    }
    if (arg == "--dtb" && i + 1 < argc) {
      args.dtb_path = argv[i + 1];
      i++;
      continue;
    }
    if (arg.rfind("--dtb=", 0) == 0) {
      args.dtb_path = arg.substr(std::string("--dtb=").size());
      continue;
    }
    if (arg == "--firmware-load-base" && i + 1 < argc) {
      uint64_t v = 0;
      if (parse_u64(argv[i + 1], v)) {
        args.firmware_load_base = v;
        i++;
        continue;
      }
    }
    if (arg.rfind("--firmware-load-base=", 0) == 0) {
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--firmware-load-base=").size()), v)) {
        args.firmware_load_base = v;
      }
      continue;
    }
    if (arg == "--virtio-blk-image" && i + 1 < argc) {
      args.virtio_blk_image = argv[i + 1];
      i++;
      continue;
    }
    if (arg.rfind("--virtio-blk-image=", 0) == 0) {
      args.virtio_blk_image = arg.substr(std::string("--virtio-blk-image=").size());
      continue;
    }
    if (arg.rfind("--difftest=", 0) == 0) {
      args.difftest_so = arg.substr(std::string("--difftest=").size());
      continue;
    }
    if (arg == "--max-cycles" && i + 1 < argc) {
      uint64_t v = 0;
      if (parse_u64(argv[i + 1], v)) {
        args.max_cycles = v;
        i++;
        continue;
      }
    }
    if (arg.rfind("--max-cycles=", 0) == 0) {
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--max-cycles=").size()), v)) {
        args.max_cycles = v;
      }
      continue;
    }
    if (arg == "--trace") {
      args.trace = true;
      if (i + 1 < argc && argv[i + 1][0] != '-') {
        args.trace_path = argv[i + 1];
        i++;
      }
      continue;
    }
    if (arg.rfind("--trace=", 0) == 0) {
      args.trace = true;
      args.trace_path = arg.substr(std::string("--trace=").size());
      continue;
    }
    if (arg == "--commit-trace") {
      args.commit_trace = true;
      if (i + 1 < argc && argv[i + 1][0] != '-') {
        uint64_t start = 0;
        uint64_t end = 0;
        if (parse_commit_trace_range(argv[i + 1], start, end)) {
          args.commit_trace_start = start;
          args.commit_trace_end = end;
          i++;
          continue;
        }
        uint64_t only_start = 0;
        if (parse_u64(argv[i + 1], only_start)) {
          args.commit_trace_start = only_start;
          if (i + 2 < argc && parse_u64(argv[i + 2], end)) {
            args.commit_trace_end = end;
            i += 2;
          } else {
            i++;
          }
        }
      }
      continue;
    }
    if (arg.rfind("--commit-trace=", 0) == 0) {
      uint64_t start = 0;
      uint64_t end = 0;
      if (parse_commit_trace_range(arg.substr(std::string("--commit-trace=").size()), start, end)) {
        args.commit_trace = true;
        args.commit_trace_start = start;
        args.commit_trace_end = end;
      }
      continue;
    }
    if (arg == "--commit-trace-start" && i + 1 < argc) {
      uint64_t v = 0;
      if (parse_u64(argv[i + 1], v)) {
        args.commit_trace = true;
        args.commit_trace_start = v;
        i++;
      }
      continue;
    }
    if (arg.rfind("--commit-trace-start=", 0) == 0) {
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--commit-trace-start=").size()), v)) {
        args.commit_trace = true;
        args.commit_trace_start = v;
      }
      continue;
    }
    if (arg == "--commit-trace-end" && i + 1 < argc) {
      uint64_t v = 0;
      if (parse_u64(argv[i + 1], v)) {
        args.commit_trace = true;
        args.commit_trace_end = v;
        i++;
      }
      continue;
    }
    if (arg.rfind("--commit-trace-end=", 0) == 0) {
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--commit-trace-end=").size()), v)) {
        args.commit_trace = true;
        args.commit_trace_end = v;
      }
      continue;
    }
    if (arg == "--fe-trace") {
      args.fe_trace = true;
      continue;
    }
    if (arg == "--bru-trace") {
      args.bru_trace = true;
      continue;
    }
    if (arg == "--stall-trace") {
      args.stall_trace = true;
      if (i + 1 < argc) {
        uint64_t v = 0;
        if (parse_u64(argv[i + 1], v)) {
          args.stall_threshold = v;
          i++;
        }
      }
      continue;
    }
    if (arg.rfind("--stall-trace=", 0) == 0) {
      args.stall_trace = true;
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--stall-trace=").size()), v)) {
        args.stall_threshold = v;
      }
      continue;
    }
    if (arg == "--progress") {
      args.progress_interval = 1000000;
      if (i + 1 < argc && argv[i + 1][0] != '-') {
        uint64_t v = 0;
        if (parse_u64(argv[i + 1], v)) {
          args.progress_interval = v;
          i++;
        }
      }
      continue;
    }
    if (arg.rfind("--progress=", 0) == 0) {
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--progress=").size()), v)) {
        args.progress_interval = v;
      }
      continue;
    }
    if (arg == "--progress-verbose") {
      args.progress_verbose = true;
      continue;
    }
    if (arg == "--linux-early-debug") {
      args.linux_early_debug = true;
      continue;
    }
    if (!arg.empty() && arg[0] == '-') {
      continue;
    }
    args.img_path = arg;
  }
  return args;
}

}  // namespace npc
