#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)

FW_PAYLOAD=${FW_PAYLOAD:-"${HOME}/rv32-linux/out/fw_payload.bin"}
DTB=${DTB:-"${HOME}/rv32-linux/out/npc.dtb"}
VIRTIO_BLK_IMAGE=${VIRTIO_BLK_IMAGE:-"${HOME}/rv32-linux/out/rootfs.img"}
MAX_CYCLES=${MAX_CYCLES:-5200000}
PROGRESS=${PROGRESS:-1000000}

LOG_DIR=$(mktemp -d "${NPC_HOME}/build/linux-priv-trap-repro.XXXXXX")
trap 'rm -rf "${LOG_DIR}"' EXIT
LOG_FILE="${LOG_DIR}/linux-priv-trap-repro.log"

set +e
make -C "${NPC_HOME}" sim DIFFTEST= IMG="${FW_PAYLOAD}" \
  ARGS="--boot-handoff --dtb ${DTB} --virtio-blk-image ${VIRTIO_BLK_IMAGE} --firmware-load-base 0x80400000 --max-cycles ${MAX_CYCLES} --progress ${PROGRESS}" \
  >"${LOG_FILE}" 2>&1
RC=$?
set -e

if [[ ! -f "${LOG_FILE}" ]]; then
  echo "repro log not found: ${LOG_FILE}" >&2
  exit 1
fi

if ! grep -q "OpenSBI v" "${LOG_FILE}"; then
  echo "OpenSBI banner missing in log" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

if ! grep -q "last_pc=0xc01d069e" "${LOG_FILE}"; then
  echo "missing signature: last_pc=0xc01d069e" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

if ! grep -Eq "\\[csrdbg\\].*pc=80400800.*priv=1.*illegal=1" "${LOG_FILE}"; then
  echo "missing signature: csrdbg pc=80400800 priv=1 illegal=1" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

if ! grep -q "sbi_trap_error: hart0: trap0: mepc=0x80400800" "${LOG_FILE}"; then
  echo "missing signature: sbi_trap_error mepc=0x80400800" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

if [[ ${RC} -eq 0 ]]; then
  echo "WARNING: make sim returned success unexpectedly, but signatures matched." >&2
fi

echo "PASS: reproduced Linux privilege trap path (0xc01d069e -> 0x80400800 illegal)"
