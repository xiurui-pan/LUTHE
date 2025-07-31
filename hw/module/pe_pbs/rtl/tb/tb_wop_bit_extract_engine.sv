// ==============================================================================================
// Filename: tb_wop_bit_extract_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// Testbench for WoP-PBS Bit Extraction Engine.
// This testbench validates the bit extraction functionality against the C++ golden reference.
//
// Author: Ray Pan 
// Date:   July 31, 2025
// ==============================================================================================

`timescale 1ns/1ps

module tb_wop_bit_extract_engine;

// ==============================================================================================
// Parameters
// ==============================================================================================
  parameter int MOD_Q_W = 32;
  parameter int MAX_BIT_WIDTH = 20;
  parameter int N_LVL1 = 1024;
  parameter int LUT_ENTRY_SIZE = 8192;
  parameter int REGF_ADDR_W = 16;
  parameter int REGF_COEF_NB = 8;
  parameter int REGF_RD_REQ_W = 32;
  parameter int REGF_WR_REQ_W = 32;
  parameter int AXI4_ADD_W = 64;
  parameter int AXI4_DATA_W = 512;

// ==============================================================================================
// Clock and Reset
// ==============================================================================================
  logic clk;
  logic s_rst_n;
  
  initial begin
    clk = 0;
    forever #5 clk = ~clk; // 100MHz clock
  end
  
  initial begin
    s_rst_n = 0;
    #100;
    s_rst_n = 1;
  end

// ==============================================================================================
// DUT Signals
// ==============================================================================================
  // Control interface
  logic start;
  logic [MAX_BIT_WIDTH-1:0] bit_pos;
  logic done;
  
  // Input/output addresses
  logic [REGF_ADDR_W-1:0] input_lwe_addr;
  logic [REGF_ADDR_W-1:0] output_bit_addr_0;
  logic [REGF_ADDR_W-1:0] output_bit_addr_1;
  
  // RegFile interface
  logic regf_rd_req_vld;
  logic regf_rd_req_rdy;
  logic [REGF_RD_REQ_W-1:0] regf_rd_req;
  logic [REGF_COEF_NB-1:0] regf_rd_data_avail;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_rd_data;
  logic regf_rd_last_word;
  
  logic regf_wr_req_vld;
  logic regf_wr_req_rdy;
  logic [REGF_WR_REQ_W-1:0] regf_wr_req;
  logic [REGF_COEF_NB-1:0] regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0] regf_wr_data_rdy;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_wr_data;
  
  // LUT access interface
  logic [AXI4_ADD_W-1:0] bit_extract_lut_base_addr;
  logic [AXI4_ADD_W-1:0] lut_addr;
  logic lut_req_vld;
  logic lut_req_rdy;
  logic lut_data_avail;
  logic [AXI4_DATA_W-1:0] lut_data;

// ==============================================================================================
// Test Data Storage
// ==============================================================================================
  // Input LWE sample (simulating encrypted data)
  logic [N_LVL1:0][MOD_Q_W-1:0] input_lwe_sample;
  
  // Expected outputs (from C++ golden reference)
  logic [N_LVL1:0][MOD_Q_W-1:0] expected_output_0;
  logic [N_LVL1:0][MOD_Q_W-1:0] expected_output_1;
  
  // Actual outputs (from DUT)
  logic [N_LVL1:0][MOD_Q_W-1:0] actual_output_0;
  logic [N_LVL1:0][MOD_Q_W-1:0] actual_output_1;
  
  // RegFile simulation memory
  logic [N_LVL1:0][MOD_Q_W-1:0] regfile_memory [0:65535];

// ==============================================================================================
// DUT Instantiation
// ==============================================================================================
  wop_bit_extract_engine #(
    .MOD_Q_W(MOD_Q_W),
    .MAX_BIT_WIDTH(MAX_BIT_WIDTH),
    .N_LVL1(N_LVL1),
    .LUT_ENTRY_SIZE(LUT_ENTRY_SIZE)
  ) dut (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // Control interface
    .start(start),
    .bit_pos(bit_pos),
    .done(done),
    
    // Input/output addresses
    .input_lwe_addr(input_lwe_addr),
    .output_bit_addr_0(output_bit_addr_0),
    .output_bit_addr_1(output_bit_addr_1),
    
    // RegFile interface
    .regf_rd_req_vld(regf_rd_req_vld),
    .regf_rd_req_rdy(regf_rd_req_rdy),
    .regf_rd_req(regf_rd_req),
    .regf_rd_data_avail(regf_rd_data_avail),
    .regf_rd_data(regf_rd_data),
    .regf_rd_last_word(regf_rd_last_word),
    
    .regf_wr_req_vld(regf_wr_req_vld),
    .regf_wr_req_rdy(regf_wr_req_rdy),
    .regf_wr_req(regf_wr_req),
    .regf_wr_data_vld(regf_wr_data_vld),
    .regf_wr_data_rdy(regf_wr_data_rdy),
    .regf_wr_data(regf_wr_data),
    
    // LUT access interface
    .bit_extract_lut_base_addr(bit_extract_lut_base_addr),
    .lut_addr(lut_addr),
    .lut_req_vld(lut_req_vld),
    .lut_req_rdy(lut_req_rdy),
    .lut_data_avail(lut_data_avail),
    .lut_data(lut_data)
  );

// ==============================================================================================
// RegFile Model
// ==============================================================================================
  // Simple RegFile model for testing
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      regf_rd_req_rdy <= 1'b1;
      regf_wr_req_rdy <= 1'b1;
      regf_wr_data_rdy <= '1;
      regf_rd_data_avail <= '0;
      regf_rd_data <= '0;
      regf_rd_last_word <= 1'b0;
    end else begin
      // Handle read requests
      if (regf_rd_req_vld && regf_rd_req_rdy) begin
        logic [REGF_ADDR_W-1:0] addr = regf_rd_req[REGF_ADDR_W-1:0];
        regf_rd_data_avail[0] <= 1'b1;
        regf_rd_data[0] <= regfile_memory[addr][0]; // Return first coefficient
        regf_rd_last_word <= 1'b1; // Simplified - single cycle read
      end else begin
        regf_rd_data_avail <= '0;
        regf_rd_last_word <= 1'b0;
      end
      
      // Handle write requests
      if (regf_wr_req_vld && regf_wr_req_rdy && regf_wr_data_vld[0] && regf_wr_data_rdy[0]) begin
        logic [REGF_ADDR_W-1:0] addr = regf_wr_req[REGF_ADDR_W-1:0];
        regfile_memory[addr][0] <= regf_wr_data[0]; // Store first coefficient
      end
    end
  end

// ==============================================================================================
// LUT Model
// ==============================================================================================
  // Simple LUT model - returns dummy data for testing
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      lut_req_rdy <= 1'b1;
      lut_data_avail <= 1'b0;
      lut_data <= '0;
    end else begin
      if (lut_req_vld && lut_req_rdy) begin
        lut_data_avail <= 1'b1;
        // Return dummy LUT data based on address
        if (lut_addr[12:0] == 0) begin
          lut_data <= 512'hDEADBEEF; // map_to_bit31 LUT
        end else begin
          lut_data <= 512'hCAFEBABE; // map_to_bit27 LUT
        end
      end else begin
        lut_data_avail <= 1'b0;
      end
    end
  end

// ==============================================================================================
// DPI-C Interface to C++ Golden Reference
// ==============================================================================================
  
  // Import C++ functions for golden reference
  import "DPI-C" function void init_golden_reference();
  import "DPI-C" function void run_golden_reference(
    input bit [31:0] input_data[],
    output bit [31:0] expected_output_0[],
    output bit [31:0] expected_output_1[]
  );
  import "DPI-C" function void cleanup_golden_reference();

// ==============================================================================================
// Test Stimulus and Golden Reference
// ==============================================================================================
  
  // Generate test vectors using original C++ bitExtract function
  task automatic generate_test_vectors();
    // Input LWE sample - simulate encrypted data
    for (int i = 0; i <= N_LVL1; i++) begin
      input_lwe_sample[i] = $random();
    end
    
    // Store input in RegFile memory
    regfile_memory[input_lwe_addr] = input_lwe_sample;
    
    // Call C++ golden reference to get expected outputs
    bit [31:0] input_array[N_LVL1+1];
    bit [31:0] expected_array_0[N_LVL1+1];
    bit [31:0] expected_array_1[N_LVL1+1];
    
    // Convert to bit array for DPI-C
    for (int i = 0; i <= N_LVL1; i++) begin
      input_array[i] = input_lwe_sample[i];
    end
    
    // Call original C++ function
    run_golden_reference(input_array, expected_array_0, expected_array_1);
    
    // Convert back to expected outputs
    for (int i = 0; i <= N_LVL1; i++) begin
      expected_output_0[i] = expected_array_0[i];
      expected_output_1[i] = expected_array_1[i];
    end
    
    $display("Generated test vectors using C++ golden reference");
  endtask

  // Compare results with golden reference
  task automatic check_results();
    logic test_passed = 1'b1;
    
    // Read actual outputs from RegFile
    actual_output_0 = regfile_memory[output_bit_addr_0];
    actual_output_1 = regfile_memory[output_bit_addr_1];
    
    // Compare with expected results
    for (int i = 0; i <= N_LVL1; i++) begin
      if (actual_output_0[i] !== expected_output_0[i]) begin
        $error("Mismatch in output_0[%0d]: expected=0x%08x, actual=0x%08x", 
               i, expected_output_0[i], actual_output_0[i]);
        test_passed = 1'b0;
      end
      
      if (actual_output_1[i] !== expected_output_1[i]) begin
        $error("Mismatch in output_1[%0d]: expected=0x%08x, actual=0x%08x", 
               i, expected_output_1[i], actual_output_1[i]);
        test_passed = 1'b0;
      end
    end
    
    if (test_passed) begin
      $display("✅ Test PASSED: Bit extraction results match golden reference");
    end else begin
      $error("❌ Test FAILED: Bit extraction results do not match");
    end
  endtask

// ==============================================================================================
// Main Test Sequence
// ==============================================================================================
  initial begin
    $display("Starting WoP-PBS Bit Extraction Engine Testbench");
    
    // Initialize C++ golden reference
    init_golden_reference();
    
    // Initialize
    start = 1'b0;
    bit_pos = '0;
    input_lwe_addr = 16'h0100;
    output_bit_addr_0 = 16'h0200;
    output_bit_addr_1 = 16'h0300;
    bit_extract_lut_base_addr = 64'h1000_0000;
    
    // Wait for reset
    wait(s_rst_n);
    repeat(10) @(posedge clk);
    
    // Run multiple test cases
    for (int test_case = 0; test_case < 5; test_case++) begin
      $display("\n=== Test Case %0d ===", test_case);
      
      // Generate test vectors
      generate_test_vectors();
      
      // Start bit extraction
      @(posedge clk);
      start = 1'b1;
      @(posedge clk);
      start = 1'b0;
      
      // Wait for completion
      wait(done);
      $display("Bit extraction completed");
      
      // Check results
      repeat(5) @(posedge clk); // Allow time for writes to complete
      check_results();
      
      // Prepare for next test
      repeat(10) @(posedge clk);
    end
    
    $display("\n=== Testbench Completed ===");
    
    // Cleanup C++ golden reference
    cleanup_golden_reference();
    
    $finish;
  end

// ==============================================================================================
// Monitoring and Debug
// ==============================================================================================
  // Monitor key signals
  always @(posedge clk) begin
    if (start) begin
      $display("Starting bit extraction at time %0t", $time);
    end
    
    if (done) begin
      $display("Bit extraction completed at time %0t", $time);
    end
    
    if (regf_wr_req_vld && regf_wr_req_rdy) begin
      $display("Writing to RegFile addr=0x%04x, data=0x%08x", 
               regf_wr_req[REGF_ADDR_W-1:0], regf_wr_data[0]);
    end
  end

  // Timeout watchdog
  initial begin
    #1000000; // 1ms timeout
    $error("Testbench timeout!");
    $finish;
  end

endmodule