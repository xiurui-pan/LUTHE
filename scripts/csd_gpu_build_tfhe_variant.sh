#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Generic builder for a patched TFHE GPU baseline variant:
# - creates an overlay (symlink tree + patched src/tfhe_types.h)
# - builds gpu_runtime_service + gpu_executor_smoke + keyset_exporter
# - optionally generates a keyset via keyset_exporter

BASE_TFHE_GPU_ROOT="${BASE_TFHE_GPU_ROOT:-$ROOT/../tfhe-gpu-baseline-wopbs}"
TFHE_CPU_ROOT_RESOLVED="${TFHE_CPU_ROOT:-$ROOT/../tfhe-cpu-baseline-wopbs}"
BUILD_JOBS="${BUILD_JOBS:-8}"

K="${K:-1}"
N_LVL0="${N_LVL0:-500}"
N_LVL1="${N_LVL1:-1024}"
N_LVL2="${N_LVL2:-2048}"
ELL_LVL2="${ELL_LVL2:-}"
BGBIT_LVL2="${BGBIT_LVL2:-}"
BKSTDEV_LVL2="${BKSTDEV_LVL2:-}"
NAME="${NAME:-k${K}_n0${N_LVL0}_n1${N_LVL1}_n2${N_LVL2}}"

OUT_OVERLAY_ROOT="${OUT_OVERLAY_ROOT:-$ROOT/sw/gpu_runtime_service/overlays/$NAME}"
BUILD_DIR="${BUILD_DIR:-$ROOT/sw/gpu_runtime_service/build-$NAME}"
KEYSET_OUT="${KEYSET_OUT:-}"
GEN_KEYSET="${GEN_KEYSET:-0}"

echo "[cfg] NAME               $NAME"
echo "[cfg] BASE_TFHE_GPU_ROOT $BASE_TFHE_GPU_ROOT"
echo "[cfg] OUT_OVERLAY_ROOT  $OUT_OVERLAY_ROOT"
echo "[cfg] BUILD_DIR         $BUILD_DIR"
echo "[cfg] K/N               K=$K n_lvl0=$N_LVL0 n_lvl1=$N_LVL1 n_lvl2=$N_LVL2"
echo "[cfg] TFHE_CPU_ROOT     $TFHE_CPU_ROOT_RESOLVED"
if [ -n "${ELL_LVL2:-}" ] || [ -n "${BGBIT_LVL2:-}" ] || [ -n "${BKSTDEV_LVL2:-}" ]; then
  echo "[cfg] BK params         ell_lvl2=${ELL_LVL2:-} bgbit_lvl2=${BGBIT_LVL2:-} bkstdev_lvl2=${BKSTDEV_LVL2:-}"
fi
if [ -n "${KEYSET_OUT:-}" ]; then
  echo "[cfg] KEYSET_OUT        $KEYSET_OUT"
fi
echo
overlay_args=(
  --base "$BASE_TFHE_GPU_ROOT"
  --out "$OUT_OVERLAY_ROOT"
  --k "$K"
  --n-lvl0 "$N_LVL0"
  --n-lvl1 "$N_LVL1"
  --n-lvl2 "$N_LVL2"
)
if [ -n "${ELL_LVL2:-}" ]; then
  overlay_args+=(--ell-lvl2 "$ELL_LVL2")
fi
if [ -n "${BGBIT_LVL2:-}" ]; then
  overlay_args+=(--bgbit-lvl2 "$BGBIT_LVL2")
fi
if [ -n "${BKSTDEV_LVL2:-}" ]; then
  overlay_args+=(--bkstdev-lvl2 "$BKSTDEV_LVL2")
fi
overlay_args+=(--force)

python3 "$ROOT/tools/tfhe_gpu_overlay_builder.py" "${overlay_args[@]}"

if [ ! -d "$TFHE_CPU_ROOT_RESOLVED" ]; then
  echo "[err] TFHE_CPU_ROOT missing: $TFHE_CPU_ROOT_RESOLVED" >&2
  exit 2
fi

cmake_args=(-S "$ROOT/sw/gpu_runtime_service" -B "$BUILD_DIR" -D TFHE_GPU_ROOT="$OUT_OVERLAY_ROOT" -D TFHE_CPU_ROOT="$TFHE_CPU_ROOT_RESOLVED")
if [ -n "${WOPBS_FP_TOTAL_BITS:-}" ]; then
  cmake_args+=(-D "WOPBS_FP_TOTAL_BITS=${WOPBS_FP_TOTAL_BITS}")
fi
if [ -n "${WOPBS_FP_INT_BITS:-}" ]; then
  cmake_args+=(-D "WOPBS_FP_INT_BITS=${WOPBS_FP_INT_BITS}")
fi
if [ -n "${WOPBS_FP_EXP_LO_BITS:-}" ]; then
  cmake_args+=(-D "WOPBS_FP_EXP_LO_BITS=${WOPBS_FP_EXP_LO_BITS}")
fi
if [ -n "${WOPBS_FP_EXP_LUT_BITS:-}" ]; then
  cmake_args+=(-D "WOPBS_FP_EXP_LUT_BITS=${WOPBS_FP_EXP_LUT_BITS}")
fi
if [ -n "${WOPBS_FP_EXP_LUT_INDEX_BITS:-}" ]; then
  cmake_args+=(-D "WOPBS_FP_EXP_LUT_INDEX_BITS=${WOPBS_FP_EXP_LUT_INDEX_BITS}")
fi
if [ -n "${WOPBS_FP_EXP_LUT_LOW_BITS:-}" ]; then
  cmake_args+=(-D "WOPBS_FP_EXP_LUT_LOW_BITS=${WOPBS_FP_EXP_LUT_LOW_BITS}")
fi
cmake "${cmake_args[@]}"
cmake --build "$BUILD_DIR" -j "$BUILD_JOBS"

if [ ! -x "$BUILD_DIR/gpu_runtime_service" ] || [ ! -x "$BUILD_DIR/gpu_executor_smoke" ] || [ ! -x "$BUILD_DIR/gpu_function_eval_smoke" ] || [ ! -x "$BUILD_DIR/keyset_exporter" ]; then
  echo "[err] build incomplete under $BUILD_DIR" >&2
  ls -la "$BUILD_DIR" >&2 || true
  exit 2
fi

echo
echo "[ok] built:"
echo "  $BUILD_DIR/gpu_runtime_service"
echo "  $BUILD_DIR/gpu_executor_smoke"
echo "  $BUILD_DIR/gpu_function_eval_smoke"
echo "  $BUILD_DIR/keyset_exporter"

if [ -n "${KEYSET_OUT:-}" ]; then
  if [ "$GEN_KEYSET" = "1" ]; then
    regen_reason=""
    if [ "${FORCE_REGEN_KEYSET:-0}" = "1" ]; then
      regen_reason="FORCE_REGEN_KEYSET=1"
    fi
    if [ -z "$regen_reason" ] && [ -n "${ELL_LVL2:-}${BGBIT_LVL2:-}${BKSTDEV_LVL2:-}" ]; then
      regen_reason="BK params set"
    fi
    if [ -n "$regen_reason" ] && [ -f "$KEYSET_OUT" ]; then
      echo
      echo "[warn] keyset exists, regen ($regen_reason): $KEYSET_OUT"
      rm -f "$KEYSET_OUT"
    fi
    if [ ! -f "$KEYSET_OUT" ]; then
      echo
      echo "[run] generate keyset: $KEYSET_OUT"
      "$BUILD_DIR/keyset_exporter" "$KEYSET_OUT"
      echo "[ok] keyset generated"
    else
      echo
      echo "[ok] keyset exists, skip generation: $KEYSET_OUT"
    fi
  else
    echo
    echo "[ok] skip keyset generation (set GEN_KEYSET=1 to generate): $KEYSET_OUT"
  fi
fi
