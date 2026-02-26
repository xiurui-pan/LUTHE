#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSD_NO_FALLBACK="${CSD_NO_FALLBACK:-0}"
TB_DIR="$ROOT/hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine"
NVMEVIRT_DIR="${NVMEVIRT_DIR:-$ROOT/../nvmevirt}"
BUILD_NVMEVIRT="${BUILD_NVMEVIRT:-1}"

DEV="${DEV:-/dev/nvme2n1}"
NSID="${NSID:-1}"
MODE="${MODE:-2}"               # 0=VP, 1=BE, 2=CB
TLWE_WORDS="${TLWE_WORDS:-631}" # CB default: N_LVL0+1
GLWE_WORDS="${GLWE_WORDS:-3}"
TIMEOUT_SEC="${TIMEOUT_SEC:-300}"
SOCKET_PATH="${SOCKET_PATH:-/tmp/wop_host_ctrl.sock}"
SOCKET_WAIT_SEC="${SOCKET_WAIT_SEC:-60}"

NVMEVIRT_CPUS="${NVMEVIRT_CPUS:-7,8}"
NVMEVIRT_MEMMAP_START="${NVMEVIRT_MEMMAP_START:-128G}"
NVMEVIRT_MEMMAP_SIZE="${NVMEVIRT_MEMMAP_SIZE:-16G}"

TLWE_FILE="${TLWE_FILE:-$ROOT/tmp_assets/vp_input_index42.bin}"

RUN_LOG="$TB_DIR/cb_oneclick.console.log"
SIM_PID=""

log() { echo "[oneclick] $*"; }
warn() { echo "[oneclick][warn] $*" >&2; }
die() { echo "[oneclick][err] $*" >&2; exit 2; }
log "no_fallback=$CSD_NO_FALLBACK"

usage() {
  cat >&2 <<EOF
Usage:
  scripts/csd_host_ctrl_dpi_oneclick.sh

Purpose:
  One-shot end-to-end smoke for: RTL HOST_CTRL_DPI server-only + nvmevirt vendor 0xC0 doorbell.

Success criteria (in \$TB_DIR/cb_test.log):
  - [TB] Doorbell fired
  - [TB] Result status write detected (COMPLETE)
  - [TB] Host ACK sent
  - CB Pre-KS: Received coefficient TLWE_WORDS/TLWE_WORDS
  - KS command accepted

Env knobs (defaults shown):
  DEV=$DEV
  MODE=$MODE TLWE_WORDS=$TLWE_WORDS GLWE_WORDS=$GLWE_WORDS NSID=$NSID
	  SOCKET_PATH=$SOCKET_PATH TIMEOUT_SEC=$TIMEOUT_SEC SOCKET_WAIT_SEC=$SOCKET_WAIT_SEC
	  NVMEVIRT_DIR=$NVMEVIRT_DIR BUILD_NVMEVIRT=$BUILD_NVMEVIRT
	  NVMEVIRT_CPUS=$NVMEVIRT_CPUS NVMEVIRT_MEMMAP_START=$NVMEVIRT_MEMMAP_START NVMEVIRT_MEMMAP_SIZE=$NVMEVIRT_MEMMAP_SIZE
	  TLWE_FILE=$TLWE_FILE
EOF
	  exit 2
}

cleanup() {
  if [ -n "${SIM_PID}" ] && kill -0 "${SIM_PID}" 2>/dev/null; then
    warn "stopping quick_cb_test.sh (pid=${SIM_PID})"
    kill "${SIM_PID}" 2>/dev/null || true
    wait "${SIM_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
fi

if [ ! -d "$TB_DIR" ]; then
  die "missing TB_DIR: $TB_DIR"
fi
if ! command -v rg >/dev/null 2>&1; then
  die "missing dependency: rg (ripgrep)"
fi
if ! command -v nvme >/dev/null 2>&1; then
  die "missing dependency: nvme (nvme-cli)"
fi
if [ ! -x "$TB_DIR/quick_cb_test.sh" ]; then
  die "missing executable: $TB_DIR/quick_cb_test.sh"
fi
if [ ! -x "$ROOT/scripts/csd_host_ctrl_dpi_smoke.sh" ]; then
  die "missing executable: $ROOT/scripts/csd_host_ctrl_dpi_smoke.sh"
fi
if [ ! -f "$TLWE_FILE" ]; then
  die "missing TLWE_FILE: $TLWE_FILE"
fi
if [ ! -d "$NVMEVIRT_DIR" ]; then
  die "missing NVMEVIRT_DIR: $NVMEVIRT_DIR"
fi
if [ ! -f "$NVMEVIRT_DIR/nvmev.ko" ]; then
  die "missing nvmevirt module: $NVMEVIRT_DIR/nvmev.ko"
fi
if [ "$BUILD_NVMEVIRT" != "0" ]; then
  if ! command -v make >/dev/null 2>&1; then
    die "missing dependency: make (required when BUILD_NVMEVIRT=1)"
  fi
  log "building nvmevirt module: $NVMEVIRT_DIR"
  make -C "$NVMEVIRT_DIR" -j"$(nproc)" >/dev/null
fi

log "sudo auth (will prompt once)"
sudo -v || die "sudo auth failed"

log "killing potential socket grabbers (best-effort)"
pkill -f "csd_sw_backend\\.py" >/dev/null 2>&1 || true
pkill -f "doorbell_stub\\.py" >/dev/null 2>&1 || true

log "clearing stale socket path: $SOCKET_PATH"
sudo rm -f "$SOCKET_PATH" >/dev/null 2>&1 || true
rm -f "$SOCKET_PATH" >/dev/null 2>&1 || true

log "reloading nvmevirt (nvmev) with host_ctrl_socket_path=$SOCKET_PATH"
sudo rmmod nvmev >/dev/null 2>&1 || true
sudo insmod "$NVMEVIRT_DIR/nvmev.ko" \
  memmap_start="$NVMEVIRT_MEMMAP_START" memmap_size="$NVMEVIRT_MEMMAP_SIZE" \
  cpus="$NVMEVIRT_CPUS" host_ctrl_socket_path="$SOCKET_PATH"

if [ -r /sys/module/nvmev/parameters/host_ctrl_socket_path ]; then
  loaded_socket="$(cat /sys/module/nvmev/parameters/host_ctrl_socket_path 2>/dev/null || true)"
  if [ "$loaded_socket" != "$SOCKET_PATH" ]; then
    die "nvmev host_ctrl_socket_path mismatch: loaded=$loaded_socket expect=$SOCKET_PATH"
  fi
fi

log "starting RTL simulation (HOST_CTRL_DPI server-only) in background"
rm -f "$RUN_LOG" >/dev/null 2>&1 || true
(
  cd "$TB_DIR"
  CB_ENABLE_HOST_CTRL=1 \
  CB_HOST_CTRL_LAUNCH_STUB=0 \
  CB_HOST_CTRL_SOCKET="$SOCKET_PATH" \
  TIMEOUT_SEC="$TIMEOUT_SEC" \
  ./quick_cb_test.sh
) >"$RUN_LOG" 2>&1 &
SIM_PID=$!
log "quick_cb_test.sh pid=$SIM_PID (console log: $RUN_LOG)"

log "waiting for HOST_CTRL_DPI socket to appear: $SOCKET_PATH (wait ${SOCKET_WAIT_SEC}s)"
deadline=$(( $(date +%s) + SOCKET_WAIT_SEC ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ -S "$SOCKET_PATH" ] && break
  sleep 0.1
done
if [ ! -S "$SOCKET_PATH" ]; then
  die "socket not ready: $SOCKET_PATH (see $RUN_LOG)"
fi

log "triggering nvmevirt vendor 0xC0 doorbell"
DEV="$DEV" MODE="$MODE" TLWE_WORDS="$TLWE_WORDS" GLWE_WORDS="$GLWE_WORDS" NSID="$NSID" \
  SOCKET_PATH="$SOCKET_PATH" TLWE_FILE="$TLWE_FILE" \
  "$ROOT/scripts/csd_host_ctrl_dpi_smoke.sh"

log "waiting for quick_cb_test.sh to finish"
set +e
wait "$SIM_PID"
SIM_RC=$?
set -e
SIM_PID=""
log "quick_cb_test.sh exit=$SIM_RC"

CB_LOG="$TB_DIR/cb_test.log"
if [ ! -f "$CB_LOG" ]; then
  die "missing log: $CB_LOG (see $RUN_LOG)"
fi

log "evidence scan (must contain all 5 lines below)"
rg -n "\\[TB\\] Doorbell fired|\\[TB\\] Result status write detected \\(COMPLETE\\)|\\[TB\\] Host ACK sent|KS command accepted" "$CB_LOG" || true
rg -n --fixed-strings "CB Pre-KS: Received coefficient ${TLWE_WORDS}/${TLWE_WORDS}" "$CB_LOG" || true

missing=()
req_fixed=(
  "[TB] Doorbell fired"
  "[TB] Result status write detected (COMPLETE)"
  "[TB] Host ACK sent"
  "KS command accepted"
)
for pat in "${req_fixed[@]}"; do
  if ! rg -q --fixed-strings "$pat" "$CB_LOG"; then
    missing+=("$pat")
  fi
done
req_coeff="CB Pre-KS: Received coefficient ${TLWE_WORDS}/${TLWE_WORDS}"
if ! rg -q --fixed-strings "$req_coeff" "$CB_LOG"; then
  missing+=("$req_coeff")
fi

if [ "$SIM_RC" -ne 0 ]; then
  warn "quick_cb_test.sh failed (rc=$SIM_RC); see $RUN_LOG"
fi
if [ ${#missing[@]} -ne 0 ]; then
  printf "[oneclick][err] missing evidence:\n" >&2
  for pat in "${missing[@]}"; do
    printf "  - %s\n" "$pat" >&2
  done
  die "E2E control-path NOT closed"
fi

log "PASS: E2E control-path closed (doorbell -> COMPLETE -> host ACK)"
