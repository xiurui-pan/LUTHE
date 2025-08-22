// ==============================================================================================
// Package: vp_pbs_interface_pkg
// ----------------------------------------------------------------------------------------------
// Description:
//
// VP-PBS接口定义包
// 定义了VP Engine与PBS Kernel之间的专用通信协议
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

package vp_pbs_inst_pkg;

// 简化导入，只保留必要的基础定义
// import common_definition_pkg::*;
// import param_tfhe_pkg::*;
// import regf_common_param_pkg::*;
// import axi_if_glwe_axi_pkg::*;

// ==============================================================================================
// VP-PBS操作类型定义
// ==============================================================================================
typedef enum logic [3:0] {
  VP_OP_IDLE                      = 4'b0000,
  VP_OP_BLIND_ROT_EXTRACT         = 4'b0001,  // Blind Rotation + Extract + Post-process (Steps 1-4)
  VP_OP_BLIND_ROT_ONLY            = 4'b0010,  // 仅Blind Rotation
  VP_OP_EXTRACT_ONLY              = 4'b0011,  // 仅Extract  
  VP_OP_POST_PROC_ONLY            = 4'b0100,  // 仅Post-processing
  VP_OP_KEYSWITCH_BOOTSTRAP_EXTRACT = 4'b0101  // 完整的第5步: Key Switching + 第二轮Bootstrapping + Extract
} vp_pbs_op_type_e;

// ==============================================================================================
// VP-PBS指令结构
// ==============================================================================================
typedef struct packed {
  // 操作控制
  vp_pbs_op_type_e        operation_type;    // 操作类型
  logic [3:0]             reserved1;         // 保留位
  
  // 地址参数
  logic [15:0]            cmux_result_addr;  // CMux结果输入地址 (TLWE)
  logic [15:0]            ggsw_bits_addr;    // GGSW bits 0-9地址
  logic [15:0]            output_addr;       // 最终输出地址
  logic [15:0]            temp_storage_addr; // 临时存储地址
  
  // 处理参数
  logic [3:0]             bit_range_start;   // blind rotation起始bit (通常为0)
  logic [3:0]             bit_range_end;     // blind rotation结束bit (通常为9)
  logic [3:0]             bit_width;         // 总bit宽度 (用于验证)
  logic                   need_post_process; // 是否需要post-processing
  logic                   extract_mode;      // Extract模式选择
  logic                   need_step5;        // 是否需要执行第5步
  logic                   reserved2;         // 保留位
  
  // LUT参数
  logic [31:0]            lut_base_addr;     // LUT基地址 (用于rotation查找)
  logic [31:0]            get_hi_lut_addr;   // get_hi LUT地址 (第5步专用)
  logic [15:0]            lut_entry_size;    // LUT条目大小
  
  // 第5步专用参数
  logic [15:0]            ksk_lvl1_addr;     // Key Switching lvl1→lvl0的KSK地址
  logic [7:0]             ksk_batch_id_step5; // 第5步的KSK批次ID
  logic [7:0]             step5_bit_range;   // 第5步的处理bit范围
} vp_pbs_inst_t;

// ==============================================================================================
// VP-PBS状态定义
// ==============================================================================================
typedef enum logic [3:0] {
  VP_PBS_IDLE           = 4'b0000,
  VP_PBS_LOADING        = 4'b0001,
  VP_PBS_BLIND_ROT      = 4'b0010,
  VP_PBS_EXTRACTING     = 4'b0011,
  VP_PBS_POST_PROC      = 4'b0100,
  VP_PBS_WRITING        = 4'b0101,
  VP_PBS_STEP5_KEYSWITCH = 4'b0110,  // 第5步: Key Switching lvl1→lvl0
  VP_PBS_STEP5_BOOTSTRAP = 4'b0111,  // 第5步: 第二轮Bootstrapping
  VP_PBS_STEP5_EXTRACT   = 4'b1000,  // 第5步: 最终Extract
  VP_PBS_DONE           = 4'b1110,
  VP_PBS_ERROR          = 4'b1111
} vp_pbs_state_e;

// ==============================================================================================
// VP-PBS响应结构
// ==============================================================================================
typedef struct packed {
  vp_pbs_state_e          current_state;     // 当前处理状态
  logic [4:0]             progress_counter;  // 处理进度计数器
  logic [15:0]            result_addr;       // 结果地址
  logic [15:0]            result_size;       // 结果大小 (words)
  logic                   success;           // 操作成功标志
  logic                   error;             // 错误标志
  logic [5:0]             reserved;          // 保留位
} vp_pbs_response_t;

// ==============================================================================================
// VP-PBS资源请求结构
// ==============================================================================================
typedef struct packed {
  // NTT资源请求
  logic                   need_ntt;          // 需要NTT引擎
  logic [1:0]             ntt_priority;      // NTT优先级
  
  // BSK资源请求  
  logic                   need_bsk;          // 需要BSK访问
  logic [7:0]             bsk_batch_id;      // BSK批次ID
  
  // KSK资源请求
  logic                   need_ksk;          // 需要KSK访问
  logic [7:0]             ksk_batch_id;      // KSK批次ID
  
  // RegFile资源请求
  logic                   need_regf_rd;      // 需要RegFile读
  logic                   need_regf_wr;      // 需要RegFile写
  logic [1:0]             regf_priority;     // RegFile优先级
  
  // AXI资源请求
  logic                   need_axi;          // 需要AXI访问
  logic [31:0]            axi_base_addr;     // AXI基地址
  logic [15:0]            axi_length;        // AXI传输长度
  
  logic [7:0]             reserved;          // 保留位
} vp_pbs_resource_req_t;

// ==============================================================================================
// VP-PBS接口参数
// ==============================================================================================
localparam int VP_PBS_INST_WIDTH = $bits(vp_pbs_inst_t);
localparam int VP_PBS_RESP_WIDTH = $bits(vp_pbs_response_t);
localparam int VP_PBS_RESOURCE_WIDTH = $bits(vp_pbs_resource_req_t);

// ==============================================================================================
// VP-PBS辅助函数
// ==============================================================================================

// 创建VP-PBS指令
function automatic vp_pbs_inst_t make_vp_pbs_inst(
  input vp_pbs_op_type_e op_type,
  input logic [15:0] cmux_addr,
  input logic [15:0] ggsw_addr,
  input logic [15:0] output_addr,
  input logic [3:0] bit_start,
  input logic [3:0] bit_end,
  input logic need_post_proc,
  input logic [31:0] lut_base
);
  vp_pbs_inst_t inst;
  inst.operation_type = op_type;
  inst.reserved1 = 4'h0;
  inst.cmux_result_addr = cmux_addr;
  inst.ggsw_bits_addr = ggsw_addr;
  inst.output_addr = output_addr;
  inst.temp_storage_addr = output_addr + 16'h200; // 默认临时存储偏移
  inst.bit_range_start = bit_start;
  inst.bit_range_end = bit_end;
  inst.bit_width = 4'd10; // bits 0-9
  inst.need_post_process = need_post_proc;
  inst.extract_mode = 1'b0; // 默认extract模式
  inst.need_step5 = 1'b0; // 默认不执行第5步
  inst.reserved2 = 1'b0;
  inst.lut_base_addr = lut_base;
  inst.get_hi_lut_addr = 32'h0; // 默认无get_hi LUT
  inst.lut_entry_size = 16'd128; // 128字节/条目
  inst.ksk_lvl1_addr = 16'h0; // 默认无KSK地址
  inst.ksk_batch_id_step5 = 8'h0; // 默认批次ID
  inst.step5_bit_range = 8'h0; // 默认bit范围
  return inst;
endfunction

// 创建第5步专用VP-PBS指令
function automatic vp_pbs_inst_t make_vp_pbs_step5_inst(
  input logic [15:0] input_addr,        // 前4步的输出地址
  input logic [15:0] final_output_addr, // 最终输出地址
  input logic [31:0] get_hi_lut_addr,   // get_hi LUT地址
  input logic [15:0] ksk_addr,          // KSK lvl1→lvl0地址
  input logic [7:0] ksk_batch_id,       // KSK批次ID
  input logic [7:0] bit_range           // 处理的bit范围
);
  vp_pbs_inst_t inst;
  inst.operation_type = VP_OP_KEYSWITCH_BOOTSTRAP_EXTRACT;
  inst.reserved1 = 4'h0;
  inst.cmux_result_addr = input_addr;    // 输入来自前4步的结果
  inst.ggsw_bits_addr = 16'h0;           // 第5步不需要GGSW bits
  inst.output_addr = final_output_addr;
  inst.temp_storage_addr = final_output_addr + 16'h400; // 临时存储
  inst.bit_range_start = 4'h0;           // 第5步的bit处理范围
  inst.bit_range_end = 4'h9;
  inst.bit_width = 4'd10;
  inst.need_post_process = 1'b1;         // 第5步总是需要post-processing
  inst.extract_mode = 1'b1;              // 使用特殊extract模式
  inst.need_step5 = 1'b1;                // 标记为第5步
  inst.reserved2 = 1'b0;
  inst.lut_base_addr = 32'h0;            // 第5步不使用常规LUT
  inst.get_hi_lut_addr = get_hi_lut_addr; // 使用get_hi LUT
  inst.lut_entry_size = 16'd128;
  inst.ksk_lvl1_addr = ksk_addr;
  inst.ksk_batch_id_step5 = ksk_batch_id;
  inst.step5_bit_range = bit_range;
  return inst;
endfunction

// 检查VP-PBS指令有效性
function automatic logic is_vp_pbs_inst_valid(input vp_pbs_inst_t inst);
  return (inst.operation_type != VP_OP_IDLE) &&
         (inst.cmux_result_addr != 16'h0) &&
         (inst.output_addr != 16'h0) &&
         (inst.bit_range_end >= inst.bit_range_start) &&
         (inst.bit_width > 0);
endfunction

// 创建资源请求
function automatic vp_pbs_resource_req_t make_vp_resource_req(
  input logic need_ntt, need_bsk, need_ksk,
  input logic [7:0] bsk_id, ksk_id,
  input logic [31:0] axi_base,
  input logic [15:0] axi_len
);
  vp_pbs_resource_req_t req;
  req.need_ntt = need_ntt;
  req.ntt_priority = 2'b10; // 中等优先级
  req.need_bsk = need_bsk;
  req.bsk_batch_id = bsk_id;
  req.need_ksk = need_ksk;
  req.ksk_batch_id = ksk_id;
  req.need_regf_rd = 1'b1; // VP总是需要RegFile读
  req.need_regf_wr = 1'b1; // VP总是需要RegFile写
  req.regf_priority = 2'b01; // 低优先级，不与主PBS冲突
  req.need_axi = (axi_len > 0);
  req.axi_base_addr = axi_base;
  req.axi_length = axi_len;
  req.reserved = 8'h0;
  return req;
endfunction

endpackage : vp_pbs_inst_pkg
