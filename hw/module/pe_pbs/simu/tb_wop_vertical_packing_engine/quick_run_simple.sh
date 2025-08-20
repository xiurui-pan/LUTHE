#!/usr/bin/bash
# 简化版快速运行脚本 - 显示更多输出用于BSK集成调试

echo "=== Quick Run Vertical Packing Engine Testbench (Simplified) ==="

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

# 🔧 使用更宽松的过滤，专注于BSK集成调试
echo "INFO> Running with simplified filtering for BSK integration debug..."

LOG=$(cd "$PROJECT_ROOT" && timeout 300 bash -lc "source setup.sh >/dev/null 2>&1 && cd $SCRIPT_DIR && ./run.sh -- -v 2>&1" | \
grep -v "Loading LUT entry" | \
grep -v "INFO>" | \
egrep -i "\
\[VP_ENGINE\]|\
\[VP_PBS_LITE\]|\
\[TB_BSK\]|\
\[TB_KSK\]|\
\[TB_DIRECT\]|\
\[TB\].*SUCCESS|\
\[TB\].*FAILURE|\
\[TB\].*Mismatch|\
\[TB\].*Starting|\
\[TB\].*completed|\
BSK.*Phase|\
BSK.*command|\
BSK.*data|\
BSK.*access|\
BSK.*response|\
BSK.*initialization|\
BSK.*slot|\
BSK_MGR.*Slot|\
LWE_K_W.*max_slots|\
KSK.*access|\
handshake.*SUCCESS|\
captured.*entries|\
\[TB_KERNEL\]|\
\[TB_VERIFY\]|\
CAPTURE.*vs.*KERNEL|\
PERFECT.*MATCH|\
verification|\
^ERROR:|\
^FATAL:|\
^WARNING:.*BSK|\
^WARNING:.*KSK|\
FAILED|\
PASSED|\
SUCCESS|\
TIMEOUT" | tail -150)

# 打印过滤后的日志
echo "$LOG"

# 根据Mismatch/FAIL/ERROR判断退出码
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


