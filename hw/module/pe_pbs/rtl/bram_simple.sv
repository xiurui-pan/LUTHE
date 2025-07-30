// ==============================================================================================
// Filename: bram_simple.sv
// ----------------------------------------------------------------------------------------------
// Description:
//
// Simple BRAM module for data storage in WoP-PBS kernel.
// This module provides a simple dual-port BRAM interface for storing
// polynomial coefficients and other data structures.
//
// Author: Ray Pan 
// Date:   July 14, 2025
// ==============================================================================================

module bram_simple
#(
  parameter int ADDR_W = 11,
  parameter int DATA_W = 32,
  parameter int DEPTH = 2**ADDR_W
)
(
  input  logic clk,
  
  // Write port
  input  logic wr_en,
  input  logic [ADDR_W-1:0] wr_addr,
  input  logic [DATA_W-1:0] wr_data,
  
  // Read port
  input  logic [ADDR_W-1:0] rd_addr,
  output logic [DATA_W-1:0] rd_data
);

// ==============================================================================================
// BRAM Memory Array
// ==============================================================================================
  logic [DATA_W-1:0] bram_array [DEPTH-1:0];

// ==============================================================================================
// Write Logic
// ==============================================================================================
  always_ff @(posedge clk) begin
    if (wr_en) begin
      bram_array[wr_addr] <= wr_data;
    end
  end

// ==============================================================================================
// Read Logic
// ==============================================================================================
  always_ff @(posedge clk) begin
    rd_data <= bram_array[rd_addr];
  end

endmodule 