// ==============================================================================================
// Filename: wop_premodswitch_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// WoP-PBS Pre-ModSwitch Engine.
// This module implements the preModSwitch() function from circuit_bootstrapping.cpp.
// 
// C++ Algorithm:
// void preModSwitch(int* result, const LweSample32* x, const Context* env) {
//     const int n_lvl0 = env->n_lvl0;
//     const int N_lvl2 = env->n_lvl2; // N_lvl2 = n_lvl2
//     const int _2N = 2*N_lvl2;
//     uint64_t interv = ((UINT64_C(1)<<63)/_2N)*2; // width of each interval
//     uint64_t half_interval = interv/2; // begin of the first interval
//
//     // Mod Switching (as in modSwitchFromTorus32)
//     for (int i = 0; i <= n_lvl0; ++i){
//         uint64_t temp = (uint64_t(x->a[i])<<32) + half_interval; // RIVEDI
//         result[i] = temp/interv;
//         // assert(result[i] >= 0 && result[i] < _2N);
//     }
// }
//
// Author: Ray Pan 
// Date:   July 31, 2025
// ==============================================================================================

module wop_premodswitch_engine
#(
  parameter int N_LVL0 = 630,
  parameter int N_LVL2 = 2048
)
(
  input  logic clk,
  input  logic s_rst_n,
  
  // Control interface
  input  logic start,
  output logic done,
  
  // Input: LWE sample at level 0 (n_lvl0 + 1 coefficients)
  input  logic [N_LVL0:0][31:0] input_lwe_sample,
  input  logic input_valid,
  
  // Output: abar array for circuit bootstrap
  output logic [N_LVL0:0][31:0] abar_result,
  output logic result_valid
);

// ==============================================================================================
// Local Parameters
// ==============================================================================================
  localparam int _2N = 2 * N_LVL2;
  localparam logic [63:0] INTERV = ((64'h8000000000000000 / _2N) * 2); // width of each interval
  localparam logic [63:0] HALF_INTERVAL = INTERV / 2; // begin of first interval

// ==============================================================================================
// State Machine
// ==============================================================================================
  typedef enum logic [1:0] {
    IDLE,
    COMPUTE,
    DONE
  } state_e;

  state_e current_state, next_state;

// ==============================================================================================
// Internal Registers
// ==============================================================================================
  logic [$clog2(N_LVL0+2)-1:0] coeff_counter;
  logic [63:0] temp_calc;
  logic [31:0] division_result;
  
  // Division operation control
  logic div_start;
  logic div_done;
  logic [63:0] dividend;
  logic [63:0] divisor;
  logic [63:0] quotient;

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      coeff_counter <= '0;
      abar_result <= '0;
      result_valid <= 1'b0;
    end else begin
      current_state <= next_state;
      
      case (current_state)
        IDLE: begin
          if (start && input_valid) begin
            coeff_counter <= '0;
            result_valid <= 1'b0;
          end
        end
        
        COMPUTE: begin
          if (div_done) begin
            // Store division result
            abar_result[coeff_counter] <= quotient[31:0];
            
            if (coeff_counter == N_LVL0) begin
              result_valid <= 1'b1;
            end else begin
              coeff_counter <= coeff_counter + 1;
            end
          end
        end
        
        DONE: begin
          // Keep result valid until next operation
        end
      endcase
    end
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    done = 1'b0;
    div_start = 1'b0;
    dividend = '0;
    divisor = INTERV;
    
    case (current_state)
      IDLE: begin
        if (start && input_valid) begin
          next_state = COMPUTE;
        end
      end
      
      COMPUTE: begin
        // Perform modular switching calculation
        // temp = (uint64_t(x->a[i])<<32) + half_interval
        temp_calc = ({32'h0, input_lwe_sample[coeff_counter]} << 32) + HALF_INTERVAL;
        
        // Start division: result[i] = temp/interv
        div_start = 1'b1;
        dividend = temp_calc;
        
        if (div_done) begin
          if (coeff_counter == N_LVL0) begin
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
// Division Unit
// ==============================================================================================
  // Simple division implementation
  // For better performance, this could be replaced with a pipelined divider
  
  logic [7:0] div_counter;
  logic [63:0] temp_dividend;
  logic [63:0] temp_quotient;
  
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      div_counter <= '0;
      temp_dividend <= '0;
      temp_quotient <= '0;
      div_done <= 1'b0;
      quotient <= '0;
    end else begin
      if (div_start) begin
        div_counter <= 8'd63; // Start from MSB
        temp_dividend <= dividend;
        temp_quotient <= '0;
        div_done <= 1'b0;
      end else if (div_counter != 8'hFF) begin
        // Perform one step of long division
        temp_quotient <= temp_quotient << 1;
        
        if (temp_dividend >= divisor) begin
          temp_dividend <= temp_dividend - divisor;
          temp_quotient[0] <= 1'b1;
        end else begin
          temp_quotient[0] <= 1'b0;
        end
        
        temp_dividend <= temp_dividend << 1;
        div_counter <= div_counter - 1;
        
        if (div_counter == 0) begin
          quotient <= temp_quotient;
          div_done <= 1'b1;
        end
      end else begin
        div_done <= 1'b0;
      end
    end
  end

endmodule