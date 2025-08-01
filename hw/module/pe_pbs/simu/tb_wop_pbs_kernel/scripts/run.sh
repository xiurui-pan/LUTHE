#! /usr/bin/bash
# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

cli="$*"

###################################################################################################
# This script deals with the testbench run for WoP-PBS kernel (complete system).
# This testbench has specificities that cannot be handled by run_edalize alone.
# They are handled here.
###################################################################################################

# aliases are not expanded when the shell is not interactive.
# Redefine here for more clarity
run_edalize=${PROJECT_DIR}/hw/scripts/edalize/run_edalize.py

module="tb_wop_pbs_kernel"

###################################################################################################
# usage
###################################################################################################
function usage () {
echo "Usage : run.sh runs the simulation for $module."
echo "./run.sh [options]"
echo "Options are:"
echo "-h                       : print this help."
echo "-g                       : GLWE_K (default 2)"
echo "-W                       : MOD_Q_W: modulo width (default 32)"
echo "-q                       : MOD_Q: modulo (default 2**32)"
echo "-B                       : MAX_BIT_WIDTH: Maximum bit width (default 20)"
echo "-0                       : N_LVL0: LWE dimension level 0 (default 630)"
echo "-1                       : N_LVL1: LWE dimension level 1 (default 1024)"
echo "-2                       : N_LVL2: LWE dimension level 2 (default 2048)"
echo "-e                       : ELL_LVL1: Ell parameter level 1 (default 3)"
echo "-E                       : ELL_LVL2: Ell parameter level 2 (default 8)"
echo "-K                       : K parameter (default 1)"
echo "-P                       : PSI parameter (default 1)"
echo "-R                       : R: Radix (default 8)"
echo "-b                       : BSK_PC: BSK parameter count (default 4)"
echo "-s                       : KSK_PC: KSK parameter count (default 4)"
echo "-i                       : Regfile number of registers (default 64)"
echo "-j                       : Regfile number of coefficients (default 32)"
echo "-k                       : Regfile number of sequences (default 4)"
echo "-- <run_edalize options> : run_edalize options."

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
MOD_Q_W=32
MOD_Q="2**32"
MAX_BIT_WIDTH=20
N_LVL0=630
N_LVL1=1024
N_LVL2=2048
ELL_LVL1=3
ELL_LVL2=8
K_PARAM=1
PSI=1
BSK_PC=4
KSK_PC=4
LWE_K=4
REGF_REG_NB=64
REGF_COEF_NB=32
REGF_SEQ=4

# Initialize your own variables here:
while getopts "hzg:W:B:0:1:2:e:E:K:P:R:b:s:i:j:k:q:" opt; do
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
    B)
      MAX_BIT_WIDTH=$OPTARG
      ;;
    0)
      N_LVL0=$OPTARG
      ;;
    1)
      N_LVL1=$OPTARG
      ;;
    2)
      N_LVL2=$OPTARG
      ;;
    e)
      ELL_LVL1=$OPTARG
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
    b)
      BSK_PC=$OPTARG
      ;;
    s)
      KSK_PC=$OPTARG
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
  echo "INFO> MAX_BIT_WIDTH=$MAX_BIT_WIDTH N_LVL0=$N_LVL0 N_LVL1=$N_LVL1 N_LVL2=$N_LVL2"
  echo "INFO> ELL_LVL1=$ELL_LVL1 ELL_LVL2=$ELL_LVL2 K=$K_PARAM PSI=$PSI R=$R BSK_PC=$BSK_PC KSK_PC=$KSK_PC"
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
            -P MAX_BIT_WIDTH int $MAX_BIT_WIDTH \
            -P N_LVL0 int $N_LVL0 \
            -P N_LVL1 int $N_LVL1 \
            -P N_LVL2 int $N_LVL2 \
            -P ELL_LVL1 int $ELL_LVL1 \
            -P ELL_LVL2 int $ELL_LVL2 \
            -P K int $K_PARAM \
            -P PSI int $PSI \
            -P R int $R \
            -P BSK_PC int $BSK_PC \
            -P KSK_PC int $KSK_PC \
            -F APPLICATION APPLI_simu \
            -F REGF_STRUCT REGF_STRUCT_reg${REGF_REG_NB}_coef${REGF_COEF_NB}_seq${REGF_SEQ}"

###################################################################################################
# Run_edalize configure
###################################################################################################
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
$run_edalize -m ${module} -t ${PROJECT_SIMU_TOOL} -k keep $eda_args $args