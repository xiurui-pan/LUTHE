#!/usr/bin/bash
# 快速运行脚本 - 精简输出用于调试

echo "=== 快速运行 Vertical Packing Engine Testbench ==="

timeout 300 ./run.sh -- -v 2>&1 | grep -v "Loading LUT entry" | egrep -i "\
\[VP_ENGINE\].*State transition|\
\[VP_ENGINE\].*FULLY COMPLETED|\
\[VP_ENGINE\].*LUT LOADING COMPLETED|\
\[VP_ENGINE\].*GGSW loading completed|\
\[VP_ENGINE\].*DONE|\
\[TB\].*Starting|\
\[TB\].*completed|\
\[TB\].*control bits|\
\[TB\].*SUCCESS|\
\[TB\].*FAILURE|\
\[TB\].*Mismatch|\
\[GOLDEN\].*Starting|\
\[GOLDEN\].*Selected LUT|\
\[GOLDEN\].*Final results|\
\[GOLDEN\].*completed|\
^ERROR:|\
^FATAL:|\
SUCCESS|\
FAILED|\
TEST (PASSED|FAILED)|\
TIMEOUT" || echo "=== 仿真完成 ==="

echo ""
echo "=== 快速运行结束 ==="
