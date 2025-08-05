// ==============================================================================================
// Filename: tb_wop_vertical_packing_engine.sv  
// ----------------------------------------------------------------------------------------------
// Description:
//
// Testbench for WoP-PBS Vertical Packing Engine
// This testbench validates the bigLut_20bit_lvl1() algorithm implementation
//
// Test Strategy:
// 1. Generate 20-bit GGSW bit samples (simulating circuit bootstrap output)
// 2. Create LUT table with known values for verification  
// 3. Use service simulators for GGSW external product and polynomial operations
// 4. Compare RTL results with C++ golden reference
//
// Author: Ray Pan
// Date:   July 14, 2025
// ==============================================================================================

`timescale 1ns / 1ps

module tb_wop_vertical_packing_engine
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import regf_common_param_pkg::*;
  import axi_if_glwe_axi_pkg::*;
();

// ==============================================================================================
// Parameters
// ==============================================================================================
  localparam int MOD_Q_W = 32;
  localparam int MAX_BIT_WIDTH = 20;
  localparam int N_LVL1 = 1024;
  localparam int ELL_LVL1 = 3;
  localparam int K = 1;
  localparam int LUT_SIZE = 1024;  // 2^10
  localparam int REGF_ADDR_W = 16;  // RegFile address width
  
  localparam int CLK_PERIOD = 10; // 10ns = 100MHz

// ==============================================================================================
// DUT Interface Signals
// ==============================================================================================
  logic clk;
  logic s_rst_n;
  
  // Control interface
  logic start;
  logic [MAX_BIT_WIDTH-1:0] bit_width;
  logic done;
  
  // Input: GGSW bit samples
  logic [REGF_ADDR_W-1:0] ggsw_samples_base_addr;
  logic ggsw_samples_ready;
  
  // Output result
  logic [REGF_ADDR_W-1:0] result_addr;
  logic result_ready;
  
  // Large LUT interface
  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] lut_base_addr;
  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] lut_addr;
  logic lut_req_vld;
  logic lut_req_rdy;
  logic lut_data_avail;
  logic [axi_if_glwe_axi_pkg::AXI4_DATA_W-1:0] lut_data;
  
  // RegFile interface
  logic regf_rd_req_vld;
  logic regf_rd_req_rdy;
  logic [REGF_RD_REQ_W-1:0] regf_rd_req;
  logic [REGF_COEF_NB-1:0] regf_rd_data_avail;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_rd_data;
  
  logic regf_wr_req_vld;
  logic regf_wr_req_rdy;
  logic [REGF_WR_REQ_W-1:0] regf_wr_req;
  logic [REGF_COEF_NB-1:0] regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0] regf_wr_data_rdy;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_wr_data;

// ==============================================================================================
// Test Data Storage
// ==============================================================================================
  // Test input: 20-bit GGSW samples (simulated circuit bootstrap output)
  logic [MAX_BIT_WIDTH-1:0][ELL_LVL1-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] test_ggsw_samples;
  
  // Test LUT table (1024 entries)
  logic [LUT_SIZE-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] test_lut_table;
  
  // Expected result from golden reference
  logic [N_LVL1-1:0][MOD_Q_W-1:0] expected_result_a;
  logic [MOD_Q_W-1:0] expected_result_b;
  
  // Actual result from DUT
  logic [N_LVL1-1:0][MOD_Q_W-1:0] actual_result_a;
  logic [MOD_Q_W-1:0] actual_result_b;
  
  // Working variables for simulators
  logic [31:0] entry_index;
  logic [15:0] ggsw_addr;
  logic [4:0] bit_index;
  
  // Golden reference variables
  int unsigned golden_ggsw_bits[MAX_BIT_WIDTH];
  int unsigned golden_lut_table[LUT_SIZE];  
  int unsigned golden_result_a[N_LVL1];
  int unsigned golden_result_b;
  int error_count;

// ==============================================================================================
// Clock Generation
// ==============================================================================================
  initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

// ==============================================================================================
// DUT Instantiation
// ==============================================================================================
  wop_vertical_packing_engine #(
    .MOD_Q_W(MOD_Q_W),
    .MAX_BIT_WIDTH(MAX_BIT_WIDTH),
    .N_LVL1(N_LVL1),
    .ELL_LVL1(ELL_LVL1),
    .K(K),
    .REGF_ADDR_W(REGF_ADDR_W)
  ) u_dut (
    .clk(clk),
    .s_rst_n(s_rst_n),
    .start(start),
    .bit_width(bit_width),
    .done(done),
    .ggsw_samples_base_addr(ggsw_samples_base_addr),
    .ggsw_samples_ready(ggsw_samples_ready),
    .result_addr(result_addr),
    .result_ready(result_ready),
    .lut_base_addr(lut_base_addr),
    .lut_addr(lut_addr),
    .lut_req_vld(lut_req_vld),
    .lut_req_rdy(lut_req_rdy),
    .lut_data_avail(lut_data_avail),
    .lut_data(lut_data),
    .regf_rd_req_vld(regf_rd_req_vld),
    .regf_rd_req_rdy(regf_rd_req_rdy),
    .regf_rd_req(regf_rd_req),
    .regf_rd_data_avail(regf_rd_data_avail),
    .regf_rd_data(regf_rd_data),
    .regf_wr_req_vld(regf_wr_req_vld),
    .regf_wr_req_rdy(regf_wr_req_rdy),
    .regf_wr_req(regf_wr_req),
    .regf_wr_data_vld(regf_wr_data_vld),
    .regf_wr_data_rdy(regf_wr_data_rdy),
    .regf_wr_data(regf_wr_data)
  );

// ==============================================================================================
// LUT Service Simulator
// ==============================================================================================
  // LUT access state machine
  typedef enum logic [1:0] {
    LUT_IDLE,
    LUT_PROCESSING,
    LUT_READY
  } lut_state_t;
  
  lut_state_t lut_state;
  logic [31:0] lut_access_counter;
  
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      lut_state <= LUT_IDLE;
      lut_req_rdy <= 1'b1;
      lut_data_avail <= 1'b0;
      lut_data <= '0;
      lut_access_counter <= 0;
    end else begin
      case (lut_state)
        LUT_IDLE: begin
          lut_req_rdy <= 1'b1;
          lut_data_avail <= 1'b0;
          
          if (lut_req_vld && lut_req_rdy) begin
            lut_state <= LUT_PROCESSING;
            lut_access_counter <= 0;
            $display("[LUT_SIM] LUT request received, addr=0x%0h at time %0t", lut_addr, $time);
          end
        end
        
        LUT_PROCESSING: begin
          lut_req_rdy <= 1'b0;
          lut_access_counter <= lut_access_counter + 1;
          
          // Simulate memory access latency
          if (lut_access_counter >= 5) begin
            lut_state <= LUT_READY;
            lut_data_avail <= 1'b1;
            
            // Calculate which LUT entry to return
            entry_index = (lut_addr - lut_base_addr) / (N_LVL1 * 4);
            if (entry_index < LUT_SIZE) begin
              // Return packed LUT data matching big_lut.cpp initialization
              // Line 14: pools[0][i].a[ii].coefs[j] = luts[i].a[ii].coefs[j]
              lut_data <= {test_lut_table[entry_index][0][3:0]};
              $display("[LUT_SIM] Returning LUT entry %0d: data[0:3]={%0h,%0h,%0h,%0h}", 
                       entry_index, test_lut_table[entry_index][0][0], test_lut_table[entry_index][0][1],
                       test_lut_table[entry_index][0][2], test_lut_table[entry_index][0][3]);
            end
          end
        end
        
        LUT_READY: begin
          lut_data_avail <= 1'b1;
          if (!lut_req_vld) begin  // Wait for request to be deasserted
            lut_state <= LUT_IDLE;
            lut_data_avail <= 1'b0;
          end
        end
      endcase
    end
  end

// ==============================================================================================
// RegFile Service Simulator
// ==============================================================================================
  // RegFile read state machine
  typedef enum logic [1:0] {
    REGF_RD_IDLE,
    REGF_RD_PROCESSING,
    REGF_RD_READY
  } regf_rd_state_t;
  
  regf_rd_state_t regf_rd_state;
  logic [31:0] regf_rd_counter;
  
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      regf_rd_state <= REGF_RD_IDLE;
      regf_rd_req_rdy <= 1'b1;
      regf_rd_data_avail <= '0;
      regf_rd_data <= '0;
      regf_rd_counter <= 0;
    end else begin
      case (regf_rd_state)
        REGF_RD_IDLE: begin
          regf_rd_req_rdy <= 1'b1;
          regf_rd_data_avail <= '0;
          
          if (regf_rd_req_vld && regf_rd_req_rdy) begin
            regf_rd_state <= REGF_RD_PROCESSING;
            regf_rd_counter <= 0;
            $display("[REGF_SIM] RegFile read request: addr=0x%0h at time %0t", 
                     regf_rd_req[REGF_RD_REQ_W-1:16], $time);
          end
        end
        
        REGF_RD_PROCESSING: begin
          regf_rd_req_rdy <= 1'b0;
          regf_rd_counter <= regf_rd_counter + 1;
          
          // Simulate regfile access latency
          if (regf_rd_counter >= 3) begin
            regf_rd_state <= REGF_RD_READY;
            regf_rd_data_avail[0] <= 1'b1;
            
            // Return test GGSW data
            ggsw_addr = regf_rd_req[REGF_RD_REQ_W-1:16];
            bit_index = ggsw_addr - ggsw_samples_base_addr;
            if (bit_index < MAX_BIT_WIDTH) begin
              regf_rd_data[0] <= test_ggsw_samples[bit_index][0][0][0];  // Simplified
              $display("[REGF_SIM] Returning GGSW bit %0d data: %0h", bit_index, test_ggsw_samples[bit_index][0][0][0]);
            end
          end
        end
        
        REGF_RD_READY: begin
          regf_rd_data_avail[0] <= 1'b1;
          if (!regf_rd_req_vld) begin
            regf_rd_state <= REGF_RD_IDLE;
            regf_rd_data_avail <= '0;
          end
        end
      endcase
    end
  end
  
  // RegFile write handling (always ready for simplicity)
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      regf_wr_req_rdy <= 1'b1;
      regf_wr_data_rdy <= '1;
    end else begin
      regf_wr_req_rdy <= 1'b1;
      regf_wr_data_rdy <= '1;
      
      if (regf_wr_req_vld && regf_wr_data_vld[0]) begin
        logic [15:0] wr_addr = regf_wr_req[REGF_WR_REQ_W-1:16];
        logic [15:0] offset = wr_addr - result_addr;
        if (offset < N_LVL1) begin
          actual_result_a[offset] <= regf_wr_data[0];
          $display("[REGF_SIM] Writing result[%0d] = %0h at time %0t", offset, regf_wr_data[0], $time);
        end
      end
    end
  end

// ==============================================================================================
// Test Data Generation
// ==============================================================================================
  task automatic generate_test_data();
    $display("[TB] Generating test data...");
    
    // Generate deterministic 20-bit GGSW samples for reproducible testing
    for (int bit_idx = 0; bit_idx < MAX_BIT_WIDTH; bit_idx++) begin
      for (int ell = 0; ell < ELL_LVL1; ell++) begin
        for (int k = 0; k <= K; k++) begin
          for (int n = 0; n < N_LVL1; n++) begin
            // Create pattern that will result in predictable bit extraction
            if (bit_idx < 10) begin
              // Lower bits (0-9): used in blind rotation
              test_ggsw_samples[bit_idx][ell][k][n] = (bit_idx % 2 == 0) ? 600 : 400;  // Alternating pattern
            end else begin
              // Upper bits (10-19): used in CMux tree
              test_ggsw_samples[bit_idx][ell][k][n] = (bit_idx % 2 == 1) ? 700 : 300;  // Different pattern
            end
          end
        end
      end
    end
    
    // Generate meaningful LUT table matching typical use case
    for (int i = 0; i < LUT_SIZE; i++) begin
      // Create a function that maps 10-bit input to meaningful output
      // Example: f(x) = x * 100 + popcount(x) for distinguishable results
      int popcount = $countones(i);
      int base_value = i * 100 + popcount;
      
      for (int k = 0; k <= K; k++) begin
        for (int n = 0; n < N_LVL1; n++) begin
          if (n == 0) begin
            test_lut_table[i][k][n] = base_value;  // Main coefficient
          end else if (n == 1) begin
            test_lut_table[i][k][n] = base_value + 1;  // Second coefficient (for b part)
          end else begin
            test_lut_table[i][k][n] = 0;  // Zero padding for simulation
          end
        end
      end
    end
    
    $display("[TB] Test data generation completed");
    $display("[TB] GGSW patterns:");
    for (int bit_idx = 0; bit_idx < MAX_BIT_WIDTH; bit_idx++) begin
      $display("[TB]   Bit %0d: value=%0h -> extracted_bit=%0b", 
               bit_idx, test_ggsw_samples[bit_idx][0][0][0], (test_ggsw_samples[bit_idx][0][0][0] % 1000) > 500);
    end
    $display("[TB] LUT examples:");
    $display("[TB]   LUT[0] = %0h (f(0) = %0d)", test_lut_table[0][0][0], 0*100 + $countones(0));
    $display("[TB]   LUT[1] = %0h (f(1) = %0d)", test_lut_table[1][0][0], 1*100 + $countones(1));
    $display("[TB]   LUT[511] = %0h (f(511) = %0d)", test_lut_table[511][0][0], 511*100 + $countones(511));
  endtask

// ==============================================================================================
// Golden Reference Interface (DPI-C)
// ==============================================================================================
  import "DPI-C" function void vertical_packing_golden_ref(
    input int unsigned ggsw_bits[MAX_BIT_WIDTH],
    input int unsigned lut_table[LUT_SIZE],  
    output int unsigned result_a[N_LVL1],
    output int unsigned result_b,
    input int n_lvl1,
    input int input_bits
  );

// ==============================================================================================
// Main Test Sequence
// ==============================================================================================
  initial begin
    $display("========================================");
    $display("  WoP Vertical Packing Engine Test");
    $display("========================================");
    
    // Initialize signals
    s_rst_n = 0;
    start = 0;
    bit_width = MAX_BIT_WIDTH;
    ggsw_samples_base_addr = 16'h1000;
    ggsw_samples_ready = 0;
    result_addr = 16'h2000;
    lut_base_addr = 32'h10000000;
    
    // Reset sequence
    repeat(10) @(posedge clk);
    s_rst_n = 1;
    repeat(5) @(posedge clk);
    
    // Generate test data
    generate_test_data();
    
    // Prepare inputs
    ggsw_samples_ready = 1;
    
    // Start test
    $display("[TB] Starting vertical packing test at time %0t", $time);
    start = 1;
    @(posedge clk);
    start = 0;
    
    // Wait for completion with timeout
    fork
      begin
        wait(done);
        $display("[TB] Vertical packing completed at time %0t", $time);
      end
      begin
        repeat(50000) @(posedge clk);  // 500us timeout
        $error("[TB] Test timeout!");
        $finish;
      end
    join_any
    disable fork;
    
    // Call golden reference for comparison
    
    // Prepare golden reference inputs (simplified)
    for (int i = 0; i < MAX_BIT_WIDTH; i++) begin
      golden_ggsw_bits[i] = int'(test_ggsw_samples[i][0][0][0]);  // Type conversion
    end
    for (int i = 0; i < LUT_SIZE; i++) begin
      golden_lut_table[i] = int'(test_lut_table[i][0][0]);  // Type conversion
    end
    
    vertical_packing_golden_ref(
      golden_ggsw_bits,
      golden_lut_table,
      golden_result_a,
      golden_result_b,
      N_LVL1,
      MAX_BIT_WIDTH
    );
    
    // Compare results
    error_count = 0;
    for (int i = 0; i < N_LVL1; i++) begin
      if (actual_result_a[i] != golden_result_a[i]) begin
        error_count++;
        if (error_count <= 10) begin  // Show first 10 errors
          $display("[TB] Mismatch at a[%0d]: RTL=%0h, Golden=%0h", 
                   i, actual_result_a[i], golden_result_a[i]);
        end
      end
    end
    
    if (error_count == 0) begin
      $display("[TB] ✅ SUCCESS: All results match golden reference!");
    end else begin
      $display("[TB] ❌ FAILURE: %0d mismatches found", error_count);
    end
    
    $display("[TB] Test completed at time %0t", $time);
    $finish;
  end

endmodule