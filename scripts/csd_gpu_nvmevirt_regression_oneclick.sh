#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSD_NO_FALLBACK="${CSD_NO_FALLBACK:-0}"
# shellcheck source=/dev/null
source "$ROOT/scripts/csd_no_fallback.sh"

DEV="${DEV:-/dev/nvme2n1}"
NSID="${NSID:-1}"
ENGINE="${ENGINE:-gpu}"

# Full nvmevirt closed-loop requires sudo; use NO_SUDO=1 for quick user-mode smoke.
NO_SUDO="${NO_SUDO:-0}"
GPU_WOKS_NATIVE="${GPU_WOKS_NATIVE:-1}"

csd_no_fallback_require_no_sudo
csd_no_fallback_forbid_env WOP_GPU_FORCE_CPU_WOKS
csd_no_fallback_force_fft
if csd_no_fallback_enabled && [ -n "${SOFTMAX_EPS_ABS_2:-}" ]; then
  csd_no_fallback_err "SOFTMAX_EPS_ABS_2=$SOFTMAX_EPS_ABS_2"
fi

# Optional: force backend PrivKS impl (works in NO_SUDO=0 via nvmevirt/tools/csd_e2e_smoke.sh forwarding).
CSD_PRIVKS_IMPL="${CSD_PRIVKS_IMPL:-numpy}"

# Optional: keyset stored on nvmevirt "flash" (see nvmevirt/tools/csd_e2e_smoke.sh).
CSD_KEYSET_IN_FLASH="${CSD_KEYSET_IN_FLASH:-0}"

# Optional: stage TLWE/GLWE through nvmevirt "flash" (see nvmevirt/tools/csd_e2e_smoke.sh).
CSD_TLWE_IN_FLASH="${CSD_TLWE_IN_FLASH:-0}"
CSD_GLWE_OUT_FLASH="${CSD_GLWE_OUT_FLASH:-0}"

# Optional (mode=0 only): run VP KeySwitch on backend via descriptor flags (wrapper knob).
CSD_VP_KS_ON_BACKEND="${CSD_VP_KS_ON_BACKEND:-0}"

# Optional: keep nvmevirt e2e session (loopdev + gpu_runtime_service) across steps.
# This is mainly useful when CSD_KEYSET_IN_FLASH=1, to avoid repeated multi-GB keyset imports.
CSD_KEEP_SESSION_ENV_SET=0
if [ "${CSD_KEEP_SESSION+x}" = "x" ]; then
  CSD_KEEP_SESSION_ENV_SET=1
fi
CSD_KEEP_SESSION="${CSD_KEEP_SESSION:-0}"
# Optional: keep nvmevirt backend (csd_sw_backend.py) across steps, to reuse Python-side key mmap/caches.
CSD_KEEP_BACKEND_ENV_SET=0
if [ "${CSD_KEEP_BACKEND+x}" = "x" ]; then
  CSD_KEEP_BACKEND_ENV_SET=1
fi
CSD_KEEP_BACKEND="${CSD_KEEP_BACKEND:-0}"
GPU_SOCKET="${GPU_SOCKET:-/tmp/wop_gpu_runtime.sock}"

RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-/tmp/csd_gpu_nvmevirt_regression_${RUN_ID}}"

mkdir -p "$OUT_DIR"

# Keyset selection (shared across all steps).
# Motivation: when CSD_KEEP_SESSION=1 / CSD_KEYSET_IN_FLASH=1, the e2e session may reuse the same
# keyset(loopdev) + gpu_runtime_service across steps. If individual oneclick scripts implicitly pick
# different keysets, their CPU golden generation can diverge from the in-session keyset, causing false
# mismatches (e.g., BE split uses preKS_gpbs).
KEYSET_DEFAULT="$ROOT/tmp_assets/wop_keyset.bin"
KEYSET_ENV_SET=0
if [ "${KEYSET+x}" = "x" ]; then
  KEYSET_ENV_SET=1
fi
KEYSET="${KEYSET:-$KEYSET_DEFAULT}"
REGEN_KEYSET="${REGEN_KEYSET:-0}"
if [ "$GPU_WOKS_NATIVE" = "1" ] && [ "$REGEN_KEYSET" = "0" ] && [ "$KEYSET_ENV_SET" = "0" ]; then
  # Default: generate a deterministic keyset once under OUT_DIR and reuse it everywhere.
  REGEN_KEYSET=1
  KEYSET="$OUT_DIR/wop_keyset.bin"
fi

if [ "$NO_SUDO" = "0" ] && [ "$CSD_KEYSET_IN_FLASH" = "1" ] && [ "$CSD_KEEP_SESSION_ENV_SET" = "0" ]; then
  # Default to keeping session in keyset-in-flash mode to reduce repeated key imports.
  if ! csd_no_fallback_enabled; then
    CSD_KEEP_SESSION=1
  fi
fi
if [ "$NO_SUDO" = "0" ] && [ "$CSD_KEEP_SESSION" = "1" ] && [ "$CSD_KEEP_BACKEND_ENV_SET" = "0" ]; then
  # Default to keeping backend when keeping session (reduces repeated python startup + key mmap churn).
  if ! csd_no_fallback_enabled; then
    CSD_KEEP_BACKEND=1
  fi
fi

cfg() { printf '[cfg] %-20s %s\n' "$1" "$2"; }

cfg "ROOT" "$ROOT"
cfg "dev" "$DEV"
cfg "nsid" "$NSID"
cfg "engine" "$ENGINE"
cfg "gpu_woks_native" "$GPU_WOKS_NATIVE"
cfg "no_sudo" "$NO_SUDO"
cfg "csd_privks_impl" "$CSD_PRIVKS_IMPL"
cfg "csd_keyset_in_flash" "$CSD_KEYSET_IN_FLASH"
cfg "csd_flash_io" "tlwe_in_flash=$CSD_TLWE_IN_FLASH glwe_out_flash=$CSD_GLWE_OUT_FLASH"
cfg "csd_vp_ks_on_backend" "$CSD_VP_KS_ON_BACKEND"
cfg "csd_keep_session" "$CSD_KEEP_SESSION"
cfg "csd_keep_backend" "$CSD_KEEP_BACKEND"
cfg "keyset" "$KEYSET regen_keyset=$REGEN_KEYSET"
cfg "out_dir" "$OUT_DIR"
cfg "no_fallback" "$CSD_NO_FALLBACK"
echo

# Session dir is stable across per-step OUT_DIR overrides (run_step sets OUT_DIR=step_dir).
SESSION_DIR="$OUT_DIR/.session"

cleanup_session() {
  if [ "$NO_SUDO" != "0" ]; then
    return 0
  fi
  if [ "$CSD_KEEP_SESSION" != "1" ]; then
    return 0
  fi
  local loopdev=""
  if [ -f "$SESSION_DIR/keyset_loopdev" ]; then
    loopdev="$(cat "$SESSION_DIR/keyset_loopdev" 2>/dev/null || true)"
  fi
  sudo pkill -f "[c]sd_sw_backend.py" >/dev/null 2>&1 || true
  pkill -f "[c]sd_sw_backend.py" >/dev/null 2>&1 || true
  sudo rm -f /tmp/wop_host_ctrl.sock >/dev/null 2>&1 || true
  sudo pkill -9 -f "[g]pu_runtime_service.*${GPU_SOCKET}" >/dev/null 2>&1 || true
  pkill -9 -f "[g]pu_runtime_service.*${GPU_SOCKET}" >/dev/null 2>&1 || true
  if [ -n "$loopdev" ] && [ -b "$loopdev" ]; then
    sudo losetup -d "$loopdev" >/dev/null 2>&1 || true
  fi
  rm -rf "$SESSION_DIR" >/dev/null 2>&1 || true
}

trap cleanup_session EXIT

run_step() {
  local name="$1"
  shift
  local step_dir="$OUT_DIR/$name"
  mkdir -p "$step_dir"
  echo
  echo "[run] $name (out_dir=$step_dir)"
  local verbose="${CSD_REGRESSION_VERBOSE:-0}"
  local log="$step_dir/run.log"
  local trace_enabled="${CSD_PIPELINE_TRACE:-1}"
  local trace_out="${CSD_PIPELINE_TRACE_OUT:-$step_dir/pipeline_trace.log}"
  local awk_prog
  awk_prog="$(mktemp)"
  cat >"$awk_prog" <<'AWK'
function strip_ansi(s) {
  gsub(/\x1B\[[0-9;]*[A-Za-z]/, "", s)
  gsub(/\x1B\][0-9;]*[^\x07]*\x07/, "", s)
  return s
}
function normalize(line) {
  gsub(/\x08/, "", line)          # backspace
  line = strip_ansi(line)
  sub(/^[[:space:]]*\|[[:space:]]*/, "", line) # drop nested "| " prefix if any
  sub(/^[[:space:]]+/, "", line)
  sub(/[[:space:]]+$/, "", line)  # rstrip
  return line
}
function keep(s) {
  if (s == "") return 0
  # Drop noisy per-step config blocks; top-level cfg is already printed by this script.
  if (s ~ /^\[cfg\]/) return 0
  if (s ~ /^\[note\]/) return 0
  # Keep script progress markers like "[1/4] ..." / "[3/6] ...".
  if (s ~ /^\[[0-9]+(\.[0-9]+)?\/[0-9]+\]/) return 1
  # Keep tagged lines like "[PASS] ...", "[gen] ...", "[softmax] ...".
  # This intentionally drops build-system progress like "[  3%] Built target ...".
  if (s ~ /^\[[A-Za-z]/) return 1
  if (s ~ /\[DESC_RING\]/) return 1
  if (s ~ /\[FTL_EMU\]/) return 1
  if (s ~ /\[KSPBS_SPLIT\]/) return 1
  if (s ~ /GLWE matches golden/) return 1
  if (s ~ /metrics cmd=/) return 1
  if (s ~ /doorbell cmd_id=/) return 1
  if (s ~ /IO Command .*result:/) return 1
  if (s ~ /\[(PASS|FAIL|WARN)\]/) return 1
  if (s ~ /(failed:|PermissionError|Traceback|RuntimeError)/) return 1
  if (s ~ /engine=[a-z]+ cmd=/) return 1
  if (s ~ /(error:|CMake Error|FAILED:|make: \*\*\*)/) return 1
  return 0
}
{
  line = normalize($0)
  if (verbose == 1) {
    if (line == "") {
      print "  |"
      fflush()
      next
    }
    printf("  | %s\n", line)
    fflush()
    next
  }
  if (keep(line)) {
    printf("  | %s\n", line)
    fflush()
  }
}
AWK

  (OUT_DIR="$step_dir" CSD_PIPELINE_TRACE="$trace_enabled" CSD_PIPELINE_TRACE_OUT="$trace_out" \
    "$@" 2>&1 | tee "$log" | tr '\r' '\n' | awk -v verbose="$verbose" -f "$awk_prog")
  local rc=$?
  rm -f "$awk_prog"
  if [ "$trace_enabled" = "1" ] && [ -f "$trace_out" ]; then
    python3 "$ROOT/tools/pipeline_overlap_analyzer.py" --out "$step_dir" "$trace_out" || true
  fi
  return $rc
}

# 1) vp/exp/soft (bit-exact)
run_step "vp_exp_soft" \
  env DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" NO_SUDO="$NO_SUDO" GPU_WOKS_NATIVE="$GPU_WOKS_NATIVE" \
      KEYSET="$KEYSET" REGEN_KEYSET="$REGEN_KEYSET" \
      GPU_SOCKET="$GPU_SOCKET" CSD_KEEP_SESSION="$CSD_KEEP_SESSION" CSD_KEEP_BACKEND="$CSD_KEEP_BACKEND" CSD_SESSION_DIR="$SESSION_DIR" \
      CSD_PRIVKS_IMPL="$CSD_PRIVKS_IMPL" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_oneclick.sh"

# Avoid repeated keyset generation across steps; keyset is deterministic and already generated.
REGEN_KEYSET=0

# If keyset is placed on flash, keep nvmev.ko loaded across steps to avoid
# re-programming multi-GB keyset repeatedly.
SKIP_RELOAD_AFTER_FIRST=0
if [ "$CSD_KEYSET_IN_FLASH" = "1" ]; then
  SKIP_RELOAD_AFTER_FIRST=1
fi

# 2) BE split (bit-exact): GPU bit_extract-only -> backend KS(gpbs)+premod -> GPU WoKS
run_step "be_split" \
  env DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" NO_SUDO="$NO_SUDO" SKIP_RELOAD="$SKIP_RELOAD_AFTER_FIRST" \
      KEYSET="$KEYSET" REGEN_KEYSET="$REGEN_KEYSET" \
      GPU_SOCKET="$GPU_SOCKET" CSD_KEEP_SESSION="$CSD_KEEP_SESSION" CSD_KEEP_BACKEND="$CSD_KEEP_BACKEND" CSD_SESSION_DIR="$SESSION_DIR" \
      CSD_PRIVKS_IMPL="$CSD_PRIVKS_IMPL" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_be_split_oneclick.sh"

# 3) softmax(mode=3) (tolerance)
# Default behavior: unset KSPBS split env to avoid slow-path timeouts for N=16 staged DIV.
# Opt-in: CSD_REGRESSION_SOFTMAX_KEEP_SPLIT=1 to inherit split env for this step as well.
SOFTMAX_KEEP_SPLIT="${CSD_REGRESSION_SOFTMAX_KEEP_SPLIT:-0}"
if csd_no_fallback_enabled && [ "$SOFTMAX_KEEP_SPLIT" != "1" ]; then
  echo "[cfg][no-fallback] softmax keep KSPBS split (force CSD_REGRESSION_SOFTMAX_KEEP_SPLIT=1)"
  SOFTMAX_KEEP_SPLIT=1
fi
if [ "$SOFTMAX_KEEP_SPLIT" = "1" ]; then
  run_step "softmax" \
    env DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" NO_SUDO="$NO_SUDO" SKIP_RELOAD="$SKIP_RELOAD_AFTER_FIRST" \
        KEYSET="$KEYSET" REGEN_KEYSET="$REGEN_KEYSET" \
        GPU_SOCKET="$GPU_SOCKET" CSD_KEEP_SESSION="$CSD_KEEP_SESSION" CSD_KEEP_BACKEND="$CSD_KEEP_BACKEND" CSD_SESSION_DIR="$SESSION_DIR" \
        CSD_PRIVKS_IMPL="$CSD_PRIVKS_IMPL" \
      bash "$ROOT/scripts/csd_gpu_nvmevirt_softmax_oneclick.sh"
else
  run_step "softmax" \
    env -u WOP_GPU_KSPBS_SPLIT -u WOP_GPU_KSPBS_SPLIT_LUTS -u WOP_GPU_KSPBS_SPLIT_LOG \
        DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" NO_SUDO="$NO_SUDO" SKIP_RELOAD="$SKIP_RELOAD_AFTER_FIRST" \
        KEYSET="$KEYSET" REGEN_KEYSET="$REGEN_KEYSET" \
        GPU_SOCKET="$GPU_SOCKET" CSD_KEEP_SESSION="$CSD_KEEP_SESSION" CSD_KEEP_BACKEND="$CSD_KEEP_BACKEND" CSD_SESSION_DIR="$SESSION_DIR" \
        CSD_PRIVKS_IMPL="$CSD_PRIVKS_IMPL" \
      bash "$ROOT/scripts/csd_gpu_nvmevirt_softmax_oneclick.sh"
fi

# 4) CB step4_only split
run_step "cb_step4only" \
  env DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" NO_SUDO="$NO_SUDO" SKIP_RELOAD="$SKIP_RELOAD_AFTER_FIRST" GPU_WOKS_NATIVE="$GPU_WOKS_NATIVE" \
      KEYSET="$KEYSET" REGEN_KEYSET="$REGEN_KEYSET" \
      GPU_SOCKET="$GPU_SOCKET" CSD_KEEP_SESSION="$CSD_KEEP_SESSION" CSD_KEEP_BACKEND="$CSD_KEEP_BACKEND" CSD_SESSION_DIR="$SESSION_DIR" \
      CSD_PRIVKS_IMPL="$CSD_PRIVKS_IMPL" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_cb_step4only_oneclick.sh"

# 5) CB step4_only + premod split (M5)
run_step "cb_step4only_premod" \
  env DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" NO_SUDO="$NO_SUDO" SKIP_RELOAD="$SKIP_RELOAD_AFTER_FIRST" GPU_WOKS_NATIVE="$GPU_WOKS_NATIVE" \
      KEYSET="$KEYSET" REGEN_KEYSET="$REGEN_KEYSET" \
      GPU_SOCKET="$GPU_SOCKET" CSD_KEEP_SESSION="$CSD_KEEP_SESSION" CSD_KEEP_BACKEND="$CSD_KEEP_BACKEND" CSD_SESSION_DIR="$SESSION_DIR" \
      CSD_PRIVKS_IMPL="$CSD_PRIVKS_IMPL" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_cb_step4only_premod_oneclick.sh"

# 6) KSPBS micro-flow split (M8)
run_step "kspbs_split" \
  env DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" NO_SUDO="$NO_SUDO" SKIP_RELOAD="$SKIP_RELOAD_AFTER_FIRST" \
      KEYSET="$KEYSET" REGEN_KEYSET="$REGEN_KEYSET" \
      GPU_SOCKET="$GPU_SOCKET" CSD_KEEP_SESSION="$CSD_KEEP_SESSION" CSD_KEEP_BACKEND="$CSD_KEEP_BACKEND" CSD_SESSION_DIR="$SESSION_DIR" \
      CSD_PRIVKS_IMPL="$CSD_PRIVKS_IMPL" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_kspbs_split_oneclick.sh"

# 7) KSPBS micro-flow split (M8) - per-sample LUT (batch + lut_id[] tail)
run_step "kspbs_split_per_sample" \
  env DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" NO_SUDO="$NO_SUDO" SKIP_RELOAD="$SKIP_RELOAD_AFTER_FIRST" \
      KEYSET="$KEYSET" REGEN_KEYSET="$REGEN_KEYSET" \
      GPU_SOCKET="$GPU_SOCKET" CSD_KEEP_SESSION="$CSD_KEEP_SESSION" CSD_KEEP_BACKEND="$CSD_KEEP_BACKEND" CSD_SESSION_DIR="$SESSION_DIR" \
      CSD_PRIVKS_IMPL="$CSD_PRIVKS_IMPL" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_kspbs_split_per_sample_oneclick.sh"

# 8) softmax KSPBS split (M9) - keep it small to stay within timeout budget.
# This step needs WOP_GPU_KSPBS_SPLIT enabled in gpu_runtime_service env; run it last so we can
# restart the session cleanly without impacting other steps.
if [ "$NO_SUDO" = "0" ] && [ "$CSD_KEEP_SESSION" = "1" ]; then
  cleanup_session || true
fi
run_step "softmax_kspbs_split_n4" \
  env DEV="$DEV" NSID="$NSID" ENGINE="$ENGINE" NO_SUDO="$NO_SUDO" SKIP_RELOAD="$SKIP_RELOAD_AFTER_FIRST" N=4 \
      KEYSET="$KEYSET" REGEN_KEYSET="$REGEN_KEYSET" \
      GPU_SOCKET="$GPU_SOCKET" \
      GPU_TIMEOUT="${GPU_TIMEOUT:-240}" \
      CSD_KEEP_SESSION=0 \
      CSD_KEEP_BACKEND=0 \
      CSD_PRIVKS_IMPL="$CSD_PRIVKS_IMPL" \
    bash "$ROOT/scripts/csd_gpu_nvmevirt_softmax_kspbs_split_n4_oneclick.sh"

extract_metrics_line() {
  local log="$1"
  if [ ! -f "$log" ]; then
    return 0
  fi
  if command -v rg >/dev/null 2>&1; then
    rg -n "metrics cmd=" "$log" | tail -n 1 | sed 's/^.*metrics /metrics /'
  else
    grep -n "metrics cmd=" "$log" | tail -n 1 | sed 's/^.*metrics /metrics /'
  fi
}

extract_kspbs_split_agg() {
  local log="$1"
  if [ ! -f "$log" ]; then
    return 0
  fi

  local awk_prog='
    BEGIN { hits=0; ks=0; boot=0; ext=0; total=0; }
    {
      hits += 1;
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^ks_ns=/) { sub(/^ks_ns=/, "", $i); ks += $i; }
        else if ($i ~ /^gpu_bootstrap_ns=/) { sub(/^gpu_bootstrap_ns=/, "", $i); boot += $i; }
        else if ($i ~ /^extract_ns=/) { sub(/^extract_ns=/, "", $i); ext += $i; }
        else if ($i ~ /^total_ns=/) { sub(/^total_ns=/, "", $i); total += $i; }
      }
    }
    END {
      if (hits == 0) { exit 0; }
      printf("kspbs_split_hits=%d kspbs_split_ks_ns=%d kspbs_split_gpu_bootstrap_ns=%d kspbs_split_extract_ns=%d kspbs_split_total_ns=%d",
             hits, ks, boot, ext, total);
    }
  '

  if command -v rg >/dev/null 2>&1; then
    (rg "\\[KSPBS_SPLIT\\]" "$log" || true) | awk "$awk_prog"
  else
    (grep "\\[KSPBS_SPLIT\\]" "$log" || true) | awk "$awk_prog"
  fi
}

extract_ftl_line() {
  local log="$1"
  if [ ! -f "$log" ]; then
    return 0
  fi
  if command -v rg >/dev/null 2>&1; then
    rg -n "\\[FTL_EMU\\]\\[SUMMARY\\]" "$log" | tail -n 1 | sed 's/^.*\\[FTL_EMU\\]/[FTL_EMU]/'
  else
    grep -n "\\[FTL_EMU\\]\\[SUMMARY\\]" "$log" | tail -n 1 | sed 's/^.*\\[FTL_EMU\\]/[FTL_EMU]/'
  fi
}

extract_flash_summary() {
  local log="$1"
  if [ ! -f "$log" ]; then
    return 0
  fi

  local loopdev=""
  local key_slba=""
  local tlwe_slba=""
  local glwe_slba=""
  local reuse_loop=0
  local reuse_gpu=0
  local reuse_backend=0

  if command -v rg >/dev/null 2>&1; then
    loopdev="$(rg -o "keyset\\(loopdev\\)=/dev/loop[0-9]+" "$log" | tail -n 1 | cut -d= -f2 || true)"
    key_slba="$(rg -n "\\[KEYSET_FLASH\\] dev=.* slba=" "$log" | tail -n 1 | sed -n 's/.*slba=\\([0-9]\\+\\).*/\\1/p' || true)"
    tlwe_slba="$(rg -n "\\[DATA_FLASH\\] tlwe slba=" "$log" | tail -n 1 | sed -n 's/.*tlwe slba=\\([0-9]\\+\\).*/\\1/p' || true)"
    glwe_slba="$(rg -n "\\[DATA_FLASH\\] glwe slba=" "$log" | tail -n 1 | sed -n 's/.*glwe slba=\\([0-9]\\+\\).*/\\1/p' || true)"
    if rg -q "\\[SESSION\\] reuse keyset loopdev" "$log"; then
      reuse_loop=1
    fi
    if rg -q "\\[SESSION\\] reuse gpu_runtime_service" "$log"; then
      reuse_gpu=1
    fi
    if rg -q "\\[SESSION\\] reuse csd_sw_backend" "$log"; then
      reuse_backend=1
    fi
  else
    loopdev="$(grep -oE "keyset\\(loopdev\\)=/dev/loop[0-9]+" "$log" | tail -n 1 | cut -d= -f2 || true)"
    key_slba="$(grep -E "\\[KEYSET_FLASH\\] dev=.* slba=" "$log" | tail -n 1 | sed -n 's/.*slba=\\([0-9]\\+\\).*/\\1/p' || true)"
    tlwe_slba="$(grep -E "\\[DATA_FLASH\\] tlwe slba=" "$log" | tail -n 1 | sed -n 's/.*tlwe slba=\\([0-9]\\+\\).*/\\1/p' || true)"
    glwe_slba="$(grep -E "\\[DATA_FLASH\\] glwe slba=" "$log" | tail -n 1 | sed -n 's/.*glwe slba=\\([0-9]\\+\\).*/\\1/p' || true)"
    if grep -q "\\[SESSION\\] reuse keyset loopdev" "$log"; then
      reuse_loop=1
    fi
    if grep -q "\\[SESSION\\] reuse gpu_runtime_service" "$log"; then
      reuse_gpu=1
    fi
    if grep -q "\\[SESSION\\] reuse csd_sw_backend" "$log"; then
      reuse_backend=1
    fi
  fi

  local out=""
  if [ -n "$loopdev" ]; then
    out="${out} loopdev=${loopdev}"
  fi
  if [ -n "$key_slba" ]; then
    out="${out} key_slba=${key_slba}"
  fi
  if [ -n "$tlwe_slba" ]; then
    out="${out} tlwe_slba=${tlwe_slba}"
  fi
  if [ -n "$glwe_slba" ]; then
    out="${out} glwe_slba=${glwe_slba}"
  fi
  if [ "$reuse_loop" = "1" ]; then
    out="${out} reuse_loop=1"
  fi
  if [ "$reuse_gpu" = "1" ]; then
    out="${out} reuse_gpu=1"
  fi
  if [ "$reuse_backend" = "1" ]; then
    out="${out} reuse_backend=1"
  fi
  if [ -z "$out" ]; then
    return 0
  fi
  echo "${out# }"
}

print_metric() {
  local name="$1"
  local log="$2"
  local line
  line="$(extract_metrics_line "$log" || true)"
  if [ -z "$line" ]; then
    printf '[summary] %-24s %s\n' "$name" "(no metrics line, log=$log)"
    return 0
  fi
  printf '[summary] %-24s %s\n' "$name" "$line"
}

print_kspbs_split_agg() {
  local name="$1"
  local log="$2"
  local line
  line="$(extract_kspbs_split_agg "$log" || true)"
  if [ -z "$line" ]; then
    return 0
  fi
  printf '[summary] %-24s %s\n' "$name" "$line"
}

print_ftl() {
  local name="$1"
  local log="$2"
  local line
  line="$(extract_ftl_line "$log" || true)"
  if [ -z "$line" ]; then
    return 0
  fi
  printf '[summary] %-24s %s\n' "$name" "$line"
}

print_flash() {
  local name="$1"
  local log="$2"
  local line
  line="$(extract_flash_summary "$log" || true)"
  if [ -z "$line" ]; then
    return 0
  fi
  printf '[summary] %-24s %s\n' "$name" "$line"
}

if [ "$NO_SUDO" = "0" ]; then
  echo
  echo "[summary] Extracted backend metrics (bytes/latency):"
  metrics_file="$OUT_DIR/metrics_summary.txt"
  {
    print_metric "vp" "$OUT_DIR/vp_exp_soft/vp_backend.log"
    print_metric "exp" "$OUT_DIR/vp_exp_soft/exp_backend.log"
    print_metric "soft" "$OUT_DIR/vp_exp_soft/soft_backend.log"
    print_metric "be_split" "$OUT_DIR/be_split/backend.log"
    print_metric "softmax" "$OUT_DIR/softmax/backend.log"
    print_ftl "softmax_ftl" "$OUT_DIR/softmax/backend.log"
    print_metric "softmax_kspbs_split_n4" "$OUT_DIR/softmax_kspbs_split_n4/backend.log"
    print_kspbs_split_agg "softmax_kspbs_split_agg" "$OUT_DIR/softmax_kspbs_split_n4/gpu_runtime_service.log"
    print_ftl "softmax_kspbs_split_ftl" "$OUT_DIR/softmax_kspbs_split_n4/backend.log"
    print_metric "cb_step4only" "$OUT_DIR/cb_step4only/backend.log"
    print_ftl "cb_step4only_ftl" "$OUT_DIR/cb_step4only/backend.log"
    print_metric "cb_step4only_premod" "$OUT_DIR/cb_step4only_premod/backend.log"
    print_ftl "cb_step4only_premod_ftl" "$OUT_DIR/cb_step4only_premod/backend.log"
    print_metric "kspbs_split" "$OUT_DIR/kspbs_split/backend.log"
    print_ftl "kspbs_split_ftl" "$OUT_DIR/kspbs_split/backend.log"
    print_metric "kspbs_split_per_sample" "$OUT_DIR/kspbs_split_per_sample/backend.log"
    print_ftl "kspbs_split_ps_ftl" "$OUT_DIR/kspbs_split_per_sample/backend.log"

    if [ "$CSD_KEYSET_IN_FLASH" = "1" ] || [ "$CSD_TLWE_IN_FLASH" = "1" ] || [ "$CSD_GLWE_OUT_FLASH" = "1" ] || [ "$CSD_KEEP_SESSION" = "1" ]; then
      print_flash "flash_vp_exp_soft" "$OUT_DIR/vp_exp_soft/exp_e2e.log"
      print_flash "flash_be_split" "$OUT_DIR/be_split/e2e.log"
      print_flash "flash_softmax" "$OUT_DIR/softmax/e2e.log"
      print_flash "flash_cb_step4only" "$OUT_DIR/cb_step4only/e2e.log"
      print_flash "flash_cb_premod" "$OUT_DIR/cb_step4only_premod/e2e.log"
      print_flash "flash_kspbs_split" "$OUT_DIR/kspbs_split/e2e.log"
      print_flash "flash_kspbs_split_ps" "$OUT_DIR/kspbs_split_per_sample/e2e.log"
      print_flash "flash_softmax_kspbs_n4" "$OUT_DIR/softmax_kspbs_split_n4/e2e.log"
    fi
  } | tee "$metrics_file"
  echo "[summary] metrics saved: $metrics_file"
fi

echo
echo "[PASS] nvmevirt regression OK. Artifacts saved under: $OUT_DIR"
