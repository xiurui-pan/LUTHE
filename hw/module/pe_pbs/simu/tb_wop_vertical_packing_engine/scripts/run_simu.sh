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

module="tb_wop_vertical_packing_engine"

###################################################################################################
# Usage
###################################################################################################
function usage () {
echo "Usage : run_simu.sh runs all the simulations for ${module}."
echo "./run_simu.sh [options]"
echo "Options are:"
echo "-h                       : print this help."
echo "-n                       : Number of test iterations (default 3)"
echo "-- <run_edalize options> : run_edalize options."
}


###################################################################################################
# input arguments
###################################################################################################

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

NUM_ITERATIONS=3

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

if [ "${1:-}" = "--" ]; then
  shift
  run_edalize_args="$*"
fi

###################################################################################################
# Run tests
###################################################################################################

cd "$(dirname "$0")/.."

# Set PROJECT_DIR if not set
if [ -z "${PROJECT_DIR}" ]; then
    export PROJECT_DIR="$(cd ../../../.. && pwd)"
fi

echo "========================================"
echo "  WoP Vertical Packing Engine Test Suite"
echo "========================================"
echo "Running $NUM_ITERATIONS test iterations..."

total_tests=0
passed_tests=0

for i in $(seq 1 $NUM_ITERATIONS); do
    echo ""
    echo "----------------------------------------"
    echo "Test iteration $i/$NUM_ITERATIONS"
    echo "----------------------------------------"
    
    total_tests=$((total_tests + 1))
    
    # Run the test with different parameters for diversity
    case $i in
        1)
            # Default parameters
            test_params=""
            echo "Running with default parameters..."
            ;;
        2) 
            # Different bit width if supported
            test_params="-B 16"
            echo "Running with MAX_BIT_WIDTH=16..."
            ;;
        3)
            # Different N_LVL1 if supported  
            test_params="-N 512"
            echo "Running with N_LVL1=512..."
            ;;
        *)
            # Random parameters for additional iterations
            test_params=""
            echo "Running with default parameters (iteration $i)..."
            ;;
    esac
    
    # Run the test
    if timeout 300 ./run.sh $test_params $run_edalize_args 2>&1 | grep -E "(SUCCESS|ERROR|FAILURE|Fatal|Error|\[GOLDEN\]|\[TB\]|\[VP_ENGINE\])" | grep -v -E "(INFO:|WARNING:)"; then
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo -e "${GREEN}✅ Test iteration $i PASSED${NC}"
            passed_tests=$((passed_tests + 1))
        else
            echo -e "${RED}❌ Test iteration $i FAILED (timeout or execution error)${NC}"
        fi
    else
        echo -e "${RED}❌ Test iteration $i FAILED (no success indicators found)${NC}"
    fi
    
    # Clean up between tests
    rm -rf build_* xsim.dir *.log *.jou 2>/dev/null || true
done

echo ""
echo "========================================"
echo "  Test Suite Summary"
echo "========================================"
echo "Total tests: $total_tests"
echo "Passed: $passed_tests"
echo "Failed: $((total_tests - passed_tests))"

if [ $passed_tests -eq $total_tests ]; then
    echo -e "${GREEN}🎉 ALL TESTS PASSED!${NC}"
    exit 0
else
    echo -e "${RED}💥 Some tests failed!${NC}"
    exit 1
fi