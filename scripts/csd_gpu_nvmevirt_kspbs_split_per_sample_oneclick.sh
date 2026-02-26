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

KEYSET_DEFAULT="$ROOT/tmp_assets/wop_keyset.bin"
KEYSET="${KEYSET:-$KEYSET_DEFAULT}"
BUILD_JOBS="${BUILD_JOBS:-8}"

# This case needs extra TLWE tail bytes (lut_id[]), so use staging mode by default.
CSD_USE_PRP_ENV_SET=0
if [ "${CSD_USE_PRP+x}" = "x" ]; then
  CSD_USE_PRP_ENV_SET=1
fi
CSD_USE_PRP="${CSD_USE_PRP:-0}"
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
OUT_DIR="${OUT_DIR:-/tmp/csd_gpu_nvmevirt_kspbs_split_per_sample_${RUN_ID}}"
mkdir -p "$OUT_DIR"

INPUT_BIN="$OUT_DIR/kspbs_input_lvl1_batch.bin"
OUT_BIN="$OUT_DIR/kspbs_out_lvl1_batch.bin"

# Per-sample LUT list (default: 4 samples, mixed LUTs to exercise grouping).
LUT_IDS="${LUT_IDS:-1,2,1,3}"
TORUS_SIZE="${TORUS_SIZE:-32}"

cfg() { printf '[cfg] %-20s %s\n' "$1" "$2"; }

cfg "ROOT" "$ROOT"
cfg "NVMEVIRT_ROOT" "$NVMEVIRT_ROOT"
cfg "dev" "$DEV nsid=$NSID engine=$ENGINE mode=$MODE flags=0x$(printf '%02x' "$FLAGS")"
cfg "keyset" "$KEYSET"
cfg "out_dir" "$OUT_DIR"
cfg "csd_use_prp" "$CSD_USE_PRP no_sudo=$NO_SUDO"
cfg "csd_flash_io" "tlwe_in_flash=$CSD_TLWE_IN_FLASH glwe_out_flash=$CSD_GLWE_OUT_FLASH"
cfg "no_fallback" "$CSD_NO_FALLBACK"
cfg "gpu_socket" "$GPU_SOCKET gpu_timeout=$GPU_TIMEOUT"
cfg "lut_ids" "$LUT_IDS torus_size=$TORUS_SIZE"
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

ensure_spqlios_tables() {
  if [ -f "$TFHE_GPU_SPQLIOS_FFT_TABLE" ] && [ -f "$TFHE_GPU_SPQLIOS_IFFT_TABLE" ]; then
    return 0
  fi
  local exporter="$ROOT/sw/gpu_runtime_service/build-clean/spqlios_table_exporter"
  if [ ! -x "$exporter" ]; then
    echo "[err] missing spqlios_table_exporter: $exporter" >&2
    exit 1
  fi
  echo "[1.5/4] Generate spqlios FFT/IFFT tables (if missing)"
  "$exporter" --fft-prefix "${TFHE_GPU_SPQLIOS_FFT_TABLE%.n4096.bin}" \
              --ifft-prefix "${TFHE_GPU_SPQLIOS_IFFT_TABLE%.n4096.bin}" \
    >"$OUT_DIR/spqlios_table_exporter.log" 2>&1 || true
  if [ ! -f "$TFHE_GPU_SPQLIOS_FFT_TABLE" ] || [ ! -f "$TFHE_GPU_SPQLIOS_IFFT_TABLE" ]; then
    echo "[err] spqlios table generation failed; see $OUT_DIR/spqlios_table_exporter.log" >&2
    exit 1
  fi
}
ensure_spqlios_tables

echo "[2/4] Generate deterministic lvl1 LWE batch input + lut_id[] tail"
TLWE_WORDS="$(
  PYTHONPATH="$NVMEVIRT_ROOT/tools:${PYTHONPATH:-}" python3 - "$KEYSET" "$INPUT_BIN" "$LUT_IDS" <<'PY' | tail -n 1
from pathlib import Path
import sys
import numpy as np
from csd_kspbs_split_common import read_keyset_header

keyset = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
lut_ids_str = sys.argv[3].strip()

hdr = read_keyset_header(keyset)
lvl1_words = int(hdr.n_lvl1) + 1

lut_ids = [int(x) & 0xFF for x in lut_ids_str.split(",") if x.strip() != ""]
if not lut_ids:
    raise SystemExit("lut_ids is empty")
batch = len(lut_ids)

rng = np.random.default_rng(1)
lwe_u32 = rng.integers(0, 2**32, size=(batch * lvl1_words,), dtype=np.uint32)
lwe_u64 = lwe_u32.astype(np.uint64)
payload = lwe_u64.astype(np.dtype("<u8")).tobytes() + bytes(lut_ids)
out.write_bytes(payload)

print(f"[gen] keyset={keyset} lvl1_words={lvl1_words} batch={batch} out={out}", file=sys.stderr)
print(batch * lvl1_words)
PY
)"
GLWE_WORDS="${GLWE_WORDS:-$TLWE_WORDS}"

# TLWE tail bytes: one u8 per sample.
LUT_TAIL_BYTES="$(
  python3 - "$LUT_IDS" <<'PY'
import sys
s = sys.argv[1].strip()
ids = [x for x in s.split(",") if x.strip() != ""]
print(len(ids))
PY
)"
TLWE_STAGE_BYTES="${TLWE_STAGE_BYTES:-$((TLWE_WORDS * 8 + LUT_TAIL_BYTES))}"

cfg "words" "tlwe_words=$TLWE_WORDS glwe_words=$GLWE_WORDS tlwe_stage_bytes=$TLWE_STAGE_BYTES lut_tail_bytes=$LUT_TAIL_BYTES"

# gpu_shared_addr bit[24]=per-sample-lut, bits[23:8]=torus_size, bits[7:0]=lut_id (ignored when per-sample).
GPU_SHARED_ADDR=$(( (1 << 24) | ((TORUS_SIZE & 0xFFFF) << 8) ))
export GPU_SHARED_ADDR

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
  echo "[PASS] KSPBS split per-sample-lut smoke OK. Artifacts saved under: $SMOKE_OUT_DIR"
  exit 0
fi

echo "[3/4] Run nvmevirt e2e KSPBS split per-sample-lut (needs sudo)"
make -C "$NVMEVIRT_ROOT" -j "$BUILD_JOBS"

HPU_FPGA_FIN_ROOT="$ROOT" \
KEYSET="$KEYSET" \
BACKEND_LOG="$OUT_DIR/backend.log" \
GPU_SERVICE_LOG="$OUT_DIR/gpu_runtime_service.log" \
DMESG_OUT="$OUT_DIR/dmesg_new.log" \
DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" MODE="$MODE" FLAGS="$FLAGS" \
GPU_SHARED_ADDR="$GPU_SHARED_ADDR" \
TLWE_WORDS="$TLWE_WORDS" GLWE_WORDS="$GLWE_WORDS" \
TLWE_STAGE_BYTES="$TLWE_STAGE_BYTES" \
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
  echo "[PASS] nvmevirt e2e KSPBS split per-sample-lut OK. Artifacts saved under: $OUT_DIR"
  exit 0
fi

echo "[FAIL] nvmevirt e2e KSPBS split per-sample-lut failed. Artifacts: $OUT_DIR" >&2
exit 2
