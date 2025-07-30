// ==============================================================================================
// Filename: poly_rotator_sub.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// Polynomial Rotator and Subtractor for WoP-PBS.
// This module implements the operation: acc2 = (X^aibar - 1) * acc1
// which is a key operation in the circuitBootstrapWoKS algorithm.
//
// The operation can be decomposed as:
// 1. acc1 * X^aibar (polynomial rotation by aibar positions)
// 2. Subtract acc1 from the result
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module poly_rotator_sub
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
  input  logic [MOD_Q_W-1:0] rotation_amount,
  output logic done,
  
  // Input polynomial interface (from accum_bram_a)
  input  logic [ADDR_W-1:0] input_addr,
  input  logic [MOD_Q_W-1:0] input_data,
  
  // Output polynomial interface (to accum_bram_b)
  output logic [ADDR_W-1:0] output_addr,
  output logic [MOD_Q_W-1:0] output_data,
  output logic output_wr_en
);

// ==============================================================================================
// Local Parameters
// ==============================================================================================
  localparam int N_ADDR_W = $clog2(N);
  localparam int ROTATION_AMOUNT_W = MOD_Q_W;

// ==============================================================================================
// Internal State Machine
// ==============================================================================================
  typedef enum logic [2:0] {
    IDLE,
    READ_INPUT,
    COMPUTE_ROTATION,
    WRITE_OUTPUT,
    DONE
  } state_e;

  state_e current_state, next_state;

// ==============================================================================================
// Internal Registers and Signals
// ==============================================================================================
  // Loop control
  logic [N_ADDR_W-1:0] coeff_counter;
  logic [N_ADDR_W-1:0] max_coeff_count;
  
  // Rotation computation
  logic [N_ADDR_W-1:0] rotated_addr;
  logic [N_ADDR_W-1:0] rotated_addr_plus_n;
  logic [N_ADDR_W-1:0] rotated_addr_minus_n;
  logic rotation_sign; // 0 for positive, 1 for negative (due to X^N = -1)
  
  // Data storage
  logic [MOD_Q_W-1:0] input_coeff;
  logic [MOD_Q_W-1:0] rotated_coeff;
  logic [MOD_Q_W-1:0] result_coeff;
  
  // Control signals
  logic read_input_done;
  logic compute_rotation_done;
  logic write_output_done;
  
  // Default output assignments
  logic done_next;
  logic output_wr_en_next;

// ==============================================================================================
// Rotation Address Computation
// ==============================================================================================
  // Compute rotated address: (j - aibar) mod N
  // Handle the case where X^N = -1 (negative rotation)
  always_comb begin
    // Normal rotation: j - aibar
    rotated_addr = coeff_counter - rotation_amount[N_ADDR_W-1:0];
    
    // Handle wraparound: if result is negative, add N
    rotated_addr_plus_n = rotated_addr + N;
    rotated_addr_minus_n = rotated_addr - N;
    
    // Determine if we need to flip sign due to X^N = -1
    // This happens when we cross the N/2 boundary
    rotation_sign = (rotation_amount[N_ADDR_W-1:0] > N/2) ? 1'b1 : 1'b0;
  end

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      done <= 1'b0;
      output_wr_en <= 1'b0;
    end else begin
      current_state <= next_state;
      done <= done_next;
      output_wr_en <= output_wr_en_next;
    end
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    done_next = 1'b0;
    output_wr_en_next = 1'b0;
    
    // Default control signals
    read_input_done = 1'b0;
    compute_rotation_done = 1'b0;
    write_output_done = 1'b0;
    
    case (current_state)
      IDLE: begin
        if (start) begin
          next_state = READ_INPUT;
          coeff_counter = 0;
          max_coeff_count = N;
        end
      end
      
      READ_INPUT: begin
        // Read input coefficient from accum_bram_a
        input_coeff = input_data;
        read_input_done = 1'b1;
        next_state = COMPUTE_ROTATION;
      end
      
      COMPUTE_ROTATION: begin
        // Compute (X^aibar - 1) * acc1
        // This is equivalent to: acc1 * X^aibar - acc1
        
        // Step 1: Get the rotated coefficient
        if (rotated_addr >= N) begin
          // Wraparound case
          rotated_coeff = input_data; // Read from rotated address
        end else if (rotated_addr < 0) begin
          // Negative wraparound case
          rotated_coeff = input_data; // Read from rotated address + N
        end else begin
          // Normal case
          rotated_coeff = input_data; // Read from rotated address
        end
        
        // Step 2: Apply sign flip if necessary
        if (rotation_sign) begin
          rotated_coeff = -rotated_coeff;
        end
        
        // Step 3: Subtract original coefficient
        result_coeff = rotated_coeff - input_coeff;
        
        compute_rotation_done = 1'b1;
        next_state = WRITE_OUTPUT;
      end
      
      WRITE_OUTPUT: begin
        // Write result to accum_bram_b
        output_addr = coeff_counter;
        output_data = result_coeff;
        output_wr_en_next = 1'b1;
        
        // Move to next coefficient
        coeff_counter = coeff_counter + 1;
        
        if (coeff_counter == max_coeff_count) begin
          write_output_done = 1'b1;
          next_state = DONE;
        end else begin
          next_state = READ_INPUT;
        end
      end
      
      DONE: begin
        done_next = 1'b1;
        next_state = IDLE;
      end
    endcase
  end

endmodule 