#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSD_NO_FALLBACK="${CSD_NO_FALLBACK:-0}"
# shellcheck source=/dev/null
source "$ROOT/scripts/csd_no_fallback.sh"

usage() {
  cat <<'EOF' >&2
usage:
  NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_macro_deepnn_multivariant_oneclick.sh --profile <deepnn_profile.json> [--] [<deep-nn-command...>]
  NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_macro_deepnn_multivariant_oneclick.sh --profile <deepnn_profile.json> [--] [<deep-nn-command...>]
  NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_macro_deepnn_multivariant_oneclick.sh --out-dir <macro OUT_DIR> [--] [<deep-nn-command...>]
  NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_macro_deepnn_multivariant_oneclick.sh --out-dir <macro OUT_DIR> [--] [<deep-nn-command...>]

notes:
  - Builds per-parameter TFHE variants (incl. K=2) from the profile and generates keysets.
  - Picks the dominant K=1 BootstrapKeyParam (if any) as the runtime variant for softmax offload.
  - Force a fixed variant matrix via CSD_DEEPNN_CONCRETE_ALIGN_FORCE_MATRIX=1 (optional).
  - Writes all stdout/stderr to LOG_FILE (default: <out-parent>/driver.log).
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

no_sudo="${NO_SUDO:-1}"
if csd_no_fallback_enabled; then
  csd_no_fallback_err "macro_deepnn_multivariant uses NO_SUDO=1 align step"
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
if [ -z "$profile" ]; then
  echo "[err] missing --profile or --out-dir" >&2
  usage
  exit 2
fi
if [ ! -f "$profile" ]; then
  echo "[err] missing deepnn_profile.json: $profile" >&2
  exit 2
fi

run_id="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
if [ -z "$out_parent" ]; then
  out_parent="/tmp/csd_gpu_nvmevirt_macro_deepnn_multivariant_${run_id}"
fi
mkdir -p "$out_parent"

log_file="${LOG_FILE:-$out_parent/driver.log}"
exec >"$log_file" 2>&1

echo "[cfg] profile             $profile"
echo "[cfg] out_parent          $out_parent"
echo "[cfg] log_file            $log_file"
echo "[cfg] no_sudo             $no_sudo"
echo "[cfg] no_fallback         $CSD_NO_FALLBACK"
echo

align_out="$out_parent/align"
align_log="$out_parent/align.log"
mkdir -p "$align_out"

align_enable_4096="${CSD_DEEPNN_CONCRETE_ALIGN_ENABLE_4096:-1}"
gen_keyset="${GEN_KEYSET:-1}"

echo "[run] build variants (align_out=$align_out log=$align_log)"
NO_SUDO=1 \
  CSD_DEEPNN_CONCRETE_ALIGN_ENABLE_4096="$align_enable_4096" \
  CSD_DEEPNN_CONCRETE_ALIGN_FORCE_MATRIX="${CSD_DEEPNN_CONCRETE_ALIGN_FORCE_MATRIX:-1}" \
  GEN_KEYSET="$gen_keyset" \
  OUT_PARENT="$align_out" \
  bash "$ROOT/scripts/csd_gpu_deepnn_concrete_align_oneclick.sh" --profile "$profile" \
  >"$align_log" 2>&1

variants_json="$align_out/variants.json"
if [ ! -f "$variants_json" ]; then
  echo "[err] missing variants.json: $variants_json" >&2
  exit 2
fi

variants_json_run="$variants_json"
variants_json_k1="$align_out/variants_k1.json"
python3 - "$variants_json" "$variants_json_k1" <<'PY'
import json
import sys

src = sys.argv[1]
dst = sys.argv[2]
vars = json.load(open(src))
k1 = [v for v in vars if int(v.get("K", 0) or 0) == 1]
if k1:
    json.dump(k1, open(dst, "w"), indent=2, sort_keys=True)
PY
if [ -s "$variants_json_k1" ]; then
  variants_json_run="$variants_json_k1"
  echo "[cfg] variants_json_k1    $variants_json_k1"
else
  echo "[warn] variants_k1.json empty; using full variants.json" >&2
fi

variant_name="$(python3 - "$profile" "$variants_json_run" <<'PY'
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

echo "[cfg] variant_name        $variant_name"
echo "[cfg] gpu_service_bin     $build_dir/gpu_runtime_service"
echo "[cfg] keyset              $keyset"
echo "[cfg] variants_json       $variants_json_run"
backend_variants="$out_parent/backend_variants.json"
python3 "$ROOT/tools/csd_deepnn_variants_backend.py" \
  --variants-json "$variants_json_run" \
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
echo "[cfg] backend_variants    $backend_variants"
echo "[cfg] func_variant_id     $func_variant_id"
echo

run_dir="$out_parent/run"
mkdir -p "$run_dir"

if [ "$no_sudo" = "1" ] && [ -z "${CSD_VARIANTS_ALLOW_IDS:-}" ]; then
  ids="$func_variant_id"
  if [ -n "${CSD_SOFTMAX_VARIANT_ID:-}" ] && [ "$CSD_SOFTMAX_VARIANT_ID" != "$func_variant_id" ]; then
    ids="$ids,$CSD_SOFTMAX_VARIANT_ID"
  fi
  export CSD_VARIANTS_ALLOW_IDS="$ids"
  echo "[cfg] csd_variants_allow_ids $CSD_VARIANTS_ALLOW_IDS"
fi

flash_variants="${CSD_KEYSET_FLASH_VARIANTS:-}"
if [ "${CSD_KEYSET_IN_FLASH:-0}" = "1" ] && [ -z "$flash_variants" ]; then
  flash_variants="$func_variant_id"
  echo "[cfg] csd_keyset_flash_variants $flash_variants"
fi
if [ -n "$flash_variants" ]; then
  export CSD_KEYSET_FLASH_VARIANTS="$flash_variants"
else
  unset CSD_KEYSET_FLASH_VARIANTS || true
fi

if [ "${#deep_nn_cmd[@]}" -gt 0 ]; then
  NO_SUDO="$no_sudo" OUT_DIR="$run_dir" \
    GPU_SERVICE_BIN="$build_dir/gpu_runtime_service" \
    KEYSET="$keyset" \
    CSD_DEEPNN_VARIANTS_JSON="$variants_json_run" \
    CSD_VARIANTS_JSON="$backend_variants" \
    CSD_FUNC_VARIANT_ID="$func_variant_id" \
    WOP_GPU_VARIANT_NAME="$variant_name" \
    WOP_GPU_VARIANT_ID="$func_variant_id" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh" -- "${deep_nn_cmd[@]}"
else
  NO_SUDO="$no_sudo" OUT_DIR="$run_dir" \
    GPU_SERVICE_BIN="$build_dir/gpu_runtime_service" \
    KEYSET="$keyset" \
    CSD_DEEPNN_VARIANTS_JSON="$variants_json_run" \
    CSD_VARIANTS_JSON="$backend_variants" \
    CSD_FUNC_VARIANT_ID="$func_variant_id" \
    WOP_GPU_VARIANT_NAME="$variant_name" \
    WOP_GPU_VARIANT_ID="$func_variant_id" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh"
fi

echo
echo "[ok] multivariant macro deep-nn done."
echo "[ok] out_parent: $out_parent"
echo "[ok] run_dir:    $run_dir"
echo "[ok] log_file:   $log_file"
