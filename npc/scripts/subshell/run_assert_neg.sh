#!/usr/bin/env bash
# Phase 5 negative self-check: each case must abort with the expected [assert] tag.
set -u

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

NEG_MAIN="$NPC_HOME/csrc/test/test_rob_assert_neg.cpp"
BIN="$NPC_HOME/build/tb_rob_exception"

cd "$NPC_HOME"

log_section "build tb_rob_exception (ASSERT=1, neg driver)"
make ASSERT=1 TOPNAME=tb_rob_exception SIM_MAIN="$NEG_MAIN" -B -j"$(nproc)"
test -x "$BIN"
log_section_done "build tb_rob_exception (ASSERT=1, neg driver)"

log_section "negative assert cases"
cases=(
  "1:rob/dispatch_while_full"
  "2:rob/wb_to_invalid"
  "3:rob/wb_duplicate_tag"
)

pass=0
fail=0

for entry in "${cases[@]}"; do
  id="${entry%%:*}"
  tag="${entry##*:}"
  set +e
  out="$("$BIN" "+neg_test=$id" 2>&1)"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]] && echo "$out" | grep -q "\[assert\] $tag"; then
    echo "[PASS] N$id ($tag) rc=$rc"
    pass=$((pass + 1))
  else
    echo "[FAIL] N$id expected fatal '$tag', rc=$rc"
    echo "$out" | tail -6
    fail=$((fail + 1))
  fi
done
log_section_done "negative assert cases"

echo "[assert-neg] pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "[assert-neg] PASS"
  exit 0
fi
exit 1
