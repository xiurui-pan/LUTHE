// ==============================================================================================
// Filename: wop_vertical_packing_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// WoP-PBS Vertical Packing Engine.
// This module implements the bigLut_20bit_lvl1() function from big_lut.cpp.
// 
// C++ Algorithm:
// 1. Convert LWE bit samples to GGSW format (done in previous stage)
// 2. CMux Tree: Build selection tree using GGSW samples
//    - Start with LUT entries in pools[0]
//    - For each bit d from 10 to 19: CMux(pools[i][j], pools[i][j<<1], pools[i][j<<1|1], tgsw_radixs[d])
// 3. Blind Rotation: Use remaining bits (0-9) for final rotation
//    - For each bit d from 0 to 9: CMux(rotate_lut, rotate_lut, rotate_lut * X^(-2^d), tgsw_radixs[d])
// 4. Sample Extraction: Extract final LWE result
// 5. Post-processing: Extract high bits using additional bootstrapping
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module wop_vertical_packing_engine
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import regf_common_param_pkg::*;
  import axi_if_glwe_axi_pkg::*;
#(
  parameter int MOD_Q_W = 32,
  parameter int MAX_BIT_WIDTH = 20,
  parameter int N_LVL1 = 1024,
  parameter int ELL_LVL1 = 3,
  parameter int K = 1  // k parameter for TLWE
)
(
  input  logic clk,
  input  logic s_rst_n,
  
  // Control interface
  input  logic start,
  input  logic [MAX_BIT_WIDTH-1:0] bit_width,
  output logic done,
  
  // Input: GGSW bit samples from circuit bootstrapping stage
  input  logic [REGF_ADDR_W-1:0] ggsw_samples_base_addr,
  input  logic ggsw_samples_ready,
  
  // Output: final result address
  input  logic [REGF_ADDR_W-1:0] result_addr,
  output logic result_ready,
  
  // Large LUT interface
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] lut_base_addr,
  output logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] lut_addr,
  output logic lut_req_vld,
  input  logic lut_req_rdy,
  input  logic lut_data_avail,
  input  logic [axi_if_glwe_axi_pkg::AXI4_DATA_W-1:0] lut_data,
  
  // RegFile interface
  output logic regf_rd_req_vld,
  input  logic regf_rd_req_rdy,
  output logic [REGF_RD_REQ_W-1:0] regf_rd_req,
  input  logic [REGF_COEF_NB-1:0] regf_rd_data_avail,
  input  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_rd_data,
  
  output logic regf_wr_req_vld,
  input  logic regf_wr_req_rdy,
  output logic [REGF_WR_REQ_W-1:0] regf_wr_req,
  output logic [REGF_COEF_NB-1:0] regf_wr_data_vld,
  input  logic [REGF_COEF_NB-1:0] regf_wr_data_rdy,
  output logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_wr_data
);

// ==============================================================================================
// Local Parameters
// ==============================================================================================
  localparam int CMUX_TREE_BITS = 10;  // Upper 10 bits for CMux tree
  localparam int BLIND_ROT_BITS = 10;  // Lower 10 bits for blind rotation
  localparam int MAX_POOL_ENTRIES = 1 << CMUX_TREE_BITS;  // 2^10 = 1024 entries

// ==============================================================================================
// State Machine
// ==============================================================================================
  typedef enum logic [3:0] {
    IDLE,
    LOAD_LUT_ENTRIES,         // Load initial LUT entries into pools[0]
    LOAD_GGSW_SAMPLES,        // Load GGSW bit samples
    CMUX_TREE_INIT,           // Initialize CMux tree construction
    CMUX_TREE_PROCESS,        // Process CMux tree (bits 10-19)
    BLIND_ROTATION_INIT,      // Initialize blind rotation
    BLIND_ROTATION_PROCESS,   // Process blind rotation (bits 0-9)
    SAMPLE_EXTRACT,           // Extract LWE sample from final TLWE
    POST_PROCESS,             // Post-processing bootstrapping
    WRITE_RESULT,             // Write final result
    DONE
  } state_e;

  state_e current_state, next_state;

// ==============================================================================================
// Internal Storage
// ==============================================================================================
  // Dual pools for CMux tree (ping-pong buffers)
  logic [1:0][MAX_POOL_ENTRIES-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] pools;
  
  // GGSW samples storage (20 bits worth)
  logic [MAX_BIT_WIDTH-1:0][ELL_LVL1-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] tgsw_radixs;
  
  // Working variables
  logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] rotate_lut;
  logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] tmp_mid;
  logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] tmp_result;
  logic [N_LVL1-1:0][MOD_Q_W-1:0] final_lwe_result;
  
  // Control signals
  logic [MAX_BIT_WIDTH-1:0] bit_counter;
  logic [MAX_POOL_ENTRIES-1:0] entry_counter;
  logic [31:0] lut_load_counter;
  logic pool_select;  // 0 or 1 for ping-pong
  
  // Stage completion flags
  logic lut_load_done;
  logic ggsw_load_done;
  logic cmux_tree_done;
  logic blind_rotation_done;
  logic sample_extract_done;
  logic post_process_done;

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      bit_counter <= '0;
      entry_counter <= '0;
      lut_load_counter <= '0;
      pool_select <= 1'b0;
    end else begin
      current_state <= next_state;
      
      case (current_state)
        LOAD_LUT_ENTRIES: begin
          if (lut_data_avail) begin
            lut_load_counter <= lut_load_counter + 1;
          end
        end
        
        CMUX_TREE_PROCESS: begin
          if (cmux_operation_done) begin
            bit_counter <= bit_counter + 1;
            pool_select <= ~pool_select;  // Ping-pong between pools
          end
        end
        
        BLIND_ROTATION_PROCESS: begin
          if (blind_rot_operation_done) begin
            bit_counter <= bit_counter + 1;
          end
        end
      endcase
    end
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    done = 1'b0;
    result_ready = 1'b0;
    
    // Interface defaults
    lut_req_vld = 1'b0;
    lut_addr = '0;
    regf_rd_req_vld = 1'b0;
    regf_rd_req = '0;
    regf_wr_req_vld = 1'b0;
    regf_wr_req = '0;
    regf_wr_data_vld = '0;
    regf_wr_data = '0;
    
    case (current_state)
      IDLE: begin
        if (start && ggsw_samples_ready) begin
          next_state = LOAD_LUT_ENTRIES;
        end
      end
      
      LOAD_LUT_ENTRIES: begin
        // Load initial LUT entries into pools[0]
        // LUT has 2^20 entries, but we only load 2^10 initially
        lut_req_vld = 1'b1;
        lut_addr = lut_base_addr + (lut_load_counter * (N_LVL1 * 4)); // 4 bytes per coefficient
        
        if (lut_req_rdy && lut_data_avail) begin
          // Store LUT data into pools[0][entry_counter]
          // This is simplified - actual implementation would parse the LUT data properly
          
          if (lut_load_counter >= MAX_POOL_ENTRIES) begin
            lut_load_done = 1'b1;
            next_state = LOAD_GGSW_SAMPLES;
          end
        end
      end
      
      LOAD_GGSW_SAMPLES: begin
        // Load GGSW samples from RegFile
        regf_rd_req_vld = 1'b1;
        regf_rd_req = {ggsw_samples_base_addr + bit_counter, 16'h0000};
        
        if (regf_rd_req_rdy && regf_rd_data_avail[0]) begin
          // Store GGSW data - this is simplified
          // Actual implementation would need to handle the full GGSW structure
          
          if (bit_counter >= bit_width - 1) begin
            ggsw_load_done = 1'b1;
            next_state = CMUX_TREE_INIT;
          end
        end
      end
      
      CMUX_TREE_INIT: begin
        bit_counter = CMUX_TREE_BITS;  // Start from bit 10
        pool_select = 1'b0;
        next_state = CMUX_TREE_PROCESS;
      end
      
      CMUX_TREE_PROCESS: begin
        // CMux Tree: for d = 10 to 19
        // CMux(&to[j], &from[j << 1], &from[j << 1 | 1], &tgsw_radixs[d])
        
        if (bit_counter < bit_width) begin
          // Perform CMux operations for current bit level
          int from_pool = pool_select;
          int to_pool = ~pool_select;
          int entries_at_level = 1 << (bit_width - 1 - bit_counter);
          
          for (int j = 0; j < entries_at_level; j++) begin
            // CMux operation: result = c ? in1 : in0
            // This implements TLwe32CMux_TGsw_lvl1 operation
            
            // Simplified CMux: result = in0 + c * (in1 - in0)
            // where c is the GGSW bit selector
            logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] diff, cmux_result;
            
            // Compute difference: diff = in1 - in0
            for (int k = 0; k <= K; k++) begin
              for (int n = 0; n < N_LVL1; n++) begin
                diff[k][n] = pools[from_pool][j << 1 | 1][k][n] - pools[from_pool][j << 1][k][n];
              end
            end
            
            // Multiply by GGSW selector (simplified)
            if (tgsw_bit_is_set(bit_counter)) begin
              cmux_result = diff; // c = 1, select in1
            end else begin
              cmux_result = '0;   // c = 0, select in0
            end
            
            // Add to base: result = in0 + c * diff
            for (int k = 0; k <= K; k++) begin
              for (int n = 0; n < N_LVL1; n++) begin
                pools[to_pool][j][k][n] = pools[from_pool][j << 1][k][n] + cmux_result[k][n];
              end
            end
          end
          
          if (bit_counter + 1 >= bit_width) begin
            cmux_tree_done = 1'b1;
            next_state = BLIND_ROTATION_INIT;
          end
        end
      end
      
      BLIND_ROTATION_INIT: begin
        // Initialize blind rotation
        // rotate_lut = pools[current_pool][0] (result of CMux tree)
        for (int i = 0; i <= K; i++) begin
          for (int j = 0; j < N_LVL1; j++) begin
            rotate_lut[i][j] = pools[pool_select][0][i][j];
          end
        end
        
        bit_counter = 0;  // Start from bit 0
        next_state = BLIND_ROTATION_PROCESS;
      end
      
      BLIND_ROTATION_PROCESS: begin
        // Blind Rotation: for d = 0 to 9
        // Compute: rotate_lut * X^(-2^d)
        // Then: CMux(tmp_result, rotate_lut, tmp_mid, tgsw_radixs[d])
        
        if (bit_counter < BLIND_ROT_BITS) begin
          int a = 1 << bit_counter;  // 2^d
          a = (2 * N_LVL1 - a) % (2 * N_LVL1);  // -2^d mod 2N
          
          // Multiply by X^a (polynomial rotation)
          for (int i = 0; i <= K; i++) begin
            polynomial_mul_by_xai(tmp_mid[i], rotate_lut[i], a);
          end
          
          // CMux operation
          if (tgsw_bit_is_set(bit_counter)) begin
            // Select tmp_mid
            for (int i = 0; i <= K; i++) begin
              for (int j = 0; j < N_LVL1; j++) begin
                tmp_result[i][j] = tmp_mid[i][j];
              end
            end
          end else begin
            // Select rotate_lut
            for (int i = 0; i <= K; i++) begin
              for (int j = 0; j < N_LVL1; j++) begin
                tmp_result[i][j] = rotate_lut[i][j];
              end
            end
          end
          
          // Update rotate_lut for next iteration
          for (int i = 0; i <= K; i++) begin
            for (int j = 0; j < N_LVL1; j++) begin
              rotate_lut[i][j] = tmp_result[i][j];
            end
          end
          
          if (bit_counter + 1 >= BLIND_ROT_BITS) begin
            blind_rotation_done = 1'b1;
            next_state = SAMPLE_EXTRACT;
          end
        end
      end
      
      SAMPLE_EXTRACT: begin
        // Extract LWE sample from final TLWE (rotate_lut)
        // This implements tLwe32ExtractSample_lvl1
        
        final_lwe_result[0] = rotate_lut[0][0];  // First coefficient of a[0]
        
        for (int j = 1; j < N_LVL1; j++) begin
          final_lwe_result[j] = -rotate_lut[0][N_LVL1 - j];  // Negated and reversed
        end
        
        // The b part comes from a[1][0]
        // final_lwe_result[N_LVL1] = rotate_lut[1][0]; // This would be the b part
        
        sample_extract_done = 1'b1;
        next_state = POST_PROCESS;
      end
      
      POST_PROCESS: begin
        // Post-processing: extract high bits using additional bootstrapping
        // result->b[0] += modSwitchToTorus32(2, FULL_MSG_SIZE);
        // TLwe32_Keyswitch_Bootstrapping_Extract_lvl1(result, env->predefinedTLwe32Luts.get_hi, result, FULL_MSG_SIZE, env);
        
        // This requires another PBS operation with the get_hi LUT
        // For now, we'll skip this complex step
        
        post_process_done = 1'b1;
        next_state = WRITE_RESULT;
      end
      
      WRITE_RESULT: begin
        // Write final result to RegFile
        regf_wr_req_vld = 1'b1;
        regf_wr_req = {result_addr, 16'h0000};
        regf_wr_data_vld[0] = 1'b1;
        regf_wr_data[0] = final_lwe_result[entry_counter];
        
        if (regf_wr_data_rdy[0]) begin
          if (entry_counter >= N_LVL1 - 1) begin
            result_ready = 1'b1;
            next_state = DONE;
          end else begin
            entry_counter = entry_counter + 1;
          end
        end
      end
      
      DONE: begin
        done = 1'b1;
        next_state = IDLE;
      end
    endcase
  end

// ==============================================================================================
// Helper Functions
// ==============================================================================================
  
  // Check if a bit in the GGSW sample is set (simplified)
  function automatic logic tgsw_bit_is_set(input logic [MAX_BIT_WIDTH-1:0] bit_pos);
    // This is a placeholder - actual implementation would decode the GGSW sample
    return 1'b0;  // Simplified
  endfunction
  
  // Polynomial multiplication by X^a
  function automatic void polynomial_mul_by_xai(
    output logic [N_LVL1-1:0][MOD_Q_W-1:0] result,
    input  logic [N_LVL1-1:0][MOD_Q_W-1:0] poly,
    input  int a
  );
    // Implement polynomial multiplication by X^a
    // This involves coefficient rotation with sign changes for X^N = -1
    for (int i = 0; i < N_LVL1; i++) begin
      int src_idx = (i - a + N_LVL1) % N_LVL1;
      if (i < a) begin
        result[i] = -poly[src_idx];  // Sign flip due to X^N = -1
      end else begin
        result[i] = poly[src_idx];
      end
    end
  endfunction

// ==============================================================================================
// Control Signals
// ==============================================================================================
  logic cmux_operation_done;
  logic blind_rot_operation_done;
  
  // These would be driven by the actual CMux and blind rotation logic
  assign cmux_operation_done = 1'b1;      // Placeholder
  assign blind_rot_operation_done = 1'b1; // Placeholder

endmodule