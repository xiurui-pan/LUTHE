#include "tfhe_types.h"
#include "tfhe_functions.h"
#include "fixedpoint_number.h"
#include "global_random.h"
#include "gpu_runtime/keyset.hpp"
#include "gpu_runtime/keyset_reader.hpp"
#include "gpu_runtime/ipc.hpp"

extern void circuitBootstrapWoKS(LweSample64* result,
                                 Torus64 mu,
                                 const int* abar,
                                 const Context* env);
extern void circuitPrivKS(TLweSample32* result,
                          const int u,
                          const LweSample64* x,
                          const Context* env);

extern void bigLut_20bit_lvl1(LweSample32* result,
                              const TLweSample32* luts,
                              const LweSample32* in_s,
                              const Context* env);
extern void bigLut_20bit_lvl1_batch(LweSample32* results,
                                    const TLweSample32* luts,
                                    const LweSample32* in,
                                    int len,
                                    const Context* env);
extern void bigLut_20bit_lvl1_ip_batch(LweSample32* results,
                                       const TLweSample32* luts,
                                       const LweSample32* in,
                                       int len,
                                       const Context* env);
extern void preModSwitch(int* result, const LweSample32* x, const Context* env);

GlobalRandom* random_instances = new GlobalRandom[64];

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <span>
#include <string>
#include <string_view>
#include <vector>
#include <omp.h>
#include <unistd.h>
#include <sstream>

namespace {

struct Arguments {
  std::filesystem::path tlwe_path;
  std::filesystem::path glwe_path;
  std::filesystem::path keyset_path;
  std::filesystem::path ks_input_path;
  std::filesystem::path ks_dump_path;
  std::filesystem::path premod_path;
  std::filesystem::path decode_tlwe_path;
  std::filesystem::path decode_tlwe_out;
  std::filesystem::path bk_fft_prefix;
  std::filesystem::path dec_fft_path;
  std::filesystem::path acc_fft_path;
  std::filesystem::path poly_fft_path;
  std::filesystem::path extmul_path;
  std::filesystem::path acc_raw_path;
  std::filesystem::path dec_plain_path;
  std::size_t tlwe_words = 0;
  std::size_t glwe_words = 0;
  std::size_t word_bytes = sizeof(std::uint32_t);
  int mode = -1;
  std::string vp_lut = "test";  // {test, exp_minus}
  int vp_select = 0;            // select output digit; -1 => dump all
  int vp_input_select = -2;     // -2=disabled; -1=dump all inputs; >=0 select input sample
  int vp_ks_gpbs = 0;           // KeySwitch_lv10 is_gpbs for VP input bypass path
  bool vp_input_kspbs_get_hi = false;
  bool vp_input_kspbs_add_offset = true;
  int threads = 1;
  bool synth_vp = false;
  std::uint32_t synth_vp_index = 0;
  bool synth_lvl0 = false;
  int synth_lvl0_msg = 0;
  bool ks_only = false;
  bool privks_only = false;
  bool privks_step4 = false;
  bool mu_override_enabled = false;
  std::uint64_t mu_override = 0;
};

[[noreturn]] void usage(const char* prog) {
  std::cerr << "Usage: " << prog
            << " --tlwe <input.bin> --glwe <output.bin> "
               "[--tlwe-words <n>] [--glwe-words <m>] [--word-bytes <b>] "
               "[--mode <0..3>] "
               "[--vp-lut {test|exp_minus}] [--vp-select <idx|-1>] "
               "[--vp-input-select <idx|-1>] [--vp-ks-gpbs <0|1>] "
               "[--vp-input-kspbs-get-hi] [--vp-input-kspbs-no-offset] "
               "[--mu <hex>] "
               "[--threads <t>] [--synth-vp <index>] [--synth-lvl0 <msg>] "
               "[--keyset <keyset.bin>] [--premod <premod.bin>] "
               "[--decode-tlwe <tlwe_dump.bin>] [--decode-tlwe-out <path>] "
               "[--privks-step4] "
               "[--dump-bk-fft <prefix>] "
              "[--dump-dec-fft <path>] [--dump-acc-fft <path>] [--dump-poly-fft <prefix>] [--dump-extmul <path>] "
              "[--dump-acc-raw <path>] [--dump-dec-plain <path>]\n";
  std::exit(EXIT_FAILURE);
}

Arguments parse_arguments(int argc, char** argv) {
  Arguments args;
  for (int i = 1; i < argc; ++i) {
    std::string_view flag(argv[i]);
    auto require_value = [&](std::string_view name) -> std::string_view {
      if (i + 1 >= argc) {
        std::cerr << "Missing value after " << name << "\n";
        usage(argv[0]);
      }
      return std::string_view(argv[++i]);
    };
    if (flag == "--tlwe") {
      args.tlwe_path = require_value(flag);
    } else if (flag == "--glwe") {
      args.glwe_path = require_value(flag);
    } else if (flag == "--tlwe-words") {
      args.tlwe_words = std::stoul(std::string(require_value(flag)));
    } else if (flag == "--glwe-words") {
      args.glwe_words = std::stoul(std::string(require_value(flag)));
    } else if (flag == "--word-bytes") {
      args.word_bytes = std::stoul(std::string(require_value(flag)));
    } else if (flag == "--mode") {
      args.mode = std::stoi(std::string(require_value(flag)));
    } else if (flag == "--vp-lut") {
      args.vp_lut = std::string(require_value(flag));
    } else if (flag == "--vp-select") {
      args.vp_select = std::stoi(std::string(require_value(flag)));
    } else if (flag == "--vp-input-select") {
      args.vp_input_select = std::stoi(std::string(require_value(flag)));
    } else if (flag == "--vp-ks-gpbs") {
      args.vp_ks_gpbs = std::stoi(std::string(require_value(flag)));
    } else if (flag == "--vp-input-kspbs-get-hi") {
      args.vp_input_kspbs_get_hi = true;
    } else if (flag == "--vp-input-kspbs-no-offset") {
      args.vp_input_kspbs_add_offset = false;
    } else if (flag == "--threads") {
      args.threads = std::stoi(std::string(require_value(flag)));
    } else if (flag == "--mu") {
      const std::string_view raw = require_value(flag);
      std::string tmp(raw);
      std::size_t idx = 0;
      args.mu_override = std::stoull(tmp, &idx, 0);
      if (idx != tmp.size()) {
        std::cerr << "Invalid --mu value: " << tmp << "\n";
        usage(argv[0]);
      }
      args.mu_override_enabled = true;
    } else if (flag == "--synth-vp") {
      args.synth_vp = true;
      args.synth_vp_index = static_cast<std::uint32_t>(std::stoul(std::string(require_value(flag))));
    } else if (flag == "--synth-lvl0") {
      args.synth_lvl0 = true;
      args.synth_lvl0_msg = std::stoi(std::string(require_value(flag)));
    } else if (flag == "--ks-input") {
      args.ks_input_path = require_value(flag);
    } else if (flag == "--dump-ks") {
      args.ks_dump_path = require_value(flag);
    } else if (flag == "--ks-only") {
      args.ks_only = true;
    } else if (flag == "--privks-only") {
      args.privks_only = true;
    } else if (flag == "--privks-step4") {
      args.privks_step4 = true;
    } else if (flag == "--dump-dec-fft") {
      args.dec_fft_path = require_value(flag);
    } else if (flag == "--dump-acc-fft") {
      args.acc_fft_path = require_value(flag);
    } else if (flag == "--dump-poly-fft") {
      args.poly_fft_path = require_value(flag);
    } else if (flag == "--dump-extmul") {
      args.extmul_path = require_value(flag);
    } else if (flag == "--dump-acc-raw") {
      args.acc_raw_path = require_value(flag);
    } else if (flag == "--dump-dec-plain") {
      args.dec_plain_path = require_value(flag);
    } else if (flag == "--dump-bk-fft") {
      args.bk_fft_prefix = require_value(flag);
    } else if (flag == "--keyset") {
      args.keyset_path = require_value(flag);
    } else if (flag == "--premod") {
      args.premod_path = require_value(flag);
    } else if (flag == "--decode-tlwe") {
      args.decode_tlwe_path = require_value(flag);
    } else if (flag == "--decode-tlwe-out") {
      args.decode_tlwe_out = require_value(flag);
    } else if (flag == "--help" || flag == "-h") {
      usage(argv[0]);
    } else {
      std::cerr << "Unknown argument: " << flag << "\n";
      usage(argv[0]);
    }
  }
  if (args.tlwe_path.empty() || args.glwe_path.empty()) {
    std::cerr << "Missing --tlwe / --glwe arguments\n";
    usage(argv[0]);
  }
  if (args.word_bytes == 0 || (args.word_bytes != 4 && args.word_bytes != 8)) {
    std::cerr << "Only 4-byte or 8-byte words are supported\n";
    usage(argv[0]);
  }
  if (args.vp_ks_gpbs != 0 && args.vp_ks_gpbs != 1) {
    std::cerr << "Unsupported --vp-ks-gpbs: " << args.vp_ks_gpbs << " (expected 0 or 1)\n";
    usage(argv[0]);
  }
  if (args.vp_lut != "test" && args.vp_lut != "exp_minus") {
    std::cerr << "Unsupported --vp-lut: " << args.vp_lut
              << " (supported: test, exp_minus)\n";
    usage(argv[0]);
  }
  if (args.threads <= 0) {
    std::cerr << "Unsupported --threads: " << args.threads << " (expected > 0)\n";
    usage(argv[0]);
  }
  if (args.synth_vp && args.synth_lvl0) {
    std::cerr << "Cannot combine --synth-vp and --synth-lvl0\n";
    usage(argv[0]);
  }
  if (args.synth_vp && args.keyset_path.empty()) {
    std::cerr << "--synth-vp requires --keyset\n";
    usage(argv[0]);
  }
  if (args.synth_lvl0 && args.keyset_path.empty()) {
    std::cerr << "--synth-lvl0 requires --keyset\n";
    usage(argv[0]);
  }
  if (args.privks_step4 && args.keyset_path.empty()) {
    std::cerr << "--privks-step4 requires --keyset\n";
    usage(argv[0]);
  }
  return args;
}

template <typename T>
T read_little_endian(const std::uint8_t* ptr) {
  T value = 0;
  for (std::size_t i = 0; i < sizeof(T); ++i) {
    value |= static_cast<T>(ptr[i]) << (8 * i);
  }
  return value;
}

template <typename T>
void write_little_endian(std::uint8_t* dst, T value) {
  for (std::size_t i = 0; i < sizeof(T); ++i) {
    dst[i] = static_cast<std::uint8_t>((value >> (8 * i)) & 0xFF);
  }
}

std::vector<std::uint8_t> read_file(const std::filesystem::path& path) {
  std::ifstream ifs(path, std::ios::binary);
  if (!ifs) {
    std::cerr << "Failed to open TLWE file: " << path << "\n";
    std::exit(EXIT_FAILURE);
  }
  std::vector<std::uint8_t> data((std::istreambuf_iterator<char>(ifs)),
                                 std::istreambuf_iterator<char>());
  return data;
}

void write_file(const std::filesystem::path& path, std::span<const std::uint8_t> data) {
  std::ofstream ofs(path, std::ios::binary | std::ios::trunc);
  if (!ofs) {
    std::cerr << "Failed to open GLWE file for writing: " << path << "\n";
    std::exit(EXIT_FAILURE);
  }
  ofs.write(reinterpret_cast<const char*>(data.data()),
            static_cast<std::streamsize>(data.size()));
  if (!ofs) {
    std::cerr << "Failed to write GLWE file: " << path << "\n";
    std::exit(EXIT_FAILURE);
  }
}

void apply_keyset(Context& ctx, const std::filesystem::path& path) {
  if (path.empty()) {
    return;
  }
  std::ifstream ifs(path, std::ios::binary);
  if (!ifs) {
    std::cerr << "Failed to open keyset file: " << path << "\n";
    std::exit(EXIT_FAILURE);
  }

  auto parsed = gpu_runtime::keyset_tools::read_keyset_header(ifs);
  const gpu_runtime::keyset::Header& header = parsed.header;
  if (header.glwe_dimension == 0) {
    std::cerr << "Keyset glwe_dimension missing/zero\n";
    std::exit(EXIT_FAILURE);
  }
  if (header.kslength_lvl10 != static_cast<std::uint32_t>(Context::kslength_lvl10) ||
      header.ksbasebit_lvl10 != static_cast<std::uint32_t>(Context::ksbasebit_lvl10) ||
      header.kslength_lvl10_gpbs != static_cast<std::uint32_t>(Context::kslength_lvl10_gpbs) ||
      header.ksbasebit_lvl10_gpbs != static_cast<std::uint32_t>(Context::ksbasebit_lvl10_gpbs)) {
    std::cerr << "Keyset ks parameters mismatch\n";
    std::exit(EXIT_FAILURE);
  }
  if (header.n_lvl0 != static_cast<std::uint32_t>(Context::n_lvl0) ||
      header.n_lvl1 != static_cast<std::uint32_t>(Context::n_lvl1) ||
      header.n_lvl2 != static_cast<std::uint32_t>(Context::n_lvl2)) {
    std::cerr << "Keyset parameter mismatch\n";
    std::exit(EXIT_FAILURE);
  }
  if ((header.flags & gpu_runtime::keyset::kSectionSecretKeys) == 0) {
    std::cerr << "Keyset missing secret key section\n";
    std::exit(EXIT_FAILURE);
  }

  auto read_secret_section = [&](std::uint64_t offset,
                                 std::uint32_t words,
                                 int* dst,
                                 std::size_t expected) {
    if (words != expected) {
      std::cerr << "Keyset secret key size mismatch (expected "
                << expected << ", got " << words << ")\n";
      std::exit(EXIT_FAILURE);
    }
    std::vector<std::int32_t> buf(words);
    ifs.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!ifs) {
      std::cerr << "Failed to seek keyset secret section\n";
      std::exit(EXIT_FAILURE);
    }
    ifs.read(reinterpret_cast<char*>(buf.data()),
             static_cast<std::streamsize>(buf.size() * sizeof(std::int32_t)));
    if (!ifs) {
      std::cerr << "Failed to read keyset secret section\n";
      std::exit(EXIT_FAILURE);
    }
    std::memcpy(dst, buf.data(), buf.size() * sizeof(std::int32_t));
  };

  read_secret_section(header.offset_key_lvl0,
                      header.key_lvl0_words,
                      ctx.key_lvl0,
                      Context::n_lvl0);
  read_secret_section(header.offset_key_lvl1,
                      header.key_lvl1_words,
                      ctx.key_lvl1,
                      Context::n_lvl1);
  read_secret_section(header.offset_key_lvl2,
                      header.key_lvl2_words,
                      ctx.key_lvl2,
                      Context::n_lvl2 + 1);
  std::memcpy(ctx.Key_lvl1->coefs,
              ctx.key_lvl1,
              static_cast<std::size_t>(Context::n_lvl1) * sizeof(int));
  std::memcpy(ctx.Key_lvl2->coefs,
              ctx.key_lvl2,
              static_cast<std::size_t>(Context::n_lvl2) * sizeof(int));

  auto restore_preks = [&](std::uint64_t offset,
                           std::uint32_t samples,
                           std::uint32_t words,
                           LweSample32*** target,
                           int kslength,
                           int ksbasebit,
                           const char* label) {
    if (samples == 0 || words == 0) {
      return;
    }
    if (offset == 0) {
      std::cerr << "Keyset " << label << " offset missing\n";
      std::exit(EXIT_FAILURE);
    }
    const std::size_t expected_words = static_cast<std::size_t>(Context::n_lvl0) + 1;
    if (words != expected_words) {
      std::cerr << "Keyset " << label << " word count mismatch (expected "
                << expected_words << ", got " << words << ")\n";
      std::exit(EXIT_FAILURE);
    }
    const int base = 1 << ksbasebit;
    const std::size_t base_count = static_cast<std::size_t>(base);
    const std::size_t expected_samples =
        static_cast<std::size_t>(Context::n_lvl1) *
        static_cast<std::size_t>(kslength) *
        base_count;
    if (samples != expected_samples) {
      std::cerr << "Keyset " << label << " sample count mismatch (expected "
                << expected_samples << ", got " << samples << ")\n";
      std::exit(EXIT_FAILURE);
    }
    std::vector<std::int32_t> buf(expected_words);
    ifs.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!ifs) {
      std::cerr << "Failed to seek " << label << " section\n";
      std::exit(EXIT_FAILURE);
    }
    for (int i = 0; i < Context::n_lvl1; ++i) {
      for (int j = 0; j < kslength; ++j) {
        for (int u = 0; u < base; ++u) {
          ifs.read(reinterpret_cast<char*>(buf.data()),
                   static_cast<std::streamsize>(buf.size() * sizeof(std::int32_t)));
          if (!ifs) {
            std::cerr << "Failed to read " << label << " payload\n";
            std::exit(EXIT_FAILURE);
          }
          std::memcpy(target[i][j][u].a,
                      buf.data(),
                      buf.size() * sizeof(std::int32_t));
        }
      }
    }
  };

  if ((header.flags & gpu_runtime::keyset::kSectionPreKS) != 0) {
    restore_preks(header.offset_preks_lvl10,
                  header.preks_lvl10_samples,
                  header.preks_lvl10_words,
                  ctx.preKS,
                  Context::kslength_lvl10,
                  Context::ksbasebit_lvl10,
                  "preKS lvl10");
    restore_preks(header.offset_preks_lvl10_gpbs,
                  header.preks_lvl10_gpbs_samples,
                  header.preks_lvl10_gpbs_words,
                  ctx.preKS_gpbs,
                  Context::kslength_lvl10_gpbs,
                  Context::ksbasebit_lvl10_gpbs,
                  "preKS lvl10 gpbs");
  } else {
    std::cerr << "[CPU_REF] Warning: keyset missing preKS section; results may diverge\n";
  }

  const int k_plus_1 = k + 1;
  const int sample_per_tgsw = Context::ell_lvl2 * k_plus_1;
  const int sample_per_tgsw_32 = Context::ell_lvl1_gpbs * k_plus_1;
  const int N_lvl2 = Context::n_lvl2;
  const int N_lvl1 = Context::n_lvl1;
  const std::uint64_t expected_bk_values_lvl2 =
      static_cast<std::uint64_t>(Context::n_lvl0) * sample_per_tgsw * k_plus_1 * N_lvl2;
  const std::uint64_t expected_bk_values_lvl1 =
      static_cast<std::uint64_t>(Context::n_lvl0) * sample_per_tgsw_32 * k_plus_1 * N_lvl1;
  const std::uint64_t expected_bk_values_total =
      expected_bk_values_lvl2 + expected_bk_values_lvl1;
  bool has_bk32 = false;

  if ((header.flags & gpu_runtime::keyset::kSectionBootstrappingKeys) != 0) {
    const std::uint64_t bk_values = static_cast<std::uint64_t>(header.bk_fft_values);
    if (bk_values == expected_bk_values_lvl2) {
      has_bk32 = false;
    } else if (bk_values == expected_bk_values_total) {
      has_bk32 = true;
    } else {
      std::cerr << "Keyset bk_fft size mismatch (expected "
                << expected_bk_values_lvl2 << " or " << expected_bk_values_total
                << ", got " << header.bk_fft_values << ")\n";
      std::exit(EXIT_FAILURE);
    }
    std::vector<double> fft_real(static_cast<std::size_t>(N_lvl2));
    ifs.seekg(static_cast<std::streamoff>(header.offset_bk_fft), std::ios::beg);
    if (!ifs) {
      std::cerr << "Failed to seek bk_fft section\n";
      std::exit(EXIT_FAILURE);
    }
    for (int i = 0; i < Context::n_lvl0; ++i) {
      TLweSampleFFT* allsamples = ctx.bkFFT[i].allsamples;
      for (int p = 0; p < sample_per_tgsw; ++p) {
        TLweSampleFFT& sample = allsamples[p];
        for (int q = 0; q < k_plus_1; ++q) {
          ifs.read(reinterpret_cast<char*>(fft_real.data()),
                   static_cast<std::streamsize>(fft_real.size() * sizeof(double)));
          if (!ifs) {
            std::cerr << "Failed to read bk_fft payload\n";
            std::exit(EXIT_FAILURE);
          }
          std::memcpy(sample.a[q].values,
                      fft_real.data(),
                      fft_real.size() * sizeof(double));
          if (std::getenv("CPU_CBS_DEBUG") != nullptr && i == 0 && p == 0 && q == 0) {
            const int Ns2 = static_cast<int>(fft_real.size() / 2);
            std::cout << "[CPU_CBS_DEBUG] bkFFT64[0][0][0]real[0..3]={";
            for (int idx = 0; idx < 4; ++idx) {
              std::cout << fft_real[idx];
              if (idx != 3) std::cout << ",";
            }
            std::cout << "} imag[0..3]={";
            for (int idx = 0; idx < 4; ++idx) {
              std::cout << fft_real[idx + Ns2];
              if (idx != 3) std::cout << ",";
            }
            std::cout << "}" << std::endl;
          }
        }
      }
    }
    if (has_bk32) {
      std::vector<double> fft_real32(static_cast<std::size_t>(N_lvl1));
      for (int i = 0; i < Context::n_lvl0; ++i) {
        TLweSampleFFT* allsamples = ctx.bkFFT_32[i].allsamples;
        for (int p = 0; p < sample_per_tgsw_32; ++p) {
          TLweSampleFFT& sample = allsamples[p];
          for (int q = 0; q < k_plus_1; ++q) {
            ifs.read(reinterpret_cast<char*>(fft_real32.data()),
                     static_cast<std::streamsize>(fft_real32.size() * sizeof(double)));
            if (!ifs) {
              std::cerr << "Failed to read bk_fft32 payload\n";
              std::exit(EXIT_FAILURE);
            }
            std::memcpy(sample.a[q].values,
                        fft_real32.data(),
                        fft_real32.size() * sizeof(double));
          }
        }
      }
    } else {
      std::cerr << "[CPU_REF] Warning: keyset missing bk_fft32 section; lvl1 ops may diverge\n";
    }
  } else {
    std::cerr << "[CPU_REF] Warning: keyset missing bk_fft section; results may diverge\n";
  }

  const int priv_dim_z = k_plus_1;
  const int priv_dim_i = Context::n_lvl2 + 1;
  const int priv_dim_j = Context::kslength_lvl21;
  const int priv_dim_u = 1 << Context::ksbasebit_lvl21;
  const std::uint64_t expected_priv_values =
      static_cast<std::uint64_t>(priv_dim_z) *
      priv_dim_i *
      priv_dim_j *
      priv_dim_u *
      k_plus_1 *
      N_lvl1;

  if ((header.flags & gpu_runtime::keyset::kSectionPrivKS) != 0) {
    if (static_cast<std::uint64_t>(header.privks_values) != expected_priv_values) {
      std::cerr << "Keyset privKS size mismatch (expected "
                << expected_priv_values << ", got " << header.privks_values << ")\n";
      std::exit(EXIT_FAILURE);
    }
    std::vector<std::int32_t> priv_chunk(static_cast<std::size_t>(N_lvl1));
    ifs.seekg(static_cast<std::streamoff>(header.offset_privks), std::ios::beg);
    if (!ifs) {
      std::cerr << "Failed to seek privKS section\n";
      std::exit(EXIT_FAILURE);
    }
    for (int z = 0; z < priv_dim_z; ++z) {
      for (int i = 0; i < priv_dim_i; ++i) {
        for (int j = 0; j < priv_dim_j; ++j) {
          for (int u = 0; u < priv_dim_u; ++u) {
            TLweSample32& sample = ctx.privKS[z][i][j][u];
            for (int q = 0; q < k_plus_1; ++q) {
              ifs.read(reinterpret_cast<char*>(priv_chunk.data()),
                       static_cast<std::streamsize>(priv_chunk.size() * sizeof(std::int32_t)));
              if (!ifs) {
                std::cerr << "Failed to read privKS payload\n";
                std::exit(EXIT_FAILURE);
              }
              std::memcpy(sample.a[q].coefs,
                          priv_chunk.data(),
                          priv_chunk.size() * sizeof(std::int32_t));
            }
          }
        }
      }
    }
  } else {
    std::cerr << "[CPU_REF] Warning: keyset missing privKS section; results may diverge\n";
  }

  std::cout << "[CPU_REF] Applied keyset from " << path << std::endl;
}

void dump_bk_fft(const Context& ctx, const std::filesystem::path& prefix) {
  if (prefix.empty()) {
    return;
  }
  const int k_plus_1 = k + 1;
  const int sample_per_tgsw = ctx.ell_lvl2 * k_plus_1;
  const int N = ctx.n_lvl2;
  std::vector<double> buffer(static_cast<std::size_t>(N));

  auto make_path = [&](int i, int p, int q) {
    std::stringstream ss;
    ss << prefix.string() << "_i" << i << "_p" << p << "_q" << q << ".bin";
    return std::filesystem::path(ss.str());
  };

  for (int i = 0; i < ctx.n_lvl0; ++i) {
    TLweSampleFFT* allsamples = ctx.bkFFT[i].allsamples;
    for (int p = 0; p < sample_per_tgsw; ++p) {
      TLweSampleFFT& sample = allsamples[p];
      for (int q = 0; q < k_plus_1; ++q) {
        std::memcpy(buffer.data(),
                    sample.a[q].values,
                    static_cast<std::size_t>(N) * sizeof(double));
        const auto out_path = make_path(i, p, q);
        std::ofstream ofs(out_path, std::ios::binary | std::ios::trunc);
        if (!ofs) {
          std::cerr << "[CPU_REF][DUMP_BK] failed to open " << out_path << "\n";
          std::exit(EXIT_FAILURE);
        }
        ofs.write(reinterpret_cast<const char*>(buffer.data()),
                  static_cast<std::streamsize>(buffer.size() * sizeof(double)));
        if (!ofs) {
          std::cerr << "[CPU_REF][DUMP_BK] failed to write " << out_path << "\n";
          std::exit(EXIT_FAILURE);
        }
      }
    }
  }
  std::cout << "[CPU_REF][DUMP_BK] dumped bk_fft to prefix " << prefix << std::endl;
}

void dump_block_complex(const std::filesystem::path& path,
                        const LagrangeHalfCPolynomial* polys,
                        int rows,
                        int N) {
  if (path.empty()) {
    return;
  }
  std::ofstream ofs(path, std::ios::binary | std::ios::trunc);
  if (!ofs) {
    std::cerr << "[CPU_REF][DUMP] failed to open " << path << "\n";
    std::exit(EXIT_FAILURE);
  }
  const std::size_t row_bytes = static_cast<std::size_t>(N) * sizeof(double);
  for (int r = 0; r < rows; ++r) {
    ofs.write(reinterpret_cast<const char*>(polys[r].values),
              static_cast<std::streamsize>(row_bytes));
    if (!ofs) {
      std::cerr << "[CPU_REF][DUMP] failed to write " << path << "\n";
      std::exit(EXIT_FAILURE);
    }
  }
  std::cout << "[CPU_REF][DUMP] wrote " << rows << "x" << N
            << " doubles to " << path << std::endl;
}

void dump_int64_matrix(const std::filesystem::path& path,
                       const Torus64Polynomial* polys,
                       int rows,
                       int N) {
  if (path.empty()) {
    return;
  }
  std::ofstream ofs(path, std::ios::binary | std::ios::trunc);
  if (!ofs) {
    std::cerr << "[CPU_REF][DUMP] failed to open " << path << "\n";
    std::exit(EXIT_FAILURE);
  }
  const std::size_t row_bytes = static_cast<std::size_t>(N) * sizeof(Torus64);
  for (int r = 0; r < rows; ++r) {
    ofs.write(reinterpret_cast<const char*>(polys[r].coefs),
              static_cast<std::streamsize>(row_bytes));
    if (!ofs) {
      std::cerr << "[CPU_REF][DUMP] failed to write " << path << "\n";
      std::exit(EXIT_FAILURE);
    }
  }
  std::cout << "[CPU_REF][DUMP] wrote " << rows << "x" << N
            << " int64 to " << path << std::endl;
}

void dump_int32_matrix(const std::filesystem::path& path,
                       const IntPolynomial* polys,
                       int rows,
                       int N) {
  if (path.empty()) {
    return;
  }
  std::ofstream ofs(path, std::ios::binary | std::ios::trunc);
  if (!ofs) {
    std::cerr << "[CPU_REF][DUMP] failed to open " << path << "\n";
    std::exit(EXIT_FAILURE);
  }
  const std::size_t row_bytes = static_cast<std::size_t>(N) * sizeof(std::int32_t);
  for (int r = 0; r < rows; ++r) {
    ofs.write(reinterpret_cast<const char*>(polys[r].coefs),
              static_cast<std::streamsize>(row_bytes));
    if (!ofs) {
      std::cerr << "[CPU_REF][DUMP] failed to write " << path << "\n";
      std::exit(EXIT_FAILURE);
    }
  }
  std::cout << "[CPU_REF][DUMP] wrote " << rows << "x" << N
            << " int32 to " << path << std::endl;
}

void circuitBootstrapWoKS_debug(LweSample64* result,
                                const Torus64 mu,
                                const int* abar,
                                const Context* env,
                                const std::filesystem::path& dec_fft_path,
                                const std::filesystem::path& acc_fft_path,
                                const std::filesystem::path& poly_fft_path,
                                const std::filesystem::path& extmul_path,
                                const std::filesystem::path& acc_raw_path,
                                const std::filesystem::path& dec_plain_path) {
  const int N_lvl2 = env->N_lvl2;
  const int n_lvl0 = env->n_lvl0;
  const int l = env->ell_lvl2;
  const int N2 = N_lvl2 / 2;
  const int _2l = 2 * l;
  const Torus64 mu2 = mu / 2;
  const bool debug_dump = std::getenv("CPU_CBS_DEBUG") != nullptr;
  auto dump_poly = [&](const char* tag, const Torus64* data, int len) {
    if (!debug_dump) return;
    std::cout << "[CPU_CBS_DEBUG] " << tag << "[0..7]={";
    for (int i = 0; i < std::min(len, 8); ++i) {
      std::cout << "0x" << std::hex << static_cast<unsigned long long>(data[i]);
      if (i != std::min(len, 8) - 1) std::cout << ",";
    }
    std::cout << "}" << std::dec << std::endl;
  };
  Torus64Polynomial* testvecttemp = new Torus64Polynomial(N_lvl2);
  Torus64Polynomial* testvect = new Torus64Polynomial(N_lvl2);
  const int bbar = abar[n_lvl0];
  TLweSample64* acc1 = new TLweSample64(N_lvl2);
  TLweSample64* acc2 = new TLweSample64(N_lvl2);
  TLweSample64* acc = new TLweSample64(N_lvl2);
  TLweSampleFFT* accFFT = new TLweSampleFFT(N_lvl2);
  TGswSampleFFT* bkFFT = env->bkFFT;
  bool dumped = false;

  for (int j = 0; j < N2; ++j) testvecttemp->coefs[j] = -mu2;
  for (int j = N2; j < N_lvl2; ++j) testvecttemp->coefs[j] = mu2;
  if (bbar < N_lvl2) {
    for (int j = 0; j < N_lvl2 - bbar; j++) {
      testvect->coefs[j] = testvecttemp->coefs[j + bbar];
    }
    for (int j = N_lvl2 - bbar; j < N_lvl2; j++) {
      testvect->coefs[j] = -testvecttemp->coefs[j - (N_lvl2 - bbar)];
    }
  } else {
    int bbar_ = bbar - N_lvl2;
    for (int j = 0; j < N_lvl2 - bbar_; j++) {
      testvect->coefs[j] = -testvecttemp->coefs[j + bbar_];
    }
    for (int j = N_lvl2 - bbar_; j < N_lvl2; j++) {
      testvect->coefs[j] = testvecttemp->coefs[j - (N_lvl2 - bbar_)];
    }
  }
  dump_poly("testvec", testvect->coefs, N_lvl2);

  for (int j = 0; j < N_lvl2; ++j) {
    acc->a[0].coefs[j] = 0;
    acc->a[1].coefs[j] = testvect->coefs[j];
  }
  dump_poly("acc_b_initial", acc->a[1].coefs, N_lvl2);
  const bool dump_acc_raw = !acc_raw_path.empty();
  std::vector<Torus64> host_acc_raw;
  if (dump_acc_raw) {
    host_acc_raw.resize(static_cast<std::size_t>(k + 1) * N_lvl2);
  }

  IntPolynomial* decomp = new_array1<IntPolynomial>(_2l, N_lvl2);
  LagrangeHalfCPolynomial* decompFFT = new_array1<LagrangeHalfCPolynomial>(_2l, N_lvl2);
  for (int i = 0; i < n_lvl0; ++i) {
    int aibar = abar[i];
    if (aibar == 0) continue;

    for (int q = 0; q <= k; ++q)
      for (int j = 0; j < N_lvl2; ++j) acc1->a[q].coefs[j] = acc->a[q].coefs[j];

    for (int q = 0; q <= k; ++q) {
      if (aibar < N_lvl2) {
        for (int j = 0; j < aibar; j++) {
          acc2->a[q].coefs[j] = -acc1->a[q].coefs[j + N_lvl2 - aibar] - acc1->a[q].coefs[j];
        }
        for (int j = aibar; j < N_lvl2; j++) {
          acc2->a[q].coefs[j] = acc1->a[q].coefs[j - aibar] - acc1->a[q].coefs[j];
        }
      } else {
        int aibar_ = aibar - N_lvl2;
        for (int j = 0; j < aibar_; j++) {
          acc2->a[q].coefs[j] = acc1->a[q].coefs[j + N_lvl2 - aibar_] - acc1->a[q].coefs[j];
        }
        for (int j = aibar_; j < N_lvl2; j++) {
          acc2->a[q].coefs[j] = -acc1->a[q].coefs[j - aibar_] - acc1->a[q].coefs[j];
        }
      }
    }
    if (debug_dump && i == 0) {
      dump_poly("after_mul", acc2->a[1].coefs, N_lvl2);
    }

    tGsw64DecompH(decomp, acc2, env);
    if (!dumped && !dec_plain_path.empty()) {
      dump_int32_matrix(dec_plain_path, decomp, _2l, N_lvl2);
    }
    for (int p = 0; p < _2l; ++p) IntPolynomial_ifft_lvl2(decompFFT + p, decomp + p, env);
    if (!dumped && !dec_fft_path.empty()) {
      dump_block_complex(dec_fft_path, decompFFT, _2l, N_lvl2);
    }
    for (int q = 0; q <= k; ++q) LagrangeHalfCPolynomialClear_lvl2(accFFT->a + q, env);
    for (int p = 0; p < _2l; ++p)
      for (int q = 0; q <= k; ++q)
        LagrangeHalfCPolynomialAddMul_lvl2(accFFT->a + q, decompFFT + p, &bkFFT[i].allsamples[p].a[q], env);
    if (!dumped && !acc_fft_path.empty()) {
      dump_block_complex(acc_fft_path, accFFT->a, k + 1, N_lvl2);
    }
    for (int q = 0; q <= k; ++q) {
      std::string poly_dump;
      if (!dumped && !poly_fft_path.empty()) {
        poly_dump = poly_fft_path.string() + "_q" + std::to_string(q) + ".bin";
        setenv("SPQLIOS_DUMP_DIRECT_TORUS64", poly_dump.c_str(), 1);
      }
      TorusPolynomial64_fft_lvl2(acc1->a + q, accFFT->a + q, env);
      if (!poly_dump.empty()) {
        unsetenv("SPQLIOS_DUMP_DIRECT_TORUS64");
      }
    }
    if (!dumped && !extmul_path.empty()) {
      dump_int64_matrix(extmul_path, acc1->a, k + 1, N_lvl2);
    }
    if (dump_acc_raw && !dumped) {
      for (int q = 0; q <= k; ++q) {
        std::memcpy(host_acc_raw.data() + static_cast<std::size_t>(q) * N_lvl2,
                    acc2->a[q].coefs,
                    static_cast<std::size_t>(N_lvl2) * sizeof(Torus64));
      }
      std::ofstream ofs(acc_raw_path, std::ios::binary | std::ios::trunc);
      if (!ofs) {
        std::cerr << "[CPU_REF][DUMP] failed to open " << acc_raw_path << "\n";
        std::exit(EXIT_FAILURE);
      }
      ofs.write(reinterpret_cast<const char*>(host_acc_raw.data()),
                static_cast<std::streamsize>(host_acc_raw.size() * sizeof(Torus64)));
      if (!ofs) {
        std::cerr << "[CPU_REF][DUMP] failed to write " << acc_raw_path << "\n";
        std::exit(EXIT_FAILURE);
      }
      std::cout << "[CPU_REF][DUMP] wrote acc_raw to " << acc_raw_path << std::endl;
    }
    dumped = dumped || !dec_fft_path.empty() || !acc_fft_path.empty() || !poly_fft_path.empty() ||
             !extmul_path.empty() || !acc_raw_path.empty() || !dec_plain_path.empty();

    for (int q = 0; q <= k; ++q)
      for (int j = 0; j < N_lvl2; ++j) acc->a[q].coefs[j] += acc1->a[q].coefs[j];
    if (debug_dump && i < 4) {
      dump_poly("acc_b_iter", acc->a[1].coefs, N_lvl2);
    }
  }

  dump_poly("acc_b_final", acc->a[1].coefs, N_lvl2);
  if (const char* dump_env = std::getenv("CPU_REF_DUMP_ACC_B");
      dump_env != nullptr && *dump_env != '\0') {
    std::ofstream ofs(dump_env, std::ios::binary | std::ios::trunc);
    if (!ofs) {
      std::cerr << "Failed to open CPU acc_b dump file: " << dump_env << "\n";
      std::exit(EXIT_FAILURE);
    }
    ofs.write(reinterpret_cast<const char*>(acc->a[1].coefs),
              static_cast<std::streamsize>(N_lvl2 * sizeof(Torus64)));
    if (!ofs) {
      std::cerr << "Failed to write CPU acc_b dump file: " << dump_env << "\n";
      std::exit(EXIT_FAILURE);
    }
  }

  result->a[0] = acc->a[0].coefs[0];
  for (int j = 1; j < N_lvl2; j++) result->a[j] = -acc->a[0].coefs[N_lvl2 - j];
  *result->b = acc->a[1].coefs[0] + mu2;
  dump_poly("extract_a0", result->a, N_lvl2);

  delete accFFT;
  delete_array1<LagrangeHalfCPolynomial>(decompFFT);
  delete_array1<IntPolynomial>(decomp);
  delete acc;
  delete acc2;
  delete acc1;
  delete testvect;
  delete testvecttemp;
}

std::vector<std::uint8_t> synthesize_vp_payload(const Context& ctx,
                                                std::uint32_t index,
                                                std::size_t word_bytes) {
  const int samples = 20;  // 20 encrypted bits feeding BigLUT
  const int words_per_sample = static_cast<int>(ctx.n_lvl1) + 1;
  const double stdev = std::pow(2.0, -15);

  auto lwe_bits = new_array1<LweSample32>(samples, ctx.n_lvl1);
  for (int i = 0; i < samples; ++i) {
    const int bit = (index >> i) & 1;
    const int msg = modSwitchToTorus32(bit, FULL_MSG_SIZE);
    lwe32Encrypt_lvl1(&lwe_bits[i], msg, stdev, &ctx);
  }

  std::vector<std::uint8_t> payload(
      static_cast<std::size_t>(samples * words_per_sample) * word_bytes,
      0);
  std::uint8_t* dst = payload.data();
  for (int s = 0; s < samples; ++s) {
    for (int w = 0; w < words_per_sample; ++w) {
      const std::uint32_t word = static_cast<std::uint32_t>(lwe_bits[s].a[w]);
      if (word_bytes == sizeof(std::uint32_t)) {
        write_little_endian<std::uint32_t>(dst, word);
      } else {
        write_little_endian<std::uint64_t>(dst, static_cast<std::uint64_t>(word));
      }
      dst += word_bytes;
    }
  }
  delete_array1<LweSample32>(lwe_bits);
  return payload;
}

std::vector<std::uint8_t> synthesize_lvl0_payload(const Context& ctx,
                                                  int msg,
                                                  std::size_t word_bytes) {
  const double stdev = Context::ksstdev_lvl10;
  const int words = static_cast<int>(ctx.n_lvl0) + 1;
  const Torus32 torus_msg = modSwitchToTorus32(msg, FULL_MSG_SIZE);

  LweSample32 lwe_lvl0(ctx.n_lvl0);
  lwe32Encrypt_lvl0(&lwe_lvl0, torus_msg, stdev, &ctx);

  std::vector<std::uint8_t> payload(static_cast<std::size_t>(words) * word_bytes, 0);
  std::uint8_t* dst = payload.data();
  for (int i = 0; i < words; ++i) {
    const std::uint32_t word = static_cast<std::uint32_t>(lwe_lvl0.a[i]);
    if (word_bytes == sizeof(std::uint32_t)) {
      write_little_endian<std::uint32_t>(dst, word);
    } else {
      write_little_endian<std::uint64_t>(dst, static_cast<std::uint64_t>(word));
    }
    dst += word_bytes;
  }
  return payload;
}

}  // namespace

int main(int argc, char** argv) {
  Arguments args = parse_arguments(argc, argv);
  omp_set_num_threads(args.threads);
  std::cout << "[CPU_REF] threads=" << omp_get_max_threads() << std::endl;

  Context ctx;
  apply_keyset(ctx, args.keyset_path);

  if (!args.decode_tlwe_path.empty()) {
    const std::vector<std::uint8_t> raw = read_file(args.decode_tlwe_path);
    if (raw.size() % sizeof(std::int32_t) != 0) {
      std::cerr << "[CPU_REF][DECODE_TLWE] input size not aligned to int32: "
                << raw.size() << " bytes\n";
      return EXIT_FAILURE;
    }
    const std::size_t total_words = raw.size() / sizeof(std::int32_t);
    const std::size_t per_sample = static_cast<std::size_t>(k + 1) * ctx.n_lvl1;
    if (per_sample == 0 || total_words % per_sample != 0) {
      std::cerr << "[CPU_REF][DECODE_TLWE] size mismatch: words=" << total_words
                << " per_sample=" << per_sample << "\n";
      return EXIT_FAILURE;
    }
    const int len = static_cast<int>(total_words / per_sample);
    std::ofstream ofs;
    std::ostream* out = &std::cout;
    if (!args.decode_tlwe_out.empty()) {
      ofs.open(args.decode_tlwe_out, std::ios::out | std::ios::trunc);
      if (!ofs) {
        std::cerr << "[CPU_REF][DECODE_TLWE] failed to open output: "
                  << args.decode_tlwe_out << "\n";
        return EXIT_FAILURE;
      }
      out = &ofs;
    }
    const std::int32_t* words =
        reinterpret_cast<const std::int32_t*>(raw.data());
    for (int i = 0; i < len; ++i) {
      TLweSample32 sample(ctx.N_lvl1);
      const std::size_t base = static_cast<std::size_t>(i) * per_sample;
      for (int kk = 0; kk <= k; ++kk) {
        const std::size_t offset = base + static_cast<std::size_t>(kk) * ctx.n_lvl1;
        std::memcpy(sample.a[kk].coefs,
                    words + offset,
                    static_cast<std::size_t>(ctx.n_lvl1) * sizeof(std::int32_t));
      }
      LweSample32 lwe(ctx.n_lvl1);
      tLwe32ExtractSample_lvl1(&lwe, &sample, &ctx);
      const Torus32 phase = lwe32Decrypt(&lwe, ctx.n_lvl1, ctx.key_lvl1);
      const std::int32_t msg = modSwitchFromTorus32(phase, FULL_MSG_SIZE);
      (*out) << "idx=" << i << " phase=0x"
             << std::hex << static_cast<std::uint32_t>(phase)
             << std::dec << " msg=" << msg << "\n";
    }
    return EXIT_SUCCESS;
  }

  if (args.synth_vp) {
    auto payload = synthesize_vp_payload(ctx, args.synth_vp_index, args.word_bytes);
    write_file(args.tlwe_path, payload);
    std::cout << "[CPU_REF][SYNTH] generated VP payload index=" << args.synth_vp_index
              << " -> " << args.tlwe_path << " (" << payload.size() << " bytes)"
              << std::endl;
  }
  if (args.synth_lvl0) {
    auto payload = synthesize_lvl0_payload(ctx, args.synth_lvl0_msg, args.word_bytes);
    write_file(args.tlwe_path, payload);
    std::cout << "[CPU_REF][SYNTH] generated lvl0 LWE msg=" << args.synth_lvl0_msg
              << " -> " << args.tlwe_path << " (" << payload.size() << " bytes)"
              << std::endl;
  }

  const std::vector<std::uint8_t> tlwe_raw = read_file(args.tlwe_path);

  if (args.privks_step4) {
    if (args.word_bytes != sizeof(std::uint64_t)) {
      std::cerr << "[CPU_REF][PRIVKS_STEP4] requires --word-bytes 8\n";
      return EXIT_FAILURE;
    }
    const std::size_t expected_words = static_cast<std::size_t>(ctx.n_lvl2) + 1;
    const std::size_t expected_bytes = expected_words * args.word_bytes;
    if (tlwe_raw.size() < expected_bytes) {
      std::cerr << "[CPU_REF][PRIVKS_STEP4] TLWE payload too short (need "
                << expected_bytes << " bytes, got " << tlwe_raw.size() << ")\n";
      return EXIT_FAILURE;
    }

    LweSample64 res_boot(ctx.n_lvl2);
    for (std::size_t idx = 0; idx < expected_words; ++idx) {
      const std::uint8_t* base = tlwe_raw.data() + idx * args.word_bytes;
      const std::uint64_t word = read_little_endian<std::uint64_t>(base);
      res_boot.a[idx] = static_cast<Torus64>(word);
    }

    // Step5 (PrivKS): compute TLweSample32 for u=0 from Step4 LWE (lvl2).
    TLweSample32 privks_out(ctx.n_lvl1);
    circuitPrivKS(&privks_out, 0, &res_boot, &ctx);

    const std::size_t words_per_poly = static_cast<std::size_t>(ctx.n_lvl1);
    const std::size_t default_words = static_cast<std::size_t>(k + 1) * words_per_poly;
    const std::size_t out_words =
        args.glwe_words != 0 ? std::min(args.glwe_words, default_words) : default_words;

    std::vector<std::uint8_t> glwe_raw(out_words * args.word_bytes, 0);
    std::size_t out_idx = 0;
    for (int q = 0; q <= k && out_idx < out_words; ++q) {
      for (int p = 0; p < ctx.n_lvl1 && out_idx < out_words; ++p) {
        const std::uint32_t value = static_cast<std::uint32_t>(privks_out.a[q].coefs[p]);
        const std::size_t offset = out_idx * args.word_bytes;
        write_little_endian<std::uint64_t>(
            glwe_raw.data() + offset, static_cast<std::uint64_t>(value));
        ++out_idx;
      }
    }
    write_file(args.glwe_path, glwe_raw);
    std::cout << "[CPU_REF][PRIVKS_STEP4] wrote " << out_words
              << " words to " << args.glwe_path << std::endl;
    _Exit(EXIT_SUCCESS);
  }

  if (args.privks_only) {
    if (args.glwe_words == 0) {
      if (args.tlwe_words != 0) {
        args.glwe_words = args.tlwe_words;
      } else {
        args.glwe_words = tlwe_raw.size() / args.word_bytes;
      }
    }
    const std::size_t total_words =
        args.word_bytes == 0 ? 0 : tlwe_raw.size() / args.word_bytes;
    if (total_words == 0) {
      std::cerr << "[CPU_REF][PRIVKS_ONLY] TLWE payload empty\n";
      return EXIT_FAILURE;
    }
    if (args.glwe_words == 0 || args.glwe_words > total_words) {
      args.glwe_words = total_words;
    }
    const std::size_t glwe_bytes = args.glwe_words * args.word_bytes;
    std::vector<std::uint8_t> glwe_raw(glwe_bytes, 0);
    std::memcpy(glwe_raw.data(), tlwe_raw.data(), glwe_bytes);
    write_file(args.glwe_path, glwe_raw);
    std::cout << "[CPU_REF][PRIVKS_ONLY] copied " << args.glwe_words
              << " words (" << glwe_bytes << " bytes) from TLWE payload\n";
    _Exit(EXIT_SUCCESS);
  }

  const std::size_t expected_words = static_cast<std::size_t>(ctx.n_lvl0) + 1;

  if (args.tlwe_words == 0) {
    args.tlwe_words = expected_words;
  }
  if (args.glwe_words == 0) {
    args.glwe_words = static_cast<std::size_t>(ctx.n_lvl2) + 1;
  }

  std::vector<int32_t> abar(expected_words, 0);
  dump_bk_fft(ctx, args.bk_fft_prefix);

  auto compute_mu = [&](int mode) -> Torus64 {
    if (args.mu_override_enabled) {
      return static_cast<Torus64>(args.mu_override);
    }
    Torus64 mu = UINT64_C(1) << (64 - ctx.bgbit_lvl1);
    if (mode == gpu_runtime::ipc::kDescriptorModeCircuitBootstrap) {
      mu = UINT64_C(0x8000000000000000);
    }
    return mu;
  };

  const auto run_woks = [&](std::span<const int32_t> abar_words) -> std::vector<std::uint8_t> {
    LweSample64 result(static_cast<int>(ctx.n_lvl2));
    const Torus64 mu = compute_mu(args.mode);
    const bool need_debug_dump = !args.dec_fft_path.empty() ||
                                 !args.acc_fft_path.empty() ||
                                 !args.poly_fft_path.empty() ||
                                 !args.extmul_path.empty() ||
                                 !args.acc_raw_path.empty() ||
                                 !args.dec_plain_path.empty();
    if (need_debug_dump) {
      circuitBootstrapWoKS_debug(&result,
                                 mu,
                                 abar_words.data(),
                                 &ctx,
                                 args.dec_fft_path,
                                 args.acc_fft_path,
                                 args.poly_fft_path,
                                 args.extmul_path,
                                 args.acc_raw_path,
                                 args.dec_plain_path);
    } else {
      circuitBootstrapWoKS(&result, mu, abar_words.data(), &ctx);
    }
    std::cout << "[CPU_REF][WOKS] lwe[0..3]={";
    for (int i = 0; i < 4; ++i) {
      std::cout << "0x" << std::hex << static_cast<std::uint64_t>(result.a[i])
                << std::dec;
      if (i != 3) std::cout << ",";
    }
    std::cout << "} b=0x" << std::hex
              << static_cast<std::uint64_t>(result.b[0])
              << std::dec << std::endl;

    const std::size_t output_words = std::min<std::size_t>(args.glwe_words,
                                                           static_cast<std::size_t>(ctx.n_lvl2) + 1);
    std::vector<std::uint8_t> glwe_raw(output_words * args.word_bytes, 0);
    for (std::size_t idx = 0; idx < output_words; ++idx) {
      const std::uint64_t value = static_cast<std::uint64_t>(result.a[idx]);
      if (args.word_bytes == sizeof(std::uint32_t)) {
        write_little_endian<std::uint32_t>(glwe_raw.data() + idx * args.word_bytes,
                                           static_cast<std::uint32_t>(value));
      } else {
        write_little_endian<std::uint64_t>(glwe_raw.data() + idx * args.word_bytes, value);
      }
    }
    return glwe_raw;
  };
  if (!args.premod_path.empty()) {
    const auto premod_raw = read_file(args.premod_path);
    if (premod_raw.size() != expected_words * sizeof(std::int32_t)) {
      std::cerr << "Premod file size mismatch (expected "
                << expected_words * sizeof(std::int32_t)
                << " bytes, got " << premod_raw.size() << ")\n";
      return EXIT_FAILURE;
    }
    std::memcpy(abar.data(), premod_raw.data(), premod_raw.size());
    std::cout << "[CPU_REF][PREMOD] override using "
              << args.premod_path << std::endl;
    for (std::size_t idx = 0; idx < std::min<std::size_t>(8, abar.size()); ++idx) {
      std::cout << "[CPU_REF][PREMOD] idx=" << idx
                << " value=0x" << std::hex << static_cast<std::uint32_t>(abar[idx])
                << std::dec << std::endl;
    }
  } else if (!args.ks_input_path.empty()) {
    const auto ks_raw = read_file(args.ks_input_path);
    const std::size_t expected_lvl1_bytes = (static_cast<std::size_t>(ctx.n_lvl1) + 1) * args.word_bytes;
    if (ks_raw.size() != expected_lvl1_bytes) {
      std::cerr << "KS input size mismatch (expected " << expected_lvl1_bytes
                << " bytes, got " << ks_raw.size() << ")\n";
      return EXIT_FAILURE;
    }
    LweSample32 lwe_lvl1(ctx.n_lvl1);
    for (std::size_t idx = 0; idx < static_cast<std::size_t>(ctx.n_lvl1) + 1; ++idx) {
      const std::uint8_t* base = ks_raw.data() + idx * args.word_bytes;
      std::uint64_t word = 0;
      for (std::size_t b = 0; b < args.word_bytes; ++b) {
        word |= static_cast<std::uint64_t>(base[b]) << (8 * b);
      }
      lwe_lvl1.a[idx] = static_cast<std::int32_t>(static_cast<std::uint32_t>(word));
    }
    LweSample32 lwe_lvl0(ctx.n_lvl0);
    KeySwitch_lv10(&lwe_lvl0, &lwe_lvl1, 0, &ctx);
    for (std::size_t idx = 0; idx < expected_words; ++idx) {
      abar[idx] = lwe_lvl0.a[idx];
      if (idx < 8) {
        std::cout << "[CPU_REF][KS] idx=" << idx
                  << " lvl1=0x" << std::hex << static_cast<std::uint32_t>(lwe_lvl1.a[idx])
                  << " lvl0=0x" << static_cast<std::uint32_t>(abar[idx])
                  << std::dec << std::endl;
      }
    }
    auto dump_ks_if_requested = [&]() -> int {
      if (args.ks_dump_path.empty()) {
        return EXIT_SUCCESS;
      }
      std::ofstream ofs(args.ks_dump_path, std::ios::binary | std::ios::trunc);
      if (!ofs) {
        std::cerr << "Failed to open KS dump file: " << args.ks_dump_path << "\n";
        return EXIT_FAILURE;
      }
      std::vector<std::uint8_t> buffer(args.word_bytes);
      for (std::size_t idx = 0; idx < expected_words; ++idx) {
        const std::uint32_t value = static_cast<std::uint32_t>(abar[idx]);
        if (args.word_bytes == sizeof(std::uint32_t)) {
          write_little_endian<std::uint32_t>(buffer.data(), value);
        } else if (args.word_bytes == sizeof(std::uint64_t)) {
          write_little_endian<std::uint64_t>(buffer.data(),
                                             static_cast<std::uint64_t>(value));
        } else {
          std::cerr << "Unsupported word_bytes for KS dump: " << args.word_bytes << "\n";
          return EXIT_FAILURE;
        }
        ofs.write(reinterpret_cast<const char*>(buffer.data()),
                  static_cast<std::streamsize>(args.word_bytes));
        if (!ofs) {
          std::cerr << "Failed to write KS dump file: " << args.ks_dump_path << "\n";
          return EXIT_FAILURE;
        }
      }
      return EXIT_SUCCESS;
    };
    if (dump_ks_if_requested() != EXIT_SUCCESS) {
      return EXIT_FAILURE;
    }
    if (args.ks_only) {
      _Exit(EXIT_SUCCESS);
    }
  } else {
    const std::size_t available_words = tlwe_raw.size() / args.word_bytes;
    if (args.tlwe_words == 0) {
      args.tlwe_words = available_words;
    }
    if (available_words < args.tlwe_words) {
      std::cerr << "TLWE payload shorter than requested words\n";
      return EXIT_FAILURE;
    }

    const auto decode_word_raw = [&](std::size_t word_index) -> std::uint64_t {
      const std::uint8_t* base = tlwe_raw.data() + word_index * args.word_bytes;
      if (args.word_bytes == sizeof(std::uint32_t)) {
        return static_cast<std::uint64_t>(read_little_endian<std::uint32_t>(base));
      }
      return read_little_endian<std::uint64_t>(base);
    };
    const auto decode_word_signed = [&](std::size_t word_index) -> std::int64_t {
      return static_cast<std::int64_t>(decode_word_raw(word_index));
    };
    const auto normalize = [&](std::int64_t value) -> std::int32_t {
      const std::int32_t msize = static_cast<std::int32_t>(ctx.n_lvl2 * 2);
      const Torus32 phase = static_cast<Torus32>(static_cast<std::uint32_t>(value));
      return ::modSwitchFromTorus32(phase, msize);
    };

    const std::size_t lvl1_words = static_cast<std::size_t>(ctx.n_lvl1) + 1;
    const bool vp_payload =
        (args.mode == gpu_runtime::ipc::kDescriptorModeVerticalPacking) &&
        (args.tlwe_words % lvl1_words == 0) &&
        (args.tlwe_words / lvl1_words >= 20);
    const bool be_payload =
        (args.mode == gpu_runtime::ipc::kDescriptorModeBitExtract) &&
        (args.tlwe_words % lvl1_words == 0) &&
        (args.tlwe_words != 0);
    if (const char* env = std::getenv("CPU_REF_DEBUG_VP"); env != nullptr && *env != '\0') {
      std::cout << "[CPU_REF][VP_DEBUG] mode=" << args.mode
                << " tlwe_words=" << args.tlwe_words
                << " lvl1_words=" << lvl1_words
                << " vp_payload=" << vp_payload
                << " be_payload=" << be_payload
                << std::endl;
    }
    const std::int32_t msize = static_cast<std::int32_t>(ctx.n_lvl2 * 2);

    if (vp_payload) {
      const std::size_t sample_count = args.tlwe_words / lvl1_words;
      std::cout << "[CPU_REF][VP] preparing inputs, sample_count=" << sample_count
                << " lvl1_words=" << lvl1_words << std::endl;
      auto lwe_inputs = new_array1<LweSample32>(sample_count, ctx.n_lvl1);
      std::cout << "[CPU_REF][VP] allocated inputs" << std::endl;
      for (std::size_t sample = 0; sample < sample_count; ++sample) {
        const std::size_t base_index = sample * lvl1_words;
        for (std::size_t i = 0; i < lvl1_words; ++i) {
          const std::uint32_t torus =
              static_cast<std::uint32_t>(decode_word_raw(base_index + i));
          lwe_inputs[sample].a[i] = static_cast<std::int32_t>(torus);
        }
      }

      if (args.vp_input_select != -2) {
        auto run_one_input = [&](int in_idx, const std::filesystem::path& out_path) -> bool {
          LweSample32 lvl1_in(ctx.n_lvl1);
          lwe32Copy_lvl1(&lvl1_in, &lwe_inputs[in_idx], &ctx);
          if (args.vp_input_kspbs_get_hi) {
            if (args.vp_input_kspbs_add_offset) {
              lvl1_in.b[0] += modSwitchToTorus32(2, FULL_MSG_SIZE);
            }
            LweSample32 lvl1_out(ctx.n_lvl1);
            TLwe32_Keyswitch_Bootstrapping_Extract_lvl1(
                &lvl1_out, ctx.predefinedTLwe32Luts.get_hi, &lvl1_in, FULL_MSG_SIZE, &ctx);
            lwe32Copy_lvl1(&lvl1_in, &lvl1_out, &ctx);
          }

          LweSample32 lwe_lvl0(ctx.n_lvl0);
          KeySwitch_lv10(&lwe_lvl0, &lvl1_in, args.vp_ks_gpbs, &ctx);
          std::vector<int32_t> abar_sel(expected_words, 0);
          preModSwitch(abar_sel.data(), &lwe_lvl0, &ctx);
          std::vector<std::uint8_t> glwe_raw = run_woks(abar_sel);
          write_file(out_path, glwe_raw);
          std::cout << "[CPU_REF][VP] wrote " << out_path << std::endl;
          return true;
        };

        if (args.vp_input_select < 0) {
          for (int idx = 0; idx < static_cast<int>(sample_count); ++idx) {
            std::filesystem::path out_path = args.glwe_path;
            out_path += ".in" + std::to_string(idx);
            if (!run_one_input(idx, out_path)) return EXIT_FAILURE;
          }
          delete_array1<LweSample32>(lwe_inputs);
          return EXIT_SUCCESS;
        }

        int idx = args.vp_input_select;
        if (idx < 0) idx = 0;
        if (idx >= static_cast<int>(sample_count)) idx = static_cast<int>(sample_count) - 1;
        LweSample32 lvl1_in(ctx.n_lvl1);
        lwe32Copy_lvl1(&lvl1_in, &lwe_inputs[idx], &ctx);
        if (args.vp_input_kspbs_get_hi) {
          if (args.vp_input_kspbs_add_offset) {
            lvl1_in.b[0] += modSwitchToTorus32(2, FULL_MSG_SIZE);
          }
          LweSample32 lvl1_out(ctx.n_lvl1);
          TLwe32_Keyswitch_Bootstrapping_Extract_lvl1(
              &lvl1_out, ctx.predefinedTLwe32Luts.get_hi, &lvl1_in, FULL_MSG_SIZE, &ctx);
          lwe32Copy_lvl1(&lvl1_in, &lvl1_out, &ctx);
        }

        LweSample32 lwe_lvl0(ctx.n_lvl0);
        KeySwitch_lv10(&lwe_lvl0, &lvl1_in, args.vp_ks_gpbs, &ctx);
        std::cout << "[CPU_REF][VP] KeySwitch done (input=" << idx
                  << ", is_gpbs=" << args.vp_ks_gpbs << ")" << std::endl;
        preModSwitch(abar.data(), &lwe_lvl0, &ctx);
        delete_array1<LweSample32>(lwe_inputs);
      } else {
      int lut_len = 1;
      const TLweSample32* luts = ctx.predefinedTLwe32Luts.lut_test;
      if (args.vp_lut == "exp_minus") {
        lut_len = NUM_TOTAL_SIZE;
        luts = ctx.predefinedTLwe32Luts.exp_minus[0];
      }
      if (const char* dump_env = std::getenv("CPU_REF_DUMP_BIGLUT_TABLE");
          dump_env != nullptr && *dump_env != '\0') {
        std::ofstream ofs(dump_env, std::ios::binary | std::ios::trunc);
        if (!ofs) {
          std::cerr << "Failed to open CPU biglut table dump file: " << dump_env << "\n";
          return EXIT_FAILURE;
        }
        ofs.write(reinterpret_cast<const char*>(luts[0].b->coefs),
                  static_cast<std::streamsize>(ctx.N_lvl1 * sizeof(std::int32_t)));
        if (!ofs) {
          std::cerr << "Failed to write CPU biglut table dump file: " << dump_env << "\n";
          return EXIT_FAILURE;
        }
        std::cout << "[CPU_REF][VP] dumped biglut_table[0].b -> " << dump_env << "\n";
      }

      auto biglut_result = new_array1<LweSample32>(lut_len, ctx.n_lvl1);
      bigLut_20bit_lvl1_ip_batch(biglut_result, luts, lwe_inputs, lut_len, &ctx);
      std::cout << "[CPU_REF][VP] biglut ip_batch done (lut=" << args.vp_lut
                << ", len=" << lut_len << ")" << std::endl;

      auto dump_biglut_array = [&](const char* env_name) -> bool {
        const char* dump_env = std::getenv(env_name);
        if (dump_env == nullptr || *dump_env == '\0') return true;
        std::ofstream ofs(dump_env, std::ios::binary | std::ios::trunc);
        if (!ofs) {
          std::cerr << "Failed to open CPU biglut dump file: " << dump_env << "\n";
          return false;
        }
        ofs.write(reinterpret_cast<const char*>(biglut_result[0].a),
                  lvl1_words * sizeof(std::int32_t));
        if (!ofs) {
          std::cerr << "Failed to write CPU biglut dump file: " << dump_env << "\n";
          return false;
        }
        return true;
      };
      if (!dump_biglut_array("CPU_REF_DUMP_BIGLUT_RAW")) return EXIT_FAILURE;
      if (!dump_biglut_array("CPU_REF_DUMP_BIGLUT")) return EXIT_FAILURE;

      auto run_one = [&](int sel, const std::filesystem::path& out_path) -> bool {
        LweSample32 lwe_lvl0(ctx.n_lvl0);
        const int is_gpbs = 0;
        KeySwitch_lv10(&lwe_lvl0, &biglut_result[sel], is_gpbs, &ctx);
        std::vector<int32_t> abar_sel(expected_words, 0);
        preModSwitch(abar_sel.data(), &lwe_lvl0, &ctx);
        std::vector<std::uint8_t> glwe_raw = run_woks(abar_sel);
        write_file(out_path, glwe_raw);
        std::cout << "[CPU_REF][VP] wrote " << out_path << std::endl;
        return true;
      };

      if (args.vp_select < 0) {
        for (int sel = 0; sel < lut_len; ++sel) {
          std::filesystem::path out_path = args.glwe_path;
          out_path += ".sel" + std::to_string(sel);
          if (!run_one(sel, out_path)) return EXIT_FAILURE;
        }
        delete_array1<LweSample32>(biglut_result);
        delete_array1<LweSample32>(lwe_inputs);
        return EXIT_SUCCESS;
      }

      int sel = args.vp_select;
      if (sel < 0) sel = 0;
      if (sel >= lut_len) sel = lut_len - 1;
      LweSample32 lwe_lvl0(ctx.n_lvl0);
      const int is_gpbs = 0;
      KeySwitch_lv10(&lwe_lvl0, &biglut_result[sel], is_gpbs, &ctx);
      std::cout << "[CPU_REF][VP] KeySwitch done (sel=" << sel << ")" << std::endl;
      preModSwitch(abar.data(), &lwe_lvl0, &ctx);

      delete_array1<LweSample32>(biglut_result);
      delete_array1<LweSample32>(lwe_inputs);
      }
    } else if (be_payload) {
      const std::size_t sample_count = args.tlwe_words / lvl1_words;
      std::cout << "[CPU_REF][BE] preparing inputs, sample_count=" << sample_count
                << " lvl1_words=" << lvl1_words << std::endl;

      auto lwe_inputs = new_array1<LweSample32>(sample_count, ctx.n_lvl1);
      for (std::size_t sample = 0; sample < sample_count; ++sample) {
        const std::size_t base_index = sample * lvl1_words;
        for (std::size_t i = 0; i < lvl1_words; ++i) {
          const std::uint32_t torus =
              static_cast<std::uint32_t>(decode_word_raw(base_index + i));
          lwe_inputs[sample].a[i] = static_cast<Torus32>(torus);
        }
      }

      auto bit_extract_out = new_array1<LweSample32>(sample_count * 2, ctx.n_lvl1);
      for (std::size_t sample = 0; sample < sample_count; ++sample) {
        bitExtract(bit_extract_out + (sample << 1), &lwe_inputs[sample], &ctx);
      }
      std::cout << "[CPU_REF][BE] bitExtract done" << std::endl;
      if (const char* dump_env = std::getenv("CPU_REF_DUMP_BE_BITS");
          dump_env != nullptr && *dump_env != '\0') {
        const std::size_t bytes_per_sample = (static_cast<std::size_t>(ctx.n_lvl1) + 1) * sizeof(std::int32_t);
        std::vector<std::uint8_t> host_bits(sample_count * 2 * bytes_per_sample);
        for (std::size_t sample = 0; sample < sample_count * 2; ++sample) {
          std::memcpy(host_bits.data() + sample * bytes_per_sample,
                      bit_extract_out[sample].a,
                      bytes_per_sample);
        }
        std::ofstream ofs(dump_env, std::ios::binary | std::ios::trunc);
        if (!ofs) {
          std::cerr << "Failed to open CPU BE bit dump file: " << dump_env << "\n";
          return EXIT_FAILURE;
        }
        ofs.write(reinterpret_cast<const char*>(host_bits.data()),
                  static_cast<std::streamsize>(host_bits.size()));
        if (!ofs) {
          std::cerr << "Failed to write CPU BE bit dump file: " << dump_env << "\n";
          return EXIT_FAILURE;
        }
      }

      auto ks_output = new_array1<LweSample32>(1, ctx.n_lvl0);
      const int is_gpbs = 1;
      KeySwitch_lv10(ks_output, bit_extract_out, is_gpbs, &ctx);
      std::cout << "[CPU_REF][BE] KeySwitch_lv10 done" << std::endl;

      const Torus32* lvl0_coefs = ks_output[0].a;
      for (std::size_t idx = 0; idx < expected_words; ++idx) {
        const Torus32 phase = lvl0_coefs[idx];
        abar[idx] = ::modSwitchFromTorus32(phase, msize);
        if (idx < 8) {
          std::cout << "[CPU_REF][BE_KS] idx=" << idx
                    << " torus=0x" << std::hex << static_cast<std::uint32_t>(phase)
                    << " premod=0x" << static_cast<std::uint32_t>(abar[idx])
                    << std::dec << std::endl;
        }
      }

      delete_array1<LweSample32>(ks_output);
      delete_array1<LweSample32>(bit_extract_out);
      delete_array1<LweSample32>(lwe_inputs);
    } else {
      const std::size_t coeff_words = expected_words > 0 ? expected_words - 1 : 0;
      const std::size_t available_coeffs = args.tlwe_words > 0 ? args.tlwe_words - 1 : 0;
      const std::size_t words_to_copy = std::min(coeff_words, available_coeffs);
      for (std::size_t idx = 0; idx < words_to_copy; ++idx) {
        abar[idx] = normalize(decode_word_signed(idx));
        if (idx < 8) {
          std::cout << "[CPU_REF][TLWE] idx=" << idx
                    << " raw=0x" << std::hex << decode_word_signed(idx)
                    << " premod=0x" << static_cast<std::uint32_t>(abar[idx])
                    << std::dec << std::endl;
        }
      }
      std::fill(abar.begin() + words_to_copy, abar.begin() + coeff_words, 0);

      if (expected_words > 0) {
        const std::size_t b_index = (args.tlwe_words > 0) ? (args.tlwe_words - 1) : 0;
        abar[expected_words - 1] = normalize(decode_word_signed(b_index));
        std::cout << "[CPU_REF][TLWE] b raw=0x" << std::hex << decode_word_signed(b_index)
                  << " premod=0x" << static_cast<std::uint32_t>(abar[expected_words - 1])
                  << std::dec << std::endl;
      }

    }
  }

  if (const char* dump_env = std::getenv("CPU_REF_DUMP_KS");
      dump_env != nullptr && *dump_env != '\0') {
    std::ofstream ofs(dump_env, std::ios::binary | std::ios::trunc);
    if (!ofs) {
      std::cerr << "Failed to open CPU KS dump file: " << dump_env << "\n";
      return EXIT_FAILURE;
    }
    const std::size_t bytes_per_word = args.word_bytes;
    std::vector<std::uint8_t> buffer(bytes_per_word);
    for (std::size_t idx = 0; idx < expected_words; ++idx) {
      const std::uint32_t value = static_cast<std::uint32_t>(abar[idx]);
      if (bytes_per_word == sizeof(std::uint32_t)) {
        write_little_endian<std::uint32_t>(buffer.data(), value);
      } else if (bytes_per_word == sizeof(std::uint64_t)) {
        write_little_endian<std::uint64_t>(buffer.data(),
                                           static_cast<std::uint64_t>(value));
      } else {
        std::cerr << "Unsupported word_bytes for CPU_REF_DUMP_KS: "
                  << bytes_per_word << "\n";
        return EXIT_FAILURE;
      }
      ofs.write(reinterpret_cast<const char*>(buffer.data()),
                static_cast<std::streamsize>(bytes_per_word));
      if (!ofs) {
        std::cerr << "Failed to write CPU KS dump file: " << dump_env << "\n";
        return EXIT_FAILURE;
      }
    }
  }
  if (const char* dump_env = std::getenv("CPU_REF_DUMP_PREMOD");
      dump_env != nullptr && *dump_env != '\0') {
    std::ofstream ofs(dump_env, std::ios::binary | std::ios::trunc);
    if (!ofs) {
      std::cerr << "Failed to open CPU premod dump file: " << dump_env << "\n";
      return EXIT_FAILURE;
    }
    ofs.write(reinterpret_cast<const char*>(abar.data()),
              static_cast<std::streamsize>(expected_words * sizeof(std::int32_t)));
    if (!ofs) {
      std::cerr << "Failed to write CPU premod dump file: " << dump_env << "\n";
      return EXIT_FAILURE;
    }
  }

  LweSample64 result(static_cast<int>(ctx.n_lvl2));
  const Torus64 mu = compute_mu(args.mode);
  const bool need_debug_dump = !args.dec_fft_path.empty() ||
                               !args.acc_fft_path.empty() ||
                               !args.poly_fft_path.empty() ||
                               !args.extmul_path.empty() ||
                               !args.acc_raw_path.empty() ||
                               !args.dec_plain_path.empty();
  if (need_debug_dump) {
    circuitBootstrapWoKS_debug(&result,
                               mu,
                               abar.data(),
                               &ctx,
                               args.dec_fft_path,
                               args.acc_fft_path,
                               args.poly_fft_path,
                               args.extmul_path,
                               args.acc_raw_path,
                               args.dec_plain_path);
  } else {
    circuitBootstrapWoKS(&result, mu, abar.data(), &ctx);
  }
  std::cout << "[CPU_REF][WOKS] lwe[0..3]={";
  for (int i = 0; i < 4; ++i) {
    std::cout << "0x" << std::hex << static_cast<std::uint64_t>(result.a[i])
              << std::dec;
    if (i != 3) std::cout << ",";
  }
  std::cout << "} b=0x" << std::hex
            << static_cast<std::uint64_t>(result.b[0])
            << std::dec << std::endl;
  if (const char* dump_env = std::getenv("CPU_REF_DUMP_WOKS");
      dump_env != nullptr && *dump_env != '\0') {
    std::ofstream ofs(dump_env, std::ios::binary | std::ios::trunc);
    if (!ofs) {
      std::cerr << "Failed to open CPU WoKS dump file: " << dump_env << "\n";
      return EXIT_FAILURE;
    }
    ofs.write(reinterpret_cast<const char*>(result.a),
              static_cast<std::streamsize>((ctx.n_lvl2 + 1) * sizeof(Torus64)));
    if (!ofs) {
      std::cerr << "Failed to write CPU WoKS dump file: " << dump_env << "\n";
      return EXIT_FAILURE;
    }
  }

  const std::size_t output_words = std::min<std::size_t>(args.glwe_words,
                                                         static_cast<std::size_t>(ctx.n_lvl2) + 1);
  std::vector<std::uint8_t> glwe_raw(output_words * args.word_bytes, 0);
  for (std::size_t idx = 0; idx < output_words; ++idx) {
    const std::uint64_t value = static_cast<std::uint64_t>(result.a[idx]);
    if (args.word_bytes == sizeof(std::uint32_t)) {
      write_little_endian<std::uint32_t>(glwe_raw.data() + idx * args.word_bytes,
                                         static_cast<std::uint32_t>(value));
    } else {
      write_little_endian<std::uint64_t>(glwe_raw.data() + idx * args.word_bytes, value);
    }
  }

  write_file(args.glwe_path, glwe_raw);
  _Exit(EXIT_SUCCESS);
}
