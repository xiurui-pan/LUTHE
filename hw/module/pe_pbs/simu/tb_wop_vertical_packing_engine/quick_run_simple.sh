#!/usr/bin/bash
# 简化版快速运行脚本 - 显示更多输出用于BSK集成调试

# echo "=== Quick VP Engine Testbench ==="

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

# echo "INFO> Using project root: $PROJECT_ROOT"

# Stage 9: 增强调试输出来定位KS硬件问题  
cd "$PROJECT_ROOT" && timeout 45s bash -lc "source setup.sh >/dev/null 2>&1 && cd $SCRIPT_DIR && ./run.sh -- -v --timeout 40000000 2>&1" > run_output.log

echo "请查看run_output.log"