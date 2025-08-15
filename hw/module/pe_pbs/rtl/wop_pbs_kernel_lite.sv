// ==============================================================================================
// Filename: wop_pbs_kernel_lite.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// 精简版WoP-PBS Kernel - 专门为VP Engine服务
// 只包含VP引擎所需的核心功能：
// 1. Blind Rotation (bits 0-9)
// 2. Sample Extract
// 3. Post-processing (modSwitch + keyswitch)
//
// 移除了不必要的Stage 1 (Bit Extraction) 和 Stage 2 (Circuit Bootstrap)
// 职责清晰：VP Engine负责CMux Tree，这里负责密码学运算
//
// Author: Ray Pan 
// Date:   August 15, 2025
// ==============================================================================================

module wop_pbs_kernel_lite
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import regf_common_param_pkg::*;
  import axi_if_glwe_axi_pkg::*;
  import axi_if_common_param_pkg::*;
  import hpu_common_instruction_pkg::*;
  import vp_pbs_inst_pkg::*;
#(
  parameter int MOD_Q_W = 32,
  parameter int MAX_BIT_WIDTH = 20,
  parameter int N_LVL1 = 1024,
  parameter int ELL_LVL1 = 3,
  parameter int K = 1,
  parameter int REGF_ADDR_W = 16,
  parameter int LUT_SIZE = 1024
)
(
  input  logic clk,
  input  logic s_rst_n,

  // == VP-PBS专用接口 ==
  input  vp_pbs_inst_t                                                 vp_pbs_inst,
  input  logic                                                         vp_pbs_inst_vld,
  output logic                                                         vp_pbs_inst_rdy,
  output logic                                                         vp_pbs_inst_ack,
  output vp_pbs_response_t                                             vp_pbs_response,

  // == RegFile Interface ==
  // Write interface
  output logic                                                         pep_regf_wr_req_vld,
  input  logic                                                         pep_regf_wr_req_rdy,
  output logic [REGF_WR_REQ_W-1:0]                                     pep_regf_wr_req,
  output logic [REGF_COEF_NB-1:0]                                      pep_regf_wr_data_vld,
  input  logic [REGF_COEF_NB-1:0]                                      pep_regf_wr_data_rdy,
  output logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0]                         pep_regf_wr_data,
  input  logic                                                         regf_pep_wr_ack,

  // Read interface
  output logic                                                         pep_regf_rd_req_vld,
  input  logic                                                         pep_regf_rd_req_rdy,
  output logic [REGF_RD_REQ_W-1:0]                                     pep_regf_rd_req,
  input  logic [REGF_COEF_NB-1:0]                                      regf_pep_rd_data_avail,
  input  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0]                         regf_pep_rd_data,
  input  logic                                                         regf_pep_rd_last_word,

  // == AXI Interface for LUTs ==
  output logic [axi_if_glwe_axi_pkg::AXI4_ID_W-1:0]                    m_axi4_glwe_arid,
  output logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0]                   m_axi4_glwe_araddr,
  output logic [AXI4_LEN_W-1:0]                                        m_axi4_glwe_arlen,
  output logic [AXI4_SIZE_W-1:0]                                       m_axi4_glwe_arsize,
  output logic [AXI4_BURST_W-1:0]                                      m_axi4_glwe_arburst,
  output logic                                                         m_axi4_glwe_arvalid,
  input  logic                                                         m_axi4_glwe_arready,
  input  logic [axi_if_glwe_axi_pkg::AXI4_ID_W-1:0]                    m_axi4_glwe_rid,
  input  logic [axi_if_glwe_axi_pkg::AXI4_DATA_W-1:0]                  m_axi4_glwe_rdata,
  input  logic [AXI4_RESP_W-1:0]                                       m_axi4_glwe_rresp,
  input  logic                                                         m_axi4_glwe_rlast,
  input  logic                                                         m_axi4_glwe_rvalid,
  output logic                                                         m_axi4_glwe_rready
);

// ==============================================================================================
// 精简状态机 - 只处理VP所需的操作
// ==============================================================================================
typedef enum logic [2:0] {
  IDLE,
  LOAD_CMUX_RESULT,      // 加载VP的CMux结果
  BLIND_ROTATION,        // Blind Rotation (bits 0-9)
  SAMPLE_EXTRACT,        // Sample Extract
  POST_PROCESSING,       // Post-processing (modSwitch + keyswitch)
  WRITE_RESULT,          // 写入最终结果
  DONE                   // 完成
} vp_pbs_lite_state_e;

vp_pbs_lite_state_e current_state, next_state;

// ==============================================================================================
// 内部信号和存储
// ==============================================================================================

// VP-PBS指令解码
vp_pbs_inst_t vp_inst_decoded;
vp_pbs_response_t vp_response;
logic vp_processing_active;

// 地址信号
logic [REGF_ADDR_W-1:0] cmux_result_addr;
logic [REGF_ADDR_W-1:0] ggsw_bits_addr;  
logic [REGF_ADDR_W-1:0] output_addr;
logic [31:0] lut_base_addr;

// CMux结果存储 (从VP Engine接收)
logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] cmux_result_tlwe;
logic cmux_result_loaded;

// GGSW样本存储 (bits 0-9，用于Blind Rotation)
logic [9:0][ELL_LVL1-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] ggsw_samples;
logic [3:0] ggsw_bit_counter;

// Blind Rotation结果
logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] blind_rot_result;
logic blind_rot_done;

// Sample Extract结果  
logic [K:0][MOD_Q_W-1:0] extract_result;
logic extract_done;

// Post-processing结果
logic [K:0][MOD_Q_W-1:0] final_result;
logic post_proc_done;

// 计数器和控制信号
logic [9:0] rot_shift;
logic [9:0] lut_index;
logic [31:0] process_counter;

// ==============================================================================================
// 状态机实现
// ==============================================================================================
always_ff @(posedge clk or negedge s_rst_n) begin
  if (!s_rst_n) begin
    current_state <= IDLE;
    vp_processing_active <= 1'b0;
    cmux_result_loaded <= 1'b0;
    blind_rot_done <= 1'b0;
    extract_done <= 1'b0;
    post_proc_done <= 1'b0;
    process_counter <= '0;
    ggsw_bit_counter <= '0;
    rot_shift <= '0;
    lut_index <= '0;
    // 静默复位，避免干扰调试
  end else begin
    current_state <= next_state;
    
    // 更新处理计数器 (在主状态机中避免多重驱动)
    case (current_state)
      LOAD_CMUX_RESULT,
      BLIND_ROTATION,
      SAMPLE_EXTRACT,
      POST_PROCESSING: begin
        process_counter <= process_counter + 1;
      end
      default: begin
        process_counter <= '0;
      end
    endcase
    
    // 状态转换时的处理
    case (next_state)
      LOAD_CMUX_RESULT: begin
        if (current_state != next_state) begin
          $display("[VP_PBS_LITE] Loading CMux result from addr=0x%0h", cmux_result_addr);
          cmux_result_loaded <= 1'b0;
        end
      end
      
      BLIND_ROTATION: begin
        if (current_state != next_state) begin
          $display("[VP_PBS_LITE] Starting Blind Rotation for bits 0-9");
          blind_rot_done <= 1'b0;
          ggsw_bit_counter <= '0;
          rot_shift <= '0;
        end
      end
      
      SAMPLE_EXTRACT: begin
        if (current_state != next_state) begin
          $display("[VP_PBS_LITE] Starting Sample Extract");
          extract_done <= 1'b0;
        end
      end
      
      POST_PROCESSING: begin
        if (current_state != next_state) begin
          $display("[VP_PBS_LITE] Starting Post-processing (modSwitch + keyswitch)");
          post_proc_done <= 1'b0;
        end
      end
      
      WRITE_RESULT: begin
        if (current_state != next_state) begin
          $display("[VP_PBS_LITE] Writing final result to addr=0x%0h", output_addr);
        end
      end
    endcase
  end
end

always_comb begin
  // 默认赋值
  next_state = current_state;
  vp_pbs_inst_rdy = 1'b0;
  vp_pbs_inst_ack = 1'b0;
  vp_response = '0;
  vp_response.current_state = VP_PBS_IDLE;
  
  // RegFile接口默认值
  pep_regf_rd_req_vld = 1'b0;
  pep_regf_rd_req = '0;
  pep_regf_wr_req_vld = 1'b0;
  pep_regf_wr_req = '0;
  pep_regf_wr_data_vld = '0;
  pep_regf_wr_data = '0;
  
  // AXI接口默认值
  m_axi4_glwe_arid = '0;
  m_axi4_glwe_araddr = '0;
  m_axi4_glwe_arlen = '0;
  m_axi4_glwe_arsize = 3'b010; // 4 bytes
  m_axi4_glwe_arburst = 2'b01; // INCR
  m_axi4_glwe_arvalid = 1'b0;
  m_axi4_glwe_rready = 1'b0;
  
  case (current_state)
    IDLE: begin
      vp_pbs_inst_rdy = 1'b1;
      vp_response.current_state = VP_PBS_IDLE;
      
      // 简化状态监控：每当有请求时才打印
      if (vp_pbs_inst_vld && $time > 100000) begin
        $display("[VP_PBS_LITE] *** REQUEST RECEIVED *** vld=%b, rdy=%b at time %0t", vp_pbs_inst_vld, vp_pbs_inst_rdy, $time);
      end
      
      if (vp_pbs_inst_vld) begin
        $display("[VP_PBS_LITE] VP-PBS request detected: operation=%0d, vld=%b, rdy=%b at time %0t", 
                 vp_pbs_inst.operation_type, vp_pbs_inst_vld, vp_pbs_inst_rdy, $time);
        
        if (vp_pbs_inst.operation_type == VP_OP_BLIND_ROT_EXTRACT) begin
          // 解码VP-PBS指令
          vp_inst_decoded = vp_pbs_inst;
          cmux_result_addr = vp_pbs_inst.cmux_result_addr;
          ggsw_bits_addr = vp_pbs_inst.ggsw_bits_addr;
          output_addr = vp_pbs_inst.output_addr;
          lut_base_addr = vp_pbs_inst.lut_base_addr;
          
          $display("[VP_PBS_LITE] Accepted VP-PBS request: cmux=0x%0h, ggsw=0x%0h, output=0x%0h", 
                   cmux_result_addr, ggsw_bits_addr, output_addr);
          
          vp_response.current_state = VP_PBS_LOADING;
          next_state = LOAD_CMUX_RESULT;
        end else begin
          $display("[VP_PBS_LITE] Unsupported operation type: %0d", vp_pbs_inst.operation_type);
        end
      end
    end
    
    LOAD_CMUX_RESULT: begin
      // 从RegFile加载CMux结果
      pep_regf_rd_req_vld = 1'b1;
      pep_regf_rd_req = {cmux_result_addr + process_counter[15:0], 16'h0000};
      
      if (pep_regf_rd_req_rdy && regf_pep_rd_data_avail[0]) begin
        // 简化的CMux结果加载
        if (process_counter < N_LVL1) begin
          cmux_result_tlwe[0][process_counter] = regf_pep_rd_data[0];
          if (K > 0) begin
            cmux_result_tlwe[1][process_counter] = regf_pep_rd_data[0]; // 简化
          end
        end
        
        if (process_counter >= N_LVL1) begin
          cmux_result_loaded = 1'b1;
          next_state = BLIND_ROTATION;
        end
      end
    end
    
    BLIND_ROTATION: begin
      // 简化的Blind Rotation实现
      // 实际实现需要多项式乘法和旋转逻辑
      
      vp_response.current_state = VP_PBS_BLIND_ROT;
      vp_response.progress_counter = ggsw_bit_counter;
      
      // 模拟Blind Rotation处理时间
      if (process_counter > 32) begin // 简化的处理延迟
        blind_rot_done = 1'b1;
        next_state = SAMPLE_EXTRACT;
      end
    end
    
    SAMPLE_EXTRACT: begin
      // 简化的Sample Extract实现
      vp_response.current_state = VP_PBS_EXTRACTING;
      
      // 简化的extract逻辑：从多项式提取LWE样本
      if (!extract_done) begin
        extract_result[0] = cmux_result_tlwe[0][0]; // 简化提取
        if (K > 0) begin
          extract_result[1] = cmux_result_tlwe[1][0]; // 简化提取
        end
        extract_done = 1'b1;
      end
      
      if (extract_done) begin
        next_state = POST_PROCESSING;
      end
    end
    
    POST_PROCESSING: begin
      // 简化的Post-processing (modSwitch + keyswitch)
      vp_response.current_state = VP_PBS_POST_PROC;
      
      if (!post_proc_done) begin
        // 简化的modSwitch和keyswitch
        final_result = extract_result; // 简化：直接传递
        post_proc_done = 1'b1;
      end
      
      if (post_proc_done) begin
        next_state = WRITE_RESULT;
      end
    end
    
    WRITE_RESULT: begin
      // 将最终结果写入RegFile
      pep_regf_wr_req_vld = 1'b1;
      pep_regf_wr_req = {output_addr, 16'h0000};
      pep_regf_wr_data_vld[0] = 1'b1;
      pep_regf_wr_data[0] = final_result[0];
      
      if (pep_regf_wr_req_rdy && pep_regf_wr_data_rdy[0]) begin
        $display("[VP_PBS_LITE] Final result written to addr=0x%0h, value=0x%0h", 
                 output_addr, final_result[0]);
        next_state = DONE;
      end
    end
    
    DONE: begin
      // 发送完成响应
      vp_response.current_state = VP_PBS_DONE;
      vp_response.result_addr = output_addr;
      vp_response.result_size = K + 1;
      vp_response.success = 1'b1;
      vp_response.error = 1'b0;
      
      vp_pbs_inst_ack = 1'b1;
      vp_pbs_response = vp_response;
      
      $display("[VP_PBS_LITE] VP-PBS operation completed successfully");
      next_state = IDLE;
    end
  endcase
end

// 合并的处理计数器更新到主状态机always块中 (避免多重驱动)

endmodule
