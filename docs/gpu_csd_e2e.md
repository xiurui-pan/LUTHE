# GPU‑CSD nvmevirt e2e（文档总入口）

> Last update: 2026-02-06  
> 目的：把当前“nvmevirt+CSD 控制面 + Host 后端 + GPU runtime service 数据面”的 e2e 闭环，和目标的“细粒度算子分工”放到同一页里，便于验收与后续拆分。

## 1. 参考文档（分工与路线）
- 目标算子放置（StoryLine）：`docs/storyline.md`
- 算子边界合同（M2 草案）：`docs/gpu_csd_operator_contract.md`
- 详细算子拆分/接口映射：`docs/wop_pbs_function_eval_plan.md`
- OpenSSD 集成分工（历史规划）：`docs/wop_pbs_openssd_integration_plan.md`
- 取证审阅报告（2026-02-02）：`docs/gpu_csd_e2e_audit_20260202.md`

## 2. 一句话现状
当前还不是 `docs/storyline.md` 那种“细粒度分工”（CSD 做低开销、GPU 只做 BR/FFT）。  
现在更像：**CSD/nvmevirt 负责控制与搬运，GPU runtime service 负责把整段算子一次算完**。

## 3. 当前 e2e 架构（nvmevirt + GPU）

### 3.1 控制面 vs 数据面
- 控制面（nvmevirt 内核）：Vendor opcode `0xC0` → 解析参数 → doorbell/status 桥接 → 触发后端处理。
- 数据面（Host 后端 + GPU service）：
  - 读输入（PRP 或 memmap staging）
  - 执行 TFHE pipeline（CPU runner 或 GPU runtime service）
  - 写回输出（GLWE / fp64 输出）到 memmap，然后由 e2e 脚本读回做比对。

### 3.2 参与组件与职责
- **CSD/nvmevirt（内核侧）**：不执行 TFHE 算子；只负责 0xC0、PRP→memmap staging、doorbell/status、延迟模型。  
  入口脚本：`../nvmevirt/tools/csd_e2e_smoke.sh`
- **Host 软件后端（python）**：解析 descriptor/status，选择引擎执行，并把结果写回物理地址（通常通过 `/dev/mem`）。  
  入口：`../nvmevirt/tools/csd_sw_backend.py`
- **GPU runtime service**：真正的算子执行点；按 IPC 的 `mode` 跑 VP/BE/CB/FunctionEval（softmax）。  
  IPC：`sw/gpu_runtime_service/include/gpu_runtime/ipc.hpp`

## 4. IPC / mode 语义（与 e2e 的关系）
- `mode=0`：VerticalPacking（vp/exp/soft 三案使用同一 mode，靠 flags 区分 LUT/配置）
- `mode=1`：BitExtract
- `mode=2`：CircuitBootstrap
- `mode=3`：FunctionEval（本阶段实现：TFHE softmax）

### 4.1 FunctionEval(mode=3) 的 payload 合同（当前实现）
- 输入 payload：按 fp64 数组解释（`word_bytes=8`，`tlwe_words=N`）
- 输出 payload：fp64 数组（`glwe_words>=tlwe_words`，默认输出 N 个 double）
- 约束与实现点：`sw/gpu_runtime_service/src/tfhe_gpu_executor.cpp` 的 `process_function_eval()`

## 5. 验收与一键脚本（最短路径）

### 5.0 全量回归（推荐入口）
- 脚本：`scripts/csd_gpu_nvmevirt_regression_oneclick.sh`
- 推荐验收（完整 nvmevirt e2e）：`GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh`
- 判据：末尾打印 `[PASS] nvmevirt regression OK`
- 附带：`NO_SUDO=0` 时会额外打印 `[summary] ... metrics cmd=...`（从各用例 `backend.log` 提取的 bytes/latency 摘要），并写入 `OUT_DIR/metrics_summary.txt` 便于长期对比。
- 日志排版：默认控制台输出会做“去噪 + 对齐”（保留 `[x/y]`、`[PASS]/[FAIL]`、`metrics`、错误关键词等）；每步完整原始输出在 `OUT_DIR/<step>/run.log`，需要全量滚屏可设 `CSD_REGRESSION_VERBOSE=1`。
- OpenSSD/FTL（真·走 nvmevirt 自带 FTL/模拟 NAND 存储密钥）：设 `CSD_KEYSET_IN_FLASH=1` 可把 `KEYSET` 文件写入 nvmevirt namespace 的 LBA 空间（靠近盘尾，默认留 `CSD_KEYSET_FLASH_MARGIN_MB=64` 保护带），并用 loopdev 把那段 LBA 暴露成“文件”供后端/GPU service 读取（更接近“密钥在 flash、固件按需加载”的模型）。
  - 可选：固定落盘位置 `CSD_KEYSET_FLASH_SLBA=<slba>`（512B 扇区）
  - 取证：`../nvmevirt/tools/csd_e2e_smoke.sh` 会打印 `[1.5/6] Provision keyset into nvmevirt flash + loopdev` 与 `cfg keyset(loopdev) /dev/loop*`
  - 回归脚本行为：
    - 当开启该模式时，`scripts/csd_gpu_nvmevirt_regression_oneclick.sh` 会在首案后自动 `SKIP_RELOAD=1`，避免每个子用例都重刷多 GB keyset。
    - 默认会启用 `CSD_KEEP_SESSION=1`（可手动设 `CSD_KEEP_SESSION=0` 关闭），让 nvmevirt e2e 尽量复用同一个 `keyset(loopdev)` 与 `gpu_runtime_service`，避免每个子用例都重新导入多 GB keyset（降低 20s+ 级别抖动与系统 ABRT 风险）。
    - 默认会启用 `CSD_KEEP_BACKEND=1`（可手动设 `CSD_KEEP_BACKEND=0` 关闭），让 nvmevirt e2e 复用同一个 `csd_sw_backend.py`（key mmap/caches 常驻），减少反复 python 启动与重复 mmap 抖动；取证为 `e2e.log` 中出现 `[SESSION] reuse csd_sw_backend`（回归汇总 `flash_*` 行会额外打印 `reuse_backend=1`）。
  - 新增会话开关：`CSD_KEEP_SESSION=1`
    - 行为：`../nvmevirt/tools/csd_e2e_smoke.sh` 会复用 session 内的 `keyset(loopdev)`，并在 `ENGINE=gpu` 时复用已有 `gpu_runtime_service`（同一 `GPU_SOCKET`）。
  - 新增后端常驻开关：`CSD_KEEP_BACKEND=1`
    - 行为：`../nvmevirt/tools/csd_e2e_smoke.sh` 在 `CSD_KEEP_SESSION=1` 时可复用同一 `csd_sw_backend.py`（`/tmp/wop_host_ctrl.sock`），复用 key mmap/caches。
    - 注意：softmax KSPBS split（`WOP_GPU_KSPBS_SPLIT=1`，可选 `WOP_GPU_KSPBS_SPLIT_ALL_STAGES=1`）需要不同的 `gpu_runtime_service` 启动环境；回归脚本会把该步骤放到最后，并在该步前自动清理 session 再重启一次 service。
- OpenSSD/FTL（可选：把 TLWE/GLWE 也放到 flash）：设 `CSD_TLWE_IN_FLASH=1` 可将本次 TLWE 输入先写入 nvmevirt namespace 的 LBA 空间，再从 flash 读入 memmap storage window（模拟“固件从 flash DMA 到 DRAM staging”）；设 `CSD_GLWE_OUT_FLASH=1` 可将 GLWE 输出写回 flash 并做读回校验。
  - 约束：`CSD_TLWE_IN_FLASH=1` 需要同时 `CSD_USE_PRP=0`（该路径使用 `/dev/mem` staging 作为 DRAM window，PRP staging 会绕过这一步；一键脚本在未显式设置 `CSD_USE_PRP` 时会自动切到 `0`）
  - 取证：`../nvmevirt/tools/csd_e2e_smoke.sh` 会打印 `[DATA_FLASH] ... tlwe ...` / `[DATA_FLASH] ... glwe ...`（含 `slba/sectors/bytes` 与 flash 读回校验）
- OpenSSD/FTL 软件移植（无硬件）：设 `CSD_FTL_EMU=1` 可让 nvmevirt backend 模拟 OpenSSD 风格的 FTL staging 与 ring(doorbell/ACK) 行为；证据在各步 `backend.log` 的 `[DESC_RING]`/`[FTL_EMU][SUMMARY]`，并会被回归汇总到 `OUT_DIR/metrics_summary.txt`。可选开启延时注入：`CSD_FTL_DELAY=1 CSD_FTL_DELAY_SCALE=<float>`（把 staging latency 转成 `sleep`，用于做时序敏感的回归/校准）。
- 备注：`NO_SUDO=1` 为用户态 smoke（不走 nvmevirt），用于无 sudo 的快速 sanity（目录结构与 e2e 一致，便于对照）。
- M9 备注：回归脚本会把 M9 的 KSPBS split 固定收口为 `softmax_kspbs_split_n4/`（`N=4`，默认 `WOP_GPU_KSPBS_SPLIT_ALL_STAGES=1`）；并对 `softmax/`（默认 `N=16`）默认自动 unset `WOP_GPU_KSPBS_SPLIT*`，避免 staged DIV(op=6) 因超时导致回归失败。若要让 `softmax/` 也继承 split 环境，可设 `CSD_REGRESSION_SOFTMAX_KEEP_SPLIT=1`。
- keyset 一致性：当 `CSD_KEEP_SESSION=1`（尤其 `CSD_KEYSET_IN_FLASH=1`）时，回归会**固定一份 keyset** 并透传给每个子用例，避免某一步用“不同 keyset”生成 golden 导致假 mismatch（典型是 BE/KSPBS 用到 `preKS_gpbs`）。如需指定 keyset：`KEYSET=<path> ... bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh`。
- 产物：每个子用例目录都会落盘关键日志（便于取证/复盘）
  - `vp_exp_soft/`：`vp_backend.log`/`exp_backend.log`/`soft_backend.log` + 对应 `*_gpu_runtime_service.log`、`*_dmesg_new.log`
  - `be_split/`：`backend.log`、`gpu_runtime_service.log`、`dmesg_new.log`，以及 `e2e.log`（`mode=1 + flags=0x08(backend_split)`）
  - `softmax/`：`backend.log`、`gpu_runtime_service.log`、`dmesg_new.log`，以及 `e2e.log`
  - `softmax_kspbs_split_n4/`：同 `softmax/`，但固定 `N=4` 并开启 `WOP_GPU_KSPBS_SPLIT` + `WOP_GPU_KSPBS_SPLIT_ALL_STAGES=1`（默认 lut1/2/7/10/11），用于验证 split 接口/证据链（`gpu_runtime_service.log` 含 `[KSPBS_SPLIT]`，且 stage 不再只为 1）。
  - `cb_step4only/`、`cb_step4only_premod/`：`backend.log`、`gpu_runtime_service.log`、`dmesg_new.log`
  - `kspbs_split/`：`backend.log`、`gpu_runtime_service.log`、`dmesg_new.log`（含 `[KSPBS_SPLIT]` 与分段 `metrics`）
  - `kspbs_split_per_sample/`：`backend.log`、`gpu_runtime_service.log`、`dmesg_new.log`（含 `[KSPBS_SPLIT] per_sample=1`、`batch/groups` 与分段 `metrics`）

#### 5.0.1 本次验收记录（取证）
- 2025-12-29：`GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20251229_175657/`（末尾 `[PASS] nvmevirt regression OK`）。
- 2025-12-30：`NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh` 通过（已包含 `kspbs_split_per_sample`），产物目录：`/tmp/csd_gpu_nvmevirt_regression_20251230_140237/`。
- 2026-01-01：`NO_SUDO=1 WOP_GPU_KSPBS_SPLIT=1 WOP_GPU_KSPBS_SPLIT_LUTS=10,11 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260101_180729/`（末尾 `[PASS] nvmevirt regression OK`）。
- 2026-01-01：`GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260101_185217/`（末尾 `[PASS] nvmevirt regression OK`，且 `softmax fail=0`，`metrics_summary.txt` 落盘）。
- 2026-01-02：`GPU_WOKS_NATIVE=1 NO_SUDO=0 WOP_GPU_KSPBS_SPLIT=1 WOP_GPU_KSPBS_SPLIT_LUTS=1,2,7,10,11 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260102_094059/`（末尾 `[PASS] nvmevirt regression OK`，且 `softmax fail=0`；`softmax_div_split_n4/gpu_runtime_service.log` 含 `[KSPBS_SPLIT] stage=1 lut1/2/7/10/11`）。
- 2026-01-02：`CSD_FTL_EMU=1 GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260102_142536/`（末尾 `[PASS] nvmevirt regression OK`；`metrics_summary.txt` 摘出 `[FTL_EMU][SUMMARY]` 取证行）。
- 2026-01-28：FTL_EMU + ssdparams 映射 smoke（`ENGINE=cpu`，`CSD_FTL_SECSZ=512 CSD_FTL_SECS_PER_PG=8 CSD_FTL_PGS_PER_BLK=256 CSD_FTL_BLKS_PER_PL=1024 CSD_FTL_PLS_PER_LUN=2 CSD_FTL_LUNS_PER_CH=8 CSD_FTL_NCHS=8 CSD_FTL_PG_RD_LAT=6000 CSD_FTL_PG_WR_LAT=12000 CSD_FTL_BLK_ER_LAT=30000`），`/tmp/csd_ftl_emu_backend_cpu_20260128.log` 含 `[FTL_EMU][TLWE]`/`[FTL_EMU][GLWE]`/`[FTL_EMU][SUMMARY]` 证据行。
- 2026-01-28：deepnn4096 变体 smoke 通过（动态 shared‑mem 属性补齐后）：`/tmp/gpu_executor_smoke_4096_20260128c.log` 末尾 `[SMOKE] status_code=0 error_code=0`。
- 2026-01-03：全 flash 数据通路 + VP split 通过：`GPU_WOKS_NATIVE=1 NO_SUDO=0 CSD_KEYSET_IN_FLASH=1 CSD_TLWE_IN_FLASH=1 CSD_GLWE_OUT_FLASH=1 CSD_VP_KS_ON_BACKEND=1 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh`，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260103_185434/`（三案 `GLWE matches golden`，softmax `fail=0`，末尾 `[PASS] nvmevirt regression OK`）。
- 2026-01-03：全 flash 数据通路 + VP split + BE split（回归内置 be_split）通过：同上命令，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260103_224216/`（`be_split` 出现 `GLWE matches golden`，softmax `fail=0`，末尾 `[PASS] nvmevirt regression OK`；`metrics_summary.txt` 含 `be_split` 摘要行）。
- 2026-01-04：全 flash + VP split + BE split + M9 softmax KSPBS split（N=4）通过：同上命令，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260104_211109/`（末尾 `[PASS] nvmevirt regression OK`；用 `bash scripts/csd_gpu_nvmevirt_metrics_summary.sh <OUT_DIR> --write` 可补齐 `metrics_summary.txt` 的 `softmax_kspbs_split_agg kspbs_split_hits=532 ...`）。
- 2026-01-30：`GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260130_114725/`（末尾 `[PASS] nvmevirt regression OK`；`softmax fail=0`；`metrics_summary.txt` 落盘）。
- 2026-01-30：no‑fallback 回归（`CSD_NO_FALLBACK=1 NO_SUDO=0 GPU_WOKS_NATIVE=1`）通过，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260130_214544/`（`vp/exp/soft` 全部 `GLWE matches golden`，`softmax fail=0`，末尾 `[PASS] nvmevirt regression OK`，`metrics_summary.txt` 落盘且 `no_fallback=1`）。

### 5.1 VP/exp/soft（bit‑exact 比对 golden）
- 脚本：`scripts/csd_gpu_nvmevirt_oneclick.sh`
- 推荐验收：`GPU_WOKS_NATIVE=1`（禁用 CPU 兜底，验证纯 GPU WoKS 正确性）
- 判据：脚本输出 `GLWE matches golden`（三案都要过）
- 可选：`CSD_VP_KS_ON_BACKEND=1` 触发 VP KeySwitch 下沉（`flags[3]=0x08(backend_split)`）；取证看 `*_backend.log` 的 `vp_split=1` 与 `biglut_ns/ks_ns/premod_ns/woks_ns` 分段打点。
- 取证日志：`OUT_DIR/{vp,exp,soft}_e2e.log` + `OUT_DIR/*_backend.log`/`OUT_DIR/*_gpu_runtime_service.log`/`OUT_DIR/*_dmesg_new.log`

### 5.2 softmax（容差比对）
- 脚本：`scripts/csd_gpu_nvmevirt_softmax_oneclick.sh`
- 推荐验收：`NO_SUDO=0`（走完整 nvmevirt e2e，覆盖 0xC0→backend→/dev/mem 数据面）
- 判据：末尾打印 `fail=0`（`tools/softmax_fp64.py` 的 check 输出）
- 正确性含义：softmax 是 **明文 fp64 输入→TFHE 加密→密态 softmax→解密回 fp64 输出** 的闭环；`tools/softmax_fp64.py check` 会用同一份明文输入重算 trivial softmax 并做 abs/rel 容差比对，因此 `fail=0` 表示“解密后的结果与明文参考一致（容差内）”，不是 bit‑exact。
- M7 说明：默认使用 `FLAGS=0x10` 触发“后端分阶段编排 softmax”是**分阶段 RPC/取证接口**（后端分段发令、GPU service 持 session）；但**各阶段计算仍在 GPU service 内完成**，阶段名不等价于“轻算子”。当前 MAX/SHIFT/SUM/DIV 在 fixed‑point 实现里仍可能触发 PBS primitive（如 KSPBS），真实分工需按 PBS 微流程（Step4/Step5、SampleExtract/KeySwitch vs BR/FFT-heavy）来切。
- 取证日志：`NO_SUDO=0` 时为 `OUT_DIR/e2e.log` + `OUT_DIR/backend.log`/`OUT_DIR/gpu_runtime_service.log`/`OUT_DIR/dmesg_new.log`；`NO_SUDO=1` 时为 `OUT_DIR/gpu_runtime_service.log` + `OUT_DIR/staged_ipc.log`。
- 额外取证（更直观）：`OUT_DIR/check.log` 现在会打印 `got(head=...)`/`ref(head=...)` 的前几个 fp64 值，便于人工快速确认“解密结果≈明文参考”。
- 可选打点：`WOP_GPU_FUNC_STAGE_METRICS=1` 时，会额外打印 softmax 的分阶段耗时（`enc/max/shift/exp/sum/div/dec`），用于判断真正的瓶颈与后续下沉边界（默认在 `OUT_DIR/gpu_runtime_service.log`；`NO_SUDO=1` 的 staged IPC 客户端滚屏在 `OUT_DIR/staged_ipc.log`）。
  - 提取示例：`rg -n "\\[TFHE_GPU_EXEC\\]\\[FUNC_METRICS\\]" "$OUT_DIR/gpu_runtime_service.log"`（注意不要写成 `<OUT_DIR>`，shell 会把它当作重定向）。
  - 脚本行为：设置该变量后，`scripts/csd_gpu_nvmevirt_softmax_oneclick.sh` 末尾会额外打印一行 `[metrics] ...`（取自对应日志）。
- 可选打点：`WOP_GPU_KSPBS_CALL_METRICS=1` 时，`gpu_runtime_service.log` 会额外打印各阶段触发的 KSPBS 次数（`[TFHE_GPU_EXEC][KSPBS_CALLS] stage=... stride0=... stride1=...`），用于把“瓶颈”从函数阶段名进一步定位到 PBS primitive 的真实调用密度。
  - 脚本行为：设置该变量后，`scripts/csd_gpu_nvmevirt_softmax_oneclick.sh` 末尾会额外打印一段 `[metrics] KSPBS call counts ...`（取自对应日志）。
- 可选打点：`WOP_GPU_KSPBS_LUT_METRICS=1`（需同时开启 `WOP_GPU_KSPBS_CALL_METRICS=1`）时，会额外打印各阶段 KSPBS 的 **LUT 热点分布**（按 `lut_id` 统计 samples，输出 topN；格式形如 `lut10(lshift)=... lut11(rshift)=...`），用于决定优先下沉/优化哪些 LUT/流程。
  - 脚本行为：设置该变量后，`scripts/csd_gpu_nvmevirt_softmax_oneclick.sh` 末尾会额外打印一段 `[metrics] KSPBS LUT samples ...`（取自对应日志）。
- M9 试验：KSPBS split（默认只在 DIV 生效；设 `WOP_GPU_KSPBS_SPLIT_ALL_STAGES=1` 覆盖 MAX/SHIFT/EXP_MINUS/SUM/DIV）：`WOP_GPU_KSPBS_SPLIT=1 WOP_GPU_KSPBS_SPLIT_LUTS=1,2,7,10,11`。
  - 目标：让 FunctionEval/softmax 内的 KSPBS 走 split 微流程（CPU KeySwitch/Extract + GPU bootstrap-only），用于验证“GPU 只做 bootstrap-heavy”的证据链。
  - 脚本行为：当开启 split 时会自动启用 split 日志（等价于 `WOP_GPU_KSPBS_SPLIT_LOG=1`），并在末尾打印 `[metrics] KSPBS split hits ...`（取自 `gpu_runtime_service.log`；命中行形如 `[KSPBS_SPLIT] stage=1 lut10(lshift) ... ks_ns=... gpu_bootstrap_ns=... extract_ns=... total_ns=...`）。
- 一键入口（N=4 快跑，全阶段）：`scripts/csd_gpu_nvmevirt_softmax_kspbs_split_n4_oneclick.sh`。
- 一键入口（N=16 全阶段取证，较慢）：`scripts/csd_gpu_nvmevirt_softmax_kspbs_split_n16_oneclick.sh`（默认 `GPU_TIMEOUT=300`）。

#### 5.2.1 本次验收记录（取证）
- 2025-12-29：`NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_softmax_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_softmax_20251229_104458/`（末尾 `[PASS] softmax closed-loop OK`，`fail=0`）。
- 2025-12-30：`NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_softmax_oneclick.sh` 通过（修复 staged 空 payload gate 后），产物目录：`/tmp/csd_gpu_nvmevirt_softmax_20251230_091800/`（`fail=0`）。
- 2025-12-30：softmax 分阶段耗时打点（`WOP_GPU_FUNC_STAGE_METRICS=1 NO_SUDO=1`）通过，产物目录：`/tmp/csd_gpu_nvmevirt_softmax_stage_metrics_20251230_192346/`（`rg -n "\\[TFHE_GPU_EXEC\\]\\[FUNC_METRICS\\]" smoke.log`）。
- 2025-12-30：softmax 分阶段耗时打点（`WOP_GPU_FUNC_STAGE_METRICS=1 NO_SUDO=0`）通过，产物目录：`/tmp/csd_gpu_nvmevirt_softmax_20251230_203134/`（脚本末尾打印 `[metrics] ...`）。
- 2026-01-01：M9 DIV KSPBS split（`WOP_GPU_KSPBS_SPLIT=1 WOP_GPU_KSPBS_SPLIT_LUTS=10,11 NO_SUDO=0 N=4`）通过，产物目录：`/tmp/csd_gpu_nvmevirt_softmax_20260101_152549/`（`fail=0`，且 `gpu_runtime_service.log` 含 `[KSPBS_SPLIT] stage=1 lut10(lshift)/lut11(rshift)`；旧目录可能显示为 `lut=10/11`）。
- 2026-01-30：no‑fallback softmax（`CSD_NO_FALLBACK=1 NO_SUDO=0`）通过，产物目录：`/tmp/csd_gpu_nvmevirt_softmax_20260130_215517/`（`check.log` 含 `fail=0`，`e2e.log` 含 `no_fallback=1`）。
- 2026-01-31：no‑fallback softmax KSPBS split（`CSD_NO_FALLBACK=1 NO_SUDO=0`，N=16 全阶段）通过，产物目录：`/tmp/csd_gpu_nvmevirt_softmax_20260131_104100/`（`check.log` `fail=0`，`e2e.log` 含 `no_fallback=1`，`backend.log` 含 `func_stage cfg: kspbs_split=1 all_stages=1`，`gpu_runtime_service.log` 含 `stage=1/2/3` 的 `[KSPBS_SPLIT]`）。

### 5.3 CB step4_only（GPU 只做 Step4，Step5 在后端模拟）
- 脚本：`scripts/csd_gpu_nvmevirt_cb_step4only_oneclick.sh`
- 推荐验收：`GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_cb_step4only_oneclick.sh`
- 判据：脚本过程中出现 `GLWE matches golden`，末尾打印 `[PASS] CB step4_only split e2e OK`
- 备注：`NO_SUDO=1` 可跑用户态 smoke（GPU Step4-only → CPU privks-step4 → cmp golden），用于无 sudo 的快速 sanity check；`NO_SUDO=0` 时 Step5 由后端执行（`CSD_PRIVKS_IMPL=numpy|cpu_runner`，默认 numpy）。
- 取证日志：`OUT_DIR/e2e.log` + `OUT_DIR/backend.log`（含 `metrics ...` 行，记录 step4/step5 延迟与 bytes）+ `OUT_DIR/gpu_runtime_service.log` + `OUT_DIR/dmesg_new.log`

#### 5.3.1 本次验收记录（取证）
- 2025-12-29：`GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_cb_step4only_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_cb_step4only_20251229_155503/`（末尾 `[PASS] CB step4_only split e2e OK`）。
- 2026-01-30：no‑fallback CB step4_only（`CSD_NO_FALLBACK=1 NO_SUDO=0`）通过，产物目录：`/tmp/csd_gpu_nvmevirt_cb_step4only_20260130_215732/`（`e2e.log` 含 `GLWE matches golden`，末尾 `[PASS] CB step4_only split e2e OK`，`no_fallback=1`）。

### 5.4 CB step4_only + premod（M5：Preprocess 下沉）
- 脚本：`scripts/csd_gpu_nvmevirt_cb_step4only_premod_oneclick.sh`
- 推荐验收：`GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_cb_step4only_premod_oneclick.sh`
- 判据：末尾打印 `[PASS] CB step4_only + premod split e2e OK`
- 备注：`NO_SUDO=1` 可跑用户态 smoke（后端 premod(i32) → GPU Step4-only → CPU privks-step4 → cmp golden），用于无 sudo 的快速 sanity check；`NO_SUDO=0` 时 Step5 由后端执行（`CSD_PRIVKS_IMPL=numpy|cpu_runner`，默认 numpy）。
- 取证日志：同 5.3（`OUT_DIR/e2e.log`/`OUT_DIR/backend.log`/`OUT_DIR/gpu_runtime_service.log`/`OUT_DIR/dmesg_new.log`）

#### 5.4.1 本次验收记录（取证）
- 2025-12-29：`GPU_WOKS_NATIVE=1 NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_cb_step4only_premod_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_cb_step4only_premod_20251229_164111/`（末尾 `[PASS] Smoke OK: step5 matches golden`）。
- 2025-12-29：`GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_cb_step4only_premod_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_cb_step4only_premod_20251229_164721/`（末尾 `[PASS] CB step4_only + premod split e2e OK`，并出现 `GLWE matches golden`）。
- 2026-01-30：no‑fallback 回归内置 premod 步骤通过（`CSD_NO_FALLBACK=1 NO_SUDO=0`），产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260130_214544/cb_step4only_premod/`（末尾 `[PASS] CB step4_only + premod split e2e OK`，`no_fallback=1`）。

### 5.5 M6：Step5(PrivKS) 后端模块化（去掉“外部 cpu_reference_runner 模拟”）
- 背景：M4/M5 的 split 路径里，Step5 曾通过 `cpu_reference_runner --privks-step4` 单次进程调用实现；这不利于“后端/CSD 可实现”的模块化与 key 常驻。
- 现状：nvmevirt 后端默认走 **mmap keyset + numpy 计算** 的 Step5（与 CPU baseline bit‑exact 对齐），失败会自动回退到 `cpu_reference_runner`。
  - Step5 模块：`../nvmevirt/tools/csd_privks_step4.py`
  - 后端集成点：`../nvmevirt/tools/csd_sw_backend.py`
  - 强制选择实现：`CSD_PRIVKS_IMPL=numpy|cpu_runner`（`../nvmevirt/tools/csd_e2e_smoke.sh` 会在 sudo 场景下透传该变量）
- 无 sudo 自检（推荐先跑）：`bash scripts/csd_gpu_privks_step4_backend_smoke.sh`

#### 5.5.1 本次验收记录（取证）
- 2025-12-29：`bash scripts/csd_gpu_privks_step4_backend_smoke.sh` 通过，产物目录：`/tmp/csd_gpu_privks_step4_backend_smoke_20251229_173959/`（打印 `[PASS] PrivKS step5 matches cpu_reference_runner`）。

### 5.6 M8：KSPBS 微流程拆分（KeySwitch+Extract 下沉，GPU 只做 bootstrap-heavy）
- 背景：softmax/FunctionEval 的 `MAX/SHIFT/SUM/DIV` 是函数级步骤名；真正的“轻/重”边界在 PBS primitive（如 KSPBS=KeySwitch+Bootstrap+SampleExtract）的微流程里。
- 目标：把 KSPBS 拆成“后端/CSD：KeySwitch_lv10 + SampleExtract；GPU：bootstrap-only（BlindRotate/FFT-heavy）”，并与 GPU 单体 KSPBS 做 bit‑exact 对照。
- nvmevirt e2e 入口（推荐）：`bash scripts/csd_gpu_nvmevirt_kspbs_split_oneclick.sh`
  - 协议编码：复用 nvmevirt 现有 `mode=3(FunctionEval)`，用 `flags=0x08` 触发后端 KSPBS split（仍满足 “mode 只有 2 bit” 的约束）。
  - 后端实现：`../nvmevirt/tools/csd_sw_backend.py` 在 `mode=3 && flags&0x08` 下执行
    - KeySwitch_lv10（`preKS_gpbs`）+ SampleExtract（后端）
    - bootstrap-only（GPU：`gpu_runtime_service mode=4(PBS primitive), flags=1`）
    - 并对照 GPU full（`mode=4, flags=2`）做 bit‑exact 校验，失败直接报错码。
  - 备注：首次运行若 sudo 需要口令，请先执行 `sudo -v`（或用 `NO_SUDO=1` 走用户态 smoke）。
- 用户态 smoke（不走 nvmevirt）：`bash scripts/csd_gpu_kspbs_split_backend_smoke.sh`（脚本内部调用 `../nvmevirt/tools/csd_kspbs_split.py`）
- 判据：后端日志出现 `[KSPBS_SPLIT][PASS] ...`（nvmevirt e2e）或 `kspbs_split.log` 出现 `[PASS] KSPBS split matches GPU monolithic`（smoke），并落盘分段耗时 `ks_ns/gpu_bootstrap_ns/extract_ns`。 
- per-sample LUT（batch + `lut_id[]` tail bytes）入口：`bash scripts/csd_gpu_nvmevirt_kspbs_split_per_sample_oneclick.sh`
  - 推荐：`CSD_USE_PRP=0`（走 `/dev/mem` staging，避免 PRP path 只拷 `tlwe_words*8` 导致 `lut_id[]` tail 丢失）；脚本默认已设置。
  - 判据：`backend.log` 含 `[KSPBS_SPLIT][PASS]` 且 `metrics ... per_sample=1 batch=... groups=...`。

#### 5.6.1 本次验收记录（取证）
- 2025-12-29：`bash scripts/csd_gpu_kspbs_split_backend_smoke.sh` 通过，产物目录：`/tmp/csd_gpu_kspbs_split_backend_smoke_20251229_224402/`。
- 2025-12-29：`NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_kspbs_split_oneclick.sh` 通过（用户态 smoke），产物目录：`/tmp/csd_gpu_nvmevirt_kspbs_split_20251229_233330/`。
- 2026-01-30：no‑fallback KSPBS split（`CSD_NO_FALLBACK=1 NO_SUDO=0`）通过，产物目录：`/tmp/csd_gpu_nvmevirt_kspbs_split_20260130_215910/`（`backend.log` 含 `[KSPBS_SPLIT][PASS]`，`e2e.log` 含 `no_fallback=1`）。
- 2026-01-30：no‑fallback 回归内置 per‑sample LUT split 通过，产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260130_214544/kspbs_split_per_sample/`（`backend.log` 含 `[KSPBS_SPLIT][PASS]`，`per_sample=1 batch=4 groups=3`）。

### 5.7 BE KeySwitch 下沉（mode=1，backend_split=0x08）
- nvmevirt e2e 脚本：`scripts/csd_gpu_nvmevirt_be_split_oneclick.sh`
  - `NO_SUDO=0`：完整 nvmevirt e2e（0xC0→backend split→GPU service）
  - `NO_SUDO=1`：用户态 smoke（不走 nvmevirt）
- 分工语义：GPU bit_extract-only → 后端 KeySwitch_lv10(gpbs)+premod → GPU WoKS（见 `docs/gpu_csd_operator_contract.md` 的 `flags[3]=0x08`）
- 判据：`e2e.log` 出现 `GLWE matches golden`；`backend.log` 含 `metrics cmd=... be_split=1 ...` 分段耗时打点
- 取证日志：`OUT_DIR/e2e.log` + `OUT_DIR/backend.log`/`OUT_DIR/gpu_runtime_service.log`/`OUT_DIR/dmesg_new.log`

### 5.8 macrobenchmark：Zama deep‑nn（准备长跑）
- 包装脚本：`scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh`
  - 作用：统一长跑环境变量（默认走全 flash + keep session/backend），并把 deep‑nn 的 stdout/stderr 落盘到 `OUT_DIR/run.log`，便于复盘与 `rg` 过滤取证。
  - 控制台输出对齐：默认 `CSD_DEEPNN_CONSOLE_PRETTY=1`（剥离 ANSI/控制字符并过滤 tqdm 进度条，保留表格缩进；需要原始滚屏设 `CSD_DEEPNN_CONSOLE_PRETTY=0`）。
  - 说明：该脚本不自带 deep‑nn workload repo；若未提供命令，会尝试跑默认 workload（concrete-ml 的 `benchmarks/deep_learning.py`，默认路径 `~/workspace/deep-nn`）。
  - 图谱画像：默认启用 `CSD_DEEPNN_PROFILE=1`，会把 deep‑nn 编译期统计写到 `OUT_DIR/deepnn_profile.json`；摘要：`python3 tools/csd_deepnn_profile_summary.py "$OUT_DIR/deepnn_profile.json"`。
  - 接入钩子：默认启用 `CSD_DEEPNN_OFFLOAD_SOFTMAX=1`，会在 deep‑nn 运行过程中触发一次 softmax offload，用于证明 workload 已能调用我们链路并留证。
    - `NO_SUDO=1`：IPC→`gpu_runtime_service`
    - `NO_SUDO=0`：nvmevirt/0xC0 e2e（mode=3, flags=0x10），证据落盘 `OUT_DIR/backend.log` + `OUT_DIR/dmesg_new.log`（长跑前先 `sudo -v`）
      - 若 sudo ticket 缺失，可设 `CSD_DEEPNN_ALLOW_SUDO_PROMPT=1`（或 `CSD_SOFTMAX_ALLOW_SUDO_PROMPT=1`）允许运行时弹 sudo；默认仍推荐提前 `sudo -v`。
    - 正确性门槛（默认启用）：`CSD_DEEPNN_OFFLOAD_SOFTMAX_STRICT=1` + `CSD_DEEPNN_OFFLOAD_SOFTMAX_MAX_MAE=1e-3`，若 offload MAE 超阈值则直接失败（用于防 spqlios/参数错配导致 silent wrong）。
    - 性能试验（可选）：`CSD_DEEPNN_OFFLOAD_SOFTMAX_KSPBS_SPLIT=1`（启用 KSPBS split；默认 `WOP_GPU_KSPBS_SPLIT_LUTS=10,11`）
- 方案与里程碑：`docs/gpu_csd_deepnn_macrobenchmark_plan.md`
- 已验证最小 deep‑nn workload（离线可跑，无需下载数据集）：`zama-ai/concrete-ml` 的 `benchmarks/deep_learning.py`（MNIST + CNN）。
  - 拉仓库：`git clone https://github.com/zama-ai/concrete-ml.git ~/workspace/deep-nn`
  - 建 venv + 安装（CPU-only torch，避免拉 CUDA 巨包）：
    - `cd ~/workspace/deep-nn && python3 -m venv .venv && .venv/bin/pip install -U pip`
    - `cd ~/workspace/deep-nn && .venv/bin/pip install --index-url https://download.pytorch.org/whl/cpu torch==2.3.1`
    - `cd ~/workspace/deep-nn && .venv/bin/pip install concrete-ml==1.9.0 py-progress-tracker==0.7.0`
  - 坑：`benchmarks/pre_trained_models/*.pt` 可能是 git-lfs 指针文件；若报 `torch.load ... invalid load key, 'v'`，先训练生成权重：
    - `cd ~/workspace/deep-nn && .venv/bin/python benchmarks/deep_learning.py --train --epochs 1 --batch_size 32 --models ShallowNarrowCNN --datasets MNIST`
- 推荐前置门槛：先通过全量回归 `GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh`（末尾 `[PASS] nvmevirt regression OK`）。
- 建议用法：`bash scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh -- <deep-nn-command...>`
  - 最小可跑（1 个 FHE sample）：
    - `NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh -- ~/workspace/deep-nn/.venv/bin/python ~/workspace/deep-nn/benchmarks/deep_learning.py --models ShallowNarrowCNN --datasets MNIST --configs '{"n_bits":2,"p_error":9.094947017729282e-13}' --fhe_samples 1 --model_samples 1 --verbose`
- 默认可跑（无需提供命令，走 `~/workspace/deep-nn`）：
  - `NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh`
- 快速取证：`rg -n "\\[PASS\\]|\\[FAIL\\]|error|timeout|metrics|Traceback" "$OUT_DIR/run.log"`
  - offload 证据：`OUT_DIR/run.log` 含 `[CSD_DEEPNN] softmax offload ok`，且 `OUT_DIR/gpu_runtime_service.log` 含 `mode=3` 的 `[TFHE_GPU_EXEC][REQ]`。
  - 汇总（自动生成）：`OUT_DIR/deepnn_run_summary.txt`（聚合 progress.json + profile top 参数组 + `keyset_meta` + `param_alignment_hint`）
    - `param_alignment_hint` 会给出 `fully_compatible` 与 `blocking_reasons`，用于明确：deep‑nn 的编译期 PBS 参数（polynomial_size / input_lwe_dimension / glwe_dimension）是否能被本项目 keyset/执行器直接覆盖。
  - M3 扫描回归：`REPEATS=5 NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_macro_deepnn_sweep.sh`
    - 产物：`OUT_PARENT/sweep_summary.csv` + `OUT_PARENT/sweep_stats.txt`
    - 已有 OUT_PARENT 只做汇总：`python3 tools/csd_deepnn_sweep_summary.py --out-parent <OUT_PARENT>`

#### 5.8.1 本次验收记录（取证）
- 2026-01-06：`NO_SUDO=0 GPU_TIMEOUT=240 bash scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_macro_deepnn_20260106_152053/`（`deepnn_run_summary.txt` 含 `nvmevirt_evidence`）。
- 2026-01-06：`REPEATS=5 NO_SUDO=0 GPU_TIMEOUT=240 bash scripts/csd_gpu_nvmevirt_macro_deepnn_sweep.sh` 通过，产物目录：`/tmp/csd_gpu_nvmevirt_macro_deepnn_sweep_20260106_170305/`（`sweep_summary.csv` 作为 M3 方差基线）。
- 2026-01-07：多变体对齐（poly=1024/K=2、2048/K=1、4096/K=1）NO_SUDO=0 单跑通过，产物：`/tmp/csd_gpu_nvmevirt_macro_deepnn_multivariant_nosudo_20260107_142718/`（`softmax offload ok`，MAE≈1.21e-05，`param_alignment_hint_variants fully_compatible=True`，`dmesg_new.log` 含 `mode=3 flags=0x10`）。
- 2026-01-07：多变体 NO_SUDO=0 方差扫（REPEATS=5），产物：`/tmp/csd_gpu_nvmevirt_macro_deepnn_multivariant_sweep_nosudo_20260107_150115/`（`sweep_stats.txt`：offload_time 平均≈167.131s ±2.101，exec_time_per_sample 平均≈169.314s ±2.063，五次均 `softmax offload ok`，`param_alignment_hint_variants fully_compatible=True`）。
- 2026-01-28：多变体 + keyset flash（K=1 过滤）NO_SUDO=0 nvmevirt e2e 取证：`/tmp/csd_gpu_nvmevirt_macro_deepnn_multivariant_20260128_134705/`（`softmax_offload_e2e.log` 含 `keyset(loopdev)`/`[KEYSET_FLASH]`；`dmesg_new.log` 含 `CSD: op=0xc0 mode=3`；`backend.log` 含 `metrics cmd=... mode=3 flags=0x10`；`run.log` 含 `softmax offload ok`）。
- 2026-01-28：deep‑nn L2 一键（NO_SUDO=0）通过：`/tmp/csd_gpu_nvmevirt_macro_deepnn_l2_20260128_124125/`（`m5_m6_run/run.log` 含 `[CSD_DEEPNN][L2] fhe compare ok` 与 `device=cuda`；`m5_m6_run/backend_fhe.log` 含 `metrics cmd=49921 ... concrete_exec=gpu_service`；`m5_m6_run/dmesg_fhe.log` 含 `CSD: op=0xc0 mode=3 flags=0x24`）。

### 5.9 he3db trace replay（性能回放）
- 说明：`--no-prp` 走 memmap staging，属于性能回放路径（非 correctness 校验）。
- 取证（2026-01-27）：
  - 4096 trace：`/tmp/csd_he3db_replay_20260127_092755/trace_4096/replay.log`（`no_prp=True`，`ops_per_s=5.637`）。
  - 16384 trace：`/tmp/csd_he3db_replay_20260127_092755/trace_16384/replay.log`（`no_prp=True`，`ops_per_s=5.624`）。
- 取证（2026-02-05/06，重启后复跑）：`/home/pxr/workspace/hpu_fpga_fin/tmp/overlap_he3db_20260205_101746/`
  - 4096 trace：`trace_4096/replay.log`（`ops_per_s=5.644`），并已生成 `trace_4096/pipeline_stats.{json,txt}`。
  - 16384 trace：`trace_16384/replay.log`（`ops_per_s=5.643`），并已生成 `trace_16384/pipeline_stats.{json,txt}`。

### 5.10 pipeline overlap 取证（nvmevirt）
- 说明：通过 `CSD_PIPELINE_TRACE=1` 落盘 `pipeline_trace.log`，再用 `tools/pipeline_overlap_analyzer.py` 生成 `pipeline_stats.{json,txt}`。
- 取证（2026-02-02）：回归矩阵 overlap 复跑目录：`/tmp/overlap_regression_20260202_112218/`
  - 覆盖步骤：`vp_exp_soft`、`be_split`、`softmax`、`cb_step4only`、`cb_step4only_premod`、`kspbs_split`、`kspbs_split_per_sample`、`softmax_kspbs_split_n4`。
  - 每步均含：`pipeline_trace.log` + `pipeline_stats.{json,txt}`。
- 取证（2026-02-05）：deep‑nn L2 overlap 复跑目录：`/tmp/overlap_deepnn_l2_20260205_093529/`
  - `m5_m6_run/run.log` 含 `[CSD_DEEPNN][L2] fhe compare ok`；`m5_m6_run/pipeline_stats.{json,txt}` 已生成。

## 6. 常见坑（必须知道）
- **TLWE staging 地址**：不要把输入写到 `memmap_start` 头 1MB（NVMe BAR/doorbell/MSI‑X），会导致 0xC0 卡死；必须用 storage window（常用 `memmap_start+2MB`）。
- **backend 写回 `Operation not permitted`**：若 `../nvmevirt/tools/csd_sw_backend.py` 报 `PermissionError: [Errno 1] Operation not permitted`，多半是 `glwe_addr` 落在 System RAM（bounce 回退 `dma_alloc_coherent`，严格 devmem 下用户态无法 mmap）；应确保 bounce stripes 落在 memmap storage window，使 `glwe_addr` 为 `0x2000...`。
- **spqlios 表文件缺失**：默认使用 `/tmp/spqlios_{fft,ifft}_table.n4096.bin`；若 `/tmp` 被清理会导致脚本启动即失败。当前一键脚本会在缺失时自动调用 `sw/gpu_runtime_service/build-clean/spqlios_table_exporter` 生成（日志在各自 `OUT_DIR/spqlios_table_exporter.log`）。
- **mode=3 被误当成 mode=0**：nvmevirt 0xC0 的 `mode` 字段只有 2 bit；若内核把 `mode>2` clamp 成 `mode=0`，softmax 会“跑了但跑错 pipeline”，输出被当作 fp64 解读后出现极大/极小值。验收时可在 dmesg/`e2e.log` 中确认 `CSD: ... mode=3`。
- **softmax staged 输出全 0**：若 `OUT_DIR/check.log` 里 `got=0.00000000` 大面积出现，先 `rg -n "tlwe payload is empty|falling back to echo" OUT_DIR/gpu_runtime_service.log`；该类问题通常是 `gpu_runtime_service` 入口误拒绝 staged 的空 payload（中间 op 按合同会发 `tlwe_bytes=0`）。已修复：`sw/gpu_runtime_service/src/tfhe_gpu_executor.cpp:1844` 放行 `mode=3 && tlwe_bytes=0`；确认已重新编译/使用最新 `sw/gpu_runtime_service/build-clean/gpu_runtime_service`。
- **nvme-cli 语义限制**：`nvme io-passthru` 难以表达“PRP1 输入 + PRP2 输出”的非标准语义；当前 e2e 以 doorbell + `/dev/mem` 数据面为主，必要时走 PRP staging。
- **descriptor/status 布局**：按 RTL/TB 的 SV packed qwords 解析/回写；按 C struct 会把地址/字段读错。
- **keyset / golden 一致性**：keyset 或 threads 变动会导致 golden 失配；回归应固定同一 keyset 生成 TLWE+golden 并复用。
- **flash staging 校验报 `Permission denied`**：若开启 `CSD_TLWE_IN_FLASH=1`/`CSD_GLWE_OUT_FLASH=1` 后出现 `dd: failed to open '/tmp/tmp.*': Permission denied`，通常是系统开启了 /tmp 的 sticky-dir 保护；升级 `../nvmevirt/tools/csd_e2e_smoke.sh`（用 stdout 重定向写临时文件）即可。
- **sudo 行为**：脚本可能先探测 `sudo -n true`，ticket 有效时不提示密码；过期才会弹窗。
- **nvmevirt 性能 profile**：可通过 `CSD_NVMEVIRT_PROFILE_NAME=<name>` 与 `CSD_NVMEVIRT_PROFILE_OVERRIDES="<k=v,...>"` 透传到 `insmod nvmev.ko`（对应 `profile_name/profile_overrides` 参数，见 `../nvmevirt/README.md`）。
- **FTL/flash 模型参数对齐（nvmevirt 兼容）**：启用 `CSD_FTL_EMU=1` 后，若提供 nvmevirt 的 FTL 参数（`CSD_FTL_SECSZ`/`CSD_FTL_SECS_PER_PG`/`CSD_FTL_PGS_PER_BLK`/`CSD_FTL_BLKS_PER_PL`/`CSD_FTL_PLS_PER_LUN`/`CSD_FTL_LUNS_PER_CH`/`CSD_FTL_PG_RD_LAT`/`CSD_FTL_PG_WR_LAT`/`CSD_FTL_BLK_ER_LAT`/`CSD_FTL_FW_*`），后端会按 ssdparams 映射几何与延迟（lat 以 ns 计，`cycle_ns` 自动降为 1），并在 `backend.log` 输出 `[FTL_EMU][TLWE]/[GLWE]/[SUMMARY]` 证据行。

## 7. 状态：细粒度分工已闭环（仅剩 OpenSSD 上板）
- M0–M11 已闭环：vp/exp/soft、softmax、CB step4_only、KSPBS split、staged FunctionEval、后端常驻/预热、性能模型校准均有取证。
- 更新（2026-02-06）：流水线重叠（nvmevirt 侧）已补齐证据：回归矩阵 `tmp/overlap_regression_20260202_112218/`、deep‑nn L2 `tmp/overlap_deepnn_l2_20260205_093529/`、he3db replay `tmp/overlap_he3db_20260205_101746/` 均含 `pipeline_stats.{json,txt}`；后续仅需 OpenSSD 上板补齐板级时间线/节拍数据。
- 当前仅剩 **OpenSSD 实物上板验证**（含板级 ACK stub/AXI 事务/latency/QoS 取证）作为后续任务。
