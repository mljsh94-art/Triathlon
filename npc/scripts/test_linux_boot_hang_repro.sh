#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)
RUN_SCRIPT="${NPC_HOME}/scripts/run_linux_smoke.sh"

FW_PAYLOAD=${FW_PAYLOAD:-"${HOME}/rv32-linux/src/opensbi/build/platform/generic/firmware/fw_payload.bin"}
DTB=${DTB:-"${HOME}/rv32-linux/out/npc.dtb"}
VIRTIO_BLK_IMAGE=${VIRTIO_BLK_IMAGE:-"${HOME}/rv32-linux/out/rootfs.img"}
MAX_CYCLES=${MAX_CYCLES:-7000000}
PROGRESS=${PROGRESS:-1000000}
LOG_DIR=$(mktemp -d "${NPC_HOME}/build/linux-hang-repro.XXXXXX")
trap 'rm -rf "${LOG_DIR}"' EXIT

set +e
"${RUN_SCRIPT}" \
  --mode full \
  --fw-payload "${FW_PAYLOAD}" \
  --dtb "${DTB}" \
  --virtio-blk-image "${VIRTIO_BLK_IMAGE}" \
  --timeout-sec 0 \
  --max-cycles "${MAX_CYCLES}" \
  --progress "${PROGRESS}" \
  --log-dir "${LOG_DIR}" >/tmp/linux-hang-repro.out 2>&1
RC=$?
set -e

if [[ ${RC} -eq 0 ]]; then
  echo "expected linux smoke to fail (hang repro), but got success" >&2
  exit 1
fi

LOG_FILE="${LOG_DIR}/linux-smoke.log"
if [[ ! -f "${LOG_FILE}" ]]; then
  echo "repro log not found: ${LOG_FILE}" >&2
  cat /tmp/linux-hang-repro.out >&2 || true
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

mapfile -t NO_COMMIT_SERIES < <(
  grep "last_pc=0x80801064" "${LOG_FILE}" | sed -n 's/.*no_commit=\([0-9]\+\).*/\1/p'
)

if [[ "${#NO_COMMIT_SERIES[@]}" -lt 2 ]]; then
  echo "hang signature (last_pc=0x80801064) not found enough times" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

FIRST_NO_COMMIT="${NO_COMMIT_SERIES[0]}"
LAST_NO_COMMIT="${NO_COMMIT_SERIES[$((${#NO_COMMIT_SERIES[@]} - 1))]}"
if (( LAST_NO_COMMIT <= FIRST_NO_COMMIT )); then
  echo "hang signature no_commit did not grow as expected: first=${FIRST_NO_COMMIT}, last=${LAST_NO_COMMIT}" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

if ! grep -q "cycle=5000000" "${LOG_FILE}"; then
  echo "expected progress line at cycle=5000000 not found" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

if ! grep -q "cycle=6000000" "${LOG_FILE}"; then
  echo "expected progress line at cycle=6000000 not found" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

echo "PASS: reproduced Linux boot stall at 0x80801064 with growing no_commit"
