# hpu_fpga_fin：GPU‑CSD nvmevirt e2e（工程入口）

> 本文件用于 Codex CLI 工作流的“Clarify Scope”，给出**目标 / 判据 / 入口脚本 / 取证路径**。  
> 文档总入口：`docs/gpu_csd_e2e.md`

## 目标（当前阶段）
- 跑通并固化 GPU‑CSD nvmevirt e2e：链路全通、分工闭环、可回归、可取证。
- 分工原则：按 **PBS 微流程边界** 拆分（Step4：BR/FFT-heavy 在 GPU；Step5/SampleExtract/KeySwitch 等低算强环节在后端/CSD），而不是按 softmax 的函数级步骤名拆。

## 停止条件（验收判据）
- 全量回归一键：`GPU_WOKS_NATIVE=1 NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh`
  - 判据：末尾出现 `[PASS] nvmevirt regression OK`
  - 更新（2026-01-30）：已通过（`/tmp/csd_gpu_nvmevirt_regression_20260130_094718/`）
  - 更新（2026-01-31）：启用 `CSD_KEEP_BACKEND=1 CSD_BACKEND_PREWARM=1` 回归通过（`/tmp/csd_gpu_nvmevirt_regression_20260131_113138/`，`metrics_summary.txt` 含 `reuse_backend=1`）。
  - 更新（2026-01-31）：no‑fallback 复跑通过（`/tmp/csd_gpu_nvmevirt_regression_20260131_134826/`）。
- 用户态快速 smoke：`GPU_WOKS_NATIVE=1 NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_regression_oneclick.sh`
  - 判据：末尾出现 `[PASS] nvmevirt regression OK`
  - 更新（2026-01-30）：已通过（`/tmp/csd_gpu_nvmevirt_regression_20260130_093506/`）；NO_SUDO=0 亦已在后续回归中通过取证（见 self.md 记录）。

## 入口脚本（常用）
- 全量回归（推荐入口）：`scripts/csd_gpu_nvmevirt_regression_oneclick.sh`
  - 默认控制台输出会去噪并对齐；每步完整原始输出在 `OUT_DIR/<step>/run.log`
  - 需要全量滚屏：`CSD_REGRESSION_VERBOSE=1 ...`（仍会剥离控制字符并 trim，避免乱缩进；原始未处理输出见 `run.log`）
  - M9：回归内会额外跑 `softmax_kspbs_split_n4/`（`N=4`）用于 split 取证（默认 `WOP_GPU_KSPBS_SPLIT=1 WOP_GPU_KSPBS_SPLIT_ALL_STAGES=1`），并对 `softmax/`（默认 `N=16`）默认自动 unset `WOP_GPU_KSPBS_SPLIT*`，避免 staged DIV(op=6) 超时；如需让 `softmax/` 也继承 split 环境，设 `CSD_REGRESSION_SOFTMAX_KEEP_SPLIT=1`。
  - M10：当 `NO_SUDO=0` 且 `CSD_KEEP_SESSION=1` 时，回归脚本默认也会启用 `CSD_KEEP_BACKEND=1` 复用 `csd_sw_backend.py`（key mmap/caches 常驻）；取证看 `e2e.log` 的 `[SESSION] reuse csd_sw_backend`（回归汇总 `flash_*` 行会额外打印 `reuse_backend=1`）。
  - 可选：`CSD_BACKEND_PREWARM=1` 会在 backend 启动后异步预热 PrivKS/KSPBS cache（`backend_service.log` 含 `Prewarm done` 与 `cache hit`）。
  - OpenSSD/FTL 软件移植（无硬件）：`CSD_FTL_EMU=1` 可在 nvmevirt backend 里启用 OpenSSD 风格 FTL staging + ring(doorbell/ACK) 日志；证据看各步 `backend.log` 的 `[DESC_RING]`/`[FTL_EMU][SUMMARY]`，回归汇总会把最后一条 `[FTL_EMU][SUMMARY]` 摘到 `metrics_summary.txt`。
- VP/exp/soft（bit‑exact）：`scripts/csd_gpu_nvmevirt_oneclick.sh`
  - nvmevirt e2e 详细滚屏落盘：`OUT_DIR/vp_e2e.log`、`OUT_DIR/exp_e2e.log`、`OUT_DIR/soft_e2e.log`
- BE KeySwitch 下沉（用户态 smoke，bit‑exact）：`scripts/csd_gpu_be_split_backend_smoke.sh`
  - 含义：GPU bit_extract-only → 后端 KeySwitch_lv10(gpbs)+premod → GPU WoKS，对齐 `cpu_reference_runner --mode 1` golden。
- softmax（容差比对）：`scripts/csd_gpu_nvmevirt_softmax_oneclick.sh`
  - 含义：softmax 是明文 fp64 输入→TFHE 加密→密态 softmax→解密回 fp64 输出；`fail=0` 来自 `tools/softmax_fp64.py check` 的容差比对（非 bit‑exact）。
  - 16bit 注意：固定点分辨率为 1/1024，softmax 输出使用 floor 截断会产生 ~9.77e-4 量化误差。脚本在 `WOPBS_FP_TOTAL_BITS=16` 时自动传 `--ref-quant-frac-bits` + `--ref-quant-mode floor`，保持默认阈值不变。
- softmax KSPBS split（M9，N=4 快跑，全阶段）：`scripts/csd_gpu_nvmevirt_softmax_kspbs_split_n4_oneclick.sh`
- CB step4_only split：`scripts/csd_gpu_nvmevirt_cb_step4only_oneclick.sh`
  - nvmevirt e2e 详细滚屏落盘：`OUT_DIR/e2e.log`
- CB step4_only + premod：`scripts/csd_gpu_nvmevirt_cb_step4only_premod_oneclick.sh`
  - nvmevirt e2e 详细滚屏落盘：`OUT_DIR/e2e.log`
- KSPBS micro‑flow split：`scripts/csd_gpu_nvmevirt_kspbs_split_oneclick.sh`
- KSPBS micro‑flow split（per-sample LUT）：`scripts/csd_gpu_nvmevirt_kspbs_split_per_sample_oneclick.sh`
- macrobenchmark（Zama deep‑nn）：`scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh`
  - 说明：统一 env + 日志落盘；若未提供命令，会尝试跑默认 workload（concrete-ml 的 `benchmarks/deep_learning.py`，默认路径 `~/workspace/deep-nn`，详见 `docs/gpu_csd_e2e.md` 的 5.8）。
  - 默认还会触发一次 softmax offload 作为接入钩子：`CSD_DEEPNN_OFFLOAD_SOFTMAX=1`
    - `NO_SUDO=1`：IPC→`gpu_runtime_service`（证据见 `OUT_DIR/run.log` 的 `[CSD_DEEPNN]` 与 `OUT_DIR/gpu_runtime_service.log` 的 `mode=3`）。
    - `NO_SUDO=0`：nvmevirt/0xC0 e2e（mode=3, flags=0x10；证据见 `OUT_DIR/backend.log`/`OUT_DIR/dmesg_new.log`；长跑前先 `sudo -v`）。
  - 关键正确性前置：FunctionEval softmax 依赖 spqlios FFT 表；脚本默认设置 `TFHE_GPU_SPQLIOS_{FFT,IFFT}=1` 并使用 `/tmp/spqlios_*_table.n4096.bin`（缺失会自动生成）。
  - 详细方案（正确性/性能里程碑）：`docs/gpu_csd_deepnn_macrobenchmark_plan.md`
  - 用法：`bash scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh -- <deep-nn-command...>`（或直接不带 args 走默认）
  - 控制台输出对齐：默认 `CSD_DEEPNN_CONSOLE_PRETTY=1`（剥离 ANSI/控制字符并过滤 tqdm 进度条，保留表格缩进；需要原始滚屏设 `CSD_DEEPNN_CONSOLE_PRETTY=0`）
  - 汇总（自动生成）：`OUT_DIR/deepnn_run_summary.txt`（含 `keyset_meta` 与 `param_alignment_hint`，用于判断 deep‑nn 编译参数与本项目 keyset 是否具备对齐基础）
- macrobenchmark L2（M4→M6，一键）：`scripts/csd_gpu_nvmevirt_macro_deepnn_l2_oneclick.sh`
   - 说明：自动做多变体对齐 + nvmevirt FHE 运行 + IPC 对比，证据落盘到 `OUT_PARENT/m5_m6_run/`，需 `NO_SUDO=0`。

## no‑fallback 模式（CSD_NO_FALLBACK=1）
- 入口：`CSD_NO_FALLBACK=1`（默认 0）；所有一键/回归脚本会打印 `no_fallback` 配置行。
- 行为：禁止 IPC/NO_SUDO 回退、CPU override、BR no‑FFT（强制 `WOP_GPU_BIGLUT_BR_FORCE_FFT=1`）、softmax 自动容差、softmax 自动清理 split；触发直接报错退出（`[err][no-fallback] ...`）。
- 后端：`../nvmevirt/tools/csd_sw_backend.py` 在 no‑fallback 下禁止变体/PrivKS fallback。
- 直接拒绝运行（no‑fallback=1 时）：
  - 任何 `NO_SUDO=1` 的一键/回归路径（含 user‑mode smoke）。
  - `scripts/csd_gpu_nvmevirt_macro_deepnn_l2_oneclick.sh`（内部包含 NO_SUDO=1 profile/align）。
  - `scripts/csd_gpu_nvmevirt_macro_deepnn_multivariant_oneclick.sh`（align 为 NO_SUDO=1）。
  - `scripts/csd_gpu_nvmevirt_macro_deepnn_fullflow_oneclick.sh` 在 `RUN_MULTIVARIANT=1` 时。
  - `scripts/csd_gpu_deepnn_concrete_align_oneclick.sh`（NO_SUDO=1 only）。

## 取证与定位（最短路径）
- 产物目录：默认写到 `/tmp/csd_gpu_nvmevirt_*_<timestamp>/`
- 常用证据文件：
  - `backend.log`：后端关键日志 + `metrics cmd=...`
  - `gpu_runtime_service.log`：GPU service 侧日志（mode/flags/session）
  - `dmesg_new.log`：本次加载 nvmevirt 后新增的 dmesg 片段
- 快速过滤（示例）：`rg -n "metrics cmd=|GLWE matches golden|doorbell cmd_id=|PermissionError|Oops|timeout|KSPBS_SPLIT|fail=" -S <log>`
- 老产物补齐汇总（log-only）：`bash scripts/csd_gpu_nvmevirt_metrics_summary.sh <OUT_DIR> --write`（从现有日志生成/更新 `metrics_summary.txt`，含 `softmax_kspbs_split_agg kspbs_split_hits=...`）。
- DIV split 试验开关：`WOP_GPU_KSPBS_SPLIT=1 WOP_GPU_KSPBS_SPLIT_LUTS=1,2,7,10,11`（可收口为 `10,11`）；证据看 `gpu_runtime_service.log` 的 `[KSPBS_SPLIT]`（`scripts/csd_gpu_nvmevirt_softmax_oneclick.sh` 开启 split 时会自动在末尾打印 `[metrics] KSPBS split hits ...`）。

## 关键文档
- e2e 总入口与验收矩阵：`docs/gpu_csd_e2e.md`
- 目标分工表（StoryLine）：`docs/storyline.md`
- 算子边界合同（M2）：`docs/gpu_csd_operator_contract.md`
- 证据审阅报告（2026-02-02）：`docs/gpu_csd_e2e_audit_20260202.md`

## 16bit 固定点（exp_minus）已闭环
- no‑fallback 下允许 16bit；固定点配置已对齐（`WOPBS_FP_INT_BITS=6`、exp 分段默认对齐）。
- bigLUT L<N + spqlios FFT guard 已闭环，FunctionEval smoke `max_abs_err≈0.001146`（`/tmp/gpu_function_eval_smoke_wopbs16_br_nofmt_20260129_151536.log`）。
- softmax 结果按 2^-10 floor 量化对齐参考值，默认阈值保持不变（详见 `/tmp/csd_gpu_nvmevirt_softmax_20260201_120625/` 复核）。

## macrobenchmark（deep‑nn）已闭环
- no‑fallback macro deep‑nn 与 fullflow 均已通过（证据见 self.md：`/tmp/csd_gpu_nvmevirt_macro_deepnn_20260131_222627/`、`/tmp/csd_gpu_nvmevirt_macro_deepnn_fullflow_20260131_222901/`）。
- 当前仅剩 OpenSSD 实物上板验证作为后续任务。
- 更新（2026-02-02）：现有日志审阅已完成（见 `docs/gpu_csd_e2e_audit_20260202.md`），流水线重叠优化暂无可核验证据，需后续上板或实测补齐。
