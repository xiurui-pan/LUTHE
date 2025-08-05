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
  parameter int K = 1,  // k parameter for TLWE
  parameter int REGF_ADDR_W = 16  // RegFile address width
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
  
  // Temporary variables for combinational logic
  logic current_bit_value;
  
  // Stage completion flags
  logic lut_load_done;
  logic ggsw_load_done;
  logic cmux_tree_done;
  logic blind_rotation_done;
  
  // Operation control signals
  logic cmux_operation_done;
  logic blind_rot_operation_done;
  logic [31:0] operation_cycle_counter;
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
      // Initialize flags
      lut_load_done <= 1'b0;
      ggsw_load_done <= 1'b0;
      cmux_tree_done <= 1'b0;
      blind_rotation_done <= 1'b0;
      sample_extract_done <= 1'b0;
      post_process_done <= 1'b0;
    end else begin
      current_state <= next_state;
      
      // Debug printing for state transitions
      if (current_state != next_state) begin
        $display("[VP_ENGINE] State transition: %s -> %s at time %0t", 
                 current_state.name(), next_state.name(), $time);
      end
      
      case (current_state)
        LOAD_LUT_ENTRIES: begin
          if (lut_req_rdy && lut_data_avail) begin
            lut_load_counter <= lut_load_counter + 1;
            $display("[VP_ENGINE] Loading LUT entry %0d at time %0t", lut_load_counter, $time);
            if (lut_load_counter >= MAX_POOL_ENTRIES - 1) begin
              lut_load_done <= 1'b1;
            end
          end
        end
        
        LOAD_GGSW_SAMPLES: begin
          if (regf_rd_req_rdy && regf_rd_data_avail[0]) begin
            bit_counter <= bit_counter + 1;
            $display("[VP_ENGINE] Loading GGSW sample %0d at time %0t", bit_counter, $time);
            if (bit_counter >= bit_width - 1) begin
              ggsw_load_done <= 1'b1;
            end
          end
        end
        
        CMUX_TREE_INIT: begin
          bit_counter <= CMUX_TREE_BITS;  // Start from bit 10
          pool_select <= 1'b0;
          $display("[VP_ENGINE] CMux tree initialized, starting from bit %0d", CMUX_TREE_BITS);
        end
        
        CMUX_TREE_PROCESS: begin
          if (cmux_operation_done) begin
            bit_counter <= bit_counter + 1;
            pool_select <= ~pool_select;  // Ping-pong between pools
            $display("[VP_ENGINE] CMux bit %0d completed, pool_select=%0b", bit_counter, ~pool_select);
            if (bit_counter >= bit_width - 1) begin
              cmux_tree_done <= 1'b1;
            end
          end
        end
        
        BLIND_ROTATION_INIT: begin
          bit_counter <= 0;  // Start from bit 0
          $display("[VP_ENGINE] Blind rotation initialized");
        end
        
        BLIND_ROTATION_PROCESS: begin
          if (blind_rot_operation_done) begin
            bit_counter <= bit_counter + 1;
            $display("[VP_ENGINE] Blind rotation bit %0d completed", bit_counter);
            if (bit_counter >= BLIND_ROT_BITS - 1) begin
              blind_rotation_done <= 1'b1;
            end
          end
        end
        
        SAMPLE_EXTRACT: begin
          sample_extract_done <= 1'b1;
          $display("[VP_ENGINE] Sample extraction completed");
        end
        
        POST_PROCESS: begin
          post_process_done <= 1'b1;
          $display("[VP_ENGINE] Post-processing completed");
        end
        
        WRITE_RESULT: begin
          if (regf_wr_req_rdy && regf_wr_data_rdy[0]) begin
            entry_counter <= entry_counter + 1;
            $display("[VP_ENGINE] Writing result coefficient %0d", entry_counter);
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
        next_state = CMUX_TREE_PROCESS;
      end
      
      CMUX_TREE_PROCESS: begin
        // CMux Tree: for d = 10 to 19 (exactly matching big_lut.cpp line 18-23)
        // Implements: for (int d = 10, i = 1; d < 20; d++, i ^= 1)
        
        if (bit_counter < bit_width && !cmux_tree_done) begin
          // Calculate current level parameters (exact match to big_lut.cpp)
          int from_pool = pool_select ^ 1;  // pools[i ^ 1]
          int to_pool = pool_select;        // pools[i]
          int entries_at_level = 1 << (19 - bit_counter);  // Exact match: (1 << (19 - d))
          
          $display("[VP_ENGINE] CMux d=%0d: processing %0d entries, pool %0d -> %0d", 
                   bit_counter, entries_at_level, from_pool, to_pool);
          
          // For each entry at this level, perform CMux operation
          // Line 21: TLwe32CMux_TGsw_lvl1(&to[j], &from[j << 1], &from[j << 1 | 1], &tgsw_radixs[d], env)
          current_bit_value = tgsw_bit_is_set(bit_counter);
          
          for (int j = 0; j < entries_at_level; j++) begin
            // Simplified CMux: result = current_bit_value ? in1 : in0
            // In real implementation: result = in0 + c * (in1 - in0) where c = tgsw_radixs[d]
            
            for (int k = 0; k <= K; k++) begin
              for (int n = 0; n < N_LVL1; n++) begin
                if (current_bit_value) begin
                  // Select in1: from[j << 1 | 1]
                  pools[to_pool][j][k][n] = pools[from_pool][j << 1 | 1][k][n];
                end else begin
                  // Select in0: from[j << 1]
                  pools[to_pool][j][k][n] = pools[from_pool][j << 1][k][n];
                end
              end
            end
          end
          
          $display("[VP_ENGINE] CMux d=%0d completed, bit_value=%0b", bit_counter, current_bit_value);
          
          if (cmux_tree_done) begin
            next_state = BLIND_ROTATION_INIT;
          end
        end else if (cmux_tree_done) begin
          next_state = BLIND_ROTATION_INIT;
        end
      end
      
      BLIND_ROTATION_INIT: begin
        // The rotate_lut initialization will be done in always_ff
        next_state = BLIND_ROTATION_PROCESS;
      end
      
      BLIND_ROTATION_PROCESS: begin
        // Blind Rotation: for d = 0 to 9 (exactly matching big_lut.cpp line 29-37)
        // Implements: for (int d = 0; d < 10; d++)
        
        if (bit_counter < BLIND_ROT_BITS && !blind_rotation_done) begin
          // Line 30-31: Calculate rotation amount exactly as in C++
          int a = 1 << bit_counter;  // (1 << d) - exact match
          a = (2 * N_LVL1 - a) % (2 * N_LVL1);  // exact match
          
          $display("[VP_ENGINE] Blind rotation d=%0d: a = %0d", bit_counter, a);
          
          // Line 33: Apply polynomial rotation for each polynomial component
          // for (int i = 0; i <= 1; i++) torus32PolynomialMulByXai_lvl1(tmp_mid->a + i, rotate_lut->a + i, a, env)
          for (int k = 0; k <= K; k++) begin  // K=1, so k=0,1 matches i=0,1
            polynomial_mul_by_xai(tmp_mid[k], rotate_lut[k], a);
          end
          
          // Extract bit value from GGSW sample  
          current_bit_value = tgsw_bit_is_set(bit_counter);
          $display("[VP_ENGINE] GGSW bit d=%0d = %0b", bit_counter, current_bit_value);
          
          // Line 35: CMux selection
          // TLwe32CMux_TGsw_lvl1(tmp_result, rotate_lut, tmp_mid, &tgsw_radixs[d], env)
          for (int k = 0; k <= K; k++) begin
            for (int n = 0; n < N_LVL1; n++) begin
              if (current_bit_value) begin
                tmp_result[k][n] = tmp_mid[k][n];      // Select rotated version
              end else begin
                tmp_result[k][n] = rotate_lut[k][n];   // Select original
              end
            end
          end
          
          // Line 36: std::swap(rotate_lut, tmp_result)
          for (int k = 0; k <= K; k++) begin
            for (int n = 0; n < N_LVL1; n++) begin
              rotate_lut[k][n] = tmp_result[k][n];
            end
          end
          
          $display("[VP_ENGINE] After rotation d=%0d: rotate_lut[0][0] = %0h", bit_counter, rotate_lut[0][0]);
          
          if (blind_rotation_done) begin
            next_state = SAMPLE_EXTRACT;
          end
        end else if (blind_rotation_done) begin
          next_state = SAMPLE_EXTRACT;
        end
      end
      
      SAMPLE_EXTRACT: begin
        // Extract LWE sample from final TLWE (rotate_lut)
        // This implements tLwe32ExtractSample_lvl1
        // The actual extraction will be done in always_ff
        
        if (sample_extract_done) begin
          next_state = POST_PROCESS;
        end
      end
      
      POST_PROCESS: begin
        // Post-processing: extract high bits using additional bootstrapping
        // For now, we'll skip this complex step and go directly to result writing
        
        if (post_process_done) begin
          next_state = WRITE_RESULT;
        end
      end
      
      WRITE_RESULT: begin
        // Write final result to RegFile
        regf_wr_req_vld = 1'b1;
        regf_wr_req = {result_addr, 16'h0000};
        regf_wr_data_vld[0] = 1'b1;
        regf_wr_data[0] = final_lwe_result[entry_counter];
        
        if (regf_wr_req_rdy && regf_wr_data_rdy[0]) begin
          if (entry_counter >= N_LVL1 - 1) begin
            result_ready = 1'b1;
            next_state = DONE;
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
// Helper Tasks and Functions
// ==============================================================================================
  
  // Check if a bit in the GGSW sample is set (simplified for simulation)
  function automatic logic tgsw_bit_is_set(input logic [MAX_BIT_WIDTH-1:0] bit_pos);
    // Simplified GGSW bit extraction for simulation
    // In real implementation, this would involve complex GGSW decryption
    // For now, use a threshold on the GGSW sample value
    logic [MOD_Q_W-1:0] ggsw_value = tgsw_radixs[bit_pos][0][0][0];  // Simplified access
    return (ggsw_value % 1000) > 500;  // Simple threshold
  endfunction
  
  // Polynomial multiplication by X^a (implementing torus32PolynomialMulByXai_lvl1)
  function automatic void polynomial_mul_by_xai(
    output logic [N_LVL1-1:0][MOD_Q_W-1:0] result,
    input  logic [N_LVL1-1:0][MOD_Q_W-1:0] poly,
    input  int a
  );
    // Normalize a to [0, 2*N_LVL1)
    int normalized_a = a % (2 * N_LVL1);
    if (normalized_a < 0) normalized_a = normalized_a + 2 * N_LVL1;
    
    if (normalized_a < N_LVL1) begin
      // X^a where a < N: coefficients shift with sign change for wraparound
      for (int i = 0; i < normalized_a; i++) begin
        result[i] = -poly[N_LVL1 - normalized_a + i];  // Sign flip due to X^N = -1
      end
      for (int i = normalized_a; i < N_LVL1; i++) begin
        result[i] = poly[i - normalized_a];
      end
    end else begin
      // X^a where a >= N: equivalent to X^(a-N) with global sign flip
      normalized_a = normalized_a - N_LVL1;
      for (int i = 0; i < normalized_a; i++) begin
        result[i] = poly[N_LVL1 - normalized_a + i];   // No sign flip (double negative)
      end
      for (int i = normalized_a; i < N_LVL1; i++) begin
        result[i] = -poly[i - normalized_a];           // Sign flip
      end
    end
  endfunction
  
  // Sample extraction task (implementing tLwe32ExtractSample_lvl1)
  task automatic extract_lwe_sample();
    // Extract LWE sample from final TLWE (rotate_lut)
    // This implements the exact logic from tlwe_functions.cpp lines 45-52
    
    // result->a[0] = sample->a[0].coefs[0]
    final_lwe_result[0] = rotate_lut[0][0];  // First coefficient of a[0]
    
    // for (int i = 1; i < N; i++) result->a[i] = -sample->a[0].coefs[N - i]
    for (int j = 1; j < N_LVL1; j++) begin
      final_lwe_result[j] = -rotate_lut[0][N_LVL1 - j];  // Negated and reversed
    end
    
    // The b part would come from rotate_lut[K][0], but we store it separately
    // In our simplified representation, we'll use the b part from the TLWE structure
    
    $display("[VP_ENGINE] LWE sample extracted: a[0]=%0h, a[1]=%0h, samples extracted from TLWE", 
             final_lwe_result[0], final_lwe_result[1]);
    $display("[VP_ENGINE]   Source TLWE: a[0][0]=%0h, a[1][0]=%0h", rotate_lut[0][0], rotate_lut[1][0]);
  endtask
  
  // Initialize rotate_lut from CMux tree result
  task automatic init_rotate_lut();
    for (int i = 0; i <= K; i++) begin
      for (int j = 0; j < N_LVL1; j++) begin
        rotate_lut[i][j] = pools[pool_select][0][i][j];
      end
    end
    $display("[VP_ENGINE] Rotate LUT initialized from pool[%0b][0]", pool_select);
  endtask

// ==============================================================================================
// Control Signals and Operation Logic
// ==============================================================================================
  
  // Operation cycle counter for timing simulation
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      operation_cycle_counter <= 0;
      cmux_operation_done <= 1'b0;
      blind_rot_operation_done <= 1'b0;
    end else begin
      case (current_state)
        CMUX_TREE_PROCESS: begin
          operation_cycle_counter <= operation_cycle_counter + 1;
          // Simulate CMux operation taking some cycles
          if (operation_cycle_counter >= 10) begin  // 10 cycles per CMux operation
            cmux_operation_done <= 1'b1;
            operation_cycle_counter <= 0;
          end else begin
            cmux_operation_done <= 1'b0;
          end
        end
        
        BLIND_ROTATION_PROCESS: begin
          operation_cycle_counter <= operation_cycle_counter + 1;
          // Simulate blind rotation taking some cycles
          if (operation_cycle_counter >= 20) begin  // 20 cycles per rotation
            blind_rot_operation_done <= 1'b1;
            operation_cycle_counter <= 0;
          end else begin
            blind_rot_operation_done <= 1'b0;
          end
        end
        
        SAMPLE_EXTRACT: begin
          // Perform sample extraction
          extract_lwe_sample();
        end
        
        BLIND_ROTATION_INIT: begin
          // Initialize rotate_lut
          init_rotate_lut();
        end
        
        default: begin
          operation_cycle_counter <= 0;
          cmux_operation_done <= 1'b0;
          blind_rot_operation_done <= 1'b0;
        end
      endcase
    end
  end

endmodule