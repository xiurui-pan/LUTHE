# WoP-PBS 仿真脚本使用说明

## 概述

这个目录包含了重构后的 WoP-PBS bit extraction engine 仿真脚本，参考了 pe_alu 的仿真框架结构。

## 目录结构

```
pe_pbs/simu/
├── scripts/
│   ├── run.sh          # 单次仿真脚本（基于 edalize）
│   └── run_simu.sh     # 批量仿真脚本
├── gen/
│   ├── info/           # 生成的信息文件
│   └── rtl/            # 生成的 RTL 包文件
├── rtl/                # 测试文件
│   ├── tb_wop_bit_extract_engine.sv  # SystemVerilog 测试平台
│   └── tb_wop_bit_extract_engine.cpp # C++ 金标准参考
└── README.md           # 本说明文件
```

## 使用方法

### 1. 单次仿真 - run.sh

运行单个测试用例：

```bash
cd hw/module/pe_pbs/simu/scripts
./run.sh [选项]
```

**支持的选项：**
- `-h` : 显示帮助信息
- `-g <值>` : GLWE_K 参数 (默认: 2)
- `-W <值>` : MOD_Q_W 模数宽度 (默认: 32)
- `-q <值>` : MOD_Q 模数值 (默认: 2**32)
- `-B <值>` : MAX_BIT_WIDTH 最大位宽 (默认: 20)
- `-N <值>` : N_LVL1 LWE 维度 (默认: 1024)
- `-L <值>` : LUT_ENTRY_SIZE LUT 项大小 (默认: 8192)
- `-i <值>` : 寄存器文件寄存器数量 (默认: 64)
- `-j <值>` : 寄存器文件系数数量 (默认: 32)
- `-k <值>` : 寄存器文件序列数量 (默认: 4)

**示例：**
```bash
# 默认参数运行
./run.sh

# 自定义参数运行
./run.sh -g 3 -W 64 -N 2048 -L 16384

# 传递额外的 edalize 选项
./run.sh -g 2 -- -s 12345 -v
```

### 2. 批量仿真 - run_simu.sh

运行多个随机参数化的测试：

```bash
cd hw/module/pe_pbs/simu/scripts
./run_simu.sh [选项]
```

**支持的选项：**
- `-h` : 显示帮助信息
- `-n <数量>` : 测试迭代次数 (默认: 5)

**示例：**
```bash
# 运行 5 次测试（默认）
./run_simu.sh

# 运行 10 次测试
./run_simu.sh -n 10

# 传递额外的 edalize 选项
./run_simu.sh -n 3 -- -v
```

## 主要改进

### 相比原始测试脚本的改进：

1. **集成 edalize 框架**：使用项目标准的 edalize 工具进行仿真管理
2. **参数化配置**：支持灵活的参数配置，便于不同测试场景
3. **自动包生成**：自动生成必要的 SystemVerilog 包文件
4. **批量测试**：支持随机参数化的批量测试，提高测试覆盖率
5. **统一接口**：与 pe_alu 等其他模块的仿真脚本保持一致的接口

### 生成的文件：

- `gen/rtl/param_tfhe_definition_pkg.sv` - TFHE 参数包
- `gen/rtl/regf_common_definition_pkg.sv` - 寄存器文件参数包
- `gen/info/file_list.json` - 文件列表配置

## 注意事项

1. 确保设置了正确的环境变量：
   - `PROJECT_DIR` - 项目根目录路径
   - `PROJECT_SIMU_TOOL` - 仿真工具（如 questa, xsim 等）

2. 需要安装相应的 EDA 工具和 Python 依赖

3. 第一次运行时会自动生成必要的包文件，后续运行可使用 `-z` 选项跳过包生成

## 故障排除

如果遇到问题，请检查：

1. 环境变量是否正确设置
2. EDA 工具是否正确安装和配置
3. Python 脚本依赖是否满足
4. 查看生成的日志文件了解详细错误信息

## 兼容性

- 兼容原有的 Makefile/Verilator 测试流程（在 `rtl/tb/` 目录下）
- 新的 edalize 框架提供更好的参数化和集成能力
- 可以根据需要选择使用不同的仿真框架