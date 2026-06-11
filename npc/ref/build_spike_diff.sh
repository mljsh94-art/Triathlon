#!/usr/bin/env bash
# Build Spike rv32imac difftest reference library and run smoke test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "[build_spike_diff] building Spike + riscv32-spike-difftest.so ..."
make -j"$(nproc)"

echo "[build_spike_diff] running smoke test ..."
make check

echo "[build_spike_diff] OK: $ROOT/riscv32-spike-difftest.so"
