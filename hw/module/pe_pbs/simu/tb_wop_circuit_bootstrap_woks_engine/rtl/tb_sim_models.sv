// ==============================================================================================
// Filename: tb_sim_models.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// 仿真模型模块 - 包含所有非真实模式的模拟模型代码
// 从 tb_wop_circuit_bootstrap_woks_engine.sv 中分离出来，保持主TB简洁
//
// Author: Ray Pan 
// Date:   January 2025
// ==============================================================================================

`timescale 1ns/1ps

module tb_sim_models #(
  parameter int MOD_Q_W = 64,
  parameter int N_LVL0 = 16,
  parameter int N_LVL2 = 256,
  parameter int ELL_LVL2 = 8,
  parameter int K = 1,
  parameter int PSI = 1,
  parameter int R = 8,
  parameter int NTT_OP_W = 64,
  parameter int PBS_B_W = 32,
  parameter int BPBS_ID_W = 8,
  parameter int REGF_ADDR_W = 16
)(
  input  logic clk,
  input  logic s_rst_n,
  
  // BSK interface
  input  logic bsk_req_vld,
  output logic bsk_req_rdy,
  input  logic [7:0] bsk_batch_id,
  output logic bsk_data_avail,
  output logic [0:0][R-1:0][MOD_Q_W-1:0] bsk_data,
  
  // NTT decomp interface  
  input  logic [PSI-1:0][R-1:0] decomp_ntt_data_avail,
  input  logic [PSI-1:0][R-1:0][PBS_B_W:0] decomp_ntt_data,
  input  logic decomp_ntt_sob, decomp_ntt_eob,
  input  logic decomp_ntt_sog, decomp_ntt_eog,
  input  logic decomp_ntt_sol, decomp_ntt_eol,
  input  logic [BPBS_ID_W-1:0] decomp_ntt_pbs_id,
  input  logic decomp_ntt_last_pbs,
  input  logic decomp_ntt_full_throughput,
  input  logic decomp_ntt_ctrl_avail,
  output logic [PSI-1:0][R-1:0] decomp_ntt_data_rdy,
  output logic decomp_ntt_ctrl_rdy,
  
  // NTT output interface
  output logic [PSI-1:0][R-1:0][NTT_OP_W-1:0] ntt_next_data,
  output logic [PSI-1:0][R-1:0] ntt_next_data_avail,
  input  logic [PSI-1:0][R-1:0] ntt_next_data_rdy,
  output logic ntt_next_ctrl_avail,
  input  logic ntt_next_ctrl_rdy
);

  import param_tfhe_pkg::*;
  import param_ntt_pkg::*;
  import ntt_core_common_param_pkg::*;
  import regf_common_param_pkg::*;
  import common_definition_pkg::*;

// ==============================================================================================
// BSK 管理器模拟
// ==============================================================================================
  typedef struct {
    logic [MOD_Q_W-1:0] coefficients[R];
  } bsk_batch_t;
  
  bsk_batch_t bsk_storage[256];
  logic bsk_initialized = 1'b0;
  
  typedef enum logic [1:0] {
    BSK_IDLE,
    BSK_PROCESSING,
    BSK_DATA_READY
  } bsk_state_e;
  
  bsk_state_e bsk_state = BSK_IDLE;
  logic [7:0] current_bsk_batch;
  logic [3:0] bsk_latency_counter;
  
  initial begin
    bsk_initialized = 1'b0;
    #1000;
    $display("[TB_SIM] Initializing BSK storage with deterministic data...");
    for (int batch = 0; batch < 256; batch++) begin
      for (int r = 0; r < R; r++) begin
        bsk_storage[batch].coefficients[r] = {batch[7:0], 8'hAB, r[7:0], 8'hCD} ^ (batch * r);
      end
    end
    bsk_initialized = 1'b1;
    $display("[TB_SIM] BSK storage initialized (%0d batches)", 256);
  end
  
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      bsk_state <= BSK_IDLE;
      bsk_req_rdy <= 1'b0;
      bsk_data_avail <= 1'b0;
      bsk_data <= '0;
      current_bsk_batch <= '0;
      bsk_latency_counter <= '0;
    end else begin
      case (bsk_state)
        BSK_IDLE: begin
          bsk_req_rdy <= 1'b1;
          bsk_data_avail <= 1'b0;
          if (bsk_req_vld && bsk_req_rdy && bsk_initialized) begin
            current_bsk_batch <= bsk_batch_id;
            bsk_latency_counter <= 4'd3;
            bsk_state <= BSK_PROCESSING;
            bsk_req_rdy <= 1'b0;
            if (bsk_batch_id < 5) $display("[TB_SIM] BSK Manager - req batch_id=%0d", bsk_batch_id);
          end
        end
        BSK_PROCESSING: begin
          bsk_latency_counter <= bsk_latency_counter - 1;
          if (bsk_latency_counter == 1) begin
            for (int r = 0; r < R; r++) begin
              bsk_data[0][r] <= bsk_storage[current_bsk_batch].coefficients[r];
            end
            bsk_data_avail <= 1'b1;
            bsk_state <= BSK_DATA_READY;
          end
        end
        BSK_DATA_READY: begin
          if (bsk_req_vld) begin
            bsk_state <= BSK_IDLE;
            bsk_data_avail <= 1'b0;
          end
        end
      endcase
    end
  end

// ==============================================================================================
// NTT 服务模拟器（轻量）
// ==============================================================================================
  typedef enum logic [2:0] {
    NTT_IDLE,
    NTT_FORWARD_PROCESSING,
    NTT_EXTERNAL_PRODUCT,
    NTT_INVERSE_PROCESSING,
    NTT_RESULT_READY
  } ntt_state_e;

  ntt_state_e ntt_state;
  logic [7:0] ntt_process_counter;
  logic [31:0] ntt_op_count;
  logic [31:0] ntt_accept_count;
  localparam int NTT_EXPECTED_ACCEPTS = (K+1)*N_LVL2;

  localparam int NTT_FORWARD_CYCLES = 4;
  localparam int NTT_EXTERNAL_CYCLES = 2;
  localparam int NTT_INVERSE_CYCLES = 4;

  // NTT ready signals - always ready in simulation mode
  always_comb begin
    decomp_ntt_ctrl_rdy = 1'b1;
    for (int p = 0; p < PSI; p++) begin
      for (int r = 0; r < R; r++) begin
        decomp_ntt_data_rdy[p][r] = 1'b1;
      end
    end
  end

  // NTT Service State Machine - Simple deterministic behavior
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      ntt_state <= NTT_IDLE;
      ntt_next_data_avail <= '0;
      ntt_next_data <= '0;
      ntt_next_ctrl_avail <= 1'b0;
      ntt_process_counter <= '0;
      ntt_op_count <= '0;
      ntt_accept_count <= '0;
    end else begin
      case (ntt_state)
        NTT_IDLE: begin
          ntt_next_data_avail <= '0;
          ntt_next_ctrl_avail <= 1'b0;
          
          // Detect NTT request from DUT
          if (decomp_ntt_ctrl_avail && |decomp_ntt_data_avail) begin
            ntt_process_counter <= NTT_FORWARD_CYCLES;
            ntt_state <= NTT_FORWARD_PROCESSING;
            ntt_op_count <= ntt_op_count + 1;
            $display("[TB_SIM_NTT t=%0t] Forward NTT Start - Op: %0d", $time, ntt_op_count);
          end
        end
        
        NTT_FORWARD_PROCESSING: begin
          if (ntt_process_counter > 0) begin
            ntt_process_counter <= ntt_process_counter - 1;
          end else begin
            ntt_process_counter <= NTT_EXTERNAL_CYCLES;
            ntt_state <= NTT_EXTERNAL_PRODUCT;
            $display("[TB_SIM_NTT t=%0t] Forward Complete, starting External Product", $time);
          end
        end
        
        NTT_EXTERNAL_PRODUCT: begin
          if (ntt_process_counter > 0) begin
            ntt_process_counter <= ntt_process_counter - 1;
          end else begin
            ntt_process_counter <= NTT_INVERSE_CYCLES;
            ntt_state <= NTT_INVERSE_PROCESSING;
            $display("[TB_SIM_NTT t=%0t] External Product Complete, starting Inverse NTT", $time);
          end
        end
        
        NTT_INVERSE_PROCESSING: begin
          if (ntt_process_counter > 0) begin
            ntt_process_counter <= ntt_process_counter - 1;
          end else begin
            for (int p = 0; p < PSI; p++) begin
              for (int r = 0; r < R; r++) begin
                // 与简化NTT模拟器保持一致的算法，确保结果确定性
                automatic logic [31:0] base_val = ntt_op_count[15:0] * (p*R + r + 1);
                ntt_next_data[p][r] <= $signed(base_val ^ 32'h55AA3C96);
                ntt_next_data_avail[p][r] <= 1'b1;
              end
            end
            ntt_next_ctrl_avail <= 1'b1;
            ntt_accept_count <= '0;
            ntt_state <= NTT_RESULT_READY;
            $display("[TB_SIM_NTT t=%0t] Inverse NTT Complete, result ready", $time);
          end
        end
        
        NTT_RESULT_READY: begin
          int accept_incr;
          accept_incr = 0;
          for (int p = 0; p < PSI; p++) begin
            for (int r = 0; r < R; r++) begin
              if (ntt_next_data_avail[p][r] && ntt_next_data_rdy[p][r] && ntt_next_ctrl_rdy) begin
                accept_incr++;
              end
            end
          end
          if (accept_incr != 0) begin
            ntt_accept_count <= ntt_accept_count + accept_incr;
            $display("[TB_SIM_NTT t=%0t] Accepted %0d items, total=%0d/%0d", $time, accept_incr, ntt_accept_count + accept_incr, NTT_EXPECTED_ACCEPTS);
          end
          if ((ntt_accept_count + accept_incr) >= NTT_EXPECTED_ACCEPTS) begin
            ntt_next_data_avail <= '0;
            ntt_next_ctrl_avail <= 1'b0;
            ntt_state <= NTT_IDLE;
            $display("[TB_SIM_NTT t=%0t] Result accepted, returning to IDLE (accepted=%0d)", $time, ntt_accept_count + accept_incr);
          end else begin
            ntt_next_ctrl_avail <= 1'b1;
            for (int p = 0; p < PSI; p++) begin
              for (int r = 0; r < R; r++) begin
                ntt_next_data_avail[p][r] <= 1'b1;
              end
            end
          end
        end
      endcase
    end
  end

endmodule

