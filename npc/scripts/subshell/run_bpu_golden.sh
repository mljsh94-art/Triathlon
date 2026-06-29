#!/usr/bin/env bash
# BPU golden baseline: fixed IMG set with DiffTest + profile-json, compare dbg_bpu_* + cycles.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

ARCH=riscv32im-npc
CROSS_COMPILE="${CROSS_COMPILE:-riscv64-unknown-elf-}"
REF_SO="$NPC_HOME/ref/riscv32-spike-difftest.so"
GOLDEN_DIR="$NPC_HOME/scripts/golden"
BASELINE_JSON="$GOLDEN_DIR/bpu_baseline.json"
GOLDEN_PY="$GOLDEN_DIR/bpu_golden.py"
COREMARK="$TRIATHLON_HOME/am-kernels/benchmarks/coremark"
DHRYSTONE="$TRIATHLON_HOME/am-kernels/benchmarks/dhrystone"
BENCHMARKS=(coremark dhrystone)

UPDATE="${BPU_GOLDEN_UPDATE:-0}"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bpu-golden.XXXXXX")"
trap 'rm -rf "$RUN_DIR"' EXIT

fail=0

check_sim_run() {
  local label="$1"
  local log="$2"
  if grep -q '\*\*\*FAIL\*\*\*' "$log"; then
    echo "[FAIL] $label contains ***FAIL***"
    fail=1
    return
  fi
  if grep -q '\[difftest\] mismatch' "$log"; then
    echo "[FAIL] $label difftest mismatch"
    fail=1
    return
  fi
  if ! grep -q '\[profile-json\] wrote' "$log"; then
    echo "[FAIL] $label missing profile-json output"
    fail=1
    return
  fi
  echo "[PASS] $label sim + profile-json"
}

cd "$NPC_HOME"

log_section "Spike reference"
if [[ ! -f "$REF_SO" ]]; then
  echo "[verify-bpu-golden] building Spike difftest .so"
  make -C "$NPC_HOME/ref" -j"$(nproc)"
fi
if [[ ! -f "$REF_SO" ]]; then
  echo "[FAIL] missing Spike difftest .so: $REF_SO"
  exit 1
fi
log_section_done "Spike reference"

log_section "rebuild tb_triathlon (ASSERT off, DiffTest on)"
echo "[verify-bpu-golden] compiling tb_triathlon (may take a few minutes)..."
make -C "$NPC_HOME" ASSERT= TOPNAME=tb_triathlon -B -j"$(nproc)"
test -x "$NPC_HOME/build/tb_triathlon"
log_section_done "rebuild tb_triathlon"

log_section "build benchmark images"
make -C "$COREMARK" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" image
make -C "$DHRYSTONE" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" image
log_section_done "build benchmark images"

COREMARK_IMG="$COREMARK/build/coremark-${ARCH}.bin"
DHRYSTONE_IMG="$DHRYSTONE/build/dhrystone-${ARCH}.bin"

run_bench() {
  local label="$1"
  local img="$2"
  local json="$RUN_DIR/${label}.json"
  local log="$RUN_DIR/${label}.sim.log"
  local progress="$3"
  echo "[verify-bpu-golden] run ${label} (DiffTest + profile-json)"
  if ! make -C "$NPC_HOME" sim \
    IMG="$img" \
    ARGS="--profile-json ${json} --progress=${progress}" \
    > "$log" 2>&1; then
    echo "[FAIL] ${label} sim exit non-zero"
    tail -n 40 "$log"
    fail=1
    return
  fi
  check_sim_run "$label" "$log"
}

log_section "golden benchmark runs"
run_bench coremark "$COREMARK_IMG" 1000000
run_bench dhrystone "$DHRYSTONE_IMG" 50000
log_section_done "golden benchmark runs"

if [[ $fail -ne 0 ]]; then
  echo "[verify-bpu-golden] FAIL: simulation errors (logs in $RUN_DIR)"
  exit 1
fi

CURRENT_JSON="$RUN_DIR/bpu_current.json"
python3 "$GOLDEN_PY" merge --run-dir "$RUN_DIR" --benchmarks "${BENCHMARKS[@]}" --output "$CURRENT_JSON"

if [[ "$UPDATE" == "1" ]]; then
  cp "$CURRENT_JSON" "$BASELINE_JSON"
  echo "[verify-bpu-golden] updated baseline: $BASELINE_JSON"
  echo "[verify-bpu-golden] PASS (baseline refreshed)"
  exit 0
fi

if [[ ! -f "$BASELINE_JSON" ]]; then
  echo "[verify-bpu-golden] baseline missing: $BASELINE_JSON"
  echo "[verify-bpu-golden] run with BPU_GOLDEN_UPDATE=1 to generate it"
  exit 1
fi

if python3 "$GOLDEN_PY" diff "$BASELINE_JSON" "$CURRENT_JSON"; then
  echo "[verify-bpu-golden] PASS"
  exit 0
fi

echo "[verify-bpu-golden] FAIL"
exit 1
