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

make -C npc profile-baseline
make -C npc profile-dashboard

make -C npc profile-clean

# 单 benchmark 手动 JSON
make -C npc sim DIFFTEST= IMG=.../dhrystone-riscv32i-npc.bin \
  ARGS='--profile-json npc/profile/out.json --progress=50000'
```

仿真失败时保留 `<run_id>/dhrystone.sim.log`、`<run_id>/coremark.sim.log`、`<run_id>/microbench.sim.log`。

改名后刷新看板：

```bash
python3 npc/tools/profiler/set_display_name.py \
  --run-dir npc/profile/20260605-164936 --display-name 'BPU修复v1'
make -C npc profile-dashboard
```
