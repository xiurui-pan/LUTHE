# VP Engine Architecture Design - 基于tfhe-cpu-baseline分析

## 📊 **C++ 参考实现分析 (bigLut_20bit_lvl1)**

### 算法流程分解
```cpp
// bigLut_20bit_lvl1() - 完整流程
void bigLut_20bit_lvl1(LweSample32 *result, const TLweSample32 *luts, const LweSample32 *in_s, const Context *env) {
    
    // 1. 准备阶段 - Circuit Bootstrapping (line 5-8)
    TGswSample32 *tgsw_radixs = new_array1<TGswSample32>(20, env->ell_lvl1, env->N_lvl1);
    for (int d = 0; d < 20; d++) {
        circuitBootstrapping(&tgsw_radixs[d], &in_s[d], env);
    }
    
    // 2. CMux Tree阶段 - VP Engine责任 (line 9-24)
    TLweSample32 **pools = new_array2<TLweSample32>(2, 1 << 10, env->N_lvl1);
    // 初始化pools[0]为LUT entries
    for (int d = 10, i = 1; d < 20; d++, i ^= 1) {
        // CMux操作使用bits 10-19
        for (int j = 0; j < (1 << (19 - d)); j++) {
            TLwe32CMux_TGsw_lvl1(&to[j], &from[j << 1], &from[j << 1 | 1], &tgsw_radixs[d], env);
        }
    }
    
    // 3. Blind Rotation阶段 - PBS责任 (line 28-37)
    for (int d = 0; d < 10; d++) {
        int a = (1 << d);
        // X^(-2^d) 多项式乘法
        torus32PolynomialMulByXai_lvl1(tmp_mid->a + i, rotate_lut->a + i, a, env);
        TLwe32CMux_TGsw_lvl1(tmp_result, rotate_lut, tmp_mid, &tgsw_radixs[d], env);
    }
    
    // 4. Sample Extract - PBS责任 (line 39)
    tLwe32ExtractSample_lvl1(result, rotate_lut, env);
    
    // 5. Post-processing - PBS责任 (line 41-44)
    result->b[0] += modSwitchToTorus32(2, FULL_MSG_SIZE);
    TLwe32_Keyswitch_Bootstrapping_Extract_lvl1(result, env->predefinedTLwe32Luts.get_hi, result, FULL_MSG_SIZE, env);
}
```

## 🏗️ **资源需求分析**

### VP Engine 需要的资源
```
✅ 需要：
- RegFile 读写接口 (加载LUT/GGSW, 写入CMux结果)  
- 内部存储 (双池CMux缓冲区, GGSW样本存储)
- 基础计算逻辑 (CMux操作, 地址生成)

❌ 不需要：
- NTT 引擎 (CMux Tree无需多项式乘法)
- BSK 访问 (无Blind Rotation)
- KSK 访问 (无keyswitch操作)
- 复杂AXI接口 (只需LUT读取)
```

### PBS Engine 需要的资源
```
✅ 需要：
- 完整NTT引擎 (多项式乘法 X^(-2^d))
- BSK访问 (TLwe32CMux_TGsw操作)
- KSK访问 (最终keyswitch操作)
- AXI接口 (读取predefined LUTs)
- RegFile接口 (读取VP结果, 写入最终结果)
```

## 🎯 **优化架构设计**

### 方案1: 最小化VP Engine (推荐)
```systemverilog
// VP Engine - 精简版本
module wop_vertical_packing_engine_lite (
    // 基础控制
    input  logic clk, s_rst_n, start,
    output logic done,
    
    // RegFile接口 (简化)
    pep_regf_if.master regf_if,
    
    // LUT接口 (简化，只读)
    axi_if_rd.master lut_if,
    
    // PBS服务接口 (发送指令给PBS)
    output vp_pbs_req_t  pbs_req,
    output logic         pbs_req_vld,
    input  logic         pbs_req_rdy,
    input  logic         pbs_ack
);

// 状态机精简至7个状态
typedef enum logic [2:0] {
    IDLE,
    LOAD_LUT_ENTRIES,    // 加载LUT到内部缓冲
    LOAD_GGSW_SAMPLES,   // 加载GGSW样本
    CMUX_TREE_PROCESS,   // CMux Tree (bits 10-19)
    WRITE_CMUX_RESULT,   // 写入CMux结果到RegFile  
    PBS_REQUEST,         // 发送PBS请求
    WAIT_PBS_DONE        // 等待PBS完成
} vp_state_e;
```

### 方案2: PBS扩展支持VP请求
```systemverilog
// 在wop_pbs_kernel中添加VP专用处理路径
module wop_pbs_kernel (
    // 现有接口...
    
    // VP专用接口
    input  vp_pbs_req_t  vp_req,
    input  logic         vp_req_vld, 
    output logic         vp_req_rdy,
    output logic         vp_ack,
    
    // VP处理参数
    input  logic [REGF_ADDR_W-1:0] vp_cmux_result_addr,  // CMux结果地址
    input  logic [REGF_ADDR_W-1:0] vp_ggsw_addr,         // GGSW bits 0-9地址
    input  logic [REGF_ADDR_W-1:0] vp_output_addr        // 最终输出地址
);

// VP请求类型
typedef struct packed {
    logic [3:0]           operation_type;  // VP_BLIND_ROTATION_EXTRACT
    logic [REGF_ADDR_W-1:0] cmux_addr;     // CMux结果输入
    logic [REGF_ADDR_W-1:0] ggsw_addr;     // GGSW bits 0-9
    logic [REGF_ADDR_W-1:0] output_addr;   // 输出地址
    logic [3:0]           bit_range_start; // 0 (bits 0-9)
    logic [3:0]           bit_range_end;   // 9
    logic                 need_post_process; // 1 (需要post-processing)
} vp_pbs_req_t;
```

## 🔄 **资源共享策略**

### 共享资源矩阵
| 资源组件 | VP Engine | PBS Engine | 共享方式 |
|----------|-----------|------------|----------|
| RegFile | 读写CMux | 全部操作 | 时分复用 |
| NTT Engine | ❌ | ✅ | PBS专用 |  
| BSK Memory | ❌ | ✅ | PBS专用 |
| KSK Memory | ❌ | ✅ | PBS专用 |
| LUT AXI | 简化读取 | 复杂读取 | 接口复用 |
| Control Logic | 独立状态机 | 主控制器 | 指令仲裁 |

### 接口设计
```systemverilog
// 统一的PBS服务接口
interface pbs_service_if;
    logic [PE_INST_W-1:0] inst;
    logic                 inst_vld;
    logic                 inst_rdy; 
    logic                 inst_ack;
    
    // VP专用扩展
    logic                 vp_mode;     // VP请求标志
    logic [REGF_ADDR_W-1:0] vp_cmux_addr;
    logic [9:0]           vp_bit_mask; // bits 0-9 mask
    
    modport client (output inst, inst_vld, vp_mode, vp_cmux_addr, vp_bit_mask,
                   input  inst_rdy, inst_ack);
    modport server (input  inst, inst_vld, vp_mode, vp_cmux_addr, vp_bit_mask,
                   output inst_rdy, inst_ack);
endinterface
```

## 📈 **性能优化**

### VP Engine优化
```systemverilog
// 并行CMux处理
always_ff @(posedge clk) begin
    if (cmux_active) begin
        // 并行处理多个CMux操作
        for (int i = 0; i < CMUX_PARALLEL_NUM; i++) begin
            if (control_bits[bit_counter][i]) begin
                pools[pool_next][entry_base+i] <= pools[pool_current][entry_left+i];
            end else begin
                pools[pool_next][entry_base+i] <= pools[pool_current][entry_right+i];
            end
        end
    end
end
```

### PBS资源复用
```systemverilog
// PBS资源调度器
module pbs_resource_scheduler (
    input  bit_extract_req_t   bit_req,
    input  circuit_bootstrap_req_t cb_req,
    input  vp_pbs_req_t       vp_req,
    
    output ntt_req_t          ntt_req,
    output bsk_req_t          bsk_req,
    output ksk_req_t          ksk_req,
    
    // 仲裁控制
    input  logic [2:0]        priority,
    output logic [2:0]        grant
);
```

## 🎯 **实现优先级**

### Phase 1: VP Engine独立化 (本次重构)
```
1. ✅ 移除VP中的Blind Rotation逻辑
2. ✅ 精简VP状态机 (7个状态)
3. ✅ 实现PBS服务接口
4. ✅ CMux Tree专用优化
```

### Phase 2: PBS集成 (下一阶段)
```
1. ⚠️ 扩展wop_pbs_kernel支持VP请求
2. ⚠️ 实现VP-PBS握手协议
3. ⚠️ 添加PBS资源调度逻辑
4. ⚠️ 验证端到端功能
```

### Phase 3: 性能优化 (未来)
```
1. ⚠️ 并行CMux处理
2. ⚠️ 流水线化设计  
3. ⚠️ 动态资源分配
4. ⚠️ 功耗优化
```

## ⚡ **关键设计决策**

### 决策1: VP Engine最小化
**理由**: VP只需要CMux Tree功能，不需要复杂的密码学运算单元

### 决策2: PBS作为服务提供者
**理由**: Blind Rotation/Extract/Post-process需要完整的PBS基础设施

### 决策3: 时分复用RegFile
**理由**: VP和PBS操作不重叠，可以共享RegFile接口

### 决策4: 分阶段实现
**理由**: 先保证功能正确，再优化性能和资源利用率

## 🔍 **验证策略**

### 功能验证
```cpp
// 与C++参考的每个阶段对比
1. CMux Tree结果 vs pools[0][0] (line 24)
2. PBS输入准备 vs rotate_lut初始化 (line 25-26)  
3. 最终结果 vs LWE样本输出 (line 39-44)
```

### 性能验证
```
1. 资源利用率 < 原始设计的60%
2. 延迟 ≈ 原始设计 (主要是PBS延迟)
3. 吞吐量 ≥ 原始设计 (更好的资源调度)
```

这个设计确保了VP Engine只负责其核心职责，同时充分利用现有的PBS基础设施，避免资源浪费。
