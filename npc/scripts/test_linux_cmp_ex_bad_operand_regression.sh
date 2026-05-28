#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)

FW_PAYLOAD=${FW_PAYLOAD:-"${HOME}/rv32-linux/out/fw_payload.bin"}
DTB=${DTB:-"${HOME}/rv32-linux/out/npc.dtb"}
VIRTIO_BLK_IMAGE=${VIRTIO_BLK_IMAGE:-"${HOME}/rv32-linux/out/rootfs.img"}
MAX_CYCLES=${MAX_CYCLES:-4300000}
PROGRESS=${PROGRESS:-1000000}
TIMEOUT_SEC=${TIMEOUT_SEC:-360}
LOG_TAG=${LOG_TAG:-cmp-ex-bad-opr}

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
  ARGS="--boot-handoff --dtb ${DTB} --virtio-blk-image ${VIRTIO_BLK_IMAGE} --firmware-load-base 0x80400000 --max-cycles ${MAX_CYCLES} --progress ${PROGRESS} +npc_diag_trace" \
  >"${LOG_FILE}" 2>&1
RC=$?
set -e

BAD_BE_OPR=$(grep -c '\[be-opr-lsu\].*pc=c074befe.*issue_v1=43' "${LOG_FILE}" || true)
BAD_RS_ENQ=$(grep -c '\[rs-lsu-enq\].*pc=c074befe.*in_v1=43' "${LOG_FILE}" || true)
BAD_LSU_REQ=$(grep -c '\[lsu-req\].*pc=c074befe.*rs1=43' "${LOG_FILE}" || true)

echo "OUT_DIR=${OUT_DIR}"
echo "LOG_FILE=${LOG_FILE}"
echo "RC=${RC}"
echo "BAD_BE_OPR=${BAD_BE_OPR}"
echo "BAD_RS_ENQ=${BAD_RS_ENQ}"
echo "BAD_LSU_REQ=${BAD_LSU_REQ}"

if [[ ${RC} -ne 0 && ${RC} -ne 1 && ${RC} -ne 2 && ${RC} -ne 124 ]]; then
  echo "simulation exited unexpectedly, rc=${RC}" >&2
  exit ${RC}
fi

if [[ "${BAD_BE_OPR}" != "0" || "${BAD_RS_ENQ}" != "0" || "${BAD_LSU_REQ}" != "0" ]]; then
  echo "FAIL: cmp_ex_search bad operand detected (expected all BAD_* counters to be 0)" >&2
  exit 1
fi

echo "PASS: no cmp_ex_search bad operand observed"
