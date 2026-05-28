#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)

FW_PAYLOAD=${FW_PAYLOAD:-"${HOME}/rv32-linux/out/fw_payload.bin"}
DTB=${DTB:-"${HOME}/rv32-linux/out/npc.dtb"}
VIRTIO_BLK_IMAGE=${VIRTIO_BLK_IMAGE:-"${HOME}/rv32-linux/out/rootfs.img"}
MAX_CYCLES=${MAX_CYCLES:-5000000}
PROGRESS=${PROGRESS:-1000000}

LOG_DIR=$(mktemp -d "${NPC_HOME}/build/linux-satp-alias-regression.XXXXXX")
LOG_FILE="${LOG_DIR}/linux-satp-alias-regression.log"

cleanup() {
  local rc=$?
  if [[ ${rc} -eq 0 ]]; then
    rm -rf "${LOG_DIR}"
  else
    echo "repro log kept at: ${LOG_FILE}" >&2
  fi
}
trap cleanup EXIT

set +e
make -C "${NPC_HOME}" sim DIFFTEST= IMG="${FW_PAYLOAD}" \
  ARGS="--boot-handoff --linux-early-debug --dtb ${DTB} --virtio-blk-image ${VIRTIO_BLK_IMAGE} --firmware-load-base 0x80400000 --max-cycles ${MAX_CYCLES} --progress ${PROGRESS}" \
  >"${LOG_FILE}" 2>&1
RC=$?
set -e

if [[ ! -f "${LOG_FILE}" ]]; then
  echo "regression log not found: ${LOG_FILE}" >&2
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
  echo "missing satp transition to 0x800820bd in regression window" >&2
  tail -n 160 "${LOG_FILE}" >&2 || true
  exit 1
fi

if grep -Eq "\\[lsu-mmu-pf\\].*pc=c00999f6.*vaddr=820b8074" "${LOG_FILE}"; then
  echo "regression detected: load page fault at pc=0xc00999f6 vaddr=0x820b8074" >&2
  rg -n "\\[lsu-mmu-pf\\].*c00999f6|\\[mmu-pf-l1\\].*820b8074|\\[debug\\]\\[flush-exc\\].*c00999f6" "${LOG_FILE}" >&2 || true
  exit 1
fi

if grep -Eq "\\[mmu-pf-l1\\].*vaddr=820b8074" "${LOG_FILE}"; then
  echo "regression detected: mmu invalid l1 pte for vaddr=0x820b8074" >&2
  rg -n "\\[mmu-pf-l1\\].*820b8074|\\[debug\\]\\[satp-change\\]|\\[debug\\]\\[linux-hotstep\\].*c00999f0" "${LOG_FILE}" >&2 || true
  exit 1
fi

if [[ ${RC} -ne 0 ]] && ! grep -q "TIMEOUT after" "${LOG_FILE}"; then
  echo "make sim exited unexpectedly with rc=${RC}" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

echo "PASS: no c00999f6/820b8074 satp-alias page-fault signature in ${MAX_CYCLES} cycles"
