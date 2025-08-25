# Phase 2: PBS 集成优化详细实施计划

## 📋 **阶段概述**

**目标**: 完善VP-PBS协作机制，优化资源共享，实现端到端Big LUT功能
**周期**: 3-4周  
**优先级**: 🟡 High
**前置条件**: Phase 1 VP Engine重构完成
**预期成果**: 真实PBS模块集成，端到端验证通过，性能提升20-30%

---

## 🎯 **核心集成目标**

### Phase 1成果 → Phase 2目标

| **方面** | **Phase 1输出** | **Phase 2目标** | **集成重点** |
|---------|----------------|---------------|-------------|
| VP架构 | 精简7状态CMux引擎 | VP-PBS协作就绪 | 接口对接 |
| PBS支持 | VP-PBS接口定义 | 真实PBS集成 | 资源调度 |
|功能完整性 | CMux Tree验证 | 端到端Big LUT | 算法验证 |
| 性能优化 | 资源节省40% | 吞吐量提升30% | 并行优化 |
| 质量水平 | 架构重构完成 | 生产就绪 | 稳定性验证 |

---

## 🏗️ **详细实施步骤**

### **Step 1: wop_pbs_kernel扩展设计** *(Week 1, Day 1-3)*

#### 1.1 PBS Kernel接口扩展分析
```systemverilog
// 当前wop_pbs_kernel.sv接口分析
// 需要添加VP专用处理能力

// 现有接口 (保留)
✅ NTT Core接口
✅ BSK Manager接口  
✅ KSK Manager接口
✅ RegFile接口
✅ 基础控制信号

// 新增接口 (VP支持)
🆕 VP-PBS指令接口
🆕 VP资源调度接口
🆕 VP状态报告接口
```

#### 1.2 VP支持的PBS Kernel架构设计
```systemverilog
// 扩展的PBS Kernel模块声明
module wop_pbs_kernel_vp_enhanced
    import vp_pbs_interface_pkg::*;
    #(
        // 继承现有参数
        parameter int MOD_Q_W = 32,
        parameter int N_LVL1 = 1024,
        parameter int K = 1,
        // 新增VP支持参数
        parameter int VP_REQUEST_FIFO_DEPTH = 8,
        parameter int VP_RESPONSE_BUFFER_SIZE = 4
    )(
        // 现有接口 (完整保留)
        input  logic clk, s_rst_n,
        // ... 所有现有PBS接口 ...
        
        // VP专用接口 (新增)
        input  vp_pbs_inst_t                    vp_pbs_inst,
        input  logic                            vp_pbs_inst_vld,
        output logic                            vp_pbs_inst_rdy,
        output logic                            vp_pbs_inst_ack,
        output vp_pbs_response_t                vp_pbs_response,
        
        // VP资源调度接口 (新增)
        output logic                            vp_resource_grant,
        output logic [7:0]                      vp_priority_level,
        input  logic                            vp_resource_release
    );
```

#### 1.3 VP请求处理状态机设计
```systemverilog
// VP请求处理专用状态机
typedef enum logic [3:0] {
    VP_IDLE,                    // VP处理空闲
    VP_REQUEST_DECODE,          // VP请求解码
    VP_RESOURCE_ACQUIRE,        // 获取PBS资源 (NTT/BSK/KSK)
    VP_LOAD_CMUX_RESULT,        // 加载VP的CMux结果
    VP_LOAD_GGSW_BITS,          // 加载GGSW样本 (bits 0-9)
    VP_BLIND_ROTATION,          // 盲旋转处理
    VP_SAMPLE_EXTRACT,          // 样本提取
    VP_POST_PROCESSING,         // 后处理 (modSwitch + keyswitch)
    VP_WRITE_RESULT,            // 写入最终结果
    VP_RESPONSE_SEND,           // 发送完成响应
    VP_RESOURCE_RELEASE,        // 释放PBS资源
    VP_ERROR                    // 错误状态
} vp_pbs_state_e;

vp_pbs_state_e vp_current_state, vp_next_state;
```

### **Step 2: 资源调度机制实现** *(Week 1, Day 4-7)*

#### 2.1 PBS资源仲裁器设计
```systemverilog
// PBS资源调度器 - 支持多客户端 (Bit Extract + Circuit Bootstrap + VP)
module pbs_resource_scheduler #(
    parameter int NUM_CLIENTS = 3,  // BE + CB + VP
    parameter int RESOURCE_TIMEOUT = 10000
)(
    input  logic clk, s_rst_n,
    
    // 客户端请求接口
    input  logic [NUM_CLIENTS-1:0]              client_req,
    input  logic [NUM_CLIENTS-1:0][7:0]         client_priority,
    output logic [NUM_CLIENTS-1:0]              client_grant,
    input  logic [NUM_CLIENTS-1:0]              client_release,
    
    // 资源状态接口
    output logic                                 ntt_busy,
    output logic                                 bsk_busy,
    output logic                                 ksk_busy,
    output logic [7:0]                           active_client_id
);

    // 优先级仲裁逻辑
    always_comb begin
        // 默认: 无授权
        client_grant = '0;
        
        // 固定优先级: VP (2) > Circuit Bootstrap (1) > Bit Extract (0)
        if (client_req[2] && !ntt_busy && !bsk_busy && !ksk_busy) begin
            client_grant[2] = 1'b1;  // VP优先
            active_client_id = 8'd2;
        end else if (client_req[1] && !ntt_busy && !bsk_busy) begin
            client_grant[1] = 1'b1;  // Circuit Bootstrap次优先
            active_client_id = 8'd1;
        end else if (client_req[0] && !ntt_busy) begin
            client_grant[0] = 1'b1;  // Bit Extract最低优先级
            active_client_id = 8'd0;
        end
    end
    
    // 资源占用状态管理
    always_ff @(posedge clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
            ntt_busy <= 1'b0;
            bsk_busy <= 1'b0;
            ksk_busy <= 1'b0;
        end else begin
            // VP需要所有资源
            if (client_grant[2]) begin
                ntt_busy <= 1'b1;
                bsk_busy <= 1'b1;  
                ksk_busy <= 1'b1;
            end 
            // Circuit Bootstrap需要BSK + NTT
            else if (client_grant[1]) begin
                ntt_busy <= 1'b1;
                bsk_busy <= 1'b1;
                ksk_busy <= 1'b0;
            end
            // Bit Extract只需要NTT
            else if (client_grant[0]) begin
                ntt_busy <= 1'b1;
                bsk_busy <= 1'b0;
                ksk_busy <= 1'b0;
            end
            
            // 资源释放
            if (|client_release) begin
                ntt_busy <= 1'b0;
                bsk_busy <= 1'b0;
                ksk_busy <= 1'b0;
            end
        end
    end
    
endmodule
```

#### 2.2 VP专用操作实现
```systemverilog
// VP专用的Blind Rotation + Extract + Post-processing实现
always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
        vp_current_state <= VP_IDLE;
        // 初始化VP处理变量
    end else begin
        vp_current_state <= vp_next_state;
        
        case (vp_current_state)
            VP_LOAD_CMUX_RESULT: begin
                // 从RegFile加载VP Engine的CMux结果
                if (regf_data_available) begin
                    vp_cmux_result[vp_load_counter] <= regf_rd_data;
                    vp_load_counter <= vp_load_counter + 1;
                end
            end
            
            VP_BLIND_ROTATION: begin
                // 使用真实BSK Manager执行盲旋转
                // 对bits 0-9循环处理
                if (bsk_data_available && vp_blind_rot_bit < 10) begin
                    // 调用真实的盲旋转逻辑 (复用pe_pbs_with_bsk)
                    vp_execute_blind_rotation_step(vp_blind_rot_bit);
                    vp_blind_rot_bit <= vp_blind_rot_bit + 1;
                end
            end
            
            VP_SAMPLE_EXTRACT: begin
                // 实现tLwe32ExtractSample_lvl1等效功能
                vp_extracted_lwe[0] <= vp_tlwe_result[0][0];  // a[0] = TLWE.a[0][0] 
                for (int i = 1; i < N_LVL1; i++) begin
                    // a[i] = -TLWE.a[0][N-i] (negacyclic特性)
                    vp_extracted_lwe[i] <= -vp_tlwe_result[0][N_LVL1-i];
                end
                vp_extracted_lwe[N_LVL1] <= vp_tlwe_result[1][0]; // b = TLWE.b[0]
            end
            
            VP_POST_PROCESSING: begin
                // 1. modSwitchToTorus32(2, FULL_MSG_SIZE)
                logic [31:0] mod_switch_offset = 32'h40000000; // 2^30
                vp_final_result[N_LVL1] <= vp_extracted_lwe[N_LVL1] + mod_switch_offset;
                
                // 2. 调用真实KSK Manager执行keyswitch
                if (ksk_data_available) begin
                    // 使用pe_pbs_with_ksk执行keyswitch
                    vp_execute_keyswitch(vp_extracted_lwe, vp_final_result);
                end
            end
        endcase
    end
end
```

### **Step 3: 真实PBS模块集成** *(Week 2, Day 1-4)*

#### 3.1 利用现有wop_pbs_kernel_lite基础
```systemverilog
// 基于现有的wop_pbs_kernel_lite.sv进行扩展
// 该模块已经集成了真实BSK和KSK模块

// 集成策略: 扩展而非重写
module wop_pbs_kernel_vp_integrated
    // 继承wop_pbs_kernel_lite的所有参数和接口
    import common_definition_pkg::*;
    // ... 所有现有import ...
    #(
        // 继承所有现有参数
        parameter int MOD_Q_W = 32,
        // ... 
        // 新增VP专用参数
        parameter int VP_FIFO_DEPTH = 16
    )(
        // 继承所有现有接口
        input  logic clk, s_rst_n,
        // ... 所有现有信号 ...
        
        // 新增VP接口
        vp_pbs_if.slave vp_pbs_interface
    );
    
    // 实例化现有的lite版本作为核心
    wop_pbs_kernel_lite #(
        .MOD_Q_W(MOD_Q_W),
        .MAX_BIT_WIDTH(MAX_BIT_WIDTH),
        // ... 所有参数传递 ...
    ) pbs_core (
        .clk(clk),
        .s_rst_n(s_rst_n),
        .vp_pbs_inst(vp_pbs_interface.inst),
        .vp_pbs_inst_vld(vp_pbs_interface.inst_vld),
        .vp_pbs_inst_rdy(vp_pbs_interface.inst_rdy),
        .vp_pbs_inst_ack(vp_pbs_interface.inst_ack),
        .vp_pbs_response(vp_pbs_interface.response),
        // ... 所有其他接口连接 ...
    );
    
    // 添加VP专用增强逻辑 (如果需要)
    // 例如: 性能监控, 错误处理, 调试接口等
    
endmodule
```

#### 3.2 BSK/KSK模块参数优化
基于现有实现已解决的配置问题:
```systemverilog
// wop_pbs_kernel_lite.sv中已解决的配置
✅ BSK_PC = 2 (匹配BSK_CUT_NB)
✅ KSK_PC = 1 (KSK端口数配置)  
✅ LBX_OVERRIDE = 4 (强制LBX=4)
✅ KS_BLOCK_COL_W_MIN = 2 (确保KS_BLOCK_COL_W>=2)

// 进一步优化建议
parameter int BSK_RESPONSE_TIMEOUT = 1000;  // BSK响应超时
parameter int KSK_RESPONSE_TIMEOUT = 2000;  // KSK响应超时
parameter int VP_PRIORITY_BOOST = 8;        // VP请求优先级提升
```

#### 3.3 AXI4接口验证与优化
```systemverilog
// 验证现有AXI4接口配置
// wop_pbs_kernel_lite.sv中的AXI4接口已经正确连接

// KSK AXI4接口验证
initial begin
    $display("=== AXI4 Interface Verification ===");
    $display("KSK_PC = %0d", KSK_PC);
    $display("AXI4_ID_W = %0d", axi_if_ksk_axi_pkg::AXI4_ID_W);
    $display("AXI4_ADD_W = %0d", axi_if_ksk_axi_pkg::AXI4_ADD_W);
    $display("AXI4_DATA_W = %0d", axi_if_ksk_axi_pkg::AXI4_DATA_W);
    
    // 验证信号宽度匹配
    assert(KSK_PC > 0) else $error("KSK_PC must be > 0");
    assert($bits(m_axi4_ksk_arid) == KSK_PC * axi_if_ksk_axi_pkg::AXI4_ID_W)
        else $error("KSK AXI4 arid width mismatch");
end

// 性能监控增强
always_ff @(posedge clk) begin
    if (vp_pbs_inst_vld && vp_pbs_inst_rdy) begin
        $display("[PBS_KERNEL_VP] VP request received at time %0t", $time);
        vp_request_timestamp <= $time;
    end
    
    if (vp_pbs_inst_ack) begin
        vp_response_timestamp <= $time;
        vp_processing_latency <= vp_response_timestamp - vp_request_timestamp;
        $display("[PBS_KERNEL_VP] VP request completed, latency = %0d cycles", vp_processing_latency);
    end
end
```

### **Step 4: 端到端测试环境构建** *(Week 2, Day 5-7)*

#### 4.1 完整系统测试台设计
```systemverilog
// 文件: tb_vp_pbs_integration.sv
// 完整的VP-PBS集成测试台

module tb_vp_pbs_integration;
    
    // 时钟和复位
    logic clk = 0;
    logic s_rst_n;
    always #5 clk = ~clk;
    
    // VP-PBS接口
    vp_pbs_if vp_pbs_if_inst();
    
    // RegFile模拟器接口
    pep_regf_if regf_if_inst();
    
    // AXI接口模拟器
    axi_if_glwe_sim axi_glwe_sim();
    axi_if_ksk_sim axi_ksk_sim();
    
    // VP Engine实例 (重构版)
    wop_vertical_packing_engine_lite #(
        .MOD_Q_W(32),
        .N_LVL1(1024),
        .K(1),
        .LUT_SIZE(1024)
    ) vp_engine (
        .clk(clk),
        .s_rst_n(s_rst_n),
        .start(start_vp),
        .done(done_vp),
        .vp_pbs(vp_pbs_if_inst.master),
        // RegFile and AXI connections...
    );
    
    // PBS Kernel实例 (集成版)
    wop_pbs_kernel_vp_integrated #(
        .MOD_Q_W(32),
        .N_LVL1(1024),
        .K(1),
        // 真实BSK/KSK参数
        .BSK_PC(2),
        .KSK_PC(1)
    ) pbs_kernel (
        .clk(clk),
        .s_rst_n(s_rst_n),
        .vp_pbs_interface(vp_pbs_if_inst.slave),
        // 所有其他接口连接...
    );
    
    // 测试用例
    initial begin
        // 测试初始化
        s_rst_n = 0;
        start_vp = 0;
        #100;
        s_rst_n = 1;
        #50;
        
        // 准备测试数据
        prepare_test_data();
        
        // 启动VP Engine
        $display("[TEST] Starting VP Engine at time %0t", $time);
        start_vp = 1;
        #10;
        start_vp = 0;
        
        // 等待VP Engine完成CMux Tree
        wait(vp_engine.current_state == vp_engine.VP_PBS_REQUEST);
        $display("[TEST] VP Engine completed CMux Tree, sending PBS request");
        
        // 等待PBS处理完成
        wait(done_vp);
        $display("[TEST] ✅ Complete Big LUT evaluation finished at time %0t", $time);
        
        // 验证结果
        verify_results();
        
        #1000;
        $finish;
    end
    
    // 测试数据准备
    task prepare_test_data();
        // 准备20位输入数据
        logic [19:0] test_input = 20'h12345;  // 0x12345 = 74565
        
        // 准备LUT数据 (2^20 = 1M entries)
        // 这里使用简化的测试LUT (例如: f(x) = x^2 mod 2^32)
        for (int i = 0; i < 2**20; i++) begin
            test_lut[i] = i * i;  // 简单的平方函数
        end
        
        // 模拟加载到内存
        load_test_data_to_memory(test_input, test_lut);
        
        $display("[TEST] Test data prepared: input=0x%05h, LUT size=%0d entries", test_input, 2**20);
    endtask
    
    // 结果验证
    task verify_results();
        logic [31:0] expected_result, actual_result;
        
        // 从内存读取实际结果
        actual_result = read_result_from_memory();
        
        // 计算期望结果 (基于C++参考实现)
        expected_result = calculate_expected_result();
        
        // 对比验证
        if (actual_result == expected_result) begin
            $display("[TEST] ✅ PASS: Result verification successful");
            $display("[TEST]     Expected: 0x%08h", expected_result);  
            $display("[TEST]     Actual:   0x%08h", actual_result);
        end else begin
            $error("[TEST] ❌ FAIL: Result mismatch");
            $error("[TEST]     Expected: 0x%08h", expected_result);
            $error("[TEST]     Actual:   0x%08h", actual_result);
        end
    endtask
    
endmodule
```

#### 4.2 C++参考对比验证
```cpp
// 文件: reference_verification.cpp
// 用于生成测试向量和验证结果

#include "tfhe_functions.h"
#include "context.h"

class VPPBSTestVector {
public:
    // 生成测试向量
    void generate_test_vectors() {
        Context* env = init_context();
        
        // 生成20位输入
        uint32_t input_20bit = 0x12345;  // 与SystemVerilog一致
        
        // 分解为20个LWE样本
        LweSample32* input_lwe = decompose_to_lwe(input_20bit, env);
        
        // 生成LUT (与SystemVerilog一致: f(x) = x^2)
        TLweSample32* lut_samples = generate_square_lut(env);
        
        // 执行完整Big LUT评估
        LweSample32* result = new_LweSample32(env->n_lvl0);
        bigLut_20bit_lvl1(result, lut_samples, input_lwe, env);
        
        // 输出期望结果供SystemVerilog验证使用
        export_expected_result(result, "expected_result.txt");
        
        printf("Reference calculation completed\n");
        printf("Input: 0x%05x, Expected result: 0x%08x\n", 
               input_20bit, extract_result_value(result));
        
        cleanup(env, input_lwe, lut_samples, result);
    }
    
private:
    // 实现辅助函数...
};

int main() {
    VPPBSTestVector test_gen;
    test_gen.generate_test_vectors();
    return 0;
}
```

### **Step 5: 性能优化与并行化** *(Week 3, Day 1-4)*

#### 5.1 并行CMux处理优化
```systemverilog
// VP Engine中的并行CMux优化
parameter int CMUX_PARALLEL_UNITS = 4;  // 并行处理4个CMux

// 并行CMux处理逻辑
genvar g;
generate
    for (g = 0; g < CMUX_PARALLEL_UNITS; g++) begin : cmux_parallel_gen
        always_ff @(posedge clk) begin
            if (current_state == CMUX_TREE_PROCESS && (g < entries_at_level)) begin
                logic control_bit = tgsw_control_bit[bit_counter];
                
                if (control_bit) begin
                    cmux_pools[pool_next][g] <= cmux_pools[pool_current][(g << 1) | 1]; // 右分支
                end else begin
                    cmux_pools[pool_next][g] <= cmux_pools[pool_current][g << 1];       // 左分支
                end
            end
        end
    end
endgenerate

// 并行处理完成检测
always_comb begin
    cmux_parallel_complete = (entries_at_level <= CMUX_PARALLEL_UNITS) && 
                           (cmux_process_counter >= entries_at_level);
end
```

#### 5.2 PBS资源利用优化
```systemverilog
// PBS资源流水线优化
always_ff @(posedge clk) begin
    case (vp_current_state)
        VP_BLIND_ROTATION: begin
            // 流水线式盲旋转: 当前位处理 + 下一位预取
            if (vp_blind_rot_bit < 9) begin
                // 并行处理: 当前位 + 预取下一位的GGSW
                execute_blind_rotation(vp_blind_rot_bit);
                prefetch_ggsw_sample(vp_blind_rot_bit + 1);
            end
        end
        
        VP_SAMPLE_EXTRACT: begin
            // 优化的样本提取: 使用向量化处理
            for (int i = 0; i < N_LVL1; i += 4) begin  // 每次处理4个系数
                extract_coefficients_vectorized(i, i+3);
            end
        end
        
        VP_POST_PROCESSING: begin
            // 流水线后处理: modSwitch与keyswitch重叠
            if (!modswitch_done) begin
                execute_modswitch();
            end
            if (modswitch_done && !keyswitch_done) begin
                execute_keyswitch();  // 与下一个modSwitch重叠
            end
        end
    endcase
end
```

#### 5.3 性能监控与调优
```systemverilog
// 性能计数器模块
module vp_pbs_performance_monitor (
    input  logic clk, s_rst_n,
    input  logic vp_start, vp_done,
    input  logic [2:0] vp_current_state,
    input  logic [3:0] pbs_current_state,
    
    output logic [31:0] total_cycles,
    output logic [31:0] cmux_cycles,
    output logic [31:0] blind_rot_cycles,
    output logic [31:0] extract_cycles,
    output logic [31:0] post_proc_cycles,
    output logic [31:0] throughput_ops_per_sec
);
    
    always_ff @(posedge clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
            total_cycles <= '0;
            cmux_cycles <= '0;
            // ... 其他计数器初始化 ...
        end else begin
            // 总周期计数
            if (vp_start || (!vp_done && total_cycles > 0)) begin
                total_cycles <= total_cycles + 1;
            end
            
            // 分阶段计数
            case (vp_current_state)
                3'd3: cmux_cycles <= cmux_cycles + 1;        // CMUX_TREE_PROCESS
                default: begin
                    case (pbs_current_state)
                        4'd2: blind_rot_cycles <= blind_rot_cycles + 1;  // VP_BLIND_ROT
                        4'd3: extract_cycles <= extract_cycles + 1;      // VP_EXTRACTING  
                        4'd4: post_proc_cycles <= post_proc_cycles + 1;  // VP_POST_PROC
                    endcase
                end
            endcase
            
            // 吞吐量计算 (每秒完成的Big LUT评估数)
            if (vp_done) begin
                throughput_ops_per_sec <= (1000000000 / total_cycles);  // 假设1GHz时钟
                total_cycles <= '0;  // 重置准备下一次测量
            end
        end
    end
    
endmodule
```

### **Step 6: 稳定性验证与错误处理** *(Week 3, Day 5-7)*

#### 6.1 错误处理机制
```systemverilog
// VP-PBS错误处理和恢复机制
typedef enum logic [7:0] {
    ERR_NONE                = 8'h00,
    ERR_VP_TIMEOUT          = 8'h01,  // VP处理超时
    ERR_PBS_TIMEOUT         = 8'h02,  // PBS响应超时
    ERR_BSK_FAILURE         = 8'h03,  // BSK操作失败
    ERR_KSK_FAILURE         = 8'h04,  // KSK操作失败
    ERR_REGFILE_ACCESS      = 8'h05,  // RegFile访问错误
    ERR_AXI_TIMEOUT         = 8'h06,  // AXI总线超时
    ERR_RESOURCE_DEADLOCK   = 8'h07,  // 资源死锁
    ERR_DATA_CORRUPTION     = 8'h08   // 数据损坏
} vp_pbs_error_code_e;

// 错误检测与恢复逻辑
always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
        error_state <= ERR_NONE;
        timeout_counter <= '0;
    end else begin
        // 超时检测
        if (vp_processing_active) begin
            timeout_counter <= timeout_counter + 1;
            
            // VP超时检测 (10000 cycles)
            if (timeout_counter > 10000 && vp_current_state != VP_IDLE) begin
                error_state <= ERR_VP_TIMEOUT;
                $error("[VP_PBS] VP processing timeout in state %0d at time %0t", vp_current_state, $time);
            end
            
            // PBS超时检测 (20000 cycles)  
            if (timeout_counter > 20000 && pbs_processing) begin
                error_state <= ERR_PBS_TIMEOUT;
                $error("[VP_PBS] PBS processing timeout in state %0d at time %0t", pbs_current_state, $time);
            end
        end else begin
            timeout_counter <= '0;
        end
        
        // 资源死锁检测
        if (resource_request_pending && resource_timeout_counter > 5000) begin
            error_state <= ERR_RESOURCE_DEADLOCK;
            $error("[VP_PBS] Resource deadlock detected - forcing recovery");
            
            // 强制资源释放
            force_resource_release <= 1'b1;
        end
        
        // 错误恢复
        if (error_state != ERR_NONE) begin
            // 执行错误恢复程序
            execute_error_recovery(error_state);
        end
    end
end

// 错误恢复任务
task execute_error_recovery(input vp_pbs_error_code_e error_code);
    case (error_code)
        ERR_VP_TIMEOUT: begin
            // VP超时恢复: 重置VP状态机
            vp_current_state <= VP_IDLE;
            reset_vp_state_variables();
            $display("[RECOVERY] VP timeout recovered, state reset to IDLE");
        end
        
        ERR_PBS_TIMEOUT: begin
            // PBS超时恢复: 重置PBS并释放资源  
            pbs_force_reset <= 1'b1;
            release_all_resources();
            $display("[RECOVERY] PBS timeout recovered, resources released");
        end
        
        ERR_RESOURCE_DEADLOCK: begin
            // 死锁恢复: 强制释放所有资源
            force_resource_release <= 1'b1;
            resource_request_pending <= 1'b0;
            $display("[RECOVERY] Resource deadlock resolved, all resources freed");
        end
        
        default: begin
            // 通用恢复: 重置整个VP-PBS系统
            system_soft_reset <= 1'b1;
            $display("[RECOVERY] General error recovery, soft reset triggered");
        end
    endcase
    
    // 清除错误状态
    error_state <= ERR_NONE;
endtask
```

#### 6.2 压力测试与边界条件
```systemverilog
// 压力测试场景生成器
module vp_pbs_stress_tester (
    input  logic clk, s_rst_n,
    output logic start_test,
    output logic [19:0] test_input,
    output logic [31:0] test_lut_addr,
    input  logic test_complete,
    input  logic test_pass
);
    
    logic [15:0] test_counter;
    logic [31:0] pass_count, fail_count;
    
    // 测试案例生成
    always_ff @(posedge clk) begin
        if (test_counter < 1000) begin  // 1000个测试案例
            // 生成不同类型的测试输入
            case (test_counter % 10)
                0: test_input = 20'h00000;      // 边界: 最小值
                1: test_input = 20'hFFFFF;      // 边界: 最大值  
                2: test_input = 20'h80000;      // 边界: 中点
                3: test_input = 20'h55555;      // 模式: 01010101...
                4: test_input = 20'hAAAAA;      // 模式: 10101010...
                5: test_input = $random;         // 随机值
                6: test_input = 20'h12345;      // 固定测试值
                7: test_input = test_counter[19:0]; // 递增序列
                8: test_input = ~test_counter[19:0]; // 递减序列
                9: test_input = {test_counter[9:0], test_counter[9:0]}; // 重复模式
            endcase
            
            start_test <= 1'b1;
            test_counter <= test_counter + 1;
        end else begin
            start_test <= 1'b0;
            $display("[STRESS_TEST] Completed %0d tests: %0d pass, %0d fail", 
                     test_counter, pass_count, fail_count);
        end
        
        // 统计测试结果
        if (test_complete) begin
            if (test_pass) begin
                pass_count <= pass_count + 1;
            end else begin
                fail_count <= fail_count + 1;
                $error("[STRESS_TEST] Test %0d FAILED with input 0x%05h", test_counter-1, test_input);
            end
        end
    end
    
endmodule
```

---

## 📊 **验证与测试计划**

### **测试层级1: 模块级验证** *(Week 4, Day 1-2)*
```yaml
VP-PBS接口测试:
  - 握手协议正确性
  - 指令编码/解码验证
  - 响应状态机验证
  - 超时和错误处理

资源调度测试:
  - 多客户端仲裁验证
  - 优先级正确性
  - 死锁避免验证
  - 资源释放及时性
```

### **测试层级2: 集成验证** *(Week 4, Day 3-4)*
```yaml
端到端Big LUT:
  - 完整20位输入处理
  - 与C++参考结果对比
  - 不同LUT函数验证 (ReLU, GeLU, exp)
  - 批处理模式测试

性能基准测试:
  - 延迟测量 (vs Legacy)
  - 吞吐量测试 (ops/sec)
  - 资源利用率分析
  - 功耗评估
```

### **测试层级3: 系统级验证** *(Week 4, Day 5-7)*
```yaml
稳定性测试:
  - 长时间运行测试 (24小时)
  - 压力测试 (1000+ 连续操作)
  - 边界条件测试
  - 错误注入与恢复测试

兼容性验证:
  - 与现有系统集成
  - 不同参数配置测试
  - 向后兼容性验证
  - 未来扩展性评估
```

---

## 🎯 **成功标准与验收条件**

### **功能验收标准**
- [ ] **VP-PBS握手成功率**: 100% (无失败案例)
- [ ] **Big LUT正确性**: 与C++参考100%一致
- [ ] **资源调度效率**: 无死锁，平均等待时间<50 cycles
- [ ] **错误处理覆盖**: 所有错误类型可检测和恢复
- [ ] **端到端延迟**: ≤ Legacy实现的110% (允许10%误差)

### **性能验收标准**
- [ ] **吞吐量提升**: 比Legacy版本提升20%+
- [ ] **资源利用率**: BSK/KSK利用率>80%
- [ ] **并行效率**: CMux并行度达到设计目标
- [ ] **功耗优化**: 动态功耗降低15%+
- [ ] **稳定性**: 24小时连续运行无故障

### **质量验收标准**
- [ ] **代码覆盖率**: >95% 
- [ ] **测试用例**: 覆盖所有功能路径和边界条件
- [ ] **文档完整**: 接口规范、设计文档、用户手册
- [ ] **可维护性**: 清晰的模块边界和接口定义

---

## 📈 **预期成果与效益**

### **技术成果**
```yaml
架构完善:
  ✅ VP-PBS清晰职责分离
  ✅ 真实PBS模块完整集成  
  ✅ 资源高效共享和调度
  ✅ 端到端Big LUT功能验证

性能提升:
  📈 吞吐量: +20-30%
  📈 资源利用率: +40-50%  
  📈 并行效率: +25-35%
  📈 稳定性: 24/7可靠运行
```

### **为Phase 3奠定基础**
```yaml
OpenSSD集成准备:
  🔧 清晰的系统接口 (AXI4)
  🔧 验证的性能基准
  🔧 完整的错误处理机制
  🔧 可扩展的架构设计

产业化就绪:
  📋 完整的测试套件
  📋 详细的技术文档  
  📋 性能优化建议
  📋 维护和升级计划
```

**Phase 2完成后，LUTHE WoP-PBS将具备生产级的功能完整性和性能表现，为与OpenSSD near-storage集成奠定坚实的技术基础。**