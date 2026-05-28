#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AMK_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)
WORKTREE_ROOT=$(cd "${AMK_HOME}/.." && pwd)

if [[ "${WORKTREE_ROOT}" != *"/.worktrees/"* ]]; then
  echo "SKIP: not in a worktree path (${WORKTREE_ROOT})"
  exit 0
fi

REAL_ROOT="${WORKTREE_ROOT%/.worktrees/*}"
POLLUTED_AM_HOME="${REAL_ROOT}/abstract-machine"
POLLUTED_NPC_HOME="${REAL_ROOT}/npc"

OUT=$(AM_HOME="${POLLUTED_AM_HOME}" \
      NPC_HOME="${POLLUTED_NPC_HOME}" \
      make -n -C "${AMK_HOME}/benchmarks/dhrystone" \
      ARCH=riscv32e-npc CROSS_COMPILE=riscv64-elf- run 2>&1 || true)

EXPECT_WORKTREE="make -C ${WORKTREE_ROOT}/npc sim"
EXPECT_POLLUTED="make -C ${POLLUTED_NPC_HOME} sim"

if grep -Fq "${EXPECT_POLLUTED}" <<<"${OUT}"; then
  echo "FAIL: run command still points to polluted NPC_HOME"
  echo "Found: ${EXPECT_POLLUTED}"
  exit 1
fi

if ! grep -Fq "${EXPECT_WORKTREE}" <<<"${OUT}"; then
  echo "FAIL: run command does not point to worktree npc"
  echo "Expected contains: ${EXPECT_WORKTREE}"
  echo "---- make -n output tail ----"
  echo "${OUT}" | tail -n 40
  exit 1
fi

CPU_OUT=$(env -u AM_HOME \
          NPC_HOME="${POLLUTED_NPC_HOME}" \
          make -C "${AMK_HOME}/tests/cpu-tests" \
          ALL=bubble-sort \
          ARCH=riscv32e-npc CROSS_COMPILE=riscv64-elf- run 2>&1 || true)

if grep -Fq "/Makefile: No such file or directory" <<<"${CPU_OUT}"; then
  echo "FAIL: cpu-tests generated Makefile still resolves include to /Makefile"
  echo "---- cpu-tests output tail ----"
  echo "${CPU_OUT}" | tail -n 40
  exit 1
fi

if grep -Fq "***FAIL***" <<<"${CPU_OUT}"; then
  echo "FAIL: cpu-tests bubble-sort did not pass under polluted env"
  echo "---- cpu-tests output tail ----"
  echo "${CPU_OUT}" | tail -n 40
  exit 1
fi

for bench in Dhrystone coremark; do
  BENCH_OUT=$(env -u AM_HOME \
              NPC_HOME="${POLLUTED_NPC_HOME}" \
              make -C "${AMK_HOME}/benchmark/${bench}" \
              ARCH=riscv32e-npc CROSS_COMPILE=riscv64-elf- run 2>&1 || true)

  if grep -Fq "/Makefile: No such file or directory" <<<"${BENCH_OUT}"; then
    echo "FAIL: ${bench} still resolves include to /Makefile"
    echo "---- ${bench} output tail ----"
    echo "${BENCH_OUT}" | tail -n 40
    exit 1
  fi

  if ! grep -Fq "[npc.mk] AM_HOME=${WORKTREE_ROOT}/abstract-machine NPC_HOME=${WORKTREE_ROOT}/npc" <<<"${BENCH_OUT}"; then
    echo "FAIL: ${bench} did not route to worktree AM/NPC path"
    echo "---- ${bench} output tail ----"
    echo "${BENCH_OUT}" | tail -n 40
    exit 1
  fi
done

echo "PASS"
