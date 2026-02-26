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
MODE="${MODE:-1}"
FLAGS="${FLAGS:-8}" # 0x08: backend_split (mode=1) => GPU bit_extract-only -> backend KS(gpbs)+premod -> GPU WoKS

TLWE_WORDS="${TLWE_WORDS:-1025}" # lvl1 words
GLWE_WORDS="${GLWE_WORDS:-2049}" # lvl2 words

KEYSET_DEFAULT="$ROOT/tmp_assets/wop_keyset.bin"
KEYSET="${KEYSET:-$KEYSET_DEFAULT}"
REGEN_KEYSET="${REGEN_KEYSET:-0}"

CPU_THREADS="${CPU_THREADS:-16}"
BUILD_JOBS="${BUILD_JOBS:-8}"

SEED="${SEED:-0}"

NO_SUDO="${NO_SUDO:-0}"
SKIP_RELOAD="${SKIP_RELOAD:-0}"

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

GPU_SOCKET_ENV_SET=0
if [ "${GPU_SOCKET+x}" = "x" ]; then
  GPU_SOCKET_ENV_SET=1
fi
GPU_SOCKET="${GPU_SOCKET:-/tmp/wop_gpu_runtime.sock}"
if [ "$NO_SUDO" = "1" ] && [ "$GPU_SOCKET_ENV_SET" = "0" ]; then
  GPU_SOCKET="/tmp/wop_gpu_runtime_be.sock"
fi
GPU_TIMEOUT="${GPU_TIMEOUT:-120}"

WOP_GPU_FORCE_CPU_WOKS="${WOP_GPU_FORCE_CPU_WOKS:-0}"
WOP_GPU_SERVICE_WORKERS="${WOP_GPU_SERVICE_WORKERS:-4}"

csd_no_fallback_require_no_sudo
csd_no_fallback_forbid_env WOP_GPU_FORCE_CPU_WOKS
csd_no_fallback_force_fft

TFHE_GPU_TWIDDLES_LIBM="${TFHE_GPU_TWIDDLES_LIBM:-1}"
TFHE_GPU_SPQLIOS_FFT="${TFHE_GPU_SPQLIOS_FFT:-1}"
TFHE_GPU_SPQLIOS_IFFT="${TFHE_GPU_SPQLIOS_IFFT:-1}"
TFHE_GPU_SPQLIOS_FFT_TABLE="${TFHE_GPU_SPQLIOS_FFT_TABLE:-/tmp/spqlios_fft_table.n4096.bin}"
TFHE_GPU_SPQLIOS_IFFT_TABLE="${TFHE_GPU_SPQLIOS_IFFT_TABLE:-/tmp/spqlios_ifft_table.n4096.bin}"

RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-/tmp/csd_gpu_nvmevirt_be_split_${RUN_ID}}"
mkdir -p "$OUT_DIR"

CPU_RUNNER="${CPU_RUNNER:-$ROOT/sw/gpu_runtime_service/build-clean/cpu_reference_runner}"
KEYSET_EXPORTER="${KEYSET_EXPORTER:-$ROOT/sw/gpu_runtime_service/build-clean/keyset_exporter}"
SPQLIOS_EXPORTER="${SPQLIOS_EXPORTER:-$ROOT/sw/gpu_runtime_service/build-clean/spqlios_table_exporter}"

INPUT_BIN="$OUT_DIR/be_input_lvl1.bin"
GOLDEN_BIN="$OUT_DIR/be_golden_lvl2.bin"
OUT_BIN="$OUT_DIR/be_out_lvl2.bin"

cfg() { printf '[cfg] %-20s %s\n' "$1" "$2"; }

cfg "ROOT" "$ROOT"
cfg "NVMEVIRT_ROOT" "$NVMEVIRT_ROOT"
cfg "dev" "$DEV nsid=$NSID engine=$ENGINE mode=$MODE flags=0x$(printf '%02x' "$FLAGS")"
cfg "words" "tlwe_words=$TLWE_WORDS glwe_words=$GLWE_WORDS"
cfg "keyset" "$KEYSET"
cfg "regen_keyset" "$REGEN_KEYSET"
cfg "seed" "$SEED"
cfg "out_dir" "$OUT_DIR"
cfg "csd_use_prp" "$CSD_USE_PRP no_sudo=$NO_SUDO skip_reload=$SKIP_RELOAD"
cfg "csd_flash_io" "tlwe_in_flash=$CSD_TLWE_IN_FLASH glwe_out_flash=$CSD_GLWE_OUT_FLASH"
cfg "no_fallback" "$CSD_NO_FALLBACK"
cfg "gpu_socket" "$GPU_SOCKET gpu_timeout=$GPU_TIMEOUT force_cpu_woks=$WOP_GPU_FORCE_CPU_WOKS"
cfg "gpu_service_workers" "$WOP_GPU_SERVICE_WORKERS"
cfg "spqlios_fft_table" "$TFHE_GPU_SPQLIOS_FFT_TABLE"
cfg "spqlios_ifft_table" "$TFHE_GPU_SPQLIOS_IFFT_TABLE"
echo
echo "[note] This script will prompt for sudo when NO_SUDO=0 (insmod/rmmod, dmesg, /dev/mem)."
echo

if [ ! -d "$NVMEVIRT_ROOT" ]; then
  echo "[err] nvmevirt repo not found: $NVMEVIRT_ROOT" >&2
  exit 1
fi
if [ ! -x "$E2E_SH" ]; then
  echo "[err] missing e2e script: $E2E_SH" >&2
  exit 1
fi

if [ "$MODE" != "1" ]; then
  echo "[err] expected MODE=1 (BitExtract), got MODE=$MODE" >&2
  exit 1
fi

echo "[1/4] Build gpu_runtime_service (build-clean)"
cmake --build "$ROOT/sw/gpu_runtime_service/build-clean" -j "$BUILD_JOBS"

ensure_spqlios_tables() {
  if [ -f "$TFHE_GPU_SPQLIOS_FFT_TABLE" ] && [ -f "$TFHE_GPU_SPQLIOS_IFFT_TABLE" ]; then
    return 0
  fi
  if [ ! -x "$SPQLIOS_EXPORTER" ]; then
    echo "[err] missing spqlios_table_exporter: $SPQLIOS_EXPORTER" >&2
    exit 1
  fi
  echo "[1.5/4] Generate spqlios FFT/IFFT tables (if missing)"
  "$SPQLIOS_EXPORTER" --fft-prefix "${TFHE_GPU_SPQLIOS_FFT_TABLE%.n4096.bin}" \
                      --ifft-prefix "${TFHE_GPU_SPQLIOS_IFFT_TABLE%.n4096.bin}" \
    >"$OUT_DIR/spqlios_table_exporter.log" 2>&1 || true
  if [ ! -f "$TFHE_GPU_SPQLIOS_FFT_TABLE" ] || [ ! -f "$TFHE_GPU_SPQLIOS_IFFT_TABLE" ]; then
    echo "[err] spqlios table generation failed; see $OUT_DIR/spqlios_table_exporter.log" >&2
    exit 1
  fi
}

ensure_spqlios_tables

if [ "$NO_SUDO" = "1" ]; then
  echo "[2/4] Run user-mode smoke (skipped nvmevirt e2e: NO_SUDO=1)"
  OUT_DIR="$OUT_DIR" \
  KEYSET="$KEYSET" \
  CPU_THREADS="$CPU_THREADS" \
  GPU_SOCKET="$GPU_SOCKET" \
  GPU_TIMEOUT="$GPU_TIMEOUT" \
  WOP_GPU_SERVICE_WORKERS="$WOP_GPU_SERVICE_WORKERS" \
  TFHE_GPU_TWIDDLES_LIBM="$TFHE_GPU_TWIDDLES_LIBM" \
  TFHE_GPU_SPQLIOS_FFT="$TFHE_GPU_SPQLIOS_FFT" \
  TFHE_GPU_SPQLIOS_FFT_TABLE="$TFHE_GPU_SPQLIOS_FFT_TABLE" \
  TFHE_GPU_SPQLIOS_IFFT="$TFHE_GPU_SPQLIOS_IFFT" \
  TFHE_GPU_SPQLIOS_IFFT_TABLE="$TFHE_GPU_SPQLIOS_IFFT_TABLE" \
    bash "$ROOT/scripts/csd_gpu_be_split_backend_smoke.sh"
  exit 0
fi

echo "[2/4] Build nvmevirt (nvmev.ko)"
make -C "$NVMEVIRT_ROOT" -j "$BUILD_JOBS"

if [ "$REGEN_KEYSET" = "1" ]; then
  if [ ! -x "$KEYSET_EXPORTER" ]; then
    echo "[err] keyset_exporter missing/executable: $KEYSET_EXPORTER" >&2
    exit 1
  fi
  echo "[2.5/4] Generate keyset (bkFFT_64+bkFFT_32)"
  "$KEYSET_EXPORTER" "$KEYSET" >/dev/null
  echo "[gen] sha256(keyset)=$(sha256sum "$KEYSET" | awk '{print $1}')"
elif [ ! -f "$KEYSET" ]; then
  echo "[err] missing keyset: $KEYSET" >&2
  exit 1
fi

if [ ! -x "$CPU_RUNNER" ]; then
  echo "[err] cpu_reference_runner missing/executable: $CPU_RUNNER" >&2
  exit 1
fi

echo "[3/4] Generate deterministic lvl1 LWE + golden (mode=1 BitExtract) (threads=$CPU_THREADS)"
PYTHONPATH="$NVMEVIRT_ROOT/tools:${PYTHONPATH:-}" python3 - "$INPUT_BIN" "${SEED:-0}" <<'PY'
from pathlib import Path
import sys
import numpy as np

out = Path(sys.argv[1]).resolve()
seed = int(sys.argv[2])

n_lvl1 = 1024
n_words = n_lvl1 + 1
rng = np.random.default_rng(seed)
lwe_u32 = rng.integers(0, 2**32, size=(n_words,), dtype=np.uint32)
lwe_u64 = lwe_u32.astype(np.uint64)
out.write_bytes(lwe_u64.astype(np.dtype("<u8")).tobytes())
print(f"[gen] n_words={n_words} seed={seed} out={out}", file=sys.stderr)
PY

"$CPU_RUNNER" \
  --mode 1 \
  --word-bytes 8 \
  --tlwe-words "$TLWE_WORDS" \
  --glwe-words "$GLWE_WORDS" \
  --keyset "$KEYSET" \
  --threads "$CPU_THREADS" \
  --tlwe "$INPUT_BIN" \
  --glwe "$GOLDEN_BIN" \
  >"$OUT_DIR/cpu_reference_runner.log" 2>&1

echo "[gen] sha256(input)=$(sha256sum "$INPUT_BIN" | awk '{print $1}')"
echo "[gen] sha256(golden)=$(sha256sum "$GOLDEN_BIN" | awk '{print $1}')"

echo "[4/4] Run nvmevirt e2e (mode=1 BitExtract split) via PRP/memmap staging"

E2E_LOG="$OUT_DIR/e2e.log"
BACKEND_LOG="$OUT_DIR/backend.log"
GPU_SERVICE_LOG="$OUT_DIR/gpu_runtime_service.log"
DMESG_OUT="$OUT_DIR/dmesg_new.log"

rc=0
HPU_FPGA_FIN_ROOT="$ROOT" \
KEYSET="$KEYSET" \
BACKEND_LOG="$BACKEND_LOG" \
GPU_SERVICE_LOG="$GPU_SERVICE_LOG" \
DMESG_OUT="$DMESG_OUT" \
SKIP_RELOAD="$SKIP_RELOAD" \
DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" MODE="$MODE" FLAGS="$FLAGS" \
TLWE_WORDS="$TLWE_WORDS" GLWE_WORDS="$GLWE_WORDS" \
TLWE_FILE="$INPUT_BIN" GOLDEN="$GOLDEN_BIN" OUT_GLWE="$OUT_BIN" \
CSD_USE_PRP="$CSD_USE_PRP" \
GPU_SOCKET="$GPU_SOCKET" GPU_TIMEOUT="$GPU_TIMEOUT" \
TFHE_GPU_TWIDDLES_LIBM="$TFHE_GPU_TWIDDLES_LIBM" \
TFHE_GPU_SPQLIOS_FFT="$TFHE_GPU_SPQLIOS_FFT" \
TFHE_GPU_SPQLIOS_FFT_TABLE="$TFHE_GPU_SPQLIOS_FFT_TABLE" \
TFHE_GPU_SPQLIOS_IFFT="$TFHE_GPU_SPQLIOS_IFFT" \
TFHE_GPU_SPQLIOS_IFFT_TABLE="$TFHE_GPU_SPQLIOS_IFFT_TABLE" \
WOP_GPU_FORCE_CPU_WOKS="$WOP_GPU_FORCE_CPU_WOKS" \
WOP_GPU_CPU_THREADS="$CPU_THREADS" \
WOP_GPU_SERVICE_WORKERS="$WOP_GPU_SERVICE_WORKERS" \
  "$E2E_SH" >"$E2E_LOG" 2>&1 || rc=$?

if [ "$rc" -ne 0 ]; then
  echo "[FAIL] nvmevirt e2e failed: rc=$rc (see: $E2E_LOG)" >&2
  tail -n 200 "$E2E_LOG" >&2 || true
  if [ -f "$BACKEND_LOG" ]; then
    echo "[FAIL] backend tail: $BACKEND_LOG" >&2
    tail -n 200 "$BACKEND_LOG" >&2 || true
  fi
  exit "$rc"
fi

last_match() {
  local pat="$1"
  local file="$2"
  if [ ! -f "$file" ]; then
    return 0
  fi
  if command -v rg >/dev/null 2>&1; then
    rg -e "$pat" "$file" | tail -n 1 || true
  else
    grep -E "$pat" "$file" | tail -n 1 || true
  fi
}

glwe_line="$(last_match "GLWE matches golden" "$E2E_LOG")"
if [ -n "$glwe_line" ]; then
  echo "  | $glwe_line"
fi
metrics_line="$(last_match "metrics cmd=" "$BACKEND_LOG")"
if [ -n "$metrics_line" ]; then
  echo "  | $metrics_line"
fi

echo
echo "[PASS] BE split e2e OK. Artifacts saved under: $OUT_DIR"
