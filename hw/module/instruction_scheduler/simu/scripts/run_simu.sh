#! /usr/bin/bash
# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.
#
# aliases are not expanded when the shell is not interactive.
# Redefine here for more clarity

run_edalize=${PROJECT_DIR}/hw/scripts/edalize/run_edalize.py

RED='\033[1;31m'
GREEN='\033[1;32m'
NC='\033[0m'

module="tb_instruction_scheduler"

###################################################################################################
# Usage
###################################################################################################
function usage () {
echo "Usage : run_simu.sh runs all the simulations for ${module}."
echo "./run_simu.sh [options]"
echo "Options are:"
echo "-h                       : print this help."
echo "-- <run_edalize options> : run_edalize options."
}


###################################################################################################
# input arguments
###################################################################################################

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

# Initialize your own variables here:
while getopts "h" opt; do
  case "$opt" in
    h)
      usage
      exit 0
      ;;
  esac
done

shift $((OPTIND-1))

[ "${1:-}" = "--" ] && shift
args=$@


###################################################################################################
# Run simulation
###################################################################################################
# Write simulation command lines here
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
mkdir -p ${PROJECT_DIR}/hw/output
SEED_FILE="${PROJECT_DIR}/hw/output/${module}.seed"
TMP_FILE="${PROJECT_DIR}/hw/output/${RANDOM}${RANDOM}._tmp"
echo -n "" > $SEED_FILE
echo -n "" > $TMP_FILE

# IOP_NAME_L=("ADD" "SUB" "MUL" "BW_AND" "BW_OR" "BW_XOR" "CMP_GT" "CMP_GTE" "CMP_LT" "CMP_LTE" "CMP_EQ" "CMP_NEQ")
# IOP_WIDTH_L=(4 8 16)
# PBS_W_MAX=16
IOP_LIST=("ADD" "SUB" "MUL")
IOP_WIDTH=20 # 固定操作数位宽为16位，以进行公平比较
PBS_WIDTH=10  # 固定PBS位宽
USE_BPIP=1   # 固定BPIP设置

# for ((j = 0; j < 1; j++)); do
#   iop_name_size=${#IOP_NAME_L[@]}
#   iop_width_size=${#IOP_WIDTH_L[@]}
#   iop_name_index=$(($RANDOM % $iop_name_size))
#   iop_width_index=$(($RANDOM % $iop_width_size))
#   iop_asm="${IOP_NAME_L[$iop_name_index]} @[0]0x00 @[0]0x40 @[0]0x80"
#   iop_w=${IOP_WIDTH_L[$iop_width_index]}
#   pbs_w=$(( $(($RANDOM % $(($PBS_W_MAX - 1)))) + 1))
#   use_bpip=$(($RANDOM % 2))

#   cmd="${SCRIPT_DIR}/run.sh \
#                   -I \"${iop_asm}\" \
#                   -W ${iop_w} \
#                   -P ${pbs_w} \
#                   -B ${use_bpip} \
#                   -- $args"
for iop_name in "${IOP_LIST[@]}"; do
  # 使用固定的寄存器ID构建指令
  iop_asm="${iop_name} @[0]0x00 @[0]0x40 @[0]0x80"

  cmd="${SCRIPT_DIR}/run.sh \
           -I \"${iop_asm}\" \
           -W ${IOP_WIDTH} \
           -P ${PBS_WIDTH} \
           -B ${USE_BPIP} \
           -- $args"
  echo "==========================================================="
  echo "INFO> Running : $cmd"
  echo "==========================================================="
  # echo ${cmd}| sh | tee >(grep "Seed" | head -1 >> $SEED_FILE) |  grep -c "> SUCCEED !" > $TMP_FILE
  # eval $cmd 2>&1 | tee >(grep "Seed" | head -1 >> $SEED_FILE) |  grep -c "> SUCCEED !" > $TMP_FILE
  eval $cmd >> log.log
  exit_status=$?
  succeed_cnt=$(cat $TMP_FILE)
  rm -f $TMP_FILE
  if [ $exit_status -gt 0 ] || [ $succeed_cnt -ne 1 ] ; then
    echo -e "${RED}FAILURE>${NC} $cmd" 1>&2
    exit $exit_status
  else
    echo -e "${GREEN}SUCCEED>${NC} $cmd" 1>&2
  fi
done

