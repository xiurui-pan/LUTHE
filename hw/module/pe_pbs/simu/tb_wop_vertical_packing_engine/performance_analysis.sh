#!/bin/bash

# VP-PBS性能分析脚本
echo "🔍 VP-PBS性能分析开始..."

# 创建临时日志文件
TEMP_LOG="performance_analysis.log"
echo "📊 运行完整仿真并收集性能数据..."

# 运行仿真并收集关键性能指标
timeout 90 make run 2>&1 > $TEMP_LOG

echo ""
echo "=== 📈 VP-PBS系统性能报告 ==="
echo ""

# 1. 时序分析
echo "🕒 时序性能分析:"
echo "----------------------------------------"
grep -E "time.*[0-9]{4,}.*ps|@.*[0-9]{4,}" $TEMP_LOG | head -5 | while read line; do
    echo "  $line"
done

echo ""

# 2. 状态机性能
echo "🔄 状态机转换性能:"
echo "----------------------------------------"
echo "VP Engine状态转换:"
grep "VP_ENGINE.*State transition" $TEMP_LOG | while read line; do
    echo "  $line"
done

echo ""
echo "PBS Kernel状态转换:"
grep "VP_PBS_LITE.*State transition" $TEMP_LOG | head -5 | while read line; do
    echo "  $line"
done

echo ""

# 3. 吞吐量分析
echo "📊 数据处理吞吐量:"
echo "----------------------------------------"
TOTAL_CMUX_ROUNDS=$(grep -c "CMux processing.*bit.*round" $TEMP_LOG)
TOTAL_BLIND_ROT_BITS=$(grep -c "BSK.*bit.*processing" $TEMP_LOG)
echo "  CMux Tree处理轮次: $TOTAL_CMUX_ROUNDS"
echo "  Blind Rotation处理位数: $TOTAL_BLIND_ROT_BITS"

# 4. 资源利用率（模拟估算）
echo ""
echo "🔧 模块活跃度分析:"
echo "----------------------------------------"
VP_ENGINE_ACTIVE=$(grep -c "VP_ENGINE.*processing\|VP_ENGINE.*Starting" $TEMP_LOG)
PBS_KERNEL_ACTIVE=$(grep -c "VP_PBS_LITE.*Starting\|VP_PBS_LITE.*processing" $TEMP_LOG)
echo "  VP Engine活跃操作: $VP_ENGINE_ACTIVE"
echo "  PBS Kernel活跃操作: $PBS_KERNEL_ACTIVE"

# 5. 成功率分析
echo ""
echo "✅ 成功率分析:"
echo "----------------------------------------"
SUCCESS_COUNT=$(grep -c "SUCCESS\|PASSED" $TEMP_LOG)
ERROR_COUNT=$(grep -c "ERROR\|FAILED\|Fatal" $TEMP_LOG)
echo "  成功操作: $SUCCESS_COUNT"
echo "  错误计数: $ERROR_COUNT"
if [ $ERROR_COUNT -eq 0 ]; then
    echo "  ✅ 系统稳定性: 100% (无错误)"
else
    echo "  ⚠️ 系统稳定性: $((SUCCESS_COUNT * 100 / (SUCCESS_COUNT + ERROR_COUNT)))%"
fi

# 6. 关键性能指标总结
echo ""
echo "🎯 关键性能指标总结:"
echo "----------------------------------------"
START_TIME=$(grep -o "Starting.*bigLut.*test" $TEMP_LOG | head -1)
END_TIME=$(grep -o "VP Engine.*completed" $TEMP_LOG | tail -1)
if [ ! -z "$START_TIME" ] && [ ! -z "$END_TIME" ]; then
    echo "  算法执行: 开始 -> 完成"
else
    echo "  算法执行: 数据收集中..."
fi

VERIFICATION_RESULT=$(grep -o "bigLut result verification.*ED" $TEMP_LOG | tail -1)
if [ ! -z "$VERIFICATION_RESULT" ]; then
    echo "  验证结果: $VERIFICATION_RESULT"
fi

echo ""
echo "📋 性能分析完成!"
echo "详细日志保存在: $TEMP_LOG"

# 清理临时文件
# rm -f $TEMP_LOG  # 保留日志用于进一步分析

