#!/usr/bin/bash
# 快速运行脚本 - 精简输出用于调试

echo "=== Quick Run Vertical Packing Engine Testbench ==="

# 确定项目根目录
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

# 使用bash -lc方式运行，确保环境正确设置
LOG=$(cd "$PROJECT_ROOT" && timeout 300 bash -lc "source setup.sh >/dev/null 2>&1 && cd $SCRIPT_DIR && ./run.sh -- -v 2>&1" | grep -v "Loading LUT entry" | egrep -i "\
\[VP_ENGINE\].*State transition|\
\[VP_ENGINE\].*FULLY COMPLETED|\
\[VP_ENGINE\].*LUT LOADING COMPLETED|\
\[VP_ENGINE\].*GGSW loading completed|\
\[VP_ENGINE\].*DONE|\
\[VP_ENGINE\].*RTL RESULT|\
\[VP_ENGINE\].*WRITE_RESULT COMPLETED|\
\[TB\].*Starting|\
\[TB\].*completed|\
\[TB\].*control bits|\
\[TB\].*Running external golden|\
\[TB\]\[PBS_MON\]|\
\[TB\].*Mismatch|\
\[TB\].*FAILURE|\
\[TB\].*SUCCESS|\
\[GOLDEN\]|\
\[SIMPLE_PBS\]|\
\[VP_ENGINE\].*POST_PROCESS.*|\
^ERROR:|\
^FATAL:|\
FAILED|\
TEST (PASSED|FAILED)|\
TIMEOUT")

# 打印过滤后的日志
echo "$LOG"

# 根据Mismatch/FAIL/ERROR判断退出码；只有在不存在这些关键词时，如果包含SUCCESS则视为通过
if echo "$LOG" | egrep -iq "Mismatch|FAIL|ERROR|FATAL|FAILED|TIMEOUT"; then
	echo "=== 检测到错误/不匹配，快速运行失败 ==="
	exit 1
fi

if echo "$LOG" | egrep -iq "SUCCESS"; then
	echo "=== 快速运行成功（无错误/不匹配检测到） ==="
	exit 0
fi

# 若既没有错误也没有SUCCESS，给出提示
echo "=== 无明确结论（请查看完整日志） ==="
exit 2

echo ""
echo "=== 快速运行结束 ==="