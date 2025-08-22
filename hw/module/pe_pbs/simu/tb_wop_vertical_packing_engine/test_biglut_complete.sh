#!/usr/bin/bash
# 完整bigLut算法测试：验证Steps 1-5的完整实现

echo "=== Complete bigLut Algorithm Test ==="
echo "Testing: TLwe32_Keyswitch_Bootstrapping_Extract_lvl1 implementation"

# 设置项目环境
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

echo "INFO> Project root: $PROJECT_ROOT"

# 运行完整bigLut算法测试
echo "INFO> Running complete bigLut algorithm test (150s timeout)..."

cd "$PROJECT_ROOT" && source setup.sh >/dev/null 2>&1 && \
cd "$SCRIPT_DIR" && \
timeout 150 ./run.sh -- -v 2>&1 | \
egrep -i "Step.*[1-5]|STEP[1-5]|CMux|VP_PBS|Key.*Switch|Bootstrap|Extract|get_hi|LUT|bigLut.*result|modSwitch|tLwe32|Sample.*Extract|POST_PROCESSING|WRITE_RESULT|Mismatch|PASSED|FAILED|completed|算法|实际结果" | \
tail -100 > biglut_complete_test.log

echo ""
echo "=== Test Results Summary ==="
echo "Full log saved to: biglut_complete_test.log"

# 显示关键结果
echo ""
echo "Key Results:"
tail -20 biglut_complete_test.log | egrep -i "Step.*5|Extract.*completed|bigLut.*result|Mismatch|PASSED|FAILED"

echo ""
echo "=== Complete bigLut Algorithm Test Finished ==="