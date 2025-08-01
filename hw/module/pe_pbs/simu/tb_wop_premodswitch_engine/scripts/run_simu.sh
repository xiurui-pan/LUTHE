#! /usr/bin/bash
# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

run_edalize=${PROJECT_DIR}/hw/scripts/edalize/run_edalize.py

RED='\033[1;31m'
GREEN='\033[1;32m'
NC='\033[0m'

module="tb_wop_premodswitch_engine"

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
    
    # Randomize N_LVL0 (common values: 630, 512, 1024)
    N_LVL0_VALS=(630 512 1024)
    N_LVL0=${N_LVL0_VALS[$RANDOM % ${#N_LVL0_VALS[@]}]}
    
    # Randomize N_LVL2 (common values: 2048, 1024, 4096)
    N_LVL2_VALS=(1024 2048 4096)
    N_LVL2=${N_LVL2_VALS[$RANDOM % ${#N_LVL2_VALS[@]}]}
    
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
  -0 $N_LVL0 \
  -2 $N_LVL2 \
  -i $REGF_REG_NB \
  -j $REGF_COEF_NB \
  -k $REGF_SEQ \
  -- $args"

    echo "==========================================================="
    echo "INFO> Running iteration $i/$NUM_ITERATIONS"
    echo "INFO> Parameters: GLWE_K=$GLWE_K, MOD_Q_W=$MOD_Q_W"
    echo "INFO>            N_LVL0=$N_LVL0, N_LVL2=$N_LVL2"
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