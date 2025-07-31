# WoP-PBS RTL Testbench Suite

## 📁 文件夹结构

这个文件夹包含了所有WoP-PBS RTL模块的测试代码，采用了基于原始C++代码的黄金标准验证方法。

```
tb/
├── README.md                              # 本文件
├── Makefile                               # 构建系统
├── run_tests.sh                           # 自动化测试脚本
├── tb_wop_bit_extract_engine.sv           # 比特提取引擎测试
├── tb_wop_bit_extract_engine.cpp          # 比特提取引擎C++驱动
├── tb_wop_premodswitch_engine.sv          # Pre-ModSwitch引擎测试
├── tb_wop_premodswitch_engine.cpp         # Pre-ModSwitch引擎C++驱动
├── tb_wop_circuit_bootstrap_woks_engine.sv # 电路自举引擎测试
├── tb_wop_circuit_bootstrap_woks_engine.cpp# 电路自举引擎C++驱动
└── tb_wop_pbs_kernel.sv                   # 完整系统测试
└── tb_wop_pbs_kernel.cpp                  # 完整系统C++驱动
```

## 🎯 设计理念

### 直接调用原始C++代码
与传统的testbench不同，我们的测试方法直接调用`tfhe-cpu-baseline-wopbs/src/`中的原始C++函数作为黄金标准，这样的好处是：

1. **100%准确性**: 直接使用算法作者的实现，避免重新实现带来的错误
2. **易于协同**: C++代码更新时，测试自动跟上，便于与算法开发者协同
3. **减少维护**: 不需要维护两套算法实现
4. **真实验证**: 确保RTL实现与原始算法完全一致

### DPI-C接口设计
我们使用SystemVerilog的DPI-C接口来连接RTL testbench和C++黄金标准：

```systemverilog
// 导入C++函数
import "DPI-C" function void init_golden_reference();
import "DPI-C" function void run_golden_reference(
  input bit [31:0] input_data[],
  output bit [31:0] expected_output[]
);
import "DPI-C" function void cleanup_golden_reference();
```

```cpp
// C++端导出函数
extern "C" {
  void init_golden_reference();
  void run_golden_reference(const svBitVecVal* input_data, svBitVecVal* expected_output);
  void cleanup_golden_reference();
}
```

## 🧪 测试覆盖范围

### 1. 比特提取引擎 (`tb_wop_bit_extract_engine`)
- **测试函数**: `bitExtract()` from `bit_extract.cpp`
- **功能**: 从加密数据中提取第27位和第31位
- **验证点**: 两个输出LWE样本的正确性

### 2. Pre-ModSwitch引擎 (`tb_wop_premodswitch_engine`)
- **测试函数**: `preModSwitch()` from `circuit_bootstrapping.cpp`
- **功能**: 模运算和除法操作
- **验证点**: abar数组的计算精度

### 3. 电路自举引擎 (`tb_wop_circuit_bootstrap_woks_engine`)
- **测试函数**: `circuitBootstrapWoKS()` from `circuit_bootstrapping.cpp`
- **功能**: 测试向量生成、盲旋转、外部积计算
- **验证点**: 完整的电路自举流程

### 4. 完整系统测试 (`tb_wop_pbs_kernel`)
- **测试函数**: 完整的WoP-PBS流程
- **功能**: 端到端的三阶段算法验证
- **验证点**: 整个系统的数据流和状态机

## 🚀 快速开始

### 环境要求
- Verilator (>= 4.0)
- GCC/Clang (支持C++17)
- Make

### 运行所有测试
```bash
# 进入测试目录
cd tb/

# 运行所有测试
./run_tests.sh

# 或者使用Makefile
make test_all
```

### 运行单个测试
```bash
# 测试比特提取引擎
make test_bit_extract

# 测试Pre-ModSwitch引擎
make test_premodswitch

# 测试电路自举引擎
make test_circuit_bootstrap

# 测试完整系统
make test_wop_pbs_kernel
```

### 生成波形文件
```bash
# 生成波形（FST格式）
make waves_bit_extract

# 使用GTKWave查看
gtkwave build/tb_wop_bit_extract_engine.fst
```

## 🔧 自定义测试

### 修改测试参数
可以在各个testbench的参数部分修改测试配置：

```systemverilog
// 在testbench顶部
parameter int MOD_Q_W = 32;
parameter int N_LVL1 = 1024;
parameter int TEST_CASES = 10;  // 测试用例数量
```

### 添加新的测试
1. 创建新的`.sv`和`.cpp`文件
2. 在Makefile中添加对应的测试目标
3. 实现DPI-C接口函数
4. 更新`run_tests.sh`脚本

## 📊 测试报告

测试运行后会生成以下输出：
- **控制台输出**: 实时测试进度和结果
- **波形文件**: `build/*.fst` - 用于调试的波形
- **日志文件**: `logs/*.log` - 详细的测试日志

### 典型输出示例
```
=== Test Case 1 ===
Generated test vectors using C++ golden reference
Bit extraction completed
✅ Test PASSED: Bit extraction results match golden reference

=== Test Summary ===
Total Tests: 4
Passed: 4
Failed: 0
🎉 ALL TESTS PASSED! WoP-PBS implementation is ready!
```

## 🐛 调试指南

### 1. 波形调试
```bash
# 生成波形
make waves_bit_extract

# 用GTKWave查看
gtkwave build/tb_wop_bit_extract_engine.fst
```

### 2. 日志分析
```bash
# 查看详细日志
cat logs/bit_extract.log

# 搜索错误信息
grep -i error logs/*.log
```

### 3. C++调试
如果需要调试C++黄金标准代码：
```bash
# 使用GDB调试
make debug_kernel
```

## 📝 注意事项

1. **编译依赖**: 确保能正确编译`tfhe-cpu-baseline-wopbs/src/`中的C++代码
2. **路径设置**: Makefile中的`CPP_SRC_DIR`路径需要正确指向C++源码目录
3. **参数一致性**: 确保RTL和C++使用相同的TFHE参数
4. **内存管理**: C++端需要正确管理动态分配的内存

## 🔄 持续集成

这个测试套件设计为可以集成到CI/CD流程中：
```bash
# CI脚本示例
./run_tests.sh --quick  # 快速测试
echo $?  # 检查退出码，0表示成功
```

## 📞 支持

如果遇到问题：
1. 检查环境依赖是否正确安装
2. 确认C++源码路径配置正确
3. 查看日志文件获取详细错误信息
4. 使用波形文件进行调试分析