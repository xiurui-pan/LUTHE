// ==============================================================================================
// Filename: wop_pbs_kernel.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// WoP-PBS (Programmable Bootstrapping Without Padding) Processing Element.
// This module implements the bootstrapping algorithm found in 'circuit_bootstrapping.cpp'.
// It is designed to coexist with the standard pe_pbs module and reuse its
// core computational resources like the NTT engine and AXI interfaces.
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
  // BRAM parameters for data storage
  parameter int ACCUM_BRAM_ADDR_W = 11, // Address width for Accumulator BRAM (2^11 = 2048 coefficients)
  parameter int LWE_A_BRAM_ADDR_W = 10, // Address width for input LWE 'a' coefficients
  parameter int ACCUM_BRAM_DEPTH = 2**ACCUM_BRAM_ADDR_W,
  parameter int LWE_A_BRAM_DEPTH = 2**LWE_A_BRAM_ADDR_W,
  
  // NTT engine parameters (reused from pe_pbs)
  parameter int MOD_MULT_TYPE = set_mod_mult_type(MOD_NTT_TYPE),
  parameter int REDUCT_TYPE = set_mod_reduct_type(MOD_NTT_TYPE),
  parameter int MULT_TYPE = MULT_CORE,
  parameter int PHI_MULT_TYPE = set_ntt_mult_type(MOD_NTT_W, MOD_NTT_TYPE),
  parameter int PP_MOD_MULT_TYPE = MOD_MULT_TYPE,
  parameter int PP_MULT_TYPE = MULT_TYPE,
  parameter int MODSW_2_PRECISION_W = MOD_NTT_W + 32,
  parameter int MODSW_2_MULT_TYPE = set_mult_type(MODSW_2_PRECISION_W),
  parameter int MODSW_MULT_TYPE = set_mult_type(MOD_NTT_W),
  
  // Memory latency parameters
  parameter int RAM_LATENCY = 2,
  parameter int URAM_LATENCY = RAM_LATENCY + 1,
  parameter int ROM_LATENCY = 2,
  
  // Twiddle file parameters
  parameter string TWD_IFNL_FILE_PREFIX = NTT_CORE_ARCH == NTT_CORE_ARCH_WMM_UNFOLD ?
                                          "memory_file/twiddle/NTT_CORE_ARCH_WMM/R8_PSI8_S3/SOLINAS3_32_17_13/twd_ifnl_bwd" :
                                          "memory_file/twiddle/NTT_CORE_ARCH_WMM/R8_PSI8_S3/SOLINAS3_32_17_13/twd_ifnl",
  parameter string TWD_PHRU_FILE_PREFIX = "memory_file/twiddle/NTT_CORE_ARCH_WMM/R8_PSI8_S3/SOLINAS3_32_17_13/twd_phru",
  parameter string TWD_GF64_FILE_PREFIX = $sformatf("memory_file/twiddle/NTT_CORE_ARCH_GF64/R%0d_PSI%0d/twd_phi", R, PSI),
  
  // Other parameters
  parameter int INST_FIFO_DEPTH = 8,
  parameter int REGF_RD_LATENCY = URAM_LATENCY + 4,
  parameter int KS_IF_COEF_NB = (LBY < REGF_COEF_NB) ? LBY : REGF_SEQ_COEF_NB,
  parameter int KS_IF_SUBW_NB = (LBY < REGF_COEF_NB) ? 1 : REGF_SEQ,
  parameter int PHYS_RAM_DEPTH = 1024
)
(
  input  logic clk,
  input  logic s_rst_n,

  // == Instruction Interface ==
  input  logic                           wop_pbs_inst_vld,
  input  logic [PE_INST_W-1:0]           wop_pbs_inst,
  input  logic                           inst_vld,
  output logic                           inst_rdy,
  output logic                           inst_ack,

  // == RegFile Interface (reused from pe_pbs) ==
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

  // == AXI Interface for Test Vector / LUT (SHARED with pe_pbs's GLWE interface) ==
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

  // == AXI Interface for BSK (SHARED with pe_pbs) ==
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

  // == Interface TO the SHARED NTT Engine ==
  output logic [PSI-1:0][R-1:0]                                        wop_ntt_data_avail,
  output logic [PSI-1:0][R-1:0][PBS_B_W:0]                             wop_ntt_data,
  output logic                                                           wop_ntt_sob,
  output logic                                                           wop_ntt_eob,
  output logic                                                           wop_ntt_sog,
  output logic                                                           wop_ntt_eog,
  output logic                                                           wop_ntt_sol,
  output logic                                                           wop_ntt_eol,
  output logic [BPBS_ID_W-1:0]                                         wop_ntt_pbs_id,
  output logic                                                           wop_ntt_last_pbs,
  output logic                                                           wop_ntt_full_throughput,
  output logic                                                           wop_ntt_ctrl_avail,
  input  logic [PSI-1:0][R-1:0]                                        wop_ntt_data_rdy,
  input  logic                                                           wop_ntt_ctrl_rdy,

  // == Interface FROM the SHARED NTT Engine ==
  input  logic [PSI-1:0][R-1:0]                                        ntt_wop_data_avail,
  input  logic [PSI-1:0][R-1:0][MOD_Q_W-1:0]                           ntt_wop_data,
  input  logic                                                           ntt_wop_sob,
  input  logic                                                           ntt_wop_eob,
  input  logic                                                           ntt_wop_sol,
  input  logic                                                           ntt_wop_eol,
  input  logic                                                           ntt_wop_sog,
  input  logic                                                           ntt_wop_eog,
  input  logic [BPBS_ID_W-1:0]                                         ntt_wop_pbs_id,

  // == Configuration Interface ==
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0]                   gid_offset,
  input  logic [1:0][R/2-1:0][MOD_NTT_W-1:0]                           twd_omg_ru_r_pow,

  // == Error and Info Interface ==
  output logic [PEP_ERROR_W-1:0]                                       error,
  output logic [PEP_INFO_W-1:0]                                        pep_rif_info,
  output logic [PEP_COUNTER_INC_W-1:0]                                 pep_rif_counter_inc
);

// ==============================================================================================
// Local Parameters
// ==============================================================================================
  localparam int LWE_N = N; // Number of coefficients in LWE sample
  localparam int N_LVL2 = N; // N for level 2 (same as N in this context)
  localparam int K = 1; // k parameter for TLWE (k=1 for standard TFHE)
  localparam int ELL_LVL2 = 8; // ell parameter for level 2
  localparam int _2L = 2 * ELL_LVL2; // 2*ell for decomposition

// ==============================================================================================
// Internal State Machine - Directly maps to circuitBootstrapWoKS logic
// ==============================================================================================
  typedef enum logic [3:0] {
    IDLE,
    DECODE_INST,
    LOAD_TEST_VEC,      // Load the LUT/TestVector into the accumulator BRAM
    LOAD_INPUT_LWE,     // Load the input LWE sample (abar) into its BRAM
    LOOP_INIT,
    LOOP_ROTATE_ACC,    // Corresponds to: acc2 = (X^aibar - 1) * acc1
    LOOP_EXT_PROD,      // Corresponds to: acc1 = BKi * acc2
    LOOP_ACCUMULATE,    // Corresponds to: acc += acc1
    SAMPLE_EXTRACT,
    WRITE_RESULT,
    DONE
  } state_e;

  state_e current_state, next_state;

// ==============================================================================================
// Internal Registers and Signals
// ==============================================================================================
  // Loop control
  logic [LWE_N_W-1:0] loop_counter;
  logic [LWE_N_W-1:0] max_loop_count;
  
  // Instruction decoding
  logic [REGF_ADDR_W-1:0] input_lwe_addr;
  logic [REGF_ADDR_W-1:0] output_lwe_addr;
  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] test_vec_addr;
  logic [BSK_BATCH_ID_W-1:0] bsk_batch_id;
  logic [MOD_Q_W-1:0] mu_value; // mu parameter from instruction
  
  // BRAM control signals
  logic accum_bram_a_wr_en;
  logic [ACCUM_BRAM_ADDR_W-1:0] accum_bram_a_wr_addr;
  logic [MOD_Q_W-1:0] accum_bram_a_wr_data;
  logic [ACCUM_BRAM_ADDR_W-1:0] accum_bram_a_rd_addr;
  logic [MOD_Q_W-1:0] accum_bram_a_rd_data;
  
  logic accum_bram_b_wr_en;
  logic [ACCUM_BRAM_ADDR_W-1:0] accum_bram_b_wr_addr;
  logic [MOD_Q_W-1:0] accum_bram_b_wr_data;
  logic [ACCUM_BRAM_ADDR_W-1:0] accum_bram_b_rd_addr;
  logic [MOD_Q_W-1:0] accum_bram_b_rd_data;
  
  logic lwe_a_bram_wr_en;
  logic [LWE_A_BRAM_ADDR_W-1:0] lwe_a_bram_wr_addr;
  logic [MOD_Q_W-1:0] lwe_a_bram_wr_data;
  logic [LWE_A_BRAM_ADDR_W-1:0] lwe_a_bram_rd_addr;
  logic [MOD_Q_W-1:0] lwe_a_bram_rd_data;
  
  // Sub-module control signals
  logic poly_rotator_start;
  logic poly_rotator_done;
  logic [MOD_Q_W-1:0] poly_rotator_rotation_amount;
  
  logic sample_extractor_start;
  logic sample_extractor_done;
  logic [LWE_N-1:0][MOD_Q_W-1:0] sample_extractor_result;
  
  // External product control
  logic ext_prod_start;
  logic ext_prod_done;
  logic [PSI-1:0][R-1:0] ext_prod_data_avail;
  logic [PSI-1:0][R-1:0][PBS_B_W:0] ext_prod_data;
  
  // Load control signals
  logic load_test_vec_done;
  logic load_input_lwe_done;
  logic write_result_done;
  
  // Default output assignments
  logic inst_ack_next;
  logic inst_rdy_next;

// ==============================================================================================
// BRAM Instantiations
// ==============================================================================================
  // Accumulator BRAM A (stores acc, acc1 from C++ code)
  bram_simple #(
    .ADDR_W(ACCUM_BRAM_ADDR_W),
    .DATA_W(MOD_Q_W),
    .DEPTH(ACCUM_BRAM_DEPTH)
  ) i_accum_bram_a (
    .clk(clk),
    .wr_en(accum_bram_a_wr_en),
    .wr_addr(accum_bram_a_wr_addr),
    .wr_data(accum_bram_a_wr_data),
    .rd_addr(accum_bram_a_rd_addr),
    .rd_data(accum_bram_a_rd_data)
  );

  // Accumulator BRAM B (stores acc2 from C++ code)
  bram_simple #(
    .ADDR_W(ACCUM_BRAM_ADDR_W),
    .DATA_W(MOD_Q_W),
    .DEPTH(ACCUM_BRAM_DEPTH)
  ) i_accum_bram_b (
    .clk(clk),
    .wr_en(accum_bram_b_wr_en),
    .wr_addr(accum_bram_b_wr_addr),
    .wr_data(accum_bram_b_wr_data),
    .rd_addr(accum_bram_b_rd_addr),
    .rd_data(accum_bram_b_rd_data)
  );

  // Input LWE 'a' part BRAM (stores abar from C++ code)
  bram_simple #(
    .ADDR_W(LWE_A_BRAM_ADDR_W),
    .DATA_W(MOD_Q_W),
    .DEPTH(LWE_A_BRAM_DEPTH)
  ) i_lwe_a_bram (
    .clk(clk),
    .wr_en(lwe_a_bram_wr_en),
    .wr_addr(lwe_a_bram_wr_addr),
    .wr_data(lwe_a_bram_wr_data),
    .rd_addr(lwe_a_bram_rd_addr),
    .rd_data(lwe_a_bram_rd_data)
  );

// ==============================================================================================
// Sub-Module Instantiations
// ==============================================================================================
  // 1. NEW: Polynomial Rotator and Subtractor
  poly_rotator_sub #(
    .MOD_Q_W(MOD_Q_W),
    .N(N),
    .ADDR_W(ACCUM_BRAM_ADDR_W)
  ) i_poly_rotator (
    .clk(clk),
    .s_rst_n(s_rst_n),
    .start(poly_rotator_start),
    .rotation_amount(poly_rotator_rotation_amount),
    .input_addr(accum_bram_a_rd_addr),
    .input_data(accum_bram_a_rd_data),
    .output_addr(accum_bram_b_wr_addr),
    .output_data(accum_bram_b_wr_data),
    .output_wr_en(accum_bram_b_wr_en),
    .done(poly_rotator_done)
  );

  // 2. NEW: Sample Extractor
  sample_extractor #(
    .MOD_Q_W(MOD_Q_W),
    .N(N),
    .ADDR_W(ACCUM_BRAM_ADDR_W)
  ) i_sample_extractor (
    .clk(clk),
    .s_rst_n(s_rst_n),
    .start(sample_extractor_start),
    .input_addr(accum_bram_a_rd_addr),
    .input_data(accum_bram_a_rd_data),
    .mu_value(mu_value),
    .result(sample_extractor_result),
    .done(sample_extractor_done)
  );

  // 3. REUSED: BSK Manager (conceptually - will be shared with pe_pbs)
  // This will be handled at the top level through arbitration

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      inst_ack <= 1'b0;
      inst_rdy <= 1'b1;
    end else begin
      current_state <= next_state;
      inst_ack <= inst_ack_next;
      inst_rdy <= inst_rdy_next;
    end
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    inst_ack_next = 1'b0;
    inst_rdy_next = 1'b1;
    
    // Default sub-module control
    poly_rotator_start = 1'b0;
    sample_extractor_start = 1'b0;
    ext_prod_start = 1'b0;
    
    // Default BRAM control
    accum_bram_a_wr_en = 1'b0;
    accum_bram_b_wr_en = 1'b0;
    lwe_a_bram_wr_en = 1'b0;
    
    case (current_state)
      IDLE: begin
        if (wop_pbs_inst_vld) begin
          next_state = DECODE_INST;
          inst_rdy_next = 1'b0;
        end
      end
      
      DECODE_INST: begin
        // Decode instruction to extract addresses and parameters
        // This will be implemented based on the instruction format
        next_state = LOAD_TEST_VEC;
      end
      
      LOAD_TEST_VEC: begin
        // Issue AXI read on m_axi4_glwe to load test vector into accum_bram_a
        // This will be implemented with AXI read logic
        if (load_test_vec_done) begin
          next_state = LOAD_INPUT_LWE;
        end
      end
      
      LOAD_INPUT_LWE: begin
        // Issue RegFile read to load input LWE 'a' coefficients into lwe_a_bram
        // This will be implemented with RegFile read logic
        if (load_input_lwe_done) begin
          next_state = LOOP_INIT;
        end
      end
      
      LOOP_INIT: begin
        loop_counter = 0;
        max_loop_count = LWE_N;
        next_state = LOOP_ROTATE_ACC;
      end
      
      LOOP_ROTATE_ACC: begin
        // Trigger i_poly_rotator to compute (X^aibar - 1) * acc
        // 'aibar' is read from lwe_a_bram[loop_counter]
        poly_rotator_start = 1'b1;
        poly_rotator_rotation_amount = lwe_a_bram_rd_data;
        
        if (poly_rotator_done) begin
          next_state = LOOP_EXT_PROD;
        end
      end
      
      LOOP_EXT_PROD: begin
        // This state orchestrates the external product.
        // 1. Request BSK chunk from shared BSK manager
        // 2. Decompose the rotated accumulator (from accum_bram_b)
        // 3. Send decomposed data TO the shared NTT engine
        // 4. Send BSK data TO the shared NTT engine
        // 5. Receive results FROM the shared NTT engine
        // 6. Perform point-wise multiplications
        // 7. Send result TO the shared NTT engine for INTT
        // 8. Store final result in accum_bram_a
        ext_prod_start = 1'b1;
        
        if (ext_prod_done) begin
          next_state = LOOP_ACCUMULATE;
        end
      end
      
      LOOP_ACCUMULATE: begin
        // Add the result of the external product to the main accumulator (accum_bram_a)
        loop_counter = loop_counter + 1;
        if (loop_counter == max_loop_count) begin
          next_state = SAMPLE_EXTRACT;
        end else begin
          next_state = LOOP_ROTATE_ACC; // Next iteration
        end
      end
      
      SAMPLE_EXTRACT: begin
        // Trigger i_sample_extractor on the final accumulator value
        sample_extractor_start = 1'b1;
        
        if (sample_extractor_done) begin
          next_state = WRITE_RESULT;
        end
      end
      
      WRITE_RESULT: begin
        // Write the extracted LWE sample back to the RegFile
        // This will be implemented with RegFile write logic
        if (write_result_done) begin
          next_state = DONE;
        end
      end
      
      DONE: begin
        inst_ack_next = 1'b1;
        next_state = IDLE;
      end
    endcase
  end

// ==============================================================================================
// External Product Control Logic
// ==============================================================================================
  // This section will implement the complex external product state machine
  // that coordinates with the shared NTT engine
  // Implementation will be added based on the NTT engine interface

// ==============================================================================================
// AXI Read/Write Control Logic
// ==============================================================================================
  // This section will implement the AXI read/write logic for:
  // 1. Loading test vector from HBM via m_axi4_glwe
  // 2. Reading BSK data via m_axi4_bsk
  // Implementation will be added based on the AXI interface requirements

// ==============================================================================================
// RegFile Read/Write Control Logic
// ==============================================================================================
  // This section will implement the RegFile read/write logic for:
  // 1. Reading input LWE samples
  // 2. Writing output LWE samples
  // Implementation will be added based on the RegFile interface requirements

// ==============================================================================================
// Error and Info Logic
// ==============================================================================================
  // This section will implement error handling and performance monitoring
  // Implementation will be added based on the error/info interface requirements

endmodule