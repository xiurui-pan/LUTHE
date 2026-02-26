#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSD_NO_FALLBACK="${CSD_NO_FALLBACK:-0}"
# shellcheck source=/dev/null
source "$ROOT/scripts/csd_no_fallback.sh"

# M9: FunctionEval KSPBS split across all softmax stages (MAX/SHIFT/EXP_MINUS/SUM/DIV).
NO_SUDO="${NO_SUDO:-0}"
N="${N:-16}"

csd_no_fallback_require_no_sudo
csd_no_fallback_force_fft

export WOP_GPU_KSPBS_SPLIT="${WOP_GPU_KSPBS_SPLIT:-1}"
export WOP_GPU_KSPBS_SPLIT_ALL_STAGES="${WOP_GPU_KSPBS_SPLIT_ALL_STAGES:-1}"
export WOP_GPU_KSPBS_SPLIT_LUTS="${WOP_GPU_KSPBS_SPLIT_LUTS:-1,2,7,10,11}"
export CSD_SOFTMAX_KSPBS_SPLIT="${CSD_SOFTMAX_KSPBS_SPLIT:-1}"
export CSD_SOFTMAX_KSPBS_SPLIT_ALL_STAGES="${CSD_SOFTMAX_KSPBS_SPLIT_ALL_STAGES:-1}"
export GPU_TIMEOUT="${GPU_TIMEOUT:-300}"

if [ "$NO_SUDO" = "0" ]; then
  sudo -v
fi

echo "[cfg] ROOT                 $ROOT"
echo "[cfg] no_sudo              $NO_SUDO"
echo "[cfg] no_fallback          $CSD_NO_FALLBACK"
echo "[cfg] n                    $N"
echo "[cfg] gpu_timeout          $GPU_TIMEOUT"
echo "[cfg] WOP_GPU_KSPBS_SPLIT  $WOP_GPU_KSPBS_SPLIT"
echo "[cfg] WOP_GPU_KSPBS_SPLIT_ALL_STAGES $WOP_GPU_KSPBS_SPLIT_ALL_STAGES"
echo "[cfg] WOP_GPU_KSPBS_SPLIT_LUTS $WOP_GPU_KSPBS_SPLIT_LUTS"
echo "[cfg] CSD_SOFTMAX_KSPBS_SPLIT $CSD_SOFTMAX_KSPBS_SPLIT"
echo "[cfg] CSD_SOFTMAX_KSPBS_SPLIT_ALL_STAGES $CSD_SOFTMAX_KSPBS_SPLIT_ALL_STAGES"
echo

NO_SUDO="$NO_SUDO" N="$N" GPU_TIMEOUT="$GPU_TIMEOUT" bash "$ROOT/scripts/csd_gpu_nvmevirt_softmax_oneclick.sh"
