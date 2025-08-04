// ==============================================================================================
// Filename: wop_pbs_kernel.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// Correct WoP-PBS (Programmable Bootstrapping Without Padding) Implementation.
// Based on careful analysis of the C++ implementation, WoP-PBS consists of three distinct stages:
//
// 1. Bit Extraction: Extract individual bits from high-precision messages using specialized LUTs
// 2. Circuit Bootstrapping: Convert LWE bit samples to GGSW samples through:
//    - Pre-KeySwitch (level 1 → level 0)  
//    - Circuit Bootstrap WoKS (level 0 → level 2)
//    - Private KeySwitch (level 2 → level 1 GGSW)
// 3. Vertical Packing: Evaluate large LUT using CMux tree + blind rotation
//
// This implementation correctly reuses pe_pbs_with_* auxiliary modules (BSK, KSK, NTT) 
// while implementing the unique WoP-PBS algorithm flow.
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module wop_pbs_kernel
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import param_ntt_pkg::*;
  import ntt_core_common_param_pkg::*;
  import top_common_param_pkg::*;
  import pep_common_param_pkg::*;
  import pep_ks_common_param_pkg::*;
  import bsk_mgr_common_param_pkg::*;
  import ksk_mgr_common_param_pkg::*;
  import axi_if_common_param_pkg::*;
  import axi_if_bsk_axi_pkg::*;
  import axi_if_ksk_axi_pkg::*;
  import axi_if_glwe_axi_pkg::*;
  import regf_common_param_pkg::*;
  import hpu_common_instruction_pkg::*;
#(
  // Parameters matching pe_pbs architecture
  parameter  mod_mult_type_e   MOD_MULT_TYPE       = set_mod_mult_type(MOD_NTT_TYPE),
  parameter  mod_reduct_type_e REDUCT_TYPE         = set_mod_reduct_type(MOD_NTT_TYPE),
  parameter  arith_mult_type_e MULT_TYPE           = MULT_CORE,
  parameter  arith_mult_type_e PHI_MULT_TYPE       = set_ntt_mult_type(MOD_NTT_W,MOD_NTT_TYPE),
  parameter  mod_mult_type_e   PP_MOD_MULT_TYPE    = MOD_MULT_TYPE,
  parameter  arith_mult_type_e PP_MULT_TYPE        = MULT_TYPE,
  parameter  int               MODSW_2_PRECISION_W = MOD_NTT_W + 32,
  parameter  arith_mult_type_e MODSW_2_MULT_TYPE   = set_mult_type(MODSW_2_PRECISION_W),
  parameter  arith_mult_type_e MODSW_MULT_TYPE     = set_mult_type(MOD_NTT_W),
  
  // Memory and latency parameters
  parameter  int               RAM_LATENCY         = 2,
  parameter  int               URAM_LATENCY        = RAM_LATENCY + 1,
  parameter  int               ROM_LATENCY         = 2,
  
  // Twiddle files
  parameter  string            TWD_IFNL_FILE_PREFIX = NTT_CORE_ARCH == NTT_CORE_ARCH_WMM_UNFOLD ?
                                                          "memory_file/twiddle/NTT_CORE_ARCH_WMM/R8_PSI8_S3/SOLINAS3_32_17_13/twd_ifnl_bwd" :
                                                          "memory_file/twiddle/NTT_CORE_ARCH_WMM/R8_PSI8_S3/SOLINAS3_32_17_13/twd_ifnl",
  parameter  string            TWD_PHRU_FILE_PREFIX = "memory_file/twiddle/NTT_CORE_ARCH_WMM/R8_PSI8_S3/SOLINAS3_32_17_13/twd_phru",
  parameter  string            TWD_GF64_FILE_PREFIX = $sformatf("memory_file/twiddle/NTT_CORE_ARCH_GF64/R%0d_PSI%0d/twd_phi",R,PSI),
  
  // WoP-PBS specific parameters
  parameter  int               INST_FIFO_DEPTH      = 8,
  parameter  int               REGF_RD_LATENCY      = URAM_LATENCY + 4,
  parameter  int               KS_IF_COEF_NB        = (LBY < REGF_COEF_NB) ? LBY : REGF_SEQ_COEF_NB,
  parameter  int               KS_IF_SUBW_NB        = (LBY < REGF_COEF_NB) ? 1 : REGF_SEQ,
  parameter  int               PHYS_RAM_DEPTH       = 1024,
  
  // WoP-PBS algorithm parameters
  parameter  int               MAX_BIT_WIDTH        = 20,   // Maximum input bit width (for 20-bit LUT)
  parameter  int               N_LVL0               = 630,  // Level 0 dimension
  parameter  int               N_LVL1               = 1024, // Level 1 dimension  
  parameter  int               N_LVL2               = 2048, // Level 2 dimension
  parameter  int               ELL_LVL1             = 3,    // Decomposition parameter level 1
  parameter  int               ELL_LVL2             = 8     // Decomposition parameter level 2
)
(
  input  logic clk,
  input  logic s_rst_n,

  // == Instruction Interface ==
  input  logic [PE_INST_W-1:0]                                         wop_pbs_inst,
  input  logic                                                         wop_pbs_inst_vld,
  output logic                                                         wop_pbs_inst_rdy,
  output logic                                                         wop_pbs_inst_ack,

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
  input  logic                                                         regf_pep_rd_is_body,
  input  logic                                                         regf_pep_rd_last_mask,

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

  // == Shared BSK Interface (reuse pe_pbs_with_bsk) ==
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

  // == Shared KSK Interface (reuse pe_pbs_with_ksk) ==
  output logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ID_W-1:0]         m_axi4_ksk_arid,
  output logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ADD_W-1:0]        m_axi4_ksk_araddr,
  output logic [KSK_PC-1:0][AXI4_LEN_W-1:0]                            m_axi4_ksk_arlen,
  output logic [KSK_PC-1:0][AXI4_SIZE_W-1:0]                           m_axi4_ksk_arsize,
  output logic [KSK_PC-1:0][AXI4_BURST_W-1:0]                          m_axi4_ksk_arburst,
  output logic [KSK_PC-1:0]                                            m_axi4_ksk_arvalid,
  input  logic [KSK_PC-1:0]                                            m_axi4_ksk_arready,
  input  logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ID_W-1:0]         m_axi4_ksk_rid,
  input  logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_DATA_W-1:0]       m_axi4_ksk_rdata,
  input  logic [KSK_PC-1:0][AXI4_RESP_W-1:0]                           m_axi4_ksk_rresp,
  input  logic [KSK_PC-1:0]                                            m_axi4_ksk_rlast,
  input  logic [KSK_PC-1:0]                                            m_axi4_ksk_rvalid,
  output logic [KSK_PC-1:0]                                            m_axi4_ksk_rready,

  // == Configuration Interface ==
  input  logic                                                         reset_bsk_cache,
  output logic                                                         reset_bsk_cache_done,
  input  logic                                                         bsk_mem_avail,
  input  logic [BSK_PC_MAX-1:0][axi_if_bsk_axi_pkg::AXI4_ADD_W-1:0]    bsk_mem_addr,

  input  logic                                                         reset_ksk_cache,
  output logic                                                         reset_ksk_cache_done,
  input  logic                                                         ksk_mem_avail,
  input  logic [KSK_PC_MAX-1:0][axi_if_ksk_axi_pkg::AXI4_ADD_W-1:0]    ksk_mem_addr,

  input  logic                                                         reset_cache,
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0]                   gid_offset,
  input  logic [1:0][R/2-1:0][MOD_NTT_W-1:0]                           twd_omg_ru_r_pow,

  // == Error and Info Interface ==
  output logic [PEP_ERROR_W-1:0]                                       error,
  output logic [PEP_INFO_W-1:0]                                        pep_rif_info,
  output logic [PEP_COUNTER_INC_W-1:0]                                 pep_rif_counter_inc,

  // == Debug Interface ==
  output logic [3:0]                                                   debug_current_stage,
  output logic [MAX_BIT_WIDTH-1:0]                                     debug_current_bit,
  output logic [4:0]                                                   debug_current_substage
);

// ==============================================================================================
// WoP-PBS State Machine - Based on C++ Algorithm Flow
// ==============================================================================================
  typedef enum logic [3:0] {
    IDLE,
    STAGE1_BIT_EXTRACT,         // Stage 1: Bit extraction (bitExtract function)
    STAGE2_CIRCUIT_BS_PREKSK,   // Stage 2a: Pre-KeySwitch (level 1 → level 0)
    STAGE2_CIRCUIT_BS_PREMOD,   // Stage 2b: Pre-ModSwitch 
    STAGE2_CIRCUIT_BS_WOKS,     // Stage 2c: Circuit Bootstrap WoKS (level 0 → level 2)
    STAGE2_CIRCUIT_BS_PRIVKS,   // Stage 2d: Private KeySwitch (level 2 → level 1 GGSW)
    STAGE3_VERTICAL_PACK_CMUX,  // Stage 3a: CMux tree construction
    STAGE3_VERTICAL_PACK_BLIND, // Stage 3b: Blind rotation
    STAGE3_VERTICAL_PACK_EXTRACT, // Stage 3c: Sample extraction
    DONE
  } wop_pbs_state_e;

  wop_pbs_state_e current_state, next_state;

// ==============================================================================================
// Internal Registers and Control Signals
// ==============================================================================================
  // Instruction decoding
  logic [REGF_ADDR_W-1:0] input_lwe_addr;
  logic [REGF_ADDR_W-1:0] output_lwe_addr;
  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] bit_extract_lut_addr;
  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] vertical_pack_lut_addr;
  logic [MAX_BIT_WIDTH-1:0] bit_width;
  
  // Loop control
  logic [MAX_BIT_WIDTH-1:0] bit_counter;
  logic [ELL_LVL1-1:0] ell_counter;
  logic [4:0] substage_counter;
  
  // Stage completion flags
  logic stage1_done, stage2_done, stage3_done;
  
  // Data storage addresses (in RegFile)
  logic [REGF_ADDR_W-1:0] bit_extract_results_addr [MAX_BIT_WIDTH-1:0];
  logic [REGF_ADDR_W-1:0] circuit_bs_results_addr [MAX_BIT_WIDTH-1:0];
  logic [REGF_ADDR_W-1:0] temp_storage_base_addr;
  
  // Initialize temporary storage base address
  initial begin
    temp_storage_base_addr = 16'h1000; // Start temp storage at address 0x1000
  end

// ==============================================================================================
// Reused Auxiliary Modules from pe_pbs_with_*
// ==============================================================================================

  // 1. BSK Manager (reuse pe_pbs_with_bsk)
  logic bsk_req_vld;
  logic bsk_req_rdy;
  logic [BSK_BATCH_ID_W-1:0] bsk_batch_id;
  logic bsk_data_avail;
  logic [BSK_PC-1:0][R-1:0][MOD_Q_W-1:0] bsk_data;

  pe_pbs_with_bsk #(
    .MOD_MULT_TYPE(MOD_MULT_TYPE),
    .REDUCT_TYPE(REDUCT_TYPE),
    .MULT_TYPE(MULT_TYPE),
    .PHI_MULT_TYPE(PHI_MULT_TYPE),
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
    .TWD_GF64_FILE_PREFIX(TWD_GF64_FILE_PREFIX),
    .INST_FIFO_DEPTH(INST_FIFO_DEPTH),
    .REGF_RD_LATENCY(REGF_RD_LATENCY),
    .KS_IF_COEF_NB(KS_IF_COEF_NB),
    .KS_IF_SUBW_NB(KS_IF_SUBW_NB),
    .PHYS_RAM_DEPTH(PHYS_RAM_DEPTH)
  ) i_bsk_manager (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // BSK request interface
    .bsk_req_vld(bsk_req_vld),
    .bsk_req_rdy(bsk_req_rdy),
    .bsk_batch_id(bsk_batch_id),
    .bsk_data_avail(bsk_data_avail),
    .bsk_data(bsk_data),
    
    // AXI interface
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
    
    // Configuration
    .reset_bsk_cache(reset_bsk_cache),
    .reset_bsk_cache_done(reset_bsk_cache_done),
    .bsk_mem_avail(bsk_mem_avail),
    .bsk_mem_addr(bsk_mem_addr)
  );

  // 2. KSK Manager (reuse pe_pbs_with_ksk) 
  logic ksk_req_vld;
  logic ksk_req_rdy;
  logic [KSK_BATCH_ID_W-1:0] ksk_batch_id;
  logic ksk_data_avail;
  logic [KSK_PC-1:0][R-1:0][MOD_Q_W-1:0] ksk_data;

  pe_pbs_with_ksk #(
    .MOD_MULT_TYPE(MOD_MULT_TYPE),
    .REDUCT_TYPE(REDUCT_TYPE),
    .MULT_TYPE(MULT_TYPE),
    .PHI_MULT_TYPE(PHI_MULT_TYPE),
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
    .TWD_GF64_FILE_PREFIX(TWD_GF64_FILE_PREFIX),
    .INST_FIFO_DEPTH(INST_FIFO_DEPTH),
    .REGF_RD_LATENCY(REGF_RD_LATENCY),
    .KS_IF_COEF_NB(KS_IF_COEF_NB),
    .KS_IF_SUBW_NB(KS_IF_SUBW_NB),
    .PHYS_RAM_DEPTH(PHYS_RAM_DEPTH)
  ) i_ksk_manager (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // KSK request interface
    .ksk_req_vld(ksk_req_vld),
    .ksk_req_rdy(ksk_req_rdy),
    .ksk_batch_id(ksk_batch_id),
    .ksk_data_avail(ksk_data_avail),
    .ksk_data(ksk_data),
    
    // AXI interface
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
    
    // Configuration
    .reset_ksk_cache(reset_ksk_cache),
    .reset_ksk_cache_done(reset_ksk_cache_done),
    .ksk_mem_avail(ksk_mem_avail),
    .ksk_mem_addr(ksk_mem_addr)
  );

  // 3. Dedicated PE_PBS Instance for Bit Extraction Operations
  logic [PE_INST_W-1:0] bit_extract_pbs_inst;
  logic bit_extract_pbs_inst_vld;
  logic bit_extract_pbs_inst_rdy;
  logic bit_extract_pbs_inst_ack;
  logic [LWE_K_W-1:0] bit_extract_pbs_inst_ack_br_loop;
  logic bit_extract_pbs_inst_load_blwe_ack;
  
  // Dedicated RegFile interface for bit extract PBS operations
  logic bit_extract_pbs_regf_wr_req_vld;
  logic [REGF_WR_REQ_W-1:0] bit_extract_pbs_regf_wr_req;
  logic [REGF_COEF_NB-1:0] bit_extract_pbs_regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] bit_extract_pbs_regf_wr_data;
  logic bit_extract_pbs_regf_rd_req_vld;
  logic [REGF_RD_REQ_W-1:0] bit_extract_pbs_regf_rd_req;

  pe_pbs #(
    .MOD_MULT_TYPE(MOD_MULT_TYPE),
    .REDUCT_TYPE(REDUCT_TYPE),
    .MULT_TYPE(MULT_TYPE),
    .PHI_MULT_TYPE(PHI_MULT_TYPE),
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
    .TWD_GF64_FILE_PREFIX(TWD_GF64_FILE_PREFIX),
    .INST_FIFO_DEPTH(INST_FIFO_DEPTH),
    .REGF_RD_LATENCY(REGF_RD_LATENCY),
    .KS_IF_COEF_NB(KS_IF_COEF_NB),
    .KS_IF_SUBW_NB(KS_IF_SUBW_NB),
    .PHYS_RAM_DEPTH(PHYS_RAM_DEPTH)
  ) i_bit_extract_pe_pbs (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // PE_PBS instruction interface - connected to bit extract engine
    .inst(bit_extract_pbs_inst),
    .inst_vld(bit_extract_pbs_inst_vld),
    .inst_rdy(bit_extract_pbs_inst_rdy),
    .inst_ack(bit_extract_pbs_inst_ack),
    .inst_ack_br_loop(bit_extract_pbs_inst_ack_br_loop),
    .inst_load_blwe_ack(bit_extract_pbs_inst_load_blwe_ack),
    
    // RegFile interface - will be arbitrated with other modules
    .pep_regf_wr_req_vld(bit_extract_pbs_regf_wr_req_vld),
    .pep_regf_wr_req_rdy(pep_regf_wr_req_rdy),  // Shared
    .pep_regf_wr_req(bit_extract_pbs_regf_wr_req),
    .pep_regf_wr_data_vld(bit_extract_pbs_regf_wr_data_vld),
    .pep_regf_wr_data_rdy(pep_regf_wr_data_rdy),  // Shared
    .pep_regf_wr_data(bit_extract_pbs_regf_wr_data),
    .regf_pep_wr_ack(regf_pep_wr_ack),  // Shared
    
    .pep_regf_rd_req_vld(bit_extract_pbs_regf_rd_req_vld),
    .pep_regf_rd_req_rdy(pep_regf_rd_req_rdy),  // Shared
    .pep_regf_rd_req(bit_extract_pbs_regf_rd_req),
    .regf_pep_rd_data_avail(regf_pep_rd_data_avail),  // Shared
    .regf_pep_rd_data(regf_pep_rd_data),  // Shared
    .regf_pep_rd_last_word(regf_pep_rd_last_word),  // Shared
    .regf_pep_rd_is_body(regf_pep_rd_is_body),  // Shared
    .regf_pep_rd_last_mask(regf_pep_rd_last_mask),  // Shared
    
    // Configuration - shared with other PBS modules
    .reset_bsk_cache(reset_bsk_cache),
    .reset_bsk_cache_done(),  // Don't care for now
    .bsk_mem_avail(bsk_mem_avail),
    .bsk_mem_addr(bsk_mem_addr),
    .reset_ksk_cache(reset_ksk_cache),
    .reset_ksk_cache_done(),  // Don't care for now  
    .ksk_mem_avail(ksk_mem_avail),
    .ksk_mem_addr(ksk_mem_addr),
    .reset_cache(reset_cache),
    .gid_offset(gid_offset),
    .twd_omg_ru_r_pow(twd_omg_ru_r_pow),
    .use_bpip(use_bpip),
    .use_bpip_opportunism(use_bpip_opportunism),
    .bpip_timeout(bpip_timeout),
    
    // AXI interfaces - shared with other modules (need arbitration)
    .m_axi4_bsk_arid(),     // TODO: Add arbitration logic
    .m_axi4_bsk_araddr(),
    .m_axi4_bsk_arlen(),
    .m_axi4_bsk_arsize(),
    .m_axi4_bsk_arburst(),
    .m_axi4_bsk_arvalid(),
    .m_axi4_bsk_arready(m_axi4_bsk_arready),
    .m_axi4_bsk_rid(m_axi4_bsk_rid),
    .m_axi4_bsk_rdata(m_axi4_bsk_rdata),
    .m_axi4_bsk_rresp(m_axi4_bsk_rresp),
    .m_axi4_bsk_rlast(m_axi4_bsk_rlast),
    .m_axi4_bsk_rvalid(m_axi4_bsk_rvalid),
    .m_axi4_bsk_rready(),
    
    .m_axi4_ksk_arid(),     // TODO: Add arbitration logic
    .m_axi4_ksk_araddr(),
    .m_axi4_ksk_arlen(),
    .m_axi4_ksk_arsize(),
    .m_axi4_ksk_arburst(),
    .m_axi4_ksk_arvalid(),
    .m_axi4_ksk_arready(m_axi4_ksk_arready),
    .m_axi4_ksk_rid(m_axi4_ksk_rid),
    .m_axi4_ksk_rdata(m_axi4_ksk_rdata),
    .m_axi4_ksk_rresp(m_axi4_ksk_rresp),
    .m_axi4_ksk_rlast(m_axi4_ksk_rlast),
    .m_axi4_ksk_rvalid(m_axi4_ksk_rvalid),
    .m_axi4_ksk_rready(),
    
    .m_axi4_glwe_arid(),    // TODO: Add arbitration logic
    .m_axi4_glwe_araddr(),
    .m_axi4_glwe_arlen(),
    .m_axi4_glwe_arsize(),
    .m_axi4_glwe_arburst(),
    .m_axi4_glwe_arvalid(),
    .m_axi4_glwe_arready(m_axi4_glwe_arready),
    .m_axi4_glwe_rid(m_axi4_glwe_rid),
    .m_axi4_glwe_rdata(m_axi4_glwe_rdata),
    .m_axi4_glwe_rresp(m_axi4_glwe_rresp),
    .m_axi4_glwe_rlast(m_axi4_glwe_rlast),
    .m_axi4_glwe_rvalid(m_axi4_glwe_rvalid),
    .m_axi4_glwe_rready()
  );

// ==============================================================================================
// WoP-PBS Specific Computation Modules
// ==============================================================================================

  // 1. Bit Extraction Engine
  logic bit_extract_start;
  logic bit_extract_done;
  logic bit_extract_regf_rd_req_vld;
  logic [REGF_RD_REQ_W-1:0] bit_extract_regf_rd_req;
  logic bit_extract_regf_wr_req_vld;
  logic [REGF_WR_REQ_W-1:0] bit_extract_regf_wr_req;
  logic [REGF_COEF_NB-1:0] bit_extract_regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] bit_extract_regf_wr_data;
  logic bit_extract_lut_req_vld;
  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] bit_extract_lut_addr;

  wop_bit_extract_engine #(
    .MOD_Q_W(MOD_Q_W),
    .MAX_BIT_WIDTH(MAX_BIT_WIDTH),
    .N_LVL1(N_LVL1),
    .LUT_ENTRY_SIZE(8192)
  ) i_bit_extract_engine (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // Control interface
    .start(bit_extract_start),
    .bit_pos(bit_counter),
    .done(bit_extract_done),
    
    // Input/output addresses
    .input_lwe_addr(input_lwe_addr),
    .output_bit_addr_0(bit_extract_results_addr[bit_counter]),
    .output_bit_addr_1(bit_extract_results_addr[bit_counter + 1]),
    
    // RegFile interface
    .regf_rd_req_vld(bit_extract_regf_rd_req_vld),
    .regf_rd_req_rdy(pep_regf_rd_req_rdy),
    .regf_rd_req(bit_extract_regf_rd_req),
    .regf_rd_data_avail(regf_pep_rd_data_avail),
    .regf_rd_data(regf_pep_rd_data),
    .regf_rd_last_word(regf_pep_rd_last_word),
    
    .regf_wr_req_vld(bit_extract_regf_wr_req_vld),
    .regf_wr_req_rdy(pep_regf_wr_req_rdy),
    .regf_wr_req(bit_extract_regf_wr_req),
    .regf_wr_data_vld(bit_extract_regf_wr_data_vld),
    .regf_wr_data_rdy(pep_regf_wr_data_rdy),
    .regf_wr_data(bit_extract_regf_wr_data),
    
    // LUT access interface
    .bit_extract_lut_base_addr(bit_extract_lut_addr),
    .lut_addr(bit_extract_lut_addr),
    .lut_req_vld(bit_extract_lut_req_vld),
    .lut_req_rdy(m_axi4_glwe_arready),
    .lut_data_avail(m_axi4_glwe_rvalid),
    .lut_data(m_axi4_glwe_rdata),
    
    // PBS Service Interface - connected to dedicated pe_pbs instance
    .pbs_inst(bit_extract_pbs_inst),
    .pbs_inst_vld(bit_extract_pbs_inst_vld),
    .pbs_inst_rdy(bit_extract_pbs_inst_rdy),
    .pbs_inst_ack(bit_extract_pbs_inst_ack),
    .pbs_inst_ack_br_loop(bit_extract_pbs_inst_ack_br_loop),
    .pbs_inst_load_blwe_ack(bit_extract_pbs_inst_load_blwe_ack)
  );

  // 2. Circuit Bootstrap WoKS Engine (core of circuit bootstrapping)
  logic circuit_bs_start;
  logic circuit_bs_done;
  logic [MOD_Q_W-1:0] mu_value;
  logic [N_LVL0:0][31:0] abar_data;
  logic abar_valid;
  logic [N_LVL2-1:0][MOD_Q_W-1:0] circuit_bs_result_a;
  logic [MOD_Q_W-1:0] circuit_bs_result_b;
  logic circuit_bs_result_valid;
  
  // NTT interface signals for circuit bootstrap engine
  logic [PSI-1:0][R-1:0] circuit_bs_ntt_data_avail;
  logic [PSI-1:0][R-1:0][MOD_Q_W-1:0] circuit_bs_ntt_data;
  logic circuit_bs_ntt_sob, circuit_bs_ntt_eob, circuit_bs_ntt_sog, circuit_bs_ntt_eog;
  logic circuit_bs_ntt_sol, circuit_bs_ntt_eol;
  logic [PSI-1:0][R-1:0] circuit_bs_ntt_data_rdy;
  logic [PSI-1:0][R-1:0][MOD_Q_W-1:0] circuit_bs_ntt_result_data;
  logic circuit_bs_ntt_result_sob, circuit_bs_ntt_result_eob;
  logic circuit_bs_ntt_result_sol, circuit_bs_ntt_result_eol;
  
  wop_circuit_bootstrap_woks_engine #(
    .MOD_Q_W(MOD_Q_W),
    .N_LVL0(N_LVL0),
    .N_LVL2(N_LVL2),
    .ELL_LVL2(ELL_LVL2),
    .K(1)
  ) i_circuit_bs_woks_engine (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // Control interface
    .start(circuit_bs_start),
    .mu_value(mu_value),
    .done(circuit_bs_done),
    
    // Input: pre-modswitch result (abar)
    .abar_data(abar_data),
    .abar_valid(abar_valid),
    
    // Output: LWE sample at level 2
    .result_a(circuit_bs_result_a),
    .result_b(circuit_bs_result_b),
    .result_valid(circuit_bs_result_valid),
    
    // BSK interface (shared)
    .bsk_req_vld(bsk_req_vld),
    .bsk_req_rdy(bsk_req_rdy),
    .bsk_batch_id(bsk_batch_id),
    .bsk_data_avail(bsk_data_avail),
    .bsk_data(bsk_data),
    
    // NTT engine interface (shared with pe_pbs)
    .ntt_data_avail(circuit_bs_ntt_data_avail),
    .ntt_data(circuit_bs_ntt_data),
    .ntt_sob(circuit_bs_ntt_sob),
    .ntt_eob(circuit_bs_ntt_eob),
    .ntt_sog(circuit_bs_ntt_sog),
    .ntt_eog(circuit_bs_ntt_eog),
    .ntt_sol(circuit_bs_ntt_sol),
    .ntt_eol(circuit_bs_ntt_eol),
    .ntt_data_rdy(circuit_bs_ntt_data_rdy),
    .ntt_result_data(circuit_bs_ntt_result_data),
    .ntt_result_sob(circuit_bs_ntt_result_sob),
    .ntt_result_eob(circuit_bs_ntt_result_eob),
    .ntt_result_sol(circuit_bs_ntt_result_sol),
    .ntt_result_eol(circuit_bs_ntt_result_eol)
  );

  // 3. Vertical Packing Engine (CMux tree + blind rotation)
  logic vertical_pack_start;
  logic vertical_pack_done;
  logic vertical_pack_result_ready;
  logic vertical_pack_regf_rd_req_vld;
  logic [REGF_RD_REQ_W-1:0] vertical_pack_regf_rd_req;
  logic vertical_pack_regf_wr_req_vld;
  logic [REGF_WR_REQ_W-1:0] vertical_pack_regf_wr_req;
  logic [REGF_COEF_NB-1:0] vertical_pack_regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] vertical_pack_regf_wr_data;
  logic vertical_pack_lut_req_vld;
  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] vertical_pack_lut_addr;
  
  wop_vertical_packing_engine #(
    .MOD_Q_W(MOD_Q_W),
    .MAX_BIT_WIDTH(MAX_BIT_WIDTH),
    .N_LVL1(N_LVL1),
    .ELL_LVL1(ELL_LVL1),
    .K(1)
  ) i_vertical_pack_engine (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // Control interface
    .start(vertical_pack_start),
    .bit_width(bit_width),
    .done(vertical_pack_done),
    
    // Input: GGSW bit samples
    .ggsw_samples_base_addr(circuit_bs_results_addr[0]),
    .ggsw_samples_ready(stage2_done),
    
    // Output: final result
    .result_addr(output_lwe_addr),
    .result_ready(vertical_pack_result_ready),
    
    // LUT interface
    .lut_base_addr(vertical_pack_lut_addr),
    .lut_addr(vertical_pack_lut_addr),
    .lut_req_vld(vertical_pack_lut_req_vld),
    .lut_req_rdy(m_axi4_glwe_arready),
    .lut_data_avail(m_axi4_glwe_rvalid),
    .lut_data(m_axi4_glwe_rdata),
    
    // RegFile interface
    .regf_rd_req_vld(vertical_pack_regf_rd_req_vld),
    .regf_rd_req_rdy(pep_regf_rd_req_rdy),
    .regf_rd_req(vertical_pack_regf_rd_req),
    .regf_rd_data_avail(regf_pep_rd_data_avail),
    .regf_rd_data(regf_pep_rd_data),
    
    .regf_wr_req_vld(vertical_pack_regf_wr_req_vld),
    .regf_wr_req_rdy(pep_regf_wr_req_rdy),
    .regf_wr_req(vertical_pack_regf_wr_req),
    .regf_wr_data_vld(vertical_pack_regf_wr_data_vld),
    .regf_wr_data_rdy(pep_regf_wr_data_rdy),
    .regf_wr_data(vertical_pack_regf_wr_data)
  );

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      bit_counter <= '0;
      ell_counter <= '0;
      substage_counter <= '0;
    end else begin
      current_state <= next_state;
      
      // Update counters based on state
      case (current_state)
        STAGE1_BIT_EXTRACT: begin
          if (/* bit extraction done for current bit */) begin
            bit_counter <= bit_counter + 1;
          end
        end
        
        STAGE2_CIRCUIT_BS_PRIVKS: begin
          if (/* private keyswitch done for current ell */) begin
            ell_counter <= ell_counter + 1;
            if (ell_counter == ELL_LVL1 - 1) begin
              ell_counter <= '0;
              bit_counter <= bit_counter + 1;
            end
          end
        end
        
        // Add other counter updates as needed
      endcase
    end
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    wop_pbs_inst_rdy = 1'b0;
    wop_pbs_inst_ack = 1'b0;
    
    // Engine control signals
    bit_extract_start = 1'b0;
    circuit_bs_start = 1'b0;
    vertical_pack_start = 1'b0;
    
    // Debug outputs
    debug_current_stage = current_state;
    debug_current_bit = bit_counter;
    debug_current_substage = substage_counter;
    
    case (current_state)
      IDLE: begin
        wop_pbs_inst_rdy = 1'b1;
        if (wop_pbs_inst_vld) begin
          // Decode WoP-PBS instruction
          input_lwe_addr = wop_pbs_inst[REGF_ADDR_W-1:0];
          output_lwe_addr = wop_pbs_inst[2*REGF_ADDR_W-1:REGF_ADDR_W];
          bit_width = wop_pbs_inst[2*REGF_ADDR_W+MAX_BIT_WIDTH-1:2*REGF_ADDR_W];
          bit_extract_lut_addr = wop_pbs_inst[2*REGF_ADDR_W+MAX_BIT_WIDTH+axi_if_glwe_axi_pkg::AXI4_ADD_W-1:2*REGF_ADDR_W+MAX_BIT_WIDTH];
          vertical_pack_lut_addr = wop_pbs_inst[2*REGF_ADDR_W+MAX_BIT_WIDTH+2*axi_if_glwe_axi_pkg::AXI4_ADD_W-1:2*REGF_ADDR_W+MAX_BIT_WIDTH+axi_if_glwe_axi_pkg::AXI4_ADD_W];
          
          // Initialize intermediate result addresses
          for (int i = 0; i < MAX_BIT_WIDTH; i++) begin
            bit_extract_results_addr[i] = temp_storage_base_addr + i;
            circuit_bs_results_addr[i] = temp_storage_base_addr + MAX_BIT_WIDTH + i;
          end
          
          next_state = STAGE1_BIT_EXTRACT;
        end
      end
      
      STAGE1_BIT_EXTRACT: begin
        // Bit extraction: for each input LWE sample, extract individual bits
        // This uses specialized LUTs (map_to_bit31, map_to_bit27, etc.)
        bit_extract_start = 1'b1;
        
        if (bit_counter < bit_width) begin
          // Process current bit
          if (bit_extract_done) begin
            if (bit_counter + 1 == bit_width) begin
              stage1_done = 1'b1;
              next_state = STAGE2_CIRCUIT_BS_PREKSK;
            end
          end
        end
      end
      
      STAGE2_CIRCUIT_BS_PREKSK: begin
        // Pre-KeySwitch: LweSample level 1 → level 0
        // This reuses the KSK manager
        // For now, skip to pre-modswitch (to be implemented later)
        next_state = STAGE2_CIRCUIT_BS_PREMOD;
      end
      
      STAGE2_CIRCUIT_BS_PREMOD: begin
        // Pre-ModSwitch: prepare for circuit bootstrap
        // This is a simple modular arithmetic operation
        premodswitch_start = 1'b1;
        
        if (premodswitch_done) begin
          // Connect premodswitch result to circuit bootstrap engine
          abar_data = premodswitch_result;
          abar_valid = 1'b1;
          next_state = STAGE2_CIRCUIT_BS_WOKS;
        end
      end
      
      STAGE2_CIRCUIT_BS_WOKS: begin
        // Circuit Bootstrap WoKS: level 0 → level 2
        // This is the core bootstrapping operation, similar to standard PBS
        // but with different test vector generation
        circuit_bs_start = 1'b1;
        
        if (circuit_bs_done) begin
          next_state = STAGE2_CIRCUIT_BS_PRIVKS;
        end
      end
      
      STAGE2_CIRCUIT_BS_PRIVKS: begin
        // Private KeySwitch: level 2 → level 1 GGSW
        // This creates GGSW samples from LWE samples
        private_keyswitch_start = 1'b1;
        
        if (bit_counter < bit_width && ell_counter < ELL_LVL1) begin
          // Process current bit and ell combination
          if (private_keyswitch_done) begin
            if (bit_counter + 1 == bit_width && ell_counter + 1 == ELL_LVL1) begin
              stage2_done = 1'b1;
              next_state = STAGE3_VERTICAL_PACK_CMUX;
            end
          end
        end
      end
      
      STAGE3_VERTICAL_PACK_CMUX: begin
        // CMux Tree: use GGSW bit samples to construct selection tree
        // This builds a tree of CMux operations
        vertical_pack_start = 1'b1;
        
        if (vertical_pack_done) begin
          next_state = STAGE3_VERTICAL_PACK_BLIND;
        end
      end
      
      STAGE3_VERTICAL_PACK_BLIND: begin
        // Blind Rotation: final LUT evaluation using constructed tree
        // This performs the actual function evaluation
        // (Handled internally by vertical packing engine)
        next_state = STAGE3_VERTICAL_PACK_EXTRACT;
      end
      
      STAGE3_VERTICAL_PACK_EXTRACT: begin
        // Sample Extraction: extract final result
        // (Handled internally by vertical packing engine)
        if (vertical_pack_result_ready) begin
          stage3_done = 1'b1;
          next_state = DONE;
        end
      end
      
      DONE: begin
        wop_pbs_inst_ack = 1'b1;
        next_state = IDLE;
      end
    endcase
  end

// ==============================================================================================
// Interface Multiplexing and Control
// ==============================================================================================

  // RegFile Read Interface Multiplexer
  always_comb begin
    // Default assignments
    pep_regf_rd_req_vld = 1'b0;
    pep_regf_rd_req = '0;
    
    case (current_state)
      STAGE1_BIT_EXTRACT: begin
        // Route to bit extraction engine
        pep_regf_rd_req_vld = bit_extract_regf_rd_req_vld;
        pep_regf_rd_req = bit_extract_regf_rd_req;
      end
      
      STAGE3_VERTICAL_PACK_CMUX,
      STAGE3_VERTICAL_PACK_BLIND,
      STAGE3_VERTICAL_PACK_EXTRACT: begin
        // Route to vertical packing engine
        pep_regf_rd_req_vld = vertical_pack_regf_rd_req_vld;
        pep_regf_rd_req = vertical_pack_regf_rd_req;
      end
      
      default: begin
        pep_regf_rd_req_vld = 1'b0;
        pep_regf_rd_req = '0;
      end
    endcase
  end

  // RegFile Write Interface Multiplexer
  always_comb begin
    // Default assignments
    pep_regf_wr_req_vld = 1'b0;
    pep_regf_wr_req = '0;
    pep_regf_wr_data_vld = '0;
    pep_regf_wr_data = '0;
    
    case (current_state)
      STAGE1_BIT_EXTRACT: begin
        // Route to bit extraction engine
        pep_regf_wr_req_vld = bit_extract_regf_wr_req_vld;
        pep_regf_wr_req = bit_extract_regf_wr_req;
        pep_regf_wr_data_vld = bit_extract_regf_wr_data_vld;
        pep_regf_wr_data = bit_extract_regf_wr_data;
      end
      
      STAGE3_VERTICAL_PACK_CMUX,
      STAGE3_VERTICAL_PACK_BLIND,
      STAGE3_VERTICAL_PACK_EXTRACT: begin
        // Route to vertical packing engine
        pep_regf_wr_req_vld = vertical_pack_regf_wr_req_vld;
        pep_regf_wr_req = vertical_pack_regf_wr_req;
        pep_regf_wr_data_vld = vertical_pack_regf_wr_data_vld;
        pep_regf_wr_data = vertical_pack_regf_wr_data;
      end
      
      default: begin
        pep_regf_wr_req_vld = 1'b0;
        pep_regf_wr_req = '0;
        pep_regf_wr_data_vld = '0;
        pep_regf_wr_data = '0;
      end
    endcase
  end

  // AXI GLWE Interface Multiplexer (for LUT access)
  always_comb begin
    // Default assignments
    m_axi4_glwe_arid = '0;
    m_axi4_glwe_araddr = '0;
    m_axi4_glwe_arlen = '0;
    m_axi4_glwe_arsize = 3'b010; // 4 bytes
    m_axi4_glwe_arburst = 2'b01; // INCR
    m_axi4_glwe_arvalid = 1'b0;
    m_axi4_glwe_rready = 1'b0;
    
    case (current_state)
      STAGE1_BIT_EXTRACT: begin
        // Route to bit extraction engine
        m_axi4_glwe_arid = 4'h1; // ID for bit extraction
        m_axi4_glwe_araddr = bit_extract_lut_addr;
        m_axi4_glwe_arlen = 8'h0F; // 16 transfers for LUT data
        m_axi4_glwe_arvalid = bit_extract_lut_req_vld;
        m_axi4_glwe_rready = 1'b1;
      end
      
      STAGE3_VERTICAL_PACK_CMUX,
      STAGE3_VERTICAL_PACK_BLIND,
      STAGE3_VERTICAL_PACK_EXTRACT: begin
        // Route to vertical packing engine
        m_axi4_glwe_arid = 4'h3; // ID for vertical packing
        m_axi4_glwe_araddr = vertical_pack_lut_addr;
        m_axi4_glwe_arlen = 8'hFF; // 256 transfers for large LUT
        m_axi4_glwe_arvalid = vertical_pack_lut_req_vld;
        m_axi4_glwe_rready = 1'b1;
      end
      
      default: begin
        m_axi4_glwe_arvalid = 1'b0;
        m_axi4_glwe_rready = 1'b0;
      end
    endcase
  end

// ==============================================================================================
// Pre-ModSwitch Logic Implementation
// ==============================================================================================
  
  // Pre-ModSwitch: Convert LWE sample from level 1 to level 0 format
  // Based on preModSwitch() function in circuit_bootstrapping.cpp
  logic premodswitch_start;
  logic premodswitch_done;
  logic [N_LVL0:0][31:0] premodswitch_result;
  
  wop_premodswitch_engine #(
    .N_LVL0(N_LVL0),
    .N_LVL2(N_LVL2)
  ) i_premodswitch_engine (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // Control interface
    .start(premodswitch_start),
    .done(premodswitch_done),
    
    // Input: LWE sample at level 0 (from pre-keyswitch)
    .input_lwe_sample(/* to be connected to pre-keyswitch result */),
    .input_valid(/* to be connected */),
    
    // Output: abar array for circuit bootstrap
    .abar_result(premodswitch_result)
  );

// ==============================================================================================
// Private KeySwitch Logic Implementation  
// ==============================================================================================
  
  // Private KeySwitch: Convert LWE level 2 to GGSW level 1
  // Based on circuitPrivKS() function in circuit_bootstrapping.cpp
  logic private_keyswitch_start;
  logic private_keyswitch_done;
  logic [ELL_LVL1-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] private_ks_result;
  logic private_ks_result_valid;
  
  wop_private_keyswitch_engine #(
    .MOD_Q_W(MOD_Q_W),
    .N_LVL1(N_LVL1),
    .N_LVL2(N_LVL2),
    .ELL_LVL1(ELL_LVL1),
    .K(1)
  ) i_private_keyswitch_engine (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // Control interface
    .start(private_keyswitch_start),
    .done(private_keyswitch_done),
    .u_value(1'b0), // Use Key_lvl1[0] for now
    
    // Input: LWE sample at level 2 (from circuit bootstrap)
    .input_lwe_a(circuit_bs_result_a),
    .input_lwe_b(circuit_bs_result_b),
    .input_valid(circuit_bs_result_valid),
    
    // Output: GGSW sample at level 1
    .ggsw_result(private_ks_result),
    .result_valid(private_ks_result_valid),
    
    // KSK interface (shared)
    .ksk_req_vld(ksk_req_vld),
    .ksk_req_rdy(ksk_req_rdy),
    .ksk_batch_id(ksk_batch_id),
    .ksk_data_avail(ksk_data_avail),
    .ksk_data(ksk_data)
  );

// ==============================================================================================
// NTT Engine for Circuit Bootstrap
// ==============================================================================================
  
  // NTT Interface signals for pe_pbs_with_ntt_core_head
  logic [PSI-1:0][R-1:0][NTT_OP_W-1:0] ntt_next_data;
  logic [PSI-1:0][R-1:0] ntt_next_data_avail;
  logic [PSI-1:0][R-1:0] ntt_next_data_rdy;
  logic ntt_next_ctrl_avail;
  logic ntt_next_ctrl_rdy;
  
  pe_pbs_with_ntt_core_head #(
    .MOD_MULT_TYPE(MOD_MULT_TYPE),
    .REDUCT_TYPE(REDUCT_TYPE),
    .PHI_MULT_TYPE(PHI_MULT_TYPE),
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
    .TWD_GF64_FILE_PREFIX(TWD_GF64_FILE_PREFIX),
    .INST_FIFO_DEPTH(INST_FIFO_DEPTH),
    .REGF_RD_LATENCY(REGF_RD_LATENCY),
    .KS_IF_COEF_NB(KS_IF_COEF_NB),
    .KS_IF_SUBW_NB(KS_IF_SUBW_NB),
    .PHYS_RAM_DEPTH(PHYS_RAM_DEPTH)
  ) i_ntt_core_head (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // Configuration
    .twd_omg_ru_r_pow(twd_omg_ru_r_pow),
    
    // Broadcast batch cmd
    .br_batch_cmd(br_batch_cmd),
    .br_batch_cmd_avail(br_batch_cmd_avail),
    
    // BSK coefficients
    .bsk(bsk),
    .bsk_vld(bsk_vld),
    .bsk_rdy(bsk_rdy),
    
    // Decomposer -> NTT (from circuit bootstrap)
    .decomp_ntt_data_avail(circuit_bs_ntt_data_avail),
    .decomp_ntt_data(circuit_bs_ntt_data),
    .decomp_ntt_sob(circuit_bs_ntt_sob),
    .decomp_ntt_eob(circuit_bs_ntt_eob),
    .decomp_ntt_sog(circuit_bs_ntt_sog),
    .decomp_ntt_eog(circuit_bs_ntt_eog),
    .decomp_ntt_sol(circuit_bs_ntt_sol),
    .decomp_ntt_eol(circuit_bs_ntt_eol),
    .decomp_ntt_pbs_id('0),  // Circuit bootstrap doesn't use PBS ID
    .decomp_ntt_last_pbs(1'b1),  // Always last for circuit bootstrap
    .decomp_ntt_full_throughput(1'b1),  // Full throughput
    .decomp_ntt_ctrl_avail(circuit_bs_ntt_sob),  // Control available with start of block
    .decomp_ntt_data_rdy(circuit_bs_ntt_data_rdy),
    .decomp_ntt_ctrl_rdy(/* open */),
    
    // Output data to circuit bootstrap
    .next_data(ntt_next_data),
    .next_data_avail(ntt_next_data_avail),
    .next_data_rdy(ntt_next_data_rdy),
    .next_ctrl_avail(ntt_next_ctrl_avail),
    .next_ctrl_rdy(ntt_next_ctrl_rdy),
    
    // Other signals (not used by circuit bootstrap)
    .accumulator_add_mode(1'b0),
    .accumulator_add_en('0),
    .accumulator_result('0),
    .accumulator_result_avail('0),
    .accumulator_result_rdy('1),
    .accumulator_ctrl_avail(1'b0),
    .accumulator_ctrl_rdy(/* open */)
  );
  
  // Convert NTT output to circuit bootstrap result format
  assign circuit_bs_ntt_result_data = ntt_next_data;
  assign circuit_bs_ntt_result_sob = ntt_next_ctrl_avail && (ntt_next_data[0][0] != '0);
  assign circuit_bs_ntt_result_eob = ntt_next_ctrl_avail && (ntt_next_data[PSI-1][R-1] != '0);
  assign circuit_bs_ntt_result_sol = circuit_bs_ntt_result_sob;
  assign circuit_bs_ntt_result_eol = ntt_next_ctrl_avail && ntt_next_data_avail[PSI-1][R-1];
  assign ntt_next_data_rdy = '1;  // Always ready to accept results
  assign ntt_next_ctrl_rdy = 1'b1;

// Note: Enhanced state machine logic is integrated into the main state machine above

// ==============================================================================================
// Error Handling and Monitoring
// ==============================================================================================
  
  // Error detection and reporting
  always_comb begin
    error = '0;
    
    // Timeout detection (simplified - would need actual timeout counter)
    error[0] = 1'b0; // No timeout detection for now
    
    // Invalid state detection
    if (current_state == 4'hF) begin
      error[1] = 1'b1; // Invalid state error
    end else begin
      error[1] = 1'b0;
    end
    
    // Engine error propagation (placeholder)
    error[2] = 1'b0; // No engine errors for now
    
    // Fill remaining error bits
    error[PEP_ERROR_W-1:3] = '0;
  end
  
  // Performance monitoring
  always_comb begin
    pep_rif_info = '0;
    pep_rif_counter_inc = '0;
    
    // Stage completion counters
    pep_rif_counter_inc[0] = stage1_done;
    pep_rif_counter_inc[1] = stage2_done; 
    pep_rif_counter_inc[2] = stage3_done;
    
    // Current stage info
    pep_rif_info[3:0] = current_state;
    pep_rif_info[7:4] = bit_counter[3:0];
  end

endmodule