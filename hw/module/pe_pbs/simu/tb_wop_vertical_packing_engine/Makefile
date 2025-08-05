# ==============================================================================================
# Makefile for WoP-PBS Vertical Packing Engine Testbench
# ==============================================================================================

# Directories
RTL_DIR = rtl
SCRIPTS_DIR = scripts
GEN_DIR = gen
PROJECT_ROOT = ../../../../..

# Files
TOP_MODULE = tb_wop_vertical_packing_engine
DUT_FILE = $(PROJECT_ROOT)/hw/module/pe_pbs/rtl/wop_vertical_packing_engine.sv
TB_FILE = $(RTL_DIR)/$(TOP_MODULE).sv
GOLDEN_FILE = $(SCRIPTS_DIR)/vertical_packing_golden.cpp

# Include paths
INC_PATHS = -I$(PROJECT_ROOT)/hw/common/common_definition \
            -I$(PROJECT_ROOT)/hw/common/param_tfhe \
            -I$(PROJECT_ROOT)/hw/common/regf_common_param \
            -I$(PROJECT_ROOT)/hw/common/axi_if_glwe_axi \
            -I$(GEN_DIR)

# SystemVerilog files
SV_FILES = $(DUT_FILE) $(TB_FILE) \
           $(GEN_DIR)/param_tfhe_definition_pkg.sv \
           $(GEN_DIR)/regf_common_definition_pkg.sv

# Compilation flags
XVLOG_FLAGS = --sv --relax $(INC_PATHS)
XELAB_FLAGS = --debug typical --mt auto --relax
XSIM_FLAGS = --runall

# Targets
.PHONY: all compile elaborate run clean help

all: run

compile:
	@echo "Compiling SystemVerilog files..."
	xvlog $(XVLOG_FLAGS) $(SV_FILES)

elaborate: compile
	@echo "Elaborating design..."
	xelab $(XELAB_FLAGS) -top $(TOP_MODULE) -snapshot $(TOP_MODULE)

run: elaborate
	@echo "Running simulation..."
	xsim $(XSIM_FLAGS) $(TOP_MODULE) 2>&1 | grep -E "(GOLDEN|TB|VP_ENGINE|ERROR|SUCCESS|FAILURE|Fatal|Error)" | grep -v -E "(INFO:|WARNING:)"

clean:
	@echo "Cleaning build files..."
	rm -rf xsim.dir
	rm -f xsim.log
	rm -f *.wdb
	rm -f *.jou
	rm -f webtalk*.log
	rm -f webtalk*.jou
	rm -f vivado*.log
	rm -f vivado*.jou

help:
	@echo "Available targets:"
	@echo "  all      - Compile, elaborate, and run simulation (default)"
	@echo "  compile  - Compile SystemVerilog files"
	@echo "  elaborate- Elaborate design"
	@echo "  run      - Run simulation"
	@echo "  clean    - Clean build files"
	@echo "  help     - Show this help message"