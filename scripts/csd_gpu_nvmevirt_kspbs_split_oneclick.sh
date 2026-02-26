#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSD_NO_FALLBACK="${CSD_NO_FALLBACK:-0}"
# shellcheck source=/dev/null
source "$ROOT/scripts/csd_no_fallback.sh"
NVMEVIRT_ROOT="${NVMEVIRT_ROOT:-$ROOT/../nvmevirt}"
E2E_SH="${E2E_SH:-$NVMEVIRT_ROOT/tools/csd_e2e_smoke.sh}"

DEV="${DEV:-/dev/nvme2n1}"
NSID="${NSID:-1}"
ENGINE="${ENGINE:-gpu}"

# Reuse nvmevirt 2-bit mode space: mode=3(FunctionEval) + flags triggers backend KSPBS split (M8).
MODE="${MODE:-3}"
FLAGS="${FLAGS:-8}" # 0x08: FLAG_FUNC_KSPBS_SPLIT (backend-only trigger; not forwarded to GPU)

SEED="${SEED:-0}"

KEYSET_DEFAULT="$ROOT/tmp_assets/wop_keyset.bin"
KEYSET="${KEYSET:-$KEYSET_DEFAULT}"
BUILD_JOBS="${BUILD_JOBS:-8}"

CSD_USE_PRP_ENV_SET=0
if [ "${CSD_USE_PRP+x}" = "x" ]; then
  CSD_USE_PRP_ENV_SET=1
fi
CSD_USE_PRP="${CSD_USE_PRP:-1}"
CSD_TLWE_IN_FLASH="${CSD_TLWE_IN_FLASH:-0}"
CSD_GLWE_OUT_FLASH="${CSD_GLWE_OUT_FLASH:-0}"
if [ "$CSD_TLWE_IN_FLASH" = "1" ]; then
  if [ "$CSD_USE_PRP_ENV_SET" = "0" ]; then
    CSD_USE_PRP=0
  elif [ "$CSD_USE_PRP" = "1" ]; then
    echo "[err] CSD_TLWE_IN_FLASH=1 requires CSD_USE_PRP=0" >&2
    exit 1
  fi
fi
GPU_SOCKET="${GPU_SOCKET:-/tmp/wop_gpu_runtime.sock}"
GPU_TIMEOUT="${GPU_TIMEOUT:-120}"
NO_SUDO="${NO_SUDO:-0}"

csd_no_fallback_require_no_sudo
csd_no_fallback_force_fft

TFHE_GPU_TWIDDLES_LIBM="${TFHE_GPU_TWIDDLES_LIBM:-1}"
TFHE_GPU_SPQLIOS_FFT="${TFHE_GPU_SPQLIOS_FFT:-1}"
TFHE_GPU_SPQLIOS_IFFT="${TFHE_GPU_SPQLIOS_IFFT:-1}"
TFHE_GPU_SPQLIOS_FFT_TABLE="${TFHE_GPU_SPQLIOS_FFT_TABLE:-/tmp/spqlios_fft_table.n4096.bin}"
TFHE_GPU_SPQLIOS_IFFT_TABLE="${TFHE_GPU_SPQLIOS_IFFT_TABLE:-/tmp/spqlios_ifft_table.n4096.bin}"

RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-/tmp/csd_gpu_nvmevirt_kspbs_split_${RUN_ID}}"
mkdir -p "$OUT_DIR"

INPUT_BIN="$OUT_DIR/kspbs_input_lvl1.bin"
OUT_BIN="$OUT_DIR/kspbs_out_lvl1.bin"

cfg() { printf '[cfg] %-20s %s\n' "$1" "$2"; }

cfg "ROOT" "$ROOT"
cfg "NVMEVIRT_ROOT" "$NVMEVIRT_ROOT"
cfg "dev" "$DEV nsid=$NSID engine=$ENGINE mode=$MODE flags=0x$(printf '%02x' "$FLAGS")"
cfg "seed" "$SEED"
cfg "keyset" "$KEYSET"
cfg "out_dir" "$OUT_DIR"
cfg "csd_use_prp" "$CSD_USE_PRP no_sudo=$NO_SUDO"
cfg "csd_flash_io" "tlwe_in_flash=$CSD_TLWE_IN_FLASH glwe_out_flash=$CSD_GLWE_OUT_FLASH"
cfg "no_fallback" "$CSD_NO_FALLBACK"
cfg "gpu_socket" "$GPU_SOCKET gpu_timeout=$GPU_TIMEOUT"
cfg "spqlios_fft_table" "$TFHE_GPU_SPQLIOS_FFT_TABLE"
cfg "spqlios_ifft_table" "$TFHE_GPU_SPQLIOS_IFFT_TABLE"
echo

if [ ! -d "$NVMEVIRT_ROOT" ]; then
  echo "[err] nvmevirt repo not found: $NVMEVIRT_ROOT" >&2
  exit 1
fi
if [ ! -x "$E2E_SH" ]; then
  echo "[err] missing e2e script: $E2E_SH" >&2
  exit 1
fi
if [ ! -f "$KEYSET" ]; then
  echo "[err] missing keyset: $KEYSET" >&2
  exit 1
fi

echo "[1/4] Build gpu_runtime_service (build-clean)"
cmake --build "$ROOT/sw/gpu_runtime_service/build-clean" -j "$BUILD_JOBS"

spqlios_prefix_from_path() {
  local p="$1"
  if [[ "$p" == *.n4096.bin ]]; then
    echo "${p%.n4096.bin}"
    return 0
  fi
  if [[ "$p" == *.n2048.bin ]]; then
    echo "${p%.n2048.bin}"
    return 0
  fi
  echo "$p"
}

spqlios_file_4096() {
  local p="$1"
  if [[ "$p" == *.n4096.bin ]]; then
    echo "$p"
    return 0
  fi
  if [[ "$p" == *.n2048.bin ]]; then
    echo "${p%.n2048.bin}.n4096.bin"
    return 0
  fi
  echo "${p}.n4096.bin"
}

spqlios_file_2048() {
  local p="$1"
  if [[ "$p" == *.n2048.bin ]]; then
    echo "$p"
    return 0
  fi
  if [[ "$p" == *.n4096.bin ]]; then
    echo "${p%.n4096.bin}.n2048.bin"
    return 0
  fi
  echo "${p}.n2048.bin"
}

ensure_spqlios_tables() {
  local fft4096
  local ifft4096
  fft4096="$(spqlios_file_4096 "$TFHE_GPU_SPQLIOS_FFT_TABLE")"
  ifft4096="$(spqlios_file_4096 "$TFHE_GPU_SPQLIOS_IFFT_TABLE")"
  if [ -f "$fft4096" ] && [ -f "$ifft4096" ]; then
    return 0
  fi

  local exporter="$ROOT/sw/gpu_runtime_service/build-clean/spqlios_table_exporter"
  if [ ! -x "$exporter" ]; then
    echo "[err] missing spqlios_table_exporter: $exporter" >&2
    exit 1
  fi

  local fft_prefix
  local ifft_prefix
  fft_prefix="$(spqlios_prefix_from_path "$TFHE_GPU_SPQLIOS_FFT_TABLE")"
  ifft_prefix="$(spqlios_prefix_from_path "$TFHE_GPU_SPQLIOS_IFFT_TABLE")"

  echo "[1.5/4] Generate spqlios FFT/IFFT tables (if missing)"
  "$exporter" --fft-prefix "$fft_prefix" --ifft-prefix "$ifft_prefix" \
    >"$OUT_DIR/spqlios_table_exporter.log" 2>&1 || true

  fft4096="$(spqlios_file_4096 "$TFHE_GPU_SPQLIOS_FFT_TABLE")"
  ifft4096="$(spqlios_file_4096 "$TFHE_GPU_SPQLIOS_IFFT_TABLE")"
  if [ ! -f "$fft4096" ] || [ ! -f "$ifft4096" ]; then
    echo "[err] missing spqlios tables after generation; see $OUT_DIR/spqlios_table_exporter.log" >&2
    exit 1
  fi
  if [ ! -f "$(spqlios_file_2048 "$TFHE_GPU_SPQLIOS_FFT_TABLE")" ] || \
     [ ! -f "$(spqlios_file_2048 "$TFHE_GPU_SPQLIOS_IFFT_TABLE")" ]; then
    echo "[warn] spqlios n2048 tables not found; lvl1 FFT may fall back to non-spqlios path" >&2
  fi
}

ensure_spqlios_tables

echo "[2/4] Generate deterministic lvl1 LWE input (torus32 packed into 8B words)"
TLWE_WORDS="$(
  PYTHONPATH="$NVMEVIRT_ROOT/tools:${PYTHONPATH:-}" python3 - "$KEYSET" "$INPUT_BIN" "$SEED" <<'PY' | tail -n 1
from pathlib import Path
import sys
import numpy as np
from csd_kspbs_split import read_keyset_header

keyset = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
seed = int(sys.argv[3])

hdr = read_keyset_header(keyset)
n_words = int(hdr.n_lvl1) + 1

rng = np.random.default_rng(seed)
lwe_u32 = rng.integers(0, 2**32, size=(n_words,), dtype=np.uint32)
lwe_u64 = lwe_u32.astype(np.uint64)
out.write_bytes(lwe_u64.astype(np.dtype("<u8")).tobytes())

print(f"[gen] keyset={keyset} n_words={n_words} seed={seed} out={out}", file=sys.stderr)
print(n_words)
PY
)"
GLWE_WORDS="${GLWE_WORDS:-$TLWE_WORDS}"
cfg "words" "tlwe_words=$TLWE_WORDS glwe_words=$GLWE_WORDS"

export WOP_GPU_KEY_IMPORT="$KEYSET"
export WOP_GPU_KEY_EXPORT="$KEYSET"
export TFHE_GPU_TWIDDLES_LIBM="$TFHE_GPU_TWIDDLES_LIBM"
export TFHE_GPU_SPQLIOS_FFT="$TFHE_GPU_SPQLIOS_FFT"
export TFHE_GPU_SPQLIOS_FFT_TABLE="$TFHE_GPU_SPQLIOS_FFT_TABLE"
export TFHE_GPU_SPQLIOS_IFFT="$TFHE_GPU_SPQLIOS_IFFT"
export TFHE_GPU_SPQLIOS_IFFT_TABLE="$TFHE_GPU_SPQLIOS_IFFT_TABLE"

if [ "$NO_SUDO" = "1" ]; then
  echo "[3/4] NO_SUDO=1: run backend smoke (no nvmevirt)"
  SMOKE_OUT_DIR="$OUT_DIR/smoke"
  OUT_DIR="$SMOKE_OUT_DIR" \
  KEYSET="$KEYSET" GPU_SOCKET="$GPU_SOCKET" GPU_TIMEOUT="$GPU_TIMEOUT" \
  TFHE_GPU_TWIDDLES_LIBM="$TFHE_GPU_TWIDDLES_LIBM" \
  TFHE_GPU_SPQLIOS_FFT="$TFHE_GPU_SPQLIOS_FFT" \
  TFHE_GPU_SPQLIOS_IFFT="$TFHE_GPU_SPQLIOS_IFFT" \
  TFHE_GPU_SPQLIOS_FFT_TABLE="$TFHE_GPU_SPQLIOS_FFT_TABLE" \
  TFHE_GPU_SPQLIOS_IFFT_TABLE="$TFHE_GPU_SPQLIOS_IFFT_TABLE" \
    bash "$ROOT/scripts/csd_gpu_kspbs_split_backend_smoke.sh"
  echo
  echo "[PASS] KSPBS split smoke OK. Artifacts saved under: $SMOKE_OUT_DIR"
  exit 0
fi

echo "[3/4] Run nvmevirt e2e KSPBS split (needs sudo)"
make -C "$NVMEVIRT_ROOT" -j "$BUILD_JOBS"

HPU_FPGA_FIN_ROOT="$ROOT" \
KEYSET="$KEYSET" \
BACKEND_LOG="$OUT_DIR/backend.log" \
GPU_SERVICE_LOG="$OUT_DIR/gpu_runtime_service.log" \
DMESG_OUT="$OUT_DIR/dmesg_new.log" \
DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" MODE="$MODE" FLAGS="$FLAGS" \
TLWE_WORDS="$TLWE_WORDS" GLWE_WORDS="$GLWE_WORDS" \
TLWE_FILE="$INPUT_BIN" OUT_GLWE="$OUT_BIN" \
CSD_USE_PRP="$CSD_USE_PRP" \
GPU_SOCKET="$GPU_SOCKET" GPU_TIMEOUT="$GPU_TIMEOUT" \
  "$E2E_SH" > "$OUT_DIR/e2e.log" 2>&1

echo "[4/4] Result"
if command -v rg >/dev/null 2>&1; then
  rg -n "KSPBS_SPLIT|metrics cmd=|doorbell cmd_id=|failed:|PermissionError|Traceback|engine=|status=" "$OUT_DIR/backend.log" | tail -n 120 || true
else
  grep -nE "KSPBS_SPLIT|metrics cmd=|doorbell cmd_id=|failed:|PermissionError|Traceback|engine=|status=" "$OUT_DIR/backend.log" | tail -n 120 || true
fi
if command -v rg >/dev/null 2>&1; then
  pass_line="$(rg -n "\\[KSPBS_SPLIT\\]\\[PASS\\] KSPBS split matches GPU monolithic" "$OUT_DIR/backend.log" || true)"
else
  pass_line="$(grep -n "\\[KSPBS_SPLIT\\]\\[PASS\\] KSPBS split matches GPU monolithic" "$OUT_DIR/backend.log" || true)"
fi
if [ -n "${pass_line:-}" ]; then
  echo
  echo "[PASS] nvmevirt e2e KSPBS split OK. Artifacts saved under: $OUT_DIR"
  exit 0
fi

echo "[FAIL] nvmevirt e2e KSPBS split failed. Artifacts saved under: $OUT_DIR" >&2
exit 2
