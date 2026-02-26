# GPU-CSD nvmevirt e2e 审阅报告（2026-02-02）

目的：基于**现有日志**核对“nvmevirt+GPU+WOPBS 相关闭环、FTL/flash 映射、pipeline 重叠优化”的完成度，给出可追溯证据与缺口说明。

## 审阅结论（摘要）
- nvmevirt+GPU+WOPBS（vp/exp/soft）闭环：**已通过**（GLWE matches + PASS）。
- softmax e2e：**已通过**（fail=0 且 golden_mismatch=0）。
- CB step4_only / KSPBS split：**已通过**（GLWE matches golden / KSPBS split PASS）。
- FTL emu：**已通过配置与汇总日志证明启用**（CFG + SUMMARY）。
- flash 模拟与 keyset/TLWE/GLWE PBA 映射：**有明确日志证据**（KEYSET_FLASH/DATA_FLASH + slba/loopdev）。
- “流水线计算重叠与优化已完成”：**未见明确日志或指标证据**（仅在计划/说明文档出现；需要 timeline/overlap 实测或指标输出）。

## 证据与日志片段

### 1) vp/exp/soft（nvmevirt+GPU+WOPBS）闭环
证据路径：`/tmp/csd_gpu_nvmevirt_regression_20260201_145433/vp_exp_soft/run.log`
```
69:  | [6/6] GLWE matches golden: /tmp/csd_gpu_nvmevirt_regression_20260201_145433/vp_exp_soft/vp_golden_index42.bin
73:  | [6/6] GLWE matches golden: /tmp/csd_gpu_nvmevirt_regression_20260201_145433/vp_exp_soft/exp_golden_index43.bin
77:  | [6/6] GLWE matches golden: /tmp/csd_gpu_nvmevirt_regression_20260201_145433/vp_exp_soft/soft_golden_index44.bin
80:[PASS] All cases OK. Artifacts saved under: /tmp/csd_gpu_nvmevirt_regression_20260201_145433/vp_exp_soft
```

### 2) softmax e2e（容差检查 + golden_mismatch=0）
证据路径：
- `/tmp/csd_gpu_nvmevirt_softmax_20260201_144629/check.log`
- `/tmp/csd_gpu_nvmevirt_softmax_20260201_144629/backend.log`
```
check.log:6:[softmax] n=16 warn=0 fail=0 max_abs=0.00000000e+00 max_rel=0.00000000e+00
backend.log:19:... golden_mismatch=0 status=0x00000002
```

### 3) CB step4_only e2e
证据路径：`/tmp/csd_gpu_nvmevirt_regression_20260201_145433/cb_step4only/e2e.log`
```
44:[6/6] GLWE matches golden: /tmp/csd_gpu_nvmevirt_regression_20260201_145433/cb_step4only/cb_step5_golden.bin
```

### 4) KSPBS split
证据路径：`/tmp/csd_gpu_nvmevirt_regression_20260201_145433/kspbs_split/backend.log`
```
11:2026-02-01 15:02:18,820 INFO [KSPBS_SPLIT][PASS] KSPBS split matches GPU monolithic
```

### 5) FTL emu（配置 + 汇总）
证据路径：`/tmp/csd_ftl_emu_backend_cpu_20260128.log`
```
1:2026-01-28 15:50:31,656 INFO [FTL_EMU][CFG] enable=1 profile=daisyplus channels=8 ...
43:2026-01-28 15:51:35,417 INFO [FTL_EMU][SUMMARY] cmd=4656 tlwe_pages=3 glwe_pages=5 hits=0 misses=8 ...
```

### 6) flash 模拟与 PBA 映射（KEYSET/TLWE/GLWE）
证据路径（示例）：
- `/tmp/csd_gpu_nvmevirt_macro_deepnn_fullflow_20260131_222901/driver.log`
- `/tmp/csd_gpu_nvmevirt_macro_deepnn_20260131_222627/softmax_offload_e2e.log`
- `/tmp/csd_gpu_nvmevirt_macro_deepnn_multivariant_20260128_134705/run/softmax_offload_e2e.log`
```
driver.log:91:[KEYSET_FLASH] host=/tmp/csd_gpu_nvmevirt_regression_20260131_134826/wop_keyset.bin bytes=3292641408
driver.log:92:[KEYSET_FLASH] dev=/dev/nvme2n123 slba=21398304 margin_mb=64
driver.log:94:[KEYSET_FLASH] loopdev=/dev/loop142
driver.log:97:[DATA_FLASH] glwe slba=21397648 sectors=649 bytes=331856
driver.log:98:[DATA_FLASH] tlwe slba=21397640 sectors=4 bytes=1848
```
```
softmax_offload_e2e.log:33:[KEYSET_FLASH] host=/tmp/csd_gpu_nvmevirt_regression_20260131_134826/wop_keyset.bin bytes=3292641408
softmax_offload_e2e.log:34:[KEYSET_FLASH] dev=/dev/nvme2n123 slba=21398304 margin_mb=64
softmax_offload_e2e.log:43:[DATA_FLASH] glwe slba=21398296 sectors=1 bytes=128
softmax_offload_e2e.log:44:[DATA_FLASH] tlwe slba=21398288 sectors=1 bytes=128
```
```
softmax_offload_e2e.log:34:[KEYSET_FLASH] host=/home/pxr/workspace/hpu_fpga_fin/tmp_assets/wop_keyset_concrete_poly2048_k1_n0771_n22048.bin bytes=3621207228
softmax_offload_e2e.log:35:[KEYSET_FLASH] dev=/dev/nvme2n119 slba=20756576 margin_mb=64
softmax_offload_e2e.log:41:[DATA_FLASH] glwe slba=20756568 sectors=1 bytes=128
softmax_offload_e2e.log:42:[DATA_FLASH] tlwe slba=20756560 sectors=1 bytes=128
```

### 7) “流水线计算重叠与优化已完成”
当前结论：**未见明确取证**。  
说明：现有日志缺少“IO_in/Compute/IO_out timeline、overlap_ms、steady-state 节拍”等直接指标；仅在计划/分析文档中描述目标与估算。若需证明完成，需要补充以下任一类证据：
- GPU/SSD 时间线或分段打点（明确 overlap 或 max{IO_in,Compute,IO_out} 的节拍）。
- `tools/gpu_ssd_perf_model.py` 的实测输入与导出结果（非占位/历史数据）。

## 总结
基于上述证据，nvmevirt+GPU+WOPBS 主要闭环、softmax、CB/KSPBS、FTL emu 与 flash 映射均有现成日志支撑；**流水线重叠优化未见可核验证据**，暂不能断言完成。
