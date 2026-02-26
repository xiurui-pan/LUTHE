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
MODE="${MODE:-3}"
FLAGS="${FLAGS:-16}" # 0x10: FunctionEval staged RPC (M7; control-plane only, compute stays in gpu_runtime_service)

N="${N:-16}"
SEED="${SEED:-0}"

KEYSET_DEFAULT="$ROOT/tmp_assets/wop_keyset.bin"
KEYSET="${KEYSET:-$KEYSET_DEFAULT}"
BUILD_JOBS="${BUILD_JOBS:-8}"
WOPBS_FP_TOTAL_BITS="${WOPBS_FP_TOTAL_BITS:-}"
WOPBS_FP_INT_BITS="${WOPBS_FP_INT_BITS:-}"
CACHE_FILE="$ROOT/sw/gpu_runtime_service/build-clean/CMakeCache.txt"

if [ -z "${SOFTMAX_EPS_ABS_2:-}" ] && [ "${WOPBS_FP_TOTAL_BITS:-}" = "16" ]; then
  if csd_no_fallback_enabled; then
    csd_no_fallback_err "SOFTMAX_EPS_ABS_2 auto-set for WOPBS_FP_TOTAL_BITS=16"
  fi
  SOFTMAX_EPS_ABS_2=3e-3
fi

SOFTMAX_REF_QUANT_FRAC_BITS="${SOFTMAX_REF_QUANT_FRAC_BITS:-}"
SOFTMAX_REF_QUANT_MODE="${SOFTMAX_REF_QUANT_MODE:-}"
SOFTMAX_REF_QUANT_AUTO=0
if [ -z "$SOFTMAX_REF_QUANT_FRAC_BITS" ]; then
  ref_total_bits="$WOPBS_FP_TOTAL_BITS"
  if [ -z "$ref_total_bits" ] && [ -f "$CACHE_FILE" ]; then
    ref_total_bits="$(sed -n 's/^WOPBS_FP_TOTAL_BITS:STRING=//p' "$CACHE_FILE" | head -n 1)"
  fi
  if [ "$ref_total_bits" = "16" ]; then
    ref_int_bits="$WOPBS_FP_INT_BITS"
    if [ -z "$ref_int_bits" ] && [ -f "$CACHE_FILE" ]; then
      ref_int_bits="$(sed -n 's/^WOPBS_FP_INT_BITS:STRING=//p' "$CACHE_FILE" | head -n 1)"
    fi
    if [ -z "$ref_int_bits" ]; then
      ref_int_bits=6
    fi
    SOFTMAX_REF_QUANT_FRAC_BITS=$((ref_total_bits - ref_int_bits))
    if [ "$SOFTMAX_REF_QUANT_FRAC_BITS" -le 0 ]; then
      SOFTMAX_REF_QUANT_FRAC_BITS=""
    fi
    if [ -z "$SOFTMAX_REF_QUANT_MODE" ] && [ -n "$SOFTMAX_REF_QUANT_FRAC_BITS" ]; then
      SOFTMAX_REF_QUANT_MODE="floor"
    fi
    if [ -n "$SOFTMAX_REF_QUANT_FRAC_BITS" ]; then
      SOFTMAX_REF_QUANT_AUTO=1
    fi
  fi
fi

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

if [ -z "${WOP_GPU_KSPBS_SPLIT_LOG:-}" ]; then
  if [ "${WOP_GPU_KSPBS_SPLIT:-0}" = "1" ] || [ -n "${WOP_GPU_KSPBS_SPLIT_LUTS:-}" ]; then
    export WOP_GPU_KSPBS_SPLIT_LOG=1
  fi
fi

FLAGS_NUM=$((FLAGS))
if [ "${CSD_SOFTMAX_KSPBS_SPLIT:-0}" != "0" ] || [ "${WOP_GPU_KSPBS_SPLIT:-0}" = "1" ] || \
  [ -n "${WOP_GPU_KSPBS_SPLIT_LUTS:-}" ]; then
  FLAGS_NUM=$((FLAGS_NUM | 0x08))
fi
FLAGS="$FLAGS_NUM"

RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-/tmp/csd_gpu_nvmevirt_softmax_${RUN_ID}}"
mkdir -p "$OUT_DIR"

INPUT_BIN="$OUT_DIR/softmax_input_fp64.bin"
REF_BIN="$OUT_DIR/softmax_ref_fp64.bin"
OUT_BIN="$OUT_DIR/softmax_out_fp64.bin"

cfg() { printf '[cfg] %-20s %s\n' "$1" "$2"; }

cfg "ROOT" "$ROOT"
cfg "NVMEVIRT_ROOT" "$NVMEVIRT_ROOT"
cfg "dev" "$DEV nsid=$NSID engine=$ENGINE mode=$MODE flags=0x$(printf '%02x' "$FLAGS")"
cfg "n" "$N seed=$SEED"
cfg "keyset" "$KEYSET"
cfg "out_dir" "$OUT_DIR"
cfg "csd_use_prp" "$CSD_USE_PRP no_sudo=$NO_SUDO"
cfg "csd_flash_io" "tlwe_in_flash=$CSD_TLWE_IN_FLASH glwe_out_flash=$CSD_GLWE_OUT_FLASH"
cfg "no_fallback" "$CSD_NO_FALLBACK"
cfg "gpu_socket" "$GPU_SOCKET gpu_timeout=$GPU_TIMEOUT"
cfg "spqlios_fft_table" "$TFHE_GPU_SPQLIOS_FFT_TABLE"
cfg "spqlios_ifft_table" "$TFHE_GPU_SPQLIOS_IFFT_TABLE"
if [ -n "$WOPBS_FP_TOTAL_BITS" ] || [ -n "$WOPBS_FP_INT_BITS" ]; then
  cfg "wopbs_fp" "total_bits=${WOPBS_FP_TOTAL_BITS:-default} int_bits=${WOPBS_FP_INT_BITS:-default}"
fi
if [ -n "${SOFTMAX_EPS_ABS_1:-}" ] || [ -n "${SOFTMAX_EPS_ABS_2:-}" ] || \
   [ -n "${SOFTMAX_EPS_REL_1:-}" ] || [ -n "${SOFTMAX_EPS_REL_2:-}" ]; then
  cfg "softmax_eps" "abs1=${SOFTMAX_EPS_ABS_1:-default} abs2=${SOFTMAX_EPS_ABS_2:-default} rel1=${SOFTMAX_EPS_REL_1:-default} rel2=${SOFTMAX_EPS_REL_2:-default}"
fi
if [ -n "${SOFTMAX_REF_QUANT_FRAC_BITS:-}" ]; then
  cfg "softmax_ref_quant" "frac_bits=$SOFTMAX_REF_QUANT_FRAC_BITS mode=${SOFTMAX_REF_QUANT_MODE:-round}"
fi
echo

if [ ! -f "$KEYSET" ]; then
  echo "[err] missing keyset: $KEYSET" >&2
  exit 1
fi

if [ -z "$WOPBS_FP_TOTAL_BITS" ] && [ -z "$WOPBS_FP_INT_BITS" ]; then
  if [ -f "$CACHE_FILE" ]; then
    CACHED_TOTAL="$(sed -n 's/^WOPBS_FP_TOTAL_BITS:STRING=//p' "$CACHE_FILE" | head -n 1)"
    CACHED_INT="$(sed -n 's/^WOPBS_FP_INT_BITS:STRING=//p' "$CACHE_FILE" | head -n 1)"
    if [ -n "$CACHED_TOTAL" ] || [ -n "$CACHED_INT" ]; then
      echo "[0/4] Configure gpu_runtime_service (clear cached WOPBS fixed-point override)"
      cmake -S "$ROOT/sw/gpu_runtime_service" -B "$ROOT/sw/gpu_runtime_service/build-clean" \
        -DWOPBS_FP_TOTAL_BITS= \
        -DWOPBS_FP_INT_BITS=
      if [ "$SOFTMAX_REF_QUANT_AUTO" = "1" ]; then
        SOFTMAX_REF_QUANT_FRAC_BITS=""
        SOFTMAX_REF_QUANT_MODE=""
      fi
    fi
  fi
fi

if [ -n "$WOPBS_FP_TOTAL_BITS" ] || [ -n "$WOPBS_FP_INT_BITS" ]; then
  echo "[0/4] Configure gpu_runtime_service (WOPBS fixed-point override)"
  cmake -S "$ROOT/sw/gpu_runtime_service" -B "$ROOT/sw/gpu_runtime_service/build-clean" \
    ${WOPBS_FP_TOTAL_BITS:+-DWOPBS_FP_TOTAL_BITS=$WOPBS_FP_TOTAL_BITS} \
    ${WOPBS_FP_INT_BITS:+-DWOPBS_FP_INT_BITS=$WOPBS_FP_INT_BITS}
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

ensure_spqlios_tables

echo "[2/4] Generate softmax fp64 input/ref"
python3 "$ROOT/tools/softmax_fp64.py" gen --n "$N" --seed "$SEED" \
  --out-input "$INPUT_BIN" --out-ref "$REF_BIN" > "$OUT_DIR/gen.log" 2>&1
tail -n 20 "$OUT_DIR/gen.log" || true

export WOP_GPU_KEY_IMPORT="$KEYSET"
export WOP_GPU_KEY_EXPORT="$KEYSET"
export TFHE_GPU_TWIDDLES_LIBM="$TFHE_GPU_TWIDDLES_LIBM"
export TFHE_GPU_SPQLIOS_FFT="$TFHE_GPU_SPQLIOS_FFT"
export TFHE_GPU_SPQLIOS_FFT_TABLE="$TFHE_GPU_SPQLIOS_FFT_TABLE"
export TFHE_GPU_SPQLIOS_IFFT="$TFHE_GPU_SPQLIOS_IFFT"
export TFHE_GPU_SPQLIOS_IFFT_TABLE="$TFHE_GPU_SPQLIOS_IFFT_TABLE"

if [ "$NO_SUDO" = "1" ]; then
  echo "[3/4] Run user-mode softmax staged IPC (NO_SUDO=1)"

  GPU_SERVICE_BIN="${GPU_SERVICE_BIN:-$ROOT/sw/gpu_runtime_service/build-clean/gpu_runtime_service}"
  if [ ! -x "$GPU_SERVICE_BIN" ]; then
    echo "[err] gpu_runtime_service missing/executable: $GPU_SERVICE_BIN" >&2
    exit 1
  fi
  if [ ! -d "$NVMEVIRT_ROOT" ]; then
    echo "[err] nvmevirt repo not found: $NVMEVIRT_ROOT" >&2
    exit 1
  fi

  rm -f "$GPU_SOCKET" >/dev/null 2>&1 || true
  pkill -9 -f "[g]pu_runtime_service.*${GPU_SOCKET}" >/dev/null 2>&1 || true

  "$GPU_SERVICE_BIN" "$GPU_SOCKET" >"$OUT_DIR/gpu_runtime_service.log" 2>&1 &
  GPU_SERVICE_PID=$!

  for _ in $(seq 1 60); do
    if [ -S "$GPU_SOCKET" ]; then
      break
    fi
    sleep 1
  done
  if [ ! -S "$GPU_SOCKET" ]; then
    echo "[3/4][err] gpu_runtime_service socket not ready: $GPU_SOCKET" >&2
    tail -n 120 "$OUT_DIR/gpu_runtime_service.log" || true
    kill "$GPU_SERVICE_PID" >/dev/null 2>&1 || true
    exit 1
  fi

  cleanup() {
    kill "$GPU_SERVICE_PID" >/dev/null 2>&1 || true
    pkill -9 -f "[g]pu_runtime_service.*${GPU_SOCKET}" >/dev/null 2>&1 || true
    rm -f "$GPU_SOCKET" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  PYTHONPATH="$NVMEVIRT_ROOT/tools:${PYTHONPATH:-}" \
  GPU_SOCKET="$GPU_SOCKET" GPU_TIMEOUT="$GPU_TIMEOUT" \
  N="$N" INPUT_BIN="$INPUT_BIN" OUT_BIN="$OUT_BIN" \
  python3 - <<'PY' >"$OUT_DIR/staged_ipc.log" 2>&1
import os, time
from csd_gpu_ipc import Descriptor, run_gpu_service

sock = os.environ["GPU_SOCKET"]
timeout_s = float(os.environ.get("GPU_TIMEOUT", "120"))
n = int(os.environ["N"])
input_bin = os.environ["INPUT_BIN"]
out_bin = os.environ["OUT_BIN"]

with open(input_bin, "rb") as f:
    fp64_payload = f.read()

def fe_flags(op: int) -> int:
    return ((int(op) & 0x3F) << 2) | func_opt

def env_enabled(name: str, default: str = "0") -> bool:
    value = str(os.environ.get(name, default))
    return value not in ("0", "", "false", "False", "no", "No")

func_opt = 0
if env_enabled("CSD_SOFTMAX_KSPBS_SPLIT") or env_enabled("CSD_DEEPNN_OFFLOAD_SOFTMAX_KSPBS_SPLIT"):
    func_opt |= 0x1
    if env_enabled("CSD_SOFTMAX_KSPBS_SPLIT_ALL_STAGES") or env_enabled("WOP_GPU_KSPBS_SPLIT_ALL_STAGES"):
        func_opt |= 0x2

session_id = int(time.time_ns()) & 0xFFFF_FFFF_FFFF_FFFF
cmd_base = 0xB000

op_init = 1
op_max = 2
op_shift = 3
op_exp = 4
op_sum = 5
op_div = 6
op_export = 7
op_clear = 8

def submit(desc: Descriptor, payload: bytes, tlwe_words: int, glwe_words: int) -> bytes:
    res = run_gpu_service(
        socket_path=sock,
        desc=desc,
        tlwe_data=payload,
        tlwe_word_bytes=8,
        glwe_word_bytes=8,
        timeout_s=timeout_s,
    )
    return res.payload[: glwe_words * 8]

try:
    # INIT: fp64 in (N doubles), no output.
    init_desc = Descriptor(
        cmd_id=(cmd_base + 0) & 0xFFFF,
        mode=3,
        flags=fe_flags(op_init),
        tlwe_words=n,
        glwe_words=0,
        status_addr=session_id,
    )
    submit(init_desc, fp64_payload, tlwe_words=n, glwe_words=0)

    # Stateless stages.
    for step, op in enumerate([op_max, op_shift, op_exp, op_sum, op_div], start=1):
        stage_desc = Descriptor(
            cmd_id=(cmd_base + step) & 0xFFFF,
            mode=3,
            flags=fe_flags(op),
            tlwe_words=0,
            glwe_words=0,
            status_addr=session_id,
        )
        submit(stage_desc, b"", tlwe_words=0, glwe_words=0)

    export_desc = Descriptor(
        cmd_id=(cmd_base + 7) & 0xFFFF,
        mode=3,
        flags=fe_flags(op_export),
        tlwe_words=0,
        glwe_words=n,
        status_addr=session_id,
    )
    out = submit(export_desc, b"", tlwe_words=0, glwe_words=n)
    with open(out_bin, "wb") as f:
        f.write(out)
finally:
    try:
        clear_desc = Descriptor(
            cmd_id=(cmd_base + 8) & 0xFFFF,
            mode=3,
            flags=fe_flags(op_clear),
            tlwe_words=0,
            glwe_words=0,
            status_addr=session_id,
        )
        submit(clear_desc, b"", tlwe_words=0, glwe_words=0)
    except Exception:
        pass
PY
else
  echo "[3/4] Run nvmevirt e2e softmax (needs sudo)"
  if [ ! -x "$E2E_SH" ]; then
    echo "[err] missing e2e script: $E2E_SH" >&2
    exit 1
  fi
  if [ ! -d "$NVMEVIRT_ROOT" ]; then
    echo "[err] nvmevirt repo not found: $NVMEVIRT_ROOT" >&2
    exit 1
  fi
  make -C "$NVMEVIRT_ROOT" -j "$BUILD_JOBS"

  HPU_FPGA_FIN_ROOT="$ROOT" \
  KEYSET="$KEYSET" \
  BACKEND_LOG="$OUT_DIR/backend.log" \
  GPU_SERVICE_LOG="$OUT_DIR/gpu_runtime_service.log" \
  DMESG_OUT="$OUT_DIR/dmesg_new.log" \
  DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" MODE="$MODE" FLAGS="$FLAGS" \
  TLWE_WORDS="$N" GLWE_WORDS="$N" \
  TLWE_FILE="$INPUT_BIN" OUT_GLWE="$OUT_BIN" \
  CSD_USE_PRP="$CSD_USE_PRP" \
  GPU_SOCKET="$GPU_SOCKET" GPU_TIMEOUT="$GPU_TIMEOUT" \
    "$E2E_SH" > "$OUT_DIR/e2e.log" 2>&1
fi

echo "[4/4] Check output vs trivial softmax"
set +e
CHECK_ARGS=()
if [ -n "${SOFTMAX_EPS_ABS_1:-}" ]; then
  CHECK_ARGS+=(--eps-abs-1 "$SOFTMAX_EPS_ABS_1")
fi
if [ -n "${SOFTMAX_EPS_ABS_2:-}" ]; then
  CHECK_ARGS+=(--eps-abs-2 "$SOFTMAX_EPS_ABS_2")
fi
if [ -n "${SOFTMAX_EPS_REL_1:-}" ]; then
  CHECK_ARGS+=(--eps-rel-1 "$SOFTMAX_EPS_REL_1")
fi
if [ -n "${SOFTMAX_EPS_REL_2:-}" ]; then
  CHECK_ARGS+=(--eps-rel-2 "$SOFTMAX_EPS_REL_2")
fi
if [ -n "${SOFTMAX_REF_QUANT_FRAC_BITS:-}" ]; then
  CHECK_ARGS+=(--ref-quant-frac-bits "$SOFTMAX_REF_QUANT_FRAC_BITS")
  if [ -n "${SOFTMAX_REF_QUANT_MODE:-}" ]; then
    CHECK_ARGS+=(--ref-quant-mode "$SOFTMAX_REF_QUANT_MODE")
  fi
fi
python3 "$ROOT/tools/softmax_fp64.py" check --n "$N" --input "$INPUT_BIN" --output "$OUT_BIN" \
  "${CHECK_ARGS[@]}" \
  > "$OUT_DIR/check.log" 2>&1
rc=$?
set -e
cat "$OUT_DIR/check.log" || true

if [ "$rc" -ne 0 ]; then
  echo "[FAIL] softmax check failed (rc=$rc). Artifacts saved under: $OUT_DIR" >&2
  exit "$rc"
fi

if [ "${WOP_GPU_FUNC_STAGE_METRICS:-0}" = "1" ]; then
  METRICS_LOG="$OUT_DIR/gpu_runtime_service.log"
  if [ ! -f "$METRICS_LOG" ] && [ "$NO_SUDO" = "1" ]; then
    METRICS_LOG="$OUT_DIR/smoke.log"
  fi
  echo
  echo "[metrics] softmax stage metrics (from $METRICS_LOG)"
  if command -v rg >/dev/null 2>&1; then
    rg "\\[TFHE_GPU_EXEC\\]\\[FUNC_METRICS\\]" "$METRICS_LOG" | tail -n 1 || true
  else
    grep "\\[TFHE_GPU_EXEC\\]\\[FUNC_METRICS\\]" "$METRICS_LOG" | tail -n 1 || true
  fi
fi

if [ "${WOP_GPU_KSPBS_CALL_METRICS:-0}" = "1" ]; then
  METRICS_LOG="$OUT_DIR/gpu_runtime_service.log"
  if [ ! -f "$METRICS_LOG" ] && [ "$NO_SUDO" = "1" ]; then
    METRICS_LOG="$OUT_DIR/smoke.log"
  fi
  echo
  echo "[metrics] KSPBS call counts (from $METRICS_LOG)"
  if command -v rg >/dev/null 2>&1; then
    rg "\\[TFHE_GPU_EXEC\\]\\[KSPBS_CALLS\\]" "$METRICS_LOG" || true
  else
    grep "\\[TFHE_GPU_EXEC\\]\\[KSPBS_CALLS\\]" "$METRICS_LOG" || true
  fi
fi

if [ "${WOP_GPU_KSPBS_LUT_METRICS:-0}" = "1" ]; then
  METRICS_LOG="$OUT_DIR/gpu_runtime_service.log"
  if [ ! -f "$METRICS_LOG" ] && [ "$NO_SUDO" = "1" ]; then
    METRICS_LOG="$OUT_DIR/smoke.log"
  fi
  echo
  echo "[metrics] KSPBS LUT samples (from $METRICS_LOG)"
  if command -v rg >/dev/null 2>&1; then
    rg "\\[TFHE_GPU_EXEC\\]\\[KSPBS_LUT_SAMPLES\\]" "$METRICS_LOG" || true
  else
    grep "\\[TFHE_GPU_EXEC\\]\\[KSPBS_LUT_SAMPLES\\]" "$METRICS_LOG" || true
  fi
fi

if [ "${WOP_GPU_KSPBS_SPLIT_LOG:-0}" = "1" ]; then
  METRICS_LOG="$OUT_DIR/gpu_runtime_service.log"
  if [ ! -f "$METRICS_LOG" ] && [ "$NO_SUDO" = "1" ]; then
    METRICS_LOG="$OUT_DIR/smoke.log"
  fi
  echo
  echo "[metrics] KSPBS split hits (from $METRICS_LOG)"
  if command -v rg >/dev/null 2>&1; then
    rg "\\[KSPBS_SPLIT\\]" "$METRICS_LOG" | tail -n 10 || true
  else
    grep "\\[KSPBS_SPLIT\\]" "$METRICS_LOG" | tail -n 10 || true
  fi
fi

echo
echo "[PASS] softmax closed-loop OK. Artifacts saved under: $OUT_DIR"
