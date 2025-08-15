#include <cstdio>
#include <cstdint>

// C++ reference implementation (from tfhe-cpu-baseline-wopbs)
inline uint32_t modSwitchToTorus32_ref(int32_t mu, int32_t Msize) {
    uint64_t interv = ((UINT64_C(1)<<63)/Msize)*2; // width of each intervall
    uint64_t phase64 = mu*interv;
    //floor to the nearest multiples of interv
    return phase64>>32;
}

// Hardware implementation (what we put in SystemVerilog)
uint32_t modSwitchToTorus32_hw(int32_t mu, int32_t Msize) {
    uint64_t interv = (0x8000000000000000ULL / Msize) * 2;
    uint64_t phase64 = mu * interv;
    return phase64 >> 32;
}

int main() {
    printf("=== modSwitchToTorus32 Verification ===\n\n");
    
    // Test the specific values used in big_lut.cpp
    int32_t mu = 2;
    int32_t Msize = 32;  // FULL_MSG_SIZE = 1 << (1 + 2 + 2) = 32
    
    uint32_t ref_result = modSwitchToTorus32_ref(mu, Msize);
    uint32_t hw_result = modSwitchToTorus32_hw(mu, Msize);
    
    printf("Input: mu=%d, Msize=%d\n", mu, Msize);
    printf("C++ Reference Result: 0x%08x (%u)\n", ref_result, ref_result);
    printf("Hardware Implementation: 0x%08x (%u)\n", hw_result, hw_result);
    printf("Match: %s\n", (ref_result == hw_result) ? "✅ YES" : "❌ NO");
    printf("\n");
    
    // Show intermediate calculations
    printf("Intermediate Calculations:\n");
    uint64_t interv_ref = ((UINT64_C(1)<<63)/Msize)*2;
    uint64_t interv_hw = (0x8000000000000000ULL / Msize) * 2;
    printf("interv (reference): 0x%016llx\n", interv_ref);
    printf("interv (hardware):  0x%016llx\n", interv_hw);
    printf("interv match: %s\n", (interv_ref == interv_hw) ? "✅ YES" : "❌ NO");
    printf("\n");
    
    uint64_t phase64_ref = mu * interv_ref;
    uint64_t phase64_hw = mu * interv_hw;
    printf("phase64 (reference): 0x%016llx\n", phase64_ref);
    printf("phase64 (hardware):  0x%016llx\n", phase64_hw);
    printf("phase64 match: %s\n", (phase64_ref == phase64_hw) ? "✅ YES" : "❌ NO");
    printf("\n");
    
    // Test a few more values
    printf("Additional Test Cases:\n");
    int test_cases[][2] = {{1, 32}, {3, 32}, {0, 32}, {2, 16}, {2, 64}};
    int num_cases = sizeof(test_cases) / sizeof(test_cases[0]);
    
    for (int i = 0; i < num_cases; i++) {
        int32_t test_mu = test_cases[i][0];
        int32_t test_Msize = test_cases[i][1];
        uint32_t test_ref = modSwitchToTorus32_ref(test_mu, test_Msize);
        uint32_t test_hw = modSwitchToTorus32_hw(test_mu, test_Msize);
        printf("mu=%d, Msize=%d: ref=0x%08x, hw=0x%08x, match=%s\n", 
               test_mu, test_Msize, test_ref, test_hw, 
               (test_ref == test_hw) ? "✅" : "❌");
    }
    
    printf("\n=== Verification Complete ===\n");
    return 0;
}
