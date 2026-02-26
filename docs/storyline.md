# StoryLine（算子分工）

> e2e 总入口：`docs/gpu_csd_e2e.md`  
> 算子边界合同（M2 草案）：`docs/gpu_csd_operator_contract.md`  
> 说明：本表描述目标形态的算子放置；当前实现仍以 GPU runtime service 执行整段算子为主，详见上面的总入口文档。

- 进展：VP KeySwitch 已可在 nvmevirt 后端执行（`mode=0 + flags[3]=0x08(backend_split)`；取证见 `docs/gpu_csd_e2e.md` 与 `docs/gpu_csd_operator_contract.md`）。
- 进展：BE KeySwitch 已可在 nvmevirt 后端执行并纳入回归（`mode=1 + flags[3]=0x08(backend_split)`；一键：`NO_SUDO=0 bash scripts/csd_gpu_nvmevirt_be_split_oneclick.sh`；用户态快跑：`bash scripts/csd_gpu_be_split_backend_smoke.sh`）。
- 进展：CB `step4_only` 分工闭环已通并纳入回归（`mode=2 + flags[6]=0x40(step4_only)`；GPU 仅 Step4-heavy，后端执行 Step5(PrivKS)；取证见 `docs/gpu_csd_e2e.md`）。
- 进展：Preprocess 下沉已通并纳入回归（`mode=2 + flags[5]=0x20(premod_in)`；后端产出 premod(i32)，GPU 跳过 normalize；取证见 `docs/gpu_csd_e2e.md`）。
- 进展：PBS primitive 微流程拆分已通并纳入回归（KSPBS split：后端 KeySwitch+SampleExtract，GPU bootstrap-only；取证见 `docs/gpu_csd_operator_contract.md` 与 `docs/gpu_csd_e2e.md` 的 `kspbs_split*`）。
- 进展：softmax 的 PBS split 取证已纳入回归（`softmax_kspbs_split_n4/` 固定 N=4 快跑；`gpu_runtime_service.log` 含 `[KSPBS_SPLIT]` 与分段耗时字段）。
- 进展：FunctionEval 全阶段 split 语义已对齐，N=16 no‑fallback 取证通过（`/tmp/csd_gpu_nvmevirt_softmax_20260131_104100/`）。
- 进展：后端常驻/预热已闭环（`CSD_KEEP_BACKEND=1` + `CSD_BACKEND_PREWARM=1`），回归 `/tmp/csd_gpu_nvmevirt_regression_20260131_113138/metrics_summary.txt` 含 `reuse_backend=1`，backend log 含 `cache hit`。
- 进展：回归已默认支持 session/backend 常驻（`CSD_KEEP_SESSION=1` 复用 loopdev+gpu_runtime_service，`CSD_KEEP_BACKEND=1` 复用 `csd_sw_backend.py`，降低 macrobenchmark 前的冷启动抖动；取证见 `docs/gpu_csd_e2e.md` 的 `flash_* reuse_backend=1`）。
- 验收：最新全量回归通过（2026-01-30，`/tmp/csd_gpu_nvmevirt_regression_20260130_114725/`，末尾 `[PASS] nvmevirt regression OK`；详见 `docs/gpu_csd_e2e.md`）。

| **算子**                                       | **输入** **→** **输出** | **主要读写**           | **估算** **FLOPs** | **计算强度** **FLOPs/Byte** | **带宽需求****/****瓶颈判断** | **放置**              |
| ---------------------------------------------- | ----------------------- | ---------------------- | ------------------ | --------------------------- | ----------------------------- | --------------------- |
| **LUT load**                                   | Flash→(CSD DRAM)：32KB  | LUT                    | ~0                 | ~0                          | 很小                          | CSD 侧缓存 + 按需 DMA |
| **ModSwitch / Preprocess**                     | 4.3KB→4.3KB             | LWE state              | ~O(n)（极小）      | 很低                        | 很小                          | CSD                   |
| **FFT(fwd)×(k+1)ℓbr**                          | time→freq               | FFT buffers            | ~26×FFT(4096)      | 中                          | compute+memory-bound          | GPU                   |
| **外积核心：****PointwiseMul + Accumulate**    | freq×key→freq           | 读 1×GGSW=1.70MB/外积  | ~O((k+1)²(br·N)    | 中等（~几 FLOPs/Byte）      | memory-bound，极高            | GPU                   |
| **iFFT×(k+1)**                                 | freq→time               | FFT buffers            | ~2×FFT(4096)       | 中                          | 同上                          | GPU                   |
| **CMux / BlindRotate loop**                    | GLWE→GLWE               | 总读 BSK≈0.87GB/次 PBS | ~5.1×10⁹           | ~几 FLOPs/Byte              | compute+memory-bound          | GPU                   |
| **SampleExtract****（****GLWE→LWE_{kN}****）** | 64KB→~32KB              | GLWE state             | 小                 | 低                          | memory-bound                  | CSD                   |
| **KeySwitch**                                  | 32KB→4.3KB              | 读 KSK≈86MB/次         | ~2.26×10⁷          | 很低（~0.26 ops/Byte）      | memory-bound                  | CSD                   |
| **Assemble / Pack**                            | 小→小                   | 小                     | 小                 | 低                          | latency                       | CSD                   |

+ Contribution
  + Characterization：首次系统性地分析、拆解TFHE WoPBS在密态大模型推理场景下的瓶颈与开销，发现PrivKS的数据膨胀和密钥依赖导致了极高的数据搬移开销
  + GPU-CSD流水线架构：实现了以CSD为中心的计算与数据过滤架构，将PreKS、BE等严重依赖密钥的算子下沉到存储内部，GPU专注BR/FFT-heavy的核心计算，从而避免了数据膨胀和密钥传输的开销
  + CSD优化：1. 融合了多阶段算子（BE/CB/VP）的统一调度内核，实现最小化bubble和零仲裁开销；2. 面向巨量只读顺序访问的密钥数据，设计了bypass-FTL的静态stripe和阶段感知的流式轻量化MAC引擎和流水线
