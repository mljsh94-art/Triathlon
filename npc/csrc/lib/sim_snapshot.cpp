#include "sim_snapshot.h"

#include "Vtb_triathlon.h"
#include "difftest_client.h"
#include "platform_contract.h"

#if NPC_SNAPSHOT
#include "verilated_save.h"
#endif

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>

namespace npc {
namespace {

constexpr char kMagic[8] = {'T', 'R', 'S', 'N', 'A', 'P', '1', '\0'};
constexpr uint32_t kVersion = 2;
constexpr uint32_t kBlobRaw = 0;

enum BlobId : uint32_t {
  kBlobMeta = 1,
  kBlobRf = 2,
  kBlobUnifiedFixed = 3,
  kBlobPmem = 4,
  kBlobBootrom = 5,
  kBlobVirtioImage = 6,
  kBlobICache = 7,
  kBlobDCache = 8,
  kBlobRefState = 9,
  kBlobRefPmem = 10,
  kBlobDut = 11,
};

struct FileHeader {
  char magic[8];
  uint32_t version;
  uint64_t cycle;
  uint64_t sim_time;
  uint64_t no_commit_cycles;
};

struct BlobHeader {
  uint32_t id;
  uint32_t codec;
  uint64_t raw_size;
  uint64_t stored_size;
};

struct UnifiedFixed {
  uint64_t rtc_time_us;
  uint64_t clint_mtime;
  uint64_t clint_mtimecmp;
  uint32_t plic_priority1;
  uint32_t plic_enable_m;
  uint32_t plic_threshold_m;
  uint8_t plic_source_pending1;
  uint8_t plic_pending1;
  uint8_t plic_claimed1;
  uint8_t virtio_blk_enabled_flag;
  uint32_t virtio_device_features_sel;
  uint32_t virtio_driver_features_sel;
  uint32_t virtio_driver_features_lo;
  uint32_t virtio_driver_features_hi;
  uint32_t virtio_queue_sel;
  uint32_t virtio_queue_num;
  uint32_t virtio_queue_ready;
  uint64_t virtio_queue_desc;
  uint64_t virtio_queue_avail;
  uint64_t virtio_queue_used;
  uint16_t virtio_last_avail_idx;
  uint8_t virtio_status;
  uint32_t virtio_interrupt_status;
  uint32_t virtio_config_generation;
  uint8_t uart_stdout_enabled;
  uint8_t uart_ier;
  uint8_t uart_fcr;
  uint8_t uart_lcr;
  uint8_t uart_mcr;
  uint8_t uart_lsr;
  uint8_t uart_msr;
  uint8_t uart_scr;
  uint8_t uart_dll;
  uint8_t uart_dlm;
  uint8_t uart_tx_irq_latched;
  uint8_t uart_tx_rearm_pending;
  uint64_t uart_tx_rearm_at;
  uint64_t uart_tx_bytes;
  uint8_t uart_last_tx;
  uint8_t fw_text_watch_enabled;
  uint32_t fw_text_watch_base;
  uint32_t fw_text_watch_limit;
  uint64_t fw_text_write_count;
  uint32_t fw_text_last_write_addr;
  uint32_t fw_text_last_write_data;
};

struct ICacheFixed {
  uint8_t pending;
  int32_t delay;
  uint32_t miss_addr;
  uint32_t miss_way;
  uint8_t refill_pulse;
  uint32_t line_words[8];
};

struct DCacheTxnFixed {
  int32_t delay;
  uint32_t miss_addr;
  uint32_t miss_way;
  uint32_t line_words[8];
};

struct DCacheFixed {
  uint8_t refill_pulse;
  DCacheTxnFixed refill_txn;
  uint64_t pending_count;
};

std::vector<uint8_t> bytes_from_object(const void *ptr, size_t size) {
  const auto *begin = static_cast<const uint8_t *>(ptr);
  return std::vector<uint8_t>(begin, begin + size);
}

template <typename T>
std::vector<uint8_t> bytes_from_vector(const std::vector<T> &vec) {
  const auto *begin = reinterpret_cast<const uint8_t *>(vec.data());
  return std::vector<uint8_t>(begin, begin + vec.size() * sizeof(T));
}

template <typename T>
void vector_from_bytes(const std::vector<uint8_t> &bytes, std::vector<T> &out,
                       const char *name) {
  if ((bytes.size() % sizeof(T)) != 0) {
    throw std::runtime_error(std::string("bad vector blob size for ") + name);
  }
  out.resize(bytes.size() / sizeof(T));
  if (!bytes.empty()) {
    std::memcpy(out.data(), bytes.data(), bytes.size());
  }
}

std::string hash_file_fnv1a(const std::string &path) {
  if (path.empty()) return "";
  std::ifstream in(path, std::ios::binary);
  if (!in) return "missing";
  uint64_t h = 1469598103934665603ull;
  char buf[4096];
  while (in) {
    in.read(buf, sizeof(buf));
    std::streamsize n = in.gcount();
    for (std::streamsize i = 0; i < n; i++) {
      h ^= static_cast<uint8_t>(buf[i]);
      h *= 1099511628211ull;
    }
  }
  std::ostringstream os;
  os << std::hex << h;
  return os.str();
}

void write_u64_text(std::ostream &os, const char *key, uint64_t value) {
  os << key << "=" << value << "\n";
}

void write_str_text(std::ostream &os, const char *key, const std::string &value) {
  os << key << "=" << value << "\n";
}

std::vector<uint8_t> encode_meta(const SnapshotMeta &meta) {
  std::ostringstream os;
  write_str_text(os, "img_path", meta.img_path);
  write_str_text(os, "img_hash", meta.img_hash);
  write_str_text(os, "dtb_path", meta.dtb_path);
  write_str_text(os, "virtio_blk_image", meta.virtio_blk_image);
  write_u64_text(os, "boot_handoff", meta.boot_handoff ? 1 : 0);
  write_u64_text(os, "entry_pc", meta.entry_pc);
  write_u64_text(os, "firmware_base", meta.firmware_base);
  write_u64_text(os, "difftest_enabled", meta.difftest_enabled ? 1 : 0);
  std::string text = os.str();
  return std::vector<uint8_t>(text.begin(), text.end());
}

bool parse_u64_text(const std::string &s, uint64_t &out) {
  try {
    size_t idx = 0;
    out = std::stoull(s, &idx, 0);
    return idx == s.size();
  } catch (...) {
    return false;
  }
}

SnapshotMeta decode_meta(const std::vector<uint8_t> &bytes) {
  SnapshotMeta meta;
  std::string text(bytes.begin(), bytes.end());
  std::istringstream is(text);
  std::string line;
  while (std::getline(is, line)) {
    size_t eq = line.find('=');
    if (eq == std::string::npos) continue;
    std::string key = line.substr(0, eq);
    std::string value = line.substr(eq + 1);
    uint64_t v = 0;
    if (key == "img_path") meta.img_path = value;
    else if (key == "img_hash") meta.img_hash = value;
    else if (key == "dtb_path") meta.dtb_path = value;
    else if (key == "virtio_blk_image") meta.virtio_blk_image = value;
    else if (key == "boot_handoff" && parse_u64_text(value, v)) meta.boot_handoff = v != 0;
    else if (key == "entry_pc" && parse_u64_text(value, v)) meta.entry_pc = static_cast<uint32_t>(v);
    else if (key == "firmware_base" && parse_u64_text(value, v)) meta.firmware_base = static_cast<uint32_t>(v);
    else if (key == "difftest_enabled" && parse_u64_text(value, v)) meta.difftest_enabled = v != 0;
  }
  return meta;
}

UnifiedFixed pack_unified(const UnifiedMem &mem) {
  UnifiedFixed f{};
  f.rtc_time_us = mem.rtc_time_us;
  f.clint_mtime = mem.clint_mtime;
  f.clint_mtimecmp = mem.clint_mtimecmp;
  f.plic_priority1 = mem.plic_priority1;
  f.plic_enable_m = mem.plic_enable_m;
  f.plic_threshold_m = mem.plic_threshold_m;
  f.plic_source_pending1 = mem.plic_source_pending1;
  f.plic_pending1 = mem.plic_pending1;
  f.plic_claimed1 = mem.plic_claimed1;
  f.virtio_blk_enabled_flag = mem.virtio_blk_enabled_flag;
  f.virtio_device_features_sel = mem.virtio_device_features_sel;
  f.virtio_driver_features_sel = mem.virtio_driver_features_sel;
  f.virtio_driver_features_lo = mem.virtio_driver_features_lo;
  f.virtio_driver_features_hi = mem.virtio_driver_features_hi;
  f.virtio_queue_sel = mem.virtio_queue_sel;
  f.virtio_queue_num = mem.virtio_queue_num;
  f.virtio_queue_ready = mem.virtio_queue_ready;
  f.virtio_queue_desc = mem.virtio_queue_desc;
  f.virtio_queue_avail = mem.virtio_queue_avail;
  f.virtio_queue_used = mem.virtio_queue_used;
  f.virtio_last_avail_idx = mem.virtio_last_avail_idx;
  f.virtio_status = mem.virtio_status;
  f.virtio_interrupt_status = mem.virtio_interrupt_status;
  f.virtio_config_generation = mem.virtio_config_generation;
  f.uart_stdout_enabled = mem.uart_stdout_enabled;
  f.uart_ier = mem.uart_ier;
  f.uart_fcr = mem.uart_fcr;
  f.uart_lcr = mem.uart_lcr;
  f.uart_mcr = mem.uart_mcr;
  f.uart_lsr = mem.uart_lsr;
  f.uart_msr = mem.uart_msr;
  f.uart_scr = mem.uart_scr;
  f.uart_dll = mem.uart_dll;
  f.uart_dlm = mem.uart_dlm;
  f.uart_tx_irq_latched = mem.uart_tx_irq_latched;
  f.uart_tx_rearm_pending = mem.uart_tx_rearm_pending;
  f.uart_tx_rearm_at = mem.uart_tx_rearm_at;
  f.uart_tx_bytes = mem.uart_tx_bytes;
  f.uart_last_tx = mem.uart_last_tx;
  f.fw_text_watch_enabled = mem.fw_text_watch_enabled;
  f.fw_text_watch_base = mem.fw_text_watch_base;
  f.fw_text_watch_limit = mem.fw_text_watch_limit;
  f.fw_text_write_count = mem.fw_text_write_count;
  f.fw_text_last_write_addr = mem.fw_text_last_write_addr;
  f.fw_text_last_write_data = mem.fw_text_last_write_data;
  return f;
}

void unpack_unified(const UnifiedFixed &f, UnifiedMem &mem) {
  mem.rtc_time_us = f.rtc_time_us;
  mem.clint_mtime = f.clint_mtime;
  mem.clint_mtimecmp = f.clint_mtimecmp;
  mem.plic_priority1 = f.plic_priority1;
  mem.plic_enable_m = f.plic_enable_m;
  mem.plic_threshold_m = f.plic_threshold_m;
  mem.plic_source_pending1 = f.plic_source_pending1 != 0;
  mem.plic_pending1 = f.plic_pending1 != 0;
  mem.plic_claimed1 = f.plic_claimed1 != 0;
  mem.virtio_blk_enabled_flag = f.virtio_blk_enabled_flag != 0;
  mem.virtio_device_features_sel = f.virtio_device_features_sel;
  mem.virtio_driver_features_sel = f.virtio_driver_features_sel;
  mem.virtio_driver_features_lo = f.virtio_driver_features_lo;
  mem.virtio_driver_features_hi = f.virtio_driver_features_hi;
  mem.virtio_queue_sel = f.virtio_queue_sel;
  mem.virtio_queue_num = f.virtio_queue_num;
  mem.virtio_queue_ready = f.virtio_queue_ready;
  mem.virtio_queue_desc = f.virtio_queue_desc;
  mem.virtio_queue_avail = f.virtio_queue_avail;
  mem.virtio_queue_used = f.virtio_queue_used;
  mem.virtio_last_avail_idx = f.virtio_last_avail_idx;
  mem.virtio_status = f.virtio_status;
  mem.virtio_interrupt_status = f.virtio_interrupt_status;
  mem.virtio_config_generation = f.virtio_config_generation;
  mem.uart_stdout_enabled = f.uart_stdout_enabled != 0;
  mem.uart_ier = f.uart_ier;
  mem.uart_fcr = f.uart_fcr;
  mem.uart_lcr = f.uart_lcr;
  mem.uart_mcr = f.uart_mcr;
  mem.uart_lsr = f.uart_lsr;
  mem.uart_msr = f.uart_msr;
  mem.uart_scr = f.uart_scr;
  mem.uart_dll = f.uart_dll;
  mem.uart_dlm = f.uart_dlm;
  mem.uart_tx_irq_latched = f.uart_tx_irq_latched != 0;
  mem.uart_tx_rearm_pending = f.uart_tx_rearm_pending != 0;
  mem.uart_tx_rearm_at = f.uart_tx_rearm_at;
  mem.uart_tx_bytes = f.uart_tx_bytes;
  mem.uart_last_tx = f.uart_last_tx;
  mem.fw_text_watch_enabled = f.fw_text_watch_enabled != 0;
  mem.fw_text_watch_base = f.fw_text_watch_base;
  mem.fw_text_watch_limit = f.fw_text_watch_limit;
  mem.fw_text_write_count = f.fw_text_write_count;
  mem.fw_text_last_write_addr = f.fw_text_last_write_addr;
  mem.fw_text_last_write_data = f.fw_text_last_write_data;
}

std::vector<uint8_t> pack_icache(const ICacheModel &icache) {
  ICacheFixed f{};
  f.pending = icache.pending;
  f.delay = icache.delay;
  f.miss_addr = icache.miss_addr;
  f.miss_way = icache.miss_way;
  f.refill_pulse = icache.refill_pulse;
  for (size_t i = 0; i < icache.line_words.size(); i++) f.line_words[i] = icache.line_words[i];
  return bytes_from_object(&f, sizeof(f));
}

void unpack_icache(const std::vector<uint8_t> &bytes, ICacheModel &icache) {
  if (bytes.size() != sizeof(ICacheFixed)) throw std::runtime_error("bad icache blob size");
  ICacheFixed f{};
  std::memcpy(&f, bytes.data(), sizeof(f));
  icache.pending = f.pending != 0;
  icache.delay = f.delay;
  icache.miss_addr = f.miss_addr;
  icache.miss_way = f.miss_way;
  icache.refill_pulse = f.refill_pulse != 0;
  for (size_t i = 0; i < icache.line_words.size(); i++) icache.line_words[i] = f.line_words[i];
}

DCacheTxnFixed pack_dcache_txn(const DCacheModel::MissTxn &txn) {
  DCacheTxnFixed f{};
  f.delay = txn.delay;
  f.miss_addr = txn.miss_addr;
  f.miss_way = txn.miss_way;
  for (size_t i = 0; i < txn.line_words.size(); i++) f.line_words[i] = txn.line_words[i];
  return f;
}

DCacheModel::MissTxn unpack_dcache_txn(const DCacheTxnFixed &f) {
  DCacheModel::MissTxn txn{};
  txn.delay = f.delay;
  txn.miss_addr = f.miss_addr;
  txn.miss_way = f.miss_way;
  for (size_t i = 0; i < txn.line_words.size(); i++) txn.line_words[i] = f.line_words[i];
  return txn;
}

std::vector<uint8_t> pack_dcache(const DCacheModel &dcache) {
  DCacheFixed f{};
  f.refill_pulse = dcache.refill_pulse;
  f.refill_txn = pack_dcache_txn(dcache.refill_txn);
  f.pending_count = dcache.pending_q.size();
  std::vector<uint8_t> bytes = bytes_from_object(&f, sizeof(f));
  for (const auto &txn : dcache.pending_q) {
    DCacheTxnFixed packed = pack_dcache_txn(txn);
    auto txn_bytes = bytes_from_object(&packed, sizeof(packed));
    bytes.insert(bytes.end(), txn_bytes.begin(), txn_bytes.end());
  }
  return bytes;
}

void unpack_dcache(const std::vector<uint8_t> &bytes, DCacheModel &dcache) {
  if (bytes.size() < sizeof(DCacheFixed)) throw std::runtime_error("bad dcache blob size");
  DCacheFixed f{};
  std::memcpy(&f, bytes.data(), sizeof(f));
  size_t expected = sizeof(DCacheFixed) + static_cast<size_t>(f.pending_count) * sizeof(DCacheTxnFixed);
  if (bytes.size() != expected) throw std::runtime_error("bad dcache pending blob size");
  dcache.refill_pulse = f.refill_pulse != 0;
  dcache.refill_txn = unpack_dcache_txn(f.refill_txn);
  dcache.pending_q.clear();
  const uint8_t *ptr = bytes.data() + sizeof(DCacheFixed);
  for (uint64_t i = 0; i < f.pending_count; i++) {
    DCacheTxnFixed packed{};
    std::memcpy(&packed, ptr, sizeof(packed));
    dcache.pending_q.push_back(unpack_dcache_txn(packed));
    ptr += sizeof(packed);
  }
}

void write_blob(std::ofstream &out, uint32_t id, const std::vector<uint8_t> &bytes) {
  BlobHeader h{id, kBlobRaw, bytes.size(), bytes.size()};
  out.write(reinterpret_cast<const char *>(&h), sizeof(h));
  if (!bytes.empty()) out.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
}

std::vector<uint8_t> read_blob_payload(std::ifstream &in, const BlobHeader &h) {
  if (h.codec != kBlobRaw || h.raw_size != h.stored_size) {
    throw std::runtime_error("unsupported snapshot blob codec");
  }
  std::vector<uint8_t> bytes(static_cast<size_t>(h.stored_size));
  if (!bytes.empty()) in.read(reinterpret_cast<char *>(bytes.data()), bytes.size());
  if (!in) throw std::runtime_error("truncated snapshot blob");
  return bytes;
}

std::vector<uint8_t> read_file_bytes(const std::filesystem::path &path) {
  std::ifstream in(path, std::ios::binary);
  return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)),
                              std::istreambuf_iterator<char>());
}

bool write_file_bytes(const std::filesystem::path &path,
                      const std::vector<uint8_t> &bytes) {
  std::ofstream out(path, std::ios::binary);
  if (!out) return false;
  if (!bytes.empty()) out.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
  return static_cast<bool>(out);
}

bool capture_dut_blob(Vtb_triathlon *top, std::vector<uint8_t> &blob) {
#if NPC_SNAPSHOT
  std::filesystem::path tmp =
      std::filesystem::temp_directory_path() /
      ("triathlon-dut-save-" + std::to_string(reinterpret_cast<uintptr_t>(top)) + ".bin");
  VerilatedSave save;
  save.open(tmp.string());
  save << *top;
  save.close();
  blob = read_file_bytes(tmp);
  std::error_code ec;
  std::filesystem::remove(tmp, ec);
  return !blob.empty();
#else
  (void)top;
  blob.clear();
  std::cerr << "[snapshot] binary was not built with SNAPSHOT=1\n";
  return false;
#endif
}

bool restore_dut_blob(Vtb_triathlon *top, const std::vector<uint8_t> &blob) {
#if NPC_SNAPSHOT
  std::filesystem::path tmp =
      std::filesystem::temp_directory_path() /
      ("triathlon-dut-restore-" + std::to_string(reinterpret_cast<uintptr_t>(top)) + ".bin");
  if (!write_file_bytes(tmp, blob)) return false;
  VerilatedRestore restore;
  restore.open(tmp.string());
  restore >> *top;
  restore.close();
  std::error_code ec;
  std::filesystem::remove(tmp, ec);
  return true;
#else
  (void)top;
  (void)blob;
  std::cerr << "[snapshot] binary was not built with SNAPSHOT=1\n";
  return false;
#endif
}

bool parse_snapshot_cycle(const std::filesystem::path &path, uint64_t &cycle) {
  std::string name = path.filename().string();
  const std::string prefix = "triathlon-";
  const std::string suffix = ".snap";
  if (name.rfind(prefix, 0) != 0) return false;
  if (name.size() <= prefix.size() + suffix.size()) return false;
  if (name.substr(name.size() - suffix.size()) != suffix) return false;
  std::string num = name.substr(prefix.size(), name.size() - prefix.size() - suffix.size());
  try {
    size_t idx = 0;
    cycle = std::stoull(num, &idx, 10);
    return idx == num.size();
  } catch (...) {
    return false;
  }
}

}  // namespace

SnapshotMeta make_snapshot_meta(const SimArgs &args, uint32_t entry_pc,
                                uint32_t firmware_base, bool difftest_enabled) {
  SnapshotMeta meta;
  meta.img_path = args.img_path;
  meta.img_hash = hash_file_fnv1a(args.img_path);
  meta.dtb_path = args.dtb_path;
  meta.virtio_blk_image = args.virtio_blk_image;
  meta.boot_handoff = args.boot_handoff;
  meta.entry_pc = entry_pc;
  meta.firmware_base = firmware_base;
  meta.difftest_enabled = difftest_enabled;
  return meta;
}

bool snapshot_meta_matches(const SnapshotMeta &saved, const SnapshotMeta &current,
                           std::string &reason) {
  if (saved.img_hash != current.img_hash) {
    reason = "IMG hash differs";
    return false;
  }
  if (saved.boot_handoff != current.boot_handoff) {
    reason = "boot_handoff differs";
    return false;
  }
  if (saved.entry_pc != current.entry_pc) {
    reason = "entry_pc differs";
    return false;
  }
  if (saved.firmware_base != current.firmware_base) {
    reason = "firmware_base differs";
    return false;
  }
  if (saved.difftest_enabled != current.difftest_enabled) {
    reason = "difftest enable differs";
    return false;
  }
  return true;
}

bool capture_snapshot(const std::string &path, Vtb_triathlon *top, MemSystem &mem,
                      Difftest &difftest, const SnapshotMeta &meta,
                      const std::array<uint32_t, 32> &rf, uint64_t cycle,
                      uint64_t sim_time, uint64_t no_commit_cycles) {
  std::filesystem::create_directories(std::filesystem::path(path).parent_path());

  DUTCoreState ref_state{};
  std::vector<uint8_t> ref_pmem;
  if (!difftest.capture_ref_state(ref_state, ref_pmem)) return false;

  std::vector<uint8_t> dut_blob;
  if (!capture_dut_blob(top, dut_blob)) return false;

  std::ofstream out(path, std::ios::binary);
  if (!out) {
    std::cerr << "[snapshot] failed to open " << path << " for write\n";
    return false;
  }

  FileHeader header{};
  std::memcpy(header.magic, kMagic, sizeof(kMagic));
  header.version = kVersion;
  header.cycle = cycle;
  header.sim_time = sim_time;
  header.no_commit_cycles = no_commit_cycles;
  out.write(reinterpret_cast<const char *>(&header), sizeof(header));

  UnifiedFixed unified = pack_unified(mem.mem);
  write_blob(out, kBlobMeta, encode_meta(meta));
  write_blob(out, kBlobRf, bytes_from_object(rf.data(), rf.size() * sizeof(uint32_t)));
  write_blob(out, kBlobUnifiedFixed, bytes_from_object(&unified, sizeof(unified)));
  write_blob(out, kBlobPmem, bytes_from_vector(mem.mem.pmem_words));
  write_blob(out, kBlobBootrom, bytes_from_vector(mem.mem.bootrom_words));
  write_blob(out, kBlobVirtioImage, bytes_from_vector(mem.mem.virtio_blk_image));
  write_blob(out, kBlobICache, pack_icache(mem.icache));
  write_blob(out, kBlobDCache, pack_dcache(mem.dcache));
  write_blob(out, kBlobRefState, bytes_from_object(&ref_state, sizeof(ref_state)));
  write_blob(out, kBlobRefPmem, ref_pmem);
  write_blob(out, kBlobDut, dut_blob);

  if (!out) {
    std::cerr << "[snapshot] failed while writing " << path << "\n";
    return false;
  }

  std::cerr << "[snapshot] wrote " << path << " cycle=" << cycle
            << " bytes=" << std::filesystem::file_size(path) << "\n";
  return true;
}

bool restore_snapshot(const std::string &path, Vtb_triathlon *top, MemSystem &mem,
                      Difftest &difftest, const SnapshotMeta &expected_meta,
                      std::array<uint32_t, 32> &rf, uint64_t &cycle_out,
                      uint64_t &sim_time_out, uint64_t &no_commit_cycles_out) {
  try {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
      std::cerr << "[snapshot] failed to open " << path << " for restore\n";
      return false;
    }

    FileHeader header{};
    in.read(reinterpret_cast<char *>(&header), sizeof(header));
    if (!in || std::memcmp(header.magic, kMagic, sizeof(kMagic)) != 0 ||
        header.version != kVersion) {
      std::cerr << "[snapshot] bad snapshot header: " << path << "\n";
      return false;
    }

    SnapshotMeta saved_meta;
    UnifiedFixed unified{};
    DUTCoreState ref_state{};
    std::vector<uint8_t> ref_pmem;
    std::vector<uint8_t> dut_blob;
    bool have_meta = false;
    bool have_rf = false;
    bool have_unified = false;
    bool have_dut = false;

    BlobHeader bh{};
    while (in.read(reinterpret_cast<char *>(&bh), sizeof(bh))) {
      std::vector<uint8_t> payload = read_blob_payload(in, bh);
      switch (bh.id) {
        case kBlobMeta:
          saved_meta = decode_meta(payload);
          have_meta = true;
          break;
        case kBlobRf:
          if (payload.size() != rf.size() * sizeof(uint32_t)) throw std::runtime_error("bad rf size");
          std::memcpy(rf.data(), payload.data(), payload.size());
          have_rf = true;
          break;
        case kBlobUnifiedFixed:
          if (payload.size() != sizeof(unified)) throw std::runtime_error("bad unified size");
          std::memcpy(&unified, payload.data(), sizeof(unified));
          have_unified = true;
          break;
        case kBlobPmem:
          vector_from_bytes(payload, mem.mem.pmem_words, "pmem");
          break;
        case kBlobBootrom:
          vector_from_bytes(payload, mem.mem.bootrom_words, "bootrom");
          break;
        case kBlobVirtioImage:
          mem.mem.virtio_blk_image = payload;
          break;
        case kBlobICache:
          unpack_icache(payload, mem.icache);
          break;
        case kBlobDCache:
          unpack_dcache(payload, mem.dcache);
          break;
        case kBlobRefState:
          if (payload.size() != sizeof(ref_state)) throw std::runtime_error("bad ref state size");
          std::memcpy(&ref_state, payload.data(), sizeof(ref_state));
          break;
        case kBlobRefPmem:
          ref_pmem = std::move(payload);
          break;
        case kBlobDut:
          dut_blob = std::move(payload);
          have_dut = true;
          break;
        default:
          break;
      }
    }

    if (!have_meta || !have_rf || !have_unified || !have_dut) {
      std::cerr << "[snapshot] missing required blobs in " << path << "\n";
      return false;
    }
    std::string reason;
    if (!snapshot_meta_matches(saved_meta, expected_meta, reason)) {
      std::cerr << "[snapshot] restore metadata mismatch: " << reason << "\n";
      return false;
    }

    unpack_unified(unified, mem.mem);
    mem.icache.mem = &mem.mem;
    mem.dcache.mem = &mem.mem;
    mem.mmio.mem = &mem.mem;
    if (!difftest.restore_ref_state(ref_state, ref_pmem)) return false;
    if (!restore_dut_blob(top, dut_blob)) return false;

    cycle_out = header.cycle;
    sim_time_out = header.sim_time;
    no_commit_cycles_out = header.no_commit_cycles;
    std::cerr << "[snapshot] restored " << path << " cycle=" << cycle_out << "\n";
    return true;
  } catch (const std::exception &e) {
    std::cerr << "[snapshot] restore failed: " << e.what() << "\n";
    return false;
  }
}

std::string snapshot_path_for_cycle(const std::string &dir, uint64_t cycle) {
  std::filesystem::path p(dir);
  p /= "triathlon-" + std::to_string(cycle) + ".snap";
  return p.string();
}

void rotate_snapshots(const std::string &dir, uint64_t keep) {
  if (keep == 0) return;
  std::vector<std::pair<uint64_t, std::filesystem::path>> snaps;
  std::error_code ec;
  if (!std::filesystem::exists(dir, ec)) return;
  for (const auto &entry : std::filesystem::directory_iterator(dir, ec)) {
    uint64_t cycle = 0;
    if (!ec && entry.is_regular_file() && parse_snapshot_cycle(entry.path(), cycle)) {
      snaps.emplace_back(cycle, entry.path());
    }
  }
  std::sort(snaps.begin(), snaps.end(),
            [](const auto &a, const auto &b) { return a.first < b.first; });
  while (snaps.size() > keep) {
    std::filesystem::remove(snaps.front().second, ec);
    snaps.erase(snaps.begin());
  }
}

std::string nearest_snapshot_before_or_at(const std::string &dir, uint64_t cycle,
                                          uint64_t *snapshot_cycle_out) {
  std::error_code ec;
  if (!std::filesystem::exists(dir, ec)) return "";
  uint64_t best = 0;
  std::filesystem::path best_path;
  bool found = false;
  for (const auto &entry : std::filesystem::directory_iterator(dir, ec)) {
    uint64_t snap_cycle = 0;
    if (!ec && entry.is_regular_file() && parse_snapshot_cycle(entry.path(), snap_cycle) &&
        snap_cycle <= cycle && (!found || snap_cycle > best)) {
      best = snap_cycle;
      best_path = entry.path();
      found = true;
    }
  }
  if (!found) return "";
  if (snapshot_cycle_out) *snapshot_cycle_out = best;
  return best_path.string();
}

}  // namespace npc
