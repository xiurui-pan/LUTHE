#!/usr/bin/env bash

csd_env_enabled() {
  local v="${1:-0}"
  [ "$v" != "0" ] && [ "$v" != "" ] && [ "$v" != "false" ] && [ "$v" != "False" ] && [ "$v" != "no" ] && [ "$v" != "No" ]
}

csd_no_fallback_enabled() {
  [ "${CSD_NO_FALLBACK:-0}" = "1" ]
}

csd_no_fallback_err() {
  echo "[err][no-fallback] $1; set CSD_NO_FALLBACK=0 to allow" >&2
  exit 2
}

csd_no_fallback_require_no_sudo() {
  if csd_no_fallback_enabled && [ "${NO_SUDO:-0}" != "0" ]; then
    csd_no_fallback_err "NO_SUDO=$NO_SUDO (IPC fallback not allowed)"
  fi
}

csd_no_fallback_forbid_env() {
  local var="$1"
  local val="${!var-}"
  if csd_no_fallback_enabled && csd_env_enabled "$val"; then
    csd_no_fallback_err "$var=$val"
  fi
}

csd_no_fallback_force_fft() {
  if ! csd_no_fallback_enabled; then
    return 0
  fi
  local fp_total="${WOPBS_FP_TOTAL_BITS-}"
  local nofft="${WOP_GPU_BIGLUT_BR_NOFFT-}"
  if csd_env_enabled "$nofft"; then
    csd_no_fallback_err "WOP_GPU_BIGLUT_BR_NOFFT=$nofft"
  fi
  export WOP_GPU_BIGLUT_BR_FORCE_FFT=1
}
