#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSD_NO_FALLBACK="${CSD_NO_FALLBACK:-0}"
# shellcheck source=/dev/null
source "$ROOT/scripts/csd_no_fallback.sh"

# One-click sanity for "align to deep-nn / Concrete compile-time params":
# - extracts BootstrapKeyParam tuples from a deep-nn profile
# - builds TFHE GPU baseline variants (overlay + build dir) per unique tuple
# - runs gpu_executor_smoke for each build (NO_SUDO=1 only, fast correctness sanity)
#
# This does NOT make deep-nn end-to-end FHE run on nvmevirt; it only ensures our TFHE stack
# can be built for the observed parameter families (poly size / glwe dimension / input lwe dim).

usage() {
  cat <<'EOF' >&2
usage:
  NO_SUDO=1 bash scripts/csd_gpu_deepnn_concrete_align_oneclick.sh --profile <deepnn_profile.json>
  NO_SUDO=1 bash scripts/csd_gpu_deepnn_concrete_align_oneclick.sh --out-dir <macro OUT_DIR>

notes:
  - Requires NO_SUDO=1 (user-space). This script is a build+smoke sanity, not an nvmevirt e2e.
  - Uses gpu_executor_smoke (mode=2) to validate the build is runnable for each parameter variant.
  - If the profile contains polynomial_size=4096, it is off by default (set CSD_DEEPNN_CONCRETE_ALIGN_ENABLE_4096=1).
  - To also align bootstrap base_log/level, set CSD_DEEPNN_ALIGN_BK_PARAMS=1 (default: off).
  - To force a fixed variant matrix, set CSD_DEEPNN_CONCRETE_ALIGN_FORCE_MATRIX=1
    (override lists with CSD_DEEPNN_CONCRETE_ALIGN_MATRIX_{N0S,POLYS,KS}).
EOF
}

NO_SUDO="${NO_SUDO:-1}"
csd_no_fallback_require_no_sudo
if [ "$NO_SUDO" != "1" ]; then
  echo "[err] this oneclick is NO_SUDO=1 only (build + user-space smoke)." >&2
  echo "[hint] run: NO_SUDO=1 bash $0 --profile <...>" >&2
  exit 2
fi

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

echo "[cfg] profile  $profile"
echo "[cfg] no_fallback $CSD_NO_FALLBACK"
echo

python3 - "$profile" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
obj = json.loads(path.read_text())
records = obj if isinstance(obj, list) else [obj]
rec = records[-1] if records else {}
pbs = (rec or {}).get("pbs", {})
cpp = (pbs or {}).get("count_per_parameter", {}) if isinstance(pbs, dict) else {}

pat = re.compile(r"BootstrapKeyParam\(polynomial_size=([0-9]+),")
polys = set()
for k in cpp.keys():
    m = pat.search(str(k))
    if m:
        polys.add(int(m.group(1)))

enable_4096 = os.environ.get("CSD_DEEPNN_CONCRETE_ALIGN_ENABLE_4096", "0") not in ("0", "", "false", "False")
if 4096 in polys and not enable_4096:
    print("[note] profile contains polynomial_size=4096, but this oneclick skips 4096 by default.", file=sys.stderr)
    print("       export CSD_DEEPNN_CONCRETE_ALIGN_ENABLE_4096=1 to attempt building/running it (currently unstable).", file=sys.stderr)
PY

variants_json="$(
  python3 - "$profile" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
obj = json.loads(path.read_text())
records = obj if isinstance(obj, list) else [obj]
rec = records[-1] if records else {}
pbs = (rec or {}).get("pbs", {})
cpp = (pbs or {}).get("count_per_parameter", {}) if isinstance(pbs, dict) else {}

pat = re.compile(
    r"BootstrapKeyParam\(polynomial_size=([0-9]+),\s*glwe_dimension=([0-9]+),\s*input_lwe_dimension=([0-9]+),\s*level=([0-9]+),\s*base_log=([0-9]+),\s*variance=([0-9eE+\-.]+)\)"
)
tuples = []
for k, v in cpp.items():
    m = pat.search(str(k))
    if not m:
        continue
    poly = int(m.group(1))
    glwe = int(m.group(2))
    n0 = int(m.group(3))
    level = int(m.group(4))
    base_log = int(m.group(5))
    try:
        var = float(m.group(6))
    except Exception:
        var = 0.0
    count = int(v)
    tuples.append((poly, glwe, n0, level, base_log, var, count))

# Choose a compact build plan:
# - polynomial_size 1024/2048/4096 map to n_lvl1 or n_lvl2; we build a variant per polynomial_size.
# - glwe_dimension maps to K.
# - n_lvl0 set to the max input_lwe_dimension for that (poly,glwe) family.
plan = {}
param_stats = {}
for poly, glwe, n0, level, base_log, var, count in tuples:
    key = (poly, glwe)
    plan[key] = max(plan.get(key, 0), n0)
    stats = param_stats.setdefault(key, {})
    bucket = (level, base_log, var)
    stats[bucket] = stats.get(bucket, 0) + count

param = {}
for key, stats in param_stats.items():
    best = sorted(stats.items(), key=lambda x: (-x[1], x[0]))[0][0]
    param[key] = best
    if len(stats) > 1:
        print(f"[warn] multiple BK params for {key}: {sorted(stats.items())}", file=sys.stderr)

def parse_int_list(value, default):
    if not value:
        return list(default)
    items = re.split(r"[ ,;:]+", value)
    out = []
    for item in items:
        if not item:
            continue
        try:
            val = int(item)
        except Exception:
            continue
        if val > 0:
            out.append(val)
    return sorted(set(out)) if out else list(default)


out = []
enable_4096 = os.environ.get("CSD_DEEPNN_CONCRETE_ALIGN_ENABLE_4096", "0") not in ("0", "", "false", "False")
for (poly, glwe), n0 in sorted(plan.items()):
    if poly == 4096 and not enable_4096:
        continue
    # Heuristic mapping:
    # - keep n_lvl1=1024 unless poly==1024
    # - set n_lvl2=poly when poly>=2048 else 2048
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
    level, base_log, var = param.get((poly, glwe), (0, 0, 0.0))
    if var <= 0:
        var = None
    out.append(
        {
            "poly": poly,
            "K": glwe,
            "n_lvl0": n0,
            "n_lvl1": n1,
            "n_lvl2": n2,
            "level": level,
            "base_log": base_log,
            "variance": var,
        }
    )

force_matrix = os.environ.get("CSD_DEEPNN_CONCRETE_ALIGN_FORCE_MATRIX", "0") not in (
    "0",
    "",
    "false",
    "False",
)
if force_matrix:
    matrix_n0s = parse_int_list(
        os.environ.get("CSD_DEEPNN_CONCRETE_ALIGN_MATRIX_N0S", ""),
        default=(771, 772, 813),
    )
    matrix_polys = parse_int_list(
        os.environ.get("CSD_DEEPNN_CONCRETE_ALIGN_MATRIX_POLYS", ""),
        default=(1024, 2048, 4096),
    )
    matrix_ks = parse_int_list(
        os.environ.get("CSD_DEEPNN_CONCRETE_ALIGN_MATRIX_KS", ""),
        default=(1, 2),
    )

    existing = {(v.get("poly"), v.get("K"), v.get("n_lvl0")) for v in out}
    for poly in matrix_polys:
        if poly == 4096 and not enable_4096:
            continue
        for glwe in matrix_ks:
            for n0 in matrix_n0s:
                key = (poly, glwe, n0)
                if key in existing:
                    continue
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
                level, base_log, var = param.get((poly, glwe), (0, 0, 0.0))
                if var <= 0:
                    var = None
                out.append(
                    {
                        "poly": poly,
                        "K": glwe,
                        "n_lvl0": n0,
                        "n_lvl1": n1,
                        "n_lvl2": n2,
                        "level": level,
                        "base_log": base_log,
                        "variance": var,
                    }
                )
                existing.add(key)

print(json.dumps(out))
PY
)"

echo "$variants_json" | python3 -m json.tool >/dev/null 2>&1 || true

count="$(python3 - <<PY
import json
print(len(json.loads('''$variants_json''')))
PY
)"
if [ "$count" -eq 0 ]; then
  echo "[err] no BootstrapKeyParam tuples found in profile: $profile" >&2
  exit 2
fi

echo "[cfg] variants  $count"
echo

out_parent="${OUT_PARENT:-/tmp/csd_gpu_deepnn_concrete_align_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$out_parent"
export ROOT
export OUT_PARENT="$out_parent"

variants_file="$OUT_PARENT/variants.json"
printf '%s\n' "$variants_json" >"$variants_file"

python3 - "$variants_file" <<'PY'
import json
import sys
from pathlib import Path

vars = json.loads(Path(sys.argv[1]).read_text())
for v in vars:
    extra = []
    if v.get("level") is not None:
        extra.append(f"level={v['level']}")
    if v.get("base_log") is not None:
        extra.append(f"base_log={v['base_log']}")
    if v.get("variance") is not None:
        extra.append(f"variance={v['variance']}")
    suffix = f" {' '.join(extra)}" if extra else ""
    print(f"- poly={v['poly']} K={v['K']} n0={v['n_lvl0']} n1={v['n_lvl1']} n2={v['n_lvl2']}{suffix}")
PY
echo

python3 - "$variants_file" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

root = Path(os.environ["ROOT"])
out_parent = Path(os.environ["OUT_PARENT"])
vars = json.loads(Path(sys.argv[1]).read_text())
align_bk = os.environ.get("CSD_DEEPNN_ALIGN_BK_PARAMS", "0") not in ("0", "", "false", "False")

def run(cmd, **kw):
    print("[cmd]", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, **kw)

for i, v in enumerate(vars, start=1):
    name = f"concrete_poly{v['poly']}_k{v['K']}_n0{v['n_lvl0']}_n2{v['n_lvl2']}"
    out_dir = out_parent / name
    out_dir.mkdir(parents=True, exist_ok=True)

    keyset = root / "tmp_assets" / f"wop_keyset_{name}.bin"
    build_dir = root / "sw" / "gpu_runtime_service" / f"build-{name}"
    overlay_dir = root / "sw" / "gpu_runtime_service" / "overlays" / name

    env = os.environ.copy()
    env.setdefault("FORCE_REGEN_KEYSET", os.environ.get("CSD_DEEPNN_FORCE_REGEN_KEYSET", "1"))
    env["NAME"] = name
    env["K"] = str(v["K"])
    env["N_LVL0"] = str(v["n_lvl0"])
    env["N_LVL1"] = str(v["n_lvl1"])
    env["N_LVL2"] = str(v["n_lvl2"])
    if align_bk:
        if v.get("level") is not None:
            env["ELL_LVL2"] = str(v["level"])
        if v.get("base_log") is not None:
            env["BGBIT_LVL2"] = str(v["base_log"])
        var = v.get("variance")
        if var is not None:
            try:
                if float(var) > 0:
                    env["BKSTDEV_LVL2"] = str(var)
            except Exception:
                pass
    env["BUILD_DIR"] = str(build_dir)
    env["OUT_OVERLAY_ROOT"] = str(overlay_dir)
    env["KEYSET_OUT"] = str(keyset)
    env["GEN_KEYSET"] = env.get("GEN_KEYSET", "0")
    env["BUILD_JOBS"] = env.get("BUILD_JOBS", "8")
    # For any runtime smoke that touches FFT, prefer spqlios tables for stability.
    env.setdefault("TFHE_GPU_SPQLIOS_FFT", "1")
    env.setdefault("TFHE_GPU_SPQLIOS_IFFT", "1")
    env.setdefault("TFHE_GPU_SPQLIOS_FFT_TABLE", "/tmp/spqlios_fft_table.n4096.bin")
    env.setdefault("TFHE_GPU_SPQLIOS_IFFT_TABLE", "/tmp/spqlios_ifft_table.n4096.bin")

    print(f"[{i}/{len(vars)}] build {name}", flush=True)
    run(["bash", str(root / "scripts" / "csd_gpu_build_tfhe_variant.sh")], env=env)

    # Run a minimal smoke (no socket, user-space).
    # We use CB(mode=2) everywhere: it is the closest "primitive sanity" without relying on
    # our FunctionEval(fp softmax) contract, which is not the same as Concrete's graph.
    print(f"[{i}/{len(vars)}] smoke {name}", flush=True)
    smoke_bin = build_dir / "gpu_executor_smoke"
    with (out_dir / "smoke.log").open("w") as f:
        run([str(smoke_bin)], stdout=f, stderr=subprocess.STDOUT, env=env)
    print(f"[{i}/{len(vars)}] [PASS] smoke OK: {out_dir}", flush=True)

print("[ok] all variants built + smoke passed")
print(f"[ok] artifacts: {out_parent}")
PY

echo
echo "[ok] deep-nn concrete-align sanity done. Artifacts: $out_parent"
echo "[hint] quick grep: rg -n \"\\[SMOKE\\]|status_code=|Error\" \"$out_parent\"/**/smoke.log"
