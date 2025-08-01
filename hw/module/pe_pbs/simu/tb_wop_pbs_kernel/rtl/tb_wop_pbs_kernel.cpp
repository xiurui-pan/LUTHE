// ==============================================================================================
// Filename: tb_wop_pbs_kernel.cpp
// ----------------------------------------------------------------------------------------------
// Description:
//
// C++ driver for WoP-PBS Kernel testbench.
// This file provides the main() function for Verilator simulation.
//
// Author: Ray Pan 
// Date:   July 31, 2025
// ==============================================================================================

#include <verilated.h>
#include <verilated_fst_c.h>
#include "Vtb_wop_pbs_kernel.h"

int main(int argc, char** argv) {
    // Initialize Verilator
    Verilated::commandArgs(argc, argv);
    
    // Create DUT instance
    Vtb_wop_pbs_kernel* tb = new Vtb_wop_pbs_kernel;
    
    // Initialize trace dump
    Verilated::traceEverOn(true);
    VerilatedFstC* tfp = new VerilatedFstC;
    tb->trace(tfp, 99);
    tfp->open("tb_wop_pbs_kernel.fst");
    
    // Run simulation
    int time_counter = 0;
    while (!Verilated::gotFinish() && time_counter < 100000000) {
        tb->eval();
        tfp->dump(time_counter);
        time_counter++;
    }
    
    // Cleanup
    tfp->close();
    delete tb;
    delete tfp;
    
    return 0;
}