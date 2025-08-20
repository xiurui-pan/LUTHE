#!/usr/bin/bash
# CMux Tree 详细分析脚本 - 基于原有工作脚本修改

echo "=== CMux Tree Analysis - Detailed Round-by-Round Inspection ==="

# 确定项目根目录（复制自原脚本）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT=""
CHECK_DIR="$SCRIPT_DIR"
for i in {1..6}; do  # Check up to 6 levels up
    if [ -f "$CHECK_DIR/setup.sh" ]; then
        PROJECT_ROOT="$CHECK_DIR"
        break
    fi
    CHECK_DIR="$(dirname "$CHECK_DIR")"
done

if [ -z "$PROJECT_ROOT" ]; then
    echo "ERROR: Cannot find setup.sh in parent directories"
    exit 1
fi

echo "INFO> Using project root: $PROJECT_ROOT"
echo "INFO> Running VP-PBS simulation with CMux focus..."

# 运行仿真并捕获CMux相关输出（基于原有工作脚本）
LOG=$(cd "$PROJECT_ROOT" && timeout 300 bash -lc "source setup.sh >/dev/null 2>&1 && cd $SCRIPT_DIR && ./run.sh -- -v 2>&1" | \
grep -v "Loading LUT entry" | \
grep -v "INFO>" | \
egrep -i "\
\[VP_ENGINE\].*CMux|\
\[VP_ENGINE\].*Round|\
\[VP_ENGINE\].*cmux|\
\[VP_ENGINE\].*entries|\
\[VP_ENGINE\].*pools|\
\[VP_ENGINE\].*ping_pong|\
\[VP_ENGINE\].*SELECTED_INDEX|\
\[VP_ENGINE\].*CRITICAL|\
\[VP_ENGINE\].*DEBUG|\
\[VP_ENGINE\].*Final|\
\[VP_ENGINE\].*extracted|\
\[VP_ENGINE\].*Starting|\
\[VP_ENGINE\].*completed|\
\[VP_ENGINE\].*Advancing|\
\[VP_ENGINE\].*processing|\
\[VP_ENGINE\].*ggsw_value|\
\[VP_ENGINE\].*control_bit|\
\[VP_ENGINE\].*Selected|\
\[VP_ENGINE\].*Entry|\
\[VP_ENGINE\].*Source|\
\[VP_PBS_LITE\].*SAMPLE_EXTRACT|\
\[VP_PBS_LITE\].*final_result_vec|\
CAPTURE.*vs.*KERNEL|\
PERFECT.*MATCH|\
verification|\
CMux.*tree|\
CMux.*calculation|\
CMux.*result|\
round.*[0-9]|\
tree.*level" | tail -300)

# 打印CMux相关日志
echo "$LOG"

echo ""
echo "=== CMux Analysis Summary ==="

# Extract key CMux information
selected_index=$(echo "$LOG" | grep "SELECTED_INDEX" | tail -1)
final_values=$(echo "$LOG" | grep -i "Final.*CMux\|Final.*values" | tail -1)
extracted_from=$(echo "$LOG" | grep "extracted from" | tail -1)

echo "Selected Index: $selected_index"
echo "Final Values: $final_values" 
echo "Extracted From: $extracted_from"

# Count rounds
round_count=$(echo "$LOG" | grep -c "Round.*completed")
cmux_count=$(echo "$LOG" | grep -c -i "cmux")
echo "Total CMux Rounds Completed: $round_count"
echo "Total CMux Messages: $cmux_count"

# Check for any issues
if echo "$LOG" | grep -q "PERFECT.*MATCH"; then
    echo "✅ CMux Tree Verification: PASSED"
else
    echo "❌ CMux Tree Verification: NEEDS REVIEW"
fi

echo ""
echo "=== Detailed Round Analysis ==="

# Show round progression
echo "$LOG" | grep -E -i "Starting.*round|Round.*completed|cmux.*round" | head -20

echo ""
echo "=== Critical CMux Decisions ==="
echo "$LOG" | grep -i "CRITICAL\|cmux.*tree\|cmux.*calculation" | head -10

echo ""
echo "=== VP_ENGINE CMux Messages ==="
echo "$LOG" | grep "\[VP_ENGINE\]" | grep -i "cmux" | head -15

echo "=== CMux Tree Analysis Complete ==="
