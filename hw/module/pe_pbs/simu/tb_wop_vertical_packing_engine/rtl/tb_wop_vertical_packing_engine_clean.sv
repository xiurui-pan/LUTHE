// ==============================================================================================
// Filename: tb_wop_vertical_packing_engine_clean.sv  
// ----------------------------------------------------------------------------------------------
// Description: Simplified testbench for WoP-PBS Vertical Packing Engine
// Focus on PBS Service Interface integration
// ==============================================================================================

`timescale 1ns/1ps

import param_tfhe_definition_pkg::*;
import regf_common_definition_pkg::*;
import pe_pbs_common_definition_pkg::*;
import axi_if_glwe_axi_pkg::*;

module tb_wop_vertical_packing_engine;

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
    #100 s_rst_n = 1;
  end

// ==============================================================================================
// DUT Signals
// ==============================================================================================
  logic start;
  logic done;
  logic [REGF_ADDR_W-1:0] ggsw_samples_base_addr;
  logic ggsw_samples_ready;
  logic [REGF_ADDR_W-1:0] result_addr;
  logic result_ready;
  
  // LUT interface
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

  // PBS service interface
  logic [PE_INST_W-1:0] pbs_inst;
  logic pbs_inst_vld;
  logic pbs_inst_rdy;
  logic pbs_inst_ack;
  logic pbs_inst_load_blwe_ack;

// ==============================================================================================
// Test Data
// ==============================================================================================
  parameter LUT_SIZE = 1024;
  parameter MAX_BIT_WIDTH = 20;
  
  // Test LUT table - simplified
  logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] test_lut_table [0:LUT_SIZE-1];
  
  // Test GGSW samples - simplified
  logic [L_LVL1-1:0][K:0][N_LVL1-1:0][MOD_Q_W-1:0] test_ggsw_samples [0:MAX_BIT_WIDTH-1];
  
  // Golden reference results
  logic [MOD_Q_W-1:0] golden_result_a [0:N_LVL1-1];
  logic [MOD_Q_W-1:0] golden_result_b;
  
  // Actual results from PBS
  logic [MOD_Q_W-1:0] actual_result_a [0:N_LVL1-1];
  logic [MOD_Q_W-1:0] actual_result_b;

// ==============================================================================================
// RegFile Memory Model
// ==============================================================================================
  logic [MOD_Q_W-1:0] regfile_memory [0:65535];
  
  // Initialize RegFile memory
  initial begin
    for (int addr = 0; addr < 65536; addr++) begin
      regfile_memory[addr] = 32'h0;
    end
    $display("[REGF_MODEL] RegFile memory initialized");
  end

// ==============================================================================================
// DUT Instantiation
// ==============================================================================================
  wop_vertical_packing_engine u_dut (
    .clk(clk),
    .s_rst_n(s_rst_n),
    .start(start),
    .done(done),
    .ggsw_samples_base_addr(ggsw_samples_base_addr),
    .ggsw_samples_ready(ggsw_samples_ready),
    .result_addr(result_addr),
    .result_ready(result_ready),
    // LUT interface
    .lut_base_addr(lut_base_addr),
    .lut_addr(lut_addr),
    .lut_req_vld(lut_req_vld),
    .lut_req_rdy(lut_req_rdy),
    .lut_data_avail(lut_data_avail),
    .lut_data(lut_data),
    // RegFile interface
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
    .regf_wr_data(regf_wr_data),
    // PBS service interface
    .pbs_inst(pbs_inst),
    .pbs_inst_vld(pbs_inst_vld),
    .pbs_inst_rdy(pbs_inst_rdy),
    .pbs_inst_ack(pbs_inst_ack),
    .pbs_inst_load_blwe_ack(pbs_inst_load_blwe_ack)
  );

// ==============================================================================================
// Simple LUT Model
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      lut_req_rdy <= 1'b1;
      lut_data_avail <= 1'b0;
      lut_data <= '0;
    end else begin
      if (lut_req_vld && lut_req_rdy) begin
        lut_req_rdy <= 1'b0;
        lut_data_avail <= 1'b1;
        // Calculate LUT entry index
        automatic int entry_idx = (lut_addr - lut_base_addr) >> 7;
        if (entry_idx < LUT_SIZE) begin
          // Pack TLWE data: {a[3], a[2], b[0], a[0]}
          lut_data <= {test_lut_table[entry_idx][0][3], test_lut_table[entry_idx][0][2],
                      test_lut_table[entry_idx][1][0], test_lut_table[entry_idx][0][0]};
        end else begin
          lut_data <= '0;
        end
      end else if (!lut_req_vld) begin
        lut_req_rdy <= 1'b1;
        lut_data_avail <= 1'b0;
      end
    end
  end

// ==============================================================================================
// Simple RegFile Model
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      regf_rd_req_rdy <= 1'b1;
      regf_wr_req_rdy <= 1'b1;
      regf_wr_data_rdy <= '1;
      regf_rd_data_avail <= '0;
      regf_rd_data <= '0;
    end else begin
      // Handle read requests
      if (regf_rd_req_vld && regf_rd_req_rdy) begin
        automatic logic [REGF_ADDR_W-1:0] read_addr = regf_rd_req[REGF_RD_REQ_W-1 -: REGF_ADDR_W];
        regf_rd_data_avail[0] <= 1'b1;
        regf_rd_data[0] <= regfile_memory[read_addr];
      end else begin
        regf_rd_data_avail[0] <= 1'b0;
      end
      
      // Handle write requests
      if (regf_wr_req_vld && regf_wr_data_vld[0] && regf_wr_req_rdy && regf_wr_data_rdy[0]) begin
        automatic logic [REGF_ADDR_W-1:0] write_addr = regf_wr_req[REGF_WR_REQ_W-1 -: REGF_ADDR_W];
        regfile_memory[write_addr] <= regf_wr_data[0];
        
        // Capture results for verification
        if (write_addr >= result_addr && write_addr < result_addr + N_LVL1 + 1) begin
          automatic int result_idx = write_addr - result_addr;
          if (result_idx < N_LVL1) begin
            actual_result_a[result_idx] <= regf_wr_data[0];
          end else begin
            actual_result_b <= regf_wr_data[0];
          end
        end
      end
    end
  end

// ==============================================================================================
// PBS Model with Sample Extract
// ==============================================================================================
  logic [7:0] pbs_ack_cnt;
  logic [15:0] pbs_src_addr, pbs_dst_addr;
  logic [MOD_Q_W-1:0] tlwe_a [0:N_LVL1-1];
  logic [MOD_Q_W-1:0] tlwe_b;
  logic [MOD_Q_W-1:0] lwe_a [0:N_LVL1-1];
  logic [MOD_Q_W-1:0] lwe_b;
  logic [31:0] pbs_read_cnt;
  
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      pbs_inst_rdy <= 1'b1;
      pbs_inst_ack <= 1'b0;
      pbs_inst_load_blwe_ack <= 1'b0;
      pbs_ack_cnt <= '0;
      pbs_read_cnt <= '0;
    end else begin
      pbs_inst_ack <= 1'b0;
      pbs_inst_load_blwe_ack <= 1'b0;
      
      if (pbs_inst_vld && pbs_inst_rdy) begin
        pbs_src_addr <= u_dut.vp_src_blwe_addr;
        pbs_dst_addr <= u_dut.vp_dst_result_addr;
        pbs_ack_cnt <= 8'd1;
        pbs_read_cnt <= 0;
        pbs_inst_rdy <= 1'b0;
        $display("[PBS_MODEL] Processing PBS instruction: src=0x%0h dst=0x%0h", 
                 u_dut.vp_src_blwe_addr, u_dut.vp_dst_result_addr);
      end else if (pbs_ack_cnt > 0) begin
        if (pbs_ack_cnt <= N_LVL1 + 1) begin
          // Read TLWE data
          if (pbs_read_cnt < N_LVL1) begin
            tlwe_a[pbs_read_cnt] <= regfile_memory[pbs_src_addr + pbs_read_cnt];
          end else if (pbs_read_cnt == N_LVL1) begin
            tlwe_b <= regfile_memory[pbs_src_addr + pbs_read_cnt];
          end
          pbs_read_cnt <= pbs_read_cnt + 1;
        end else if (pbs_ack_cnt == N_LVL1 + 2) begin
          // Perform Sample Extract
          lwe_b = tlwe_b;
          lwe_a[0] = tlwe_a[0];
          for (int j = 1; j < N_LVL1; j++) begin
            lwe_a[j] = -tlwe_a[N_LVL1 - j];
          end
          $display("[PBS_MODEL] Sample Extract: b=0x%0h, a[0]=0x%0h", lwe_b, lwe_a[0]);
        end else if (pbs_ack_cnt >= N_LVL1 + 3 && pbs_ack_cnt <= 2*N_LVL1 + 3) begin
          // Write LWE result
          int write_idx = pbs_ack_cnt - (N_LVL1 + 3);
          if (write_idx < N_LVL1) begin
            regfile_memory[pbs_dst_addr + write_idx] = lwe_a[write_idx];
          end else if (write_idx == N_LVL1) begin
            regfile_memory[pbs_dst_addr + write_idx] = lwe_b;
          end
        end else if (pbs_ack_cnt == 2*N_LVL1 + 4) begin
          pbs_inst_ack <= 1'b1;
          pbs_inst_load_blwe_ack <= 1'b1;
          pbs_inst_rdy <= 1'b1;
          $display("[PBS_MODEL] PBS processing completed");
        end
        pbs_ack_cnt <= pbs_ack_cnt + 1;
      end else begin
        pbs_ack_cnt <= '0;
        pbs_inst_rdy <= 1'b1;
      end
    end
  end

// ==============================================================================================
// Test Generation
// ==============================================================================================
  task generate_test_data();
    // Generate LUT table
    for (int i = 0; i < LUT_SIZE; i++) begin
      logic [31:0] base_value = 32'h8000 + i;
      // k=0: TLWE a polynomial
      for (int n = 0; n < N_LVL1; n++) begin
        test_lut_table[i][0][n] = base_value + n;
      end
      // k=1: TLWE b scalar
      test_lut_table[i][1][0] = base_value + 1000;
      for (int n = 1; n < N_LVL1; n++) begin
        test_lut_table[i][1][n] = 0;
      end
    end
    
    // Generate GGSW samples
    for (int bit_idx = 0; bit_idx < MAX_BIT_WIDTH; bit_idx++) begin
      logic [31:0] bit_value = (bit_idx % 3 == 0) ? 32'h80000000 : 32'h40000000;
      for (int l = 0; l < L_LVL1; l++) begin
        for (int k = 0; k <= K; k++) begin
          for (int n = 0; n < N_LVL1; n++) begin
            test_ggsw_samples[bit_idx][l][k][n] = bit_value + (k * 100) + n;
          end
        end
      end
      // Load to RegFile
      for (int n = 0; n < N_LVL1; n++) begin
        regfile_memory[ggsw_samples_base_addr + bit_idx * N_LVL1 + n] = test_ggsw_samples[bit_idx][0][0][n];
      end
    end
    
    $display("[TB] Test data generated");
  endtask

// ==============================================================================================
// Golden Reference (Simplified)
// ==============================================================================================
  task generate_golden_reference();
    // Simplified golden calculation
    golden_result_b = test_lut_table[0][1][0];  // Use first LUT entry b
    golden_result_a[0] = test_lut_table[0][0][0];  // Use first LUT entry a[0]
    for (int i = 1; i < N_LVL1; i++) begin
      golden_result_a[i] = test_lut_table[0][0][i] + i;  // Simple pattern
    end
    $display("[TB] Golden reference generated");
  endtask

// ==============================================================================================
// Main Test
// ==============================================================================================
  initial begin
    // Initialize
    start = 0;
    ggsw_samples_base_addr = 16'h1000;
    ggsw_samples_ready = 0;
    result_addr = 16'h2000;
    lut_base_addr = 64'h100000;
    
    // Wait for reset
    wait(s_rst_n);
    #100;
    
    // Generate test data
    generate_test_data();
    generate_golden_reference();
    
    // Start test
    ggsw_samples_ready = 1;
    start = 1;
    #10;
    start = 0;
    
    $display("[TB] Test started at time %0t", $time);
    
    // Wait for completion
    wait(done);
    #100;
    
    // Compare results
    $display("[TB] *** RESULT COMPARISON ***");
    int error_count = 0;
    
    if (actual_result_b != golden_result_b) begin
      error_count++;
      $display("[TB] Mismatch at b: RTL=0x%0h, Golden=0x%0h", actual_result_b, golden_result_b);
    end
    
    for (int i = 0; i < N_LVL1; i++) begin
      if (actual_result_a[i] != golden_result_a[i]) begin
        error_count++;
        if (error_count <= 10) begin  // Only show first 10 mismatches
          $display("[TB] Mismatch at a[%0d]: RTL=0x%0h, Golden=0x%0h", i, actual_result_a[i], golden_result_a[i]);
        end
      end
    end
    
    if (error_count == 0) begin
      $display("[TB] ✅ SUCCESS: All results match");
    end else begin
      $display("[TB] ❌ FAILURE: %0d mismatches found", error_count);
    end
    
    $display("[TB] Test completed at time %0t", $time);
    $finish;
  end
  
  // Timeout protection
  initial begin
    #200000;
    $error("[TB] Test timeout!");
    $finish;
  end

endmodule

