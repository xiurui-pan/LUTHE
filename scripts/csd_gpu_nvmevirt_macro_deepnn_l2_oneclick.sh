#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSD_NO_FALLBACK="${CSD_NO_FALLBACK:-0}"
# shellcheck source=/dev/null
source "$ROOT/scripts/csd_no_fallback.sh"

usage() {
  cat <<'EOF' >&2
usage:
  NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_macro_deepnn_l2_oneclick.sh \
    [--profile <deepnn_profile.json> | --out-dir <macro OUT_DIR>] [--out-parent <dir>] [--] [<deep-nn-command...>]

notes:
  - Runs M4 (multi-variant alignment), M5 (nvmevirt FHE execution), and M6 (ipc vs nvmevirt compare).
  - If profile is not provided, a short profile-only run will be executed first.
  - Requires an active sudo ticket (run "sudo -v" before invoking).
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

no_sudo="${NO_SUDO:-0}"
if [ "$no_sudo" != "0" ]; then
  echo "[err] L2 oneclick requires NO_SUDO=0" >&2
  exit 2
fi
if csd_no_fallback_enabled; then
  csd_no_fallback_err "macro_deepnn_l2 uses NO_SUDO=1 prep steps (profile/align)"
fi

profile=""
out_dir=""
out_parent=""
deep_nn_cmd=()

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
    --out-parent)
      out_parent="$2"
      shift 2
      ;;
    --)
      shift
      deep_nn_cmd=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      deep_nn_cmd+=("$1")
      shift
      ;;
  esac
done

if [ -n "$out_dir" ] && [ -z "$profile" ]; then
  profile="$out_dir/deepnn_profile.json"
fi

run_id="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
if [ -z "$out_parent" ]; then
  out_parent="/tmp/csd_gpu_nvmevirt_macro_deepnn_l2_${run_id}"
fi
mkdir -p "$out_parent"

log_file="${LOG_FILE:-$out_parent/driver.log}"
exec >"$log_file" 2>&1

echo "[cfg] out_parent   $out_parent"
echo "[cfg] log_file     $log_file"
echo "[cfg] no_sudo      $no_sudo"
echo "[cfg] no_fallback  $CSD_NO_FALLBACK"
echo

if ! sudo -n true >/dev/null 2>&1; then
  echo "[err] sudo ticket missing (run: sudo -v)" >&2
  exit 2
fi

profile_dir="$out_parent/m0_profile"
m4_dir="$out_parent/m4_align"
run_dir="$out_parent/m5_m6_run"
mkdir -p "$profile_dir" "$m4_dir" "$run_dir"

if [ -z "$profile" ] || [ ! -f "$profile" ]; then
  echo "[m0] generate deepnn_profile.json"
  if [ "${#deep_nn_cmd[@]}" -gt 0 ]; then
    NO_SUDO=1 OUT_DIR="$profile_dir" \
      CSD_DEEPNN_PROFILE=1 CSD_DEEPNN_FHE_NVMEVIRT=0 CSD_DEEPNN_OFFLOAD_SOFTMAX=0 \
      bash "$ROOT/scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh" -- "${deep_nn_cmd[@]}"
  else
    NO_SUDO=1 OUT_DIR="$profile_dir" \
      CSD_DEEPNN_PROFILE=1 CSD_DEEPNN_FHE_NVMEVIRT=0 CSD_DEEPNN_OFFLOAD_SOFTMAX=0 \
      bash "$ROOT/scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh"
  fi
  profile="$profile_dir/deepnn_profile.json"
fi

if [ ! -f "$profile" ]; then
  echo "[err] missing deepnn_profile.json: $profile" >&2
  exit 2
fi

echo "[m4] align variants + keysets"
NO_SUDO=1 OUT_PARENT="$m4_dir" \
  CSD_DEEPNN_CONCRETE_ALIGN_ENABLE_4096="${CSD_DEEPNN_CONCRETE_ALIGN_ENABLE_4096:-1}" \
  CSD_DEEPNN_CONCRETE_ALIGN_FORCE_MATRIX="${CSD_DEEPNN_CONCRETE_ALIGN_FORCE_MATRIX:-1}" \
  CSD_DEEPNN_ALIGN_BK_PARAMS="${CSD_DEEPNN_ALIGN_BK_PARAMS:-0}" \
  GEN_KEYSET="${GEN_KEYSET:-1}" \
  bash "$ROOT/scripts/csd_gpu_deepnn_concrete_align_oneclick.sh" --profile "$profile"

variants_json="$m4_dir/variants.json"
if [ ! -f "$variants_json" ]; then
  echo "[err] missing variants.json: $variants_json" >&2
  exit 2
fi

glwe_max="$(python3 - "$variants_json" <<'PY'
import json
import sys

vars = json.load(open(sys.argv[1]))
ks = [int(v.get("K", 0) or 0) for v in vars if isinstance(v, dict)]
print(max(ks) if ks else 0)
PY
)"
if [ "${glwe_max:-0}" -gt 1 ]; then
  export CSD_DEEPNN_ALLOW_GLWE_GT1=1
  echo "[cfg] allow_glwe_gt1 1 (variants include K>1)"
fi

variant_name="$(python3 - "$profile" "$variants_json" <<'PY'
import json
import re
import sys
from pathlib import Path

profile_path = Path(sys.argv[1])
variants_path = Path(sys.argv[2])

obj = json.loads(profile_path.read_text())
rec = obj[-1] if isinstance(obj, list) else obj
pbs = (rec.get("pbs") or {}).get("count_per_parameter") or {}

pat = re.compile(r"BootstrapKeyParam\(polynomial_size=([0-9]+),\s*glwe_dimension=([0-9]+),\s*input_lwe_dimension=([0-9]+),")
params = []
for k, v in pbs.items():
    m = pat.search(str(k))
    if not m:
        continue
    try:
        count = int(v)
    except Exception:
        continue
    poly = int(m.group(1))
    glwe = int(m.group(2))
    n0 = int(m.group(3))
    params.append((count, poly, glwe, n0))

if not params:
    raise SystemExit("[err] no BootstrapKeyParam entries found in profile")

def pick(cands):
    cands = sorted(cands, key=lambda x: (-x[0], x[1], x[2], x[3]))
    return cands[0]

params_k1 = [p for p in params if p[2] == 1]
chosen = pick(params_k1) if params_k1 else pick(params)
count, poly, glwe, n0 = chosen

variants = json.loads(variants_path.read_text())
match = None
for v in variants:
    try:
        v_poly = int(v.get("poly", 0) or 0)
        v_k = int(v.get("K", 0) or 0)
        v_n0 = int(v.get("n_lvl0", 0) or 0)
    except Exception:
        continue
    if v_poly == poly and v_k == glwe and v_n0 == n0:
        match = v
        break

if match is None:
    raise SystemExit(f"[err] no variant matches poly={poly} K={glwe} n0={n0}")

n2 = int(match.get("n_lvl2", 0) or 0)
name = f"concrete_poly{poly}_k{glwe}_n0{n0}_n2{n2}"
print(name)
print(f"[cfg] variant_selected count={count} poly={poly} K={glwe} n0={n0} n2={n2}", file=sys.stderr)
PY
)"

build_dir="$ROOT/sw/gpu_runtime_service/build-$variant_name"
keyset="$ROOT/tmp_assets/wop_keyset_${variant_name}.bin"

if [ ! -x "$build_dir/gpu_runtime_service" ]; then
  echo "[err] missing gpu_runtime_service: $build_dir/gpu_runtime_service" >&2
  exit 2
fi
if [ ! -f "$keyset" ]; then
  echo "[err] missing keyset: $keyset" >&2
  exit 2
fi

backend_variants="$out_parent/backend_variants.json"
python3 "$ROOT/tools/csd_deepnn_variants_backend.py" \
  --variants-json "$variants_json" \
  --out "$backend_variants"
func_variant_id="$(python3 - "$backend_variants" "$variant_name" <<'PY'
import json
import sys

vars = json.load(open(sys.argv[1]))
name = sys.argv[2]
for v in vars:
    if v.get("name") == name:
        print(v.get("id", 0))
        break
else:
    raise SystemExit(f"[err] variant not found: {name}")
PY
)"

echo "[m5/m6] run deep-nn FHE via nvmevirt"
if [ "${#deep_nn_cmd[@]}" -gt 0 ]; then
  NO_SUDO=0 OUT_DIR="$run_dir" \
    CSD_PIPELINE_TRACE="${CSD_PIPELINE_TRACE:-1}" \
    CSD_PIPELINE_TRACE_OUT="${CSD_PIPELINE_TRACE_OUT:-$run_dir/pipeline_trace.log}" \
    GPU_SERVICE_BIN="$build_dir/gpu_runtime_service" \
    KEYSET="$keyset" \
    CSD_DEEPNN_VARIANTS_JSON="$variants_json" \
    CSD_VARIANTS_JSON="$backend_variants" \
    CSD_FUNC_VARIANT_ID="$func_variant_id" \
    WOP_GPU_VARIANT_NAME="$variant_name" \
    WOP_GPU_VARIANT_ID="$func_variant_id" \
    CSD_DEEPNN_FHE_NVMEVIRT=1 \
    CSD_DEEPNN_FHE_BACKEND=nvmevirt \
    CSD_DEEPNN_FHE_MARK_L2=1 \
    CSD_DEEPNN_FHE_SEPARATE_LOGS=1 \
    CSD_DEEPNN_CONCRETE_META=1 \
    CSD_DEEPNN_FHE_COMPARE_BACKENDS=1 \
    CSD_DEEPNN_FHE_COMPARE_STRICT="${CSD_DEEPNN_FHE_COMPARE_STRICT:-1}" \
    CSD_DEEPNN_FHE_COMPARE_MAX_MAE="${CSD_DEEPNN_FHE_COMPARE_MAX_MAE:-0}" \
    CSD_DEEPNN_FHE_COMPARE_MIN_ARGMAX="${CSD_DEEPNN_FHE_COMPARE_MIN_ARGMAX:-1}" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh" -- "${deep_nn_cmd[@]}"
else
  NO_SUDO=0 OUT_DIR="$run_dir" \
    CSD_PIPELINE_TRACE="${CSD_PIPELINE_TRACE:-1}" \
    CSD_PIPELINE_TRACE_OUT="${CSD_PIPELINE_TRACE_OUT:-$run_dir/pipeline_trace.log}" \
    GPU_SERVICE_BIN="$build_dir/gpu_runtime_service" \
    KEYSET="$keyset" \
    CSD_DEEPNN_VARIANTS_JSON="$variants_json" \
    CSD_VARIANTS_JSON="$backend_variants" \
    CSD_FUNC_VARIANT_ID="$func_variant_id" \
    WOP_GPU_VARIANT_NAME="$variant_name" \
    WOP_GPU_VARIANT_ID="$func_variant_id" \
    CSD_DEEPNN_FHE_NVMEVIRT=1 \
    CSD_DEEPNN_FHE_BACKEND=nvmevirt \
    CSD_DEEPNN_FHE_MARK_L2=1 \
    CSD_DEEPNN_FHE_SEPARATE_LOGS=1 \
    CSD_DEEPNN_CONCRETE_META=1 \
    CSD_DEEPNN_FHE_COMPARE_BACKENDS=1 \
    CSD_DEEPNN_FHE_COMPARE_STRICT="${CSD_DEEPNN_FHE_COMPARE_STRICT:-1}" \
    CSD_DEEPNN_FHE_COMPARE_MAX_MAE="${CSD_DEEPNN_FHE_COMPARE_MAX_MAE:-0}" \
    CSD_DEEPNN_FHE_COMPARE_MIN_ARGMAX="${CSD_DEEPNN_FHE_COMPARE_MIN_ARGMAX:-1}" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh"
fi

if [ -f "$run_dir/pipeline_trace.log" ]; then
  python3 "$ROOT/tools/pipeline_overlap_analyzer.py" --out "$run_dir" "$run_dir/pipeline_trace.log" || true
fi

echo "[m5/m6] evidence"
rg -n "\\[CSD_DEEPNN\\]\\[L2\\]" "$run_dir/run.log"
rg -n "fhe compare ok" "$run_dir/run.log"
if [ -f "$run_dir/dmesg_fhe.log" ]; then
  rg -n "CSD: op=0xc0" "$run_dir/dmesg_fhe.log"
else
  rg -n "CSD: op=0xc0" "$run_dir/dmesg_new.log"
fi
if [ -f "$run_dir/backend_fhe.log" ]; then
  rg -n "metrics cmd=" "$run_dir/backend_fhe.log"
else
  rg -n "metrics cmd=" "$run_dir/backend.log"
fi
rg -n "fully_compatible\\s+True" "$run_dir/deepnn_run_summary.txt" || true
if [ -f "$run_dir/deepnn_run_summary.txt" ]; then
  rg -n "^concrete_contract:|^contract_recommend_|^  max_input_lwe|^  max_output_lwe|^  require_n_lvl0|^  require_allowed_lwe|^  variant_ok|^  variant_mismatches|^  assumptions" \
    "$run_dir/deepnn_run_summary.txt" || true
fi
if [ -f "$run_dir/deepnn_fhe_contract.json" ]; then
  contract_strict="${CSD_DEEPNN_CONTRACT_STRICT:-1}"
  python3 - "$run_dir/deepnn_fhe_contract.json" "$contract_strict" <<'PY'
import json
import sys

path = sys.argv[1]
strict = sys.argv[2] not in ("0", "", "false", "False")
contract = json.loads(open(path, "r").read())

allowed = [int(x) for x in (contract.get("variant_allowed_lwe_dimensions") or []) if int(x) > 0]
inputs = [int(x) for x in (contract.get("input_lwe_dimensions") or []) if int(x) > 0]
outputs = [int(x) for x in (contract.get("output_lwe_dimensions") or []) if int(x) > 0]

missing_in = [x for x in inputs if x not in allowed] if allowed else inputs
missing_out = [x for x in outputs if x not in allowed] if allowed else outputs
variant_ok = contract.get("variant_meets_requirements")

ok = (variant_ok is True) and not missing_in and not missing_out
status = "ok" if ok else "mismatch"
print(f"[contract] status={status} variant_ok={variant_ok} missing_in={missing_in} missing_out={missing_out}")

if strict and not ok:
    raise SystemExit("[err] contract alignment failed")
PY
fi
echo

echo "[ok] L2 oneclick done."
echo "[ok] out_parent: $out_parent"
echo "[ok] run_dir:    $run_dir"
