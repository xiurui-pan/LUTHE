#!/usr/bin/bash
# VP Engine详细调试 - 不过滤任何VP_ENGINE输出

echo "=== VP Engine Detailed Debug (No Filtering) ==="

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
echo "INFO> Capturing ALL VP_ENGINE messages without filtering..."

# 运行仿真并捕获所有VP_ENGINE输出
LOG=$(cd "$PROJECT_ROOT" && timeout 300 bash -lc "source setup.sh >/dev/null 2>&1 && cd $SCRIPT_DIR && ./run.sh -- -v 2>&1" | \
grep -v "Loading LUT entry" | \
grep -v "INFO>" | \
grep "\[VP_ENGINE\]" | head -100)

echo "$LOG"

echo ""
echo "=== VP Engine Message Count ==="
total_vp_msgs=$(echo "$LOG" | wc -l)
cmux_msgs=$(echo "$LOG" | grep -c -i "cmux")
state_msgs=$(echo "$LOG" | grep -c -i "state")
round_msgs=$(echo "$LOG" | grep -c -i "round\|bit")
critical_msgs=$(echo "$LOG" | grep -c -i "critical")

echo "Total VP_ENGINE messages: $total_vp_msgs"
echo "CMux-related messages: $cmux_msgs"
echo "State transition messages: $state_msgs"  
echo "Round/bit messages: $round_msgs"
echo "Critical messages: $critical_msgs"

if [ "$total_vp_msgs" -eq 0 ]; then
    echo "❌ NO VP_ENGINE messages found - possible filtering or compilation issue"
elif [ "$cmux_msgs" -eq 0 ]; then
    echo "❌ NO CMux messages found - CMux tree not executing"
else
    echo "✅ VP_ENGINE messages detected"
fi

echo "=== VP Engine Detailed Debug Complete ==="


