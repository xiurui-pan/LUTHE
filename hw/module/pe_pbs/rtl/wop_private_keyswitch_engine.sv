// ==============================================================================================
// Filename: wop_private_keyswitch_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// WoP-PBS Private KeySwitch Engine.
// This module implements the circuitPrivKS() function from circuit_bootstrapping.cpp.
// 
// C++ Algorithm:
// void circuitPrivKS(TLweSample32* result, const int u, const LweSample64* x, const Context* env) {
//     const int n_lvl2 = env->n_lvl2;
//     const int kslen = env->kslength_lvl21;
//     const int N_lvl1 = env->n_lvl1; // N_lvl1 = n_lvl1
//     const int basebit21 = env->ksbasebit_lvl21;
//     const int base21 = 1<<basebit21;       // base=2 in [CGGI16]
//     const int mask = base21 - 1;
//     const int64_t prec_offset = UINT64_C(1)<<(64-(1+basebit21*kslen)); //precision ILA: revoir
//
//     // clear result
//     for (int i = 0; i <= k ; ++i) {
//         for (int j = 0; j < N_lvl1; ++j) {
//             result->a[i].coefs[j] = 0;
//         }
//     }
//
//     // Private Key Switching 
//     for (int i = 0; i <= n_lvl2; ++i) {
//         const uint64_t aibar = x->a[i] + prec_offset;
//
//         for (int j = 0; j < kslen; ++j) {
//             const uint64_t aij = (aibar>>(64-(j+1)*basebit21)) & mask;
//
//             if (aij != 0){
//                 for (int q = 0; q <= k; ++q) {
//                     for (int p = 0; p < N_lvl1; ++p) result->a[q].coefs[p] -= env->privKS[u][i][j][aij].a[q].coefs[p];
//                 }
//             }
//         }
//     }
// }
//
// Author: Ray Pan 
// Date:   July 31, 2025
// ==============================================================================================

module wop_private_keyswitch_engine
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import ksk_mgr_common_param_pkg::*;
#(
  parameter int MOD_Q_W = 32,
  parameter int N_LVL1 = 1024,
  parameter int N_LVL2 = 2048,
  parameter int ELL_LVL1 = 3,
  parameter int K = 1,
  parameter int KSLENGTH_LVL21 = 4,
  parameter int KSBASEBIT_LVL21 = 3
)
(
  input  logic clk,
  input  logic s_rst_n,
  
  // Control interface
  input  logic start,
  output logic done,
  input  logic u_value, // 0 or 1 for Key_lvl1 selection
  
  // Input: LWE sample at level 2
  input  logic [N_LVL2-1:0][MOD_Q_W-1:0] input_lwe_a,
  input  logic [MOD_Q_W-1:0] input_lwe_b,
  input  logic input_valid,
  
  // Output: GGSW sample at level 1 (one decomposition level)
  output logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] ggsw_result,
  output logic result_valid,
  
  // KSK interface (shared)
  output logic ksk_req_vld,
  input  logic ksk_req_rdy,
  output logic [KSK_BATCH_ID_W-1:0] ksk_batch_id,
  input  logic ksk_data_avail,
  input  logic [KSK_PC-1:0][R-1:0][MOD_Q_W-1:0] ksk_data
);

// ==============================================================================================
// Local Parameters
// ==============================================================================================
  localparam int BASE21 = 1 << KSBASEBIT_LVL21;
  localparam int MASK = BASE21 - 1;
  localparam logic [63:0] PREC_OFFSET = 64'h1 << (64 - (1 + KSBASEBIT_LVL21 * KSLENGTH_LVL21));

// ==============================================================================================
// State Machine
// ==============================================================================================
  typedef enum logic [3:0] {
    IDLE,
    CLEAR_RESULT,
    LOOP_I_INIT,
    LOOP_I_COMPUTE,
    LOOP_J_INIT,
    LOOP_J_COMPUTE,
    LOAD_PRIVKS,
    ACCUMULATE,
    DONE
  } state_e;

  state_e current_state, next_state;

// ==============================================================================================
// Internal Registers
// ==============================================================================================
  // Loop counters
  logic [$clog2(N_LVL2+2)-1:0] i_counter; // for i = 0 to n_lvl2
  logic [$clog2(KSLENGTH_LVL21+1)-1:0] j_counter; // for j = 0 to kslen-1
  logic [$clog2(K+2)-1:0] q_counter; // for q = 0 to k
  logic [$clog2(N_LVL1+1)-1:0] p_counter; // for p = 0 to N_lvl1-1
  
  // Computation variables
  logic [63:0] aibar;
  logic [63:0] aij;
  logic [MOD_Q_W-1:0] current_input_coeff;
  
  // KSK access
  logic [KSK_BATCH_ID_W-1:0] privks_addr;
  logic privks_load_done;
  
  // Result accumulator
  logic [K:0][N_LVL1-1:0][MOD_Q_W-1:0] temp_result;
  
  // Control flags
  logic clear_done;
  logic i_loop_done;
  logic j_loop_done;
  logic accumulate_done;

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      i_counter <= '0;
      j_counter <= '0;
      q_counter <= '0;
      p_counter <= '0;
      temp_result <= '0;
      ggsw_result <= '0;
      result_valid <= 1'b0;
    end else begin
      current_state <= next_state;
      
      case (current_state)
        IDLE: begin
          if (start && input_valid) begin
            i_counter <= '0;
            j_counter <= '0;
            q_counter <= '0;
            p_counter <= '0;
            result_valid <= 1'b0;
          end
        end
        
        CLEAR_RESULT: begin
          // Clear result array
          if (q_counter <= K && p_counter < N_LVL1) begin
            temp_result[q_counter][p_counter] <= '0;
            
            if (p_counter == N_LVL1 - 1) begin
              p_counter <= '0;
              if (q_counter == K) begin
                q_counter <= '0;
                clear_done <= 1'b1;
              end else begin
                q_counter <= q_counter + 1;
              end
            end else begin
              p_counter <= p_counter + 1;
            end
          end
        end
        
        LOOP_I_INIT: begin
          if (i_counter <= N_LVL2) begin
            // Get current coefficient
            if (i_counter < N_LVL2) begin
              current_input_coeff <= input_lwe_a[i_counter];
            end else begin
              current_input_coeff <= input_lwe_b; // b coefficient
            end
            
            // Compute aibar = x->a[i] + prec_offset
            aibar <= {32'h0, current_input_coeff} + PREC_OFFSET;
            j_counter <= '0;
          end
        end
        
        LOOP_J_COMPUTE: begin
          // Compute aij = (aibar>>(64-(j+1)*basebit21)) & mask
          aij <= (aibar >> (64 - (j_counter + 1) * KSBASEBIT_LVL21)) & MASK;
        end
        
        ACCUMULATE: begin
          // result->a[q].coefs[p] -= env->privKS[u][i][j][aij].a[q].coefs[p]
          if (aij != 0 && ksk_data_avail) begin
            if (q_counter <= K && p_counter < N_LVL1) begin
              temp_result[q_counter][p_counter] <= temp_result[q_counter][p_counter] - ksk_data[0][0]; // Simplified access
              
              if (p_counter == N_LVL1 - 1) begin
                p_counter <= '0;
                if (q_counter == K) begin
                  q_counter <= '0;
                  accumulate_done <= 1'b1;
                end else begin
                  q_counter <= q_counter + 1;
                end
              end else begin
                p_counter <= p_counter + 1;
              end
            end
          end else begin
            accumulate_done <= 1'b1;
          end
        end
        
        DONE: begin
          ggsw_result <= temp_result;
          result_valid <= 1'b1;
        end
      endcase
    end
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    done = 1'b0;
    ksk_req_vld = 1'b0;
    ksk_batch_id = '0;
    
    // Control flags
    clear_done = 1'b0;
    i_loop_done = 1'b0;
    j_loop_done = 1'b0;
    accumulate_done = 1'b0;
    privks_load_done = 1'b0;
    
    case (current_state)
      IDLE: begin
        if (start && input_valid) begin
          next_state = CLEAR_RESULT;
        end
      end
      
      CLEAR_RESULT: begin
        if (q_counter == K && p_counter == N_LVL1 - 1) begin
          clear_done = 1'b1;
          next_state = LOOP_I_INIT;
        end
      end
      
      LOOP_I_INIT: begin
        if (i_counter <= N_LVL2) begin
          next_state = LOOP_J_INIT;
        end else begin
          i_loop_done = 1'b1;
          next_state = DONE;
        end
      end
      
      LOOP_I_COMPUTE: begin
        next_state = LOOP_J_INIT;
      end
      
      LOOP_J_INIT: begin
        if (j_counter < KSLENGTH_LVL21) begin
          next_state = LOOP_J_COMPUTE;
        end else begin
          j_loop_done = 1'b1;
          i_counter = i_counter + 1;
          next_state = LOOP_I_INIT;
        end
      end
      
      LOOP_J_COMPUTE: begin
        next_state = LOAD_PRIVKS;
      end
      
      LOAD_PRIVKS: begin
        // Load private key switching data
        ksk_req_vld = 1'b1;
        // Construct KSK address: privKS[u][i][j][aij]
        ksk_batch_id = {u_value, i_counter[7:0], j_counter[3:0], aij[3:0]}; // Simplified addressing
        
        if (ksk_req_rdy && ksk_data_avail) begin
          privks_load_done = 1'b1;
          next_state = ACCUMULATE;
        end
      end
      
      ACCUMULATE: begin
        if (accumulate_done) begin
          j_counter = j_counter + 1;
          q_counter = 0;
          p_counter = 0;
          next_state = LOOP_J_INIT;
        end
      end
      
      DONE: begin
        done = 1'b1;
        next_state = IDLE;
      end
    endcase
  end

endmodule