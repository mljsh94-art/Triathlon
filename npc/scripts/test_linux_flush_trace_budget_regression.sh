#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)

FW_PAYLOAD=${FW_PAYLOAD:-"${HOME}/rv32-linux/out/fw_payload.bin"}
DTB=${DTB:-"${HOME}/rv32-linux/out/npc.dtb"}
VIRTIO_BLK_IMAGE=${VIRTIO_BLK_IMAGE:-"${HOME}/rv32-linux/out/rootfs.img"}
MAX_CYCLES=${MAX_CYCLES:-20000000}
PROGRESS=${PROGRESS:-1000000}
TIMEOUT_SEC=${TIMEOUT_SEC:-90}
MAX_FLUSH_TRACE=${MAX_FLUSH_TRACE:-1024}
MAX_RAT_TRACE=${MAX_RAT_TRACE:-1024}
MAX_ROB_QUERY_TRACE=${MAX_ROB_QUERY_TRACE:-1024}

LOG_DIR=$(mktemp -d "${NPC_HOME}/build/linux-flush-trace-regression.XXXXXX")
LOG_FILE="${LOG_DIR}/linux-flush-trace-regression.log"

cleanup() {
  local rc=$?
  if [[ ${rc} -eq 0 ]]; then
    rm -rf "${LOG_DIR}"
  else
    echo "repro log kept at: ${LOG_FILE}" >&2
  fi
}
trap cleanup EXIT

if [[ ! -f "${FW_PAYLOAD}" ]]; then
  echo "fw payload not found: ${FW_PAYLOAD}" >&2
  exit 1
fi
if [[ ! -f "${DTB}" ]]; then
  echo "dtb not found: ${DTB}" >&2
  exit 1
fi
if [[ ! -f "${VIRTIO_BLK_IMAGE}" ]]; then
  echo "virtio blk image not found: ${VIRTIO_BLK_IMAGE}" >&2
  exit 1
fi

set +e
timeout "${TIMEOUT_SEC}s" make -C "${NPC_HOME}" sim DIFFTEST= IMG="${FW_PAYLOAD}" \
  ARGS="--boot-handoff --dtb ${DTB} --virtio-blk-image ${VIRTIO_BLK_IMAGE} --firmware-load-base 0x80400000 --max-cycles ${MAX_CYCLES} --progress ${PROGRESS}" \
  >"${LOG_FILE}" 2>&1
RC=$?
set -e

if [[ ! -f "${LOG_FILE}" ]]; then
  echo "regression log not found: ${LOG_FILE}" >&2
  exit 1
fi

if [[ ${RC} -ne 0 ]] && [[ ${RC} -ne 124 ]] && ! grep -q "TIMEOUT after" "${LOG_FILE}"; then
  echo "make sim exited unexpectedly with rc=${RC}" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

if ! grep -Eq "OpenSBI v|\\[progress\\]|\\[issue-lsu-on-flush\\]" "${LOG_FILE}"; then
  echo "simulation log has no runtime markers (inconclusive run)" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

FLUSH_TRACE_COUNT=$(grep -c "\\[issue-lsu-on-flush\\]" "${LOG_FILE}" || true)
if (( FLUSH_TRACE_COUNT > MAX_FLUSH_TRACE )); then
  echo "regression detected: issue-lsu-on-flush trace storm (${FLUSH_TRACE_COUNT} > ${MAX_FLUSH_TRACE})" >&2
  rg -n "\\[issue-lsu-on-flush\\]|\\[issue-lsu\\]|\\[progress\\]|Linux version|OpenSBI" "${LOG_FILE}" | head -n 120 >&2 || true
  exit 1
fi

RAT_TRACE_COUNT=$(grep -Ec "\\[rat-watch-(flush|commit-clear|disp)\\]" "${LOG_FILE}" || true)
if (( RAT_TRACE_COUNT > MAX_RAT_TRACE )); then
  echo "regression detected: rat-watch trace storm (${RAT_TRACE_COUNT} > ${MAX_RAT_TRACE})" >&2
  rg -n "\\[rat-watch-(flush|commit-clear|disp)\\]|\\[progress\\]|Linux version|OpenSBI" "${LOG_FILE}" | head -n 120 >&2 || true
  exit 1
fi

ROB_QUERY_TRACE_COUNT=$(grep -c "\\[rob-tag-query\\]" "${LOG_FILE}" || true)
if (( ROB_QUERY_TRACE_COUNT > MAX_ROB_QUERY_TRACE )); then
  echo "regression detected: rob-tag-query trace storm (${ROB_QUERY_TRACE_COUNT} > ${MAX_ROB_QUERY_TRACE})" >&2
  rg -n "\\[rob-tag-query\\]|\\[progress\\]|Linux version|OpenSBI" "${LOG_FILE}" | head -n 120 >&2 || true
  exit 1
fi

echo "PASS: trace counts are bounded (issue-lsu-on-flush=${FLUSH_TRACE_COUNT}, rat-watch=${RAT_TRACE_COUNT}, rob-tag-query=${ROB_QUERY_TRACE_COUNT})"
