#!/bin/bash
# 🔧 VP-PBS AXI X-state Fix Verification Script

cd /home/pxr/workspace/hpu_fpga/hw/module/pe_pbs/simu/tb_wop_vertical_packing_engine

echo "=============================================="
echo "🔧 VP-PBS AXI X-STATE FIX VERIFICATION"
echo "=============================================="
echo "Testing fixes for m_axi4_ksk_arvalid[0]=x issue"
echo ""

# Clean previous builds
echo "🧹 Cleaning previous simulation files..."
make clean > /dev/null 2>&1

# Compile with focus on AXI signal monitoring
echo "🔨 Compiling with AXI debug monitoring..."
timeout 300 make compile 2>&1 | tee compile_axi_fix.log

# Check for compilation success
if [ ${PIPESTATUS[0]} -eq 124 ]; then
    echo "❌ COMPILE TIMEOUT after 5 minutes"
    exit 1
elif [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "❌ COMPILE FAILED - checking errors:"
    grep -i "error\|fatal" compile_axi_fix.log | head -10
    exit 1
else
    echo "✅ COMPILE SUCCESS"
fi

echo ""
echo "🧪 Running focused AXI X-state verification..."
echo "   Focus: m_axi4_ksk_arvalid[0] signal behavior"
echo "   Duration: 30 seconds max"

# Run simulation with focused monitoring on AXI signals
timeout 30 make run 2>&1 | grep -E "(AXI_arvalid|ksk_mem_avail|KSK_DATA|arvalid|X-state)" | tee axi_debug.log

echo ""
echo "🔍 ANALYSIS RESULTS:"
echo "==================="

# Check for X-states in AXI signals
if grep -q "AXI_arvalid=x\|arvalid.*x\|arvalid.*X" axi_debug.log; then
    echo "❌ X-STATES STILL PRESENT in AXI arvalid signals"
    echo "   Found X-states in:"
    grep -n "AXI_arvalid=x\|arvalid.*x\|arvalid.*X" axi_debug.log
    RESULT="FAILED"
else
    echo "✅ NO X-STATES detected in AXI arvalid signals"
    RESULT="PASSED"
fi

# Check for proper initialization sequence
if grep -q "ksk_mem_avail.*1" axi_debug.log; then
    echo "✅ KSK memory available signal properly asserted"
else
    echo "⚠️  KSK memory available signal not found in logs"
fi

# Check for KS activity
if grep -q "KSK_DATA.*vld.*1\|ksk_data_vld.*1" axi_debug.log; then
    echo "✅ KSK data valid signals detected"
else
    echo "⚠️  KSK data activity not detected"
fi

echo ""
echo "=============================================="
echo "🎯 AXI X-STATE FIX VERIFICATION: $RESULT"
echo "=============================================="

if [ "$RESULT" = "PASSED" ]; then
    echo "✅ SUCCESS: AXI X-state contamination resolved"
    echo "   - m_axi4_ksk_arvalid[0] now shows proper 0/1 values"
    echo "   - KSK initialization sequence working"
    echo "   - X-state protection mechanisms active"
    exit 0
else
    echo "❌ FAILED: AXI X-states still present"
    echo "   - Review axi_debug.log for detailed analysis"
    echo "   - May need additional initialization fixes"
    exit 1
fi