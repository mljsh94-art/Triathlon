# OpenSBI + Linux 全系统仿真

`merge.py` 生成 **OpenSBI + Linux Kernel Image + DTB**，不是 `echo_payload/payload.bin`。OpenSBI 经 `FW_JUMP_ADDR=0x80400000` 跳转 Linux，`FW_JUMP_FDT_ADDR=0x83F00000` 传 DTB 给 Linux `a1`。设备树报告 **64MB** 可见内存（`0x80000000`–`0x83FFFFFF`）。

## 内存布局（`fw_combined.bin`）

| 组件 | 物理地址 | 来源 |
|------|----------|------|
| OpenSBI | `0x80000000` | `opensbi/build/platform/triathlon/firmware/fw_jump.bin` |
| Linux Image | `0x80400000` | `linux_workspace/linux/arch/riscv/boot/Image` |
| DTB | `0x83F00000` | `linux_workspace/build/triathlon.dtb` |

仿真器加载到 `0x80000000`（`kPmemBase`）。成功标志：OpenSBI banner 中 `Domain0 Next Arg1 : 0x83f00000`。

## OpenSBI 平台（`opensbi/platform/triathlon/`）

| 文件 | 作用 |
|------|------|
| `objects.mk` | `FW_JUMP_ADDR` / `FW_JUMP_FDT_ADDR` |
| `platform.c` | PLIC / CLINT / UART |
| `triathlon.dts` | 设备树 |
| `configs/defconfig` | `CONFIG_PLATFORM_TRIATHLON=y` |

PLIC 仅暴露 S-mode external context，与仿真平台单 context 布局一致。

`objects.mk` 关键项：

```makefile
PLATFORM_RISCV_XLEN = 32
FW_JUMP=y
FW_JUMP_ADDR=0x80400000
FW_JUMP_FDT_ADDR=0x83F00000
```

修改跳转地址后须重编 OpenSBI 并重跑 `merge.py`。

## 工具链

| 用途 | 前缀 | 说明 |
|------|------|------|
| OpenSBI | `riscv64-linux-gnu-` | 需 PIE |
| echo_payload / 裸机 | `riscv64-unknown-elf-` | 不能用于 OpenSBI |
| Verilator | 宿主机 g++ 5.008 | 见 `npc/Makefile` |
| DTB（可选） | `dtc` | 无则 merge 用内置 DTB |

## 何时重编

| 修改 | 重编 | merge |
|------|------|-------|
| `objects.mk` | OpenSBI | 是 |
| `triathlon.dts` | —（merge 编 DTB） | 是 |
| `platform.c` | OpenSBI | 是 |
| Linux 源码/.config | Image | 是 |
| RTL / npc/csrc | `make -C npc` | 否 |

## 编译命令

```bash
# OpenSBI
make -C opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-

# Linux（工作树 linux_workspace/linux/，CONFIG_32BIT=y）
make -C linux_workspace/linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) Image
# 或 ./linux_workspace/build_kernel.sh

# 合并
python3 linux_workspace/merge.py
```

## 全系统仿真（`fw_combined.bin`）

镜像为整包加载（默认模式，**不用** `--boot-handoff`）：`<IMG>` 写入 `0x80000000`。详见 [sim-args.md](sim-args.md) 镜像加载模式。

### 前置

```bash
cd /mnt/d/sjj_ict2026/Triathlon   # 仓库根，WSL 下执行

# Spike DiffTest 库（首次或 ref 变更后）
make -C npc/ref

# 全系统镜像（首次或 OpenSBI/Linux/merge 变更后）
python3 linux_workspace/merge.py
```

DiffTest 在 `npc/ref/riscv32-spike-difftest.so` 存在时 **默认开启**；须关闭时显式写 `DIFFTEST=`。

### 带 Snapshot 编译

Snapshot 须 `SNAPSHOT=1` 构建（Verilator `--savable --threads 1`，比默认 `--threads 2` 慢）。改 RTL 后须重编。

```bash
make -C npc SNAPSHOT=1
```

### DiffTest + Snapshot 长跑 Linux

```bash
make -C npc sim SNAPSHOT=1 \
  IMG=$PWD/fw_combined.bin \
  ARGS='--max-cycles=100000000 \
        --progress=2000000 \
        --linux-early-debug \
        --snapshot-interval=5000000 \
        --snapshot-dir=snapshots \
        --snapshot-keep=3'
```

| 参数 | 说明 |
|------|------|
| 不写 `DIFFTEST=` | 开启 Spike lockstep（默认） |
| `SNAPSHOT=1` | 编译与运行均需；否则 snapshot 相关 ARGS 无效 |
| `--snapshot-interval` | 周期性保存；`0` 表示禁用 |
| `--snapshot-dir` | 快照目录，默认 `snapshots`；在 `make -C npc` 下实际位于仓库的 `npc/snapshots` |
| `--linux-early-debug` | 打印 `[linux-stage]` 启动里程碑（可选） |

Snapshot 格式、路径与兼容性详见 [sim-args.md](sim-args.md#simulation-snapshot)。

### 从 Snapshot 恢复继续跑

```bash
make -C npc sim SNAPSHOT=1 \
  IMG=$PWD/fw_combined.bin \
  ARGS='--snapshot-restore=snapshots/triathlon-5000000.snap \
        --max-cycles=100000000 \
        --progress=2000000 \
        --linux-early-debug'
```

将 `triathlon-5000000.snap` 换为 `npc/snapshots/` 下实际文件名（ARGS 里写 `snapshots/...` 即可）。

### Snapshot 使用注意（Linux 长跑）

- **改 RTL 后**：旧 snap **不能** 用于新 `tb_triathlon`（Verilator 报 `different model`）。修复 backend/frontend 后须从头跑，或跑到目标 cycle 再存新 snap。
- **只改 C++ 调试**（如 `npc_main` 写 NDJSON、`--linux-early-debug`）：RTL 与 `SNAPSHOT=1` 构建不变时，可从已有 snap 继续，免重跑数千万 cycle 启动段。
- **路径**：`make -C npc` 的 cwd 是 `npc/`，默认 `--snapshot-dir=snapshots` → 仓库 `npc/snapshots/`；勿写 `npc/snapshots`（会落到 `npc/npc/snapshots/`）。
- **IMG 与 DiffTest**：恢复时须与保存 snap 时相同的 `fw_combined.bin` 和 DiffTest 开关（默认开 Spike，关则写 `DIFFTEST=`）。

典型工作流：先 `SNAPSHOT=1` 长跑并 `--snapshot-interval=5000000` 存盘 → difftest 在远 cycle 失败 → 仅加 C++ 日志 → 从最近 snap restore → 短跑复现；若改了 RTL，则放弃旧 snap，重新长跑。

### 快速调试（关闭 DiffTest）

启动阶段仅看 RTL 日志、暂不 lockstep 时：

```bash
make -C npc sim DIFFTEST= IMG=$PWD/fw_combined.bin \
  ARGS='--max-cycles=100000000 --progress=1000000 --linux-early-debug'
```

启动阶段表与 NDJSON 排障见 [debugging.md](debugging.md)。

## merge.py 常量

须与 `objects.mk` 中 `FW_JUMP_*` 一致：

| 变量 | 值 |
|------|-----|
| `PMEM_BASE` | `0x80000000` |
| `LINUX_LOAD_ADDR` | `0x80400000` |
| `DTB_LOAD_ADDR` | `0x83F00000` |
| `LINUX_VISIBLE_MEM_SIZE` | `0x04000000`（64MB） |

## Linux 关键 Kconfig

| 选项 | 值 | 说明 |
|------|-----|------|
| `CONFIG_32BIT` | `y` | RV32 内核 |
| `CONFIG_PAGE_OFFSET` | `0xC0000000` | 内核虚拟基址 |
| `CONFIG_RISCV_ISA_C` | `y` | RVC |
| `CONFIG_INITRAMFS_SOURCE` | `../rootfs ../rootfs_extra.list` | 内置 initramfs |

启动参数常用：`earlycon=sbi console=ttyS0 root=/dev/ram0`。

`build_kernel.sh` 用 `allnoconfig` + `.triathlon_min.config` 生成最小配置；`rootfs_extra.list` 注入 `/proc`、`/sys`、`/dev/console`。

## Linux 非对齐访问临时补丁

Linux `check_unaligned_access()` 可能触发 `load address misaligned` panic。可在 `linux_workspace/linux/arch/riscv/kernel/cpufeature.c` 临时 bypass：直接标记 `RISCV_HWPROBE_MISALIGNED_SLOW` 并返回。RTL 稳定后应恢复原始逻辑。

## echo_payload（可选）

`echo_payload/` 为轻量 S-mode 测试，**不参与** `merge.py`。单独验证须手动拼接或改 merge 流程，链接地址 `0x80400000`。

## 流程摘要

1. 编译 OpenSBI → 确认 `FW_JUMP_*` 与 merge 一致  
2. 编译 Linux Image → `CONFIG_32BIT=y`  
3. `python3 linux_workspace/merge.py` → `fw_combined.bin`  
4. `make -C npc/ref` → 构建 DiffTest `.so`（默认启用 lockstep）  
5. 长跑：`make -C npc SNAPSHOT=1` 后按上文 **DiffTest + Snapshot** 命令仿真（ARGS 见 [sim-args.md](sim-args.md)）

人类可读快速上手见根目录 [README.md](../README.md)。
