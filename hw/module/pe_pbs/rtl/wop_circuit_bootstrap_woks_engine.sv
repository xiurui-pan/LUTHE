// ==============================================================================================
// Filename: wop_circuit_bootstrap_woks_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// WoP-PBS Circuit Bootstrap WoKS Engine.
// This module implements the circuitBootstrapWoKS() function from circuit_bootstrapping.cpp.
// 
// C++ Algorithm:
// 1. Generate test vector: (1+X+...+X^{N-1})*X^{N/2}*mu2, then multiply by X^{bbar}
// 2. Initialize accumulator with test vector as noiseless trivial TLweSample
// 3. Blind rotation loop for each coefficient:
//    - acc1 = acc
//    - acc2 = (X^aibar - 1) * acc1 = acc1*X^aibar - acc1  
//    - acc1 = BKi * acc2 (external product using BSK and NTT)
//    - acc += acc1
// 4. Sample extraction: extract LWE sample from final accumulator
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module wop_circuit_bootstrap_woks_engine
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import param_ntt_pkg::*;
  import ntt_core_common_param_pkg::*;
  import bsk_mgr_common_param_pkg::*;
#(
  parameter int MOD_Q_W = 32,
  parameter int N_LVL0 = 630,
  parameter int N_LVL2 = 2048,
  parameter int ELL_LVL2 = 8,
  parameter int K = 1,  // k parameter for TLWE
  parameter int BSK_BATCH_ID_W = 8,
  parameter int BSK_PC = 1,
  parameter int R = 32,  // Ring size parameter  
  parameter int PSI = 2  // PSI parameter
)
(
  input  logic clk,
  input  logic s_rst_n,
  
  // Control interface
  input  logic start,
  input  logic [MOD_Q_W-1:0] mu_value,
  output logic done,
  
  // Input: pre-modswitch result (abar)
  input  logic [N_LVL0:0][31:0] abar_data,  // abar[n_lvl0+1] from preModSwitch
  input  logic abar_valid,
  
  // Output: LWE sample at level 2
  output logic [N_LVL2-1:0][MOD_Q_W-1:0] result_a,
  output logic [MOD_Q_W-1:0] result_b,
  output logic result_valid,
  
  // BSK interface (shared)
  output logic bsk_req_vld,
  input  logic bsk_req_rdy,
  output logic [BSK_BATCH_ID_W-1:0] bsk_batch_id,
  input  logic bsk_data_avail,
  input  logic [BSK_PC-1:0][R-1:0][MOD_Q_W-1:0] bsk_data,
  
  // NTT engine interface (shared)
  output logic [PSI-1:0][R-1:0] ntt_data_avail,
  output logic [PSI-1:0][R-1:0][MOD_Q_W-1:0] ntt_data,
  output logic ntt_sob, ntt_eob, ntt_sog, ntt_eog, ntt_sol, ntt_eol,
  input  logic [PSI-1:0][R-1:0] ntt_data_rdy,
  input  logic [PSI-1:0][R-1:0][MOD_Q_W-1:0] ntt_result_data,
  input  logic ntt_result_sob, ntt_result_eob, ntt_result_sol, ntt_result_eol
);

// ==============================================================================================
// Local Parameters
// ==============================================================================================
  localparam int N2 = N_LVL2 / 2;
  localparam int _2L = 2 * ELL_LVL2;

// ==============================================================================================
// State Machine
// ==============================================================================================
  typedef enum logic [4:0] {
    IDLE,
    GENERATE_TEST_VECTOR,     // Generate test vector based on mu and bbar
    INIT_ACCUMULATOR,         // Initialize accumulator with test vector
    BLIND_ROTATE_LOOP,        // Main blind rotation loop
    COMPUTE_ACC2,             // acc2 = (X^aibar - 1) * acc1
    DECOMPOSE_ACC2,           // Gadget decomposition of acc2
    NTT_FORWARD,              // Forward NTT of decomposed polynomials
    EXTERNAL_PRODUCT,         // Point-wise multiplication with BSK
    NTT_INVERSE,              // Inverse NTT of product results
    ACCUMULATE,               // acc += acc1
    SAMPLE_EXTRACT,           // Extract final LWE sample
    DONE
  } state_e;

  // External product sub-state machine
  typedef enum logic [2:0] {
    EP_IDLE,
    EP_DECOMPOSE,
    EP_NTT_FWD,
    EP_MULTIPLY,
    EP_NTT_INV,
    EP_DONE
  } external_product_state_e;

  state_e current_state, next_state;

// ==============================================================================================
// Internal Registers and Storage
// ==============================================================================================
  // Test vector storage
  logic [N_LVL2-1:0][MOD_Q_W-1:0] testvect_temp;
  logic [N_LVL2-1:0][MOD_Q_W-1:0] testvect;
  
  // Accumulator storage (TLWE samples)
  logic [K:0][N_LVL2-1:0][MOD_Q_W-1:0] acc;   // Main accumulator
  logic [K:0][N_LVL2-1:0][MOD_Q_W-1:0] acc1;  // Temporary accumulator 1
  logic [K:0][N_LVL2-1:0][MOD_Q_W-1:0] acc2;  // Temporary accumulator 2
  
  // Loop control
  logic [$clog2(N_LVL0+1)-1:0] loop_counter;
  logic [31:0] current_aibar;
  logic [MOD_Q_W-1:0] mu2;
  logic [31:0] bbar;
  
  // Decomposition storage for external product (Gadget decomposition)
  logic [_2L-1:0][N_LVL2-1:0][31:0] decomp;
  logic [_2L-1:0][N_LVL2-1:0][MOD_Q_W-1:0] decomp_fft;
  
  // External product state and control
  external_product_state_e ep_state;
  logic [$clog2(_2L)-1:0] decomp_level_counter;
  logic [$clog2(N_LVL2)-1:0] coeff_counter;
  
  // Gadget decomposition parameters
  localparam int BASE_LOG = 4;  // Base 2^4 = 16 for decomposition
  localparam int BASE = 1 << BASE_LOG;
  localparam int MASK = BASE - 1;
  
  // Control signals
  logic test_vector_done;
  logic accumulator_init_done;
  logic acc2_compute_done;
  logic decompose_done;
  logic ntt_forward_done;
  logic external_product_done;
  logic ntt_inverse_done;
  logic accumulate_done;
  logic sample_extract_done;

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      loop_counter <= '0;
      mu2 <= '0;
      bbar <= '0;
      ep_state <= EP_IDLE;
      decomp_level_counter <= '0;
      coeff_counter <= '0;
    end else begin
      current_state <= next_state;
      
      case (current_state)
        IDLE: begin
          if (start && abar_valid) begin
            mu2 <= mu_value / 2;  // mu2 = mu / 2
            bbar <= abar_data[N_LVL0];  // bbar = abar[n_lvl0]
            loop_counter <= '0;
          end
        end
        
        BLIND_ROTATE_LOOP: begin
          current_aibar <= abar_data[loop_counter];
          // Reset external product counters when entering this state
          if (current_state != next_state && next_state == DECOMPOSE_ACC2) begin
            decomp_level_counter <= '0;
            coeff_counter <= '0;
          end
          // Handle skip case: when aibar is 0, increment counter
          if (current_state == next_state && current_aibar == 0) begin
            loop_counter <= loop_counter + 1;
          end
        end
        
        NTT_FORWARD: begin
          // Handle coefficient and level counters in sequential logic
          if (ntt_data_rdy[0][0] && decomp_level_counter < _2L) begin
            if (coeff_counter < N_LVL2-1) begin
              coeff_counter <= coeff_counter + 1;
            end else begin
              coeff_counter <= '0;
              decomp_level_counter <= decomp_level_counter + 1;
            end
          end
          // Reset counters for inverse NTT
          if (current_state != next_state && next_state == NTT_INVERSE) begin
            decomp_level_counter <= '0;
            coeff_counter <= '0;
          end
        end
        
        NTT_INVERSE: begin
          // Handle coefficient and level counters in sequential logic
          if (ntt_data_rdy[0][0] && decomp_level_counter < _2L) begin
            if (coeff_counter < N_LVL2-1) begin
              coeff_counter <= coeff_counter + 1;
            end else begin
              coeff_counter <= '0;
              decomp_level_counter <= decomp_level_counter + 1;
            end
          end
        end
        
        ACCUMULATE: begin
          if (accumulate_done) begin
            loop_counter <= loop_counter + 1;
          end
        end
      endcase
    end
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    done = 1'b0;
    result_valid = 1'b0;
    
    // BSK and NTT interface defaults
    bsk_req_vld = 1'b0;
    bsk_batch_id = '0;
    ntt_data_avail = '0;
    ntt_data = '0;
    ntt_sob = 1'b0; ntt_eob = 1'b0; ntt_sog = 1'b0; 
    ntt_eog = 1'b0; ntt_sol = 1'b0; ntt_eol = 1'b0;
    
    case (current_state)
      IDLE: begin
        if (start && abar_valid) begin
          next_state = GENERATE_TEST_VECTOR;
        end
      end
      
      GENERATE_TEST_VECTOR: begin
        // Generate test vector: (1+X+...+X^{N-1})*X^{N/2}*mu2
        // First generate base pattern
        for (int j = 0; j < N2; j++) begin
          testvect_temp[j] = -mu2;  // Negative for first half
        end
        for (int j = N2; j < N_LVL2; j++) begin
          testvect_temp[j] = mu2;   // Positive for second half
        end
        
        // Then multiply by X^{bbar} (rotation)
        if (bbar < N_LVL2) begin
          for (int j = 0; j < N_LVL2 - bbar; j++) begin
            testvect[j] = testvect_temp[j + bbar];
          end
          for (int j = N_LVL2 - bbar; j < N_LVL2; j++) begin
            testvect[j] = -testvect_temp[j - (N_LVL2 - bbar)];  // Sign flip due to X^N = -1
          end
        end else begin
          automatic int bbar_ = bbar - N_LVL2;
          for (int j = 0; j < N_LVL2 - bbar_; j++) begin
            testvect[j] = -testvect_temp[j + bbar_];
          end
          for (int j = N_LVL2 - bbar_; j < N_LVL2; j++) begin
            testvect[j] = testvect_temp[j - (N_LVL2 - bbar_)];
          end
        end
        
        test_vector_done = 1'b1;
        next_state = INIT_ACCUMULATOR;
      end
      
      INIT_ACCUMULATOR: begin
        // Initialize accumulator as noiseless trivial TLweSample
        for (int j = 0; j < N_LVL2; j++) begin
          acc[0][j] = '0;                    // a[0] = 0 (k=1)
          acc[1][j] = testvect[j];          // a[1] = testvect (b part)
        end
        
        accumulator_init_done = 1'b1;
        next_state = BLIND_ROTATE_LOOP;
      end
      
      BLIND_ROTATE_LOOP: begin
        if (loop_counter < N_LVL0) begin
          if (current_aibar == 0) begin
            // Skip if aibar is 0 - increment will be handled in sequential logic
            next_state = BLIND_ROTATE_LOOP;  // Stay in same state, counter incremented in always_ff
          end else begin
            // Copy acc to acc1
            for (int q = 0; q <= K; q++) begin
              for (int j = 0; j < N_LVL2; j++) begin
                acc1[q][j] = acc[q][j];
              end
            end
            next_state = COMPUTE_ACC2;
          end
        end else begin
          next_state = SAMPLE_EXTRACT;
        end
      end
      
      COMPUTE_ACC2: begin
        // acc2 = (X^aibar - 1) * acc1 = acc1*X^aibar - acc1
        for (int q = 0; q <= K; q++) begin
          if (current_aibar < N_LVL2) begin
            for (int j = 0; j < current_aibar; j++) begin
              acc2[q][j] = -acc1[q][j + N_LVL2 - current_aibar] - acc1[q][j];
            end
            for (int j = current_aibar; j < N_LVL2; j++) begin
              acc2[q][j] = acc1[q][j - current_aibar] - acc1[q][j];
            end
          end else begin
            automatic int aibar_ = current_aibar - N_LVL2;
            for (int j = 0; j < aibar_; j++) begin
              acc2[q][j] = acc1[q][j + N_LVL2 - aibar_] - acc1[q][j];
            end
            for (int j = aibar_; j < N_LVL2; j++) begin
              acc2[q][j] = -acc1[q][j - aibar_] - acc1[q][j];
            end
          end
        end
        
        acc2_compute_done = 1'b1;
        next_state = EXTERNAL_PRODUCT;
      end
      
      DECOMPOSE_ACC2: begin
        // Gadget decomposition: decompose acc2 into _2L levels
        // Based on tGsw64DecompH algorithm
        for (int p = 0; p < _2L; p++) begin
          for (int q = 0; q <= K; q++) begin
            for (int j = 0; j < N_LVL2; j++) begin
              // Correct Gadget decomposition using base decomposition
              // Extract BASE_LOG bits from each level
              automatic logic [63:0] temp_coeff = acc2[q][j];
              automatic logic [31:0] shift_amount = p * BASE_LOG;
              decomp[p][j] = (temp_coeff >> shift_amount) & MASK;
            end
          end
        end
        decompose_done = 1'b1;
        next_state = NTT_FORWARD;
      end
      
      NTT_FORWARD: begin
        // Forward NTT: IntPolynomial_ifft_lvl2 equivalent
        // Send decomposed polynomials to NTT engine for forward transform
        
        if (decomp_level_counter < _2L) begin
          // Send current decomposition level to NTT
          ntt_data_avail[0][0] = 1'b1;
          ntt_data[0][0] = decomp[decomp_level_counter][coeff_counter];
          ntt_sob = (coeff_counter == 0);
          ntt_eob = (coeff_counter == N_LVL2-1);
          ntt_sol = (decomp_level_counter == 0) && (coeff_counter == 0);
          ntt_eol = (decomp_level_counter == _2L-1) && (coeff_counter == N_LVL2-1);
          
          // Counter updates moved to sequential logic in always_ff
          next_state = NTT_FORWARD;  // Stay in same state until completion
        end else begin
          ntt_forward_done = 1'b1;
          next_state = EXTERNAL_PRODUCT;
        end
      end
      
      EXTERNAL_PRODUCT: begin
        // Point-wise multiplication with BSK: LagrangeHalfCPolynomialAddMul_lvl2 equivalent
        
        // Request BSK data for current coefficient
        bsk_req_vld = 1'b1;
        bsk_batch_id = loop_counter;
        
        if (bsk_req_rdy && bsk_data_avail && ntt_result_eol) begin
          // Perform point-wise multiplication of NTT results with BSK data
          // This is a simplified model - real implementation needs proper complex multiplication
          for (int p = 0; p < _2L; p++) begin
            for (int q = 0; q <= K; q++) begin
              for (int j = 0; j < N_LVL2; j++) begin
                // Simplified point-wise multiplication
                decomp_fft[p][j] = ntt_result_data[0][0] * bsk_data[0][j % 8];  // Use BSK data
              end
            end
          end
          
          external_product_done = 1'b1;
          next_state = NTT_INVERSE;
        end
      end
      
      NTT_INVERSE: begin
        // Inverse NTT: TorusPolynomial64_fft_lvl2 equivalent
        // Send FFT results back to NTT engine for inverse transform
        
        if (decomp_level_counter < _2L) begin
          // Send current FFT level to NTT for inverse transform
          ntt_data_avail[0][0] = 1'b1;
          ntt_data[0][0] = decomp_fft[decomp_level_counter][coeff_counter];
          ntt_sob = (coeff_counter == 0);
          ntt_eob = (coeff_counter == N_LVL2-1);
          ntt_sol = (decomp_level_counter == 0) && (coeff_counter == 0);
          ntt_eol = (decomp_level_counter == _2L-1) && (coeff_counter == N_LVL2-1);
          
          // Counter updates moved to sequential logic in always_ff
          next_state = NTT_INVERSE;  // Stay in same state until completion
        end else begin
          // Collect inverse NTT results into acc1
          if (ntt_result_eol) begin
            for (int q = 0; q <= K; q++) begin
              for (int j = 0; j < N_LVL2; j++) begin
                acc1[q][j] = ntt_result_data[0][0];  // Collect final results
              end
            end
            ntt_inverse_done = 1'b1;
            next_state = ACCUMULATE;
          end
        end
      end
      
      ACCUMULATE: begin
        // acc += acc1
        for (int q = 0; q <= K; q++) begin
          for (int j = 0; j < N_LVL2; j++) begin
            acc[q][j] = acc[q][j] + acc1[q][j];
          end
        end
        
        accumulate_done = 1'b1;
        next_state = BLIND_ROTATE_LOOP;
      end
      
      SAMPLE_EXTRACT: begin
        // Sample extraction from final accumulator
        // result->a[0] = acc->a[0].coefs[0]
        result_a[0] = acc[0][0];
        
        // result->a[j] = -acc->a[0].coefs[N_lvl2 - j] for j > 0
        for (int j = 1; j < N_LVL2; j++) begin
          result_a[j] = -acc[0][N_LVL2 - j];
        end
        
        // result->b = acc->a[1].coefs[0] + mu2
        result_b = acc[1][0] + mu2;
        
        sample_extract_done = 1'b1;
        result_valid = 1'b1;
        next_state = DONE;
      end
      
      DONE: begin
        done = 1'b1;
        next_state = IDLE;
      end
    endcase
  end

// ==============================================================================================
// Decomposition and NTT Interface Logic
// ==============================================================================================
  // The external product operation requires careful coordination with the NTT engine
  // This involves:
  // 1. Decomposing the TLWE sample into multiple integer polynomials
  // 2. Converting each to NTT domain
  // 3. Point-wise multiplication with BSK coefficients
  // 4. Accumulating results
  // 5. Converting back from NTT domain
  
  // Note: This is a simplified interface - the actual implementation would need
  // detailed state machines for managing the NTT pipeline and data flow

endmodule