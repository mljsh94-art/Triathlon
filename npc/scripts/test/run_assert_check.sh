#!/usr/bin/env bash
# Phase 6 positive assert regression: ASSERT=1 unit TBs + full cpu-tests (no [assert] fatal).
set -u

NPC_HOME="$(cd "$(dirname "$0")/../.." && pwd)"
TRIATHLON_HOME="$(cd "$NPC_HOME/.." && pwd)"
CPU_TESTS="$TRIATHLON_HOME/am-kernels/tests/cpu-tests"

# top:sim_main pairs (required gate)
UNIT_CASES=(
  "tb_rob_exception|${NPC_HOME}/csrc/test/test_rob_exception.cpp"
  "tb_ibuffer|${NPC_HOME}/csrc/test/test_ibuffer.cpp"
  "tb_frontend|${NPC_HOME}/csrc/test/test_frontend.cpp"
  "tb_ifu_mmu|${NPC_HOME}/csrc/test/test_ifu_mmu.cpp"
  "tb_issue|${NPC_HOME}/csrc/test/test_issue.cpp"
)

# Known functional failures unrelated to ASSERT; run when ASSERT_CHECK_OPTIONAL=1
UNIT_OPTIONAL=(
  "tb_backend|${NPC_HOME}/csrc/test/test_backend.cpp"
  "tb_lsu|${NPC_HOME}/csrc/test/test_lsu.cpp"
)

unit_pass=0
unit_fail=0
cpu_ok=0

run_unit() {
  local top="$1"
  local sim_main="$2"
  local label="$3"
  local bin="$NPC_HOME/build/${top}"

  echo "[assert-check] unit ${label}: ASSERT=1 ${top}"
  make -C "$NPC_HOME" ASSERT=1 TOPNAME="$top" SIM_MAIN="$sim_main" -B -j"$(nproc)" >/dev/null
  set +e
  local out
  out="$("$bin" 2>&1)"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q '\[assert\]'; then
    echo "[PASS] unit ${label}"
    unit_pass=$((unit_pass + 1))
    return 0
  fi
  echo "[FAIL] unit ${label} rc=$rc"
  echo "$out" | tail -8
  unit_fail=$((unit_fail + 1))
  return 1
}

cd "$NPC_HOME"

echo "[assert-check] === required unit TBs (ASSERT=1) ==="
for entry in "${UNIT_CASES[@]}"; do
  top="${entry%%|*}"
  sim_main="${entry##*|}"
  run_unit "$top" "$sim_main" "$top" || true
done

if [[ "${ASSERT_CHECK_OPTIONAL:-0}" == "1" ]]; then
  echo "[assert-check] === optional unit TBs ==="
  for entry in "${UNIT_OPTIONAL[@]}"; do
    top="${entry%%|*}"
    sim_main="${entry##*|}"
    run_unit "$top" "$sim_main" "$top (optional)" || true
  done
fi

echo "[assert-check] rebuild tb_triathlon (ASSERT=1) after unit TBs"
make -C "$NPC_HOME" ASSERT=1 TOPNAME=tb_triathlon -B -j"$(nproc)" >/dev/null
test -x "$NPC_HOME/build/tb_triathlon"

echo "[assert-check] === cpu-tests (ARCH=riscv32im-npc, NPC_EXTRA=ASSERT=1) ==="
set +e
cpu_out="$(make -C "$CPU_TESTS" ARCH=riscv32im-npc NPC_EXTRA='ASSERT=1' run 2>&1)"
cpu_rc=$?
set -e
echo "$cpu_out" | tail -20

if echo "$cpu_out" | grep -q '\*\*\*FAIL\*\*\*'; then
  echo "[FAIL] cpu-tests contain failures"
elif [[ $cpu_rc -ne 0 ]]; then
  echo "[FAIL] cpu-tests make exit rc=$cpu_rc"
else
  echo "[PASS] cpu-tests"
  cpu_ok=1
fi

echo "[assert-check] unit pass=$unit_pass fail=$unit_fail cpu_ok=$cpu_ok"
if [[ $unit_fail -eq 0 && $cpu_ok -eq 1 ]]; then
  echo "[assert-check] PASS"
  exit 0
fi
exit 1
