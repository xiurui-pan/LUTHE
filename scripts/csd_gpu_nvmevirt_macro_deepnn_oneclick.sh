#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSD_NO_FALLBACK="${CSD_NO_FALLBACK:-0}"
# shellcheck source=/dev/null
source "$ROOT/scripts/csd_no_fallback.sh"
NVMEVIRT_ROOT="${NVMEVIRT_ROOT:-$ROOT/../nvmevirt}"
export HPU_FPGA_FIN_ROOT="$ROOT"
export NVMEVIRT_ROOT="$NVMEVIRT_ROOT"

env_enabled() {
  local v="${1:-0}"
  [ "$v" != "0" ] && [ "$v" != "" ] && [ "$v" != "false" ] && [ "$v" != "False" ] && [ "$v" != "no" ] && [ "$v" != "No" ]
}

usage() {
  cat <<'EOF' >&2
usage:
  bash scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh -- <deep-nn-command...>

examples:
  # concrete-ml deep_learning benchmark (MNIST, ShallowNarrowCNN, 1 FHE sample)
  DEEP_NN_ROOT="$HOME/workspace/deep-nn"
  bash scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh -- \
    "$DEEP_NN_ROOT/.venv/bin/python" "$DEEP_NN_ROOT/benchmarks/deep_learning.py" \
    --models ShallowNarrowCNN --datasets MNIST \
    --configs '{"n_bits":2,"p_error":9.094947017729282e-13}' \
    --fhe_samples 1 --model_samples 1 --verbose

  # Or pass via env var (keep it simple for long commands):
  DEEP_NN_CMD="$DEEP_NN_ROOT/.venv/bin/python $DEEP_NN_ROOT/benchmarks/deep_learning.py --models ShallowNarrowCNN --datasets MNIST --configs '{\"n_bits\":2,\"p_error\":9.094947017729282e-13}' --fhe_samples 1 --model_samples 1" \
    bash scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh

notes:
  - This script standardizes env + logging for macrobenchmark runs.
  - It does NOT ship a deep-nn workload repo, but when no command is provided it will try to run
    the default concrete-ml benchmark under $DEEP_NN_ROOT (default: ~/workspace/deep-nn).
  - It can optionally trigger ONE FunctionEval softmax offload call (IPC -> gpu_runtime_service)
    as an integration hook; controlled by CSD_DEEPNN_OFFLOAD_SOFTMAX (default: 1).
  - If torch fails to load "*.pt" with "invalid load key, 'v'", it's likely a git-lfs pointer file.
    Either run "git lfs pull" in the workload repo, or train once to regenerate the weights.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

run_id="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
out_dir="${OUT_DIR:-/tmp/csd_gpu_nvmevirt_macro_deepnn_${run_id}}"
mkdir -p "$out_dir"

no_sudo="${NO_SUDO:-0}"

KEYSET_DEFAULT="$ROOT/tmp_assets/wop_keyset.bin"
KEYSET="${KEYSET-}"
BUILD_JOBS="${BUILD_JOBS:-8}"
WOPBS_FP_TOTAL_BITS="${WOPBS_FP_TOTAL_BITS:-}"
WOPBS_FP_INT_BITS="${WOPBS_FP_INT_BITS:-}"
WOPBS_FP_CONFIGURED=0
GPU_SOCKET="${GPU_SOCKET:-$out_dir/wop_gpu_runtime.sock}"
GPU_TIMEOUT="${GPU_TIMEOUT:-240}"
GPU_SERVICE_BIN_DEFAULT="$ROOT/sw/gpu_runtime_service/build-clean/gpu_runtime_service"
GPU_SERVICE_BIN="${GPU_SERVICE_BIN-}"
DEEPNN_TFHE_VARIANT="${CSD_DEEPNN_TFHE_VARIANT:-}"
if [ -n "$DEEPNN_TFHE_VARIANT" ]; then
  case "$DEEPNN_TFHE_VARIANT" in
    deepnn4096)
      # Build and use a dedicated TFHE baseline overlay that patches n_lvl0/n_lvl2.
      # This is a stepping stone towards covering polynomial_size=4096 observed in deep-nn profiles.
      build_dir="$ROOT/sw/gpu_runtime_service/build-deepnn4096"
      keyset_deepnn="$ROOT/tmp_assets/wop_keyset_deepnn4096.bin"
      if [ ! -x "$build_dir/gpu_runtime_service" ] || [ ! -x "$build_dir/keyset_exporter" ]; then
        bash "$ROOT/scripts/csd_gpu_build_tfhe_deepnn_4096.sh"
      fi
      if [ -z "${GPU_SERVICE_BIN:-}" ]; then
        GPU_SERVICE_BIN="$build_dir/gpu_runtime_service"
      fi
      if [ -z "${KEYSET:-}" ]; then
        KEYSET="$keyset_deepnn"
      fi
      ;;
    *)
      echo "[err] unsupported CSD_DEEPNN_TFHE_VARIANT=$DEEPNN_TFHE_VARIANT (supported: deepnn4096)" >&2
      exit 2
      ;;
  esac
fi

if [ -z "${GPU_SERVICE_BIN:-}" ]; then
  GPU_SERVICE_BIN="$GPU_SERVICE_BIN_DEFAULT"
fi
if [ -z "${KEYSET:-}" ]; then
  KEYSET="$KEYSET_DEFAULT"
fi

# Defaults tuned for long-running macrobenchmarks (can be overridden by the caller).
export NO_SUDO="$no_sudo"
export GPU_WOKS_NATIVE="${GPU_WOKS_NATIVE:-1}"
export CSD_USE_PRP="${CSD_USE_PRP:-0}"
export CSD_KEYSET_IN_FLASH="${CSD_KEYSET_IN_FLASH:-1}"
export CSD_TLWE_IN_FLASH="${CSD_TLWE_IN_FLASH:-1}"
export CSD_GLWE_OUT_FLASH="${CSD_GLWE_OUT_FLASH:-1}"
export CSD_VP_KS_ON_BACKEND="${CSD_VP_KS_ON_BACKEND:-1}"
export CSD_KEEP_SESSION="${CSD_KEEP_SESSION:-1}"
export CSD_KEEP_BACKEND="${CSD_KEEP_BACKEND:-1}"
if [ "${CSD_KEYSET_IN_FLASH:-0}" = "1" ] && [ -n "${CSD_VARIANTS_JSON:-}" ]; then
  if [ -z "${CSD_KEYSET_FLASH_VARIANTS:-}" ]; then
    ids=""
    if [ -n "${CSD_FUNC_VARIANT_ID:-}" ]; then
      ids="$CSD_FUNC_VARIANT_ID"
    fi
    if [ -n "${CSD_SOFTMAX_VARIANT_ID:-}" ]; then
      if [ -n "$ids" ]; then
        ids="$ids,$CSD_SOFTMAX_VARIANT_ID"
      else
        ids="$CSD_SOFTMAX_VARIANT_ID"
      fi
    fi
    if [ -n "$ids" ]; then
      export CSD_KEYSET_FLASH_VARIANTS="$ids"
    fi
  fi
fi
export KEYSET="$KEYSET"
export GPU_SOCKET="$GPU_SOCKET"
export GPU_TIMEOUT="$GPU_TIMEOUT"
export CSD_DEEPNN_OFFLOAD_SOFTMAX="${CSD_DEEPNN_OFFLOAD_SOFTMAX:-1}"
export CSD_DEEPNN_OFFLOAD_SOFTMAX_STRICT="${CSD_DEEPNN_OFFLOAD_SOFTMAX_STRICT:-1}"
export CSD_DEEPNN_OFFLOAD_SOFTMAX_MAX_MAE="${CSD_DEEPNN_OFFLOAD_SOFTMAX_MAX_MAE:-1e-3}"
export CSD_DEEPNN_OFFLOAD_SOFTMAX_KSPBS_SPLIT="${CSD_DEEPNN_OFFLOAD_SOFTMAX_KSPBS_SPLIT:-0}"
export CSD_DEEPNN_ROUNDING_BITS="${CSD_DEEPNN_ROUNDING_BITS:-}"
export CSD_DEEPNN_ROUNDING_METHOD="${CSD_DEEPNN_ROUNDING_METHOD:-}"
export CSD_DEEPNN_ALLOW_ROUNDING_BITS_GT8="${CSD_DEEPNN_ALLOW_ROUNDING_BITS_GT8:-0}"
if env_enabled "$CSD_DEEPNN_OFFLOAD_SOFTMAX_KSPBS_SPLIT"; then
  export WOP_GPU_KSPBS_SPLIT="${WOP_GPU_KSPBS_SPLIT:-1}"
  export WOP_GPU_KSPBS_SPLIT_ALL_STAGES="${WOP_GPU_KSPBS_SPLIT_ALL_STAGES:-0}"
  export WOP_GPU_KSPBS_SPLIT_LUTS="${WOP_GPU_KSPBS_SPLIT_LUTS:-10,11}"
  export WOP_GPU_KSPBS_SPLIT_LOG="${WOP_GPU_KSPBS_SPLIT_LOG:-1}"
  export CSD_SOFTMAX_KSPBS_SPLIT="${CSD_SOFTMAX_KSPBS_SPLIT:-1}"
  export CSD_SOFTMAX_KSPBS_SPLIT_ALL_STAGES="${CSD_SOFTMAX_KSPBS_SPLIT_ALL_STAGES:-$WOP_GPU_KSPBS_SPLIT_ALL_STAGES}"
fi

csd_no_fallback_require_no_sudo
csd_no_fallback_forbid_env WOP_GPU_FORCE_CPU_WOKS
csd_no_fallback_force_fft

# For FunctionEval(mode=3) softmax correctness, enable spqlios FFT tables by default
# (matches scripts/csd_gpu_nvmevirt_softmax_oneclick.sh).
export TFHE_GPU_TWIDDLES_LIBM="${TFHE_GPU_TWIDDLES_LIBM:-1}"
export TFHE_GPU_SPQLIOS_FFT="${TFHE_GPU_SPQLIOS_FFT:-1}"
export TFHE_GPU_SPQLIOS_IFFT="${TFHE_GPU_SPQLIOS_IFFT:-1}"
export TFHE_GPU_SPQLIOS_FFT_TABLE="${TFHE_GPU_SPQLIOS_FFT_TABLE:-/tmp/spqlios_fft_table.n4096.bin}"
export TFHE_GPU_SPQLIOS_IFFT_TABLE="${TFHE_GPU_SPQLIOS_IFFT_TABLE:-/tmp/spqlios_ifft_table.n4096.bin}"

export OUT_DIR="$out_dir"
export PROGRESS_OUTPUT="${PROGRESS_OUTPUT:-$OUT_DIR/progress.json}"
export CSD_DEEPNN_PROFILE="${CSD_DEEPNN_PROFILE:-1}"
export CSD_DEEPNN_PROFILE_OUT="${CSD_DEEPNN_PROFILE_OUT:-$OUT_DIR/deepnn_profile.json}"
export CSD_DEEPNN_FHE_NVMEVIRT="${CSD_DEEPNN_FHE_NVMEVIRT:-0}"
export CSD_DEEPNN_FHE_BACKEND="${CSD_DEEPNN_FHE_BACKEND:-}"
if env_enabled "$CSD_DEEPNN_FHE_NVMEVIRT" && [ -z "${CSD_DEEPNN_FHE_EXECUTOR:-}" ]; then
  CSD_DEEPNN_FHE_EXECUTOR="gpu_service"
fi
export CSD_DEEPNN_FHE_EXECUTOR="${CSD_DEEPNN_FHE_EXECUTOR:-}"
if [ -n "${CSD_DEEPNN_FHE_EXECUTOR:-}" ]; then
  case "$CSD_DEEPNN_FHE_EXECUTOR" in
    adapter|wop|wop_adapter|wopbs)
      if [ -z "${CSD_DEEPNN_FHE_ADAPTER:-}" ] && [ -z "${WOP_GPU_FHE_ADAPTER:-}" ]; then
        if csd_no_fallback_enabled; then
          csd_no_fallback_err "CSD_DEEPNN_FHE_EXECUTOR=$CSD_DEEPNN_FHE_EXECUTOR requires CSD_DEEPNN_FHE_ADAPTER/WOP_GPU_FHE_ADAPTER"
        fi
        export CSD_DEEPNN_FHE_ADAPTER="$ROOT/tools/csd_concrete_fhe_adapter_stub.py"
      fi
      if env_enabled "$CSD_DEEPNN_FHE_NVMEVIRT" && [ -z "${CSD_DEEPNN_FHE_SEPARATE_LOGS:-}" ]; then
        export CSD_DEEPNN_FHE_SEPARATE_LOGS=1
      fi
      ;;
  esac
fi
if env_enabled "$CSD_DEEPNN_FHE_NVMEVIRT" && [ -z "${CSD_DEEPNN_FHE_DEVICE:-}" ]; then
  CSD_DEEPNN_FHE_DEVICE="cuda"
fi
export CSD_DEEPNN_FHE_DEVICE="${CSD_DEEPNN_FHE_DEVICE:-cpu}"
if env_enabled "$CSD_DEEPNN_FHE_NVMEVIRT" && [ -z "${CSD_DEEPNN_REQUIRE_GPU:-}" ]; then
  CSD_DEEPNN_REQUIRE_GPU="1"
fi
export CSD_DEEPNN_REQUIRE_GPU="${CSD_DEEPNN_REQUIRE_GPU:-0}"
export CSD_DEEPNN_FHE_MARK_L2="${CSD_DEEPNN_FHE_MARK_L2:-0}"
export CSD_DEEPNN_FHE_COMPARE_BACKENDS="${CSD_DEEPNN_FHE_COMPARE_BACKENDS:-0}"
export CSD_DEEPNN_FHE_COMPARE_STRICT="${CSD_DEEPNN_FHE_COMPARE_STRICT:-0}"
export CSD_DEEPNN_FHE_COMPARE_MAX_MAE="${CSD_DEEPNN_FHE_COMPARE_MAX_MAE:-0}"
export CSD_DEEPNN_FHE_COMPARE_MIN_ARGMAX="${CSD_DEEPNN_FHE_COMPARE_MIN_ARGMAX:-1}"
export CSD_DEEPNN_FHE_UNCOMPRESSED="${CSD_DEEPNN_FHE_UNCOMPRESSED:-0}"
if env_enabled "$CSD_DEEPNN_FHE_UNCOMPRESSED"; then
  export USE_INPUT_COMPRESSION="${USE_INPUT_COMPRESSION:-0}"
  export USE_KEY_COMPRESSION="${USE_KEY_COMPRESSION:-0}"
  export CSD_DEEPNN_FHE_KEEP_IO="${CSD_DEEPNN_FHE_KEEP_IO:-1}"
fi
export CSD_DEEPNN_FHE_KEEP_IO="${CSD_DEEPNN_FHE_KEEP_IO:-0}"
export CSD_DEEPNN_FHE_SERVER_DIR="${CSD_DEEPNN_FHE_SERVER_DIR:-$OUT_DIR/concrete_fhe}"
export CSD_DEEPNN_FHE_EVAL_KEYS="${CSD_DEEPNN_FHE_EVAL_KEYS:-$CSD_DEEPNN_FHE_SERVER_DIR/evaluation_keys.bin}"
if [ -z "${CSD_DEEPNN_FHE_PYTHON:-}" ]; then
  deep_nn_root_guess="${DEEP_NN_ROOT:-$HOME/workspace/deep-nn}"
  if [ -x "$deep_nn_root_guess/.venv/bin/python" ]; then
    CSD_DEEPNN_FHE_PYTHON="$deep_nn_root_guess/.venv/bin/python"
  fi
fi
export CSD_DEEPNN_FHE_PYTHON="${CSD_DEEPNN_FHE_PYTHON:-}"
if [ -n "${CSD_DEEPNN_FHE_PYTHON:-}" ] && [ -z "${CSD_DEEPNN_FHE_ADAPTER_PYTHON:-}" ]; then
  case "${CSD_DEEPNN_FHE_EXECUTOR:-}" in
    adapter|wop|wop_adapter|wopbs)
      export CSD_DEEPNN_FHE_ADAPTER_PYTHON="$CSD_DEEPNN_FHE_PYTHON"
      ;;
  esac
fi
export WOP_GPU_CONCRETE_RUNNER="${WOP_GPU_CONCRETE_RUNNER:-$ROOT/tools/csd_concrete_fhe_runner.py}"
if [ -n "${CSD_DEEPNN_FHE_PYTHON:-}" ] && [ -z "${WOP_GPU_CONCRETE_PYTHON:-}" ]; then
  WOP_GPU_CONCRETE_PYTHON="$CSD_DEEPNN_FHE_PYTHON"
fi
export WOP_GPU_CONCRETE_PYTHON="${WOP_GPU_CONCRETE_PYTHON:-python3}"
if env_enabled "$CSD_DEEPNN_FHE_NVMEVIRT"; then
  export BACKEND_LOG="${BACKEND_LOG:-$OUT_DIR/backend.log}"
  export DMESG_OUT="${DMESG_OUT:-$OUT_DIR/dmesg_new.log}"
fi

cfg() { printf '[cfg] %-22s %s\n' "$1" "$2"; }
cfg "ROOT" "$ROOT"
cfg "NVMEVIRT_ROOT" "$NVMEVIRT_ROOT"
cfg "out_dir" "$OUT_DIR"
cfg "no_sudo" "$no_sudo"
cfg "no_fallback" "$CSD_NO_FALLBACK"
cfg "gpu_woks_native" "$GPU_WOKS_NATIVE"
cfg "csd_use_prp" "$CSD_USE_PRP"
cfg "csd_keyset_in_flash" "$CSD_KEYSET_IN_FLASH"
if [ -n "${CSD_KEYSET_FLASH_VARIANTS:-}" ]; then
  cfg "csd_keyset_flash_variants" "$CSD_KEYSET_FLASH_VARIANTS"
fi
cfg "csd_flash_io" "tlwe_in_flash=$CSD_TLWE_IN_FLASH glwe_out_flash=$CSD_GLWE_OUT_FLASH"
cfg "csd_vp_ks_on_backend" "$CSD_VP_KS_ON_BACKEND"
cfg "csd_keep_session" "$CSD_KEEP_SESSION"
cfg "csd_keep_backend" "$CSD_KEEP_BACKEND"
cfg "keyset" "$KEYSET"
cfg "gpu_socket" "$GPU_SOCKET gpu_timeout=$GPU_TIMEOUT"
if [ -n "${CSD_VARIANTS_JSON:-}" ]; then
  cfg "csd_variants_json" "$CSD_VARIANTS_JSON"
fi
if [ -n "${CSD_VARIANTS_ALLOW_IDS:-}" ]; then
  cfg "csd_variants_allow_ids" "$CSD_VARIANTS_ALLOW_IDS"
fi
if [ -n "${CSD_VARIANTS_MAX_SERVICES:-}" ]; then
  cfg "csd_variants_max_services" "$CSD_VARIANTS_MAX_SERVICES"
fi
if [ -n "${CSD_VARIANTS_AUTO_FILTER:-}" ]; then
  cfg "csd_variants_auto_filter" "$CSD_VARIANTS_AUTO_FILTER"
fi
if [ -n "${CSD_FUNC_VARIANT_ID:-}" ]; then
  cfg "csd_func_variant_id" "$CSD_FUNC_VARIANT_ID"
fi
if [ -n "${CSD_SOFTMAX_VARIANT_ID:-}" ]; then
  cfg "csd_softmax_variant_id" "$CSD_SOFTMAX_VARIANT_ID"
fi
cfg "deepnn_tfhe_variant" "${DEEPNN_TFHE_VARIANT:-default}"
cfg "spqlios_fft" "$TFHE_GPU_SPQLIOS_FFT table=$TFHE_GPU_SPQLIOS_FFT_TABLE"
cfg "spqlios_ifft" "$TFHE_GPU_SPQLIOS_IFFT table=$TFHE_GPU_SPQLIOS_IFFT_TABLE"
cfg "deepnn_offload" "CSD_DEEPNN_OFFLOAD_SOFTMAX=$CSD_DEEPNN_OFFLOAD_SOFTMAX strict=$CSD_DEEPNN_OFFLOAD_SOFTMAX_STRICT max_mae=$CSD_DEEPNN_OFFLOAD_SOFTMAX_MAX_MAE"
cfg "deepnn_split" "CSD_DEEPNN_OFFLOAD_SOFTMAX_KSPBS_SPLIT=$CSD_DEEPNN_OFFLOAD_SOFTMAX_KSPBS_SPLIT WOP_GPU_KSPBS_SPLIT=${WOP_GPU_KSPBS_SPLIT:-0} luts=${WOP_GPU_KSPBS_SPLIT_LUTS:-}"
if [ -n "${CSD_DEEPNN_ROUNDING_BITS:-}" ]; then
  cfg "deepnn_rounding" "bits=$CSD_DEEPNN_ROUNDING_BITS method=${CSD_DEEPNN_ROUNDING_METHOD:-} allow_gt8=$CSD_DEEPNN_ALLOW_ROUNDING_BITS_GT8"
fi
cfg "deepnn_profile" "CSD_DEEPNN_PROFILE=$CSD_DEEPNN_PROFILE out=$CSD_DEEPNN_PROFILE_OUT"
cfg "deepnn_fhe" "CSD_DEEPNN_FHE_NVMEVIRT=$CSD_DEEPNN_FHE_NVMEVIRT backend=$CSD_DEEPNN_FHE_BACKEND device=$CSD_DEEPNN_FHE_DEVICE"
cfg "deepnn_fhe_exec" "$CSD_DEEPNN_FHE_EXECUTOR"
cfg "deepnn_fhe_require_gpu" "$CSD_DEEPNN_REQUIRE_GPU"
cfg "deepnn_fhe_mark_l2" "$CSD_DEEPNN_FHE_MARK_L2"
cfg "deepnn_fhe_compare" "CSD_DEEPNN_FHE_COMPARE_BACKENDS=$CSD_DEEPNN_FHE_COMPARE_BACKENDS strict=$CSD_DEEPNN_FHE_COMPARE_STRICT max_mae=$CSD_DEEPNN_FHE_COMPARE_MAX_MAE min_argmax=$CSD_DEEPNN_FHE_COMPARE_MIN_ARGMAX"
cfg "deepnn_fhe_uncompressed" "$CSD_DEEPNN_FHE_UNCOMPRESSED"
cfg "deepnn_fhe_keep_io" "$CSD_DEEPNN_FHE_KEEP_IO"
if env_enabled "$CSD_DEEPNN_FHE_UNCOMPRESSED"; then
  cfg "deepnn_fhe_compression" "USE_INPUT_COMPRESSION=${USE_INPUT_COMPRESSION:-1} USE_KEY_COMPRESSION=${USE_KEY_COMPRESSION:-1}"
fi
if [ -n "$WOPBS_FP_TOTAL_BITS" ] || [ -n "$WOPBS_FP_INT_BITS" ]; then
  cfg "wopbs_fp" "total_bits=${WOPBS_FP_TOTAL_BITS:-default} int_bits=${WOPBS_FP_INT_BITS:-default}"
fi
cfg "deepnn_fhe_io" "server_dir=$CSD_DEEPNN_FHE_SERVER_DIR eval_keys=$CSD_DEEPNN_FHE_EVAL_KEYS"
cfg "concrete_runner" "script=$WOP_GPU_CONCRETE_RUNNER python=$WOP_GPU_CONCRETE_PYTHON"
cfg "progress_output" "$PROGRESS_OUTPUT"
cfg "git_rev" "$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo

# Guard against glwe_dimension>1 (executor assumes glwe_dimension=1 today).
if [ -n "${CSD_DEEPNN_VARIANTS_JSON:-}" ] && [ -f "${CSD_DEEPNN_VARIANTS_JSON:-}" ]; then
  glwe_max="$(python3 - "$CSD_DEEPNN_VARIANTS_JSON" <<'PY'
import json, sys
v = json.loads(open(sys.argv[1]).read())
ks = [int(x.get("K", 0) or 0) for x in v if isinstance(x, dict)]
print(max(ks) if ks else 0)
PY
)"
  if [ "${glwe_max:-0}" -gt 1 ] && ! env_enabled "${CSD_DEEPNN_ALLOW_GLWE_GT1:-0}"; then
    echo "[err] variants_json contains glwe_dimension>1 but executor currently assumes glwe_dimension=1." >&2
    echo "[hint] set CSD_DEEPNN_ALLOW_GLWE_GT1=1 if you intentionally want to run (likely to fail), or pick a glwe=1 variant." >&2
    exit 2
  fi
fi
if [ -n "${CSD_DEEPNN_VARIANTS_JSON:-}" ] && [ -z "${CSD_VARIANTS_JSON:-}" ]; then
  echo "[hint] set CSD_VARIANTS_JSON to the backend variants JSON (keyset + gpu_socket) before NO_SUDO=0 runs." >&2
fi

if [ "$no_sudo" = "0" ]; then
  if ! sudo -n true >/dev/null 2>&1; then
    # Fail early unless the caller explicitly allows sudo prompts (for environments with timestamp_timeout=0).
    backend="${CSD_SOFTMAX_OFFLOAD_BACKEND:-auto}"
    if env_enabled "$CSD_DEEPNN_OFFLOAD_SOFTMAX" && [ "$backend" != "ipc" ] && [ "$backend" != "socket" ] && [ "$backend" != "direct" ]; then
      if env_enabled "${CSD_DEEPNN_ALLOW_SUDO_PROMPT:-0}"; then
        echo "[warn] sudo ticket missing; will prompt during run (CSD_DEEPNN_ALLOW_SUDO_PROMPT=1)." >&2
      else
        echo "[err] NO_SUDO=0 + CSD_DEEPNN_OFFLOAD_SOFTMAX=1 requires sudo without prompt." >&2
        echo "[hint] run 'sudo -v' in a terminal, or set CSD_DEEPNN_ALLOW_SUDO_PROMPT=1 to allow prompts." >&2
        exit 2
      fi
    fi
    if env_enabled "$CSD_DEEPNN_FHE_NVMEVIRT"; then
      if env_enabled "${CSD_DEEPNN_ALLOW_SUDO_PROMPT:-0}"; then
        echo "[warn] sudo ticket missing; will prompt during run (CSD_DEEPNN_ALLOW_SUDO_PROMPT=1)." >&2
      else
        echo "[err] NO_SUDO=0 + CSD_DEEPNN_FHE_NVMEVIRT=1 requires sudo without prompt." >&2
        echo "[hint] run 'sudo -v' in a terminal, or set CSD_DEEPNN_ALLOW_SUDO_PROMPT=1 to allow prompts." >&2
        exit 2
      fi
    fi
    echo "[warn] NO_SUDO=0 typically needs sudo; run 'sudo -v' in a terminal before starting long runs." >&2
    echo >&2
  fi
fi

if [ ! -f "$KEYSET" ]; then
  echo "[err] missing keyset: $KEYSET" >&2
  echo "[hint] set KEYSET=... or generate one via scripts/csd_gpu_nvmevirt_regression_oneclick.sh" >&2
  exit 2
fi

configure_gpu_runtime_service() {
  if [ -z "$WOPBS_FP_TOTAL_BITS" ] && [ -z "$WOPBS_FP_INT_BITS" ]; then
    return 0
  fi
  if [ "$WOPBS_FP_CONFIGURED" = "1" ]; then
    return 0
  fi
  WOPBS_FP_CONFIGURED=1
  echo "[setup] configure gpu_runtime_service (WOPBS fixed-point override)"
  cmake -S "$ROOT/sw/gpu_runtime_service" -B "$ROOT/sw/gpu_runtime_service/build-clean" \
    ${WOPBS_FP_TOTAL_BITS:+-DWOPBS_FP_TOTAL_BITS=$WOPBS_FP_TOTAL_BITS} \
    ${WOPBS_FP_INT_BITS:+-DWOPBS_FP_INT_BITS=$WOPBS_FP_INT_BITS}
}

ensure_spqlios_tables() {
  local fft_tbl="${TFHE_GPU_SPQLIOS_FFT_TABLE:-/tmp/spqlios_fft_table.n4096.bin}"
  local ifft_tbl="${TFHE_GPU_SPQLIOS_IFFT_TABLE:-/tmp/spqlios_ifft_table.n4096.bin}"
  if [ -f "$fft_tbl" ] && [ -f "$ifft_tbl" ]; then
    return 0
  fi

  local exporter="$ROOT/sw/gpu_runtime_service/build-clean/spqlios_table_exporter"
  if [ ! -x "$exporter" ]; then
    configure_gpu_runtime_service
    echo "[setup] build gpu_runtime_service (build-clean) for spqlios_table_exporter"
    cmake --build "$ROOT/sw/gpu_runtime_service/build-clean" -j "$BUILD_JOBS"
  fi
  if [ ! -x "$exporter" ]; then
    echo "[err] missing spqlios_table_exporter: $exporter" >&2
    exit 2
  fi

  echo "[setup] generate spqlios FFT/IFFT tables (if missing)"
  "$exporter" --fft-prefix "${fft_tbl%.n4096.bin}" --ifft-prefix "${ifft_tbl%.n4096.bin}" \
    >"$OUT_DIR/spqlios_table_exporter.log" 2>&1 || true

  if [ ! -f "$fft_tbl" ] || [ ! -f "$ifft_tbl" ]; then
    echo "[err] spqlios tables missing after generation" >&2
    echo "[err] fft=$fft_tbl ifft=$ifft_tbl" >&2
    echo "[err] see: $OUT_DIR/spqlios_table_exporter.log" >&2
    exit 2
  fi
}

gpu_service_pids=()
gpu_service_sockets=()

start_multi_variant_gpu_services() {
  local variants_json="$1"
  local entries=()
  mapfile -t entries < <(python3 - "$variants_json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
obj = json.load(open(path))
records = obj.get("variants", obj) if isinstance(obj, dict) else obj
if not isinstance(records, list):
    raise SystemExit(f"[err] variants_json must be list or dict with 'variants': {path}")

def _parse_ids(raw):
    ids = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            ids.append(int(part))
        except Exception:
            continue
    return ids

def _env_enabled(name, default="0"):
    value = str(os.environ.get(name, default))
    return value not in ("0", "", "false", "False", "no", "No")

def _record_id(rec, idx):
    if isinstance(rec, dict) and "id" in rec:
        try:
            return int(rec.get("id"))
        except Exception:
            return idx
    return idx

allow_ids = []
allow_env = os.environ.get("CSD_VARIANTS_ALLOW_IDS", "").strip()
if allow_env:
    allow_ids = _parse_ids(allow_env)
elif _env_enabled("CSD_VARIANTS_AUTO_FILTER", "0"):
    for key in ("CSD_SOFTMAX_VARIANT_ID", "CSD_FUNC_VARIANT_ID", "WOP_GPU_VARIANT_ID"):
        raw = str(os.environ.get(key, "")).strip()
        if not raw:
            continue
        try:
            allow_ids.append(int(raw))
        except Exception:
            continue

allow_set = set(allow_ids)
if allow_set:
    filtered = []
    for idx, rec in enumerate(records):
        if _record_id(rec, idx) in allow_set:
            filtered.append(rec)
    records = filtered
    print(f"[setup] limit variants to ids: {sorted(allow_set)}", file=sys.stderr)

max_services_raw = str(os.environ.get("CSD_VARIANTS_MAX_SERVICES", "")).strip()
if max_services_raw:
    try:
        max_services = int(max_services_raw)
    except Exception:
        max_services = 0
else:
    max_services = 0

if max_services > 0 and len(records) > max_services:
    records = records[:max_services]
    print(f"[setup] limit variants to first {max_services} entries", file=sys.stderr)

for idx, rec in enumerate(records):
    if not isinstance(rec, dict):
        continue
    vid = rec.get("id", idx)
    name = rec.get("name", f"variant{vid}")
    keyset = rec.get("keyset", "")
    gpu_bin = rec.get("gpu_service_bin") or rec.get("gpu_bin") or rec.get("gpu_service")
    socket = rec.get("gpu_socket", "")
    timeout = rec.get("gpu_timeout", os.environ.get("GPU_TIMEOUT", "120"))
    print(f"{vid}|{name}|{keyset}|{gpu_bin}|{socket}|{timeout}")
PY
)

  if [ "${#entries[@]}" -eq 0 ]; then
    echo "[err] empty variants_json: $variants_json" >&2
    exit 2
  fi

  ensure_spqlios_tables

  local selected_socket="$GPU_SOCKET"
  local selected_timeout="$GPU_TIMEOUT"
  local want_id="${CSD_FUNC_VARIANT_ID:-${WOP_GPU_VARIANT_ID:-}}"

  for entry in "${entries[@]}"; do
    IFS='|' read -r v_id v_name v_keyset v_bin v_socket v_timeout <<< "$entry"
    if [ -z "$v_id" ] || [ -z "$v_keyset" ] || [ -z "$v_bin" ] || [ -z "$v_socket" ]; then
      echo "[err] invalid variant entry: $entry" >&2
      exit 2
    fi
    if [ ! -f "$v_keyset" ]; then
      echo "[err] variant keyset missing: $v_keyset" >&2
      exit 2
    fi
    if [ ! -x "$v_bin" ]; then
      echo "[err] variant gpu_runtime_service missing: $v_bin" >&2
      exit 2
    fi

    rm -f "$v_socket" >/dev/null 2>&1 || true
    pkill -9 -f "[g]pu_runtime_service.*${v_socket}" >/dev/null 2>&1 || true

    local log="$OUT_DIR/gpu_runtime_service_${v_id}.log"
    if [ "$v_id" = "0" ]; then
      log="$OUT_DIR/gpu_runtime_service.log"
    fi
    WOP_GPU_KEY_IMPORT="$v_keyset" \
      WOP_GPU_KEY_EXPORT="$v_keyset" \
      WOP_GPU_VARIANT_ID="$v_id" \
      WOP_GPU_VARIANT_NAME="$v_name" \
      "$v_bin" "$v_socket" >"$log" 2>&1 &
    gpu_service_pids+=("$!")
    gpu_service_sockets+=("$v_socket")

    for _ in $(seq 1 60); do
      if [ -S "$v_socket" ]; then
        break
      fi
      sleep 1
    done
    if [ ! -S "$v_socket" ]; then
      echo "[err] gpu_runtime_service socket not ready: $v_socket" >&2
      tail -n 120 "$log" || true
      exit 2
    fi

    if [ -n "$want_id" ] && [ "$v_id" = "$want_id" ]; then
      selected_socket="$v_socket"
      selected_timeout="$v_timeout"
    fi
  done

  if [ -z "$want_id" ]; then
    IFS='|' read -r v_id v_name v_keyset v_bin v_socket v_timeout <<< "${entries[0]}"
    selected_socket="$v_socket"
    selected_timeout="$v_timeout"
  fi

  export GPU_SOCKET="$selected_socket"
  export GPU_TIMEOUT="$selected_timeout"
  export CSD_SOFTMAX_VARIANTS_JSON="$variants_json"
}

start_gpu_service_if_needed() {
  if [ "$CSD_DEEPNN_OFFLOAD_SOFTMAX" = "0" ] || [ "$CSD_DEEPNN_OFFLOAD_SOFTMAX" = "false" ] || [ "$CSD_DEEPNN_OFFLOAD_SOFTMAX" = "False" ]; then
    return 0
  fi
  if [ ! -d "$NVMEVIRT_ROOT/tools" ]; then
    echo "[err] nvmevirt tools not found: $NVMEVIRT_ROOT/tools" >&2
    exit 2
  fi

  export PYTHONPATH="$NVMEVIRT_ROOT/tools:${PYTHONPATH:-}"

  local variants_json="${CSD_VARIANTS_JSON:-}"
  if [ "$no_sudo" = "1" ] && [ -n "$variants_json" ] && [ -f "$variants_json" ]; then
    start_multi_variant_gpu_services "$variants_json"
    return 0
  fi

  export WOP_GPU_KEY_IMPORT="${WOP_GPU_KEY_IMPORT:-$KEYSET}"
  export WOP_GPU_KEY_EXPORT="${WOP_GPU_KEY_EXPORT:-$KEYSET}"

  if [ ! -x "$GPU_SERVICE_BIN" ]; then
    configure_gpu_runtime_service
    echo "[setup] build gpu_runtime_service (build-clean) for gpu_runtime_service"
    cmake --build "$ROOT/sw/gpu_runtime_service/build-clean" -j "$BUILD_JOBS"
  fi
  if [ ! -x "$GPU_SERVICE_BIN" ]; then
    echo "[err] gpu_runtime_service missing/executable: $GPU_SERVICE_BIN" >&2
    exit 2
  fi
  ensure_spqlios_tables

  rm -f "$GPU_SOCKET" >/dev/null 2>&1 || true
  pkill -9 -f "[g]pu_runtime_service.*${GPU_SOCKET}" >/dev/null 2>&1 || true

  "$GPU_SERVICE_BIN" "$GPU_SOCKET" >"$OUT_DIR/gpu_runtime_service.log" 2>&1 &
  gpu_service_pids+=("$!")
  gpu_service_sockets+=("$GPU_SOCKET")

  local wait_secs="${GPU_SERVICE_WAIT_SECS:-60}"
  for _ in $(seq 1 "$wait_secs"); do
    if [ -S "$GPU_SOCKET" ]; then
      last_pid_idx=$(( ${#gpu_service_pids[@]} - 1 ))
      echo "[setup] gpu_runtime_service ready: $GPU_SOCKET (pid=${gpu_service_pids[$last_pid_idx]})"
      return 0
    fi
    sleep 1
  done

  echo "[err] gpu_runtime_service socket not ready: $GPU_SOCKET" >&2
  tail -n 120 "$OUT_DIR/gpu_runtime_service.log" || true
  exit 2
}

cleanup() {
  if [ "${#gpu_service_pids[@]}" -gt 0 ]; then
    for pid in "${gpu_service_pids[@]}"; do
      kill "$pid" >/dev/null 2>&1 || true
    done
    sleep 0.2
    for pid in "${gpu_service_pids[@]}"; do
      kill -9 "$pid" >/dev/null 2>&1 || true
    done
    gpu_service_pids=()
  fi
  if [ "${#gpu_service_sockets[@]}" -gt 0 ]; then
    for sock in "${gpu_service_sockets[@]}"; do
      pkill -9 -f "[g]pu_runtime_service.*${sock}" >/dev/null 2>&1 || true
      rm -f "$sock" >/dev/null 2>&1 || true
    done
    gpu_service_sockets=()
  else
    pkill -9 -f "[g]pu_runtime_service.*${GPU_SOCKET}" >/dev/null 2>&1 || true
    rm -f "$GPU_SOCKET" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

start_gpu_service_if_needed

deep_nn_cmd=()
if [ "$#" -gt 0 ]; then
  if [ "$1" = "--" ]; then
    shift
  fi
  if [ "$#" -gt 0 ]; then
    deep_nn_cmd=("$@")
  fi
fi

if [ "${#deep_nn_cmd[@]}" -eq 0 ] && [ -n "${DEEP_NN_CMD:-}" ]; then
  # shellcheck disable=SC2206
  deep_nn_cmd=(${DEEP_NN_CMD})
fi

if [ "${#deep_nn_cmd[@]}" -eq 0 ]; then
  deep_nn_root="${DEEP_NN_ROOT:-$HOME/workspace/deep-nn}"
  deep_nn_py="${DEEP_NN_PY:-$deep_nn_root/.venv/bin/python}"
  deep_nn_entry="${DEEP_NN_ENTRY:-$deep_nn_root/benchmarks/deep_learning.py}"
  deep_nn_fhe_samples="${CSD_DEEPNN_FHE_SAMPLES:-1}"
  deep_nn_model_samples="${CSD_DEEPNN_MODEL_SAMPLES:-1}"

  if [ -x "$deep_nn_py" ] && [ -f "$deep_nn_entry" ]; then
    deep_nn_cmd=(
      "$deep_nn_py"
      "$deep_nn_entry"
      --models ShallowNarrowCNN
      --datasets MNIST
      --configs '{"n_bits":2,"p_error":9.094947017729282e-13}'
      --fhe_samples "$deep_nn_fhe_samples"
      --model_samples "$deep_nn_model_samples"
    )
    cfg "deepnn_samples" "fhe_samples=$deep_nn_fhe_samples model_samples=$deep_nn_model_samples"
  else
    echo "[err] deep-nn command missing (pass it after --, or set DEEP_NN_CMD=...)" >&2
    echo "[hint] default workload expects concrete-ml repo at: $deep_nn_root" >&2
    usage
    exit 2
  fi
fi

echo "[run] deep-nn macrobenchmark:"
printf '  %q' "${deep_nn_cmd[@]}"
echo
echo

log="$OUT_DIR/run.log"
console_pretty="${CSD_DEEPNN_CONSOLE_PRETTY:-1}"
if env_enabled "$console_pretty"; then
  (cd "$ROOT" && "${deep_nn_cmd[@]}" 2>&1) | tee "$log" | tr '\r' '\n' | awk '
function strip_ansi(s) {
  # CSI: ESC [ ... final-byte (covers ?-params used by tqdm, e.g. ESC[?25l)
  gsub(/\x1B\[[0-9;:<=>?]*[ -/]*[@-~]/, "", s)
  # OSC: ESC ] ... BEL
  gsub(/\x1B\][0-9;]*[^\x07]*\x07/, "", s)
  # OSC: ESC ] ... ESC \
  gsub(/\x1B\][^\x1B]*\x1B\\/, "", s)
  # Any remaining single-character ESC sequences
  gsub(/\x1B./, "", s)
  return s
}
function normalize(line) {
  gsub(/\x08/, "", line)          # backspace
  line = strip_ansi(line)
  gsub(/\t/, "  ", line)
  sub(/^[[:space:]]+\|[[:space:]]+/, "", line) # py_progress_tracker tree prefix
  sub(/^[[:space:]]+/, "", line)               # lstrip (tqdm clears lines with spaces)
  sub(/[[:space:]]+$/, "", line)               # rstrip
  return line
}
function emit(line) {
  line = normalize(line)
  print line
  fflush()
}
function is_tqdm_progress(line) {
  return line ~ /^[0-9]{1,3}%\|/
}
BEGIN {
  prev_blank = 0
}
{
  line = normalize($0)
  if (line == "") {
    if (prev_blank == 0) {
      emit("")
    }
    prev_blank = 1
    next
  }

  # tqdm progress bars may print without newline; keep the evidence tag only.
  pos = index(line, "[CSD_DEEPNN]")
  if (pos > 0) {
    prev_blank = 0
    emit(substr(line, pos))
    next
  }

  # Drop tqdm lines to keep the console output readable; raw output is in run.log.
  if (is_tqdm_progress(line)) {
    next
  }

  prev_blank = 0
  emit(line)
}'
else
  (cd "$ROOT" && "${deep_nn_cmd[@]}" 2>&1) | tee "$log"
fi

if env_enabled "$CSD_DEEPNN_PROFILE" && [ -f "$CSD_DEEPNN_PROFILE_OUT" ]; then
  python3 "$ROOT/tools/csd_deepnn_profile_summary.py" "$CSD_DEEPNN_PROFILE_OUT" \
    >"$OUT_DIR/deepnn_profile_summary.txt" 2>&1 || true
fi

if env_enabled "$CSD_DEEPNN_FHE_NVMEVIRT"; then
  server_zip="$CSD_DEEPNN_FHE_SERVER_DIR/server.zip"
  if [ -f "$server_zip" ]; then
    python3 "$ROOT/tools/csd_concrete_mlir_summary.py" --server-zip "$server_zip" \
      --out "$OUT_DIR/concrete_mlir_summary.json" >/dev/null 2>&1 || true
  fi
fi

summary_args=("--out-dir" "$OUT_DIR" "--keyset" "$KEYSET")
if [ -n "${CSD_DEEPNN_VARIANTS_JSON:-}" ] && [ -f "${CSD_DEEPNN_VARIANTS_JSON:-}" ]; then
  summary_args+=("--variants-json" "$CSD_DEEPNN_VARIANTS_JSON")
fi

python3 "$ROOT/tools/csd_deepnn_run_summary.py" "${summary_args[@]}" \
  >"$OUT_DIR/deepnn_run_summary.txt" 2>&1 || true

echo
echo "[ok] deep-nn macrobenchmark finished. Artifacts saved under: $OUT_DIR"
if [ -f "$OUT_DIR/deepnn_profile_summary.txt" ]; then
  echo "[ok] deep-nn profile summary saved: $OUT_DIR/deepnn_profile_summary.txt"
fi
if [ -f "$OUT_DIR/deepnn_run_summary.txt" ]; then
  echo "[ok] deep-nn run summary saved: $OUT_DIR/deepnn_run_summary.txt"
  echo "[summary] deep-nn vs keyset param alignment (quick):"
  rg -n "^param_alignment_hint:|^  fully_compatible|^  blocking_reasons|^  missing_poly_sizes|^  input_lwe_dims_exceed_keyset_n_lvl0|^  unsupported_glwe_dimensions" \
    "$OUT_DIR/deepnn_run_summary.txt" \
    | sed 's/^/  /' || true
fi
echo "[hint] quick grep: rg -n \"\\[PASS\\]|\\[FAIL\\]|error|timeout|metrics\" \"$OUT_DIR/run.log\""
