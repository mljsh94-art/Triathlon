# 仿真器命令行参数（ARGS）

仿真主程序为 `npc/build/tb_triathlon`。参数解析见 `npc/csrc/lib/args_parser.cpp` 与 `npc/csrc/include/args_parser.h`。

## 传参方式

```bash
make -C npc sim IMG=/path/to/image.bin ARGS='--max-cycles=1000000 --progress=500000'
make -C npc sim DIFFTEST= IMG=/path/to/fw_combined.bin ARGS='--linux-early-debug'

./npc/build/tb_triathlon /path/to/image.bin --max-cycles=1000000
```

Makefile 拼装顺序：`ARGS` → DiffTest（`-d $(DIFFTEST_SO)`）→ `IMG`（positional，必需）。

## 参数一览

周期级 trace 与仿真结束 `--profile` **相互独立**，可任意组合。

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `<IMG>` | — | 镜像路径（positional，必需） |
| `--max-cycles N` | `600000000` | 最大周期；超时退出码 1 |
| `-d REF_SO` / `--difftest=REF_SO` | Makefile 注入 | Spike DiffTest；`DIFFTEST=` 禁用 |
| `--progress [N]` | 禁用；仅 `--progress` 时 `N=1000000` | 周期性 `[progress]` 心跳 |
| `--progress-verbose` | 禁用 | 详细 progress 快照 |
| `--trace [path]` | `npc.vcd` | VCD 波形；需 `VM_TRACE` 构建 |
| `--profile` | 禁用 | 结束时输出 `[commitm]`/`[stallm]` 等汇总 |
| `--profile-json <path>` | 禁用 | 写出 benchmark JSON |
| `--commit-trace [窗口]` | 禁用 | commit/LSU/store trace |
| `--commit-trace=START:END` | — | cycle `[START, END]` |
| `--commit-trace-start N` | `0` | trace 起始 cycle |
| `--commit-trace-end N` | `0`（无上限） | trace 结束 cycle |
| `--commit-ring N` | DiffTest 开时 `64` | mismatch 时 dump 最近 retire |
| `--bru-trace` | 禁用 | BRU/flush trace（无窗口限制） |
| `--fe-trace` | 禁用 | 取指校验 `[fe]` |
| `--stall-trace [N]` | 禁用；`N=200` | 无 commit stall 快照 |
| `--boot-handoff` | 禁用 | Boot ROM handoff 启动链 |
| `--dtb <path>` | 内置 FDT | handoff 下外部 DTB |
| `--firmware-load-base <addr>` | `0x80020000` | handoff 固件基址；推荐 `0x80400000` |
| `--virtio-blk-image <path>` | 无 | VirtIO 磁盘镜像 |
| `--linux-early-debug` | 禁用 | OpenSBI/Linux 启动调试 |
| `--snapshot-interval N` | `0` | 周期性 snapshot；需 `SNAPSHOT=1` |
| `--snapshot-dir <path>` | `snapshots` | snapshot 目录 |
| `--snapshot-keep K` | `3` | 保留 snapshot 数量 |
| `--snapshot-restore <path>` | 禁用 | 从 snapshot 恢复 |

说明：`make -C npc` 运行二进制时工作目录是 `npc/`，因此相对路径 `snapshots` 对应仓库中的 `npc/snapshots/`；不要在 ARGS 里再写 `npc/snapshots`，否则会落到 `npc/npc/snapshots/`。

## Simulation Snapshot

Snapshot 保存 Verilator savable 状态、C++ `MemSystem`、RF 影子、周期计数和 Spike REF。`ProfileCollector`、`SimObserver` 统计和 VCD 句柄不保存。

构建须 `SNAPSHOT=1`（Verilator `--savable --threads 1`）。默认构建为 `--threads 2`，与 Snapshot **不兼容**。

磁盘格式：`TRSNAP1` v2（含 Spike `mscratch`/`sscratch`）。实现见 `npc/csrc/lib/sim_snapshot.cpp`。

### 路径与工作目录

| 写法 | `make -C npc` 下实际目录 |
|------|--------------------------|
| `--snapshot-dir=snapshots`（推荐，默认） | 仓库 `npc/snapshots/` |
| `--snapshot-dir=npc/snapshots`（错误） | 仓库 `npc/npc/snapshots/` |
| `--snapshot-restore=snapshots/triathlon-25000000.snap` | 从 `npc/snapshots/` 读 |

`make -C npc sim` 会在 `npc/` 目录执行 `tb_triathlon`，相对路径均相对 **cwd=`npc/`**，不是仓库根。若历史上曾用旧路径 `build/snapshots` 保存，恢复时 `--snapshot-restore` 须写能命中该文件的路径（例如 `build/snapshots/triathlon-....snap`）。

### 适用场景

Snapshot 用于 **同一版 CPU 二进制** 下跳过重复仿真，不是“改 RTL 后接着跑”的 time machine：

- Linux 全系统长跑：每 N 百万 cycle 存盘，崩溃或手动停止后从最近 snap 继续，免重跑 OpenSBI 启动段。
- DiffTest 在极远 cycle 失败：从最近 snap 恢复，只跑失败点之前的一小段（配合 `--commit-trace` / `--commit-ring`）。
- **仅改 C++ 观测**（如 `npc_main` 打 NDJSON、`sim_observer`、profile 参数）：RTL 不变时，旧 snap 通常仍可恢复，恢复后继续打日志。

### 兼容性（能否从旧 snap 恢复）

恢复时有两层校验：

1. **C++ 元数据**（`snapshot_meta_matches`）：`IMG` 文件 hash、`boot_handoff`、`entry_pc`、`firmware_base`、DiffTest 是否开启须与保存时一致。
2. **Verilator DUT blob**：须与保存时 **同一 Verilator 模型**（RTL + 影响模型的编译选项一致）。

| 变更 | 能否用旧 snap |
|------|----------------|
| 仅 `npc/csrc/`（如 `npc_main` NDJSON），RTL 未动 | 通常 **可以** |
| 仅 CLI（`--progress`、`--commit-ring` 等） | **可以** |
| `npc/vsrc/` RTL 任意修改后重编 | **不可以** |
| `SNAPSHOT=0` ↔ `SNAPSHOT=1` | **不可以** |
| `ASSERT=0` ↔ `ASSERT=1`（会改变 Verilator 模型） | **不可以** |
| 更换 `fw_combined.bin` 或其它 `IMG` | **不可以**（img hash 不匹配） |
| 保存时开 DiffTest、恢复时 `DIFFTEST=`（或反之） | **不可以** |

改 RTL 后验证 bug 修复：须 **从头重跑**（或跑到目标 cycle 再存 **新** snap），不能指望改代码前的 snap 接到新二进制上。

### 常见错误

| 现象 | 原因 | 处理 |
|------|------|------|
| `Can't deserialize save-restore file as was made from different model` | snap 与当前 `tb_triathlon` 的 Verilator 模型不一致（常见：改 RTL 后重编） | 用当前二进制重跑并生成新 snap；或 checkout 生成 snap 时的 RTL 再恢复 |
| `[snapshot] restore metadata mismatch: IMG hash differs` | `IMG` 与保存时不一致 | 使用同一 `fw_combined.bin` |
| `[snapshot] restore metadata mismatch: difftest enable differs` | DiffTest 开关与保存时不一致 | 恢复命令与保存时同样是否写 `DIFFTEST=` |
| 找不到 snap 文件 | `--snapshot-dir` 多写了 `npc/` 前缀 | 改用 `snapshots`（默认） |
| mismatch 提示的 `nearest=...` 路径找不到 | 文档/命令用了错误相对路径 | 见上文「路径与工作目录」 |

### 通用 Snapshot 命令

```bash
# 须先 SNAPSHOT=1 编译
make -C npc SNAPSHOT=1

# 周期性保存（任意 IMG）
make -C npc sim SNAPSHOT=1 IMG=/path/to/image.bin \
  ARGS='--snapshot-interval=1000000 --snapshot-keep=3 --progress=2000000'

# 从快照恢复
make -C npc sim SNAPSHOT=1 IMG=/path/to/image.bin \
  ARGS='--snapshot-restore=snapshots/triathlon-12000000.snap \
        --commit-trace=12050000:12100000 --max-cycles=12150000'
```

### Linux 全系统 + DiffTest + Snapshot

使用 `fw_combined.bin` 整镜像加载（无 `--boot-handoff`）。完整前置与参数说明见 [full-system.md](full-system.md#全系统仿真fw_combinedbin)。

```bash
cd /mnt/d/sjj_ict2026/Triathlon

make -C npc/ref
make -C npc SNAPSHOT=1

make -C npc sim SNAPSHOT=1 \
  IMG=$PWD/fw_combined.bin \
  ARGS='--max-cycles=100000000 \
        --progress=2000000 \
        --linux-early-debug \
        --snapshot-interval=5000000 \
        --snapshot-dir=snapshots \
        --snapshot-keep=3'
```

不写 `DIFFTEST=` 即开启 Spike DiffTest（`.so` 存在时 Makefile 自动注入 `-d`）。恢复示例：

```bash
make -C npc sim SNAPSHOT=1 \
  IMG=$PWD/fw_combined.bin \
  ARGS='--snapshot-restore=snapshots/triathlon-5000000.snap \
        --max-cycles=100000000 --progress=2000000 --linux-early-debug'
```

## `--commit-trace` 窗口语法

| 写法 | 含义 |
|------|------|
| `--commit-trace` | 全周期 |
| `--commit-trace START:END` | cycle `[START, END]` |
| `--commit-trace START` | 单点 |
| `--commit-trace START END` | 两个 positional |
| `--commit-trace-start N` + `--commit-trace-end M` | 分别指定；`end=0` 无上限 |

## 镜像加载模式

| 模式 | 条件 | 行为 |
|------|------|------|
| 整镜像加载（默认） | 无 `--boot-handoff` | `<IMG>` → `0x80000000`；适用于 `fw_combined.bin` |
| Boot handoff | `--boot-handoff` | 固件加载到 `--firmware-load-base`；复位经 boot ROM stub |

## 输出 Tag 速查

| Tag | 触发 | 内容 |
|-----|------|------|
| `[commit]` | `--commit-trace` | ROB retire |
| `[stwb]` | 同上 | STQ 队头已提交 store 写 DCache（senior drain；与 store 完成上报 ROB 的专用 WB 口不同） |
| `[ldreq]`/`[ldrsp]` | 同上 | LSU load |
| `[flush]`/`[flushp]`/`[bru]` | commit-trace 或 `--bru-trace` | flush / 惩罚 / BRU |
| `[bruwb]` | `--bru-trace` | BRU writeback |
| `[fe]` | `--fe-trace` | 取指校验 |
| `[stall]` | `--stall-trace` | stall 快照 |
| `[commit-ring]` | DiffTest mismatch | 最近 retire 摘要 |
| `[progress]` | `--progress` | 心跳 |
| `[linux-stage]`/`[debug][...]` | `--linux-early-debug` | 启动里程碑 / 细粒度日志 |
| `[commitm]` 等 | `--profile` | 结束汇总 |
| `HIT GOOD/BAD TRAP` | — | AM ebreak 结果 |

linux-stage 阶段表见 [debugging.md](debugging.md)。

## 常用组合

```bash
make -C npc profile-report PROFILE_OUT_DIR=npc/profile/$(date +%Y%m%d-%H%M%S)
make -C npc sim IMG=.../test.bin ARGS='--commit-trace 100000:150000'

# Linux 全系统 + DiffTest + Snapshot（fw_combined.bin，详见 full-system.md）
make -C npc sim SNAPSHOT=1 IMG=$PWD/fw_combined.bin \
  ARGS='--max-cycles=100000000 --progress=2000000 --linux-early-debug \
        --snapshot-interval=5000000 --snapshot-dir=snapshots --snapshot-keep=3'

# Linux 快速调试（关 DiffTest）
make -C npc sim DIFFTEST= IMG=$PWD/fw_combined.bin \
  ARGS='--max-cycles=2000000 --progress=500000 --linux-early-debug'

make -C npc sim IMG=.../test.bin ARGS='--trace wave.vcd --max-cycles=50000'
```
