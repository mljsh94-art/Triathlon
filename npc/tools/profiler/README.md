# NPC Profiler Workflow

## One-command run

```bash
make -C npc profile-report
# 默认 CROSS_COMPILE=riscv64-unknown-elf-；AM 架构固定 riscv32im-npc
```

Default output directory:

- `npc/profile/<timestamp>/dhrystone.json`
- `npc/profile/<timestamp>/coremark.json`
- `npc/profile/<timestamp>/microbench.json`
- `npc/profile/<timestamp>/summary.json`
- `npc/profile/<timestamp>/metadata.json`

Fixed output directory example:

```bash
# 从仓库根目录：可省略 PROFILE_OUT_DIR（自动时间戳目录）
make -C npc profile-report PROFILE_OUT_DIR=npc/profile/$(date +%Y%m%d-%H%M%S)

# 或固定 tag 目录（profile-baseline 等价于 PROFILE_TAG=baseline）
make -C npc profile-baseline
```

## Dashboard

```bash
make -C npc profile-dashboard
# open npc/profile/dashboard/index.html
```

## Clean and re-run

```bash
make -C npc profile-clean   # removes npc/profile/ entirely
make -C npc profile-baseline
make -C npc profile-report PROFILE_OUT_DIR=npc/profile/$(date +%Y%m%d-%H%M%S)
make -C npc profile-dashboard
```

`profile-dashboard` runs `build_index.py` then `build_dashboard.py` under `npc/profile/`.
Each run also gets a rendered `summary.html` (click **查看完整报告** on the dashboard).

## Custom run name (directory + dashboard)

```bash
# One variable: npc/profile/FTBupdate-<timestamp>/ + dashboard label "FTBupdate"
make -C npc profile-report PROFILE_NAME=FTBupdate
make -C npc profile-dashboard

# Or set directory and label separately
make -C npc profile-report PROFILE_OUT_DIR=npc/profile/my-run \
  PROFILE_DISPLAY_NAME='BPU修复v1'
```

## Rename dashboard labels

Chart/table labels use `display_name` from `metadata.json` (falls back to directory name).

```bash
# At collection time (alias of PROFILE_OUT_DIR + PROFILE_DISPLAY_NAME)
make -C npc profile-report PROFILE_NAME=BPU修复v1

# Rename an existing run, then refresh dashboard
python3 npc/tools/profiler/set_display_name.py \
  --run-dir npc/profile/20260605-164936 \
  --display-name 'BPU修复v1'
make -C npc profile-dashboard
```

Or edit `metadata.json` manually: add `"display_name": "你的名称"` (keep `run_id` as the directory name).

## Compare two baselines

```bash
python3 npc/tools/profiler/compare_summary.py \
  --base npc/profile/baseline/summary.json \
  --current npc/profile/latest/summary.json
```

Thresholds:

- IPC drop: `>3%` warn, `>5%` fail
- CPI rise: `>3%` warn, `>5%` fail
- cycles rise (dhrystone/coremark/microbench): `>5%` warn, `>8%` fail
- key stall share rise (`frontend_empty`, `lsu_req_blocked`, `rob_backpressure`):
  `>5pp` warn, `>8pp` fail

Regression compare: diff `summary.json` between baseline and latest run dirs, or use `make -C npc profile-dashboard`.

## Single benchmark JSON (manual)

```bash
make -C npc sim IMG=path/to/dhrystone.bin DIFFTEST= \
  ARGS='--profile-json npc/build/out.json --progress=50000'
```

`--profile-json` enables profile collection and writes one benchmark JSON at sim exit.

## Notes

- Benchmark runs use `--profile-json` (no log parsing).
- Performance job uses `DIFFTEST=`; functional correctness is a separate flow.
- Fixed benchmarks: **dhrystone**, **coremark**, and **microbench** (`mainargs=test`, overridable via `MICROBENCH_MAINARGS`).
