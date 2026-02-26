# GPU‑CSD 算子边界合同（M2）

> Last update: 2025-12-30  
> 目的：把“GPU 只做盲旋/FFT-heavy，CSD 做低开销算子”的分工边界写成可执行的接口合同（草案），作为后续 M3 逐步迁移的蓝图。

## 1) 背景与现状

- 总入口与当前 e2e 现状：`docs/gpu_csd_e2e.md`
- 目标算子放置（StoryLine）：`docs/storyline.md`

当前 nvmevirt e2e 的实现形态仍是：**CSD/nvmevirt 负责控制与搬运，GPU runtime service 负责把整段 pipeline 一口气算完**。  
本文件定义的是下一阶段“细粒度分工”的接口合同，不要求立刻落地所有代码。

## 2) 目标分工边界（对齐 StoryLine）

### 2.1 CSD/Host 后端侧（低开销算子 + 控制）

原则：计算轻、但带宽敏感/需要靠近数据面的环节优先放 CSD。

- ModSwitch / Preprocess（含 preModSwitch）
- SampleExtract（GLWE → LWE_{kN}）
- KeySwitch（大维度 → 小维度）
- Assemble / Pack（小数据拼装、输出布局）
- Descriptor 队列、memmap/PRP staging、doorbell/status

### 2.2 GPU 侧（BR/FFT-heavy 核心）

原则：计算重、FFT/外积/盲旋相关的环节集中放 GPU。

- Blind Rotation（盲旋）/ CMux loop
- FFT / iFFT（含外积核心：PointwiseMul + Accumulate）

> 解释：这对应 `docs/storyline.md` 中 “CMux / BlindRotate loop + FFT-heavy” 的行，目标是减少密钥/中间态在 CSD↔GPU 间往返的次数。

## 3) 数据尺寸与字节合同（以当前参数为准）

以当前 tfhe baseline 的 `Context` 常量为准（`../tfhe-gpu-baseline-wopbs/src/tfhe_types.h`）：

- `n_lvl0=500` → LWE 词数 `n_lvl0+1=501`
- `n_lvl1=1024` → LWE/TLWE 词数 `n_lvl1+1=1025`
- `n_lvl2=2048` → LWE 词数 `n_lvl2+1=2049`

字节合同（适用于 nvmevirt e2e 与未来 CSD 侧实现）：

- payload 为 little-endian 定长“word”数组
- `word_bytes = tlwe_bytes / tlwe_words`（以及 `glwe_bytes / glwe_words`）必须是整数
- 当前 e2e 推荐统一 `word_bytes=8`（torus64）；若要让 CSD 侧直接喂 preModSwitch，可使用 `word_bytes=4`（int32）
- 地址对齐：建议 `8B` 对齐（至少满足 `/dev/mem` 读写与 DMA 对齐习惯）

## 4) GPU 加速接口合同（草案）

> 目标：把 GPU runtime service 从“整段 pipeline”收敛成“只提供 BR/FFT-heavy 的加速服务”。  
> 约束：nvmevirt 的 vendor 0xC0 `mode` 只有 2 bit（0..3），因此“细粒度子算子”建议通过 `flags` 扩展语义。

### 4.1 关键开关：step5_only / step4_only / premod_in

- `flags[7] (0x80) = step5_only`：语义沿用 RTL（只跑 Step5，跳过前级）。现有实现已使用该位。
- `flags[6] (0x40) = step4_only`：只跑 Step4=Blind Rotation/WoKS，跳过 Step5=PrivKS。
  - 实现状态：`gpu_runtime_service` 已支持该 flag（CB 模式下跳过 privks），本地冒烟可用 `GPU_SMOKE_FLAGS=0x40 sw/gpu_runtime_service/build-clean/gpu_executor_smoke CB`。
- `flags[5] (0x20) = premod_in`：输入 payload 已是 preModSwitch/normalize 的 `int32` 数组（`word_bytes=4`），GPU 侧跳过 `normalize_pre_modswitch()`。
  - 实现状态：nvmevirt 后端已支持在 `mode=2(CB)` 下预处理并向 GPU 发送 premod(i32)；回归脚本：`scripts/csd_gpu_nvmevirt_cb_step4only_premod_oneclick.sh`。
- `flags[3] (0x08) = backend_split`：后端编排拆分微流程（backend-only trigger，不透传给 GPU），语义随 `mode`：
  - `mode=0(VP)`：VP KeySwitch 下沉（GPU biglut-only → 后端 KeySwitch_lv10 + premod → GPU WoKS）
  - `mode=1(BE)`：BE KeySwitch 下沉（GPU bit_extract-only → 后端 KeySwitch_lv10(gpbs) + premod → GPU WoKS）
  - `mode=3(FunctionEval)`：KSPBS micro‑flow split（见 4.5）

这样可以把 “Step4-heavy” 固定留在 GPU，“Step5-light” 迁回 CSD，从而逐步逼近 `docs/storyline.md` 的分工。

### 4.2 操作定义：CB_WOKS_STEP4_ONLY（GPU 仅盲旋/FFT-heavy）

调用方式（建议复用现有通道）：

- 载体：`gpu_runtime_service` 的 IPC `SubmitRequest`（`sw/gpu_runtime_service/include/gpu_runtime/ipc.hpp`）
- `descriptor.mode = 2 (CircuitBootstrap)`
- `descriptor.flags` 设置 `step4_only=1`，并保证 `step5_only=0`

输入 payload（两种形态，建议优先 B）：

- A) raw LWE（最小改动，先跑通）：`tlwe_words = n_lvl0+1 = 501`，`word_bytes=8`  
  GPU service 内部仍会做 preModSwitch（逻辑在 CPU 侧，计算轻但会占用 host 时间）。
- B) preModSwitch（符合目标分工）：`tlwe_words = n_lvl0+1 = 501`，`word_bytes=4`（int32）  
  由 CSD/后端先做 ModSwitch/Preprocess，然后把 premod 直接送 GPU，减少重复计算与 host 参与度。
  - 实现状态：已落地（`flags[5]=0x20(premod_in)`），见：`scripts/csd_gpu_nvmevirt_cb_step4only_premod_oneclick.sh`。

输出 payload：

- `glwe_words = n_lvl2+1 = 2049`（torus64）
- 含义：Blind Rotation / WoKS 的结果（Step4 输出），用于后续 Step5（PrivKS）。

密钥与驻留要求：

- GPU 侧必须常驻/缓存 Bootstrapping Key 的 FFT 形式（如 `bkFFT_64`/`bkFFT_32`），避免每次调用搬运巨量密钥。
- Step5 所需的 KeySwitch Key（KSK / privks）不再要求 GPU 持有，迁移到 CSD/后端侧。

错误码约定（建议）：

- `status_code=0`：成功
- `status_code!=0`：失败，`error_code` 细分原因（参数非法/长度不匹配/密钥未加载/内部 CUDA 错误）

### 4.3 操作定义：STEP5_ON_CSD（CSD 侧执行 SampleExtract + KeySwitch）

本阶段不要求立刻“RTL 落地”，但合同需要固定输入/输出形态：

- 输入：Step4 输出（`n_lvl2+1=2049` torus64）
- 输出：PrivKS 结果（当前模拟输出 TLweSample32 的 `u=0` 平面，按 `(k+1)*n_lvl1=2048` 词展平；word_bytes=8 时零扩展 torus32）
- 建议：`glwe_words=2048`（避免额外补零；若仍为 2049，后端会在末尾补 0）
- 校验：与 CPU baseline 的 bit-exact golden 对齐（先在 nvmevirt 后端跑通，再下沉 RTL）

现有软件入口（M6，推荐）：
- Step5 模块：`../nvmevirt/tools/csd_privks_step4.py`（mmap `wop_keyset.bin` 的 privKS section + numpy 计算 `circuitPrivKS(u=0)`，与 CPU baseline bit‑exact）
- 后端集成点：`../nvmevirt/tools/csd_sw_backend.py`
- 选择实现：`CSD_PRIVKS_IMPL=numpy|cpu_runner`（`../nvmevirt/tools/csd_e2e_smoke.sh` 会在 sudo 场景下透传到后端）
- 备注：当 `mode=2` 且 `step4_only=1` 时，nvmevirt 后端会强制向 GPU 请求 Step4 的完整 `(n_lvl2+1)=2049` words 输出，再生成 Step5 输出并按 `descriptor.glwe_words` 写回（不足自动补 0）。

历史 fallback（保留）：
- 后端调用 `cpu_reference_runner --privks-step4`（`sw/gpu_runtime_service/build-clean/cpu_reference_runner`），用于兜底/对照验证。

### 4.4 FunctionEval(mode=3) 分阶段接口（M7：softmax）

目的：让 softmax/FunctionEval 也走“分阶段发令”的接口形态，先把 **控制面拆分 + session 协议 + 取证打点** 做出来。

注意：这里的 `INIT/MAX/SHIFT/EXP_MINUS/SUM/DIV/...` 是 softmax 的函数级步骤名，不等价于“轻算子”。在当前 fixed‑point 实现里，MAX/SHIFT/SUM/DIV 仍可能触发 PBS primitive（例如 KSPBS），因此后续真实的“GPU 只做 BR/FFT-heavy，CSD 做低开销”拆分，应以 PBS 微流程边界（Step4/Step5、SampleExtract/KeySwitch vs BR/FFT-heavy）为准。

实现定位（softmax 的 PBS primitive 在哪里）：
- `MAX`：`fp_max_assign_ip()` 内部多次调用 `TLwe32KSPBS_batch_lvl1`（`get_sign/sign_comb/mux_ano_0`），见 `../tfhe-gpu-baseline-wopbs/src/fp_op/max.cu:38`。
- `SHIFT`：`fp_sub_rev_assign_ip()` 自身是线性核，但会触发 `carry_propagation_full()`；carry 的实现里包含多次 `TLwe32KSPBS_batch_lvl1`（`get_hi/get_lo/block_state/lshift/rshift/...`），见 `../tfhe-gpu-baseline-wopbs/src/fp_op/sub.cu:6`、`../tfhe-gpu-baseline-wopbs/src/fp_op/carry_prop.cu:178`。
- `SUM`：`fp_add_assign_ip()` 同样触发 carry propagation，内部包含 `TLwe32KSPBS_batch_lvl1`，见 `../tfhe-gpu-baseline-wopbs/src/fp_op/add.cu:5`、`../tfhe-gpu-baseline-wopbs/src/fp_op/carry_prop.cu:178`。
- `EXP_MINUS`：`fp_exp_minus_ip()` 包含 `bit_extract_ip` + `biglut_batch_20bit_ip`，并额外调用 `TLwe32KSPBS_batch_lvl1`（`logical_or/mux_1` 等），见 `../tfhe-gpu-baseline-wopbs/src/fp_op/exp_minus.cu:50`。
- `DIV`：`fp_div_u_l1_assign_ip()` 内部包含 `TLwe32KSPBS_batch_lvl1`（条件选择/约束收敛，使用 `mux_ano_1` 等 LUT），见 `../tfhe-gpu-baseline-wopbs/src/fp_op/div.cu:95`。

- 触发（nvmevirt e2e）：`descriptor.mode=3` 且 `descriptor.flags & 0x10 != 0`（该位仅用于 nvmevirt→后端触发，不透传给 GPU）。
- 后端编排：`../nvmevirt/tools/csd_sw_backend.py` 会把 softmax 拆成 `INIT/MAX/SHIFT/EXP_MINUS/SUM/DIV/EXPORT/CLEAR` 并逐阶段调用 `gpu_runtime_service`。
- GPU service staged 合同（当前实现约定）：
  - `session_id`：复用 `descriptor.status_addr` 传递（后端写入稳定的 64-bit id）。
  - `func_op`：通过 `flags[7:2]` 编码（等价 `func_op = flags >> 2`），并保持 `flags[1:0]=0`，避免与 nvmevirt `mode` 低 2 bit 语义混淆。
  - payload：除 `INIT` 外，中间 op 会发 `tlwe_bytes=0` 且 TLWE payload 为空；gpu_runtime_service 必须接受并基于 session 状态执行。
- 验收：`NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_softmax_oneclick.sh` 末尾 `fail=0`，并且 `OUT_DIR/backend.log` 含 `func_stage ...` 与 `metrics ... func_split_total_ns=...`。

### 4.5 PBS primitive 微流程拆分（M8：KSPBS split）

目的：把“轻/重”边界从函数级步骤名拉回到 PBS primitive 的真实微流程，验证 **KeySwitch/SampleExtract 可下沉到 CSD/后端侧**，GPU 只保留 BlindRotate/FFT-heavy 的 bootstrap。

KSPBS（KeySwitch + Programmable Bootstrapping + SampleExtract）可拆为：
- CSD/后端侧：`KeySwitch_lv10` + `SampleExtract`
- GPU 侧：bootstrap-only（BlindRotate + FFT-heavy）

当前实现形态（调试/取证版，不走 nvmevirt）：
- nvmevirt 侧触发（复用现有 2-bit mode）：
  - `mode=3(FunctionEval)` + `flags[3]=0x08(backend_split)`：后端执行 KSPBS split（backend-only trigger，不透传给 GPU）
  - 一键入口：`bash scripts/csd_gpu_nvmevirt_kspbs_split_oneclick.sh`
- GPU runtime service（实际执行点）：新增 `mode=4(PBS primitive)`（由后端直连 socket 调用）
  - `flags=1`：KSPBS bootstrap-only（输入 lvl0 LWE，输出 TLWE accumulator，展平为 `(k+1)*n_lvl1` torus32 words）
  - `flags=2`：KSPBS full（用于对照：输入 lvl1 LWE，输出 lvl1 LWE）
  - `flags=3`：KSPBS full（per-sample LUT；用于对齐 `TLwe32KSPBS_batch_lvl1<1>` 这类“每个 sample LUT 不同”的场景）
    - TLWE payload：`batch*(n_lvl1+1)*word_bytes + batch*1B(lut_id[])`（lut_id 紧贴在 payload 尾部）
- 后端侧 per-sample LUT micro-flow split（不改 GPU service 的最短路径）：
  - 思路：后端先对全 batch 做 KeySwitch，然后按 `lut_id` 分组多次调用 `flags=1` 的 bootstrap-only；Extract 后按原顺序拼回输出。
  - 验收/取证：`bash scripts/csd_gpu_kspbs_split_backend_smoke.sh` 的 `3.6/4` 步骤会把该 split 输出与 GPU `flags=3` golden 做 bit-exact 对照。
- nvmevirt e2e（per-sample LUT + batch）一键入口：`bash scripts/csd_gpu_nvmevirt_kspbs_split_per_sample_oneclick.sh`
  - 后端参数：通过 `gpu_shared_addr`（cdw13/cdw14）传递
    - `[24] per_sample_lut = 1`
    - `[23:8] torus_size`（0 视作 32）
    - `[7:0] lut_id`（per-sample 模式下可忽略）
  - payload 要求：TLWE buffer 末尾追加 `batch` 个字节的 `lut_id[]`，因此 staging 侧需要写入 `TLWE_STAGE_BYTES = tlwe_words*8 + batch`。
  - 注意：当前 PRP path 默认只搬运 `tlwe_words*8`，会丢 tail；因此 per-sample LUT 推荐 `CSD_USE_PRP=0`（脚本默认已设置）。
- 后端软件模块：`../nvmevirt/tools/csd_kspbs_split_engine.py`（可复用 split 引擎）；CLI smoke 工具：`../nvmevirt/tools/csd_kspbs_split.py`
- 一键 smoke（无 sudo）：`bash scripts/csd_gpu_kspbs_split_backend_smoke.sh`
  - 验收：打印 `[PASS] KSPBS split matches GPU monolithic`，并在 `OUT_DIR/kspbs_split/kspbs_split.log` 输出 `ks_ns/gpu_bootstrap_ns/extract_ns` 分段耗时。

备注：nvmevirt 0xC0 的 `mode` 仅 2 bit（0..3），因此 PBS primitive 本身仍由后端用 `mode=4` 直连 GPU service 调用；nvmevirt e2e 侧只负责用 `mode=3 + flags=0x08` 触发后端进入该 split 微流程。

**最新回归指标（2026-01-30，闭环通过）**
- 产物目录：`/tmp/csd_gpu_nvmevirt_regression_20260130_114725/`（末尾 `[PASS] nvmevirt regression OK`）
- 指标摘录：`metrics_summary.txt`
  - `vp/exp/soft`：`mode=0`、`flags=0x00/0x04`，`GLWE matches golden`
  - `be_split`：`mode=1 flags=0x08 bitext_ns=81164451 ks_ns=134002505 premod_ns=397373 woks_ns=50837660`
  - `cb_step4only`：`mode=2 flags=0x40 step4_gpu_latency_ns=53658621 step5_latency_ns=126079559`
  - `cb_step4only_premod`：`mode=2 flags=0x60 step4_gpu_latency_ns=50639111 step5_latency_ns=67977428`
  - `kspbs_split`：`mode=3 flags=0x08 ks_ns=100202083 gpu_bootstrap_ns=27903165 extract_ns=88453`
  - `kspbs_split_per_sample`：`mode=3 flags=0x08 per_sample=1 batch=4 groups=3`
  - `softmax`：`mode=3 flags=0x10 func_split_total_ns=119936457157 (fail=0)`
  - `softmax_kspbs_split_n4`：`mode=3 flags=0x18 func_split_total_ns=49953450679`
  - `softmax_kspbs_split_agg`：`kspbs_split_hits=532 kspbs_split_total_ns=19068317656`

## 5) M3 迁移路径（基于本合同的最短闭环）

为避免一上来就改 RTL，建议按“先软件模拟 CSD 侧算子，再逐步下沉”的顺序推进：

1. nvmevirt 后端先实现 `STEP5_ON_CSD`（SampleExtract + KeySwitch），输入来自 GPU 的 Step4 输出
2. GPU runtime service 增加 `step4_only` 支持（仅 WOKS/BR/FFT-heavy）
3. 复用现有一键脚本做回归（vp/exp/soft + softmax），以同一份 keyset/golden 做证据链

完成后，算子分工就从“GPU 一口气算完”迈进到“GPU 只算 BR/FFT-heavy”，为最终 CSD RTL 下沉铺平道路。
