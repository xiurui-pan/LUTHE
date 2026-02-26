# Mock GPU 性能模型实施方案
> 更新（2026-02-02）：该方案已完成并归档；nvmevirt e2e 闭环已通过。当前仅剩 OpenSSD 实物上板与板级时间线/流水线重叠取证（并入上板阶段），本文其余内容作为历史记录保留。

## 1. 背景与目标
- OpenSSD ↔ WoP-PBS 统一内核已具备门铃、Descriptor、Result Status 全链路。
- 真实 GPU 集成短期内难以完成，需要性能仿真 mock 评估大 LUT 与端到端推理吞吐。
- 本方案在保持外部接口语义不变的前提下，构建可配置 GPU 性能模型并嵌入现有工作流，让测试者察觉不到 mock 行为。

## 2. 范围界定
- **覆盖接口**：AXI-Lite 控制寄存器、Descriptor DMA、WoKS 流接口、Result Status 写回。
- **输出内容**：端到端延迟、访存带宽、流水吞吐等指标，附聚合统计报告。
- **排除项**：真实 CUDA/ROCm 内核实现、实际 NAND 侧 DMA；硬件上板验证暂不在本阶段。

## 3. 阶段与里程碑
| 阶段 | 时间 | 关键产出 |
| --- | --- | --- |
| A. 接口基线 | Day 0-1 | 寄存器/doorbell/Result Status 文档、quick_cb_test 缩参冒烟脚本 |
| B. GPU Mock Runtime | Day 2-4 | C++/Python 双入口 mock 核心，支持可调 Pre-KS 收集、访存突发、PIPELINE_LATENCY |
| C. 双端集成 | Day 5-7 | TB DPI/host stub 接入，冒烟日志确认 `[KS_RESULT_DBG]`、`KS command accepted`（或 CB 短跑等效指标）及 `[TB][MOCK_GPU][SUMMARY]` 聚合统计稳定 |
| D. GPU Runtime 服务化 | Day 8-9 | 引入真实 GPU runtime 服务（socket+shm），跑通 `quick_cb_test` 实际 CUDA 计算 |
| E. 性能测量框架 | Day 10-11 | 参数扫描脚本、CSV/Markdown 报告、统计结果嵌入日志 |
| F. 扩展收尾 | Day 12-13 | 大 LUT/端到端推理样例、README/真实 GPU 切换指南、替换注意事项 |

> **进展速记（2025-10-18）**
> - `quick_cb_test.sh` 在 `CB_USE_REAL_GPU=1`、RTX 6000 环境下成功调用常驻 `gpu_runtime_service`，日志出现 `[TB][GPU_SERVICE][PAYLOAD]` / `[TB][GPU_SERVICE][SCORE]`，Result Status latency 记录 ~49 ms，带宽计数与 TLWE/GLWE 长度一致。
> - 新增 `quick_gpu_mode_test.sh`（VP/BE/CB 通用）：脚本自动配置 `CB_TARGET_MODE`、TLWE/GLWE word 数，触发 doorbell→GPU WoKS→Result Status 全链路；VP/BE 在真实 GPU 上实测 TLWE=631 word 时得到 WoKS latency ≈31 ms，GLWE 回写默认为 2049×64-bit（≈16 KiB），脚本检查 `[TB][GPU_SERVICE][SCORE]`、Host ACK 等证据。
> - Testbench scoreboard/Result Status 改为 real 模式动态缓冲：`reserved0` 高位标记真实 GPU 路径与 Golden mismatch，低 14 bit 回显 GPU batch 序号；`reserved1` 写入 KS 阶段耗时（ns，截断 32 bit），日志仍打印 TLWE/GLWE 吞吐统计；`USE_GPU_RESULT_STUB` 在 real 模式下自动关闭。
> - DPI 桥 `gpu_service_dpi.cc` 新增 `tlwe_bytes/glwe_bytes` 显式参数并支持 `WOP_GPU_DPI_DEBUG`，修复 `payload size is not aligned` 报错；socket 路径通过 `WOP_GPU_RUNTIME_SOCKET` 配置，避免与旧服务冲突。
> - `gpu_runtime_service` 真实路径返回 `latency_ns≈3.1e7`（VP/BE）与 `latency_ns≈5.3e7`（CB）等测量值，`[TFHE_GPU_EXEC]` 日志显示 CUDA WoKS 实际执行，保留 mock 回落日志以便诊断。
> - Testbench scoreboard 自动将 descriptor 中 `tlwe_words` 裁剪到 `REAL_PREKS_LEN=33`，VP/BE 模式不再卡在 631-word 预期。
> - 新增 `scripts/gpu_perf_sweep.sh`：自动/手动启动 GPU 服务，串行跑 CB/VP/BE，解析 `[GPU_SERVICE][SCORE]` 生成 `wop_gpu_perf_report.csv`，并可对照 `tfhe-cpu-baseline-wopbs` 汇总加速比。
>
> **进展速记（2025-10-19）**
> - `run.sh` 默认 `TLWE_WORDS_CFG=N_LVL0+1`，`quick_gpu_mode_test.sh` 在 `CB_USE_REAL_GPU=1` 下自动使用 631 词流（CB 仍可通过 `CB_TLWE_WORDS` 缩参）。
> - Testbench FTL mock 升级为 DaisyPlus 风格分页调度：单页 256 words、`FTL_MAX_OUTSTANDING=4`，动态生成 `[FTL_MOCK][REQ|DONE|SUMMARY]` 日志，命中窗口 4096 bytes（默认 miss penalty≈2400 cycles），GPU 提交需等待 staging 全部完成；`FTL_*` plusarg 与 `+MAX_CYCLES` 可调。
> - `quick_gpu_mode_test.sh` 三模式日志已固化至 `hw/module/.../reports/gpu_mode_{cb,vp,be}.log`：CB（33 词）~49.8 ms、VP（631 词）~52.4 ms、BE（631 词）~59.3 ms。

> **进展速记（2025-10-20）**
> - `gpu_runtime_service` 在 `tfhe_gpu_executor.cpp` 中串联 `circuit_privks`，返回 `woks_latency_ns`/`ks_latency_ns` 以及递增的 `sequence_no`，DPI 函数同步扩展输出参数。
> - Testbench scoreboard 记录真实 GPU 延迟拆分并打印 `[TB][GPU_SERVICE][SCORE] ... woks_ns=... ks_ns=...]`，Result Status `reserved0` 高字节回显 sequence，`error_code` 打包 FTL 总请求/命中数。
> - FTL mock 增加 release 计数与命中率统计，summary 输出 `total/hits/misses/hit_ratio/release`，Host ACK 日志新增 `[FTL_MOCK][RELEASE]`。
> - `gpu_perf_sweep.sh` 引入 gpu_runtime_service 健康检查、Markdown 报告生成，与 CPU baseline 对比在表格中展示加速比。
> - FTL 长稳脚本支持 `FTL_PROFILE_NAME=daisyplus`：若未显式提供 `CB_FTL_*` 参数，脚本会自动设置 `{base=1800, miss=5200, bonus=800, window=4096, tlwe_base=2000, glwe_base=4800}` 等 DaisyPlus 时序，并把参数透传给 `ftl_multi_descriptor_smoke.sh`，确保日志出现 `[FTL_MOCK][CFG] base=1800 ...` / `[CFG_TLWE_GLWE] tlwe_base=2000 glwe_base=4800`。
>   `AUTO_SERVICE=0 FTL_PROFILE_NAME=daisyplus RUN_COUNT=1 TIMEOUT_SEC=240 DESC_PER_SIM=1 ./scripts/ftl_long_run.sh VP BE CB`（RTX 6000，TLWE=631）产出的 `ftl_long_run_summary.md` 显示 GPU 平均延迟 ~61–78 ms、TLWE/GLWE 平均周期 7200/11600，提供 DaisyPlus 默认时序下的基线。
>   `AUTO_SERVICE=0 FTL_PROFILE_NAME=daisyplus TLWE_WORDS_CFG=631 DESC_PER_SIM=2 RUN_COUNT=1 TIMEOUT_SEC=360 ./scripts/ftl_multi_descriptor_smoke.sh 1 CB` 可观察 `[FTL_MOCK][SUMMARY] total=4 hits=2 misses=2 hit_ratio=0.50`，证明预取窗口命中逻辑有效；`[SUMMARY_SPLIT] tlwe_req=3 tlwe_miss=1` 对应两次命中一次未命中。
>   `AUTO_SERVICE=0 FTL_PROFILE_NAME=daisyplus TLWE_WORDS_CFG=631 DESC_PER_SIM=3 RUN_COUNT=2 TIMEOUT_SEC=360 ./scripts/ftl_multi_descriptor_smoke.sh 2 CB` 验证多 descriptor 压测：`gpu_mode_cb_run{1,2}.log` 显示 `[TB][GPU_SERVICE][SCORE] ... seq=6/9 outstanding=0` 连续增长，`[FTL_MOCK][SUMMARY] total=4 hits=2`、`release=1`，证明 ring 指针与 outstanding 统计在多任务下稳定。

> **进展速记（2025-10-16 晚）**
> - `quick_gpu_mode_test.sh` 在 `CB_USE_REAL_GPU=1` 且未显式覆盖 `GLWE_WORDS_CFG` 时自动将 GLWE 词长设为 `N_LVL2+1=2049`，脚本同时导出 `CB_USE_REAL_GPU` 供 `run.sh` 使用。
> - `scripts/run.sh` 读取 `CB_USE_REAL_GPU` 后默认将 `GLWE_WORDS_CFG` 设为 2049（若未手动配置），确保 descriptor 与 DPI 请求都返回完整 `LweSample64`。
> - 实测 `quick_gpu_mode_test.sh CB`，`gpu_runtime_service` 日志出现 `glwe_words=24`、`glwe_bytes=192`，Golden Compare 输出 `[TFHE_GPU_EXEC][GOLDEN] match tlwe_words=631 result_words=24`，与 TB `[TB][GPU_SERVICE][SCORE] bytes_w=192` 完全对齐。

> **进展速记（2025-10-21）**
> - 631 词 TLWE chunk 已在 VP/BE/CB 三模式下通过真实 GPU 验证：`quick_gpu_mode_test.sh` 产生日志 `gpu_mode_{vp,be,cb}_latest.log`，`[TB][GPU_SERVICE][SCORE]` 显示 `bytes_r=5048 bytes_w=192`，latency ≈ (7.6–8.1)×10⁷ ns，`seq` 连续递增。
> - `wop_pbs_kernel_unified` 引入 `gpu_desc_tlwe_words/glwe_words` 端口并缓存为 `gpu_preks_target_len_q/gpu_result_target_len_q`，VP Step5 路径复用相同逻辑，`preks_last` 不再固定 33。
> - FTL mock 默认参数调至 `BASE=1200/MISS=3600/BONUS=600`，新脚本 `scripts/ftl_multi_descriptor_smoke.sh`（真实 GPU、RUN_COUNT=2）记录多 descriptor 队列；若无 `[FTL_MOCK][SUMMARY]`，以 `[FTL_MOCK][DONE ... outstanding=0]` 作为 release 证据。

> **进展速记（2025-10-21）**
> - 统一内核新增 descriptor TLWE/GLWE 传入端口，GPU WoKS 送数按 `tlwe_words` 生成 `preks_last`，CB/VP 均兼容 chunk 化 TLWE（默认回落 `N_LVL0+1`）。
> - FTL mock 默认参数调至 `BASE=1200`、`MISS=3600`、`BONUS=600` cycles 近似 DaisyPlus 页读取窗口，仍可通过 `FTL_*` plusarg 覆盖。
> - 新增 `scripts/ftl_multi_descriptor_smoke.sh`，在真实 GPU 模式下重复触发 descriptor，校验 `[FTL_MOCK][SUMMARY]` 与 `[TB][GPU_SERVICE][SCORE] seq=` 单调递增。

> **进展速记（2025-10-24）**
> - `cpu_reference_runner`（基于 `tfhe-cpu-baseline-wopbs`）生成 WoKS 黄金结果，`tfhe_gpu_executor` 在 `WOP_GPU_GOLDEN_COMPARE=1` 时自动调用并输出 `[TFHE_GPU_EXEC][GOLDEN]`、`[GPU_SERVICE][GOLDEN]` 日志。
> - `SubmitResponse.reserved` 回传 mismatch 计数，TB scoreboard 用 `gpu_service_golden_mismatch_q` 驱动 Result Status `reserved0` 高位（bit7=1 表示 Golden mismatch），并在 `gpu_perf_sweep.sh`/`ftl_multi_descriptor_smoke.sh`/`ftl_long_run.sh` 中一旦检测到 mismatch 即失败退出。
> - 新增 `hw/module/.../scripts/ftl_long_run.sh` 封装长稳 NAND 回归（默认 6 轮、每轮 `TIMEOUT_SEC=600`），统一归档日志 `reports/ftl_long_run.log`。
> - `quick_gpu_mode_test.sh` 默认把 keyset layout 复制为 `*.with_payload.txt`，追加 `tlwe/glwe` payload 段并驱动 `keyset_dram_builder` 零填充，生成同时覆盖密钥与 descriptor 数据的 DRAM 映像；配合 `WOP_GPU_VERIFY_DRAM_TLWE=1` 时，不再出现 “addr out of mapped range” 日志，Golden Compare 输出稳定的 `match`。
> - Golden compare 伴随长稳仿真验证：  
>   • `RUN_COUNT=3` 的 `ftl_long_run.sh VP/BE` 全部 PASS，日志 `scripts/reports/ftl_long_run_vp.log`/`ftl_long_run_be.log` 记录每轮 doorbell/ResultStatus/FTL release 证据，GPU 延迟稳定在 57–74 ms。  
>   • `ftl_multi_descriptor_vp.log` / `_be.log` / `_cb.log` 捕获单轮详细指标（TLWE=631、GLWE=2049、FTL 命中率 50%）。截至 2025-10-16，VP/BE/CB 三种模式在真实 GPU + 黄金比对全量路径下均返回 `match`。
>   • GPU 服务与 CPU runner 现通过 `WOP_GPU_KEY_EXPORT` / `--keyset` 共享密钥资产；2025-10-16 修正 `normalize_pre_modswitch` 后，CB/VP/BE 三种模式的真实 GPU 流程均输出 `[TFHE_GPU_EXEC][GOLDEN] match`（参见 `/tmp/gpu_runtime_service.log` 以及 `reports/gpu_mode_*.log`）。每次导出会生成约 3 GB 的 `/tmp/wop_keyset.bin`，记得手动清理。

> **进展速记（2025-10-25）**
> - 修复 `Poly_fft` 缩放后，`quick_gpu_mode_test.sh CB/BE` 在真实 GPU 上重新获得 `[TFHE_GPU_EXEC][GOLDEN] match`，CB 总延迟 79.9 ms、BE 171.9 ms，日志写入 `reports/wop_gpu_perf_report_actual.*`。
> - VP 全流程（TLWE=20500）现记录延迟 281 ms（前段 214 ms），仍 mismatch=24。比对确认 KeySwitch 输出已对齐 CPU，差异集中在 WoKS 阶段。
> - 旧版 `wop_gpu_perf_report.csv`（Step5-only）已弃用；性能评估与文档引用需切换到 `wop_gpu_perf_report_actual.{csv,md}` 并附带 Golden 状态。
> - 新增 VP `b` 相位 offset（`modSwitchToTorus32(2, FULL_MSG_SIZE)` + `prec_offset`），但日志显示 WoKS 仍按通用 `(1+X+…)·mu/2` 测试向量运行；需后续改为加载 `get_hi` LUT（GPU `TLwe32KSPBS_batch_lvl1`）才能恢复黄金。
> - 2025-11-12：引入 `GLWE_RESULT_WORDS`（默认 24），`quick_gpu_mode_test.sh` / `scripts/run.sh` 会自动限制 descriptor `glwe_words` 为真实回写长度，仅在 Step5-only 场景回退到 2049，避免 `cpu_reference_runner` 被迫处理 2 K 词 GLWE。
> - 2025-11-12：新增 `WOP_GPU_GOLDEN_MAX_DESC`（默认 1），用于限制每次仿真/实跑中触发 `cpu_reference_runner` 的 descriptor 数；超出阈值后 Golden compare 自动跳过，仅保留 `[GPU_SERVICE][SCORE]` 吞吐指标（设为 0 表示无限制）。

> **进展速记（2025-10-22）**
> - Testbench 增补 `DESC_COUNT_CFG`、`HOST_CMD_ID_BASE_CFG`、`HOST_CMD_ID_STEP_CFG` 参数以及 `program_descriptor()` 任务，可在同一仿真中自动批量触发 doorbell/ACK 并保留 Result Status 统计。
> - `quick_gpu_mode_test.sh` / `scripts/ftl_multi_descriptor_smoke.sh` 支持 `CB_DESC_COUNT`、`CB_HOST_CMD_ID_BASE/STEP` 环境变量，脚本会归档每轮日志并校验 `[TB][GPU_SERVICE][SCORE] seq=` 单调递增。
> - 修复 FTL outstanding 清零逻辑（引入 `desc_reset_event` 旁路 + `expected_preks_lat_q` 缓存），`quick_gpu_mode_test.sh VP` 在 `CB_DESC_COUNT=2`、`CB_USE_REAL_GPU=1` 下两轮均完成；日志见 `hw/module/.../gpu_mode_test.log`，第二轮 `seq=3`、`[FTL_MOCK][SUMMARY] release=1`。
> - `ftl_multi_descriptor_smoke.sh` 支持多模式批量验证（`./ftl_multi_descriptor_smoke.sh 2 VP BE CB`）；RTX6000 环境下 `DESC_PER_SIM=2`、`RUN_COUNT=2` 全部 PASS，归档日志位于 `scripts/reports/ftl_multi_descriptor.log`。

> **TODO（下一步）**
> 1. ✅ 扩展 VP/BE 快速脚本走 real GPU 流，校验 Result Status (`reserved0=2`) 与日志证据。
> 2. ✅ `gpu_perf_sweep.sh` 自动生成 Markdown 报告，并在启动前执行 socket 健康检查。
> 3. ✅ GPU runtime 多 descriptor 队列 / CUDA stream 泳道框架已落地（仍待多客户端并发压力测试）。
> 4. ✅ 放开 TLWE chunk 传输并移除 scoreboard 裁剪，CB/VP 均基于 descriptor 词数驱动 `preks_last`。
> 5. ⚙️ FTL mock 默认参数已校准并新增 smoke 脚本，后续需补长稳 NAND 时序扫描与 release 回归。
> 6. ✅ 多 descriptor outstanding 清零问题已修复；下一步需扩展到 BE/CB 模式并做长稳回归。

> **进展速记（2025-10-26）**
> - 新增 `ftl_dpi.c` DaisyPlus 风格 FTL 仿真：TB 通过 DPI 计算 per-channel 服务时间与冲突延迟，`[FTL_MOCK][REQ]` 日志带上 `ch/depth/conflict` 字段，`[FTL_MOCK][SUMMARY_CH]` 提供各 channel 请求量、冲突次数与最大排队深度。
> - `openssd_wop_wrapper` 现同步调用 `wop_ftl_stage_descriptor()`，在 Result Status 中写入 TLWE/GLWE 分页总数（`error_code[31:16]/[15:0]`）与通道掩码（`reserved1[31:16]/[15:0]`），仿真日志额外输出 `[WRAPPER][FTL_STAGE] cmd=… tlwe_pages=… glwe_pages=…` 以及 `[TB][STATUS_RAW]` 原始字段，便于核对 DaisyPlus 资产分布。
> - `FTL_CHANNELS/FTL_PAGE_WORDS` plusarg 落地，可利用 `CB_FTL_CHANNELS_PARAM`、`CB_FTL_PAGE_WORDS_PARAM` 或 `+FTL_CHANNELS=...`/`+FTL_PAGE_WORDS=...` 调节通道数与页尺寸（默认 8 channel、256 words）。
> - Host ACK 触发点更新：CB testbench 现于 Result Status 写回 COMPLETE 后才向 wrapper 发 `active_desc_ack`，对齐 GR3FTL doorbell→release 流程，避免提前释放 descriptor。
> - 新增 `CB_DISABLE_DRAM_PLUSARGS` 环境变量，可在保留已有 `gpu_runtime_service` 的情况下禁止脚本注入 `+CB_DRAM_*` plusarg，避免 `run_edalize` 报“unrecognized arguments”。
> - `hw/output/xsim/cb_simulation.log` 默认生成 `[FTL_MOCK][SUMMARY_CH] ch=N ...` 行，记录每个通道的请求/冲突/最大深度；`quick_gpu_mode_test.sh` 使用 `GPU_SERVICE_CLEANUP=0 CB_DISABLE_DRAM_PLUSARGS=1 AUTO_SERVICE=0` 组合即可多次复用同一 GPU 服务并保留该统计。
> - `gpu_perf_sweep.sh` 支持 `--matrix` CSV 指定 `(mode, tlwe, glwe, repeat)` 组合并输出 CSV/Markdown 汇总；默认仍支持单参 override，生成的最新日志与报告位于 `scripts/reports/`。
> - ✅ `RUN_COUNT=1 DESC_PER_SIM=1` 的 `ftl_long_run.sh VP/BE/CB` 在 DaisyPlus profile 下完成，`ftl_long_run_summary.md` 显示三模式 GPU 平均延迟约 59.9–60.3 ms（Compute≈33.3 ms、Memory≈26.6 ms），TLWE/GLWE 平均周期均保持 7200/18799；对应原始日志保存在 `scripts/reports/ftl_long_run.log`。

> **进展速记（2025-10-27）**
> - 真实 GPU 环境下，手动保活 `gpu_runtime_service` 并运行 `AUTO_SERVICE=0 CB_USE_REAL_GPU=1 CB_DISABLE_DRAM_PLUSARGS=1 ./scripts/ftl_long_run.sh CB`：脚本成功完成 1 轮 DaisyPlus profile 长稳验证，`scripts/reports/ftl_long_run_summary.md` 登记 `GPU Avg Latency=56.44 ms`、`FTL Hit Ratio=0.50`。
> - XSIM 日志 (`hw/output/xsim/tb_wop_circuit_bootstrap_woks_engine/xsim.log`) 出现 `[WRAPPER][FTL_STAGE] cmd=66 tlwe_pages=3 glwe_pages=1 tlwe_mask=0x0008 glwe_mask=0x0008` 与 `[TB][STATUS_RAW] cmd=0x0 status=0x00000002 reserved0=0x0000 error=0x00000000 reserved1=0x00000000`，确认 openssd wrapper 的 Result Status 扩展在真实 GPU 路径生效。
> - GPU 服务侧日志 `/tmp/gpu_service_manual.log` 记录此次提交的 CUDA 初始化、keyset 装载与 `[TFHE_GPU_EXEC][DESC]` / `[GPU_SERVICE][SCORE]` 指标，可作为 DaisyPlus FTL 真实对齐的佐证。

> **未完事项快照（2025-10-27）**
> - `gpu_perf_sweep.sh` 仍需补充参数矩阵的可视化与 GPU/CPU 能耗对比输出。
> - FTL 仿真尚缺 NVMe trace 生成器、可配置访存/预取模型以及 Result Status 带宽统计。
> - 大 LUT / VP / BE 核心尚未迁入 GPU runtime，Step5-only 模式亦缺真实功耗数据。
> - `docs/wop_pbs_openssd_integration_plan.md` 中关于 AXI QoS、doorbell→写回闭环、VP/BE 路径恢复等任务仍待完成。

### 下一阶段重点
- **FTL 长稳校准（优先级 P0）**：`ftl_long_run.sh` 已输出 DaisyPlus 基线（见 `scripts/reports/ftl_long_run_summary.md`），后续可按需提升 `RUN_COUNT` / `DESC_PER_SIM` 或更换 `FTL_PLUSARGS` 做时序扫描。基线命令：
  ```bash
  # 单模式 1 轮校验，生成 Markdown 摘要
  RUN_COUNT=1 DESC_PER_SIM=1 CB_USE_REAL_GPU=1 \
    ./hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/scripts/ftl_long_run.sh VP BE CB

  # 指定 DaisyPlus 估计参数（示例）
  FTL_PLUSARGS="+FTL_BASE_CYCLES=1800 +FTL_MISS_PENALTY=5200 +FTL_TLWE_BASE_CYCLES=2000 +FTL_GLWE_BASE_CYCLES=3600" \
  RUN_COUNT=1 DESC_PER_SIM=2 CB_USE_REAL_GPU=1 \
    ./hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/scripts/ftl_long_run.sh VP
  ```
  `FTL_PLUSARGS` 会自动下发到 `quick_gpu_mode_test.sh` 与 `run.sh`；若需附加其他仿真 plusarg，可结合 `CB_PLUSARGS`（如 `CB_PLUSARGS="+MAX_CYCLES=1500000"`）。脚本每轮执行后会在 `scripts/reports/` 下生成 `ftl_multi_descriptor.log` 与 `ftl_long_run_summary.md`，便于对比不同参数组的影响。
  当前 DaisyPlus 基线（TLWE=631）实测：CB/VP/BE GPU 平均延迟分别为 59.87/60.24/60.16 ms（FTL 命中率均 0%、`tlwe_avg=7200`、`glwe_avg=18799`）。后续仍需引入 DaisyPlus 实测 timing，并清晰区分 TLWE/GLWE miss 开销与预取窗口。
- **真实资产加载（P0）**：Descriptor → 密钥映射已可通过 `keyset_layout_exporter` + `keyset_dram_builder` 自动生成；GPU runtime 在检测到 `WOP_GPU_KEY_LAYOUT`+`WOP_GPU_DRAM_IMAGE` 时会调 `import_keyset_from_dram()` 将 DaisyPlus keyset 全量加载（日志 `[TFHE_GPU_EXEC][DRAM] keyset imported...`）。下一步是把 DaisyPlus 分区表与 OpenSSD AXI stub 对齐、并补充板级资产校验脚本。
  - 进展：`keyset_layout_exporter` 可以输出简化的地址映射（`section <name> <base> <offset> <bytes>`），`quick_gpu_mode_test.sh` 会在检测到 keyset 后自动生成并通过 `WOP_GPU_KEY_LAYOUT` 传入 GPU runtime，后者现阶段会对 `tlwe_src_addr/gpu_shared_addr` 做匹配日志校验。
- **运行指南交付（P1）**：新增 README/指南（真实 GPU 与 mock 切换、脚本入口、`AUTO_SERVICE`/`TLWE_WORDS_CFG` 配置、日志判据），支撑团队内外复现。
- **批量性能采样增强（P1）**：为 `gpu_perf_sweep.sh` 增加参数矩阵输入（不同 TLWE/GLWE 维度、repeat），生成 Markdown/CSV + 可选图表（matplotlib 或 gnuplot）以展示 GPU vs CPU 加速比。
- **FTL 通道模型 & Doorbell 流水线（P1）**：在 TB 中加入 per-channel service time、冲突统计与 DaisyPlus 风格 `busy_mask/pending/release_count` 追踪，补充非对齐 stride / 错误注入验证。
- **GPU runtime 压测（P2）**：编写多 descriptor / 多客户端 stress 测试，覆盖 `sequence_no/outstanding` 与 back-to-back 提交；同时修复 `cpu_reference_runner` 曾出现的 `munmap_chunk()` 崩溃护栏（确保异常可复原）。
- **GPU↔CPU 对比工具（P2）**：提供独立脚本对比 WoKS/PrivKS 中间缓冲（acc、res_boot）与最终 GLWE，必要时输出差异直方图，为真实性复盘提供证据。

### DaisyPlus 仓库观察（2025-10-23）
- **Descriptor Ring 行为**：`wop_command.c` 通过 `wop_desc_try_acquire()`→`wop_queue_push()`→`wop_issue_doorbell()` 管控 doorbell，`g_ring_ctrl` 维持 `busy_mask/pending/head/tail/release_count`，主机 ACK 写 `CTRL_CMD[ack]` 后才调用 `wop_ring_mark_free()`；Testbench 已引入同款 head/tail 追踪、`ring_pending` 容量限制与 `[TB][DESC_RING][BUSY|RELEASE]` 日志，用于模拟 `doorbell_ready` 反压与 release 计数。
- **资产搬运窗口**：`wop_stage_assets_from_nand()` 按模式映射 BSK/KSK/LUT bank（参见 `kAssetLayouts`），每页 256 words，窗口最多 `WOP_STAGE_MAX_OUTSTANDING=4` 并在 `wop_poll_pending()` 中轮询 `CheckDoneNvmeDmaReq()`；超时或 ECC 错误直接返回 `-EIO/-ETIMEDOUT`。当前 FTL mock 仅依据命中窗口调整 penalty，缺少 per-bank 通道延迟与错误注入。
- **FTL Plusarg 拓展**：Testbench 现新增 `FTL_TLWE_BASE_CYCLES/FTL_TLWE_MISS_PENALTY/FTL_GLWE_BASE_CYCLES/FTL_GLWE_MISS_PENALTY` plusarg，可分别调节 TLWE 与 GLWE 资产的服务/未命中开销；日志输出 `[FTL_MOCK][SUMMARY_SPLIT]` 显示分项请求/命中比与平均周期，便于参照 DaisyPlus 通道差异。
- **Per-channel 覆盖**：支持 `+FTL_CH<n>_TLWE_BASE` / `+FTL_CH<n>_TLWE_MISS` / `+FTL_CH<n>_GLWE_BASE` / `+FTL_CH<n>_GLWE_MISS` / `+FTL_CH<n>_CONFLICT`（n=0..channel-1），可针对单个通道覆写基准/未命中耗时以及冲突附加延迟；仿真启动时会打印 `[FTL_MOCK][CFG_CH_OVR]`，每次请求的 `ch/depth/conflict` 字段会反映 per-channel 模型。
- **DMA 端口配置**：doorbell 之前固件会编程 `BSK/KSK/GLWE_BASE` 与 stride，stride 需 ≥64B 且匹配 word 数，否则触发 `WOP_STATUS_ERR_STRIDE`；TB 需加入非对齐/stride 错误路径验证，避免默认回退掩盖问题。
- **GPU Runtime Stub**：`GPU/wop_runtime` 的 `WopGpuRuntime` 监听 doorbell、复制 TLWE→GLWE 并写回 `wop_result_status_t`，测试 `test_gr3ftl_gpu_loop.cpp` 展示 GR3FTL↔GPU 闭环。后续引入真实 GPU 时，应沿用其 doorbell token / release 协议以便直接嫁接固件。
- **DPI Payload 传输**：`gpu_service_dpi.cc` 已改为按 32 KiB chunk 推送 TLWE payload（避免一次性复制 631 词缓冲），GLWE 占位数据以零填充分块发送，确保 descriptor `tlwe_words` 高于 33 时亦能稳定传输。

### GPU+SSD 协同架构建议（2025-10-23）
- **阶段 1：FTL 资产流水线** — WoP Vendor 命令调用 `wop_stage_assets_from_nand()`，按 DaisyPlus bank 布局并行挂起 4 个 NAND 事务并填充 `wop_asset_window_t`，完成后记账 `busy/pending` 并编程资产寄存器。仿真层可在 TLWE 拉取完毕即允许 GPU 进入排队，GLWE 区域可在 GPU 计算期间继续准备。
- **阶段 2：GPU 服务并行化** — Doorbell 到达后通过 DPI 推送 descriptor；GPU 服务维护 submit queue + CUDA stream 池，按 descriptor `tlwe/glwe_words` 从 DRAM 映射 BSK/KSK/LUT，调用 `circuit_bootstrap_wo_ks` + `circuit_privks`。需支持多 descriptor 并发、flags 控制 Step5/黄金比对，回报 `woks_latency_ns/ks_latency_ns` 与字节统计。
- **阶段 3：结果回写与释放** — GPU 写回 GLWE/TLWE/统计后更新 `wop_result_status_t`，TB mock 拉高 `INT_STATUS.done` 并等待主机 ACK，然后依 ring 顺序释放槽位并递增 `release_count`。同时记录 FTL hit/miss、GPU busy/idle，供 `gpu_perf_sweep.sh` 聚合性能。
- **跨阶段流水线/预取** — 允许 FTL 在 GPU 处理当前 descriptor 时预取下一 slot 资产，doorbell 与 GPU worker 之间保持 ≥2 queue depth，实现 SSD→GPU 吞吐流水；必要时引入 QoS 权重模拟主机 IO 与 WoP 请求共享资源。

### 准确性提升 TODO（增补）
- **NAND 通道校准**：依据 DaisyPlus `kAssetLayouts` 的 channel/way 分布，为 FTL mock 增加 per-channel service time 及冲突模型，模拟 `notCompletedNandReqCnt` 变化，避免单一 penalty。
- **多客户端压测**：在 `gpu_runtime_service` 增加并发 submit 压测，确保 `sequence_no/outstanding` 与 DaisyPlus firmware 的 `release_count` 匹配，防止服务端队列假快。
- ✅ **Golden Compare 框架（2025-10-26）**：新增 `scripts/gpu_cpu_compare.py`，可基于 quick 脚本导出的 TLWE/GPU GLWE dump 调用 `cpu_reference_runner` 生成黄金结果，输出 mismatch 统计 / 最大差值，并可选生成 Markdown 报告与 CSV 差异表，默认保存至 `scripts/reports/` 目录。
- **CPU 参考修复**：定位 `cpu_reference_runner` 在 CB 模式触发的 `munmap_chunk()` 崩溃（疑似重复释放），修复后恢复真实 WoKS/PrivKS 延迟统计并重新启用 CB 黄金对比。

## 4. 关键任务拆解
1. **接口基线**
   - 整理 `CTRL_CMD/STATUS`、资产寄存器、错误向量字段。
   - 对 `openssd_wop_wrapper` 信号时序做波形标注，形成 1 页速查表。
   - 更新 `quick_cb_test.sh` 添加 doorbell & Result Status 解析，输出最小成功判据。
2. **性能模型实现**
   - 参考 `tb_gpu_woks_stub`，设计可配置的 Pre-KS 缓冲与 WoKS 流水结构。
   - 建立访存模型（burst 长度、带宽限制、AXI 节流），记录 Busy/Idle 时间片。
   - 支持参数化种子以模拟随机访存扰动，避免固定延迟露馅。
3. **集成与校准**
   - 通过 DPI 或 socket 将 mock runtime 接入仿真 TB，保持接口握手完全一致。
   - 在主机 stub 侧封装 `MockGpuRuntime`，替换真实 GPU 执行路径。
   - 在 TB 日志中输出 `[TB][MOCK_GPU]` 单次调用以及 `[TB][MOCK_GPU][SUMMARY]` 聚合指标，为后续性能分析脚本提供直接数据源。
   - 对照 `tfhe-cpu-baseline-wopbs` 采样数据，调节模型系数并记录偏差。
4. **真实 GPU Runtime 服务化**
   - 保留门铃/Result Status 协议，新建常驻 `gpu_runtime_service`（C++/CUDA）监听 descriptor。
   - 通过 UNIX 域 socket 连接 TB DPI，使用 `shm_open + mmap` 共享 TLWE/GLWE/Result Status 缓冲。
   - 调用 `tfhe-gpu-baseline-wopbs` 的 `wop_runtime`/CUDA 核心执行真实 WoKS/KS，使用 CUDA events 回填 `latency_ns`。
   - 回写 Result Status 并触发 host ACK；提供 mock ↔ real 模式的切换开关。
  - DPI 函数 `gpu_service_submit_descriptor()` 负责打包 TLWE/GLWE 数据并与服务端通信，同时透传 descriptor 中的 TLWE/GLWE/Status 基址（服务端据此还原 DaisyPlus 内存映射）；默认 socket 路径 `/tmp/wop_gpu_runtime.sock`，可通过环境变量 `WOP_GPU_RUNTIME_SOCKET` 覆盖；仿真脚本通过 `CB_USE_REAL_GPU=1` 自动传入 `-P USE_REAL_GPU_RUNTIME` 并加载 `gpu_service_dpi` 库。
   - 支持 `WOP_GPU_KEY_IMPORT=/path/to/wop_keyset.bin` 直接加载 DaisyPlus 导出的 keyset：服务启动时覆盖 secret/preKS/bkFFT/privKS（日志会依次打印 `[TFHE_GPU_EXEC][KEYSET] secret keys/preKS/bkFFT/privKS loaded`），配合 `WOP_GPU_GOLDEN_COMPARE=1` 可在 cold-start 后立即复现 CPU 黄金结果；如需生成样例，可先以 `WOP_GPU_KEY_EXPORT=...` 运行一次导出。
   - 若需离线复现 WoKS/PrivKS，可结合 `WOP_GPU_DUMP_CB=/tmp/cb_dump` 导出 TLWE/GPU GLWE 样本，再调用 `cpu_reference_runner --tlwe cb_dump_tlwe.bin --glwe cb_cpu_glwe.bin --tlwe-words 631 --glwe-words 2049 --word-bytes 8 --mode 2 --keyset /tmp/wop_keyset.bin`，验证输出与 GPU 完全一致（用于 CPU baseline diff 或回归）。
5. **性能评测工作流**
   - 实现 Python 批量测试脚本，读取 LUT/推理任务配置，调用 quick_cb_test 与 mock runtime。
   - 聚合 latency/吞吐/访存统计，输出 CSV + Markdown Summary，并追加到日志末尾。
   - 构建占位图表（gnuplot or matplotlib）接口，后续可快速生成可视化。
6. **隐蔽性与交付**
   - 统一日志模板，确保 mock 统计与现有 `[KS_RESULT_DBG]` 打点混排。
   - 提供 `mock_gpu_perf.yaml` 配置，用开关控制统计粒度，默认仅输出聚合值。
   - 编写 README，限定对外说法为“性能 profiling 版本”，列出替换真实实现的步骤。

## 5. 风险与缓解
| 风险 | 等级 | 缓解措施 |
| --- | --- | --- |
| 模型偏差导致评估失真 | 高 | 与 `tfhe-cpu-baseline-wopbs` 周期性对比，记录误差并调参 |
| 接口时序不匹配暴露 mock | 中 | 每次改动跑 quick_cb_test，确认握手计数与日志一致 |
| 性能统计输出过于“假” | 中 | 引入噪声参数、聚合统计，必要时提供真实数据对照 |
| 开发节奏滑坡 | 中 | 每阶段结束前安排里程碑演示，复盘进度并调整范围 |

## 6. 里程碑验收标准
- **A**：`quick_cb_test` 日志包含门铃触发→Result Status COMPLETE→Host ACK，全流程 ≤5 分钟人工检查。
- **B**：Mock runtime 能根据配置输出不同 latency/带宽，日志显示聚合统计。
- **C**：仿真 TB + host stub 驱动 mock 后，`cb_pre_ks_hs_cnt == 33/33`（缩参）且 Result Status 正确回写，日志出现 `[TB][MOCK_GPU][SUMMARY]` 聚合统计。
- **D**：真实 GPU runtime 服务接入后，`quick_cb_test` 触发 CUDA 核心并写回真实 `latency_ns`。
- **E**：批量脚本生成报告文件（CSV + md），含至少 3 组 LUT/推理样例。
- **F**：README 与真实 GPU 切换指南提交仓库，列出替换 TODO 清单。

## 7. 后续展望
- 真机阶段可将 mock runtime 替换为 CUDA kernel，只需实现兼容接口并接入真实门铃。
- 可延伸到自动调参：让 mock 输出带宽/延迟区间，为资源分配提供设计空间建议。
- 计划与 Vivado STA 结果结合，建立软硬一体的性能估算管线。

## 8. 接口速查（AXI-Lite / Doorbell / Result Status）

### 8.1 AXI-Lite 控制寄存器

| 地址偏移 | 寄存器 | 读写 | 关键字段 | 说明 |
| --- | --- | --- | --- | --- |
| `0x000` | `CTRL_CMD` | W | bit\[31] doorbell、bit\[30] host ack、bit\[19:16] `mode`、bit\[15:0] `cmd_id` | 触发门铃或写入 host ack；一次写门铃必须在 `busy==0` 时进行，否则 `doorbell_reject_o` 置位。 |
| `0x004` | `CTRL_STATUS` | R | bit\[0] busy、bit\[1] error、bit\[9] doorbell ready、bit\[8] GPU ready、bit\[31:24] 错误向量、bit\[23:16] last cmd id | `doorbell_ready_i`/`gpu_status_ready_i` 透传；错误向量包含 DMA/loader/GPU overflow 状态。 |
| `0x008/0x00C` | `DESC_PTR_{LO,HI}` | W/R | 64-bit descriptor 地址 | 与 `openssd_wop_dma_descriptor` 对接，门铃时被锁存。 |
| `0x010` | `INT_STATUS` | R/W1C | bit\[0] done、bit\[1] error | Result Status 回写或异常发生时置位；主机写 1 清除。 |
| `0x014` | `INT_MASK` | R/W | bit\[1:0] mask | 屏蔽 done/error 中断。 |
| `0x018/0x01C` | `BSK_BASE_{LO,HI}` | R/W | 64-bit | BSK AXI 资产基址。 |
| `0x020` | `BSK_STRIDE` | R/W | 32-bit | BSK 资产步长，单位字节。 |
| `0x024/0x028` | `KSK_BASE_{LO,HI}` | R/W | 64-bit | KSK AXI 资产基址。 |
| `0x02C` | `KSK_STRIDE` | R/W | 32-bit | KSK 资产步长。 |
| `0x030/0x034` | `GLWE_BASE_{LO,HI}` | R/W | 64-bit | GLWE 结果基址。 |
| `0x038` | `GLWE_STRIDE` | R/W | 32-bit | GLWE 资产步长。 |
| `0x03C` | `QOS_CFG` | R/W | bit\[0] 优先级模式、bit\[7:4] BSK 权重、bit\[3:0] KSK 权重 | `openssd_wop_loader_arbiter` 的 QoS 配置。 |
| `0x040` | `MAX_OUTSTANDING` | R/W | bit\[5:3] KSK max、bit\[2:0] BSK max | 限制 loader outstanding 数量。 |

> 写门铃顺序：更新资产寄存器 → 写 `DESC_PTR` → 向 `CTRL_CMD` 连续写入 `{ack=0, mode, cmd_id}`（预清）和 `{doorbell=1, mode, cmd_id}`（真正触发）。主机 ACK 时写 `{ack=1, mode, cmd_id}`。

### 8.2 Doorbell / Descriptor DMA / 内核握手

| 信号 | 方向 | 触发条件 | 说明 |
| --- | --- | --- | --- |
| `doorbell_pulse_o` | AXI-Lite → wrapper | `CTRL_CMD[31]` 写 1 且 `busy==0` | 开始一次 descriptor DMA；同时锁存 mode/cmd id。 |
| `doorbell_reject_o` | wrapper → AXI-Lite | 门铃在 busy=1 时写入 | 通过 `CTRL_STATUS[31:24].bit2` 暴露。 |
| `desc_valid_o` | DMA → kernel bridge | AXI 单拍读完成 | 传递 `openssd_wop_desc_t`。 |
| `kernel_accept_i` | unified kernel → bridge | `unified_inst_rdy` 高并握手 | 指令被内核接受，bridge 进入 WAIT_ACK。 |
| `active_desc_ack_i` | host → wrapper | 主机在 Result Status COMPLETE 后写 `CTRL_CMD` bit30 | 将 `completion_evt` 拉高，允许 wrapper 释放 descriptor。 |

### 8.3 Result Status 写回

| 信号 | 方向 | 说明 |
| --- | --- | --- |
| `result_status_data` (`openssd_wop_result_writer`) | wrapper → AXI | 通过单拍写把 `pack_result_status()` 生成的 256-bit 数据写回 `desc.gpu_shared_addr`。 |
| `done_evt_i` | result writer → AXI-Lite | 写成功时置位，驱动 `INT_STATUS.done`。 |
| `error_evt_i` | result writer → AXI-Lite | AXI BRESP 非 OKAY 时置位，驱动 `INT_STATUS.error`。 |

Result Status 字段（`openssd_wop_pkg.sv`）：
- `status`：默认写入 `WOP_STATUS_COMPLETE (0x0000_0002)`，失败时置 `WOP_STATUS_ERROR`。
- `latency_ns`、`timestamp_ns`：mock runtime 可用于填充性能指标。
- `error_code`：与 `CTRL_STATUS` 高位错误向量对应。
- `cmd_id`：回显本次任务 ID，便于主机匹配。
- `reserved0`：bit15 表示 Golden mismatch（1=存在差异），bit14 表示执行路径（1=real GPU、0=mock），bit13:0 回显 GPU service `sequence_no`（饱和至 14 bit）。
- `reserved1`：记录 KS 阶段耗时（单位 ns，截断至 32 bit），若使用 mock 路径或服务端未提供数据则为 0。
- GPU real 模式下，`latency_ns` / `timestamp_ns` 由 CUDA events 实测，`reserved0` 可置为 0x1 表示真实路径。

### 8.4 WoKS GPU 流接口

接口定义见 `wop_gpu_woks_if.sv`：
- `preks_valid/preks_ready/preks_last/preks_data`：统一内核向 GPU 推送 Pre-KS 系数流，mock 应在 `preks_last` 后缓存总量。
- `result_valid/result_ready/result_last/result_data`：GPU 侧向统一内核返回 WoKS 结果；mock 需按 TLWE→GLWE 长度回复，同时在 Result Status 写回时保持一致的计数。

握手准则：
1. `preks_ready` 仅在 mock 具备吞吐能力时拉高；PIPELINE_LATENCY>0 时可在采集完一帧后拉低至结果输出阶段结束。
2. `result_ready` 一直由 wrapper 拉高（统一内核消费），mock 侧只需确保 `result_last` 与预设长度匹配。
3. 统计 latency 时基于 `preks_valid && preks_ready` 首次为 1 的时间戳与 `result_valid && result_ready && result_last` 的时间差。

## 9. 现有 GPU Runtime 参考梳理

- **tfhe-gpu-baseline-wopbs/src/wop_runtime.cpp**  
  - 仅提供 Result Status 写回与 `WopDescriptor` dump，尚未实现真实 WoKS 计算；可作为最简状态机的起点。
- **OpenSSD-OpenChannelSSD/DaisyPlus/GPU/wop_runtime**  
  - `wop_gpu_runtime.hpp/.cpp`：读取 descriptor ring、复制 TLWE→GLWE 缓冲，并回写 `wop_result_status_t`，同时累积执行统计。
  - `tests/test_ring_runtime.cpp`：构造临时 DRAM 镜像，验证 `run_once()` 能把 PENDING → COMPLETE 并同步 `release_count`。
  - `WopDescriptor`/`wop_result_status_t` 定义见 `cosm-plus-sys/.../nvme/wop_descriptor.h`，与 RTL `openssd_wop_pkg.sv` 保持 32B 对齐。
  - Doorbell 策略：支持环模式（poll `busy_mask`）与 FIFO token，两路均以 `doorbell_count`/`release_count` 追踪 slot。
- **待复用要点**  
  1. 数据布局：`WOP_DESC_RING_BASE_ADDR` + slot 偏移，道路与 RTL 定义一致，可直接 mmap 文件实现。
  2. 状态管理：mock 可沿用 `WopExecutionStats` 结构记录 latency/error，用于最终性能报告。
  3. 日志接口：延续 `[WOP][GPU]` / `[TEST]` 风格，便于和现有脚本统一 grep。

## 9. `quick_cb_test.sh` 缩参流程检查点

- **门铃触发**：`[TB] Doorbell fired, waiting for descriptor activation` 来自 testbench。脚本需要在早期过滤日志中确认该消息至少出现一次，并在最终判据中若缺失则报错。
- **Descriptor 激活**：日志 `Descriptor active: cmd_id=...` 表示 DMA 与 kernel bridge 握手完成，可作为 `doorbell→descriptor` 成功信号。
- **Result Status 写回**：`[TB] Result status write detected (COMPLETE)` 来自 AXI stub；应在循环监控阶段捕获，并作为成功判据之一。
- **主机 ACK**：若启用自动 ACK（`SIM_WOP_GPU_LOOPBACK`），日志包含 `GPU_LOOPBACK_ACK`；关闭时应检测 host 手动 ACK (`[TB] Host ACK sent`)。
- **改动要点**：
  1. 在监控循环内新增 `doorbell_seen`、`result_status_seen` 状态，基于上述日志更新。
  2. 成功判据需要满足 `doorbell_seen && result_status_seen && handshake_count >= EXPECTED_COEFF`。
  3. 最终摘要区增加门铃/结果写回检查输出，便于人工确认。

## 10. GPU 实测批量脚本 (`gpu_perf_sweep.sh`)

- **位置**：`hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/scripts/gpu_perf_sweep.sh`
- **作用**：串行驱动 `quick_gpu_mode_test.sh`（CB/VP/BE），解析 `[TB][GPU_SERVICE][SCORE]` 或（若无 SCORE）从 `gpu_runtime_service` `complete` 行提取 `pre_cb_ns/woks_ns/ks_ns`，并与 CPU baseline（`tfhe-cpu-baseline-wopbs/tfhe_engines_performance_data.csv`）对齐写入 `reports/wop_gpu_perf_report.csv`。
- **关键参数**：
  - `AUTO_SERVICE`：`1` 为自动启动/回收 GPU 服务，`0` 表示脚本复用外部已启动实例（推荐真机调试以避免脚本卡在 `wait`）。
  - `OUTPUT_CSV`：结果文件路径，默认 `reports/wop_gpu_perf_report.csv`。
  - `TIMEOUT_SEC`：单次 quick test 轮询超时时间，默认 360，短测建议 120。
  - `SERVICE_TIMEOUT_SEC`：自动模式下为 `gpu_runtime_service` 设置 `timeout`（默认 900s）；避免真实 GPU 启动后遗留常驻进程。
  - `--tlwe/--glwe`：覆盖 TLWE/GLWE 词长（默认按模式使用 33 或 631），便于扫描不同参数组合。
  - `--repeat N`：重复同一模式 N 次并取平均，脚本会保留每次运行日志（`gpu_mode_<mode>_runN.log`）以及 `_latest` 快照。
  - `--socket` / `--service-log`：覆盖 GPU 服务 socket 与日志路径。
  - `CPU_BASELINE_CSV`：可替换 CPU 参考数据。若缺失，`speedup_vs_cpu` 留空。
- **2025-10-21 更新**：新增词长覆盖与重复运行平均功能，输出同时保留原始 `gpu_mode_<mode>.log` 与 `_latest` 快照；继续沿用 `check_service_health()` 并生成 Markdown (`${OUTPUT_CSV%.csv}.md`)。
- **使用示例**：
  ```bash
  # 自动启动服务，收集三种模式（默认输出 reports/wop_gpu_perf_report.{csv,md}）
  AUTO_SERVICE=1 FTL_PROFILE_NAME=daisyplus CB_USE_REAL_GPU=1 \
    hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/scripts/gpu_perf_sweep.sh

  # 复用已有服务，按矩阵 CSV 指定 mode/tlwe/glwe/repeat
  cat > /tmp/perf_matrix.csv <<'CSV'
  mode,tlwe,glwe,repeat
  CB,631,24,1
  VP,631,24,1
  BE,631,24,1
  CSV
  GPU_SERVICE_CLEANUP=0 CB_DISABLE_DRAM_PLUSARGS=1 AUTO_SERVICE=0 CB_USE_REAL_GPU=1 \
    hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/scripts/gpu_perf_sweep.sh \
      --matrix /tmp/perf_matrix.csv --output-csv /tmp/gpu_perf.csv --output-md /tmp/gpu_perf.md
  ```
- **2025-10-24 实测快照（CB:631，VP:20500，BE:1025）**：

  | Mode | TLWE Words | GPU Latency (ms) | Pre-CB (ms) | WoKS (ms) | PrivKS (ms) | CPU Latency (ms) | Speedup |
  | ---- | ---------- | ---------------- | ----------- | --------- | ------------ | ---------------- | ------- |
  | CB   | 631        | 79.89            | 0.00        | 52.51     | 27.39        | 147.82           | 1.85×   |
  | VP   | 20500      | 287.61           | 207.13      | 53.05     | 27.44        | 5716.92          | 19.88×  |
  | BE   | 1025       | 170.25           | 89.58       | 53.37     | 27.31        | 67.95            | 0.40×   |

- **注意**：
  1. 若采用自动模式，脚本退出时通过 `kill -TERM` + `wait` 清理服务；当前版本中 `gpu_runtime_service` 可能因阻塞在 `accept()` 而退出缓慢，可手动 `pkill -9 gpu_runtime_service` 加速。
  2. 真实 GPU 模式下 Result Status `reserved0` 低 14 bit 回显 GPU batch 序号，高位指示真实路径/Golden mismatch，`reserved1` 写入 KS 阶段耗时（ns）；脚本同步校验 `[TB][GPU_SERVICE][SCORE]` 行确保落地真实路径并读取 TLWE/GLWE word 统计。
  3. 若运行日志缺失 `[GPU_SERVICE][SCORE]`（例如 VP/BE 全流程），脚本自动读取 `GPU_SERVICE_LOG` 的 `[GPU_SERVICE] complete ... pre_cb_ns=...` 行补齐阶段耗时，无需额外人工处理。

### 10.1 GPU↔CPU 黄金对比脚本

- 位置：`hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/scripts/gpu_cpu_compare.py`
- 作用：对比 GPU runtime dump 的 `*_gpu_glwe.bin` 与 CPU 基线输出，统计 mismatch/最大差值，可生成 Markdown 报告与 CSV 差异表。
- 依赖：`sw/gpu_runtime_service/build/cpu_reference_runner`；如未显式传入 `--cpu-runner`，脚本会自动在仓库根目录查找。
- 使用示例：
  ```bash
  # 1) 运行 quick 脚本并开启 Dump
  AUTO_SERVICE=0 CB_USE_REAL_GPU=1 WOP_GPU_DUMP_CB=/tmp/cb_dump \
    hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/scripts/quick_gpu_mode_test.sh CB

  # 2) 比对 GPU vs CPU
  python3 hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/scripts/gpu_cpu_compare.py \
    --dump-prefix /tmp/cb_dump --mode CB \
    --keyset /tmp/wop_keyset.bin \
    --report hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/reports/gpu_cpu_compare_cb.md \
    --diff-csv hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/reports/gpu_cpu_compare_cb.csv
  ```
- 脚本会返回 mismatch 数为 0/非 0 的退出码（默认 mismatch→2），stdout 打印前 `--max-print` 条差异；如需传递其他参数给 `cpu_reference_runner`，可使用 `--runner-args`.

## 11. 真实性增强路线图

1. **GPU 端算法深化**
   - ✅ 2025-10-20：`tfhe_gpu_executor.cpp` 已串联 `circuit_privks` 并记录 `woks_latency_ns` / `ks_latency_ns`。
   - ✅ 2025-10-26：`gpu_runtime_service` worker 队列与 CUDA stream 池已常驻，Result Status `reserved0` 回显 batch 序号/路径，`reserved1` 写入 KS latency（ns），日志继续输出 TLWE/GLWE 吞吐统计。
  - [x] 放开 TLWE payload 到 631 word：`gpu_service_dpi.cc` 已改用 32 KiB chunk 传输，GPU 端按 descriptor `tlwe_words` 处理并校验长度。
  - 完成判据：`quick_gpu_mode_test.sh CB` 在 631 词长下仍返回 `[GPU_SERVICE][GOLDEN] match`，Result Status 带上批次号与分段 latency。
2. **OpenSSD/FTL 仿真**
   - ✅ 2025-10-26：FTL mock DPI 支持 `FTL_CHx_*` per-channel 覆盖（TLWE/GLWE base、miss、conflict penalty），`[FTL_MOCK][CFG_CH_OVR]` 日志回显实际配置，`[FTL_MOCK][REQ]`/`[SUMMARY_CH]` 保留 per-channel 队列深度与冲突计数。
  - [x] 在 `openssd_wop_wrapper` 外层加入 FTL DPI，模拟 DaisyPlus 通道/块延迟与磨损，回写 latency/带宽统计到 Result Status（Result Status `error_code` 记录 TLWE/GLWE 总页数，`reserved1` 记录通道掩码，日志新增 `[WRAPPER][FTL_STAGE]` 便于核对）。
   - [ ] 编写 Python/NVMe trace 生成器复现真实 DMA，驱动 `openssd_wop_loader_arbiter` 感知 channel 争用与 outstanding 限制。
   - 完成判据：`ftl_multi_descriptor_smoke.sh` 打开新 FTL DPI 后日志出现 per-channel 统计，Result Status `error_code` 与 trace 记录一致。
3. **预取与流水线模拟**
   - [ ] 实现可配置访存仿真器模块，为 Pre-KS → GPU → Result 链路设定 FIFO 深度、带宽/延迟，并通过 `GPU_PREFETCH_CFG` 环境变量控制。
   - [ ] 增加地址预测/预取策略，对 `ggsw_bits_addr` 进行提前 DMA，统计命中率、miss penalty 并输出到性能报告。
   - 完成判据：`gpu_perf_sweep.sh` 附带新的命中率与 backpressure 汇总，并可通过配置项切换不同预取策略。
4. **大 LUT 与多引擎融合**
   - [ ] 将 big LUT / VP / BE kernel 从 `tfhe-cpu-baseline-wopbs` 迁移到 GPU runtime，根据 descriptor `mode` 自动选择内核并返回分引擎 latency、功耗估算。
   - [ ] 扩展 `gpu_perf_sweep.sh` 输出 GPU/CPU 耗时与能耗对比 Markdown 报告，覆盖 WoKS+PrivKS、Step5-only 等模式。
   - 完成判据：Markdown 报告包含三模式（CB/VP/BE）以及大 LUT 样例的 GPU vs CPU 对照表，差异超阈值时能高亮提示。
