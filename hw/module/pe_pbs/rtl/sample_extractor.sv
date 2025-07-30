// ==============================================================================================
// Filename: sample_extractor.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// Sample Extractor for WoP-PBS.
// This module implements the sample extraction operation from the final TLWE accumulator
// to produce an LWE sample. This corresponds to the sample extraction logic in
// circuitBootstrapWoKS function.
//
// The extraction follows the rule:
// result->a[j] = -acc->a[0].coefs[N_lvl2 - j] for j > 0
// result->a[0] = acc->a[0].coefs[0]
// result->b = acc->a[1].coefs[0] + mu2
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module sample_extractor
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
#(
  parameter int MOD_Q_W = 32,
  parameter int N = 1024,
  parameter int ADDR_W = 11,
  parameter int N_W = $clog2(N)
)
(
  input  logic clk,
  input  logic s_rst_n,
  
  // Control interface
  input  logic start,
  input  logic [MOD_Q_W-1:0] mu_value,
  output logic done,
  
  // Input polynomial interface (from accum_bram_a)
  input  logic [ADDR_W-1:0] input_addr,
  input  logic [MOD_Q_W-1:0] input_data,
  
  // Output LWE sample
  output logic [N-1:0][MOD_Q_W-1:0] result
);

// ==============================================================================================
// Local Parameters
// ==============================================================================================
  localparam int N_ADDR_W = $clog2(N);
  localparam int MU2_W = MOD_Q_W;

// ==============================================================================================
// Internal State Machine
// ==============================================================================================
  typedef enum logic [2:0] {
    IDLE,
    READ_A0_COEFFS,
    READ_A1_COEFFS,
    EXTRACT_SAMPLE,
    DONE
  } state_e;

  state_e current_state, next_state;

// ==============================================================================================
// Internal Registers and Signals
// ==============================================================================================
  // Loop control
  logic [N_ADDR_W-1:0] coeff_counter;
  logic [N_ADDR_W-1:0] max_coeff_count;
  
  // Data storage for TLWE coefficients
  logic [N-1:0][MOD_Q_W-1:0] a0_coeffs; // a[0] coefficients
  logic [N-1:0][MOD_Q_W-1:0] a1_coeffs; // a[1] coefficients
  
  // Extraction parameters
  logic [MOD_Q_W-1:0] mu2_value; // mu/2
  logic [MOD_Q_W-1:0] b_value;   // b coefficient of LWE sample
  
  // Control signals
  logic read_a0_done;
  logic read_a1_done;
  logic extract_done;
  
  // Default output assignments
  logic done_next;

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      done <= 1'b0;
    end else begin
      current_state <= next_state;
      done <= done_next;
    end
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    done_next = 1'b0;
    
    // Default control signals
    read_a0_done = 1'b0;
    read_a1_done = 1'b0;
    extract_done = 1'b0;
    
    case (current_state)
      IDLE: begin
        if (start) begin
          next_state = READ_A0_COEFFS;
          coeff_counter = 0;
          max_coeff_count = N;
          mu2_value = mu_value >> 1; // mu/2
        end
      end
      
      READ_A0_COEFFS: begin
        // Read a[0] coefficients from accum_bram_a
        // These are stored in the first N coefficients
        a0_coeffs[coeff_counter] = input_data;
        
        coeff_counter = coeff_counter + 1;
        if (coeff_counter == max_coeff_count) begin
          read_a0_done = 1'b1;
          next_state = READ_A1_COEFFS;
          coeff_counter = 0;
        end
      end
      
      READ_A1_COEFFS: begin
        // Read a[1] coefficients from accum_bram_a
        // These are stored in the second N coefficients (offset by N)
        a1_coeffs[coeff_counter] = input_data;
        
        coeff_counter = coeff_counter + 1;
        if (coeff_counter == max_coeff_count) begin
          read_a1_done = 1'b1;
          next_state = EXTRACT_SAMPLE;
        end
      end
      
      EXTRACT_SAMPLE: begin
        // Extract LWE sample according to the rules:
        // result->a[0] = acc->a[0].coefs[0]
        // result->a[j] = -acc->a[0].coefs[N - j] for j > 0
        // result->b = acc->a[1].coefs[0] + mu2
        
        // Extract a coefficients
        for (int j = 0; j < N; j++) begin
          if (j == 0) begin
            result[j] = a0_coeffs[0];
          end else begin
            result[j] = -a0_coeffs[N - j];
          end
        end
        
        // Extract b coefficient
        b_value = a1_coeffs[0] + mu2_value;
        
        extract_done = 1'b1;
        next_state = DONE;
      end
      
      DONE: begin
        done_next = 1'b1;
        next_state = IDLE;
      end
    endcase
  end

endmodule 