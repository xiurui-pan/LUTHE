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
  import pep_common_param_pkg::*;
  import hpu_common_instruction_pkg::*;
  import vp_pbs_inst_pkg::*;
  // 🎯 策略A解决方案：通过构建配置强制使用BSK_PC=1
#(
  parameter int MOD_Q_W = 32,
  parameter int MAX_BIT_WIDTH = 20,
  parameter int N_LVL1 = 1024,
  parameter int ELL_LVL1 = 3,
  parameter int BSK_PC = 1,     // BSK port count - 匹配BSK_CUT_NB=1
  parameter int KSK_PC = 2      // KSK port count - 匹配实际TOP_PC配置
)();

// ==============================================================================================
// Parameters
// ==============================================================================================
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
  
  // 共享RegFile接口信号
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
  
  // VP Engine独立RegFile信号
  logic vp_regf_rd_req_vld;
  logic [REGF_RD_REQ_W-1:0] vp_regf_rd_req;
  logic vp_regf_wr_req_vld;
  logic [REGF_WR_REQ_W-1:0] vp_regf_wr_req;
  logic [REGF_COEF_NB-1:0] vp_regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] vp_regf_wr_data;
  
  // PBS Kernel Lite独立RegFile信号
  logic pbs_regf_rd_req_vld;
  logic [REGF_RD_REQ_W-1:0] pbs_regf_rd_req;
  logic pbs_regf_wr_req_vld;
  logic [REGF_WR_REQ_W-1:0] pbs_regf_wr_req;
  logic [REGF_COEF_NB-1:0] pbs_regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] pbs_regf_wr_data;
  
  // VP-PBS interface signals (new protocol)
  vp_pbs_inst_t vp_pbs_inst;
  logic vp_pbs_inst_vld;
  logic vp_pbs_inst_rdy;
  logic vp_pbs_inst_ack;
  vp_pbs_response_t vp_pbs_response;
  

  
  // RegFile memory simulation
  logic [MOD_Q_W-1:0] regfile_memory [0:65535];
  
  // Track captured result write index
  int actual_write_index;

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
  
  // RegFile interface helper variables
  regf_rd_req_t rd_req_temp;
  regf_wr_req_t wr_req_temp;
  
  // Golden reference variables
  int golden_ggsw_bits[MAX_BIT_WIDTH];
  int golden_lut_table[LUT_SIZE];  
  int golden_result_a[N_LVL1];
  int golden_result_b;
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
    .REGF_ADDR_W(REGF_ADDR_W),
    .LUT_SIZE(LUT_SIZE)
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
    .regf_rd_req_vld(vp_regf_rd_req_vld),
    .regf_rd_req_rdy(regf_rd_req_rdy),
    .regf_rd_req(vp_regf_rd_req),
    .regf_rd_data_avail(regf_rd_data_avail),
    .regf_rd_data(regf_rd_data),
    .regf_wr_req_vld(vp_regf_wr_req_vld),
    .regf_wr_req_rdy(regf_wr_req_rdy),
    .regf_wr_req(vp_regf_wr_req),
    .regf_wr_data_vld(vp_regf_wr_data_vld),
    .regf_wr_data_rdy(regf_wr_data_rdy),
    .regf_wr_data(vp_regf_wr_data),
    // VP-PBS service interface (connected to wop_pbs_kernel)
    .vp_pbs_inst(vp_pbs_inst),
    .vp_pbs_inst_vld(vp_pbs_inst_vld),
    .vp_pbs_inst_rdy(vp_pbs_inst_rdy),
    .vp_pbs_inst_ack(vp_pbs_inst_ack),
    .vp_pbs_response(vp_pbs_response)
  );

// ==============================================================================================
// Real wop_pbs_kernel Integration (VP-PBS Protocol)  
// ==============================================================================================

  // WOP PBS Kernel接口信号
  logic [PE_INST_W-1:0] wop_pbs_inst;
  logic wop_pbs_inst_vld;
  logic wop_pbs_inst_rdy;
  logic wop_pbs_inst_ack;
  
  // 简化的共享接口信号 (测试用)
  logic reset_bsk_cache = 1'b0;
  logic reset_bsk_cache_done;
  logic bsk_mem_avail = 1'b1;
  logic [1:0][axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] bsk_mem_addr = '0;
  logic reset_ksk_cache = 1'b0;
  logic reset_ksk_cache_done;
  logic ksk_mem_avail = 1'b1;
  logic [1:0][axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] ksk_mem_addr = '0;
  logic reset_cache = 1'b0;
  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] gid_offset = '0;
  logic [1:0][7:0][MOD_Q_W-1:0] twd_omg_ru_r_pow = '0;
  
  // Real wop_pbs_kernel_lite实例化 (精简版，专为VP服务)
  wop_pbs_kernel_lite #(
    .MOD_Q_W(MOD_Q_W),
    .MAX_BIT_WIDTH(MAX_BIT_WIDTH),
    .N_LVL1(N_LVL1),
    .ELL_LVL1(ELL_LVL1),
    .K(K),
    .REGF_ADDR_W(REGF_ADDR_W),
    .BSK_PC(BSK_PC),
    .KSK_PC(KSK_PC)
  ) u_wop_pbs_kernel_lite (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // VP-PBS专用接口 (连接到VP Engine) - 精简版只有VP接口
    .vp_pbs_inst(vp_pbs_inst),
    .vp_pbs_inst_vld(vp_pbs_inst_vld),
    .vp_pbs_inst_rdy(vp_pbs_inst_rdy),
    .vp_pbs_inst_ack(vp_pbs_inst_ack),
    .vp_pbs_response(vp_pbs_response),
    
    // RegFile接口 (简化，只连接关键信号)
    .pep_regf_wr_req_vld(pbs_regf_wr_req_vld),
    .pep_regf_wr_req_rdy(regf_wr_req_rdy),
    .pep_regf_wr_req(pbs_regf_wr_req),
    .pep_regf_wr_data_vld(pbs_regf_wr_data_vld),
    .pep_regf_wr_data_rdy(regf_wr_data_rdy),
    .pep_regf_wr_data(pbs_regf_wr_data),
    .regf_pep_wr_ack(1'b1), // 简化应答
    
    .pep_regf_rd_req_vld(pbs_regf_rd_req_vld),
    .pep_regf_rd_req_rdy(regf_rd_req_rdy),
    .pep_regf_rd_req(pbs_regf_rd_req),
    .regf_pep_rd_data_avail(regf_rd_data_avail),
    .regf_pep_rd_data(regf_rd_data),
    .regf_pep_rd_last_word(1'b1),
    
    // AXI接口 (简化，连接到LUT模拟器)
    .m_axi4_glwe_arid(),
    .m_axi4_glwe_araddr(),
    .m_axi4_glwe_arlen(),
    .m_axi4_glwe_arsize(),
    .m_axi4_glwe_arburst(),
    .m_axi4_glwe_arvalid(),
    .m_axi4_glwe_arready(lut_req_rdy),
    .m_axi4_glwe_rid('0),
    .m_axi4_glwe_rdata(lut_data),
    .m_axi4_glwe_rresp('0),
    .m_axi4_glwe_rlast(1'b1),
    .m_axi4_glwe_rvalid(lut_data_avail),
    .m_axi4_glwe_rready()
  );
  
  // ==============================================================================================
  // RegFile接口仲裁器 (VP Engine vs PBS Kernel Lite)
  // ==============================================================================================
  
  // 简单优先级仲裁：VP优先，PBS其次
  always_comb begin
    // 默认分配给VP Engine
    regf_rd_req_vld = vp_regf_rd_req_vld;
    regf_rd_req = vp_regf_rd_req;
    regf_wr_req_vld = vp_regf_wr_req_vld;
    regf_wr_req = vp_regf_wr_req;
    regf_wr_data_vld = vp_regf_wr_data_vld;
    regf_wr_data = vp_regf_wr_data;
    
    // 如果VP不活跃，分配给PBS
    if (!vp_regf_rd_req_vld && !vp_regf_wr_req_vld) begin
      regf_rd_req_vld = pbs_regf_rd_req_vld;
      regf_rd_req = pbs_regf_rd_req;
      regf_wr_req_vld = pbs_regf_wr_req_vld;
      regf_wr_req = pbs_regf_wr_req;
      regf_wr_data_vld = pbs_regf_wr_data_vld;
      regf_wr_data = pbs_regf_wr_data;
    end
  end
  
  // 初始化共享接口信号
  initial begin
    wop_pbs_inst_vld = 1'b0;
    wop_pbs_inst = '0;
  end
  
  // 旧的简化PBS逻辑已删除，现在使用真实的wop_pbs_kernel



// ==============================================================================================
// LUT Signal Monitor
// ==============================================================================================
  // Variables for LUT driver
  logic [31:0] entry_idx;
  
  // Simple LUT data driver with proper handshake protocol
  always @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      lut_req_rdy <= 1'b1;
      lut_data_avail <= 1'b0;
      lut_data <= '0;
    end else begin
      if (lut_req_vld && lut_req_rdy) begin
        // Step 1: Request received, provide data and deassert ready
        lut_req_rdy <= 1'b0;
        lut_data_avail <= 1'b1;
        // Calculate which LUT entry based on address
        entry_idx = (lut_addr - lut_base_addr) >> 7;
        if (entry_idx < LUT_SIZE) begin
          lut_data <= {test_lut_table[entry_idx][0][3], test_lut_table[entry_idx][0][2],
                      test_lut_table[entry_idx][0][1], test_lut_table[entry_idx][0][0]};
          $display("[LUT_DRIVER] Providing LUT[%0d] = 0x%0h at time %0t",
                   entry_idx, {test_lut_table[entry_idx][0][3], test_lut_table[entry_idx][0][2],
                              test_lut_table[entry_idx][0][1], test_lut_table[entry_idx][0][0]}, $time);
        end else begin
          lut_data <= '0;
        end
      end else if (!lut_req_vld && !lut_req_rdy) begin
        // Step 2: Request deasserted, reset for next transaction
        lut_req_rdy <= 1'b1;
        lut_data_avail <= 1'b0;
        $display("[LUT_DRIVER] Transaction completed, ready for next request at time %0t", $time);
      end
    end
  end

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
      $display("[LUT_SIM] *** LUT SIMULATOR RESET *** at time %0t", $time);
    end else begin
      // Debug: Print key events (simplified)
      if (lut_req_vld && lut_req_rdy) begin
        $display("[LUT_SIM] *** REQUEST DETECTED *** addr=0x%0h at time %0t", lut_addr, $time);
      end
      case (lut_state)
        LUT_IDLE: begin
          lut_req_rdy <= 1'b1;
          lut_data_avail <= 1'b0;
          
          if (lut_req_vld && lut_req_rdy) begin
            lut_state <= LUT_PROCESSING;
            lut_access_counter <= 0;
            $display("[LUT_SIM] *** LUT REQUEST RECEIVED *** addr=0x%0h at time %0t", lut_addr, $time);
          end
        end
        
        LUT_PROCESSING: begin
          lut_req_rdy <= 1'b0;
          lut_access_counter <= lut_access_counter + 1;
          $display("[LUT_SIM] Processing cycle %0d/5 at time %0t", lut_access_counter, $time);
          
          // Simulate memory access latency
          if (lut_access_counter >= 5) begin
            lut_state <= LUT_READY;
            lut_data_avail <= 1'b1;
            $display("[LUT_SIM] *** ENTERING DATA PREPARATION *** at time %0t", $time);
            
            // Calculate which LUT entry to return
            // RTL uses 128-byte steps, so divide by 128
            entry_index = (lut_addr - lut_base_addr) >> 7;  // >> 7 = / 128
            $display("[LUT_SIM] Address calculation: addr=0x%0h, base=0x%0h, entry_index=%0d", 
                     lut_addr, lut_base_addr, entry_index);
            if (entry_index < LUT_SIZE) begin
              // Return packed LUT data - first 4 coefficients for simplicity
              // Format: lut_data[127:0] = {coef[3], coef[2], coef[1], coef[0]}
              lut_data <= {test_lut_table[entry_index][0][3], test_lut_table[entry_index][0][2], 
                          test_lut_table[entry_index][0][1], test_lut_table[entry_index][0][0]};
              $display("[LUT_SIM] *** PREPARING DATA *** Returning LUT entry %0d: data=0x%0h (coef[0]=%0h)", 
                       entry_index, {test_lut_table[entry_index][0][3], test_lut_table[entry_index][0][2], 
                                   test_lut_table[entry_index][0][1], test_lut_table[entry_index][0][0]},
                       test_lut_table[entry_index][0][0]);
            end else begin
              lut_data <= '0;
              $display("[LUT_SIM] ERROR: Invalid LUT entry %0d (>= %0d)", entry_index, LUT_SIZE);
            end
          end
        end
        
        LUT_READY: begin
          lut_req_rdy <= 1'b1;        // Keep ready asserted for handshake completion
          lut_data_avail <= 1'b1;
          if (!lut_req_vld) begin  // Wait for request to be deasserted
            lut_state <= LUT_IDLE;
            lut_data_avail <= 1'b0;
            $display("[LUT_SIM] LUT handshake completed, returning to IDLE at time %0t", $time);
          end
        end
      endcase
    end
  end

  // ==============================================================================================
  // PBS Instruction Monitor (format sanity check against kernel decode slices)
  // ==============================================================================================
  // 原有的PBS监控逻辑已移除，现在使用VP-PBS接口
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      // do nothing
    end else begin
      if (vp_pbs_inst_vld && vp_pbs_inst_rdy) begin
        $display("[TB][VP_PBS_MON] VP-PBS request: operation=%0d, cmux_addr=0x%0h, output_addr=0x%0h", 
                 vp_pbs_inst.operation_type, vp_pbs_inst.cmux_result_addr, vp_pbs_inst.output_addr);
      end
      
      if (vp_pbs_inst_ack) begin
        $display("[TB][VP_PBS_MON] VP-PBS response ACK: state=%0d, success=%b", 
                 vp_pbs_response.current_state, vp_pbs_response.success);
      end
      
      // 定期检查VP-PBS握手信号状态
      if ($time % 100000 == 0) begin
        $display("[TB][VP_PBS_STATUS] at time %0t: vld=%b, rdy=%b, ack=%b, response_state=%0d, vp_state=%s", 
                 $time, vp_pbs_inst_vld, vp_pbs_inst_rdy, vp_pbs_inst_ack, vp_pbs_response.current_state, u_dut.current_state.name());
      end
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
      // Initialize regfile_memory to zero to avoid X propagation
      for (int i = 0; i < 65536; i++) begin
        regfile_memory[i] <= '0;
      end
    end else begin
      case (regf_rd_state)
        REGF_RD_IDLE: begin
          regf_rd_req_rdy <= 1'b1;
          regf_rd_data_avail <= '0;
          
          if (regf_rd_req_vld && regf_rd_req_rdy) begin
            regf_rd_state <= REGF_RD_PROCESSING;
            regf_rd_counter <= 0;
            rd_req_temp <= regf_rd_req;
            $display("[REGF_SIM] RegFile read request: req=0x%0h at time %0t", 
                     regf_rd_req, $time);
          end
        end
        
        REGF_RD_PROCESSING: begin
          regf_rd_req_rdy <= 1'b0;
          regf_rd_counter <= regf_rd_counter + 1;
          
          // Simulate regfile access latency
          if (regf_rd_counter >= 3) begin
            regf_rd_state <= REGF_RD_READY;
            regf_rd_data_avail[0] <= 1'b1;
            
            // Generic read-back: return regfile_memory at requested address
            begin
              logic [REGF_ADDR_W-1:0] read_addr;
              read_addr = rd_req_temp[REGF_RD_REQ_W-1 -: REGF_ADDR_W];
              regf_rd_data[0] <= regfile_memory[read_addr];
              $display("[REGF_SIM] Returning data from addr=0x%0h: %0h", read_addr, regfile_memory[read_addr]);
            end
          end
        end
        
        REGF_RD_READY: begin
          regf_rd_req_rdy <= 1'b1;        // Keep ready asserted for handshake completion
          regf_rd_data_avail[0] <= 1'b1;
          if (!regf_rd_req_vld) begin
            regf_rd_state <= REGF_RD_IDLE;
            regf_rd_data_avail <= '0;
            $display("[REGF_SIM] RegFile handshake completed at time %0t", $time);
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
      actual_write_index <= 0;
    end else begin
      regf_wr_req_rdy <= 1'b1;
      regf_wr_data_rdy <= '1;
      
      if (regf_wr_req_vld && regf_wr_data_vld[0]) begin
        wr_req_temp <= regf_wr_req;
        
        // Write to regfile_memory
        begin
          automatic logic [REGF_ADDR_W-1:0] write_addr = regf_wr_req[REGF_WR_REQ_W-1 -: REGF_ADDR_W];
          regfile_memory[write_addr] <= regf_wr_data[0];
        end
        
        // Capture full result vector sequentially
        if (actual_write_index < N_LVL1) begin
          actual_result_a[actual_write_index] <= regf_wr_data[0];
          actual_write_index <= actual_write_index + 1;
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
          // Fill entire polynomial with distinct non-zero values
          test_lut_table[i][k][n] = base_value + n + (k * 100000);
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

  task automatic dump_lut_and_bits_to_files(string lut_path, string bits_path);
    int fh_lut, fh_bits;
    fh_lut = $fopen(lut_path, "w");
    if (fh_lut == 0) $fatal("[TB] Failed to open %s", lut_path);
    for (int i = 0; i < LUT_SIZE; i++) begin
      for (int n = 0; n < N_LVL1; n++) begin
        $fwrite(fh_lut, "%0d ", int'(test_lut_table[i][0][n]));
      end
      $fwrite(fh_lut, "\n");
    end
    $fclose(fh_lut);

    fh_bits = $fopen(bits_path, "w");
    if (fh_bits == 0) $fatal("[TB] Failed to open %s", bits_path);
    for (int d = 0; d < 20; d++) begin
      $fwrite(fh_bits, "%0d\n", golden_ggsw_bits[d] & 1);
    end
    $fclose(fh_bits);
  endtask

  function automatic int load_golden_from_file(string out_path);
    int fh;
    fh = $fopen(out_path, "r");
    if (fh == 0) begin
      $display("[TB] Failed to open golden output %s", out_path);
      return 0;
    end
    for (int i = 0; i < N_LVL1; i++) begin
      int val;
      if ($fscanf(fh, "%d\n", val) != 1) begin
        $display("[TB] Error reading golden at line %0d", i);
        $fclose(fh);
        return 0;
      end
      golden_result_a[i] = val;
    end
    $fclose(fh);
    return 1;
  endfunction

// ==============================================================================================
// Golden Reference - SystemVerilog Implementation (no DPI-C needed)
// ==============================================================================================
  
  // No DPI-C functions needed - using simple SystemVerilog logic
  
  // Simplified vertical packing golden reference
  function automatic void generate_expected_results();
    // Baseline-like golden using simplified semantics consistent with test data
    int selected_index;
    int rotation_shift;
    int bit_value;
    int src_idx;
    int poly_val;

    // 1) CMux tree selection index from bits 10..19 (MSB first)
    selected_index = 0;
    for (int d = 10; d < 20; d++) begin
      bit_value = golden_ggsw_bits[d] & 1;
      selected_index = (selected_index << 1) | bit_value;
    end

    // 2) Rotation shift from bits 0..9: sum of 2^d where bit is 1
    rotation_shift = 0;
    for (int d = 0; d < 10; d++) begin
      if (golden_ggsw_bits[d]) begin
        rotation_shift += (1 << d);
      end
    end
    rotation_shift = rotation_shift % N_LVL1;

    // 3) Sample extract directly from rotated polynomial
    // a[0] = poly[(0 + rotation_shift) % N]
    // a[i] = -poly[(N - i + rotation_shift) % N] for i>=1
    for (int i = 0; i < N_LVL1; i++) begin
      if (i == 0) begin
        src_idx = (0 + rotation_shift) % N_LVL1;
        poly_val = int'(test_lut_table[selected_index][0][src_idx]);
        golden_result_a[i] = poly_val;
      end else begin
        src_idx = (N_LVL1 - i + rotation_shift) % N_LVL1;
        poly_val = int'(test_lut_table[selected_index][0][src_idx]);
        golden_result_a[i] = -poly_val;
      end
    end

    $display("[GOLDEN] Baseline-like: index=%0d, rot=%0d, a0=%0h, a1=%0h", selected_index, rotation_shift,
             golden_result_a[0], golden_result_a[1]);
  endfunction

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
    $display("[TB] Releasing reset at time %0t", $time);
    s_rst_n = 1;
    $display("[TB] Reset released, s_rst_n=%b at time %0t", s_rst_n, $time);
    repeat(5) @(posedge clk);
    $display("[TB] Reset sequence completed, s_rst_n=%b at time %0t", s_rst_n, $time);
    
    // Generate test data
    generate_test_data();
    
    // Prepare inputs
    ggsw_samples_ready = 1;
    
    // Start test
    $display("[TB] Starting vertical packing test at time %0t", $time);
    $display("[TB] Inputs: bit_width=%0d, ggsw_samples_ready=%0b", bit_width, ggsw_samples_ready);
    start = 1;
    @(posedge clk);
    start = 0;
    $display("[TB] Start pulse sent, now waiting for done signal...");
    
    // Wait for completion with timeout
    fork
      begin
        wait(done);
        $display("[TB] Vertical packing completed at time %0t", $time);
      end
      begin
        // Monitor DUT status every 1000 cycles (less frequent)
        repeat(50) begin
          repeat(1000) @(posedge clk);
          $display("[TB] Status check: current_state=%s, regf_rd_req_vld=%b, regf_rd_req_rdy=%b, regf_rd_data_avail=%b, ggsw_load_done=%b at time %0t", 
                   u_dut.current_state.name(), regf_rd_req_vld, regf_rd_req_rdy, regf_rd_data_avail[0], u_dut.done, $time);
        end
        $error("[TB] Test timeout!");
        $finish;
      end
    join_any
    disable fork;
    
    // After done, pull actual results from PBS dst region in regfile_memory
    // to avoid relying on write-capture path.
    $display("[TB] Captured %0d coefficients via write path", actual_write_index);
    if (actual_write_index < N_LVL1) begin
      $display("[TB] WARNING: Only %0d/%0d coefficients captured from write path", actual_write_index, N_LVL1);
    end

    // Build actual_result_a from VP-PBS output region (authoritative)
    for (int i = 0; i < N_LVL1; i++) begin
      actual_result_a[i] = regfile_memory[result_addr + i];
    end
    
    // Call golden reference for comparison
    
    // Prepare golden reference inputs - extract control bits from GGSW samples
    for (int i = 0; i < MAX_BIT_WIDTH; i++) begin
      int ggsw_value = int'(test_ggsw_samples[i][0][0][0]);
      golden_ggsw_bits[i] = (ggsw_value % 1000) > 500 ? 1 : 0;  // Extract control bit
    end
    for (int i = 0; i < LUT_SIZE; i++) begin
      golden_lut_table[i] = int'(test_lut_table[i][0][0]);  // Type conversion
    end

    // External golden path
    dump_lut_and_bits_to_files("output_lut.txt", "output_bits.txt");
    $display("[TB] Running external golden generator...");
    void'($system($sformatf("../big_lut_simplified %s %s %s %0d %0d", "output_lut.txt", "output_bits.txt", "output_golden.txt", N_LVL1, LUT_SIZE)));
    if (!load_golden_from_file("output_golden.txt")) begin
      $fatal("[TB] Failed to load external golden results");
    end

    // SV internal golden for cross-check (can be removed later)
    generate_expected_results();

    // Sanity: detect X in actual/golden vectors
    begin
      int x_count;
      x_count = 0;
      for (int i = 0; i < N_LVL1; i++) begin
        if ($isunknown(actual_result_a[i])) begin
          x_count++;
          if (x_count <= 8) $display("[TB] X detected at actual_result_a[%0d]=%0h", i, actual_result_a[i]);
        end
        if ($isunknown(golden_result_a[i])) begin
          x_count++;
          if (x_count <= 8) $display("[TB] X detected at golden_result_a[%0d]=%0h", i, golden_result_a[i]);
        end
      end
      if (x_count > 0) begin
        $display("[TB] ❌ FAILURE: %0d X values detected in results, aborting compare", x_count);
        $finish;
      end
    end

    // Compare results
    error_count = 0;
    for (int i = 0; i < N_LVL1; i++) begin
      if (actual_result_a[i] != golden_result_a[i]) begin
        error_count++;
        if (error_count <= 16) begin
          $display("[TB] Mismatch at a[%0d]: RTL=%0h, Golden=%0h", i, actual_result_a[i], golden_result_a[i]);
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