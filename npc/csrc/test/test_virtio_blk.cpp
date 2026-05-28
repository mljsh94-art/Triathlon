#include "Vtb_virtio_blk.h"
#include "../include/memory_models.h"
#include "verilated.h"

#include <array>
#include <cassert>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>

namespace {

constexpr uint32_t kQueueNum = 8;
constexpr uint32_t kSectorBytes = 512;

constexpr uint32_t kDescBase = npc::kPmemBase + 0x4000u;
constexpr uint32_t kAvailBase = npc::kPmemBase + 0x5000u;
constexpr uint32_t kUsedBase = npc::kPmemBase + 0x6000u;
constexpr uint32_t kReqHdrBase = npc::kPmemBase + 0x7000u;
constexpr uint32_t kDataBase = npc::kPmemBase + 0x8000u;
constexpr uint32_t kStatusBase = npc::kPmemBase + 0x9000u;

constexpr uint32_t kVirtioMagicValue = 0x74726976u;

uint8_t read8(const npc::UnifiedMem &mem, uint32_t addr) {
  const uint32_t word = mem.read_word(addr & ~0x3u);
  return static_cast<uint8_t>((word >> ((addr & 0x3u) * 8u)) & 0xffu);
}

uint16_t read16(const npc::UnifiedMem &mem, uint32_t addr) {
  const uint32_t lo = static_cast<uint32_t>(read8(mem, addr));
  const uint32_t hi = static_cast<uint32_t>(read8(mem, addr + 1u));
  return static_cast<uint16_t>(lo | (hi << 8));
}

void write8(npc::UnifiedMem &mem, uint32_t addr, uint8_t value) {
  mem.write_store(addr, static_cast<uint32_t>(value), 7u);
}

void write16(npc::UnifiedMem &mem, uint32_t addr, uint16_t value) {
  mem.write_store(addr, static_cast<uint32_t>(value), 8u);
}

void write32(npc::UnifiedMem &mem, uint32_t addr, uint32_t value) {
  mem.write_word(addr, value);
}

void write64(npc::UnifiedMem &mem, uint32_t addr, uint64_t value) {
  write32(mem, addr, static_cast<uint32_t>(value & 0xffffffffu));
  write32(mem, addr + 4u, static_cast<uint32_t>((value >> 32) & 0xffffffffu));
}

std::string build_test_disk() {
  const std::string path = "/tmp/npc_virtio_blk_test.img";
  std::array<uint8_t, kSectorBytes * 2> data{};
  for (uint32_t i = 0; i < data.size(); i++) {
    data[i] = static_cast<uint8_t>((i * 7u + 3u) & 0xffu);
  }
  std::ofstream ofs(path, std::ios::binary | std::ios::trunc);
  ofs.write(reinterpret_cast<const char *>(data.data()),
            static_cast<std::streamsize>(data.size()));
  return path;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_virtio_blk top;
  top.eval();

  npc::UnifiedMem mem;
  const std::string disk = build_test_disk();
  assert(mem.load_virtio_blk_image(disk));

  const uint32_t base = npc::kVirtioBlkBase;

  assert(mem.read_word(base + 0x000u) == kVirtioMagicValue);
  assert(mem.read_word(base + 0x008u) == 2u);

  // Configure queue.
  write32(mem, base + 0x030u, 0u);          // QueueSel
  write32(mem, base + 0x038u, kQueueNum);   // QueueNum
  write32(mem, base + 0x080u, kDescBase);   // QueueDescLow
  write32(mem, base + 0x090u, kAvailBase);  // QueueAvailLow
  write32(mem, base + 0x0a0u, kUsedBase);   // QueueUsedLow
  write32(mem, base + 0x044u, 1u);          // QueueReady

  // Program descriptor chain: hdr -> data -> status
  write64(mem, kDescBase + 0u, kReqHdrBase);
  write32(mem, kDescBase + 8u, 16u);
  write16(mem, kDescBase + 12u, 1u);  // NEXT
  write16(mem, kDescBase + 14u, 1u);

  write64(mem, kDescBase + 16u, kDataBase);
  write32(mem, kDescBase + 24u, kSectorBytes);
  write16(mem, kDescBase + 28u, 3u);  // NEXT | WRITE
  write16(mem, kDescBase + 30u, 2u);

  write64(mem, kDescBase + 32u, kStatusBase);
  write32(mem, kDescBase + 40u, 1u);
  write16(mem, kDescBase + 44u, 2u);  // WRITE
  write16(mem, kDescBase + 46u, 0u);

  // virtio_blk_outhdr: type=IN(0), reserved=0, sector=1
  write32(mem, kReqHdrBase + 0u, 0u);
  write32(mem, kReqHdrBase + 4u, 0u);
  write64(mem, kReqHdrBase + 8u, 1u);

  write8(mem, kStatusBase, 0xffu);

  // avail ring: idx=1, ring[0]=head desc 0
  write16(mem, kAvailBase + 0u, 0u);
  write16(mem, kAvailBase + 2u, 1u);
  write16(mem, kAvailBase + 4u, 0u);
  write16(mem, kUsedBase + 2u, 0u);

  // Notify queue 0.
  write32(mem, base + 0x050u, 0u);

  for (uint32_t i = 0; i < kSectorBytes; i++) {
    uint8_t got = read8(mem, kDataBase + i);
    uint8_t exp = static_cast<uint8_t>(((kSectorBytes + i) * 7u + 3u) & 0xffu);
    assert(got == exp);
  }
  assert(read8(mem, kStatusBase) == 0u);

  assert(read16(mem, kUsedBase + 2u) == 1u);
  assert(mem.read_word(kUsedBase + 4u) == 0u);
  assert(mem.read_word(kUsedBase + 8u) == kSectorBytes);

  assert((mem.read_word(base + 0x060u) & 0x1u) != 0u);
  write32(mem, base + 0x064u, 0x1u);
  assert((mem.read_word(base + 0x060u) & 0x1u) == 0u);

  std::cout << "[PASS] test_virtio_blk\n";
  return 0;
}
