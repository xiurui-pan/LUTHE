#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSD_NO_FALLBACK="${CSD_NO_FALLBACK:-0}"
# shellcheck source=/dev/null
source "$ROOT/scripts/csd_no_fallback.sh"
NVMEVIRT_ROOT="${NVMEVIRT_ROOT:-$ROOT/../nvmevirt}"
E2E_SH="${E2E_SH:-$NVMEVIRT_ROOT/tools/csd_e2e_smoke.sh}"

usage() {
  cat <<'EOF' >&2
usage:
  NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_deepnn_pbs_hotspot_oneclick.sh --profile <deepnn_profile.json>
  NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_deepnn_pbs_hotspot_oneclick.sh --out-dir <macro OUT_DIR>
  NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_deepnn_pbs_hotspot_oneclick.sh --profile <deepnn_profile.json>

notes:
  - Picks the most frequent BootstrapKeyParam from deep-nn profile and runs a CB(mode=2) e2e.
  - Builds a matching GPU runtime variant/keyset if missing.
  - NO_SUDO=1 uses IPC against gpu_runtime_service (no nvmevirt); NO_SUDO=0 requires sudo.
EOF
}

profile=""
out_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
      ;;
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[err] unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -n "$out_dir" ] && [ -z "$profile" ]; then
  profile="$out_dir/deepnn_profile.json"
fi
if [ -z "$profile" ]; then
  echo "[err] missing --profile or --out-dir" >&2
  usage
  exit 2
fi
if [ ! -f "$profile" ]; then
  echo "[err] missing deepnn_profile.json: $profile" >&2
  exit 2
fi
if [ ! -x "$E2E_SH" ]; then
  echo "[err] missing e2e script: $E2E_SH" >&2
  exit 1
fi

RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-/tmp/csd_gpu_nvmevirt_deepnn_pbs_hotspot_${RUN_ID}}"
mkdir -p "$OUT_DIR"

NO_SUDO="${NO_SUDO:-0}"

csd_no_fallback_require_no_sudo

HOTSPOT_MAX_POLY="${CSD_DEEPNN_PBS_HOTSPOT_MAX_POLY:-}"
if [ "$NO_SUDO" = "1" ] && [ -z "$HOTSPOT_MAX_POLY" ]; then
  HOTSPOT_MAX_POLY=2048
fi
HOTSPOT_MAX_GLWE="${CSD_DEEPNN_PBS_HOTSPOT_MAX_GLWE:-}"
if [ "$NO_SUDO" = "1" ] && [ -z "$HOTSPOT_MAX_GLWE" ]; then
  HOTSPOT_MAX_GLWE=1
fi

read -r POLY K N0 N1 N2 LEVEL BASE_LOG VARIANCE < <(
  CSD_DEEPNN_PBS_HOTSPOT_MAX_POLY="$HOTSPOT_MAX_POLY" \
  CSD_DEEPNN_PBS_HOTSPOT_MAX_GLWE="$HOTSPOT_MAX_GLWE" \
  python3 - "$profile" <<'PY'
import json
import os
import re
import sys

path = sys.argv[1]
obj = json.loads(open(path, "r").read())
records = obj if isinstance(obj, list) else [obj]
rec = records[-1] if records else {}
pbs = (rec or {}).get("pbs", {})
cpp = (pbs or {}).get("count_per_parameter", {}) if isinstance(pbs, dict) else {}
max_poly = int(os.getenv("CSD_DEEPNN_PBS_HOTSPOT_MAX_POLY", "0") or 0)
max_glwe = int(os.getenv("CSD_DEEPNN_PBS_HOTSPOT_MAX_GLWE", "0") or 0)

pat = re.compile(
    r"BootstrapKeyParam\(polynomial_size=([0-9]+),\s*glwe_dimension=([0-9]+),\s*input_lwe_dimension=([0-9]+),\s*level=([0-9]+),\s*base_log=([0-9]+),\s*variance=([0-9eE+\-.]+)\)"
)
best = None
best_all = None
for key, count in cpp.items():
    m = pat.search(str(key))
    if not m:
        continue
    try:
        c = int(count)
    except Exception:
        continue
    poly = int(m.group(1))
    glwe = int(m.group(2))
    n0 = int(m.group(3))
    level = int(m.group(4))
    base_log = int(m.group(5))
    var = m.group(6)
    cand = (c, poly, glwe, n0, level, base_log, var)
    if best_all is None or cand > best_all:
        best_all = cand
    if max_poly > 0 and poly > max_poly:
        continue
    if max_glwe > 0 and glwe > max_glwe:
        continue
    if best is None or cand > best:
        best = cand

if best is None:
    if best_all is None:
        raise SystemExit("[err] no BootstrapKeyParam entries found")
    best = best_all
    warn_bits = []
    if max_poly > 0:
        warn_bits.append(f"max_poly={max_poly}")
    if max_glwe > 0:
        warn_bits.append(f"max_glwe={max_glwe}")
    warn_suffix = " and ".join(warn_bits) if warn_bits else "filters"
    print(f"[warn] no BootstrapKeyParam <= {warn_suffix}, falling back to max candidate", file=sys.stderr)

_, poly, glwe, n0, level, base_log, var = best

# Match csd_gpu_deepnn_concrete_align_oneclick.sh mapping.
n1 = 1024
n2 = 2048
if poly == 1024:
    n1 = 1024
    n2 = 2048
elif poly == 2048:
    n2 = 2048
elif poly == 4096:
    n2 = 4096
else:
    n2 = poly

print(poly, glwe, n0, n1, n2, level, base_log, var)
PY
)

NAME="concrete_poly${POLY}_k${K}_n0${N0}_n2${N2}"
BUILD_DIR="$ROOT/sw/gpu_runtime_service/build-$NAME"
OVERLAY_DIR="$ROOT/sw/gpu_runtime_service/overlays/$NAME"
CPU_OVERLAY_DIR="$ROOT/sw/gpu_runtime_service/overlays_cpu/$NAME"
KEYSET="$ROOT/tmp_assets/wop_keyset_${NAME}.bin"
GPU_SERVICE_BIN="$BUILD_DIR/gpu_runtime_service"
CPU_RUNNER="${CPU_RUNNER:-$BUILD_DIR/cpu_reference_runner}"
WORD_BYTES="${WORD_BYTES:-8}"
CPU_THREADS="${CPU_THREADS:-16}"
BUILD_JOBS="${BUILD_JOBS:-8}"
GEN_KEYSET="${GEN_KEYSET:-1}"
FORCE_REGEN_KEYSET="${FORCE_REGEN_KEYSET:-1}"
ALIGN_BK_PARAMS="${CSD_DEEPNN_ALIGN_BK_PARAMS:-1}"
TFHE_CPU_BASE_ROOT="${TFHE_CPU_BASE_ROOT:-$ROOT/../tfhe-cpu-baseline-wopbs}"
CB_MSG="${CB_MSG:-1}"
GPU_SOCKET="${GPU_SOCKET:-$OUT_DIR/wop_gpu_runtime.sock}"
GPU_TIMEOUT="${GPU_TIMEOUT:-240}"
FORCE_CPU_WOKS="${CSD_DEEPNN_PBS_HOTSPOT_FORCE_CPU_WOKS:-0}"

csd_no_fallback_forbid_env CSD_DEEPNN_PBS_HOTSPOT_FORCE_CPU_WOKS
csd_no_fallback_forbid_env WOP_GPU_FORCE_CPU_WOKS
csd_no_fallback_force_fft

if [ "$FORCE_CPU_WOKS" != "0" ] && [ "$FORCE_CPU_WOKS" != "false" ]; then
  export WOP_GPU_FORCE_CPU_WOKS=1
  export WOP_GPU_CPU_THREADS="${WOP_GPU_CPU_THREADS:-$CPU_THREADS}"
  if [ "$GPU_TIMEOUT" -lt 600 ]; then
    GPU_TIMEOUT=600
  fi
fi

TLWE_WORDS=$((N0 + 1))
GLWE_WORDS=$(((K + 1) * N1))

cfg() { printf '[cfg] %-22s %s\n' "$1" "$2"; }

cfg "profile" "$profile"
cfg "out_dir" "$OUT_DIR"
cfg "variant" "poly=$POLY K=$K n0=$N0 n1=$N1 n2=$N2 level=$LEVEL base_log=$BASE_LOG"
cfg "name" "$NAME"
cfg "tlwe_words" "$TLWE_WORDS"
cfg "glwe_words" "$GLWE_WORDS"
if [ -n "$HOTSPOT_MAX_POLY" ]; then
  cfg "hotspot_max_poly" "$HOTSPOT_MAX_POLY"
fi
if [ -n "$HOTSPOT_MAX_GLWE" ]; then
  cfg "hotspot_max_glwe" "$HOTSPOT_MAX_GLWE"
fi
cfg "keyset" "$KEYSET"
cfg "gpu_service_bin" "$GPU_SERVICE_BIN"
cfg "gpu_socket" "$GPU_SOCKET gpu_timeout=$GPU_TIMEOUT"
cfg "cpu_runner" "$CPU_RUNNER"
cfg "no_fallback" "$CSD_NO_FALLBACK"
if [ "$FORCE_CPU_WOKS" != "0" ] && [ "$FORCE_CPU_WOKS" != "false" ]; then
  cfg "force_cpu_woks" "WOP_GPU_FORCE_CPU_WOKS=1 cpu_threads=${WOP_GPU_CPU_THREADS:-$CPU_THREADS}"
fi
cfg "no_sudo" "$NO_SUDO"
cfg "cpu_overlay" "$CPU_OVERLAY_DIR"
echo

TFHE_GPU_SPQLIOS_FFT="${TFHE_GPU_SPQLIOS_FFT:-1}"
TFHE_GPU_SPQLIOS_IFFT="${TFHE_GPU_SPQLIOS_IFFT:-1}"
TFHE_GPU_SPQLIOS_FFT_TABLE="${TFHE_GPU_SPQLIOS_FFT_TABLE:-/tmp/spqlios_fft_table.n4096.bin}"
TFHE_GPU_SPQLIOS_IFFT_TABLE="${TFHE_GPU_SPQLIOS_IFFT_TABLE:-/tmp/spqlios_ifft_table.n4096.bin}"

if [ "$TFHE_GPU_SPQLIOS_FFT" = "1" ] || [ "$TFHE_GPU_SPQLIOS_IFFT" = "1" ]; then
  if [ ! -f "$TFHE_GPU_SPQLIOS_FFT_TABLE" ] || [ ! -f "$TFHE_GPU_SPQLIOS_IFFT_TABLE" ]; then
    exporter="$ROOT/sw/gpu_runtime_service/build-clean/spqlios_table_exporter"
    if [ -x "$exporter" ]; then
      "$exporter" >/dev/null 2>&1 || true
    fi
  fi
fi

if [ "$FORCE_REGEN_KEYSET" = "1" ] || [ ! -x "$GPU_SERVICE_BIN" ] || [ ! -f "$KEYSET" ]; then
  echo "[1/3] Build TFHE variant $NAME"
  export NAME K N0 N1 N2 BUILD_DIR OUT_OVERLAY_ROOT KEYSET_OUT
  NAME="$NAME"
  K="$K"
  N_LVL0="$N0"
  N_LVL1="$N1"
  N_LVL2="$N2"
  BUILD_DIR="$BUILD_DIR"
  OUT_OVERLAY_ROOT="$OVERLAY_DIR"
  KEYSET_OUT="$KEYSET"
  GEN_KEYSET="$GEN_KEYSET"
  FORCE_REGEN_KEYSET="$FORCE_REGEN_KEYSET"
  BUILD_JOBS="$BUILD_JOBS"
  export N_LVL0 N_LVL1 N_LVL2 GEN_KEYSET FORCE_REGEN_KEYSET BUILD_JOBS
  export TFHE_GPU_SPQLIOS_FFT TFHE_GPU_SPQLIOS_IFFT TFHE_GPU_SPQLIOS_FFT_TABLE TFHE_GPU_SPQLIOS_IFFT_TABLE
  mkdir -p "$CPU_OVERLAY_DIR"
  cpu_overlay_args=(
    --base "$TFHE_CPU_BASE_ROOT"
    --out "$CPU_OVERLAY_DIR"
    --k "$K"
    --n-lvl0 "$N0"
    --n-lvl1 "$N1"
    --n-lvl2 "$N2"
    --force
  )
  if [ "$ALIGN_BK_PARAMS" != "0" ] && [ -n "$LEVEL" ] && [ -n "$BASE_LOG" ]; then
    cpu_overlay_args+=(--ell-lvl2 "$LEVEL" --bgbit-lvl2 "$BASE_LOG")
  fi
  if [ "$ALIGN_BK_PARAMS" != "0" ] && [ -n "$VARIANCE" ] && [ "$VARIANCE" != "0" ]; then
    cpu_overlay_args+=(--bkstdev-lvl2 "$VARIANCE")
  fi
  python3 "$ROOT/tools/tfhe_cpu_overlay_builder.py" "${cpu_overlay_args[@]}"
  export TFHE_CPU_ROOT="$CPU_OVERLAY_DIR"
  if [ "$ALIGN_BK_PARAMS" != "0" ] && [ -n "$LEVEL" ] && [ -n "$BASE_LOG" ]; then
    export ELL_LVL2="$LEVEL"
    export BGBIT_LVL2="$BASE_LOG"
  fi
  if [ "$ALIGN_BK_PARAMS" != "0" ] && [ -n "$VARIANCE" ] && [ "$VARIANCE" != "0" ]; then
    export BKSTDEV_LVL2="$VARIANCE"
  fi
  bash "$ROOT/scripts/csd_gpu_build_tfhe_variant.sh"
  echo
fi

if [ ! -x "$CPU_RUNNER" ]; then
  CPU_RUNNER="$ROOT/sw/gpu_runtime_service/build-clean/cpu_reference_runner"
fi
if [ ! -x "$CPU_RUNNER" ]; then
  echo "[err] cpu_reference_runner missing: $CPU_RUNNER" >&2
  exit 1
fi

echo "[2/3] Generate TLWE input + golden (cpu_reference_runner)"
TLWE_BIN="$OUT_DIR/tlwe.bin"
GOLDEN_BIN="$OUT_DIR/golden.bin"
"$CPU_RUNNER" \
  --keyset "$KEYSET" \
  --tlwe "$TLWE_BIN" \
  --glwe "$GOLDEN_BIN" \
  --tlwe-words "$TLWE_WORDS" \
  --glwe-words "$GLWE_WORDS" \
  --word-bytes "$WORD_BYTES" \
  --mode 2 \
  --threads "$CPU_THREADS" \
  --synth-lvl0 "$CB_MSG"
echo

echo "[3/3] Run nvmevirt e2e (CB mode=2)"
OUT_GLWE="$OUT_DIR/out_glwe.bin"
BACKEND_LOG="$OUT_DIR/backend.log"
DMESG_OUT="$OUT_DIR/dmesg_new.log"
GPU_SERVICE_LOG="$OUT_DIR/gpu_runtime_service.log"
if [ "$NO_SUDO" = "1" ]; then
  echo "[3/3] Run user-mode IPC (NO_SUDO=1)"

  if [ ! -x "$GPU_SERVICE_BIN" ]; then
    echo "[err] gpu_runtime_service missing/executable: $GPU_SERVICE_BIN" >&2
    exit 1
  fi

  export WOP_GPU_KEY_IMPORT="$KEYSET"
  export WOP_GPU_KEY_EXPORT="$KEYSET"
  export TFHE_GPU_SPQLIOS_FFT="${TFHE_GPU_SPQLIOS_FFT:-1}"
  export TFHE_GPU_SPQLIOS_IFFT="${TFHE_GPU_SPQLIOS_IFFT:-1}"
  export TFHE_GPU_SPQLIOS_FFT_TABLE="${TFHE_GPU_SPQLIOS_FFT_TABLE:-/tmp/spqlios_fft_table.n4096.bin}"
  export TFHE_GPU_SPQLIOS_IFFT_TABLE="${TFHE_GPU_SPQLIOS_IFFT_TABLE:-/tmp/spqlios_ifft_table.n4096.bin}"

  rm -f "$GPU_SOCKET" >/dev/null 2>&1 || true
  pkill -9 -f "[g]pu_runtime_service.*${GPU_SOCKET}" >/dev/null 2>&1 || true
  "$GPU_SERVICE_BIN" "$GPU_SOCKET" >"$GPU_SERVICE_LOG" 2>&1 &
  GPU_SERVICE_PID=$!

  for _ in $(seq 1 60); do
    if [ -S "$GPU_SOCKET" ]; then
      break
    fi
    sleep 1
  done
  if [ ! -S "$GPU_SOCKET" ]; then
    echo "[err] gpu_runtime_service socket not ready: $GPU_SOCKET" >&2
    tail -n 120 "$GPU_SERVICE_LOG" || true
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
  TLWE_BIN="$TLWE_BIN" OUT_GLWE="$OUT_GLWE" GOLDEN_BIN="$GOLDEN_BIN" \
  TLWE_WORDS="$TLWE_WORDS" GLWE_WORDS="$GLWE_WORDS" WORD_BYTES="$WORD_BYTES" \
  python3 - <<'PY' >"$OUT_DIR/ipc.log" 2>&1
import os
from csd_gpu_ipc import Descriptor, run_gpu_service

sock = os.environ["GPU_SOCKET"]
timeout_s = float(os.environ.get("GPU_TIMEOUT", "120"))
tlwe_bin = os.environ["TLWE_BIN"]
out_glwe = os.environ["OUT_GLWE"]
golden_bin = os.environ["GOLDEN_BIN"]
tlwe_words = int(os.environ["TLWE_WORDS"])
glwe_words = int(os.environ["GLWE_WORDS"])
word_bytes = int(os.environ["WORD_BYTES"])

with open(tlwe_bin, "rb") as f:
    tlwe_payload = f.read()

desc = Descriptor(
    cmd_id=0,
    mode=2,
    flags=0,
    tlwe_words=tlwe_words,
    glwe_words=glwe_words,
)
res = run_gpu_service(
    socket_path=sock,
    desc=desc,
    tlwe_data=tlwe_payload,
    tlwe_word_bytes=word_bytes,
    glwe_word_bytes=word_bytes,
    timeout_s=timeout_s,
)

with open(out_glwe, "wb") as f:
    f.write(res.payload)

with open(golden_bin, "rb") as f:
    golden = f.read()

match = res.payload == golden
print(f"[ipc] resp_glwe_bytes={res.resp_glwe_bytes} latency_ns={res.latency_ns} match={int(match)}")
if match:
    print("[PASS] GLWE matches golden")
else:
    mismatches = sum(1 for a, b in zip(res.payload, golden) if a != b)
    print(f"[FAIL] GLWE mismatch bytes={mismatches}")
    raise SystemExit(2)
PY
  cat "$OUT_DIR/ipc.log"
else
  ENGINE=gpu MODE=2 FLAGS=0 \
  TLWE_WORDS="$TLWE_WORDS" GLWE_WORDS="$GLWE_WORDS" \
  TLWE_FILE="$TLWE_BIN" OUT_GLWE="$OUT_GLWE" GOLDEN="$GOLDEN_BIN" \
  KEYSET="$KEYSET" GPU_SERVICE_BIN="$GPU_SERVICE_BIN" \
  NO_SUDO="$NO_SUDO" CSD_USE_PRP="${CSD_USE_PRP:-0}" \
  GPU_WOKS_NATIVE="${GPU_WOKS_NATIVE:-1}" \
  TFHE_GPU_SPQLIOS_FFT="${TFHE_GPU_SPQLIOS_FFT:-1}" \
  TFHE_GPU_SPQLIOS_IFFT="${TFHE_GPU_SPQLIOS_IFFT:-1}" \
  TFHE_GPU_SPQLIOS_FFT_TABLE="${TFHE_GPU_SPQLIOS_FFT_TABLE:-/tmp/spqlios_fft_table.n4096.bin}" \
  TFHE_GPU_SPQLIOS_IFFT_TABLE="${TFHE_GPU_SPQLIOS_IFFT_TABLE:-/tmp/spqlios_ifft_table.n4096.bin}" \
  BACKEND_LOG="$BACKEND_LOG" DMESG_OUT="$DMESG_OUT" GPU_SERVICE_LOG="$GPU_SERVICE_LOG" \
    bash "$E2E_SH" 2>&1 | tee "$OUT_DIR/e2e.log"
fi

echo
echo "[ok] deep-nn PBS hotspot e2e done: $OUT_DIR"
echo "[hint] rg -n \"GLWE matches golden|CSD: op=0xc0|metrics cmd=\" \"$OUT_DIR\"/e2e.log \"$OUT_DIR\"/backend.log \"$OUT_DIR\"/dmesg_new.log"
