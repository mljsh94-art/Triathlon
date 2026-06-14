#!/usr/bin/env bash
# ① Positive unit TB assert gate (no program tests, no neg).
set -u

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

MODULE="${1:-all}"
unit_pass=0
unit_fail=0

run_case_entry() {
  local entry="$1"
  local label="$2"
  local top="${entry%%|*}"
  local sim_main="${entry##*|}"
  if run_unit_tb "$top" "$sim_main" "$label"; then
    unit_pass=$((unit_pass + 1))
  else
    unit_fail=$((unit_fail + 1))
  fi
}

run_case_list() {
  local section="$1"
  shift
  log_section "$section"
  for entry in "$@"; do
    run_case_entry "$entry" "${entry%%|*}"
  done
  log_section_done "$section"
}

cd "$NPC_HOME"

case "$MODULE" in
  all)
    run_case_list "required unit TBs (ASSERT=1)" "${MANDATORY_UNIT_CASES[@]}"
    if [[ "${ASSERT_CHECK_OPTIONAL:-0}" == "1" ]]; then
      run_case_list "optional unit TBs" "${OPTIONAL_UNIT_CASES[@]}"
    fi
    ;;
  rob)
    run_case_list "module=rob" "${MANDATORY_UNIT_CASES[0]}"
    ;;
  fe)
    run_case_list "module=fe" "${MANDATORY_UNIT_CASES[@]:1:4}"
    ;;
  issue)
    run_case_list "module=issue" "${MANDATORY_UNIT_CASES[4]}"
    ;;
  lsu)
    run_case_list "module=lsu" "${OPTIONAL_UNIT_CASES[1]}"
    ;;
  *)
    echo "[verify] unknown MODULE=$MODULE (expected all|rob|fe|issue|lsu)" >&2
    exit 1
    ;;
esac

echo "[verify] unit pass=$unit_pass fail=$unit_fail"
if [[ $unit_fail -eq 0 ]]; then
  echo "[verify-unit] PASS"
  exit 0
fi
exit 1
