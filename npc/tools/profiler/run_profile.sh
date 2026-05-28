#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/../.." && pwd)
TRIATHLON_HOME=$(cd "${NPC_HOME}/.." && pwd)

: "${ARCH:=riscv32i-npc}"
: "${CROSS_COMPILE:=riscv64-elf-}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR=${OUT_DIR:-"${NPC_HOME}/build/profile/${TIMESTAMP}"}
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

echo "[profiler] run dhrystone full profile"
make -C "${NPC_HOME}" sim \
  DIFFTEST= \
  IMG="${DHRYSTONE_IMG}" \
  ARGS="--commit-trace --bru-trace --stall-trace=100 --progress=50000" \
  > "${OUT_DIR}/dhrystone.log" 2>&1

echo "[profiler] run coremark full profile"
make -C "${NPC_HOME}" sim \
  DIFFTEST= \
  IMG="${COREMARK_IMG}" \
  ARGS="--bru-trace --stall-trace=20 --progress=1000000" \
  > "${OUT_DIR}/coremark.log" 2>&1

echo "[profiler] run coremark commit sample"
make -C "${NPC_HOME}" sim \
  DIFFTEST= \
  IMG="${COREMARK_IMG}" \
  ARGS="--max-cycles=2000000 --commit-trace" \
  > "${OUT_DIR}/coremark_commit_sample.log" 2>&1 || true

python3 "${SCRIPT_DIR}/parse_profile.py" \
  --log-dir "${OUT_DIR}" \
  --template "${SCRIPT_DIR}/report_template.md" \
  --out-json "${OUT_DIR}/summary.json" \
  --out-md "${OUT_DIR}/report.md"

echo "[profiler] done"
echo "[profiler] report: ${OUT_DIR}/report.md"
