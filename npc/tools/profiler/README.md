# NPC Profiler Workflow

## One-command run

```bash
make -C npc profile-report ARCH=riscv32i-npc CROSS_COMPILE=riscv64-elf-
```

Default output directory:

- `npc/build/profile/<timestamp>/summary.json`
- `npc/build/profile/<timestamp>/report.md`
- raw logs: `dhrystone.log`, `coremark.log`, `coremark_commit_sample.log`

If you want a fixed output directory (for example `latest`), override it:

```bash
make -C npc profile-report ARCH=riscv32i-npc CROSS_COMPILE=riscv64-elf- \
  PROFILE_OUT_DIR=$(pwd)/npc/build/profile/latest
```

## Parse existing logs only

```bash
make -C npc profile-parse PROFILE_OUT_DIR=/abs/path/to/profile-dir
```

## Compare two baselines

```bash
python3 npc/tools/profiler/compare_summary.py \
  --base npc/build/profile/20260224-133934/summary.json \
  --current npc/build/profile/20260225-115408/summary.json
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
  npc/build/profile/20260224-133934 \
  npc/build/profile/20260225-115408
```

## Notes

- This workflow does not modify CPU behavior; it only runs benchmarks and parses logs.
- `coremark_commit_sample.log` uses `--max-cycles=2000000` for manageable commit-trace size.
