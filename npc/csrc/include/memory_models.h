#pragma once

#include "platform_contract.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <array>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

namespace npc {

struct UnifiedMem {
  std::vector<uint32_t> pmem_words;
  std::vector<uint32_t> bootrom_words;
  uint64_t rtc_time_us = 0;
  uint64_t clint_mtime = 0;
  uint64_t clint_mtimecmp = ~0ull;
  uint32_t plic_priority1 = 0;
  uint32_t plic_enable_m = 0;
  uint32_t plic_threshold_m = 0;
  bool plic_source_pending1 = false;
  bool plic_pending1 = false;
  bool plic_claimed1 = false;
  bool virtio_blk_enabled_flag = false;
  std::vector<uint8_t> virtio_blk_image;
  uint32_t virtio_device_features_sel = 0;
  uint32_t virtio_driver_features_sel = 0;
  uint32_t virtio_driver_features_lo = 0;
  uint32_t virtio_driver_features_hi = 0;
  uint32_t virtio_queue_sel = 0;
  uint32_t virtio_queue_num = 0;
  uint32_t virtio_queue_ready = 0;
  uint64_t virtio_queue_desc = 0;
  uint64_t virtio_queue_avail = 0;
  uint64_t virtio_queue_used = 0;
  uint16_t virtio_last_avail_idx = 0;
  uint8_t virtio_status = 0;
  uint32_t virtio_interrupt_status = 0;
  uint32_t virtio_config_generation = 0;
  bool uart_stdout_enabled = true;
  uint8_t uart_ier = 0;
  uint8_t uart_fcr = 0;
  uint8_t uart_lcr = 0;
  uint8_t uart_mcr = 0;
  uint8_t uart_lsr = 0x60;  // THR/TEMT ready
  uint8_t uart_msr = 0;
  uint8_t uart_scr = 0;
  uint8_t uart_dll = 0;
  uint8_t uart_dlm = 0;
  bool uart_tx_irq_latched = false;
  bool uart_tx_rearm_pending = false;
  uint64_t uart_tx_rearm_at = 0;
  uint64_t uart_tx_bytes = 0;
  uint8_t uart_last_tx = 0;
  bool fw_text_watch_enabled = false;
  uint32_t fw_text_watch_base = 0x80400000u;
  uint32_t fw_text_watch_limit = 0x80440000u;
  uint64_t fw_text_write_count = 0;
  uint32_t fw_text_last_write_addr = 0;
  uint32_t fw_text_last_write_data = 0;

  static constexpr uint64_t kUartTxEmptyDelayCycles = 1u;

  UnifiedMem()
      : pmem_words(kPmemSize / sizeof(uint32_t), 0),
        bootrom_words(kBootRomSize / sizeof(uint32_t), 0) {}

  static bool in_pmem(uint32_t addr) {
    return addr >= kPmemBase && addr < (kPmemBase + kPmemSize);
  }

  static bool in_bootrom(uint32_t addr) {
    return addr >= kBootRomBase && addr < (kBootRomBase + kBootRomSize);
  }

  static bool in_uart(uint32_t addr) {
    return addr >= kUartTx && addr < (kUartTx + 8u);
  }

  static bool in_virtio_blk(uint32_t addr) {
    return addr >= kVirtioBlkBase && addr < (kVirtioBlkBase + kVirtioBlkSize);
  }

  bool in_fw_text_watch(uint32_t addr) const {
    return addr >= fw_text_watch_base && addr < fw_text_watch_limit;
  }

  static bool access_touches_bootrom(uint32_t addr, uint32_t size) {
    for (uint32_t i = 0; i < size; i++) {
      if (in_bootrom(addr + i)) return true;
    }
    return false;
  }

  bool uart_dlab() const { return (uart_lcr & 0x80u) != 0; }

  // TX-empty interrupt is latched: asserted when THRI is enabled and THR is empty,
  // cleared by a THR write (byte loaded) or disabling THRI. Unlike the old model,
  // it is NOT tied directly to IER.THRI so PLIC complete can drop the line before
  // the driver re-arms via IER disable/enable (Linux 8250 stop_tx/start_tx path).
  bool uart_irq_pending() const { return uart_tx_irq_latched; }

  void arm_uart_tx_irq_if_enabled() {
    if ((uart_ier & 0x02u) != 0u) {
      uart_tx_irq_latched = true;
      update_uart_plic();
    }
  }

  void clear_uart_tx_irq() {
    if (!uart_tx_irq_latched) return;
    uart_tx_irq_latched = false;
    update_uart_plic();
  }

  void schedule_uart_tx_empty_rearm() {
    if ((uart_ier & 0x02u) == 0u) {
      uart_tx_rearm_pending = false;
      return;
    }
    uart_tx_rearm_pending = true;
    uart_tx_rearm_at = rtc_time_us + kUartTxEmptyDelayCycles;
  }

  void service_uart_tx_empty_rearm() {
    if (!uart_tx_rearm_pending || rtc_time_us < uart_tx_rearm_at) return;
    uart_tx_rearm_pending = false;
    if ((uart_ier & 0x02u) == 0u || uart_tx_irq_latched) return;

    arm_uart_tx_irq_if_enabled();
  }

  uint8_t uart_peek8(uint32_t addr) const {
    uint32_t off = addr - kUartTx;
    switch (off) {
      case 0:
        return uart_dlab() ? uart_dll : 0u;  // no RX FIFO model yet
      case 1:
        return uart_dlab() ? uart_dlm : uart_ier;
      case 2: {
        // Bit0=0 => an interrupt is pending. Report the THR-empty (TX)
        // interrupt id (0b001) when the driver enabled it; otherwise 0x01
        // (no interrupt pending). Upper bits flag an enabled FIFO.
        uint8_t iir = uart_irq_pending() ? 0x02u : 0x01u;
        if ((uart_fcr & 0x01u) != 0) iir |= 0xC0u;
        return iir;
      }
      case 3:
        return uart_lcr;
      case 4:
        return uart_mcr;
      case 5:
        return static_cast<uint8_t>(uart_lsr | 0x60u);
      case 6:
        return uart_msr;
      case 7:
        return uart_scr;
      default:
        return 0xffu;
    }
  }

  void uart_write8(uint32_t addr, uint8_t data) {
    uint32_t off = addr - kUartTx;
    switch (off) {
      case 0:
        if (uart_dlab()) {
          uart_dll = data;
        } else {
          uart_tx_bytes++;
          uart_last_tx = data;
          if (uart_stdout_enabled) {
            std::cout << static_cast<char>(data) << std::flush;
          }
          // THR load clears the TX-empty condition until re-armed via IER.
          clear_uart_tx_irq();
          schedule_uart_tx_empty_rearm();
        }
        break;
      case 1:
        if (uart_dlab()) {
          uart_dlm = data;
        } else {
          uint8_t old_ier = uart_ier;
          uart_ier = data;
          if ((uart_ier & 0x02u) == 0u) {
            uart_tx_rearm_pending = false;
            clear_uart_tx_irq();
          } else if ((old_ier & 0x02u) == 0u) {
            arm_uart_tx_irq_if_enabled();
          } else {
            update_uart_plic();
          }
        }
        break;
      case 2:
        uart_fcr = data;
        break;
      case 3:
        uart_lcr = data;
        break;
      case 4:
        uart_mcr = data;
        break;
      case 7:
        uart_scr = data;
        break;
      default:
        break;
    }
  }

  static bool is_clint_word(uint32_t aligned) {
    return aligned == kClintMtimecmpLow || aligned == kClintMtimecmpHigh ||
           aligned == kClintMtimeLow || aligned == kClintMtimeHigh;
  }

  static bool is_plic_word(uint32_t aligned) {
    return aligned == kPlicPriority1 || aligned == kPlicPending ||
           aligned == kPlicEnableM || aligned == kPlicThresholdM ||
           aligned == kPlicClaimCompleteM;
  }

  static constexpr uint32_t kVirtioMagicValue = 0x74726976u;
  static constexpr uint32_t kVirtioVersion = 2u;
  static constexpr uint32_t kVirtioDeviceIdBlk = 2u;
  static constexpr uint32_t kVirtioVendorId = 0x554d4551u;
  static constexpr uint32_t kVirtioQueueNumMax = 128u;
  static constexpr uint32_t kVirtioInterruptUsedBuffer = 1u;
  static constexpr uint32_t kVirtioFeatureVersion1Sel = 1u;
  static constexpr uint32_t kVirtioFeatureVersion1Bit = 0u;
  static constexpr uint32_t kVirtioBlkTIn = 0u;
  static constexpr uint32_t kVirtioBlkTOut = 1u;
  static constexpr uint8_t kVirtioBlkStatusOk = 0u;
  static constexpr uint8_t kVirtioBlkStatusIoErr = 1u;
  static constexpr uint8_t kVirtioBlkStatusUnsupp = 2u;
  static constexpr uint32_t kVirtqDescFNext = 1u;
  static constexpr uint32_t kVirtqDescFWrite = 2u;
  static constexpr uint32_t kVirtioBlkSectorSize = 512u;

  struct VirtqDesc {
    uint64_t addr = 0;
    uint32_t len = 0;
    uint16_t flags = 0;
    uint16_t next = 0;
  };

  bool read_phys_byte(uint64_t addr, uint8_t &out) const {
    if (addr > 0xFFFFFFFFull) return false;
    uint32_t a32 = static_cast<uint32_t>(addr);
    uint32_t aligned = a32 & ~0x3u;
    uint32_t shift = (a32 & 0x3u) * 8u;
    if (in_pmem(a32)) {
      uint32_t idx = (aligned - kPmemBase) >> 2;
      if (idx >= pmem_words.size()) return false;
      out = static_cast<uint8_t>((pmem_words[idx] >> shift) & 0xffu);
      return true;
    }
    if (in_bootrom(a32)) {
      uint32_t idx = (aligned - kBootRomBase) >> 2;
      if (idx >= bootrom_words.size()) return false;
      out = static_cast<uint8_t>((bootrom_words[idx] >> shift) & 0xffu);
      return true;
    }
    return false;
  }

  bool write_phys_byte(uint64_t addr, uint8_t data) {
    if (addr > 0xFFFFFFFFull) return false;
    uint32_t a32 = static_cast<uint32_t>(addr);
    if (!in_pmem(a32)) return false;
    uint32_t aligned = a32 & ~0x3u;
    uint32_t shift = (a32 & 0x3u) * 8u;
    uint32_t idx = (aligned - kPmemBase) >> 2;
    if (idx >= pmem_words.size()) return false;
    uint32_t mask = 0xffu << shift;
    pmem_words[idx] = (pmem_words[idx] & ~mask) | (static_cast<uint32_t>(data) << shift);
    return true;
  }

  bool read_phys_u16(uint64_t addr, uint16_t &out) const {
    uint8_t b0 = 0;
    uint8_t b1 = 0;
    if (!read_phys_byte(addr, b0)) return false;
    if (!read_phys_byte(addr + 1u, b1)) return false;
    out = static_cast<uint16_t>(static_cast<uint16_t>(b0) |
                                (static_cast<uint16_t>(b1) << 8));
    return true;
  }

  bool read_phys_u32(uint64_t addr, uint32_t &out) const {
    uint8_t b[4] = {};
    for (uint32_t i = 0; i < 4; i++) {
      if (!read_phys_byte(addr + i, b[i])) return false;
    }
    out = static_cast<uint32_t>(b[0]) |
          (static_cast<uint32_t>(b[1]) << 8) |
          (static_cast<uint32_t>(b[2]) << 16) |
          (static_cast<uint32_t>(b[3]) << 24);
    return true;
  }

  bool read_phys_u64(uint64_t addr, uint64_t &out) const {
    uint32_t lo = 0;
    uint32_t hi = 0;
    if (!read_phys_u32(addr, lo)) return false;
    if (!read_phys_u32(addr + 4u, hi)) return false;
    out = static_cast<uint64_t>(lo) | (static_cast<uint64_t>(hi) << 32);
    return true;
  }

  bool write_phys_u16(uint64_t addr, uint16_t value) {
    if (!write_phys_byte(addr, static_cast<uint8_t>(value & 0xffu))) return false;
    if (!write_phys_byte(addr + 1u, static_cast<uint8_t>((value >> 8) & 0xffu))) return false;
    return true;
  }

  bool write_phys_u32(uint64_t addr, uint32_t value) {
    for (uint32_t i = 0; i < 4; i++) {
      if (!write_phys_byte(addr + i, static_cast<uint8_t>((value >> (i * 8u)) & 0xffu))) {
        return false;
      }
    }
    return true;
  }

  uint64_t virtio_blk_capacity_sectors() const {
    return static_cast<uint64_t>(virtio_blk_image.size() / kVirtioBlkSectorSize);
  }

  void virtio_blk_reset_transport_state() {
    virtio_device_features_sel = 0;
    virtio_driver_features_sel = 0;
    virtio_driver_features_lo = 0;
    virtio_driver_features_hi = 0;
    virtio_queue_sel = 0;
    virtio_queue_num = 0;
    virtio_queue_ready = 0;
    virtio_queue_desc = 0;
    virtio_queue_avail = 0;
    virtio_queue_used = 0;
    virtio_last_avail_idx = 0;
    virtio_status = 0;
    virtio_interrupt_status = 0;
    set_plic_source_pending(kVirtioBlkIrqId, false);
  }

  bool load_virtio_blk_image(const std::string &path) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) {
      std::cerr << "Failed to open virtio-blk image: " << path << "\n";
      return false;
    }
    virtio_blk_image.assign(std::istreambuf_iterator<char>(ifs),
                            std::istreambuf_iterator<char>());
    virtio_blk_enabled_flag = true;
    virtio_blk_reset_transport_state();
    return true;
  }

  bool virtio_blk_enabled() const { return virtio_blk_enabled_flag; }

  bool virtio_read_desc(uint16_t index, VirtqDesc &desc) const {
    if (virtio_queue_num == 0 || index >= virtio_queue_num) return false;
    uint64_t base = virtio_queue_desc + static_cast<uint64_t>(index) * 16ull;
    if (!read_phys_u64(base + 0u, desc.addr)) return false;
    if (!read_phys_u32(base + 8u, desc.len)) return false;
    if (!read_phys_u16(base + 12u, desc.flags)) return false;
    if (!read_phys_u16(base + 14u, desc.next)) return false;
    return true;
  }

  void virtio_push_used(uint16_t head_idx, uint32_t used_len) {
    if (virtio_queue_num == 0) return;
    uint16_t used_idx = 0;
    if (!read_phys_u16(virtio_queue_used + 2u, used_idx)) return;
    uint32_t slot = used_idx % virtio_queue_num;
    uint64_t elem = virtio_queue_used + 4u + static_cast<uint64_t>(slot) * 8ull;
    if (!write_phys_u32(elem + 0u, head_idx)) return;
    if (!write_phys_u32(elem + 4u, used_len)) return;
    write_phys_u16(virtio_queue_used + 2u, static_cast<uint16_t>(used_idx + 1u));
  }

  bool virtio_process_blk_request(uint16_t head_idx, uint32_t &used_len, uint8_t &status) {
    used_len = 0;
    status = kVirtioBlkStatusIoErr;
    if (!virtio_blk_enabled_flag) return false;
    if (virtio_queue_num == 0) return false;

    std::array<VirtqDesc, kVirtioQueueNumMax> chain{};
    uint32_t chain_len = 0;
    uint16_t cur = head_idx;
    std::array<bool, kVirtioQueueNumMax> visited{};
    while (chain_len < kVirtioQueueNumMax) {
      if (cur >= virtio_queue_num) return false;
      if (visited[cur]) return false;
      visited[cur] = true;
      if (!virtio_read_desc(cur, chain[chain_len])) return false;
      bool has_next = (chain[chain_len].flags & kVirtqDescFNext) != 0u;
      chain_len++;
      if (!has_next) break;
      cur = chain[chain_len - 1u].next;
    }
    if (chain_len < 3u) return false;

    const VirtqDesc &hdr_desc = chain[0];
    const VirtqDesc &status_desc = chain[chain_len - 1u];
    if (hdr_desc.len < 16u) return false;
    if ((status_desc.flags & kVirtqDescFWrite) == 0u || status_desc.len < 1u) return false;

    uint32_t req_type = 0;
    uint64_t sector = 0;
    if (!read_phys_u32(hdr_desc.addr + 0u, req_type)) return false;
    if (!read_phys_u64(hdr_desc.addr + 8u, sector)) return false;

    if (req_type != kVirtioBlkTIn && req_type != kVirtioBlkTOut) {
      status = kVirtioBlkStatusUnsupp;
      write_phys_byte(status_desc.addr, status);
      return false;
    }

    uint64_t disk_off = sector * static_cast<uint64_t>(kVirtioBlkSectorSize);
    bool ok = true;
    for (uint32_t i = 1; i + 1 < chain_len; i++) {
      const VirtqDesc &d = chain[i];
      bool dev_write = (d.flags & kVirtqDescFWrite) != 0u;
      if (req_type == kVirtioBlkTIn && !dev_write) {
        ok = false;
        break;
      }
      if (req_type == kVirtioBlkTOut && dev_write) {
        ok = false;
        break;
      }
      if (disk_off + static_cast<uint64_t>(d.len) > virtio_blk_image.size()) {
        ok = false;
        break;
      }
      for (uint32_t b = 0; b < d.len; b++) {
        if (req_type == kVirtioBlkTIn) {
          if (!write_phys_byte(d.addr + b, virtio_blk_image[disk_off + b])) {
            ok = false;
            break;
          }
        } else {
          uint8_t v = 0;
          if (!read_phys_byte(d.addr + b, v)) {
            ok = false;
            break;
          }
          virtio_blk_image[disk_off + b] = v;
        }
      }
      if (!ok) break;
      disk_off += d.len;
      used_len += d.len;
    }

    status = ok ? kVirtioBlkStatusOk : kVirtioBlkStatusIoErr;
    write_phys_byte(status_desc.addr, status);
    return ok;
  }

  void virtio_handle_notify(uint32_t queue_idx) {
    if (!virtio_blk_enabled_flag) return;
    if (queue_idx != 0u) return;
    if (virtio_queue_num == 0u || virtio_queue_num > kVirtioQueueNumMax) return;
    if (virtio_queue_ready == 0u) return;

    uint16_t avail_idx = 0;
    if (!read_phys_u16(virtio_queue_avail + 2u, avail_idx)) return;

    bool processed = false;
    while (virtio_last_avail_idx != avail_idx) {
      uint16_t ring_slot = virtio_last_avail_idx % virtio_queue_num;
      uint16_t head_idx = 0;
      if (!read_phys_u16(virtio_queue_avail + 4u + static_cast<uint64_t>(ring_slot) * 2ull, head_idx)) {
        break;
      }
      uint32_t used_len = 0;
      uint8_t req_status = kVirtioBlkStatusIoErr;
      virtio_process_blk_request(head_idx, used_len, req_status);
      virtio_push_used(head_idx, used_len);
      virtio_last_avail_idx = static_cast<uint16_t>(virtio_last_avail_idx + 1u);
      processed = true;
    }

    if (processed) {
      virtio_interrupt_status |= kVirtioInterruptUsedBuffer;
      set_plic_source_pending(kVirtioBlkIrqId, true);
    }
  }

  uint32_t virtio_mmio_read(uint32_t aligned) const {
    uint32_t off = aligned - kVirtioBlkBase;
    switch (off) {
      case 0x000u:
        return kVirtioMagicValue;
      case 0x004u:
        return kVirtioVersion;
      case 0x008u:
        return virtio_blk_enabled_flag ? kVirtioDeviceIdBlk : 0u;
      case 0x00cu:
        return kVirtioVendorId;
      case 0x010u:
        if (virtio_device_features_sel == kVirtioFeatureVersion1Sel) {
          return (1u << kVirtioFeatureVersion1Bit);
        }
        return 0u;
      case 0x014u:
        return virtio_device_features_sel;
      case 0x020u:
        return (virtio_driver_features_sel == 0u) ? virtio_driver_features_lo
                                                  : virtio_driver_features_hi;
      case 0x024u:
        return virtio_driver_features_sel;
      case 0x030u:
        return virtio_queue_sel;
      case 0x034u:
        return (virtio_queue_sel == 0u && virtio_blk_enabled_flag) ? kVirtioQueueNumMax : 0u;
      case 0x038u:
        return virtio_queue_num;
      case 0x044u:
        return virtio_queue_ready;
      case 0x060u:
        return virtio_interrupt_status;
      case 0x070u:
        return virtio_status;
      case 0x080u:
        return static_cast<uint32_t>(virtio_queue_desc & 0xffffffffu);
      case 0x084u:
        return static_cast<uint32_t>((virtio_queue_desc >> 32) & 0xffffffffu);
      case 0x090u:
        return static_cast<uint32_t>(virtio_queue_avail & 0xffffffffu);
      case 0x094u:
        return static_cast<uint32_t>((virtio_queue_avail >> 32) & 0xffffffffu);
      case 0x0a0u:
        return static_cast<uint32_t>(virtio_queue_used & 0xffffffffu);
      case 0x0a4u:
        return static_cast<uint32_t>((virtio_queue_used >> 32) & 0xffffffffu);
      case 0x0fcu:
        return virtio_config_generation;
      case 0x100u:
        return static_cast<uint32_t>(virtio_blk_capacity_sectors() & 0xffffffffu);
      case 0x104u:
        return static_cast<uint32_t>((virtio_blk_capacity_sectors() >> 32) & 0xffffffffu);
      default:
        return 0u;
    }
  }

  void virtio_mmio_write(uint32_t aligned, uint32_t data) {
    uint32_t off = aligned - kVirtioBlkBase;
    switch (off) {
      case 0x014u:
        virtio_device_features_sel = data;
        break;
      case 0x020u:
        if (virtio_driver_features_sel == 0u) {
          virtio_driver_features_lo = data;
        } else if (virtio_driver_features_sel == 1u) {
          virtio_driver_features_hi = data;
        }
        break;
      case 0x024u:
        virtio_driver_features_sel = data;
        break;
      case 0x030u:
        virtio_queue_sel = data;
        break;
      case 0x038u:
        if (virtio_queue_sel == 0u && data <= kVirtioQueueNumMax) {
          virtio_queue_num = data;
        }
        break;
      case 0x044u:
        if (virtio_queue_sel == 0u) {
          virtio_queue_ready = (data & 0x1u);
          if (virtio_queue_ready == 0u) virtio_last_avail_idx = 0u;
        }
        break;
      case 0x050u:
        virtio_handle_notify(data);
        break;
      case 0x064u:
        virtio_interrupt_status &= ~data;
        if ((virtio_interrupt_status & kVirtioInterruptUsedBuffer) == 0u) {
          set_plic_source_pending(kVirtioBlkIrqId, false);
        }
        break;
      case 0x070u:
        if (data == 0u) {
          virtio_blk_reset_transport_state();
        } else {
          virtio_status = static_cast<uint8_t>(data & 0xffu);
        }
        break;
      case 0x080u:
        virtio_queue_desc = (virtio_queue_desc & 0xffffffff00000000ull) |
                            static_cast<uint64_t>(data);
        break;
      case 0x084u:
        virtio_queue_desc = (virtio_queue_desc & 0x00000000ffffffffull) |
                            (static_cast<uint64_t>(data) << 32);
        break;
      case 0x090u:
        virtio_queue_avail = (virtio_queue_avail & 0xffffffff00000000ull) |
                             static_cast<uint64_t>(data);
        break;
      case 0x094u:
        virtio_queue_avail = (virtio_queue_avail & 0x00000000ffffffffull) |
                             (static_cast<uint64_t>(data) << 32);
        break;
      case 0x0a0u:
        virtio_queue_used = (virtio_queue_used & 0xffffffff00000000ull) |
                            static_cast<uint64_t>(data);
        break;
      case 0x0a4u:
        virtio_queue_used = (virtio_queue_used & 0x00000000ffffffffull) |
                            (static_cast<uint64_t>(data) << 32);
        break;
      default:
        break;
    }
  }

  void set_time_us(uint64_t t) {
    rtc_time_us = t;
    clint_mtime = t;
    service_uart_tx_empty_rearm();
  }

  bool timer_irq_pending() const { return clint_mtime >= clint_mtimecmp; }

  bool plic_source1_enabled() const {
    return ((plic_enable_m >> 1) & 0x1u) != 0u && plic_priority1 > plic_threshold_m;
  }

  bool plic_source1_eligible() const {
    return plic_pending1 && plic_source1_enabled() && !plic_claimed1;
  }

  // Combined request line for PLIC source 1. In triathlon.dts the ns8250 UART
  // is wired to source 1 (interrupts=<1>) and the VirtIO block device shares
  // the same source id (kVirtioBlkIrqId==1), so OR their request lines.
  bool plic_line1() const { return plic_source_pending1 || uart_irq_pending(); }

  void refresh_plic_pending() {
    if (plic_line1() && !plic_claimed1) {
      plic_pending1 = true;
    }
  }

  // Re-evaluate the UART's contribution to source 1 (called when IER changes).
  // Latches a pending interrupt while THRI is enabled; drops it once the driver
  // disables THRI, provided VirtIO is idle and the source is not in service.
  void update_uart_plic() {
    if (uart_irq_pending()) {
      refresh_plic_pending();
    } else if (!plic_source_pending1 && !plic_claimed1) {
      plic_pending1 = false;
    }
  }

  uint32_t plic_pending_bits() const { return plic_pending1 ? (1u << 1) : 0u; }

  void set_plic_source_pending(uint32_t source_id, bool pending) {
    if (source_id != 1u) return;
    plic_source_pending1 = pending;
    if (!pending) {
      // Keep the line asserted if the UART still requests source 1.
      if (!uart_irq_pending()) {
        plic_pending1 = false;
      }
      return;
    }
    refresh_plic_pending();
  }

  bool plic_irq_pending() const { return plic_source1_eligible(); }

  uint32_t plic_claim_peek() const { return plic_source1_eligible() ? 1u : 0u; }

  uint32_t plic_claim_read(uint32_t caller_addr = kPlicClaimCompleteM) {
    (void)caller_addr;
    if (!plic_source1_eligible()) return 0u;
    plic_pending1 = false;
    plic_claimed1 = true;
    return 1u;
  }

  void plic_complete_write(uint32_t data) {
    if (data != 1u) return;
    plic_claimed1 = false;
    refresh_plic_pending();
  }

  void write_word(uint32_t addr, uint32_t data) {
    uint32_t aligned = addr & ~0x3u;

    if (aligned == kClintMtimecmpLow) {
      clint_mtimecmp = (clint_mtimecmp & 0xFFFFFFFF00000000ull) | static_cast<uint64_t>(data);
      return;
    }
    if (aligned == kClintMtimecmpHigh) {
      clint_mtimecmp = (clint_mtimecmp & 0x00000000FFFFFFFFull) |
                       (static_cast<uint64_t>(data) << 32);
      return;
    }
    if (aligned == kClintMtimeLow) {
      clint_mtime = (clint_mtime & 0xFFFFFFFF00000000ull) | static_cast<uint64_t>(data);
      return;
    }
    if (aligned == kClintMtimeHigh) {
      clint_mtime = (clint_mtime & 0x00000000FFFFFFFFull) |
                    (static_cast<uint64_t>(data) << 32);
      return;
    }

    if (aligned == kPlicPriority1) {
      plic_priority1 = (data & 0x7u);
      return;
    }
    if (aligned == kPlicEnableM || aligned == kPlicEnableS) {
      plic_enable_m = data;
      return;
    }
    if (aligned == kPlicThresholdM || aligned == kPlicThresholdS) {
      plic_threshold_m = (data & 0x7u);
      return;
    }
    if (aligned == kPlicClaimCompleteM || aligned == kPlicClaimCompleteS) {
      plic_complete_write(data);
      return;
    }

    if (in_uart(aligned)) {
      for (uint32_t i = 0; i < 4; i++) {
        uart_write8(aligned + i, static_cast<uint8_t>((data >> (i * 8u)) & 0xffu));
      }
      return;
    }

    if (in_virtio_blk(aligned)) {
      virtio_mmio_write(aligned, data);
      return;
    }

    if (aligned >= kPlicBase && aligned < (kPlicBase + 0x04000000u)) {
      return;
    }

    if (in_bootrom(aligned)) {
      uint32_t idx = (aligned - kBootRomBase) >> 2;
      if (idx < bootrom_words.size()) {
        bootrom_words[idx] = data;
      }
      return;
    }

    if (!in_pmem(aligned)) return;
    uint32_t idx = (aligned - kPmemBase) >> 2;
    if (idx < pmem_words.size()) {
      if (fw_text_watch_enabled && in_fw_text_watch(aligned)) {
        fw_text_write_count++;
        fw_text_last_write_addr = aligned;
        fw_text_last_write_data = data;
      }
      pmem_words[idx] = data;
    }
  }

  void write_byte(uint32_t addr, uint8_t data) {
    if (in_uart(addr)) {
      uart_write8(addr, data);
      return;
    }
    if (in_virtio_blk(addr)) {
      uint32_t aligned = addr & ~0x3u;
      uint32_t shift = (addr & 0x3u) * 8u;
      uint32_t mask = 0xffu << shift;
      uint32_t cur = read_word(aligned);
      uint32_t next = (cur & ~mask) | (static_cast<uint32_t>(data) << shift);
      write_word(aligned, next);
      return;
    }
    if (!in_pmem(addr) && !in_bootrom(addr)) return;
    uint32_t aligned = addr & ~0x3u;
    uint32_t shift = (addr & 0x3u) * 8u;
    uint32_t mask = 0xffu << shift;
    uint32_t cur = read_word(aligned);
    uint32_t next = (cur & ~mask) | (static_cast<uint32_t>(data) << shift);
    write_word(aligned, next);
  }

  void write_half(uint32_t addr, uint16_t data) {
    bool lo_ok = in_pmem(addr) || in_bootrom(addr) || in_uart(addr) || in_virtio_blk(addr);
    bool hi_ok = in_pmem(addr + 1u) || in_bootrom(addr + 1u) || in_uart(addr + 1u) ||
                 in_virtio_blk(addr + 1u);
    if (!lo_ok || !hi_ok) return;
    if (in_uart(addr) || in_uart(addr + 1u)) {
      write_byte(addr, static_cast<uint8_t>(data & 0xffu));
      write_byte(addr + 1u, static_cast<uint8_t>((data >> 8) & 0xffu));
      return;
    }
    if (in_virtio_blk(addr) || in_virtio_blk(addr + 1u)) {
      write_byte(addr, static_cast<uint8_t>(data & 0xffu));
      write_byte(addr + 1u, static_cast<uint8_t>((data >> 8) & 0xffu));
      return;
    }
    uint32_t aligned = addr & ~0x3u;
    uint32_t shift = (addr & 0x3u) * 8u;
    uint32_t mask = 0xffffu << shift;
    uint32_t cur = read_word(aligned);
    uint32_t next = (cur & ~mask) | (static_cast<uint32_t>(data) << shift);
    write_word(aligned, next);
  }

  void write_store(uint32_t addr, uint32_t data, uint32_t op) {
    // Boot ROM is executable/read-only after initialization.
    if ((op == 7u && access_touches_bootrom(addr, 1u)) ||
        (op == 8u && access_touches_bootrom(addr, 2u)) ||
        (op == 9u && access_touches_bootrom(addr, 4u))) {
      return;
    }

    switch (op) {
      case 7u:
        write_byte(addr, static_cast<uint8_t>(data & 0xffu));
        break;
      case 8u:
        write_half(addr, static_cast<uint16_t>(data & 0xffffu));
        break;
      case 9u:
        write_word(addr, data);
        break;
      default:
        break;
    }
  }

  uint32_t read_word_common(uint32_t aligned) const {
    if (aligned == kRtcPortLow) return static_cast<uint32_t>(rtc_time_us & 0xFFFFFFFFu);
    if (aligned == kRtcPortHigh) return static_cast<uint32_t>((rtc_time_us >> 32) & 0xFFFFFFFFu);

    if (aligned == kClintMtimecmpLow) return static_cast<uint32_t>(clint_mtimecmp & 0xFFFFFFFFu);
    if (aligned == kClintMtimecmpHigh) return static_cast<uint32_t>((clint_mtimecmp >> 32) & 0xFFFFFFFFu);
    if (aligned == kClintMtimeLow) return static_cast<uint32_t>(clint_mtime & 0xFFFFFFFFu);
    if (aligned == kClintMtimeHigh) return static_cast<uint32_t>((clint_mtime >> 32) & 0xFFFFFFFFu);

    if (aligned == kPlicPriority1) return plic_priority1;
    if (aligned == kPlicPending) return plic_pending_bits();
    if (aligned == kPlicEnableM || aligned == kPlicEnableS) return plic_enable_m;
    if (aligned == kPlicThresholdM || aligned == kPlicThresholdS) return plic_threshold_m;
    if (aligned == kPlicClaimCompleteM || aligned == kPlicClaimCompleteS) return plic_claim_peek();

    if (in_virtio_blk(aligned)) return virtio_mmio_read(aligned);

    if (in_uart(aligned)) {
      uint32_t value = 0u;
      for (uint32_t i = 0; i < 4; i++) {
        value |= static_cast<uint32_t>(uart_peek8(aligned + i)) << (i * 8u);
      }
      return value;
    }

    if (in_bootrom(aligned)) {
      uint32_t idx = (aligned - kBootRomBase) >> 2;
      if (idx < bootrom_words.size()) {
        return bootrom_words[idx];
      }
      return 0u;
    }

    if (!in_pmem(aligned)) return 0u;
    uint32_t idx = (aligned - kPmemBase) >> 2;
    if (idx < pmem_words.size()) {
      return pmem_words[idx];
    }
    return 0u;
  }

  uint32_t read_word(uint32_t addr) {
    uint32_t aligned = addr & ~0x3u;
    if (aligned == kPlicClaimCompleteM || aligned == kPlicClaimCompleteS) return plic_claim_read(aligned);
    return read_word_common(aligned);
  }

  uint32_t read_word(uint32_t addr) const {
    uint32_t aligned = addr & ~0x3u;
    return read_word_common(aligned);
  }

  void fill_line(uint32_t line_addr, std::array<uint32_t, 8> &line) {
    for (int i = 0; i < 8; i++) {
      line[i] = read_word(line_addr + 4u * static_cast<uint32_t>(i));
    }
  }

  void write_line(uint32_t line_addr, const std::array<uint32_t, 8> &line) {
    for (int i = 0; i < 8; i++) {
      write_word(line_addr + 4u * static_cast<uint32_t>(i), line[i]);
    }
  }

  bool load_binary(const std::string &path, uint32_t base) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) {
      std::cerr << "Failed to open IMG: " << path << "\n";
      return false;
    }
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(ifs)),
                             std::istreambuf_iterator<char>());
    for (size_t i = 0; i < buf.size(); i += 4) {
      uint32_t word = 0;
      for (size_t b = 0; b < 4; b++) {
        if (i + b < buf.size()) {
          word |= static_cast<uint32_t>(buf[i + b]) << (8 * b);
        }
      }
      write_word(base + static_cast<uint32_t>(i), word);
    }
    return true;
  }

  bool load_words(const std::vector<uint32_t> &words, uint32_t base) {
    for (size_t i = 0; i < words.size(); i++) {
      write_word(base + static_cast<uint32_t>(i) * 4u, words[i]);
    }
    return true;
  }
};

struct ICacheModel {
  bool pending = false;
  int delay = 0;
  uint32_t miss_addr = 0;
  uint32_t miss_way = 0;
  bool refill_pulse = false;
  std::array<uint32_t, 8> line_words{};
  UnifiedMem *mem = nullptr;

  void reset() {
    pending = false;
    delay = 0;
    miss_addr = 0;
    miss_way = 0;
    refill_pulse = false;
  }

  template <typename Top>
  void drive(Top *top) {
    top->icache_miss_req_ready_i = 1;
    if (refill_pulse) {
      top->icache_refill_valid_i = 1;
      top->icache_refill_paddr_i = miss_addr;
      top->icache_refill_way_i = miss_way;
      for (int i = 0; i < 8; i++) top->icache_refill_data_i[i] = line_words[i];
    } else {
      top->icache_refill_valid_i = 0;
      top->icache_refill_paddr_i = 0;
      top->icache_refill_way_i = 0;
      for (int i = 0; i < 8; i++) top->icache_refill_data_i[i] = 0;
    }
  }

  template <typename Top>
  void observe(Top *top) {
    if (!top->rst_ni) {
      reset();
      return;
    }

    if (refill_pulse) {
      refill_pulse = false;
    }

    if (top->icache_miss_req_valid_o && top->icache_miss_req_ready_i) {
      pending = true;
      delay = 2;
      miss_addr = top->icache_miss_req_paddr_o;
      miss_way = top->icache_miss_req_victim_way_o;
      if (mem) mem->fill_line(miss_addr, line_words);
    }

    if (pending) {
      if (delay > 0) {
        delay--;
      } else if (top->icache_refill_ready_o) {
        refill_pulse = true;
        pending = false;
      }
    }
  }
};

struct DCacheModel {
  struct MissTxn {
    int delay = 0;
    uint32_t miss_addr = 0;
    uint32_t miss_way = 0;
    std::array<uint32_t, 8> line_words{};
  };

  std::deque<MissTxn> pending_q{};
  bool refill_pulse = false;
  MissTxn refill_txn{};
  UnifiedMem *mem = nullptr;

  void reset() {
    pending_q.clear();
    refill_pulse = false;
    refill_txn = MissTxn{};
  }

  template <typename Top>
  void drive(Top *top) {
    top->dcache_miss_req_ready_i = 1;
    top->dcache_wb_req_ready_i = 1;
    if (refill_pulse) {
      top->dcache_refill_valid_i = 1;
      top->dcache_refill_paddr_i = refill_txn.miss_addr;
      top->dcache_refill_way_i = refill_txn.miss_way;
      for (int i = 0; i < 8; i++) top->dcache_refill_data_i[i] = refill_txn.line_words[i];
    } else {
      top->dcache_refill_valid_i = 0;
      top->dcache_refill_paddr_i = 0;
      top->dcache_refill_way_i = 0;
      for (int i = 0; i < 8; i++) top->dcache_refill_data_i[i] = 0;
    }
  }

  template <typename Top>
  void observe(Top *top) {
    if (!top->rst_ni) {
      reset();
      return;
    }

    if (refill_pulse) {
      refill_pulse = false;
    }

    if (top->dcache_miss_req_valid_o && top->dcache_miss_req_ready_i) {
      MissTxn txn{};
      txn.delay = 2;
      txn.miss_addr = top->dcache_miss_req_paddr_o;
      txn.miss_way = top->dcache_miss_req_victim_way_o;
      if (mem) mem->fill_line(txn.miss_addr, txn.line_words);
      pending_q.push_back(txn);
    }

    for (auto &txn : pending_q) {
      if (txn.delay > 0) {
        txn.delay--;
      }
    }

    if (!pending_q.empty() && pending_q.front().delay == 0) {
      if (top->dcache_refill_ready_o) {
        refill_txn = pending_q.front();
        pending_q.pop_front();
        refill_pulse = true;
      }
    }

    if (top->dcache_wb_req_valid_o && top->dcache_wb_req_ready_i) {
      std::array<uint32_t, 8> wb_line{};
      for (int i = 0; i < 8; i++) wb_line[i] = top->dcache_wb_req_data_o[i];
      if (mem) mem->write_line(top->dcache_wb_req_paddr_o, wb_line);
    }
  }
};

// MMIO model: single-word uncached access (no cache-line fill).
// This avoids the side-effect problem where fill_line reads 8 consecutive
// words from device registers that have read-side-effects (PLIC claim, UART RX).
struct MmioModel {
  UnifiedMem *mem = nullptr;

  void reset() {}

  template <typename Top>
  void drive(Top *top) {
    // Always ready to accept MMIO requests
    top->mmio_req_ready_i = 1;

    if (top->mmio_req_valid_o) {
      uint32_t addr = top->mmio_req_addr_o;
      // Precise single-word read — NOT fill_line. The LSU MMIO path returns
      // this value directly, so present the addressed byte/halfword in low bits.
      uint32_t raw_data = mem->read_word(addr);
      uint32_t data = raw_data >> ((addr & 0x3u) * 8u);
      top->mmio_rsp_valid_i = 1;
      top->mmio_rsp_data_i  = data;
    } else {
      top->mmio_rsp_valid_i = 0;
      top->mmio_rsp_data_i  = 0;
    }
  }

  template <typename Top>
  void observe(Top *top) {
    (void)top; // Combinational response, nothing to observe
  }
};

struct MemSystem {
  UnifiedMem mem;
  ICacheModel icache;
  DCacheModel dcache;
  MmioModel mmio;

  void reset() {
    icache.reset();
    dcache.reset();
    mmio.reset();
  }

  template <typename Top>
  void drive(Top *top) {
    top->timer_irq_i = mem.timer_irq_pending() ? 1 : 0;
    top->ext_irq_i = mem.plic_irq_pending() ? 1 : 0;
    icache.drive(top);
    dcache.drive(top);
    mmio.drive(top);
  }

  template <typename Top>
  void observe(Top *top) {
    icache.observe(top);
    dcache.observe(top);
    mmio.observe(top);
  }
};

template <typename Top>
inline void tick(Top *top, MemSystem &mem, VerilatedVcdC *tfp,
                 vluint64_t &sim_time) {
  mem.drive(top);
  top->clk_i = 0;
  top->eval();
  if (top->dbg_sb_dcache_req_valid_o && top->dbg_sb_dcache_req_ready_o) {
    const uint32_t addr = top->dbg_sb_dcache_req_addr_o;
    if (!UnifiedMem::in_pmem(addr)) {
      const uint32_t data = top->dbg_sb_dcache_req_data_o;
      const uint32_t op = top->dbg_sb_dcache_req_op_o;
      mem.mem.write_store(addr, data, op);
    }
  }
#if VM_TRACE
  if (tfp) tfp->dump(sim_time++);
#endif
  top->clk_i = 1;
  top->eval();
#if VM_TRACE
  if (tfp) tfp->dump(sim_time++);
#endif
  mem.observe(top);
}

template <typename Top>
inline void reset(Top *top, MemSystem &mem, VerilatedVcdC *tfp,
                  vluint64_t &sim_time) {
  top->rst_ni = 0;
  mem.reset();
  for (int i = 0; i < 5; i++) tick(top, mem, tfp, sim_time);
  top->rst_ni = 1;
  for (int i = 0; i < 2; i++) tick(top, mem, tfp, sim_time);
}

}  // namespace npc
