// ==============================================================================================
// Filename: tb_wop_premodswitch_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// Testbench for WoP-PBS Pre-ModSwitch Engine.
// This testbench validates the preModSwitch functionality against the C++ golden reference.
//
// Author: Ray Pan 
// Date:   July 31, 2025
// ==============================================================================================

`timescale 1ns/1ps

module tb_wop_premodswitch_engine;

// ==============================================================================================
// Parameters
// ==============================================================================================
  parameter int N_LVL0 = 630;
  parameter int N_LVL2 = 2048;

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
  logic start;
  logic done;
  logic [N_LVL0:0][31:0] input_lwe_sample;
  logic input_valid;
  logic [N_LVL0:0][31:0] abar_result;
  logic result_valid;

// ==============================================================================================
// Test Data
// ==============================================================================================
  logic [N_LVL0:0][31:0] expected_abar;
  
  // Constants from C++ implementation
  localparam int _2N = 2 * N_LVL2;
  localparam logic [63:0] INTERV = ((64'h8000000000000000 / _2N) * 2);
  localparam logic [63:0] HALF_INTERVAL = INTERV / 2;

// ==============================================================================================
// DUT Instantiation
// ==============================================================================================
  wop_premodswitch_engine #(
    .N_LVL0(N_LVL0),
    .N_LVL2(N_LVL2)
  ) dut (
    .clk(clk),
    .s_rst_n(s_rst_n),
    .start(start),
    .done(done),
    .input_lwe_sample(input_lwe_sample),
    .input_valid(input_valid),
    .abar_result(abar_result),
    .result_valid(result_valid)
  );

// ==============================================================================================
// DPI-C Interface to C++ Golden Reference
// ==============================================================================================
  
  // Import C++ functions for golden reference
  import "DPI-C" function void init_premodswitch_golden_reference();
  import "DPI-C" function void run_premodswitch_golden_reference(
    input bit [31:0] input_data[],
    output bit [31:0] expected_output[]
  );
  import "DPI-C" function void cleanup_premodswitch_golden_reference();

// ==============================================================================================
// Golden Reference Model
// ==============================================================================================
  task automatic compute_golden_reference();
    // Call C++ golden reference to get expected outputs
    bit [31:0] input_array[N_LVL0+1];
    bit [31:0] expected_array[N_LVL0+1];
    
    $display("Computing golden reference using C++ preModSwitch function");
    
    // Convert to bit array for DPI-C
    for (int i = 0; i <= N_LVL0; i++) begin
      input_array[i] = input_lwe_sample[i];
    end
    
    // Call original C++ function
    run_premodswitch_golden_reference(input_array, expected_array);
    
    // Convert back to expected outputs
    for (int i = 0; i <= N_LVL0; i++) begin
      expected_abar[i] = expected_array[i];
    end
  endtask

// ==============================================================================================
// Test Stimulus
// ==============================================================================================
  task automatic generate_test_vectors();
    $display("Generating test vectors...");
    
    // Generate random LWE sample
    for (int i = 0; i <= N_LVL0; i++) begin
      input_lwe_sample[i] = $random() & 32'hFFFFFFFF;
    end
    
    // Compute expected results
    compute_golden_reference();
  endtask

// ==============================================================================================
// Result Checking
// ==============================================================================================
  task automatic check_results();
    logic test_passed = 1'b1;
    int max_error = 0;
    int error;
    
    $display("Checking results...");
    
    for (int i = 0; i <= N_LVL0; i++) begin
      error = (abar_result[i] > expected_abar[i]) ? 
              (abar_result[i] - expected_abar[i]) : 
              (expected_abar[i] - abar_result[i]);
      
      if (error > max_error) max_error = error;
      
      if (abar_result[i] !== expected_abar[i]) begin
        $display("Mismatch at i=%0d: expected=0x%08x, actual=0x%08x, error=%0d", 
                 i, expected_abar[i], abar_result[i], error);
        
        // Allow small errors due to division precision
        if (error > 2) begin
          test_passed = 1'b0;
        end
      end
    end
    
    $display("Maximum error: %0d", max_error);
    
    if (test_passed) begin
      $display("✅ Test PASSED: Pre-ModSwitch results match golden reference (max error: %0d)", max_error);
    end else begin
      $error("❌ Test FAILED: Pre-ModSwitch results have significant errors");
    end
  endtask

// ==============================================================================================
// Main Test Sequence
// ==============================================================================================
  initial begin
    $display("Starting WoP-PBS Pre-ModSwitch Engine Testbench");
    
    // Initialize C++ golden reference
    init_premodswitch_golden_reference();
    
    // Initialize
    start = 1'b0;
    input_valid = 1'b0;
    input_lwe_sample = '0;
    
    // Wait for reset
    wait(s_rst_n);
    repeat(10) @(posedge clk);
    
    // Run multiple test cases
    for (int test_case = 0; test_case < 10; test_case++) begin
      $display("\n=== Test Case %0d ===", test_case);
      
      // Generate test vectors
      generate_test_vectors();
      
      // Start pre-modswitch
      @(posedge clk);
      input_valid = 1'b1;
      start = 1'b1;
      @(posedge clk);
      start = 1'b0;
      input_valid = 1'b0;
      
      // Wait for completion
      wait(result_valid);
      $display("Pre-ModSwitch completed");
      
      // Check results
      check_results();
      
      // Wait before next test
      repeat(10) @(posedge clk);
    end
    
    // Test edge cases
    $display("\n=== Edge Case Tests ===");
    
    // Test with all zeros
    input_lwe_sample = '0;
    compute_golden_reference();
    @(posedge clk);
    input_valid = 1'b1;
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;
    input_valid = 1'b0;
    wait(result_valid);
    check_results();
    
    // Test with all ones
    input_lwe_sample = '1;
    compute_golden_reference();
    @(posedge clk);
    input_valid = 1'b1;
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;
    input_valid = 1'b0;
    wait(result_valid);
    check_results();
    
    $display("\n=== Testbench Completed ===");
    
    // Cleanup C++ golden reference
    cleanup_premodswitch_golden_reference();
    
    $finish;
  end

// ==============================================================================================
// Monitoring
// ==============================================================================================
  always @(posedge clk) begin
    if (start) begin
      $display("Starting pre-modswitch at time %0t", $time);
    end
    
    if (done) begin
      $display("Pre-modswitch completed at time %0t", $time);
    end
  end

  // Timeout watchdog
  initial begin
    #10000000; // 10ms timeout
    $error("Testbench timeout!");
    $finish;
  end

endmodule