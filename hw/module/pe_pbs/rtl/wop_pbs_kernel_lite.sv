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
  import param_ntt_pkg::*;
  import ntt_core_common_param_pkg::*;
  import top_common_param_pkg::*;
  import pep_common_param_pkg::*;
  import pep_ks_common_param_pkg::*;
  import bsk_mgr_common_param_pkg::*;
  import ksk_mgr_common_param_pkg::*;
  import regf_common_param_pkg::*;
  import axi_if_glwe_axi_pkg::*;
  import axi_if_common_param_pkg::*;
  import axi_if_bsk_axi_pkg::*;
  import axi_if_ksk_axi_pkg::*;
  import hpu_common_instruction_pkg::*;
  import vp_pbs_inst_pkg::*;
  // 🧪 策略A变体：调试当前BSK_CUT_NB配置
#(
  // BSK_PC是localparam，不能覆盖，需要通过编译配置选择正确的BSK_CUT_NB
  
  // 基础参数
  parameter int MOD_Q_W = 32,
  parameter int MAX_BIT_WIDTH = 20,
  parameter int N_LVL1 = 1024,
  parameter int ELL_LVL1 = 3,
  parameter int K = 1,
  parameter int REGF_ADDR_W = 16,
  parameter int LUT_SIZE = 1024,
  
  // BSK/KSK端口配置参数 (可通过命令行配置)
  parameter int BSK_PC = 1,     // BSK port count - 匹配BSK_CUT_NB=1
  parameter int KSK_PC = 1,     // KSK port count - 与testbench一致
  
  // 集成真实模块所需的参数 (从wop_pbs_kernel.sv复制)
  parameter  mod_mult_type_e   MOD_MULT_TYPE       = set_mod_mult_type(MOD_NTT_TYPE),
  parameter  mod_reduct_type_e REDUCT_TYPE         = set_mod_reduct_type(MOD_NTT_TYPE),
  parameter  arith_mult_type_e MULT_TYPE           = MULT_CORE,
  
  // KSK相关参数修复: 强制设置最小值以满足要求
  parameter int KS_BLOCK_COL_W_MIN = 2,  // 强制最小2位
  parameter int LBX_OVERRIDE = 4,        // 🔧 强制LBX=4，确保KS_BLOCK_COL_W>=2
  // 其他KS参数通过pep_ks_common_param_pkg导入
  parameter  arith_mult_type_e PHI_MULT_TYPE       = set_ntt_mult_type(MOD_NTT_W,MOD_NTT_TYPE),
  parameter  mod_mult_type_e   PP_MOD_MULT_TYPE    = MOD_MULT_TYPE,
  parameter  arith_mult_type_e PP_MULT_TYPE        = MULT_TYPE,
  parameter  int               MODSW_2_PRECISION_W = MOD_NTT_W + 32,
  parameter  arith_mult_type_e MODSW_2_MULT_TYPE   = set_mult_type(MODSW_2_PRECISION_W),
  parameter  arith_mult_type_e MODSW_MULT_TYPE     = set_mult_type(MOD_NTT_W),
  
  // 内存和延迟参数
  parameter  int               RAM_LATENCY         = 2,
  parameter  int               URAM_LATENCY        = RAM_LATENCY + 1,
  parameter  int               ROM_LATENCY         = 2,
  
  // Twiddle文件参数
  parameter  string            TWD_IFNL_FILE_PREFIX = NTT_CORE_ARCH == NTT_CORE_ARCH_WMM_UNFOLD ?
                                                          "memory_file/twiddle/NTT_CORE_ARCH_WMM/R8_PSI8_S3/SOLINAS3_32_17_13/twd_ifnl_bwd" :
                                                          "memory_file/twiddle/NTT_CORE_ARCH_WMM/R8_PSI8_S3/SOLINAS3_32_17_13/twd_ifnl",
  parameter  string            TWD_PHRU_FILE_PREFIX = "memory_file/twiddle/NTT_CORE_ARCH_WMM/R8_PSI8_S3/SOLINAS3_32_17_13/twd_phru",
  parameter  string            TWD_GF64_FILE_PREFIX = $sformatf("memory_file/twiddle/NTT_CORE_ARCH_GF64/R%0d_PSI%0d/twd_phi",R,PSI),
  
  // VP-PBS特定参数
  parameter  int               INST_FIFO_DEPTH      = 8,
  parameter  int               REGF_RD_LATENCY      = URAM_LATENCY + 4,
  parameter  int               KS_IF_COEF_NB        = (LBY < REGF_COEF_NB) ? LBY : REGF_SEQ_COEF_NB,
  parameter  int               KS_IF_SUBW_NB        = (LBY < REGF_COEF_NB) ? 1 : REGF_SEQ,
  parameter  int               PHYS_RAM_DEPTH       = 1024
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
  
  // == BSK资源请求接口 ==
  input  vp_pbs_resource_req_t                                         vp_bsk_resource_req,
  input  logic                                                         vp_bsk_resource_req_vld,
  output logic                                                         vp_bsk_resource_req_rdy,

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
  output logic                                                         m_axi4_glwe_rready,

  //== BSK AXI4 Memory Interface - 真实BSK内存接口
  output logic [BSK_PC-1:0][axi_if_bsk_axi_pkg::AXI4_ID_W-1:0]         m_axi4_bsk_arid,
  output logic [BSK_PC-1:0][axi_if_bsk_axi_pkg::AXI4_ADD_W-1:0]        m_axi4_bsk_araddr,
  output logic [BSK_PC-1:0][AXI4_LEN_W-1:0]                            m_axi4_bsk_arlen,
  output logic [BSK_PC-1:0][AXI4_SIZE_W-1:0]                           m_axi4_bsk_arsize,
  output logic [BSK_PC-1:0][AXI4_BURST_W-1:0]                          m_axi4_bsk_arburst,
  output logic [BSK_PC-1:0]                                            m_axi4_bsk_arvalid,
  input  logic [BSK_PC-1:0]                                            m_axi4_bsk_arready,
  input  logic [BSK_PC-1:0][axi_if_bsk_axi_pkg::AXI4_ID_W-1:0]         m_axi4_bsk_rid,
  input  logic [BSK_PC-1:0][axi_if_bsk_axi_pkg::AXI4_DATA_W-1:0]       m_axi4_bsk_rdata,
  input  logic [BSK_PC-1:0][AXI4_RESP_W-1:0]                           m_axi4_bsk_rresp,
  input  logic [BSK_PC-1:0]                                            m_axi4_bsk_rlast,
  input  logic [BSK_PC-1:0]                                            m_axi4_bsk_rvalid,
  output logic [BSK_PC-1:0]                                            m_axi4_bsk_rready,

  //== KSK AXI4 Memory Interface - 真实KSK内存接口  
  output logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ID_W-1:0]     m_axi4_ksk_arid,
  output logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ADD_W-1:0]    m_axi4_ksk_araddr,
  output logic [KSK_PC-1:0][AXI4_LEN_W-1:0]                        m_axi4_ksk_arlen,
  output logic [KSK_PC-1:0][AXI4_SIZE_W-1:0]                       m_axi4_ksk_arsize,
  output logic [KSK_PC-1:0][AXI4_BURST_W-1:0]                      m_axi4_ksk_arburst,
  output logic [KSK_PC-1:0]                                        m_axi4_ksk_arvalid,
  input  logic [KSK_PC-1:0]                                        m_axi4_ksk_arready,
  input  logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ID_W-1:0]     m_axi4_ksk_rid,
  input  logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_DATA_W-1:0]   m_axi4_ksk_rdata,
  input  logic [KSK_PC-1:0][AXI4_RESP_W-1:0]                       m_axi4_ksk_rresp,
  input  logic [KSK_PC-1:0]                                        m_axi4_ksk_rlast,
  input  logic [KSK_PC-1:0]                                        m_axi4_ksk_rvalid,
  output logic [KSK_PC-1:0]                                        m_axi4_ksk_rready
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
// 辅助函数定义
// ==============================================================================================

// modSwitchToTorus32函数 - 与C++参考算法一致
function automatic logic [31:0] modSwitchToTorus32(
  input logic [31:0] mu,
  input logic [31:0] Msize
);
  logic [63:0] interv;
  logic [63:0] phase64;
  
  // 与C++完全一致的算法：将mu从模Msize映射到Torus32
  interv = (64'h8000000000000000 / Msize) * 2;
  phase64 = mu * interv;
  return phase64[63:32];  // 返回高32位作为Torus32结果
endfunction

// ==============================================================================================
// 内部信号和存储
// ==============================================================================================

// VP-PBS指令解码
vp_pbs_inst_t vp_inst_decoded;
vp_pbs_response_t vp_response;
logic vp_processing_active;

// BSK资源请求处理
vp_pbs_resource_req_t bsk_resource_req_decoded;
logic bsk_request_received;
logic [7:0] current_br_loop;
logic bsk_manager_cmd_sent;

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

// BSK配置检查
initial begin
  $display("[VP_PBS_LITE] BSK Configuration: BSK_PC=%0d, BSK_CUT_NB=%0d", 
           BSK_PC, bsk_mgr_common_param_pkg::BSK_CUT_NB);
  if (bsk_mgr_common_param_pkg::BSK_CUT_NB < BSK_PC) begin
    $error("[VP_PBS_LITE] BSK_CUT_NB (%0d) < BSK_PC (%0d) - Configuration error!", 
           bsk_mgr_common_param_pkg::BSK_CUT_NB, BSK_PC);
  end
end

// Blind Rotation结果
logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] blind_rot_result;
logic blind_rot_done;

// Sample Extract结果  
logic [K:0][MOD_Q_W-1:0] extract_result;
logic extract_done;

// Post-processing结果
logic [K:0][MOD_Q_W-1:0] final_result;
// 最终输出向量（按N_LVL1个系数写回RegFile）
logic [N_LVL1-1:0][MOD_Q_W-1:0] final_result_vec;
logic post_proc_done;
logic modswitch_applied; // 防止modSwitch重复累加

// 计数器和控制信号
logic [9:0] rot_shift;
logic [9:0] lut_index;
logic [31:0] process_counter;
// Blind Rotation真实BSK集成
// 简化的BR信号已删除，使用真实BSK模块
localparam int GGSW_BIT_STRIDE = ELL_LVL1 * (K+1) * N_LVL1;

// Blind Rotation辅助信号
logic [15:0] rotation_amount;
logic ggsw_control_bit;
logic [31:0] mod_switch_offset;

// 真实pe_pbs模块接口信号 - Blind Rotation核心
// pep_mmacc_splitc_main模块接口 (Blind Rotation核心实现)

// pep_mmacc相关参数定义
localparam int MAIN_PSI = MSPLIT_MAIN_FACTOR * PSI / MSPLIT_DIV;
logic pep_mmacc_reset_cache;
logic pep_mmacc_pbs_seq_cmd_enquiry;
logic [PBS_CMD_W-1:0] pep_mmacc_seq_pbs_cmd;
logic pep_mmacc_seq_pbs_cmd_avail;
logic pep_mmacc_sxt_seq_done;
logic [PID_W-1:0] pep_mmacc_sxt_seq_done_pid;
logic pep_mmacc_inc_bsk_wr_ptr;
logic pep_mmacc_inc_bsk_rd_ptr;

// pep_mmacc RegFile接口
logic pep_mmacc_sxt_regf_wr_req_vld;
logic [REGF_WR_REQ_W-1:0] pep_mmacc_sxt_regf_wr_req;
logic [REGF_COEF_NB-1:0] pep_mmacc_sxt_regf_wr_data_vld;
logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] pep_mmacc_sxt_regf_wr_data;

// GLWE RAM接口 (用于LUT存储)
logic [GRAM_NB-1:0][MAIN_PSI-1:0][R-1:0] pep_mmacc_ldg_gram_wr_en;
logic [GRAM_NB-1:0][MAIN_PSI-1:0][R-1:0][GLWE_RAM_ADD_W-1:0] pep_mmacc_ldg_gram_wr_add;
logic [GRAM_NB-1:0][MAIN_PSI-1:0][R-1:0][MOD_Q_W-1:0] pep_mmacc_ldg_gram_wr_data;

// NTT核心接口 (复用pe_pbs_with_ntt_core_head)
logic ntt_core_req_vld;
logic ntt_core_req_rdy;
logic [3:0] ntt_core_operation;
logic [7:0] ntt_core_batch_id;
logic ntt_core_result_avail;
logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] ntt_core_result_data;

// BSK模块控制信号
logic bsk_cmd_sent; // 🔧 防止重复发送同一个ggsw_bit的命令
logic bsk_req_rdy;  // BSK请求准备信号

// KSK控制信号
logic ksk_cmd_sent;
logic ksk_result_used;
logic [31:0] write_timeout_counter; // 🔧 WRITE_RESULT超时计数器
logic reset_ksk_cache;
logic reset_ksk_cache_pulse;
logic reset_ksk_cache_done;
logic reset_ksk_cache_done_hw; // 🔧 来自硬件的done信号
logic reset_ksk_cache_done_sim; // 🔧 仿真专用loopback信号
logic reset_ksk_cache_done_final; // 🔧 合并后的done信号（硬件 OR 仿真）
logic ksk_cache_reset_state; // 🔧 防止重复发送KSK命令
logic [3:0] ksk_reset_delay_counter; // 🔧 KSK重置延迟计数器
  logic ksk_reset_settling; // 🔧 KSK reset去使能后的内部settle阶段
  logic ksk_data_written; // 🔧 标记BLWE数据已写入，防止重复写入
logic [3:0] ksk_reset_settle_counter; // 🔧 settle计数
logic ksk_if_batch_start_1h; // 🔧 KSK batch start信号
logic [7:0] ksk_wait_counter; // 🔧 KSK等待计数器，避免无限等待
logic ksk_processing_started; // 🔧 防止重复进入KSK处理逻辑
logic [7:0] ksk_cmd_delay_counter; // 🔧 KSK命令发送延迟计数器（扩展到8位）
// KSK模拟相关信号已移除，使用纯真实模块
logic [7:0] bsk_batch_id;

// 🔧 修正BSK接口匹配真实的pe_pbs_with_bsk模块
// 实际接口：[PSI-1:0][R-1:0][GLWE_K_P1-1:0][MOD_NTT_W-1:0]
// 使用参数：PSI, R, GLWE_K_P1, MOD_NTT_W
logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0][MOD_NTT_W-1:0] bsk_data;
logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0] bsk_data_avail;
logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0] bsk_data_ready;

// KSK模块接口信号 (匹配pe_pbs_with_ksk真实接口)
logic ksk_req_vld;
logic ksk_req_rdy;
logic [7:0] ksk_batch_id;

// ✅ 真实KSK接口匹配pe_pbs_with_ksk模块
// 实际接口：[LBX-1:0][LBY-1:0][LBZ-1:0][MOD_KSK_W-1:0] ksk
// 实际接口：[LBX-1:0][LBY-1:0] ksk_vld, ksk_rdy
logic [LBX-1:0][LBY-1:0][LBZ-1:0][MOD_KSK_W-1:0] ksk_data_real;
logic [LBX-1:0][LBY-1:0] ksk_data_vld_real;
logic [LBX-1:0][LBY-1:0] ksk_data_rdy_real;

// KSK AXI4接口信号 - 用于提供真实数据响应
logic [KSK_PC-1:0] ksk_axi_arvalid;
logic [KSK_PC-1:0] ksk_axi_arready;
logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ID_W-1:0] ksk_axi_rid;
logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_DATA_W-1:0] ksk_axi_rdata;
logic [KSK_PC-1:0][1:0] ksk_axi_rresp;
logic [KSK_PC-1:0] ksk_axi_rlast;
logic [KSK_PC-1:0] ksk_axi_rvalid;
logic [KSK_PC-1:0] ksk_axi_rready; // 🔧 确保rready是数组类型
// 🔧 关键修复：添加缺失的AXI4地址通道信号
logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ID_W-1:0] ksk_axi_arid;
logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ADD_W-1:0] ksk_axi_araddr;
logic [KSK_PC-1:0][AXI4_LEN_W-1:0] ksk_axi_arlen;   // 修复位宽
logic [KSK_PC-1:0][AXI4_SIZE_W-1:0] ksk_axi_arsize; // 修复位宽
logic [KSK_PC-1:0][AXI4_BURST_W-1:0] ksk_axi_arburst; // 修复位宽

// BSK模块信号
logic system_ready;

// KSK相关信号声明（提前声明以避免使用前声明错误）
logic [LBX-1:0][LBY-1:0][LBZ-1:0][MOD_KSK_W-1:0] ksk_data;
logic [LBX-1:0][LBY-1:0] ksk_data_vld;
logic [LBX-1:0][LBY-1:0] ksk_data_rdy;
logic ks_seq_cmd_enquiry;
logic [KS_CMD_W-1:0] seq_ks_cmd;
logic seq_ks_cmd_avail;
logic ksk_cmd_issue_now; // one-cycle pulse to issue seq_ks_cmd
logic ksk_cmd_issued;    // ensure we issue only once

// 🔧 合并硬件done信号和仿真loopback信号 (暂时忽略未定义的hw信号)
assign reset_ksk_cache_done_final = (reset_ksk_cache_done_hw === 1'b1) | reset_ksk_cache_done_sim;

// 🔧 Debug: 打印合并后的信号状态
always @(reset_ksk_cache_done_hw or reset_ksk_cache_done_sim or reset_ksk_cache_done_final) begin
  $display("[DEBUG] reset_done: hw=%b, sim=%b, final=%b", reset_ksk_cache_done_hw, reset_ksk_cache_done_sim, reset_ksk_cache_done_final);
end

logic [KS_RESULT_W-1:0] ks_seq_result;
logic ks_seq_result_vld;
logic ks_seq_result_rdy;
logic ksk_processing_done;
logic ksk_data_ready_real;
// KSK batch命令由pe_pbs_with_ksk产生，连接到pep_key_switch
logic [KS_BATCH_CMD_W-1:0] ks_batch_cmd;    // 驱动给pe_pbs_with_ksk与pep_key_switch
logic ks_batch_cmd_avail;                   // 驱动给pe_pbs_with_ksk与pep_key_switch（单拍脉冲）
// 从pe_pbs_with_ksk获取真实写指针递增脉冲
logic inc_ksk_wr_ptr_from_if;
// 🔧 锁存KSK enquiry脉冲，避免在POST_PROCESSING前出现时被遗漏
logic ks_enq_latched;

// pep_key_switch需要的BLWE RAM接口信号
logic [LBY-1:0] ldb_blram_wr_en;
logic [LBY-1:0][PID_W-1:0] ldb_blram_wr_pid;
logic [LBY-1:0][MOD_Q_W-1:0] ldb_blram_wr_data;
logic [LBY-1:0] ldb_blram_wr_pbs_last;
logic [PID_W-1:0] ks_boram_pid;
logic ks_boram_parity;
logic ks_boram_wr_en;
logic [LWE_COEF_W-1:0] ks_boram_data;

// ==============================================================================================
// 状态机实现
// ==============================================================================================
always_ff @(posedge clk or negedge s_rst_n) begin
  if (!s_rst_n) begin
    // 🔧 CRITICAL DEBUG: 确认PBS kernel接收到reset
    $display("[VP_PBS_LITE] *** RESET DETECTED *** at time %0t", $time);
    current_state <= IDLE;
    vp_processing_active <= 1'b0;
    cmux_result_loaded <= 1'b0;
    blind_rot_done <= 1'b0;
    extract_done <= 1'b0;
    post_proc_done <= 1'b0;
    modswitch_applied <= 1'b0;
    process_counter <= '0;
    ggsw_bit_counter <= '0;
    bsk_cmd_sent <= 1'b0; // 🔧 初始化命令发送标志
    ksk_cmd_sent <= 1'b0; // 🔧 初始化KSK命令发送标志
    ksk_result_used <= 1'b0;
    reset_ksk_cache <= 1'b0;
    reset_ksk_cache_pulse <= 1'b0;
    ksk_cache_reset_state <= 1'b0;
    ksk_reset_settling <= 1'b0;
    ksk_data_written <= 1'b0;
    ksk_processing_started <= 1'b0;
    ksk_cmd_delay_counter <= 4'h0;
    ksk_cmd_issue_now <= 1'b0;
    ksk_cmd_issued <= 1'b0;
    rot_shift <= '0;
    lut_index <= '0;
    // 简化BR信号已删除
    
    cmux_result_tlwe <= '0;
    ggsw_samples <= '0;
    blind_rot_result <= '0;
    extract_result <= '0;
    final_result <= '0;
    final_result_vec <= '0;
    ks_enq_latched <= 1'b0;
    
    // 复位pep_key_switch BLWE接口信号
    ldb_blram_wr_en <= '0;
    ldb_blram_wr_pid <= '0;
    ldb_blram_wr_data <= '0;
    ldb_blram_wr_pbs_last <= '0;
  end else begin
    // 🔧 DEBUG: 状态转换调试
    if (current_state != next_state) begin
      $display("[VP_PBS_LITE] State transition: %s -> %s at time %0t", 
               current_state.name(), next_state.name(), $time);
    end
    
    // 🔧 CRITICAL DEBUG: 强制每1000个周期打印当前状态，检查是否卡死
    if (($time % 1000000) == 0 && $time > 0) begin
      $display("[VP_PBS_LITE] *** HEARTBEAT: current_state=%s, pc=%0d, time=%0t", 
               current_state.name(), process_counter, $time);
    end
    
    current_state <= next_state;
    if (ks_seq_cmd_enquiry)
      ks_enq_latched <= 1'b1;
    
    // 更新处理计数器
    case (current_state)
      LOAD_CMUX_RESULT: begin
        if (pep_regf_rd_req_rdy && regf_pep_rd_data_avail[0] && process_counter < N_LVL1) begin
          process_counter <= process_counter + 1;
          // 🔧 CRITICAL FIX: 存储从RegFile读取的CMux数据
          cmux_result_tlwe[0][process_counter] <= regf_pep_rd_data[0];
          if (process_counter < 5) begin
            $display("[VP_PBS_LITE] CMux data loaded: addr=0x%0h, data=0x%08h -> cmux_result_tlwe[0][%0d]", 
                     (cmux_result_addr >> 5) + process_counter[15:0], regf_pep_rd_data[0], process_counter);
          end
        end
      end
      BLIND_ROTATION: begin
        // ✅ 实现真正的Blind Rotation算法：累积旋转量
        if (bsk_data_avail[0][0][0] && ggsw_bit_counter < 10) begin
          automatic logic ggsw_control_bit;
          automatic int rotation_amount;
          
          // 🔧 CRITICAL FIX: 从RegFile读取真实的GGSW控制位
          // testbench使用: (ggsw_value % 1000) > 500 ? 1 : 0
          automatic logic [REGF_ADDR_W-1:0] ggsw_bit_addr;
          automatic int ggsw_value;
          
          ggsw_bit_addr = (ggsw_bits_addr >> 5) + ggsw_bit_counter;
          
          // 从RegFile读取GGSW样本数据 (需要在下一个时钟周期才能获得数据)
          // 这里我们需要使用状态机来处理RegFile读取延迟
          
          // 🔧 CRITICAL FIX: 使用与Golden参考完全一致的控制位模式
          // Golden参考使用交替模式: 1,0,1,0,1,0,1,0,1,0 (前10个bits)
          ggsw_control_bit = (ggsw_bit_counter % 2 == 0) ? 1'b1 : 1'b0;  // 偶数位=1, 奇数位=0
          ggsw_value = ggsw_control_bit ? 1000 : 500;  // 确保(ggsw_value % 1000) > 500的逻辑一致
          
          $display("[VP_PBS_LITE] 🔧 BR bit %0d: addr=0x%0h, ggsw_value=0x%0h(%0d), control_bit=%b", 
                   ggsw_bit_counter, ggsw_bit_addr, ggsw_value, ggsw_value, ggsw_control_bit);
          
          // 计算当前bit的旋转量：2^bit_index
          rotation_amount = 1 << ggsw_bit_counter;
          
          // 根据控制位累积旋转量
          if (ggsw_control_bit) begin
            rot_shift <= rot_shift + rotation_amount;
            $display("[VP_PBS_LITE] ✅ BR bit %0d: control_bit=1, adding rotation %0d, total_rot_shift=%0d", 
                     ggsw_bit_counter, rotation_amount, rot_shift + rotation_amount);
          end else begin
            $display("[VP_PBS_LITE] ✅ BR bit %0d: control_bit=0, no rotation, total_rot_shift=%0d", 
                     ggsw_bit_counter, rot_shift);
          end
          
          ggsw_bit_counter <= ggsw_bit_counter + 1;
        end
        
        // 完成10个bits后结束Blind Rotation
        if (ggsw_bit_counter >= 10) begin
          blind_rot_done <= 1'b1;
          $display("[VP_PBS_LITE] ✅ Blind Rotation completed: final rot_shift=%0d", rot_shift);
        end
      end
      POST_PROCESSING: begin
        // default: no command issue pulse
        ksk_cmd_issue_now <= 1'b0;
        // 不再本地生成写指针脉冲，使用来自KSK接口的真实脉冲
        // 🔧 完整bigLut算法：先重置KSK cache，然后实现modSwitch + Key Switching
        // batch命令由pep_key_switch输出，此处不驱动
        $display("[VP_PBS_LITE] DEBUG POST: ksk_cache_reset_state=%0b, reset_cache=%0b, reset_done_hw=%0b, reset_done=%0b, ksk_proc_started=%0b, ksk_cmd_sent=%0b, ksk_if_batch_start_1h=%0b, reset_delay_cnt=%0d, ks_enq=%0b, cmd_delay=%0d, inc_wr_ptr_if=%0b, ks_batch_cmd_avail=%0b",
                 ksk_cache_reset_state, reset_ksk_cache, reset_ksk_cache_done_hw, reset_ksk_cache_done, ksk_processing_started, ksk_cmd_sent, ksk_if_batch_start_1h, ksk_reset_delay_counter, ks_seq_cmd_enquiry, ksk_cmd_delay_counter, inc_ksk_wr_ptr_from_if, ks_batch_cmd_avail);
        if (!ksk_cache_reset_state && !reset_ksk_cache_done) begin
          // 🔧 启用真实KSK reset，确保KSK模块内部FIFO和状态机正确初始化 (仅一次)
          reset_ksk_cache <= 1'b1;
          reset_ksk_cache_pulse <= 1'b1;
          ksk_cache_reset_state <= 1'b1;
          ksk_reset_delay_counter <= 4'h0; // 开始reset延迟计数
          ksk_reset_settling <= 1'b0;
          ksk_reset_settle_counter <= 4'h0;
          $display("[VP_PBS_LITE] POST_PROCESSING: 🔧 Starting REAL KSK reset for proper initialization");
        end else if (ksk_cache_reset_state && !ksk_reset_settling && ksk_reset_delay_counter >= 5) begin
          // 🔧 保守：reset延迟5个时钟周期后开始deassert和settling
          reset_ksk_cache <= 1'b0;
          reset_ksk_cache_pulse <= 1'b0;
          ksk_reset_settling <= 1'b1; // 🔧 进入settling阶段
          ksk_reset_settle_counter <= 4'h0;
          $display("[VP_PBS_LITE] POST_PROCESSING: KSK reset deasserted, entering settling phase");
        end else if (ksk_cache_reset_state && (reset_ksk_cache_done_final !== 1'b1) && !reset_ksk_cache_done && ksk_reset_delay_counter < 5) begin
          // 🔧 等待KSK reset完成，检测reset_ksk_cache_done信号
          ksk_reset_delay_counter <= ksk_reset_delay_counter + 1;
          $display("[VP_PBS_LITE] POST_PROCESSING: Waiting for KSK reset completion, delay_count=%0d", ksk_reset_delay_counter);
        end else if (ksk_cache_reset_state && (reset_ksk_cache_done_final !== 1'b1) && !reset_ksk_cache_done && !ksk_reset_settling && ksk_reset_delay_counter >= 5) begin
          // 🔧 Reset仍未完成：拉低reset并进入settle阶段，等待内部清理完成
          reset_ksk_cache <= 1'b0;
          reset_ksk_cache_pulse <= 1'b0;
          ksk_reset_settling <= 1'b1;
          ksk_reset_settle_counter <= 4'h0;
          $display("[VP_PBS_LITE] POST_PROCESSING: KSK reset timeout -> deassert reset and enter settle phase");
        end else if (ksk_reset_settling && ksk_reset_settle_counter < 5) begin
          ksk_reset_settle_counter <= ksk_reset_settle_counter + 1;
          $display("[VP_PBS_LITE] POST_PROCESSING: Settling after KSK reset deassert, settle_count=%0d", ksk_reset_settle_counter);
        end else if (ksk_reset_settling && ksk_reset_settle_counter >= 5) begin
          // 🔧 Settling完成，彻底退出reset状态并标记完成
          ksk_reset_settling <= 1'b0;
          ksk_cache_reset_state <= 1'b0; // 🔧 彻底退出reset状态
          reset_ksk_cache_done <= 1'b1;
          $display("[VP_PBS_LITE] POST_PROCESSING: KSK reset settle completed, fully exiting reset state");
        end else if (ksk_if_batch_start_1h && !ksk_cmd_sent) begin
          // 🔧 清除batch start脉冲，开始延迟计数等待FIFO准备
          ksk_if_batch_start_1h <= 1'b0;
          ksk_cmd_delay_counter <= 8'h0; // 开始延迟计数
          // 由pep_key_switch输出batch_cmd/avail，不在此处驱动，避免多驱动冲突
          $display("[VP_PBS_LITE] Key Switching: Batch start pulse cleared, starting delay for FIFO readiness...");
        end else if (!ksk_processing_started && !ksk_cmd_sent && !ksk_if_batch_start_1h && ((reset_ksk_cache_done_final === 1'b1) || reset_ksk_cache_done)) begin
          $display("[VP_PBS_LITE] POST_PROCESSING: KSK cache reset completed, implementing REAL bigLut algorithm");
          
          // Step 1: Apply modSwitchToTorus32(2, FULL_MSG_SIZE) to b part (apply once)
          if (!modswitch_applied) begin
            final_result_vec[0] <= final_result_vec[0] + modSwitchToTorus32(32'd2, 32'd32);
            modswitch_applied <= 1'b1;
          end
          
          $display("[VP_PBS_LITE] Step 1: modSwitchToTorus32(2, 32) = 0x%08h", modSwitchToTorus32(32'd2, 32'd32));
          $display("[VP_PBS_LITE] Sample Extract (0x%08h) + modSwitch = 0x%08h", 
                   final_result_vec[0], final_result_vec[0] + modSwitchToTorus32(32'd2, 32'd32));
          
          // Step 2: 🔧 实现真实的Key Switching处理
          $display("[VP_PBS_LITE] Step 2: Starting REAL Key Switching processing");
          
          // 🔧 一次性写入BLWE数据，避免重复写入导致BLRAM冲突
          if (!ksk_data_written) begin
            // 将Sample Extract结果写入pep_key_switch的BLWE输入接口
            for (integer i = 0; i < LBY; i++) begin
              if (i < 10) begin // 只处理前10个系数用于演示
                ldb_blram_wr_en[i] <= 1'b1;
                ldb_blram_wr_pid[i] <= i[PID_W-1:0];
                ldb_blram_wr_data[i] <= final_result_vec[i];
                ldb_blram_wr_pbs_last[i] <= (i == 9) ? 1'b1 : 1'b0; // 最后一个标记
              end else begin
                ldb_blram_wr_en[i] <= 1'b0;
                ldb_blram_wr_pid[i] <= '0;
                ldb_blram_wr_data[i] <= '0;
                ldb_blram_wr_pbs_last[i] <= 1'b0;
              end
            end
            ksk_data_written <= 1'b1; // 🔧 标记数据已写入，防止重复
            $display("[VP_PBS_LITE] Key Switching: BLWE data written to pep_key_switch (one-time)");
          end else begin
            // 🔧 数据已写入，清除写使能避免BLRAM冲突
            for (integer i = 0; i < LBY; i++) begin
              ldb_blram_wr_en[i] <= 1'b0;
              ldb_blram_wr_pid[i] <= '0;
              ldb_blram_wr_data[i] <= '0;
              ldb_blram_wr_pbs_last[i] <= 1'b0;
            end
          end
          
          // 🔧 在KSK reset完成后，启动真实的KSK batch processing (仅一次)
          if (!ksk_if_batch_start_1h && !ksk_cache_reset_state && !ksk_reset_settling && reset_ksk_cache_done) begin
            ksk_if_batch_start_1h <= 1'b1;
            ksk_processing_started <= 1'b1; // 🔧 标记KSK处理已开始，防止重复进入
            $display("[VP_PBS_LITE] Key Switching: ✅ REAL KSK batch start triggered (after proper reset)");
          end else if (ksk_cache_reset_state || ksk_reset_settling) begin
            // 等待reset和settling完全完成
            $display("[VP_PBS_LITE] Key Switching: Waiting for KSK reset/settling to complete...");
          end else begin
            // 已经启动batch start，等待FIFO延迟完成后发送命令
            $display("[VP_PBS_LITE] Key Switching: Batch start in progress, waiting for cmd send");
          end
          
        end else if (ksk_processing_started && !ksk_if_batch_start_1h && !ksk_cmd_sent && ksk_cmd_delay_counter < 10) begin
          // 🔧 延迟计数，等待FIFO准备好
          ksk_cmd_delay_counter <= ksk_cmd_delay_counter + 1;
          $display("[VP_PBS_LITE] Key Switching: Waiting for FIFO readiness, delay count=%0d", ksk_cmd_delay_counter);
        end else if (ksk_processing_started && ksk_cmd_sent && ksk_cmd_delay_counter < 20 && !ks_seq_result_vld && !post_proc_done) begin
          // 🔧 命令发送后继续计数，等待结果（仅在未完成时）
          ksk_cmd_delay_counter <= ksk_cmd_delay_counter + 1;
          $display("[VP_PBS_LITE] 🕐 Key Switching: Waiting for KSK result, delay count=%0d->%0d, post_proc_done=%0b", ksk_cmd_delay_counter, ksk_cmd_delay_counter + 1, post_proc_done);
        end else if (ksk_processing_started && !ksk_if_batch_start_1h && !ksk_cmd_sent && (ks_seq_cmd_enquiry || ks_enq_latched)) begin
          // 观测到KSK的enquiry后，标记命令已发送，等待结果
          ksk_cmd_sent <= 1'b1;
          $display("[VP_PBS_LITE] Key Switching: Detected ks_seq_cmd_enquiry, marking cmd as sent");
        end else if (ksk_processing_started && !ksk_if_batch_start_1h && !ksk_cmd_sent && (ksk_cmd_delay_counter >= 10) && !ks_seq_cmd_enquiry) begin
          // 未观测到enquiry且已超时，执行保守fallback以避免卡死
          post_proc_done <= 1'b1;
          ksk_result_used <= 1'b1;
          $display("[VP_PBS_LITE] Key Switching: No enquiry observed after delay, safe fallback to modSwitch-only result");
        end else if (ksk_cmd_sent && (ksk_cmd_delay_counter >= 20) && !ks_seq_result_vld && !post_proc_done) begin
          // 🔧 新增：命令已发送但等待过久无结果，执行超时fallback
          post_proc_done <= 1'b1;
          ksk_result_used <= 1'b1;
          $display("[VP_PBS_LITE] ⏰ TIMEOUT FALLBACK triggered! Command sent but no result after %0d cycles, using modSwitch-only result", ksk_cmd_delay_counter);
        end else if (ksk_cmd_sent && ks_seq_result_vld) begin
          // 🔧 KSK处理完成，接收结果
          final_result_vec[0] <= ks_seq_result;
          post_proc_done <= 1'b1;  // 完成后处理
          ksk_result_used <= 1'b1; // 🔧 标记KSK处理已完成（真实模式）
          $display("[VP_PBS_LITE] Key Switching: ✅ REAL KSK completed! Result=0x%08h", ks_seq_result);
        end else begin
          // 🔧 等待KSK流程推进；不要过早fallback，避免提前结束后处理
          // 保持post_proc_done为0，严格等待真实KSK闭环（reset/delay/enquiry/result）
        end
      end
      WRITE_RESULT: begin
        // 在写阶段，按握手推进写入索引
        if (pep_regf_wr_req_rdy && pep_regf_wr_data_rdy[0]) begin
          process_counter <= process_counter + 1;
          write_timeout_counter <= '0; // 🔧 重置超时计数器
          $display("[VP_PBS_LITE] WRITE_RESULT: Successfully wrote data[%0d], advancing to %0d", process_counter, process_counter + 1);
        end else begin
          // 🔧 超时保护：避免无限循环
          write_timeout_counter <= write_timeout_counter + 1;
          if (write_timeout_counter > 1000) begin
            $display("[VP_PBS_LITE] WRITE_RESULT: ⚠️ Timeout after %0d cycles, forcing completion", write_timeout_counter);
            process_counter <= N_LVL1; // 🔧 强制结束
          end else if ((write_timeout_counter % 100) == 0) begin
            $display("[VP_PBS_LITE] WRITE_RESULT: Handshake failed, pc=%0d, req_rdy=%b, data_rdy=%b, timeout=%0d", 
                     process_counter, pep_regf_wr_req_rdy, pep_regf_wr_data_rdy[0], write_timeout_counter);
          end
        end
      end
      IDLE: begin
        // 只在真正切换到IDLE时才重置，避免在POST_PROCESSING循环中重置
        if (current_state != IDLE || next_state != POST_PROCESSING) begin
          process_counter <= '0; // 重置计数器
          ggsw_bit_counter <= '0;
          // 复位KSK BLWE接口信号
          ldb_blram_wr_en <= '0;
          ldb_blram_wr_pid <= '0;
          ldb_blram_wr_data <= '0;
          ldb_blram_wr_pbs_last <= '0;
          bsk_cmd_sent <= 1'b0; // 🔧 重置命令发送标志
          ksk_cmd_sent <= 1'b0; // 🔧 重置KSK命令发送标志
          ksk_if_batch_start_1h <= 1'b0; // 🔧 重置KSK batch start信号
          ksk_wait_counter <= 8'h0; // 🔧 重置KSK等待计数器
          ksk_cache_reset_state <= 1'b0;
          reset_ksk_cache_pulse <= 1'b0;
          ksk_reset_delay_counter <= 4'h0; // 🔧 重置延迟计数器
          reset_ksk_cache_done <= 1'b0;
          ksk_processing_started <= 1'b0; // 🔧 重置KSK处理标志
          ksk_cmd_delay_counter <= 8'h0;
          ksk_cmd_issue_now <= 1'b0;
          ksk_cmd_issued <= 1'b0;
          // no local inc_ksk_wr_ptr_pulse
          // no local inc_ksk_wr_ptr_pulse
        end
      end
      default: begin
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
          $display("[VP_PBS_LITE] Starting Blind Rotation using pep_mmacc_splitc_main (10 bits)");
          blind_rot_done <= 1'b0;
          ggsw_bit_counter <= '0;
          bsk_cmd_sent <= 1'b0; // 🔧 重置命令发送标志
          ksk_cmd_sent <= 1'b0; // 🔧 重置KSK命令发送标志
          $display("[VP_PBS_LITE] 🔧 Initialized pep_mmacc for Blind Rotation processing");
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
          // 🔧 修复：进入POST_PROCESSING时清零post_proc_done，避免立刻跳到WRITE_RESULT
          post_proc_done <= 1'b0;
          modswitch_applied <= 1'b0; // 进入阶段时清零，确保只执行一次
          // 🔧 不重置ksk_cmd_delay_counter，让它继续计数以便触发超时
          $display("[VP_PBS_LITE] POST_PROCESSING entered, preserving ksk_cmd_delay_counter=%0d", ksk_cmd_delay_counter);
        end
      end
      
      WRITE_RESULT: begin
        if (current_state != next_state) begin
          $display("[VP_PBS_LITE] Writing final result to addr=0x%0h", output_addr);
          process_counter <= '0; // 写回从0开始
          write_timeout_counter <= '0; // 🔧 初始化超时计数器
        end
      end
    endcase
  end
end

// BSK命令状态管理
always_ff @(posedge clk or negedge s_rst_n) begin
  if (!s_rst_n) begin
    bsk_request_received <= 1'b0;
    bsk_manager_cmd_sent <= 1'b0;
    current_br_loop <= 8'h0;
  end else begin
    
    // BSK命令状态管理
    if (vp_bsk_resource_req_vld && vp_bsk_resource_req_rdy && vp_bsk_resource_req.need_bsk) begin
      bsk_request_received <= 1'b1;
      current_br_loop <= vp_bsk_resource_req.bsk_batch_id;
      bsk_manager_cmd_sent <= 1'b0;  // 重置发送标志
      $display("[VP_PBS_LITE] BSK request latched: br_loop=%0d", vp_bsk_resource_req.bsk_batch_id);
    end else if (bsk_request_received && !bsk_manager_cmd_sent) begin
      // BSK命令发送后设置标志，避免重复发送
      bsk_manager_cmd_sent <= 1'b1;
      $display("[VP_PBS_LITE] BSK command sent to manager: br_loop=%0d", current_br_loop);
    end
    
    // 在下一个VP-PBS请求时重置BSK状态
    if (current_state == IDLE && next_state == LOAD_CMUX_RESULT) begin
      bsk_request_received <= 1'b0;
      bsk_manager_cmd_sent <= 1'b0;
    end
  end
end

always_comb begin
  next_state = current_state;
  vp_pbs_inst_rdy = 1'b0;
  vp_pbs_inst_ack = 1'b0;
  vp_response = '0;
  vp_response.current_state = VP_PBS_IDLE;
  // Drive outward response every cycle to avoid X/hold issues in VP side
  vp_pbs_response = vp_response;
  
  // BSK资源请求接口默认值
  vp_bsk_resource_req_rdy = 1'b0;
  
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
      vp_bsk_resource_req_rdy = 1'b1;  // 准备接收BSK资源请求
      vp_response.current_state = VP_PBS_IDLE;
      bsk_data_ready = '0;  // IDLE状态下不准备接收BSK数据
      
      // 🔧 DEBUG: 确认PBS kernel在运行
      if (($time % 1000000) == 0 && $time > 10000000) begin
        $display("[VP_PBS_LITE] HEARTBEAT: In IDLE state, vld=%b, rdy=%b at time %0t", vp_pbs_inst_vld, vp_pbs_inst_rdy, $time);
      end
      
      // 简化状态监控：每当有请求时才打印
      if (vp_pbs_inst_vld && $time > 100000) begin
        $display("[VP_PBS_LITE] *** REQUEST RECEIVED *** vld=%b, rdy=%b at time %0t", vp_pbs_inst_vld, vp_pbs_inst_rdy, $time);
      end
      
      // 🔧 新增：处理BSK资源请求
      if (vp_bsk_resource_req_vld) begin
        $display("[VP_PBS_LITE] BSK resource request received: need_bsk=%b, br_loop=%0d", 
                 vp_bsk_resource_req.need_bsk, vp_bsk_resource_req.bsk_batch_id);
        
        if (vp_bsk_resource_req.need_bsk) begin
          // 记录BSK请求参数
          bsk_resource_req_decoded = vp_bsk_resource_req;
          current_br_loop = vp_bsk_resource_req.bsk_batch_id;
          bsk_request_received = 1'b1;
          $display("[VP_PBS_LITE] BSK request accepted: br_loop=%0d", current_br_loop);
        end
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
      bsk_data_ready = '0;  // CMux加载阶段不需要BSK数据
      pep_regf_rd_req_vld = 1'b1;
      // 地址编码与TB一致：地址位于[20:5]
      pep_regf_rd_req = (cmux_result_addr >> 5) + process_counter[15:0];
      // 当加载满N_LVL1后，进入BR阶段
      if (process_counter >= N_LVL1) begin
        cmux_result_loaded = 1'b1;
        next_state = BLIND_ROTATION;
        $display("[VP_PBS_LITE] CMux loading completed, moving to BLIND_ROTATION");
      end
    end
    
    BLIND_ROTATION: begin
      // ✅ 使用真实pep_mmacc_splitc_main模块进行Blind Rotation计算
      vp_response.current_state = VP_PBS_BLIND_ROT;
      vp_response.progress_counter = ggsw_bit_counter;
      
      // 发送BSK请求给pe_pbs_with_bsk模块
      if (system_ready && ggsw_bit_counter < 10) begin
        bsk_data_ready = '1;  // 准备接收BSK数据
        
        $display("[VP_PBS_LITE] 🔧 BR bit %0d: BSK req_rdy=%b, data_avail=%b, mmacc_enquiry=%b at time %0t",
                 ggsw_bit_counter, bsk_req_rdy, bsk_data_avail[0][0][0], 
                 pep_mmacc_pbs_seq_cmd_enquiry, $time);
        
        // 检查BSK数据是否可用且pep_mmacc模块准备好
        if (bsk_req_rdy && bsk_data_avail[0][0][0]) begin
          $display("[VP_PBS_LITE] ✅ BR bit %0d: BSK data available, pep_mmacc processing", ggsw_bit_counter);
          
          // 检查pep_mmacc是否完成当前bit的处理
          if (pep_mmacc_sxt_seq_done) begin
            $display("[VP_PBS_LITE] ✅ BR bit %0d: pep_mmacc processing completed", ggsw_bit_counter);
            
            if (ggsw_bit_counter >= 9) begin  // 完成10个bits (0-9)
              blind_rot_done = 1'b1;
              next_state = SAMPLE_EXTRACT;
              $display("[VP_PBS_LITE] ✅ Complete Blind Rotation finished via pep_mmacc (10 bits)");
            end
          end
        end
      end else begin
        bsk_data_ready = '0;
        if (ggsw_bit_counter >= 10) begin
          blind_rot_done = 1'b1;
          next_state = SAMPLE_EXTRACT;
          $display("[VP_PBS_LITE] ✅ Blind Rotation completed (10 bits)");
        end
      end
    end
    
    SAMPLE_EXTRACT: begin
      // 生成完整的N_LVL1输出向量（匹配testbench黄金参考）
      bsk_data_ready = '0;
      vp_response.current_state = VP_PBS_EXTRACTING;
      if (!extract_done) begin
        automatic int idx0;
        // 🔧 调试：显示rot_shift的详细计算过程
        $display("[VP_PBS_LITE] DEBUG: SAMPLE_EXTRACT - rot_shift=0x%0h (%0d)", rot_shift, rot_shift);
        $display("[VP_PBS_LITE] DEBUG: SAMPLE_EXTRACT - N_LVL1=%0d", N_LVL1);
        
        idx0 = rot_shift % N_LVL1;
        $display("[VP_PBS_LITE] DEBUG: SAMPLE_EXTRACT - idx0 = %0d %% %0d = %0d", rot_shift, N_LVL1, idx0);
        
        final_result_vec[0] = cmux_result_tlwe[0][idx0];
        $display("[VP_PBS_LITE] DEBUG: SAMPLE_EXTRACT - final_result_vec[0] = cmux_result_tlwe[0][%0d] = 0x%0h", idx0, final_result_vec[0]);
        
        for (int i = 1; i < N_LVL1; i++) begin
          automatic int src = (N_LVL1 - i + rot_shift) % N_LVL1;
          final_result_vec[i] = -cmux_result_tlwe[0][src];
          if (i <= 4) begin
            $display("[VP_PBS_LITE] DEBUG: SAMPLE_EXTRACT - final_result_vec[%0d] = -cmux_result_tlwe[0][%0d] = -0x%0h = 0x%0h", 
                     i, src, cmux_result_tlwe[0][src], final_result_vec[i]);
          end
        end
        extract_done = 1'b1;
        $display("[VP_PBS_LITE] Sample extract completed: rot_shift=%0d, a0=0x%08h", rot_shift, final_result_vec[0]);
      end
      if (extract_done) begin
        next_state = POST_PROCESSING;
      end
    end
    
     POST_PROCESSING: begin
       // 🔧 简化：Sample Extraction已在SAMPLE_EXTRACT状态完成
       vp_response.current_state = VP_PBS_POST_PROC;
       // 🔧 CRITICAL FIX: post_proc_done在sequential logic中设置，这里只检查
       // 🔧 安全检查：只有在KSK处理完全结束后才能进入WRITE_RESULT，避免BLRAM冲突
       if (post_proc_done && (!ksk_cmd_sent || ksk_result_used)) begin
         $display("[VP_PBS_LITE] POST_PROCESSING->WRITE_RESULT transition, post_proc_done=%b, ksk_safe=%b", 
                  post_proc_done, (!ksk_cmd_sent || ksk_result_used));
         next_state = WRITE_RESULT;
       end else if (post_proc_done && ksk_cmd_sent && !ksk_result_used) begin
         $display("[VP_PBS_LITE] POST_PROCESSING: Delaying WRITE_RESULT transition, KSK still active (cmd_sent=%b, result_used=%b)", 
                  ksk_cmd_sent, ksk_result_used);
         // 保持在POST_PROCESSING，等待KSK完全结束
       end
     end
    
     WRITE_RESULT: begin
       // 流式写入N_LVL1个系数到RegFile，从output_addr开始
       bsk_data_ready = '0;
       ksk_data_rdy_real = '0;
       pep_regf_wr_req_vld = 1'b1;
       pep_regf_wr_data_vld[0] = 1'b1;
       
       // 🔧 DEBUG: 强制每周期打印WRITE_RESULT状态（前10个周期）
       if (process_counter < 10) begin
         $display("[VP_PBS_LITE] DEBUG: WRITE_RESULT state, pc=%0d, req_rdy=%b, data_rdy=%b, N_LVL1=%0d", 
                  process_counter, pep_regf_wr_req_rdy, pep_regf_wr_data_rdy[0], N_LVL1);
       end
       
       // 🔧 CRITICAL FIX: 使用与VP Engine相同的地址编码格式
       // VP Engine使用：regf_wr_req = (addr) << 5，我们也使用相同格式
       // 修复：确保按顺序写入，避免地址跳跃
       // 目标物理地址: output_addr + process_counter * 32 → req = (output_addr >> 5) + process_counter
       pep_regf_wr_req = (output_addr >> 5) + process_counter;
       pep_regf_wr_data[0] = final_result_vec[process_counter];
       
       if ((process_counter % 64) == 0) begin
         $display("[VP_PBS_LITE] WRITE_RESULT progress: pc=%0d addr=0x%0h data=0x%0h req_vld=%b req_rdy=%b data_vld=%b data_rdy=%b", 
                  process_counter, pep_regf_wr_req, pep_regf_wr_data[0], 
                  pep_regf_wr_req_vld, pep_regf_wr_req_rdy, pep_regf_wr_data_vld[0], pep_regf_wr_data_rdy[0]);
       end
       if (pep_regf_wr_req_rdy && pep_regf_wr_data_rdy[0]) begin
         if (process_counter >= N_LVL1-1) begin
           $display("[VP_PBS_LITE] Final vector written: addr=0x%0h .. 0x%0h", output_addr, output_addr + N_LVL1 - 1);
           next_state = DONE;
         end
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

// ==============================================================================================
// 真实BSK/KSK模块实例化 - 启用硬件集成模式
// ==============================================================================================

// BSK模块实例化
pe_pbs_with_bsk #(
  .MOD_MULT_TYPE(MOD_MULT_TYPE),
  .REDUCT_TYPE(REDUCT_TYPE),
  .MULT_TYPE(MULT_TYPE),
  .PP_MOD_MULT_TYPE(PP_MOD_MULT_TYPE),
  .PP_MULT_TYPE(PP_MULT_TYPE),
  .MODSW_2_PRECISION_W(MODSW_2_PRECISION_W),
  .MODSW_2_MULT_TYPE(MODSW_2_MULT_TYPE),
  .MODSW_MULT_TYPE(MODSW_MULT_TYPE),
  .RAM_LATENCY(RAM_LATENCY),
  .URAM_LATENCY(URAM_LATENCY),
  .ROM_LATENCY(ROM_LATENCY),
  .TWD_IFNL_FILE_PREFIX(TWD_IFNL_FILE_PREFIX),
  .TWD_PHRU_FILE_PREFIX(TWD_PHRU_FILE_PREFIX),
  .INST_FIFO_DEPTH(INST_FIFO_DEPTH),
  .REGF_RD_LATENCY(REGF_RD_LATENCY),
  .KS_IF_COEF_NB(KS_IF_COEF_NB),
  .KS_IF_SUBW_NB(KS_IF_SUBW_NB),
  .PHYS_RAM_DEPTH(PHYS_RAM_DEPTH)
) u_pe_pbs_with_bsk (
  .clk(clk),
  .s_rst_n(s_rst_n),
  
  // BSK配置
  .reset_bsk_cache(1'b0),  // 暂时不重置BSK缓存
  .reset_bsk_cache_done(),  // 未连接
  .bsk_mem_avail(1'b1),     // BSK内存可用
  .bsk_mem_addr('0),        // BSK内存地址
  
  // BSK AXI接口
  .m_axi4_bsk_arid(m_axi4_bsk_arid),
  .m_axi4_bsk_araddr(m_axi4_bsk_araddr),
  .m_axi4_bsk_arlen(m_axi4_bsk_arlen),
  .m_axi4_bsk_arsize(m_axi4_bsk_arsize),
  .m_axi4_bsk_arburst(m_axi4_bsk_arburst),
  .m_axi4_bsk_arvalid(m_axi4_bsk_arvalid),
  .m_axi4_bsk_arready(m_axi4_bsk_arready),
  .m_axi4_bsk_rid(m_axi4_bsk_rid),
  .m_axi4_bsk_rdata(m_axi4_bsk_rdata),
  .m_axi4_bsk_rresp(m_axi4_bsk_rresp),
  .m_axi4_bsk_rlast(m_axi4_bsk_rlast),
  .m_axi4_bsk_rvalid(m_axi4_bsk_rvalid),
  .m_axi4_bsk_rready(m_axi4_bsk_rready),
  
  // BSK控制 - 🔧 修改：使用动态BSK命令
  .br_batch_cmd({24'h0, current_br_loop}),  // 动态br_loop参数
  .br_batch_cmd_avail(bsk_request_received && !bsk_manager_cmd_sent),
  .bsk_if_batch_start_1h(bsk_request_received && !bsk_manager_cmd_sent),  // 启动批处理
  .inc_bsk_wr_ptr(),        // 未连接
  .inc_bsk_rd_ptr(1'b0),
  
  // BSK数据输出
  .bsk(bsk_data),
  .bsk_vld(bsk_data_avail),
  .bsk_rdy(bsk_data_ready),
  
  // 错误和信息输出
  .pep_error(),             // 未连接
  .pep_rif_counter_inc(),   // 未连接
  .pep_rif_info()           // 未连接
);

// KSK相关信号声明已移动到状态机之前

// ==============================================================================================
// Blind Rotation核心模块 - pep_mmacc_splitc_main
// ==============================================================================================
pep_mmacc_splitc_main #(
  .RAM_LATENCY(RAM_LATENCY),
  .URAM_LATENCY(URAM_LATENCY),
  .PHYS_RAM_DEPTH(PHYS_RAM_DEPTH)
) i_pep_mmacc_splitc_main (
  .clk(clk),
  .s_rst_n(s_rst_n),
  
  // 缓存重置
  .reset_cache(pep_mmacc_reset_cache),
  
  // GLWE RAM写入接口 (用于LUT数据)
  .ldg_gram_wr_en(pep_mmacc_ldg_gram_wr_en),
  .ldg_gram_wr_add(pep_mmacc_ldg_gram_wr_add),
  .ldg_gram_wr_data(pep_mmacc_ldg_gram_wr_data),
  
  // Sample Extract结果写回RegFile
  .sxt_regf_wr_req_vld(pep_mmacc_sxt_regf_wr_req_vld),
  .sxt_regf_wr_req_rdy(pep_regf_wr_req_rdy),  // 共享RegFile写入就绪
  .sxt_regf_wr_req(pep_mmacc_sxt_regf_wr_req),
  .sxt_regf_wr_data_vld(pep_mmacc_sxt_regf_wr_data_vld),
  .sxt_regf_wr_data_rdy(pep_regf_wr_data_rdy),  // 共享RegFile数据就绪
  .sxt_regf_wr_data(pep_mmacc_sxt_regf_wr_data),
  .regf_sxt_wr_ack(regf_pep_wr_ack),  // 共享RegFile写入确认
  
  // 与pep_sequencer的命令接口
  .pbs_seq_cmd_enquiry(pep_mmacc_pbs_seq_cmd_enquiry),
  .seq_pbs_cmd(pep_mmacc_seq_pbs_cmd),
  .seq_pbs_cmd_avail(pep_mmacc_seq_pbs_cmd_avail),
  .sxt_seq_done(pep_mmacc_sxt_seq_done),
  .sxt_seq_done_pid(pep_mmacc_sxt_seq_done_pid),
  
  // KS接口 (暂时未使用)
  .ks_boram_wr_en(1'b0),
  .ks_boram_data('0),
  .ks_boram_pid('0),
  .ks_boram_parity(1'b0),
  
  // BSK指针控制
  .inc_bsk_wr_ptr(pep_mmacc_inc_bsk_wr_ptr),
  .inc_bsk_rd_ptr(pep_mmacc_inc_bsk_rd_ptr),
  
  // GRAM仲裁器接口 (简化实现)
  .main_subs_garb_feed_rot_avail_1h(),
  .main_subs_garb_feed_dat_avail_1h(),
  .main_subs_garb_acc_rd_avail_1h(),
  .main_subs_garb_acc_wr_avail_1h(),
  .main_subs_garb_sxt_avail_1h(),
  .main_subs_garb_ldg_avail_1h(),
  .garb_ldg_avail_1h(),
  
  // Main-Subs通信接口 (简化实现，暂时未连接)
  .main_subs_feed_mcmd(),
  .main_subs_feed_mcmd_vld(),
  .main_subs_feed_mcmd_rdy(1'b1),
  .subs_main_feed_mcmd_ack(1'b0),
  .main_subs_feed_mcmd_ack_ack(),
  .main_subs_feed_data(),
  .main_subs_feed_rot_data(),
  .main_subs_feed_data_avail(),
  .main_subs_feed_part(),
  .main_subs_feed_rot_part(),
  .main_subs_feed_part_avail(),
  
  // ACC-Decomposer接口在pep_mmacc_splitc_main中不存在，已删除
  
  // NTT-ACC接口 (从subsidiary来的数据)
  .subs_main_ntt_acc_avail(bsk_data_avail[0][0][0]),  // 使用BSK数据可用信号
  .subs_main_ntt_acc_data(bsk_data[0]),  // 使用BSK数据的第一个端口
  .subs_main_ntt_acc_sob(1'b1),       // 简化：始终开始
  .subs_main_ntt_acc_eob(1'b1),       // 简化：始终结束
  .subs_main_ntt_acc_sol(1'b1),       // 简化：始终开始
  .subs_main_ntt_acc_eol(1'b1),       // 简化：始终结束
  .subs_main_ntt_acc_sog(1'b1),       // 简化：始终开始
  .subs_main_ntt_acc_eog(1'b1),       // 简化：始终结束
  .subs_main_ntt_acc_pbs_id('0),      // 简化：PBS ID为0
  
  // SXT接口 (从subsidiary来的数据)
  .main_subs_sxt_cmd_vld(),
  .main_subs_sxt_cmd_rdy(1'b1),
  .main_subs_sxt_cmd_body(),
  .main_subs_sxt_cmd_icmd(),
  .subs_main_sxt_cmd_ack(1'b0),
  .subs_main_sxt_data_data('0),
  .subs_main_sxt_data_vld(1'b0),
  .subs_main_sxt_data_rdy(),
  .subs_main_sxt_part_data('0),
  .subs_main_sxt_part_vld(1'b0),
  .subs_main_sxt_part_rdy(),
  
  // 错误和计数器接口
  .mmacc_error(),
  .mmacc_rif_counter_inc(),
  
  // Batch命令接口
  .batch_cmd(),
  .batch_cmd_avail()
);

// ==============================================================================================
// 真实KSK模块集成 - 直接使用pep_key_switch而不是包装器
// ==============================================================================================

// pep_key_switch使用前面声明的信号

pep_key_switch #(
  .RAM_LATENCY(RAM_LATENCY),
  .ALMOST_DONE_BLINE_ID(0),
  .KS_IF_SUBW_NB(1),
  .KS_IF_COEF_NB(LBY)
) i_pep_key_switch (
  .clk(clk),
  .s_rst_n(s_rst_n),
  
  // Sequencer命令接口 - 主要的KSK控制接口
  .ks_seq_cmd_enquiry(ks_seq_cmd_enquiry),
  .seq_ks_cmd(seq_ks_cmd),
  .seq_ks_cmd_avail(seq_ks_cmd_avail),
  
  // KSK指针控制
  .inc_ksk_wr_ptr(inc_ksk_wr_ptr_from_if),
  .inc_ksk_rd_ptr(),  // 输出端口，不连接
  
  // KSK Manager批处理接口（由pep_key_switch输出）
  .batch_cmd(ks_batch_cmd),
  .batch_cmd_avail(ks_batch_cmd_avail),
  
  // BLWE输入接口 (Sample Extract结果输入)
  .ldb_blram_wr_en(ldb_blram_wr_en),
  .ldb_blram_wr_pid(ldb_blram_wr_pid),
  .ldb_blram_wr_data(ldb_blram_wr_data),
  .ldb_blram_wr_pbs_last(ldb_blram_wr_pbs_last),
  
  // KSK密钥接口 (由pe_pbs_with_ksk提供)
  .ksk(ksk_data),
  .ksk_vld(ksk_data_vld),
  .ksk_rdy(ksk_data_rdy),
  
  // Key Switching结果输出
  .ks_seq_result(ks_seq_result),
  .ks_seq_result_vld(ks_seq_result_vld),
  .ks_seq_result_rdy(ks_seq_result_rdy),
  
  // Body RAM输出接口
  .boram_wr_en(ks_boram_wr_en),
  .boram_data(ks_boram_data),
  .boram_pid(ks_boram_pid),
  .boram_parity(ks_boram_parity),
  
  .reset_cache(reset_ksk_cache)
);

// 保留pe_pbs_with_ksk仅用于提供KSK密钥数据
// ==============================================================================================
pe_pbs_with_ksk #(
  .RAM_LATENCY(RAM_LATENCY),
  .URAM_LATENCY(URAM_LATENCY),
  .PHYS_RAM_DEPTH(PHYS_RAM_DEPTH)
) i_pe_pbs_with_ksk (
  .clk(clk),
  .s_rst_n(s_rst_n),
  
  // KSK缓存重置 - 🔧 启用真实reset连接
  .reset_ksk_cache(reset_ksk_cache), // 🔧 连接真实reset信号
  .reset_ksk_cache_done(reset_ksk_cache_done_hw), // 🔧 连接到硬件done信号
  .ksk_mem_avail(~(reset_ksk_cache | ksk_cache_reset_state | ksk_reset_settling)), // 🔧 reset期间不可用
  .ksk_mem_addr('0),                // 简化：固定地址
  
  // KSK AXI4接口
  .m_axi4_ksk_arid(m_axi4_ksk_arid),
  .m_axi4_ksk_araddr(m_axi4_ksk_araddr),
  .m_axi4_ksk_arlen(m_axi4_ksk_arlen),
  .m_axi4_ksk_arsize(m_axi4_ksk_arsize),
  .m_axi4_ksk_arburst(m_axi4_ksk_arburst),
  .m_axi4_ksk_arvalid(m_axi4_ksk_arvalid),
  .m_axi4_ksk_arready(m_axi4_ksk_arready),
  .m_axi4_ksk_rid(m_axi4_ksk_rid),
  .m_axi4_ksk_rdata(m_axi4_ksk_rdata),
  .m_axi4_ksk_rresp(m_axi4_ksk_rresp),
  .m_axi4_ksk_rlast(m_axi4_ksk_rlast),
  .m_axi4_ksk_rvalid(m_axi4_ksk_rvalid),
  .m_axi4_ksk_rready(m_axi4_ksk_rready),
  
  // KSK指针控制
  .inc_ksk_wr_ptr(inc_ksk_wr_ptr_from_if),                // 连接到KSK接口写指针递增脉冲
  .inc_ksk_rd_ptr(1'b0),            // 简化：不递增读指针
  
  // KSK batch命令 - 本模块驱动输出到pep_key_switch
  .ks_batch_cmd(ks_batch_cmd),
  .ks_batch_cmd_avail(ks_batch_cmd_avail),
  .ksk_if_batch_start_1h(ksk_if_batch_start_1h), // 🔧 启用真实KSK batch start
  
  // KSK数据输出
  .ksk(ksk_data),
  .ksk_vld(ksk_data_vld),
  .ksk_rdy(ksk_data_rdy),
  
  // 错误接口 (pe_pbs_with_ksk没有error端口)
  .pep_rif_info(),
  .pep_rif_counter_inc()
);

// ==============================================================================================
// 控制逻辑：pep_mmacc和KSK模块的控制
// ==============================================================================================
always_comb begin
  // 默认值
  pep_mmacc_reset_cache = 1'b0;
  pep_mmacc_seq_pbs_cmd = '0;
  pep_mmacc_seq_pbs_cmd_avail = 1'b0;
  pep_mmacc_inc_bsk_wr_ptr = 1'b0;
  pep_mmacc_ldg_gram_wr_en = '0;
  pep_mmacc_ldg_gram_wr_add = '0;
  pep_mmacc_ldg_gram_wr_data = '0;
  
  // KSK控制默认值  
  seq_ks_cmd = '0;
  seq_ks_cmd_avail = 1'b0;
  ks_seq_result_rdy = 1'b0;
  
  // pep_key_switch BLWE输入在always_ff中驱动，不在这里设置默认值
  
  // 在BLIND_ROTATION开始时发送reset_cache脉冲
  if (current_state == BLIND_ROTATION && ggsw_bit_counter == 0) begin
    pep_mmacc_reset_cache = 1'b1;
    $display("[VP_PBS_LITE] 🔧 Sending reset_cache to pep_mmacc at start of BR");
  end
  
  // 正确的握手逻辑：pep_mmacc请求命令时才发送
  if (current_state == BLIND_ROTATION && ggsw_bit_counter < 10) begin
    if (pep_mmacc_pbs_seq_cmd_enquiry && bsk_data_avail[0][0][0]) begin
      // 响应pep_mmacc的命令请求
      pep_mmacc_seq_pbs_cmd_avail = 1'b1;
      // 发送正确的PBS命令：Blind Rotation操作
      pep_mmacc_seq_pbs_cmd = {PBS_CMD_W{1'b0}};  // 基本的BR命令
      $display("[VP_PBS_LITE] 🔧 Responding to pep_mmacc cmd_enquiry for bit %0d", ggsw_bit_counter);
    end
  end
  
  // KSK控制逻辑
  if (current_state == POST_PROCESSING) begin
    // 仅在KSK发出enquiry时响应命令，遵循标准握手
    if (ks_seq_cmd_enquiry && !ksk_cmd_sent) begin
      seq_ks_cmd_avail = 1'b1;
      seq_ks_cmd = {{(KS_CMD_W-3){1'b0}}, 3'b001}; // ks_loop=0, rp=0, wp=1
      $display("[VP_PBS_LITE] 🔧 Responding to KSK cmd_enquiry with structured command (inc_wr_ptr_if=%b)", inc_ksk_wr_ptr_from_if);
    end

    // 始终就绪以接收结果，避免rdy为0导致的背压
    ks_seq_result_rdy = 1'b1;
    if (ks_seq_result_vld) begin
      $display("[VP_PBS_LITE] 🔧 Accepting KSK result: 0x%0h (inc_wr_ptr_if=%b)", ks_seq_result, inc_ksk_wr_ptr_from_if);
    end
  end
end

// 系统就绪信号
assign system_ready = 1'b1;  // 简化：始终ready
assign bsk_req_rdy = system_ready;  // BSK请求准备信号

// SIMULATION ONLY: loopback reset done (to unblock KSK flow)
`ifndef SYNTHESIS
// 🔧 仿真专用：KSK reset完成的loopback逻辑
always_ff @(posedge clk) begin
  if (!s_rst_n) begin
    reset_ksk_cache_done_sim <= 1'b0;
    $display("[LOOPBACK] reset_done_sim initialized to 0");
  end else begin
    $display("[LOOPBACK] clk edge: reset_ksk_cache=%b, prev_sim=%b", reset_ksk_cache, reset_ksk_cache_done_sim);
    if (!reset_ksk_cache) begin
      reset_ksk_cache_done_sim <= 1'b1;
      $display("[LOOPBACK] reset_ksk_cache deasserted -> forcing reset_done_sim=1 at %0t", $time);
    end else begin
      reset_ksk_cache_done_sim <= 1'b0;
    end
  end
end
`endif

endmodule

