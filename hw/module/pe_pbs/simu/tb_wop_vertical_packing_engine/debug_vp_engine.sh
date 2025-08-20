#!/usr/bin/bash
# VP Engine状态机调试脚本

echo "=== VP Engine State Machine Debug ==="

# 确定项目根目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT=""
CHECK_DIR="$SCRIPT_DIR"
for i in {1..6}; do
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
echo "INFO> Running VP Engine state transition analysis..."

# 运行仿真并专门捕获VP_ENGINE状态转换
LOG=$(cd "$PROJECT_ROOT" && timeout 300 bash -lc "source setup.sh >/dev/null 2>&1 && cd $SCRIPT_DIR && ./run.sh -- -v 2>&1" | \
grep -v "Loading LUT entry" | \
grep -v "INFO>" | \
egrep -i "\
\[VP_ENGINE\].*State|\
\[VP_ENGINE\].*transition|\
\[VP_ENGINE\].*IDLE|\
\[VP_ENGINE\].*LOAD_LUT|\
\[VP_ENGINE\].*LOAD_GGSW|\
\[VP_ENGINE\].*CMUX_TREE|\
\[VP_ENGINE\].*WRITE_CMUX|\
\[VP_ENGINE\].*VP_PBS|\
\[VP_ENGINE\].*WAIT_PBS|\
cmux_tree_state|\
cmux_tree_done|\
cmux_extracted|\
CMUX_IDLE|\
CMUX_INIT|\
CMUX_TREE_EXEC|\
CMUX_EXTRACT|\
CMUX_RESULT_READY|\
ggsw_samples_ready|\
lut_load_done|\
ggsw_load_done|\
CAPTURE.*vs.*KERNEL|\
PERFECT.*MATCH" | tail -100)

echo "$LOG"

echo ""
echo "=== VP Engine Analysis Summary ==="

# 检查状态转换
states=$(echo "$LOG" | grep -i "State\|transition" | wc -l)
cmux_mentions=$(echo "$LOG" | grep -c -i "cmux")
echo "Total State Transitions: $states"
echo "Total CMux References: $cmux_mentions"

# 检查关键条件
if echo "$LOG" | grep -q "ggsw_samples_ready"; then
    echo "✅ GGSW samples ready detected"
else
    echo "❌ GGSW samples ready NOT detected"
fi

if echo "$LOG" | grep -q "lut_load_done"; then
    echo "✅ LUT load done detected"
else
    echo "❌ LUT load done NOT detected"
fi

if echo "$LOG" | grep -q "CMUX_TREE"; then
    echo "✅ CMux Tree state detected"
else
    echo "❌ CMux Tree state NOT detected"
fi

if echo "$LOG" | grep -q "PERFECT.*MATCH"; then
    echo "✅ Final verification: PASSED"
else
    echo "❌ Final verification: FAILED"
fi

echo "=== VP Engine Debug Complete ==="


