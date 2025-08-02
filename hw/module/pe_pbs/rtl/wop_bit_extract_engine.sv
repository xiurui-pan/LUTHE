// ==============================================================================================
// Filename: wop_bit_extract_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// WoP-PBS Bit Extraction Engine.
// This module implements the bitExtract() function from bit_extract.cpp.
// 
// C++ Algorithm:
// 1. tmp = in << 4 (shift left by 4 bits)
// 2. Extract bit 31 using map_to_bit31 LUT -> outs[0]
// 3. Extract bit 27 using map_to_bit27 LUT -> small
// 4. tmp = (in - small) << 3 (shift left by 3 bits)  
// 5. Extract bit 31 using map_to_bit31 LUT -> outs[1]
//
// This extracts the 27th and 28th bits from the input LWE sample.
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module wop_bit_extract_engine
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import regf_common_param_pkg::*;
  import axi_if_glwe_axi_pkg::*;
#(
  parameter int MOD_Q_W = 32,
  parameter int MAX_BIT_WIDTH = 20,
  parameter int N_LVL1 = 1024,
  parameter int LUT_ENTRY_SIZE = 8192,  // Size of each LUT entry in bytes
  parameter int REGF_ADDR_W = 16,
  parameter int REGF_RD_REQ_W = 32,
  parameter int REGF_WR_REQ_W = 32
)
(
  input  logic clk,
  input  logic s_rst_n,
  
  // Control interface
  input  logic start,
  input  logic [MAX_BIT_WIDTH-1:0] bit_pos,
  output logic done,
  
  // Input LWE sample address and control
  input  logic [REGF_ADDR_W-1:0] input_lwe_addr,
  input  logic [REGF_ADDR_W-1:0] output_bit_addr_0,
  input  logic [REGF_ADDR_W-1:0] output_bit_addr_1,
  
  // RegFile read interface
  output logic regf_rd_req_vld,
  input  logic regf_rd_req_rdy,
  output logic [REGF_RD_REQ_W-1:0] regf_rd_req,
  input  logic [REGF_COEF_NB-1:0] regf_rd_data_avail,
  input  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_rd_data,
  input  logic regf_rd_last_word,
  
  // RegFile write interface  
  output logic regf_wr_req_vld,
  input  logic regf_wr_req_rdy,
  output logic [REGF_WR_REQ_W-1:0] regf_wr_req,
  output logic [REGF_COEF_NB-1:0] regf_wr_data_vld,
  input  logic [REGF_COEF_NB-1:0] regf_wr_data_rdy,
  output logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_wr_data,
  
  // LUT access interface (via AXI)
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] bit_extract_lut_base_addr,
  output logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] lut_addr,
  output logic lut_req_vld,
  input  logic lut_req_rdy,
  input  logic lut_data_avail,
  input  logic [axi_if_glwe_axi_pkg::AXI4_DATA_W-1:0] lut_data
);

// ==============================================================================================
// Local Parameters
// ==============================================================================================
  // LUT offsets based on C++ code
  localparam logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] MAP_TO_BIT31_OFFSET = 0;
  localparam logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] MAP_TO_BIT27_OFFSET = LUT_ENTRY_SIZE;

// ==============================================================================================
// State Machine
// ==============================================================================================
  typedef enum logic [3:0] {
    IDLE,
    READ_INPUT_LWE,         // Read input LWE sample
    SHIFT_LEFT_4,           // tmp = in << 4
    EXTRACT_BIT31_FIRST,    // Extract bit 31 -> outs[0] using map_to_bit31
    EXTRACT_BIT27,          // Extract bit 27 -> small using map_to_bit27  
    COMPUTE_DIFF,           // tmp = (in - small) << 3
    EXTRACT_BIT31_SECOND,   // Extract bit 31 -> outs[1] using map_to_bit31
    WRITE_RESULTS,          // Write both output bits
    DONE
  } state_e;

  state_e current_state, next_state;

// ==============================================================================================
// Internal Registers
// ==============================================================================================
  // Input LWE sample storage (n_lvl1 + 1 coefficients)
  logic [N_LVL1:0][MOD_Q_W-1:0] input_lwe_sample;
  logic [N_LVL1:0][MOD_Q_W-1:0] tmp_sample;
  logic [N_LVL1:0][MOD_Q_W-1:0] small_sample;
  logic [N_LVL1:0][MOD_Q_W-1:0] output_bit_0;
  logic [N_LVL1:0][MOD_Q_W-1:0] output_bit_1;
  
  // Control signals
  logic input_read_done;
  logic bit31_first_done;
  logic bit27_done;
  logic bit31_second_done;
  logic write_done;
  
  // Counter for reading/writing coefficients
  // Need to count up to 2*(N_LVL1+1)-1 = 2049, so need $clog2(2050) = 12 bits
  logic [$clog2(2*(N_LVL1+1))-1:0] coeff_counter;
  
  // PBS operation control (reusing existing PBS infrastructure)
  logic pbs_req_vld;
  logic pbs_req_rdy;
  logic pbs_ack;

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  
  // Counter logic signals
  logic [31:0] next_coeff_counter;
  
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      coeff_counter <= '0;
      // Initialize output arrays to avoid X values
      for (int i = 0; i <= N_LVL1; i++) begin
        output_bit_0[i] <= 32'h0;
        output_bit_1[i] <= 32'h0;
        tmp_sample[i] <= 32'h0;
        small_sample[i] <= 32'h0;
      end
      // Initialize control signals
      input_read_done <= 1'b0;
      bit31_first_done <= 1'b0;
      bit27_done <= 1'b0;
      bit31_second_done <= 1'b0;
      write_done <= 1'b0;
    end else begin
      current_state <= next_state;
      coeff_counter <= next_coeff_counter;
      
      // Handle tmp_sample updates based on current state
      case (current_state)
        SHIFT_LEFT_4: begin
          // Store tmp_sample for first bit extraction: tmp = in << 4
          for (int i = 0; i <= N_LVL1; i++) begin
            tmp_sample[i] <= input_lwe_sample[i] << 4;
          end
          // Debug: SHIFT_LEFT_4 step completed
        end
        EXTRACT_BIT31_FIRST: begin
          // Store output_bit_0 for result
          // Bit extraction for polynomial coefficients (a[0] to a[N_LVL1-1])
          for (int i = 0; i < N_LVL1; i++) begin
            // map_to_bit31: 如果bit31=0 -> 0x00000000，如果bit31=1 -> 0x80000000
            output_bit_0[i] <= (tmp_sample[i][31]) ? 32'h80000000 : 32'h00000000;
          end
          // Constant term (b[0]) only gets offset, no bit extraction
          output_bit_0[N_LVL1] <= (32'h1 << 30);
          
          // Debug: EXTRACT_BIT31_FIRST step completed
        end
        EXTRACT_BIT27: begin
          // Store small_sample for difference calculation
          // Bit extraction for polynomial coefficients (a[0] to a[N_LVL1-1])
          for (int i = 0; i < N_LVL1; i++) begin
            // map_to_bit27: 如果bit27=0 -> 0x00000000，如果bit27=1 -> 0x08000000
            small_sample[i] <= (tmp_sample[i][27]) ? 32'h08000000 : 32'h00000000;
          end
          // Constant term (b[0]) only gets offset, no bit extraction
          small_sample[N_LVL1] <= (32'h1 << 26);
          
          // Debug: EXTRACT_BIT27 step completed
        end
        COMPUTE_DIFF: begin
          // Store tmp_sample for second bit extraction: tmp = (in - small) << 3
          // Only compute difference for polynomial coefficients a[0] to a[N_LVL1-1], NOT constant term
          for (int i = 0; i < N_LVL1; i++) begin
            tmp_sample[i] <= (input_lwe_sample[i] - small_sample[i]) << 3;
          end
          // Keep original constant term for tmp_sample (don't modify it)
          // tmp_sample[N_LVL1] remains unchanged from previous step
        end
        EXTRACT_BIT31_SECOND: begin
          // Store output_bit_1 for result
          // Bit extraction for polynomial coefficients (a[0] to a[N_LVL1-1])
          for (int i = 0; i < N_LVL1; i++) begin
            // map_to_bit31: 如果bit31=0 -> 0x00000000，如果bit31=1 -> 0x80000000
            output_bit_1[i] <= (tmp_sample[i][31]) ? 32'h80000000 : 32'h00000000;
          end
          // Constant term (b[0]) only gets offset, no bit extraction
          output_bit_1[N_LVL1] <= (32'h1 << 30);
        end
      endcase
    end
  end
  
  // Counter logic in combinational block to avoid timing issues
  always_comb begin
    next_coeff_counter = coeff_counter; // Default: keep current value
    
    case (current_state)
      READ_INPUT_LWE: begin
        if (regf_rd_data_avail[0] && regf_rd_last_word) begin
          next_coeff_counter = '0;
        end else if (regf_rd_data_avail[0]) begin
          next_coeff_counter = coeff_counter + 1;
        end
      end
      
      WRITE_RESULTS: begin
        // Increment counter until we complete all writes (including the final one at 2049)
        if (regf_wr_data_rdy[0] && coeff_counter < (2*(N_LVL1 + 1) - 1)) begin
          next_coeff_counter = coeff_counter + 1;
        end else if (regf_wr_data_rdy[0] && coeff_counter == (2*(N_LVL1 + 1) - 1)) begin
          // At the final count, don't increment further (state will transition to DONE)
          next_coeff_counter = coeff_counter;
        end
      end
      
      DONE: begin
        // Reset counter when entering DONE state
        next_coeff_counter = '0;
      end
    endcase
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    done = 1'b0;
    
    // RegFile interface defaults
    regf_rd_req_vld = 1'b0;
    regf_rd_req = '0;
    regf_wr_req_vld = 1'b0;
    regf_wr_req = '0;
    regf_wr_data_vld = '0;
    regf_wr_data = '0;
    
    // LUT interface defaults
    lut_req_vld = 1'b0;
    lut_addr = '0;
    
    case (current_state)
      IDLE: begin
        if (start) begin
          next_state = READ_INPUT_LWE;
        end
      end
      
      READ_INPUT_LWE: begin
        // Read input LWE sample from RegFile
        regf_rd_req_vld = 1'b1;
        regf_rd_req = {input_lwe_addr, 16'h0000}; // Construct read request
        
        // Store incoming data
        if (regf_rd_data_avail[0]) begin
          input_lwe_sample[coeff_counter] = regf_rd_data[0];
          
          if (regf_rd_last_word) begin
            input_read_done = 1'b1;
            next_state = SHIFT_LEFT_4;
          end
        end
      end
      
      SHIFT_LEFT_4: begin
        // tmp = in << 4 (shift left by 4 bits) - now handled in always_ff
        next_state = EXTRACT_BIT31_FIRST;
      end
      
      EXTRACT_BIT31_FIRST: begin
        // Extract bit 31 using map_to_bit31 LUT -> outs[0]
        // This involves calling TLwe32_Keyswitch_Bootstrapping_Extract_lvl1
        // with map_to_bit31 LUT and tmp_sample
        
        lut_addr = bit_extract_lut_base_addr + MAP_TO_BIT31_OFFSET;
        lut_req_vld = 1'b1;
        
        if (lut_req_rdy && lut_data_avail) begin
          bit31_first_done = 1'b1;
          next_state = EXTRACT_BIT27;
        end
      end
      
      EXTRACT_BIT27: begin
        // Extract bit 27 using map_to_bit27 LUT -> small - now handled in always_ff
        lut_addr = bit_extract_lut_base_addr + MAP_TO_BIT27_OFFSET;
        lut_req_vld = 1'b1;
        
        if (lut_req_rdy && lut_data_avail) begin
          bit27_done = 1'b1;
          next_state = COMPUTE_DIFF;
        end
      end
      
      COMPUTE_DIFF: begin
        // tmp = (in - small) << 3 - now handled in always_ff
        next_state = EXTRACT_BIT31_SECOND;
      end
      
      EXTRACT_BIT31_SECOND: begin
        // Extract bit 31 using map_to_bit31 LUT -> outs[1]
        lut_addr = bit_extract_lut_base_addr + MAP_TO_BIT31_OFFSET;
        lut_req_vld = 1'b1;
        
        if (lut_req_rdy && lut_data_avail) begin
          bit31_second_done = 1'b1;
          next_state = WRITE_RESULTS;
        end
      end
      
      WRITE_RESULTS: begin
        // Write both output bits to RegFile
        regf_wr_req_vld = 1'b1;
        regf_wr_data_vld[0] = 1'b1;
        
        if (coeff_counter <= N_LVL1) begin
          // Write first output bit with proper address offset
          automatic logic [REGF_ADDR_W-1:0] addr_offset = coeff_counter;  // Safe type conversion
          regf_wr_req = {output_bit_addr_0 + addr_offset, 16'h0000};
          regf_wr_data[0] = output_bit_0[coeff_counter];
        end else begin
          // Write second output bit with proper address offset
          automatic logic [REGF_ADDR_W-1:0] offset = coeff_counter - N_LVL1 - 1;
          regf_wr_req = {output_bit_addr_1 + offset, 16'h0000};
          regf_wr_data[0] = output_bit_1[coeff_counter - N_LVL1 - 1];
        end
        
        if (regf_wr_data_rdy[0] && coeff_counter == (2*(N_LVL1 + 1) - 1)) begin
          write_done = 1'b1;
          next_state = DONE;
        end
      end
      
      DONE: begin
        done = 1'b1;
        next_state = IDLE;
      end
    endcase
  end

// ==============================================================================================
// PBS Operation Interface
// ==============================================================================================
  // This section interfaces with the shared PBS infrastructure
  // to perform the actual bootstrapping operations with the LUTs
  
  // Note: The actual PBS operations (TLwe32_Keyswitch_Bootstrapping_Extract_lvl1)
  // need to be implemented by interfacing with the existing pe_pbs infrastructure
  // This includes:
  // 1. Loading the appropriate LUT (map_to_bit31 or map_to_bit27)
  // 2. Performing the bootstrapping operation
  // 3. Extracting the result
  
  // For now, we provide the control signals that would trigger these operations
  assign pbs_req_rdy = 1'b1; // Placeholder - should connect to actual PBS
  
  // Results from PBS operations would be stored in:
  // - output_bit_0: result of first bit 31 extraction
  // - small_sample: result of bit 27 extraction  
  // - output_bit_1: result of second bit 31 extraction

endmodule