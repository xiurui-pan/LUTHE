# nvmevirt + GPU 跑 deep‑nn（concrete‑ml）TFHE workload：正确性 & 性能方案（M0→M6）

> 适用 workload：`~/workspace/deep-nn/benchmarks/deep_learning.py`（`zama-ai/concrete-ml`）  
> 文档入口：`docs/gpu_csd_e2e.md` 的 5.8  
> 目标：用 **GPU‑nvmevirt 项目链路（0xC0→backend→gpu_runtime_service）** 来执行 TFHE 计算，并对 deep‑nn 做可回归的正确性/性能验证。

## 0. 背景与现状（必须先对齐）

### 0.1 deep‑nn 的真实执行点
- deep‑nn 脚本调用 FHE 的核心路径是：
  - `quantized_module.quantized_forward(..., fhe="execute")`
  - 它默认走 Concrete 的 execution runtime（Python/本地库），**不走 nvmevirt/0xC0**。

### 0.2 当前已打通的“接入钩子”（但不是端到端替换）
- 已实现：deep‑nn 运行过程中会 **额外触发一次** FunctionEval softmax offload，用于证明“workload 可以调用我们链路并留证”。
  - wrapper：`scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh`
  - offload helper：`../nvmevirt/tools/csd_softmax_offload.py`
  - deep‑nn hook：`~/workspace/deep-nn/benchmarks/deep_learning.py`（仅触发一次，且不影响 deep‑nn 原本 accuracy/MAE 逻辑）
- 注意：offload backend 默认按 `NO_SUDO` 自动选择：`NO_SUDO=1` 走 IPC；`NO_SUDO=0` 走 nvmevirt/0xC0 e2e（需提前 `sudo -v`，并把 `BACKEND_LOG/DMESG_OUT` 落到本次 `OUT_DIR`）。
- 重要认知：当前 offload hook 使用的是**本项目的 keyset/参数体系**（`tmp_assets/wop_keyset.bin`），而 deep‑nn 的 FHE 主计算仍由 Concrete runtime 生成/持有自己的 keyset（现已通过 gpu_runtime_service 的 runner 执行）；两者未自动对齐，`deepnn_run_summary.txt` 的 `param_alignment_hint` 会明确提示。
  - 目前已观测到的“硬性不对齐点”不仅是 `polynomial_size=4096` 缺失，还包括：
    - deep‑nn PBS `input_lwe_dimension` 约为 `771/772/813`，而本项目 keyset 固定 `n_lvl0=500`；
    - deep‑nn PBS `glwe_dimension` 同时出现 `1` 与 `2`，而本项目执行器/基线默认 `glwe_dimension=1(K=1)`（keyset header 本身也不编码 K）。
  - 结论：仅“把 keyset 覆盖到 4096”并不足以让 deep‑nn 主 FHE 推理迁移到本链路；要推进到 L2，需要明确并实现“参数体系对齐/转换/重编译”的方案。

### 0.3 “用我的架构做 TFHE 计算” 的判定（分阶段验收）
为了避免“跑了但其实没用我们的 TFHE 引擎”，本方案采用分阶段 stop condition：

- **L0（链路取证）**：deep‑nn 运行时至少触发一次 **nvmevirt/0xC0**，并在证据日志中看到 `CSD: op=0xc0 ...`。
- **L1（算子正确性）**：至少 1 个“deep‑nn 实际会用到的 TFHE 原语”（PBS/KS/激活 LUT 等）由 nvmevirt+GPU 链路执行，并有明确 golden/容差判据。
- **L2（端到端正确性）**：deep‑nn 的 FHE 推理主计算由我们的链路执行（不再依赖 Concrete execution runtime），并有端到端对照（clear/CPU golden）。
- **L3（性能评测可回归）**：固定 keyset/cache/staging 策略下，输出稳定的 latency/bytes/分段耗时报表，可回归对比。

> 本文的 M0→M3 目标是先把 L0/L1/L3 做扎实，M4→M6 才是 L2 端到端替换的关键阶段。

### 0.4 16-bit 可行性现状（结论先行）
- Concrete‑ML n_bits=16 在当前安全参数下仍无法选到可用参数（多次 `NoParametersFound`），因此 deep‑nn 主线仍以 32bit + 输入量化为基线。
- WOPBS 物理 16bit 固定点（`WOPBS_FP_TOTAL_BITS=16`）已闭环到 FunctionEval/softmax：bigLUT + spqlios FFT guard 稳定，softmax 校验使用参考值 2^-10 floor 量化以保持默认阈值。
- **当前基线**：保持 32bit 固定点 + 输入量化（`WOP_GPU_FP_QUANT_BITS=16 WOP_GPU_FP_QUANT_INT_BITS=6`）；16bit 物理路径作为已验证能力，不再作为额外待办。
- **no‑fallback 约束**：`CSD_NO_FALLBACK=1` 下允许 `WOPBS_FP_TOTAL_BITS=16`（仍强制 FFT、禁止 BR no‑FFT）。

### 0.5 PBS hotspot 最新取证（M2 前置）
- 2026-01-30：deep‑nn PBS hotspot（poly2048 profile）在 nvmevirt e2e 下通过，`WOP_GPU_WOKS_DEBUG=1 NO_SUDO=0` 时 `gpu_runtime_service.log` 含 `[WOKS_DEBUG] mismatch=0/2048`，`e2e.log` 含 `GLWE matches golden`，产物目录：`/tmp/csd_gpu_nvmevirt_deepnn_pbs_hotspot_20260130_213858/`。

## 1. 目标与停止条件（Stop Condition）

### 1.1 正确性（必达）
- **M0**：deep‑nn 的 offload 调用走 nvmevirt e2e（`NO_SUDO=0`），证据满足：
  - `OUT_DIR/run.log`：出现 `[CSD_DEEPNN] ... offload ok`
  - `OUT_DIR/dmesg_new.log` 或 nvmevirt 内核日志：出现 `CSD: op=0xc0 mode=3 ...`
  - `OUT_DIR/backend.log`：出现 `func_stage cmd=...`（backend staged 软路径）或 `metrics cmd=...`
- **M1**：产出 deep‑nn 的 TFHE 图谱画像（PBS/KS 计数、bitwidth、IO bytes、关键 tag）。
- **M2**：至少 1 个 deep‑nn FHE 图中真实热点算子（优先 ReLU/比较类 PBS 或 bit‑extract/KS）由我们链路执行，并有对照判据（bit‑exact 或容差）。
- **M4**：deep‑nn 的 FHE 主计算通过 nvmevirt/0xC0 路径执行，并打出 L2 标记与一致性证据：
  - `OUT_DIR/run.log`：出现 `[CSD_DEEPNN][L2]` 与 `fhe compare ok`
  - `OUT_DIR/backend.log`：出现 `metrics cmd=...`
  - `OUT_DIR/dmesg_new.log`：出现 `CSD: op=0xc0 ...`

### 1.2 性能（必达）
- **M3**：输出“可回归”的性能报告（同一机器同一 keyset 下，重复 5 次方差可控），至少包括：
  - e2e：每次推理/每次样本 latency
  - backend：`metrics cmd=...`（bytes/latency）+ split 分段耗时（ks_ns/gpu_bootstrap_ns/extract_ns…）
  - GPU：`gpu_runtime_service.log` 的关键阶段耗时（若启用相应 metrics）

## 2. 里程碑计划（M0→M3）

### M0：把 deep‑nn offload 从 IPC 升级为 nvmevirt/0xC0 e2e（L0）

**目标**：deep‑nn 运行过程中触发一次 0xC0（mode=3 FunctionEval），并能在 nvmevirt 侧留 “CSD: op=0xc0 …” 证据。

**实现要点**
- 在 `../nvmevirt/tools/csd_softmax_offload.py` 增加 `backend=nvmevirt` 路径：
  - 生成 fp64 输入文件（N*8B）
  - 调用 `../nvmevirt/tools/csd_e2e_smoke.sh`，设置：
    - `ENGINE=gpu MODE=3 FLAGS=0x10`
    - `TLWE_WORDS=N GLWE_WORDS=N TLWE_FILE=<fp64.bin> OUT_GLWE=<out.bin>`
    - `CSD_USE_PRP=0/1`（建议先 `0` 走 `/dev/mem` staging，易取证）
    - `BACKEND_LOG="$OUT_DIR/backend.log" DMESG_OUT="$OUT_DIR/dmesg_new.log"`（把 0xC0/后端证据落盘到本次 OUT_DIR）
    - 可选：`GPU_SERVICE_LOG="$OUT_DIR/gpu_runtime_service.log"`（如果本次 run 没有预先拉起 gpu_runtime_service）
  - 解析输出 fp64，并对 trivial softmax 做容差校验（复用 `tools/softmax_fp64.py` 的阈值策略）
- deep‑nn hook 不变：仍只触发一次，避免把宏观推理时间变成“软/硬件复位开销”。

**证据关键词（最短路径）**
- `rg -n "CSD: op=0xc0|mode=3|func_stage|metrics cmd=" "$OUT_DIR"/{dmesg_new.log,backend.log}*`
- 一键入口（M0+M2+M3）：`scripts/csd_gpu_nvmevirt_macro_deepnn_fullflow_oneclick.sh`（默认 `NO_SUDO=0`，需提前 `sudo -v`；默认 M0 走 FHE nvmevirt；可用 `RUN_FHE_NVMEVIRT=0` 跳过 FHE；`RUN_HOTSPOT=0` 跳过 M2；`RUN_DUMP_RAW=1` 同步开 raw dump+uncompressed）。

**已知坑（M0 必须规避）**
- `mode` 只有 2 bit：必须用 `mode=3 + flags/op` 扩展，不要试图从 0xC0 直接发 mode=4。
- `/dev/mem` staging：TLWE/GLWE 必须在 storage window（避免 memmap 前 1MB 的 BAR/doorbell 区）。
- **spqlios FFT 环境变量**：FunctionEval softmax 的 `exp_minus` 依赖 spqlios FFT 表；长跑前确保
  `TFHE_GPU_SPQLIOS_FFT=1 TFHE_GPU_SPQLIOS_IFFT=1` 且 `TFHE_GPU_SPQLIOS_{FFT,IFFT}_TABLE` 指向有效表文件（默认 `/tmp/spqlios_*_table.n4096.bin`）。
  `scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh` 已默认开启并在表缺失时生成。
- 冷启动抖动：需要 `CSD_KEEP_SESSION=1` + `CSD_KEEP_BACKEND=1`（宏观跑法必须复用 key mmap/caches）。
- `sudo` 口令：`NO_SUDO=0` 场景下 deep‑nn 运行中不能交互输密码；长跑前先 `sudo -v`，否则 offload 可能卡住/无证据落盘。

### M1：做 deep‑nn TFHE 图谱画像（定位“真实热点”）

**目标**：回答 3 个问题：`用了多少 PBS/KS？数据量多少？最大 bitwidth 是多少？`

**实现要点**
- 在 deep‑nn side 增加“画像输出”（默认落盘到 `OUT_DIR/deepnn_profile.json`）：
  - `programmable_bootstrap_count*`
  - `key_switch_count*`
  - `maximum_integer_bit_width`
  - `size_of_inputs/outputs/keys`
  - `graph.tag_counts` / `graph.operation_counts`（用于把“热点”从拍脑袋变成可解释的节点维度）
- 画像输出开关（wrapper 默认开启）：
  - `CSD_DEEPNN_PROFILE=1`
  - `CSD_DEEPNN_PROFILE_OUT=$OUT_DIR/deepnn_profile.json`
- 注意：Concrete‑ML 的图默认可能 **没有 tag**，导致 `*_count_per_tag` 为空；因此 M1 基线先用 `*_count_per_parameter` 做热点判定。
- 固化运行参数（seed/n_bits/p_error/模型结构），确保 profile 可复现。

**输出物**
- `OUT_DIR/deepnn_profile.json`：profile 记录（list），便于多次运行累计。
- 一键摘要：`python3 tools/csd_deepnn_profile_summary.py "$OUT_DIR/deepnn_profile.json"`（输出 PBS/KS 计数 + top 参数组）。

### M2：把 deep‑nn 的“真实 TFHE 热点算子”接到我们的链路（L1→L2 的关键）

**原则**：按 `docs/storyline.md` 的 PBS 微流程边界推进（GPU 做 BR/FFT-heavy，CSD/后端做 SampleExtract/KeySwitch/pack），不要按函数级步骤名拍脑袋拆。

**推荐优先级（从易到难）**
1) **激活/比较类 PBS（类似 ReLU/clip/max）**：如果 deep‑nn 图里 PBS 主要来自激活（常见），优先做 “LUT eval” 的通用接口（可先只支持少量 LUT id）。
2) **bit‑extract/KeySwitch**：若 deep‑nn 图里 KS 密集，则复用现有 BE split、VP split 的下沉经验（mode=1/mode=0 的 flags=0x08）。
3) **KSPBS split**：复用 `../nvmevirt/tools/csd_kspbs_split_engine.py` 的 split 引擎，把 “KeySwitch+SampleExtract” 放在后端，GPU 做 bootstrap-only，并保留 bit‑exact validate 开关。

**关键难点（需要提前写清楚）**
- Concrete‑ML/Concrete 的 ciphertext/key 参数体系与本项目的 keyset/协议不天然一致：要实现 L2（端到端替换），必须明确：
  - 是“对齐我们的 TFHE baseline（cpu_reference_runner）”还是“对齐 Concrete FHE runtime”
  - keyset 与 LUT 的生成/导入策略（避免出现“跑了但不是同一套密码学参数”的伪正确）

> 结论：M2 的第一步先做“算子级正确性 + 可取证”，再逐步扩大覆盖面。

### M3：建立 macrobenchmark 正确性/性能评测矩阵（L3）

**目标**：形成“一键跑 + 一键出报告”的回归入口，并能解释性能变化来自哪里（IO/KS/PBS）。

**跑法建议**
- 先 `NO_SUDO=1`（IPC）做 correctness/sanity（快速迭代）
- 再 `NO_SUDO=0`（nvmevirt e2e）做真实链路性能（取证完整）
- 每次跑固定：
  - keyset：`KEYSET=...`（同一份）
  - cache：`CSD_KEEP_SESSION=1 CSD_KEEP_BACKEND=1`
  - split：只在专门用例里开（避免全局 env 导致 softmax/其它阶段超时）
    - deep‑nn 的 softmax offload 可选开关：`CSD_DEEPNN_OFFLOAD_SOFTMAX_KSPBS_SPLIT=1`（默认 `WOP_GPU_KSPBS_SPLIT_LUTS=10,11`）
      - 现状实测：N=16（pad_to=16）时，lut10/11 split 反而更慢，先作为“打点/取证开关”保留，macrobenchmark 默认不推荐开启。

**报告输出**
- `OUT_DIR/metrics_summary.txt`：摘要（latency/bytes/分段耗时）
- `OUT_DIR/run.log`：deep‑nn 侧输出（含 `[CSD_DEEPNN]`）
- `OUT_DIR/backend.log` / `OUT_DIR/gpu_runtime_service.log` / `OUT_DIR/dmesg_new.log`：链路证据
- `OUT_DIR/deepnn_run_summary.txt`：自动聚合 progress.json + profile top 参数组 + `keyset_meta` + `param_alignment_hint`（适合作为 M3 回归对比基线）
- `OUT_DIR/deepnn_fhe_contract.json`：由 `concrete_fhe_meta_cmd*.json` 生成的参数合同（输入/输出 LWE 维度、压缩方式、最小 keyset 约束 + 可用变体推荐；含 `assumptions` 说明映射假设），用于执行器替换时对齐参数
- 扫描脚本：`REPEATS=5 NO_SUDO=1 bash scripts/csd_gpu_nvmevirt_macro_deepnn_sweep.sh`
  - 产物：`OUT_PARENT/sweep_summary.csv` + `OUT_PARENT/sweep_stats.txt`
  - 已有 OUT_PARENT 只做汇总：`python3 tools/csd_deepnn_sweep_summary.py --out-parent <OUT_PARENT>`

### M4：参数体系对齐 + 多变体 keyset 路由（L2 基础）

**目标**：deep‑nn 运行所需的 TFHE 参数可被我们的 keyset/GPU service 覆盖，并且能在运行时自动选择匹配变体。

**实现要点**
- 从 `deepnn_profile.json`/`server.zip` 提取参数族：`polynomial_size`、`input_lwe_dimension`、`glwe_dimension`。
- 构建多变体 keyset（至少覆盖 `n0=771/772/813`、`poly=1024/2048/4096`、`K=1/2`），并在 keyset 元数据里写入 `K` 与 `poly`。
  - `scripts/csd_gpu_deepnn_concrete_align_oneclick.sh` 支持 `CSD_DEEPNN_CONCRETE_ALIGN_FORCE_MATRIX=1` 强制覆盖固定矩阵；
    可用 `CSD_DEEPNN_CONCRETE_ALIGN_MATRIX_{N0S,POLYS,KS}` 覆盖默认列表。
- `gpu_runtime_service` 支持按变体 id/参数自动选择 keyset（避免固定 `tmp_assets/wop_keyset.bin`）。
- nvmevirt 后端在收到 Concrete 请求时优先“按参数挑 keyset”，不再只靠环境变量手动指派。
- 一键入口（M4→M6）：`scripts/csd_gpu_nvmevirt_macro_deepnn_l2_oneclick.sh`。

**证据**
- `deepnn_run_summary.txt`：`concrete_contract` 中 `variant_ok=True`，且 `variant_allowed_lwe_dimensions` 覆盖输入/输出 LWE 维度（允许 `{n_lvl0, n_lvl1*(K+1), n_lvl2*(K+1)}` 的映射假设）。
- `deepnn_run_summary.txt`：`param_alignment_hint_variants fully_compatible=True`（仍保留为粗粒度提示）。
- `gpu_runtime_service.log`：打印 keyset 参数与变体标识（`WOP_GPU_VARIANT_NAME/ID` + `n_lvl0/n_lvl1/n_lvl2/K`）。

### M5：Concrete 运行时替换/执行器接入（L2 端到端）

**目标**：deep‑nn 的 FHE 主计算通过 nvmevirt/0xC0 → backend → gpu_runtime_service 执行，并在日志中打出 L2 标记。

**实现要点**
- deep‑nn 侧通过环境变量切换执行后端（`CSD_DEEPNN_FHE_NVMEVIRT=1` + `CSD_DEEPNN_FHE_BACKEND=nvmevirt`）。
- 执行器默认使用 `CSD_DEEPNN_FHE_EXECUTOR=gpu_service`（nvmevirt 默认），backend 会把 Concrete payload 转交给 gpu_runtime_service 的 FunctionEval(op=0x09)。
- gpu_runtime_service 通过 `WOP_GPU_CONCRETE_RUNNER`/`WOP_GPU_CONCRETE_PYTHON` 调用 Concrete runner（默认脚本：`tools/csd_concrete_fhe_runner.py`）。
- 通过 `CSD_DEEPNN_FHE_MARK_L2=1` 输出 `[CSD_DEEPNN][L2]` 标记，明确本次 FHE 走 nvmevirt 路径。
- 如需 raw‑dump 校验，启用 `CSD_DEEPNN_CONCRETE_DUMP_RAW=1` + `CSD_DEEPNN_FHE_UNCOMPRESSED=1`（仅限 `compression=none`）。
  - 运行后用 `scripts/csd_gpu_nvmevirt_deepnn_raw_dump_check.sh --out-dir <OUT_DIR>` 校验 raw dump 与 payload 解包一致性。

**证据**
- `OUT_DIR/run.log`：出现 L2 明确标记（`[CSD_DEEPNN][L2] fhe_execute_backend=nvmevirt executor=gpu_runtime_service`）。
- `OUT_DIR/backend.log`：出现 `concrete_exec=gpu_service` 与关键 metrics。
- `OUT_DIR/gpu_runtime_service.log`：出现 `[TFHE_GPU_EXEC][FUNC_CONCRETE]`。
  - 若启用 `CSD_DEEPNN_FHE_SEPARATE_LOGS=1`，证据改看 `backend_fhe.log`/`dmesg_fhe.log`（避免 softmax nvmevirt 复写）。
- `concrete_fhe_meta_cmd*.json`：记录 circuit/inputs/outputs 与选用变体信息，便于后续替换执行器时对齐参数。
- 取证（2026-01-19，fullflow + raw dump）：`/tmp/csd_gpu_nvmevirt_macro_deepnn_fullflow_20260119_131600/`（`m0_nvmevirt/run.log` 含 `fhe offload ok: backend=nvmevirt executor=gpu_service device=cuda`；`driver.log` 含 `raw dump check passed`；`m0_nvmevirt` 含 `concrete_raw_input_cmd8704_idx0.bin`/`concrete_raw_output_cmd8704_idx0.bin`）。

### M6：L2 端到端正确性与回归

**目标**：端到端 FHE 预测结果在 IPC（Concrete baseline）与 nvmevirt（gpu_runtime_service）两条路径上一致（至少在小样本上稳定一致）。

**实现要点**
- 启用 `CSD_DEEPNN_FHE_COMPARE_BACKENDS=1` 对比 IPC vs nvmevirt（可用 `CSD_DEEPNN_FHE_COMPARE_STRICT=1` 强制一致）。
- 固定 keyset/cache（`CSD_KEEP_SESSION=1 CSD_KEEP_BACKEND=1`）以去除冷启动噪声。

**证据**
- `run.log`：出现 `[CSD_DEEPNN][L2] fhe compare ok`。
- `progress.json`：包含 `csd-fhe-compare-mae` 与 `csd-fhe-compare-argmax-match`。
- `deepnn_fhe_contract.json`：脚本会打印 `[contract] status=ok ...`（默认严格检查）。
- 取证（2026-01-28）：`/tmp/csd_gpu_nvmevirt_macro_deepnn_l2_20260128_124125/`（`m5_m6_run/run.log` 含 `[CSD_DEEPNN][L2] fhe compare ok` 与 `device=cuda`；`m5_m6_run/backend_fhe.log` 含 `metrics cmd=49921 ... concrete_exec=gpu_service`；`m5_m6_run/dmesg_fhe.log` 含 `CSD: op=0xc0 mode=3 flags=0x24`）。

## 3. 统一取证口径（建议固化为脚本）

推荐过滤关键词（优先级从高到低）：
- nvmevirt/0xC0：`CSD: op=0xc0|doorbell cmd_id=|status poll timeout`
- backend：`func_stage|metrics cmd=|golden_mismatch|RuntimeError|TimeoutError`
- GPU：`\\[TFHE_GPU_EXEC\\]\\[REQ\\]|\\[KSPBS_SPLIT\\]|\\[FUNC_METRICS\\]`

## 4. 已知坑清单（deep‑nn + nvmevirt + GPU）
- deep‑nn 预训练权重可能是 git‑lfs 指针：`torch.load ... invalid load key, 'v'`（先训练生成或 `git lfs pull`）。
- nvmevirt `mode` 只有 2 bit：扩展一律走 `mode=3 + flags/op`。
- `/dev/mem` 权限与 bounce buffer：如果 glwe_addr 落 System RAM，在严格 devmem 下会 `Operation not permitted`；必须把 bounce stripes 放在 memmap storage window。
- 冷启动（keyset 3GiB）导致抖动：必须 keep session/backend，宏观测量要剥离冷启动。
- GPU OOM：worker 数过多会被系统 kill（长跑需限制 workers，或复用服务进程）。
- 全局开启 split 可能导致阶段超时：split env 仅在专门用例启用，避免污染 macrobenchmark。

## 5. 参数覆盖到 4096（当前推荐做法）

> 背景：deep‑nn profile 已观测到 `BootstrapKeyParam(polynomial_size=4096, ...)`；如果后续要把真实热点算子迁移到本项目 TFHE baseline，必须先能“构建/生成 keyset/跑通 mode=3”的 4096 参数变体。

- 一键构建 4096 变体（独立 build dir，不影响现有 build-clean 回归）：
  - `bash scripts/csd_gpu_build_tfhe_deepnn_4096.sh`
  - 产物：`sw/gpu_runtime_service/build-deepnn4096/gpu_runtime_service` 与 `tmp_assets/wop_keyset_deepnn4096.bin`
- macrobenchmark 选择 4096 变体（仅影响 offload hook 的 service/keyset，不会自动替换 deep‑nn 主推理）：
  - `CSD_DEEPNN_TFHE_VARIANT=deepnn4096 NO_SUDO=0 GPU_TIMEOUT=240 bash scripts/csd_gpu_nvmevirt_macro_deepnn_oneclick.sh`
