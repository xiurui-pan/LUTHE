// ==============================================================================================
// Filename: wop_pbs_instruction_manager.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// WoP-PBS Instruction Manager.
// This module manages the instruction sequences for the three stages of WoP-PBS:
// 1. Bit Extraction: Generates PBS instructions for extracting individual bits
// 2. Circuit Bootstrapping: Generates PBS instructions for LWE->GGSW conversion
// 3. Vertical Packing: Generates PBS instructions for final LUT evaluation
//
// Each stage uses the standard PBS with different LUTs and parameters.
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module wop_pbs_instruction_manager
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import regf_common_param_pkg::*;
  import hpu_common_instruction_pkg::*;
#(
  parameter int MAX_BIT_WIDTH = 20
)
(
  input  logic clk,
  input  logic s_rst_n,
  
  // WoP-PBS instruction input
  input  logic [PE_INST_W-1:0] wop_pbs_inst,
  input  logic wop_pbs_inst_vld,
  output logic wop_pbs_inst_rdy,
  
  // PBS instruction output
  output logic [PE_INST_W-1:0] pbs_inst,
  output logic pbs_inst_vld,
  input  logic pbs_inst_rdy,
  input  logic pbs_inst_ack,
  
  // Stage control
  output logic [2:0] current_stage,
  output logic [MAX_BIT_WIDTH-1:0] current_bit,
  output logic wop_pbs_done,
  
  // Configuration
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] bit_extract_lut_base_addr,
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] circuit_bs_lut_base_addr,
  input  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] vertical_pack_lut_addr
);

// ==============================================================================================
// WoP-PBS Instruction Format (decoded from input)
// ==============================================================================================
  typedef struct packed {
    logic [REGF_ADDR_W-1:0] input_addr;      // Input LWE ciphertext address
    logic [REGF_ADDR_W-1:0] output_addr;     // Output address
    logic [MAX_BIT_WIDTH-1:0] bit_width;     // Number of bits to process
    logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] lut_base_addr; // Base address for LUTs
  } wop_pbs_inst_t;

// ==============================================================================================
// PBS Instruction Format (standard pe_pbs instruction)
// ==============================================================================================
  typedef struct packed {
    logic [REGF_ADDR_W-1:0] input_addr;      // Input address in RegFile
    logic [REGF_ADDR_W-1:0] output_addr;     // Output address in RegFile
    logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] lut_addr; // LUT address in HBM
    logic [7:0] pbs_type;                     // PBS operation type
  } pbs_inst_t;

// ==============================================================================================
// State Machine
// ==============================================================================================
  typedef enum logic [2:0] {
    IDLE = 3'd0,
    STAGE1_BIT_EXTRACT = 3'd1,
    STAGE2_CIRCUIT_BS = 3'd2,
    STAGE3_VERTICAL_PACK = 3'd3,
    DONE = 3'd4
  } state_e;

  state_e current_state, next_state;

// ==============================================================================================
// Internal Registers
// ==============================================================================================
  wop_pbs_inst_t decoded_inst;
  logic [MAX_BIT_WIDTH-1:0] bit_counter;
  logic [MAX_BIT_WIDTH-1:0] max_bits;
  
  // Temporary storage for intermediate results
  logic [REGF_ADDR_W-1:0] bit_extract_results [MAX_BIT_WIDTH-1:0];
  logic [REGF_ADDR_W-1:0] circuit_bs_results [MAX_BIT_WIDTH-1:0];
  
  // Address management
  logic [REGF_ADDR_W-1:0] temp_addr_counter;

// ==============================================================================================
// Instruction Decoding
// ==============================================================================================
  always_comb begin
    // Decode WoP-PBS instruction format
    // This depends on the specific instruction encoding used
    decoded_inst.input_addr = wop_pbs_inst[REGF_ADDR_W-1:0];
    decoded_inst.output_addr = wop_pbs_inst[2*REGF_ADDR_W-1:REGF_ADDR_W];
    decoded_inst.bit_width = wop_pbs_inst[2*REGF_ADDR_W+MAX_BIT_WIDTH-1:2*REGF_ADDR_W];
    decoded_inst.lut_base_addr = wop_pbs_inst[PE_INST_W-1:2*REGF_ADDR_W+MAX_BIT_WIDTH];
  end

// ==============================================================================================
// State Machine Implementation
// ==============================================================================================
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      current_state <= IDLE;
      bit_counter <= '0;
      temp_addr_counter <= '0;
    end else begin
      current_state <= next_state;
      
      // Update counters based on state transitions
      case (current_state)
        IDLE: begin
          if (wop_pbs_inst_vld) begin
            bit_counter <= '0;
            max_bits <= decoded_inst.bit_width;
            temp_addr_counter <= decoded_inst.output_addr + 100; // Offset for temporary storage
          end
        end
        
        STAGE1_BIT_EXTRACT: begin
          if (pbs_inst_ack) begin
            bit_counter <= bit_counter + 1;
            bit_extract_results[bit_counter] <= temp_addr_counter + bit_counter;
          end
        end
        
        STAGE2_CIRCUIT_BS: begin
          if (pbs_inst_ack) begin
            bit_counter <= bit_counter + 1;
            circuit_bs_results[bit_counter] <= temp_addr_counter + max_bits + bit_counter;
          end
        end
        
        STAGE3_VERTICAL_PACK: begin
          if (pbs_inst_ack) begin
            // Final stage complete
          end
        end
      endcase
    end
  end

  always_comb begin
    // Default assignments
    next_state = current_state;
    wop_pbs_inst_rdy = 1'b0;
    pbs_inst_vld = 1'b0;
    pbs_inst = '0;
    wop_pbs_done = 1'b0;
    current_stage = current_state;
    current_bit = bit_counter;
    
    case (current_state)
      IDLE: begin
        wop_pbs_inst_rdy = 1'b1;
        if (wop_pbs_inst_vld) begin
          next_state = STAGE1_BIT_EXTRACT;
        end
      end
      
      STAGE1_BIT_EXTRACT: begin
        if (bit_counter < max_bits) begin
          // Generate PBS instruction for bit extraction
          pbs_inst = generate_bit_extract_inst(bit_counter);
          pbs_inst_vld = pbs_inst_rdy;
          
          if (pbs_inst_ack && (bit_counter + 1 == max_bits)) begin
            next_state = STAGE2_CIRCUIT_BS;
          end
        end
      end
      
      STAGE2_CIRCUIT_BS: begin
        if (bit_counter < max_bits) begin
          // Generate PBS instruction for circuit bootstrapping
          pbs_inst = generate_circuit_bs_inst(bit_counter);
          pbs_inst_vld = pbs_inst_rdy;
          
          if (pbs_inst_ack && (bit_counter + 1 == max_bits)) begin
            next_state = STAGE3_VERTICAL_PACK;
          end
        end
      end
      
      STAGE3_VERTICAL_PACK: begin
        // Generate PBS instruction for vertical packing
        pbs_inst = generate_vertical_pack_inst();
        pbs_inst_vld = pbs_inst_rdy;
        
        if (pbs_inst_ack) begin
          next_state = DONE;
        end
      end
      
      DONE: begin
        wop_pbs_done = 1'b1;
        next_state = IDLE;
      end
    endcase
  end

// ==============================================================================================
// PBS Instruction Generation Functions
// ==============================================================================================
  
  function automatic logic [PE_INST_W-1:0] generate_bit_extract_inst(input logic [MAX_BIT_WIDTH-1:0] bit_pos);
    pbs_inst_t inst;
    
    // Stage 1: Bit Extraction
    // Input: Original LWE ciphertext
    // LUT: Bit extraction LUT for position bit_pos
    // Output: LWE ciphertext containing only the bit at position bit_pos
    
    inst.input_addr = decoded_inst.input_addr;
    inst.output_addr = temp_addr_counter + bit_pos;
    inst.lut_addr = bit_extract_lut_base_addr + (bit_pos * LUT_SIZE_BYTES);
    inst.pbs_type = PBS_TYPE_BIT_EXTRACT;
    
    return inst;
  endfunction
  
  function automatic logic [PE_INST_W-1:0] generate_circuit_bs_inst(input logic [MAX_BIT_WIDTH-1:0] bit_pos);
    pbs_inst_t inst;
    
    // Stage 2: Circuit Bootstrapping
    // Input: LWE bit ciphertext from stage 1
    // LUT: Circuit bootstrapping LUT (converts LWE to GGSW)
    // Output: GGSW ciphertext
    
    inst.input_addr = bit_extract_results[bit_pos];
    inst.output_addr = temp_addr_counter + max_bits + bit_pos;
    inst.lut_addr = circuit_bs_lut_base_addr + (bit_pos * GGSW_LUT_SIZE_BYTES);
    inst.pbs_type = PBS_TYPE_CIRCUIT_BS;
    
    return inst;
  endfunction
  
  function automatic logic [PE_INST_W-1:0] generate_vertical_pack_inst();
    pbs_inst_t inst;
    
    // Stage 3: Vertical Packing
    // Input: All GGSW bit ciphertexts from stage 2
    // LUT: Large evaluation LUT (2^bit_width entries)
    // Output: Final result
    
    inst.input_addr = temp_addr_counter + max_bits; // Base address of GGSW results
    inst.output_addr = decoded_inst.output_addr;
    inst.lut_addr = vertical_pack_lut_addr;
    inst.pbs_type = PBS_TYPE_VERTICAL_PACK;
    
    return inst;
  endfunction

// ==============================================================================================
// Constants for PBS Types
// ==============================================================================================
  localparam logic [7:0] PBS_TYPE_BIT_EXTRACT = 8'h01;
  localparam logic [7:0] PBS_TYPE_CIRCUIT_BS = 8'h02;
  localparam logic [7:0] PBS_TYPE_VERTICAL_PACK = 8'h03;
  
  // LUT size constants (these should be defined based on the actual implementation)
  localparam int LUT_SIZE_BYTES = 8192;        // Size of each bit extraction LUT
  localparam int GGSW_LUT_SIZE_BYTES = 16384;  // Size of each circuit BS LUT

endmodule