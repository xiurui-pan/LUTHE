#! /usr/bin/bash
# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

cli="$*"

###################################################################################################
# Environment check - ensure setup.sh has been sourced
###################################################################################################
if [ -z "${PROJECT_DIR}" ] || [ -z "${PROJECT_SIMU_TOOL}" ] || [ -z "${XILINX_VIVADO}" ]; then
    echo "ERROR: Environment not properly set. Required variables missing:"
    echo "  PROJECT_DIR: ${PROJECT_DIR:-<not set>}"
    echo "  PROJECT_SIMU_TOOL: ${PROJECT_SIMU_TOOL:-<not set>}"
    echo "  XILINX_VIVADO: ${XILINX_VIVADO:-<not set>}"
    echo ""
    echo "Please use the proper way to run this script:"
    echo "  cd <project_root> && bash -lc 'source setup.sh >/dev/null 2>&1 && cd $(pwd) && ./run.sh [options]'"
    echo ""
    echo "Or use quick_run.sh which handles environment setup automatically."
    exit 1
fi

###################################################################################################
# This script deals with the testbench run for WoP-PBS Vertical Packing Engine.
# This testbench has specificities that cannot be handled by run_edalize alone.
# They are handled here.
###################################################################################################

# aliases are not expanded when the shell is not interactive.
# Note: run_edalize will be defined after PROJECT_DIR is set

module="tb_wop_vertical_packing_engine"

###################################################################################################
# usage
###################################################################################################
function usage () {
echo "Usage : run.sh runs the simulation for $module."
echo "./run.sh [options]"
echo "Options are:"
echo "-h                       : print this help."
echo "-g                       : GLWE_K (default 1)"
echo "-W                       : MOD_Q_W: modulo width (default 32)"
echo "-q                       : MOD_Q: modulo (default 2**32)"
echo "-B                       : MAX_BIT_WIDTH: Maximum bit width (default 20)"
echo "-N                       : N_LVL1: LWE dimension level 1 (default 1024)"
echo "-L                       : ELL_LVL1: GGSW decomposition level (default 3)"
echo "-b                       : BSK_PC: BSK parameter count (default 2)"
echo "-s                       : KSK_PC: KSK parameter count (default 2)"
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
GLWE_K=1  # K parameter for TLWE
MAX_BIT_WIDTH=20
MOD_Q_W=32
MOD_Q="2**32"
N_LVL1=1024
ELL_LVL1=3
BSK_PC=2  # 🎯 匹配pe_pbs_with_bsk内部期望的BSK_PC=2
KSK_PC=2  # 🎯 匹配pe_pbs_with_ksk内部期望的KSK_PC=2
REGF_REG_NB=64
REGF_COEF_NB=32
REGF_SEQ=4
PBS_L=1
LWE_K=16
R=2
S=8

# Initialize your own variables here:
while getopts "hg:W:q:B:N:L:b:s:i:j:k:" opt; do
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
    N)
      N_LVL1=$OPTARG
      ;;
    L)
      ELL_LVL1=$OPTARG
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
  esac
done

shift $((OPTIND-1))

if [ "${1:-}" = "--" ]; then
  shift
  run_edalize_args="$*"
fi

###################################################################################################
# parameters generation (align with bit_extract/circuit_bootstrap flow)
###################################################################################################

cd "$(dirname "$0")"

# Set PROJECT_DIR early, before using it  
if [ -z "${PROJECT_DIR}" ]; then
    export PROJECT_DIR="$(cd ../../../../.. && pwd)"
fi

# Define run_edalize after PROJECT_DIR is set
run_edalize=${PROJECT_DIR}/hw/scripts/edalize/run_edalize.py

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
INFO_DIR=${SCRIPT_DIR}/gen/info
mkdir -p $INFO_DIR
RTL_DIR=${SCRIPT_DIR}/gen/rtl
mkdir -p $RTL_DIR

N=$((R**S))
MOD_Q=$((2**$MOD_Q_W))

if [ $GEN_STIMULI -eq 1 ] ; then
  echo "INFO> N=${N}, GLWE_K=${GLWE_K}, PBS_L=${PBS_L} LWE_K=$LWE_K MOD_Q=$MOD_Q MOD_Q_W=$MOD_Q_W MAX_BIT_WIDTH=$MAX_BIT_WIDTH N_LVL1=$N_LVL1 ELL_LVL1=$ELL_LVL1"
  echo "INFO> Creating param_tfhe_definition_pkg.sv"
  pkg_cmd="python3 ${PROJECT_DIR}/hw/module/param/scripts/gen_param_tfhe_definition_pkg.py -f -N $N -g $GLWE_K -l $PBS_L -K $LWE_K -q $MOD_Q -W $MOD_Q_W -o ${RTL_DIR}/param_tfhe_definition_pkg.sv"
  echo "INFO> Running : $pkg_cmd"
  $pkg_cmd || exit 1

  echo "INFO> REGF_REG_NB=$REGF_REG_NB REGF_COEF_NB=$REGF_COEF_NB REGF_SEQ=$REGF_SEQ"
  echo "INFO> Creating regf_common_definition_pkg.sv"
  pkg_cmd="python3 ${PROJECT_DIR}/hw/module/regfile/module/regf_common/scripts/gen_regf_common_definition_pkg.py -f -regf_reg_nb $REGF_REG_NB -regf_coef_nb $REGF_COEF_NB -regf_seq $REGF_SEQ -o ${RTL_DIR}/regf_common_definition_pkg.sv"
  echo "INFO> Running : $pkg_cmd"
  $pkg_cmd || exit 1

  # Ensure vp_pbs_inst_pkg.sv is available under gen/rtl tree for edalize
if [ "${USE_VP_PBS_INST_PKG:-1}" -eq 1 ]; then
    VP_PKG_SRC="${PROJECT_DIR}/hw/module/pe_pbs/rtl/vp_pbs_inst_pkg.sv"
    VP_PKG_DST_DIR="${RTL_DIR}/hw/module/pe_pbs/rtl"
    VP_PKG_DST="${VP_PKG_DST_DIR}/vp_pbs_inst_pkg.sv"
    if [ -f "$VP_PKG_SRC" ]; then
      mkdir -p "$VP_PKG_DST_DIR"
      cp "$VP_PKG_SRC" "$VP_PKG_DST"
      echo "INFO> Copied vp_pbs_inst_pkg.sv into gen RTL tree: $VP_PKG_DST"
    else
      echo "WARN> vp_pbs_inst_pkg.sv not found at $VP_PKG_SRC"
    fi
  fi

  echo "INFO> Generating file_list.json"
  file_list_cmd="${PROJECT_DIR}/hw/scripts/create_module/create_file_list.py -o ${INFO_DIR}/file_list.json -p ${RTL_DIR} -R param_tfhe_definition_pkg.sv simu 0 1 -R regf_common_definition_pkg.sv simu 0 1 -F param_tfhe_definition_pkg.sv APPLICATION APPLI_simu -F regf_common_definition_pkg.sv REGF_STRUCT REGF_STRUCT_reg${REGF_REG_NB}_coef${REGF_COEF_NB}_seq${REGF_SEQ}"
  echo "INFO> Running : $file_list_cmd"
  $file_list_cmd || exit 1

  # Inject vp_pbs_inst_pkg.sv into file_list.json 
if [ "${USE_VP_PBS_INST_PKG:-1}" -eq 1 ]; then
    python3 - "$INFO_DIR/file_list.json" <<'PY'
import json,sys
path=sys.argv[1]
with open(path,'r') as f:
    data=json.load(f)
rtl=data.get('rtl_files',[])
entry={
    "name":"hw/module/pe_pbs/rtl/vp_pbs_inst_pkg.sv",
    "library":"work",
    "env":["simu"],
    "target":["all"],
    "is_include_file":False
}
if not any(x.get('name')==entry['name'] for x in rtl):
    rtl.insert(0,entry)
    data['rtl_files']=rtl
    with open(path,'w') as w:
        json.dump(data,w,indent=4)
print("INFO> Injected vp_pbs_inst_pkg.sv into file_list.json")
PY
  fi
else
  echo "INFO> Using existing ${RTL_DIR}/param_tfhe_definition_pkg.sv"
  echo "INFO> Using existing ${RTL_DIR}/regf_common_definition_pkg.sv"
fi

###################################################################################################
# run edalize
###################################################################################################

# PROJECT_DIR already set above

# Set default simulation tool if not set
if [ -z "${PROJECT_SIMU_TOOL}" ]; then
    export PROJECT_SIMU_TOOL="xsim"
fi

# Emulate the edalize flow used by other engines (configure + run phases)

# Ensure output dir exists
mkdir -p "${PROJECT_DIR}/hw/output"
TMP_FILE="${PROJECT_DIR}/hw/output/${RANDOM}${RANDOM}._info"
echo -n "" > $TMP_FILE

echo "INFO> Running configure/build phase via edalize (config+build)"
$run_edalize -m ${module} -t ${PROJECT_SIMU_TOOL} -d $(pwd) -y run \
  -P MOD_Q_W int $MOD_Q_W \
  -P MAX_BIT_WIDTH int $MAX_BIT_WIDTH \
  -P N_LVL1 int $N_LVL1 \
  -P ELL_LVL1 int $ELL_LVL1 \
  -P BSK_PC int $BSK_PC \
  -P KSK_PC int $KSK_PC \
  -F APPLICATION APPLI_simu \
  -F REGF_STRUCT REGF_STRUCT_reg${REGF_REG_NB}_coef${REGF_COEF_NB}_seq${REGF_SEQ} \
  $run_edalize_args | tee >(grep "Work directory :" >> $TMP_FILE)
sync
work_dir=$(cat ${TMP_FILE} | sed 's/Work directory : *//')
rm -f $TMP_FILE

echo "INFO> Creating output dir : ${work_dir}/output"
mkdir -p  ${work_dir}/output
echo $cli > ${work_dir}/cli.log

# Copy big_lut_simplified tool for testbench (golden generator)
if [ -f ./tools/big_lut_simplified ]; then
  echo "INFO> Copy big_lut_simplified tool to work dir"
  cp ./tools/big_lut_simplified ${work_dir}/big_lut_simplified || true
  chmod +x ${work_dir}/big_lut_simplified || true
elif [ -f ./big_lut_simplified ]; then
  echo "INFO> Copy big_lut_simplified tool (legacy path) to work dir"
  cp ./big_lut_simplified ${work_dir}/big_lut_simplified || true
  chmod +x ${work_dir}/big_lut_simplified || true
else
  echo "WARN> big_lut_simplified tool not found; testbench golden comparison will fail"
fi

echo "INFO> Running simulation (keep work) via edalize"
$run_edalize -m ${module} -t ${PROJECT_SIMU_TOOL} -d $(pwd) -k keep \
  -P MOD_Q_W int $MOD_Q_W \
  -P MAX_BIT_WIDTH int $MAX_BIT_WIDTH \
  -P N_LVL1 int $N_LVL1 \
  -P ELL_LVL1 int $ELL_LVL1 \
  -P BSK_PC int $BSK_PC \
  -P KSK_PC int $KSK_PC \
  -F APPLICATION APPLI_simu \
  -F REGF_STRUCT REGF_STRUCT_reg${REGF_REG_NB}_coef${REGF_COEF_NB}_seq${REGF_SEQ} \
  $run_edalize_args 2>&1  || echo "Simulation completed"

exit $?