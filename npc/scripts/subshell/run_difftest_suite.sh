#!/usr/bin/env bash
# ② DiffTest regression: Spike smoke + cpu-tests + dhrystone/coremark (ASSERT off).
set -u

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

ARCH=riscv32im-npc
CROSS_COMPILE="${CROSS_COMPILE:-riscv64-unknown-elf-}"
CPU_TESTS="$TRIATHLON_HOME/am-kernels/tests/cpu-tests"
DHRYSTONE="$TRIATHLON_HOME/am-kernels/benchmarks/dhrystone"
COREMARK="$TRIATHLON_HOME/am-kernels/benchmarks/coremark"
REF_SO="$NPC_HOME/ref/riscv32-spike-difftest.so"

fail=0

check_difftest_run() {
  local label="$1"
  shift
  set +e
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  set -e

  if echo "$out" | grep -q '\*\*\*FAIL\*\*\*'; then
    echo "[FAIL] $label contains ***FAIL***"
    fail=1
  elif echo "$out" | grep -q '\[difftest\] mismatch'; then
    echo "[FAIL] $label difftest mismatch"
    fail=1
  elif [[ $rc -ne 0 ]]; then
    echo "[FAIL] $label exit rc=$rc"
    fail=1
  else
    echo "[PASS] $label"
  fi
  echo "$out"
  log_section_done "$label"
}

cd "$NPC_HOME"

log_section "Spike reference smoke"
if [[ ! -f "$REF_SO" ]]; then
  echo "[verify-difftest] building Spike difftest .so"
  make -C "$NPC_HOME/ref" -j"$(nproc)"
fi
make -C "$NPC_HOME/ref" check
log_section_done "Spike reference smoke"

log_section "rebuild tb_triathlon (ASSERT off, DiffTest on)"
make -C "$NPC_HOME" ASSERT= TOPNAME=tb_triathlon -B -j"$(nproc)" >/dev/null
test -x "$NPC_HOME/build/tb_triathlon"
log_section_done "rebuild tb_triathlon"

log_section "cpu-tests (DiffTest on)"
check_difftest_run "cpu-tests" \
  make -C "$CPU_TESTS" ARCH="$ARCH" run

log_section "dhrystone (DiffTest on)"
make -C "$DHRYSTONE" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" image >/dev/null
check_difftest_run "dhrystone" \
  make -C "$DHRYSTONE" ARCH="$ARCH" run

log_section "coremark (DiffTest on)"
make -C "$COREMARK" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" image >/dev/null
check_difftest_run "coremark" \
  make -C "$COREMARK" ARCH="$ARCH" run

if [[ $fail -eq 0 ]]; then
  echo "[verify-difftest] PASS"
  exit 0
fi
exit 1
