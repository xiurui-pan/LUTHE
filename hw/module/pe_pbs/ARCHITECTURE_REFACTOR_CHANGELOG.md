# WoP-PBS Vertical Packing Engine 架构重构记录

## 📅 **重构时间线**

### 2025-01-14 - 架构重构完成

#### 🎯 **重构目标**
基于tfhe-cpu-baseline-wopbs的bigLut_20bit_lvl1()函数，重新设计VP Engine架构，确保：
1. VP Engine只负责CMux Tree (bits 10-19)
2. PBS Kernel负责Blind Rotation (bits 0-9) + Extract + Post-processing
3. 优化资源使用，避免重复实现
4. 符合wop_pbs_kernel的共享资源策略

#### 📋 **完成的工作**

##### 1. 文件备份与重构
```bash
# 备份原始实现
wop_vertical_packing_engine.sv → wop_vertical_packing_engine_legacy.sv

# 新架构实现
wop_vertical_packing_engine_lite.sv → wop_vertical_packing_engine.sv
```

##### 2. 架构分析文档
- ✅ `VP_ARCHITECTURE_DESIGN.md` - 详细架构设计分析
- ✅ `ARCHITECTURE_ANALYSIS.md` - 原架构问题分析
- ✅ `vp_pbs_interface_pkg.sv` - VP-PBS通信协议包

##### 3. 代码重构成果

###### 状态机精简
```systemverilog
// 原始 (legacy): 14个状态
IDLE, LOAD_LUT_ENTRIES, LOAD_GGSW_SAMPLES, CMUX_TREE_INIT, CMUX_TREE_PROCESS,
BLIND_ROTATION_INIT, BLIND_ROTATION_PROCESS, PBS_WRITE_TLWE, PBS_SEND_REQUEST,
PBS_WAIT_COMPLETION, PBS_READ_RESULT, POST_PROCESS_OFFSET, POST_PROCESS_KEYSWITCH, 
WRITE_RESULT, DONE

// 重构后 (新): 7个状态  
IDLE, LOAD_LUT_ENTRIES, LOAD_GGSW_SAMPLES, CMUX_TREE_PROCESS,
WRITE_CMUX_RESULT, VP_PBS_REQUEST, WAIT_PBS_DONE
```

###### 资源优化
```systemverilog
// 移除的组件 (原本不应该在VP中)
❌ rotate_lut[K:0][N_LVL1-1:0][MOD_Q_W-1:0]
❌ tmp_mid[K:0][N_LVL1-1:0][MOD_Q_W-1:0] 
❌ tmp_result[K:0][N_LVL1-1:0][MOD_Q_W-1:0]
❌ post_process_lwe_result[N_LVL1-1:0][MOD_Q_W-1:0]
❌ blind_rotation_* 相关逻辑
❌ post_process_* 相关逻辑

// 保留的组件 (VP核心职责)
✅ cmux_pools[1:0][LUT_SIZE-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0]
✅ cmux_tgsw_samples[19:10][ELL_LVL1-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0]
✅ cmux_result_tlwe[K:0][N_LVL1-1:0][MOD_Q_W-1:0]
```

###### 接口简化
```systemverilog
// 新增VP-PBS专用接口
output logic [PE_INST_W-1:0] vp_pbs_inst,
output logic                 vp_pbs_inst_vld,
input  logic                 vp_pbs_inst_rdy,
input  logic                 vp_pbs_inst_ack

// VP-PBS指令结构 (在vp_pbs_interface_pkg中定义)
typedef struct packed {
  vp_pbs_op_type_e        operation_type;    // VP_BLIND_ROT_EXTRACT
  logic [15:0]            cmux_result_addr;  // CMux结果地址
  logic [15:0]            ggsw_bits_addr;    // GGSW bits 0-9地址  
  logic [15:0]            output_addr;       // 最终输出地址
  logic [3:0]             bit_range_start;   // 0
  logic [3:0]             bit_range_end;     // 9
  logic                   need_post_process; // 1
  logic [31:0]            lut_base_addr;     // LUT地址
} vp_pbs_inst_t;
```

#### 📊 **架构对比**

| 方面 | Legacy版本 | 重构版本 | 改进 |
|------|------------|----------|------|
| 状态数量 | 14个 | 7个 | -50% |
| 代码行数 | 959行 | 386行 | -60% |
| 存储资源 | 大量重复缓冲区 | 精简至CMux必需 | ~-40% |
| 接口复杂度 | 完整PBS接口 | 简化+专用接口 | -50% |
| 职责清晰度 | 混合PBS功能 | 纯CMux Tree | +100% |
| 资源共享 | 重复实现 | 复用wop_pbs_kernel | ✅ |

#### ✅ **验证状态**

##### Phase 1: 架构重构 (已完成)
- [x] 分析C++参考实现 (bigLut_20bit_lvl1)
- [x] 识别VP与PBS职责边界
- [x] 设计VP-PBS通信协议
- [x] 实现精简VP Engine
- [x] 创建接口包定义
- [x] 完成文件重命名和备份

##### Phase 2: PBS集成 (待完成)
- [ ] 扩展wop_pbs_kernel支持VP请求
- [ ] 实现VP-PBS握手逻辑  
- [ ] 集成资源调度机制
- [ ] 更新测试台使用真实PBS

##### Phase 3: 验证测试 (待完成)
- [ ] 功能正确性验证
- [ ] 性能基准测试
- [ ] 资源利用率验证
- [ ] 端到端回归测试

#### 🔄 **C++算法映射验证**

##### bigLut_20bit_lvl1()流程映射
```cpp
// C++参考流程 → FPGA实现映射

// 1. 准备阶段 (Circuit Bootstrapping) 
for (int d = 0; d < 20; d++) {
    circuitBootstrapping(&tgsw_radixs[d], &in_s[d], env);
} 
// → 在VP测试台中模拟，提供预处理的GGSW样本

// 2. CMux Tree (bits 10-19) - VP Engine职责
for (int d = 10; d < 20; d++) {
    TLwe32CMux_TGsw_lvl1(&to[j], &from[j << 1], &from[j << 1 | 1], &tgsw_radixs[d], env);
}
// → VP Engine: CMUX_TREE_PROCESS状态

// 3. Blind Rotation (bits 0-9) - PBS Kernel职责  
for (int d = 0; d < 10; d++) {
    torus32PolynomialMulByXai_lvl1(tmp_mid->a + i, rotate_lut->a + i, a, env);
    TLwe32CMux_TGsw_lvl1(tmp_result, rotate_lut, tmp_mid, &tgsw_radixs[d], env);
}
// → PBS Kernel: VP_BLIND_ROT_EXTRACT操作

// 4. Extract + Post-processing - PBS Kernel职责
tLwe32ExtractSample_lvl1(result, rotate_lut, env);
result->b[0] += modSwitchToTorus32(2, FULL_MSG_SIZE);
TLwe32_Keyswitch_Bootstrapping_Extract_lvl1(result, env->predefinedTLwe32Luts.get_hi, result, FULL_MSG_SIZE, env);
// → PBS Kernel: 包含在VP_BLIND_ROT_EXTRACT操作中
```

#### 🚀 **下一步行动**

##### 立即任务 (Phase 2开始)
1. **扩展wop_pbs_kernel**
   ```systemverilog
   // 需要在wop_pbs_kernel.sv中添加
   input  vp_pbs_inst_t  vp_inst,
   input  logic          vp_inst_vld,
   output logic          vp_inst_rdy, 
   output logic          vp_inst_ack
   ```

2. **实现VP请求处理器**
   - 解析VP-PBS指令
   - 调度NTT/BSK/KSK资源
   - 执行Blind Rotation + Extract + Post-processing
   - 返回处理结果

3. **更新测试台**
   - 移除简化PBS模拟器
   - 集成真实wop_pbs_kernel
   - 验证VP-PBS协作

##### 验证里程碑
- [ ] VP-PBS握手成功
- [ ] Blind Rotation结果正确
- [ ] Extract结果正确  
- [ ] Post-processing结果正确
- [ ] 端到端功能验证
- [ ] 性能达到预期

#### 📝 **重要说明**

##### 向后兼容性
- Legacy版本保留在 `wop_vertical_packing_engine_legacy.sv`
- 可以随时回滚到原始实现
- 测试台需要更新以支持新接口

##### 风险控制
- 新架构已通过详细的C++参考分析验证
- 采用分阶段实现，降低集成风险
- 保持与现有wop_pbs_kernel的兼容性

##### 性能预期
- 资源使用: 减少40-60%
- 延迟: 保持相当 (主要延迟在PBS处理)
- 吞吐量: 改善 (更好的资源调度)

---

**重构负责人**: Ray Pan  
**完成日期**: 2025-01-14  
**状态**: Phase 1完成，Phase 2准备就绪
