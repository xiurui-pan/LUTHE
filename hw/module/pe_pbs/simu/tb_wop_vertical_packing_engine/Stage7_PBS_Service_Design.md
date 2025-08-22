# Stage 7: 标准化PBS服务接口集成设计文档

## 🎯 目标
使VP-PBS kernel达到与bit extract引擎相同的架构完整性，实现标准PBS服务接口。

## 🔍 当前架构限制分析

### bit extract引擎成功模式 ✅
```systemverilog
// 标准PBS服务接口
output logic [PE_INST_W-1:0] pbs_inst,
output logic pbs_inst_vld,
input  logic pbs_inst_rdy,
input  logic pbs_inst_ack,

// 使用方式
pbs_inst = make_pbs_inst(lut_gid, src_addr, dst_addr);
pbs_inst_vld = 1'b1;
```

### VP-PBS kernel当前实现 ⚠️
```systemverilog
// 直接使用pep_mmacc_splitc_main
// 缺少标准PBS服务抽象
// STEP5_BOOTSTRAP只读取get_hi LUT，无完整bootstrap计算
```

## 📋 实现计划

### Phase 1: 接口扩展
1. **添加PBS服务接口到wop_pbs_kernel_lite.sv**
   - 添加与bit extract引擎相同的PBS接口信号
   - 实现make_pbs_inst函数
   - 保持现有pep_mmacc集成的兼容性

### Phase 2: BLIND_ROTATION状态重构 
2. **改造BLIND_ROTATION状态使用标准PBS调用**
   - 替换直接pep_mmacc操作为标准PBS指令
   - 实现proper bootstrap流程而非简化状态转换
   - 保持10-bit控制位处理逻辑

### Phase 3: STEP5_BOOTSTRAP完整实现
3. **实现真正的第二轮Bootstrapping**
   - 使用标准PBS接口进行get_hi LUT bootstrap
   - 替换当前的数据读取为完整bootstrap计算
   - 集成Key Switching输出与bootstrap流程

### Phase 4: 接口连接和验证
4. **连接到pe_pbs实例**
   - 在顶层testbench添加专用pe_pbs实例用于VP-PBS kernel
   - 实现PBS指令路由和结果处理
   - 验证端到端标准PBS服务功能

## 🛠️ 技术实现细节

### 接口信号定义
```systemverilog
// 在wop_pbs_kernel_lite.sv中添加
output logic [PE_INST_W-1:0] pbs_inst,
output logic pbs_inst_vld,
input  logic pbs_inst_rdy,
input  logic pbs_inst_ack,
input  logic [LWE_K_W-1:0] pbs_inst_ack_br_loop,
input  logic pbs_inst_load_blwe_ack
```

### make_pbs_inst函数复用
```systemverilog
// 直接从bit extract引擎复制make_pbs_inst函数
function automatic logic [PE_INST_W-1:0] make_pbs_inst(
  logic [GID_W-1:0] lut_gid,
  logic [REGF_ADDR_W-1:0] src_addr,
  logic [REGF_ADDR_W-1:0] dst_addr
);
  pep_inst_t inst_struct;
  inst_struct.dop.kind = DOPT_PBS;
  inst_struct.dop.flush_pbs = 1'b0;
  inst_struct.dop.log_lut_nb = 2'b00;
  inst_struct.gid = lut_gid;
  inst_struct.src_rid = src_addr;
  inst_struct.dst_rid = dst_addr;
  return inst_struct;
endfunction
```

### BLIND_ROTATION状态重构
```systemverilog
BLIND_ROTATION: begin
  // 使用标准PBS调用而非直接pep_mmacc操作
  if (pbs_inst_rdy && ggsw_bit_counter < 10) begin
    pbs_inst = make_pbs_inst(
      lut_base_gid + ggsw_bit_counter,  // LUT GID for this bit
      cmux_result_addr[RID_W-1:0],      // Source: CMux result
      temp_br_result_addr[RID_W-1:0]    // Destination: BR temp result
    );
    pbs_inst_vld = 1'b1;
  end
  
  if (pbs_inst_ack) begin
    ggsw_bit_counter++;
    if (ggsw_bit_counter >= 10) begin
      next_state = SAMPLE_EXTRACT;
    end
  end
end
```

### STEP5_BOOTSTRAP完整实现
```systemverilog
STEP5_BOOTSTRAP: begin
  // 使用标准PBS接口进行第二轮bootstrap
  if (pbs_inst_rdy && step5_bs_lut_loaded) begin
    pbs_inst = make_pbs_inst(
      get_hi_lut_gid,                   // get_hi LUT GID
      step5_ks_result_addr[RID_W-1:0],  // Source: KS result
      step5_bs_result_addr[RID_W-1:0]   // Destination: bootstrap result
    );
    pbs_inst_vld = 1'b1;
  end
  
  if (pbs_inst_ack) begin
    next_state = STEP5_EXTRACT;
  end
end
```

## 🔄 状态机改进

### 当前状态流程
```
VP Engine CMux → BLIND_ROTATION (simplified) → SAMPLE_EXTRACT → POST_PROCESSING
                       ↓
              STEP5_KEY_SWITCHING → STEP5_BOOTSTRAP (data read only) → STEP5_EXTRACT
```

### 改进后状态流程  
```
VP Engine CMux → BLIND_ROTATION (standard PBS) → SAMPLE_EXTRACT → POST_PROCESSING
                       ↓
              STEP5_KEY_SWITCHING → STEP5_BOOTSTRAP (full PBS) → STEP5_EXTRACT
```

## 📊 验证策略

### 功能验证
1. **BLIND_ROTATION验证**: 确保10-bit处理结果与当前实现一致
2. **STEP5_BOOTSTRAP验证**: 验证第二轮bootstrap完整计算
3. **接口验证**: 确认PBS握手协议正确实现

### 性能验证
1. **资源使用**: 对比标准PBS接口vs直接模块集成的资源开销
2. **时序验证**: 确保PBS服务调用不影响整体时序
3. **算法正确性**: 验证改进后结果与C++参考的一致性

## 🎯 成功标准

1. ✅ VP-PBS kernel具备与bit extract引擎相同的PBS服务接口
2. ✅ BLIND_ROTATION使用标准PBS调用而非简化实现
3. ✅ STEP5_BOOTSTRAP实现完整第二轮bootstrap计算
4. ✅ 端到端测试通过，解决KSK reset loopback问题
5. ✅ 算法结果与C++参考完全一致

## 📅 实施时间线

- **阶段1 (接口扩展)**: 1-2小时
- **阶段2 (BLIND_ROTATION重构)**: 2-3小时  
- **阶段3 (STEP5完整实现)**: 3-4小时
- **阶段4 (集成验证)**: 2-3小时

**总计**: 8-12小时完整实现

---
*创建时间: 2025-08-22*
*状态: 设计阶段 - 准备开始实施*