#!/usr/bin/bash
# 简化版快速运行脚本 - 显示更多输出用于BSK集成调试

echo "=== Quick VP Engine Testbench ==="

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


# Stage 9: 增强调试输出来定位KS硬件问题
LOG=$(cd "$PROJECT_ROOT" && timeout 120 bash -lc "source setup.sh >/dev/null 2>&1 && cd $SCRIPT_DIR && ./run.sh -- -v --timeout 120000000 2>&1" | \
grep -v "Loading LUT entry" | \
grep -v "Compiling package" | \
grep -v "INFO: \[VRFC" | \
grep -v "WARNING: \[VRFC" | \
grep -v "analyzing module" | \
grep -v "Compiling module" | \
grep -v "Same file given several times")

# 打印完整日志（可以在命令行添加额外过滤）
echo "$LOG"

# 根据真正的错误模式判断退出码（排除Vivado正常信息）
if echo "$LOG" | egrep -iq "ERROR:.*\[|FATAL|FAILED.*test|Mismatch.*detected|TIMEOUT.*exceeded" | grep -v "Using init file"; then
	echo "=== 检测到错误/不匹配，失败 ==="
	exit 1
fi

if echo "$LOG" | egrep -iq "bigLut.*algorithm.*finished.*successfully|Complete.*bigLut.*algorithm.*finished"; then
	echo "=== bigLut算法运行结束 ==="
	exit 0
elif echo "$LOG" | egrep -iq "SUCCESS"; then
	echo "=== 部分成功（Step 4完成，但需验证Step 5） ==="
	# 不要立即退出，继续检查Step 5
fi

# 若既没有错误也没有SUCCESS，给出提示
echo "=== 无明确结论（请查看完整日志） ==="
exit 2

echo ""
echo "=== 快速运行结束 ==="


