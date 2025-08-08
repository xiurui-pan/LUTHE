#! /usr/bin/bash
# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

cli="$*"

###################################################################################################
# This script deals with the testbench run for WoP-PBS circuit bootstrap WoKS engine.
# This testbench has specificities that cannot be handled by run_edalize alone.
# They are handled here.
###################################################################################################

# aliases are not expanded when the shell is not interactive.
# Redefine here for more clarity
run_edalize=${PROJECT_DIR}/hw/scripts/edalize/run_edalize.py

module="tb_wop_circuit_bootstrap_woks_engine"

###################################################################################################
# usage
###################################################################################################
function usage () {
echo "Usage : run.sh runs the simulation for $module."
echo "./run.sh [options]"
echo "Options are:"
echo "-h                       : print this help."
echo "-g                       : GLWE_K (default 2)"
echo "-W                       : MOD_Q_W: modulo width (default 64)"
echo "-q                       : MOD_Q: modulo (default 2**32)"
echo "-0                       : N_LVL0: LWE dimension level 0 (default 630)"
echo "-2                       : N_LVL2: LWE dimension level 2 (default 2048)"
echo "-E                       : ELL_LVL2: Ell parameter level 2 (default 8)"
echo "-K                       : K parameter (default 1)"
echo "-P                       : PSI parameter (default 1)"
echo "-R                       : R: Radix (default 8)"
echo "-i                       : Regfile number of registers (default 64)"
echo "-j                       : Regfile number of coefficients (default 32)"
echo "-k                       : Regfile number of sequences (default 4)"
echo "-- <run_edalize options> : run_edalize options."
echo "--real                   : use real NTT head in TB (USE_REAL_CORES=1)"

}

###################################################################################################
# input arguments
###################################################################################################

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

run_edalize_args=""
GEN_STIMULI=1
GLWE_K=2
PBS_L=1
R=8
S=8
MOD_Q_W=64
MOD_Q="2**32"
N_LVL0=630
N_LVL2=2048
ELL_LVL2=8
K_PARAM=1
PSI=1
LWE_K=4
REGF_REG_NB=64
REGF_COEF_NB=32
REGF_SEQ=4

# Initialize your own variables here:
USE_REAL=0
while getopts "hzg:W:0:2:E:K:P:R:i:j:k:q:-:" opt; do
  case "$opt" in
    h)
      usage
      exit 0
      ;;
    g)
      GLWE_K=$OPTARG
      ;;
    W)
      MOD_Q_W=$OPTARG
      ;;
    q)
      MOD_Q=$OPTARG
      ;;
    -)
      case "$OPTARG" in
        real)
          USE_REAL=1
          ;;
        *)
          echo "Invalid long option: --$OPTARG"
          exit 1
          ;;
      esac
      ;;
    0)
      N_LVL0=$OPTARG
      ;;
    2)
      N_LVL2=$OPTARG
      ;;
    E)
      ELL_LVL2=$OPTARG
      ;;
    K)
      K_PARAM=$OPTARG
      ;;
    P)
      PSI=$OPTARG
      ;;
    R)
      R=$OPTARG
      ;;
    i)
      REGF_REG_NB=$OPTARG
      ;;
    j)
      REGF_COEF_NB=$OPTARG
      ;;
    k)
      REGF_SEQ=$OPTARG
      ;;
    z)
      echo "Do not generate stimuli."
      GEN_STIMULI=0
      ;;
    :)
      echo "$0: Must supply an argument to -$OPTARG." >&2
      exit 1
      ;;
    ?)
      echo "Invalid option: -${OPTARG}."
      exit 1
      ;;
  esac
done

shift $((OPTIND-1))

# run_edalize additional arguments
[ "${1:-}" = "--" ] && shift
args=$@

N=$((R**S))
MOD_Q=$((2**$MOD_Q_W))

###################################################################################################
# Generate package
###################################################################################################
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

INFO_DIR=${SCRIPT_DIR}/../gen/info
mkdir -p $INFO_DIR
RTL_DIR=${SCRIPT_DIR}/../gen/rtl
mkdir -p $RTL_DIR

# Create package
if [ $GEN_STIMULI -eq 1 ] ; then
  pkg_cmd="python3 ${PROJECT_DIR}/hw/module/param/scripts/gen_param_tfhe_definition_pkg.py -f -N $N -g $GLWE_K -l $PBS_L -K $LWE_K \
           -q $MOD_Q -W $MOD_Q_W -o ${RTL_DIR}/param_tfhe_definition_pkg.sv"
  echo "INFO> N=${N}, GLWE_K=${GLWE_K}, PBS_L=${PBS_L} LWE_K=$LWE_K MOD_Q=$MOD_Q MOD_Q_W=$MOD_Q_W"
  echo "INFO> N_LVL0=$N_LVL0 N_LVL2=$N_LVL2 ELL_LVL2=$ELL_LVL2 K=$K_PARAM PSI=$PSI R=$R"
  echo "INFO> Creating param_tfhe_definition_pkg.sv"
  echo "INFO> Running : $pkg_cmd"
  $pkg_cmd || exit 1

  pkg_cmd="python3 ${PROJECT_DIR}/hw/module/regfile/module/regf_common/scripts/gen_regf_common_definition_pkg.py -f \
          -regf_reg_nb $REGF_REG_NB -regf_coef_nb $REGF_COEF_NB -regf_seq $REGF_SEQ -o ${RTL_DIR}/regf_common_definition_pkg.sv"
  echo "INFO> REGF_REG_NB=$REGF_REG_NB REGF_COEF_NB=$REGF_COEF_NB REGF_SEQ=$REGF_SEQ"
  echo "INFO> Creating regf_common_definition_pkg.sv"
  echo "INFO> Running : $pkg_cmd"
  $pkg_cmd || exit 1

  # Create the associated file_list.json
  echo ""
  file_list_cmd="${PROJECT_DIR}/hw/scripts/create_module/create_file_list.py\
                -o ${INFO_DIR}/file_list.json \
                -p ${RTL_DIR} \
                -R param_tfhe_definition_pkg.sv simu 0 1 \
                -R regf_common_definition_pkg.sv simu 0 1 \
                -F param_tfhe_definition_pkg.sv APPLICATION APPLI_simu \
                -F regf_common_definition_pkg.sv REGF_STRUCT REGF_STRUCT_reg${REGF_REG_NB}_coef${REGF_COEF_NB}_seq${REGF_SEQ}"
  echo "INFO> Running : $file_list_cmd"
  $file_list_cmd || exit 1

  echo ""

else
  echo "INFO> Using existing ${RTL_DIR}/param_tfhe_definition_pkg.sv"
  echo "INFO> Using existing ${RTL_DIR}/regf_common_definition_pkg.sv"
fi

eda_args=""

eda_args="$eda_args \
            -P MOD_Q_W int $MOD_Q_W \
            -P N_LVL0 int $N_LVL0 \
            -P N_LVL2 int $N_LVL2 \
            -P ELL_LVL2 int $ELL_LVL2 \
            -P K int $K_PARAM \
            -P PSI int $PSI \
            -P R int $R \
            -F APPLICATION APPLI_simu \
            -F REGF_STRUCT REGF_STRUCT_reg${REGF_REG_NB}_coef${REGF_COEF_NB}_seq${REGF_SEQ}"

# Enable real NTT/BSK head if requested
if [ $USE_REAL -eq 1 ]; then
  eda_args="$eda_args -P USE_REAL_CORES int 1"
  echo "INFO> USE_REAL_CORES=1 (real NTT head enabled)"
fi

###################################################################################################
# Run_edalize configure
###################################################################################################
mkdir -p "${PROJECT_DIR}/hw/output"
TMP_FILE="${PROJECT_DIR}/hw/output/${RANDOM}${RANDOM}._info"
echo -n "" > $TMP_FILE

$run_edalize -m ${module} -t ${PROJECT_SIMU_TOOL} -y run -y build \
  $eda_args \
  $args | tee >(grep "Work directory :" >> $TMP_FILE)
sync
work_dir=$(cat ${TMP_FILE} | sed 's/Work directory : *//')

# Delete TMP_FILE
rm -f $TMP_FILE

# create output dir
echo "INFO> Creating output dir : ${work_dir}/output"
mkdir -p  ${work_dir}/output

# log command line
echo $cli > ${work_dir}/cli.log

###################################################################################################
# Run phase : simulation
###################################################################################################
LOG_TS=$(date +%Y%m%d_%H%M%S)
OUT_LOG="${work_dir}/output/${module}_${LOG_TS}.log"
echo "INFO> Logging simulator output to: ${OUT_LOG}"

# Run simulation, save full log, and print only key lines to console
$run_edalize -m ${module} -t ${PROJECT_SIMU_TOOL} -k keep $eda_args $args 2>&1 \
  | tee ${OUT_LOG} \
  | grep -v "WARNING>" \
  | egrep -i "TEST STATUS|TEST PASSED|TEST FAILED|TIMEOUT|\\[TB_|Circuit bootstrap|Starting|completed|Result|SAMPLE_EXTRACT|^ERROR:|^FATAL:" || true