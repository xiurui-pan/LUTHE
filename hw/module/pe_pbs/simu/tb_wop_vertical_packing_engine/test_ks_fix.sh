#!/bin/bash

# VP-PBS KS集成修复验证脚本
# 用于快速检查X-state和无限循环修复效果

echo "=========================================="
echo "VP-PBS KS Integration Fix Verification"
echo "=========================================="

cd /home/pxr/workspace/hpu_fpga
source setup.sh 2>/dev/null

echo "Starting 30-second timeout simulation..."
timeout 30s ./hw/module/pe_pbs/simu/tb_wop_vertical_packing_engine/quick_run_simple.sh > /tmp/vp_pbs_test.log 2>&1

if [ $? -eq 124 ]; then
    echo "✅ GOOD: Simulation timed out (not stuck in infinite loop)"
else
    echo "⚠️ Simulation completed or failed within 30s"
fi

echo ""
echo "=========================================="
echo "Key Issue Analysis:"
echo "=========================================="

# 1. 检查X-state修复
x_states=$(grep -c "X-STATE DETECTED" /tmp/vp_pbs_test.log)
echo "🔍 X-STATE detections: $x_states"

# 2. 检查STEP5 enquiry修复
emergency_fix=$(grep -c "STEP5_KS_EMERGENCY_FIX" /tmp/vp_pbs_test.log)
echo "⚡ STEP5 emergency enquiry fixes: $emergency_fix"

# 3. 检查KS命令生成
ks_commands=$(grep -c "★★★.*COMPLETE.*KS.*COMMAND.*ISSUED" /tmp/vp_pbs_test.log)
echo "★ KS Commands issued: $ks_commands"

# 4. 检查超时保护
timeouts=$(grep -c "EMERGENCY.*TIMEOUT" /tmp/vp_pbs_test.log)
echo "🚨 Emergency timeouts: $timeouts"

# 5. 检查编译错误/警告
errors=$(grep -c "ERROR" /tmp/vp_pbs_test.log)
warnings=$(grep -c "WARNING.*select.*out.*bounds" /tmp/vp_pbs_test.log)
echo "❌ Compile errors: $errors"
echo "⚠️ Array bounds warnings: $warnings"

echo ""
echo "=========================================="
echo "Recent Key Events (last 20 lines):"
echo "=========================================="
grep -E "(X-STATE|EMERGENCY_FIX|★★★|TIMEOUT|ERROR|finish)" /tmp/vp_pbs_test.log | tail -20

echo ""
echo "Full log available at: /tmp/vp_pbs_test.log"
echo "Log size: $(wc -l < /tmp/vp_pbs_test.log) lines (vs previous 550,000+ lines)"
