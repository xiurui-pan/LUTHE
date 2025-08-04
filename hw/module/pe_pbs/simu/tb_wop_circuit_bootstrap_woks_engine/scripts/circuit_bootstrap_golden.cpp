#include <cstdint>
#include <cstdio>
#include <cstring>

// DPI-C interface for SystemVerilog
extern "C" {

// Circuit Bootstrap WoKS golden reference based on algorithm analysis
// This mimics the expected behavior from circuit_bootstrapping.cpp
void circuit_bootstrap_woks_golden_ref(
    const uint64_t mu,                 // Input mu parameter
    const int* abar,                   // Pre-modswitch result [n_lvl0+1]
    uint64_t* result_a,                // Output LWE sample a part [n_lvl2]
    uint64_t* result_b,                // Output LWE sample b part
    int n_lvl0,                        // N_LVL0 parameter  
    int n_lvl2                         // N_LVL2 parameter
) {
    printf("[CPP_GOLDEN] circuit_bootstrap_woks_golden_ref called\n");
    printf("[CPP_GOLDEN] mu=0x%016llx, n_lvl0=%d, n_lvl2=%d\n", mu, n_lvl0, n_lvl2);
    printf("[CPP_GOLDEN] abar[0-4]: 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x\n", 
           abar[0], abar[1], abar[2], abar[3], abar[4]);
    
    // Circuit Bootstrap Algorithm Implementation
    const int N2 = n_lvl2 / 2;
    const uint64_t mu2 = mu / 2;
    const int bbar = abar[n_lvl0];
    
    // Temporary arrays
    uint64_t testvect_temp[2048];
    uint64_t testvect[2048];
    uint64_t acc[2][2048];      // acc[k+1][n_lvl2], k=1 so [2][n_lvl2]
    uint64_t acc1[2][2048];
    uint64_t acc2[2][2048];
    
    printf("[CPP_GOLDEN] mu2=0x%016llx, bbar=%d, N2=%d\n", mu2, bbar, N2);
    
    // Step 1: Generate test vector = (1+X+...+X^{N-1})*X^{N/2}*mu2
    for (int j = 0; j < N2; j++) {
        testvect_temp[j] = -mu2; // Negative for first half
    }
    for (int j = N2; j < n_lvl2; j++) {
        testvect_temp[j] = mu2;  // Positive for second half
    }
    
    // Step 2: Test Vector *= X^{bbar} (rotation)
    if (bbar < n_lvl2) {
        for (int j = 0; j < n_lvl2 - bbar; j++) {
            testvect[j] = testvect_temp[j + bbar];
        }
        for (int j = n_lvl2 - bbar; j < n_lvl2; j++) {
            testvect[j] = -testvect_temp[j - (n_lvl2 - bbar)]; // Sign flip due to X^N = -1
        }
    } else {
        int bbar_ = bbar - n_lvl2;
        for (int j = 0; j < n_lvl2 - bbar_; j++) {
            testvect[j] = -testvect_temp[j + bbar_];
        }
        for (int j = n_lvl2 - bbar_; j < n_lvl2; j++) {
            testvect[j] = testvect_temp[j - (n_lvl2 - bbar_)];
        }
    }
    
    printf("[CPP_GOLDEN] testvect[0-4]: 0x%016llx 0x%016llx 0x%016llx 0x%016llx 0x%016llx\n",
           testvect[0], testvect[1], testvect[2], testvect[3], testvect[4]);
    
    // Step 3: Initialize accumulator as noiseless trivial TLweSample
    for (int j = 0; j < n_lvl2; j++) {
        acc[0][j] = 0;              // a[0] = 0 (k=1)
        acc[1][j] = testvect[j];    // a[1] = testvect (b part)
    }
    
    // Step 4: Blind rotation loop
    for (int i = 0; i < n_lvl0; i++) {
        int aibar = abar[i];
        if (aibar == 0) continue;
        
        printf("[CPP_GOLDEN] Processing i=%d, aibar=%d\n", i, aibar);
        
        // acc1 = acc
        for (int q = 0; q <= 1; q++) { // k=1, so q <= 1
            for (int j = 0; j < n_lvl2; j++) {
                acc1[q][j] = acc[q][j];
            }
        }
        
        // acc2 = (X^aibar - 1) * acc1 = acc1*X^aibar - acc1
        for (int q = 0; q <= 1; q++) {
            if (aibar < n_lvl2) {
                for (int j = 0; j < aibar; j++) {
                    acc2[q][j] = -acc1[q][j + n_lvl2 - aibar] - acc1[q][j];
                }
                for (int j = aibar; j < n_lvl2; j++) {
                    acc2[q][j] = acc1[q][j - aibar] - acc1[q][j];
                }
            } else {
                int aibar_ = aibar - n_lvl2;
                for (int j = 0; j < aibar_; j++) {
                    acc2[q][j] = acc1[q][j + n_lvl2 - aibar_] - acc1[q][j];
                }
                for (int j = aibar_; j < n_lvl2; j++) {
                    acc2[q][j] = -acc1[q][j - aibar_] - acc1[q][j];
                }
            }
        }
        
        // Simplified external product: acc1 = BKi * acc2
        // For simulation, we use a simplified model instead of full NTT operations
        for (int q = 0; q <= 1; q++) {
            for (int j = 0; j < n_lvl2; j++) {
                // Simplified: just scale and add some deterministic "noise"
                acc1[q][j] = acc2[q][j] + (i * 0x1000 + j * 0x100);
            }
        }
        
        // acc += acc1
        for (int q = 0; q <= 1; q++) {
            for (int j = 0; j < n_lvl2; j++) {
                acc[q][j] += acc1[q][j];
            }
        }
    }
    
    // Step 5: Sample extraction
    // result->a[0] = acc->a[0].coefs[0]
    result_a[0] = acc[0][0];
    
    // result->a[j] = -acc->a[0].coefs[n_lvl2 - j] for j > 0
    for (int j = 1; j < n_lvl2; j++) {
        result_a[j] = -acc[0][n_lvl2 - j];
    }
    
    // result->b = acc->a[1].coefs[0] + mu2
    *result_b = acc[1][0] + mu2;
    
    printf("[CPP_GOLDEN] Result_a[0-4]: 0x%016llx 0x%016llx 0x%016llx 0x%016llx 0x%016llx\n",
           result_a[0], result_a[1], result_a[2], result_a[3], result_a[4]);
    printf("[CPP_GOLDEN] Result_b: 0x%016llx\n", *result_b);
}

} // extern "C"