#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)
PRECHECK_SCRIPT="${SCRIPT_DIR}/precheck_linux_boot.sh"

FW_PAYLOAD="${HOME}/rv32-linux/out/fw_payload.bin"
DTB="${HOME}/rv32-linux/out/npc.dtb"
VIRTIO_BLK_IMAGE="${HOME}/rv32-linux/out/rootfs.img"
OPENSBI_BIN="${HOME}/rv32-linux/src/opensbi/build/platform/generic/firmware/fw_payload.bin"
OUT_PAYLOAD_MIRROR="${HOME}/rv32-linux/out/fw_payload.bin"
FIRMWARE_LOAD_BASE="0x80400000"
TIMEOUT_SEC=240
MAX_CYCLES=80000000
PROGRESS=0
LOG_DIR="${NPC_HOME}/build/linux-smoke/$(date +%Y%m%d-%H%M%S)"
SMOKE_MODE="quick"
RUN_PRECHECK=1
DEFAULT_MARKERS=()
USER_MARKERS=()
CLEAR_DEFAULT_MARKERS=0

emit_known_failure_hints() {
  local log_file="$1"
  if grep -q "clint init failed" "${log_file}"; then
    echo "[linux-smoke] HINT: OpenSBI failed to init CLINT. Check DTB has cpus/timebase-frequency." >&2
  fi

  if grep -q "last_pc=0x80441088" "${log_file}" &&
     grep -Eq "no_commit=[1-9][0-9]{5,}" "${log_file}"; then
    echo "[linux-smoke] HINT: detected stall at S-mode entry PC 0x80441088 with no_commit growing." >&2
    echo "[linux-smoke] HINT: likely payload contains RVC compressed instructions, but current CPU ISA is rv32ima (no C)." >&2
    echo "[linux-smoke] HINT: rebuild Linux/OpenSBI payload with -march=rv32ima -mabi=ilp32 and disable CONFIG_RISCV_ISA_C." >&2
  fi

  if grep -q "last_pc=0x80801064" "${log_file}" &&
     grep -Eq "no_commit=[1-9][0-9]{5,}" "${log_file}"; then
    echo "[linux-smoke] HINT: detected stall at Linux early entry PC 0x80801064 (c.jr x1) with no_commit growing." >&2
    echo "[linux-smoke] HINT: check RVC control-flow path (c.jr/c.jalr) and post-jump frontend redirect/commit progress." >&2
  fi
}

has_linux_execution_progress() {
  local log_file="$1"
  local line pc_hex
  while IFS= read -r line; do
    if [[ "${line}" =~ last_pc=0x([0-9a-fA-F]+) ]]; then
      pc_hex="${BASH_REMATCH[1]}"
      # Treat progress PCs in S-mode Linux image range as Linux execution evidence.
      if (( 16#${pc_hex} >= 0x80800000 )); then
        return 0
      fi
    fi
  done < <(grep -E "\\[progress\\]" "${log_file}" || true)
  return 1
}

usage() {
  cat <<'EOF'
Usage: run_linux_smoke.sh [options]
  --fw-payload <path>         OpenSBI fw_payload.bin
  --opensbi-bin <path>        OpenSBI build output used for precheck compare
  --out-payload <path>        Mirrored payload path for precheck compare
  --dtb <path>                DTB path
  --virtio-blk-image <path>   Rootfs block image
  --mode <quick|full>         quick: OpenSBI+handoff markers; full: Linux marker
  --no-precheck               Skip payload/DTB precheck
  --firmware-load-base <addr> Firmware load base (default: 0x80400000)
  --timeout-sec <n>           Timeout seconds (0 disables timeout)
  --max-cycles <n>            --max-cycles passed to npc
  --progress <n>              --progress passed to npc
  --log-dir <path>            Log output directory
  --marker <text>             Add required log marker (repeatable)
  --clear-default-markers     Require only markers passed by --marker
  -h, --help                  Show help
EOF
}

expand_path() {
  local p="$1"
  if [[ "${p}" == "~" ]]; then
    printf '%s\n' "${HOME}"
    return
  fi
  if [[ "${p}" == "~/"* ]]; then
    printf '%s/%s\n' "${HOME}" "${p#"~/"}"
    return
  fi
  printf '%s\n' "${p}"
}

setup_default_markers() {
  case "${SMOKE_MODE}" in
    quick)
      DEFAULT_MARKERS=("OpenSBI" "Domain0 Next Address")
      ;;
    full)
      DEFAULT_MARKERS=("OpenSBI" "Linux version")
      ;;
    *)
      echo "[linux-smoke] ERROR: unsupported --mode '${SMOKE_MODE}' (expected quick|full)" >&2
      exit 2
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fw-payload)
      FW_PAYLOAD="$2"
      shift 2
      ;;
    --opensbi-bin)
      OPENSBI_BIN="$2"
      shift 2
      ;;
    --out-payload)
      OUT_PAYLOAD_MIRROR="$2"
      shift 2
      ;;
    --dtb)
      DTB="$2"
      shift 2
      ;;
    --virtio-blk-image)
      VIRTIO_BLK_IMAGE="$2"
      shift 2
      ;;
    --mode)
      SMOKE_MODE="$2"
      shift 2
      ;;
    --no-precheck)
      RUN_PRECHECK=0
      shift 1
      ;;
    --firmware-load-base)
      FIRMWARE_LOAD_BASE="$2"
      shift 2
      ;;
    --timeout-sec)
      TIMEOUT_SEC="$2"
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
    --log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --marker)
      USER_MARKERS+=("$2")
      shift 2
      ;;
    --clear-default-markers)
      CLEAR_DEFAULT_MARKERS=1
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[linux-smoke] ERROR: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

FW_PAYLOAD=$(expand_path "${FW_PAYLOAD}")
OPENSBI_BIN=$(expand_path "${OPENSBI_BIN}")
OUT_PAYLOAD_MIRROR=$(expand_path "${OUT_PAYLOAD_MIRROR}")
DTB=$(expand_path "${DTB}")
VIRTIO_BLK_IMAGE=$(expand_path "${VIRTIO_BLK_IMAGE}")
LOG_DIR=$(expand_path "${LOG_DIR}")
setup_default_markers
if [[ "${CLEAR_DEFAULT_MARKERS}" -eq 1 ]]; then
  MARKERS=("${USER_MARKERS[@]}")
else
  MARKERS=("${DEFAULT_MARKERS[@]}" "${USER_MARKERS[@]}")
fi

if [[ ! "${FIRMWARE_LOAD_BASE}" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]]; then
  echo "[linux-smoke] ERROR: invalid --firmware-load-base '${FIRMWARE_LOAD_BASE}'" >&2
  exit 2
fi
base_val=$((FIRMWARE_LOAD_BASE))
if (( (base_val & 0x3fffff) != 0 )); then
  echo "[linux-smoke] ERROR: firmware-load-base must be 4MiB aligned for RV32 Linux early MMU setup." >&2
  echo "[linux-smoke] HINT: use 0x80400000 (default) or another 0x400000-aligned address." >&2
  exit 2
fi

if [[ ! -f "${FW_PAYLOAD}" ]]; then
  echo "[linux-smoke] ERROR: fw payload not found: ${FW_PAYLOAD}" >&2
  exit 1
fi
if [[ ! -f "${DTB}" ]]; then
  echo "[linux-smoke] ERROR: dtb not found: ${DTB}" >&2
  exit 1
fi
if [[ ! -f "${VIRTIO_BLK_IMAGE}" ]]; then
  echo "[linux-smoke] ERROR: virtio blk image not found: ${VIRTIO_BLK_IMAGE}" >&2
  exit 1
fi

if [[ "${RUN_PRECHECK}" -eq 1 ]]; then
  if [[ "${FW_PAYLOAD}" == "${OUT_PAYLOAD_MIRROR}" ]]; then
    if [[ ! -x "${PRECHECK_SCRIPT}" ]]; then
      echo "[linux-smoke] ERROR: precheck script missing: ${PRECHECK_SCRIPT}" >&2
      exit 1
    fi
    if ! "${PRECHECK_SCRIPT}" \
      --opensbi-bin "${OPENSBI_BIN}" \
      --out-bin "${OUT_PAYLOAD_MIRROR}" \
      --dtb "${DTB}" \
      --firmware-load-base "${FIRMWARE_LOAD_BASE}" \
      --max-cycles "${MAX_CYCLES}" \
      --progress "${PROGRESS}"; then
      echo "[linux-smoke] ERROR: precheck failed." >&2
      exit 1
    fi
  else
    echo "[linux-smoke] WARN: skip precheck because --fw-payload differs from --out-payload mirror." >&2
  fi
fi

if [[ "${#MARKERS[@]}" -eq 0 ]]; then
  echo "[linux-smoke] ERROR: no markers configured" >&2
  exit 2
fi

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/linux-smoke.log"

ARGS="--boot-handoff --dtb ${DTB} --virtio-blk-image ${VIRTIO_BLK_IMAGE} --firmware-load-base ${FIRMWARE_LOAD_BASE} --max-cycles ${MAX_CYCLES} --progress ${PROGRESS}"
CMD=(make sim DIFFTEST= IMG="${FW_PAYLOAD}" ARGS="${ARGS}")

echo "[linux-smoke] npc home: ${NPC_HOME}"
echo "[linux-smoke] mode: ${SMOKE_MODE}"
echo "[linux-smoke] log: ${LOG_FILE}"

pushd "${NPC_HOME}" >/dev/null
set +e
if [[ "${TIMEOUT_SEC}" -gt 0 ]]; then
  timeout "${TIMEOUT_SEC}s" "${CMD[@]}" >"${LOG_FILE}" 2>&1
  RC=$?
else
  "${CMD[@]}" >"${LOG_FILE}" 2>&1
  RC=$?
fi
set -e
popd >/dev/null

timed_out=0
cycle_timeout=0
if [[ "${RC}" -eq 124 ]]; then
  timed_out=1
  echo "[linux-smoke] WARN: timeout after ${TIMEOUT_SEC}s, validating markers from collected log." >&2
elif [[ "${RC}" -ne 0 ]] && grep -q "TIMEOUT after" "${LOG_FILE}"; then
  cycle_timeout=1
  echo "[linux-smoke] WARN: simulator hit max-cycles, validating markers from collected log." >&2
elif [[ "${RC}" -ne 0 ]]; then
  echo "[linux-smoke] ERROR: make sim exited with ${RC}" >&2
  emit_known_failure_hints "${LOG_FILE}"
  tail -n 40 "${LOG_FILE}" | sed 's/^/[linux-smoke] | /' >&2 || true
  exit 1
fi

linux_progress_fallback=0
if [[ "${SMOKE_MODE}" == "full" ]] && has_linux_execution_progress "${LOG_FILE}"; then
  linux_progress_fallback=1
fi

missing=()
for marker in "${MARKERS[@]}"; do
  if [[ "${linux_progress_fallback}" -eq 1 ]] && [[ "${marker}" == "Linux version" ]]; then
    continue
  fi
  if ! grep -q "${marker}" "${LOG_FILE}"; then
    missing+=("${marker}")
  fi
done

if [[ "${#missing[@]}" -ne 0 ]]; then
  echo "[linux-smoke] ERROR: missing markers:" >&2
  for marker in "${missing[@]}"; do
    echo "[linux-smoke]   - ${marker}" >&2
  done
  if [[ "${timed_out}" -eq 1 ]]; then
    echo "[linux-smoke] ERROR: timed out before required markers were fully observed." >&2
  elif [[ "${cycle_timeout}" -eq 1 ]]; then
    echo "[linux-smoke] ERROR: hit max-cycles before required markers were fully observed." >&2
  fi
  emit_known_failure_hints "${LOG_FILE}"
  tail -n 40 "${LOG_FILE}" | sed 's/^/[linux-smoke] | /' >&2 || true
  exit 1
fi

echo "[linux-smoke] PASS"
if [[ "${timed_out}" -eq 1 ]]; then
  echo "[linux-smoke] note: timeout occurred but required markers were observed."
fi
if [[ "${cycle_timeout}" -eq 1 ]]; then
  echo "[linux-smoke] note: max-cycles reached but required markers were observed."
fi
if [[ "${linux_progress_fallback}" -eq 1 ]] && ! grep -q "Linux version" "${LOG_FILE}"; then
  echo "[linux-smoke] note: Linux execution detected via progress PC fallback (no Linux version UART marker)."
fi
echo "[linux-smoke] matched markers: ${MARKERS[*]}"
echo "[linux-smoke] log: ${LOG_FILE}"
