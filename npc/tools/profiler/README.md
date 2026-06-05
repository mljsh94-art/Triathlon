# NPC Profiler Workflow

## One-command run

```bash
make -C npc profile-report
# 默认 ARCH=riscv32i-npc、CROSS_COMPILE=riscv64-unknown-elf-
```

Default output directory:

- `npc/build/profile/<timestamp>/dhrystone.json`
- `npc/build/profile/<timestamp>/coremark.json`
- `npc/build/profile/<timestamp>/summary.json`
- `npc/build/profile/<timestamp>/metadata.json`

Fixed output directory example:

```bash
# 从仓库根目录：可省略 PROFILE_OUT_DIR（自动时间戳目录）
make -C npc profile-report PROFILE_OUT_DIR=npc/build/profile/$(date +%Y%m%d-%H%M%S)

# 或固定 tag 目录（profile-baseline 等价于 PROFILE_TAG=baseline）
make -C npc profile-baseline
```

## Dashboard

```bash
make -C npc profile-dashboard
# open npc/build/profile/dashboard/index.html
```

## Clean and re-run

```bash
make -C npc profile-clean   # removes npc/build/profile/ entirely
make -C npc profile-baseline
make -C npc profile-report PROFILE_OUT_DIR=npc/build/profile/$(date +%Y%m%d-%H%M%S)
make -C npc profile-dashboard
```

`profile-dashboard` runs `build_index.py` then `build_dashboard.py` under `npc/build/profile/`.
Each run also gets a rendered `summary.html` (click **查看完整报告** on the dashboard).

## Compare two baselines

```bash
python3 npc/tools/profiler/compare_summary.py \
  --base npc/build/profile/baseline/summary.json \
  --current npc/build/profile/latest/summary.json
```

Thresholds:

- IPC drop: `>3%` warn, `>5%` fail
- CPI rise: `>3%` warn, `>5%` fail
- cycles rise (dhrystone/coremark): `>5%` warn, `>8%` fail
- key stall share rise (`frontend_empty`, `lsu_req_blocked`, `rob_backpressure`):
  `>5pp` warn, `>8pp` fail

Convenience gate script:

```bash
npc/scripts/check_perf_regression.sh \
  npc/build/profile/baseline \
  npc/build/profile/latest
```

## Single benchmark JSON (manual)

```bash
make -C npc sim IMG=path/to/dhrystone.bin DIFFTEST= \
  ARGS='--profile-json npc/build/out.json --progress=50000'
```

`--profile-json` enables profile collection and writes one benchmark JSON at sim exit.

## Notes

- Benchmark runs use `--profile-json` (no log parsing).
- Performance job uses `DIFFTEST=`; functional correctness is a separate flow.
- Fixed benchmarks: **dhrystone** and **coremark**.
