#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)

OPEN_SBI_BIN="${HOME}/rv32-linux/src/opensbi/build/platform/generic/firmware/fw_payload.bin"
OUT_BIN="${HOME}/rv32-linux/out/fw_payload.bin"
DTB="${HOME}/rv32-linux/out/npc.dtb"
FIRMWARE_LOAD_BASE="0x80400000"
MAX_CYCLES="20000000"
PROGRESS="1000000"

usage() {
  cat <<'EOF'
Usage: precheck_linux_boot.sh [options]
  --opensbi-bin <path>         OpenSBI built fw_payload.bin
  --out-bin <path>             Mirror fw_payload.bin used by npc sim
  --dtb <path>                 DTB file for boot handoff
  --firmware-load-base <addr>  Firmware load base (default: 0x80400000)
  --max-cycles <n>             Max simulation cycles (default: 20000000)
  --progress <n>               Progress interval (default: 1000000)
  -h, --help                   Show this help
EOF
}

expand_path() {
  local path="$1"
  if [[ "${path}" == "~" ]]; then
    printf '%s\n' "${HOME}"
    return
  fi
  if [[ "${path}" == "~/"* ]]; then
    printf '%s/%s\n' "${HOME}" "${path#"~/"}"
    return
  fi
  printf '%s\n' "${path}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --opensbi-bin)
      OPEN_SBI_BIN="$2"
      shift 2
      ;;
    --out-bin)
      OUT_BIN="$2"
      shift 2
      ;;
    --dtb)
      DTB="$2"
      shift 2
      ;;
    --firmware-load-base)
      FIRMWARE_LOAD_BASE="$2"
      shift 2
      ;;
    --max-cycles)
      MAX_CYCLES="$2"
      shift 2
      ;;
    --progress)
      PROGRESS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[precheck] ERROR: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

OPEN_SBI_BIN=$(expand_path "${OPEN_SBI_BIN}")
OUT_BIN=$(expand_path "${OUT_BIN}")
DTB=$(expand_path "${DTB}")

if [[ ! "${FIRMWARE_LOAD_BASE}" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]]; then
  echo "[precheck] ERROR: invalid --firmware-load-base '${FIRMWARE_LOAD_BASE}'" >&2
  exit 2
fi
base_val=$((FIRMWARE_LOAD_BASE))
if (( (base_val & 0x3fffff) != 0 )); then
  echo "[precheck] ERROR: firmware-load-base must be 4MiB aligned for RV32 Linux early MMU setup." >&2
  echo "[precheck] HINT: use 0x80400000 (default) or another 0x400000-aligned address." >&2
  exit 2
fi

if [[ ! -f "${OPEN_SBI_BIN}" ]]; then
  echo "[precheck] ERROR: OpenSBI payload not found: ${OPEN_SBI_BIN}" >&2
  exit 1
fi
if [[ ! -f "${OUT_BIN}" ]]; then
  echo "[precheck] ERROR: output payload not found: ${OUT_BIN}" >&2
  exit 1
fi
if [[ ! -f "${DTB}" ]]; then
  echo "[precheck] ERROR: dtb not found: ${DTB}" >&2
  exit 1
fi

if ! cmp -s "${OPEN_SBI_BIN}" "${OUT_BIN}"; then
  echo "[precheck] ERROR: payload mismatch between OpenSBI build and out mirror." >&2
  echo "[precheck]   opensbi: ${OPEN_SBI_BIN}" >&2
  echo "[precheck]   out:     ${OUT_BIN}" >&2
  echo "[precheck] Fix with:" >&2
  echo "cp \"${OPEN_SBI_BIN}\" \"${OUT_BIN}\"" >&2
  exit 1
fi

echo "[precheck] PASS: payloads match."
echo "[precheck] Run:"
echo "cd \"${NPC_HOME}\""
echo "make sim DIFFTEST= IMG=\"${OUT_BIN}\" ARGS=\"--boot-handoff --dtb ${DTB} --firmware-load-base ${FIRMWARE_LOAD_BASE} --max-cycles ${MAX_CYCLES} --progress ${PROGRESS}\""
