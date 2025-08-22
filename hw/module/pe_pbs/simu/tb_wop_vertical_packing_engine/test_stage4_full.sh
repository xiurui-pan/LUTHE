#!/usr/bin/bash
# Stage 4 完整测试：验证Key Switching → Bootstrap → Extract完整流程

echo "=== Stage 4 Full Flow Test ==="

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

# 运行完整仿真，捕获所有Stage 4相关输出
echo "INFO> Running complete Stage 4 flow test (120s timeout)..."

cd "$PROJECT_ROOT" && source setup.sh >/dev/null 2>&1 && \
cd "$SCRIPT_DIR" && \
timeout 120 ./run.sh -- -v 2>&1 | \
egrep -i "Step.*5|STEP5|KS:|Bootstrap|Extract|get_hi|Second.*round|lvl1.*lvl0|VP_PBS_STEP5|step5_.*completed|completed.*moving" | \
tail -50

echo ""
echo "=== Stage 4 Full Flow Test Complete ==="