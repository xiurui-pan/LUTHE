#!/bin/bash
# =============================================================================
# KS Hardware Result Path Debugging Script
# =============================================================================
# Purpose: Systematically trace KS command/result flow to identify why 
#          ks_seq_result_vld never reaches VP-PBS
# =============================================================================

cd "$(dirname "$0")"

echo "🔍 Starting KS Hardware Result Path Debug Analysis..."
echo "============================================================"

# Run simulation with focused KS result tracking
timeout 60s ./quick_run_simple.sh 2>&1 | tee ks_debug_full.log | \
grep -E "(★|KS_TOP|KS_CTRL|KS.*RESULT|result_vld|STEP5.*KS|Command received|COMPLETE.*Step 5)" | \
head -50

echo ""
echo "🔍 KS Command Flow Analysis:"
echo "============================================================"
grep -E "(Command received|seq_ks_cmd_avail=1|COMPLETE.*Step 5)" ks_debug_full.log | head -10

echo ""
echo "🔍 KS Result Generation Analysis:"
echo "============================================================"
grep -E "(Result valid|ks_seq_result_vld=1|KS.*RESULT.*TRANSFERRED)" ks_debug_full.log | head -10

echo ""
echo "🔍 VP-PBS Waiting Analysis:"
echo "============================================================"
grep -E "(STEP5_KS.*Waiting|Delay counting|ks_seq_result_vld=b)" ks_debug_full.log | head -10

echo ""
echo "🔍 KS Pipeline Stall Indicators:"
echo "============================================================"
grep -E "(ERROR.*cmd_fifo|s0_cmd.*not ready|Pipeline stall|FIFO.*full)" ks_debug_full.log | head -10

echo ""
echo "💡 Debug Summary:"
echo "============================================================"
echo "- Full log saved to: ks_debug_full.log"
echo "- Check if KS commands reach hardware but results get stuck in pipeline"
echo "- Look for FIFO overflow or pipeline stall conditions"
echo "- Verify result valid signals from pep_ks_result_format module"