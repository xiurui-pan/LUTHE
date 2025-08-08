// ==============================================================================================
// Filename: wop_circuit_bootstrap_woks_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// WoP-PBS Circuit Bootstrap WoKS Engine.
// This module implements the circuitBootstrapWoKS() function from circuit_bootstrapping.cpp.
// 
// C++ Algorithm:
// 1. Generate test vector: (1+X+...+X^{N-1})*X^{N/2}*mu2, then multiply by X^{bbar}
// 2. Initialize accumulator with test vector as noiseless trivial TLweSample
// 3. Blind rotation loop for each coefficient:
//    - acc1 = acc
//    - acc2 = (X^aibar - 1) * acc1 = acc1*X^aibar - acc1  
//    - acc1 = BKi * acc2 (external product using BSK and NTT)
//    - acc += acc1
// 4. Sample extraction: extract LWE sample from final accumulator
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module wop_circuit_bootstrap_woks_engine
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import param_ntt_pkg::*;
  import ntt_core_common_param_pkg::*;
  import bsk_mgr_common_param_pkg::*;
  import regf_common_param_pkg::*;
  import pep_if_pkg::*;
#(
  parameter int MOD_Q_W = 64,
  parameter int N_LVL0 = 630,
  parameter int N_LVL2 = 2048,
  parameter int ELL_LVL2 = 8,
  parameter int K = 1,  // k parameter for TLWE
  parameter int BSK_BATCH_ID_W = 8,
  parameter int BSK_PC = 1,
  parameter int R = 32,  // Ring size parameter  
  parameter int PSI = 2,  // PSI parameter
  parameter int BPBS_ID_W = 8,  // BPBS ID width
  parameter int REGF_ADDR_W = 16,  // RegFile address width
  parameter int NTT_OP_W = 64,  // NTT操作数据宽度
  parameter int PBS_B_W = 32,  // PBS操作数据宽度
  parameter bit APPLY_POST_SCALE = 1'b0  // 可选 N^{-1} 缩放开关（默认关）
)
(
  input  logic clk,
  input  logic s_rst_n,
  
  // Control interface
  input  logic start,
  input  logic [MOD_Q_W-1:0] mu_value,
  output logic done,
  
  // RegFile interface (shared) - 复用pe_pbs RegFile
  output logic regf_wr_req_vld,
  input  logic regf_wr_req_rdy,
  output logic [REGF_WR_REQ_W-1:0] regf_wr_req,
  output logic [REGF_COEF_NB-1:0] regf_wr_data_vld,
  input  logic [REGF_COEF_NB-1:0] regf_wr_data_rdy,
  output logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_wr_data,
  
  output logic regf_rd_req_vld,
  input  logic regf_rd_req_rdy,
  output logic [REGF_RD_REQ_W-1:0] regf_rd_req,
  input  logic [REGF_COEF_NB-1:0] regf_rd_data_avail,
  input  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_rd_data,
  input  logic regf_rd_last_word,
  
  // Input: pre-modswitch result (abar)
  input  logic [N_LVL0:0][63:0] abar_data,  // abar[n_lvl0+1] from preModSwitch
  input  logic abar_valid,
  
  // Output: LWE sample at level 2
  output logic [N_LVL2-1:0][MOD_Q_W-1:0] result_a,
  output logic [MOD_Q_W-1:0] result_b,
  output logic result_valid,
  
  // ✅ NTT接口 - 与wop_pbs_kernel的共享NTT引擎通信
  // 发送分解数据到NTT引擎
  output logic [PSI-1:0][R-1:0] decomp_ntt_data_avail,
  output logic [PSI-1:0][R-1:0][PBS_B_W:0] decomp_ntt_data,
  output logic decomp_ntt_sob, decomp_ntt_eob,
  output logic decomp_ntt_sog, decomp_ntt_eog,
  output logic decomp_ntt_sol, decomp_ntt_eol,
  output logic [BPBS_ID_W-1:0] decomp_ntt_pbs_id,
  output logic decomp_ntt_last_pbs,
  output logic decomp_ntt_full_throughput,
  output logic decomp_ntt_ctrl_avail,
  input  logic [PSI-1:0][R-1:0] decomp_ntt_data_rdy,
  input  logic decomp_ntt_ctrl_rdy,
  
  // 接收NTT引擎的结果
  input  logic [PSI-1:0][R-1:0][NTT_OP_W-1:0] ntt_next_data,
  input  logic [PSI-1:0][R-1:0] ntt_next_data_avail,
  output logic [PSI-1:0][R-1:0] ntt_next_data_rdy,
  input  logic ntt_next_ctrl_avail,
  output logic ntt_next_ctrl_rdy,
  
  // ✅ BSK接口 - 与wop_pbs_kernel的共享BSK管理器通信
  // 请求BSK系数
  output logic bsk_req_vld,
  input  logic bsk_req_rdy,
  output logic [BSK_BATCH_ID_W-1:0] bsk_batch_id,
  
  // 接收BSK数据
  input  logic bsk_data_avail,
  input  logic [BSK_PC-1:0][R-1:0][MOD_Q_W-1:0] bsk_data
);

// ==============================================================================================
// Local Parameters
// ==============================================================================================
  localparam int N2 = N_LVL2 / 2;
  localparam int _2L = 2 * ELL_LVL2;
  // Compile-time check for 64-bit mode (P1)
  initial begin
    if (MOD_Q_W != 64) $fatal(1, "MOD_Q_W must be 64 for P1 phase");
  end
  // log2(N) for optional post INTT scaling
  localparam int N_LVL2_LOG2 = $clog2(N_LVL2);
  // Optional post-scale enable (parameterized)
  
  // Address space design - 基于Bit Extract成功经验，支持大规模存储
  // 每个区域分配0x800 (2048)地址，支持最大N_LVL2=2048系数
  // 确保RID_W=7截断后地址唯一性，避免冲突
  localparam logic [REGF_ADDR_W-1:0] ACC_STORAGE_ADDR     = 16'h4000; // 累加器存储 (0x4000 & 0x7F = 0x00)
  localparam logic [REGF_ADDR_W-1:0] ACC1_STORAGE_ADDR    = 16'h4820; // 临时累加器1 (0x4820 & 0x7F = 0x20)  
  localparam logic [REGF_ADDR_W-1:0] ACC2_STORAGE_ADDR    = 16'h5040; // 临时累加器2 (0x5040 & 0x7F = 0x40)
  localparam logic [REGF_ADDR_W-1:0] DECOMP_STORAGE_ADDR  = 16'h5860; // Gadget分解存储 (0x5860 & 0x7F = 0x60)
  localparam logic [REGF_ADDR_W-1:0] TESTVECT_STORAGE_ADDR= 16'h6080; // 测试向量存储 (0x6080 & 0x7F = 0x00, next bank)

// ==============================================================================================
// Internal Variables
// ==============================================================================================
  // tGsw64DecompH算法所需的内部变量
  logic [63:0] torus_decomp_offset;
  logic [63:0] buf_storage [0:K][0:N_LVL2-1];
  logic will_complete_level, will_complete_all;

  // Optional INTT post-scaling for torus64
  function automatic logic [MOD_Q_W-1:0] post_scale_intt (
    input logic [NTT_OP_W-1:0] intt_word
  );
    logic signed [MOD_Q_W-1:0] narrowed;
    logic signed [MOD_Q_W-1:0] scaled;
    begin
      narrowed = intt_word[MOD_Q_W-1:0];
      if (APPLY_POST_SCALE) begin
        scaled = narrowed >>> N_LVL2_LOG2;
      end else begin
        scaled = narrowed;
      end
      post_scale_intt = scaled;
    end
  endfunction

// ==============================================================================================
// State Machine
// ==============================================================================================
  typedef enum logic [4:0] {
    IDLE,
    GENERATE_TEST_VECTOR,     // Generate test vector based on mu and bbar
    INIT_ACCUMULATOR,         // Initialize accumulator with test vector
    BLIND_ROTATE_LOOP,        // Main blind rotation loop
    COMPUTE_ACC2,             // acc2 = (X^aibar - 1) * acc1
    DECOMPOSE_ACC2,           // Gadget decomposition of acc2
    NTT_FORWARD,              // Forward NTT of decomposed polynomials
    // EXTERNAL_PRODUCT removed: external product handled inside shared NTT core
    NTT_INVERSE,              // Inverse NTT of product results
    ACCUMULATE,               // acc += acc1
    SAMPLE_EXTRACT,           // Extract final LWE sample
    DONE
  } state_e;

  state_e current_state, next_state;

// ==============================================================================================
// Internal Registers and Storage
// ==============================================================================================
  // Test vector storage
  logic [N_LVL2-1:0][MOD_Q_W-1:0] testvect_temp;
  logic [N_LVL2-1:0][MOD_Q_W-1:0] testvect;
  
  // Accumulator storage (TLWE samples)
  logic [K:0][N_LVL2-1:0][MOD_Q_W-1:0] acc;   // Main accumulator
  logic [K:0][N_LVL2-1:0][MOD_Q_W-1:0] acc1;  // Temporary accumulator 1
  logic [K:0][N_LVL2-1:0][MOD_Q_W-1:0] acc2;  // Temporary accumulator 2
  
  // Loop control
  logic [$clog2(N_LVL0+1)-1:0] loop_counter;
  logic [63:0] current_aibar;
  logic [MOD_Q_W-1:0] mu2;
  logic [63:0] bbar;
  
  // Decomposition storage for external product (Gadget decomposition)
  logic [_2L-1:0][N_LVL2-1:0][63:0] decomp;
  logic [_2L-1:0][N_LVL2-1:0][MOD_Q_W-1:0] decomp_fft;
  
  // NTT traversal control
  logic [$clog2(_2L)-1:0] decomp_level_counter;
  logic [$clog2(N_LVL2)-1:0] coeff_counter;
  // INTT receive aggregator counters
  logic [$clog2((K+1)*N_LVL2+1)-1:0] ntt_recv_count;
  logic [$clog2((K+1)*N_LVL2+1)-1:0] ntt_recv_count_incr;
  
  // ✅ TFHE标准Gadget分解参数 (tGsw64DecompH)
  // 参考: env->bgbit_lvl2 和 env->ell_lvl2
  localparam int BASE_LOG = 4;   // bgbit_lvl2: 每层4位 
  localparam int BASE = 1 << BASE_LOG;     // Bg = 2^4 = 16
  localparam int MASK = BASE - 1;          // mask = 15 (0xF)
  
  // TFHE Context参数映射
  // ELL_LVL2 = 8   → _2L = 16 (2*8, for k+1=2 polynomials)  
  // N_LVL2 = 2048  → 多项式大小
  // 这些参数与标准TFHE参数完全匹配
  
  // Control signals
  logic test_vector_done;
  logic accumulator_init_done;
  logic acc2_compute_done;
  logic decompose_done;
  logic ntt_forward_done;
  logic ntt_inverse_done;
  logic accumulate_done;
  logic sample_extract_done;

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      loop_counter <= '0;
      mu2 <= '0;
      bbar <= '0;
      decomp_level_counter <= '0;
      coeff_counter <= '0;
      ntt_recv_count <= '0;
    end else begin
      current_state <= next_state;
      // Debug state transitions
      if (current_state != next_state) begin
        $display("[WoKS] State transition: %0d -> %0d at t=%0t", current_state, next_state, $time);
      end
      
      case (current_state)
        IDLE: begin
          if (start && abar_valid) begin
            mu2 <= mu_value / 2;  // mu2 = mu / 2
            bbar <= abar_data[N_LVL0];  // bbar = abar[n_lvl0]
            loop_counter <= '0;
          end
        end
        
        BLIND_ROTATE_LOOP: begin
          current_aibar <= abar_data[loop_counter];
          // Reset external product counters when entering this state
          if (current_state != next_state && next_state == DECOMPOSE_ACC2) begin
            decomp_level_counter <= '0;
            coeff_counter <= '0;
          end
          // Handle skip case: when staying in BLIND_ROTATE_LOOP and abar=0, increment loop_counter
          if (current_state == next_state && abar_data[loop_counter] == 0) begin
            loop_counter <= loop_counter + 1;
            $display("%0t: BLIND_ROTATE_LOOP - skipping loop_counter %0d (abar=0), incrementing", 
                     $time, loop_counter);
          end
        end
        
         NTT_FORWARD: begin
          // Advance counters only when NTT core accepted the data for all lanes
          if (decomp_level_counter < _2L && coeff_counter < N_LVL2) begin
            if (decomp_ntt_ctrl_rdy && (&decomp_ntt_data_rdy) && decomp_ntt_ctrl_avail) begin
              if (coeff_counter < N_LVL2-1) begin
                coeff_counter <= coeff_counter + 1;
                if (coeff_counter % 128 == 0) begin
                  $display("%0t: NTT_FORWARD - accepted coeff=%0d (level=%0d)", $time, coeff_counter, decomp_level_counter);
                end
              end else begin
                coeff_counter <= '0;
                decomp_level_counter <= decomp_level_counter + 1;
                $display("%0t: NTT_FORWARD - Level %0d completed, moving to level %0d", 
                         $time, decomp_level_counter, decomp_level_counter + 1);
              end
            end
          end
          // Reset counters for inverse NTT (external product handled inside shared NTT)
          if (current_state != next_state && next_state == NTT_INVERSE) begin
            decomp_level_counter <= '0;
            coeff_counter <= '0;
            ntt_recv_count <= '0;
          end

        end
        
        NTT_INVERSE: begin
          // Advance counters only when we accepted data from NTT for at least one lane
          if (decomp_level_counter < _2L && coeff_counter < N_LVL2) begin
            if (ntt_next_ctrl_avail && (|ntt_next_data_avail) && (|ntt_next_data_rdy)) begin
              if (coeff_counter < N_LVL2-1) begin
                coeff_counter <= coeff_counter + 1;
              end else begin
                coeff_counter <= '0;
                decomp_level_counter <= decomp_level_counter + 1;
              end
              // accumulate accepted items
              ntt_recv_count <= ntt_recv_count + ntt_recv_count_incr;
            end
          end
        end
        
        // Removed duplicate BLIND_ROTATE_LOOP handling - now unified in combinational logic
        
        ACCUMULATE: begin
          // Simple increment: when accumulate is done, increment loop_counter
          if (accumulate_done) begin
            $display("%0t: ACCUMULATE - incrementing loop_counter from %0d to %0d", 
                     $time, loop_counter, loop_counter + 1);
            loop_counter <= loop_counter + 1;
          end
        end
        
        // (EXTERNAL_PRODUCT) removed
      endcase
    end
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    done = 1'b0;
    result_valid = 1'b0;
    
    // ✅ RegFile接口默认值设置
    regf_wr_req_vld = 1'b0;
    regf_wr_req = '0;
    regf_wr_data_vld = '0;
    regf_wr_data = '0;
    regf_rd_req_vld = 1'b0;
    regf_rd_req = '0;
    
    // ✅ NTT接口默认值设置 - 复用共享NTT引擎
    decomp_ntt_data_avail = '0;
    decomp_ntt_data = '0;
    decomp_ntt_sob = 1'b0;
    decomp_ntt_eob = 1'b0;
    decomp_ntt_sog = 1'b0;
    decomp_ntt_eog = 1'b0;
    decomp_ntt_sol = 1'b0;
    decomp_ntt_eol = 1'b0;
    decomp_ntt_pbs_id = '0;
    decomp_ntt_last_pbs = 1'b0;
    decomp_ntt_full_throughput = 1'b0;
    decomp_ntt_ctrl_avail = 1'b0;
    ntt_next_data_rdy = '0;
    ntt_next_ctrl_rdy = 1'b0;
    
    // ✅ BSK接口默认值设置 - 复用共享BSK管理器
    bsk_req_vld = 1'b0;
    bsk_batch_id = '0;


    
    case (current_state)
      IDLE: begin
        if (start && abar_valid) begin
          next_state = GENERATE_TEST_VECTOR;
        end
      end
      
      GENERATE_TEST_VECTOR: begin
        // Generate test vector: (1+X+...+X^{N-1})*X^{N/2}*mu2
        // First generate base pattern
        for (int j = 0; j < N2; j++) begin
          testvect_temp[j] = -mu2;  // Negative for first half
        end
        for (int j = N2; j < N_LVL2; j++) begin
          testvect_temp[j] = mu2;   // Positive for second half
        end
        
        // Then multiply by X^{bbar} (rotation)
        if (bbar < N_LVL2) begin
          for (int j = 0; j < N_LVL2 - bbar; j++) begin
            testvect[j] = testvect_temp[j + bbar];
          end
          for (int j = N_LVL2 - bbar; j < N_LVL2; j++) begin
            testvect[j] = -testvect_temp[j - (N_LVL2 - bbar)];  // Sign flip due to X^N = -1
          end
        end else begin
          automatic int bbar_ = bbar - N_LVL2;
          for (int j = 0; j < N_LVL2 - bbar_; j++) begin
            testvect[j] = -testvect_temp[j + bbar_];
          end
          for (int j = N_LVL2 - bbar_; j < N_LVL2; j++) begin
            testvect[j] = testvect_temp[j - (N_LVL2 - bbar_)];
          end
        end
        
        test_vector_done = 1'b1;
        next_state = INIT_ACCUMULATOR;
      end
      
      INIT_ACCUMULATOR: begin
        // Initialize accumulator as noiseless trivial TLweSample
        for (int j = 0; j < N_LVL2; j++) begin
          acc[0][j] = '0;                    // a[0] = 0 (k=1)
          acc[1][j] = testvect[j];          // a[1] = testvect (b part)
        end
        
        // Debug: Check testvect and acc initialization
        $display("%0t: INIT_ACCUMULATOR - testvect[0:3]=[0x%016x, 0x%016x, 0x%016x, 0x%016x]", 
                 $time, testvect[0], testvect[1], testvect[2], testvect[3]);
        $display("%0t: INIT_ACCUMULATOR - acc[1][0:3]=[0x%016x, 0x%016x, 0x%016x, 0x%016x]", 
                 $time, acc[1][0], acc[1][1], acc[1][2], acc[1][3]);
        
        accumulator_init_done = 1'b1;
        next_state = BLIND_ROTATE_LOOP;
      end
      
      BLIND_ROTATE_LOOP: begin
        if (loop_counter < N_LVL0) begin
          // Debug: 打印当前循环状态
          $display("%0t: BLIND_ROTATE_LOOP - loop_counter=%0d, abar_data[%0d]=%0d", 
                   $time, loop_counter, loop_counter, abar_data[loop_counter]);
          
          // Fix timing issue: use abar_data[loop_counter] directly instead of current_aibar
          if (abar_data[loop_counter] == 0) begin
            // Skip if aibar is 0 - need to increment loop_counter and continue
            $display("%0t: BLIND_ROTATE_LOOP - skipping (abar=0), setting skip flag", $time);
            next_state = BLIND_ROTATE_LOOP;  // Loop back to process next iteration
          end else begin
            // Copy acc to acc1
            $display("%0t: BLIND_ROTATE_LOOP - processing (abar=%0d), going to COMPUTE_ACC2",
                     $time, abar_data[loop_counter]);
            // current_aibar will be set to abar_data[loop_counter] in sequential logic
            
            // Debug: Check acc before copying
            $display("%0t: BLIND_ROTATE_LOOP - acc[1][0:3]=[0x%016x, 0x%016x, 0x%016x, 0x%016x]", 
                     $time, acc[1][0], acc[1][1], acc[1][2], acc[1][3]);
            
            for (int q = 0; q <= K; q++) begin
              for (int j = 0; j < N_LVL2; j++) begin
                acc1[q][j] = acc[q][j];
              end
            end
            
            // Debug: Check acc1 after copying  
            $display("%0t: BLIND_ROTATE_LOOP - copied acc1[1][0:3]=[0x%016x, 0x%016x, 0x%016x, 0x%016x]", 
                     $time, acc1[1][0], acc1[1][1], acc1[1][2], acc1[1][3]);
            next_state = COMPUTE_ACC2;
          end
        end else begin
          $display("%0t: BLIND_ROTATE_LOOP - loop completed (%0d >= %0d), going to SAMPLE_EXTRACT", 
                   $time, loop_counter, N_LVL0);
          next_state = SAMPLE_EXTRACT;
        end
      end
      
      COMPUTE_ACC2: begin
        // acc2 = (X^aibar - 1) * acc1 = acc1*X^aibar - acc1
        $display("%0t: COMPUTE_ACC2 - current_aibar=%0d, acc1[1][0:3]=[0x%016x, 0x%016x, 0x%016x, 0x%016x]", 
                 $time, current_aibar, acc1[1][0], acc1[1][1], acc1[1][2], acc1[1][3]);
        
        for (int q = 0; q <= K; q++) begin
          if (current_aibar < N_LVL2) begin
            for (int j = 0; j < current_aibar; j++) begin
              acc2[q][j] = -acc1[q][j + N_LVL2 - current_aibar] - acc1[q][j];
            end
            for (int j = current_aibar; j < N_LVL2; j++) begin
              acc2[q][j] = acc1[q][j - current_aibar] - acc1[q][j];
            end
          end else begin
            automatic int aibar_ = current_aibar - N_LVL2;
            for (int j = 0; j < aibar_; j++) begin
              acc2[q][j] = acc1[q][j + N_LVL2 - aibar_] - acc1[q][j];
            end
            for (int j = aibar_; j < N_LVL2; j++) begin
              acc2[q][j] = -acc1[q][j - aibar_] - acc1[q][j];
            end
          end
        end
        
        $display("%0t: COMPUTE_ACC2 - computed acc2[1][0:3]=[0x%016x, 0x%016x, 0x%016x, 0x%016x]", 
                 $time, acc2[1][0], acc2[1][1], acc2[1][2], acc2[1][3]);
        
        acc2_compute_done = 1'b1;
        next_state = DECOMPOSE_ACC2;
      end
      
      DECOMPOSE_ACC2: begin
        // Gadget decomposition: decompose acc2 into _2L levels
        // Based on tGsw64DecompH algorithm
        $display("%0t: DECOMPOSE_ACC2 - performing gadget decomposition, loop_counter=%0d", $time, loop_counter);
        
        // Debug: Check acc2 values
        $display("%0t: DECOMPOSE_ACC2 - acc2[1][0:3] = [0x%016x, 0x%016x, 0x%016x, 0x%016x]", 
                 $time, acc2[1][0], acc2[1][1], acc2[1][2], acc2[1][3]);
        
        // ✅ 实现真正的tGsw64DecompH算法
        // 基于TFHE标准：预处理 + 位提取 + halfBg偏移
        
        // Step 1: 预处理 - 添加offset (接近 torusDecompOffset64；具体数值由 Context 决定)
        // 使用半 Bg 累加的近似：sum_{i=0..ELL-1} 1 << (64 - (i+1)*BASE_LOG - 1)
        torus_decomp_offset = '0;
        for (int i = 0; i < ELL_LVL2; i++) begin
          torus_decomp_offset = torus_decomp_offset + (64'd1 << (64 - (i+1)*BASE_LOG - 1));
        end
        
        for (int q = 0; q <= K; q++) begin
          for (int j = 0; j < N_LVL2; j++) begin
            buf_storage[q][j] = acc2[q][j] + torus_decomp_offset;
          end
        end
        
        // Step 2: tGsw64DecompH标准分解
        // 正确展开索引：p = q*ELL_LVL2 + i，i为分解层(0..ELL_LVL2-1)，q为通道(0..K)
        for (int q = 0; q <= K; q++) begin
          for (int i = 0; i < ELL_LVL2; i++) begin
            automatic int p = q*ELL_LVL2 + i;
            automatic int decal = 64 - (i + 1) * BASE_LOG;
            automatic logic [31:0] temp1;
            automatic logic [31:0] half_bg = (1 << BASE_LOG) / 2;
            for (int j = 0; j < N_LVL2; j++) begin
              // 提取BASE_LOG位并减去halfBg
              temp1 = (buf_storage[q][j] >> decal) & MASK;
              decomp[p][j] = temp1 - half_bg;
            end
          end
        end
        
        // Debug: Verify tGsw64DecompH算法结果
        $display("%0t: DECOMPOSE_ACC2 - tGsw64DecompH completed", $time);
        $display("  ✅ 预处理: buf[0] = 0x%016x (acc2[1][0] + offset)", buf_storage[1][0]);
        $display("  ✅ 分解层级: _2L=%0d, BASE_LOG=%0d, half_bg=%0d", _2L, BASE_LOG, (1 << BASE_LOG) / 2);
        for (int p = 0; p < 4 && p < _2L; p++) begin
          $display("  Level %0d: decomp[%0d][0:3] = [0x%08x, 0x%08x, 0x%08x, 0x%08x]", 
                   p, p, decomp[p][0], decomp[p][1], decomp[p][2], decomp[p][3]);
        end
        
        decompose_done = 1'b1;
        next_state = NTT_FORWARD;
        $display("[WoKS] DECOMPOSE_ACC2 -> NTT_FORWARD: decompose_done=1, next_state=%0d", NTT_FORWARD);
      end
      
      NTT_FORWARD: begin
        $display("[WoKS] Entered NTT_FORWARD state at t=%0t, level=%0d, coeff=%0d, will_complete_all=%0b", $time, decomp_level_counter, coeff_counter, will_complete_all);
        // ✅ 真正的前向NTT实现 - 发送分解数据到共享NTT引擎
        // 基于C++参考：IntPolynomial_ifft_lvl2(decompFFT + p, decomp + p, env)
        
        // 检查是否完成所有分解层级
        will_complete_level = (coeff_counter == N_LVL2-1);
        will_complete_all = will_complete_level && (decomp_level_counter == _2L-1);
        
        if (!will_complete_all) begin
          // 发送分解数据到NTT引擎进行前向变换
          for (int p = 0; p < PSI; p++) begin
            for (int r = 0; r < R; r++) begin
              if (decomp_level_counter < _2L && coeff_counter < N_LVL2) begin
                decomp_ntt_data_avail[p][r] = 1'b1;
                decomp_ntt_data[p][r] = decomp[decomp_level_counter][coeff_counter];
              end else begin
                decomp_ntt_data_avail[p][r] = 1'b0;
                decomp_ntt_data[p][r] = '0;
              end
            end
          end
          
          // 设置控制信号 - 告诉NTT引擎当前数据的位置和状态
          decomp_ntt_sob = (coeff_counter == 0);  // Start of block
          decomp_ntt_eob = (coeff_counter == N_LVL2-1);  // End of block
          decomp_ntt_sol = (decomp_level_counter == 0);  // Start of level
          decomp_ntt_eol = (decomp_level_counter == _2L-1);  // End of level
          decomp_ntt_sog = (decomp_level_counter == 0 && coeff_counter == 0);  // Start of group
          decomp_ntt_eog = (decomp_level_counter == _2L-1 && coeff_counter == N_LVL2-1);  // End of group
          decomp_ntt_pbs_id = {BPBS_ID_W{1'b0}};  // PBS ID for this operation
          decomp_ntt_last_pbs = decomp_ntt_eog;
          decomp_ntt_full_throughput = 1'b1;
          decomp_ntt_ctrl_avail = 1'b1;
          
          $display("%t: NTT_FORWARD - Sending level=%0d, coeff=%0d, data=0x%08x to NTT", 
                   $time, decomp_level_counter, coeff_counter, decomp[decomp_level_counter][coeff_counter]);
          
          // 等待NTT引擎准备好接收数据
          $display("%t: NTT_FORWARD - NTT signals: ctrl_rdy=%0b, data_rdy=%0b, ctrl_avail=%0b", $time, decomp_ntt_ctrl_rdy, (&decomp_ntt_data_rdy), decomp_ntt_ctrl_avail);
          if (decomp_ntt_ctrl_rdy && (&decomp_ntt_data_rdy)) begin
            // NTT引擎已接收数据，移动到下一个系数
            next_state = NTT_FORWARD;
            $display("%t: NTT_FORWARD - Data accepted by NTT engine", $time);
          end else begin
            next_state = NTT_FORWARD;  // 等待NTT引擎ready
            $display("%t: NTT_FORWARD - waiting for NTT ready (ctrl_rdy=%0b, data_rdy=%0b)", $time, decomp_ntt_ctrl_rdy, (&decomp_ntt_data_rdy));
          end
        end else begin
          // 所有分解数据已发送给NTT引擎，外积在NTT核内部完成，
          // 这里等待NTT完成整个频域乘加与逆变换，再进入 ACCUMULATE
          ntt_forward_done = 1'b1;
          next_state = NTT_INVERSE;
          $display("%0t: NTT_FORWARD - all decomp data sent; waiting for INTT results", $time);
        end
      end
      
      // EXTERNAL_PRODUCT removed: external product is performed inside shared NTT core head
      
      NTT_INVERSE: begin
        // ✅ 反向NTT - 接收共享NTT引擎的反向变换结果
        // 基于C++参考：TorusPolynomial64_fft_lvl2(acc1->a + q, accFFT->a + q, env)
        
        // 正确的复用实现：
        // 1. 等待共享NTT引擎完成反向变换
        // 2. 通过ntt_next_data接口接收变换后的结果
        // 3. 将结果存储到acc1中供ACCUMULATE阶段使用
        
        // 检查NTT引擎是否有结果返回
        if (ntt_next_ctrl_avail && (|ntt_next_data_avail)) begin
          // 接收NTT引擎的反向变换结果
          ntt_recv_count_incr = '0;
          for (int p = 0; p < PSI; p++) begin
            for (int r = 0; r < R; r++) begin
              if (ntt_next_data_avail[p][r]) begin
                // 写回映射：q_idx 依据分层 p_total / ELL_LVL2，j 依据 coeff_counter
                if (coeff_counter < N_LVL2) begin
                  automatic int q_idx = (decomp_level_counter / ELL_LVL2);
                  if (q_idx <= K) begin
                    acc1[q_idx][coeff_counter] = post_scale_intt(ntt_next_data[p][r]);
                  end
                end
                ntt_next_data_rdy[p][r] = 1'b1;
                ntt_recv_count_incr = ntt_recv_count_incr + 1;
              end
            end
          end
          ntt_next_ctrl_rdy = 1'b1;
          
          // Debug: 打点q与层边界
          if ((coeff_counter % 256) == 0) begin
            $display("%t: NTT_INVERSE - q=%0d coeff=%0d recv_incr=%0d recv_total=%0d sample=0x%08x",
                     $time, (decomp_level_counter/ELL_LVL2), coeff_counter, ntt_recv_count_incr, ntt_recv_count + ntt_recv_count_incr, ntt_next_data[0][0][MOD_Q_W-1:0]);
          end
          if ((coeff_counter == N_LVL2-1)) begin
            $display("%t: NTT_INVERSE - Completed coeff ring for q=%0d (level=%0d)", $time, (decomp_level_counter/ELL_LVL2), decomp_level_counter);
          end
          
          // 继续接收或完成：按接收总数达到 (K+1)*N_LVL2 判定完成
          assert ((ntt_recv_count + ntt_recv_count_incr) <= ((K+1)*N_LVL2)) else $fatal("NTT_INVERSE - recv overflow: %0d > %0d", ntt_recv_count + ntt_recv_count_incr, ((K+1)*N_LVL2));
          next_state = ((ntt_recv_count + ntt_recv_count_incr) >= ((K+1)*N_LVL2)) ? ACCUMULATE : NTT_INVERSE;
          if (next_state == ACCUMULATE) begin
            ntt_inverse_done = 1'b1;
            $display("%t: NTT_INVERSE - All inverse NTT results received from shared engine", $time);
          end
        end else begin
          // 继续等待NTT引擎结果
          ntt_next_data_rdy = '0;
          ntt_next_ctrl_rdy = 1'b0;
          next_state = NTT_INVERSE;
          $display("%t: NTT_INVERSE - Waiting for inverse NTT results from shared engine", $time);
        end
      end
      
      ACCUMULATE: begin
        // acc += acc1
        for (int q = 0; q <= K; q++) begin
          for (int j = 0; j < N_LVL2; j++) begin
            acc[q][j] = acc[q][j] + acc1[q][j];
          end
        end
        
        // Set accumulate_done and transition back to BLIND_ROTATE_LOOP
        $display("%0t: ACCUMULATE - setting accumulate_done=1, returning to BLIND_ROTATE_LOOP", $time);
        accumulate_done = 1'b1;
        next_state = BLIND_ROTATE_LOOP;
      end
      
      SAMPLE_EXTRACT: begin
        // Sample extraction from final accumulator
        // result->a[0] = acc->a[0].coefs[0]
        result_a[0] = acc[0][0];
        
        // result->a[j] = -acc->a[0].coefs[N_lvl2 - j] for j > 0
        for (int j = 1; j < N_LVL2; j++) begin
          result_a[j] = -acc[0][N_LVL2 - j];
        end
        
        // result->b = acc->a[1].coefs[0] + mu2
        result_b = acc[1][0] + mu2;
        
        sample_extract_done = 1'b1;
        result_valid = 1'b1;
        next_state = DONE;
      end
      
      DONE: begin
        done = 1'b1;
        next_state = IDLE;
      end
    endcase
  end

// ==============================================================================================
// Decomposition and NTT Interface Logic
// ==============================================================================================
  // The external product operation requires careful coordination with the NTT engine
  // This involves:
  // 1. Decomposing the TLWE sample into multiple integer polynomials
  // 2. Converting each to NTT domain
  // 3. Point-wise multiplication with BSK coefficients
  // 4. Accumulating results
  // 5. Converting back from NTT domain
  
  // Note: This is a simplified interface - the actual implementation would need
  // detailed state machines for managing the NTT pipeline and data flow

  // Debug: Print current state every 10000 time units  
  always @(posedge clk) begin
    if ($time % 10000 == 0 && $time > 100000) begin
      $display("[WoKS_DEBUG] t=%0t: current_state=%0d (%s)", $time, current_state, 
               current_state == IDLE ? "IDLE" :
               current_state == GENERATE_TEST_VECTOR ? "GENERATE_TEST_VECTOR" :
               current_state == INIT_ACCUMULATOR ? "INIT_ACCUMULATOR" :
               current_state == BLIND_ROTATE_LOOP ? "BLIND_ROTATE_LOOP" :
               current_state == COMPUTE_ACC2 ? "COMPUTE_ACC2" :
               current_state == DECOMPOSE_ACC2 ? "DECOMPOSE_ACC2" :
               current_state == NTT_FORWARD ? "NTT_FORWARD" :
               current_state == NTT_INVERSE ? "NTT_INVERSE" :
               current_state == ACCUMULATE ? "ACCUMULATE" :
               current_state == SAMPLE_EXTRACT ? "SAMPLE_EXTRACT" :
               current_state == DONE ? "DONE" : "UNKNOWN");
    end
  end

endmodule