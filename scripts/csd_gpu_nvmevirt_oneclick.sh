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
MODE="${MODE:-0}"
ENGINE="${ENGINE:-gpu}"
TLWE_WORDS="${TLWE_WORDS:-20500}"
GLWE_WORDS="${GLWE_WORDS:-2049}"

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
GPU_WOKS_NATIVE="${GPU_WOKS_NATIVE:-0}"
NO_SUDO="${NO_SUDO:-0}"
TFHE_GPU_TWIDDLES_LIBM="${TFHE_GPU_TWIDDLES_LIBM:-}"
TFHE_GPU_SPQLIOS_FFT="${TFHE_GPU_SPQLIOS_FFT:-}"
TFHE_GPU_SPQLIOS_FFT_TABLE="${TFHE_GPU_SPQLIOS_FFT_TABLE:-}"
TFHE_GPU_SPQLIOS_IFFT="${TFHE_GPU_SPQLIOS_IFFT:-}"
TFHE_GPU_SPQLIOS_IFFT_TABLE="${TFHE_GPU_SPQLIOS_IFFT_TABLE:-}"
WOP_GPU_FORCE_CPU_WOKS="${WOP_GPU_FORCE_CPU_WOKS:-1}"
WOP_GPU_SERVICE_WORKERS="${WOP_GPU_SERVICE_WORKERS:-4}"
# Optional (mode=0 only): run VP KeySwitch on backend via descriptor flags (see docs/gpu_csd_operator_contract.md).
CSD_VP_KS_ON_BACKEND="${CSD_VP_KS_ON_BACKEND:-0}"

RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-/tmp/csd_gpu_nvmevirt_oneclick_${RUN_ID}}"

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
cfg "dev" "$DEV nsid=$NSID engine=$ENGINE mode=$MODE"
cfg "words" "tlwe_words=$TLWE_WORDS glwe_words=$GLWE_WORDS"
cfg "keyset" "$KEYSET"
cfg "regen_keyset" "$REGEN_KEYSET"
cfg "cpu_threads" "$CPU_THREADS (must match WOP_GPU_CPU_THREADS)"
cfg "out_dir" "$OUT_DIR"
cfg "csd_use_prp" "$CSD_USE_PRP"
cfg "csd_flash_io" "tlwe_in_flash=$CSD_TLWE_IN_FLASH glwe_out_flash=$CSD_GLWE_OUT_FLASH"
cfg "csd_vp_ks_on_backend" "$CSD_VP_KS_ON_BACKEND"
cfg "gpu_socket" "$GPU_SOCKET gpu_timeout=$GPU_TIMEOUT force_cpu_woks=$WOP_GPU_FORCE_CPU_WOKS"
cfg "gpu_service_workers" "$WOP_GPU_SERVICE_WORKERS"
cfg "gpu_woks_native" "$GPU_WOKS_NATIVE"
cfg "no_sudo" "$NO_SUDO"
cfg "no_fallback" "$CSD_NO_FALLBACK"
if [ "$GPU_WOKS_NATIVE" = "1" ]; then
  cfg "spqlios_fft_table" "$TFHE_GPU_SPQLIOS_FFT_TABLE"
  cfg "spqlios_ifft_table" "$TFHE_GPU_SPQLIOS_IFFT_TABLE"
fi
echo
echo "[note] This script will prompt for sudo (insmod/rmmod, dmesg, /dev/mem)."
echo

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

gen_assets() {
  local name="$1"
  local index="$2"
  local vp_lut="$3"
  local tlwe_out="$4"
  local golden_out="$5"
  local args=(
    --mode 0
    --word-bytes 8
    --tlwe-words "$TLWE_WORDS"
    --glwe-words "$GLWE_WORDS"
    --keyset "$KEYSET"
    --threads "$CPU_THREADS"
    --synth-vp "$index"
    --vp-lut "$vp_lut"
    --tlwe "$tlwe_out"
    --glwe "$golden_out"
  )
  echo "[gen] $name: synth-vp=$index vp-lut=$vp_lut"
  "$CPU_RUNNER" "${args[@]}" >/dev/null
  echo "[gen] sha256(tlwe)=$(sha256sum "$tlwe_out" | awk '{print $1}')"
  echo "[gen] sha256(golden)=$(sha256sum "$golden_out" | awk '{print $1}')"
}

run_case() {
  local name="$1"
  local flags="$2"
  local tlwe_file="$3"
  local golden="$4"
  local out_glwe="$5"
  local skip_reload="${6:-0}"
  local e2e_log="$OUT_DIR/${name}_e2e.log"
  local backend_log="$OUT_DIR/${name}_backend.log"

  echo
  echo "[run] case=$name flags=0x$(printf '%02x' "$flags")"

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

  local rc=0
  HPU_FPGA_FIN_ROOT="$ROOT" \
  KEYSET="$KEYSET" \
  BACKEND_LOG="$backend_log" \
  GPU_SERVICE_LOG="$OUT_DIR/${name}_gpu_runtime_service.log" \
  DMESG_OUT="$OUT_DIR/${name}_dmesg_new.log" \
  SKIP_RELOAD="$skip_reload" \
  DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" MODE="$MODE" FLAGS="$flags" \
  TLWE_WORDS="$TLWE_WORDS" GLWE_WORDS="$GLWE_WORDS" \
  TLWE_FILE="$tlwe_file" GOLDEN="$golden" OUT_GLWE="$out_glwe" \
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
    "$E2E_SH" >"$e2e_log" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    echo "[FAIL] nvmevirt e2e failed: case=$name rc=$rc (see: $e2e_log)" >&2
    tail -n 200 "$e2e_log" >&2 || true
    if [ -f "$backend_log" ]; then
      echo "[FAIL] backend tail: $backend_log" >&2
      tail -n 200 "$backend_log" >&2 || true
    fi
    exit "$rc"
  fi

  local glwe_line
  glwe_line="$(last_match "GLWE matches golden" "$e2e_log")"
  if [ -n "$glwe_line" ]; then
    echo "  | $glwe_line"
  fi
  local metrics_line
  metrics_line="$(last_match "metrics cmd=" "$backend_log")"
  if [ -n "$metrics_line" ]; then
    echo "  | $metrics_line"
  fi
}

echo "[3/4] Generate deterministic TLWE+golden assets (threads=$CPU_THREADS)"
vp_tlwe="$OUT_DIR/vp_input_index42.bin"
vp_golden="$OUT_DIR/vp_golden_index42.bin"
exp_tlwe="$OUT_DIR/exp_input_index43.bin"
exp_golden="$OUT_DIR/exp_golden_index43.bin"
soft_tlwe="$OUT_DIR/soft_input_index44.bin"
soft_golden="$OUT_DIR/soft_golden_index44.bin"

gen_assets "vp" 42 "test" "$vp_tlwe" "$vp_golden"
gen_assets "exp" 43 "exp_minus" "$exp_tlwe" "$exp_golden"
gen_assets "soft" 44 "exp_minus" "$soft_tlwe" "$soft_golden"

# mode=0 flags:
#   - 0x04: VP LUT selector (exp_minus)
#   - 0x08: backend VP split trigger (GPU biglut-only -> backend KS+premod -> GPU WoKS)
VP_SPLIT_FLAG=8
vp_flags=0
exp_flags=4
soft_flags=4
if [ -n "${CSD_VP_KS_ON_BACKEND:-}" ] && [ "$CSD_VP_KS_ON_BACKEND" != "0" ] && [ "$CSD_VP_KS_ON_BACKEND" != "false" ] && [ "$CSD_VP_KS_ON_BACKEND" != "False" ]; then
  vp_flags=$((vp_flags | VP_SPLIT_FLAG))
  exp_flags=$((exp_flags | VP_SPLIT_FLAG))
  soft_flags=$((soft_flags | VP_SPLIT_FLAG))
fi

if [ "$NO_SUDO" = "1" ]; then
  echo "[4/4] Run user-mode smoke (skipped nvmevirt e2e: NO_SUDO=1)"
  if [ "$MODE" != "0" ]; then
    echo "[err] NO_SUDO=1 currently supports MODE=0 (VP) only, got MODE=$MODE" >&2
    exit 1
  fi
  if [ "$vp_flags" != "0" ] || [ "$exp_flags" != "4" ] || [ "$soft_flags" != "4" ]; then
    echo "[note] NO_SUDO=1 smoke runs GPU monolithic; backend VP split flag is ignored."
  fi
  SMOKE_BIN="$ROOT/sw/gpu_runtime_service/build-clean/gpu_executor_smoke"
  if [ ! -x "$SMOKE_BIN" ]; then
    echo "[err] missing smoke binary: $SMOKE_BIN" >&2
    exit 1
  fi

  export WOP_GPU_KEY_IMPORT="$KEYSET"
  export WOP_GPU_FORCE_CPU_WOKS="$WOP_GPU_FORCE_CPU_WOKS"
  export WOP_GPU_CPU_THREADS="$CPU_THREADS"
  export GPU_SMOKE_WORD_BYTES=8
  export GPU_SMOKE_GLWE_WORDS="$GLWE_WORDS"
  export TFHE_GPU_TWIDDLES_LIBM="$TFHE_GPU_TWIDDLES_LIBM"
  export TFHE_GPU_SPQLIOS_FFT="$TFHE_GPU_SPQLIOS_FFT"
  export TFHE_GPU_SPQLIOS_FFT_TABLE="$TFHE_GPU_SPQLIOS_FFT_TABLE"
  export TFHE_GPU_SPQLIOS_IFFT="$TFHE_GPU_SPQLIOS_IFFT"
  export TFHE_GPU_SPQLIOS_IFFT_TABLE="$TFHE_GPU_SPQLIOS_IFFT_TABLE"

  run_smoke() {
    local name="$1"
    local flags="$2"
    local tlwe_file="$3"
    local golden="$4"
    local out_glwe="$5"
    echo
    echo "[smoke] case=$name flags=0x$(printf '%02x' "$flags")"
    export GPU_SMOKE_FLAGS="$flags"
    "$SMOKE_BIN" VP "$tlwe_file" "$out_glwe" >/tmp/csd_smoke_${name}.log 2>&1
    if cmp -s "$out_glwe" "$golden"; then
      echo "[smoke] OK: $name matches golden"
    else
      echo "[smoke] FAIL: $name mismatch" >&2
      echo "[smoke] out=$out_glwe golden=$golden" >&2
      exit 1
    fi
	  }

	  run_smoke "vp" 0 "$vp_tlwe" "$vp_golden" "$OUT_DIR/vp_glwe_out.bin"
	  run_smoke "exp" 4 "$exp_tlwe" "$exp_golden" "$OUT_DIR/exp_glwe_out.bin"
	  run_smoke "soft" 4 "$soft_tlwe" "$soft_golden" "$OUT_DIR/soft_glwe_out.bin"
	  echo
	  echo "[PASS] Smoke OK (no nvmevirt). Artifacts saved under: $OUT_DIR"
	  exit 0
	fi

echo "[4/4] Run nvmevirt e2e via PRP input (0xC0 -> backend -> gpu_runtime_service -> /dev/mem)"
# When keyset lives on nvmevirt flash, avoid reloading nvmev.ko between cases,
# otherwise we'd re-program ~3GB keyset multiple times.
skip_reload_after_first=0
if [ "${CSD_KEYSET_IN_FLASH:-0}" = "1" ]; then
	skip_reload_after_first=1
	fi
	run_case "vp" "$vp_flags" "$vp_tlwe" "$vp_golden" "$OUT_DIR/vp_glwe_out.bin" 0
	run_case "exp" "$exp_flags" "$exp_tlwe" "$exp_golden" "$OUT_DIR/exp_glwe_out.bin" "$skip_reload_after_first"
	run_case "soft" "$soft_flags" "$soft_tlwe" "$soft_golden" "$OUT_DIR/soft_glwe_out.bin" "$skip_reload_after_first"

	echo
	echo "[PASS] All cases OK. Artifacts saved under: $OUT_DIR"
