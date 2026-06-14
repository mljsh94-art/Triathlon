#pragma once

#include "args_parser.h"
#include "difftest_arch.h"
#include "memory_models.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

class Vtb_triathlon;

namespace npc {

class Difftest;

struct SnapshotMeta {
  std::string img_path;
  std::string img_hash;
  std::string dtb_path;
  std::string virtio_blk_image;
  bool boot_handoff = false;
  uint32_t entry_pc = 0;
  uint32_t firmware_base = 0;
  bool difftest_enabled = false;
};

struct SimSnapshot {
  uint64_t cycle = 0;
  uint64_t sim_time = 0;
  uint64_t no_commit_cycles = 0;
  std::array<uint32_t, 32> rf{};
  SnapshotMeta meta;
  MemSystem mem;
  DUTCoreState ref_state = {};
  std::vector<uint8_t> ref_pmem;
  std::vector<uint8_t> dut_blob;
};

SnapshotMeta make_snapshot_meta(const SimArgs &args, uint32_t entry_pc,
                                uint32_t firmware_base, bool difftest_enabled);
bool snapshot_meta_matches(const SnapshotMeta &saved, const SnapshotMeta &current,
                           std::string &reason);

bool capture_snapshot(const std::string &path, Vtb_triathlon *top, MemSystem &mem,
                      Difftest &difftest, const SnapshotMeta &meta,
                      const std::array<uint32_t, 32> &rf, uint64_t cycle,
                      uint64_t sim_time, uint64_t no_commit_cycles);

bool restore_snapshot(const std::string &path, Vtb_triathlon *top, MemSystem &mem,
                      Difftest &difftest, const SnapshotMeta &expected_meta,
                      std::array<uint32_t, 32> &rf, uint64_t &cycle_out,
                      uint64_t &sim_time_out, uint64_t &no_commit_cycles_out);

std::string snapshot_path_for_cycle(const std::string &dir, uint64_t cycle);
void rotate_snapshots(const std::string &dir, uint64_t keep);
std::string nearest_snapshot_before_or_at(const std::string &dir, uint64_t cycle,
                                          uint64_t *snapshot_cycle_out = nullptr);

}  // namespace npc
