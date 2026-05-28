#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/../.." && pwd)
RUN_SCRIPT="${SCRIPT_DIR}/run_profile.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_BIN="${TMP_DIR}/fake-bin"
MAKE_LOG="${TMP_DIR}/make.log"
PY_LOG="${TMP_DIR}/python.log"
mkdir -p "${FAKE_BIN}"

cat > "${FAKE_BIN}/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "make $*" >> "${MAKE_LOG:?}"
exit 0
EOF
chmod +x "${FAKE_BIN}/make"

cat > "${FAKE_BIN}/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "python3 $*" >> "${PY_LOG:?}"
exit 0
EOF
chmod +x "${FAKE_BIN}/python3"

PATH="${FAKE_BIN}:${PATH}" \
MAKE_LOG="${MAKE_LOG}" \
PY_LOG="${PY_LOG}" \
OUT_DIR="${TMP_DIR}/out" \
  bash "${RUN_SCRIPT}" >/dev/null

if ! grep -q 'benchmarks/dhrystone.* clean' "${MAKE_LOG}"; then
  echo "missing clean for dhrystone" >&2
  exit 1
fi

if ! grep -q 'benchmarks/coremark.* clean' "${MAKE_LOG}"; then
  echo "missing clean for coremark" >&2
  exit 1
fi

if ! grep -q 'sim .*DIFFTEST=' "${MAKE_LOG}"; then
  echo "missing DIFFTEST= in sim invocation" >&2
  exit 1
fi

if ! grep -q 'benchmarks/dhrystone.*ARCH=riscv32i-npc.*CROSS_COMPILE=riscv64-elf-.* image' "${MAKE_LOG}"; then
  echo "missing default riscv32i arch for dhrystone image" >&2
  exit 1
fi

if ! grep -q 'benchmarks/coremark.*ARCH=riscv32i-npc.*CROSS_COMPILE=riscv64-elf-.* image' "${MAKE_LOG}"; then
  echo "missing default riscv32i arch for coremark image" >&2
  exit 1
fi

echo "PASS"
