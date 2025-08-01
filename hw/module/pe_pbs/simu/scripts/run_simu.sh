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

module="tb_wop_bit_extract_engine"

###################################################################################################
# Usage
###################################################################################################
function usage () {
echo "Usage : run_simu.sh runs all the simulations for ${module}."
echo "./run_simu.sh [options]"
echo "Options are:"
echo "-h                       : print this help."
echo "-n                       : Number of test iterations (default 5)"
echo "-- <run_edalize options> : run_edalize options."
}


###################################################################################################
# input arguments
###################################################################################################

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

NUM_ITERATIONS=5

# Initialize your own variables here:
while getopts "hn:" opt; do
  case "$opt" in
    h)
      usage
      exit 0
      ;;
    n)
      NUM_ITERATIONS=$OPTARG
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

for i in `seq 1 $NUM_ITERATIONS`; do
    # Randomize GLWE_K parameter
    GLWE_K=$((1+$RANDOM % 3))
    
    # Randomize MOD_Q_W (16, 32, 64)
    MOD_Q_W_VALS=(16 32 64)
    MOD_Q_W=${MOD_Q_W_VALS[$RANDOM % ${#MOD_Q_W_VALS[@]}]}
    
    # Randomize MAX_BIT_WIDTH (10-30)
    MAX_BIT_WIDTH=$((10+$RANDOM % 21))
    
    # Randomize N_LVL1 (common values: 512, 1024, 2048)
    N_LVL1_VALS=(512 1024 2048)
    N_LVL1=${N_LVL1_VALS[$RANDOM % ${#N_LVL1_VALS[@]}]}
    
    # Randomize LUT_ENTRY_SIZE (4096, 8192, 16384)
    LUT_SIZE_VALS=(4096 8192 16384)
    LUT_ENTRY_SIZE=${LUT_SIZE_VALS[$RANDOM % ${#LUT_SIZE_VALS[@]}]}
    
    # Randomize regfile parameters
    REGF_REG_NB=$((1+$RANDOM % 9))
    REGF_REG_NB=$((8*REGF_REG_NB))
    
    REGF_COEF_NB=$((1+$RANDOM % 4))
    REGF_COEF_NB=$((2**$REGF_COEF_NB))
    while [ $REGF_COEF_NB -gt $REGF_REG_NB ] ; do
      REGF_COEF_NB=$((1+$RANDOM % 4))
      REGF_COEF_NB=$((2**$REGF_COEF_NB))
    done
    
    REGF_SEQ=$(($RANDOM % 4))
    REGF_SEQ=$((2**$REGF_SEQ))
    while [ $REGF_SEQ -gt $REGF_COEF_NB ] ; do
      REGF_SEQ=$(($RANDOM % 4))
      REGF_SEQ=$((2**$REGF_SEQ))
    done

    cmd="${SCRIPT_DIR}/run.sh \
  -g $GLWE_K \
  -W $MOD_Q_W \
  -q "2**$MOD_Q_W" \
  -B $MAX_BIT_WIDTH \
  -N $N_LVL1 \
  -L $LUT_ENTRY_SIZE \
  -i $REGF_REG_NB \
  -j $REGF_COEF_NB \
  -k $REGF_SEQ \
  -- $args"

    echo "==========================================================="
    echo "INFO> Running iteration $i/$NUM_ITERATIONS"
    echo "INFO> Parameters: GLWE_K=$GLWE_K, MOD_Q_W=$MOD_Q_W, MAX_BIT_WIDTH=$MAX_BIT_WIDTH"
    echo "INFO>            N_LVL1=$N_LVL1, LUT_ENTRY_SIZE=$LUT_ENTRY_SIZE"
    echo "INFO>            REGF: ${REGF_REG_NB}x${REGF_COEF_NB}x${REGF_SEQ}"
    echo "INFO> Running : $cmd"
    echo "==========================================================="
    $cmd | tee >(grep "Seed" | head -1 >> $SEED_FILE) |  grep -c "> SUCCEED !" > $TMP_FILE
    exit_status=$?
    # In case of post processing, presence of several SUCCEED is necessary to be a real success
    succeed_cnt=$(cat $TMP_FILE)
    rm -f $TMP_FILE
    if [ $exit_status -gt 0 ] || [ $succeed_cnt -ne 1 ] ; then
      echo -e "${RED}FAILURE>${NC} $cmd" 1>&2
      exit $exit_status
    else
      echo -e "${GREEN}SUCCEED>${NC} $cmd" 1>&2
    fi
done

echo ""
echo "==========================================================="
echo -e "${GREEN}All $NUM_ITERATIONS tests completed successfully!${NC}"
echo "==========================================================="