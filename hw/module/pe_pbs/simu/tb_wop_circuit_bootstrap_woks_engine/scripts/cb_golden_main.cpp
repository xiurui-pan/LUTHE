#include <cstdint>
#include <cstdio>
#include <vector>
#include <cstdlib>

extern "C" void circuit_bootstrap_woks_golden_ref(
    const uint64_t mu,
    const int* abar,
    uint64_t* result_a,
    uint64_t* result_b,
    int n_lvl0,
    int n_lvl2);

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <N_LVL0> <N_LVL2>\n", argv[0]);
    return 2;
  }
  const int n_lvl0 = std::atoi(argv[1]);
  const int n_lvl2 = std::atoi(argv[2]);
  const uint64_t mu = 0x8000000000000000ULL; // match TB test_mu

  std::vector<int> abar(n_lvl0 + 1);
  for (int i = 0; i <= n_lvl0; i++) abar[i] = (i + 1) % 8; // match TB test_abar

  std::vector<uint64_t> out_a(n_lvl2);
  uint64_t out_b = 0;
  circuit_bootstrap_woks_golden_ref(mu, abar.data(), out_a.data(), &out_b, n_lvl0, n_lvl2);

  // Print compact line for parser (lower 32 bits to match TB prints)
  auto lo32 = [](uint64_t x) { return static_cast<uint32_t>(x & 0xffffffffu); };
  std::printf("[GOLDEN_CPP] a0-3=[0x%08x,0x%08x,0x%08x,0x%08x] b=0x%08x\n",
              lo32(out_a[0]), lo32(out_a[1]), lo32(out_a[2]), lo32(out_a[3]), lo32(out_b));
  return 0;
}

