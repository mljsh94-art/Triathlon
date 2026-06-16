#!/usr/bin/env bash
# ③ Program ASSERT gate: neg self-check + tb_triathlon + cpu-tests + benchmarks.
set -u

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

ARCH=riscv32im-npc
CROSS_COMPILE="${CROSS_COMPILE:-riscv64-unknown-elf-}"
CPU_TESTS="$TRIATHLON_HOME/am-kernels/tests/cpu-tests"
DHRYSTONE="$TRIATHLON_HOME/am-kernels/benchmarks/dhrystone"
COREMARK="$TRIATHLON_HOME/am-kernels/benchmarks/coremark"

fail=0

check_program_run() {
  local label="$1"
  shift
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/verify-assert-prog.XXXXXX")"

  run_streaming "$tmp" "$@"
  local rc=$RUN_STREAM_RC

  if grep -q '\*\*\*FAIL\*\*\*' "$tmp"; then
    echo "[FAIL] $label contains ***FAIL***"
    fail=1
  elif grep -q '\[assert\]' "$tmp"; then
    echo "[FAIL] $label triggered unexpected [assert]"
    fail=1
  elif [[ $rc -ne 0 ]]; then
    echo "[FAIL] $label exit rc=$rc"
    fail=1
  elif ! grep -q 'HIT GOOD TRAP' "$tmp"; then
    echo "[FAIL] $label missing HIT GOOD TRAP"
    fail=1
  else
    echo "[PASS] $label"
  fi
  rm -f "$tmp"
  log_section_done "$label"
}

cd "$NPC_HOME"

log_section "negative assert self-check (fail-fast)"
bash "$SUBSHELL_DIR/run_assert_neg.sh" || exit 1
log_section_done "negative assert self-check"

log_section "rebuild tb_triathlon (ASSERT=1)"
echo "[verify-assert-programs] compiling tb_triathlon with ASSERT=1..."
make -C "$NPC_HOME" ASSERT=1 TOPNAME=tb_triathlon -B -j"$(nproc)"
test -x "$NPC_HOME/build/tb_triathlon"
log_section_done "rebuild tb_triathlon (ASSERT=1)"

log_section "cpu-tests (ASSERT=1, DiffTest off)"
check_program_run "cpu-tests" \
  make -C "$CPU_TESTS" ARCH="$ARCH" NPC_EXTRA='ASSERT=1' NPC_DIFFTEST= run

log_section "dhrystone (ASSERT=1, DiffTest off)"
echo "[verify-assert-programs] building dhrystone image..."
make -C "$DHRYSTONE" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" image
check_program_run "dhrystone" \
  make -C "$DHRYSTONE" ARCH="$ARCH" NPC_EXTRA='ASSERT=1' NPC_DIFFTEST= run

log_section "coremark (ASSERT=1, DiffTest off)"
echo "[verify-assert-programs] building coremark image..."
make -C "$COREMARK" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" image
check_program_run "coremark" \
  make -C "$COREMARK" ARCH="$ARCH" NPC_EXTRA='ASSERT=1' NPC_DIFFTEST= run

if [[ $fail -eq 0 ]]; then
  echo "[verify-assert-programs] PASS"
  exit 0
fi
exit 1
