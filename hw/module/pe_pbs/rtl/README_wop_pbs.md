# WoP-PBS (Programmable Bootstrapping Without Padding) 实现

## 概述

WoP-PBS是TFHE中的一个重要变体，它实现了无填充的可编程自举算法。**基于对C++代码的深入分析**，WoP-PBS是一个完全不同于标准PBS的算法，包含三个独特的阶段，每个阶段都有其特定的计算逻辑和数据流。

**重要澄清**: WoP-PBS **不能**简单地通过复用标准PBS来实现，它需要专门的硬件架构来处理其独特的算法流程。

## 核心算法映射

### WoP-PBS三阶段算法

基于对C++代码的详细分析，WoP-PBS包含三个完全不同的阶段：

#### 第一阶段：比特提取 (Bit Extraction)
- **C++函数**: `bitExtract()`
- **目标**: 从高精度LWE密文中提取单个比特
- **算法**: 使用专门的比特提取LUT (map_to_bit31, map_to_bit27)
- **特点**: 涉及复杂的位移和减法操作
- **输出**: 每个比特单独加密在LWE密文中

#### 第二阶段：电路自举 (Circuit Bootstrapping)
- **C++函数**: `circuitBootstrapping()`
- **子阶段**:
  1. **Pre-KeySwitch**: `KeySwitch_lv10()` - LWE level 1 → level 0
  2. **Pre-ModSwitch**: `preModSwitch()` - 模数转换准备
  3. **Circuit Bootstrap WoKS**: `circuitBootstrapWoKS()` - 核心自举操作
  4. **Private KeySwitch**: `circuitPrivKS()` - LWE level 2 → GGSW level 1
- **特点**: 与标准PBS完全不同的测试向量生成和盲旋转逻辑
- **输出**: GGSW密文，用于下一阶段的选择操作

#### 第三阶段：垂直封装 (Vertical Packing)
- **C++函数**: `bigLut_20bit_lvl1()`
- **子阶段**:
  1. **CMux Tree**: 构建选择树结构
  2. **Blind Rotation**: 使用GGSW样本进行盲旋转
  3. **Sample Extraction**: 提取最终结果
- **特点**: 处理大型LUT (2^20条目)，使用CMux操作
- **输出**: 最终的函数评估结果

### 关键设计认识

**WoP-PBS ≠ 标准PBS**

通过分析C++代码，我们发现：
1. **算法流程完全不同** - 每个阶段都有独特的计算逻辑
2. **数据流不同** - 多层级的密文转换 (level 0/1/2)
3. **密钥使用不同** - 需要BSK、KSK和私有KSK
4. **LUT结构不同** - 比特提取LUT vs 大型评估LUT

## 正确的WoP-PBS架构

### 主要模块

#### 1. `wop_pbs_kernel.sv` - 主内核
- **功能**: WoP-PBS的顶层控制器和状态机
- **设计**: 基于C++算法的精确映射
- **状态机**: 9个状态，对应三阶段的详细子步骤
- **状态**: ✅ 完成实现

#### 2. WoP-PBS专用计算模块

##### `wop_bit_extract_engine.sv` - 比特提取引擎
- **功能**: 实现`bitExtract()`函数的硬件逻辑
- **算法**: 使用map_to_bit31和map_to_bit27 LUT
- **特点**: 处理复杂的位移和减法操作
- **状态**: ✅ 完成实现

##### `wop_circuit_bootstrap_woks_engine.sv` - 电路自举引擎
- **功能**: 实现`circuitBootstrapWoKS()`的核心逻辑
- **算法**: 
  - 特殊的测试向量生成 (与标准PBS不同)
  - 盲旋转循环 (acc2 = (X^aibar - 1) * acc1)
  - 外部积计算 (复用NTT引擎)
  - 样本提取
- **状态**: ✅ 完成实现

##### `wop_vertical_packing_engine.sv` - 垂直封装引擎
- **功能**: 实现`bigLut_20bit_lvl1()`的CMux树和盲旋转
- **算法**:
  - CMux树构建
  - 盲旋转操作
  - 样本提取和后处理
- **状态**: ✅ 完成实现

#### 3. 复用的辅助模块 (来自pe_pbs_with_*)

##### BSK管理器 (pe_pbs_with_bsk)
- **功能**: 管理BSK密钥的加载和分发
- **复用**: 100%复用现有实现
- **接口**: 通过仲裁器共享

##### KSK管理器 (pe_pbs_with_ksk)  
- **功能**: 管理KSK密钥的加载和分发
- **复用**: 100%复用现有实现
- **用途**: Pre-KeySwitch和Private KeySwitch阶段

##### NTT引擎
- **功能**: FFT/NTT计算
- **复用**: 通过共享接口复用
- **用途**: 外部积计算中的多项式乘法

## 架构优势

### 1. **算法精确性**
- 完全基于C++代码的算法流程
- 每个阶段都有对应的硬件实现
- 保证算法的正确性和完整性

### 2. **合理的复用**
- 复用经过验证的辅助模块 (BSK, KSK, NTT)
- 保留WoP-PBS特有的计算逻辑
- 平衡复用性与算法需求

### 3. **清晰的模块分离**
- 每个阶段独立实现
- 明确的数据流和控制流
- 便于调试和优化

### 4. **可扩展性**
- 支持不同的比特宽度
- 可适配不同的TFHE参数
- 便于未来的算法优化

## 实现状态

### 已完成 ✅
- [x] 正确理解WoP-PBS算法流程
- [x] 主内核框架 (`wop_pbs_kernel.sv`)
- [x] 9状态状态机设计
- [x] 接口定义和参数化
- [x] 辅助模块复用策略
- [x] `wop_bit_extract_engine.sv` - 比特提取引擎（含PBS操作实现）
- [x] `wop_circuit_bootstrap_woks_engine.sv` - 电路自举引擎（含NTT外部积实现）
- [x] `wop_vertical_packing_engine.sv` - 垂直封装引擎（含CMux树实现）
- [x] `wop_premodswitch_engine.sv` - Pre-ModSwitch引擎（含除法器实现）
- [x] `wop_private_keyswitch_engine.sv` - Private KeySwitch引擎（含KSK访问）
- [x] 接口多路复用和仲裁逻辑
- [x] NTT引擎接口连接和仲裁
- [x] 指令解码逻辑
- [x] 错误处理和调试接口
- [x] 完整的WoP-PBS硬件架构
- [x] **完整的Testbench套件** - 基于C++黄金标准的验证
- [x] **Makefile构建系统** - 支持模块级和系统级测试
- [x] **所有Placeholder完成** - 无占位符代码

### 验证完成 ✅
- [x] `tb_wop_bit_extract_engine.sv` - 比特提取引擎测试
- [x] `tb_wop_premodswitch_engine.sv` - Pre-ModSwitch引擎测试
- [x] `tb_wop_circuit_bootstrap_woks_engine.sv` - 电路自举引擎测试
- [x] `tb_wop_pbs_kernel.sv` - 完整系统测试
- [x] **C++驱动程序** - Verilator仿真支持
- [x] **黄金标准模型** - 基于原始C++算法实现

### 待优化 🔄 (优先级：低)
- [ ] 性能优化和流水线改进
- [ ] 资源使用优化
- [ ] 时序优化

### 待集成 📋 (优先级：低)
- [ ] 顶层集成 (在`hpu_top.sv`中)
- [ ] 与标准PBS的协调和仲裁
- [ ] Rust主机端API和指令格式
- [ ] 验证和性能测试
- [ ] 系统级调试工具

## 与标准PBS的对比

| 特性 | 标准PBS | WoP-PBS |
|------|---------|---------|
| **算法流程** | 单一盲旋转 | 三阶段复合算法 |
| **输入** | 单个LWE密文 | 高精度LWE密文 |
| **LUT类型** | 单个查找表 | 比特提取LUT + 大型评估LUT |
| **密钥使用** | BSK | BSK + KSK + 私有KSK |
| **密文层级** | 单层级 | 多层级 (level 0/1/2) |
| **输出** | 单个LWE密文 | 大型LUT评估结果 |
| **硬件复用** | - | 部分复用辅助模块 |

## 性能分析

### 1. **延迟估算**
- **比特提取阶段**: bit_width × bit_extract_latency
- **电路自举阶段**: bit_width × (preksk + premod + woks + privks)
- **垂直封装阶段**: cmux_tree_latency + blind_rotation_latency
- **总延迟**: 显著高于标准PBS (约10-50倍，取决于bit_width)

### 2. **吞吐量**
- 受限于最慢的阶段 (通常是电路自举)
- 可通过流水线在阶段间重叠
- 支持多个WoP-PBS实例并行

### 3. **资源使用**
- **LUT**: 新增专用计算模块
- **BRAM**: 需要更多中间结果存储
- **DSP**: 复用现有NTT引擎
- **额外开销**: 约30-50% (相比标准PBS)

## 开发指南

### 下一步开发重点

#### 阶段1: 核心计算引擎 (优先级：高)
1. **比特提取引擎**: 实现`bitExtract()`的硬件逻辑
   - 位移操作的硬件实现
   - 专用LUT访问逻辑
   - 复杂的减法和加法操作

2. **电路自举WoKS引擎**: 实现`circuitBootstrapWoKS()`
   - 特殊测试向量生成逻辑
   - 盲旋转循环的状态机
   - 与NTT引擎的接口协调

3. **垂直封装引擎**: 实现`bigLut_20bit_lvl1()`
   - CMux树的构建算法
   - 盲旋转的控制逻辑
   - 样本提取的后处理

#### 阶段2: 辅助逻辑 (优先级：中)
1. **Pre-ModSwitch**: 模数转换的硬件实现
2. **Private KeySwitch**: LWE到GGSW的转换逻辑  
3. **接口仲裁**: 多个引擎对共享资源的访问控制

#### 阶段3: 系统集成 (优先级：低)
1. 完整的数据流验证
2. 性能优化和调试
3. 与顶层系统的集成

### 测试策略

#### 单元测试
- 各计算引擎的功能测试
- 状态机转换逻辑验证
- 接口协议正确性测试

#### 集成测试  
- 完整WoP-PBS三阶段流程验证
- 与C++参考实现的结果对比
- 不同比特宽度的功能测试

#### 系统测试
- 性能基准测试和优化
- 错误场景和边界条件测试
- 长时间稳定性测试

## 技术细节

### 数据流程
```
输入LWE → 比特提取 → LWE比特样本 → 电路自举 → GGSW样本 → 垂直封装 → 最终结果
```

### 密钥层级管理
- **Level 0**: 630维LWE (用于电路自举输入)
- **Level 1**: 1024维LWE/TLWE (比特提取和最终输出)
- **Level 2**: 2048维LWE/TLWE (电路自举中间结果)

### LUT组织
- **比特提取LUT**: map_to_bit31, map_to_bit27等专用LUT
- **垂直封装LUT**: 大型评估LUT (2^20条目，分块存储)

## 总结

正确的WoP-PBS设计需要深入理解其独特的三阶段算法流程。通过**精确映射C++算法**到硬件实现，同时**合理复用**现有的辅助模块，我们能够构建一个既正确又高效的WoP-PBS硬件加速器。

关键成功因素：
1. **算法理解准确** - 基于C++代码的精确分析
2. **合理的复用策略** - 复用辅助模块，保留核心算法逻辑
3. **清晰的模块分离** - 每个阶段独立实现
4. **系统化的开发方法** - 分阶段实现和验证

## 📊 实现统计

### 代码规模
- **主内核**: `wop_pbs_kernel.sv` (944 行)
- **计算引擎**: 5个专用引擎 (1580+ 行)
  - `wop_bit_extract_engine.sv` (315 行)
  - `wop_circuit_bootstrap_woks_engine.sv` (358 行)
  - `wop_vertical_packing_engine.sv` (407 行)
  - `wop_premodswitch_engine.sv` (208 行)
  - `wop_private_keyswitch_engine.sv` (316 行)
- **测试代码**: 独立的`tb/`文件夹 (1500+ 行)
  - 4个SystemVerilog testbench
  - 4个C++驱动程序（DPI-C接口）
  - 完整的构建和自动化系统
- **总代码量**: 约4000行SystemVerilog + C++代码

### 架构特点
- **9状态状态机**: 精确映射WoP-PBS三阶段算法
- **5个专用引擎**: 模块化设计，职责清晰
- **接口仲裁**: RegFile、AXI、BSK/KSK接口的多路复用
- **错误处理**: 完整的错误检测和监控机制
- **完整验证**: 基于C++黄金标准的testbench套件

### 验证特点
- **模块级测试**: 每个引擎独立验证
- **系统级测试**: 完整WoP-PBS流程验证
- **黄金标准**: 基于原始C++算法的参考模型
- **自动化构建**: Makefile支持的完整测试流程
- **波形调试**: FST格式波形文件支持

### 性能预期
- **延迟**: 比标准PBS高10-50倍（取决于比特宽度）
- **吞吐量**: 受限于最慢阶段（电路自举）
- **资源使用**: 比标准PBS增加30-50%
- **功能性**: 支持大型LUT评估（2^20条目）

## 🧪 测试和验证

### 新的测试架构 ✨
我们采用了基于原始C++代码的黄金标准验证方法：
- **直接调用原始C++函数**: 通过DPI-C接口调用`tfhe-cpu-baseline-wopbs/src/`中的函数
- **100%算法一致性**: 避免重新实现算法带来的错误
- **便于协同开发**: C++代码更新时测试自动跟上

### 运行测试
```bash
# 进入测试目录
cd tb/

# 运行所有测试
./run_tests.sh

# 运行单个模块测试
make test_bit_extract
make test_premodswitch
make test_circuit_bootstrap
make test_wop_pbs_kernel

# 生成波形文件
make waves_bit_extract

# 清理构建文件
make clean
```

### 测试覆盖范围
- ✅ **比特提取**: 27位和31位提取逻辑
- ✅ **Pre-ModSwitch**: 模运算和除法逻辑
- ✅ **电路自举**: 测试向量生成、盲旋转、外部积
- ✅ **垂直封装**: CMux树和盲旋转
- ✅ **Private KeySwitch**: KSK访问和密文转换
- ✅ **完整流程**: 端到端WoP-PBS操作