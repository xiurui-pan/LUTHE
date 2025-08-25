# Phase 1: VP Engine 架构重构详细实施计划

## 📋 **阶段概述**

**目标**: 解决VP Engine架构违规问题，建立清晰的职责边界
**周期**: 2-3周
**优先级**: 🔴 Critical
**预期成果**: VP引擎从14状态精简到7状态，资源使用减少50%+

---

## 🎯 **核心重构目标**

### 问题现状 vs 目标架构

| **方面** | **当前Legacy** | **重构目标** | **改进幅度** |
|---------|---------------|-------------|-------------|
| 状态机复杂度 | 14个状态 | 7个状态 | -50% |
| 代码行数 | 959行 | ~400行 | -58% |
| 职责边界 | 混合PBS逻辑 | 纯CMux Tree | 清晰化 |
| 资源占用 | 重复缓冲区 | 精简缓冲区 | -40% |
| 接口复杂度 | 直接硬件访问 | 服务化接口 | 简化 |

---

## 🏗️ **详细实施步骤**

### **Step 1: 代码备份与环境准备** *(Day 1)*

#### 1.1 完整备份现有实现
```bash
cd hw/module/pe_pbs/rtl/

# 备份原始VP引擎实现
cp wop_vertical_packing_engine.sv wop_vertical_packing_engine_legacy.sv

# 备份测试环境
cp -r simu/tb_wop_vertical_packing_engine simu/tb_wop_vertical_packing_engine_legacy

# 创建重构工作分支标记
echo "# VP Engine Legacy Backup - $(date)" > VP_LEGACY_BACKUP_INFO.md
echo "Original implementation backed up before Phase 1 refactor" >> VP_LEGACY_BACKUP_INFO.md
```

#### 1.2 分析接口依赖关系
```systemverilog
// 分析当前VP引擎的所有接口连接
// 识别需要保留的接口 vs 需要移除的接口

保留接口:
✅ RegFile读写接口 (pep_regf_*)
✅ LUT AXI接口 (m_axi4_glwe_*)  
✅ 基础控制信号 (clk, rst_n, start, done)

移除接口 (移交给PBS):
❌ NTT相关接口
❌ BSK相关接口  
❌ KSK相关接口
❌ 复杂AXI总线接口

新增接口:
🆕 VP-PBS服务接口
```

### **Step 2: VP-PBS通信协议设计** *(Day 2-3)*

#### 2.1 创建VP-PBS接口包
```systemverilog
// 文件: vp_pbs_interface_pkg.sv
package vp_pbs_interface_pkg;
    
    // VP-PBS操作类型枚举
    typedef enum logic [3:0] {
        VP_OP_IDLE             = 4'h0,
        VP_OP_BLIND_ROT_EXTRACT = 4'h1,  // Blind Rotation + Extract + Post-process
        VP_OP_CUSTOM_LUT       = 4'h2,   // 自定义LUT操作
        VP_OP_STATUS_QUERY     = 4'h3    // 状态查询
    } vp_pbs_op_type_e;
    
    // VP-PBS指令结构
    typedef struct packed {
        vp_pbs_op_type_e        operation_type;    // 操作类型
        logic [15:0]            cmux_result_addr;  // CMux结果地址
        logic [15:0]            ggsw_bits_addr;    // GGSW样本地址 (bits 0-9)
        logic [15:0]            output_addr;       // 最终输出地址
        logic [3:0]             bit_range_start;   // 处理位范围开始 (通常为0)
        logic [3:0]             bit_range_end;     // 处理位范围结束 (通常为9)
        logic                   need_post_process; // 是否需要后处理
        logic [31:0]            lut_base_addr;     // LUT基地址
        logic [7:0]             reserved;          // 保留字段
    } vp_pbs_inst_t;
    
    // VP-PBS状态枚举
    typedef enum logic [3:0] {
        VP_PBS_IDLE           = 4'h0,
        VP_PBS_LOADING        = 4'h1,
        VP_PBS_BLIND_ROT      = 4'h2,
        VP_PBS_EXTRACTING     = 4'h3,
        VP_PBS_POST_PROC      = 4'h4,
        VP_PBS_DONE           = 4'h5,
        VP_PBS_ERROR          = 4'hF
    } vp_pbs_state_e;
    
    // VP-PBS响应结构
    typedef struct packed {
        vp_pbs_state_e          current_state;     // 当前处理状态
        logic [15:0]            result_addr;       // 结果地址
        logic [7:0]             result_size;       // 结果大小
        logic [15:0]            progress_counter;  // 进度计数器
        logic                   success;           // 操作成功标志
        logic                   error;             // 错误标志
        logic [7:0]             error_code;        // 错误码
        logic [31:0]            reserved;          // 保留字段
    } vp_pbs_response_t;
    
    // VP-PBS接口定义
    interface vp_pbs_if;
        logic                   inst_vld;          // 指令有效
        logic                   inst_rdy;          // 指令准备好
        logic                   inst_ack;          // 指令确认
        vp_pbs_inst_t          inst;              // 指令数据
        vp_pbs_response_t      response;          // 响应数据
        
        modport master (
            output inst_vld, inst,
            input  inst_rdy, inst_ack, response
        );
        
        modport slave (
            input  inst_vld, inst,
            output inst_rdy, inst_ack, response
        );
    endinterface
    
endpackage
```

#### 2.2 VP引擎接口声明更新
```systemverilog
// 新的VP引擎模块接口 (精简版)
module wop_vertical_packing_engine_lite
    import vp_pbs_interface_pkg::*;
    #(
        // 保持必要参数
        parameter int MOD_Q_W = 32,
        parameter int N_LVL1 = 1024,
        parameter int K = 1,
        parameter int LUT_SIZE = 1024,
        parameter int REGF_ADDR_W = 16
    )(
        // 基础控制
        input  logic clk,
        input  logic s_rst_n,
        input  logic start,
        output logic done,
        
        // RegFile接口 (保留)
        output logic                                    pep_regf_rd_req_vld,
        input  logic                                    pep_regf_rd_req_rdy,
        output logic [REGF_RD_REQ_W-1:0]              pep_regf_rd_req,
        input  logic [REGF_COEF_NB-1:0]               regf_pep_rd_data_avail,
        input  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0]  regf_pep_rd_data,
        
        output logic                                    pep_regf_wr_req_vld,
        input  logic                                    pep_regf_wr_req_rdy,
        output logic [REGF_WR_REQ_W-1:0]              pep_regf_wr_req,
        output logic [REGF_COEF_NB-1:0]               pep_regf_wr_data_vld,
        input  logic [REGF_COEF_NB-1:0]               pep_regf_wr_data_rdy,
        output logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0]  pep_regf_wr_data,
        
        // LUT AXI接口 (简化，只读)
        output logic [AXI4_ID_W-1:0]                   m_axi4_glwe_arid,
        output logic [AXI4_ADD_W-1:0]                  m_axi4_glwe_araddr,
        output logic [AXI4_LEN_W-1:0]                  m_axi4_glwe_arlen,
        output logic [AXI4_SIZE_W-1:0]                 m_axi4_glwe_arsize,
        output logic [AXI4_BURST_W-1:0]                m_axi4_glwe_arburst,
        output logic                                    m_axi4_glwe_arvalid,
        input  logic                                    m_axi4_glwe_arready,
        input  logic [AXI4_ID_W-1:0]                   m_axi4_glwe_rid,
        input  logic [AXI4_DATA_W-1:0]                 m_axi4_glwe_rdata,
        input  logic [AXI4_RESP_W-1:0]                 m_axi4_glwe_rresp,
        input  logic                                    m_axi4_glwe_rlast,
        input  logic                                    m_axi4_glwe_rvalid,
        output logic                                    m_axi4_glwe_rready,
        
        // VP-PBS服务接口 (新增)
        vp_pbs_if.master                               vp_pbs
    );
```

### **Step 3: 精简状态机设计** *(Day 4-5)*

#### 3.1 新状态机架构定义
```systemverilog
// 精简状态机 - 7个状态
typedef enum logic [2:0] {
    IDLE,                  // 0: 等待启动指令
    LOAD_LUT_ENTRIES,      // 1: 加载LUT条目到CMux缓冲区
    LOAD_GGSW_SAMPLES,     // 2: 加载GGSW样本 (bits 10-19)  
    CMUX_TREE_PROCESS,     // 3: CMux Tree处理 (VP核心算法)
    WRITE_CMUX_RESULT,     // 4: 写入CMux结果到RegFile
    VP_PBS_REQUEST,        // 5: 发送VP-PBS请求 (委托bits 0-9处理)
    WAIT_PBS_DONE          // 6: 等待PBS处理完成
} vp_lite_state_e;

vp_lite_state_e current_state, next_state;
```

#### 3.2 状态转换逻辑定义
```systemverilog
// 清晰的状态转换条件
always_comb begin
    next_state = current_state;
    
    case (current_state)
        IDLE: begin
            if (start) begin
                next_state = LOAD_LUT_ENTRIES;
            end
        end
        
        LOAD_LUT_ENTRIES: begin
            if (lut_loading_complete) begin
                next_state = LOAD_GGSW_SAMPLES;
            end
        end
        
        LOAD_GGSW_SAMPLES: begin
            if (ggsw_loading_complete) begin
                next_state = CMUX_TREE_PROCESS;
            end
        end
        
        CMUX_TREE_PROCESS: begin
            if (cmux_tree_complete) begin
                next_state = WRITE_CMUX_RESULT;
            end
        end
        
        WRITE_CMUX_RESULT: begin
            if (cmux_write_complete) begin
                next_state = VP_PBS_REQUEST;
            end
        end
        
        VP_PBS_REQUEST: begin
            if (vp_pbs.inst_rdy && vp_pbs.inst_vld) begin
                next_state = WAIT_PBS_DONE;
            end
        end
        
        WAIT_PBS_DONE: begin
            if (vp_pbs.inst_ack && vp_pbs.response.current_state == VP_PBS_DONE) begin
                next_state = IDLE;  // 完成，返回IDLE
            end
        end
    endcase
end
```

### **Step 4: 存储资源精简** *(Day 6-7)*

#### 4.1 移除不必要的缓冲区
```systemverilog
// ❌ 移除这些存储 (原本属于PBS)
// logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] rotate_lut;
// logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] tmp_mid;  
// logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] tmp_result;
// logic [N_LVL1-1:0][MOD_Q_W-1:0] post_process_lwe_result;
// logic [31:0] post_process_counter;

// ❌ 移除复杂的GGSW存储 (bits 0-9)
// logic [9:0][ELL_LVL1-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] blind_rot_ggsw_samples;
```

#### 4.2 保留VP核心存储
```systemverilog
// ✅ 保留VP专用存储
// CMux Tree双缓冲区 (ping-pong)
logic [1:0][LUT_SIZE-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] cmux_pools;

// GGSW样本存储 (仅bits 10-19)
logic [19:10][ELL_LVL1-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] cmux_tgsw_samples;

// CMux Tree最终结果
logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] cmux_result_tlwe;

// VP控制变量
logic [3:0] bit_counter;         // 当前处理位 (10-19)
logic pool_select;               // 当前活跃pool选择
logic [15:0] lut_load_counter;   // LUT加载计数器
logic [15:0] ggsw_load_counter;  // GGSW加载计数器
```

#### 4.3 地址映射简化
```systemverilog
// 简化的地址计算
logic [REGF_ADDR_W-1:0] lut_base_addr;     // LUT基地址
logic [REGF_ADDR_W-1:0] ggsw_base_addr;    // GGSW基地址 (bits 10-19)
logic [REGF_ADDR_W-1:0] cmux_output_addr;  // CMux输出地址

// VP-PBS请求参数
logic [REGF_ADDR_W-1:0] pbs_ggsw_addr;     // PBS需要的GGSW地址 (bits 0-9)
logic [REGF_ADDR_W-1:0] final_output_addr; // 最终结果地址
```

### **Step 5: CMux Tree算法优化** *(Day 8-10)*

#### 5.1 核心CMux Tree实现
```systemverilog
// VP核心算法: CMux Tree处理 (bits 10-19)
always_ff @(posedge clk) begin
    if (current_state == CMUX_TREE_PROCESS) begin
        // 并行CMux处理
        for (int j = 0; j < entries_at_level; j++) begin
            // 基于GGSW control bit选择输入
            if (tgsw_control_bit[bit_counter]) begin
                // 选择右分支 (j << 1 | 1)
                cmux_pools[pool_next][j] <= cmux_pools[pool_current][j << 1 | 1];
            end else begin
                // 选择左分支 (j << 1)  
                cmux_pools[pool_next][j] <= cmux_pools[pool_current][j << 1];
            end
        end
        
        // 更新控制变量
        bit_counter <= bit_counter + 1;
        pool_select <= ~pool_select;  // ping-pong切换
        entries_at_level <= entries_at_level >> 1;  // 每层减半
        
        // 检查完成条件
        if (bit_counter >= 19) begin
            cmux_tree_complete <= 1'b1;
        end
    end
end
```

#### 5.2 GGSW控制位提取
```systemverilog
// 从GGSW样本中提取控制位
always_comb begin
    // 简化的控制位提取 (基于GGSW样本的符号位)
    tgsw_control_bit[bit_counter] = cmux_tgsw_samples[bit_counter][0][0][0][MOD_Q_W-1];
    
    // 或者使用更复杂的解码逻辑 (如果需要)
    // tgsw_control_bit[bit_counter] = decode_tgsw_bit(cmux_tgsw_samples[bit_counter]);
end

// GGSW解码函数 (如果需要复杂逻辑)
function automatic logic decode_tgsw_bit(
    input logic [ELL_LVL1-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] tgsw_sample
);
    // 这里实现GGSW→bit的解码逻辑
    // 简化版本：直接使用符号位
    return tgsw_sample[0][0][0][MOD_Q_W-1];
endfunction
```

### **Step 6: VP-PBS请求逻辑实现** *(Day 11-12)*

#### 6.1 VP-PBS请求构造
```systemverilog
// VP-PBS请求发送逻辑
always_ff @(posedge clk) begin
    if (current_state == VP_PBS_REQUEST) begin
        // 构造VP-PBS指令
        vp_pbs.inst.operation_type     = VP_OP_BLIND_ROT_EXTRACT;
        vp_pbs.inst.cmux_result_addr   = cmux_output_addr;
        vp_pbs.inst.ggsw_bits_addr     = pbs_ggsw_addr;       // bits 0-9
        vp_pbs.inst.output_addr        = final_output_addr;
        vp_pbs.inst.bit_range_start    = 4'd0;                // bits 0-9
        vp_pbs.inst.bit_range_end      = 4'd9;
        vp_pbs.inst.need_post_process  = 1'b1;               // 需要后处理
        vp_pbs.inst.lut_base_addr      = lut_base_addr;
        
        vp_pbs.inst_vld = 1'b1;
        
        $display("[VP_LITE] Sending VP-PBS request: op=%0d, cmux_addr=0x%0h, ggsw_addr=0x%0h, output_addr=0x%0h", 
                 vp_pbs.inst.operation_type, vp_pbs.inst.cmux_result_addr, 
                 vp_pbs.inst.ggsw_bits_addr, vp_pbs.inst.output_addr);
    end else begin
        vp_pbs.inst_vld = 1'b0;
    end
end
```

#### 6.2 VP-PBS响应处理
```systemverilog
// VP-PBS响应监控
always_ff @(posedge clk) begin
    if (current_state == WAIT_PBS_DONE) begin
        // 监控PBS处理状态
        case (vp_pbs.response.current_state)
            VP_PBS_IDLE: begin
                $display("[VP_LITE] PBS is idle, waiting for processing to start");
            end
            VP_PBS_LOADING: begin
                $display("[VP_LITE] PBS loading CMux result");
            end
            VP_PBS_BLIND_ROT: begin
                $display("[VP_LITE] PBS performing blind rotation, progress=%0d/10", 
                         vp_pbs.response.progress_counter);
            end
            VP_PBS_EXTRACTING: begin
                $display("[VP_LITE] PBS extracting LWE sample");
            end
            VP_PBS_POST_PROC: begin
                $display("[VP_LITE] PBS post-processing (modSwitch + keyswitch)");
            end
            VP_PBS_DONE: begin
                if (vp_pbs.response.success) begin
                    $display("[VP_LITE] ✅ PBS processing completed successfully!");
                    $display("[VP_LITE] Result available at addr=0x%0h, size=%0d", 
                             vp_pbs.response.result_addr, vp_pbs.response.result_size);
                end else begin
                    $error("[VP_LITE] ❌ PBS processing failed with error code=0x%0h", 
                           vp_pbs.response.error_code);
                end
            end
            VP_PBS_ERROR: begin
                $error("[VP_LITE] ❌ PBS encountered error: code=0x%0h", 
                       vp_pbs.response.error_code);
            end
        endcase
    end
end
```

### **Step 7: 测试台适配** *(Day 13-14)*

#### 7.1 测试台接口更新
```systemverilog
// 文件: tb_wop_vertical_packing_engine_lite.sv
module tb_wop_vertical_packing_engine_lite;
    
    // VP-PBS接口实例化
    vp_pbs_if vp_pbs_if_inst();
    
    // VP引擎实例化 (新版)
    wop_vertical_packing_engine_lite #(
        .MOD_Q_W(32),
        .N_LVL1(1024),
        .K(1),
        .LUT_SIZE(1024)
    ) dut (
        .clk(clk),
        .s_rst_n(s_rst_n),  
        .start(start),
        .done(done),
        .vp_pbs(vp_pbs_if_inst.master),
        // 其他接口连接...
    );
    
    // VP-PBS服务器模拟器 (用于测试)
    vp_pbs_server_sim #(
        .RESPONSE_DELAY(100)  // 100 cycles响应延迟
    ) vp_pbs_sim (
        .clk(clk),
        .s_rst_n(s_rst_n),
        .vp_pbs(vp_pbs_if_inst.slave)
    );
    
endmodule
```

#### 7.2 VP-PBS模拟器实现
```systemverilog
// VP-PBS服务器模拟器 (用于VP引擎单独测试)
module vp_pbs_server_sim #(
    parameter int RESPONSE_DELAY = 100
)(
    input  logic clk,
    input  logic s_rst_n,
    vp_pbs_if.slave vp_pbs
);
    
    logic [15:0] delay_counter;
    logic request_received;
    vp_pbs_inst_t received_inst;
    
    always_ff @(posedge clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
            delay_counter <= '0;
            request_received <= 1'b0;
            vp_pbs.inst_rdy <= 1'b1;
            vp_pbs.inst_ack <= 1'b0;
            vp_pbs.response <= '0;
        end else begin
            // 接收VP请求
            if (vp_pbs.inst_vld && vp_pbs.inst_rdy && !request_received) begin
                received_inst <= vp_pbs.inst;
                request_received <= 1'b1;
                delay_counter <= '0;
                vp_pbs.inst_rdy <= 1'b0;
                
                $display("[VP_PBS_SIM] Received request: op=%0d", vp_pbs.inst.operation_type);
            end
            
            // 模拟处理过程
            if (request_received && delay_counter < RESPONSE_DELAY) begin
                delay_counter <= delay_counter + 1;
                
                // 更新响应状态
                if (delay_counter < 20) begin
                    vp_pbs.response.current_state = VP_PBS_LOADING;
                end else if (delay_counter < 80) begin
                    vp_pbs.response.current_state = VP_PBS_BLIND_ROT;
                    vp_pbs.response.progress_counter = (delay_counter - 20) / 6; // 模拟10个bit的进度
                end else if (delay_counter < 90) begin
                    vp_pbs.response.current_state = VP_PBS_EXTRACTING;
                end else begin
                    vp_pbs.response.current_state = VP_PBS_POST_PROC;
                end
            end
            
            // 完成处理
            if (request_received && delay_counter >= RESPONSE_DELAY) begin
                vp_pbs.response.current_state = VP_PBS_DONE;
                vp_pbs.response.result_addr = received_inst.output_addr;
                vp_pbs.response.result_size = 16;  // 假设结果大小
                vp_pbs.response.success = 1'b1;
                vp_pbs.response.error = 1'b0;
                vp_pbs.inst_ack = 1'b1;
                
                $display("[VP_PBS_SIM] ✅ Processing completed, result at addr=0x%0h", 
                         vp_pbs.response.result_addr);
            end
            
            // 重置状态准备下一次请求
            if (vp_pbs.inst_ack) begin
                request_received <= 1'b0;
                vp_pbs.inst_rdy <= 1'b1;
                vp_pbs.inst_ack <= 1'b0;
                vp_pbs.response <= '0;
            end
        end
    end
    
endmodule
```

---

## 📊 **验证与测试计划**

### **测试阶段1: 单元测试** *(Day 15)*
```yaml
CMux Tree测试:
  - 验证ping-pong缓冲区切换
  - 验证位计数器递增逻辑  
  - 验证entries_at_level计算
  - 对比C++参考结果

状态机测试:
  - 验证7个状态的转换逻辑
  - 验证完成条件检查
  - 验证超时问题修复

接口测试:
  - VP-PBS握手协议验证
  - RegFile读写操作验证
  - AXI接口简化验证
```

### **测试阶段2: 集成测试** *(Day 16)*
```yaml
VP引擎端到端:
  - 完整CMux Tree处理流程
  - VP-PBS请求发送验证
  - 与模拟PBS服务器协作

性能验证:
  - 状态机周期数统计
  - 资源使用情况分析
  - 与Legacy版本对比
```

---

## 🎯 **成功标准与验收条件**

### **功能验收标准**
- [ ] **状态机精简**: 从14个状态减少到7个状态
- [ ] **代码行数**: 减少50%以上 (< 480行)
- [ ] **编译通过**: 无语法和接口错误
- [ ] **CMux Tree正确性**: 与C++参考结果100%一致
- [ ] **VP-PBS握手**: 成功发送请求并接收响应
- [ ] **无超时问题**: 所有状态转换在预期时间内完成

### **性能验收标准**
- [ ] **资源节省**: LUT使用减少40%以上
- [ ] **延迟保持**: CMux Tree处理延迟不增加
- [ ] **接口简化**: 移除80%的直接硬件接口
- [ ] **可读性提升**: 代码结构更清晰，注释完善

### **质量验收标准**
- [ ] **架构清晰**: VP与PBS职责边界明确
- [ ] **可维护性**: 模块化设计，易于扩展
- [ ] **文档完整**: 接口定义、状态转换图、测试报告
- [ ] **向后兼容**: Legacy版本可随时回滚

---

## 📋 **风险控制与应急预案**

### **主要风险识别**
1. **CMux Tree算法错误**: 重构过程中破坏核心算法
2. **接口不兼容**: 新接口与现有系统不匹配
3. **性能倒退**: 优化导致性能下降
4. **时间超期**: 复杂度评估不足

### **应急预案**
```yaml
风险1 - 算法错误:
  预防: 逐步验证，每个子模块单独测试
  应急: 回滚到Legacy版本，重新分析问题

风险2 - 接口不兼容:  
  预防: 详细接口设计评审，兼容性检查
  应急: 设计适配层，保持接口兼容

风险3 - 性能倒退:
  预防: 持续性能监控，基准对比
  应急: 性能调优，必要时架构微调

风险4 - 时间超期:
  预防: 每日进度检查，提前识别阻塞
  应急: 优先完成核心功能，次要功能延后
```

---

## 🚀 **预期成果展示**

### **重构前后对比**
```diff
// Legacy实现 (wop_vertical_packing_engine.sv)
- 959 lines of mixed VP/PBS logic
- 14 complex states
- Direct hardware interfaces
- Duplicate buffer allocation
- Timeout issues in post-processing

// 重构实现 (wop_vertical_packing_engine_lite.sv)  
+ ~400 lines of pure CMux Tree logic
+ 7 streamlined states
+ Service-oriented VP-PBS interface
+ Optimized resource usage
+ Robust state machine timing
```

### **架构清晰度提升**
```yaml
职责分离:
  VP Engine: 专注CMux Tree (bits 10-19)
  PBS Kernel: 专注密码学运算 (bits 0-9 + post-processing)

接口简化:
  Legacy: 直接访问NTT/BSK/KSK
  New: 通过VP-PBS服务接口

资源优化:
  Legacy: 重复实现PBS缓冲区
  New: 复用PBS kernel基础设施
```

**Phase 1完成后，LUTHE WoP-PBS架构将具备生产级的清晰度和可维护性，为Phase 2的PBS深度集成奠定坚实基础。**