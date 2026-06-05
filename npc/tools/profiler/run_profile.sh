#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/../.." && pwd)
TRIATHLON_HOME=$(cd "${NPC_HOME}/.." && pwd)

: "${ARCH:=riscv32i-npc}"
: "${CROSS_COMPILE:=riscv64-unknown-elf-}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR=${OUT_DIR:-"${NPC_HOME}/build/profile/${TIMESTAMP}"}
case "${OUT_DIR}" in
  /*) ;;
  npc/build/profile|npc/build/profile/*) OUT_DIR="${TRIATHLON_HOME}/${OUT_DIR}" ;;
  build/profile|build/profile/*) OUT_DIR="${NPC_HOME}/${OUT_DIR}" ;;
  *) OUT_DIR="${NPC_HOME}/${OUT_DIR}" ;;
esac
OUT_DIR="${OUT_DIR%/}"
PROFILE_COLLECTION="${NPC_HOME}/build/profile"
if [[ "${OUT_DIR}" == "${PROFILE_COLLECTION}" ]]; then
  OUT_DIR="${PROFILE_COLLECTION}/${TIMESTAMP}"
fi
mkdir -p "${OUT_DIR}"

DHRYSTONE_IMG="${TRIATHLON_HOME}/am-kernels/benchmarks/dhrystone/build/dhrystone-${ARCH}.bin"
COREMARK_IMG="${TRIATHLON_HOME}/am-kernels/benchmarks/coremark/build/coremark-${ARCH}.bin"

export TRIATHLON_HOME
export AM_HOME="${TRIATHLON_HOME}/abstract-machine"
export NPC_HOME
export NEMU_HOME="${TRIATHLON_HOME}/nemu"
export KERNELS_HOME="${TRIATHLON_HOME}/am-kernels"

echo "[profiler] output dir: ${OUT_DIR}"

echo "[profiler] clean stale build artifacts"
make -C "${TRIATHLON_HOME}/abstract-machine/am" clean
make -C "${TRIATHLON_HOME}/abstract-machine/klib" clean
make -C "${TRIATHLON_HOME}/am-kernels/benchmarks/dhrystone" clean
make -C "${TRIATHLON_HOME}/am-kernels/benchmarks/coremark" clean

echo "[profiler] build benchmark images"
make -C "${TRIATHLON_HOME}/am-kernels/benchmarks/dhrystone" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" image
make -C "${TRIATHLON_HOME}/am-kernels/benchmarks/coremark" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" image

run_profile_sim() {
  local label=$1
  local img=$2
  local json=$3
  local progress=$4
  local log="${OUT_DIR}/${label}.sim.log"
  echo "[profiler] run ${label} profile-json (log: ${log})"
  if ! make -C "${NPC_HOME}" sim \
    DIFFTEST= \
    IMG="${img}" \
    ARGS="--profile-json ${json} --progress=${progress}" \
    > "${log}" 2>&1; then
    echo "[profiler] ${label} sim failed; last 40 lines of ${log}:" >&2
    tail -n 40 "${log}" >&2
    exit 1
  fi
}

run_profile_sim dhrystone "${DHRYSTONE_IMG}" "${OUT_DIR}/dhrystone.json" 50000
run_profile_sim coremark "${COREMARK_IMG}" "${OUT_DIR}/coremark.json" 1000000

python3 "${SCRIPT_DIR}/merge_profile_json.py" --run-dir "${OUT_DIR}"
FINALIZE_ARGS=(--run-dir "${OUT_DIR}")
if [[ -n "${PROFILE_DISPLAY_NAME:-}" ]]; then
  FINALIZE_ARGS+=(--display-name "${PROFILE_DISPLAY_NAME}")
fi
python3 "${SCRIPT_DIR}/finalize_run.py" "${FINALIZE_ARGS[@]}"

echo "[profiler] done"
echo "[profiler] summary: ${OUT_DIR}/summary.json"
