#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN_SCRIPT="${SCRIPT_DIR}/run_eval_suite.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_BIN="${TMP_DIR}/fake-bin"
MAKE_LOG="${TMP_DIR}/make.log"
mkdir -p "${FAKE_BIN}"

cat > "${FAKE_BIN}/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "make $*" >> "${MAKE_LOG:?}"
exit 0
EOF
chmod +x "${FAKE_BIN}/make"

PATH="${FAKE_BIN}:${PATH}" \
MAKE_LOG="${MAKE_LOG}" \
  bash "${RUN_SCRIPT}" >/dev/null

if ! grep -q 'am-kernels/tests/cpu-tests.*ARCH=riscv32i-npc.*CROSS_COMPILE=riscv64-elf-.* run' "${MAKE_LOG}"; then
  echo "missing cpu-tests invocation with default riscv32i arch" >&2
  exit 1
fi

if ! grep -q '\-f Makefile_test run-all' "${MAKE_LOG}"; then
  echo "missing npc unit-test invocation" >&2
  exit 1
fi

if ! grep -q 'profile-task ARCH=riscv32i-npc CROSS_COMPILE=riscv64-elf-' "${MAKE_LOG}"; then
  echo "missing profile-task invocation with default riscv32i arch" >&2
  exit 1
fi

: > "${MAKE_LOG}"
PATH="${FAKE_BIN}:${PATH}" \
MAKE_LOG="${MAKE_LOG}" \
  bash "${RUN_SCRIPT}" --skip-profile >/dev/null

if grep -q 'profile-task' "${MAKE_LOG}"; then
  echo "profile-task should be skipped with --skip-profile" >&2
  exit 1
fi

echo "PASS"
