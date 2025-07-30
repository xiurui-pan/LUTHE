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
  parameter int ACCUM_BRAM_ADDR_W = 11, // Address width for Accumulator BRAM (2^11 = 2048 coefficients)
  parameter int LWE_A_BRAM_ADDR_W = 10  // Address width for input LWE 'a' coefficients
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

  // // == RegFile Read Interface (for input LWE ciphertext) ==
  // output logic                           pep_regf_rd_req_vld,
  // input  logic                           pep_regf_rd_req_rdy,
  // output logic [REGF_WR_REQ_W-1:0]       pep_regf_rd_req,
  // input  logic        regf_pep_rd_data_avail,
  // input  logic regf_pep_rd_data,

  // // == RegFile Write Interface (for output LWE ciphertext) ==
  // output logic                           pep_regf_wr_req_vld,
  // input  logic                           pep_regf_wr_req_rdy,
  // output regf_common_param_pkg::regf_wr_req_t pep_regf_wr_req,
  // output logic        pep_regf_wr_data_vld,
  // input  logic        pep_regf_wr_data_rdy,
  // output logic pep_regf_wr_data,
    //== pep <-> regfile
  // write
  output logic                                                         pep_regf_wr_req_vld,
  input  logic                                                         pep_regf_wr_req_rdy,
  output logic [REGF_WR_REQ_W-1:0]                                     pep_regf_wr_req,

  output logic [REGF_COEF_NB-1:0]                                      pep_regf_wr_data_vld,
  input  logic [REGF_COEF_NB-1:0]                                      pep_regf_wr_data_rdy,
  output logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0]                         pep_regf_wr_data,

  input  logic                                                         regf_pep_wr_ack,

  // read
  output logic                                                         pep_regf_rd_req_vld,
  input  logic                                                         pep_regf_rd_req_rdy,
  output logic [REGF_RD_REQ_W-1:0]                                     pep_regf_rd_req,

  input  logic [REGF_COEF_NB-1:0]                                      regf_pep_rd_data_avail,
  input  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0]                         regf_pep_rd_data,
  input  logic                                                         regf_pep_rd_last_word, // valid with avail[0]
  input  logic                                                         regf_pep_rd_is_body,
  input  logic                                                         regf_pep_rd_last_mask,

  // == AXI Interface for Test Vector / LUT (SHARED with pe_pbs's GLWE interface) ==
  output logic m_axi4_glwe_arvalid,
  //... (all other m_axi4_glwe_* signals)
  input  logic m_axi4_glwe_rvalid,
  input  logic m_axi4_glwe_rdata,

  // == AXI Interface for BSK (SHARED with pe_pbs) ==
  output logic m_axi4_bsk_arvalid,
  //... (all other m_axi4_bsk_* signals)
  input  logic m_axi4_bsk_rvalid,
  input  logic m_axi4_bsk_rdata,

  // == Interface TO the SHARED NTT Engine ==
  output logic                  wop_ntt_data_avail,
  output logic       wop_ntt_data,
  //... (all other `decomp_ntt_*` signals, prefixed with `wop_`)
  input  logic                  wop_ntt_data_rdy,

  // == Interface FROM the SHARED NTT Engine ==
  input  logic                  ntt_wop_data_avail,
  input  logic     ntt_wop_data
  //... (all other `ntt_acc_*` signals, with `wop` in the name)
);

  //--------------------------------------------------------------------------------------------
  // Internal State Machine (Sequencer) - Directly maps to circuitBootstrapWoKS logic
  //--------------------------------------------------------------------------------------------
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
  // Internal loop counter for the 'n_lvl0' iterations
  logic loop_counter;
  // Internal registers to hold instruction details
  //...

  //--------------------------------------------------------------------------------------------
  // Internal BRAMs for data storage
  //--------------------------------------------------------------------------------------------
  // Accumulator BRAM (stores acc, acc1, acc2 from C++ code)
  logic accum_bram_a[N];
  logic accum_bram_b[N];
  // Input LWE 'a' part BRAM (stores abar from C++ code)
  logic lwe_a_bram;

  //--------------------------------------------------------------------------------------------
  // Instantiation of Key Sub-Modules
  //--------------------------------------------------------------------------------------------
  // 1. NEW: Polynomial Rotator and Subtractor
  poly_rotator_sub i_poly_rotator (.clk,.s_rst_n, /*... */ );
  // 2. REUSED (conceptually): BSK Manager (driven by our FSM)
  bsk_manager i_bsk_manager (.clk,.s_rst_n, /*... */ );
  // 3. REUSED (conceptually): External Product Engine (our FSM drives the shared NTT)
  // 4. NEW: Sample Extractor
  sample_extractor i_sample_extractor (.clk,.s_rst_n, /*... */ );

  // FSM Implementation (simplified logic)
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) current_state <= IDLE;
    else          current_state <= next_state;
  end

  always_comb begin
    next_state = current_state;
    //... default output assignments...
    case (current_state)
      IDLE:
        if (wop_pbs_inst_vld) next_state = DECODE_INST;
      DECODE_INST:
        // Latch instruction details (addresses, loop bounds)
        next_state = LOAD_TEST_VEC;
      LOAD_TEST_VEC:
        // Issue AXI read on m_axi4_glwe to load test vector into accum_bram_a
        if (load_complete) next_state = LOAD_INPUT_LWE;
      LOAD_INPUT_LWE:
        // Issue RegFile read to load input LWE 'a' coefficients into lwe_a_bram
        if (load_complete) next_state = LOOP_INIT;
      LOOP_INIT:
        loop_counter = 0;
        next_state = LOOP_ROTATE_ACC;
      LOOP_ROTATE_ACC:
        // Trigger i_poly_rotator to compute (X^aibar - 1) * acc
        // 'aibar' is read from lwe_a_bram[loop_counter]
        // Input is accum_bram_a, output is written to accum_bram_b
        if (rotation_done) next_state = LOOP_EXT_PROD;
      LOOP_EXT_PROD:
        // This state orchestrates the external product.
        // 1. Request BSK chunk from i_bsk_manager.
        // 2. Decompose the rotated accumulator (from accum_bram_b).
        // 3. Send decomposed data TO the shared NTT engine.
        // 4. Send BSK data TO the shared NTT engine.
        // 5. Receive results FROM the shared NTT engine.
        // 6. Perform point-wise multiplications.
        // 7. Send result TO the shared NTT engine for INTT.
        // 8. Store final result in a temporary BRAM.
        if (ext_prod_done) next_state = LOOP_ACCUMULATE;
      LOOP_ACCUMULATE:
        // Add the result of the external product to the main accumulator (accum_bram_a)
        loop_counter = loop_counter + 1;
        if (loop_counter == LWE_N) begin
          next_state = SAMPLE_EXTRACT;
        end else begin
          next_state = LOOP_ROTATE_ACC; // Next iteration
        end
      SAMPLE_EXTRACT:
        // Trigger i_sample_extractor on the final accumulator value
        if (extract_done) next_state = WRITE_RESULT;
      WRITE_RESULT:
        // Write the extracted LWE sample back to the RegFile
        if (write_done) next_state = DONE;
      DONE:
        inst_ack = 1'b1;
        next_state = IDLE;
    endcase
  end

endmodule