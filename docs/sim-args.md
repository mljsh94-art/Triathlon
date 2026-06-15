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
| `--snapshot-dir <path>` | `build/snapshots` | snapshot 目录 |
| `--snapshot-keep K` | `3` | 保留 snapshot 数量 |
| `--snapshot-restore <path>` | 禁用 | 从 snapshot 恢复 |

## Simulation Snapshot

Snapshot 保存 Verilator savable 状态、C++ `MemSystem`、RF 影子、周期计数和 Spike REF。`ProfileCollector`、`SimObserver` 统计和 VCD 句柄不保存。

构建须 `SNAPSHOT=1`（`--savable --threads 1`）。默认 `--threads 2`。

```bash
make -C npc SNAPSHOT=1
make -C npc sim SNAPSHOT=1 IMG=../fw_combined.bin \
  ARGS='--snapshot-interval=1000000 --snapshot-keep=3 --progress=2000000'

make -C npc sim SNAPSHOT=1 IMG=../fw_combined.bin \
  ARGS='--snapshot-restore=build/snapshots/triathlon-12000000.snap \
        --commit-trace=12050000:12100000 --max-cycles=12150000'
```

磁盘格式：`TRSNAP1` v2（含 Spike `mscratch`/`sscratch`）。

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
| `[stwb]` | 同上 | Store Buffer 写 DCache |
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
make -C npc profile-report PROFILE_OUT_DIR=npc/build/profile/$(date +%Y%m%d-%H%M%S)
make -C npc sim IMG=.../test.bin ARGS='--commit-trace 100000:150000'
make -C npc sim DIFFTEST= IMG=../fw_combined.bin \
  ARGS='--max-cycles=2000000 --progress=500000 --linux-early-debug'
make -C npc sim DIFFTEST= IMG=~/rv32-linux/out/fw_payload.bin \
  ARGS='--boot-handoff --dtb ~/rv32-linux/out/npc.dtb \
        --virtio-blk-image ~/rv32-linux/out/rootfs.img \
        --firmware-load-base 0x80400000 --max-cycles=80000000'
make -C npc sim IMG=.../test.bin ARGS='--trace wave.vcd --max-cycles=50000'
```
