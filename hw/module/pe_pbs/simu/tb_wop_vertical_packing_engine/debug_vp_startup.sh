#!/usr/bin/bash
# VP Engine启动过程详细调试

echo "=== VP Engine Startup Debug ==="

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
echo "INFO> Monitoring VP Engine startup signals and state transitions..."

# 运行仿真并捕获启动相关的所有输出
LOG=$(cd "$PROJECT_ROOT" && timeout 300 bash -lc "source setup.sh >/dev/null 2>&1 && cd $SCRIPT_DIR && ./run.sh -- -v 2>&1" | \
grep -v "Loading LUT entry" | \
grep -v "INFO>" | \
egrep -i "\
\[TB\].*start|\
\[TB\].*ggsw_samples_ready|\
\[TB\].*pulse|\
\[TB\].*Input|\
\[VP_ENGINE\].*start|\
\[VP_ENGINE\].*IDLE|\
\[VP_ENGINE\].*current_state|\
\[VP_ENGINE\].*next_state|\
start.*=|\
ggsw_samples_ready.*=|\
done.*=|\
current_state.*=|\
next_state.*=|\
State.*transition|\
LOAD_LUT|\
LOAD_GGSW|\
CMUX_TREE|\
lut_load_done|\
ggsw_load_done|\
cmux_tree_done|\
Reset.*released|\
Reset.*sequence|\
Starting.*vertical|\
time.*[0-9]+000" | head -50)

echo "$LOG"

echo ""
echo "=== Startup Analysis Summary ==="

# 检查关键事件
if echo "$LOG" | grep -q "Starting vertical"; then
    echo "✅ Testbench start signal detected"
else
    echo "❌ Testbench start signal NOT detected"
fi

if echo "$LOG" | grep -q "ggsw_samples_ready.*=.*1\|ggsw_samples_ready=1"; then
    echo "✅ GGSW samples ready signal set"
else
    echo "❌ GGSW samples ready signal NOT set"
fi

if echo "$LOG" | grep -q "State.*transition"; then
    echo "✅ VP Engine state transitions detected"
    echo "State transitions:"
    echo "$LOG" | grep "State.*transition" | head -5
else
    echo "❌ VP Engine state transitions NOT detected"
fi

if echo "$LOG" | grep -q "IDLE"; then
    echo "✅ VP Engine IDLE state detected"
else
    echo "❌ VP Engine IDLE state NOT detected"
fi

# 时序分析
start_time=$(echo "$LOG" | grep "Starting vertical" | head -1 | grep -o "time [0-9]*" | grep -o "[0-9]*")
first_transition=$(echo "$LOG" | grep "State.*transition" | head -1 | grep -o "time [0-9]*" | grep -o "[0-9]*")

if [ -n "$start_time" ] && [ -n "$first_transition" ]; then
    echo "⏱️  Timing: Start at ${start_time}ns, First transition at ${first_transition}ns"
    echo "   Delay: $((first_transition - start_time))ns"
else
    echo "⏱️  Timing: Unable to calculate delays"
fi

echo "=== VP Engine Startup Debug Complete ==="


