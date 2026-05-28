#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN_SCRIPT="${SCRIPT_DIR}/run_linux_smoke.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_BIN="${TMP_DIR}/fake-bin"
mkdir -p "${FAKE_BIN}"

FW_PAYLOAD="${TMP_DIR}/fw_payload.bin"
DTB="${TMP_DIR}/npc.dtb"
BLK_IMG="${TMP_DIR}/rootfs.img"
LOG_DIR="${TMP_DIR}/logs"
MAKE_LOG="${TMP_DIR}/make.log"

printf '\x13\x00\x00\x00' > "${FW_PAYLOAD}"
printf '\xd0\x0d\xfe\xed' > "${DTB}"
dd if=/dev/zero of="${BLK_IMG}" bs=512 count=1 status=none

cat > "${FAKE_BIN}/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "make $*" >> "${MAKE_LOG:?}"
if [[ "${SIM_BEHAVIOR:-pass}" == "pass" ]]; then
  echo "OpenSBI v1.5"
  echo "Domain0 Next Address        : 0x80800000"
  echo "Linux version 6.6.0"
elif [[ "${SIM_BEHAVIOR:-pass}" == "quick" ]]; then
  echo "OpenSBI v1.5"
  echo "Domain0 Next Address        : 0x80800000"
elif [[ "${SIM_BEHAVIOR:-pass}" == "linux_nolog" ]]; then
  echo "OpenSBI v1.5"
  echo "Domain0 Next Address        : 0x80800000"
  echo "[progress] cycle=4000000 commits=4443317 no_commit=0 last_pc=0x810043ba"
  echo "[progress] cycle=6000000 commits=6443317 no_commit=0 last_pc=0x810043ba"
elif [[ "${SIM_BEHAVIOR:-pass}" == "quick_cycle_timeout" ]]; then
  echo "OpenSBI v1.5"
  echo "Domain0 Next Address        : 0x80800000"
  echo "TIMEOUT after 1000 cycles"
elif [[ "${SIM_BEHAVIOR:-pass}" == "hang" ]]; then
  echo "OpenSBI v1.5"
  echo "[progress] cycle=2900000 commits=3588795 no_commit=7231 last_pc=0x80441088"
  echo "[progress] cycle=3000000 commits=3588795 no_commit=107231 last_pc=0x80441088"
  echo "[progress] cycle=3100000 commits=3588795 no_commit=207231 last_pc=0x80441088"
else
  echo "OpenSBI v1.5"
fi
exit "${SIM_EXIT_CODE:-0}"
EOF
chmod +x "${FAKE_BIN}/make"

if ! PATH="${FAKE_BIN}:${PATH}" \
  MAKE_LOG="${MAKE_LOG}" \
  SIM_BEHAVIOR=quick \
  bash "${RUN_SCRIPT}" \
    --fw-payload "${FW_PAYLOAD}" \
    --dtb "${DTB}" \
    --virtio-blk-image "${BLK_IMG}" \
    --timeout-sec 0 \
    --max-cycles 1000 \
    --progress 100 \
    --log-dir "${LOG_DIR}" >/dev/null 2>&1; then
  echo "expected default quick smoke to pass with OpenSBI + Domain0 markers present" >&2
  exit 1
fi

if ! grep -q "virtio-blk-image ${BLK_IMG}" "${MAKE_LOG}"; then
  echo "missing virtio blk arg in make invocation" >&2
  cat "${MAKE_LOG}" >&2
  exit 1
fi

if ! PATH="${FAKE_BIN}:${PATH}" \
  MAKE_LOG="${MAKE_LOG}" \
  SIM_BEHAVIOR=quick \
  SIM_EXIT_CODE=124 \
  bash "${RUN_SCRIPT}" \
    --fw-payload "${FW_PAYLOAD}" \
    --dtb "${DTB}" \
    --virtio-blk-image "${BLK_IMG}" \
    --timeout-sec 10 \
    --max-cycles 1000 \
    --progress 100 \
    --log-dir "${LOG_DIR}" >/dev/null 2>&1; then
  echo "expected quick smoke to pass when timeout happens after quick markers are observed" >&2
  exit 1
fi

if ! PATH="${FAKE_BIN}:${PATH}" \
  MAKE_LOG="${MAKE_LOG}" \
  SIM_BEHAVIOR=quick_cycle_timeout \
  SIM_EXIT_CODE=2 \
  bash "${RUN_SCRIPT}" \
    --fw-payload "${FW_PAYLOAD}" \
    --dtb "${DTB}" \
    --virtio-blk-image "${BLK_IMG}" \
    --timeout-sec 0 \
    --max-cycles 1000 \
    --progress 100 \
    --log-dir "${LOG_DIR}" >/dev/null 2>&1; then
  echo "expected quick smoke to pass when simulator exits on max-cycles with quick markers observed" >&2
  exit 1
fi

set +e
PATH="${FAKE_BIN}:${PATH}" \
MAKE_LOG="${MAKE_LOG}" \
SIM_BEHAVIOR=quick \
bash "${RUN_SCRIPT}" \
  --mode full \
  --fw-payload "${FW_PAYLOAD}" \
  --dtb "${DTB}" \
  --virtio-blk-image "${BLK_IMG}" \
  --timeout-sec 0 \
  --max-cycles 1000 \
  --progress 100 \
  --log-dir "${LOG_DIR}" >/dev/null 2>&1
RC=$?
set -e

if [[ "${RC}" -eq 0 ]]; then
  echo "expected full smoke to fail when Linux marker is missing" >&2
  exit 1
fi

if ! PATH="${FAKE_BIN}:${PATH}" \
  MAKE_LOG="${MAKE_LOG}" \
  SIM_BEHAVIOR=linux_nolog \
  bash "${RUN_SCRIPT}" \
    --mode full \
    --fw-payload "${FW_PAYLOAD}" \
    --dtb "${DTB}" \
    --virtio-blk-image "${BLK_IMG}" \
    --timeout-sec 0 \
    --max-cycles 1000 \
    --progress 100 \
    --log-dir "${LOG_DIR}" >/dev/null 2>&1; then
  echo "expected full smoke script to pass when Linux runs but UART marker is absent" >&2
  exit 1
fi

if ! PATH="${FAKE_BIN}:${PATH}" \
  MAKE_LOG="${MAKE_LOG}" \
  SIM_BEHAVIOR=pass \
  bash "${RUN_SCRIPT}" \
    --mode full \
    --fw-payload "${FW_PAYLOAD}" \
    --dtb "${DTB}" \
    --virtio-blk-image "${BLK_IMG}" \
    --timeout-sec 0 \
    --max-cycles 1000 \
    --progress 100 \
    --log-dir "${LOG_DIR}" >/dev/null 2>&1; then
  echo "expected full smoke script to pass with Linux marker present" >&2
  exit 1
fi

set +e
HANG_OUTPUT=$(PATH="${FAKE_BIN}:${PATH}" \
MAKE_LOG="${MAKE_LOG}" \
SIM_BEHAVIOR=hang \
bash "${RUN_SCRIPT}" \
  --fw-payload "${FW_PAYLOAD}" \
  --dtb "${DTB}" \
  --virtio-blk-image "${BLK_IMG}" \
  --timeout-sec 0 \
  --max-cycles 1000 \
  --progress 100 \
  --log-dir "${LOG_DIR}" 2>&1)
RC_HANG=$?
set -e

if [[ "${RC_HANG}" -eq 0 ]]; then
  echo "expected smoke script to fail on simulated hang" >&2
  exit 1
fi

if ! grep -qi "likely payload contains RVC compressed instructions" <<< "${HANG_OUTPUT}"; then
  echo "expected RVC mismatch hint in hang output" >&2
  echo "${HANG_OUTPUT}" >&2
  exit 1
fi

echo "PASS"
