// ==============================================================================================
// Filename: tb_wop_bit_extract_engine.cpp
// ----------------------------------------------------------------------------------------------
// Description:
//
// C++ driver for WoP-PBS Bit Extract Engine testbench.
// This file provides the main() function for Verilator simulation and calls the original
// C++ functions as golden reference.
//
// Author: Ray Pan 
// Date:   July 31, 2025
// ==============================================================================================

#include <verilated.h>
#include <verilated_fst_c.h>
#include <verilated_dpi.h>
#include "Vtb_wop_bit_extract_engine.h"

// Include original C++ headers
#include "tfhe_functions.h"

// Global variables for golden reference
static Context* g_context = nullptr;
static LweSample32* g_input_lwe = nullptr;
static LweSample32* g_output_bits = nullptr;

// DPI-C exported functions
extern "C" {

// Initialize golden reference model
void init_golden_reference() {
    // Create context (this initializes keys and parameters)
    g_context = new Context();
    
    // Allocate LWE samples
    g_input_lwe = new LweSample32(g_context->n_lvl1);
    g_output_bits = new_array1<LweSample32>(2, g_context->n_lvl1);
    
    printf("Golden reference model initialized\n");
    printf("n_lvl1 = %d\n", g_context->n_lvl1);
}

// Run golden reference
void run_golden_reference(const svBitVecVal* input_data, svBitVecVal* expected_output_0, svBitVecVal* expected_output_1) {
    // Copy input data to LWE sample
    for (int i = 0; i <= g_context->n_lvl1; i++) {
        g_input_lwe->a[i] = input_data[i];
    }
    
    // Call original bitExtract function
    bitExtract(g_output_bits, g_input_lwe, g_context);
    
    // Copy results to expected outputs
    for (int i = 0; i <= g_context->n_lvl1; i++) {
        expected_output_0[i] = g_output_bits[0].a[i];
        expected_output_1[i] = g_output_bits[1].a[i];
    }
    
    printf("Golden reference computation completed\n");
}

// Cleanup golden reference
void cleanup_golden_reference() {
    if (g_output_bits) {
        delete_array1<LweSample32>(g_output_bits);
        g_output_bits = nullptr;
    }
    if (g_input_lwe) {
        delete g_input_lwe;
        g_input_lwe = nullptr;
    }
    if (g_context) {
        delete g_context;
        g_context = nullptr;
    }
}

} // extern "C"

int main(int argc, char** argv) {
    // Initialize Verilator
    Verilated::commandArgs(argc, argv);
    
    // Initialize golden reference
    init_golden_reference();
    
    // Create DUT instance
    Vtb_wop_bit_extract_engine* tb = new Vtb_wop_bit_extract_engine;
    
    // Initialize trace dump
    Verilated::traceEverOn(true);
    VerilatedFstC* tfp = new VerilatedFstC;
    tb->trace(tfp, 99);
    tfp->open("tb_wop_bit_extract_engine.fst");
    
    // Set golden reference function pointers in testbench
    // (The testbench will call these functions via DPI-C or direct calls)
    
    // Run simulation
    int time_counter = 0;
    while (!Verilated::gotFinish() && time_counter < 1000000) {
        tb->eval();
        tfp->dump(time_counter);
        time_counter++;
    }
    
    // Cleanup
    tfp->close();
    delete tb;
    delete tfp;
    cleanup_golden_reference();
    
    return 0;
}