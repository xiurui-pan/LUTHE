// ==============================================================================================
// Filename: tb_wop_premodswitch_engine.cpp
// ----------------------------------------------------------------------------------------------
// Description:
//
// C++ driver for WoP-PBS Pre-ModSwitch Engine testbench.
// This file provides the main() function for Verilator simulation and calls the original
// C++ functions as golden reference.
//
// Author: Ray Pan 
// Date:   July 31, 2025
// ==============================================================================================

#include <verilated.h>
#include <verilated_fst_c.h>
#include <verilated_dpi.h>
#include "Vtb_wop_premodswitch_engine.h"

// Include original C++ headers
#include "tfhe_functions.h"

// Global variables for golden reference
static Context* g_context = nullptr;
static LweSample32* g_input_lwe = nullptr;
static int* g_result = nullptr;

// DPI-C exported functions
extern "C" {

// Initialize golden reference model
void init_premodswitch_golden_reference() {
    g_context = new Context();
    g_input_lwe = new LweSample32(g_context->n_lvl0);
    g_result = new int[g_context->n_lvl0 + 1];
    
    printf("Pre-ModSwitch golden reference initialized\n");
    printf("n_lvl0 = %d, N_lvl2 = %d\n", g_context->n_lvl0, g_context->N_lvl2);
}

// Run golden reference
void run_premodswitch_golden_reference(const svBitVecVal* input_data, svBitVecVal* expected_output) {
    // Copy input data to LWE sample
    for (int i = 0; i <= g_context->n_lvl0; i++) {
        g_input_lwe->a[i] = input_data[i];
    }
    
    // Call original preModSwitch function
    preModSwitch(g_result, g_input_lwe, g_context);
    
    // Copy results to expected output
    for (int i = 0; i <= g_context->n_lvl0; i++) {
        expected_output[i] = g_result[i];
    }
    
    printf("Pre-ModSwitch golden reference computation completed\n");
}

// Cleanup golden reference
void cleanup_premodswitch_golden_reference() {
    if (g_result) {
        delete[] g_result;
        g_result = nullptr;
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
    init_premodswitch_golden_reference();
    
    // Create DUT instance
    Vtb_wop_premodswitch_engine* tb = new Vtb_wop_premodswitch_engine;
    
    // Initialize trace dump
    Verilated::traceEverOn(true);
    VerilatedFstC* tfp = new VerilatedFstC;
    tb->trace(tfp, 99);
    tfp->open("tb_wop_premodswitch_engine.fst");
    
    // Run simulation
    int time_counter = 0;
    while (!Verilated::gotFinish() && time_counter < 10000000) {
        tb->eval();
        tfp->dump(time_counter);
        time_counter++;
    }
    
    // Cleanup
    tfp->close();
    delete tb;
    delete tfp;
    cleanup_premodswitch_golden_reference();
    
    return 0;
}