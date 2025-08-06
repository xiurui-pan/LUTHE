#include <iostream>
#include <cstdint>

// Test our upgraded golden reference
extern "C" {
  void circuit_bootstrap_woks_golden_ref(
    const uint64_t mu,
    const int* abar,
    uint64_t* result_a,
    uint64_t* result_b,
    int n_lvl0,
    int n_lvl2
  );
}

int main() {
  // Simple test case
  uint64_t mu = 0x8000000000000000ULL;
  int abar[5] = {1, 2, 0, 1, 3};  // n_lvl0=4, so abar[5]
  uint64_t result_a[8];  // n_lvl2=8
  uint64_t result_b;
  
  std::cout << "=== Testing Upgraded Golden Reference ===" << std::endl;
  std::cout << "Input mu: 0x" << std::hex << mu << std::endl;
  std::cout << "Input abar: [";
  for(int i = 0; i < 5; i++) {
    std::cout << abar[i];
    if(i < 4) std::cout << ", ";
  }
  std::cout << "]" << std::endl;
  
  // Call our upgraded golden reference
  circuit_bootstrap_woks_golden_ref(mu, abar, result_a, &result_b, 4, 8);
  
  std::cout << "Output result_a[0-3]: [";
  for(int i = 0; i < 4; i++) {
    std::cout << "0x" << std::hex << result_a[i];
    if(i < 3) std::cout << ", ";
  }
  std::cout << "]" << std::endl;
  std::cout << "Output result_b: 0x" << std::hex << result_b << std::endl;
  
  std::cout << "✅ Golden reference test completed successfully!" << std::endl;
  return 0;
}
