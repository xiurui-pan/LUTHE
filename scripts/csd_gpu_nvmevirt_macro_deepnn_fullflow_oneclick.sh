#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSD_NO_FALLBACK="${CSD_NO_FALLBACK:-0}"
# shellcheck source=/dev/null
source "$ROOT/scripts/csd_no_fallback.sh"

usage() {
  cat <<'EOF' >&2
usage:
  NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_macro_deepnn_fullflow_oneclick.sh \
    [--out-parent <dir>] [--] [<deep-nn-command...>]

notes:
  - Runs M0 (FHE nvmevirt by default), M2 (PBS hotspot), and M3 (sweep).
  - Set RUN_FHE_NVMEVIRT=0 to skip FHE nvmevirt in M0.
  - Set RUN_HOTSPOT=0 to skip M2; set RUN_SWEEP=0 to skip M3.
  - Set RUN_MULTIVARIANT=1 to build variants/keysets before M0 and pass variants JSON.
  - Set CSD_DEEPNN_CONTRACT_STRICT=1 to require deepnn_fhe_contract.json to pass after M0.
  - Artifacts are placed under <out-parent>/{m0_nvmevirt,m2_pbs_hotspot,m3_sweep}/.
  - All stdout/stderr are redirected to LOG_FILE (default: <out-parent>/driver.log).
  - Requires an active sudo ticket (run "sudo -v" before invoking).
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

repeats="${REPEATS:-5}"
run_sweep="${RUN_SWEEP:-1}"
run_hotspot="${RUN_HOTSPOT:-1}"
run_fhe_nvmevirt="${RUN_FHE_NVMEVIRT:-1}"
run_dump_raw="${RUN_DUMP_RAW:-0}"
run_multivariant="${RUN_MULTIVARIANT:-0}"
contract_strict="${CSD_DEEPNN_CONTRACT_STRICT:-0}"
profile_path="${CSD_DEEPNN_PROFILE_PATH:-}"
out_parent="${OUT_PARENT:-}"
deep_nn_cmd=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-parent)
      shift
      out_parent="${1:-}"
      ;;
    --)
      shift
      deep_nn_cmd=("$@")
      break
      ;;
    *)
      deep_nn_cmd+=("$1")
      ;;
  esac
  shift || true
done

if [ -z "$out_parent" ]; then
  run_id="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
  out_parent="/tmp/csd_gpu_nvmevirt_macro_deepnn_fullflow_${run_id}"
fi

m0_dir="$out_parent/m0_nvmevirt"
m2_dir="$out_parent/m2_pbs_hotspot"
m3_parent="$out_parent/m3_sweep"
mkdir -p "$m0_dir" "$m2_dir" "$m3_parent"

log_file="${LOG_FILE:-$out_parent/driver.log}"
exec >"$log_file" 2>&1

echo "[cfg] out_parent            $out_parent"
echo "[cfg] m0_out                $m0_dir"
echo "[cfg] m2_out                $m2_dir"
echo "[cfg] m3_sweep_out_parent   $m3_parent"
echo "[cfg] repeats              $repeats"
echo "[cfg] run_sweep            $run_sweep"
echo "[cfg] run_hotspot          $run_hotspot"
echo "[cfg] run_fhe_nvmevirt     $run_fhe_nvmevirt"
echo "[cfg] run_dump_raw         $run_dump_raw"
echo "[cfg] run_multivariant     $run_multivariant"
echo "[cfg] contract_strict      $contract_strict"
echo "[cfg] no_fallback          $CSD_NO_FALLBACK"
if [ -n "$profile_path" ]; then
  echo "[cfg] profile_path         $profile_path"
fi
echo

if ! sudo -n true >/dev/null 2>&1; then
  echo "[err] sudo ticket missing (run: sudo -v)" >&2
  exit 2
fi

if csd_no_fallback_enabled && [ "$run_multivariant" != "0" ]; then
  csd_no_fallback_err "RUN_MULTIVARIANT=$run_multivariant (requires NO_SUDO=1 prep steps)"
fi

variant_env=()
if [ "$run_multivariant" != "0" ]; then
  profile="$profile_path"
  profile_dir="$out_parent/m0_profile"
  align_dir="$out_parent/m4_align"
  mkdir -p "$profile_dir" "$align_dir"

  if [ -z "$profile" ] || [ ! -f "$profile" ]; then
    echo "[m4] generate deepnn_profile.json"
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
  NO_SUDO=1 OUT_PARENT="$align_dir" \
    CSD_DEEPNN_CONCRETE_ALIGN_ENABLE_4096="${CSD_DEEPNN_CONCRETE_ALIGN_ENABLE_4096:-1}" \
    CSD_DEEPNN_CONCRETE_ALIGN_FORCE_MATRIX="${CSD_DEEPNN_CONCRETE_ALIGN_FORCE_MATRIX:-1}" \
    CSD_DEEPNN_ALIGN_BK_PARAMS="${CSD_DEEPNN_ALIGN_BK_PARAMS:-0}" \
    GEN_KEYSET="${GEN_KEYSET:-1}" \
    bash "$ROOT/scripts/csd_gpu_deepnn_concrete_align_oneclick.sh" --profile "$profile"

  variants_json="$align_dir/variants.json"
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
    variant_env+=(CSD_DEEPNN_ALLOW_GLWE_GT1=1)
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
    --out "$backend_variants" \
    --softmax-keyset "$ROOT/tmp_assets/wop_keyset.bin" \
    --softmax-name "softmax_default" \
    --softmax-gpu-bin "$ROOT/sw/gpu_runtime_service/build-clean/gpu_runtime_service" \
    --softmax-cpu-runner "$ROOT/sw/gpu_runtime_service/build-clean/cpu_reference_runner"
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
  softmax_variant_id="$(python3 - "$backend_variants" "softmax_default" <<'PY'
import json
import sys
vars = json.load(open(sys.argv[1]))
name = sys.argv[2]
for v in vars:
    if v.get("name") == name:
        print(v.get("id", 0))
        break
else:
    raise SystemExit(f"[err] softmax variant not found: {name}")
PY
)"

  variant_env+=(
    "CSD_DEEPNN_VARIANTS_JSON=$variants_json"
    "CSD_VARIANTS_JSON=$backend_variants"
    "CSD_FUNC_VARIANT_ID=$func_variant_id"
    "CSD_SOFTMAX_VARIANT_ID=$softmax_variant_id"
    "WOP_GPU_VARIANT_NAME=$variant_name"
    "WOP_GPU_VARIANT_ID=$func_variant_id"
    "GPU_SERVICE_BIN=$build_dir/gpu_runtime_service"
    "KEYSET=$keyset"
  )
fi

m0_env=()
if [ "$run_fhe_nvmevirt" != "0" ]; then
  m0_env+=(CSD_DEEPNN_FHE_NVMEVIRT=1)
  if [ "$run_dump_raw" != "0" ]; then
    m0_env+=(
      CSD_DEEPNN_CONCRETE_DUMP_RAW=1
      CSD_DEEPNN_FHE_UNCOMPRESSED=1
      CSD_DEEPNN_ALLOW_BIG_PAYLOAD=1
      CSD_DEEPNN_FHE_KEEP_IO=1
    )
  fi
fi
if [ "$contract_strict" != "0" ]; then
  m0_env+=(CSD_DEEPNN_CONCRETE_META=1)
fi
if [ "${#variant_env[@]}" -gt 0 ]; then
  m0_env+=("${variant_env[@]}")
fi

echo "[m0] nvmevirt e2e (single)"
if [ "${#deep_nn_cmd[@]}" -gt 0 ]; then
  env "${m0_env[@]}" NO_SUDO=0 OUT_DIR="$m0_dir" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh" -- "${deep_nn_cmd[@]}"
else
  env "${m0_env[@]}" NO_SUDO=0 OUT_DIR="$m0_dir" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh"
fi
echo

echo "[m0] evidence"
rg -n "fhe offload ok: backend=nvmevirt" "$m0_dir/run.log" || true
rg -n "metrics cmd=" "$m0_dir/backend.log" || true
rg -n "CSD: op=0xc0" "$m0_dir/dmesg_new.log" || true
ls -1 "$m0_dir" 2>/dev/null | rg -n "concrete_raw_" || true
if [ "$run_dump_raw" != "0" ]; then
  echo "[m0] raw dump check"
  bash "$ROOT/scripts/csd_gpu_nvmevirt_deepnn_raw_dump_check.sh" --out-dir "$m0_dir"
fi
if [ "$contract_strict" != "0" ]; then
  contract_path="$m0_dir/deepnn_fhe_contract.json"
  if [ ! -f "$contract_path" ]; then
    echo "[err] contract strict enabled but missing $contract_path" >&2
    exit 2
  fi
  python3 - "$contract_path" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path))
ok = data.get("variant_meets_requirements") is True
mismatches = data.get("variant_mismatches") or []
if not ok or mismatches:
    raise SystemExit(f"[err] contract strict failed: ok={ok} mismatches={mismatches}")
print("[contract] strict ok")
PY
fi
echo

if [ "$run_hotspot" != "0" ]; then
  if [ -f "$m0_dir/deepnn_profile.json" ]; then
    echo "[m2] pbs hotspot e2e"
    NO_SUDO=0 OUT_DIR="$m2_dir" \
      bash "$ROOT/scripts/csd_gpu_nvmevirt_deepnn_pbs_hotspot_oneclick.sh" --profile "$m0_dir/deepnn_profile.json"
    rg -n "GLWE matches golden|metrics cmd=" "$m2_dir/backend.log" "$m2_dir/e2e.log" || true
    rg -n "CSD: op=0xc0" "$m2_dir/dmesg_new.log" || true
    echo
  else
    echo "[warn] missing profile: $m0_dir/deepnn_profile.json (skip m2)"
  fi
fi

if [ "$run_sweep" != "0" ]; then
  echo "[m3] sweep"
  if [ "${#deep_nn_cmd[@]}" -gt 0 ]; then
    NO_SUDO=0 REPEATS="$repeats" OUT_PARENT="$m3_parent" \
      bash "$ROOT/scripts/csd_gpu_nvmevirt_macro_deepnn_sweep.sh" -- "${deep_nn_cmd[@]}"
  else
    NO_SUDO=0 REPEATS="$repeats" OUT_PARENT="$m3_parent" \
      bash "$ROOT/scripts/csd_gpu_nvmevirt_macro_deepnn_sweep.sh"
  fi
  python3 "$ROOT/tools/csd_deepnn_sweep_summary.py" --out-parent "$m3_parent" >/dev/null 2>&1 || true
  echo
fi

echo "[ok] fullflow macro deep-nn done."
echo "[ok] m0:  $m0_dir"
echo "[ok] m2:  $m2_dir"
echo "[ok] m3:  $m3_parent"
