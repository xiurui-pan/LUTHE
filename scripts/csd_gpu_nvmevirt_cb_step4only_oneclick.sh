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
MODE="${MODE:-2}"

# step4_only = flags[6] = 0x40 (GPU only WoKS/BR; backend runs PrivKS step5, impl=numpy|cpu_runner)
FLAGS="${FLAGS:-64}"

# CB input: LWE(lvl0) has (n_lvl0+1) words; step4 output has (n_lvl2+1) words.
TLWE_WORDS="${TLWE_WORDS:-501}"
STEP4_WORDS="${STEP4_WORDS:-2049}"
GLWE_WORDS="${GLWE_WORDS:-2048}"
WORD_BYTES="${WORD_BYTES:-8}"

CB_MSG="${CB_MSG:-1}"

REGEN_KEYSET="${REGEN_KEYSET:-0}"
KEYSET_DEFAULT="$ROOT/tmp_assets/wop_keyset.bin"
KEYSET_ENV_SET=0
if [ "${KEYSET+x}" = "x" ]; then
  KEYSET_ENV_SET=1
fi
KEYSET="${KEYSET:-$KEYSET_DEFAULT}"
CPU_THREADS="${CPU_THREADS:-16}"
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
GPU_WOKS_NATIVE="${GPU_WOKS_NATIVE:-1}"
NO_SUDO="${NO_SUDO:-0}"
CSD_PRIVKS_IMPL="${CSD_PRIVKS_IMPL:-numpy}"

TFHE_GPU_TWIDDLES_LIBM="${TFHE_GPU_TWIDDLES_LIBM:-}"
TFHE_GPU_SPQLIOS_FFT="${TFHE_GPU_SPQLIOS_FFT:-}"
TFHE_GPU_SPQLIOS_FFT_TABLE="${TFHE_GPU_SPQLIOS_FFT_TABLE:-}"
TFHE_GPU_SPQLIOS_IFFT="${TFHE_GPU_SPQLIOS_IFFT:-}"
TFHE_GPU_SPQLIOS_IFFT_TABLE="${TFHE_GPU_SPQLIOS_IFFT_TABLE:-}"
WOP_GPU_FORCE_CPU_WOKS="${WOP_GPU_FORCE_CPU_WOKS:-1}"
WOP_GPU_SERVICE_WORKERS="${WOP_GPU_SERVICE_WORKERS:-4}"

RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-/tmp/csd_gpu_nvmevirt_cb_step4only_${RUN_ID}}"

CPU_RUNNER="${CPU_RUNNER:-$ROOT/sw/gpu_runtime_service/build-clean/cpu_reference_runner}"
KEYSET_EXPORTER="${KEYSET_EXPORTER:-$ROOT/sw/gpu_runtime_service/build-clean/keyset_exporter}"

if [ ! -d "$NVMEVIRT_ROOT" ]; then
  echo "[err] nvmevirt repo not found: $NVMEVIRT_ROOT" >&2
  exit 1
fi
if [ ! -x "$E2E_SH" ]; then
  echo "[err] missing e2e script: $E2E_SH" >&2
  exit 1
fi
if [ "$GPU_WOKS_NATIVE" = "1" ]; then
  WOP_GPU_FORCE_CPU_WOKS=0
  : "${TFHE_GPU_TWIDDLES_LIBM:=1}"
  : "${TFHE_GPU_SPQLIOS_FFT:=1}"
  : "${TFHE_GPU_SPQLIOS_IFFT:=1}"
  : "${TFHE_GPU_SPQLIOS_FFT_TABLE:=/tmp/spqlios_fft_table.n4096.bin}"
  : "${TFHE_GPU_SPQLIOS_IFFT_TABLE:=/tmp/spqlios_ifft_table.n4096.bin}"
  if [ "$REGEN_KEYSET" = "0" ] && [ "$KEYSET_ENV_SET" = "0" ]; then
    REGEN_KEYSET=1
    KEYSET="$OUT_DIR/wop_keyset.bin"
  fi
fi

csd_no_fallback_require_no_sudo
csd_no_fallback_forbid_env WOP_GPU_FORCE_CPU_WOKS
csd_no_fallback_force_fft

mkdir -p "$OUT_DIR"

cfg() { printf '[cfg] %-20s %s\n' "$1" "$2"; }

cfg "ROOT" "$ROOT"
cfg "NVMEVIRT_ROOT" "$NVMEVIRT_ROOT"
cfg "dev" "$DEV nsid=$NSID engine=$ENGINE mode=$MODE flags=0x$(printf '%02x' "$FLAGS")"
cfg "words" "tlwe_words=$TLWE_WORDS step4_words=$STEP4_WORDS glwe_words=$GLWE_WORDS word_bytes=$WORD_BYTES"
cfg "cb_msg" "$CB_MSG"
cfg "keyset" "$KEYSET regen_keyset=$REGEN_KEYSET"
cfg "cpu_threads" "$CPU_THREADS"
cfg "out_dir" "$OUT_DIR"
cfg "csd_use_prp" "$CSD_USE_PRP no_sudo=$NO_SUDO"
cfg "csd_flash_io" "tlwe_in_flash=$CSD_TLWE_IN_FLASH glwe_out_flash=$CSD_GLWE_OUT_FLASH"
cfg "csd_privks_impl" "$CSD_PRIVKS_IMPL"
cfg "no_fallback" "$CSD_NO_FALLBACK"
cfg "gpu_socket" "$GPU_SOCKET gpu_timeout=$GPU_TIMEOUT force_cpu_woks=$WOP_GPU_FORCE_CPU_WOKS"
cfg "gpu_service_workers" "$WOP_GPU_SERVICE_WORKERS"
cfg "gpu_woks_native" "$GPU_WOKS_NATIVE"
if [ "$GPU_WOKS_NATIVE" = "1" ]; then
  cfg "spqlios_fft_table" "$TFHE_GPU_SPQLIOS_FFT_TABLE"
  cfg "spqlios_ifft_table" "$TFHE_GPU_SPQLIOS_IFFT_TABLE"
fi
echo

if [ "$WORD_BYTES" != "8" ]; then
  echo "[err] This script currently requires WORD_BYTES=8 (torus64), got WORD_BYTES=$WORD_BYTES" >&2
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

  local fft_prefix
  local ifft_prefix
  fft_prefix="$(spqlios_prefix_from_path "$TFHE_GPU_SPQLIOS_FFT_TABLE")"
  ifft_prefix="$(spqlios_prefix_from_path "$TFHE_GPU_SPQLIOS_IFFT_TABLE")"
  local exporter="$ROOT/sw/gpu_runtime_service/build-clean/spqlios_table_exporter"
  if [ ! -x "$exporter" ]; then
    echo "[err] missing spqlios_table_exporter: $exporter" >&2
    exit 1
  fi

  echo "[1.5/4] Generate spqlios FFT/IFFT tables (if missing)"
  "$exporter" --fft-prefix "$fft_prefix" --ifft-prefix "$ifft_prefix" \
    >"$OUT_DIR/spqlios_table_exporter.log" 2>&1 || true

  fft4096="$(spqlios_file_4096 "$TFHE_GPU_SPQLIOS_FFT_TABLE")"
  ifft4096="$(spqlios_file_4096 "$TFHE_GPU_SPQLIOS_IFFT_TABLE")"
  if [ ! -f "$fft4096" ]; then
    echo "[err] missing spqlios FFT table after generation: $fft4096" >&2
    echo "[err] see: $OUT_DIR/spqlios_table_exporter.log" >&2
    exit 1
  fi
  if [ ! -f "$ifft4096" ]; then
    echo "[err] missing spqlios IFFT table after generation: $ifft4096" >&2
    echo "[err] see: $OUT_DIR/spqlios_table_exporter.log" >&2
    exit 1
  fi
  if [ ! -f "$(spqlios_file_2048 "$TFHE_GPU_SPQLIOS_FFT_TABLE")" ] || \
     [ ! -f "$(spqlios_file_2048 "$TFHE_GPU_SPQLIOS_IFFT_TABLE")" ]; then
    echo "[warn] spqlios n2048 tables not found; lvl1 FFT may fall back to non-spqlios path" >&2
  fi
}

if [ "$GPU_WOKS_NATIVE" = "1" ]; then
  ensure_spqlios_tables
fi

if [ "$NO_SUDO" = "1" ]; then
  echo "[2/4] Build nvmevirt (skipped: NO_SUDO=1)"
else
  echo "[2/4] Build nvmevirt (nvmev.ko)"
  make -C "$NVMEVIRT_ROOT" -j "$BUILD_JOBS"
fi

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

TLWE_FILE="$OUT_DIR/cb_input_lvl0_msg${CB_MSG}.bin"
STEP4_CPU="$OUT_DIR/cb_step4_cpu.bin"
GOLDEN="$OUT_DIR/cb_step5_golden.bin"

echo "[3/4] Generate deterministic CB TLWE + golden (step5 on CPU)"
"$CPU_RUNNER" \
  --mode 2 \
  --word-bytes "$WORD_BYTES" \
  --tlwe-words "$TLWE_WORDS" \
  --glwe-words "$STEP4_WORDS" \
  --threads "$CPU_THREADS" \
  --keyset "$KEYSET" \
  --synth-lvl0 "$CB_MSG" \
  --tlwe "$TLWE_FILE" \
  --glwe "$STEP4_CPU" >/dev/null
echo "[gen] sha256(tlwe)=$(sha256sum "$TLWE_FILE" | awk '{print $1}')"
echo "[gen] sha256(step4_cpu)=$(sha256sum "$STEP4_CPU" | awk '{print $1}')"

"$CPU_RUNNER" \
  --mode 2 \
  --word-bytes 8 \
  --tlwe-words "$STEP4_WORDS" \
  --glwe-words "$GLWE_WORDS" \
  --threads "$CPU_THREADS" \
  --keyset "$KEYSET" \
  --privks-step4 \
  --tlwe "$STEP4_CPU" \
  --glwe "$GOLDEN" >/dev/null
echo "[gen] sha256(golden_step5)=$(sha256sum "$GOLDEN" | awk '{print $1}')"

export TFHE_GPU_TWIDDLES_LIBM="$TFHE_GPU_TWIDDLES_LIBM"
export TFHE_GPU_SPQLIOS_FFT="$TFHE_GPU_SPQLIOS_FFT"
export TFHE_GPU_SPQLIOS_FFT_TABLE="$TFHE_GPU_SPQLIOS_FFT_TABLE"
export TFHE_GPU_SPQLIOS_IFFT="$TFHE_GPU_SPQLIOS_IFFT"
export TFHE_GPU_SPQLIOS_IFFT_TABLE="$TFHE_GPU_SPQLIOS_IFFT_TABLE"

if [ "$NO_SUDO" = "1" ]; then
  echo "[4/4] Run user-mode smoke (NO_SUDO=1): GPU step4_only -> step5(cpu_reference_runner --privks-step4) -> cmp golden"
  if [ "$MODE" != "2" ]; then
    echo "[err] NO_SUDO=1 currently supports MODE=2 (CB) only, got MODE=$MODE" >&2
    exit 1
  fi
  SMOKE_BIN="$ROOT/sw/gpu_runtime_service/build-clean/gpu_executor_smoke"
  if [ ! -x "$SMOKE_BIN" ]; then
    echo "[err] missing smoke binary: $SMOKE_BIN" >&2
    exit 1
  fi

  export WOP_GPU_KEY_IMPORT="$KEYSET"
  export WOP_GPU_FORCE_CPU_WOKS="$WOP_GPU_FORCE_CPU_WOKS"
  export WOP_GPU_CPU_THREADS="$CPU_THREADS"
  export GPU_SMOKE_WORD_BYTES="$WORD_BYTES"
  export GPU_SMOKE_GLWE_WORDS="$STEP4_WORDS"
  export GPU_SMOKE_FLAGS="$FLAGS"

  STEP4_GPU="$OUT_DIR/cb_step4_gpu.bin"
  OUT_GLWE="$OUT_DIR/cb_step5_out.bin"

  "$SMOKE_BIN" CB "$TLWE_FILE" "$STEP4_GPU" >"$OUT_DIR/smoke_cb.log" 2>&1

  "$CPU_RUNNER" \
    --mode 2 \
    --word-bytes 8 \
    --tlwe-words "$STEP4_WORDS" \
    --glwe-words "$GLWE_WORDS" \
    --threads "$CPU_THREADS" \
    --keyset "$KEYSET" \
    --privks-step4 \
    --tlwe "$STEP4_GPU" \
    --glwe "$OUT_GLWE" >/dev/null

  if cmp -s "$OUT_GLWE" "$GOLDEN"; then
    echo "[PASS] Smoke OK: step5 matches golden (OUT_GLWE=$OUT_GLWE)"
    exit 0
  fi
  echo "[FAIL] Smoke mismatch vs golden" >&2
  echo "[FAIL] out=$OUT_GLWE golden=$GOLDEN" >&2
  exit 2
fi

echo "[4/4] Run nvmevirt e2e (needs sudo): 0xC0 -> backend (GPU step4_only + backend privks-step4, impl=$CSD_PRIVKS_IMPL) -> /dev/mem"
OUT_GLWE="$OUT_DIR/cb_step5_out.bin"
E2E_LOG="$OUT_DIR/e2e.log"
rc=0
HPU_FPGA_FIN_ROOT="$ROOT" \
KEYSET="$KEYSET" \
DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" MODE="$MODE" FLAGS="$FLAGS" \
TLWE_WORDS="$TLWE_WORDS" GLWE_WORDS="$GLWE_WORDS" \
TLWE_FILE="$TLWE_FILE" GOLDEN="$GOLDEN" OUT_GLWE="$OUT_GLWE" \
CSD_USE_PRP="$CSD_USE_PRP" \
CSD_PRIVKS_IMPL="$CSD_PRIVKS_IMPL" \
BACKEND_LOG="$OUT_DIR/backend.log" \
GPU_SERVICE_LOG="$OUT_DIR/gpu_runtime_service.log" \
DMESG_OUT="$OUT_DIR/dmesg_new.log" \
GPU_SOCKET="$GPU_SOCKET" GPU_TIMEOUT="$GPU_TIMEOUT" \
WOP_GPU_FORCE_CPU_WOKS="$WOP_GPU_FORCE_CPU_WOKS" \
WOP_GPU_CPU_THREADS="$CPU_THREADS" \
WOP_GPU_SERVICE_WORKERS="$WOP_GPU_SERVICE_WORKERS" \
  "$E2E_SH" >"$E2E_LOG" 2>&1 || rc=$?

if [ "$rc" -ne 0 ]; then
  echo "[FAIL] nvmevirt e2e failed (rc=$rc). Artifacts: $OUT_DIR" >&2
  echo "[FAIL] see: $E2E_LOG" >&2
  tail -n 200 "$E2E_LOG" >&2 || true
  if [ -f "$OUT_DIR/backend.log" ]; then
    echo "[FAIL] backend tail: $OUT_DIR/backend.log" >&2
    tail -n 200 "$OUT_DIR/backend.log" >&2 || true
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
metrics_line="$(last_match "metrics cmd=" "$OUT_DIR/backend.log")"
if [ -n "$metrics_line" ]; then
  echo "  | $metrics_line"
fi

echo
echo "[PASS] CB step4_only split e2e OK. Artifacts saved under: $OUT_DIR"
