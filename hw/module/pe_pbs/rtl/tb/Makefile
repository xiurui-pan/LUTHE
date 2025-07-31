# ==============================================================================================
# Makefile for WoP-PBS RTL Testbenches
# ----------------------------------------------------------------------------------------------
# Description:
#
# This Makefile provides targets for compiling and running all WoP-PBS testbenches.
# It uses Verilator for simulation and supports both individual module tests and full system tests.
#
# Author: Ray Pan 
# Date:   July 31, 2025
# ==============================================================================================

# Simulator settings
SIM = verilator
SIM_FLAGS = --cc --exe --build --trace --top-module
WAVE_FLAGS = --trace-fst --trace-structs
DPI_FLAGS = --vpi

# Source directories
RTL_DIR = ..
TB_DIR = .
BUILD_DIR = ./build
CPP_SRC_DIR = /home/pxr/workspace/tfhe-cpu-baseline-wopbs/src

# Common RTL files
COMMON_RTL = \
	wop_pbs_kernel.sv \
	wop_bit_extract_engine.sv \
	wop_circuit_bootstrap_woks_engine.sv \
	wop_vertical_packing_engine.sv \
	wop_premodswitch_engine.sv \
	wop_private_keyswitch_engine.sv

# Package files (assumed to exist)
PKG_FILES = \
	common_definition_pkg.sv \
	param_tfhe_pkg.sv \
	pep_if_pkg.sv \
	axi_if_glwe_axi_pkg.sv \
	axi_if_bsk_axi_pkg.sv \
	axi_if_ksk_axi_pkg.sv \
	bsk_mgr_common_param_pkg.sv \
	ksk_mgr_common_param_pkg.sv

# Test targets
TESTS = \
	test_bit_extract \
	test_premodswitch \
	test_circuit_bootstrap \
	test_vertical_packing \
	test_private_keyswitch \
	test_wop_pbs_kernel

# Default target
all: $(TESTS)

# Create build directory
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Individual test targets
test_bit_extract: $(BUILD_DIR)
	@echo "=== Testing Bit Extract Engine ==="
	cd $(BUILD_DIR) && $(SIM) $(SIM_FLAGS) tb_wop_bit_extract_engine $(WAVE_FLAGS) $(DPI_FLAGS) \
		-I$(RTL_DIR) -I$(CPP_SRC_DIR) \
		-CFLAGS "-I$(CPP_SRC_DIR) -std=c++17 -DVCD_TRACE" \
		-LDFLAGS "-lm -lcrypto" \
		$(TB_DIR)/tb_wop_bit_extract_engine.sv \
		$(RTL_DIR)/wop_bit_extract_engine.sv \
		$(TB_DIR)/tb_wop_bit_extract_engine.cpp \
		$(CPP_SRC_DIR)/bit_extract.cpp \
		$(CPP_SRC_DIR)/lwe_functions.cpp \
		$(CPP_SRC_DIR)/context.cpp
	cd $(BUILD_DIR) && ./Vtb_wop_bit_extract_engine

test_premodswitch: $(BUILD_DIR)
	@echo "=== Testing Pre-ModSwitch Engine ==="
	cd $(BUILD_DIR) && $(SIM) $(SIM_FLAGS) tb_wop_premodswitch_engine $(WAVE_FLAGS) $(DPI_FLAGS) \
		-I$(RTL_DIR) -I$(CPP_SRC_DIR) \
		-CFLAGS "-I$(CPP_SRC_DIR) -std=c++17 -DVCD_TRACE" \
		-LDFLAGS "-lm -lcrypto" \
		$(TB_DIR)/tb_wop_premodswitch_engine.sv \
		$(RTL_DIR)/wop_premodswitch_engine.sv \
		$(TB_DIR)/tb_wop_premodswitch_engine.cpp \
		$(CPP_SRC_DIR)/circuit_bootstrapping.cpp \
		$(CPP_SRC_DIR)/context.cpp
	cd $(BUILD_DIR) && ./Vtb_wop_premodswitch_engine

test_circuit_bootstrap: $(BUILD_DIR)
	@echo "=== Testing Circuit Bootstrap WoKS Engine ==="
	cd $(BUILD_DIR) && $(SIM) $(SIM_FLAGS) tb_wop_circuit_bootstrap_woks_engine $(WAVE_FLAGS) \
		-I$(RTL_DIR) -I$(CPP_SRC_DIR) \
		-CFLAGS "-I$(CPP_SRC_DIR) -std=c++17" \
		$(TB_DIR)/tb_wop_circuit_bootstrap_woks_engine.sv \
		$(RTL_DIR)/wop_circuit_bootstrap_woks_engine.sv \
		$(TB_DIR)/tb_wop_circuit_bootstrap_woks_engine.cpp \
		$(CPP_SRC_DIR)/circuit_bootstrapping.cpp \
		$(CPP_SRC_DIR)/context.cpp
	cd $(BUILD_DIR) && ./Vtb_wop_circuit_bootstrap_woks_engine

test_vertical_packing: $(BUILD_DIR)
	@echo "=== Testing Vertical Packing Engine ==="
	cd $(BUILD_DIR) && $(SIM) $(SIM_FLAGS) tb_wop_vertical_packing_engine $(WAVE_FLAGS) \
		-I$(RTL_DIR) -I$(CPP_SRC_DIR) \
		-CFLAGS "-I$(CPP_SRC_DIR) -std=c++17" \
		$(TB_DIR)/tb_wop_vertical_packing_engine.sv \
		$(RTL_DIR)/wop_vertical_packing_engine.sv \
		$(TB_DIR)/tb_wop_vertical_packing_engine.cpp \
		$(CPP_SRC_DIR)/big_lut.cpp \
		$(CPP_SRC_DIR)/context.cpp
	cd $(BUILD_DIR) && ./Vtb_wop_vertical_packing_engine

test_private_keyswitch: $(BUILD_DIR)
	@echo "=== Testing Private KeySwitch Engine ==="
	cd $(BUILD_DIR) && $(SIM) $(SIM_FLAGS) tb_wop_private_keyswitch_engine $(WAVE_FLAGS) \
		-I$(RTL_DIR) -I$(CPP_SRC_DIR) \
		-CFLAGS "-I$(CPP_SRC_DIR) -std=c++17" \
		$(TB_DIR)/tb_wop_private_keyswitch_engine.sv \
		$(RTL_DIR)/wop_private_keyswitch_engine.sv \
		$(TB_DIR)/tb_wop_private_keyswitch_engine.cpp \
		$(CPP_SRC_DIR)/circuit_bootstrapping.cpp \
		$(CPP_SRC_DIR)/context.cpp
	cd $(BUILD_DIR) && ./Vtb_wop_private_keyswitch_engine

test_wop_pbs_kernel: $(BUILD_DIR)
	@echo "=== Testing WoP-PBS Kernel (Full System) ==="
	cd $(BUILD_DIR) && $(SIM) $(SIM_FLAGS) tb_wop_pbs_kernel $(WAVE_FLAGS) \
		-I$(RTL_DIR) -I$(CPP_SRC_DIR) \
		-CFLAGS "-I$(CPP_SRC_DIR) -std=c++17" \
		$(TB_DIR)/tb_wop_pbs_kernel.sv \
		$(addprefix $(RTL_DIR)/,$(COMMON_RTL)) \
		$(TB_DIR)/tb_wop_pbs_kernel.cpp \
		$(CPP_SRC_DIR)/bit_extract.cpp \
		$(CPP_SRC_DIR)/circuit_bootstrapping.cpp \
		$(CPP_SRC_DIR)/big_lut.cpp \
		$(CPP_SRC_DIR)/context.cpp \
		$(CPP_SRC_DIR)/lwe_functions.cpp
	cd $(BUILD_DIR) && ./Vtb_wop_pbs_kernel

# Lint all RTL files
lint:
	@echo "=== Linting RTL Files ==="
	verilator --lint-only -I$(RTL_DIR) $(addprefix $(RTL_DIR)/,$(COMMON_RTL))

# Generate synthesis reports (if synthesis tools are available)
synth:
	@echo "=== Synthesis Analysis ==="
	@echo "Synthesis tools not configured. Skipping..."

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	rm -f *.vcd *.fst *.log

# Generate code coverage report
coverage: test_wop_pbs_kernel
	@echo "=== Code Coverage Analysis ==="
	cd $(BUILD_DIR) && verilator_coverage --annotate coverage_report logs/coverage.dat
	@echo "Coverage report generated in $(BUILD_DIR)/coverage_report/"

# Performance analysis
perf: test_wop_pbs_kernel
	@echo "=== Performance Analysis ==="
	@echo "Analyzing simulation performance..."
	cd $(BUILD_DIR) && time ./Vtb_wop_pbs_kernel

# Run all tests with summary
test_all: $(TESTS)
	@echo ""
	@echo "=== Test Summary ==="
	@echo "All WoP-PBS tests completed successfully!"
	@echo ""
	@echo "Test Results:"
	@echo "  ✅ Bit Extract Engine"
	@echo "  ✅ Pre-ModSwitch Engine" 
	@echo "  ✅ Circuit Bootstrap WoKS Engine"
	@echo "  ✅ Vertical Packing Engine"
	@echo "  ✅ Private KeySwitch Engine"
	@echo "  ✅ WoP-PBS Kernel (Full System)"
	@echo ""

# Debug target - run with GDB
debug_kernel: $(BUILD_DIR)
	cd $(BUILD_DIR) && $(SIM) $(SIM_FLAGS) tb_wop_pbs_kernel --gdb $(WAVE_FLAGS) \
		-I$(RTL_DIR) \
		$(RTL_DIR)/tb_wop_pbs_kernel.sv \
		$(addprefix $(RTL_DIR)/,$(COMMON_RTL)) \
		$(RTL_DIR)/tb_wop_pbs_kernel.cpp
	cd $(BUILD_DIR) && gdb ./Vtb_wop_pbs_kernel

# Generate waveforms for specific test
waves_%: test_%
	@echo "Waveforms generated for $* test"
	@echo "Open $(BUILD_DIR)/tb_wop_$*.fst with GTKWave"

# Help target
help:
	@echo "WoP-PBS RTL Testbench Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  all              - Run all tests"
	@echo "  test_all         - Run all tests with summary"
	@echo "  test_<module>    - Run specific module test"
	@echo "  lint             - Lint all RTL files"
	@echo "  synth            - Run synthesis analysis"
	@echo "  coverage         - Generate code coverage report"
	@echo "  perf             - Run performance analysis"
	@echo "  debug_kernel     - Debug kernel test with GDB"
	@echo "  waves_<module>   - Generate waveforms for module test"
	@echo "  clean            - Clean build artifacts"
	@echo "  help             - Show this help"
	@echo ""
	@echo "Individual test targets:"
	@echo "  test_bit_extract"
	@echo "  test_premodswitch"
	@echo "  test_circuit_bootstrap"
	@echo "  test_vertical_packing"
	@echo "  test_private_keyswitch"
	@echo "  test_wop_pbs_kernel"

# Phony targets
.PHONY: all clean lint synth coverage perf test_all help debug_kernel $(TESTS)