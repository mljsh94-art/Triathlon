#!/usr/bin/env bash
# Shared helpers for npc/scripts/subshell verify scripts.

SUBSHELL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NPC_HOME="$(cd "$SUBSHELL_DIR/../.." && pwd)"
TRIATHLON_HOME="$(cd "$NPC_HOME/.." && pwd)"

MANDATORY_UNIT_CASES=(
  "tb_rob_exception|${NPC_HOME}/csrc/test/test_rob_exception.cpp"
  "tb_ftq|${NPC_HOME}/csrc/test/test_ftq.cpp"
  "tb_ibuffer|${NPC_HOME}/csrc/test/test_ibuffer.cpp"
  "tb_frontend|${NPC_HOME}/csrc/test/test_frontend.cpp"
  "tb_ifu_mmu|${NPC_HOME}/csrc/test/test_ifu_mmu.cpp"
  "tb_issue|${NPC_HOME}/csrc/test/test_issue.cpp"
)

OPTIONAL_UNIT_CASES=(
  "tb_backend|${NPC_HOME}/csrc/test/test_backend.cpp"
  "tb_lsu|${NPC_HOME}/csrc/test/test_lsu.cpp"
)

log_section() {
  echo "[verify] === $1 ==="
}

log_section_done() {
  echo "[verify] --- $1: done ---"
}

run_unit_tb() {
  local top="$1"
  local sim_main="$2"
  local label="${3:-$top}"
  local bin="$NPC_HOME/build/${top}"

  echo "[verify] unit ${label}: ASSERT=1 ${top}"
  make -C "$NPC_HOME" ASSERT=1 TOPNAME="$top" SIM_MAIN="$sim_main" -B -j"$(nproc)" >/dev/null
  set +e
  local out
  out="$("$bin" 2>&1)"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q '\[assert\]'; then
    echo "[PASS] unit ${label}"
    return 0
  fi
  echo "[FAIL] unit ${label} rc=$rc"
  echo "$out" | tail -8
  return 1
}
