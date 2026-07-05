# Profile 性能采集与看板

工具目录 `npc/tools/profiler/`（详见 [npc/tools/profiler/README.md](../npc/tools/profiler/README.md)）。固定 benchmark：**dhrystone**、**coremark**、**microbench**（`mainargs=test`）；采集时 `DIFFTEST=` 禁用协同仿真。

## 数据流

```
run_profile.sh → make sim --profile-json → <run_id>/dhrystone.json、coremark.json、microbench.json
  → merge_profile_json.py → summary.json
  → finalize_run.py → metadata.json
  → build_index.py → index.json
  → build_dashboard.py → dashboard/index.html + <run_id>/summary.html
```

## 目录约定

每次采集写入 **`npc/profile/<run_id>/`** 子目录。省略 `PROFILE_OUT_DIR` 时自动使用 `npc/profile/<timestamp>/`。

| 路径 | 说明 |
|------|------|
| `<run_id>/dhrystone.json`、`<run_id>/coremark.json`、`<run_id>/microbench.json` | 单 benchmark JSON |
| `<run_id>/summary.json` | 聚合指标（CI/回归对比主接口） |
| `<run_id>/summary.html` | 可读报告页 |
| `<run_id>/metadata.json` | `run_id`、`git_sha`、`created_at` 等 |
| `index.json` | 历次 run 索引 |
| `dashboard/index.html` | 静态 HTML 看板 |

`index.json`、看板 HTML 及 JSON 内路径为生成时机器的绝对路径；换机器后需重新 `profile-report` / `profile-dashboard`。

## 常用命令

在**仓库根目录**、**WSL/Linux bash** 下执行（`$(date ...)` 勿在 PowerShell 直接展开）：

```bash
make -C npc profile-report
make -C npc profile-report PROFILE_OUT_DIR=npc/profile/$(date +%Y%m%d-%H%M%S)
# 自定义目录名与看板标签：npc/profile/<name>-<timestamp>/，看板显示 <name>
make -C npc profile-report PROFILE_NAME=FTBupdate

make -C npc profile-baseline
make -C npc profile-dashboard

make -C npc profile-clean

# 单 benchmark 手动 JSON
make -C npc sim DIFFTEST= IMG=.../dhrystone-riscv32i-npc.bin \
  ARGS='--profile-json npc/profile/out.json --progress=50000'
```

仿真失败时保留 `<run_id>/dhrystone.sim.log`、`<run_id>/coremark.sim.log`、`<run_id>/microbench.sim.log`。

## summary.json schema v2

`summary.json` 根对象含 `schema_version: 2`；每个 benchmark 按层级组织（由 `profile_collector_json.cpp` 输出，`merge_profile_json.py` 合并）：

| 区块 | 内容 |
|------|------|
| `meta` | 采集口径、`log_path`、质量标记 |
| `kpi` | `ipc` / `cpi` / `cycles` / `commits` |
| `commit` | `width_hist` 提交宽度分布 |
| `flush` | 冲刷次数、误预测分类、`redirect`、原因直方图 |
| `flush.mispredict_diag.detail` | TAGE 方向错与 FTB 结构桶的 PC/类型/slot 细分；`ftb_hit_shadowed_cond_nt` 表示前置 cond 判 NT 后被后续 taken 候选遮住 |
| `stall` | `category` 八大类 + `decode_blocked` / `rob_backpressure` / `frontend_empty` / `other` 明细 |
| `frontend` | `ifu_fq` Fetch Queue |
| `control` | 控制流指令统计 |
| `predict` | 分支预测（含 `ftb` / `ittage` / `cond_provider`） |
| `dbg_bpu` | 原始 BPU 计数器（与 `tb_triathlon` 的 `dbg_bpu_*_o` 对应；供 golden baseline 抽取） |
| `diagnostics` | 诊断扩展；`cond_provider_lane_top` 按 PC/provider/lane 汇总条件分支 selected/correct/miss/override |
| `hotspots` | `top_pc` / `top_inst` / BPU 热点 |

旧版扁平字段（v1）仍可通过 `npc/tools/profiler/profile_schema.py` 访问器读取；看板与回归脚本自动兼容。

LSU load 等 DCache ready 的 stall 明细会区分 refill、pending load、MSHR、DCache state 与 store drain：`*_store_drain_*` 表示 DCache 当前锁存请求确认为 store；`*_store_waiting_not_cause` 表示 store 端同周期 valid/!ready，但不是 load 被阻塞的直接归因。

BPU 重构 **行为 golden**（cycles + `dbg_bpu` 逐字段 diff）见 [bpu-refactor.md](bpu-refactor.md)，与本文性能 profile 互补。

`summary.html` 报告按 **KPI → Flush → Stall → Predict → Hotspots** 分区展示；dashboard Run Details 显示 Top stall 与 decode_blocked 前列。

改名后刷新看板：

```bash
python3 npc/tools/profiler/set_display_name.py \
  --run-dir npc/profile/20260605-164936 --display-name 'BPU修复v1'
make -C npc profile-dashboard
```
