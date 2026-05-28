#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)
TRIATHLON_HOME=$(cd "${NPC_HOME}/.." && pwd)

ARCH="${ARCH:-riscv32i-npc}"
CROSS_COMPILE="${CROSS_COMPILE:-riscv64-elf-}"

RUN_CPU_TESTS=1
RUN_UNIT_TESTS=1
RUN_PROFILE=1

usage() {
  cat <<'EOF'
Usage: run_eval_suite.sh [options]
  --arch <arch>               Override ARCH (default: riscv32i-npc)
  --cross-compile <prefix>    Override CROSS_COMPILE (default: riscv64-elf-)
  --skip-cpu-tests            Skip am-kernels/tests/cpu-tests
  --skip-unit-tests           Skip npc unit tests (Makefile_test run-all)
  --skip-profile              Skip npc profiler (includes Dhrystone/coremark)
  -h, --help                  Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --cross-compile)
      CROSS_COMPILE="$2"
      shift 2
      ;;
    --skip-cpu-tests)
      RUN_CPU_TESTS=0
      shift 1
      ;;
    --skip-unit-tests)
      RUN_UNIT_TESTS=0
      shift 1
      ;;
    --skip-profile)
      RUN_PROFILE=0
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[eval-suite] ERROR: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

echo "[eval-suite] ARCH=${ARCH}"
echo "[eval-suite] CROSS_COMPILE=${CROSS_COMPILE}"

if [[ "${RUN_CPU_TESTS}" -eq 1 ]]; then
  echo "[eval-suite] run cpu-tests"
  make -C "${TRIATHLON_HOME}/am-kernels/tests/cpu-tests" \
    ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" run
fi

if [[ "${RUN_UNIT_TESTS}" -eq 1 ]]; then
  echo "[eval-suite] run npc unit tests"
  make -C "${NPC_HOME}" -f Makefile_test run-all
fi

if [[ "${RUN_PROFILE}" -eq 1 ]]; then
  echo "[eval-suite] run npc profile-task"
  make -C "${NPC_HOME}" profile-task \
    ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}"
fi

echo "[eval-suite] PASS"
