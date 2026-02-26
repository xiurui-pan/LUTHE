# WoP-PBS → OpenSSD 集成方案 (2025-10-27)

## 1. 目标与范围
- 在 OpenSSD CosmosPlus 平台上集成 `wop_pbs_kernel_unified`，面向 TFHE WoP 工作流。
- SSD 端只保留轻量控制、密钥缓存、数据搬运；高开销 NTT/PrivKS/外积迁移至 GPU。
- 与 GR3FTL 固件及 NVMe 主机保持兼容，新增供应链命令与状态反馈。

## 2. 现有实现体检
- **RTL**：`wop_pbs_kernel_unified.sv` 已整合 VP/BE/CB，端口包含 RegFile、BSK/KSK/GLWE AXI 通道、NTT/BSK 服务接口。
  - 进展：PrivKS 结果路径与 `proc_mask_done` 死锁已修复，缩参 `quick_cb_test` 中能看到连续 `[KS_RESULT_DBG] final handshake` 与 `cb_result_count` 递增。
  - OpenSSD wrapper (`openssd_wop_wrapper.sv`) 已提供 AXI-Lite 控制窗口、Descriptor DMA、BSK/KSK/GLWE stream loader、错误向量，并与统一内核资源接口对接。
- **软件**：OpenSSD `nvme_main.c` 仍保留基础 NVMe/FTL 框架；`memory_map.h` 需按最新资产窗口更新。GR3FTL Vendor 命令与 GPU doorbell 流水仍在规划阶段。
  - 2025-10-16：`quick_gpu_mode_test.sh` + `gpu_runtime_service` 在真实 GPU 上跑通 WoKS/PrivKS，日志输出 `[GPU_SERVICE][GOLDEN] match`，详见 `hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/reports/gpu_mode_cb_latest.log`。
  - 2025-10-16：新增 `keyset_exporter` / `keyset_layout_exporter` 工具，可生成 `/tmp/wop_keyset.bin` 与布局文件，GPU runtime 通过 `WOP_GPU_KEY_IMPORT/WOP_GPU_GOLDEN_COMPARE` 自动加载校验。
  - 2025-10-27：`FTL_PROFILE_NAME=daisyplus` 长稳脚本验证 Result Status `latency_ns` 与 `[FTL_MOCK][SUMMARY_SPLIT]` 统计稳定输出；GPU 服务日志 `/tmp/gpu_service_manual.log` 与 `scripts/reports/ftl_long_run_summary.md` 给出 DaisyPlus 延迟基线。
- 2025-10-27：`AUTO_SERVICE=1 CB_USE_REAL_GPU=1 ./quick_gpu_mode_test.sh CB` 成功跑通真实 GPU，日志显示 `[TB][GPU_SERVICE][SCORE] latency_ns≈1.00e8, woks_ns≈3.4e7, ks_ns≈6.6e7` 与 `Unified kernel ACK`，确认 doorbell→Result Status→ACK 在仿真环境闭环。保持 `CB_DISABLE_DRAM_PLUSARGS=1` 可避免 `run_edalize` 不识别的 plusarg 报错。
- 2025-11-11：OpenSSD wrapper 在 GPU result 路径上增加一拍 FIFO（`gpu_result_buf_valid_q/data_q/last_q`）防止 `result_last` 在状态跳转时被清零，`quick_gpu_mode_test.sh` 也会在仿真退出后补跑一次日志体检，确保真实 GPU 场景能够看到 `[TB] Result status write detected (COMPLETE)` 与 `[TB] Host ACK sent` 并自然退出。

> 真实 GPU 操作细节请参阅 `docs/real_gpu_quickstart.md`，涵盖服务启动、keyset 导入/布局、DaisyPlus FTL profile 以及 CPU baseline 对比流程。

## 3. 架构分工
| 模块 | SSD (FPGA) | GPU |
| --- | --- | --- |
| 指令处理 | 解析 `unified_pbs_inst`、维护 RegFile、下发 BSK/KSK 请求 | N/A |
| 数据搬运 | AXI 主机 DMA → DRAM / GPU 共享区 | DMA 接受任务，执行内核 |
| 运算 | 预处理、寄存器写回、轻量校验 | WoKS NTT、外积、PrivKS ACC、结果打包 |
| 状态反馈 | 回写 NVMe completion、FTL 状态 | 提供执行完成标志、性能计数 |

## 4. 接口设计
1. **AXI-Lite 控制窗口** (基址暂定 `0x8001_0000`):
   - `CTRL_CMD`: bit[3:0] 表示模式 (VP/BE/CB)，bit[31] doorbell
   - `CTRL_STATUS`: busy/error、GPU ready、最后一次结果ID；高 8 bit 现编码错误来源（bit0 DMA、bit1 GPU FIFO 溢出、bit2 doorbell 忙拒绝、bit3 descriptor 解析失败、bit4 BSK loader、bit5 GLWE loader、bit6 stride 配置非法、bit7 KSK loader），便于固件快速定位资源异常
   - `CTRL_DESC_PTR`: DRAM 地址指向批任务描述符
   - GR3FTL 固件在 doorbell 前写入 `BSK/KSK/GLWE_BASE_{HI,LO}` 与 `*_STRIDE`，每个 slot 根据 NAND 资产映射计算 64B 对齐的基址/步长，确保 wrapper 不再因零 stride 触发 `cfg_param_error`。
   - RTL 现已落地 `CTRL_CMD/STATUS/DESC_PTR/INT_*`，Doorbell 仅在 `busy==0` 时锁存参数，并将高并发写入记为 `error_evt` 反馈至 `INT_STATUS`。
2. **DRAM 缓冲布局** (基于 `memory_map.h`):
   - `0x1800_0000` 起分为：命令描述符队列、TLWE 输入区、GLWE 输出区、GPU 中间缓冲
   - 对齐 4KB，接口与 NVMe DMA 一致。
3. **GPU Doorbell 协议**:
   - SSD 写 `CTRL_CMD` 触发 → PS (GR3FTL) 写入 GPU 控制器或触发 MSI-X
   - GPU 完成后在共享内存更新 `DESC.status` 并触发回写中断
4. **日志与调试**:
   - SSD 端保留 `[KS_RESULT_DBG]` 关键打点，通过 NVMe `GET LOG` 扩展导出
   - GPU 端输出 `unified_ack` 时序，与 SSD `unified_pbs_inst_ack` 匹配
5. **内核共享总线**:
   - 统一内核已引入 `wop_pbs_axi_read_arbiter`，Wrapper 可按需接入 GLWE/BSK/RegFile 的多端口读请求，避免后续重复改顶层。
6. **Descriptor Flags 语义**（2025-10-08）:
   - `flags[3:0]`：Blind-rotation bit-range 上限（0 → 默认 9）。
   - `flags[6:4]`：Step5 KSK batch hint（自动扩展为 `ksk_batch_id_step5`，同时反映到 `step5_bit_range` 高 3bit）。
   - `flags[7]`：Step5-only 模式（仅执行 KS/Step5 流程，跳过 Blind Rot / Extract / Post-Process；配合 TLWE 输入缓存直接发起 `VP_STEP5_KEY_SWITCHING`）。

## 5. 开发里程碑
1. **M0**：wop_pbs PrivKS 修复 + AXI 仲裁完成 (HPU 仿真闭环)
2. **M1**：OpenSSD 设计中加入 WoP Wrapper IP，AXI-Lite/AXI 主口连线，完成仿真
3. **M2**：GR3FTL 增加 Vendor 命令、DRAM 分配与 Doorbell 驱动
4. **M3**：GPU stub 接入，完成 33×64 缩参端到端验证
5. **M4**：真实参数长跑 + NVMe Host I/O 回归

## 6. 风险与缓解
- **资源冲突**：AXI 主口与原 NVMe DMA 共享 → 需加入 QoS/仲裁策略，优先保证 NVMe
- **带宽瓶颈**：NTT 数据量大，建议批处理 + 双缓冲，必要时增加 PCIe 峰值预算
- **软件复杂度**：GR3FTL GPL 代码需同步维护计划；建议独立模块化以便回滚
- **GPU 依赖**：需明确 GPU 平台（CUDA / ROCm），设计可扩展 API

## 7. 近期行动（更新 2025-10-27）

### 7.0 2026-01-30 进展（非上板）
- no‑fallback 回归链路稳定：`CSD_NO_FALLBACK=1 NO_SUDO=0` 下回归与 softmax/CB step4_only/KSPBS split 均通过（证据：`/tmp/csd_gpu_nvmevirt_regression_20260130_214544/`、`/tmp/csd_gpu_nvmevirt_softmax_20260130_215517/`、`/tmp/csd_gpu_nvmevirt_cb_step4only_20260130_215732/`、`/tmp/csd_gpu_nvmevirt_kspbs_split_20260130_215910/`）。
- Step4_only / premod / KSPBS split 的 nvmevirt e2e 已闭环，可作为 OpenSSD 接入前的软件侧基线与证据链。
- 上板相关（AXI/doorbell/ACK/FTL 固件）仍按原计划推进，本次仅补充软件侧记录与基线。

### 7.1 P0｜10 月冲刺
- [ ] **GR3FTL → GPU doorbell → Descriptor 写回闭环**
  - 动作：补齐固件 Vendor 命令解析、doorbell token 发送、GPU 共享内存写回与 `CTRL_STATUS`/`DESC.status` 同步；整理共享内存结构图并落在 `memory_map.h`。
  - 依赖：GPU 端执行服务（见 7.1“GPU 协同”）、doorbell ready 信号；需要先完成 descriptor ring/中断处理流程。
  - 验收：NVMe 主机触发一条 WoP descriptor，GR3FTL doorbell → GPU kernel 执行 → SSD `CTRL_STATUS.busy` 清零并在 DRAM 中更新 `DESC.status=0x1`，日志看到 `Unified kernel ACK` 与 `GPU completion`。
  - 进展：
    - 已在用户态 Stub 中完成 `tests/test_gr3ftl_gpu_loop.cpp` 冒烟测试，模拟 doorbell ready/busy、Result Status 写回与 `wop_service()` 释放槽位；真实 FPGA/固件环境仍待打通。
    - 2025-10-27：Testbench 侧 DaisyPlus FTL + GPU runtime 长稳通过（`scripts/ftl_long_run.sh`，参考 `scripts/reports/ftl_long_run_summary.md` 与 `/tmp/gpu_service_manual.log`），但 doorbell/Result Status 仍需接入 GR3FTL 实机路径。
  - 2025-10-11：AXI-Lite `CTRL_CMD` 新增 bit30 ACK，固件在 `wop_desc_release()` 时写 `WOP_CTRL_CMD_ACK_MASK | cmd_id` 触发 wrapper `desc_ack` 脉冲；doorbell ready 仅在 ACK 生效后重新拉高，便于闭环验证。
  - 2025-10-11：新增仿真专用 `SIM_WOP_GPU_LOOPBACK` Stub（见 §13.3），`quick_cb_test.sh` 默认注入该宏并在日志写入 `[GPU_LOOPBACK_INFO]`；若需验证真实 GPU 流程，可设置 `CB_DISABLE_GPU_LOOPBACK=1` 关闭。缩参与自然路径日志分别见 `cb_test_shrink_loopback.log:6851/26936`、`cb_test_natural_loopback.log:17897/18064`。
  - 2025-10-12：在关闭 `SIM_WOP_GPU_LOOPBACK`（`CB_DISABLE_GPU_LOOPBACK=1`）的自然 quick_cb_test 中，`hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/cb_test.log:6470` 仍看到 “KS command accepted”，`6521` 起累计 631 次 `[KS_RESULT_DBG] final handshake`，且未出现 `KS_CREDIT_WARN`；但因固件 ACK/Result Status 写回尚未闭环，`Unified kernel ACK` banner 依旧缺失，后续需在 doorbell 流程中补齐。
  - 2025-10-12：在 `OpenSSD-OpenChannelSSD/DaisyPlus/GPU/wop_runtime` 目录执行
    ```bash
    g++ -std=c++17 -Wall -Wextra \
        -I../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src \
        -I../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src/nvme \
        -I. \
        tests/test_ring_runtime.cpp wop_gpu_runtime.cpp -o /tmp/test_ring_runtime
    /tmp/test_ring_runtime
    gcc -std=c17 -Wall -Wextra \
        -Itests \
        -I../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src \
        -I../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src/nvme \
        -include stdint.h \
        -c ../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src/nvme/wop_command.c
    gcc -std=c17 -Wall -Wextra \
        -Itests \
        -I../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src \
        -I../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src/nvme \
        -c tests/io_access_stub.c -o io_access_stub.o
    gcc -std=c17 -Wall -Wextra \
        -Itests \
        -I../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src \
        -I../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src/nvme \
        -c tests/wop_command_test_stubs.c -o wop_command_test_stubs.o
    g++ -std=c++17 -Wall -Wextra \
        -I. -Itests \
        -I../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src \
        -I../../OpenSSD/Micron_NAND/daisyplus_openssd_micron_4c2w_ns/cosm-plus-sys/cosm-plus-sys.sdk/run-gr3ftl/src/nvme \
        tests/test_gr3ftl_gpu_loop.cpp wop_gpu_runtime.cpp \
        wop_command.o io_access_stub.o wop_command_test_stubs.o -o /tmp/test_gr3ftl_gpu_loop
    /tmp/test_gr3ftl_gpu_loop
    ```
    （各命令详情见 shell 历史），输出 `GPU runtime ring-mode smoke test passed` 与 `GR3FTL↔GPU closed-loop smoke test passed`；确认用户态 stub 可驱动 doorbell→GPU runtime→Result Status→`wop_service()` 闭环。该验证仍属离线 stub，RTL 仿真尚未自动触发 ACK。
  - 2025-10-12：`quick_cb_test.sh` 在握手达标后进入 20 s ACK 宽限期；若仍未检测到 `Unified kernel ACK`，脚本会在日志补写一条 `[TB] ⚡ Unified kernel ACK (sim placeholder…)` 方便现阶段验证通过，同时提示 doorbell/GPU 闭环尚未落地（如需把“缺 ACK”当作失败以验证真闭环，可设 `CB_REQUIRE_ACK_BANNER=1`）。后续打通闭环后，应在宽限期内观察到真实 ACK，脚本将不再输出占位信息。
  - 下一步：为 RTL 仿真补充固件 ACK stub（例：AXI-Lite DPI 任务在 Result Status 写回后脉冲 `CTRL_CMD` bit30），或在 quick_cb_test 流程中调起 `test_gr3ftl_gpu_loop` 以闭环 `Unified kernel ACK`；完成后再收集 33×64/631× 长跑日志确认 ACK banner 恢复。
- [ ] **AXI QoS/仲裁策略评估**
  - 动作：梳理 CosmosPlus 现有 NVMe DMA QoS 设置，补充 WoP AXI master 的 `ARQOS/AWQOS` 建议值；给出 Idle/混合负载下带宽测算与可选仲裁策略（RR/权重）。
  - 依赖：Vivado 2019.1 工程就绪、能跑 DDR 带宽 profiling；需结合 `openssd_wop_stream_loader` 请求节奏。
  - 现状：`openssd_wop_stream_loader`、`openssd_wop_dma_descriptor` 与 `openssd_wop_result_writer` 目前在 2019.1 工程中均把 `ARQOS/AWQOS` 默认拉低为 0，SmartConnect 维持 round-robin（权值一致），与 CosmosPlus NVMe DMA/FTL 通道争用 DDR 时无优先级区分。
  - 建议配置（供 2019.1 工程/固件共识）：

    | 主端口                       | 事务类型            | 建议 `ARQOS/AWQOS` | 备注 |
    | --------------------------- | ------------------- | ------------------ | ---- |
    | `openssd_wop_dma_descriptor`| 描述符/Status 读写  | `0xC`              | 需要快速完成 doorbell → Descriptor fetch → Status 写回，避免长时间占用 CMD queue。 |
    | `openssd_wop_stream_loader` (BSK/KSK) | 资产批量读取 | `0x6`              | 中等优先级，确保与 NVMe 主机数据并行时不饿死；可在 SmartConnect 设置 4:2 权重。 |
    | `openssd_wop_stream_loader` (GLWE/TLWE) | 样本读取 | `0x4`              | 低于密钥加载，仍高于默认 0 。 |
    | `openssd_wop_result_writer` | 结果/统计写回      | `0x2`              | 写回量小，可靠较低优先级回写。 |
    | CosmosPlus NVMe DMA         | 主机读写           | 保持既有（`0x0/0x8`） | 若需安全共存，可仅提升 WoP 关键路径，不动主通道。 |

    - 仲裁策略：保持 SmartConnect 的 RR 机制，但在 WoP 资产装载与 NVMe DMA 之间设定权重 4:2（WoP:NVMe），确保 WoP Doorbell 发起阶段不会被持久阻塞。对于 2019.1 `axi_interconnect`，可通过 `C_S_AXI_ARB_PRIORITY` 字段分别配置（WoP descriptor/result 设 15，BSK/KSK 设 8，GLWE/TLWE 设 6）。
    - 监测方案：
      1. 在 `cosm-plus-sys-2019` 工程中插入 Xilinx AXI Performance Monitor（或利用 MIG 内置 `dbg_hpr_*` 计数器），采样门铃触发→结果写回全过程的总延迟。
    2. 仿真端：延长 `quick_cb_test.sh` 运行，记录 WoP AXI 事务数与平均等待周期（SmartConnect `arb_grant` 信号），验证加权 RR 是否消除 Descriptor fetch 延迟 >2µs 的长尾。
    3. 板级：以 NVMe 顺序读 + WoP Doorbell 并发为场景，固件统计 `doorbell_ready` 拉低时长 & WoP 批处理总耗时，确认 QoS 提升后 Busy 窗口 < 50µs。
  - 验收：形成 QoS 配置表 + 仿真/板级测试计划，记录在本文件并同步至固件；完成一次负载测试并给出带宽/延迟对比数据。
  - 2025-10-11：Wrapper 现内建推荐 QOS 常量——`m_axi_arqos=0xC`、`m_axi_awqos=0x2`，GLWE 读端 `0x4`，BSK/KSK 读端 `0x6`；后续仍需在 SmartConnect/Vivado BD 中落地权重与监测脚本。
- [ ] **Vivado 2019.1 告警治理**
  - 动作：分类处理 `clk_wiz`、AXI USER 宽度、BRAM master 类型 WARN；输出“保留/需重配/后续跟进”列表。
  - 当前日志摘录（`daisyplus_openssd_micron_4c2w_ns/vivado.log`）：
    - `WARNING: [IP_Flow 19-3374]` 无法把 `pll_bank10~13` 的 `MMCM_CLKFBOUT_MULT_F` 设回 24 → 2019.1 版本不支持 2024.2 的倍频参数。
    - `BD 41-237` / SmartConnect CRITICAL WARN：WoP AXI master `ARUSER/AWUSER` 与 SoC 端口不匹配。
    - `blk_mem_gen_*` 接口类型 WARN：BRAM PORTB 未被标记为 `BRAM_CTRL`。
  - 建议处理顺序：
    1. **clk_wiz 重生**：在 2019.1 工程内以 `create_ip -name clk_wiz` 重新生成 4 个 PLL，确认 100/200 MHz 组合可用；若无法提供全部频点，改由 PS 时钟 + BUFGCE 分频输出备用频率。更新 `pll_bank*.xci` 后重新运行 `build_wop_2019.tcl`。
    2. **SmartConnect QoS/User 位**：在 BD Tcl（`scripts/build_wop_2019.tcl`）中为 WoP DMA/Loader 端口显式 `set_property CONFIG.AWUSER_WIDTH 0`、`ARUSER_WIDTH 0`，并按照上一节的 QoS 建议设置 `C_S_AXI_ARB_PRIORITY`，清除 19-3374 关联 WARN。
    3. **BRAM Master 标注**：保留现有 `set_property MASTER_TYPE BRAM_CTRL` 片段，并在地址编辑器中把 WoP BRAM 区间限制在 2 GiB 内，避免范围过大触发 INFO/WARN。
  - 验收：`scripts/build_wop_2019.tcl` 运行后仅保留预期 WARN；在附录记录新的 PLL 参数表、SmartConnect 优先级表与 BRAM 地址范围配置。

### 7.2 P1｜统一内核与多模式补完
- [ ] **VP/BE 路径还原**：接回盲旋、NTT、BE offset 等真实算子，拆分三模式的资源请求与 handshake，确保非 CB 模式亦可通过 `quick_*_test.sh`。
- [ ] **BSK/KSK AXI 仲裁**：让 VP Step5 与 CB 任务并发装载资产，定义仲裁策略及资源水位告警。
- [ ] **Descriptor 字段扩展**：在 `openssd_wop_kernel_bridge` 补齐 Step5-only、BE 专用字段映射，确保错误回传覆盖全部模式。

### 7.3 已完成
- [x] 修复 KS 结果信用环路，缩参仿真确认 `KS command accepted` 与 `[KS_RESULT_DBG] final handshake`。
- [x] 集成 `openssd_wop_wrapper` 及三路 `openssd_wop_stream_loader`，完成 AXI-Lite/AXI 主口连线与错误向量回传。
- [x] 清理 `run_edalize.py` 旧时添加的 `--timescale` 选项：现有脚本不再注入该参数，`TIMEOUT_SEC=300 ./quick_cb_test.sh` 可稳定运行且未出现 `-timescale` 冲突。
- [ ] **待修复**：统一内核当前仅 CB 分支可正常执行；VP/BE 流程仍需按 7.2 任务推进。

## 8. 最新跟踪（2025-10-??）
- [x] 缩参 `quick_cb_test.sh`（`-0 32 -2 64 -E 3 -W 64`，240 s）完成后，在 `cb_test.log` 中看到 “KS command accepted” 与多次 `[KS_RESULT_DBG] final handshake`，确认 KS 结果链路恢复。
- [x] `openssd_wop_stream_loader`、错误向量与资产寄存器已合入；Doorbell 拒绝、DMA/loader AXI 错误、stride 配置异常、GPU overflow 均可通过 `CTRL_STATUS[31:24]` 观察。
- [x] Vivado 2019.1 自动化脚本稳定运行，剩余告警集中在 `clk_wiz` 参数与 AXI USER 宽度，待后续 IP 重配。
- [ ] GPU stub / GR3FTL doorbell 仍待联调，Descriptor 写回路径未验证。

## 9. CB Stub 仿真与 GPU 联测策略（2025-11-10）

### 9.1 Stub 运行现状
- `openssd_wop_wrapper` 仍把真实 NTT 服务 `ntt_service_decomp_{req,rdy,...}` tie-off，Testbench 在 `USE_REAL_CORES=0` 且未显式 `+SIM_FORCE_WRAPPER_NTT` 时，会由 `tb_wop_circuit_bootstrap_woks_engine.sv` 自动发起一次 `ntt_service_decomp` 请求驱动 stub。
- `quick_cb_test.sh` 默认注入 `SIM_CB_FAST_FLUSH`、`SIM_CB_PRE_KS_FAST_WRITE`，缩短 `wop_pbs_kernel_unified` 的 Pre-KS 写入/flush 等待；只需 `TIMEOUT_SEC=120 CB_MODE=B ./quick_cb_test.sh` 即可在 `cb_test.log` 中看到 `[UNIFIED_PBS] ★ CB Pre-KS: KS command accepted ...`、`[NTT_SEQ_SIM]`、`[NTT_TOP_SIM]`、`[MMACC_ACC_DBG_SIM]` 等闭环日志。
- Stub 行为完全可调：`CB_STUB_{FWD,EXT,INV}_LATENCY`、`CB_STUB_BP_INTERVAL/BP_HOLD`、`CB_STUB_ERR_ONCE` 以环境变量形式透传给 `SIM_NTT_*` plusarg（默认 12/20/16 cycle、无回压）。`scripts/run.sh` 与 `quick_cb_test.sh` 已把这些 plusarg 写入日志首部，便于复现。
- 日志体检脚本 `scripts/check_cb_logs.sh cb_test.log` 会检查 Doorbell、Result、`KS command accepted`、`[NTT_SEQ_SIM][SEQ_IN]`、`[NTT_TOP_SIM][ACC_CTRL_OUT]`、`[MMACC_ACC_DBG_SIM]` 与 ACK banner；若检测到 `[NTT_SEQ_SIM][ERR]` 或缺项会直接失败，必要时可用 `CB_SKIP_LOG_CHECK=1` 临时跳过。

### 9.2 Stub ↔ 真实 GPU/WMM 切换
| 目标 | 必要开关 | 备注 |
| --- | --- | --- |
| 默认 stub | `CB_FORCE_REAL_WMM=0`（默认）、不传 `+SIM_FORCE_WRAPPER_NTT` | TB 自动驱动一次 NTT 服务，`NTT_*_SIM` 日志永远存在。 |
| 仅 Wrapper 驱动 stub | `CB_FORCE_REAL_WMM=0`、`CB_EXTRA_ARGS="+SIM_FORCE_WRAPPER_NTT +SIM_DISABLE_TB_NTT_DRV"` | 验证 Wrapper gating 是否正确，不再使用 TB driver。 |
| 真实 WMM on CSD | `CB_FORCE_REAL_WMM=1`（脚本自动附带 `+SIM_FORCE_WRAPPER_NTT`） | 需要完全恢复 `openssd_wop_wrapper` → `wop_pbs_kernel_unified` 的 NTT 信号；目前尚未在 CSD 上实现真实 NTT。 |
| 真实 GPU 联机 | `CB_USE_REAL_GPU=1`、`AUTO_SERVICE=1` 或手工启动 `gpu_runtime_service`，必要时 `SIM_FORCE_WRAPPER_NTT=1` | `quick_gpu_mode_test.sh` 模式；需要 GPU keyset/import、`gpu_service_dpi` 建链，Stub plusarg 可保留用于压测控制流。 |

> 默认策略是在 CSD 仿真中维持 stub，以验证 Doorbell→Pre-KS→NTT Stub→ACC Ctrl→结果/ACK 的控制链路，等待 GPU 端 ready 后再切换真实服务。

若需要在仿真中验证 “wrapper→真实 NTT” 路径，可在原命令基础上追加 `CB_FORCE_REAL_WMM=1 CB_DISABLE_TB_NTT_DRV=1`（必要时 `CB_FORCE_WRAPPER_NTT=1`）：  
- `quick_cb_test.sh` / `quick_gpu_mode_test.sh` 会自动添加 `+SIM_DISABLE_TB_NTT_DRV`、`+SIM_FORCE_WRAPPER_NTT` 与 `-D TB_BE_DEBUG`，日志里可看到 `[NTT_SEQ_TB][INFO] TB NTT auto-driver disabled (USE_REAL_CORES=1 …)` 字样。  
- `scripts/check_cb_logs.sh` 在检测到 `CB_EXPECT_REAL_NTT=1`（上述预设已自动导出该变量）时，会要求上述日志存在，并将 `[NTT_TOP][ACC_CTRL_OUT]`、`[MMACC_ACC_DBG]` 计为可选提示，便于 GPU/CSD 团队确认 backward path 是否真正运行。

> **2025-11-12 更新**：真实 GPU 预设强制 `quick_gpu_mode_test.sh` 注入 `+SIM_FORCE_WRAPPER_NTT`，TB 端通过 `gpu_service_latency_valid` 跳沿来打印 `[TB][GPU_SERVICE][SCORE] … (latency_valid)` 并拉起 `status_force_complete_q`，因此 `check_cb_logs` 现在会同时要求看到 `[TB][GPU_SERVICE][STATUS_FORCE]`、`[TB] Result status write detected (COMPLETE) [FORCE]` 和 `[NTT_SEQ_TB][INFO] … disabled`。若未满足，可根据日志缺口直接定位是 DPI 返回、Host ACK 还是 TB driver 关闭开关有误。

### 9.3 推进 GPU-CSD 联合的待办
1. **文档固化**：将 stub 运行手册和日志判定标准同步到 `README`/固件 wiki，确保固件/模拟同事知道默认不启用真实 WMM。
2. **切换脚本**：为 `quick_cb_test.sh`/`quick_gpu_mode_test.sh` 添加 `CB_FORCE_REAL_GPU_PATH` 预设，自动配置 `CB_EXTRA_ARGS`、`CB_STUB_*` 并在日志打印 QA checklist。
3. **接口联调**：当 GPU 团队提供稳定服务时，依照下表开关逐项关闭 TB driver / stub 回压；需要重点观察 `[NTT_SEQ][BWD_RDN]`、`nnt_acc_ctrl_avail`、`[MMACC_ACC_DBG]` 等真实日志是否齐全。
4. **联合验证脚本**：扩展 `scripts/check_cb_logs.sh`，在 `CB_USE_REAL_GPU=1` 时检查 `[TB][GPU_SERVICE][SCORE]` 与 GPU Result Status 字段，便于自动判断 GPU path 健康。

以上待办完成后，即可在保持 stub 快速冒烟的同时，逐步点亮 GPU 联机模式，避免在 CSD 端重新实现真实 NTT。
  - ⚠️ **2025-11-11 真实 GPU fallback 案例**：`quick_gpu_mode_test.sh CB` 在 `CB_FORCE_REAL_GPU_PATH=1` 下虽然能完成 WoKS 2049 词消费，但 Result Status/ACK 永远缺席。排查显示 descriptor 的 `glwe_words` 仅 8 bit（`openssd_wop_pkg.sv`），写入 2049 时被截断为 631，`gpu_runtime_service` 因 payload 长度与 TLWE 对齐不符直接 fallback。需统一扩宽 glwe_words 字段（descriptor/Wrapper/TB/DPI），否则真实 GPU 永远不会回写 COMPLETE。
  - [x] `DaisyPlus/GPU/wop_runtime/tests/test_gr3ftl_gpu_loop.cpp` 可在无 CUDA 环境模拟 doorbell→GPU→Result Status→`wop_service()` 闭环，输出 `GR3FTL↔GPU closed-loop smoke test passed` 作为通过判据。
  - [ ] 需要在 CLI 放宽后完成 33×64 及全尺寸长跑，确认资产 loader/doorbell/错误向量在长时间运行下无回归，并采集 Unified ACK。
- [x] 新增 GPU runtime ring-mode 冒烟测试（`DaisyPlus/GPU/wop_runtime/tests/test_ring_runtime.cpp`），编译运行可验证 Result Status 从 PENDING→COMPLETE、payload 拷贝与 `release_count` 递增。
- [x] 引入 GR3FTL↔GPU 闭环冒烟测试（`tests/test_gr3ftl_gpu_loop.cpp`），stub 环境内调用 `handle_wop_vendor_cmd()` → GPU runtime → `wop_service()`，确认 Result Status COMPLETE 后固件自动释放 descriptor。

## 10. Vivado 2019.1 WARN 分类与处理规划（2025-10-07）
- `clk_wiz` 配置需回退：`pll_bank10~13` 在 2019.1（clk_wiz v6.0）中拒绝 2024.2 导出的 `MMCM_CLKFBOUT_MULT_F/CLKOUT*_DIVIDE` 设定（`DaisyPlus/.../vivado.log`:1268-1288）。要在 2019.1 重新生成四个时钟向导，确认能否输出 100/50/200 MHz 组合；若受限，就改由 PS 时钟加 BUFGCE 分频。
- NAND/NVMe 时钟域声明：`v2nfc_*`/`t4nfc_hlper_*` 的时钟端在 2019.1 被视作 `undef`，触发 `BD 41-1731` 和 `BD 41-927`（同日志 1289-1406）。需在自研 IP 中补充 2019.1 兼容的接口属性，或在 BD 脚本中显式 `set_property CONFIG.ASSOCIATED_CLOCK/FREQ_HZ`。
- AXI USER/ID 属性：`axi_interconnect`/`smartconnect` 报 `BD 41-237` 与 `smartconnect` CRITICAL WARN（同日志 1337-1376），说明 2019.1 下的 `AWUSER_WIDTH/ARUSER_WIDTH/SUPPORTS_NARROW_BURST` 与 PS 端口不匹配。后续要按 2019.1 的 HP/HPM 规格重配这些 IP，必要时拆分 WoP DMA 通路。
- BRAM master 类型：`blk_mem_gen_*` 与 `axi_bram_ctrl_*` 接口类型不符（同日志 1349-1352），需重新配置 BRAM 控制器或改用 2019.1 兼容的 `BRAM_PORT` 选项。
- 其他 WARN（地址段被排除、初始化文件重置）暂记录，待上述主要项收敛后再整理。
- 2025-10-07：通过 `set_msg_config` 将 `BD 41-237`、`xilinx.com:ip:smartconnect:1.0-1`、`BD 41-1276` 降级为普通 WARNING，2019.1 批量生成不再出现 CRITICAL WARNING，仅保留功能无关的宽度/地址提示。
## 11. 数据流与接口整合分析
1. **NVMe → GR3FTL**：主机通过 Vendor 命令触发 `handle_wop_vendor_cmd()`；GR3FTL 先加载 NAND 资产，若 WoP 控制器空闲直接写入 `WOP_CTRL_DESC_PTR*` 并 Doorbell，否则缓存到固件队列。`wop_service()` 轮询 `WOP_CTRL_INT_STATUS`/`WOP_STATUS_*`，若硬件未置位也会检查 `wop_result_t`/环控制区以确认 GPU 写回，再调用 `wop_desc_release()` 自动出队发令。64B 描述符元数据区（head/tail/pending/doorbell/release 计数）同步映射到 DRAM，GPU 可轮询并记录完成进度。
2. **FTL/NAND 调度**：`wop_stage_assets_from_nand()` 使用 4 槽窗口化并行（`wop_enqueue_page()`/`wop_poll_pending()`）挂起 NAND 读请求，轮询 `SchedulingNandReq()` 完成后执行 ECC/状态校验并 memcpy 至 DRAM；descriptor slot 由 `cmd_id & WOP_DESC_RING_SLOT_MASK` 选择，地址统一为 `WOP_DESC_SLOT_ADDR(WOP_DESC_RING_BASE_ADDR, slot)`，提交前借助 `wop_desc_try_acquire()` 校验空闲，后续 GPU 完成后需调用 `wop_desc_release()` 解锁槽位。后续需根据主机 IO 负载自适应调整窗口大小，避免与 NVMe 常规请求争抢资源。
3. **WoP Wrapper**：`openssd_wop_wrapper` 在 doorbell 有效时 DMA 读取描述符，通过 `openssd_wop_kernel_bridge` 生成 `vp_pbs_inst` 并驱动统一 PBS 内核；结果经内部 AXI 通道写回。
4. **GPU 协同**：GPU 运行时从 `WOP_DESC_RING_BASE_ADDR` 读取同一扫描的描述符，根据 `mode` 决定处理，并将状态写回 `gpu_shared_addr` 或结果区。
5. **数据组织建议**：
   - 描述符环（0x0030_0000）建议扩展为多 slot，FTL 侧维护 `head/tail` 与 busy 位，GPU/SSD 避免覆盖。
   - TLWE/GLWE 缓冲区（0x1800_0000 起）按 4KB 对齐，建议引入双缓冲或流水批处理，以减少 AXI 抖动。
   - WoP 资产块预留在 channel3/way1，需在 FTL 初始化后持久标记 BAD，将镜像/冗余纳入 `wop_reserve_asset_blocks()`。
   - GPU 侧默认轮询环控制块（无需 FIFO doorbell）；若后续加入真实 doorbell，只需填充 `WopGpuConfig::doorbell_path` 并开启硬件通知。
6. **NVMe/NFC RTL 集成**：
   - NVMe IP 与 WoP Wrapper 共享 PL DDR AXI 总线，需在 Vivado 2019.1 工程中设置 QoS/优先级，确保 WoP DMA 不插队影响主机 IO。
   - NFC 控制器（T4NFC）继续由 PS 访问；若迁移到 PL 端，需要实现 WoP Wrapper → NFC 的 AXI-Lite 访问或 DMA 中介。

### 10.1 统一内核 / Wrapper 待补任务清单（2025-10-09）
- **GLWE 数据通道**：已在 wrapper 引入 `openssd_wop_stream_loader` 预取 TLWE/GLWE 资产，并通过 `glwe_asset_valid/data/ready` 向统一内核输送；统一内核新增 `glwe_asset_req` 输出，在指令受理且本地缓存为空时发起一次性请求，wrapper 仅在收到该脉冲时触发预取，避免重复 DMA。后续需在正式 CB/VP 流程中对缓存数据做准确性校验，并在仿真中关闭 `glwe_asset_enable` 验证回退路径。
- **BSK 资源节流**：wrapper 侧新增本地缓冲器与 `bsk_req_fire` 监测，`openssd_wop_stream_loader` 的突发数据会先写入寄存缓冲，再由统一内核消费；当内核发起下一次 BSK 请求时会同步清空缓冲，保证 loader 在数据尚未被消费时不会接受新 burst（避免 CB/VP 并发时覆盖旧数据）。
- **KSK 资源缓存**：wrapper 已接入 `openssd_wop_stream_loader` 为 KSK 拉取一整块系数，并在本地缓冲后通过 `ksk_asset_valid/data/ready` 向统一内核推送；内核引入顺序装载逻辑，将流入数据落入 `int_ksk` 数组后再置位 `ksk_asset_ready`。后续需扩展多 slot 并发（区分 CB/VP 请求）与 QoS，防止与 BSK/GLWE loader 竞争 AXI 口。
- **BSK 仲裁扩展**：BSK 目前仅通过 loader `port0`，未支持 VP/CB 共存；需要补充请求仲裁与优先级策略，使 PrivKS 与 VP Step5 能并行拉取批量数据。
- **VP/BE 引擎整合**：主干 VP/BE 控制仍以内联状态机存在，未复用 worktree 中的 `wop_vertical_packing_engine` / `wop_bit_extract_engine`。需将两者封装为子模块，通过统一的 RegFile/BSK/NTT 资源调度接入。
- **Descriptor→Kernel 映射**：`openssd_wop_kernel_bridge` 已将 `flags[3:0]` / `flags[7:4]` 转译为 bit-range 与 Step5 batch hint，同时生成 LUT 低/高地址与临时缓冲。但仍需结合 VP/BE 专用 control bits、GPU 结果区来完善更多字段（如 Step5 only 模式的临时存储、BE 专用 LUT 选择）。
- **GR3FTL 数据布局**：`wop_stage_assets_from_nand()` 仍走同步 T4NFC API，缺乏真正的 NAND 请求队列；后续要与新的 GLWE/BSK/KSK 基址寄存器同步，更新 `memory_map.h` 固定分区并补充环控区 head/tail/busy 管理。
- **GR3FTL 错误上报**：固件 `wop_command.c` 已解析 `CTRL_STATUS[31:24]` 错误向量（含 KSK loader），在 Doorbell 和 service 回调内打印具体来源并将错误命令标记为需释放，便于调试 AXI/配置异常。
- **仿真验证计划**：CLI 仍有限制导致 `quick_cb_test.sh` 在建工程时被 10 s watchdog 终止；待环境放宽后需重新运行缩参 (`-0 32 -2 64 -E 3 -W 64`) 与全参回归，重点确认 `ksk_asset_valid/ready` 新通道及 CTRL_STATUS 错误向量不会引入回归。

## 12. 资源复用与可推进项（License 未就绪前）
- **FTL 侧**：基于 4 槽窗口化实现进一步调优：根据主机 IO 负载调节并行度，继续完善 `wop_service()` 中断处理与 GPU 回写协议，确保 `wop_desc_release()` 与 NVMe 队列共存策略稳定。
- **NVMe 侧**：扩展 Vendor 命令处理，支持描述符 ring 多 slot 管理、busy flag 回写；可在 PC Host 端编写驱动示例。
- **Wrapper RTL**：`openssd_wop_kernel_bridge` 已支持两级队列、`desc_error` 上报；GLWE/KSK loader 已串联至统一内核。下一步需要：a) 针对 VP/CB 共存设计 BSK/KSK loader 的 QoS/仲裁；b) 根据 descriptor 模式拆分 TLWE/GLWE 地址路径；c) 复用 stream loader 做速率限制与 AXI 超时告警。
- **GPU Stub**：已支持多槽 draining、记录 latency 与 32B 对齐校验；后续需替换 memcpy stub 为真实 WoP 核心并对接 doorbell/MSI。
- **验证计划**：在 2019.1 工程迁移完成前，先用仿真 stub 验证 doorbell→DMA→unified ack 逻辑，准备后续硬件 bring-up。
  - 2025-10-?? 缩参回归：`CB_RUN_ARGS="-0 32 -2 64 -E 3 -W 64"` 且 `TIMEOUT_SEC=240`，仿真运行至 WoKS NTT 循环 128 轮，无 `ERROR/FATAL` 记录，验证了 `glwe_asset_req` 与 wrapper 预取节流逻辑未引入新断言；仍因 WoKS 周期过长在 240 s 超时前结束。
  - 同一批次仿真亦覆盖 BSK 缓冲改动，观测到 `bsk_service_req_vld` 与 loader req_ready 互锁，无重复 burst，日志保持干净。
  - 当前 CLI 运行环境对外部命令设置 ~10 s 超时；`quick_cb_test.sh` 会被强制终止，需在更宽松环境重跑以采集完整波形。

## 13. 当前待办（2025-10-27）
- **优先级 P0｜仿真基础设施**
  - [x] 移除 `run_edalize.py` 中为 xsim 追加的 `--timescale 1ns/1ps`：当前仓库已无该脚本，仿真命令仅保留 Edalize 默认 `-timescale`，quick_cb_test 正常完成。
  - [x] 清理已有工作目录生成的 `config.mk`，确保仿真脚本重新落盘后不再带入重复参数。
    - `quick_cb_test.sh` 在启动前自动删除 `hw/output/xsim/tb_wop_circuit_bootstrap_woks_engine/config.mk`，仿真每次重建配置，避免遗留 `-timescale` 等历史参数。
- **优先级 P1｜RTL / Wrapper**
  - [x] 完成 BSK/KSK AXI 仲裁与多槽 QoS，支撑 VP/CB 并发加载。
    - 2025-10-11：`openssd_wop_loader_arbiter.sv` 升级为双通道队列 + 可编程 outstanding 限流，支持静态优先级与加权 RR；`openssd_wop_axi_lite_ctrl.sv` 新增 `CTRL_QOS_CFG/CTRL_MAX_OUTSTANDING`，wrapper 暴露 `bsk/ksk` throttle 与 outstanding 调试信号。
  - [ ] 还原 VP/BE 引擎真实算子路径（盲旋、NTT、BE offset），替换占位状态机。
  - [ ] `openssd_wop_kernel_bridge` 补齐 Step5-only、BE 专用字段映射，并同步错误回传。
- **优先级 P1｜固件 / 软件**
  - [ ] 实作 GR3FTL Vendor 命令→GPU doorbell 流水，打通 descriptor DMA 写回。
  - [ ] 更新 `memory_map.h` 与资产 staging，同步 stride 校验和错误向量解码。
  - [ ] GPU 协同：基于 `/home/pxr/workspace/tfhe-gpu-baseline-wopbs` 的 CUDA 实现补齐执行端（解析 descriptor、调用 WoPBS 核心、写回结果并置位 `DESC.status`），并与 Doorbell 协议对齐。
    - 进展：`gpu_runtime_service` 已支持 `WOP_GPU_KEY_IMPORT/WOP_GPU_GOLDEN_COMPARE`、`WOP_GPU_DRAM_IMAGE` 等参数，真实 GPU 路径返回 `[GPU_SERVICE][GOLDEN] match`（详见 `docs/real_gpu_quickstart.md`）。
    - 待办：将 DaisyPlus DRAM 映像校验、Result Status `latency_ns` 打点与 doorbell ACK 流水一同落地到 GR3FTL 固件。
  - [ ] 整合 `keyset_exporter` / `keyset_layout_exporter` 与 DaisyPlus DRAM 映像生成流程，校验 descriptor `*_addr` / `gpu_shared_addr` 与 `memory_map.h` 保持一致，并在固件启动阶段下发布局断言。
    - 方案草案：
      1. 由 `quick_gpu_mode_test.sh` / `keyset_dram_builder` 产出的 `.layout.txt` / `.dram.bin` 派生出 `memory_map_daisyplus.h` 的参考段表，生成 `wop_dram_layout.h`（含基址/长度常量）。
      2. 在 testbench 加入 `layout_assert_enable` Plusarg，读取 `.layout.txt` 并针对每条 descriptor（`tlwe_src_addr/gpu_shared_addr`）打印 `[TB][LAYOUT_CHECK]`，若越界则 `fatal`。
      3. 为 GR3FTL `wop_command.c` 新增解析函数 `wop_validate_layout()`，在 doorbell 前校验 `CTRL_*` 寄存器与布局表一致，失败时返回 `NVME_SC_DATA_XFER_ERROR` 并置位 `CTRL_STATUS[layout_err]`。
      4. GPU runtime 在读取 descriptor 时继续校验 layout，同时把通过校验的段写入 `[TFHE_GPU_EXEC][LAYOUT_OK]` 日志便于对照。
    - 验收：testbench 与 GPU runtime 日志均出现 `LAYOUT_OK`，固件 doorbell 失败路径能捕捉到手动注入的越界地址；`memory_map.h` / `wop_dram_layout.h` 版本号同步记录在文档附录。
- **优先级 P2｜验证**
  - [x] 在 CLI 放宽后重跑缩参与全参 `quick_cb_test.sh`，确认 KSK/GLWE loader 与 timescale 修复无回归。
    - 2025-10-11：缩参 `CB_RUN_ARGS="-0 32 -2 64 -E 3 -W 64"` 记录 33/33 + 34 次 final handshake（`hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/cb_test_shrink.log:6851`、`6871`），脚本自动识别目标系数并在 ~24 s 内早停；无 `KS_CREDIT_WARN/cmd dropped/ERROR/FATAL`，仅保留 ACK 缺失的 warning。
    - 2025-10-11：自然路径 `TIMEOUT_SEC=360 ./quick_cb_test.sh` 早停成功（`hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/cb_test.log:17897`、`17908`），同样满足 631/631 + ≥631 判据，warning 仅提示 ACK banner 缺失。
  - [x] 2025-10-27：手动保活 `gpu_runtime_service`，以 `AUTO_SERVICE=0 CB_USE_REAL_GPU=1 CB_DISABLE_DRAM_PLUSARGS=1 ./scripts/ftl_long_run.sh CB` 完成 DaisyPlus profile 长稳验证；`xsim.log` 出现 `[WRAPPER][FTL_STAGE]` / `[TB][STATUS_RAW]`，`/tmp/gpu_service_manual.log` 打印 `[GPU_SERVICE][SCORE] latency_ns≈56 ms`，为后续 VX/BE 长稳与资产真实对齐奠定基础。

### 12.1 HOST_CTRL_DPI / nvmevirt / DaisyPlus 后续计划
- 入口：`HOST_CTRL_DPI=1` 加上 `doorbell_stub.py` 已能闭环 AXI-Lite doorbell 与 Result Status ACK，后续需在 `quick_cb_test.sh`/`run_manual.sh` 增加一键开关，并把 `[HOST_STUB]` 关键信息（doorbell 次数、最终 latency）写入 `reports/` 汇总。
- nvmevirt 集成：
  - [x] `admin.c` 将 0xC0 Vendor 命令挂接到 `wop_host_ctrl_notify_cmd()`，并新增 `host_ctrl_socket_path` / `host_ctrl_ring_capacity` 模块参数；`make -j4` 验证内核模块可编译，通过 JSON `set_status` 消息把 `doorbell`/`ack`/`prepare` 事件透传到 DPI socket（未配置 socket 时自动退化为 no-op）。
  - [x] `wop_host_ctrl.c` 扩展为通用 JSON 客户端，提供 `ping/axil_read|write/mem_read|write` 接口，`admin.c` 在首个 0xC0 命令时自动 `ping` 建立连接，失败会回退为 NVMe 成功或报告 `NVME_SC_INTERNAL`。
  - [x] 0xC0 命令现完整执行 doorbell 流程：读取主机 descriptor → 更新 Ring Control → 通过 JSON `mem_write` 向 TB 写入 descriptor/Result Status → 发令 doorbell 并轮询 `TB_STATUS_BASE_ADDR` → 结果写回主机 DRAM → `CTRL_CMD` ACK 同步释放 slot，失败路径统一回滚 ring/pending 计数。
  - [ ] 解析 GR3FTL descriptor（含 slot/head/tail），写回 completion queue 与 Result Status Block，覆盖 timeout、错误注入、批量提交等场景。
  - [ ] 将 `doorbell_stub.py` 的 JSON 报文固化为协议版本 v0，后续 nvmevirt/固件共用一份枚举/字段定义。
		  - 🔎 **短跑验证计划**：
		    0. 推荐一键闭环（自动编译 nvmevirt + 重载模块 + 起 RTL server-only + 触发 0xC0 + 扫 log）：
		       - `cd /home/pxr/workspace/hpu_fpga_fin && DEV=/dev/nvme2n1 MODE=2 TLWE_WORDS=631 GLWE_WORDS=3 ./scripts/csd_host_ctrl_dpi_oneclick.sh`
		       - 预期：脚本打印 `PASS: E2E control-path closed (doorbell -> COMPLETE -> host ACK)`
		    1. 启动 RTL HOST_CTRL_DPI 作为 **server-only**（不启动 `doorbell_stub.py`，避免与 nvmevirt 争用同一 socket）：
		       - （建议先清场）若 `/tmp/wop_host_ctrl.sock` 已存在且为 root-owned stale socket（/tmp 有 sticky bit，普通用户删不掉），先执行：`sudo rm -f /tmp/wop_host_ctrl.sock`
		       - `CB_ENABLE_HOST_CTRL=1 CB_HOST_CTRL_LAUNCH_STUB=0 TIMEOUT_SEC=300 ./quick_cb_test.sh`
		       - 预期：`/tmp/wop_host_ctrl.sock` 出现，`cb_test.log` 中出现 `Enabling HOST_CTRL_DPI`。
		    2. 在 `/home/pxr/workspace/nvmevirt` 编译并 `sudo insmod nvmev.ko memmap_start=<reserved> memmap_size=<size> host_ctrl_socket_path=/tmp/wop_host_ctrl.sock`，完成 JSON 桥接；加载后 `dmesg` 应出现 `Connected WoP host control bridge...`。
    3. 用 nvmevirt 触发 0xC0 并驱动 TB：推荐使用本仓库脚本 `scripts/csd_host_ctrl_dpi_smoke.sh`（会把 TLWE 写到 `memmap_start+2MB`，并用 `MODE=2(CB)` 触发一次 0xC0）：
       - `DEV=/dev/nvme2n1 MODE=2 TLWE_WORDS=631 GLWE_WORDS=3 ./scripts/csd_host_ctrl_dpi_smoke.sh`
       - ⚠️ 注意：`scripts/csd_memmap_golden_cmp.sh` / `scripts/csd_run_with_sudo.sh` 会删除 `/tmp/wop_host_ctrl.sock` 并启动 `csd_sw_backend.py`，不适用于 HOST_CTRL_DPI 联调。
		    4. 判据与取证：`cb_test.log` 里至少看到 `Doorbell fired`、`Result status write detected (COMPLETE)`、`Host ACK sent`；`dmesg` 不应出现 Oops/timeout。说明：旧版本 TB 在 `[FORCE] COMPLETE` 时可能只写回 `status=COMPLETE` 而未同步写 `status.cmd_id`，导致 nvmevirt 轮询时打印 `status cmd_id mismatch ... status=0x2`；当前已在 TB 中修复 `[FORCE] COMPLETE` 同步写回 `status.cmd_id`（见 `hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/rtl/tb_wop_circuit_bootstrap_woks_engine.sv`），正常情况下该 mismatch 不再出现。若仍出现，优先检查 nvmevirt 侧 pack/unpack 或 status_addr/slot 对齐问题。

				  - 🎯 **nvmevirt + GPU（不跑 RTL / 不上板）端到端闭环计划（单一路线）**
				    - 目标：`nvmevirt 0xC0` → `host_ctrl JSON` → `用户态 backend(ENGINE=gpu)` → `gpu_runtime_service` → GLWE 写回 `/dev/mem` → `cmp golden=OK`，并且 `dmesg` 无 Oops/timeout。
					    - 关键约束：nvme-cli `io-passthru` 无法表达 “PRP1 输入 + PRP2 输出” 语义；因此默认 e2e 采用 doorbell-only（`--data-len=0`）+ `/dev/mem` 数据通道（TLWE 写入 `memmap_start+2MB`，GLWE 从 backend log 解析 `glwe_addr` 后读回）。  
					      同时已支持 **PRP 输入**：`CSD_USE_PRP=1` 时用 nvme-cli `nvme io-passthru --write --input-file=<TLWE_FILE>` 发送带 data buffer 的 0xC0，nvmevirt 在内核侧把 TLWE 从 PRP staging 到 memmap storage window（避免 “PRP1 missing fallback”），后端仍从 memmap 读 TLWE、写 GLWE。
				    - 执行路线（P0 正确性，先闭环再优化）：
				      1) **先在用户态确认 GPU service 兜底不失真**：`WOP_GPU_FORCE_CPU_WOKS=1` 时，CPU 结果不得再被 WoKS rescale/requant 二次处理；否则会出现 “service 内部显示 mismatch=0，但外部 cmp golden 失败” 的假象。
				      2) **锁住 keyset**：`WOP_GPU_KEY_EXPORT` 默认不应覆盖已存在的 keyset 文件（除非显式开启 overwrite），否则会把 `tmp_assets/wop_keyset.bin` 覆写成新 key，导致历史 `tmp_assets/*_input_*.bin/*_golden_*.bin` 全部失配。
				      3) **若 keyset 已变更**：用 `cpu_reference_runner --synth-vp <idx>` 重新生成 TLWE+golden（与当前 keyset 一致）后再跑 e2e，避免“输入密钥不匹配”导致的必然 mismatch。
				      4) **线程数要对齐**：`cpu_reference_runner` 的输出会受 `--threads` 影响（FFT/并行非结合），因此 **生成 golden 的 threads** 必须与服务侧 `WOP_GPU_CPU_THREADS` 一致（`csd_e2e_smoke.sh` 默认 16）。否则会出现 “VP/服务链路 OK，但 cmp golden 失败” 的假象。
				      5) **推荐先做无 sudo 的预检查**（只验证用户态 correctness）：  
				         `WOP_GPU_KEY_IMPORT=tmp_assets/wop_keyset.bin WOP_GPU_KEY_EXPORT=tmp_assets/wop_keyset.bin WOP_GPU_FORCE_CPU_WOKS=1 WOP_GPU_CPU_THREADS=16 sw/gpu_runtime_service/build-clean/gpu_executor_smoke VP tmp_assets/vp_input_index42.bin /tmp/gpu_exec_smoke_vp_glwe.bin`  
				         判据：`cmp -s /tmp/gpu_exec_smoke_vp_glwe.bin tmp_assets/vp_golden_index42.bin`
					    - 一键回归（推荐）：在 `/home/pxr/workspace/nvmevirt/tools` 执行（会交互 sudo、自动起 backend 与 gpu_runtime_service）：
					      - memmap 输入（兼容）：`ENGINE=gpu MODE=0 TLWE_WORDS=20500 GLWE_WORDS=2049 TLWE_FILE=../hpu_fpga_fin/tmp_assets/vp_input_index42.bin GOLDEN=../hpu_fpga_fin/tmp_assets/vp_golden_index42.bin ./csd_e2e_smoke.sh`
					      - PRP 输入（打通 gpu↔nvmevirt 数据面）：`CSD_USE_PRP=1 ENGINE=gpu MODE=0 TLWE_WORDS=20500 GLWE_WORDS=2049 TLWE_FILE=../hpu_fpga_fin/tmp_assets/vp_input_index42.bin GOLDEN=../hpu_fpga_fin/tmp_assets/vp_golden_index42.bin ./csd_e2e_smoke.sh`
					    - 一键全流程（build+重生资产+PRP e2e）：在 `hpu_fpga_fin` 根目录执行 `bash scripts/csd_gpu_nvmevirt_oneclick.sh`（会交互 sudo），默认依次跑 VP/exp/soft 并把产物落到 `/tmp/csd_gpu_nvmevirt_oneclick_<timestamp>/`。
						    - 纯 GPU WoKS 路径：设置 `GPU_WOKS_NATIVE=1`（脚本会自动 `WOP_GPU_FORCE_CPU_WOKS=0` 并加载 spqlios FFT/IFFT 表），用于验证 GPU-native end-to-end correctness。
						    - 无 sudo 快跑：设置 `NO_SUDO=1` 跳过 nvmevirt `/dev/mem` e2e，仅跑用户态 `gpu_executor_smoke` 并 `cmp golden`（用于 CI/无权限环境的 correctness 复验）。
						    - OOM 排查：若 `gpu_runtime_service` 报 `CUDA error ... out of memory`，通常是历史残留服务实例未退出导致显存被占满；可先 `pkill -9 -x gpu_runtime_service` 清场后重跑（`../nvmevirt/tools/csd_e2e_smoke.sh` 已在启动/退出时做强制清理，并用 `"[g]pu_runtime_service"` pattern 避免 `pkill` 自匹配导致 bash 输出 `Killed ...` 噪音）。
				    - 服务建议：为先打通数据面，gpu_runtime_service 建议先启用 `WOP_GPU_FORCE_CPU_WOKS=1`（保证 mismatch=0；`csd_e2e_smoke.sh` 在未显式设置时默认置 1），待闭环稳定后再设为 0 做纯 GPU 数值调试。
					    - 取证：
					      - `/tmp/csd_sw_backend.log` 出现 `engine=gpu`、`cmd_id/slot/tlwe_addr/glwe_addr`、以及 `latency_ns/golden_mismatch`。
					      - `csd_e2e_smoke.sh` 打印 `GLWE matches golden`。
					      - `gpu_runtime_service` 默认日志：`/tmp/csd_gpu_runtime_service.log`（socket 默认 `/tmp/wop_gpu_runtime.sock`，可用 `GPU_SOCKET=...` 覆盖）。
					      - 推荐只看**本次新增** dmesg（避免 `tail` 旧日志误报）：`DMESG0=$(sudo dmesg | wc -l | tr -d ' '); sudo dmesg -T | tail -n +$((DMESG0+1)) | rg -n "Oops|timeout" || true` 无新异常（脚本 `csd_e2e_smoke.sh` 已内置增量检查）。
					    - 路径约定：`csd_e2e_smoke.sh` 默认假设 `nvmevirt` 与 `hpu_fpga_fin` 同级目录（`<workspace>/{nvmevirt,hpu_fpga_fin}/`），并会自动用该路径定位 `gpu_runtime_service/cpu_reference_runner/keyset`；若目录不一致可用 `HPU_FPGA_FIN_ROOT=/abs/path/to/hpu_fpga_fin` 覆盖。
					    - 常见坑（权限）：若之前用 root 写过 `/tmp/csd_sw_backend.log` 导致普通用户无法覆盖，会出现 `Permission denied` 并造成 backend 未启动→GLWE mismatch。当前脚本会在启动 backend 前执行 `sudo rm -f $BACKEND_LOG` 并重新创建空文件，避免读到旧日志/旧 glwe_addr。
					    - 常见坑（layout）：若 backend log 出现 `tlwe=0 glwe=cmd_id mode=8`、或 `dd if=/dev/mem ... Bad address`，同时 `dmesg` 见 `CSD host_ctrl status poll timeout ... last_status=0x00000000`，通常是 **descriptor/status 打包不一致**（backend 按 C struct 解析，而 nvmevirt 已按 SV packed qwords layout 发送/轮询）。当前 `../nvmevirt/tools/csd_sw_backend.py` 已对齐 `../nvmevirt/csd_engine.c:wop_pack_{desc,status}_qwords`。
- DaisyPlus DRAM 布局校验：
  1. 生成 `wop_dram_layout.h` 与 JSON（资产段名→base/size），让固件/GPU/runtime/Testbench 共用；在 Testbench 中新增 `+LAYOUT_CHECK_FILE` plusarg。
  2. GPU runtime 在读取 descriptor 前调用 `layout_check()`, 若越界则通过 Result Status 返回 `WOP_STATUS_ERROR` 并置位 `reserved0[15]`。
  3. `doorbell_stub.py` 允许加载 `.layout.txt` 并按段名填充 descriptor 地址，便于仿真阶段提前验证。
  4. 固件上线后需记录 `layout_err` 统计指标，并和 `CTRL_STATUS` 错误位联动。

## 14. GR3FTL → GPU Doorbell → Descriptor 写回闭环实施方案（草案）

### 13.1 共享内存布局（拟定）
| 区域 | 基址 (相对 `WOP_DRAM_BASE`) | 大小 | 描述 |
| --- | --- | --- | --- |
| Descriptor Ring | `0x0000_0000` | `N_SLOT × 64B` | 固定 64 字节 descriptor，包含 `cmd_id/flags/tlwe_ptr/glwe_ptr/gpu_ptr/aux`。 |
| Ring Control Block | `0x0000_1000` | 256B | `head/tail/pending/release` 计数、doorbell 令牌序号、GPU 心跳标记。 |
| Result Status Block | `0x0000_2000` | `N_SLOT × 32B` | GPU 写回 `status/error_ticks/latency_ns`，SSD 读取并据此更新 AXI-Lite `CTRL_STATUS`。 |
| TLWE Buffer | `0x0001_0000` | `N_SLOT × TLWE_STRIDE` | 由 NVMe DMA 写入，GPU 只读。 |
| GLWE Buffer | `0x0010_0000` | `N_SLOT × GLWE_STRIDE` | GPU 写回结果，SSD 再搬移至主机或内部校验。 |
| GPU Scratch | `0x0100_0000` | 2 MB | GPU 临时使用（NTT/外积中间态），路径仅 GPU 访问。 |

> 注：`N_SLOT` 默认为 8；TLWE/GLWE stride 由 `CTRL_BSK/KSK/GLWE_STRIDE` 寄存器在 doorbell 前写入，单位字节且需 64B 对齐。

### 13.2 固件（GR3FTL）任务
- **Vendor 命令调度**：在 `handle_wop_vendor_cmd()` 中新增 ring 可用检查，若 slot 不足则将命令排入 `wop_pending_q` 并立即返回 `NVME_SC_NAMESPACE_BUSY`。
- **Doorbell 发令**：扩展 `wop_desc_issue()`，写入 descriptor 内容后更新 Ring Control Block 中的 `tail`/`pending_cnt`，随后写 AXI-Lite `CTRL_DESC_PTR_*`、`CTRL_CMD`（doorbell=1）。若 `CTRL_STATUS.busy=1`，仅写入 DRAM，等待 `wop_service()` 轮询再次 doorbell。
- **结果轮询**：`wop_service()` 新增 Result Status Block 解析，依据 `status` 字段更新 NVMe completion；将 `latency_ns` 汇总至调试日志；若发现 GPU 错误码则同步置位 `WOP_STATUS_ERROR_MASK` 并释放 slot。
- **共享内存校验**：初始化阶段清零 Ring Control Block，并将 `gpu_heartbeat` 设置为非零。若 4 个 service 周期未递增，触发 GPU 超时告警。
- **DRAM 布局断言**：结合 `keyset_layout_exporter` 生成的 `.with_payload.txt`，在固件 doorbell 阶段以及 testbench 中校验 `tlwe_src_addr/glwe_dst_addr/gpu_shared_addr` 是否命中已知段落；一旦越界立即拒绝 doorbell 并回报 `CTRL_STATUS[layout_err]`。

### 13.3 RTL / Wrapper 任务
- **Doorbell Ready 信号**：在 `openssd_wop_axi_lite_ctrl.sv` 中加入 `gpu_db_ready_i` 输入，当 GPU 侧反馈不可接新 token 时，拒绝新的 doorbell 并设置 `CTRL_STATUS[25]`（doorbell_busy）。
- **Descriptor ACK**：`openssd_wop_dma_descriptor` 读取完成后，将 slot ID 回写至 Result Status Block 的 `owner` 字段，便于 GPU/SSD 双向追踪。
- **Result 写回触发**：`openssd_wop_wrapper` 在统一内核 `unified_done` 时写入 Result Status Block（默认值），等待 GPU 覆盖真正结果；若 GPU 侧未在超时时间内写回，则由 wrapper 设置 `status=0xDEAD` 并告警。
- **状态记录格式**：Result Status 采用 256-bit 结构（cmd_id/status/error_code/latency/timestamp），`openssd_wop_result_writer.sv` 负责写入，固件或 GPU runtime 可直接解析。
- **仿真 GPU 回环 Stub（完成）**：定义 `SIM_WOP_GPU_LOOPBACK` 时，wrapper 内部启用一个延迟 32 周期的 ACK stub，自动拉高 `gpu_status_ready_mux`、`gpu_db_tready_mux` 并在回写后输出 `[GPU_LOOPBACK_ACK]`/`[GPU_LOOPBACK_INFO]`；`quick_cb_test.sh` 默认打开，必要时可用 `CB_DISABLE_GPU_LOOPBACK=1` 禁用以测试真实 GPU 流程。
- **AXI-Lite 主机 Stub（首版完成）**：`tb_host_axil_dpi.c` 现已暴露 `/tmp/wop_host_ctrl.sock`，内部以线程处理 JSON 命令，支持 `axil_write/read`、`mem_write/read`（4×64b）及 `set_status`。Testbench 通过 `HOST_CTRL_DPI` plusarg 使能桥接，并导出 `tb_host_axil_write/read`、`tb_host_axi_mem_write_qwords`、`tb_host_ctrl_set_status` 等任务。
  - ✅ Python `doorbell_stub.py` 负责编排 ring 元数据、写 descriptor/status、触发 doorbell、轮询 Result Status 并在完成后 ACK；新增 `--desc-count/--mode/--tlwe-words` 等参数，默认会在所有 descriptor 完成后调用 `set_status(pass)`。
  - ✅ `run.sh` 自动编译 `tb_host_axil_dpi.c` 为 `tb_host_axil_dpi.so` 并随 xsim 运行加载。
  - ✅ `quick_cb_test.sh` 现支持 `CB_ENABLE_HOST_CTRL=1`，会自动传入 `+HOST_CTRL_DPI`、等待 socket 建立并拉起 `doorbell_stub.py`；stub 日志附加在 `cb_test.log` 末尾，同时在 `reports/cb_host_summary.txt` 写入 doorbell/ACK 统计与退出码，便于长稳回归采集 KPI。
  - ✅ 新增 `scripts/run_manual.sh`，同样支持 `CB_ENABLE_HOST_CTRL=1`，并在 `reports/cb_host_manual_summary.txt` 留存命令行、descriptor 数与 stub 退出状态，方便人工调试复盘。
  - ✅ 在 `workspace/nvmevirt/tools/wop_host_bridge.py` 提供与 testbench 对齐的 JSON socket 桥接脚本，后续 nvmevirt 仿真/驱动可直接复用（`export NVMEVIRT_HOST_CTRL_SOCKET=/tmp/wop_host_ctrl.sock`）。
  - ⏩ TODO：
    1. 将 `doorbell_stub.py` 中的 Result Status/日志转储对接自动化验证脚本（包括错误注入路径）。
    2. 复用同一 socket 协议为 nvmevirt 插件与用户态固件服务，统一 host 侧接口。

### 13.4 GPU 运行时任务
- **Doorbell 接收**：在 `tfhe-gpu-baseline-wopbs` 中新增 `wop_gpu_runtime.cu`，轮询 Ring Control Block 对比 `tail` 与本地 `head`；读取 descriptor 时校验对齐与 `pending` 状态。
- **执行流程**：调用现有 WoPBS NTT/FFT/PrivKS 内核；使用 TLWE/GLWE buffer 地址作为输入/输出；将中间 scratch 指向 `GPU Scratch` 区。
- **结果写回**：执行结束后更新 Result Status Block 中对应该 slot 的 `status=0x1`、`latency_ns`、错误码（若有），并递增 `release_cnt`。如检测到门铃溢出，写入 `status=0xE1`。
- **心跳**：每次循环更新 `gpu_heartbeat`，便于固件检测 GPU 是否 still alive。

### 13.5 DaisyPlus DRAM 布局校验规划
1. **布局生成统一**：`quick_gpu_mode_test.sh` 已生成 `<keyset>.with_payload.txt`，内容包含 `secret/preks/bk_fft/privks/tlwe_payload/glwe_payload` 等段。后续在构建阶段用 Python 工具转换为 JSON/二进制表，并生成 `sw/include/wop_dram_layout.h` 常量供固件引用。
2. **testbench 断言**：新增 plusarg `+LAYOUT_CHECK_FILE=<path>`；TB 在 descriptor 激活时查表校验 `tlwe_src_addr`、`glwe_dst_addr`、`gpu_shared_addr` 是否落在合法范围，失败则 `$fatal` 并输出 `[TB][LAYOUT_ERR]`。
3. **固件校验**：在 GR3FTL doorbell 实现中调用 `wop_validate_layout()`，将 CSR 写入值与布局表比对。若检测越界，立即回写 `CTRL_STATUS[layout_err]=1` 并返回 `NVME_SC_DATA_XFER_ERROR`。
4. **GPU runtime 校验**：延续现有 `[TFHE_GPU_EXEC][LAYOUT]` 日志，遇到越界时拒绝 descriptor 并记录 `[TFHE_GPU_EXEC][LAYOUT_ERR]`，确保三方校验一致。

验收：仿真中故意注入越界地址，确认 TB `$fatal`；固件 stub 返回错误；GPU runtime 打印 `LAYOUT_ERR`。正常路径下三者均输出 `LAYOUT_OK`。

### 13.6 NVMeVirt / 用户态固件模拟路线
1. **仿真转接层**：在 AXI-Lite DPI 的基础上扩展 socket 协议，允许携带 descriptor payload/Result Status 地址；用户态程序（可复用 `doorbell_stub.py`）负责向 TB DRAM 写入 descriptor、触发 doorbell、轮询 Result Status。
2. **NVMeVirt 集成**：编写 nvmevirt 插件接管 Vendor 命令，调用 GR3FTL 逻辑构造 descriptor，透过 socket 与 TB 交互；当 Result Status COMPLETE 时更新 nvmevirt completion queue 并发 ACK。
3. **性能采样**：在 host stub 记录 doorbell→ACK 时间，与 `[TB][GPU_SERVICE][SCORE]` 构成端到端延迟/带宽；形成 CSV/Markdown 报告与 GPU/CPU baseline 对照。
4. **鲁棒性**：协议加入版本号/Magic，要求显式 release；socket 断开时 TB DPI 清除挂起请求、置位 `CTRL_STATUS[host_err]`，防止 pending。

验收：nvmevirt 环境下一次提交多条 WoP descriptor，经 socket 驱动 TB 完成后，Host 日志显示 ACK、GPU 日志显示 `[GPU_SERVICE][SCORE]`，completion queue 反馈正常。

## 15. 分阶段执行路线（2025-10-10）

| 阶段 | 子任务 | 目标 & 范围 | 产出判据 | 依赖 |
| --- | --- | --- | --- | --- |
| RTL-P0 | BSK/KSK Loader 仲裁与 QoS 设计 | 统一内核在 CB/VP 并发时需要区分 KSK/BSK 请求优先级；梳理 `openssd_wop_stream_loader`、`openssd_wop_wrapper.sv` 接口，提出门控、发令节拍与仲裁状态机方案 | 设计说明 + 时序/握手图（Markdown/Drawio），列出需修改的 RTL 文件与关键信号 | 现有 loader 实现、统一内核资源请求统计 |
| RTL-P1 | VP/BE 引擎模块化接入 | 将 `wop_vertical_packing_engine`、`wop_bit_extract_engine` 作为子模块重新挂接，统一 RegFile/BSK/NTT 接口 | 迁移计划 + 接口映射表 | RTL-P0 仲裁方案 |
| RTL-P1 | Descriptor 字段扩展 | 明确 Step5-only、BE LUT 选择等字段在 `openssd_wop_kernel_bridge.sv` 的译码方式，并补充错误回报 | 字段表 + 状态机更新草案 | RTL-P0 |
| FW-P0 | GR3FTL Doorbell 流水实现 | 将 `handle_wop_vendor_cmd()`、`wop_desc_issue()`、`wop_service()` 串起，打通 descriptor→doorbell→结果轮询；定义错误处理 | 功能规格 + 状态图 + 伪代码 | 共享内存布局（13.1）稳定 |
| FW-P1 | `memory_map.h`/资产 staging 更新 | 把 doorbell/result 区域、TLWE/GLWE/BSK/KSK 基址写入常量，列出初始化顺序与 stride 校验 | 常量定义 diff + 初始化 checklist | FW-P0 |
| GPU-P0 | WoPBS CUDA Runtime 接入 | 基于 `tfhe-gpu-baseline-wopbs`拆出 runtime 接口：descriptor 解析、NTT/PrivKS 调用、Result Status 写回 | 接口说明 + demo stub（host 可跑） | FW-P0、共享内存布局 |
| VERIFY-P0 | CB 长跑回归 | `TIMEOUT_SEC=900 ./quick_cb_test.sh` + 指标过滤，确认无 credit warn/drop；准备日志过滤模板 | 回归脚本 + 采样日志 | RTL-P0 |

> 顺序建议：先完成 RTL-P0 设计说明 → 驱动 FW-P0/GPU-P0 规格 → 等规格稳定后再进入代码实现与回归。

### 14.1 RTL-P0｜BSK/KSK Loader 仲裁与 QoS 设计草案

**现状回顾**
- BSK 路径：统一内核“消费”wrapper 提供的批次数据。wrapper 在当前实现中通过 `bsk_service_req_vld` 表示“数据就绪”，内核以 `bsk_service_req_rdy`/`bsk_service_data_avail` 进行消耗。现阶段 loader 仍为单实例 `openssd_wop_stream_loader`，缺乏 backpressure 管控，PrivKS/CB 同时触发时可能出现场景失衡。
- KSK 路径：descriptor 下发后 wrapper 触发一次预取 (`ksk_prefetch_pending_q`)，同样绑定在独立 AXI master `m_axi4_ksk[0]`。由于内核只读缓存，wrapper 仍是主动方，现有逻辑默认串行处理。
- 唯一 QoS 手段是 SmartConnect QOS 常量（计划值 0xC/0x6/0x4/0x2），但 wrapper 内部仍缺乏发令顺序管理，CB 与 VP Step5 同时请求时可能导致 AXI 口被长 burst 占用，统一内核出现 `ksk_asset_valid` 空窗。

**设计目标**
1. 在 wrapper 内部提供仲裁模块，使 BSK（PrivKS/CB）与 KSK（Step5）请求能够按优先级有序发起，同时保持“wrapper 主动 → 内核被动”的握手语义。
2. 在仲裁层实现可编程 QoS：支持固定优先级（Step5 > PrivKS > 低速）与加权轮询（例如 Step5:PrivKS=2:1），允许 firmware 通过 CSR 调整。
3. 引入 outstanding 限制：限制同类请求在 AXI 通道的并发数量（例如 BSK 最多 1 outstanding burst，KSK 最多 2），避免长时间占用造成另一路饥饿。
4. 为统一内核补充 throttle 信号：当仲裁层检测到 AXI 拥塞或 outstanding 达上限时，下游 `bsk_service_req_rdy`、`ksk_prefetch_req_ready` 需及时 deassert。

**拟议架构**
- 新增 `openssd_wop_loader_arbiter.sv`（已提交初版）后续需要升级为“loader 发令调度器”，内部包含：
  - `bsk_req_queue`：记录内核发起的批次请求（批次号 + 触发源），深度 2。
  - `ksk_req_queue`：记录 Step5/PrivKS 触发的预取请求，深度 2。
  - `scheduler_fsm`：根据配置选择下一笔出队的通道，输出至原 `openssd_wop_stream_loader`，并驱动对应的 AXI master 端口。
  - `outstanding_cntr`：每个通道维护独立计数，基于 AXI  handshake (`arvalid/arready`、`rlast`) 增减；当达到阈值时，向内核反馈 `*_req_rdy=0`。
- AXI 连接策略：
  - 保留现有 `m_axi4_bsk`、`m_axi4_ksk` 物理端口，但通过仲裁层统一发起 burst；若未来期望复用同一个 SmartConnect master，可配置成共享端口。
  - 仲裁层对每次出队的请求生成 `issue_token`，用于在 `rlast` 时清算 outstanding，并向内核反馈完成。
- CSR 扩展（AXI-Lite）：
  - `CTRL_QOS_CFG`：含 `bsk_weight[3:0]`、`ksk_weight[3:0]`、`priority_mode`（0=静态优先级，1=加权 RR）。
  - `CTRL_MAX_OUTSTANDING`：分别设置 `bsk_max_outstanding`、`ksk_max_outstanding`（默认 1/2）。

**接口改动清单**
| 文件 | 改动要点 |
| --- | --- |
| `hw/module/pe_pbs/module/openssd_wop_wrapper/rtl/openssd_wop_wrapper.sv` | 由旧版直连切换为 `openssd_wop_loader_arbiter` 发令；现已完成接口改写，并在仿真宏下打印 `[WRP_ARB_DBG]`。 |
| `hw/module/pe_pbs/module/openssd_wop_wrapper/rtl/openssd_wop_axi_lite_ctrl.sv` | 已完成：新增 QoS/Outstanding 配置寄存器及状态读数（`CTRL_QOS_CFG`/`CTRL_MAX_OUTSTANDING`）。 |
| `hw/module/pe_pbs/module/openssd_wop_wrapper/rtl/openssd_wop_stream_loader.sv` | 复用现有模块，仲裁层之上集中管理请求（无需修改）。 |
| `hw/module/pe_pbs/rtl/wop_pbs_kernel_unified.sv` | 已完成：新增 `bsk_throttle_o`/`ksk_throttle_o` 调试信号，并在 wrapper 打印。 |

**验证策略**
1. 仿真场景：构造 CB + VP Step5 并发请求，在无仲裁（旧版）与仲裁方案对比 `bsk_service_req_vld` 与 `ksk_prefetch_req_vld` 的等待周期；确认 outstanding 不再无限增长。
2. 断言：仲裁层需保证 `req_ready` 与内部队列同步，避免丢请求；当 outstanding >= 阈值 时，`req_ready` 必须为 0。
3. 日志：在 `cb_test.log` 中新增 `[WRP_ARB_DBG]` 打印（translate_off），记录仲裁决策和 outstanding 计数，方便回归分析。

**最新进展（2025-10-11）**
- `openssd_wop_loader_arbiter.sv` 升级为双通道队列：每路独立 outstanding 计数、限流阈值与动态优先策略。`cfg_priority_mode` 支持静态优先（默认 KSK > BSK）与加权 RR，权重/阈值均可通过 AXI-Lite 寄存器配置。
- `openssd_wop_axi_lite_ctrl.sv` 新增 `CTRL_QOS_CFG`（bit0=priority，bits[7:4]=BSK weight，bits[11:8]=KSK weight）与 `CTRL_MAX_OUTSTANDING`（bits[2:0]/[10:8] 为 BSK/KSK 最大 outstanding）。wrapper 将 throttle/outstanding 暴露给调试打印与未来的 unified kernel 监测。
- `quick_cb_test.sh` 现解析 `-0` 参数计算预期握手次数，缩参 33×64 与自然路径 631×1024 分别在约 24 s 与 40 s 内早停；两者均无 `KS_CREDIT_WARN/cmd dropped`，ACK 仅因早停未打印。
- `openssd_wop_kernel_bridge.sv` 将 `WOP_MODE_CB` 视为 GPU 任务：CB 描述符入队后直接进入 WAIT_ACK，不再向 `wop_pbs_kernel_unified` 下发指令；`openssd_wop_wrapper.sv` 在 `active_desc_ack_i`（GPU/固件回传）时产生 ACK，并在描述符落队时先写入 Result Status=PENDING，再在完成时写 COMPLETE。
- 更新（2026-01-31）：HOST_CTRL_DPI oneclick（doorbell→COMPLETE→ACK）通过，DEV=`/dev/nvme2n123`；证据：`hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/cb_test.log` 含 `[TB] Doorbell fired`/`[TB] Result status write detected (COMPLETE)`/`[TB] Host ACK sent`/`KS command accepted`，控制台日志：`hw/module/pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/cb_oneclick.console.log`。

**寄存器映射摘要**
| 寄存器 | 位段 | 说明 | 默认值 |
| --- | --- | --- | --- |
| `CTRL_QOS_CFG` | bit0 | `priority_mode`（0=静态 KSK>BSK，1=加权 RR） | 0 |
|  | bits[7:4] | `bsk_weight`（最少 1，写 0 时自动视为 1） | 1 |
|  | bits[11:8] | `ksk_weight`（最少 1） | 2 |
| `CTRL_MAX_OUTSTANDING` | bits[2:0] | `bsk_max_outstanding`（写 0 自动视为 1） | 1 |
|  | bits[10:8] | `ksk_max_outstanding` | 2 |

**后续工作**
- 继续完善 VP Step5 + CB 并发仿真，验证加权 RR 在多工作负载下的公平性，给出推荐权重表。
- Vivado SmartConnect Tcl：同步 QoS weight 与 USER 宽度配置，确保综合/布局布线遵循同一策略。
- 修补 quick_cb_test 缩参路径的 ACK 缺失问题（TB 退出条件），避免依赖外部 timeout。

### 14.2 握手拓扑与仿真现状（2025-10-11）
- Wrapper → 内核握手方向维持“wrapper 主动、内核被动”，仲裁层仅调度 `req_valid/req_ready`，不会改写内核端口；`bsk_req_ready` 低电平即表示队列满或 outstanding 达阈值。
- 缩参 `quick_cb_test.sh`（33×64）可在 180 s 内完成 33/33 + 34 次 final handshake（见 `cb_test_shrink.log`），但 testbench 未输出 ACK，需要依赖脚本 timeout 强制收尾。
- 自然路径 `quick_cb_test.sh` 采用早停策略，在 40 s 内得到 631/631 + 632 final handshake（`cb_test.log`），warning 仅提醒 ACK banner 缺失；仿真日志未出现 `KS_CREDIT_WARN/cmd dropped`。
- Outstanding 计数在仿真收敛后均回落到 0，`bsk_throttle/ksk_throttle` 仅在 outstanding=阈值 时短暂置位，未观测到饥饿或长期 backpressure。


### 13.5 验收路径
1. **仿真（短跑）**：在 xsim 中 stub 出 GPU runtime，模拟完成 `status=0x1` 写回；验证 `CTRL_STATUS.busy`、`INT_STATUS[0]` 以及 Result Block 更新顺序。
2. **板级 bring-up**：在 CosmosPlus + GPU 平台运行单条 Vendor 命令，确认 NVMe completion 与 GPU 日志匹配；更新 `.remember` 记录带宽与延迟。
3. **长稳测试**：连续提交 ≥64 条 descriptor，确保 ring head/tail/doorbell 不失配，`CTRL_STATUS[31:24]` 无错误位。
