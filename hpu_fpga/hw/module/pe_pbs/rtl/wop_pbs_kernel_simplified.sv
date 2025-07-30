// ==============================================================================================
// Filename: wop_pbs_kernel_simplified.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// Simplified WoP-PBS (Programmable Bootstrapping Without Padding) Processing Element.
// This module implements the three-stage WoP-PBS algorithm:
// 1. Bit Extraction: Extract individual bits from high-precision messages
// 2. Circuit Bootstrapping: Convert LWE bit ciphertexts to GGSW format
// 3. Vertical Packing: Evaluate large LUT using CMux tree and blind rotation
//
// This design maximally reuses existing pe_pbs modules to minimize complexity.
// The key insight is that WoP-PBS is essentially multiple PBS operations with
// different LUTs, orchestrated by an instruction manager.
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module wop_pbs_kernel_simplified
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
  // Inherit parameters from standard pe_pbs
  parameter  mod_mult_type_e   MOD_MULT_TYPE       = set_mod_mult_type(MOD_NTT_TYPE),
  parameter  mod_reduct_type_e REDUCT_TYPE         = set_mod_reduct_type(MOD_NTT_TYPE),
  parameter  arith_mult_type_e MULT_TYPE           = MULT_CORE,
  parameter  arith_mult_type_e PHI_MULT_TYPE       = set_ntt_mult_type(MOD_NTT_W,MOD_NTT_TYPE),
  parameter  mod_mult_type_e   PP_MOD_MULT_TYPE    = MOD_MULT_TYPE,
  parameter  arith_mult_type_e PP_MULT_TYPE        = MULT_TYPE,
  parameter  int               MODSW_2_PRECISION_W = MOD_NTT_W + 32,
  parameter  arith_mult_type_e MODSW_2_MULT_TYPE   = set_mult_type(MODSW_2_PRECISION_W),
  parameter  arith_mult_type_e MODSW_MULT_TYPE     = set_mult_type(MOD_NTT_W),
  
  // RAM latency
  parameter  int               RAM_LATENCY         = 2,
  parameter  int               URAM_LATENCY        = RAM_LATENCY + 1,
  parameter  int               ROM_LATENCY         = 2,
  
  // Twiddle files
  parameter  string            TWD_IFNL_FILE_PREFIX = NTT_CORE_ARCH == NTT_CORE_ARCH_WMM_UNFOLD ?
                                                          "memory_file/twiddle/NTT_CORE_ARCH_WMM/R8_PSI8_S3/SOLINAS3_32_17_13/twd_ifnl_bwd"    :
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
  parameter  int               MAX_BIT_WIDTH        = 20   // Maximum input bit width (for 20-bit LUT)
)
(
  input  logic clk,
  input  logic s_rst_n,

  // == Instruction Interface ==
  input  logic [PE_INST_W-1:0]                                         wop_pbs_inst,
  input  logic                                                         wop_pbs_inst_vld,
  output logic                                                         wop_pbs_inst_rdy,
  output logic                                                         wop_pbs_inst_ack,

  // == RegFile Interface (shared with pe_pbs) ==
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

  // == AXI Interface for LUT (shared with pe_pbs's GLWE interface) ==
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

  // == AXI Interface for BSK (shared with pe_pbs) ==
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

  // == AXI Interface for KSK (shared with pe_pbs) ==
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

  // == WoP-PBS Configuration ==
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0]                   bit_extract_lut_base_addr,
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0]                   circuit_bs_lut_base_addr,
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0]                   vertical_pack_lut_addr,

  // == Error and Info Interface ==
  output logic [PEP_ERROR_W-1:0]                                       error,
  output logic [PEP_INFO_W-1:0]                                        pep_rif_info,
  output logic [PEP_COUNTER_INC_W-1:0]                                 pep_rif_counter_inc,

  // == Debug Interface ==
  output logic [2:0]                                                   debug_current_stage,
  output logic [MAX_BIT_WIDTH-1:0]                                     debug_current_bit
);

// ==============================================================================================
// Internal Signals
// ==============================================================================================
  // Instruction manager to PBS interface
  logic [PE_INST_W-1:0] pbs_inst;
  logic pbs_inst_vld;
  logic pbs_inst_rdy;
  logic pbs_inst_ack;
  
  // Stage control signals
  logic wop_pbs_done;

// ==============================================================================================
// WoP-PBS Instruction Manager
// ==============================================================================================
  // This module orchestrates the three stages of WoP-PBS by generating
  // appropriate PBS instructions for each stage
  
  wop_pbs_instruction_manager #(
    .MAX_BIT_WIDTH(MAX_BIT_WIDTH)
  ) i_instruction_manager (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // WoP-PBS instruction input
    .wop_pbs_inst(wop_pbs_inst),
    .wop_pbs_inst_vld(wop_pbs_inst_vld),
    .wop_pbs_inst_rdy(wop_pbs_inst_rdy),
    
    // PBS instruction output
    .pbs_inst(pbs_inst),
    .pbs_inst_vld(pbs_inst_vld),
    .pbs_inst_rdy(pbs_inst_rdy),
    .pbs_inst_ack(pbs_inst_ack),
    
    // Stage control
    .current_stage(debug_current_stage),
    .current_bit(debug_current_bit),
    .wop_pbs_done(wop_pbs_done),
    
    // Configuration
    .bit_extract_lut_base_addr(bit_extract_lut_base_addr),
    .circuit_bs_lut_base_addr(circuit_bs_lut_base_addr),
    .vertical_pack_lut_addr(vertical_pack_lut_addr)
  );

// ==============================================================================================
// Standard PBS Instance - The Workhorse of WoP-PBS
// ==============================================================================================
  // The key insight: WoP-PBS is just multiple PBS operations with different LUTs
  // We can reuse the entire pe_pbs module without any modifications
  
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
  ) i_pe_pbs (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // Instruction interface - controlled by instruction manager
    .inst(pbs_inst),
    .inst_vld(pbs_inst_vld),
    .inst_rdy(pbs_inst_rdy),
    .inst_ack(pbs_inst_ack),
    .inst_ack_br_loop(),
    .inst_load_blwe_ack(),
    
    // RegFile interface - pass through
    .pep_regf_wr_req_vld(pep_regf_wr_req_vld),
    .pep_regf_wr_req_rdy(pep_regf_wr_req_rdy),
    .pep_regf_wr_req(pep_regf_wr_req),
    .pep_regf_wr_data_vld(pep_regf_wr_data_vld),
    .pep_regf_wr_data_rdy(pep_regf_wr_data_rdy),
    .pep_regf_wr_data(pep_regf_wr_data),
    .regf_pep_wr_ack(regf_pep_wr_ack),
    
    .pep_regf_rd_req_vld(pep_regf_rd_req_vld),
    .pep_regf_rd_req_rdy(pep_regf_rd_req_rdy),
    .pep_regf_rd_req(pep_regf_rd_req),
    .regf_pep_rd_data_avail(regf_pep_rd_data_avail),
    .regf_pep_rd_data(regf_pep_rd_data),
    .regf_pep_rd_last_word(regf_pep_rd_last_word),
    .regf_pep_rd_is_body(regf_pep_rd_is_body),
    .regf_pep_rd_last_mask(regf_pep_rd_last_mask),
    
    // Configuration - pass through
    .reset_bsk_cache(reset_bsk_cache),
    .reset_bsk_cache_done(reset_bsk_cache_done),
    .bsk_mem_avail(bsk_mem_avail),
    .bsk_mem_addr(bsk_mem_addr),
    
    .reset_ksk_cache(reset_ksk_cache),
    .reset_ksk_cache_done(reset_ksk_cache_done),
    .ksk_mem_avail(ksk_mem_avail),
    .ksk_mem_addr(ksk_mem_addr),
    
    .reset_cache(reset_cache),
    .gid_offset(gid_offset),
    .twd_omg_ru_r_pow(twd_omg_ru_r_pow),
    .use_bpip(1'b0),           // Disable BPIP for WoP-PBS
    .use_bpip_opportunism(1'b0),
    .bpip_timeout('0),
    
    // AXI interfaces - pass through
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
    
    .m_axi4_glwe_arid(m_axi4_glwe_arid),
    .m_axi4_glwe_araddr(m_axi4_glwe_araddr),
    .m_axi4_glwe_arlen(m_axi4_glwe_arlen),
    .m_axi4_glwe_arsize(m_axi4_glwe_arsize),
    .m_axi4_glwe_arburst(m_axi4_glwe_arburst),
    .m_axi4_glwe_arvalid(m_axi4_glwe_arvalid),
    .m_axi4_glwe_arready(m_axi4_glwe_arready),
    .m_axi4_glwe_rid(m_axi4_glwe_rid),
    .m_axi4_glwe_rdata(m_axi4_glwe_rdata),
    .m_axi4_glwe_rresp(m_axi4_glwe_rresp),
    .m_axi4_glwe_rlast(m_axi4_glwe_rlast),
    .m_axi4_glwe_rvalid(m_axi4_glwe_rvalid),
    .m_axi4_glwe_rready(m_axi4_glwe_rready),
    
    // Error and info
    .error(error),
    .pep_rif_info(pep_rif_info),
    .pep_rif_counter_inc(pep_rif_counter_inc)
  );

// ==============================================================================================
// Output Control
// ==============================================================================================
  // WoP-PBS acknowledgment is generated when all stages are complete
  assign wop_pbs_inst_ack = wop_pbs_done;

endmodule