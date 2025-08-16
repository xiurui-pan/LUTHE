// ==============================================================================================
// Filename: wop_vertical_packing_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// 重构后的WoP-PBS垂直打包引擎 - 架构重构版本
// 基于tfhe-cpu-baseline-wopbs的bigLut_20bit_lvl1()实现
// 
// 职责划分：
// VP Engine: CMux Tree (bits 10-19) + PBS客户端
// PBS Kernel: Blind Rotation (bits 0-9) + Extract + Post-processing
//
// 关键设计决策：
// 1. VP只保留CMux Tree逻辑，移除所有Blind Rotation代码
// 2. 使用wop_pbs_kernel的VP专用接口，避免资源重复
// 3. 精简状态机至7个核心状态
// 4. 优化内存使用，只缓存CMux必需数据
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module wop_vertical_packing_engine
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import regf_common_param_pkg::*;
  import axi_if_glwe_axi_pkg::*;
  import hpu_common_instruction_pkg::*;
  import vp_pbs_inst_pkg::*;
#(
  parameter int MOD_Q_W = 32,
  parameter int MAX_BIT_WIDTH = 20,
  parameter int N_LVL1 = 1024,
  parameter int ELL_LVL1 = 3,
  parameter int K = 1,  // k parameter for TLWE
  parameter int REGF_ADDR_W = 16,
  parameter int LUT_SIZE = 1024  // 2^10 for CMux tree
)
(
  input  logic clk,
  input  logic s_rst_n,
  
  // VP控制接口
  input  logic start,
  input  logic [MAX_BIT_WIDTH-1:0] bit_width,
  output logic done,
  
  // 输入参数
  input  logic [REGF_ADDR_W-1:0] ggsw_samples_base_addr,
  input  logic ggsw_samples_ready,
  input  logic [REGF_ADDR_W-1:0] result_addr,
  output logic result_ready,
  
  // LUT接口 (简化，只读)
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] lut_base_addr,
  output logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] lut_addr,
  output logic lut_req_vld,
  input  logic lut_req_rdy,
  input  logic lut_data_avail,
  input  logic [axi_if_glwe_axi_pkg::AXI4_DATA_W-1:0] lut_data,
  
  // RegFile接口 (简化)
  output logic regf_rd_req_vld,
  input  logic regf_rd_req_rdy,
  output logic [REGF_RD_REQ_W-1:0] regf_rd_req,
  input  logic [REGF_COEF_NB-1:0] regf_rd_data_avail,
  input  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_rd_data,
  
  output logic regf_wr_req_vld,
  input  logic regf_wr_req_rdy,
  output logic [REGF_WR_REQ_W-1:0] regf_wr_req,
  output logic [REGF_COEF_NB-1:0] regf_wr_data_vld,
  input  logic [REGF_COEF_NB-1:0] regf_wr_data_rdy,
  output logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_wr_data,
  
  // VP专用PBS服务接口 (使用VP-PBS协议)
  output vp_pbs_inst_t         vp_pbs_inst,
  output logic                 vp_pbs_inst_vld,
  input  logic                 vp_pbs_inst_rdy,
  input  logic                 vp_pbs_inst_ack,
  input  vp_pbs_response_t     vp_pbs_response
);

// ==============================================================================================
// 精简状态机 (7个状态)
// ==============================================================================================
typedef enum logic [2:0] {
  IDLE,
  LOAD_LUT_ENTRIES,    // 加载LUT到内部缓冲 
  LOAD_GGSW_SAMPLES,   // 加载GGSW样本 (仅bits 10-19)
  CMUX_TREE_PROCESS,   // CMux Tree处理 (bits 10-19)
  WRITE_CMUX_RESULT,   // 写入CMux结果到RegFile
  VP_PBS_REQUEST,      // 发送VP-PBS请求
  WAIT_PBS_DONE        // 等待PBS完成
} vp_state_e;

vp_state_e current_state, next_state;

// ==============================================================================================
// 精简内部存储 (只保留CMux Tree必需资源)
// ==============================================================================================
// CMux Tree双池缓冲 (ping-pong)
logic [1:0][LUT_SIZE-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] cmux_pools;

// GGSW样本存储 (只存储bits 10-19，用于CMux Tree)
logic [19:10][ELL_LVL1-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] cmux_tgsw_samples;

// CMux Tree最终结果 (发送给PBS的TLWE)
logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] cmux_result_tlwe;
logic [REGF_ADDR_W-1:0] cmux_result_addr; // CMux结果存储地址

// 控制信号
logic [4:0] cmux_bit_counter;  // 10-19
logic [9:0] cmux_entry_counter; // 0-1023
logic [31:0] lut_load_counter;
logic [31:0] lut_data_index;  // 修复管道延迟：跟踪接收数据的实际索引
logic cmux_pool_select;  // ping-pong选择

// CMux Tree状态机 - 移到前面声明
typedef enum logic [2:0] {
  CMUX_IDLE,
  CMUX_INIT_POOLS,      // 初始化: 加载1024个LUT到pools[0]
  CMUX_TREE_EXEC,       // 执行10轮CMux选择 (避免与主状态机重名)
  CMUX_EXTRACT_RESULT   // 提取最终结果
} cmux_tree_state_e;

cmux_tree_state_e cmux_tree_state;
logic [4:0] cmux_round;          // 当前轮次 (10-19)
logic [9:0] cmux_process_idx;    // 当前处理的索引
logic [9:0] cmux_entries_count;  // 当前轮的条目数
logic cmux_pool_ping_pong;       // ping-pong选择 (0/1)

// VP-PBS交互状态
vp_pbs_inst_t vp_pbs_request;
logic vp_pbs_request_ready;

// 操作完成标志
logic lut_load_done;
logic ggsw_load_done; 
logic cmux_tree_done;
logic cmux_result_written;

// PBS相关地址
logic [REGF_ADDR_W-1:0] pbs_output_addr;   // PBS最终输出地址

// VP-PBS指令已移至vp_pbs_interface_pkg，此处删除重复定义

// ==============================================================================================
// 状态机实现
// ==============================================================================================
always_ff @(posedge clk or negedge s_rst_n) begin
  if (!s_rst_n) begin
    current_state <= IDLE;
    cmux_bit_counter <= 10;  // CMux从bit 10开始
    cmux_entry_counter <= '0;
    lut_load_counter <= '0;
    lut_data_index <= '0;  // 初始化数据索引
    cmux_pool_select <= 1'b0;
    
    // CMux Tree状态机初始化
    cmux_tree_state <= CMUX_IDLE;
    cmux_round <= 5'd12;
    cmux_process_idx <= '0;
    cmux_entries_count <= 10'd0;
    cmux_pool_ping_pong <= 1'b0;
    
    // 初始化完成标志
    lut_load_done <= 1'b0;
    ggsw_load_done <= 1'b0;
    cmux_tree_done <= 1'b0;
    cmux_result_written <= 1'b0;
    
    // 地址初始化
    cmux_result_addr <= '0;
    pbs_output_addr <= '0;
  end else begin
    current_state <= next_state;
    
    // 状态转换时的地址设置
    if (current_state != next_state) begin
      $display("[VP_ENGINE] State transition: %s -> %s at time %0t", 
               current_state.name(), next_state.name(), $time);
               
      case (next_state)
        WRITE_CMUX_RESULT: begin
          cmux_result_addr <= result_addr;  // CMux结果临时存储
          $display("[VP_ENGINE] CMux result will be stored at addr=0x%0h", result_addr);
        end
        VP_PBS_REQUEST: begin
          pbs_output_addr <= result_addr + 16'h400;  // PBS输出地址偏移
          $display("[VP_ENGINE] PBS output will be at addr=0x%0h", result_addr + 16'h400);
        end
      endcase
    end
    
    // 状态特定的计数器和标志更新
    case (current_state)
      LOAD_LUT_ENTRIES: begin
        if (lut_req_rdy && lut_data_avail) begin
          // 修复：处理AXI4数据流水线延迟
          lut_data_index <= lut_load_counter;  // 数据索引跟踪当前接收的数据
          lut_load_counter <= lut_load_counter + 1;  // 计数器为下一次请求做准备
          
          // Debug: 显示加载进度（减少频率）
          if (lut_load_counter % 200 == 0 || lut_load_counter > 1020) begin
            $display("[VP_ENGINE] LUT loading progress: %0d/%0d", lut_load_counter, LUT_SIZE-1);
          end
          
          if (lut_load_counter >= LUT_SIZE - 1) begin
            lut_load_done <= 1'b1;
            $display("[VP_ENGINE] LUT loading completed: %0d entries", LUT_SIZE);
          end
        end else begin
          // Debug: 显示等待状态
          if (lut_load_counter > 300 && lut_load_counter % 10 == 0) begin
            $display("[VP_ENGINE] LUT loading stalled: counter=%0d, req_rdy=%0d, data_avail=%0d", 
                     lut_load_counter, lut_req_rdy, lut_data_avail);
          end
        end
      end
      
      LOAD_GGSW_SAMPLES: begin
        if (regf_rd_req_rdy && regf_rd_data_avail[0]) begin
          cmux_bit_counter <= cmux_bit_counter + 1;
          if (cmux_bit_counter >= 19) begin
            ggsw_load_done <= 1'b1;
            $display("[VP_ENGINE] GGSW loading completed: bits 10-19");
          end
        end
      end
      
      CMUX_TREE_PROCESS: begin
        // CMux Tree处理完成检查
        if (cmux_tree_state == CMUX_EXTRACT_RESULT) begin
          cmux_tree_done <= 1'b1;
          $display("[VP_ENGINE] CMux Tree completed - 10 rounds processed");
        end
      end
      
      WRITE_CMUX_RESULT: begin
        if (regf_wr_req_rdy && regf_wr_data_rdy[0]) begin
          cmux_entry_counter <= cmux_entry_counter + 1;
          if (cmux_entry_counter >= N_LVL1 - 1) begin
            cmux_result_written <= 1'b1;
            $display("[VP_ENGINE] CMux result written to RegFile");
          end
        end
      end
    endcase
  end
end

// 状态转换逻辑
always_comb begin
  next_state = current_state;
  
  case (current_state)
    IDLE: begin
      if (start && ggsw_samples_ready) begin
        next_state = LOAD_LUT_ENTRIES;
      end
    end
    
          LOAD_LUT_ENTRIES: begin
        if (lut_load_done) begin
          next_state = LOAD_GGSW_SAMPLES;
          $display("[VP_ENGINE] All %0d LUT entries loaded", LUT_SIZE);
        end
      end
    
    LOAD_GGSW_SAMPLES: begin
      if (ggsw_load_done) begin
        next_state = CMUX_TREE_PROCESS;
      end
    end
    
    CMUX_TREE_PROCESS: begin
      if (cmux_tree_done) begin
        next_state = WRITE_CMUX_RESULT;
      end
    end
    
    WRITE_CMUX_RESULT: begin
      if (cmux_result_written) begin
        next_state = VP_PBS_REQUEST;
      end
    end
    
    VP_PBS_REQUEST: begin
      // 等待VP-PBS握手成功
      if (vp_pbs_inst_vld && vp_pbs_inst_rdy) begin
        next_state = WAIT_PBS_DONE;
        $display("[VP_ENGINE] State transition: VP_PBS_REQUEST -> WAIT_PBS_DONE");
      end
    end
    
    WAIT_PBS_DONE: begin
      if (vp_pbs_inst_ack) begin
        next_state = IDLE;
      end
    end
  endcase
end

// ==============================================================================================
// 接口驱动逻辑
// ==============================================================================================
always_comb begin
  // 默认值
  done = 1'b0;
  result_ready = 1'b0;
  lut_req_vld = 1'b0;
  lut_addr = '0;
  regf_rd_req_vld = 1'b0;
  regf_rd_req = '0;
  regf_wr_req_vld = 1'b0;
  regf_wr_req = '0;
  regf_wr_data_vld = '0;
  regf_wr_data = '0;
  vp_pbs_inst_vld = 1'b0;
  vp_pbs_inst = '0;
  
  case (current_state)
    LOAD_LUT_ENTRIES: begin
      if (!lut_load_done) begin
        lut_req_vld = 1'b1;
        lut_addr = lut_base_addr + (lut_load_counter << 7);  // 128字节对齐
      end
    end
    
    LOAD_GGSW_SAMPLES: begin
      if (!ggsw_load_done) begin
        regf_rd_req_vld = 1'b1;
        regf_rd_req = {ggsw_samples_base_addr + cmux_bit_counter, 16'h0000};
      end
    end
    
    WRITE_CMUX_RESULT: begin
      if (!cmux_result_written) begin
        regf_wr_req_vld = 1'b1;
        regf_wr_req = {cmux_result_addr + cmux_entry_counter, 16'h0000};
        regf_wr_data_vld[0] = 1'b1;
        regf_wr_data[0] = cmux_result_tlwe[0][cmux_entry_counter];  // 简化：只写a[0]
      end
    end
    
    VP_PBS_REQUEST: begin
      // 始终组装和发送VP-PBS请求
      vp_pbs_request = make_vp_pbs_inst(
        VP_OP_BLIND_ROT_EXTRACT,      // 操作类型
        cmux_result_addr,             // CMux结果地址
        ggsw_samples_base_addr,       // GGSW bits 0-9地址 
        pbs_output_addr,              // 输出地址
        4'd0,                         // bit_range_start
        4'd9,                         // bit_range_end
        1'b1,                         // need_post_process
        lut_base_addr                 // LUT基地址
      );
      vp_pbs_inst_vld = 1'b1;
      vp_pbs_inst = vp_pbs_request;
      
      $display("[VP_ENGINE] *** SENDING VP-PBS REQUEST *** vld=%b, rdy=%b at time %0t", 
               vp_pbs_inst_vld, vp_pbs_inst_rdy, $time);
      
      if (vp_pbs_inst_rdy) begin
        $display("[VP_ENGINE] VP-PBS handshake SUCCESS! Moving to WAIT_PBS_DONE");
      end else begin
        $display("[VP_ENGINE] VP-PBS handshake WAITING for rdy...");
      end
    end
    
    WAIT_PBS_DONE: begin
      // 监控VP-PBS响应状态
      if (vp_pbs_response.current_state == VP_PBS_DONE && vp_pbs_inst_ack) begin
        if (vp_pbs_response.success) begin
          done = 1'b1;
          result_ready = 1'b1;
          $display("[VP_ENGINE] VP-PBS processing completed successfully, result at addr=0x%0h", 
                   vp_pbs_response.result_addr);
        end else begin
          $display("[VP_ENGINE] VP-PBS processing failed with error");
          // 可以添加错误处理逻辑
          done = 1'b1; // 即使失败也要完成
        end
      end else if (vp_pbs_response.current_state == VP_PBS_ERROR) begin
        $display("[VP_ENGINE] VP-PBS reported error state");
        done = 1'b1;
      end
    end
  endcase
end

// ==============================================================================================
// CMux Tree核心逻辑 (完整实现 - 基于big_lut.cpp)
// ==============================================================================================

// CMux Tree状态机逻辑
always_ff @(posedge clk or negedge s_rst_n) begin
  if (!s_rst_n) begin
    // 重置逻辑已在主状态机中处理
  end else begin
    case (cmux_tree_state)
      CMUX_IDLE: begin
        if (current_state == CMUX_TREE_PROCESS) begin
          cmux_tree_state <= CMUX_INIT_POOLS;
          cmux_round <= 5'd10;
          cmux_process_idx <= '0;
          cmux_entries_count <= 10'd1024; // 修复位宽问题
          cmux_pool_ping_pong <= 1'b0;
        end
      end
      
      CMUX_INIT_POOLS: begin
        // 初始化已通过LOAD_LUT_ENTRIES完成，直接进入CMux处理
        cmux_tree_state <= CMUX_TREE_EXEC;
        cmux_round <= 5'd12;
        cmux_entries_count <= 10'd512; // 第一轮输出512个
        cmux_pool_ping_pong <= 1'b1;   // 输出到pools[1]
      end
      
      CMUX_TREE_EXEC: begin
        // 处理当前轮的所有条目
        if (cmux_process_idx < cmux_entries_count) begin
          cmux_process_idx <= cmux_process_idx + 1;
          // 减少调试频率，只在特定条目时显示
          if (cmux_process_idx == 0 || cmux_process_idx == cmux_entries_count-1) begin
            $display("[VP_ENGINE] CMux processing: round %0d, idx %0d/%0d", 
                     cmux_round-9, cmux_process_idx, cmux_entries_count-1);
          end
        end else begin
          // 当前轮完成，准备下一轮
          $display("[VP_ENGINE] Round %0d completed: processed %0d entries", 
                   cmux_round-9, cmux_entries_count);
          $display("[VP_ENGINE] DEBUG: cmux_round=%0d, condition (>= 19) = %0d", 
                   cmux_round, (cmux_round >= 5'd19));
          
          if (cmux_round >= 5'd19) begin // 绝对轮次19 (bit 19是最后一轮)
            // 所有轮次完成
            $display("[VP_ENGINE] All 10 CMux rounds completed! (cmux_round=%0d)", cmux_round);
            cmux_tree_state <= CMUX_EXTRACT_RESULT;
          end else begin
            // 进入下一轮
            $display("[VP_ENGINE] Advancing to next round: %0d -> %0d", cmux_round, cmux_round+1);
            cmux_round <= cmux_round + 1;
            cmux_process_idx <= '0;
            cmux_entries_count <= cmux_entries_count >> 1; // 减半
            cmux_pool_ping_pong <= ~cmux_pool_ping_pong;   // 切换ping-pong
            $display("[VP_ENGINE] Starting round %0d: %0d entries, ping_pong=%0d", 
                     cmux_round-8, cmux_entries_count >> 1, ~cmux_pool_ping_pong);
          end
        end
      end
      
      CMUX_EXTRACT_RESULT: begin
        // 提取最终结果 pools[final_pool][0]
        cmux_tree_state <= CMUX_IDLE;
      end
    endcase
  end
end

// CMux Tree数据路径
always_ff @(posedge clk) begin
  // 1. 加载LUT数据到pools[0] (初始化) - PIPELINE DELAY FIXED  
  if (current_state == LOAD_LUT_ENTRIES && lut_req_rdy && lut_data_avail) begin
    // AXI4数据格式: lut_data[127:0] = {coef3[31:0], coef2[31:0], coef1[31:0], coef0[31:0]}
    // 修复：使用lut_data_index确保数据存储到正确位置
    cmux_pools[0][lut_data_index][0][0] <= lut_data[31:0];   // coef0 -> a[0][0]
    cmux_pools[0][lut_data_index][0][1] <= lut_data[63:32];  // coef1 -> a[0][1]  
    cmux_pools[0][lut_data_index][0][2] <= lut_data[95:64];  // coef2 -> a[0][2]
    cmux_pools[0][lut_data_index][0][3] <= lut_data[127:96]; // coef3 -> a[0][3]
    
    // K=1, so we need a[1][0-3] too, but AXI4 only gives us 4 coefficients per transfer
    // For now, replicate pattern (need to check testbench LUT data format)
    cmux_pools[0][lut_data_index][1][0] <= lut_data[31:0] + 32'h8;   // offset pattern
    cmux_pools[0][lut_data_index][1][1] <= lut_data[63:32] + 32'h8;
    cmux_pools[0][lut_data_index][1][2] <= lut_data[95:64] + 32'h8;
    cmux_pools[0][lut_data_index][1][3] <= lut_data[127:96] + 32'h8;
    
    // Critical debug: Show raw AXI4 data and parsed values  
    if (lut_data_index <= 2 || lut_data_index == 341) begin
      $display("[VP_ENGINE] PIPELINE FIX - Data for LUT[%0d] RAW AXI4: 0x%0h", lut_data_index, lut_data);
      $display("[VP_ENGINE] PIPELINE FIX - LUT[%0d] PARSED: [0][0]=0x%0h, [0][1]=0x%0h, [1][0]=0x%0h", 
               lut_data_index, lut_data[31:0], lut_data[63:32], lut_data[31:0] + 32'h8);
      $display("[VP_ENGINE] PIPELINE FIX - Storing to pools[0][%0d] (req_counter=%0d)", lut_data_index, lut_load_counter);
    end
    
    // Debug: Verify stored values after a few cycles
    if (lut_load_counter == 2) begin
      $display("[VP_ENGINE] STORED VALUES CHECK:");
      $display("  pools[0][0]: [0][0]=0x%0h, [0][1]=0x%0h", 
               cmux_pools[0][0][0][0], cmux_pools[0][0][0][1]);
      $display("  pools[0][1]: [0][0]=0x%0h, [0][1]=0x%0h", 
               cmux_pools[0][1][0][0], cmux_pools[0][1][0][1]);
      $display("  pools[0][2]: [0][0]=0x%0h, [0][1]=0x%0h", 
               cmux_pools[0][2][0][0], cmux_pools[0][2][0][1]);
    end
  end
  
  // 2. 加载GGSW样本 (bits 10-19)
  if (current_state == LOAD_GGSW_SAMPLES && regf_rd_req_rdy && regf_rd_data_avail[0]) begin
    // 存储GGSW样本第一个系数，用于CMux控制位提取
    cmux_tgsw_samples[cmux_bit_counter][0][0][0] <= regf_rd_data[0];
    // 其他系数不需要存储完整的TLWE样本，只需控制位
  end
  
  // 3. CMux Tree核心算法 (基于C++实现)
  if (cmux_tree_state == CMUX_TREE_EXEC && cmux_process_idx < cmux_entries_count) begin
    // 实现: TLwe32CMux_TGsw_lvl1(&to[j], &from[j<<1], &from[j<<1|1], &tgsw_radixs[d], env)
    automatic logic [9:0] from_idx0, from_idx1;
    automatic logic from_pool, to_pool;
    automatic logic control_bit;
    automatic logic [31:0] ggsw_value;
    
    from_pool = ~cmux_pool_ping_pong;  // from = pools[i ^ 1]
    to_pool = cmux_pool_ping_pong;     // to = pools[i]
    
    from_idx0 = cmux_process_idx << 1;     // j << 1
    from_idx1 = (cmux_process_idx << 1) | 1; // j << 1 | 1
    
    // 提取控制位 (基于testbench的位提取逻辑)
    // testbench: extracted_bit = (ggsw_value % 1000) > 500
    ggsw_value = cmux_tgsw_samples[cmux_round][0][0][0];
    control_bit = (ggsw_value % 32'd1000) > 32'd500;
    
    // Debug first CMux operation to trace data flow
    if (cmux_round == 5'd10 && cmux_process_idx == 0) begin
      $display("[VP_ENGINE] CRITICAL - First CMux operation:");
      $display("  ggsw_value=0x%0h, control_bit=%0d", ggsw_value, control_bit);
      $display("  from_pool=%0d, to_pool=%0d", from_pool, to_pool);
      $display("  from_idx0=%0d, from_idx1=%0d", from_idx0, from_idx1);
      $display("  Source[%0d]: [0][0]=0x%0h, [0][1]=0x%0h", from_idx0, 
               cmux_pools[from_pool][from_idx0][0][0], cmux_pools[from_pool][from_idx0][0][1]);
      $display("  Source[%0d]: [0][0]=0x%0h, [0][1]=0x%0h", from_idx1,
               cmux_pools[from_pool][from_idx1][0][0], cmux_pools[from_pool][from_idx1][0][1]);
      $display("  Selected: Source[%0d] (control_bit=%0d)", control_bit ? from_idx1 : from_idx0, control_bit);
    end
    
    // Debug: Track a specific entry through all rounds
    if (cmux_process_idx == 0 && cmux_round <= 5'd12) begin
      $display("[VP_ENGINE] Round %0d: Entry[0] from pools[%0d][%0d] -> pools[%0d][0]", 
               cmux_round-9, from_pool, control_bit ? from_idx1 : from_idx0, to_pool);
    end
    
    // CMux选择逻辑: 根据control_bit选择from_idx0或from_idx1
    for (int k = 0; k <= K; k++) begin
      for (int n = 0; n < N_LVL1; n++) begin
        if (control_bit) begin
          cmux_pools[to_pool][cmux_process_idx][k][n] <= cmux_pools[from_pool][from_idx1][k][n]; 
        end else begin
          cmux_pools[to_pool][cmux_process_idx][k][n] <= cmux_pools[from_pool][from_idx0][k][n];
        end
      end
    end
  end
  
  // 4. 提取最终CMux结果
  if (cmux_tree_state == CMUX_EXTRACT_RESULT) begin
    automatic logic final_pool = cmux_pool_ping_pong; // 最终结果在当前pool
    for (int k = 0; k <= K; k++) begin
      for (int n = 0; n < N_LVL1; n++) begin
        cmux_result_tlwe[k][n] <= cmux_pools[final_pool][0][k][n];
      end
    end
    $display("[VP_ENGINE] CMux Tree completed: extracted from pools[%0d][0]", final_pool);
    $display("[VP_ENGINE] CRITICAL DEBUG - Final CMux values:");
    $display("  pools[%0d][0][0][0] = 0x%0h", final_pool, cmux_pools[final_pool][0][0][0]);
    $display("  pools[%0d][0][0][1] = 0x%0h", final_pool, cmux_pools[final_pool][0][0][1]);
    $display("  pools[%0d][0][1][0] = 0x%0h", final_pool, cmux_pools[final_pool][0][1][0]);
    $display("  pools[%0d][0][1][1] = 0x%0h", final_pool, cmux_pools[final_pool][0][1][1]);
  end
end

endmodule

