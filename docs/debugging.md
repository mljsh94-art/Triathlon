# 调试与排障

## NDJSON 结构化日志（`debug-*.log`）

复杂 RTL/全系统 bug 排查时，除 stdout 上的 `[debug][...]` / `[linux-stage]` 外，使用 **NDJSON**（一行一个 JSON），便于按 `runId` / `hypothesisId` / `cycle` 关联证据。

### 文件位置

| 项 | 说明 |
|----|------|
| 默认路径 | 仓库根 `debug-<sessionId>.log` |
| 写入 | RTL `$fopen("../debug-....log","a")`；C++ `std::ofstream` |
| 运行目录 | 从 `npc/` 执行 `make sim`，日志落在仓库根 |
| stdout | NDJSON **不进** stdout |

### 典型字段

| 字段 | 含义 |
|------|------|
| `sessionId` | 会话 ID |
| `runId` | 主题（如 `ifu-ctrl-flow`） |
| `hypothesisId` | 假设编号 |
| `location` | 源文件位置 |
| `message` | 简短描述 |
| `timestamp` | 仿真 cycle |
| `data` | 结构化 payload |

### 排查流程

1. 每次复现前清空当前 session 的 log。
2. 修改插桩后 `make -C npc` 重编。
3. 先假设、再插桩、再跑。
4. `sim_*.log` 看里程碑；`debug-*.log` 看 cycle 级时序。
5. 验证通过前保留插桩。

```bash
make -C npc sim DIFFTEST= IMG=../fw_combined.bin \
  ARGS='--max-cycles=70000000 --progress=2000000 --linux-early-debug' \
  > npc/sim_debug.log 2>&1
```

长跑与断点恢复：`make -C npc SNAPSHOT=1` + `--snapshot-interval` / `--snapshot-restore`，见 [full-system.md](full-system.md#全系统仿真fw_combinedbin) 与 [sim-args.md](sim-args.md#simulation-snapshot)。

## `--linux-early-debug` 启动阶段

每个 stage 仅打印一次 `[linux-stage]`（含 cycle、pc、priv、satp 等）：

| stage | 含义 |
|-------|------|
| `opensbi-reset` | M-mode 复位 @ 0x80000000 |
| `opensbi-dtb-a0` | DTB 地址装入 a0 |
| `opensbi-init` | OpenSBI 主路径 |
| `opensbi-pre-jump` | 跳转 Linux 前 |
| `linux-handoff` | S-mode 物理入口 |
| `linux-head` / `linux-decompress` / `linux-gp-init` | head.S / 解压 / gp |
| `linux-dtb-a1` | Linux 收到 a1=DTB |
| `linux-mmu-enable` | 写 satp 开 SV32 |
| `linux-first-ipf` | 开 MMU 后首次 IPF |
| `linux-trap-redirect` / `linux-trap-vec` | fixmap trap |
| `linux-swap-pgdir` | trap 路径切页表 |
| `linux-vtext` | 内核高地址虚拟文本 |

实现：`npc/csrc/include/linux_boot_stage.h`、`npc/csrc/lib/sim_observer.cpp`。

页故障时额外输出 `[debug][sv32-fault-walk]`：按 `satp` 与 tval 只读 walk L1/L0 PTE。

## 相关 sim ARGS

详见 [sim-args.md](sim-args.md)：`--commit-trace`、`--bru-trace`、`--fe-trace`、`--stall-trace`、`--commit-ring`、`--snapshot-restore`。

DiffTest mismatch 时默认 dump 最近 64 条 commit（`--commit-ring`）。

## LSU / STQ 调试探针（`tb_triathlon`）

stall trace / profile 通过 `tb_triathlon` 暴露的层级信号观察 LSU；store 完成上报已并入 **`stq`**（`lsu_group` 内不再有 `store_wb_q`）。

| 探针 | 含义 |
|------|------|
| `dbg_lsu_store_wb_head_valid_o` | `stq` 最老「已准入、未上报 ROB」store 有待写回（≈ 原 store WB queue 非空） |
| `dbg_lsu_store_wb_head_rob_idx_o` | 上述 store 的 ROB tag |
| `dbg_lsu_sq_count_o` | `stq.st_unreported_count`（`executed && !reported` 条目数；名称保留自已删除的 SQ） |
| `dbg_lsu_sq_alloc_ready_o` | store 准入反压：`st_unreported_count < SB_DEPTH` 或 store WB 口本拍可排空 |
| `dbg_lsu_store_req_ready_o` | 同上，store 请求口 ready |

层级路径示例：`dut.u_backend.u_lsu_group.store_wb_head_valid`（别名，数据源为 `u_stq.st_wb_valid_o`）。
