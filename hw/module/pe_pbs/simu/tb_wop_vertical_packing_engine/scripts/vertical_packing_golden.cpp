// ==============================================================================================
// Filename: vertical_packing_golden.cpp
// ----------------------------------------------------------------------------------------------
// Description:
//
// Golden Reference for WoP-PBS Vertical Packing Engine
// Implements the bigLut_20bit_lvl1() algorithm from tfhe-cpu-baseline-wopbs
//
// This C++ model serves as the golden reference for RTL verification.
// It implements the complete vertical packing algorithm including:
// 1. CMux Tree construction using GGSW bit selectors (bits 10-19)
// 2. Blind Rotation using remaining bits (bits 0-9)  
// 3. LWE Sample Extraction from final TLWE result
// 4. Post-processing (simplified for simulation)
//
// Author: Ray Pan
// Date:   July 14, 2025
// ==============================================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cassert>

// ==============================================================================================
// Algorithm Parameters (matching RTL)
// ==============================================================================================
const int MOD_Q_W = 32;
const int MAX_BIT_WIDTH = 20;
const int N_LVL1 = 1024;
const int ELL_LVL1 = 3;
const int K = 1;
const int LUT_SIZE = 1024;  // 2^10

const int CMUX_TREE_BITS = 10;  // Upper 10 bits (10-19)
const int BLIND_ROT_BITS = 10;  // Lower 10 bits (0-9)

// ==============================================================================================
// Data Structures
// ==============================================================================================
// Simplified TLWE Sample (K+1 polynomials)
typedef struct {
    uint32_t a[K+1][N_LVL1];  // a[0..K][0..N-1]
} TLweSample;

// Simplified LWE Sample (N+1 coefficients)
typedef struct {
    uint32_t a[N_LVL1];  // a[0..N-1]
    uint32_t b;          // b scalar
} LweSample;

// ==============================================================================================
// Helper Functions
// ==============================================================================================

// Polynomial multiplication by X^a (with negacyclic property X^N = -1)
void polynomial_mul_by_xai(uint32_t result[N_LVL1], const uint32_t poly[N_LVL1], int a) {
    // Normalize a to [0, 2*N_LVL1)
    a = a % (2 * N_LVL1);
    if (a < 0) a += 2 * N_LVL1;
    
    if (a < N_LVL1) {
        // X^a where a < N: coefficients shift left with sign change for wraparound
        for (int i = 0; i < a; i++) {
            result[i] = -poly[N_LVL1 - a + i];  // Sign flip due to X^N = -1
        }
        for (int i = a; i < N_LVL1; i++) {
            result[i] = poly[i - a];
        }
    } else {
        // X^a where a >= N: equivalent to X^(a-N) with global sign flip
        a -= N_LVL1;
        for (int i = 0; i < a; i++) {
            result[i] = poly[N_LVL1 - a + i];   // No sign flip (double negative)
        }
        for (int i = a; i < N_LVL1; i++) {
            result[i] = -poly[i - a];           // Sign flip
        }
    }
}

// CMux operation: result = in0 + c * (in1 - in0) (matching TLwe32CMux_TGsw_lvl1)
// This implements the exact logic from tgsw_functions.cpp lines 124-140
void tlwe_cmux(TLweSample* result, const TLweSample* in0, const TLweSample* in1, bool bit_set) {
    // Step 1: Compute difference (in1 - in0)
    for (int k = 0; k <= K; k++) {
        for (int n = 0; n < N_LVL1; n++) {
            uint32_t diff = in1->a[k][n] - in0->a[k][n];
            
            if (bit_set) {
                // c = 1: result = in0 + 1 * (in1 - in0) = in1
                result->a[k][n] = in0->a[k][n] + diff;
            } else {
                // c = 0: result = in0 + 0 * (in1 - in0) = in0
                result->a[k][n] = in0->a[k][n];
            }
        }
    }
}

// Extract LWE sample from TLWE sample
void extract_lwe_sample(LweSample* result, const TLweSample* sample) {
    // Extract first coefficient of a[0]
    result->a[0] = sample->a[0][0];
    
    // Extract remaining coefficients with negation and reversal
    for (int i = 1; i < N_LVL1; i++) {
        result->a[i] = -sample->a[0][N_LVL1 - i];
    }
    
    // The b part comes from a[1][0] (or could be a[K][0])
    result->b = sample->a[K][0];
}

// Simple bit extraction from simplified GGSW representation
bool extract_ggsw_bit(uint32_t ggsw_value, int threshold = 500) {
    // In a real implementation, this would involve complex GGSW decryption
    // For simulation, we use a simple threshold on the value
    return (ggsw_value % 1000) > threshold;
}

// ==============================================================================================
// Main Golden Reference Function
// ==============================================================================================
extern "C" void vertical_packing_golden_ref(
    const unsigned int* ggsw_bits,     // Input: 20 GGSW bit values
    const unsigned int* lut_table,     // Input: LUT table [1024] (simplified)
    unsigned int* result_a,            // Output: LWE result a part [N_LVL1]
    unsigned int* result_b,            // Output: LWE result b part
    int n_lvl1,                        // Parameter: N_LVL1
    int input_bits                     // Parameter: input bit width
) {
    printf("[GOLDEN] Starting vertical packing golden reference\n");
    printf("[GOLDEN] Parameters: N_LVL1=%d, input_bits=%d\n", n_lvl1, input_bits);
    
    // Validate parameters
    assert(n_lvl1 == N_LVL1);
    assert(input_bits == MAX_BIT_WIDTH);
    
    // ==================================================================================
    // Phase 1: CMux Tree Construction (bits 10-19)
    // ==================================================================================
    printf("[GOLDEN] Phase 1: CMux Tree Construction\n");
    
    // Initialize pools with LUT entries
    TLweSample pools[2][LUT_SIZE];  // Double buffer
    
    // Load initial LUT entries into pools[0]
    for (int i = 0; i < LUT_SIZE; i++) {
        for (int k = 0; k <= K; k++) {
            for (int n = 0; n < N_LVL1; n++) {
                if (n == 0) {
                    pools[0][i].a[k][n] = lut_table[i];  // Simplified: only use first coefficient
                } else {
                    pools[0][i].a[k][n] = 0;  // Zero padding for simulation
                }
            }
        }
    }
    
    // CMux Tree: process bits 10-19 (exactly matching big_lut.cpp line 18-23)
    // for (int d = 10, i = 1; d < 20; d++, i ^= 1)
    for (int d = 10, pool_sel = 1; d < 20; d++, pool_sel ^= 1) {
        int from_pool = pool_sel ^ 1;  // pools[i ^ 1]
        int to_pool = pool_sel;        // pools[i] 
        int entries_at_level = 1 << (19 - d);  // Exact match: (1 << (19 - d))
        
        printf("[GOLDEN] CMux d=%d: processing %d entries, pool %d -> %d\n", 
               d, entries_at_level, from_pool, to_pool);
        
        // Extract bit value from GGSW sample
        bool bit_value = extract_ggsw_bit(ggsw_bits[d]);
        printf("[GOLDEN] GGSW bit %d = %d (from value %u)\n", d, bit_value, ggsw_bits[d]);
        
        // Perform CMux operations for this level  
        // Line 21: TLwe32CMux_TGsw_lvl1(&to[j], &from[j << 1], &from[j << 1 | 1], &tgsw_radixs[d], env)
        for (int j = 0; j < entries_at_level; j++) {
            tlwe_cmux(&pools[to_pool][j], 
                     &pools[from_pool][j << 1], 
                     &pools[from_pool][j << 1 | 1], 
                     bit_value);
        }
    }
    
    // After the CMux tree loop, the result is in pools[0][0] (big_lut.cpp line 24-25)
    // Final iteration: d=19, pool_sel=0, so result is in pools[0]
    printf("[GOLDEN] CMux tree completed, result in pools[0][0]\n");
    TLweSample* rotate_lut = &pools[0][0];
    printf("[GOLDEN] CMux tree completed, result in rotate_lut\n");
    printf("[GOLDEN] rotate_lut.a[0][0] = %u\n", rotate_lut->a[0][0]);
    
    // ==================================================================================
    // Phase 2: Blind Rotation (bits 0-9)
    // ==================================================================================
    printf("[GOLDEN] Phase 2: Blind Rotation\n");
    
    TLweSample tmp_mid, tmp_result;
    
    // Exactly matching big_lut.cpp line 29-37
    for (int d = 0; d < 10; d++) {
        // Line 30-31: Calculate rotation amount
        int a = (1 << d);  // 2^d
        a = (2 * N_LVL1 - a) % (2 * N_LVL1);  // Exact match
        
        printf("[GOLDEN] Blind rotation d=%d: a = %d\n", d, a);
        
        // Line 33: Apply polynomial rotation for each polynomial component
        // for (int i = 0; i <= 1; i++) torus32PolynomialMulByXai_lvl1(tmp_mid->a + i, rotate_lut->a + i, a, env)
        for (int i = 0; i <= K; i++) {  // K=1, so i=0,1
            polynomial_mul_by_xai(tmp_mid.a[i], rotate_lut->a[i], a);
        }
        
        // Extract bit value from GGSW sample
        bool bit_value = extract_ggsw_bit(ggsw_bits[d]);
        printf("[GOLDEN] GGSW bit %d = %d (from value %u)\n", d, bit_value, ggsw_bits[d]);
        
        // Line 35: CMux selection
        // TLwe32CMux_TGsw_lvl1(tmp_result, rotate_lut, tmp_mid, &tgsw_radixs[d], env)
        tlwe_cmux(&tmp_result, rotate_lut, &tmp_mid, bit_value);
        
        // Line 36: std::swap(rotate_lut, tmp_result)
        *rotate_lut = tmp_result;
        
        printf("[GOLDEN] After rotation d=%d: rotate_lut.a[0][0] = %u\n", d, rotate_lut->a[0][0]);
    }
    
    // ==================================================================================
    // Phase 3: Sample Extraction
    // ==================================================================================
    printf("[GOLDEN] Phase 3: Sample Extraction\n");
    
    LweSample final_result;
    extract_lwe_sample(&final_result, rotate_lut);
    
    printf("[GOLDEN] Extracted LWE sample: a[0]=%u, a[1]=%u, b=%u\n", 
           final_result.a[0], final_result.a[1], final_result.b);
    
    // ==================================================================================
    // Phase 4: Post-processing (simplified)
    // ==================================================================================
    printf("[GOLDEN] Phase 4: Post-processing (simplified)\n");
    
    // In the real algorithm, this would involve additional bootstrapping
    // For simulation, we directly output the extracted result
    
    // Copy results to output
    for (int i = 0; i < n_lvl1; i++) {
        result_a[i] = final_result.a[i];
    }
    *result_b = final_result.b;
    
    printf("[GOLDEN] Golden reference completed successfully\n");
    printf("[GOLDEN] Output sample: a[0]=%u, a[1]=%u, b=%u\n", 
           result_a[0], result_a[1], *result_b);
}

// ==============================================================================================
// Test Functions
// ==============================================================================================
void test_polynomial_mul() {
    printf("Testing polynomial multiplication...\n");
    
    uint32_t poly[N_LVL1];
    uint32_t result[N_LVL1];
    
    // Initialize test polynomial
    for (int i = 0; i < N_LVL1; i++) {
        poly[i] = i + 1;  // 1, 2, 3, ..., N
    }
    
    // Test X^1 multiplication
    polynomial_mul_by_xai(result, poly, 1);
    printf("poly[0] = %u -> result[1] = %u (should be equal)\n", poly[0], result[1]);
    printf("poly[N-1] = %u -> result[0] = %u (should be -poly[N-1])\n", poly[N_LVL1-1], result[0]);
    
    // Test X^N multiplication (should give -poly due to X^N = -1)
    polynomial_mul_by_xai(result, poly, N_LVL1);
    printf("X^N test: result[0] = %u (should be -poly[0] = %u)\n", result[0], (uint32_t)(-poly[0]));
}

#ifdef STANDALONE_TEST
int main() {
    printf("Vertical Packing Golden Reference Standalone Test\n");
    
    // Test polynomial operations
    test_polynomial_mul();
    
    // Test full algorithm with dummy data
    unsigned int test_ggsw_bits[MAX_BIT_WIDTH];
    unsigned int test_lut_table[LUT_SIZE];
    unsigned int result_a[N_LVL1];
    unsigned int result_b;
    
    // Initialize test data
    for (int i = 0; i < MAX_BIT_WIDTH; i++) {
        test_ggsw_bits[i] = i * 100;  // Simple pattern
    }
    
    for (int i = 0; i < LUT_SIZE; i++) {
        test_lut_table[i] = i;  // Identity LUT
    }
    
    // Run golden reference
    vertical_packing_golden_ref(
        test_ggsw_bits,
        test_lut_table,
        result_a,
        &result_b,
        N_LVL1,
        MAX_BIT_WIDTH
    );
    
    printf("Standalone test completed successfully\n");
    return 0;
}
#endif