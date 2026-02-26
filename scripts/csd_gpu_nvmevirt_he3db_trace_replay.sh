#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NVMEVIRT_ROOT="${NVMEVIRT_ROOT:-$ROOT/../nvmevirt}"

DEV="${DEV:-/dev/nvme2n1}"
NSID="${NSID:-1}"
KEYSET="${KEYSET:-$ROOT/tmp_assets/wop_keyset.bin}"
GPU_SOCKET="${GPU_SOCKET:-/tmp/wop_gpu_runtime.sock}"
GPU_TIMEOUT="${GPU_TIMEOUT:-240}"
BUILD_JOBS="${BUILD_JOBS:-8}"
KO_PARAMS="${KO_PARAMS:-memmap_start=128G memmap_size=16G cpus=7,8 host_ctrl_socket_path=/tmp/wop_host_ctrl.sock}"

TRACE_4096="${TRACE_4096:-/home/pxr/workspace/he3db/he3db-4096-trace-v1.txt}"
TRACE_16384="${TRACE_16384:-/home/pxr/workspace/he3db/he3db-16384-trace-v1.txt}"

RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_PARENT="${OUT_PARENT:-/tmp/csd_he3db_replay_${RUN_ID}}"

GPU_SERVICE_BIN="${GPU_SERVICE_BIN:-$ROOT/sw/gpu_runtime_service/build-clean/gpu_runtime_service}"
CPU_RUNNER="${CPU_RUNNER:-$ROOT/sw/gpu_runtime_service/build-clean/cpu_reference_runner}"
BACKEND_SOCKET="/tmp/wop_host_ctrl.sock"

cfg() { printf '[cfg] %-20s %s\n' "$1" "$2"; }

cfg "ROOT" "$ROOT"
cfg "NVMEVIRT_ROOT" "$NVMEVIRT_ROOT"
cfg "dev" "$DEV nsid=$NSID"
cfg "keyset" "$KEYSET"
cfg "gpu_socket" "$GPU_SOCKET gpu_timeout=$GPU_TIMEOUT"
cfg "out_parent" "$OUT_PARENT"
cfg "trace_4096" "$TRACE_4096"
cfg "trace_16384" "$TRACE_16384"
echo

if [ ! -f "$KEYSET" ]; then
  echo "[err] missing keyset: $KEYSET" >&2
  exit 1
fi
if [ ! -x "$GPU_SERVICE_BIN" ]; then
  echo "[err] missing gpu_runtime_service: $GPU_SERVICE_BIN" >&2
  exit 1
fi
if [ ! -d "$NVMEVIRT_ROOT" ]; then
  echo "[err] nvmevirt repo not found: $NVMEVIRT_ROOT" >&2
  exit 1
fi

mkdir -p "$OUT_PARENT"

if ! sudo -n true >/dev/null 2>&1; then
  echo "[err] sudo ticket missing; run: sudo -v" >&2
  exit 1
fi

if [ ! -f "$ROOT/sw/gpu_runtime_service/build-clean/CMakeCache.txt" ]; then
  cmake -S "$ROOT/sw/gpu_runtime_service" -B "$ROOT/sw/gpu_runtime_service/build-clean"
fi
cmake --build "$ROOT/sw/gpu_runtime_service/build-clean" -j "$BUILD_JOBS"

make -C "$NVMEVIRT_ROOT" -j "$BUILD_JOBS"

sudo rmmod nvmev >/dev/null 2>&1 || true
sudo insmod "$NVMEVIRT_ROOT/nvmev.ko" $KO_PARAMS

rm -f "$GPU_SOCKET" >/dev/null 2>&1 || true
pkill -9 -f "[g]pu_runtime_service.*${GPU_SOCKET}" >/dev/null 2>&1 || true
"$GPU_SERVICE_BIN" "$GPU_SOCKET" >"$OUT_PARENT/gpu_runtime_service.log" 2>&1 &
GPU_SERVICE_PID=$!

for _ in $(seq 1 60); do
  if [ -S "$GPU_SOCKET" ]; then
    break
  fi
  sleep 1
done
if [ ! -S "$GPU_SOCKET" ]; then
  echo "[err] gpu_runtime_service socket not ready: $GPU_SOCKET" >&2
  tail -n 120 "$OUT_PARENT/gpu_runtime_service.log" || true
  exit 1
fi

run_trace() {
  local trace_path="$1"
  local name="$2"
  local out_dir="$OUT_PARENT/$name"
  mkdir -p "$out_dir"
  echo
  echo "[run] $name trace=$trace_path"
  sudo pkill -f "[c]sd_sw_backend.py" >/dev/null 2>&1 || true
  sudo rm -f "$BACKEND_SOCKET" >/dev/null 2>&1 || true

  sudo env \
    KEYSET="$KEYSET" \
    GPU_SOCKET="$GPU_SOCKET" \
    GPU_TIMEOUT="$GPU_TIMEOUT" \
    CSD_KSPBS_SPLIT_VALIDATE=0 \
    CSD_PIPELINE_TRACE=1 \
    CSD_PIPELINE_TRACE_OUT="$out_dir/pipeline_trace.log" \
    "$NVMEVIRT_ROOT/tools/csd_sw_backend.py" \
    --socket "$BACKEND_SOCKET" \
    --engine gpu \
    --keyset "$KEYSET" \
    --gpu-socket "$GPU_SOCKET" \
    --gpu-timeout "$GPU_TIMEOUT" \
    --cpu-runner "$CPU_RUNNER" \
    --log-level WARNING \
    >"$out_dir/backend.log" 2>&1 &

  for _ in $(seq 1 20); do
    if [ -S "$BACKEND_SOCKET" ]; then
      break
    fi
    sleep 0.2
  done
  if [ ! -S "$BACKEND_SOCKET" ]; then
    echo "[err] backend socket not ready: $BACKEND_SOCKET" >&2
    tail -n 120 "$out_dir/backend.log" || true
    exit 1
  fi

  sudo env \
    PYTHONUNBUFFERED=1 \
    python3 "$ROOT/tools/he3db_trace_replay.py" \
      --trace "$trace_path" \
      --keyset "$KEYSET" \
      --dev "$DEV" \
      --nsid "$NSID" \
      --mode 3 \
      --flags 0x08 \
      --no-prp \
      --log-every 10000 \
      >"$out_dir/replay.log" 2>&1
  tail -n 20 "$out_dir/replay.log" || true
  if [ -f "$out_dir/pipeline_trace.log" ]; then
    python3 "$ROOT/tools/pipeline_overlap_analyzer.py" --out "$out_dir" "$out_dir/pipeline_trace.log" || true
  fi
}

run_trace "$TRACE_4096" "trace_4096"
run_trace "$TRACE_16384" "trace_16384"

echo
echo "[ok] he3db trace replay finished. Artifacts saved under: $OUT_PARENT"
