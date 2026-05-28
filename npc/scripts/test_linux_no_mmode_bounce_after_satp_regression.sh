#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)

FW_PAYLOAD=${FW_PAYLOAD:-"${HOME}/rv32-linux/out/fw_payload.bin"}
DTB=${DTB:-"${HOME}/rv32-linux/out/npc.dtb"}
VIRTIO_BLK_IMAGE=${VIRTIO_BLK_IMAGE:-"${HOME}/rv32-linux/out/rootfs.img"}
MAX_CYCLES=${MAX_CYCLES:-8000000}
PROGRESS=${PROGRESS:-1000000}
TIMEOUT_SEC=${TIMEOUT_SEC:-420}

LOG_DIR=$(mktemp -d "${NPC_HOME}/build/linux-no-mmode-bounce.XXXXXX")
LOG_FILE="${LOG_DIR}/linux-no-mmode-bounce.log"

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
  ARGS="--boot-handoff --linux-early-debug --dtb ${DTB} --virtio-blk-image ${VIRTIO_BLK_IMAGE} --firmware-load-base 0x80400000 --max-cycles ${MAX_CYCLES} --progress ${PROGRESS}" \
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

if ! grep -q "OpenSBI v" "${LOG_FILE}"; then
  echo "OpenSBI banner missing in log" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

if ! grep -q "Domain0 Next Address" "${LOG_FILE}"; then
  echo "did not reach OpenSBI payload handoff stage" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

if ! grep -Eq "\\[debug\\]\\[satp-change\\].*satp_new=0x800820bd" "${LOG_FILE}"; then
  echo "missing satp transition to 0x800820bd in observation window" >&2
  tail -n 160 "${LOG_FILE}" >&2 || true
  exit 1
fi

if grep -Eq "\\[debug\\]\\[pc-cross\\].*pc=0x80400460.*satp=0x8[0-9a-fA-F]+" "${LOG_FILE}"; then
  echo "regression detected: bounced back to OpenSBI M-mode with non-zero SATP after Linux satp switch" >&2
  rg -n "\\[debug\\]\\[satp-change\\]|\\[debug\\]\\[pc-cross\\].*pc=0x80400460|\\[debug\\]\\[flush-exc\\]|\\[mmu-pf-l1\\]" "${LOG_FILE}" | tail -n 160 >&2 || true
  exit 1
fi

echo "PASS: no S-mode -> OpenSBI bounce signature after satp switch within ${MAX_CYCLES} cycles"
