#!/usr/bin/env bash
# ④ Cover property gate stub (Phase 7 placeholder).
set -u

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

EXPECTED="$NPC_HOME/build/cover/expected_hits.txt"

log_section "cover check (stub)"
if [[ -f "$EXPECTED" ]]; then
  echo "[verify-cover] found $EXPECTED ($(wc -l < "$EXPECTED") lines)"
else
  echo "[verify-cover] placeholder missing: $EXPECTED (Phase 7 not wired yet)"
fi
log_section_done "cover check (stub)"

echo "[verify-cover] PASS (stub)"
exit 0
