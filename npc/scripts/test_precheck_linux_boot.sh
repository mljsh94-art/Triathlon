#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRECHECK="${SCRIPT_DIR}/precheck_linux_boot.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

OPEN_SBI_BIN="${TMP_DIR}/fw_payload.opensbi.bin"
OUT_BIN="${TMP_DIR}/fw_payload.out.bin"
DTB="${TMP_DIR}/npc.dtb"

printf '\x13\x00\x00\x00' > "${OPEN_SBI_BIN}"
cp "${OPEN_SBI_BIN}" "${OUT_BIN}"
printf '\xd0\x0d\xfe\xed' > "${DTB}"

if ! OUTPUT_OK=$("${PRECHECK}" \
  --opensbi-bin "${OPEN_SBI_BIN}" \
  --out-bin "${OUT_BIN}" \
  --dtb "${DTB}" \
  --firmware-load-base 0x80400000 2>&1); then
  echo "expected success for matching payloads" >&2
  echo "${OUTPUT_OK}" >&2
  exit 1
fi

if ! grep -q "make sim DIFFTEST=" <<< "${OUTPUT_OK}"; then
  echo "missing make sim command in success output" >&2
  exit 1
fi

HOME_TMP="${TMP_DIR}/home"
mkdir -p "${HOME_TMP}/rv32-linux/src/opensbi/build/platform/generic/firmware" \
         "${HOME_TMP}/rv32-linux/out"
cp "${OPEN_SBI_BIN}" "${HOME_TMP}/rv32-linux/src/opensbi/build/platform/generic/firmware/fw_payload.bin"
cp "${OPEN_SBI_BIN}" "${HOME_TMP}/rv32-linux/out/fw_payload.bin"
cp "${DTB}" "${HOME_TMP}/rv32-linux/out/npc.dtb"

if ! OUTPUT_TILDE=$(HOME="${HOME_TMP}" "${PRECHECK}" \
  --opensbi-bin "~/rv32-linux/src/opensbi/build/platform/generic/firmware/fw_payload.bin" \
  --out-bin "~/rv32-linux/out/fw_payload.bin" \
  --dtb "~/rv32-linux/out/npc.dtb" 2>&1); then
  echo "expected success for tilde paths" >&2
  echo "${OUTPUT_TILDE}" >&2
  exit 1
fi

if ! grep -q "PASS" <<< "${OUTPUT_TILDE}"; then
  echo "expected PASS message for tilde paths" >&2
  exit 1
fi

set +e
OUTPUT_ALIGN=$("${PRECHECK}" \
  --opensbi-bin "${OPEN_SBI_BIN}" \
  --out-bin "${OUT_BIN}" \
  --dtb "${DTB}" \
  --firmware-load-base 0x80040000 2>&1)
RC_ALIGN=$?
set -e

if [ "${RC_ALIGN}" -eq 0 ]; then
  echo "expected failure for unaligned firmware-load-base" >&2
  exit 1
fi

if ! grep -qi "4MiB aligned" <<< "${OUTPUT_ALIGN}"; then
  echo "expected alignment error message" >&2
  echo "${OUTPUT_ALIGN}" >&2
  exit 1
fi

printf '\x23\x00\x00\x00' > "${OUT_BIN}"
set +e
OUTPUT_MISMATCH=$("${PRECHECK}" \
  --opensbi-bin "${OPEN_SBI_BIN}" \
  --out-bin "${OUT_BIN}" \
  --dtb "${DTB}" 2>&1)
RC_MISMATCH=$?
set -e

if [ "${RC_MISMATCH}" -eq 0 ]; then
  echo "expected failure for mismatched payloads" >&2
  echo "${OUTPUT_MISMATCH}" >&2
  exit 1
fi

if ! grep -qi "mismatch" <<< "${OUTPUT_MISMATCH}"; then
  echo "expected mismatch message" >&2
  echo "${OUTPUT_MISMATCH}" >&2
  exit 1
fi

rm -f "${DTB}"
set +e
OUTPUT_MISSING=$("${PRECHECK}" \
  --opensbi-bin "${OPEN_SBI_BIN}" \
  --out-bin "${OUT_BIN}" \
  --dtb "${DTB}" 2>&1)
RC_MISSING=$?
set -e

if [ "${RC_MISSING}" -eq 0 ]; then
  echo "expected failure for missing dtb" >&2
  exit 1
fi

if ! grep -qi "not found" <<< "${OUTPUT_MISSING}"; then
  echo "expected missing-file message" >&2
  echo "${OUTPUT_MISSING}" >&2
  exit 1
fi

echo "PASS"
