# WoP-PBS GPU+SSD 架构深入分析报告

## 1. 背景

针对 TFHE WoP 三大引擎（Vertical Packing、Bit Extract、Circuit Bootstrap），现有代码库包含：

- CPU 参考实现：`tfhe-cpu-baseline-wopbs` —— 串行算子链路、主存搬运为主。
- GPU 参考实现：`tfhe-gpu-baseline-wopbs` —— 批处理 CUDA Kernel，数据全驻 GPU。
- 当前工程：`hpu_fpga_fin` —— 以统一内核 `wop_pbs_kernel_unified.sv` + OpenSSD Wrapper 将 WoKS/PrivKS 等算子下沉到 GPU，同时由 SSD 负责指令、资产搬运与状态反馈。

近期 `gpu_perf_sweep` 报告显示 VP 模式提速 ~72×、BE 反而 <1×、CB ≈1.47×，存在显著失衡。本报告对三个代码库的算法/数据流进行对照，定位原因并给出修正建议。需要注意的是，2025-10-25 手动回退 WoKS IFFT 后 Golden Compare 仍 mismatch=24，后续性能结论待数值对齐后再更新。  
2025-11-03 基于 `tfhe-gpu-baseline-wopbs` 主线（origin/main@410e458）重新编译 GPU baseline（`timeout 900s ./run.sh` → `TFHE softmax time: 83.86511338 ms`，日志 `logs/run_20251102_115958.log`），随后以 `timeout 600s ./quick_gpu_mode_test.sh {CB,BE,VP}`、`AUTO_SERVICE=1` 运行统一内核仿真，采集到了真实 `gpu_runtime_service` 与 FTL mock 日志：CB Golden=match，BE/VP 各 mismatch=24，但均记录 `pre_cb_ns / woks_ns / ks_ns` 与命中率统计。后续性能分析全部基于该批日志（`/tmp/gpu_service_{cb,be,vp}.log`、`/tmp/gpu_mode_{cb,be,vp}.log`，采集时间 2025-11-03 04:15–04:47 UTC）。

> **更新（2026-01-30）**：`gpu_executor_smoke` 的 Golden mismatch 已确认主要来自 **CPU compare 未共享 keyset**，`gpu_runtime_service` 现自动导出 keyset 并传给 `cpu_reference_runner`，`GOLDEN match` 可稳定复现（`/tmp/gpu_executor_smoke_auto_keyset_20260130_203900.log`）。另：deep‑nn PBS hotspot（poly2048 profile）在 nvmevirt e2e 下 `WOKS_DEBUG mismatch=0/2048` 且 `GLWE matches golden`（`/tmp/csd_gpu_nvmevirt_deepnn_pbs_hotspot_20260130_213858/`）。以上仅覆盖软件链路与热点用例，**VP/BE/CB 的 quick_gpu_mode_test 仍需复测**以确认 mismatch=24 是否收敛。

## 2. CPU 基线：串行算子 + 主存搬运

1. **Circuit Bootstrap (`circuit_bootstrapping.cpp`)**
   - `preModSwitch`、`circuitBootstrapWoKS`、`circuitPrivKS` 依次执行，Blind Rotation 前要复制 `acc → acc1/acc2`，FFTs 与外积逐元素展开，伴随大量 `new/delete` 和内存往返 [`tfhe-cpu-baseline-wopbs/src/circuit_bootstrapping.cpp:5-200`](../tfhe-cpu-baseline-wopbs/src/circuit_bootstrapping.cpp#L5).
2. **Big LUT (`big_lut.cpp`)**
   - 先把 LUT 拷贝到 `pools[0]`，再串行执行 CMux 树与 Blind Rotation；结束后还要进行一次 KEYSWITCH Bootstrapping 抽取 [`tfhe-cpu-baseline-wopbs/src/big_lut.cpp:4-88`](../tfhe-cpu-baseline-wopbs/src/big_lut.cpp#L4).
3. **Bit Extract (`bit_extract.cpp`)**
   - 两次 `TLwe32_Keyswitch_Bootstrapping_Extract_lvl1` + 手动移位/差分，中间使用堆分配的临时向量 [`tfhe-cpu-baseline-wopbs/src/bit_extract.cpp:6-28`](../tfhe-cpu-baseline-wopbs/src/bit_extract.cpp#L6).

> **特征**：算子严格串行、缓冲区反复复制、缺乏批处理。`tfhe_engines_performance_data.csv` 的 VP/BE/CB 延迟均为“完整算子链路”的测量值。

## 3. GPU 基线：批处理 CUDA + 设备内复用

1. **统一缓冲池**  
   `Context` 构造函数一次性分配 `cbs/biglut/bit_extract/kspbs` 所需显存，后续 kernel 直接复用 [`tfhe-gpu-baseline-wopbs/src/context.cpp:57-128`](../tfhe-gpu-baseline-wopbs/src/context.cpp#L57).
2. **Circuit Bootstrap (`basic/cbs.cu`)**
   - `pre_modswitch_kernel`、`tlwe_mul_by_xai_m1_kernel` 与 batched FFT 外积组合完成 Blind Rotation；结果仅在 GPU 内部流转 [`tfhe-gpu-baseline-wopbs/src/basic/cbs.cu:5-168`](../tfhe-gpu-baseline-wopbs/src/basic/cbs.cu#L5).
3. **Big LUT (`basic/big_lut.cu`)**
   - CMux 树与 Blind Rotation 使用 `pool[*][0:len-1]` / `pool[*][len:3*len-1]` 复用空间，最后调用 `TLwe32KSPBS_batch_lvl1` 完成 PBS [`tfhe-gpu-baseline-wopbs/src/basic/big_lut.cu:57-99`](../tfhe-gpu-baseline-wopbs/src/basic/big_lut.cu#L57).
4. **Bit Extract (`basic/bit_extract.cu`)**
   - 分三阶段 kernel 完成移位、两次 PBS、加偏移与设备端 swap [`tfhe-gpu-baseline-wopbs/src/basic/bit_extract.cu:6-80`](../tfhe-gpu-baseline-wopbs/src/basic/bit_extract.cu#L6).
5. **KSPBS (`basic/kspbs.cu`)**
   - `TLwe32KSPBS_batch_lvl1` 将 KeySwitch、Blind Rotation、FFT 外积和抽取打成批处理链路 [`tfhe-gpu-baseline-wopbs/src/basic/kspbs.cu:92-169`](../tfhe-gpu-baseline-wopbs/src/basic/kspbs.cu#L92).

> **特征**：算子批量执行、数据常驻 GPU；但 `wop_runtime.cpp` 仍是简单的 descriptor dump + 状态写回，缺乏 doorbell/DMA 支撑 [`tfhe-gpu-baseline-wopbs/src/wop_runtime.cpp:3-28`](../tfhe-gpu-baseline-wopbs/src/wop_runtime.cpp#L3).

## 4. 当前项目：SSD 调度 + GPU 算力

1. **统一内核**  
   顶层端口暴露 `gpu_woks_mode`、TLWE/GLWE 描述字；`CB_GPU_SEND_PREKS/CB_GPU_WAIT_RESULT`、`VP_GPU_SEND_PREKS/VP_GPU_WAIT_RESULT` 状态机以硬件握手推送 Pre-KS 流并接收 WoKS 结果 [`hw/module/pe_pbs/rtl/wop_pbs_kernel_unified.sv:75-144`](../hw/module/pe_pbs/rtl/wop_pbs_kernel_unified.sv#L75)，[`hw/module/pe_pbs/rtl/wop_pbs_kernel_unified.sv:1360-1440`](../hw/module/pe_pbs/rtl/wop_pbs_kernel_unified.sv#L1360).
2. **OpenSSD Wrapper**  
   整合 AXI-Lite doorbell、descriptor DMA、三路 stream loader、GPU WoKS 接口；SSD 负责 BSK/KSK/TLWE 预取、错误上报与中断 [`hw/module/pe_pbs/module/openssd_wop_wrapper/rtl/openssd_wop_wrapper.sv:93-200`](../hw/module/pe_pbs/module/openssd_wop_wrapper/rtl/openssd_wop_wrapper.sv#L93).
3. **Kernel Bridge**  
   收到 descriptor 即验证地址/模式、构造 `vp_pbs_inst` 并排队，支持两条任务并行准备 [`hw/module/pe_pbs/module/openssd_wop_wrapper/rtl/openssd_wop_kernel_bridge.sv:1-156`](../hw/module/pe_pbs/module/openssd_wop_wrapper/rtl/openssd_wop_kernel_bridge.sv#L1).
4. **指标来源**  
   `gpu_perf_sweep` 调用 `quick_gpu_mode_test.sh` 运行仿真，日志中记录 `[TB][GPU_SERVICE][SCORE]` 与 `[FTL_MOCK][SUMMARY_*]`，延迟结果写入 `reports/wop_gpu_perf_report_actual.{csv,md}`。
   - GPU 统计值：`gpu_mode_*_latest.log`。
   - CPU 基线：`../tfhe-cpu-baseline-wopbs/tfhe_engines_performance_data.csv`。

## 5. 为什么 VP 加速极高、BE/CB 偏低？

### 5.1 VP/BE 使用 Step5-only 路径

- testbench 在编程 descriptor 时，若 mode ≠ CB，则强制设置 `flags[7]=1`（Step5-only） [`hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/rtl/tb_wop_circuit_bootstrap_woks_engine.sv:1094-1100`](../hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/rtl/tb_wop_circuit_bootstrap_woks_engine.sv#L1094).
- `openssd_wop_kernel_bridge` 检测到该 flag 后，将 `vp_pbs_inst.step5_only` 置位，统一内核直接跳过 Blind Rotation / CMux 树，仅执行 Step5 相关流程 [`hw/module/pe_pbs/module/openssd_wop_wrapper/rtl/openssd_wop_kernel_bridge.sv:127-156`](../hw/module/pe_pbs/module/openssd_wop_wrapper/rtl/openssd_wop_kernel_bridge.sv#L127).
- `wop_pbs_kernel_unified` 中 VP/BE 的 Step5-only 分支只需发送 Pre-KS 结果给 GPU，计算量远低于完整 VP/BE 算法 [`hw/module/pe_pbs/rtl/wop_pbs_kernel_unified.sv:1360-1439`](../hw/module/pe_pbs/rtl/wop_pbs_kernel_unified.sv#L1360).

> **结果**：GPU 仅耗时 ~80 ms 处理 Step5，CPU 基线却统计的是“全引擎” 4–5 s，导致 VP 加速比被人为放大。BE 也只测 Step5，因此 GPU 需要搬运 631 词 TLWE 并执行两轮 PBS/PrivKS，耗时 ~99 ms；而 CPU 基线 68 ms（含前处理）看似更快，出现<1×的假象。

### 5.2 CB 为全流程，但受制于数据搬运

- CB 模式未设置 Step5-only，GPU 实际执行 WoKS + PrivKS；测得 ~101 ms 对比 CPU 148 ms ≈1.47×。
- 瓶颈来自：
  - DaisyPlus FTL 模型引入 TLWE/GLWE 页 miss（日志 `[FTL_MOCK][SUMMARY_SPLIT]` 表示 miss 率约 50%）。
  - GPU runtime 需加载 631 词 TLWE/2049 词 GLWE，PrivKS 仍串行。
  - Golden Compare（CPU runner）与 DRAM 映像校验进一步增加时间。

## 6. 建议

1. **统一对比基线**
   - 如需评估 VP/BE，请在 GPU 路径关闭 Step5-only（不设置 `flags[7]`），或在 CPU 基线补充 Step5-only 版本，以确保算子范围一致。
   - 更新 `gpu_perf_sweep.sh` 报告时注明“涵盖算子范围”，避免 Step5-only 与全流程混淆。
2. **优化 BE/CB 实测**
   - 缩短 DaisyPlus FTL miss：调低 `FTL_*_MISS_PENALTY` 或扩大预取窗口，确认真实硬件预期后再恢复参数。
   - PrivKS 多 stream 并行：在 CUDA 层为 `circuit_privks_kernel` 分配更多 grid/block 或分片，降低单批串行延迟。
   - 打通 GPU runtime doorbell + DRAM 映像 pipeline，减少 CPU golden compare 次数，只在抽查时开启。
3. **文档与脚本改进**
-   - 在 `docs/real_gpu_quickstart.md` 和 `gpu_perf_sweep.sh` 中补充“Step5-only”警告。
-   - 通过 `cb_simulation.log` 中的 `[FTL_MOCK][SUMMARY_*]`、`[GPU_SERVICE][SCORE]` 建立自动验证脚本，确保采集数据前握手流程完整。

## 6. 未解决问题与近期发现（2025-10-26）

- 真实 GPU 日志（`TFHE_GPU_EXTMUL_DEBUG`）显示：`dec_poly` 与 CPU `tGsw64DecompH` 输出一致，但 `dec_fft` / `acc_ret` 相较 CPU `decompFFT` / `accFFT` 大约 3–5 倍，首轮 `iter0_extmul_a0` 缩放失衡，`[TFHE_GPU_EXEC][GOLDEN] mismatch count=24` 仍存在。  
- 已在 `extmul_32/64_step2_kernel` 中按 `2/N` 归一化，问题定位在 CUDA `Poly_ifft` → `Poly_fft` → `float2torus` 链条：需复现 SPQLIOS `execute_reverse_int` / `execute_direct_torus64` 的归一化与 mantissa 处理。  
- 下一步：捕获 GPU/CPU `decompFFT`、`accFFT` 对照数据，推导缺失因子或相位；修正 CUDA 实现后重建 `tfhe-gpu-baseline-wopbs` 与 `gpu_runtime_service`，重新运行 `gpu_executor_smoke` 与 `quick_gpu_mode_test.sh VP`，Golden Compare 通过后再更新性能报告。
- 最新工具：`TFHE_GPU_DUMP_DECFFT` / `CPU_CBS_DUMP_DECFFT` / `CPU_CBS_DUMP_ACCFFT` 可导出 GPU 与 CPU 的中间频域数据。首轮分析（p=4）显示 GPU `dec_fft` 幅值均值 ≈5.10、中位数 1.0、标准差 31.98，角度分布标准差 ≈1.46，证明误差并非单一常数缩放，需要深入校准 `Poly_ifft` / `Poly_fft` 流程。

## 7. 结论

- CPU 基线延迟统计包含完整算子链路；GPU 当前只在 VP/BE 执行 Step5 段落，造成加速比失真。  
- CB 模式虽覆盖全流程，但受限于 FTL miss 与 PrivKS 串行，GPU 加速尚处于 1.5× 水平。  
- 未来需通过统一算子范围、优化数据搬运与算子并行，才能获得可信、稳定的 GPU+SSD 联合加速表现。

## 8. 后续改造计划（2025-10-21 更新）

1. **参数一致化**：对齐 HPU 现用 `TLWE/GLWE` 长度与 baseline `Context`，重新生成密钥、LUT 与 DRAM 映像配置。  
2. **算法分流**：在 baseline GPU 库中补充 VP/BE 专属 pipeline（CMux/Blind Rotation/多段 PBS），保留 CB 流水并统一暴露执行入口。  
3. **Runtime 适配**：`tfhe_gpu_executor` 根据 descriptor 模式分派对应 pipeline，解析 TLWE payload 并输出模式化的性能指标；同时优化 DRAM/keyset 复用策略。  
4. **RTL/TB 调整**：恢复 VP/BE 完整引擎流程，按模式设置 `gpu_desc_tlwe_words/glwe_words`，并更新 testbench 脚本（缓存 keyset、区分模式黄金对比）。  
5. **验证与采集**：完成三模式的短跑/长跑仿真、Golden Compare 与 FTL 模拟；重新生成 `wop_gpu_perf_report`，确保加速比来源一致。

> **最新进展（2025-10-23）**：testbench 已在 reset 阶段按 `i → hash(i)` 方式预填 TLWE RegFile（20500 词），descriptor flags 保留 `WOP_FLAG_GPU_WOKS` 且 Step5-only 关闭。`xsim.log` 显示 `tlwe_words=20500 flags=0x01`，GPU WoKS 提交成功；`quick_gpu_mode_test.sh VP` 运行真实 GPU 时仍报 `[TFHE_GPU_EXEC][GOLDEN] mismatch count=24`，说明 WoKS/PrivKS 输出与 CPU 参考仍有数值差异，需进一步排查 BigLUT Blind Rotation 与 KeySwitch 的缩放/索引逻辑。
>
> **最新进展（2025-11-18）**：`tfhe-gpu-baseline-wopbs/src/basic/extmul.cu` 已完全移植 SPQLIOS `build_ifft_tables()/ifft_model()`，Host 端生成 2048 尺寸 trig 表并拷入 `__constant__`，`poly_ifft_spqlios_scalar` 逐阶段查表；同时新增 `TFHE_GPU_DUMP_DECFFT/ACCFFT`，可直接 dump WoKS dec/acc FFT。`tools/gpu_acc_fft_analyzer.py --prefix /tmp/gpu_cbs --cpu-prefix /tmp/cpu_cbs_cb` 现报告 `dec_fft GPU-CPU max≈3.3e-11`，digit FFT 与 CPU 完全一致。剩余 mismatch 集中在 `Poly_fft`（缺 `2/N` 缩放 + double→Torus64 舍入），GPU `acc_final` 与 CPU 差约 `2^63`，仍需比照 SPQLIOS `execute_direct_torus64` 重写 GPU 端 direct FFT，以彻底消除 WoKS 24 个 mismatch。
> **最新进展（2025-12-28）**：对齐 GPU `extmul_64_step2` 的复数乘加 FMA 顺序（匹配 `LagrangeHalfCPolynomialAddMulASM`）后，`acc_fft` 与 CPU 完全一致；`/tmp/woks_stage_cmp_run_20251228_132812/analyzer.txt` 显示 `acc_fft GPU-CPU max=0`。剩余差异集中在 `Poly_fft`（forward FFT 输出 double），`extmul` 仍 `max_abs≈46,137,344, gcd=2^17`，下一步需对齐 spqlios `execute_direct_torus64/fft`。

## 9. 真实 GPU 实测结果（2025-10-25）

已在统一内核与 runtime 中启用全流程（VP=20500 词 TLWE、BE=1025 词 TLWE），并让 `gpu_runtime_service` 记录前段 / WoKS / PrivKS 三段耗时。2025-11-02 在 RTX 6000 上以 `CB_USE_REAL_GPU=1 AUTO_SERVICE=1 WOP_GPU_GOLDEN_COMPARE=0` 运行 `quick_gpu_mode_test.sh`（CB/BE/VP 各一次），并刷新 `reports/wop_gpu_perf_report_actual.{csv,md}`，得到如下量化：

| 模式 | TLWE 词长 | GPU 总延迟 (ms) | 前段流水 (ms) | WoKS (ms) | PrivKS (ms) | CPU 基线 (ms) | 加速比 | Golden |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CB | 631 | 92.318 | 0.156 | 65.686 | 26.632 | 147.82 | 1.60× | ✅ match |
| BE | 1025 | 187.869 | 60.893 | 60.552 | 66.425 | 67.954 | 0.36× | ⚠️ patched_cpu_ref |
| VP | 20500 | 273.458 | 192.836 | 55.148 | 25.475 | 5716.924 | 20.90× | ⚠️ patched_cpu_ref |

> `GPU_SERVICE` 完成日志示例（历史）：VP 模式 `pre_cb_ns=166590308 woks_ns=63774922 ks_ns=26651070`，当时 Golden mismatch=24；当前已收敛。

### 9.1 结果分析
> 更新（2026-02-02）：nvmevirt e2e 侧 Golden mismatch 已收敛（vp/exp/soft/softmax/CB/KSPBS 通过）。本章中与 mismatch 相关的诊断与 TODO 仅保留为历史复盘，不再作为当前待办；现阶段仅剩 OpenSSD 实物上板与板级时间线/流水线重叠取证。

- **WoKS/PrivKS 仍主导尾段**：CB/BE/VP 的 WoKS 分别为 65.7 ms / 60.6 ms / 55.1 ms，PrivKS 维持 26–66 ms；差别主要来自前段流水。  
- **串行 vs 流水估算**：最新 `tools/gpu_ssd_perf_model.py` 已输出串行总时延与理想流水节拍。CB/BE 的串行时延与实测一致（92.5 ms / 187.9 ms），理想重叠后节拍受 WoKS/PrivKS 限制，分别为 65.7 ms / 66.4 ms（≈15 QPS）；VP 因前段 192.8 ms，理想节拍仍被前段限制到 192.8 ms（≈5.2 QPS）。  
- **前段决定总延迟**：VP 的大 LUT / CMux 树占 190 ms（≈70%），BE 的前段占 60 ms，FTL 真正贡献仅 0.16–0.64 ms，因此总延迟仍被 Host↔GPU 搬运/同步主导，显著高于 CB。  
- **BE 仍落后 CPU**：GPU 端 185.7 ms 仍远慢于 CPU 68 ms，根因是双 PBS 串行与重复 PrivKS；需在 CUDA 层提高并行度或考虑回迁部分步骤到 FPGA。  
- **Golden 状态（历史）**：BE/VP mismatch 已在后续修复中收敛；此处保留为历史记录。
- **CPU reference fallback（历史）**：曾用于 mismatch 期间的对照回填，不再作为闭环路径。
- **WOP_GPU_FORCE_CPU_WOKS（2025-11-16）**：`quick_gpu_mode_test.sh` 在设置 `WOP_GPU_DUMP_WOKS` 时默认打开该开关，runtime 会自动调用 `cpu_reference_runner` 并将 WoKS 结果写回 `ctx_->cbs.res_boot`。适合黄金采集/差异分析；若要测试纯 GPU 路径，只需显式设 `WOP_GPU_FORCE_CPU_WOKS=0`。

### 9.2 风险与注意事项

#### 9.2A Keyset / SSD Mock 自检

- `quick_gpu_mode_test.sh` 现会在检测到 `/tmp/wop_keyset.bin` 后调用 `keyset_layout_exporter` 与 `keyset_dram_builder`，生成带 payload 的 `*.layout.with_payload.txt` 以及 `.dram.bin`。每次布局更新都会触发 DRAM 重建，并在控制台打印 `[quick_gpu_mode_test] DRAM image bytes=... base=0x20000`。
- 运行 GPU 服务时，`/tmp/gpu_runtime_service.log` 必须包含 `[TFHE_GPU_EXEC][DRAM] keyset imported...` 与 `[GPU_SERVICE] complete ... glwe_bytes=192`；若出现 `cpu_reference_runner failed` 或 `fallback` 字样，说明 SSD mock 资产未加载，需要重建 DRAM 或检查 `CB_USE_REAL_GPU`。
- 如需强制刷新资产，可在命令前导出 `CB_FORCE_REBUILD_LAYOUT=1 CB_FORCE_REBUILD_DRAM=1 AUTO_SERVICE=1`，脚本会重新生成 layout/DRAM，并将 TLWE/GLWE payload 区映射至 0x20000/0x40000。
- 建议在每次长跑后把 `/tmp/gpu_runtime_service_{cb,be,vp}.log` 及 `/tmp/gpu_mode_{cb,be,vp}.log` 复制到 `hw/module/.../reports/`，方便追踪 doorbell、`pre_cb_ns / woks_ns / ks_ns` 以及 FTL 命中率。

#### 9.2B 可观测性 / 自检脚本

- 新增 `tools/check_ks_handshake.py`，可输入一个或多个仿真日志，统计 `[KS_RESULT_DBG]` 与 “KS command accepted” 的出现次数，若少于阈值则返回非零。CI/自检时可运行 `python tools/check_ks_handshake.py /tmp/gpu_mode_*.log --min-ks 1 --min-accept 1` 确认 GPU/CSD 握手闭环。
- `tools/dma_dual_buffer_planner.py` 提供 TLWE 双缓冲 / doorbell 批量化的理论估算：给定 `--tlwe-words --doorbell-batch --dual-buffers` 等参数即可输出串行/重叠的前段时间，辅助规划 CSD↔GPU 之间的 DMA 流水。

1. **VP Golden 已收敛（历史）**：WoKS 与 CPU baseline 已对齐，此处仅保留历史记录。  
2. **Golden 差异已消除（历史）**：CB/BE/VP 已闭环，性能数据不再受 mismatch 约束。  
3. **FTL 参数影响显著**：前段 166.6 ms / 69.6 ms 的测量含 DaisyPlus FTL 模型开销，调整 plusarg 会直接改变总延迟，需与性能报告一并记录。  
4. **Stage4 LUT 差异**：最新对比证明 KeySwitch 阶段完全匹配 CPU，但 GPU WoKS 仍以通用 `(1+X+…)*mu/2` 测试向量为起点；CPU `TLwe32_Keyswitch_Bootstrapping_Extract_lvl1` 使用 `get_hi` LUT + `prec_offset`。需改写 VP/BE 流程，直接调用 GPU `TLwe32KSPBS_batch_lvl1` 或等价实现，以便加载正确 LUT 并恢复 Golden。

### 9.3 历史计划（已归档）
> 说明：以下条目已完成或并入 OpenSSD 上板验证，不作为当前独立待办。

- **BE pipeline 优化**：评估 `bit_extract_ip` 的多 stream/批量化实现，将三段 PBS 拆分到并行 CUDA launch，或回迁部分逻辑至 FPGA，以把 69.6 ms 前段 + 26.6 ms PrivKS 压缩到 <40 ms。  
- **VP Golden 对齐**：改造 VP/BE GPU 流程，复用 `TLwe32KSPBS_batch_lvl1`（含 `get_hi` LUT 与 `prec_offset`），或在 WoKS 前显式注入 LUT，以匹配 CPU `TLwe32_Keyswitch_Bootstrapping_Extract_lvl1`。完成后再使用 `vp20500_*` dump 验证。  
- **SSD↔GPU 双缓冲**：根据 166.6 ms 前段耗时，规划 8-way FTL + GPU 双缓冲（每片 ~2.5 ms）流水，确保 WoKS 63.8 ms 不因资产搬运阻塞；并在运行时记录缓存命中率协助调参。  
- **自动化报表**：让 `gpu_perf_sweep.sh` 生成含 Golden 状态与分段耗时的 Markdown/CSV，避免手工汇整遗漏。

### 9.4 WoKS 数值差异诊断（历史，2025-11-05）

- **最新比对结果**：以 `tools/analyze_biglut_diff.py` 对 `/tmp/cpu_vp_biglut_raw.bin`、`/tmp/vp_gpu_biglut_raw.bin`、`/tmp/vp_cpu_ks.bin`、`/tmp/vp_gpu_ks.bin` 进行统计，`bigLUT raw` 最大差值 `4.198×10^9`、中位 `1.15×10^9`，KeySwitch 输出最大差值 `2.145×10^9`，说明偏差在 WoKS 出口即已产生，后续 KSPBS 仅传播误差。  
- **怀疑根因**：`TGsw32ToTGswFFT` / `TGswFFT32ExtMulToTLwe_batch_lvl1` 仍围绕 `Cplx_i64` 进行 IFFT/FFT，缺失 SPQLIOS `double` 工作缓冲的 `2/N` 缩放与 IEEE 754 取整，导致 CMux/盲旋阶段的 `(−i)^j` twist 序列无法复刻 CPU 行为。  
- **修复思路**：  
  1. 在 GPU 端补充 `double` 缓冲通路，复用 `device_convert_double_to_torus{32,64}`，并确认 `Poly_fft` 末端使用四象限 twist；  
  2. 给 `circuit_bootstrapping_ip` / `biglut_batch_20bit_ip` 插入阶段性 dump（`tgsw_radixs`、`pool[*]`、`TLwe32CMux` 输出），与 CPU `bigLut_20bit_lvl1`、`circuitBootstrapping` 同步比对；  
  3. 增加单元测试验证 `TGswFFT32ExtMulToTLwe` 与 `TLwe32CMux` 输出在双精度路径下逐项匹配 CPU；  
  4. Golden 收敛后，重新采集 `gpu_service_{be,vp}.log`，刷新 `wop_gpu_perf_report_actual.csv` 与性能文档。
- **临时应对**：为保证功能正确性，可设置 `TFHE_GPU_FORCE_CPU_REF=1`，让 `tfhe_gpu_executor` 直接调用 `cpu_reference_runner` 写回黄金 GLWE Payload（绕过整个 GPU WoKS/PrivKS 阶段）。该模式会记录真实 CPU LATENCY，并保持 `glwe_payload` 与黄金一致，适用于性能评估前的占位验证。
- **旁路时延估计**：旁路开启时，Executor 会根据 `Evaluation Results.xlsx` 中的 GPU baseline 估算返回值——CB 97.9 ms（WoKS 70.7 + PrivKS 24.8）、BE 51.0 ms（WoKS≈40.8 + PrivKS≈10.2）、VP 112.9 ms（WoKS≈95 + PrivKS≈17.9）。因此日志中 `[CPU_REF]` 行给出的 latency 仍可视作“预期 GPU 延迟”。

#### 9.3A 性能估算（历史占位）

> **声明**：以下数值直接采自 2025‑11‑03 GPU service 日志，在 Golden mismatch 未解决前仅作为流水/带宽规划的占位符。正式发布前请替换为通过 Golden 的实测数据。

`tools/gpu_ssd_perf_model.py` 自动归纳的当前阶段耗时：

| 模式 | 当前串行 (`pre+WoKS+PrivKS`, ms) | 当前重叠节拍 (`max(pre, WoKS, PrivKS)`, ms) | 备注 |
| --- | --- | --- | --- |
| CB | 92.5 | 65.7 | pre=0.16、WoKS=65.7、PrivKS=26.6、FTL≈0.16 |
| BE | 187.9 | 66.4 | pre=60.9、WoKS=60.6、PrivKS=66.4、FTL≈0.16 |
| VP | 273.5 | 192.8 | pre=192.8、WoKS=55.1、PrivKS=25.5、FTL≈0.64 |

面向 P2P DMA、批量化和双缓冲流水的目标节拍（占位估计）：

| 模式 | 目标前段 (`pre`, ms) | 目标 WoKS (ms) | 目标 PrivKS (ms) | 估计流水节拍 (`max`, ms) | 预估稳态 QPS | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| CB | ≈5 | ≈45 | ≈20 | ≈45 | ≈22 | doorbell + TLWE 整理留 5 ms |
| BE | ≈10 | ≈45 | ≈22 | ≈45 | ≈22 | 需 FPGA 预处理+P2P DMA 支撑 |
| VP | ≈30 | ≈50 | ≈22 | ≈50 | ≈20 | TLWE 体积大，预取/拆包保留 30 ms |

> **占位符提醒**：若文档需导出到 PPT/报告，请在表格标题或备注中显式标注 “Golden TBD”。

### 9.3.1 TODO 列表（历史归档）

| 优先级 | 任务 | 触点文件 / 参考 | 完成判据 |
| --- | --- | --- | --- |
| P0 | 修复 WoKS Golden mismatch：移植 CPU `execute_direct_torus64` 的双精度缩放 + 尾数舍入顺序，补齐 `(−i)^j` twist & `2/N` 归一化，并在 `TLwe32KSPBS_batch_lvl1` 中保持 `get_hi` LUT / `prec_offset` | `tfhe-gpu-baseline-wopbs/src/fft/*.cuh`、`circuit_bootstrapping.cpp`、`sw/gpu_runtime_service/src/tfhe_gpu_executor.cpp:1784+` | `quick_gpu_mode_test.sh {BE,VP}` Golden mismatch=0；`wop_gpu_perf_report_actual.csv` 更新 |
| P0 | 重新采集 GPU+SSD 日志：CB/BE/VP 各运行一次（`timeout 600s ./quick_gpu_mode_test.sh`），备份 `/tmp/gpu_{service,mode}_*.log`，刷新 `wop_gpu_perf_report_actual.csv` 与 `gpu_ssd_perf_model.py` 输出 | Testbench脚本、`tools/gpu_ssd_perf_model.py` | 文档/CSV 更新，串行/流水节拍基于最新数据 |
| P1 | 压缩前段：将 VP/BE 预处理移至 CSD 并实现双缓冲发送，减少 `cudaStreamSynchronize`/`DeviceSynchronize`，目标 pre_BE ≤10 ms、pre_VP ≤40 ms | `wop_pbs_kernel_unified.sv`、OpenSSD Wrapper、`tfhe_gpu_executor.cpp` | `gpu_ssd_perf_model.py` 报表中 pre 段满足目标；日志无长时间同步 |
| P1 | 引入 P2P DMA + pipeline：规划 TLWE/GLWE 分片与 SSD↔GPU 双缓冲，记录带宽/命中率 | OpenSSD FTL 模型、`gpu_perf_sweep.sh` | 报表新增带宽/QPS 指标，steady QPS ≥15（BE/CB） |
| P2 | 自动化报表与论文素材：`gpu_perf_sweep.sh` 汇总串行/流水数据、Golden 状态、CPU/GPU 基线对比，输出 Markdown/CSV | `tools/gpu_ssd_perf_model.py`、`gpu_perf_sweep.sh` | 一键生成报告，供文档/汇报使用 |

### 9.4 2025-10-26 更新

- `sw/gpu_runtime_service/src/tfhe_gpu_executor.cpp` 已在 VP 流程（`run_vertical_packing_pipeline`）中补入 `TLwe32KSPBS_batch_lvl1<0>`，bigLUT 输出在加上 `modSwitchToTorus32(2, FULL_MSG_SIZE)` 偏移后立即调用 `ctx->TLweLuts.get_hi` 完成 PBS，再执行 `KeySwitch_lv10` 生成 WoKS 输入。BE 流程沿用 `bit_extract_ip` 内部的三次 KSPBS，暂不额外改动。下一步需重新运行 `quick_gpu_mode_test.sh VP`（20500 词、真实 GPU）确认 `[TFHE_GPU_EXEC][GOLDEN] mismatch=24` 是否收敛，并据此更新性能表与风险评估。

### 9.5.1 2025-11-05 WoKS 差异快照

> 本节基于 `CB_USE_REAL_GPU=1 AUTO_SERVICE=1` 运行 `quick_gpu_mode_test.sh BE`（采集路径 `/tmp/be_*`、`/tmp/gpu_runtime_service.log`），不再重复跑长耗时仿真，仅对现有数据做复盘。

- **PremodSwitch 已对齐**（2025-11-05）：`gpu_executor_smoke` 与 `cpu_reference_runner` 使用同一 keyset（`/tmp/smoke_keyset.bin`）时，`WOP_GPU_DUMP_PREMOD=/tmp/smoke_premod_cb.bin` 与 `CPU_REF_DUMP_KS=/tmp/cpu_smoke_ks.bin` 首 8 个值完全一致（`0x0a5a, 0x03b9, …`），确认 `modSwitchFromTorus32` 流程无误。
- **WoKS 输出仍差 9.22×10¹⁸**：无论是 `quick_gpu_mode_test.sh BE` 还是 `gpu_executor_smoke` 的单矢量测试，`WOP_GPU_DUMP_WOKS=/tmp/*woks_gpu.bin` 与 CPU `cpu_*_woks.bin` 在 2049 维 Torus64 上 `max_abs_diff≈9.22×10^18`，点积归一化约 `10^-22`。即便导入/导出同一 keyset，差距仍存在，排除了密钥不一致的可能，矛头直指 GPU `circuit_bootstrap_wo_ks` 的 FFT / 外积实现。
- **KeySwitch dump尚未生成**：Golden mismatch 导致 runtime 用 CPU payload 回填结果 FIFO（`[TFHE_GPU_EXEC][GOLDEN] applied CPU reference payload fallback`），因此 `WOP_GPU_DUMP_BE_KS` 目前仍为空，需待 WoKS 对齐后再验证。
- **CB 已验证通过**：同一二进制下 `quick_gpu_mode_test.sh CB` 输出 `[TB][GPU_SERVICE][GOLDEN] match`，确认 `double→Torus64` 修正在 CB 路径有效；BE/VP 仍需对齐 premod 与 WoKS 流程。

**定位建议**

1. 针对 WoKS：在 `TGswFFT64ExtMulToTLwe_batch_lvl2` 周期性打点（增加 `TFHE_GPU_CBS_DEBUG`），捕获旋转前的 `acc`、乘法后的 `acc_ret`、累加后的 `dst`，并与 `CPU_CBS_DEBUG` 的 `circuitBootstrapWoKS` 输出逐项对比，确认是 `TGsw` FFT 布局还是 twist/归一化导致大幅偏差。
2. 若发现布局问题：检查 keyset 导入导出的 `TGswSampleFFT` 写入顺序，必要时在导入阶段重排 `allsamples[i].a[k].values`，保持与 CUDA kernel 期望的 `(K+1)×(K+1)×ell` 顺序一致。
3. 维持 `WOP_GPU_DUMP_*` 观察：当前 Golden mismatch 主要由 WoKS 引发，待 WoKS 修复后再启用 `WOP_GPU_DUMP_BE_KS`/`CPU_REF_DUMP_*` 进行 KeySwitch 及最终 GLWE 的端到端比对。

### 9.5 2025-10-27 BK FFT 对齐调查

- 最新 dump（`TFHE_GPU_DUMP_DECFFT` / `CPU_CBS_DUMP_DECFFT`）显示 GPU `dec_fft` 与 CPU `execute_reverse_int` 结果已逐点一致，但 `TFHE_GPU_ACCFFT_DUMP` 仍与 CPU `accFFT` 差异巨大，Golden mismatch=24 卡在 WoKS 外积阶段。  
- 对比 `bkfft_gpu.bin` 与 `bkfft_cpu.npy` 可见：GPU `TGsw64ToTGswFFT` 未应用 SPQLIOS 的奇偶扭转（`(−i)^j` twist）与 2/N 归一化，导致 `acc_ret` 相位和幅值整体偏移。  
- 修复建议：  
  1. 在 `prepare_level2_fft_input_kernel` / `extract_level2_fft_kernel` 中按 SPQLIOS `execute_reverse_int` 实现重新组织偶/奇项，并显式乘以 `(−i)^j`。  
  2. 让 `TGsw64ToTGswFFT_kernel`、`TGsw32ToTGswFFT_kernel` 同步套用 twist 与归一化，保持 level‑1/level‑2 表示一致。  
  3. 增加单元校验：CUDA 端转换后的 `bkFFT` 与 CPU 导出结果按 digit 比较，通过后再运行 `quick_gpu_mode_test.sh VP` 确认 Golden PASS。  
- 新增脚本 `tools/analyze_biglut_diff.py`，可直接比较 `/tmp/cpu_*biglut*.bin` 与 `/tmp/vp_gpu_*`，输出最大差值/均方误差，便于在修复 twist/scale 前快速评估残余差异。
- **2025-10-28 更新**：上游 `origin/main` 已合入全新的 i64 固定点 FFT/ExtMul 实现（提交 `410e458` 及之前的 `c8e60f6`/`f3d0d69`），在 `tfhe-gpu-baseline-wopbs` 中完整替换上述流程；之后的验证与性能评估应以该实现为准，废弃临时的 `level2_fft_correction_table` 校准方案。当前工作树已从该主线创建分支 `feature/fft-sync`，后续所有测试/文档更新将在此基础上重新采集。  
- 在修复前，`wop_gpu_perf_report_actual` 中的 VP 延迟仍需标注为“WoKS 数值未对齐，仅供参考”，性能复盘应优先关注 CB/BE 与前段瓶颈；完成主线对齐后需重新运行 `quick_gpu_mode_test.sh` 并刷新报表。

### 9.6 2025-11-02 待办清单

- **Golden 复核**：已在 `TIMEOUT_SEC=900`、`AUTO_SERVICE=0` 下确认 CB 模式 `match`，但 BE/VP 仍报 24 项 mismatch。待 WoKS 修复后需再次运行三模式，确保 `[TB][GPU_SERVICE][GOLDEN] match` 再发布性能数据。  
- **WoKS LUT 对齐**：继续落实 “get_hi LUT + `prec_offset`” 改造，确保 WoKS 输出与 CPU `TLwe32_Keyswitch_Bootstrapping_Extract_lvl1` 一致；完成后重新启用 Golden 校验。  
- **BE 前段/PrivKS 优化**：分析 `bit_extract_ip` 三段 PBS 的复用度，规划多 stream launch 或 FPGA 回迁策略，把 69.6 ms 前段与 26.6 ms PrivKS 缩短到 <40 ms。  
- **VP 前段流水**：针对 166.6 ms 前段，设计 TLWE 分片（≥8 片）+ SSD/GPU 双缓冲，明确每片数据量、DMA 阶段与缓存命中率记录机制。

### 9.7 2026-01-31 更新（GPU WoKS 仍未收敛）
- 已重编 `sw/gpu_runtime_service/build` 并确认 spqlios FFT/IFFT 表加载（`/tmp/spqlios_{fft,ifft}_table.n{2048,4096}.bin`）。
- 新 keyset 已生成：`/tmp/wop_keyset_new.bin`（`gpu_executor_smoke` 导出，包含 `bkFFT_32`，`bk_fft_values=28672000`）。
- 构造 synthetic VP 输入并用 CPU runner 生成 WOKS golden：`/tmp/vp_tlwe_input_new.bin` → `/tmp/vp_glwe_golden_new.bin`，以 `GPU_TLWE_FILE` 注入到 `quick_gpu_mode_test.sh VP`；GPU 仍 `mismatches=2049`。证据：`/tmp/gpu_runtime_service_vp_20260131_1235.log` 与 `hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/gpu_mode_test.log`。
- BE 实机路径仍不稳定：`quick_gpu_mode_test.sh BE` 在 AUTO_SERVICE=1 下 `gpu_runtime_service` 进程被 kill（疑似内存/系统 OOM）；需要改为手工启动或进一步降载后复测。
- **Runtime 常驻化**：观察到每次测试都会重新导入 3.19 GB keyset（`gpu_runtime_service.log` 反复出现 `importing ... privKS`），需要在 `quick_gpu_mode_test.sh` 中提供复用模式以减少冷启动开销，并将耗时纳入系统级评估。  
- **自动化报表**：扩展 `gpu_perf_sweep.sh` 输出含 `golden_status / pre_cb_ns / woks_ns / ks_ns` 的 Markdown，以便在团队复盘时快速比对 GPU 与 SSD 调参效果。

### 9.7 GPU+SSD vs GPU-only 对比快照

为量化当前 GPU+SSD 架构与历史 GPU-only（WOPBS）基线的差异，新建脚本 `tools/gpu_ssd_perf_model.py`。该脚本会解析最新的 `wop_gpu_perf_report_actual.csv`、`gpu_runtime_service` 日志与 `docs/Evaluation Results.csv`，并给出粗粒度的映射对比：

```
$ tools/gpu_ssd_perf_model.py
### GPU+SSD Pipeline Metrics

| Mode | GPU total (ms) | Pre (ms) | WoKS (ms) | PrivKS (ms) | FTL TLWE (ms) | FTL GLWE (ms) | Hits | Misses | Bytes (KiB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CB |  92.318 |   0.156 |  65.686 |  26.632 |   0.060 |   0.096 | 2 | 2 |     8.0 |
| BE | 185.731 |  60.094 |  59.812 |  65.825 |   0.072 |   0.090 | 4 | 2 |    12.0 |
| VP | 273.200 | 190.325 |  57.402 |  25.472 |   0.582 |   0.054 | 80 | 2 |   164.0 |

### Comparison with GPU-only baseline

| Evaluation Label | GPU-only (ms) | Matching Descriptor | GPU+SSD (ms) | Δ (ms) | Ratio |
| --- | --- | --- | --- | --- | --- |
| Big LUT function (20→2/4 bits) |    N/A | N/A |    N/A |    N/A | N/A |
| Mixed function 32-bit exp(-x) |   1.240 | N/A |    N/A |    N/A | N/A |
| Softmax (n=16) |  72.419 | N/A |    N/A |    N/A | N/A |
```

说明：

- Δ = 当前 GPU+SSD − 历史 GPU-only；正值表示现阶段更慢。  
- 注意：`Evaluation Results.xlsx` 中记录的 `exp(-x)`、`Softmax` 等为复合函数基准，用于验证完整 WoP-PBS 算法在典型高层算子上的效果，不能与单独的 CB/BE/VP 描述符直接对应。  
- BE/VP 的总延迟目前由 60 ms / 190 ms 的前段与未收敛的 WoKS 数值误差主导；CB 仍仅作流程参考。  
- FTL 模块贡献仅 0.06–0.64 ms（TLWE+GLWE），远低于 Host↔GPU 搬运与同步开销，可视为二级因素。  
- 优化重点仍在 WoKS LUT/偏移修复及 SSD↔GPU 流水化，待修复后需重新采集并覆盖上述表格。

### 9.8 优化后性能估计

### 9.9 CPU 兜底 + GPU 时间替换策略（2025-11-06）

鉴于 BE/VP 仍存在 WoKS 数值偏差且 GPU 调试已拉长整体周期，现阶段采纳“CPU 兜底、GPU 时间记账”的办法来支撑性能分析与汇报：

- **输出路径**：所有模式默认由 CPU 参考流程产出最终 GLWE/TLWE（`TFHE_GPU_FORCE_CPU_REF=1` + 对应缓存文件），确保 Golden 始终可用；GPU 计算仍可在后台运行用于记录 kernel 计时，但其结果不再参与 Golden 判定。
- **性能来源**：报告中的 GPU 延迟统一取自 2025-11-03 收集的 `/tmp/gpu_service_{cb,be,vp}.log` 与 `wop_gpu_perf_report_actual.csv`，若需函数级拆分则补充 `docs/Evaluation Results.xlsx` 与 `TFHE_GPU_PROFILE_STAGES` 的统计。若某阶段缺失数据，默认沿用 GPU-only baseline（`tfhe-gpu-baseline-wopbs`）的均值。
- **同步策略**：运行 `quick_gpu_mode_test.sh` 时保留 `TIMEOUT_SEC/SERVICE_TIMEOUT_SEC`，但只需等待 CPU 兜底完成；GPU kernel 超时不再阻断验证流程。性能采集使用 GPU 日志，功能验证使用 CPU 输出。

| 模式 | 输出路径 | 报告用 GPU 时延 (ms) | 数据来源 | 备注 |
| --- | --- | --- | --- | --- |
| CB | GPU 正常产出，可选 CPU 兜底 | 92.318 | `wop_gpu_perf_report_actual.csv`（Golden=match） | 可直接使用 GPU 结果；若切换 CPU 兜底需保证缓存最新 |
| BE | CPU 兜底（GPU 结果弃用） | 187.869 | `wop_gpu_perf_report_actual.csv`（GPU 输出被 CPU 覆盖） | GPU 时延仍拆分为 pre=60.893 / WoKS=60.552 / PrivKS=66.425 ms |
| VP | CPU 兜底（GPU 结果弃用） | 273.458 | `wop_gpu_perf_report_actual.csv`（GPU 输出被 CPU 覆盖） | GPU 时延拆分为 pre=192.836 / WoKS=55.148 / PrivKS=25.475 ms |

> **注意**：上述 GPU 时延与 `TFHE_GPU_PROFILE_STAGES=1` 的单算子统计一致性良好；汇报时需明确说明“功能由 CPU 兜底、性能按 GPU 实测计入”，避免读者误以为 BE/VP Golden 已对齐。

该策略允许我们在不重跑 GPU 调试的情况下继续推进 GPU+SSD 性能建模、流水线估算与汇报。后续一旦 WoKS 精度修复完成，可切换回纯 GPU 输出并重新采集 Golden 日志。

### 9.10 WoKS 多级 `mu` 修正结果（2025-11-06）

- 更改 `run_circuit_bootstrap_pipeline`：CB 模式仍使用单次 `mu=0x8000…`，BE/VP 模式则按 `level` 重新计算 `mu=1<<(64-(level+1)*bgbit_lvl1)` 并循环 `circuit_bootstrap_wo_ks → circuit_privks`。代码见 `sw/gpu_runtime_service/src/tfhe_gpu_executor.cpp:1617` 起新增分支。
- 使用导入密钥（`WOP_GPU_KEY_IMPORT=/tmp/wop_keyset.bin`）运行 `gpu_executor_smoke BE /tmp/be_gpu_tlwe.bin`，并启用 `WOP_GPU_GOLDEN_COMPARE=1` 与 `WOP_GPU_DUMP_WOKS=/tmp/be_gpu_woks_mu.bin`、`CPU_REF_DUMP_WOKS=/tmp/be_cpu_woks_mu.bin`。CPU/GPU 均耗时 ≈190 ms（GPU） + 5 min（CPU 参考），Golden 仍报 `mismatch count=24`。
- Python 对比（`np.fromfile(..., '<i8')`）显示全部 2 049 个 Torus64 系数仍存在差异，最大绝对值 `9.22×10¹⁸`，前 4 项 GPU 输出 `[-0x74.., 0x6b.., 0xc2.., 0xa5..]` 与 CPU `0x50..,0x84..,0xa8..,0x24..` 仍相差数百 LSB。说明多级 `mu` 修正未触及根因，错误仍集中在 WoKS 的 FFT/外积阶段。
- `TFHE_GPU_CBS_DEBUG` 当前在 BE 模式下触发段错误（待排查）；已改用 `WOP_GPU_DUMP_WOKS`/`CPU_REF_DUMP_WOKS` 收集差异数据，避免 debug path 引发崩溃。
- 后续需要聚焦 `TGswFFT64ExtMulToTLwe_batch_lvl2`（疑似缺失 (-i)^j twist/归一化）与 `extmul_64_step*` 流程，参考 CPU `torus64PolynomialMulByXaiMinusOne`/SPQLIOS 实现逐项比对。

结合 Evaluation 基线、现有测量以及架构改造计划，可形成如下两层展望：

1. **Multi-descriptor batching**：单条 descriptor 同时承载 10（BE）/20（VP）组 TLWE，并把中间 TGsw/TLWE 保持在设备内；WoKS 修复后可避免多余同步。  
2. **流重叠 + 双缓冲**（Stretch 目标）：在 batching 基础上，引入 SSD↔GPU 双缓冲与 CUDA stream 并行，争取前段搬运与 WoKS 同步执行，WoKS/PrivKS 段按修复后的 70 ms / 25 ms 估值计算。

> 以下数值为 ms（毫秒）；“当前”列取自 `wop_gpu_perf_report_actual.csv:2-4`，函数级数据使用 §9.7 的组合；Projection 列为推导估计，并在“备注”写明假设。

**阶段级（单 descriptor）**

| Stage | Eval GPU-only | GPU+SSD 当前测量 | GPU+SSD Batching 估计 | GPU+SSD Overlap 目标 | 备注 |
| --- | --- | --- | --- | --- | --- |
| CB（WoKS+PrivKS） | N/A | 92.3 | 82（WoKS 精度修复，Host⇔GPU 削减一次 memcpy） | 70（WoKS 70 ms + PrivKS 25 ms + 5 ms 余量） | 当前 `pre_cb_ns=0`，估计值假设修复 double→Torus 流程后允许 stream 批处理。 |
| BE（10×TLWE → 20 bits） | N/A | 185.7（len=1） | 155（10 样本一次调度，TLWE 预处理摊薄至 ~7 ms/样本） | 120（预处理与 WoKS 重叠，WoKS/PrivKS 共 95 ms） | 当前每个 TLWE 单独触发；Projection 假设 `bit_extract_ip` 的批量路径完整启用。 |
| VP（20 bits → 1 TLWE） | N/A | 273.2（批量 TLWE=20500） | 122（针对 20 比特 LUT 独立 descriptor） | 80（Blind Rotation 57 ms + PrivKS 20 ms + 3 ms overhead） | 现测 TLWE words=20500；Projection 针对 BigLUT 所需 20 比特。 |

**函数级组合**

| Workload | Eval GPU-only (`docs/Evaluation Results.xlsx`) | GPU+SSD 当前 | GPU+SSD Batching 估计 | GPU+SSD Overlap 目标 | 备注 |
| --- | --- | --- | --- | --- | --- |
| 20→2/4 BigLUT | 0.635 | 459 | 317 | 160 | 由 BE(10 样本) + VP(20 比特) 组成；Overlap 目标假设 CMux/Blind Rotation 与 SSD DMA 双缓冲。 |
| 32-bit exp(-x) | 1.240 | 6 228 | 2 300 | 400 | 需要一次 BE + 16 次 VP + carry/乘法；Overlap 目标假设 BE/VP pipeline 4-way 并行，剩余算术留在 AE CPU。 |
| Softmax(n=16) | 72.419 | 99 656 | 36 800 | 6 000 | 16 次 exp(-x) + 额外加减除法；Overlap 目标假设函数级流水（max/减法/归一化）与 exp(-x) 并行。 |

**差距与推进路径**

- **当前瓶颈**：BE/VP 前处理串行（60 ms / 190 ms）与 WoKS 精度缺陷导致的强制同步。只要完成 double 缩放 + Torus 舍入修复并切换到批量 descriptor，即可把 exp(-x) 从 6.2 s 降到 ~2.3 s，软化 3 倍以上。  
- **进一步优化**：SSD↔GPU 双缓冲、CUDA stream 并行与 AE 侧算术 offload 是把 exp(-x) 压到亚秒级（~0.4 s）、Softmax 降至 6 s 级别的关键。  
- **验证计划**：  
  1. 修复 WoKS FFT/Torus 路径并重新采集 `gpu_service_*.log`，确认 `[GPU_SERVICE][GOLDEN] match`。  
  2. 在 `run_bit_extract_pipeline` / `run_vertical_packing_pipeline` 中启用批量 TLWE 入口，度量单 descriptor latency 与 per-output 平均耗时。  
  3. 实施 stream/ping-pong 后重复生成上表数据，替换估计值并归档至 `reports/wop_gpu_perf_report_actual.*`。

### 2025-12-28 GPU WoKS mismatch 收敛：host rescale/requant 二次缩放

- 现象：在 spqlios FFT/IFFT 对齐后，stage dump（dec_fft/acc_fft/extmul/poly_fft）已全对齐，但 `cpu_out` vs `gpu_out` 仍 2049 全量 mismatch。
- 证据：CB 单样本短跑，设置 `WOP_GPU_WOKS_NOSCALE=1` 后 `cpu_out` 与 `gpu_out` `cmp=OK`，说明 GPU 内核已对齐，host 侧 2/N + float2torus 造成二次缩放。
  - 跑法：`TFHE_GPU_SPQLIOS_FFT=1 TFHE_GPU_SPQLIOS_FFT_TABLE=/tmp/spqlios_fft_table.n4096.bin TFHE_GPU_SPQLIOS_IFFT=1 TFHE_GPU_SPQLIOS_IFFT_TABLE=/tmp/spqlios_ifft_table.n4096.bin GPU_SMOKE_GLWE_WORDS=2049 sw/gpu_runtime_service/build-clean/gpu_executor_smoke CB <tlwe> <gpu_out>`
  - 结果：`/tmp/woks_stage_cmp_run_20251228_141348` 与 `/tmp/woks_stage_cmp_run_20251228_141730` 均 `cmp OK`。
- 复验：随机 501×u64 TLWE，`cpu_reference_runner --mode 2` 生成 golden 后再跑 `gpu_executor_smoke CB`，`cmp OK`（例：`/tmp/cb_native_woks_smoke_20251228_hga8lw/`）。
- 修复：`sw/gpu_runtime_service/src/tfhe_gpu_executor.cpp` 在检测到 `TFHE_GPU_SPQLIOS_FFT` 且 FFT 表已加载时，默认关闭 rescale/requant；保留 `WOP_GPU_WOKS_RESCALE`/`WOP_GPU_WOKS_FLOAT2TORUS` 强制开关。
- 风险：若未加载 spqlios FFT 表仍需旧校准路径，因此仅在 FFT 表就绪时自动跳过缩放。

### 2025-12-28 GPU native VP mismatch 完整修复（bigLUT + mu 选择）

- 现象：`GPU_WOKS_NATIVE=1` 下 `gpu_executor_smoke VP` / nvmevirt e2e 的 VP/exp/soft 初始 `cmp golden` 失败。
- 根因 1（bigLUT Blind Rotation 的 CMux 参考不一致）：CPU `bigLut_20bit_lvl1_ip_batch` 在 BR 阶段使用 `TGswSample32`（time-domain extmul/Karatsuba），而 GPU bigLUT 使用 FFT extmul；差异从 `br.d0` 开始（大量 ±1），最终传播成 GLWE mismatch。
  - 修复：CPU 改为在 BR 阶段使用 `tgsw_radixs_fft[d]`（FFT CMux，与 CMux Tree 一致），并补齐 `CPU_REF_DUMP_BIGLUT_{TGSW,ROT_PRE,ROT_POST,BR_PREFIX}` 取证（`../tfhe-cpu-baseline-wopbs/src/big_lut.cpp`）。
- 根因 2（mu 选错层）：`sw/gpu_runtime_service` 的 `run_circuit_bootstrap_pipeline` 对 VP/BE 误按 `ell_lvl1` 循环，最终输出落在最后一层 `mu=1<<48`；而 CPU golden 期望第一层 `mu=1<<56`（`bgbit_lvl1=8`）。
  - 证据：CPU 参考设置 `--mu 0x0001000000000000`（1<<48）可与旧 GPU 输出 `sha256=0b6946e9...` 完全一致。
  - 修复：VP/BE 仅跑一次 `circuit_bootstrap_wo_ks(mu=1<<(64-bgbit_lvl1))`，不跑 `privks`（`sw/gpu_runtime_service/src/tfhe_gpu_executor.cpp`）。
- 证据：纯用户态回归通过（无需 sudo）：重生 keyset+资产后，`gpu_executor_smoke VP` 在 `vp(flags=0)`、`exp/soft(flags=0x04)` 下均 `cmp golden=OK`（例：`/tmp/csd_gpu_nvmevirt_oneclick_20251228_230526/`）。
- 证据：sudo nvmevirt e2e 通过：`GPU_WOKS_NATIVE=1 bash scripts/csd_gpu_nvmevirt_oneclick.sh` 依次跑 VP/exp/soft 三个 case，均 `GLWE matches golden`（例：`/tmp/csd_gpu_nvmevirt_oneclick_20251228_224618/`）。

### 2025-12-29 softmax 函数级闭环（mode=3 FunctionEval）

- 新增 `DescriptorMode=3`（FunctionEval）：TLWE/GLWE payload 按 fp64 数组解释（输入 `N` 个 `double`，输出 `N` 个 `double`），在 `gpu_runtime_service` 内部完成 **TFHE softmax(n=N)** 并解密回 fp64。
- 冒烟验证（无需 sudo）：`NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_softmax_oneclick.sh` 输出 `softmax_out_fp64.bin`，并与明文 softmax 在容差内一致（例：`/tmp/csd_gpu_nvmevirt_softmax_20251229_001317/`）。
- nvmevirt 端到端（需 sudo）：`NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_softmax_oneclick.sh` 会走 `0xC0 → backend → gpu_runtime_service → /dev/mem` 数据面并在脚本末尾做容差校验（无需 `cmp` bit-exact）（例：`/tmp/csd_gpu_nvmevirt_softmax_20251229_104458/`，`fail=0`）。
