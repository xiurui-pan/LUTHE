#include <cstdint>
#include <cstdio>
#include <cstring>

// DPI-C interface for SystemVerilog
extern "C" {

// Simple bit extraction golden reference based on bit analysis
// This mimics the expected behavior without full cryptographic context
void bit_extract_golden_ref(
    const int* input_sample,       // Input LWE sample [N_LVL1+1]
    int* output_0,                 // Output bit 0 [N_LVL1+1] 
    int* output_1,                 // Output bit 1 [N_LVL1+1]
    int n_lvl1                     // N_LVL1 parameter
) {
    // Temporary arrays for intermediate results (fixed size to avoid DPI-C issues)
    int tmp_sample[2048];
    int small_sample[2048]; 
    int diff_sample[2048];
    
    printf("[CPP_GOLDEN] bit_extract_golden_ref called with N_LVL1=%d\n", n_lvl1);
    printf("[CPP_GOLDEN] Input sample[0-4]: 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x\n", 
           input_sample[0], input_sample[1], input_sample[2], input_sample[3], input_sample[4]);
    
    // Step 1: tmp = input << 4 (move bit 27 to bit 31)
    for (int i = 0; i <= n_lvl1; i++) {
        tmp_sample[i] = input_sample[i] << 4;
    }
    
    // Step 2: Simulate PBS with map_to_bit31 LUT on shifted input
    // TLwe32_Keyswitch_Bootstrapping_Extract_lvl1(&outs[0], map_to_bit31, tmp, 2, ctx)
    // map_to_bit31 LUT: b->coefs[i] = -(1 << 30), extracts bit 31 -> maps 0->0x00000000, 1->0x80000000
    for (int i = 0; i < n_lvl1; i++) {
        output_0[i] = (tmp_sample[i] & 0x80000000) ? 0x80000000 : 0x00000000;
    }
    // LUT contributes -(1<<30) to constant term, then code adds +(1<<30)
    output_0[n_lvl1] = -(1 << 30);  // LUT constant term
    output_0[n_lvl1] += (1 << 30);  // Code offset: outs[0].b[0] += 1 << 30
    
    // Step 3: Simulate PBS with map_to_bit27 LUT on shifted input  
    // TLwe32_Keyswitch_Bootstrapping_Extract_lvl1(small, map_to_bit27, tmp, 2, ctx)
    // map_to_bit27 LUT: b->coefs[i] = -(1 << 26), extracts bit 31 -> maps 0->0x00000000, 1->0x08000000
    for (int i = 0; i < n_lvl1; i++) {
        small_sample[i] = (tmp_sample[i] & 0x80000000) ? 0x08000000 : 0x00000000;
    }
    // LUT contributes -(1<<26) to constant term, then code adds +(1<<26)
    small_sample[n_lvl1] = -(1 << 26);  // LUT constant term
    small_sample[n_lvl1] += (1 << 26);  // Code offset: small[0].b[0] += 1 << 26
    
    // Step 4: tmp = (input - small) << 3 (remove bit 27, shift bit 28 to bit 31)
    for (int i = 0; i <= n_lvl1; i++) {
        diff_sample[i] = (input_sample[i] - small_sample[i]) << 3;
    }
    
    // Step 5: Simulate PBS with map_to_bit31 LUT on difference (extracts bit 28)
    // TLwe32_Keyswitch_Bootstrapping_Extract_lvl1(&outs[1], map_to_bit31, tmp, 2, ctx)
    // map_to_bit31 LUT: b->coefs[i] = -(1 << 30), extracts bit 31 -> maps 0->0x00000000, 1->0x80000000
    for (int i = 0; i < n_lvl1; i++) {
        output_1[i] = (diff_sample[i] & 0x80000000) ? 0x80000000 : 0x00000000;
    }
    // LUT contributes -(1<<30) to constant term, then code adds +(1<<30)
    output_1[n_lvl1] = -(1 << 30);  // LUT constant term  
    output_1[n_lvl1] += (1 << 30);  // Code offset: outs[1].b[0] += 1 << 30
    
    printf("[CPP_GOLDEN] Output_0[0-4]: 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x\n", 
           output_0[0], output_0[1], output_0[2], output_0[3], output_0[4]);
    printf("[CPP_GOLDEN] Output_1[0-4]: 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x\n", 
           output_1[0], output_1[1], output_1[2], output_1[3], output_1[4]);
    printf("[CPP_GOLDEN] Output_0[N_LVL1=%d]: 0x%08x\n", n_lvl1, output_0[n_lvl1]);
    printf("[CPP_GOLDEN] Output_1[N_LVL1=%d]: 0x%08x\n", n_lvl1, output_1[n_lvl1]);
}

} // extern "C"