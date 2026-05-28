#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <base-summary-or-dir> <current-summary-or-dir>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPARE_TOOL="${SCRIPT_DIR}/../tools/profiler/compare_summary.py"

BASE_PATH="$1"
CUR_PATH="$2"

if [ -d "$BASE_PATH" ]; then
  BASE_PATH="${BASE_PATH}/summary.json"
fi
if [ -d "$CUR_PATH" ]; then
  CUR_PATH="${CUR_PATH}/summary.json"
fi

if [ ! -f "$BASE_PATH" ]; then
  echo "Base summary not found: $BASE_PATH" >&2
  exit 2
fi
if [ ! -f "$CUR_PATH" ]; then
  echo "Current summary not found: $CUR_PATH" >&2
  exit 2
fi

python3 "$COMPARE_TOOL" --base "$BASE_PATH" --current "$CUR_PATH"
