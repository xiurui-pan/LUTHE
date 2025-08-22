#!/usr/bin/bash
# Stage 4 后台长时间测试脚本

echo "=== Stage 4 Background Test Started ===" > stage4_background.log
echo "Start time: $(date)" >> stage4_background.log

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

echo "Project root: $PROJECT_ROOT" >> stage4_background.log

# 运行长时间测试 (300秒 = 5分钟)
echo "Running 5-minute background test..." >> stage4_background.log

cd "$PROJECT_ROOT" && source setup.sh >/dev/null 2>&1 && \
cd "$SCRIPT_DIR" && \
timeout 300 ./run.sh -- -v 2>&1 | \
egrep -i "Step.*5|STEP5|KS:|Bootstrap|Extract|get_hi|Second.*round|lvl1.*lvl0|VP_PBS_STEP5|step5_.*completed|completed.*moving|tLwe32ExtractSample|bigLut.*result|Mismatch|PASSED|FAILED" \
>> stage4_background.log 2>&1

echo "Test completed at: $(date)" >> stage4_background.log
echo "=== Stage 4 Background Test Ended ===" >> stage4_background.log