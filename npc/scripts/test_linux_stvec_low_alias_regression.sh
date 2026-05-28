#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)

FW_PAYLOAD=${FW_PAYLOAD:-"${HOME}/rv32-linux/out/fw_payload.bin"}
DTB=${DTB:-"${HOME}/rv32-linux/out/npc.dtb"}
VIRTIO_BLK_IMAGE=${VIRTIO_BLK_IMAGE:-"${HOME}/rv32-linux/out/rootfs.img"}
MAX_CYCLES=${MAX_CYCLES:-5000000}
PROGRESS=${PROGRESS:-1000000}

LOG_DIR=$(mktemp -d "${NPC_HOME}/build/linux-stvec-low-regression.XXXXXX")
LOG_FILE="${LOG_DIR}/linux-stvec-low-regression.log"

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

if ! grep -Eq "\\[csr-satp-wr\\].*write=80081402" "${LOG_FILE}"; then
  echo "did not reach satp switch to 0x80081402 in regression window" >&2
  tail -n 160 "${LOG_FILE}" >&2 || true
  exit 1
fi

if grep -Eq "\\[mmu-pf-l1\\].*vaddr=808010c4" "${LOG_FILE}"; then
  echo "regression detected: instruction page-fault loop at vaddr=0x808010c4" >&2
  rg -n "\\[csr-satp-wr\\]|\\[mmu-pf-l1\\].*(80801176|808011a6|808010c4)" "${LOG_FILE}" | head -n 120 >&2 || true
  exit 1
fi

if grep -Eq "\\[mmu-pf-l1\\].*vaddr=808011a6" "${LOG_FILE}"; then
  echo "regression detected: invalid L1 pte for vaddr=0x808011a6" >&2
  rg -n "\\[csr-satp-wr\\]|\\[mmu-pf-l1\\].*(80801176|808011a6|808010c4)" "${LOG_FILE}" | head -n 120 >&2 || true
  exit 1
fi

if [[ ${RC} -ne 0 ]] && ! grep -q "TIMEOUT after" "${LOG_FILE}"; then
  echo "make sim exited unexpectedly with rc=${RC}" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

echo "PASS: no stvec-low instruction-fault alias signature in ${MAX_CYCLES} cycles"
