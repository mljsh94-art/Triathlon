#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)

FW_PAYLOAD=${FW_PAYLOAD:-"${HOME}/rv32-linux/out/fw_payload.bin"}
DTB=${DTB:-"${HOME}/rv32-linux/out/npc.dtb"}
VIRTIO_BLK_IMAGE=${VIRTIO_BLK_IMAGE:-"${HOME}/rv32-linux/out/rootfs.img"}
MAX_CYCLES=${MAX_CYCLES:-7000000}
PROGRESS=${PROGRESS:-1000000}
TIMEOUT_SEC=${TIMEOUT_SEC:-420}
LOG_TAG=${LOG_TAG:-lsu-non-mem-uop-regression}

OUT_DIR=${OUT_DIR:-"${NPC_HOME}/build/linux-diag/$(date +%Y%m%d-%H%M%S)-${LOG_TAG}"}
mkdir -p "${OUT_DIR}"
LOG_FILE="${OUT_DIR}/diag.log"

if [[ ! -f "${FW_PAYLOAD}" ]]; then
  echo "fw_payload not found: ${FW_PAYLOAD}" >&2
  exit 2
fi
if [[ ! -f "${DTB}" ]]; then
  echo "dtb not found: ${DTB}" >&2
  exit 2
fi
if [[ ! -f "${VIRTIO_BLK_IMAGE}" ]]; then
  echo "virtio image not found: ${VIRTIO_BLK_IMAGE}" >&2
  exit 2
fi

cd "${NPC_HOME}"
set +e
timeout "${TIMEOUT_SEC}" make sim DIFFTEST= IMG="${FW_PAYLOAD}" \
  ARGS="--boot-handoff --dtb ${DTB} --virtio-blk-image ${VIRTIO_BLK_IMAGE} --firmware-load-base 0x80400000 --max-cycles ${MAX_CYCLES} --progress ${PROGRESS}" \
  >"${LOG_FILE}" 2>&1
RC=$?
set -e

if [[ ${RC} -ne 0 && ${RC} -ne 1 && ${RC} -ne 2 && ${RC} -ne 124 ]]; then
  echo "simulation exited unexpectedly, rc=${RC}" >&2
  exit ${RC}
fi

BAD_COUNT=$(awk '
  /\[progress\]/ {
    pick0 = ""; pick1 = ""; ld = ""; st = "";
    if (match($0, /lsu_issue\(raw\/pick\/blk\)=\(([0-9]),([0-9])\)\/\(([0-9]),([0-9])\)\/\(([0-9]),([0-9])\)/, m)) {
      pick0 = m[3];
      pick1 = m[4];
    }
    if (match($0, /lsu_sel\(pc\/ld\/st\/dst\)=0x[0-9a-fA-F]+\/([0-9])\/([0-9])\/0x[0-9a-fA-F]+/, s)) {
      ld = s[1];
      st = s[2];
    }
    if ((pick0 == "1" || pick1 == "1") && ld == "0" && st == "0") {
      bad += 1;
    }
  }
  END { print bad + 0; }
' "${LOG_FILE}")

echo "OUT_DIR=${OUT_DIR}"
echo "LOG_FILE=${LOG_FILE}"
echo "RC=${RC}"
echo "BAD_NON_MEM_LSU_PICK=${BAD_COUNT}"

if [[ "${BAD_COUNT}" != "0" ]]; then
  echo "FAIL: observed non-memory uop selected by LSU issue path" >&2
  exit 1
fi

echo "PASS: no non-memory uop selected by LSU issue path"
