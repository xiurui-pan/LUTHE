// ==============================================================================================
// Filename: tb_wop_circuit_bootstrap_woks_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// 精简的测试平台，专注于真实模式（USE_REAL_CORES=1）的调试和验证
// 非真实模式的仿真模型已分离到 tb_sim_models.sv
//
// Author: Ray Pan 
// Date:   8.11. 2025 (Refactored)
// ==============================================================================================

`timescale 1ns/1ps

module tb_wop_circuit_bootstrap_woks_engine;

  import param_tfhe_pkg::*;
  import param_ntt_pkg::*;
  import ntt_core_common_param_pkg::*;
  import regf_common_param_pkg::*;
  import common_definition_pkg::*;
  import pep_if_pkg::*;
  import top_common_param_pkg::*;
  import pep_common_param_pkg::*;
  import bsk_if_common_param_pkg::*;
  import bsk_mgr_common_param_pkg::*;
  import axi_if_common_param_pkg::*;
  import axi_if_bsk_axi_pkg::*;
  import hpu_common_instruction_pkg::*;

// ==============================================================================================
// Parameters - 真实模式专用
// ==============================================================================================
  parameter int MOD_Q_W = 64;
  parameter int N_LVL0 = 16;
  parameter int N_LVL2 = 256;
  parameter int ELL_LVL2 = 8;
  parameter int K = 1;
  parameter int PSI = 32;
  parameter int BPBS_ID_W = 8;
  parameter int REGF_ADDR_W = 16;
  parameter int NTT_OP_W = 64;
  parameter int R = 2;
  parameter int PBS_B_W = 32;
  
  // 固定为真实模式
  parameter bit USE_REAL_CORES = 1'b1;
  parameter bit USE_DPI_GOLDEN = 1'b0;
  parameter bit APPLY_POST_SCALE = 1'b0;

  // Test control parameters
  localparam int CLK_HALF_PERIOD = 5;

// ==============================================================================================
// Clock and Reset
// ==============================================================================================
  logic clk;
  logic a_rst_n;
  logic s_rst_n;
  
  initial begin
    clk = 0;
    a_rst_n = 0;
    $display("[TB] ===== STARTUP DEBUG =====");
    $display("[TB] Reset start at t=%0t", $time);
    $display("[TB] Parameters: N_LVL0=%0d N_LVL2=%0d ELL_LVL2=%0d R=%0d PSI=%0d", N_LVL0, N_LVL2, ELL_LVL2, R, PSI);
    $display("[TB] _2L=%0d (should be %0d)", 2*ELL_LVL2, 2*ELL_LVL2);
    #17 a_rst_n = 1;
    $display("[TB] Reset released at t=%0t", $time);
    $display("[TB] ===========================");
  end
  
  always begin
    #CLK_HALF_PERIOD clk = ~clk;
  end
  
  always_ff @(posedge clk) begin
    s_rst_n <= a_rst_n;
  end

// ==============================================================================================
// Test Status
// ==============================================================================================
  typedef enum logic [1:0] { TEST_UNKNOWN, TEST_PASSED, TEST_FAILED, TEST_TIMEOUT } test_status_e;
  test_status_e test_status = TEST_UNKNOWN;

// ==============================================================================================
// DUT Signals
// ==============================================================================================
  logic start;
  logic [MOD_Q_W-1:0] mu_value;
  logic done;
  
  logic [N_LVL0:0][63:0] abar_data;
  logic abar_valid;
  
  logic [N_LVL2-1:0][MOD_Q_W-1:0] result_a;
  logic [MOD_Q_W-1:0] result_b;
  logic result_valid;
  
  // BSK interface
  logic bsk_req_vld;
  logic bsk_req_rdy;
  logic [7:0] bsk_batch_id;
  logic bsk_data_avail;
  logic [0:0][R-1:0][MOD_Q_W-1:0] bsk_data;
  
  // RegFile interface
  logic regf_wr_req_vld;
  logic regf_wr_req_rdy;
  logic [REGF_WR_REQ_W-1:0] regf_wr_req;
  logic [REGF_COEF_NB-1:0] regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0] regf_wr_data_rdy;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_wr_data;
  logic regf_rd_req_vld;
  logic regf_rd_req_rdy;
  logic [REGF_RD_REQ_W-1:0] regf_rd_req;
  logic [REGF_COEF_NB-1:0] regf_rd_data_avail;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_rd_data;
  logic regf_rd_last_word;
  
  // NTT interface
  logic [PSI-1:0][R-1:0] decomp_ntt_data_avail;
  logic [PSI-1:0][R-1:0][PBS_B_W:0] decomp_ntt_data;
  logic decomp_ntt_sob, decomp_ntt_eob;
  logic decomp_ntt_sog, decomp_ntt_eog;
  logic decomp_ntt_sol, decomp_ntt_eol;
  logic [BPBS_ID_W-1:0] decomp_ntt_pbs_id;
  logic decomp_ntt_last_pbs;
  logic decomp_ntt_full_throughput;
  logic decomp_ntt_ctrl_avail;
  logic [PSI-1:0][R-1:0] decomp_ntt_data_rdy;
  logic decomp_ntt_ctrl_rdy;
  logic [PSI-1:0][R-1:0][NTT_OP_W-1:0] ntt_next_data;
  logic [PSI-1:0][R-1:0] ntt_next_data_avail;
  logic [PSI-1:0][R-1:0] ntt_next_data_rdy;
  logic ntt_next_ctrl_avail;
  logic ntt_next_ctrl_rdy;

// ==============================================================================================
// DUT Instantiation - WoKS Engine
// ==============================================================================================
  wop_circuit_bootstrap_woks_engine #(
    .MOD_Q_W(MOD_Q_W),
    .N_LVL0(N_LVL0),
    .N_LVL2(N_LVL2),
    .ELL_LVL2(ELL_LVL2),
    .K(K),
    .BSK_BATCH_ID_W(8),
    .BSK_PC(1),
    .R(R),
    .PSI(PSI),
    .BPBS_ID_W(8),
    .REGF_ADDR_W(16),
    .NTT_OP_W(NTT_OP_W),
    .PBS_B_W(32),
    .APPLY_POST_SCALE(APPLY_POST_SCALE)
  ) dut (
    .clk(clk),
    .s_rst_n(s_rst_n),
    
    // Control interface
    .start(start),
    .mu_value(mu_value),
    .done(done),
    
    // RegFile interface
    .regf_wr_req_vld(regf_wr_req_vld),
    .regf_wr_req_rdy(regf_wr_req_rdy),
    .regf_wr_req(regf_wr_req),
    .regf_wr_data_vld(regf_wr_data_vld),
    .regf_wr_data_rdy(regf_wr_data_rdy),
    .regf_wr_data(regf_wr_data),
    .regf_rd_req_vld(regf_rd_req_vld),
    .regf_rd_req_rdy(regf_rd_req_rdy),
    .regf_rd_req(regf_rd_req),
    .regf_rd_data_avail(regf_rd_data_avail),
    .regf_rd_data(regf_rd_data),
    .regf_rd_last_word(regf_rd_last_word),
    
    // Input: pre-modswitch result
    .abar_data(abar_data),
    .abar_valid(abar_valid),
    
    // Output: LWE sample at level 2
    .result_a(result_a),
    .result_b(result_b),
    .result_valid(result_valid),
    
    // NTT interface
    .decomp_ntt_data_avail(decomp_ntt_data_avail),
    .decomp_ntt_data(decomp_ntt_data),
    .decomp_ntt_sob(decomp_ntt_sob),
    .decomp_ntt_eob(decomp_ntt_eob),
    .decomp_ntt_sog(decomp_ntt_sog),
    .decomp_ntt_eog(decomp_ntt_eog),
    .decomp_ntt_sol(decomp_ntt_sol),
    .decomp_ntt_eol(decomp_ntt_eol),
    .decomp_ntt_pbs_id(decomp_ntt_pbs_id),
    .decomp_ntt_last_pbs(decomp_ntt_last_pbs),
    .decomp_ntt_full_throughput(decomp_ntt_full_throughput),
    .decomp_ntt_ctrl_avail(decomp_ntt_ctrl_avail),
    .decomp_ntt_data_rdy(decomp_ntt_data_rdy),
    .decomp_ntt_ctrl_rdy(decomp_ntt_ctrl_rdy),
    .ntt_next_data(ntt_next_data),
    .ntt_next_data_avail(ntt_next_data_avail),
    .ntt_next_data_rdy(ntt_next_data_rdy),
    .ntt_next_ctrl_avail(ntt_next_ctrl_avail),
    .ntt_next_ctrl_rdy(ntt_next_ctrl_rdy),
    
    // BSK interface
    .bsk_req_vld(bsk_req_vld),
    .bsk_req_rdy(bsk_req_rdy),
    .bsk_batch_id(bsk_batch_id),
    .bsk_data_avail(bsk_data_avail),
    .bsk_data(bsk_data)
  );

// ==============================================================================================
// 真实NTT头部与BSK集成 - 主要调试目标
// ==============================================================================================

  // BSK控制信号
  logic reset_bsk_cache;
  logic reset_bsk_cache_done;
  logic bsk_mem_avail;
  logic [BSK_PC_MAX-1:0][axi_if_bsk_axi_pkg::AXI4_ADD_W-1:0] bsk_mem_addr;
  br_batch_cmd_t br_batch_cmd;
  logic br_batch_cmd_avail;
  logic bsk_if_batch_start_1h;
  logic inc_bsk_wr_ptr;
  logic inc_bsk_rd_ptr;

  // 真实BSK输出到NTT头部
  logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0][MOD_NTT_W-1:0] real_bsk;
  logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0] real_bsk_vld;
  logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0] real_bsk_rdy;

  // 门控信号（从DUT到真实头部）
  logic [PSI-1:0][R-1:0] decomp_avail_g;
  logic decomp_ctrl_avail_g;
  logic decomp_sob_g, decomp_eob_g;
  logic decomp_sog_g, decomp_eog_g;
  logic decomp_sol_g, decomp_eol_g;

  // 真实头部输出
  logic [PSI-1:0][R-1:0][NTT_OP_W-1:0] next_data_w;
  logic [PSI-1:0][R-1:0] next_data_avail_w;
  logic next_sob_w, next_eob_w, next_sol_w, next_eol_w;
  logic next_sos_w, next_eos_w;
  logic [BPBS_ID_W-1:0] next_pbs_id_w;
  logic next_ctrl_avail_w;

  // BSK控制信号初始化
  initial begin
    $display("[TB] Real-only testbench: Instantiating pe_pbs_with_ntt_core_head");
    reset_bsk_cache = 1'b0;
    bsk_mem_avail = 1'b1;
    bsk_mem_addr = '0;
    bsk_if_batch_start_1h = 1'b0;
    inc_bsk_rd_ptr = 1'b0;
    
    // 为真实模式提供BSK数据
    bsk_data_avail = 1'b1;
    for (int r = 0; r < R; r++) begin
      bsk_data[0][r] = 64'h123456789ABCDEF0 + r;
    end
    $display("[TB] Real mode: BSK data initialized");
  end

  // twiddle配置
  logic [1:0][R/2-1:0][MOD_NTT_W-1:0] twd_omg_ru_r_pow;
  initial begin
    twd_omg_ru_r_pow = '0;
    for (int i = 0; i < 2; i++) begin
      for (int r = 0; r < R/2; r++) begin
        twd_omg_ru_r_pow[i][r] = 32'h10000001 + (i << 16) + r; 
      end
    end
  end

  // 脉冲拉伸逻辑
  logic decomp_ntt_sog_stretch, decomp_ntt_sol_stretch;
  logic [1:0] sog_cnt, sol_cnt;
  logic sog_prev, sol_prev;
  
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      decomp_ntt_sog_stretch <= 1'b0;
      decomp_ntt_sol_stretch <= 1'b0;
      sog_cnt <= '0;
      sol_cnt <= '0;
      sog_prev <= 1'b0;
      sol_prev <= 1'b0;
    end else begin
      sog_prev <= decomp_ntt_sog;
      sol_prev <= decomp_ntt_sol;

      if (decomp_ntt_sog && !sog_prev && sog_cnt == 0) begin
        decomp_ntt_sog_stretch <= 1'b1;
        sog_cnt <= 2;
      end else if (sog_cnt != 0) begin
        sog_cnt <= sog_cnt - 1;
        decomp_ntt_sog_stretch <= (sog_cnt > 1);
      end else begin
        decomp_ntt_sog_stretch <= 1'b0;
      end

      if (decomp_ntt_sol && !sol_prev && sol_cnt == 0) begin
        decomp_ntt_sol_stretch <= 1'b1;
        sol_cnt <= 2;
      end else if (sol_cnt != 0) begin
        sol_cnt <= sol_cnt - 1;
        decomp_ntt_sol_stretch <= (sol_cnt > 1);
      end else begin
        decomp_ntt_sol_stretch <= 1'b0;
      end
    end
  end

  // 批次驱动的窗口门控
  logic window_open;
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      window_open <= 1'b0;
    end else begin
      if (br_batch_cmd_avail) begin
        window_open <= 1'b1;
        $display("[TB_NTT_DEBUG] %0t: Window opened by batch_cmd (pbs_nb=%0d br_loop=%0d) avail=%0d", 
                 $time, br_batch_cmd.pbs_nb, br_batch_cmd.br_loop, br_batch_cmd_avail);
      end else if (next_eos_w) begin
        window_open <= 1'b0;
        $display("[TB_NTT_DEBUG] %0t: Window closed by next_eos", $time);
      end
    end
  end

  // 门控逻辑
  wire ctrl_gate_en = 1'b1; // 调试时去除门控
  assign decomp_ctrl_avail_g = decomp_ntt_ctrl_avail && ctrl_gate_en;
  logic [PSI-1:0][R-1:0] ctrl_mask;
  assign ctrl_mask = {PSI{ {R{ctrl_gate_en}} }};
  assign decomp_avail_g = decomp_ntt_data_avail & ctrl_mask;
  assign decomp_sob_g = decomp_ntt_sob & ctrl_gate_en;
  assign decomp_eob_g = decomp_ntt_eob & ctrl_gate_en;
  // 真实头部严格依赖单拍sol/sog时序，这里改为直连原始脉冲
  assign decomp_sol_g = decomp_ntt_sol & ctrl_gate_en;
  assign decomp_eol_g = decomp_ntt_eol & ctrl_gate_en;
  assign decomp_sog_g = decomp_ntt_sog & ctrl_gate_en;
  assign decomp_eog_g = decomp_ntt_eog & ctrl_gate_en;

  // BSK映射到真实接口：保持型提供，确保NTT头部能获取到BSK数据
  always_comb begin
    for (int p = 0; p < PSI; p++) begin
      for (int r = 0; r < R; r++) begin
        for (int g = 0; g < GLWE_K_P1; g++) begin
          if (g == 0) begin
            real_bsk[p][r][g] = bsk_data_avail ? (bsk_data[0][r] | 64'h0000_0001_0000_0001) : '0;
          end else begin
            real_bsk[p][r][g] = bsk_data_avail ? {32'h1234_5678, 16'h9ABC, r[7:0], g[7:0]} : '0;
          end
          // 简化为直接有效，避免复杂的window逻辑
          real_bsk_vld[p][r][g] = bsk_data_avail;
        end
      end
    end
  end

  // 真实NTT头部实例化
  pe_pbs_with_ntt_core_head #(
    .S_NB(2*S),
    .USE_PP(1)
    // 使用默认的 TWD_GF64_FILE_PREFIX，基于运行时 R 和 PSI 参数自动生成
  ) pe_pbs_with_ntt_core_head_u (
    .clk                        (clk),
    .s_rst_n                    (s_rst_n),
    .twd_omg_ru_r_pow           (twd_omg_ru_r_pow),
    .br_batch_cmd               (br_batch_cmd),
    .br_batch_cmd_avail         (br_batch_cmd_avail),
    .bsk                        (real_bsk),
    .bsk_vld                    (real_bsk_vld),
    .bsk_rdy                    (real_bsk_rdy),
    .decomp_ntt_data_avail      (decomp_avail_g),
    .decomp_ntt_data            (decomp_ntt_data),
    .decomp_ntt_sob             (decomp_sob_g),
    .decomp_ntt_eob             (decomp_eob_g),
    .decomp_ntt_sog             (decomp_sog_g),
    .decomp_ntt_eog             (decomp_eog_g),
    .decomp_ntt_sol             (decomp_sol_g),
    .decomp_ntt_eol             (decomp_eol_g),
    .decomp_ntt_pbs_id          (decomp_ntt_pbs_id),
    .decomp_ntt_last_pbs        (decomp_ntt_last_pbs),
    .decomp_ntt_full_throughput (decomp_ntt_full_throughput),
    .decomp_ntt_ctrl_avail      (decomp_ctrl_avail_g),
    .decomp_ntt_data_rdy        (decomp_ntt_data_rdy),
    .decomp_ntt_ctrl_rdy        (decomp_ntt_ctrl_rdy),
    .next_data                  (next_data_w),
    .next_data_avail            (next_data_avail_w),
    .next_sob                   (next_sob_w),
    .next_eob                   (next_eob_w),
    .next_sol                   (next_sol_w),
    .next_eol                   (next_eol_w),
    .next_sos                   (next_sos_w),
    .next_eos                   (next_eos_w),
    .next_pbs_id                (next_pbs_id_w),
    .next_ctrl_avail            (next_ctrl_avail_w),
    .pep_error                  (),
    .pep_rif_info               (),
    .pep_rif_counter_inc        ()
  );
  
  // NTT参数显示
  initial begin
    $display("[TB_NTT_PARAMS] ===== 真实模式 NTT Core Parameters =====");
    $display("[TB_NTT_PARAMS] Global: S=%0d, R=%0d, PSI=%0d", S, R, PSI);
    $display("[TB_NTT_PARAMS] Head: S_NB=%0d, USE_PP=%0d", 
             pe_pbs_with_ntt_core_head_u.S_NB, pe_pbs_with_ntt_core_head_u.USE_PP);
    $display("[TB_NTT_PARAMS] TWD_FILE=%s", pe_pbs_with_ntt_core_head_u.TWD_GF64_FILE_PREFIX);
    if (R != 2) begin
      $display("[TB_NTT_PARAMS] ** WARNING: Global R=%0d, twiddle files for R=2! **", R);
    end else begin
      $display("[TB_NTT_PARAMS] ** R参数匹配 twiddle files (R=%0d) **", R);
    end
    $display("[TB_NTT_PARAMS] ==========================================");
  end
  
  // 批次命令状态机
  typedef enum logic [1:0] {B_IDLE, B_SEND_CMD, B_ACTIVE} batch_fsm_e;
  batch_fsm_e batch_state;
  logic [1:0] cmd_pulse_cnt;
  logic [31:0] start_cnt;

  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      batch_state <= B_IDLE;
      cmd_pulse_cnt <= '0;
      br_batch_cmd_avail <= 1'b0;
      br_batch_cmd <= '0;
      start_cnt <= '0;
    end else begin
      br_batch_cmd_avail <= 1'b0;
      start_cnt <= start_cnt + 1'b1;

      unique case (batch_state)
        B_IDLE: begin
          if (decomp_ntt_sog || decomp_ntt_ctrl_avail || (start_cnt > 32'd20000)) begin
            br_batch_cmd.pbs_nb <= 1;
            br_batch_cmd.br_loop <= 3;  // 修复位宽问题：br_loop只有2位，最大值3
            cmd_pulse_cnt <= 2;
            br_batch_cmd_avail <= 1'b1;
            batch_state <= B_SEND_CMD;
            $display("[TB] Real mode: SET br_batch_cmd pbs_nb=1 br_loop=3 at t=%0t", $time);
            $display("[TB] DEBUG: br_batch_cmd width=%0d bits, br_loop width=%0d bits", 
                     $bits(br_batch_cmd), $bits(br_batch_cmd.br_loop));
          end
        end

        B_SEND_CMD: begin
          br_batch_cmd_avail <= 1'b1;
          if (cmd_pulse_cnt > 1) begin
            cmd_pulse_cnt <= cmd_pulse_cnt - 1'b1;
          end else begin
            cmd_pulse_cnt <= '0;
            batch_state <= B_ACTIVE;
            $display("[TB] Real mode: batch cmd sent, entering ACTIVE");
          end
        end

        B_ACTIVE: begin
          if (next_eos_w) begin
            batch_state <= B_IDLE;
            $display("[TB] Real mode: batch completed");
          end
        end
      endcase
    end
  end

  // NTT输出转换
  function automatic logic [MOD_Q_W-1:0] sext_to_modq (
    input logic [NTT_OP_W-1:0] x
  );
    logic signed [NTT_OP_W-1:0] xs;
    begin
      xs = x;
      if (MOD_Q_W >= NTT_OP_W) begin
        sext_to_modq = {{(MOD_Q_W-NTT_OP_W){xs[NTT_OP_W-1]}}, xs};
      end else begin
        sext_to_modq = xs[MOD_Q_W-1:0]; // 截断高位
      end
    end
  endfunction

  always_comb begin
    for (int p = 0; p < PSI; p++) begin
      for (int r = 0; r < R; r++) begin
        ntt_next_data[p][r] = sext_to_modq(next_data_w[p][r]);
      end
    end
    ntt_next_data_avail = next_data_avail_w;
    ntt_next_ctrl_avail = next_ctrl_avail_w;
  end

  // 始终准备好消费NTT输出，确保各R车道背压一致，避免twd_phi_rdy不一致
  // 与WoKS引擎的输出握手由引擎内部驱动，这里不再额外驱动，避免多驱动冲突

// ==============================================================================================
// 精简的RegFile模拟
// ==============================================================================================
  logic [N_LVL2-1:0][MOD_Q_W-1:0] regfile_memory [0:65535];
  
  initial begin
    for (int addr = 0; addr < 65536; addr++) begin
      for (int coeff = 0; coeff < N_LVL2; coeff++) begin
        regfile_memory[addr][coeff] = 32'h0;
      end
    end
  end

  int read_counter = 0;
  logic reading_in_progress = 1'b0;
  logic [REGF_ADDR_W-1:0] current_read_addr;
  
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      regf_rd_req_rdy <= 1'b1;
      regf_wr_req_rdy <= 1'b1;
      regf_wr_data_rdy <= '1;
      regf_rd_data_avail <= '0;
      regf_rd_data <= '0;
      regf_rd_last_word <= 1'b0;
      read_counter <= 0;
      reading_in_progress <= 1'b0;
    end else begin
      // Handle read requests
      if (regf_rd_req_vld && regf_rd_req_rdy && !reading_in_progress) begin
        automatic logic [REGF_ADDR_W-1:0] read_addr = regf_rd_req[REGF_RD_REQ_W-1:REGF_ADDR_W];
        current_read_addr <= read_addr;
        reading_in_progress <= 1'b1;
        read_counter <= 0;
        regf_rd_data_avail[0] <= 1'b1;
        regf_rd_data[0] <= regfile_memory[read_addr][0];
        regf_rd_last_word <= 1'b0;
      end else if (reading_in_progress) begin
        read_counter <= read_counter + 1;
        regf_rd_data_avail[0] <= 1'b1;
        regf_rd_data[0] <= regfile_memory[current_read_addr][read_counter + 1];
        
        if (read_counter == N_LVL2-1) begin
          regf_rd_last_word <= 1'b1;
          reading_in_progress <= 1'b0;
        end else begin
          regf_rd_last_word <= 1'b0;
        end
      end else begin
        regf_rd_data_avail <= '0;
      end
      
      // Handle write requests
      if (regf_wr_req_vld && regf_wr_req_rdy && regf_wr_data_vld[0] && regf_wr_data_rdy[0]) begin
        automatic logic [REGF_ADDR_W-1:0] addr = regf_wr_req[REGF_ADDR_W-1:0];
        regfile_memory[addr][0] <= regf_wr_data[0];
      end
    end
  end

// ==============================================================================================
// 调试监控 - 精简版
// ==============================================================================================
  logic [31:0] debug_cycle_count = 0;
  logic debug_first_input = 1'b0;
  // 边沿触发+配额限制，避免刷屏
  logic prev_decomp_ctrl_avail, prev_decomp_data_any;
  logic prev_next_ctrl_avail_w, prev_next_data_any;
  integer debug_print_budget = 30;
  
  always @(posedge clk) begin
    if (!s_rst_n) begin
      debug_cycle_count <= 0;
      debug_first_input <= 1'b0;
    end else begin
      debug_cycle_count <= debug_cycle_count + 1;
      
      if (decomp_ctrl_avail_g && !debug_first_input) begin
        debug_first_input <= 1'b1;
        $display("[TB_REAL] FIRST INPUT at cycle %0d", debug_cycle_count);
      end
      
      // 每5万周期状态检查
      if (debug_first_input && (debug_cycle_count % 50000 == 0)) begin
        $display("[TB_REAL] STATUS - cycle=%0d ctrl_in=%0d ctrl_out=%0d eos=%0d", 
                 debug_cycle_count, decomp_ctrl_avail_g, next_ctrl_avail_w, next_eos_w);
      end
      
      // 批次命令监控
      if (br_batch_cmd_avail) begin
        $display("[TB_REAL] BATCH_CMD pbs_nb=%0d br_loop=%0d", 
                 br_batch_cmd.pbs_nb, br_batch_cmd.br_loop);
      end
      
      // 首次若干拍：仅在事件边沿打印，并限制最多30条
      if (debug_cycle_count < 2000 && debug_print_budget > 0) begin
        logic data_any      = (|decomp_ntt_data_avail);
        logic data_rdy_all  = (&decomp_ntt_data_rdy);
        logic next_data_any = (|next_data_avail_w);

        if (decomp_ntt_ctrl_avail && !prev_decomp_ctrl_avail) begin
          $display("[TB_REAL] NTT_CTRL(+edge) in_avail=1 in_rdy=%0b sog=%0b sol=%0b sob=%0b", 
                   decomp_ntt_ctrl_rdy, decomp_ntt_sog, decomp_ntt_sol, decomp_ntt_sob);
          debug_print_budget -= 1;
        end
        if (data_any && !prev_decomp_data_any && debug_print_budget > 0) begin
          $display("[TB_REAL] NTT_DATA(+edge) avail_any=1 rdy_all=%0b eog=%0b eol=%0b eob=%0b", 
                   data_rdy_all, decomp_ntt_eog, decomp_ntt_eol, decomp_ntt_eob);
          debug_print_budget -= 1;
        end
        if (!decomp_ntt_ctrl_rdy && debug_print_budget > 0) begin
          $display("[TB_REAL] NTT_CTRL backpressure: in_rdy=0");
          debug_print_budget -= 1;
        end
        if (!data_rdy_all && debug_print_budget > 0) begin
          $display("[TB_REAL] NTT_DATA backpressure: rdy_all=0");
          debug_print_budget -= 1;
        end
        if (next_ctrl_avail_w && !prev_next_ctrl_avail_w && debug_print_budget > 0) begin
          $display("[TB_REAL] NTT_OUT(+edge) ctrl_avail=1 sos=%0b sol=%0b sob=%0b", next_sos_w, next_sol_w, next_sob_w);
          debug_print_budget -= 1;
        end
        if (next_data_any && !prev_next_data_any && debug_print_budget > 0) begin
          $display("[TB_REAL] NTT_OUT(+edge) data_any=1");
          debug_print_budget -= 1;
        end
      end

  // 输出监控
      if (next_ctrl_avail_w) begin
        $display("[TB_REAL] OUTPUT ctrl_avail");
      end
      if (next_eos_w) begin
        $display("[TB_REAL] OUTPUT eos - finishing");
        $finish;
      end
    end
  end

  // 记录上一拍状态（放在时序块之后）
  always @(posedge clk) begin
    if (!s_rst_n) begin
      prev_decomp_ctrl_avail <= 1'b0;
      prev_decomp_data_any   <= 1'b0;
      prev_next_ctrl_avail_w <= 1'b0;
      prev_next_data_any     <= 1'b0;
    end else begin
      prev_decomp_ctrl_avail <= decomp_ntt_ctrl_avail;
      prev_decomp_data_any   <= (|decomp_ntt_data_avail);
      prev_next_ctrl_avail_w <= next_ctrl_avail_w;
      prev_next_data_any     <= (|next_data_avail_w);
    end
  end

  // NTT内部状态监控
  logic prev_ntt_internal_active;
  integer ntt_debug_print_cnt;
  always @(posedge clk) begin
    if (!s_rst_n) begin
      prev_ntt_internal_active <= 1'b0;
      ntt_debug_print_cnt <= 0;
    end else begin
      // 检测NTT头部内部是否有活动，通过监控关键信号
      logic ntt_has_input = decomp_ntt_ctrl_avail || (|decomp_ntt_data_avail);
      logic ntt_has_bsk = (|real_bsk_vld);
      logic ntt_internal_active = ntt_has_input || ntt_has_bsk;
      
      // 每10万周期打印一次NTT内部状态
      if (debug_cycle_count % 100000 == 0 && debug_cycle_count > 100000) begin
        $display("[TB_NTT_DEBUG] cycle=%0d ntt_in_active=%0b bsk_active=%0b out_active=%0b", 
                 debug_cycle_count, ntt_has_input, ntt_has_bsk, next_ctrl_avail_w);
        
        // 尝试访问NTT头部内部信号（如果存在层级化接口）
        if (ntt_debug_print_cnt < 5) begin
          $display("[TB_NTT_DEBUG] decomp_ctrl: avail=%0b rdy=%0b", decomp_ntt_ctrl_avail, decomp_ntt_ctrl_rdy);
          $display("[TB_NTT_DEBUG] decomp_data: avail=%0b rdy=%0b", (|decomp_ntt_data_avail), (&decomp_ntt_data_rdy));
          $display("[TB_NTT_DEBUG] next_ctrl: avail=%0b", next_ctrl_avail_w);
          $display("[TB_NTT_DEBUG] next_data: avail=%0b", (|next_data_avail_w));
          ntt_debug_print_cnt <= ntt_debug_print_cnt + 1;
        end
      end
      
      // 检测NTT内部状态变化的边沿
      if (ntt_internal_active && !prev_ntt_internal_active) begin
        $display("[TB_NTT_DEBUG] %0t: NTT internal activity started", $time);
        // 打印BSK和批次命令状态
        $display("[TB_NTT_DEBUG] BSK vld pattern: [0][0]=%0b [0][1]=%0b", real_bsk_vld[0][0], real_bsk_vld[0][1]);
        $display("[TB_NTT_DEBUG] BSK data samples: [0][0][0]=0x%x [0][1][0]=0x%x", real_bsk[0][0][0], real_bsk[0][1][0]);
        $display("[TB_NTT_DEBUG] Batch cmd: pbs_nb=%0d br_loop=%0d avail=%0b", 
                 br_batch_cmd.pbs_nb, br_batch_cmd.br_loop, br_batch_cmd_avail);
        $display("[TB_NTT_DEBUG] Window open=%0b batch_state=%0d", window_open, batch_state);
      end else if (!ntt_internal_active && prev_ntt_internal_active) begin
        $display("[TB_NTT_DEBUG] %0t: NTT internal activity stopped", $time);
        $display("[TB_NTT_DEBUG] Final status - BSK active=%0b window=%0b batch_state=%0d", 
                 (|real_bsk_vld), window_open, batch_state);
      end
      prev_ntt_internal_active <= ntt_internal_active;
    end
  end

  // Watchdog
  logic [31:0] active_cycle_cnt;
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      active_cycle_cnt <= '0;
    end else begin
      if (batch_state == B_ACTIVE) begin
        active_cycle_cnt <= active_cycle_cnt + 1'b1;
        if (active_cycle_cnt == 32'd2000000) begin
          $display("[WD] ACTIVE timeout - ctrl_in=%0d next_ctrl=%0d eos=%0d", 
                   decomp_ntt_ctrl_avail, next_ctrl_avail_w, next_eos_w);
          $finish;
        end
      end else begin
        active_cycle_cnt <= '0;
      end
    end
  end

// ==============================================================================================
// 测试激励 - 简化版
// ==============================================================================================
  logic [63:0] test_mu;
  logic [N_LVL0:0][63:0] test_abar;
  
  task automatic generate_test_vectors();
    $display("[TB] Generating test vectors at t=%0t", $time);
    $display("[TB] N_LVL0=%0d, generating %0d abar values", N_LVL0, N_LVL0+1);
    test_mu = 64'h8000_0000_0000_0000;
    
    for (int i = 0; i <= N_LVL0; i++) begin
      if (N_LVL0 <= 64) begin
        test_abar[i] = ((i % 4) == 0) ? (64'd1 + i) : 64'd0;
      end else begin
        test_abar[i] = ((i % 16) == 0) ? 64'd1 : 64'd0;
      end
    end
    
    mu_value = test_mu;
    abar_data = test_abar;
    $display("[TB] Vectors ready (mu=0x%016x)", test_mu);
    $display("[TB] Sample abar[0:min(3,%0d)] = [%0d, %0d, %0d, %0d]", 
             N_LVL0, test_abar[0], 
             (N_LVL0>=1) ? test_abar[1] : 0, 
             (N_LVL0>=2) ? test_abar[2] : 0, 
             (N_LVL0>=3) ? test_abar[3] : 0);
  endtask

// ==============================================================================================
// 主测试序列
// ==============================================================================================
  initial begin
    $display("[TB] WoP-PBS Real-Mode Testbench");
    $display("[TB] MAIN_SEQ: Initializing signals at t=%0t", $time);
    
    start = 1'b0;
    mu_value = '0;
    abar_data = '0;
    abar_valid = 1'b0;
    
    $display("[TB] MAIN_SEQ: Waiting for reset release at t=%0t", $time);
    wait(s_rst_n);
    $display("[TB] MAIN_SEQ: Reset released, waiting 10 cycles at t=%0t", $time);
    repeat(10) @(posedge clk);
    
    $display("[TB] MAIN_SEQ: Generating test vectors at t=%0t", $time);
    generate_test_vectors();
    
    $display("[TB] MAIN_SEQ: Starting circuit bootstrap at t=%0t", $time);
    @(posedge clk);
    abar_valid = 1'b1;
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;
    $display("[TB] Circuit bootstrap started at t=%0t", $time);
    
    fork
      begin
        wait(result_valid);
        $display("[TB] ✅ Circuit bootstrap completed");
        $display("[TB] result_a[0-3]: [0x%08x, 0x%08x, 0x%08x, 0x%08x]", 
                 result_a[0], result_a[1], result_a[2], result_a[3]);
        $display("[TB] result_b: 0x%08x", result_b);
        test_status = TEST_PASSED;
      end
      begin
        #10000000000;  // 10秒超时，足够NTT计算完成
        $display("❌ TIMEOUT: Circuit bootstrap did not complete (10s timeout)");
        test_status = TEST_TIMEOUT;
      end
    join_any
    disable fork;
    
    abar_valid = 1'b0;
    repeat(10) @(posedge clk);
    
    $display("[TB] Testbench Completed - Status: %0d", test_status);
    $finish;
  end

  // 绝对超时保护 - 增加到15秒以确保NTT有足够时间完成
  initial begin
    #15000000000;  // 15秒绝对超时
    if (test_status == TEST_UNKNOWN) begin
      $error("Testbench absolute timeout after 15 seconds!");
      test_status = TEST_TIMEOUT;
      $finish;
    end
  end

endmodule