#!/bin/bash

# ==============================================================================================
# Filename: run_tests.sh
# ----------------------------------------------------------------------------------------------
# Description:
#
# Script to run all WoP-PBS testbenches and generate reports.
# This script provides a convenient way to run the complete test suite.
#
# Author: Ray Pan 
# Date:   July 31, 2025
# ==============================================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v verilator &> /dev/null; then
        log_error "Verilator not found. Please install Verilator."
        exit 1
    fi
    
    if ! command -v make &> /dev/null; then
        log_error "Make not found. Please install Make."
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Run a single test
run_test() {
    local test_name=$1
    local test_target=$2
    
    log_info "Running $test_name..."
    
    if make $test_target 2>&1 | tee logs/${test_name}.log; then
        log_success "$test_name PASSED"
        return 0
    else
        log_error "$test_name FAILED"
        return 1
    fi
}

# Main function
main() {
    log_info "Starting WoP-PBS RTL Test Suite"
    echo "=========================================="
    
    # Create logs directory
    mkdir -p logs
    
    # Check prerequisites
    check_prerequisites
    
    # Clean previous builds
    log_info "Cleaning previous builds..."
    make clean > /dev/null 2>&1 || true
    
    # Test results tracking
    declare -a test_results
    total_tests=0
    passed_tests=0
    
    # Define tests to run
    declare -A tests=(
        ["Bit Extract Engine"]="test_bit_extract"
        ["Pre-ModSwitch Engine"]="test_premodswitch"
        ["Circuit Bootstrap WoKS Engine"]="test_circuit_bootstrap"
        ["WoP-PBS Kernel (Full System)"]="test_wop_pbs_kernel"
    )
    
    # Run all tests
    for test_name in "${!tests[@]}"; do
        test_target=${tests[$test_name]}
        total_tests=$((total_tests + 1))
        
        echo ""
        echo "=========================================="
        log_info "Test $total_tests: $test_name"
        echo "=========================================="
        
        if run_test "$test_name" "$test_target"; then
            test_results+=("✅ $test_name")
            passed_tests=$((passed_tests + 1))
        else
            test_results+=("❌ $test_name")
        fi
    done
    
    # Run lint check
    echo ""
    echo "=========================================="
    log_info "Running Lint Check"
    echo "=========================================="
    
    if make lint 2>&1 | tee logs/lint.log; then
        log_success "Lint check PASSED"
        test_results+=("✅ Lint Check")
        passed_tests=$((passed_tests + 1))
    else
        log_error "Lint check FAILED"
        test_results+=("❌ Lint Check")
    fi
    total_tests=$((total_tests + 1))
    
    # Generate summary report
    echo ""
    echo "=========================================="
    log_info "Test Summary Report"
    echo "=========================================="
    
    for result in "${test_results[@]}"; do
        echo "$result"
    done
    
    echo ""
    echo "Total Tests: $total_tests"
    echo "Passed: $passed_tests"
    echo "Failed: $((total_tests - passed_tests))"
    
    if [ $passed_tests -eq $total_tests ]; then
        log_success "🎉 ALL TESTS PASSED! WoP-PBS implementation is ready!"
        
        # Generate coverage report if available
        if command -v verilator_coverage &> /dev/null; then
            log_info "Generating coverage report..."
            make coverage 2>&1 | tee logs/coverage.log || true
        fi
        
        exit 0
    else
        log_error "Some tests failed. Please check the logs in the logs/ directory."
        exit 1
    fi
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "WoP-PBS RTL Test Suite Runner"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --quick, -q    Run quick tests only (skip system test)"
        echo "  --verbose, -v  Enable verbose output"
        echo ""
        echo "Examples:"
        echo "  $0                Run all tests"
        echo "  $0 --quick       Run quick tests only"
        echo "  $0 --verbose     Run with verbose output"
        exit 0
        ;;
    --quick|-q)
        log_info "Running quick tests only..."
        # Remove system test from the list
        unset tests["WoP-PBS Kernel (Full System)"]
        ;;
    --verbose|-v)
        set -x  # Enable verbose mode
        ;;
esac

# Run main function
main "$@"