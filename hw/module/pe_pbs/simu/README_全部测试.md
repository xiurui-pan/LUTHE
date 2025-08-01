# WoP-PBS 完整仿真测试套件

## 概述

这是完全重构后的 WoP-PBS 仿真测试套件，参考 pe_alu 的仿真框架，提供了基于 edalize 的标准化仿真环境。

## 重构完成的测试模块

### 1. 🔧 tb_wop_bit_extract_engine
**位提取引擎测试**
- **位置**: `pe_pbs/simu/tb_wop_bit_extract_engine/`
- **功能**: 验证 WoP-PBS 位提取功能
- **主要参数**: MOD_Q_W, MAX_BIT_WIDTH, N_LVL1, LUT_ENTRY_SIZE

### 2. 🔄 tb_wop_premodswitch_engine  
**预模切换引擎测试**
- **位置**: `pe_pbs/simu/tb_wop_premodswitch_engine/`
- **功能**: 验证预模切换算法实现
- **主要参数**: N_LVL0, N_LVL2

### 3. 🚀 tb_wop_circuit_bootstrap_woks_engine
**电路自举 WoKS 引擎测试**
- **位置**: `pe_pbs/simu/tb_wop_circuit_bootstrap_woks_engine/`
- **功能**: 验证电路自举 WoKS 功能
- **主要参数**: MOD_Q_W, N_LVL0, N_LVL2, ELL_LVL2, K, PSI, R

### 4. 🏛️ tb_wop_pbs_kernel
**完整 PBS 内核系统测试**
- **位置**: `pe_pbs/simu/tb_wop_pbs_kernel/`
- **功能**: 验证完整的 WoP-PBS 流程
- **主要参数**: 包含所有模块的完整参数集

## 统一目录结构

每个测试模块都采用相同的目录结构：

```
tb_<module_name>/
├── scripts/
│   ├── run.sh          # 单次参数化仿真
│   └── run_simu.sh     # 批量随机测试
├── gen/
│   ├── info/           # 生成的配置信息
│   └── rtl/            # 生成的 SystemVerilog 包
├── rtl/
│   ├── tb_<name>.sv    # 重构后的测试平台
│   └── tb_<name>.cpp   # C++ 金标准参考
└── README.md           # 模块特定说明
```

## 使用方法

### 快速开始

```bash
# 进入任一测试目录
cd hw/module/pe_pbs/simu/tb_wop_bit_extract_engine/scripts

# 运行单次测试
./run.sh

# 运行批量测试（5次随机参数）
./run_simu.sh -n 5
```

### 参数化测试

每个模块支持的参数化选项：

#### 通用参数
- `-g GLWE_K` : GLWE 参数 K
- `-W MOD_Q_W` : 模数位宽
- `-i/-j/-k` : 寄存器文件参数

#### 模块特定参数
- **bit_extract**: `-B MAX_BIT_WIDTH`, `-N N_LVL1`, `-L LUT_ENTRY_SIZE`
- **premodswitch**: `-0 N_LVL0`, `-2 N_LVL2`
- **circuit_bootstrap**: `-E ELL_LVL2`, `-K K`, `-P PSI`, `-R R`
- **pbs_kernel**: 包含所有参数的完整集合

### 示例

```bash
# 位提取引擎 - 自定义参数
cd tb_wop_bit_extract_engine/scripts
./run.sh -g 2 -W 32 -N 1024 -L 8192

# 电路自举引擎 - 批量测试
cd tb_wop_circuit_bootstrap_woks_engine/scripts
./run_simu.sh -n 10

# 完整系统测试 - 减少迭代次数（复杂度高）
cd tb_wop_pbs_kernel/scripts
./run_simu.sh -n 3
```

## 主要改进

### 🎯 相比原始测试架构的优势

1. **标准化框架**: 统一采用项目标准的 edalize 仿真工具
2. **参数化配置**: 支持灵活的测试参数调整和随机化测试
3. **自动化流程**: 自动生成 SystemVerilog 参数包
4. **批量测试**: 内置随机参数化批量测试，提高覆盖率
5. **一致性接口**: 所有模块使用相同的命令行接口
6. **可扩展性**: 易于添加新的测试模块

### 🔧 技术特性

- **包生成**: 自动生成 `param_tfhe_definition_pkg.sv` 和 `regf_common_definition_pkg.sv`
- **文件管理**: 自动创建 `file_list.json` 配置
- **错误处理**: 统一的成功/失败检测机制
- **日志记录**: 完整的命令行和种子记录

## 测试覆盖范围

### 功能覆盖
- ✅ 位提取算法验证
- ✅ 预模切换逻辑验证  
- ✅ 电路自举 WoKS 流程验证
- ✅ 完整 PBS 内核集成验证

### 参数覆盖
- ✅ 多种模数位宽 (16, 32, 64)
- ✅ 不同 LWE 维度组合
- ✅ 各种寄存器文件配置
- ✅ 随机化参数测试

## 环境要求

### 必需环境变量
```bash
export PROJECT_DIR=/path/to/project/root
export PROJECT_SIMU_TOOL=questa  # 或其他支持的仿真器
```

### 依赖工具
- Python 3.x
- EDA 仿真工具 (Questa, Xsim, 等)
- edalize 框架

## 故障排除

### 常见问题

1. **包生成失败**: 检查 Python 脚本路径和权限
2. **仿真器错误**: 确认 `PROJECT_SIMU_TOOL` 设置正确
3. **权限问题**: 确保脚本有执行权限 (`chmod +x *.sh`)

### 调试选项

```bash
# 跳过包生成（使用现有包）
./run.sh -z

# 详细输出
./run.sh -- -v

# 指定种子
./run.sh -- -s 12345
```

## 性能指标

### 测试复杂度
- **bit_extract**: 轻量级，适合快速验证
- **premodswitch**: 中等复杂度
- **circuit_bootstrap**: 较高复杂度
- **pbs_kernel**: 最高复杂度，完整系统验证

### 建议测试策略
- 开发阶段：使用单模块测试 (bit_extract, premodswitch)
- 集成阶段：使用组合测试 (circuit_bootstrap)
- 验证阶段：使用完整测试 (pbs_kernel)

## 未来扩展

可以轻松添加新的测试模块：

1. 创建新的目录结构
2. 基于现有脚本模板创建 `run.sh` 和 `run_simu.sh`
3. 重构测试文件以兼容 edalize 框架
4. 更新参数配置

---

## 维护信息

- **创建日期**: 2025年1月
- **版本**: v1.0
- **兼容性**: 与原有 Makefile/Verilator 流程并行存在
- **维护者**: 根据项目需要更新