#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)
SMOKE_SCRIPT="${SCRIPT_DIR}/run_linux_smoke.sh"

TIMEOUT_SEC=${TIMEOUT_SEC:-600}
MAX_CYCLES=${MAX_CYCLES:-120000000}
PROGRESS=${PROGRESS:-1000000}

if [[ ! -x "${SMOKE_SCRIPT}" ]]; then
  echo "run_linux_smoke.sh not found or not executable: ${SMOKE_SCRIPT}" >&2
  exit 1
fi

set +e
SMOKE_OUT=$(
  "${SMOKE_SCRIPT}" \
    --mode full \
    --clear-default-markers \
    --marker OpenSBI \
    --marker "Linux version" \
    --timeout-sec "${TIMEOUT_SEC}" \
    --max-cycles "${MAX_CYCLES}" \
    --progress "${PROGRESS}" 2>&1
)
RC=$?
set -e

echo "${SMOKE_OUT}"
if [[ ${RC} -ne 0 ]]; then
  exit ${RC}
fi

LOG_FILE=$(echo "${SMOKE_OUT}" | awk -F': ' '/\[linux-smoke\] log:/ {print $2}' | tail -n 1)
if [[ -z "${LOG_FILE}" ]] || [[ ! -f "${LOG_FILE}" ]]; then
  echo "strict check failed: cannot locate smoke log file" >&2
  exit 1
fi

# Strict criterion: UART log must contain the literal Linux version banner.
if ! grep -q "Linux version" "${LOG_FILE}"; then
  echo "strict check failed: Linux version marker not found in log (fallback is not accepted)" >&2
  echo "log: ${LOG_FILE}" >&2
  exit 1
fi

echo "PASS: strict Linux version marker observed"
