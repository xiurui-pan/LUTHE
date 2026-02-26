#include "tfhe_gpu_executor.hpp"

#include <algorithm>
#include <cmath>
#include <cctype>
#include <chrono>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <optional>
#include <span>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <tuple>
#include <vector>
#include "luts.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cuda_runtime.h>

#include "tfhe_types.h"
#include "tfhe_functions.h"
#include "fp_number.h"
#include "gpu_runtime/keyset.hpp"
#include "gpu_runtime/ipc.hpp"
#include "tfhe_keyset_utils.hpp"

extern void circuit_privks(
    TGswSample32* result,
    const LweSample64* x,
    int m,
    int level,
    const Context* env);

namespace {

constexpr std::size_t kMinWordBytes = 4;
constexpr std::uint32_t kGoldenMismatchErrorBit = 0x1;
constexpr std::uint32_t kGoldenSkipSentinel = std::numeric_limits<std::uint32_t>::max() - 1;
std::vector<std::int32_t> g_preks_host_gpbs;

bool env_flag_enabled(const char* name) {
  const char* value = std::getenv(name);
  if (value == nullptr || *value == '\0') {
    return false;
  }
  return std::strcmp(value, "0") != 0 && std::strcmp(value, "false") != 0;
}

void maybe_enable_spqlios_defaults() {
  const char* default_ifft = "/tmp/spqlios_ifft_table.n4096.bin";
  const char* default_fft = "/tmp/spqlios_fft_table.n4096.bin";
  const char* ifft_env = std::getenv("TFHE_GPU_SPQLIOS_IFFT_TABLE");
  const char* fft_env = std::getenv("TFHE_GPU_SPQLIOS_FFT_TABLE");
  if ((ifft_env == nullptr || *ifft_env == '\0') && std::filesystem::exists(default_ifft)) {
    setenv("TFHE_GPU_SPQLIOS_IFFT_TABLE", default_ifft, 0);
    ifft_env = default_ifft;
  }
  if ((fft_env == nullptr || *fft_env == '\0') && std::filesystem::exists(default_fft)) {
    setenv("TFHE_GPU_SPQLIOS_FFT_TABLE", default_fft, 0);
    fft_env = default_fft;
  }
  if ((ifft_env != nullptr && *ifft_env != '\0') ||
      (fft_env != nullptr && *fft_env != '\0')) {
    if (!env_flag_enabled("TFHE_GPU_SPQLIOS_IFFT")) {
      setenv("TFHE_GPU_SPQLIOS_IFFT", "1", 0);
    }
    if (!env_flag_enabled("TFHE_GPU_SPQLIOS_FFT")) {
      setenv("TFHE_GPU_SPQLIOS_FFT", "1", 0);
    }
  }
}

std::string trim_copy(const std::string& input) {
  std::size_t start = 0;
  while (start < input.size() && std::isspace(static_cast<unsigned char>(input[start]))) {
    ++start;
  }
  std::size_t end = input.size();
  while (end > start && std::isspace(static_cast<unsigned char>(input[end - 1]))) {
    --end;
  }
  return input.substr(start, end - start);
}

bool parse_int32(const std::string& token, int* out) {
  if (token.empty() || out == nullptr) {
    return false;
  }
  try {
    std::size_t idx = 0;
    const int value = std::stoi(token, &idx, 10);
    if (idx != token.size()) {
      return false;
    }
    *out = value;
    return true;
  } catch (const std::exception&) {
    return false;
  }
}

std::unordered_map<int, std::filesystem::path> load_keyset_variants_env() {
  const char* env = std::getenv("WOP_GPU_KEYSET_VARIANTS");
  if (env == nullptr || *env == '\0') {
    return {};
  }
  std::string raw(env);
  for (char& ch : raw) {
    if (ch == ';') {
      ch = ',';
    }
  }
  std::unordered_map<int, std::filesystem::path> variants;
  std::stringstream ss(raw);
  std::string entry;
  while (std::getline(ss, entry, ',')) {
    entry = trim_copy(entry);
    if (entry.empty()) {
      continue;
    }
    std::size_t sep = entry.find('=');
    if (sep == std::string::npos) {
      sep = entry.find(':');
    }
    if (sep == std::string::npos) {
      continue;
    }
    std::string id_str = trim_copy(entry.substr(0, sep));
    std::string path_str = trim_copy(entry.substr(sep + 1));
    int id = 0;
    if (!parse_int32(id_str, &id) || path_str.empty()) {
      continue;
    }
    const auto [it, inserted] =
        variants.emplace(id, std::filesystem::path(path_str));
    if (!inserted) {
      std::cerr << "[TFHE_GPU_EXEC][KEYSET] duplicate variant id " << id
                << " in WOP_GPU_KEYSET_VARIANTS (keeping " << it->second << ")"
                << std::endl;
    }
  }
  return variants;
}

std::uint64_t parse_env_u64(const char* name, std::uint64_t default_value) {
  const char* value = std::getenv(name);
  if (value == nullptr || *value == '\0') {
    return default_value;
  }
  char* end = nullptr;
  errno = 0;
  unsigned long long parsed = std::strtoull(value, &end, 0);
  if (errno != 0 || end == value) {
    throw std::runtime_error(std::string("failed to parse ") + name);
  }
  return static_cast<std::uint64_t>(parsed);
}

double parse_env_double(const char* name, double default_value) {
  const char* value = std::getenv(name);
  if (value == nullptr || *value == '\0') {
    return default_value;
  }
  char* end = nullptr;
  errno = 0;
  const double parsed = std::strtod(value, &end);
  if (errno != 0 || end == value) {
    return default_value;
  }
  return parsed;
}

int parse_env_int(const char* name, int default_value) {
  const char* value = std::getenv(name);
  if (value == nullptr || *value == '\0') {
    return default_value;
  }
  char* end = nullptr;
  errno = 0;
  const long parsed = std::strtol(value, &end, 0);
  if (errno != 0 || end == value) {
    return default_value;
  }
  return static_cast<int>(parsed);
}

}  // namespace

const bool kVerifyDramTlwe = env_flag_enabled("WOP_GPU_VERIFY_DRAM_TLWE");

class DramImage {
 public:
  DramImage(const std::filesystem::path& path, std::uint64_t base)
      : path_(path), fd_(-1), data_(nullptr), length_(0), base_addr_(base) {
    fd_ = ::open(path_.c_str(), O_RDONLY);
    if (fd_ < 0) {
      throw std::system_error(errno, std::generic_category(), "open dram image");
    }
    struct stat st {};
    if (::fstat(fd_, &st) != 0) {
      int err = errno;
      ::close(fd_);
      fd_ = -1;
      throw std::system_error(err, std::generic_category(), "fstat dram image");
    }
    length_ = static_cast<std::size_t>(st.st_size);
    if (length_ == 0) {
      ::close(fd_);
      fd_ = -1;
      throw std::runtime_error("dram image is empty");
    }
    void* mapped = ::mmap(nullptr, length_, PROT_READ, MAP_PRIVATE, fd_, 0);
    if (mapped == MAP_FAILED) {
      int err = errno;
      ::close(fd_);
      fd_ = -1;
      throw std::system_error(err, std::generic_category(), "mmap dram image");
    }
    data_ = static_cast<std::uint8_t*>(mapped);
  }

  DramImage(const DramImage&) = delete;
  DramImage& operator=(const DramImage&) = delete;

  DramImage(DramImage&& other) noexcept
      : path_(std::move(other.path_)),
        fd_(other.fd_),
        data_(other.data_),
        length_(other.length_),
        base_addr_(other.base_addr_) {
    other.fd_ = -1;
    other.data_ = nullptr;
    other.length_ = 0;
    other.base_addr_ = 0;
  }

  DramImage& operator=(DramImage&& other) noexcept {
    if (this != &other) {
      cleanup();
      path_ = std::move(other.path_);
      fd_ = other.fd_;
      data_ = other.data_;
      length_ = other.length_;
      base_addr_ = other.base_addr_;
      other.fd_ = -1;
      other.data_ = nullptr;
      other.length_ = 0;
      other.base_addr_ = 0;
    }
    return *this;
  }

  ~DramImage() { cleanup(); }

  bool read_into(std::uint64_t addr, std::span<std::uint8_t> out) const {
    if (data_ == nullptr || out.empty()) {
      return false;
    }
    if (addr < base_addr_) {
      return false;
    }
    const std::uint64_t offset = addr - base_addr_;
    if (offset > std::numeric_limits<std::size_t>::max()) {
      return false;
    }
    const std::size_t span = out.size();
    if (offset + span > length_) {
      return false;
    }
    std::memcpy(out.data(), data_ + offset, span);
    return true;
  }

  std::size_t size_bytes() const { return length_; }
  std::uint64_t base_addr() const { return base_addr_; }
  const std::filesystem::path& path() const { return path_; }

 private:
  void cleanup() {
    if (data_ != nullptr) {
      ::munmap(data_, length_);
      data_ = nullptr;
    }
    if (fd_ >= 0) {
      ::close(fd_);
      fd_ = -1;
    }
    length_ = 0;
  }

  std::filesystem::path path_;
  int fd_;
  std::uint8_t* data_;
  std::size_t length_;
  std::uint64_t base_addr_;
};

namespace {

bool is_golden_enabled() {
  const char* env = std::getenv("WOP_GPU_GOLDEN_COMPARE");
  if (env == nullptr) {
    return false;
  }
  if (*env == '\0') {
    return false;
  }
  return std::strcmp(env, "0") != 0 && std::strcmp(env, "false") != 0;
}

constexpr std::uint8_t kFlagVpLutExpMinus = 0x04u;  // VP LUT selector: 0=test, 1=exp_minus

void append_cpu_runner_vp_args(std::ostringstream& cmd, std::uint8_t mode, std::uint8_t flags) {
  if (mode != gpu_runtime::ipc::kDescriptorModeVerticalPacking) {
    return;
  }
  if ((flags & kFlagVpLutExpMinus) != 0) {
    cmd << " --vp-lut exp_minus";
  }
}

bool golden_stage_is_woks() {
  const char* env = std::getenv("WOP_GPU_GOLDEN_STAGE");
  if (env == nullptr || *env == '\0') return false;
  // case-insensitive compare to "WOKS"
  std::string v(env);
  for (auto& ch : v) ch = static_cast<char>(std::tolower(ch));
  return v == "woks";
}

std::filesystem::path resolve_runner_path() {
  const char* env = std::getenv("WOP_GPU_CPU_RUNNER");
  if (env != nullptr && *env != '\0') {
    return std::filesystem::path(env);
  }
  try {
    std::filesystem::path self = std::filesystem::canonical("/proc/self/exe");
    return self.parent_path() / "cpu_reference_runner";
  } catch (const std::exception&) {
    return std::filesystem::path("cpu_reference_runner");
  }
}

std::filesystem::path resolve_concrete_runner_path() {
  const char* env = std::getenv("WOP_GPU_CONCRETE_RUNNER");
  if (env != nullptr && *env != '\0') {
    return std::filesystem::path(env);
  }
  const char* root = std::getenv("HPU_FPGA_FIN_ROOT");
  if (root != nullptr && *root != '\0') {
    return std::filesystem::path(root) / "tools" / "csd_concrete_fhe_runner.py";
  }
  return std::filesystem::path("csd_concrete_fhe_runner.py");
}

std::string resolve_concrete_python() {
  const char* env = std::getenv("WOP_GPU_CONCRETE_PYTHON");
  if (env != nullptr && *env != '\0') {
    return std::string(env);
  }
  return std::string("python3");
}

class TempFile {
 public:
  TempFile(const std::string& tag, std::size_t bytes, std::span<const std::uint8_t> init) {
    std::filesystem::path dir = std::filesystem::temp_directory_path();
    std::string templ = (dir / ("wop_" + tag + "XXXXXX")).string();
    fd_ = ::mkstemp(templ.data());
    if (fd_ < 0) {
      throw std::system_error(errno, std::generic_category(), "mkstemp");
    }
    path_ = std::filesystem::path(templ);
    if (!init.empty()) {
      write_all(init);
    } else if (bytes != 0) {
      std::vector<std::uint8_t> zeros(bytes, 0);
      write_all(zeros);
    }
    ::close(fd_);
    fd_ = -1;
  }

  TempFile(const TempFile&) = delete;
  TempFile& operator=(const TempFile&) = delete;
  TempFile(TempFile&& other) noexcept : path_(std::move(other.path_)), fd_(other.fd_) {
    other.fd_ = -1;
  }
  TempFile& operator=(TempFile&& other) noexcept {
    if (this != &other) {
      cleanup();
      path_ = std::move(other.path_);
      fd_ = other.fd_;
      other.fd_ = -1;
    }
    return *this;
  }

  ~TempFile() { cleanup(); }

  const std::filesystem::path& path() const { return path_; }

 private:
  void write_all(std::span<const std::uint8_t> data) {
    std::size_t written = 0;
    while (written < data.size()) {
      const ssize_t rc = ::write(fd_, data.data() + written, data.size() - written);
      if (rc < 0) {
        throw std::system_error(errno, std::generic_category(), "write");
      }
      written += static_cast<std::size_t>(rc);
    }
  }

  void cleanup() {
    if (fd_ >= 0) {
      ::close(fd_);
      fd_ = -1;
    }
    if (!path_.empty()) {
      std::error_code ec;
      std::filesystem::remove(path_, ec);
      path_.clear();
    }
  }

  std::filesystem::path path_;
  int fd_ = -1;
};

std::string shell_quote(const std::filesystem::path& path) {
  const std::string raw = path.string();
  std::string quoted;
  quoted.reserve(raw.size() + 2);
  quoted.push_back('\'');
  for (char ch : raw) {
    if (ch == '\'') {
      quoted.append("'\\''");
    } else {
      quoted.push_back(ch);
    }
  }
  quoted.push_back('\'');
  return quoted;
}

std::string shell_quote_str(const std::string& raw) {
  std::string quoted;
  quoted.reserve(raw.size() + 2);
  quoted.push_back('\'');
  for (char ch : raw) {
    if (ch == '\'') {
      quoted.append("'\\''");
    } else {
      quoted.push_back(ch);
    }
  }
  quoted.push_back('\'');
  return quoted;
}

std::vector<std::uint8_t> read_file_bytes(const std::filesystem::path& path) {
  std::ifstream ifs(path, std::ios::binary);
  if (!ifs) {
    throw std::runtime_error("failed to open golden output: " + path.string());
  }
  std::vector<std::uint8_t> data((std::istreambuf_iterator<char>(ifs)),
                                 std::istreambuf_iterator<char>());
  return data;
}

std::vector<std::uint8_t> run_concrete_runner(
    std::span<const std::uint8_t> payload,
    std::size_t out_limit) {
  const char* server_dir_env = std::getenv("CSD_DEEPNN_SERVER_DIR");
  if (server_dir_env == nullptr || *server_dir_env == '\0') {
    throw std::runtime_error("concrete runner missing CSD_DEEPNN_SERVER_DIR");
  }
  const char* eval_keys_env = std::getenv("CSD_DEEPNN_EVAL_KEYS");
  if (eval_keys_env == nullptr || *eval_keys_env == '\0') {
    throw std::runtime_error("concrete runner missing CSD_DEEPNN_EVAL_KEYS");
  }
  const std::filesystem::path server_dir(server_dir_env);
  const std::filesystem::path eval_keys(eval_keys_env);
  const std::filesystem::path server_zip = server_dir / "server.zip";
  std::error_code ec;
  if (!std::filesystem::exists(server_zip, ec)) {
    throw std::runtime_error("concrete runner missing server.zip: " + server_zip.string());
  }
  if (!std::filesystem::exists(eval_keys, ec)) {
    throw std::runtime_error("concrete runner missing eval keys: " + eval_keys.string());
  }

  const std::filesystem::path runner = resolve_concrete_runner_path();
  if (!std::filesystem::exists(runner, ec)) {
    throw std::runtime_error("concrete runner script not found: " + runner.string());
  }

  TempFile in_file("concrete_in", 0, payload);
  TempFile out_file("concrete_out", 0, {});

  const std::string python = resolve_concrete_python();
  std::ostringstream cmd;
  cmd << shell_quote_str(python)
      << " " << shell_quote(runner)
      << " --in " << shell_quote(in_file.path())
      << " --out " << shell_quote(out_file.path())
      << " --server-dir " << shell_quote(server_dir)
      << " --eval-keys " << shell_quote(eval_keys)
      << " --executor concrete";

  const char* func_env = std::getenv("CSD_DEEPNN_FUNC_NAME");
  if (func_env != nullptr && *func_env != '\0') {
    cmd << " --func-name " << shell_quote_str(std::string(func_env));
  }
  if (env_flag_enabled("CSD_DEEPNN_REQUIRE_GPU")) {
    cmd << " --require-gpu";
  }

  const int rc = std::system(cmd.str().c_str());
  if (rc == -1) {
    throw std::system_error(errno, std::generic_category(), "std::system");
  }
  if (!WIFEXITED(rc) || WEXITSTATUS(rc) != 0) {
    int exit_status = WIFEXITED(rc) ? WEXITSTATUS(rc) : -1;
    int term_signal = WIFSIGNALED(rc) ? WTERMSIG(rc) : 0;
    std::ostringstream err;
    err << "concrete runner failed";
    if (exit_status >= 0) {
      err << " exit_status=" << exit_status;
    }
    if (term_signal != 0) {
      err << " signal=" << term_signal;
    }
    throw std::runtime_error(err.str());
  }

  std::vector<std::uint8_t> output = read_file_bytes(out_file.path());
  if (out_limit != 0 && output.size() > out_limit) {
    throw std::runtime_error("concrete runner output exceeds glwe buffer");
  }
  return output;
}

std::uint64_t read_word64_le(const std::uint8_t* src, std::size_t bytes) {
  std::uint64_t value = 0;
  const std::size_t limit = std::min<std::size_t>(bytes, sizeof(value));
  for (std::size_t i = 0; i < limit; ++i) {
    value |= static_cast<std::uint64_t>(src[i]) << (8 * i);
  }
  return value;
}

std::optional<std::vector<std::uint8_t>> load_manual_golden(
    std::size_t result_words,
    std::size_t word_bytes) {
  if (result_words == 0 || word_bytes == 0) {
    return std::nullopt;
  }
  const char* manual_env = std::getenv("WOP_GPU_GOLDEN_FILE");
  if (manual_env == nullptr || *manual_env == '\0') {
    // If stage=WOKS, allow fallback to WOP_GPU_DUMP_WOKS as reference
    if (golden_stage_is_woks()) {
      const char* dump_env = std::getenv("WOP_GPU_DUMP_WOKS");
      if (dump_env != nullptr && *dump_env != '\0') {
        std::filesystem::path dump_path(dump_env);
        std::error_code ec;
        if (std::filesystem::exists(dump_path, ec)) {
          std::vector<std::uint8_t> data = read_file_bytes(dump_path);
          const std::size_t required_bytes = result_words * word_bytes;
          if (data.size() >= required_bytes) {
            if (data.size() > required_bytes) data.resize(required_bytes);
            std::cout << "[TFHE_GPU_EXEC][GOLDEN] using WOKS dump as reference: "
                      << dump_path << std::endl;
            return data;
          }
        }
      }
    }
    return std::nullopt;
  }
  std::filesystem::path manual_path(manual_env);
  std::error_code ec;
  if (!std::filesystem::exists(manual_path, ec)) {
    std::cout << "[TFHE_GPU_EXEC][GOLDEN] manual reference missing at "
              << manual_path << "; falling back to cpu_reference_runner" << std::endl;
    return std::nullopt;
  }
  std::vector<std::uint8_t> data = read_file_bytes(manual_path);
  const std::size_t required_bytes = result_words * word_bytes;
  if (data.size() < required_bytes) {
    std::cout << "[TFHE_GPU_EXEC][GOLDEN] manual reference too short ("
              << data.size() << " < " << required_bytes
              << "); falling back to cpu_reference_runner" << std::endl;
    return std::nullopt;
  }
  if (data.size() > required_bytes) {
    data.resize(required_bytes);
  }
  std::cout << "[TFHE_GPU_EXEC][GOLDEN] using manual reference file "
            << manual_path << std::endl;
  return data;
}

struct GoldenCompareResult {
  std::uint32_t mismatches = 0;
  std::uint64_t max_abs_diff = 0;
  std::vector<std::uint8_t> reference_payload;
};

std::optional<GoldenCompareResult> run_golden_compare(
    std::span<const std::uint8_t> tlwe_payload,
    std::span<const std::uint8_t> glwe_payload,
    std::size_t tlwe_words,
    std::size_t result_words,
    std::size_t word_bytes,
    std::uint8_t mode,
    std::uint8_t flags,
    const std::filesystem::path* keyset_path) {
  if (!is_golden_enabled()) {
    return std::nullopt;
  }

  const bool premod_input = (flags & gpu_runtime::ipc::kDescriptorFlagPremodInput) != 0;

  std::optional<std::vector<std::uint8_t>> reference_bytes =
      load_manual_golden(result_words, word_bytes);

  if (!reference_bytes) {
    const auto runner = resolve_runner_path();
    if (!std::filesystem::exists(runner)) {
      throw std::runtime_error("golden compare enabled but runner not found: " + runner.string());
    }
    TempFile tlwe_file("tlwe", 0, tlwe_payload);
    TempFile glwe_file("glwe", result_words * word_bytes, {});

    std::ostringstream cmd;
    cmd << shell_quote(runner)
        << " --tlwe " << shell_quote(tlwe_file.path())
        << " --glwe " << shell_quote(glwe_file.path())
        << " --tlwe-words " << tlwe_words
        << " --glwe-words " << result_words
        << " --word-bytes " << word_bytes
        << " --mode " << static_cast<int>(mode);
    append_cpu_runner_vp_args(cmd, mode, flags);
    if (premod_input) {
      cmd << " --premod " << shell_quote(tlwe_file.path());
    }
    if (keyset_path != nullptr) {
      cmd << " --keyset " << shell_quote(*keyset_path);
    } else {
      const char* keyset_env = std::getenv("WOP_GPU_KEY_IMPORT");
      if (keyset_env == nullptr || *keyset_env == '\0') {
        keyset_env = std::getenv("WOP_GPU_KEY_EXPORT");
      }
      if (keyset_env != nullptr && *keyset_env != '\0') {
        cmd << " --keyset " << shell_quote(std::filesystem::path(keyset_env));
      }
    }

    const int rc = std::system(cmd.str().c_str());
    if (rc == -1) {
      throw std::system_error(errno, std::generic_category(), "std::system");
    }
    if (!WIFEXITED(rc) || WEXITSTATUS(rc) != 0) {
      int exit_status = WIFEXITED(rc) ? WEXITSTATUS(rc) : -1;
      int term_signal = WIFSIGNALED(rc) ? WTERMSIG(rc) : 0;
      std::ostringstream err;
      err << "cpu_reference_runner failed";
      if (exit_status >= 0) {
        err << " exit_status=" << exit_status;
      }
      if (term_signal != 0) {
        err << " signal=" << term_signal;
      }
      throw std::runtime_error(err.str());
    }

    std::vector<std::uint8_t> golden = read_file_bytes(glwe_file.path());
    const std::size_t required_bytes = result_words * word_bytes;
    if (golden.size() < required_bytes) {
      throw std::runtime_error("cpu_reference_runner produced insufficient bytes");
    }
    if (golden.size() > required_bytes) {
      golden.resize(required_bytes);
    }
    reference_bytes.emplace(std::move(golden));
  }

  GoldenCompareResult summary{};
  summary.reference_payload = std::move(*reference_bytes);
  std::size_t sample_mismatch_prints = 0;
  constexpr std::size_t kMaxMismatchPrints = 4;
  for (std::size_t idx = 0; idx < result_words; ++idx) {
    const std::uint64_t gpu_value = read_word64_le(glwe_payload.data() + idx * word_bytes, word_bytes);
    const std::uint64_t ref_value = read_word64_le(
        summary.reference_payload.data() + idx * word_bytes, word_bytes);
    if (gpu_value != ref_value) {
      summary.mismatches += 1;
      const std::uint64_t diff = (gpu_value > ref_value) ? (gpu_value - ref_value)
                                                         : (ref_value - gpu_value);
      summary.max_abs_diff = std::max(summary.max_abs_diff, diff);
      if (sample_mismatch_prints < kMaxMismatchPrints) {
        std::cout << "[TFHE_GPU_EXEC][GOLDEN] mismatch idx=" << idx
                  << " gpu=0x" << std::hex << gpu_value
                  << " ref=0x" << ref_value
                  << " diff=0x" << diff
                  << std::dec << std::endl;
        sample_mismatch_prints += 1;
      }
    }
  }

  return summary;
}

std::optional<std::vector<std::uint8_t>> maybe_run_cpu_woks_override(
    std::span<const std::uint8_t> tlwe_payload,
    std::size_t tlwe_words,
    std::size_t result_words,
    std::size_t output_word_bytes,
    std::uint8_t mode,
    std::uint8_t flags,
    const std::filesystem::path* keyset_path,
    std::uint64_t& latency_ns_out) {
  latency_ns_out = 0;
  if (!env_flag_enabled("WOP_GPU_FORCE_CPU_WOKS")) {
    return std::nullopt;
  }

  const bool premod_input = (flags & gpu_runtime::ipc::kDescriptorFlagPremodInput) != 0;

  const auto runner = resolve_runner_path();
  if (!std::filesystem::exists(runner)) {
    std::cout << "[TFHE_GPU_EXEC][CPU_WOKS] runner missing at " << runner
              << "; skip override" << std::endl;
    return std::nullopt;
  }

  TempFile tlwe_file("tlwe", 0, tlwe_payload);
  TempFile glwe_file("glwe", result_words * output_word_bytes, {});

  std::ostringstream cmd;
  cmd << shell_quote(runner)
      << " --tlwe " << shell_quote(tlwe_file.path())
      << " --glwe " << shell_quote(glwe_file.path())
      << " --tlwe-words " << tlwe_words
      << " --glwe-words " << result_words
      << " --word-bytes " << output_word_bytes
      << " --mode " << static_cast<int>(mode);
  append_cpu_runner_vp_args(cmd, mode, flags);
  if (premod_input) {
    cmd << " --premod " << shell_quote(tlwe_file.path());
  }
  if (keyset_path != nullptr) {
    cmd << " --keyset " << shell_quote(*keyset_path);
  } else {
    const char* keyset_env = std::getenv("WOP_GPU_KEY_IMPORT");
    if (keyset_env == nullptr || *keyset_env == '\0') {
      keyset_env = std::getenv("WOP_GPU_KEY_EXPORT");
    }
    if (keyset_env != nullptr && *keyset_env != '\0') {
      cmd << " --keyset " << shell_quote(std::filesystem::path(keyset_env));
    }
  }
  if (const char* threads_env = std::getenv("WOP_GPU_CPU_THREADS");
      threads_env != nullptr && *threads_env != '\0') {
    cmd << " --threads " << threads_env;
  }

  const auto cpu_start = std::chrono::steady_clock::now();
  const int rc = std::system(cmd.str().c_str());
  const auto cpu_end = std::chrono::steady_clock::now();
  latency_ns_out = std::chrono::duration_cast<std::chrono::nanoseconds>(
                       cpu_end - cpu_start)
                       .count();

  if (rc == -1 || !WIFEXITED(rc) || WEXITSTATUS(rc) != 0) {
    std::cout << "[TFHE_GPU_EXEC][CPU_WOKS] cpu_reference_runner failed rc=" << rc
              << " (ignored, keep GPU result)" << std::endl;
    return std::nullopt;
  }

  std::vector<std::uint8_t> cpu_bytes = read_file_bytes(glwe_file.path());
  const std::size_t required = result_words * output_word_bytes;
  if (cpu_bytes.size() < required) {
    std::cout << "[TFHE_GPU_EXEC][CPU_WOKS] cpu_reference_runner output too short ("
              << cpu_bytes.size() << " < " << required << "); skip override"
              << std::endl;
    return std::nullopt;
  }
  if (cpu_bytes.size() > required) {
    cpu_bytes.resize(required);
  }
  std::cout << "[TFHE_GPU_EXEC][CPU_WOKS] override active, words=" << result_words
            << " bytes=" << cpu_bytes.size()
            << " latency_ns=" << latency_ns_out << std::endl;
  return cpu_bytes;
}

void run_cpu_woks_debug_compare(
    std::span<const std::uint8_t> tlwe_payload,
    std::span<const Torus64> gpu_lwe_words,
    std::size_t tlwe_words,
    std::size_t result_words,
    std::size_t output_word_bytes,
    std::uint8_t mode,
    std::uint8_t flags,
    const std::filesystem::path* keyset_path) {
  if (!env_flag_enabled("WOP_GPU_WOKS_DEBUG")) {
    return;
  }

  const bool premod_input = (flags & gpu_runtime::ipc::kDescriptorFlagPremodInput) != 0;

  const auto runner = resolve_runner_path();
  if (!std::filesystem::exists(runner)) {
    std::cout << "[TFHE_GPU_EXEC][WOKS_DEBUG] runner missing at " << runner
              << "; skip compare" << std::endl;
    return;
  }

  TempFile tlwe_file("tlwe", 0, tlwe_payload);
  TempFile glwe_file("glwe", result_words * output_word_bytes, {});

  std::ostringstream cmd;
  cmd << shell_quote(runner)
      << " --tlwe " << shell_quote(tlwe_file.path())
      << " --glwe " << shell_quote(glwe_file.path())
      << " --tlwe-words " << tlwe_words
      << " --glwe-words " << result_words
      << " --word-bytes " << output_word_bytes
      << " --mode " << static_cast<int>(mode);
  append_cpu_runner_vp_args(cmd, mode, flags);
  if (premod_input) {
    cmd << " --premod " << shell_quote(tlwe_file.path());
  }
  if (keyset_path != nullptr) {
    cmd << " --keyset " << shell_quote(*keyset_path);
  } else {
    const char* keyset_env = std::getenv("WOP_GPU_KEY_IMPORT");
    if (keyset_env == nullptr || *keyset_env == '\0') {
      keyset_env = std::getenv("WOP_GPU_KEY_EXPORT");
    }
    if (keyset_env != nullptr && *keyset_env != '\0') {
      cmd << " --keyset " << shell_quote(std::filesystem::path(keyset_env));
    }
  }
  if (const char* threads_env = std::getenv("WOP_GPU_CPU_THREADS");
      threads_env != nullptr && *threads_env != '\0') {
    cmd << " --threads " << threads_env;
  }

  const int rc = std::system(cmd.str().c_str());
  if (rc == -1 || !WIFEXITED(rc) || WEXITSTATUS(rc) != 0) {
    std::cout << "[TFHE_GPU_EXEC][WOKS_DEBUG] cpu_reference_runner failed rc=" << rc
              << " (skip debug compare)" << std::endl;
    return;
  }

  std::vector<std::uint8_t> cpu_bytes = read_file_bytes(glwe_file.path());
  const std::size_t required = result_words * output_word_bytes;
  if (cpu_bytes.size() < required) {
    std::cout << "[TFHE_GPU_EXEC][WOKS_DEBUG] cpu output too short (" << cpu_bytes.size()
              << " < " << required << ")" << std::endl;
    return;
  }
  if (cpu_bytes.size() > required) cpu_bytes.resize(required);

  auto read_word = [&](std::size_t idx) -> std::uint64_t {
    return read_word64_le(cpu_bytes.data() + idx * output_word_bytes, output_word_bytes);
  };

  std::size_t mismatches = 0;
  std::uint64_t max_abs_diff = 0;
  long double sum_abs_diff = 0.0;
  constexpr std::size_t kPrint = 8;
  for (std::size_t i = 0; i < result_words; ++i) {
    const std::uint64_t gpu = static_cast<std::uint64_t>(gpu_lwe_words[i]);
    const std::uint64_t cpu = read_word(i);
    if (gpu != cpu) {
      mismatches++;
      const std::uint64_t diff = (gpu > cpu) ? (gpu - cpu) : (cpu - gpu);
      max_abs_diff = std::max(max_abs_diff, diff);
      sum_abs_diff += static_cast<long double>(diff);
      if (mismatches <= kPrint) {
        std::cout << "[TFHE_GPU_EXEC][WOKS_DEBUG] idx=" << i
                  << " gpu=0x" << std::hex << gpu
                  << " cpu=0x" << cpu
                  << " diff=0x" << diff
                  << std::dec << std::endl;
      }
    }
  }
  const long double avg = result_words ? (sum_abs_diff / static_cast<long double>(result_words))
                                       : 0.0L;
  std::cout << "[TFHE_GPU_EXEC][WOKS_DEBUG] mismatch=" << mismatches
            << "/" << result_words
            << " max_abs_diff=" << max_abs_diff
            << " avg_abs_diff=" << static_cast<double>(avg)
            << std::endl;
}

std::size_t determine_stream_count() {
  const char* env = std::getenv("WOP_GPU_STREAMS");
  if (env != nullptr && *env != '\0') {
    char* end = nullptr;
    const long parsed = std::strtol(env, &end, 10);
    if (end != nullptr && end != env && parsed > 0) {
      constexpr std::size_t kMaxStreams = 16;
      const std::size_t clamped = static_cast<std::size_t>(parsed);
      return std::min(kMaxStreams, std::max<std::size_t>(1, clamped));
    }
  }
  return 1;
}

std::size_t safe_divide(std::size_t dividend, std::size_t divisor) {
  if (divisor == 0) {
    throw std::invalid_argument("divide by zero when computing word size");
  }
  if (dividend % divisor != 0) {
    throw std::invalid_argument("payload size is not aligned with tlwe word count");
  }
  return dividend / divisor;
}

std::int64_t decode_word_le_signed(const std::uint8_t* src, std::size_t bytes) {
  std::uint64_t raw = 0;
  const std::size_t limit = std::min<std::size_t>(bytes, sizeof(raw));
  for (std::size_t i = 0; i < limit; ++i) {
    raw |= static_cast<std::uint64_t>(src[i]) << (8 * i);
  }
  if (bytes >= sizeof(std::uint64_t)) {
    return static_cast<std::int64_t>(raw);
  }
  std::uint32_t as32 = static_cast<std::uint32_t>(raw & 0xFFFFFFFFu);
  return static_cast<std::int64_t>(static_cast<std::int32_t>(as32));
}

std::int32_t normalize_pre_modswitch(std::int64_t value) {
  const std::uint32_t torus32 = static_cast<std::uint32_t>(value);
  const std::uint64_t msize = static_cast<std::uint64_t>(Context::n_lvl2) * 2u;
  const std::uint64_t interval = ((UINT64_C(1) << 63) / msize) * 2u;
  const std::uint64_t half_interval = interval / 2u;
  const std::uint64_t temp =
      (static_cast<std::uint64_t>(torus32) << 32) + half_interval;
  return static_cast<std::int32_t>(temp / interval);
}

void encode_word_le(std::uint8_t* dst, std::size_t bytes, std::uint64_t value) {
  for (std::size_t i = 0; i < bytes; ++i) {
    dst[i] = static_cast<std::uint8_t>((value >> (8 * i)) & 0xFF);
  }
}

void maybe_dump_payload(const char* path, std::span<const std::uint8_t> payload) {
  if (path == nullptr || *path == '\0') {
    return;
  }
  std::filesystem::path dump_path(path);
  try {
    if (!dump_path.parent_path().empty()) {
      std::filesystem::create_directories(dump_path.parent_path());
    }
    std::cout << "[TFHE_GPU_EXEC][DUMP] write " << payload.size()
              << " bytes -> " << dump_path << std::endl;
    std::ofstream ofs(dump_path, std::ios::binary | std::ios::trunc);
    if (!ofs) {
      std::cerr << "[TFHE_GPU_EXEC][CB] failed to open dump path: " << dump_path << std::endl;
      return;
    }
    ofs.write(reinterpret_cast<const char*>(payload.data()),
              static_cast<std::streamsize>(payload.size()));
  } catch (const std::exception& ex) {
    std::cerr << "[TFHE_GPU_EXEC][CB] dump error: " << ex.what() << std::endl;
  }
}

void ensure_cuda_success(cudaError_t status, const char* what) {
  if (status != cudaSuccess) {
    throw std::runtime_error(std::string(what) + ": " + cudaGetErrorString(status));
  }
}


bool is_key_export_requested(std::filesystem::path& out_path) {
  const char* env = std::getenv("WOP_GPU_KEY_EXPORT");
  if (env == nullptr || *env == '\0') {
    return false;
  }
  out_path = std::filesystem::path(env);
  return true;
}

std::vector<std::int32_t> copy_device_int_vector(const int* device_ptr, std::size_t count) {
  std::vector<std::int32_t> host(count);
  if (count == 0) {
    return host;
  }
  ensure_cuda_success(
      cudaMemcpy(host.data(), device_ptr, count * sizeof(std::int32_t), cudaMemcpyDeviceToHost),
      "copy keyset data");
  return host;
}

void copy_int_vector_to_device(int* device_ptr,
                               const std::vector<std::int32_t>& data,
                               const char* label) {
  if (device_ptr == nullptr || data.empty()) {
    return;
  }
  ensure_cuda_success(
      cudaMemcpy(device_ptr,
                 data.data(),
                 data.size() * sizeof(std::int32_t),
                 cudaMemcpyHostToDevice),
      label);
}

bool import_keyset_from_path(Context* ctx,
                             const std::filesystem::path& import_path,
                             const char* variant_name_override,
                             const char* variant_id_override) {
  if (ctx == nullptr) {
    return false;
  }
  std::ifstream ifs(import_path, std::ios::binary);
  if (!ifs) {
    throw std::runtime_error("failed to open keyset file for reading: " + import_path.string());
  }

  gpu_runtime::keyset_tools::ParsedHeader parsed =
      gpu_runtime::keyset_tools::read_keyset_header(ifs);
  const gpu_runtime::keyset::Header& header = parsed.header;
  if (header.glwe_dimension == 0 || header.glwe_dimension != static_cast<std::uint32_t>(K)) {
    std::ostringstream oss;
    oss << "keyset glwe_dimension mismatch (header=" << header.glwe_dimension
        << ", compiled K=" << K << ")";
    throw std::runtime_error(oss.str());
  }
  if (header.n_lvl0 != static_cast<std::uint32_t>(Context::n_lvl0) ||
      header.n_lvl1 != static_cast<std::uint32_t>(Context::n_lvl1) ||
      header.n_lvl2 != static_cast<std::uint32_t>(Context::n_lvl2)) {
    throw std::runtime_error("keyset parameter mismatch");
  }

  auto read_int_block = [&](std::uint64_t offset,
                            std::uint32_t words,
                            std::size_t expected_words,
                            std::vector<std::int32_t>& out) {
    if (words != expected_words) {
      throw std::runtime_error("keyset word count mismatch");
    }
    out.resize(words);
    ifs.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!ifs) {
      throw std::runtime_error("failed to seek keyset section");
    }
    ifs.read(reinterpret_cast<char*>(out.data()),
             static_cast<std::streamsize>(out.size() * sizeof(std::int32_t)));
    if (!ifs) {
      throw std::runtime_error("failed to read keyset payload");
    }
  };

  if ((header.flags & gpu_runtime::keyset::kSectionSecretKeys) == 0) {
    throw std::runtime_error("keyset missing secret key section");
  }

  const char* variant_name = variant_name_override;
  const char* variant_id = variant_id_override;
  if (variant_name == nullptr || *variant_name == '\0') {
    variant_name = std::getenv("WOP_GPU_VARIANT_NAME");
  }
  if (variant_id == nullptr || *variant_id == '\0') {
    variant_id = std::getenv("WOP_GPU_VARIANT_ID");
  }

  std::cout << "[TFHE_GPU_EXEC][KEYSET] importing from " << import_path << std::endl;
  if ((variant_name != nullptr && *variant_name != '\0') ||
      (variant_id != nullptr && *variant_id != '\0')) {
    std::cout << "[TFHE_GPU_EXEC][KEYSET] variant"
              << (variant_name != nullptr && *variant_name ? " name=" : "")
              << (variant_name != nullptr && *variant_name ? variant_name : "")
              << (variant_id != nullptr && *variant_id ? " id=" : "")
              << (variant_id != nullptr && *variant_id ? variant_id : "")
              << std::endl;
  }
  std::cout << "[TFHE_GPU_EXEC][KEYSET] params: glwe_dimension=" << header.glwe_dimension
            << " n_lvl0=" << header.n_lvl0
            << " n_lvl1=" << header.n_lvl1
            << " n_lvl2=" << header.n_lvl2
            << std::endl;
  std::cout << "[TFHE_GPU_EXEC][KEYSET] header: key_lvl0_words=" << header.key_lvl0_words
            << " key_lvl1_words=" << header.key_lvl1_words
            << " key_lvl2_words=" << header.key_lvl2_words << std::endl;

  std::vector<std::int32_t> key_lvl0;
  std::vector<std::int32_t> key_lvl1;
  std::vector<std::int32_t> key_lvl2;
  read_int_block(header.offset_key_lvl0,
                 header.key_lvl0_words,
                 static_cast<std::size_t>(Context::n_lvl0),
                 key_lvl0);
  read_int_block(header.offset_key_lvl1,
                 header.key_lvl1_words,
                 static_cast<std::size_t>(Context::n_lvl1),
                 key_lvl1);
  read_int_block(header.offset_key_lvl2,
                 header.key_lvl2_words,
                 static_cast<std::size_t>(Context::n_lvl2) + 1,
                 key_lvl2);

  copy_int_vector_to_device(ctx->key_lvl0, key_lvl0, "import key_lvl0");
  copy_int_vector_to_device(ctx->key_lvl1, key_lvl1, "import key_lvl1");
  copy_int_vector_to_device(ctx->key_lvl2, key_lvl2, "import key_lvl2");
  if (ctx->Key_lvl1 != nullptr) {
    ensure_cuda_success(
        cudaMemcpy(ctx->Key_lvl1->coefs,
                   key_lvl1.data(),
                   key_lvl1.size() * sizeof(std::int32_t),
                   cudaMemcpyHostToDevice),
        "import key_lvl1 poly");
  }
  if (ctx->Key_lvl2 != nullptr) {
    ensure_cuda_success(
        cudaMemcpy(ctx->Key_lvl2->coefs,
                   key_lvl2.data(),
                   Context::n_lvl2 * sizeof(int),
                   cudaMemcpyHostToDevice),
        "import key_lvl2 poly");
  }
  std::cout << "[TFHE_GPU_EXEC][KEYSET] secret keys loaded" << std::endl;

  const std::size_t lwe_words = static_cast<std::size_t>(Context::n_lvl0) + 1;
  std::vector<std::int32_t> lwe_buffer(lwe_words);
  const char* split_luts_env = std::getenv("WOP_GPU_KSPBS_SPLIT_LUTS");
  const bool want_kspbs_split =
      env_flag_enabled("WOP_GPU_KSPBS_SPLIT") ||
      (split_luts_env != nullptr && *split_luts_env != '\0');
  ctx->preks_host = {};
  ctx->preks_host_gpbs = {};
  g_preks_host_gpbs.clear();

  auto import_preks = [&](std::uint64_t offset,
                          std::uint32_t samples,
                          std::uint32_t words,
                          LweSample32*** target,
                          int kslength,
                          int ksbasebit,
                          const char* label,
                          std::vector<std::int32_t>* host_flat) {
    if (samples == 0 || words == 0) {
      return;
    }
    if (offset == 0) {
      throw std::runtime_error(std::string("keyset ") + label + " offset missing");
    }
    const int base = 1 << ksbasebit;
    const std::size_t expected_samples =
        static_cast<std::size_t>(Context::n_lvl1) *
        static_cast<std::size_t>(kslength) *
        static_cast<std::size_t>(base);
    if (samples != expected_samples) {
      throw std::runtime_error(std::string("keyset ") + label + " sample mismatch");
    }
    if (words != lwe_words) {
      throw std::runtime_error(std::string("keyset ") + label + " word mismatch");
    }
    ifs.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!ifs) {
      throw std::runtime_error(std::string("failed to seek ") + label);
    }
    if (host_flat != nullptr) {
      host_flat->resize(static_cast<std::size_t>(samples) * lwe_words);
      ifs.read(reinterpret_cast<char*>(host_flat->data()),
               static_cast<std::streamsize>(host_flat->size() * sizeof(std::int32_t)));
      if (!ifs) {
        throw std::runtime_error(std::string("failed to read ") + label);
      }
    }
    for (int i = 0; i < Context::n_lvl1; ++i) {
      for (int j = 0; j < kslength; ++j) {
        for (int u = 0; u < base; ++u) {
          const std::int32_t* src = nullptr;
          if (host_flat != nullptr) {
            const std::size_t idx =
                ((static_cast<std::size_t>(i) * kslength + j) * base + u) * lwe_words;
            src = host_flat->data() + idx;
          } else {
            ifs.read(reinterpret_cast<char*>(lwe_buffer.data()),
                     static_cast<std::streamsize>(lwe_words * sizeof(std::int32_t)));
            if (!ifs) {
              throw std::runtime_error(std::string("failed to read ") + label);
            }
            src = lwe_buffer.data();
          }
          ensure_cuda_success(
              cudaMemcpy(target[i][j][u].a,
                         src,
                         lwe_words * sizeof(std::int32_t),
                         cudaMemcpyHostToDevice),
              label);
        }
      }
    }
  };

  if ((header.flags & gpu_runtime::keyset::kSectionPreKS) != 0) {
    std::cout << "[TFHE_GPU_EXEC][KEYSET] importing preKS" << std::endl;
    import_preks(header.offset_preks_lvl10,
                 header.preks_lvl10_samples,
                 header.preks_lvl10_words,
                 ctx->preKS,
                 Context::kslength_lvl10,
                 Context::ksbasebit_lvl10,
                 "preKS lvl10",
                 nullptr);
    import_preks(header.offset_preks_lvl10_gpbs,
                 header.preks_lvl10_gpbs_samples,
                 header.preks_lvl10_gpbs_words,
                 ctx->preKS_gpbs,
                 Context::kslength_lvl10_gpbs,
                 Context::ksbasebit_lvl10_gpbs,
                 "preKS lvl10 gpbs",
                 want_kspbs_split ? &g_preks_host_gpbs : nullptr);
    std::cout << "[TFHE_GPU_EXEC][KEYSET] preKS loaded" << std::endl;
  }
  if (want_kspbs_split && !g_preks_host_gpbs.empty()) {
    ctx->preks_host_gpbs.flat = g_preks_host_gpbs.data();
    ctx->preks_host_gpbs.n0 = Context::n_lvl0;
    ctx->preks_host_gpbs.n1 = Context::n_lvl1;
    ctx->preks_host_gpbs.kslen = Context::kslength_lvl10_gpbs;
    ctx->preks_host_gpbs.basebit = Context::ksbasebit_lvl10_gpbs;
    ctx->preks_host_gpbs.base = 1 << Context::ksbasebit_lvl10_gpbs;
    ctx->preks_host_gpbs.words = static_cast<int>(lwe_words);
    std::cout << "[TFHE_GPU_EXEC][KEYSET] host preKS gpbs loaded for KSPBS split" << std::endl;
  }

  if ((header.flags & gpu_runtime::keyset::kSectionBootstrappingKeys) != 0) {
    std::cout << "[TFHE_GPU_EXEC][KEYSET] importing bkFFT" << std::endl;
    const int k_plus_1 = K + 1;
    const int sample_per_tgsw = Context::ell_lvl2 * k_plus_1;
    const int N_lvl2 = Context::n_lvl2;
    const int Ns2 = N_lvl2 / 2;
    const int sample_per_tgsw_32 = Context::ell_lvl1_gpbs * k_plus_1;
    const int N_lvl1 = Context::n_lvl1;
    const std::uint64_t expected_bk_values_lvl2 =
        static_cast<std::uint64_t>(Context::n_lvl0) *
        static_cast<std::uint64_t>(sample_per_tgsw) *
        static_cast<std::uint64_t>(k_plus_1) *
        static_cast<std::uint64_t>(N_lvl2);
    const std::uint64_t expected_bk_values_lvl1 =
        static_cast<std::uint64_t>(Context::n_lvl0) *
        static_cast<std::uint64_t>(sample_per_tgsw_32) *
        static_cast<std::uint64_t>(k_plus_1) *
        static_cast<std::uint64_t>(N_lvl1);
    const std::uint64_t expected_bk_values_total =
        expected_bk_values_lvl2 + expected_bk_values_lvl1;
    const std::uint64_t bk_values =
        static_cast<std::uint64_t>(header.bk_fft_values);
    bool has_bk32 = false;
    if (bk_values == expected_bk_values_lvl2) {
      has_bk32 = false;
    } else if (bk_values == expected_bk_values_total) {
      has_bk32 = true;
    } else {
      std::ostringstream oss;
      oss << "keyset bk_fft size mismatch (expected "
          << expected_bk_values_lvl2 << " or " << expected_bk_values_total
          << ", got " << bk_values << ")";
      throw std::runtime_error(oss.str());
    }
    // Keyset bkFFT is stored as split real/imag halves (length N):
    //   [ Re[0..Ns2-1], Im[0..Ns2-1] ]
    // This matches the exporter (`export_keyset_if_requested`) and keeps the
    // on-disk layout independent of `double2` packing.
    std::vector<double> fft_split(static_cast<std::size_t>(N_lvl2));
    std::vector<double2> fft_complex(static_cast<std::size_t>(Ns2));
    std::vector<double2> fft_complex_perm(static_cast<std::size_t>(Ns2));
    const int bitrev_bits = 31 - __builtin_clz(static_cast<unsigned int>(Ns2));
    std::vector<int> bitrev_map(static_cast<std::size_t>(Ns2));
    for (int idx = 0; idx < Ns2; ++idx) {
      int r = 0;
      int v = idx;
      for (int b = 0; b < bitrev_bits; ++b) {
        r = (r << 1) | (v & 1);
        v >>= 1;
      }
      bitrev_map[static_cast<std::size_t>(idx)] = r;
    }
    const double fft_scale = parse_env_double("WOP_GPU_BKFFT_SCALE", 1.0);
    ifs.seekg(static_cast<std::streamoff>(header.offset_bk_fft), std::ios::beg);
    if (!ifs) {
      throw std::runtime_error("failed to seek bk_fft section");
    }
    for (int i = 0; i < Context::n_lvl0; ++i) {
      TLweSampleFFT<double2>* allsamples = ctx->bkFFT_64[i].allsamples;
      for (int p = 0; p < sample_per_tgsw; ++p) {
        TLweSampleFFT<double2>& sample = allsamples[p];
        for (int q = 0; q < k_plus_1; ++q) {
          LagrangeHalfCPolynomial<double2>& poly = sample.a[q];
          ifs.read(reinterpret_cast<char*>(fft_split.data()),
                   static_cast<std::streamsize>(fft_split.size() * sizeof(double)));
          if (!ifs) {
            throw std::runtime_error("failed to read bk_fft payload");
          }
          for (int idx = 0; idx < Ns2; ++idx) {
            fft_complex[idx].x = fft_scale * fft_split[idx];
            fft_complex[idx].y = fft_scale * fft_split[idx + Ns2];
          }
          for (int idx = 0; idx < Ns2; ++idx) {
            fft_complex_perm[idx] = fft_complex[bitrev_map[static_cast<std::size_t>(idx)]];
          }
          ensure_cuda_success(
              cudaMemcpy(poly.values,
                         fft_complex_perm.data(),
                         fft_complex_perm.size() * sizeof(double2),
                         cudaMemcpyHostToDevice),
              "import bk_fft");
          if (std::getenv("TFHE_GPU_CBS_DEBUG") != nullptr && i == 0 && p == 0 && q == 0) {
            std::cout << "[CB_GPU_DEBUG] bkFFT64[0][0][0][0..3]={";
            for (int idx = 0; idx < std::min<std::size_t>(4, fft_complex_perm.size()); ++idx) {
              std::cout << "(" << fft_complex_perm[idx].x << "," << fft_complex_perm[idx].y << ")";
              if (idx != std::min<std::size_t>(4, fft_complex_perm.size()) - 1) std::cout << ",";
            }
            std::cout << "}" << std::endl;
          }
        }
      }
    }
    if (has_bk32) {
      const int Ns2_32 = N_lvl1 / 2;
      std::vector<double> fft_split32(static_cast<std::size_t>(N_lvl1));
      std::vector<double2> fft_complex32(static_cast<std::size_t>(Ns2_32));
      std::vector<double2> fft_complex_perm32(static_cast<std::size_t>(Ns2_32));
      const int bitrev_bits32 = 31 - __builtin_clz(static_cast<unsigned int>(Ns2_32));
      std::vector<int> bitrev_map32(static_cast<std::size_t>(Ns2_32));
      for (int idx = 0; idx < Ns2_32; ++idx) {
        int r = 0;
        int v = idx;
        for (int b = 0; b < bitrev_bits32; ++b) {
          r = (r << 1) | (v & 1);
          v >>= 1;
        }
        bitrev_map32[static_cast<std::size_t>(idx)] = r;
      }
      for (int i = 0; i < Context::n_lvl0; ++i) {
        TLweSampleFFT<double2>* allsamples = ctx->bkFFT_32[i].allsamples;
        for (int p = 0; p < sample_per_tgsw_32; ++p) {
          TLweSampleFFT<double2>& sample = allsamples[p];
          for (int q = 0; q < k_plus_1; ++q) {
            LagrangeHalfCPolynomial<double2>& poly = sample.a[q];
            ifs.read(reinterpret_cast<char*>(fft_split32.data()),
                     static_cast<std::streamsize>(fft_split32.size() * sizeof(double)));
            if (!ifs) {
              throw std::runtime_error("failed to read bk_fft32 payload");
            }
            for (int idx = 0; idx < Ns2_32; ++idx) {
              fft_complex32[static_cast<std::size_t>(idx)].x =
                  fft_scale * fft_split32[static_cast<std::size_t>(idx)];
              fft_complex32[static_cast<std::size_t>(idx)].y =
                  fft_scale * fft_split32[static_cast<std::size_t>(idx + Ns2_32)];
            }
            for (int idx = 0; idx < Ns2_32; ++idx) {
              fft_complex_perm32[static_cast<std::size_t>(idx)] =
                  fft_complex32[bitrev_map32[static_cast<std::size_t>(idx)]];
            }
            ensure_cuda_success(
                cudaMemcpy(poly.values,
                           fft_complex_perm32.data(),
                           fft_complex_perm32.size() * sizeof(double2),
                           cudaMemcpyHostToDevice),
                "import bk_fft32");
          }
        }
      }
    } else {
      std::cerr << "[TFHE_GPU_EXEC][KEYSET] warning: bkFFT_32 missing; lvl1 ops may diverge\n";
    }
    std::cout << "[TFHE_GPU_EXEC][KEYSET] bkFFT loaded" << std::endl;
  }

  if ((header.flags & gpu_runtime::keyset::kSectionPrivKS) != 0) {
    std::cout << "[TFHE_GPU_EXEC][KEYSET] importing privKS" << std::endl;
    const int k_plus_1 = K + 1;
    const int priv_dim_z = k_plus_1;
    const int priv_dim_i = Context::n_lvl2 + 1;
    const int priv_dim_j = Context::kslength_lvl21;
    const int priv_dim_u = 1 << Context::ksbasebit_lvl21;
    const int N_lvl1 = Context::n_lvl1;
    std::vector<std::int32_t> priv_chunk(static_cast<std::size_t>(N_lvl1));
    ifs.seekg(static_cast<std::streamoff>(header.offset_privks), std::ios::beg);
    if (!ifs) {
      throw std::runtime_error("failed to seek privKS section");
    }
    for (int z = 0; z < priv_dim_z; ++z) {
      for (int i = 0; i < priv_dim_i; ++i) {
        for (int j = 0; j < priv_dim_j; ++j) {
          for (int u = 0; u < priv_dim_u; ++u) {
            TLweSample32& sample = ctx->privKS[z][i][j][u];
            for (int q = 0; q < k_plus_1; ++q) {
              ifs.read(reinterpret_cast<char*>(priv_chunk.data()),
                       static_cast<std::streamsize>(priv_chunk.size() * sizeof(std::int32_t)));
              if (!ifs) {
                throw std::runtime_error("failed to read privKS payload");
              }
              ensure_cuda_success(
                  cudaMemcpy(sample.a[q].coefs,
                             priv_chunk.data(),
                             priv_chunk.size() * sizeof(std::int32_t),
                             cudaMemcpyHostToDevice),
                  "import privKS");
            }
          }
        }
      }
    }
    std::cout << "[TFHE_GPU_EXEC][KEYSET] privKS loaded" << std::endl;
  }

  ensure_cuda_success(cudaDeviceSynchronize(), "keyset import sync");
  std::cout << "[TFHE_GPU_EXEC][KEYSET] imported keyset from " << import_path << std::endl;
  return true;
}

bool import_keyset_if_available(Context* ctx) {
  const char* env = std::getenv("WOP_GPU_KEY_IMPORT");
  if (env == nullptr || *env == '\0') {
    return false;
  }
  return import_keyset_from_path(ctx, std::filesystem::path(env), nullptr, nullptr);
}

void export_keyset_if_requested(Context* ctx);

std::optional<std::filesystem::path> ensure_keyset_for_cpu_compare(Context* ctx) {
  static std::optional<std::filesystem::path> cached;
  static bool attempted = false;
  if (cached) {
    return cached;
  }
  if (attempted || ctx == nullptr) {
    return std::nullopt;
  }
  attempted = true;
  std::filesystem::path export_path =
      std::filesystem::temp_directory_path() /
      ("wop_keyset_cpu_compare_" + std::to_string(getpid()) + ".bin");
  const char* old_export = std::getenv("WOP_GPU_KEY_EXPORT");
  const char* old_overwrite = std::getenv("WOP_GPU_KEY_EXPORT_OVERWRITE");
  std::string old_export_str = old_export != nullptr ? std::string(old_export) : std::string();
  std::string old_overwrite_str = old_overwrite != nullptr ? std::string(old_overwrite) : std::string();
  if (setenv("WOP_GPU_KEY_EXPORT", export_path.c_str(), 1) != 0) {
    std::cerr << "[TFHE_GPU_EXEC][KEYSET] cpu compare export failed to set WOP_GPU_KEY_EXPORT\n";
    return std::nullopt;
  }
  setenv("WOP_GPU_KEY_EXPORT_OVERWRITE", "1", 1);
  export_keyset_if_requested(ctx);
  if (!old_export_str.empty()) {
    setenv("WOP_GPU_KEY_EXPORT", old_export_str.c_str(), 1);
  } else {
    unsetenv("WOP_GPU_KEY_EXPORT");
  }
  if (!old_overwrite_str.empty()) {
    setenv("WOP_GPU_KEY_EXPORT_OVERWRITE", old_overwrite_str.c_str(), 1);
  } else {
    unsetenv("WOP_GPU_KEY_EXPORT_OVERWRITE");
  }
  if (!std::filesystem::exists(export_path)) {
    std::cerr << "[TFHE_GPU_EXEC][KEYSET] cpu compare export failed (missing file)\n";
    return std::nullopt;
  }
  cached = export_path;
  return cached;
}

std::optional<std::filesystem::path> resolve_keyset_path_for_compare(Context* ctx) {
  const char* keyset_env = std::getenv("WOP_GPU_KEY_IMPORT");
  if (keyset_env == nullptr || *keyset_env == '\0') {
    keyset_env = std::getenv("WOP_GPU_KEY_EXPORT");
  }
  if (keyset_env != nullptr && *keyset_env != '\0') {
    return std::filesystem::path(keyset_env);
  }
  return ensure_keyset_for_cpu_compare(ctx);
}

void export_keyset_if_requested(Context* ctx) {
  static bool exported = false;
  if (exported || ctx == nullptr) {
    return;
  }
  std::filesystem::path export_path;
  if (!is_key_export_requested(export_path)) {
    return;
  }
  exported = true;
  std::error_code exists_ec;
  if (std::filesystem::exists(export_path, exists_ec) &&
      !env_flag_enabled("WOP_GPU_KEY_EXPORT_OVERWRITE")) {
    std::cout << "[TFHE_GPU_EXEC][KEYSET] export skipped (exists): " << export_path
              << " (set WOP_GPU_KEY_EXPORT_OVERWRITE=1 to overwrite)\n";
    return;
  }
  try {
    ensure_cuda_success(cudaDeviceSynchronize(), "keyset export sync");

    const std::size_t key_lvl0_words = static_cast<std::size_t>(Context::n_lvl0);
    const std::size_t key_lvl1_words = static_cast<std::size_t>(Context::n_lvl1);
    const std::size_t key_lvl2_words = static_cast<std::size_t>(Context::n_lvl2) + 1;

    std::vector<std::int32_t> key_lvl0 = copy_device_int_vector(ctx->key_lvl0, key_lvl0_words);
    std::vector<std::int32_t> key_lvl1 = copy_device_int_vector(ctx->key_lvl1, key_lvl1_words);
    std::vector<std::int32_t> key_lvl2 = copy_device_int_vector(ctx->key_lvl2, key_lvl2_words);

    gpu_runtime::keyset::Header header{};
    std::memcpy(header.magic, gpu_runtime::keyset::kMagic.data(), gpu_runtime::keyset::kMagic.size());
    header.version = gpu_runtime::keyset::kVersion;
    header.glwe_dimension = static_cast<std::uint32_t>(K);
    header.n_lvl0 = static_cast<std::uint32_t>(Context::n_lvl0);
    header.n_lvl1 = static_cast<std::uint32_t>(Context::n_lvl1);
    header.n_lvl2 = static_cast<std::uint32_t>(Context::n_lvl2);
    header.ell_lvl2 = static_cast<std::uint32_t>(Context::ell_lvl2);
    header.ks_length_lvl21 = static_cast<std::uint32_t>(Context::kslength_lvl21);
    header.ks_basebit_lvl21 = static_cast<std::uint32_t>(Context::ksbasebit_lvl21);

    if (!export_path.parent_path().empty()) {
      std::filesystem::create_directories(export_path.parent_path());
    }

    std::ofstream ofs(export_path, std::ios::binary | std::ios::trunc);
    if (!ofs) {
      throw std::runtime_error("failed to open keyset file for writing: " + export_path.string());
    }

    ofs.write(reinterpret_cast<const char*>(&header), sizeof(header));  // placeholder
    header.kslength_lvl10 = static_cast<std::uint32_t>(Context::kslength_lvl10);
    header.ksbasebit_lvl10 = static_cast<std::uint32_t>(Context::ksbasebit_lvl10);
    header.kslength_lvl10_gpbs = static_cast<std::uint32_t>(Context::kslength_lvl10_gpbs);
    header.ksbasebit_lvl10_gpbs = static_cast<std::uint32_t>(Context::ksbasebit_lvl10_gpbs);

    header.flags |= gpu_runtime::keyset::kSectionSecretKeys;
    header.offset_key_lvl0 = static_cast<std::uint64_t>(ofs.tellp());
    ofs.write(reinterpret_cast<const char*>(key_lvl0.data()),
              static_cast<std::streamsize>(key_lvl0.size() * sizeof(std::int32_t)));
    header.key_lvl0_words = static_cast<std::uint32_t>(key_lvl0.size());

    header.offset_key_lvl1 = static_cast<std::uint64_t>(ofs.tellp());
    ofs.write(reinterpret_cast<const char*>(key_lvl1.data()),
              static_cast<std::streamsize>(key_lvl1.size() * sizeof(std::int32_t)));
    header.key_lvl1_words = static_cast<std::uint32_t>(key_lvl1.size());

    header.offset_key_lvl2 = static_cast<std::uint64_t>(ofs.tellp());
    ofs.write(reinterpret_cast<const char*>(key_lvl2.data()),
              static_cast<std::streamsize>(key_lvl2.size() * sizeof(std::int32_t)));
    header.key_lvl2_words = static_cast<std::uint32_t>(key_lvl2.size());

    const std::size_t lwe_words = static_cast<std::size_t>(Context::n_lvl0) + 1;
    std::vector<std::int32_t> lwe_buffer(lwe_words);

    const std::size_t preks_lvl10_samples =
        static_cast<std::size_t>(Context::n_lvl1) *
        static_cast<std::size_t>(Context::kslength_lvl10) *
        static_cast<std::size_t>(1u << Context::ksbasebit_lvl10);
    if (preks_lvl10_samples > 0) {
      header.flags |= gpu_runtime::keyset::kSectionPreKS;
      header.offset_preks_lvl10 = static_cast<std::uint64_t>(ofs.tellp());
      for (int i = 0; i < Context::n_lvl1; ++i) {
        for (int j = 0; j < Context::kslength_lvl10; ++j) {
          const int base = 1 << Context::ksbasebit_lvl10;
          for (int u = 0; u < base; ++u) {
            LweSample32& sample = ctx->preKS[i][j][u];
            ensure_cuda_success(
                cudaMemcpy(lwe_buffer.data(),
                           sample.a,
                           lwe_words * sizeof(std::int32_t),
                           cudaMemcpyDeviceToHost),
                "copy preKS lvl10");
            ofs.write(reinterpret_cast<const char*>(lwe_buffer.data()),
                      static_cast<std::streamsize>(lwe_words * sizeof(std::int32_t)));
          }
        }
      }
      header.preks_lvl10_samples = static_cast<std::uint32_t>(preks_lvl10_samples);
      header.preks_lvl10_words = static_cast<std::uint32_t>(lwe_words);
    }

    const std::size_t preks_lvl10_gpbs_samples =
        static_cast<std::size_t>(Context::n_lvl1) *
        static_cast<std::size_t>(Context::kslength_lvl10_gpbs) *
        static_cast<std::size_t>(1u << Context::ksbasebit_lvl10_gpbs);
    if (preks_lvl10_gpbs_samples > 0) {
      header.flags |= gpu_runtime::keyset::kSectionPreKS;
      header.offset_preks_lvl10_gpbs = static_cast<std::uint64_t>(ofs.tellp());
      for (int i = 0; i < Context::n_lvl1; ++i) {
        for (int j = 0; j < Context::kslength_lvl10_gpbs; ++j) {
          const int base = 1 << Context::ksbasebit_lvl10_gpbs;
          for (int u = 0; u < base; ++u) {
            LweSample32& sample = ctx->preKS_gpbs[i][j][u];
            ensure_cuda_success(
                cudaMemcpy(lwe_buffer.data(),
                           sample.a,
                           lwe_words * sizeof(std::int32_t),
                           cudaMemcpyDeviceToHost),
                "copy preKS lvl10 gpbs");
            ofs.write(reinterpret_cast<const char*>(lwe_buffer.data()),
                      static_cast<std::streamsize>(lwe_words * sizeof(std::int32_t)));
          }
        }
      }
      header.preks_lvl10_gpbs_samples = static_cast<std::uint32_t>(preks_lvl10_gpbs_samples);
      header.preks_lvl10_gpbs_words = static_cast<std::uint32_t>(lwe_words);
    }

    const int k_plus_1 = K + 1;
    const int sample_per_tgsw = Context::ell_lvl2 * k_plus_1;
    const int N_lvl2 = Context::n_lvl2;
    const int Ns2 = N_lvl2 / 2;
    std::vector<double2> fft_complex(static_cast<std::size_t>(Ns2));
    std::vector<double> fft_real(static_cast<std::size_t>(N_lvl2));
    const int bitrev_bits = 31 - __builtin_clz(static_cast<unsigned int>(Ns2));
    std::vector<int> bitrev_map(static_cast<std::size_t>(Ns2));
    for (int idx = 0; idx < Ns2; ++idx) {
      int r = 0;
      int v = idx;
      for (int b = 0; b < bitrev_bits; ++b) {
        r = (r << 1) | (v & 1);
        v >>= 1;
      }
      bitrev_map[static_cast<std::size_t>(idx)] = r;
    }
    std::uint64_t bk_fft_values = 0;

    header.flags |= gpu_runtime::keyset::kSectionBootstrappingKeys;
    header.offset_bk_fft = static_cast<std::uint64_t>(ofs.tellp());
    for (int i = 0; i < Context::n_lvl0; ++i) {
      TLweSampleFFT<double2>* allsamples = ctx->bkFFT_64[i].allsamples;
      for (int p = 0; p < sample_per_tgsw; ++p) {
        TLweSampleFFT<double2>& sample = allsamples[p];
        for (int q = 0; q < k_plus_1; ++q) {
          const LagrangeHalfCPolynomial<double2>& poly = sample.a[q];
          ensure_cuda_success(
              cudaMemcpy(fft_complex.data(),
                         poly.values,
                         fft_complex.size() * sizeof(double2),
                         cudaMemcpyDeviceToHost),
              "copy bkFFT polynomial");
          for (int idx = 0; idx < Ns2; ++idx) {
            const double2 v = fft_complex[bitrev_map[static_cast<std::size_t>(idx)]];
            fft_real[idx] = v.x;
            fft_real[idx + Ns2] = v.y;
          }
          ofs.write(reinterpret_cast<const char*>(fft_real.data()),
                    static_cast<std::streamsize>(fft_real.size() * sizeof(double)));
          bk_fft_values += fft_real.size();
        }
      }
    }
    {
      const int sample_per_tgsw_32 = Context::ell_lvl1_gpbs * k_plus_1;
      const int N_lvl1 = Context::n_lvl1;
      const int Ns2_32 = N_lvl1 / 2;
      std::vector<double2> fft_complex32(static_cast<std::size_t>(Ns2_32));
      std::vector<double> fft_real32(static_cast<std::size_t>(N_lvl1));
      const int bitrev_bits32 = 31 - __builtin_clz(static_cast<unsigned int>(Ns2_32));
      std::vector<int> bitrev_map32(static_cast<std::size_t>(Ns2_32));
      for (int idx = 0; idx < Ns2_32; ++idx) {
        int r = 0;
        int v = idx;
        for (int b = 0; b < bitrev_bits32; ++b) {
          r = (r << 1) | (v & 1);
          v >>= 1;
        }
        bitrev_map32[static_cast<std::size_t>(idx)] = r;
      }
      for (int i = 0; i < Context::n_lvl0; ++i) {
        TLweSampleFFT<double2>* allsamples = ctx->bkFFT_32[i].allsamples;
        for (int p = 0; p < sample_per_tgsw_32; ++p) {
          TLweSampleFFT<double2>& sample = allsamples[p];
          for (int q = 0; q < k_plus_1; ++q) {
            const LagrangeHalfCPolynomial<double2>& poly = sample.a[q];
            ensure_cuda_success(
                cudaMemcpy(fft_complex32.data(),
                           poly.values,
                           fft_complex32.size() * sizeof(double2),
                           cudaMemcpyDeviceToHost),
                "copy bkFFT32 polynomial");
            for (int idx = 0; idx < Ns2_32; ++idx) {
              const double2 v = fft_complex32[bitrev_map32[static_cast<std::size_t>(idx)]];
              fft_real32[static_cast<std::size_t>(idx)] = v.x;
              fft_real32[static_cast<std::size_t>(idx + Ns2_32)] = v.y;
            }
            ofs.write(reinterpret_cast<const char*>(fft_real32.data()),
                      static_cast<std::streamsize>(fft_real32.size() * sizeof(double)));
            bk_fft_values += fft_real32.size();
          }
        }
      }
    }
    header.bk_fft_values = static_cast<std::uint32_t>(bk_fft_values);

    const int priv_dim_z = k_plus_1;
    const int priv_dim_i = Context::n_lvl2 + 1;
    const int priv_dim_j = Context::kslength_lvl21;
    const int priv_dim_u = 1 << Context::ksbasebit_lvl21;
    const int N_lvl1 = Context::n_lvl1;
    std::vector<std::int32_t> priv_chunk(static_cast<std::size_t>(N_lvl1));
    std::uint64_t priv_values = 0;
    std::uint64_t priv_samples = 0;

    header.flags |= gpu_runtime::keyset::kSectionPrivKS;
    header.offset_privks = static_cast<std::uint64_t>(ofs.tellp());
    for (int z = 0; z < priv_dim_z; ++z) {
      for (int i = 0; i < priv_dim_i; ++i) {
        for (int j = 0; j < priv_dim_j; ++j) {
          for (int u = 0; u < priv_dim_u; ++u) {
            TLweSample32& sample = ctx->privKS[z][i][j][u];
            for (int q = 0; q < k_plus_1; ++q) {
              ensure_cuda_success(
                  cudaMemcpy(priv_chunk.data(),
                             sample.a[q].coefs,
                             priv_chunk.size() * sizeof(std::int32_t),
                             cudaMemcpyDeviceToHost),
                  "copy privKS polynomial");
              ofs.write(reinterpret_cast<const char*>(priv_chunk.data()),
                        static_cast<std::streamsize>(priv_chunk.size() * sizeof(std::int32_t)));
              priv_values += priv_chunk.size();
            }
            priv_samples += 1;
          }
        }
      }
    }
    header.privks_values = static_cast<std::uint32_t>(priv_values);
    header.privks_samples = static_cast<std::uint32_t>(priv_samples);

    if (!ofs) {
      throw std::runtime_error("failed to write keyset payload to " + export_path.string());
    }

    ofs.seekp(0, std::ios::beg);
    ofs.write(reinterpret_cast<const char*>(&header), sizeof(header));
    ofs.flush();

    std::uintmax_t file_size = 0;
    std::error_code ec;
    if (std::filesystem::exists(export_path, ec)) {
      file_size = std::filesystem::file_size(export_path, ec);
    }
    std::cout << "[TFHE_GPU_EXEC][KEYSET] exported keyset to " << export_path
              << " (secret=" << header.key_lvl0_words + header.key_lvl1_words + header.key_lvl2_words
              << " words, bk_fft_values=" << header.bk_fft_values
              << ", privks_values=" << header.privks_values
              << ", bytes=" << file_size << ")\n";
  } catch (const std::exception& ex) {
    std::cerr << "[TFHE_GPU_EXEC][KEYSET] export failed: " << ex.what() << std::endl;
  }
}

Context* create_context() {
  auto* ctx = new Context();
  ctx->secret_keygen();
  ctx->cloud_keygen();
  import_keyset_if_available(ctx);
  export_keyset_if_requested(ctx);
  return ctx;
}

}  // namespace

bool TfheGpuExecutor::import_keyset_from_dram() {
  if (force_stub_ || ctx_ == nullptr) {
    return false;
  }
  if (keyset_loaded_from_dram_) {
    return true;
  }
  if (!dram_image_ || layout_by_name_.empty()) {
    return false;
  }

  try {
    const char* split_luts_env = std::getenv("WOP_GPU_KSPBS_SPLIT_LUTS");
    const bool want_kspbs_split =
        env_flag_enabled("WOP_GPU_KSPBS_SPLIT") ||
        (split_luts_env != nullptr && *split_luts_env != '\0');
    ctx_->preks_host = {};
    ctx_->preks_host_gpbs = {};
    g_preks_host_gpbs.clear();

    auto read_section = [&](const std::string& name,
                            std::vector<std::uint8_t>& buffer) -> bool {
      auto it = layout_by_name_.find(name);
      if (it == layout_by_name_.end()) {
        return false;
      }
      const auto& entry = it->second;
      if (entry.bytes == 0) {
        buffer.clear();
        return true;
      }
      if (entry.bytes >
          static_cast<std::uint64_t>(std::numeric_limits<std::size_t>::max())) {
        throw std::runtime_error("layout section '" + name + "' too large");
      }
      buffer.resize(static_cast<std::size_t>(entry.bytes));
      if (!dram_image_->read_into(
              entry.base,
              std::span<std::uint8_t>(buffer.data(), buffer.size()))) {
        throw std::runtime_error("failed to read section '" + name + "' from DRAM image");
      }
      return true;
    };

    const std::size_t key_lvl0_words = static_cast<std::size_t>(Context::n_lvl0);
    const std::size_t key_lvl1_words = static_cast<std::size_t>(Context::n_lvl1);
    const std::size_t key_lvl2_words = static_cast<std::size_t>(Context::n_lvl2) + 1;

    std::vector<std::uint8_t> raw_lvl0;
    if (!read_section("secret_lvl0", raw_lvl0)) {
      throw std::runtime_error("DRAM image missing section 'secret_lvl0'");
    }
    if (raw_lvl0.size() != key_lvl0_words * sizeof(std::int32_t)) {
      throw std::runtime_error("secret_lvl0 size mismatch in DRAM image");
    }
    std::vector<std::int32_t> key_lvl0(key_lvl0_words);
    std::memcpy(key_lvl0.data(), raw_lvl0.data(), raw_lvl0.size());
    copy_int_vector_to_device(ctx_->key_lvl0, key_lvl0, "dram key_lvl0");

    std::vector<std::uint8_t> raw_lvl1;
    if (!read_section("secret_lvl1", raw_lvl1)) {
      throw std::runtime_error("DRAM image missing section 'secret_lvl1'");
    }
    if (raw_lvl1.size() != key_lvl1_words * sizeof(std::int32_t)) {
      throw std::runtime_error("secret_lvl1 size mismatch in DRAM image");
    }
    std::vector<std::int32_t> key_lvl1(key_lvl1_words);
    std::memcpy(key_lvl1.data(), raw_lvl1.data(), raw_lvl1.size());
    copy_int_vector_to_device(ctx_->key_lvl1, key_lvl1, "dram key_lvl1");
    if (ctx_->Key_lvl1 != nullptr) {
      ensure_cuda_success(
          cudaMemcpy(ctx_->Key_lvl1->coefs,
                     key_lvl1.data(),
                     key_lvl1.size() * sizeof(std::int32_t),
                     cudaMemcpyHostToDevice),
          "dram key_lvl1 poly");
    }

    std::vector<std::uint8_t> raw_lvl2;
    if (!read_section("secret_lvl2", raw_lvl2)) {
      throw std::runtime_error("DRAM image missing section 'secret_lvl2'");
    }
    if (raw_lvl2.size() != key_lvl2_words * sizeof(std::int32_t)) {
      throw std::runtime_error("secret_lvl2 size mismatch in DRAM image");
    }
    std::vector<std::int32_t> key_lvl2(key_lvl2_words);
    std::memcpy(key_lvl2.data(), raw_lvl2.data(), raw_lvl2.size());
    copy_int_vector_to_device(ctx_->key_lvl2, key_lvl2, "dram key_lvl2");
    if (ctx_->Key_lvl2 != nullptr) {
      ensure_cuda_success(
          cudaMemcpy(ctx_->Key_lvl2->coefs,
                     key_lvl2.data(),
                     Context::n_lvl2 * sizeof(int),
                     cudaMemcpyHostToDevice),
          "dram key_lvl2 poly");
    }

    auto import_preks_from_buffer =
        [&](const std::vector<std::uint8_t>& buffer,
            LweSample32*** target,
            int kslength,
            int ksbasebit,
            const char* label,
            std::vector<std::int32_t>* host_flat) {
          if (target == nullptr || buffer.empty()) {
            return;
          }
          const int base = 1 << ksbasebit;
          const std::size_t words = static_cast<std::size_t>(Context::n_lvl0) + 1;
          const std::size_t expected_samples =
              static_cast<std::size_t>(Context::n_lvl1) *
              static_cast<std::size_t>(kslength) *
              static_cast<std::size_t>(base);
          const std::size_t expected_total = expected_samples * words;
          if (buffer.size() != expected_total * sizeof(std::int32_t)) {
            throw std::runtime_error(std::string(label) + " size mismatch in DRAM image");
          }
          std::vector<std::int32_t> local_flat;
          const std::int32_t* flat_ptr = nullptr;
          if (host_flat != nullptr) {
            host_flat->resize(expected_total);
            std::memcpy(host_flat->data(), buffer.data(), buffer.size());
            flat_ptr = host_flat->data();
          } else {
            local_flat.resize(expected_total);
            std::memcpy(local_flat.data(), buffer.data(), buffer.size());
            flat_ptr = local_flat.data();
          }
          for (int i = 0; i < Context::n_lvl1; ++i) {
            for (int j = 0; j < kslength; ++j) {
              for (int u = 0; u < base; ++u) {
                const std::size_t idx =
                    ((static_cast<std::size_t>(i) * kslength + j) * base + u) * words;
                const std::int32_t* src = flat_ptr + idx;
                ensure_cuda_success(
                    cudaMemcpy(target[i][j][u].a,
                               src,
                               words * sizeof(std::int32_t),
                               cudaMemcpyHostToDevice),
                    label);
              }
            }
          }
        };

    std::vector<std::uint8_t> raw_preks;
    if (read_section("preks_lvl10", raw_preks) && !raw_preks.empty()) {
      import_preks_from_buffer(raw_preks,
                               ctx_->preKS,
                               Context::kslength_lvl10,
                               Context::ksbasebit_lvl10,
                               "dram preKS lvl10",
                               nullptr);
    }

    std::vector<std::uint8_t> raw_preks_gpbs;
    if (read_section("preks_lvl10_gpbs", raw_preks_gpbs) && !raw_preks_gpbs.empty()) {
      import_preks_from_buffer(raw_preks_gpbs,
                               ctx_->preKS_gpbs,
                               Context::kslength_lvl10_gpbs,
                               Context::ksbasebit_lvl10_gpbs,
                               "dram preKS lvl10 gpbs",
                               want_kspbs_split ? &g_preks_host_gpbs : nullptr);
    }
    if (want_kspbs_split && !g_preks_host_gpbs.empty()) {
      ctx_->preks_host_gpbs.flat = g_preks_host_gpbs.data();
      ctx_->preks_host_gpbs.n0 = Context::n_lvl0;
      ctx_->preks_host_gpbs.n1 = Context::n_lvl1;
      ctx_->preks_host_gpbs.kslen = Context::kslength_lvl10_gpbs;
      ctx_->preks_host_gpbs.basebit = Context::ksbasebit_lvl10_gpbs;
      ctx_->preks_host_gpbs.base = 1 << Context::ksbasebit_lvl10_gpbs;
      ctx_->preks_host_gpbs.words = static_cast<int>(Context::n_lvl0) + 1;
      std::cout << "[TFHE_GPU_EXEC][KEYSET] host preKS gpbs loaded for KSPBS split (DRAM)"
                << std::endl;
    }

    std::vector<std::uint8_t> raw_bk_fft;
    if (!read_section("bk_fft", raw_bk_fft)) {
      throw std::runtime_error("DRAM image missing section 'bk_fft'");
    }
    if (raw_bk_fft.size() % sizeof(double) != 0) {
      throw std::runtime_error("bk_fft payload is not aligned to double");
    }
    const int k_plus_1 = K + 1;
    const int sample_per_tgsw = Context::ell_lvl2 * k_plus_1;
    const int N_lvl2 = Context::n_lvl2;
    const int Ns2 = N_lvl2 / 2;
    std::vector<double> fft_r2hc(static_cast<std::size_t>(N_lvl2));
    std::vector<double2> fft_complex(static_cast<std::size_t>(Ns2));
    const double fft_scale = parse_env_double("WOP_GPU_BKFFT_SCALE", 1.0);
    const int imag_sign = parse_env_int("WOP_GPU_BKFFT_IMAG_SIGN", -1);
    const std::uint8_t* bk_ptr = raw_bk_fft.data();
    const std::uint8_t* bk_end = raw_bk_fft.data() + raw_bk_fft.size();
    for (int i = 0; i < Context::n_lvl0; ++i) {
      TLweSampleFFT<double2>* allsamples = ctx_->bkFFT_64[i].allsamples;
      for (int p = 0; p < sample_per_tgsw; ++p) {
        TLweSampleFFT<double2>& sample = allsamples[p];
        for (int q = 0; q < k_plus_1; ++q) {
          if (bk_ptr + fft_r2hc.size() * sizeof(double) > bk_end) {
            throw std::runtime_error("bk_fft buffer underrun");
          }
          std::memcpy(fft_r2hc.data(), bk_ptr, fft_r2hc.size() * sizeof(double));
          bk_ptr += fft_r2hc.size() * sizeof(double);
          // convert FFTW r2hc -> complex array compatible with cuFFT
          fft_complex[0].x = fft_scale * fft_r2hc[0];
          fft_complex[0].y = 0.0;
          if (Ns2 > 1) {
            fft_complex[Ns2 - 1].x = fft_scale * fft_r2hc[Ns2];
            fft_complex[Ns2 - 1].y = 0.0;
          }
          for (int k = 1; k < Ns2 - 1; ++k) {
            fft_complex[k].x = fft_scale * fft_r2hc[k];
            fft_complex[k].y = fft_scale * imag_sign * fft_r2hc[N_lvl2 - k];
          }
          ensure_cuda_success(
              cudaMemcpy(sample.a[q].values,
                         fft_complex.data(),
                         fft_complex.size() * sizeof(double2),
                         cudaMemcpyHostToDevice),
              "dram bk_fft");
        }
      }
    }

    std::vector<std::uint8_t> raw_privks;
    if (!read_section("privks", raw_privks)) {
      throw std::runtime_error("DRAM image missing section 'privks'");
    }
    if (raw_privks.size() % sizeof(std::int32_t) != 0) {
      throw std::runtime_error("privks payload is not aligned to int32");
    }
    const int priv_dim_z = k_plus_1;
    const int priv_dim_i = Context::n_lvl2 + 1;
    const int priv_dim_j = Context::kslength_lvl21;
    const int priv_dim_u = 1 << Context::ksbasebit_lvl21;
    const int N_lvl1 = Context::n_lvl1;
    std::vector<std::int32_t> priv_chunk(static_cast<std::size_t>(N_lvl1));
    const std::uint8_t* pk_ptr = raw_privks.data();
    const std::uint8_t* pk_end = raw_privks.data() + raw_privks.size();
    for (int z = 0; z < priv_dim_z; ++z) {
      for (int i = 0; i < priv_dim_i; ++i) {
        for (int j = 0; j < priv_dim_j; ++j) {
          for (int u = 0; u < priv_dim_u; ++u) {
            TLweSample32& sample = ctx_->privKS[z][i][j][u];
            for (int q = 0; q < k_plus_1; ++q) {
              if (pk_ptr + priv_chunk.size() * sizeof(std::int32_t) > pk_end) {
                throw std::runtime_error("privks buffer underrun");
              }
              std::memcpy(priv_chunk.data(),
                          pk_ptr,
                          priv_chunk.size() * sizeof(std::int32_t));
              pk_ptr += priv_chunk.size() * sizeof(std::int32_t);
              ensure_cuda_success(
                  cudaMemcpy(sample.a[q].coefs,
                             priv_chunk.data(),
                             priv_chunk.size() * sizeof(std::int32_t),
                             cudaMemcpyHostToDevice),
                  "dram privKS");
            }
          }
        }
      }
    }

    ensure_cuda_success(cudaDeviceSynchronize(), "keyset dram import sync");
    keyset_loaded_from_dram_ = true;
    std::cout << "[TFHE_GPU_EXEC][DRAM] keyset imported from image (sections="
              << layout_by_name_.size() << ")" << std::endl;
    return true;
  } catch (const std::exception& ex) {
    std::cerr << "[TFHE_GPU_EXEC][DRAM] keyset import failed: " << ex.what() << std::endl;
    return false;
  }
}

TfheGpuExecutor::TfheGpuExecutor() {
  maybe_enable_spqlios_defaults();
  force_stub_ = env_flag_enabled("WOP_GPU_FORCE_STUB");
  perf_mode_ = env_flag_enabled("WOP_GPU_PERF_MODE") || env_flag_enabled("WOP_GPU_PERF");
  perf_multistream_ = perf_mode_ || env_flag_enabled("WOP_GPU_PERF_MULTISTREAM");
  if (force_stub_) {
    std::cout << "[TFHE_GPU_EXEC][STUB] WOP_GPU_FORCE_STUB=1 → GPU kernels disabled (stub mode)"
              << std::endl;
  } else {
    ctx_.reset(create_context());
  }
  std::cout << "[TFHE_GPU_EXEC][FP] total_bits=" << NUM_TOTAL_BITS
            << " int_bits=" << NUM_INT_BITS
            << " frac_bits=" << NUM_FRAC_BITS
            << " radix_bits=" << MSG_BITS
            << " digits=" << NUM_TOTAL_SIZE
            << std::endl;
  keyset_variants_ = load_keyset_variants_env();
  if (!keyset_variants_.empty()) {
    std::cout << "[TFHE_GPU_EXEC][KEYSET] variants loaded: "
              << keyset_variants_.size() << std::endl;
    const char* env_id = std::getenv("WOP_GPU_VARIANT_ID");
    const char* env_key = std::getenv("WOP_GPU_KEY_IMPORT");
    if (env_id != nullptr && *env_id != '\0' && env_key != nullptr && *env_key != '\0') {
      int parsed_id = -1;
      if (parse_int32(std::string(env_id), &parsed_id) && parsed_id >= 0) {
        active_variant_id_ = parsed_id;
        active_keyset_path_ = std::filesystem::path(env_key);
      }
    }
  }
  if (const char* layout_env = std::getenv("WOP_GPU_KEY_LAYOUT");
      layout_env != nullptr && *layout_env != '\0') {
    try {
      auto entries = gpu_runtime::keyset_tools::load_layout_file(layout_env);
      for (const auto& entry : entries) {
        layout_by_base_.emplace(entry.base, entry);
        layout_by_name_.emplace(entry.name, entry);
      }
      std::cout << "[TFHE_GPU_EXEC][LAYOUT] loaded " << layout_by_base_.size()
                << " entries from " << layout_env << std::endl;
    } catch (const std::exception& ex) {
      std::cerr << "[TFHE_GPU_EXEC][LAYOUT] failed to load layout: " << ex.what() << std::endl;
    }
  }
  const char* dram_image_env = std::getenv("WOP_GPU_DRAM_IMAGE");
  if (dram_image_env != nullptr && *dram_image_env != '\0') {
    try {
      const std::uint64_t dram_base = parse_env_u64("WOP_GPU_DRAM_BASE", 0);
      dram_image_ = std::make_unique<DramImage>(std::filesystem::path(dram_image_env), dram_base);
      std::cout << "[TFHE_GPU_EXEC][DRAM] mapped " << dram_image_->size_bytes()
                << " bytes from " << dram_image_->path()
                << " (base=0x" << std::hex << dram_image_->base_addr() << std::dec << ")\n";
    } catch (const std::exception& ex) {
      std::cerr << "[TFHE_GPU_EXEC][DRAM] failed to map image: " << ex.what() << std::endl;
    }
  }
  if (dram_image_ && !layout_by_name_.empty()) {
    import_keyset_from_dram();
  }
  if (dram_image_ && kVerifyDramTlwe) {
    std::cout << "[TFHE_GPU_EXEC][DRAM] TLWE payload verification enabled" << std::endl;
  }
  if (!force_stub_) {
    const std::size_t stream_count = determine_stream_count();
    streams_.reserve(stream_count);
    stream_available_.reserve(stream_count);
    for (std::size_t idx = 0; idx < stream_count; ++idx) {
      cudaStream_t stream = nullptr;
      ensure_cuda_success(
          cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking),
          "cudaStreamCreateWithFlags");
      streams_.push_back(stream);
      stream_available_.push_back(true);
    }
    std::cout << "[TFHE_GPU_EXEC] initialised "
              << streams_.size() << " CUDA stream(s)" << std::endl;
    if (perf_mode_) {
      std::cout << "[TFHE_GPU_EXEC][PERF] perf_mode enabled (multistream="
                << (perf_multistream_ ? "1" : "0")
                << ")" << std::endl;
    }
  } else {
    std::cout << "[TFHE_GPU_EXEC] stub mode active (no CUDA streams initialised)" << std::endl;
  }
}

TfheGpuExecutor::~TfheGpuExecutor() {
  for (cudaStream_t stream : streams_) {
    if (stream != nullptr) {
      const cudaError_t status = cudaStreamDestroy(stream);
      if (status != cudaSuccess) {
        std::cerr << "[TFHE_GPU_EXEC] warning: cudaStreamDestroy failed: "
                  << cudaGetErrorString(status) << std::endl;
      }
    }
  }
}

cudaStream_t TfheGpuExecutor::acquire_stream() {
  if (force_stub_ || streams_.empty()) {
    return nullptr;
  }

  std::unique_lock<std::mutex> lock(stream_mutex_);
  stream_cv_.wait(lock, [this] {
    for (bool available : stream_available_) {
      if (available) {
        return true;
      }
    }
    return false;
  });

  for (std::size_t idx = 0; idx < stream_available_.size(); ++idx) {
    if (stream_available_[idx]) {
      stream_available_[idx] = false;
      return streams_[idx];
    }
  }
  return nullptr;
}

void TfheGpuExecutor::release_stream(cudaStream_t stream) {
  if (force_stub_ || stream == nullptr) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(stream_mutex_);
    for (std::size_t idx = 0; idx < streams_.size(); ++idx) {
      if (streams_[idx] == stream) {
        stream_available_[idx] = true;
        break;
      }
    }
  }
  stream_cv_.notify_one();
}

bool TfheGpuExecutor::ensure_keyset_variant(const gpu_runtime::ipc::SubmitRequest& request) {
  if (force_stub_ || ctx_ == nullptr || keyset_variants_.empty()) {
    return false;
  }
  if (keyset_loaded_from_dram_) {
    return false;
  }

  int desired_id = -1;
  if (request.descriptor.reserved != 0) {
    desired_id = static_cast<int>(request.descriptor.reserved);
  }
  if (desired_id < 0) {
    const char* env_id = std::getenv("WOP_GPU_VARIANT_ID");
    if (env_id != nullptr && *env_id != '\0') {
      int parsed = -1;
      if (parse_int32(std::string(env_id), &parsed) && parsed >= 0) {
        desired_id = parsed;
      }
    }
  }
  if (desired_id < 0 && keyset_variants_.size() == 1) {
    desired_id = keyset_variants_.begin()->first;
  }
  if (desired_id < 0) {
    return false;
  }

  auto it = keyset_variants_.find(desired_id);
  if (it == keyset_variants_.end()) {
    std::cerr << "[TFHE_GPU_EXEC][KEYSET] variant id " << desired_id
              << " not found; keep current keyset" << std::endl;
    return false;
  }
  const std::filesystem::path& import_path = it->second;
  if (active_variant_id_ == desired_id && !active_keyset_path_.empty() &&
      active_keyset_path_ == import_path) {
    return true;
  }

  const std::string id_str = std::to_string(desired_id);
  import_keyset_from_path(ctx_.get(), import_path, nullptr, id_str.c_str());
  active_variant_id_ = desired_id;
  active_keyset_path_ = import_path;
  return true;
}

gpu_runtime::ipc::SubmitResponse TfheGpuExecutor::process(
    const gpu_runtime::ipc::SubmitRequest& request,
    std::span<const std::uint8_t> tlwe_payload,
    std::vector<std::uint8_t>& glwe_payload) {
  std::cout << "[TFHE_GPU_EXEC][REQ] cmd_id=" << request.descriptor.cmd_id
            << " mode=" << static_cast<int>(request.descriptor.mode)
            << " tlwe_words=" << request.descriptor.tlwe_words
            << " tlwe_bytes=" << request.tlwe_bytes
            << " payload_bytes=" << tlwe_payload.size()
            << " glwe_words=" << request.descriptor.glwe_words;
  if (request.descriptor.reserved != 0) {
    std::cout << " variant_id=" << request.descriptor.reserved;
  }
  std::cout << std::endl;

  std::unique_lock<std::mutex> keyset_lock;
  if (!keyset_variants_.empty()) {
    keyset_lock = std::unique_lock<std::mutex>(keyset_mutex_);
    ensure_keyset_variant(request);
  }
  if (request.descriptor.mode == gpu_runtime::ipc::kDescriptorModeVerticalPacking) {
    const std::size_t expect_vp_words =
        (static_cast<std::size_t>(Context::n_lvl1) + 1u) * 20u;  // 20×lvl1 TLWE
    const std::size_t expect_be_words = static_cast<std::size_t>(Context::n_lvl0) + 1u;
    if (request.descriptor.tlwe_words != expect_vp_words &&
        request.descriptor.tlwe_words != expect_be_words) {
      std::cerr << "[TFHE_GPU_EXEC][ERR] VP tlwe_words unexpected: "
                << request.descriptor.tlwe_words << " (expect "
                << expect_vp_words << " or " << expect_be_words << ")" << std::endl;
    }
    const std::size_t tlwe_words = static_cast<std::size_t>(request.descriptor.tlwe_words);
    if (tlwe_words == 0) {
      std::cerr << "[TFHE_GPU_EXEC][ERR] VP tlwe_words is 0" << std::endl;
    } else if (tlwe_payload.size() % tlwe_words != 0) {
      std::cerr << "[TFHE_GPU_EXEC][ERR] VP payload bytes misaligned: bytes="
                << tlwe_payload.size() << " tlwe_words=" << tlwe_words << std::endl;
    } else {
      const std::size_t word_bytes = tlwe_payload.size() / tlwe_words;
      const std::size_t expect_bytes = tlwe_words * word_bytes;
      if (tlwe_payload.size() != expect_bytes) {
        std::cerr << "[TFHE_GPU_EXEC][ERR] VP payload bytes mismatch: bytes="
                  << tlwe_payload.size() << " expect=" << expect_bytes
                  << " word_bytes=" << word_bytes << std::endl;
      }
    }
  }
  const bool allow_empty_tlwe_payload =
      (request.descriptor.mode == gpu_runtime::ipc::kDescriptorModeFunctionEval &&
       request.tlwe_bytes == 0);
  if (tlwe_payload.empty() && !allow_empty_tlwe_payload) {
    throw std::invalid_argument("tlwe payload is empty");
  }
  if (force_stub_) {
    return run_stub_pipeline(request, tlwe_payload, glwe_payload);
  }

  switch (request.descriptor.mode) {
    case gpu_runtime::ipc::kDescriptorModeVerticalPacking:
      return process_vertical_packing(request, tlwe_payload, glwe_payload);
    case gpu_runtime::ipc::kDescriptorModeBitExtract:
      return process_bit_extract(request, tlwe_payload, glwe_payload);
    case gpu_runtime::ipc::kDescriptorModeCircuitBootstrap:
      return process_circuit_bootstrap(request, tlwe_payload, glwe_payload);
    case gpu_runtime::ipc::kDescriptorModeFunctionEval:
      return process_function_eval(request, tlwe_payload, glwe_payload);
    case gpu_runtime::ipc::kDescriptorModePbsPrimitive:
      return process_pbs_primitive(request, tlwe_payload, glwe_payload);
    default:
      throw std::invalid_argument("unsupported descriptor mode");
  }
}

bool TfheGpuExecutor::is_step5_only_descriptor(const gpu_runtime::ipc::SubmitRequest& request) {
  // Descriptor flag bit 7 mirrors RTL step5_only; other bits carry range hints.
  return (request.descriptor.flags & gpu_runtime::ipc::kDescriptorFlagStep5Only) != 0;
}

gpu_runtime::ipc::SubmitResponse TfheGpuExecutor::run_stub_pipeline(
    const gpu_runtime::ipc::SubmitRequest& request,
    std::span<const std::uint8_t> tlwe_payload,
    std::vector<std::uint8_t>& glwe_payload) {
  const std::size_t tlwe_bytes = tlwe_payload.size();
  const std::size_t tlwe_words = request.descriptor.tlwe_words != 0
                                     ? static_cast<std::size_t>(request.descriptor.tlwe_words)
                                     : tlwe_bytes / sizeof(std::uint32_t);
  const std::size_t word_bytes = (tlwe_words != 0)
                                     ? safe_divide(tlwe_bytes, tlwe_words)
                                     : sizeof(std::uint32_t);
  std::size_t result_words = request.descriptor.glwe_words;
  if (result_words == 0) {
    result_words = tlwe_words;
  }
  const std::size_t result_bytes = result_words * word_bytes;
  glwe_payload.resize(result_bytes);
  const std::size_t copy_bytes = std::min(glwe_payload.size(), tlwe_payload.size());
  if (copy_bytes > 0) {
    std::memcpy(glwe_payload.data(), tlwe_payload.data(), copy_bytes);
  }
  if (copy_bytes < glwe_payload.size()) {
    std::memset(glwe_payload.data() + copy_bytes, 0, glwe_payload.size() - copy_bytes);
  }

  gpu_runtime::ipc::SubmitResponse response{};
  response.status_code = 0;
  response.error_code = 0;
  response.latency_ns = 1'000'000;
  response.glwe_bytes = static_cast<std::uint32_t>(glwe_payload.size());
  response.woks_latency_ns = 500'000;
  response.ks_latency_ns = 500'000;
  response.sequence_no = 0;
  response.outstanding_descriptors = 0;
  response.reserved = 0;

  std::cout << "[TFHE_GPU_EXEC][STUB] cmd_id=" << request.descriptor.cmd_id
            << " mode=" << static_cast<int>(request.descriptor.mode)
            << " tlwe_words=" << request.descriptor.tlwe_words
            << " glwe_words=" << request.descriptor.glwe_words
            << " bytes=" << glwe_payload.size()
            << " latency_ns=" << response.latency_ns << std::endl;
  return response;
}

gpu_runtime::ipc::SubmitResponse TfheGpuExecutor::process_vertical_packing(
    const gpu_runtime::ipc::SubmitRequest& request,
    std::span<const std::uint8_t> tlwe_payload,
    std::vector<std::uint8_t>& glwe_payload) {
  const std::size_t lvl0_words = static_cast<std::size_t>(Context::n_lvl0) + 1u;
  if (request.descriptor.tlwe_words == lvl0_words) {
    // Direct WoKS path: payload already reduced to lvl0 (or premod(i32) when FLAG_PREMOD_INPUT is set).
    return run_circuit_bootstrap_pipeline(request, tlwe_payload, glwe_payload);
  }

  // VP 不走 step5-only 直通，始终按 20500 词处理
  gpu_runtime::ipc::SubmitRequest req = request;
  req.descriptor.flags &= static_cast<std::uint8_t>(~gpu_runtime::ipc::kDescriptorFlagStep5Only);

  const std::size_t lvl1_words = static_cast<std::size_t>(Context::n_lvl1) + 1u;
  const bool vp_biglut_only = (req.descriptor.glwe_words == lvl1_words);

  // 关键修正：VP 流程内部会派生/收缩中间态（例如 KS payload=10020 words），
  // 若在中间态阶段再去调用 cpu_reference_runner，会导致其无法识别 VP payload 格式，
  // 输出全 0 或与 golden 不一致。这里在 VP 入口直接对原始 TLWE payload 做 CPU 兜底，
  // 用于 nvmevirt+GPU（不上板）端到端闭环的 correctness 优先路线。
  if (!vp_biglut_only && env_flag_enabled("WOP_GPU_FORCE_CPU_WOKS")) {
    const std::size_t tlwe_bytes = tlwe_payload.size();
    const std::size_t tlwe_words =
        req.descriptor.tlwe_words != 0 ? static_cast<std::size_t>(req.descriptor.tlwe_words)
                                       : (tlwe_bytes / sizeof(std::uint32_t));
    const std::size_t word_bytes =
        (tlwe_words != 0) ? safe_divide(tlwe_bytes, tlwe_words) : sizeof(std::uint32_t);
    if (tlwe_words != 0 && word_bytes >= kMinWordBytes) {
      const std::size_t available_words = static_cast<std::size_t>(Context::n_lvl2) + 1;
      std::size_t result_words = req.descriptor.glwe_words;
      if (result_words == 0) {
        result_words = available_words;
      }
      result_words = std::min<std::size_t>(result_words, available_words);
      std::uint64_t cpu_latency_ns = 0;
      const auto compare_keyset = resolve_keyset_path_for_compare(ctx_.get());
      const std::filesystem::path* compare_keyset_ptr =
          compare_keyset ? &*compare_keyset : nullptr;
      if (auto cpu_override = maybe_run_cpu_woks_override(
              tlwe_payload,
              tlwe_words,
              result_words,
              word_bytes,
              req.descriptor.mode,
              req.descriptor.flags,
              compare_keyset_ptr,
              cpu_latency_ns)) {
        glwe_payload = std::move(*cpu_override);
        gpu_runtime::ipc::SubmitResponse response{};
        response.status_code = 0;
        response.error_code = 0;
        response.latency_ns = cpu_latency_ns;
        response.glwe_bytes = static_cast<std::uint32_t>(glwe_payload.size());
        response.reserved = 0;
        response.woks_latency_ns = cpu_latency_ns;
        response.ks_latency_ns = 0;
        response.sequence_no = 0;
        response.outstanding_descriptors = 0;
        return response;
      }
    }
  }

  return run_vertical_packing_pipeline(req, tlwe_payload, glwe_payload);
}

gpu_runtime::ipc::SubmitResponse TfheGpuExecutor::process_bit_extract(
    const gpu_runtime::ipc::SubmitRequest& request,
    std::span<const std::uint8_t> tlwe_payload,
    std::vector<std::uint8_t>& glwe_payload) {
  if (is_step5_only_descriptor(request)) {
    std::cout << "[TFHE_GPU_EXEC][INFO] BE step5-only descriptor; reusing CB pipeline"
              << std::endl;
    return run_circuit_bootstrap_pipeline(request, tlwe_payload, glwe_payload);
  }
  const std::size_t lvl0_words = static_cast<std::size_t>(Context::n_lvl0) + 1u;
  if (request.descriptor.tlwe_words == lvl0_words) {
    // BE split: backend sends lvl0 (or premod(i32)) payload for WoKS stage.
    std::cout << "[TFHE_GPU_EXEC][INFO] BE direct WoKS (lvl0/premod) tlwe_words="
              << request.descriptor.tlwe_words << " glwe_words=" << request.descriptor.glwe_words
              << " flags=0x" << std::hex << static_cast<int>(request.descriptor.flags) << std::dec
              << std::endl;
    return run_circuit_bootstrap_pipeline(request, tlwe_payload, glwe_payload);
  }
  const std::size_t lvl1_words = static_cast<std::size_t>(Context::n_lvl1) + 1u;
  if (request.descriptor.glwe_words == lvl1_words) {
    std::cout << "[TFHE_GPU_EXEC][INFO] BE bit_extract-only output tlwe_words="
              << request.descriptor.tlwe_words << " glwe_words=" << request.descriptor.glwe_words
              << " flags=0x" << std::hex << static_cast<int>(request.descriptor.flags) << std::dec
              << std::endl;
    return run_bit_extract_pipeline(request, tlwe_payload, glwe_payload);
  }
  // 默认走 BE 前端管线：BitExtract + KS_lvl10 (lvl1→lvl0) → WoKS/PrivKS。
  // 只有显式设置 WOP_GPU_BE_DIRECT 时才保留旧的“截断后直通 WoKS”路径。
  const bool force_pipeline = env_flag_enabled("WOP_GPU_BE_PIPELINE");  // 兼容旧开关（1=走管线）
  const bool force_direct = env_flag_enabled("WOP_GPU_BE_DIRECT");
  if (!force_direct || force_pipeline) {
    std::cout << "[TFHE_GPU_EXEC][INFO] BE pipeline (bit_extract + ks_lvl10) tlwe_words="
              << request.descriptor.tlwe_words << " glwe_words=" << request.descriptor.glwe_words
              << " flags=0x" << std::hex << static_cast<int>(request.descriptor.flags) << std::dec
              << (force_pipeline ? " (WOP_GPU_BE_PIPELINE=1)" : " (default pipeline)") << std::endl;
    return run_bit_extract_pipeline(request, tlwe_payload, glwe_payload);
  }

  std::cout << "[TFHE_GPU_EXEC][INFO] BE direct WoKS path (descriptor-preserve) tlwe_words="
            << request.descriptor.tlwe_words << " glwe_words=" << request.descriptor.glwe_words
            << " flags=0x" << std::hex << static_cast<int>(request.descriptor.flags) << std::dec
            << " (WOP_GPU_BE_DIRECT=1)" << std::endl;
  return run_circuit_bootstrap_pipeline(request, tlwe_payload, glwe_payload);
}

gpu_runtime::ipc::SubmitResponse TfheGpuExecutor::process_circuit_bootstrap(
    const gpu_runtime::ipc::SubmitRequest& request,
    std::span<const std::uint8_t> tlwe_payload,
    std::vector<std::uint8_t>& glwe_payload) {
  return run_circuit_bootstrap_pipeline(request, tlwe_payload, glwe_payload);
}

gpu_runtime::ipc::SubmitResponse TfheGpuExecutor::process_function_eval(
    const gpu_runtime::ipc::SubmitRequest& request,
    std::span<const std::uint8_t> tlwe_payload,
    std::vector<std::uint8_t>& glwe_payload) {
  // FunctionEval (mode=3):
  // - flags[7:2] == 0: monolithic TFHE softmax (fp64 in/out) inside gpu_runtime_service.
  // - flags[7:2] != 0: staged RPC (backend drives stages; gpu_runtime_service holds session state).
  // - flags[7:2] == 0x09: Concrete payload execution (delegated to Python runner).
  //
  // NOTE: NVMe/CSD descriptor layout is unchanged; we only reinterpret flags for mode=3.
  // NOTE: staged RPC is a control-plane split only (compute still runs inside gpu_runtime_service);
  //       stage ops are softmax algorithm steps and may each invoke PBS primitives.

  const std::uint8_t func_op = static_cast<std::uint8_t>(request.descriptor.flags >> 2);
  const std::uint8_t func_opt = static_cast<std::uint8_t>(request.descriptor.flags & 0x3u);
  constexpr std::uint8_t kOpConcrete = 0x09;
  int quant_frac_bits = parse_env_int("WOP_GPU_FP_QUANT_FRAC_BITS", 0);
  int quant_total_bits = parse_env_int("WOP_GPU_FP_QUANT_BITS", 0);
  int quant_int_bits = parse_env_int("WOP_GPU_FP_QUANT_INT_BITS", 0);
  if (quant_frac_bits <= 0 && quant_total_bits > 0) {
    if (quant_int_bits <= 0) {
      quant_int_bits = NUM_INT_BITS;
    }
    quant_frac_bits = quant_total_bits - quant_int_bits;
  }
  if (quant_frac_bits < 0) {
    quant_frac_bits = 0;
  }
  const bool quantize_inputs = (quant_frac_bits > 0);
  const double quant_scale = quantize_inputs ? std::ldexp(1.0, quant_frac_bits) : 1.0;
  auto quantize_value = [&](double v) -> double {
    if (!quantize_inputs) {
      return v;
    }
    double q = std::round(v * quant_scale) / quant_scale;
    if (quant_int_bits > 0) {
      const double limit = std::ldexp(1.0, quant_int_bits - 1);
      if (q > limit) {
        q = limit;
      } else if (q < -limit) {
        q = -limit;
      }
    }
    return q;
  };
  if (quantize_inputs && func_op == 0) {
    std::cout << "[TFHE_GPU_EXEC][FP] input_quantize=1 total_bits=" << quant_total_bits
              << " int_bits=" << quant_int_bits
              << " frac_bits=" << quant_frac_bits
              << std::endl;
  }
  if (func_op == kOpConcrete) {
    if (tlwe_payload.empty()) {
      throw std::invalid_argument("FunctionEval concrete requires non-empty payload");
    }
    if (request.descriptor.glwe_words == 0 && request.glwe_bytes == 0) {
      throw std::invalid_argument("FunctionEval concrete requires non-zero glwe_words/glwe_bytes");
    }
    std::size_t out_limit = static_cast<std::size_t>(request.glwe_bytes);
    if (out_limit == 0 && request.descriptor.glwe_words != 0) {
      out_limit = static_cast<std::size_t>(request.descriptor.glwe_words) * sizeof(std::uint64_t);
    }
    const auto start = std::chrono::steady_clock::now();
    std::vector<std::uint8_t> output = run_concrete_runner(tlwe_payload, out_limit);
    glwe_payload = std::move(output);
    const auto end = std::chrono::steady_clock::now();
    const std::uint64_t latency_ns =
        std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
    std::cout << "[TFHE_GPU_EXEC][FUNC_CONCRETE] payload_bytes=" << tlwe_payload.size()
              << " out_bytes=" << glwe_payload.size() << std::endl;

    gpu_runtime::ipc::SubmitResponse response{};
    response.status_code = 0;
    response.error_code = 0;
    response.latency_ns = latency_ns;
    response.glwe_bytes = static_cast<std::uint32_t>(glwe_payload.size());
    response.woks_latency_ns = 0;
    response.ks_latency_ns = 0;
    response.sequence_no = 0;
    response.outstanding_descriptors = 0;
    response.reserved = 0;
    return response;
  }

  std::lock_guard<std::mutex> context_lock(context_mutex_);
  if (force_stub_ || ctx_ == nullptr) {
    return run_stub_pipeline(request, tlwe_payload, glwe_payload);
  }

  const bool force_kspbs_split = (func_opt & 0x1u) != 0;
  const bool force_kspbs_split_all_stages = (func_opt & 0x2u) != 0;
  const std::uint64_t session_id = request.descriptor.status_addr;
  auto cleanup_session = [&](FuncEvalSession& session) {
    if (session.lwe_data != nullptr) {
      delete_array2<LweSample32>(session.lwe_data);
      session.lwe_data = nullptr;
    }
    if (session.scratch != nullptr) {
      delete_array1<LweSample32>(session.scratch);
      session.scratch = nullptr;
    }
    session.n = 0;
    session.stage = 0;
    session.enc_ns = 0;
    session.max_ns = 0;
    session.shift_ns = 0;
    session.exp_ns = 0;
    session.sum_ns = 0;
    session.div_ns = 0;
    session.dec_ns = 0;
    session.metrics_reported = false;
  };

  struct KspbsSplitOverrideGuard {
    explicit KspbsSplitOverrideGuard(bool enable) : active(enable), prev(0) {
      if (active) {
        prev = tfhe_gpu_get_kspbs_split_override();
        tfhe_gpu_set_kspbs_split_override(1);
      }
    }
    ~KspbsSplitOverrideGuard() {
      if (active) {
        tfhe_gpu_set_kspbs_split_override(prev);
      }
    }
    bool active;
    int prev;
  };

  if (func_op != 0) {
    // Staged function-eval RPC. Backend must provide a non-zero session id in status_addr.
    if (session_id == 0) {
      throw std::invalid_argument("FunctionEval staged RPC requires non-zero status_addr as session_id");
    }

    constexpr std::uint8_t kOpInit = 1;
    constexpr std::uint8_t kOpMax = 2;
    constexpr std::uint8_t kOpShift = 3;
    constexpr std::uint8_t kOpExpMinus = 4;
    constexpr std::uint8_t kOpSum = 5;
    constexpr std::uint8_t kOpDiv = 6;
    constexpr std::uint8_t kOpExport = 7;
    constexpr std::uint8_t kOpClear = 8;

    const bool stage_metrics = env_flag_enabled("WOP_GPU_FUNC_STAGE_METRICS");
    const bool kspbs_call_metrics = env_flag_enabled("WOP_GPU_KSPBS_CALL_METRICS");
    const bool kspbs_lut_metrics = env_flag_enabled("WOP_GPU_KSPBS_LUT_METRICS");
    const bool kspbs_split_all_stages =
        env_flag_enabled("WOP_GPU_KSPBS_SPLIT_ALL_STAGES") || force_kspbs_split_all_stages;
    const auto log_kspbs_calls = [&](const char* stage) {
      if (!kspbs_call_metrics) {
        return;
      }
      const KspbsCallCounter counter = kspbs_call_counter_snapshot();
      std::cout << "[TFHE_GPU_EXEC][KSPBS_CALLS] stage=" << stage
                << " stride0=" << counter.stride0_calls << " stride1=" << counter.stride1_calls
                << std::endl;

      if (!kspbs_lut_metrics) {
        return;
      }

      const auto lut_name = [](int id) -> const char* {
        switch (id) {
          case 0:
          case 1:
            return "get_hi";
          case 2:
            return "get_lo";
          case 3:
            return "get_sign";
          case 4:
            return "logical_or";
          case 5:
            return "mux_1";
          case 6:
            return "mux_ano_0";
          case 7:
            return "mux_ano_1";
          case 8:
            return "sign_comb";
          case 9:
            return "test";
          case 10:
            return "lshift";
          case 11:
            return "rshift";
          case 12:
            return "mul_lo";
          case 13:
            return "mul_hi";
          case 20:
            return "block_state[0]";
          case 21:
            return "block_state[1]";
          case 22:
            return "block_state[2]";
          case 23:
            return "block_state[3]";
          case 24:
            return "block_state[4]";
          case 25:
            return "first_group_carry";
          case 26:
            return "first_group_prop_state[0]";
          case 27:
            return "first_group_prop_state[1]";
          case 28:
            return "first_group_prop_state[2]";
          case 29:
            return "other_group_carry[0]";
          case 30:
            return "other_group_carry[1]";
          case 31:
            return "other_group_carry[2]";
          case 32:
            return "other_group_prop_state[0]";
          case 33:
            return "other_group_prop_state[1]";
          case 34:
            return "other_group_prop_state[2]";
          case 35:
            return "other_group_prop_state[3]";
          case 36:
            return "get_bit[0]";
          case 37:
            return "get_bit[1]";
          case 38:
            return "get_bit[2]";
          case 39:
            return "get_bit[3]";
          case 40:
            return "map_to_bit27";
          case 41:
            return "map_to_bit31";
          default:
            return nullptr;
        }
      };

      struct LutEntry {
        int id;
        std::uint64_t samples;
      };
      std::vector<LutEntry> entries;
      entries.reserve(64);
      std::uint64_t total_known = 0;
      for (int id = 0; id < 64; ++id) {
        const std::uint64_t samples = counter.lut_samples[id];
        total_known += samples;
        if (samples != 0) {
          entries.push_back(LutEntry{id, samples});
        }
      }
      std::sort(entries.begin(), entries.end(), [](const LutEntry& a, const LutEntry& b) {
        if (a.samples != b.samples) {
          return a.samples > b.samples;
        }
        return a.id < b.id;
      });

      constexpr std::size_t kTop = 6;
      std::uint64_t top_sum = 0;
      std::cout << "[TFHE_GPU_EXEC][KSPBS_LUT_SAMPLES] stage=" << stage;
      for (std::size_t i = 0; i < entries.size() && i < kTop; ++i) {
        top_sum += entries[i].samples;
        const char* name = lut_name(entries[i].id);
        if (name != nullptr) {
          std::cout << " lut" << entries[i].id << "(" << name << ")=" << entries[i].samples;
        } else {
          std::cout << " lut" << entries[i].id << "=" << entries[i].samples;
        }
      }
      const std::uint64_t unknown = counter.unknown_lut_samples;
      const std::uint64_t total_all = total_known + unknown;
      const std::uint64_t others = (total_known >= top_sum) ? (total_known - top_sum) : 0;
      std::cout << " others=" << others << " unknown=" << unknown << " total=" << total_all
                << std::endl;
    };
    const auto start = std::chrono::steady_clock::now();

    if (func_op == kOpClear) {
      auto it = func_eval_sessions_.find(session_id);
      if (it != func_eval_sessions_.end()) {
        cleanup_session(it->second);
        func_eval_sessions_.erase(it);
      }
      gpu_runtime::ipc::SubmitResponse response{};
      response.status_code = 0;
      response.error_code = 0;
      response.latency_ns = 0;
      response.glwe_bytes = 0;
      response.woks_latency_ns = 0;
      response.ks_latency_ns = 0;
      response.sequence_no = 0;
      response.outstanding_descriptors = 0;
      response.reserved = 0;
      return response;
    }

    auto it = func_eval_sessions_.find(session_id);
    if (func_op == kOpInit) {
      // Overwrite existing session if present.
      if (it != func_eval_sessions_.end()) {
        cleanup_session(it->second);
        func_eval_sessions_.erase(it);
      }
      const std::uint32_t tlwe_words_u32 = request.descriptor.tlwe_words;
      if (tlwe_words_u32 == 0) {
        throw std::invalid_argument("FunctionEval INIT requires tlwe_words > 0");
      }
      const std::size_t n = static_cast<std::size_t>(tlwe_words_u32);
      const std::size_t word_bytes = safe_divide(tlwe_payload.size(), n);
      if (word_bytes != sizeof(double)) {
        throw std::invalid_argument("FunctionEval INIT requires 8-byte words (fp64 payload)");
      }
      if (quantize_inputs) {
        std::cout << "[TFHE_GPU_EXEC][FP] input_quantize=1 total_bits=" << quant_total_bits
                  << " int_bits=" << quant_int_bits
                  << " frac_bits=" << quant_frac_bits
                  << std::endl;
      }

      FuncEvalSession session{};
      session.n = static_cast<int>(n);
      session.stage = 1;

      if (kspbs_call_metrics) {
        kspbs_call_counter_reset();
      }
      if (force_kspbs_split) {
        std::cout << "[TFHE_GPU_EXEC][FUNC] softmax kspbs_split=1 all_stages="
                  << (kspbs_split_all_stages ? 1 : 0) << std::endl;
      }
      const auto t_enc_start = std::chrono::steady_clock::now();
      session.lwe_data = new_array2<LweSample32>(session.n, NUM_TOTAL_SIZE, ctx_->n_lvl1);
      session.scratch = new_array1<LweSample32>(NUM_TOTAL_SIZE, ctx_->n_lvl1);
      for (std::size_t i = 0; i < n; ++i) {
        double value = 0.0;
        std::memcpy(&value, tlwe_payload.data() + i * sizeof(double), sizeof(double));
        fp_from_double(session.lwe_data[static_cast<int>(i)], quantize_value(value), ctx_.get());
      }
      const auto t_enc_end = std::chrono::steady_clock::now();
      if (stage_metrics) {
        session.enc_ns += static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(t_enc_end - t_enc_start).count());
      }
      log_kspbs_calls("init");

      func_eval_sessions_.emplace(session_id, session);
      glwe_payload.clear();
    } else {
      if (it == func_eval_sessions_.end()) {
        throw std::invalid_argument("FunctionEval staged RPC requires existing session_id");
      }
      FuncEvalSession& session = it->second;
      if (session.lwe_data == nullptr || session.scratch == nullptr || session.n <= 0) {
        throw std::runtime_error("FunctionEval session is not initialized");
      }

      if (func_op == kOpMax) {
        // x_max = max(x[0..n-1])
        if (kspbs_call_metrics) {
          kspbs_call_counter_reset();
        }
        const auto t_max_start = std::chrono::steady_clock::now();
        LweSample32* x_max = session.scratch;
        lwe32Copy_batch(x_max, session.lwe_data[0], NUM_TOTAL_SIZE, ctx_->n_lvl1);
        {
          KspbsSplitOverrideGuard split_guard(force_kspbs_split);
          if (kspbs_split_all_stages) {
            tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageMax);
          }
          for (int i = 1; i < session.n; ++i) {
            fp_max_assign_ip(x_max, session.lwe_data[i], ctx_.get());
          }
          if (kspbs_split_all_stages) {
            tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageNone);
          }
        }
        const auto t_max_end = std::chrono::steady_clock::now();
        if (stage_metrics) {
          session.max_ns += static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::nanoseconds>(t_max_end - t_max_start).count());
        }
        log_kspbs_calls("max");
        session.stage = 2;
        glwe_payload.clear();
      } else if (func_op == kOpShift) {
        // x[i] = x_max - x[i]
        if (kspbs_call_metrics) {
          kspbs_call_counter_reset();
        }
        const auto t_shift_start = std::chrono::steady_clock::now();
        const LweSample32* x_max = session.scratch;
        {
          KspbsSplitOverrideGuard split_guard(force_kspbs_split);
          if (kspbs_split_all_stages) {
            tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageShift);
          }
          for (int i = 0; i < session.n; ++i) {
            fp_sub_rev_assign_ip(session.lwe_data[i], x_max, ctx_.get());
          }
          if (kspbs_split_all_stages) {
            tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageNone);
          }
        }
        const auto t_shift_end = std::chrono::steady_clock::now();
        if (stage_metrics) {
          session.shift_ns += static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::nanoseconds>(t_shift_end - t_shift_start)
                  .count());
        }
        log_kspbs_calls("shift");
        session.stage = 3;
        glwe_payload.clear();
      } else if (func_op == kOpExpMinus) {
        // x[i] = exp(-x[i])
        if (kspbs_call_metrics) {
          kspbs_call_counter_reset();
        }
        const auto t_exp_start = std::chrono::steady_clock::now();
        {
          KspbsSplitOverrideGuard split_guard(force_kspbs_split);
          if (kspbs_split_all_stages) {
            tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageExpMinus);
          }
          for (int i = 0; i < session.n; ++i) {
            fp_exp_minus_ip(session.lwe_data[i], ctx_.get(), /*verbose=*/false);
          }
          if (kspbs_split_all_stages) {
            tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageNone);
          }
        }
        const auto t_exp_end = std::chrono::steady_clock::now();
        if (stage_metrics) {
          session.exp_ns += static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::nanoseconds>(t_exp_end - t_exp_start).count());
        }
        log_kspbs_calls("exp_minus");
        session.stage = 4;
        glwe_payload.clear();
      } else if (func_op == kOpSum) {
        // sum = Σ x[i]
        if (kspbs_call_metrics) {
          kspbs_call_counter_reset();
        }
        const auto t_sum_start = std::chrono::steady_clock::now();
        LweSample32* x_sum = session.scratch;
        fp_from_double(x_sum, 0.0, ctx_.get());
        {
          KspbsSplitOverrideGuard split_guard(force_kspbs_split);
          if (kspbs_split_all_stages) {
            tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageSum);
          }
          for (int i = 0; i < session.n; ++i) {
            fp_add_assign_ip(x_sum, session.lwe_data[i], ctx_.get());
          }
          if (kspbs_split_all_stages) {
            tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageNone);
          }
        }
        const auto t_sum_end = std::chrono::steady_clock::now();
        if (stage_metrics) {
          session.sum_ns += static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::nanoseconds>(t_sum_end - t_sum_start).count());
        }
        log_kspbs_calls("sum");
        session.stage = 5;
        glwe_payload.clear();
      } else if (func_op == kOpDiv) {
        // x[i] = x[i] / sum
        if (kspbs_call_metrics) {
          kspbs_call_counter_reset();
        }
        const auto t_div_start = std::chrono::steady_clock::now();
        const LweSample32* x_sum = session.scratch;
        {
          KspbsSplitOverrideGuard split_guard(force_kspbs_split);
          tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageDiv);
          for (int i = 0; i < session.n; ++i) {
            fp_div_u_l1_assign_ip(session.lwe_data[i], x_sum, ctx_.get());
          }
          tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageNone);
        }
        const auto t_div_end = std::chrono::steady_clock::now();
        if (stage_metrics) {
          session.div_ns += static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::nanoseconds>(t_div_end - t_div_start).count());
        }
        log_kspbs_calls("div");
        session.stage = 6;
        glwe_payload.clear();
      } else if (func_op == kOpExport) {
        const std::size_t out_words =
            request.descriptor.glwe_words != 0
                ? static_cast<std::size_t>(request.descriptor.glwe_words)
                : static_cast<std::size_t>(session.n);
        if (out_words < static_cast<std::size_t>(session.n)) {
          throw std::invalid_argument("FunctionEval EXPORT requires glwe_words >= n");
        }
        if (kspbs_call_metrics) {
          kspbs_call_counter_reset();
        }
        const auto t_dec_start = std::chrono::steady_clock::now();
        glwe_payload.resize(out_words * sizeof(double));
        for (int i = 0; i < session.n; ++i) {
          const double value = fp_to_double(session.lwe_data[i], ctx_.get());
          std::memcpy(glwe_payload.data() + static_cast<std::size_t>(i) * sizeof(double),
                      &value,
                      sizeof(double));
        }
        for (std::size_t i = static_cast<std::size_t>(session.n); i < out_words; ++i) {
          const double value = 0.0;
          std::memcpy(glwe_payload.data() + i * sizeof(double), &value, sizeof(double));
        }
        const auto t_dec_end = std::chrono::steady_clock::now();
        if (stage_metrics) {
          session.dec_ns += static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::nanoseconds>(t_dec_end - t_dec_start).count());
        }
        session.stage = 7;

        if (stage_metrics && !session.metrics_reported) {
          const std::uint64_t total_ns =
              session.enc_ns + session.max_ns + session.shift_ns + session.exp_ns + session.sum_ns +
              session.div_ns + session.dec_ns;
          std::cout << "[TFHE_GPU_EXEC][FUNC_METRICS] softmax n=" << session.n
                    << " enc_ns=" << session.enc_ns << " max_ns=" << session.max_ns
                    << " shift_ns=" << session.shift_ns << " exp_ns=" << session.exp_ns
                    << " sum_ns=" << session.sum_ns << " div_ns=" << session.div_ns
                    << " dec_ns=" << session.dec_ns << " total_ns=" << total_ns << std::endl;
          session.metrics_reported = true;
        }
        log_kspbs_calls("export");
      } else {
        throw std::invalid_argument("FunctionEval staged RPC: unknown func_op");
      }
    }

    const auto end = std::chrono::steady_clock::now();
    const std::uint64_t latency_ns =
        std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();

    gpu_runtime::ipc::SubmitResponse response{};
    response.status_code = 0;
    response.error_code = 0;
    response.latency_ns = latency_ns;
    response.glwe_bytes = static_cast<std::uint32_t>(glwe_payload.size());
    response.woks_latency_ns = 0;
    response.ks_latency_ns = 0;
    response.sequence_no = 0;
    response.outstanding_descriptors = 0;
    response.reserved = 0;
    return response;
  }

  const std::uint32_t tlwe_words_u32 = request.descriptor.tlwe_words;
  if (tlwe_words_u32 == 0) {
    throw std::invalid_argument("FunctionEval requires tlwe_words > 0");
  }
  const std::size_t tlwe_words = static_cast<std::size_t>(tlwe_words_u32);
  const std::size_t word_bytes = safe_divide(tlwe_payload.size(), tlwe_words);
  if (word_bytes != sizeof(double)) {
    throw std::invalid_argument("FunctionEval requires 8-byte words (fp64 payload)");
  }

  std::size_t out_words = request.descriptor.glwe_words;
  if (out_words == 0) {
    out_words = tlwe_words;
  }
  if (out_words < tlwe_words) {
    throw std::invalid_argument("FunctionEval requires glwe_words >= tlwe_words");
  }

  std::vector<double> inputs(tlwe_words);
  for (std::size_t i = 0; i < tlwe_words; ++i) {
    double value = 0.0;
    std::memcpy(&value, tlwe_payload.data() + i * sizeof(double), sizeof(double));
    inputs[i] = value;
  }

  const bool verbose = env_flag_enabled("WOP_GPU_FUNC_VERBOSE");
  const bool stage_dump = env_flag_enabled("WOP_GPU_FUNC_STAGE_DUMP");
  const int exp_verbose_idx = stage_dump ? parse_env_int("WOP_GPU_FUNC_EXP_VERBOSE_IDX", -1) : -1;
  const bool stage_metrics = env_flag_enabled("WOP_GPU_FUNC_STAGE_METRICS");
  const bool kspbs_split_all_stages =
      env_flag_enabled("WOP_GPU_KSPBS_SPLIT_ALL_STAGES") || force_kspbs_split_all_stages;
  const auto start = std::chrono::steady_clock::now();
  KspbsSplitOverrideGuard split_guard(force_kspbs_split);

  const int n = static_cast<int>(tlwe_words);
  auto dump_vec = [&](const char* tag, LweSample32** data) {
    if (!stage_dump) {
      return;
    }
    std::cout << "[TFHE_GPU_EXEC][FUNC_DUMP] " << tag << ":";
    for (int i = 0; i < n; ++i) {
      std::cout << (i == 0 ? " " : ", ") << std::fixed << std::setprecision(6)
                << fp_to_double(data[i], ctx_.get());
    }
    std::cout << std::endl;
  };
  auto dump_one = [&](const char* tag, LweSample32* data) {
    if (!stage_dump) {
      return;
    }
    std::cout << "[TFHE_GPU_EXEC][FUNC_DUMP] " << tag << ": " << std::fixed
              << std::setprecision(6) << fp_to_double(data, ctx_.get()) << std::endl;
  };

  // Encrypt inputs.
  const auto t_enc_start = std::chrono::steady_clock::now();
  LweSample32** lwe_data = new_array2<LweSample32>(n, NUM_TOTAL_SIZE, ctx_->n_lvl1);
  for (int i = 0; i < n; ++i) {
    fp_from_double(lwe_data[i], quantize_value(inputs[static_cast<std::size_t>(i)]), ctx_.get());
  }
  const auto t_enc_end = std::chrono::steady_clock::now();

  // TFHE softmax (mirrors ../tfhe-gpu-baseline-wopbs/src/main.cpp softmax::tfhe()).
  LweSample32* scratch = new_array1<LweSample32>(NUM_TOTAL_SIZE, ctx_->n_lvl1);

  const auto t_max_start = std::chrono::steady_clock::now();
  LweSample32* x_max = scratch;
  lwe32Copy_batch(x_max, lwe_data[0], NUM_TOTAL_SIZE, ctx_->n_lvl1);
  if (kspbs_split_all_stages) {
    tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageMax);
  }
  for (int i = 1; i < n; ++i) {
    fp_max_assign_ip(x_max, lwe_data[i], ctx_.get());
  }
  if (kspbs_split_all_stages) {
    tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageNone);
  }
  dump_one("x_max", x_max);
  const auto t_max_end = std::chrono::steady_clock::now();

  // x[i] = x_max - x[i]
  const auto t_shift_start = std::chrono::steady_clock::now();
  if (kspbs_split_all_stages) {
    tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageShift);
  }
  for (int i = 0; i < n; ++i) {
    fp_sub_rev_assign_ip(lwe_data[i], x_max, ctx_.get());
  }
  if (kspbs_split_all_stages) {
    tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageNone);
  }
  dump_vec("after_shift", lwe_data);
  const auto t_shift_end = std::chrono::steady_clock::now();

  // x[i] = exp(-x[i])
  const auto t_exp_start = std::chrono::steady_clock::now();
  if (kspbs_split_all_stages) {
    tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageExpMinus);
  }
  for (int i = 0; i < n; ++i) {
    const bool exp_verbose = (exp_verbose_idx >= 0 && i == exp_verbose_idx);
    fp_exp_minus_ip(lwe_data[i], ctx_.get(), exp_verbose);
  }
  if (kspbs_split_all_stages) {
    tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageNone);
  }
  dump_vec("after_exp", lwe_data);
  const auto t_exp_end = std::chrono::steady_clock::now();

  // sum = Σ x[i]
  const auto t_sum_start = std::chrono::steady_clock::now();
  LweSample32* x_sum = scratch;
  fp_from_double(x_sum, 0.0, ctx_.get());
  if (kspbs_split_all_stages) {
    tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageSum);
  }
  for (int i = 0; i < n; ++i) {
    fp_add_assign_ip(x_sum, lwe_data[i], ctx_.get());
  }
  if (kspbs_split_all_stages) {
    tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageNone);
  }
  dump_one("x_sum", x_sum);
  const auto t_sum_end = std::chrono::steady_clock::now();

  // x[i] = x[i] / sum
  const auto t_div_start = std::chrono::steady_clock::now();
  tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageDiv);
  for (int i = 0; i < n; ++i) {
    fp_div_u_l1_assign_ip(lwe_data[i], x_sum, ctx_.get());
  }
  tfhe_gpu_set_kspbs_split_stage(kKspbsSplitStageNone);
  dump_vec("after_div", lwe_data);
  const auto t_div_end = std::chrono::steady_clock::now();

  const auto t_dec_start = std::chrono::steady_clock::now();
  std::vector<double> outputs(tlwe_words, 0.0);
  for (int i = 0; i < n; ++i) {
    outputs[static_cast<std::size_t>(i)] = fp_to_double(lwe_data[i], ctx_.get());
  }
  const auto t_dec_end = std::chrono::steady_clock::now();

  if (verbose) {
    std::cout << "[TFHE_GPU_EXEC][FUNC] softmax in:";
    for (std::size_t i = 0; i < inputs.size(); ++i) {
      std::cout << (i == 0 ? " " : ", ") << std::fixed << std::setprecision(6) << inputs[i];
    }
    std::cout << std::endl;
    std::cout << "[TFHE_GPU_EXEC][FUNC] softmax out:";
    for (std::size_t i = 0; i < outputs.size(); ++i) {
      std::cout << (i == 0 ? " " : ", ") << std::fixed << std::setprecision(6) << outputs[i];
    }
    std::cout << std::endl;
  }

  delete_array2<LweSample32>(lwe_data);
  delete_array1<LweSample32>(scratch);

  glwe_payload.resize(out_words * sizeof(double));
  for (std::size_t i = 0; i < out_words; ++i) {
    const double value = (i < outputs.size()) ? outputs[i] : 0.0;
    std::memcpy(glwe_payload.data() + i * sizeof(double), &value, sizeof(double));
  }

  const auto end = std::chrono::steady_clock::now();
  const std::uint64_t latency_ns =
      std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();

  if (stage_metrics) {
    const auto ns = [](const std::chrono::steady_clock::time_point& a,
                       const std::chrono::steady_clock::time_point& b) -> std::uint64_t {
      return static_cast<std::uint64_t>(
          std::chrono::duration_cast<std::chrono::nanoseconds>(b - a).count());
    };
    std::cout << "[TFHE_GPU_EXEC][FUNC_METRICS] softmax n=" << n
              << " enc_ns=" << ns(t_enc_start, t_enc_end)
              << " max_ns=" << ns(t_max_start, t_max_end)
              << " shift_ns=" << ns(t_shift_start, t_shift_end)
              << " exp_ns=" << ns(t_exp_start, t_exp_end)
              << " sum_ns=" << ns(t_sum_start, t_sum_end)
              << " div_ns=" << ns(t_div_start, t_div_end)
              << " dec_ns=" << ns(t_dec_start, t_dec_end) << " total_ns=" << latency_ns
              << std::endl;
  }

  gpu_runtime::ipc::SubmitResponse response{};
  response.status_code = 0;
  response.error_code = 0;
  response.latency_ns = latency_ns;
  response.glwe_bytes = static_cast<std::uint32_t>(glwe_payload.size());
  response.woks_latency_ns = 0;
  response.ks_latency_ns = 0;
  response.sequence_no = 0;
  response.outstanding_descriptors = 0;
  response.reserved = 0;
  return response;
}

gpu_runtime::ipc::SubmitResponse TfheGpuExecutor::process_pbs_primitive(
    const gpu_runtime::ipc::SubmitRequest& request,
    std::span<const std::uint8_t> tlwe_payload,
    std::vector<std::uint8_t>& glwe_payload) {
  std::lock_guard<std::mutex> context_lock(context_mutex_);
  if (force_stub_ || ctx_ == nullptr) {
    return run_stub_pipeline(request, tlwe_payload, glwe_payload);
  }

  // Contract (mode=4):
  // - descriptor.flags: selects primitive op
  // - descriptor.status_addr: packed params (backend-only; not a physical status address)
  //   - [7:0]   lut_id
  //   - [23:8]  torus_size (0 => default FULL_MSG_SIZE)
  //
  // Payload word format:
  // - Input words may be 4B (torus32) or 8B (torus64 with low-32 used).
  // - Output words may be 4B (torus32) or 8B (zero-extended torus32).

  constexpr std::uint8_t kOpKspbsBootstrapOnly = 1;
  constexpr std::uint8_t kOpKspbsFull = 2;
  constexpr std::uint8_t kOpKspbsFullPerSampleLut = 3;

  const std::uint8_t op = request.descriptor.flags;
  const std::uint64_t param = request.descriptor.status_addr;
  const std::uint8_t lut_id = static_cast<std::uint8_t>(param & 0xFFu);
  const std::uint16_t torus_size_param = static_cast<std::uint16_t>((param >> 8) & 0xFFFFu);
  const int torus_size = (torus_size_param != 0) ? static_cast<int>(torus_size_param) : FULL_MSG_SIZE;

  const std::size_t tlwe_words = static_cast<std::size_t>(request.descriptor.tlwe_words);
  const std::size_t glwe_words = static_cast<std::size_t>(request.descriptor.glwe_words);
  if (glwe_words == 0 || request.glwe_bytes == 0) {
    throw std::invalid_argument("PBS primitive requires non-zero glwe_words/glwe_bytes");
  }
  const std::size_t glwe_word_bytes =
      safe_divide(static_cast<std::size_t>(request.glwe_bytes), glwe_words);
  if (glwe_word_bytes != sizeof(std::uint32_t) && glwe_word_bytes != sizeof(std::uint64_t)) {
    throw std::invalid_argument("PBS primitive requires 4-byte or 8-byte output words");
  }

  auto resolve_lut = [&](std::uint8_t id) -> const TLweSample32* {
    switch (id) {
      case 0:
      case 1:
        return ctx_->TLweLuts.get_hi;
      case 2:
        return ctx_->TLweLuts.get_lo;
      case 3:
        return ctx_->TLweLuts.get_sign;
      case 4:
        return ctx_->TLweLuts.logical_or;
      case 5:
        return ctx_->TLweLuts.mux_1;
      case 6:
        return ctx_->TLweLuts.mux_ano_0;
      case 7:
        return ctx_->TLweLuts.mux_ano_1;
      case 8:
        return ctx_->TLweLuts.sign_comb;
      case 9:
        return ctx_->TLweLuts.test;
      case 10:
        return ctx_->TLweLuts.lshift;
      case 11:
        return ctx_->TLweLuts.rshift;
      case 12:
        return ctx_->TLweLuts.mul_lo;
      case 13:
        return ctx_->TLweLuts.mul_hi;
      case 20:
      case 21:
      case 22:
      case 23:
      case 24:
        return &ctx_->TLweLuts.block_state[static_cast<int>(id - 20)];
      case 25:
        return ctx_->TLweLuts.first_group_carry_lut;
      case 26:
      case 27:
      case 28:
        return &ctx_->TLweLuts.first_group_prop_state_luts[static_cast<int>(id - 26)];
      case 29:
      case 30:
      case 31:
        return &ctx_->TLweLuts.other_group_carry_luts[static_cast<int>(id - 29)];
      case 32:
      case 33:
      case 34:
      case 35:
        return &ctx_->TLweLuts.other_group_prop_state_luts[static_cast<int>(id - 32)];
      case 36:
      case 37:
      case 38:
      case 39:
        return &ctx_->TLweLuts.get_bit[static_cast<int>(id - 36)];
      case 40:
        return ctx_->TLweLuts.map_to_bit27;
      case 41:
        return ctx_->TLweLuts.map_to_bit31;
      default:
        throw std::invalid_argument("PBS primitive: unknown lut_id");
    }
  };

  const auto start = std::chrono::steady_clock::now();

  if (op == kOpKspbsFull) {
    const std::size_t lvl1_words = static_cast<std::size_t>(Context::n_lvl1) + 1u;
    if (tlwe_words == 0 || tlwe_words % lvl1_words != 0) {
      throw std::invalid_argument("KSPBS full requires tlwe_words = batch*(n_lvl1+1)");
    }
    const std::size_t batch = tlwe_words / lvl1_words;
    const std::size_t expected_out_words = batch * lvl1_words;
    if (glwe_words != expected_out_words) {
      throw std::invalid_argument("KSPBS full requires glwe_words = batch*(n_lvl1+1)");
    }
    if (batch > static_cast<std::size_t>(Context::KSPBS::MAX_BATCH_SIZE)) {
      throw std::invalid_argument("KSPBS full batch exceeds MAX_BATCH_SIZE");
    }

    const std::size_t tlwe_word_bytes =
        safe_divide(tlwe_payload.size(), std::max<std::size_t>(tlwe_words, 1));
    if (tlwe_word_bytes != sizeof(std::uint32_t) && tlwe_word_bytes != sizeof(std::uint64_t)) {
      throw std::invalid_argument("PBS primitive requires 4-byte or 8-byte input words");
    }
    std::vector<std::int32_t> host_in(batch * lvl1_words);
    for (std::size_t i = 0; i < host_in.size(); ++i) {
      const std::uint64_t raw = read_word64_le(tlwe_payload.data() + i * tlwe_word_bytes, tlwe_word_bytes);
      host_in[i] = static_cast<std::int32_t>(static_cast<std::uint32_t>(raw));
    }

    auto in_lvl1 = new_array1<LweSample32>(static_cast<int>(batch), ctx_->n_lvl1);
    auto out_lvl1 = new_array1<LweSample32>(static_cast<int>(batch), ctx_->n_lvl1);
    for (std::size_t b = 0; b < batch; ++b) {
      ensure_cuda_success(
          cudaMemcpy(in_lvl1[static_cast<int>(b)].a,
                     host_in.data() + b * lvl1_words,
                     lvl1_words * sizeof(std::int32_t),
                     cudaMemcpyHostToDevice),
          "kspbs full input h2d");
    }

    const TLweSample32* lut = resolve_lut(lut_id);
    TLwe32KSPBS_batch_lvl1<0>(out_lvl1, in_lvl1, lut, torus_size, static_cast<int>(batch), ctx_.get());

    std::vector<std::int32_t> host_out(batch * lvl1_words);
    for (std::size_t b = 0; b < batch; ++b) {
      ensure_cuda_success(
          cudaMemcpy(host_out.data() + b * lvl1_words,
                     out_lvl1[static_cast<int>(b)].a,
                     lvl1_words * sizeof(std::int32_t),
                     cudaMemcpyDeviceToHost),
          "kspbs full output d2h");
    }

    delete_array1<LweSample32>(in_lvl1);
    delete_array1<LweSample32>(out_lvl1);

    glwe_payload.resize(glwe_words * glwe_word_bytes);
    for (std::size_t i = 0; i < host_out.size(); ++i) {
      const std::uint64_t value = static_cast<std::uint64_t>(static_cast<std::uint32_t>(host_out[i]));
      encode_word_le(glwe_payload.data() + i * glwe_word_bytes, glwe_word_bytes, value);
    }
  } else if (op == kOpKspbsFullPerSampleLut) {
    const std::size_t lvl1_words = static_cast<std::size_t>(Context::n_lvl1) + 1u;
    if (tlwe_words == 0 || tlwe_words % lvl1_words != 0) {
      throw std::invalid_argument("KSPBS full-per-sample-lut requires tlwe_words = batch*(n_lvl1+1)");
    }
    const std::size_t batch = tlwe_words / lvl1_words;
    const std::size_t expected_out_words = batch * lvl1_words;
    if (glwe_words != expected_out_words) {
      throw std::invalid_argument("KSPBS full-per-sample-lut requires glwe_words = batch*(n_lvl1+1)");
    }
    if (batch > static_cast<std::size_t>(Context::KSPBS::MAX_BATCH_SIZE)) {
      throw std::invalid_argument("KSPBS full-per-sample-lut batch exceeds MAX_BATCH_SIZE");
    }
    if (tlwe_payload.size() < batch) {
      throw std::invalid_argument("KSPBS full-per-sample-lut payload too short for lut-id suffix");
    }
    const std::size_t lut_id_bytes = batch;
    const std::size_t input_bytes = tlwe_payload.size() - lut_id_bytes;
    const std::size_t tlwe_word_bytes =
        safe_divide(input_bytes, std::max<std::size_t>(tlwe_words, 1));
    if (tlwe_word_bytes != sizeof(std::uint32_t) && tlwe_word_bytes != sizeof(std::uint64_t)) {
      throw std::invalid_argument("PBS primitive requires 4-byte or 8-byte input words");
    }
    if (input_bytes != tlwe_words * tlwe_word_bytes) {
      throw std::invalid_argument("KSPBS full-per-sample-lut input_bytes mismatch");
    }

    const std::uint8_t* lut_ids = tlwe_payload.data() + input_bytes;

    std::vector<std::int32_t> host_in(batch * lvl1_words);
    for (std::size_t i = 0; i < host_in.size(); ++i) {
      const std::uint64_t raw =
          read_word64_le(tlwe_payload.data() + i * tlwe_word_bytes, tlwe_word_bytes);
      host_in[i] = static_cast<std::int32_t>(static_cast<std::uint32_t>(raw));
    }

    auto in_lvl1 = new_array1<LweSample32>(static_cast<int>(batch), ctx_->n_lvl1);
    auto out_lvl1 = new_array1<LweSample32>(static_cast<int>(batch), ctx_->n_lvl1);
    for (std::size_t b = 0; b < batch; ++b) {
      ensure_cuda_success(
          cudaMemcpy(in_lvl1[static_cast<int>(b)].a,
                     host_in.data() + b * lvl1_words,
                     lvl1_words * sizeof(std::int32_t),
                     cudaMemcpyHostToDevice),
          "kspbs full-per-sample-lut input h2d");
    }

    auto lut_views = new_array1<TLweSample32View>(static_cast<int>(batch));
    for (std::size_t b = 0; b < batch; ++b) {
      const std::uint8_t sample_lut_id = lut_ids[b];
      const TLweSample32* lut = resolve_lut(sample_lut_id);
      lut_views[static_cast<int>(b)] = TLweSample32View(*lut);
    }
    TLwe32KSPBS_batch_lvl1<1>(
        out_lvl1, in_lvl1, lut_views, torus_size, static_cast<int>(batch), ctx_.get());
    delete_array1<TLweSample32View>(lut_views);

    std::vector<std::int32_t> host_out(batch * lvl1_words);
    for (std::size_t b = 0; b < batch; ++b) {
      ensure_cuda_success(
          cudaMemcpy(host_out.data() + b * lvl1_words,
                     out_lvl1[static_cast<int>(b)].a,
                     lvl1_words * sizeof(std::int32_t),
                     cudaMemcpyDeviceToHost),
          "kspbs full-per-sample-lut output d2h");
    }

    delete_array1<LweSample32>(in_lvl1);
    delete_array1<LweSample32>(out_lvl1);

    glwe_payload.resize(glwe_words * glwe_word_bytes);
    for (std::size_t i = 0; i < host_out.size(); ++i) {
      const std::uint64_t value = static_cast<std::uint64_t>(static_cast<std::uint32_t>(host_out[i]));
      encode_word_le(glwe_payload.data() + i * glwe_word_bytes, glwe_word_bytes, value);
    }
  } else if (op == kOpKspbsBootstrapOnly) {
    const std::size_t lvl0_words = static_cast<std::size_t>(Context::n_lvl0) + 1u;
    const std::size_t tlwe_words_u = std::max<std::size_t>(tlwe_words, 1u);
    if (tlwe_words == 0 || tlwe_words % lvl0_words != 0) {
      throw std::invalid_argument("KSPBS bootstrap-only requires tlwe_words = batch*(n_lvl0+1)");
    }
    const std::size_t batch = tlwe_words_u / lvl0_words;
    const std::size_t tlwe32_words_per_sample = static_cast<std::size_t>(Context::N_lvl1) * (K + 1u);
    const std::size_t expected_out_words = batch * tlwe32_words_per_sample;
    if (glwe_words != expected_out_words) {
      throw std::invalid_argument("KSPBS bootstrap-only requires glwe_words = batch*(k+1)*N_lvl1");
    }
    if (batch > static_cast<std::size_t>(Context::KSPBS::MAX_BATCH_SIZE)) {
      throw std::invalid_argument("KSPBS bootstrap-only batch exceeds MAX_BATCH_SIZE");
    }

    const std::size_t tlwe_word_bytes =
        safe_divide(tlwe_payload.size(), std::max<std::size_t>(tlwe_words, 1));
    if (tlwe_word_bytes != sizeof(std::uint32_t) && tlwe_word_bytes != sizeof(std::uint64_t)) {
      throw std::invalid_argument("PBS primitive requires 4-byte or 8-byte input words");
    }
    std::vector<std::int32_t> host_lv0(batch * lvl0_words);
    for (std::size_t i = 0; i < host_lv0.size(); ++i) {
      const std::uint64_t raw = read_word64_le(tlwe_payload.data() + i * tlwe_word_bytes, tlwe_word_bytes);
      host_lv0[i] = static_cast<std::int32_t>(static_cast<std::uint32_t>(raw));
    }
    for (std::size_t b = 0; b < batch; ++b) {
      ensure_cuda_success(
          cudaMemcpy(ctx_->kspbs.lwe_lv0[static_cast<int>(b)].a,
                     host_lv0.data() + b * lvl0_words,
                     lvl0_words * sizeof(std::int32_t),
                     cudaMemcpyHostToDevice),
          "kspbs bootstrap-only input h2d");
    }

    const TLweSample32* lut = resolve_lut(lut_id);
    auto tlwe_out = new_array1<TLweSample32>(static_cast<int>(batch), ctx_->N_lvl1);
    TLwe32KSPBS_bootstrap_only_batch_lvl1(
        tlwe_out, ctx_->kspbs.lwe_lv0, lut, torus_size, static_cast<int>(batch), ctx_.get());

    std::vector<std::int32_t> host_tlwe(batch * tlwe32_words_per_sample);
    for (std::size_t b = 0; b < batch; ++b) {
      // Layout: [q=0][0..N-1], [q=1][0..N-1] (same as privKS output convention).
      const std::size_t base = b * tlwe32_words_per_sample;
      for (std::size_t q = 0; q < static_cast<std::size_t>(K) + 1u; ++q) {
        ensure_cuda_success(
            cudaMemcpy(host_tlwe.data() + base + q * static_cast<std::size_t>(ctx_->N_lvl1),
                       tlwe_out[static_cast<int>(b)].a[q].coefs,
                       static_cast<std::size_t>(ctx_->N_lvl1) * sizeof(std::int32_t),
                       cudaMemcpyDeviceToHost),
            "kspbs bootstrap-only output d2h");
      }
    }

    delete_array1<TLweSample32>(tlwe_out);

    glwe_payload.resize(glwe_words * glwe_word_bytes);
    for (std::size_t i = 0; i < host_tlwe.size(); ++i) {
      const std::uint64_t value = static_cast<std::uint64_t>(static_cast<std::uint32_t>(host_tlwe[i]));
      encode_word_le(glwe_payload.data() + i * glwe_word_bytes, glwe_word_bytes, value);
    }
  } else {
    throw std::invalid_argument("unsupported PBS primitive op");
  }

  const auto end = std::chrono::steady_clock::now();
  const std::uint64_t latency_ns =
      std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();

  gpu_runtime::ipc::SubmitResponse response{};
  response.status_code = 0;
  response.error_code = 0;
  response.latency_ns = latency_ns;
  response.glwe_bytes = static_cast<std::uint32_t>(glwe_payload.size());
  response.woks_latency_ns = latency_ns;
  response.ks_latency_ns = 0;
  response.sequence_no = 0;
  response.outstanding_descriptors = 0;
  response.reserved = 0;
  return response;
}

gpu_runtime::ipc::SubmitResponse TfheGpuExecutor::run_circuit_bootstrap_pipeline(
    const gpu_runtime::ipc::SubmitRequest& request,
    std::span<const std::uint8_t> tlwe_payload,
    std::vector<std::uint8_t>& glwe_payload) {
  struct StreamLease {
    TfheGpuExecutor* owner;
    cudaStream_t stream;
    explicit StreamLease(TfheGpuExecutor* o, cudaStream_t s)
        : owner(o), stream(s) {}
    ~StreamLease() {
      if (owner != nullptr) {
        owner->release_stream(stream);
      }
    }
    cudaStream_t get() const { return stream; }
  };

  StreamLease stream_lease(this, acquire_stream());
  cudaStream_t stream = stream_lease.get();

  std::lock_guard<std::mutex> context_lock(context_mutex_);

  const auto& desc = request.descriptor;
  std::cout << "[TFHE_GPU_EXEC][DESC] cmd_id=0x" << std::hex << desc.cmd_id
            << " mode=" << static_cast<int>(desc.mode)
            << " flags=0x" << static_cast<int>(desc.flags)
            << " tlwe_addr=0x" << desc.tlwe_addr
            << " glwe_addr=0x" << desc.glwe_addr
            << " status_addr=0x" << desc.status_addr
            << " tlwe_words=" << std::dec << desc.tlwe_words
            << " glwe_words=" << desc.glwe_words << std::endl;
  if (!layout_by_base_.empty()) {
    auto check_layout = [&](std::uint64_t addr, const char* label) {
      auto it = layout_by_base_.find(addr);
      if (it != layout_by_base_.end()) {
        std::cout << "[TFHE_GPU_EXEC][LAYOUT] " << label << " base 0x"
                  << std::hex << addr << std::dec << " -> " << it->second.name
                  << " bytes=0x" << std::hex << it->second.bytes << std::dec << std::endl;
      } else {
        std::cout << "[TFHE_GPU_EXEC][LAYOUT] " << label << " base 0x"
                  << std::hex << addr << std::dec << " not mapped" << std::endl;
      }
    };
    check_layout(desc.tlwe_addr, "TLWE");
    check_layout(desc.glwe_addr, "GLWE");
  }

  auto tlwe_words = std::max<std::uint32_t>(request.descriptor.tlwe_words, 1);
  std::size_t tlwe_word_bytes = safe_divide(tlwe_payload.size(), tlwe_words);

  // Optional override: if payload长度恰好可被 lvl1 TLWE 拆分，则在 BE 模式下纠正被 descriptor 截断的词数
  if (request.descriptor.mode == gpu_runtime::ipc::kDescriptorModeBitExtract) {
    const std::size_t lvl1_words = static_cast<std::size_t>(Context::n_lvl1) + 1;
    if (tlwe_payload.size() % lvl1_words == 0) {
      const std::size_t candidate_word_bytes = tlwe_payload.size() / lvl1_words;
      const bool override_enabled = env_flag_enabled("WOP_GPU_TLWE_OVERRIDE_LVL1");
      if ((tlwe_words != lvl1_words || tlwe_word_bytes != candidate_word_bytes) && override_enabled) {
        std::cout << "[TFHE_GPU_EXEC][TLWE] override tlwe_words=" << lvl1_words
                  << " word_bytes=" << candidate_word_bytes
                  << " (payload=" << tlwe_payload.size() << " bytes)" << std::endl;
        tlwe_words = static_cast<std::uint32_t>(lvl1_words);
        tlwe_word_bytes = candidate_word_bytes;
      }
    }
  }

  if (tlwe_word_bytes < kMinWordBytes) {
    throw std::invalid_argument("word size below 32-bit is not supported");
  }

  std::size_t glwe_word_bytes = tlwe_word_bytes;
  if (request.glwe_bytes != 0 && request.descriptor.glwe_words != 0) {
    glwe_word_bytes = safe_divide(static_cast<std::size_t>(request.glwe_bytes),
                                  static_cast<std::size_t>(request.descriptor.glwe_words));
    if (glwe_word_bytes < kMinWordBytes) {
      throw std::invalid_argument("glwe word size below 32-bit is not supported");
    }
  }

  if (dram_image_ && kVerifyDramTlwe && desc.tlwe_addr != 0) {
    std::vector<std::uint8_t> dram_tlwe(tlwe_payload.size());
    if (dram_image_->read_into(desc.tlwe_addr, std::span<std::uint8_t>(dram_tlwe.data(), dram_tlwe.size()))) {
      if (!std::equal(dram_tlwe.begin(), dram_tlwe.end(), tlwe_payload.begin())) {
        std::cout << "[TFHE_GPU_EXEC][DRAM] TLWE payload mismatch at addr=0x"
                  << std::hex << desc.tlwe_addr << std::dec
                  << " (first word differs)" << std::endl;
      }
    } else {
      std::cout << "[TFHE_GPU_EXEC][DRAM] TLWE addr 0x"
                << std::hex << desc.tlwe_addr << std::dec
                << " out of mapped range (size=" << dram_image_->size_bytes() << ")" << std::endl;
    }
  }

  // 对不同模式采用匹配的预期词长：CB/BE 使用 lvl0+1；VP 进入 WoKS 前已降为 lvl0+1
  std::size_t expected_words = static_cast<std::size_t>(Context::n_lvl0) + 1;
  int32_t** abar = ctx_->cbs.res_preMod;
  if (abar == nullptr) {
    throw std::runtime_error("ctx_->cbs.res_preMod is null");
  }
  if (ctx_->cbs.res_boot == nullptr) {
    throw std::runtime_error("ctx_->cbs.res_boot is null");
  }

  int current_device = 0;
  ensure_cuda_success(cudaGetDevice(&current_device), "cudaGetDevice");
  // 预取关键常量/输出缓冲，提高首次访问命中率。按可配置 chunk 划分，避免一次性大跨度。
  const int chunk_mb = parse_env_int("WOP_GPU_PREFETCH_CHUNK_MB", 64);
  const std::size_t chunk_bytes =
      (chunk_mb <= 0) ? std::numeric_limits<std::size_t>::max()
                      : static_cast<std::size_t>(chunk_mb) * 1024 * 1024;
  // 预取流优先用额外 stream，避免阻塞主流
  cudaStream_t prefetch_stream = perf_multistream_ ? acquire_stream() : stream;
  auto prefetch_chunked = [&](const void* ptr, std::size_t bytes, const char* tag) {
    std::size_t offset = 0;
    while (offset < bytes) {
      const std::size_t now = std::min(chunk_bytes, bytes - offset);
      ensure_cuda_success(
          cudaMemPrefetchAsync(const_cast<void*>(static_cast<const void*>(
                                   static_cast<const char*>(ptr) + offset)),
                               now,
                               current_device,
                               prefetch_stream),
          tag);
      offset += now;
    }
  };
  ensure_cuda_success(
      cudaMemPrefetchAsync(abar,
                           sizeof(int32_t*) * Context::CBS::MAX_BATCH_SIZE,
                           current_device,
                           prefetch_stream),
      "prefetch res_preMod pointers");
  ensure_cuda_success(
      cudaMemPrefetchAsync(ctx_->cbs.res_boot,
                           sizeof(LweSample64) * Context::CBS::MAX_BATCH_SIZE,
                           current_device,
                           prefetch_stream),
      "prefetch res_boot");
  const bool prefetch_key = env_flag_enabled("WOP_GPU_PREFETCH_KEY") || perf_mode_;
  const bool prefetch_per_level = env_flag_enabled("WOP_GPU_PREFETCH_PER_LEVEL");
  if (prefetch_key && ctx_->biglut.tgsw_radixs != nullptr) {
    const std::size_t tgsw_bytes =
        static_cast<std::size_t>(Context::BigLut::POOL_SIZE) * sizeof(TGswSample32);
    prefetch_chunked(ctx_->biglut.tgsw_radixs, tgsw_bytes, "prefetch biglut tgsw_radixs");
  }
  if (prefetch_key && ctx_->bkFFT_64 != nullptr) {
    const std::size_t bkfft_stride =
        static_cast<std::size_t>(Context::n_lvl0) * (Context::n_lvl2 + 1) * sizeof(double2);
    if (prefetch_per_level) {
      for (int ell = 0; ell < Context::ell_lvl2; ++ell) {
        const void* ptr = static_cast<const void*>(ctx_->bkFFT_64 + ell * (Context::n_lvl0 * (Context::n_lvl2 + 1)));
        prefetch_chunked(ptr, bkfft_stride, "prefetch bkFFT_64 level");
      }
    } else {
      const std::size_t bkfft_bytes =
          bkfft_stride * static_cast<std::size_t>(Context::ell_lvl2);
      prefetch_chunked(ctx_->bkFFT_64, bkfft_bytes, "prefetch bkFFT_64");
    }
  }
  if (prefetch_key && ctx_->privKS != nullptr) {
    const std::size_t privks_stride_lvl2 =
        static_cast<std::size_t>(Context::kslength_lvl21) *
        static_cast<std::size_t>(Context::ksbasebit_lvl21) *
        static_cast<std::size_t>(Context::n_lvl1 + 1) *
        sizeof(LweSample32);
    if (prefetch_per_level) {
      for (int z = 0; z < Context::n_lvl2; ++z) {
        const void* ptr = static_cast<const void*>(ctx_->privKS + z * (Context::kslength_lvl21 * Context::ksbasebit_lvl21 * (Context::n_lvl1 + 1)));
        prefetch_chunked(ptr, privks_stride_lvl2, "prefetch privKS level");
      }
    } else {
      const std::size_t privks_bytes =
          static_cast<std::size_t>(Context::n_lvl2) * privks_stride_lvl2;
      prefetch_chunked(ctx_->privKS, privks_bytes, "prefetch privKS");
    }
  }
  // Optional prefetch; guard by nullptr/availability
  // bk_fft_lvl2 结构在 ctx_->bk_fft 中（二维指针），此处跳过直接预取以免误解指针层级
  if (ctx_->preKS[0][0] != nullptr) {
    prefetch_chunked(ctx_->preKS[0][0],
                     sizeof(LweSample32) * Context::CBS::MAX_BATCH_SIZE * (Context::n_lvl0 + 1),
                     "prefetch preKS lvl0");
  }
  ensure_cuda_success(cudaStreamSynchronize(prefetch_stream), "prefetch stream sync");
  if (prefetch_stream != stream) {
    release_stream(prefetch_stream);
  }
  ensure_cuda_success(cudaDeviceSynchronize(), "prefetch sync");

  std::cout << "[TFHE_GPU_EXEC] res_preMod=" << static_cast<const void*>(abar)
            << " res_boot=" << static_cast<const void*>(ctx_->cbs.res_boot)
            << std::endl;

  if (const char* dump_env_dbg = std::getenv("WOP_GPU_DUMP_TLWE_IN")) {
    std::cout << "[TFHE_GPU_EXEC][DUMP] env WOP_GPU_DUMP_TLWE_IN=" << dump_env_dbg
              << " size=" << tlwe_payload.size() << std::endl;
  }
  if (const char* dump_env = std::getenv("WOP_GPU_DUMP_TLWE_IN");
      dump_env != nullptr && *dump_env != '\0') {
    maybe_dump_payload(dump_env, tlwe_payload);
  }

  int32_t* abar0 = abar[0];
  if (abar0 == nullptr) {
    throw std::runtime_error("ctx_->cbs.res_preMod[0] is null");
  }
  const char* dump_env = std::getenv("WOP_GPU_DUMP_CB");
  const bool dump_enabled = dump_env != nullptr && *dump_env != '\0';
  std::string dump_base;
  if (dump_enabled) {
    dump_base = dump_env;
  }

  const bool premod_input =
      (request.descriptor.flags & gpu_runtime::ipc::kDescriptorFlagPremodInput) != 0;

  // 复用 host preMod 缓冲，降低反复分配开销
  host_premod_scratch_.assign(expected_words, 0);
  std::int32_t* host_pre_mod = host_premod_scratch_.data();
  if (premod_input) {
    if (tlwe_words != expected_words) {
      throw std::invalid_argument("premod input requires tlwe_words == (n_lvl0 + 1)");
    }
    if (tlwe_word_bytes != sizeof(std::int32_t)) {
      throw std::invalid_argument("premod input requires 4-byte words");
    }
    const std::size_t required_bytes = expected_words * sizeof(std::int32_t);
    if (tlwe_payload.size() < required_bytes) {
      throw std::invalid_argument("premod payload too short");
    }
    std::memcpy(host_pre_mod, tlwe_payload.data(), required_bytes);
    for (std::size_t i = 0; i < std::min<std::size_t>(8, expected_words); ++i) {
      std::cout << "[TFHE_GPU_EXEC][PREMOD] idx=" << i
                << " value=0x" << std::hex
                << static_cast<std::uint32_t>(host_pre_mod[i])
                << std::dec << std::endl;
    }
  } else {
    const std::size_t copy_words = std::min<std::size_t>(tlwe_words, expected_words);
    for (std::size_t i = 0; i < copy_words; ++i) {
      const std::uint8_t* src = tlwe_payload.data() + i * tlwe_word_bytes;
      const std::int64_t decoded = decode_word_le_signed(src, tlwe_word_bytes);
      const std::int32_t normalized = normalize_pre_modswitch(decoded);
      host_pre_mod[i] = normalized;
      if (i < 8) {
        std::cout << "[TFHE_GPU_EXEC][TLWE] idx=" << i
                  << " raw=0x" << std::hex << static_cast<std::uint64_t>(decoded)
                  << " premod=0x" << static_cast<std::uint32_t>(normalized)
                  << std::dec << std::endl;
      }
    }
    if (expected_words > 0) {
      const std::size_t b_index = (tlwe_words > 0) ? (tlwe_words - 1) : 0;
      const std::uint8_t* src = tlwe_payload.data() + b_index * tlwe_word_bytes;
      const std::int64_t decoded = decode_word_le_signed(src, tlwe_word_bytes);
      host_pre_mod[expected_words - 1] = normalize_pre_modswitch(decoded);
    }
  }
  if (const char* vp_dbg = std::getenv("TFHE_GPU_VP_DEBUG");
      vp_dbg != nullptr && *vp_dbg != '\0') {
    std::cout << "[TFHE_GPU_VP] premod_host[0..7]={";
    for (int i = 0; i < 8; ++i) {
      std::cout << host_pre_mod[i];
      if (i != 7) std::cout << ",";
    }
    std::cout << "}" << std::endl;
  }
  if (const char* dump_env = std::getenv("WOP_GPU_DUMP_PREMOD");
      dump_env != nullptr && *dump_env != '\0') {
    const std::span<const std::uint8_t> bytes(
        reinterpret_cast<const std::uint8_t*>(host_pre_mod),
        expected_words * sizeof(std::int32_t));
    maybe_dump_payload(dump_env, bytes);
  }
  if (const char* tlwe_dump = std::getenv("WOP_GPU_DUMP_TLWE_IN");
      tlwe_dump != nullptr && *tlwe_dump != '\0') {
    // VP 路径已在入口 dump 原始 20500 词 TLWE；避免覆盖，将 CB 入口 dump 仅限非 VP
    if (request.descriptor.mode != gpu_runtime::ipc::kDescriptorModeVerticalPacking) {
      const std::span<const std::uint8_t> bytes(
          reinterpret_cast<const std::uint8_t*>(tlwe_payload.data()),
          tlwe_payload.size());
      maybe_dump_payload(tlwe_dump, bytes);
      std::cout << "[TFHE_GPU_EXEC][DUMP] tlwe_in -> " << tlwe_dump
                << " (bytes=" << tlwe_payload.size() << " words=" << tlwe_words
                << " word_bytes=" << tlwe_word_bytes << ")" << std::endl;
    }
  }
  const std::size_t abar_bytes = expected_words * sizeof(std::int32_t);
  // H2D：可选使用独立 stream 以便与后续计算重叠
  cudaEvent_t evt_h2d_start = nullptr, evt_h2d_done = nullptr;
  const bool perf_timing = perf_mode_ || env_flag_enabled("WOP_GPU_PERF_TIMING");
  cudaStream_t h2d_stream = stream;
  if (perf_multistream_) {
    cudaStream_t extra = acquire_stream();
    if (extra != nullptr) {
      h2d_stream = extra;
    }
  }
  if (perf_timing) {
    ensure_cuda_success(cudaEventCreate(&evt_h2d_start), "create h2d start event");
    ensure_cuda_success(cudaEventCreate(&evt_h2d_done), "create h2d done event");
    ensure_cuda_success(cudaEventRecord(evt_h2d_start, h2d_stream), "record h2d start");
  }
  ensure_cuda_success(
      cudaMemcpyAsync(abar0, host_pre_mod, abar_bytes, cudaMemcpyHostToDevice, h2d_stream),
      "copy preModSwitch data to device");
  if (perf_timing) {
    ensure_cuda_success(cudaEventRecord(evt_h2d_done, h2d_stream), "record h2d done");
  }
  // 计算 stream 等待 H2D 完成
  if (h2d_stream != stream) {
    ensure_cuda_success(cudaStreamWaitEvent(stream, evt_h2d_done, 0), "compute wait h2d");
  }
  if (dump_enabled) {
    std::vector<std::int32_t> dbg(expected_words);
    ensure_cuda_success(
        cudaMemcpy(dbg.data(), abar0, abar_bytes, cudaMemcpyDeviceToHost),
        "read back preModSwitch");
    std::cout << "[TFHE_GPU_EXEC][CB] abar[0..7]=";
    for (int i = 0; i < std::min<std::size_t>(8, dbg.size()); ++i) {
      std::cout << dbg[i] << (i == std::min<std::size_t>(8, dbg.size()) - 1 ? "" : ",");
    }
    std::cout << std::endl;
  }
  ensure_cuda_success(
      cudaMemPrefetchAsync(abar0, abar_bytes, current_device, stream),
      "prefetch abar to device");
  ensure_cuda_success(cudaStreamSynchronize(stream), "prefetch abar stream sync");
  ensure_cuda_success(cudaDeviceSynchronize(), "prefetch abar sync");

  LweSample64* result_lwe = ctx_->cbs.res_boot;
  const bool is_cb_mode =
      request.descriptor.mode == gpu_runtime::ipc::kDescriptorModeCircuitBootstrap;
  const bool step4_only =
      !is_step5_only_descriptor(request) &&
      ((request.descriptor.flags & gpu_runtime::ipc::kDescriptorFlagStep4Only) != 0);
  const bool force_cpu_woks = env_flag_enabled("WOP_GPU_FORCE_CPU_WOKS");

  auto dump_woks_buffer = [&](const char* tag) {
    if (!dump_enabled) {
      return;
    }
    std::vector<Torus64> dbg_boot(static_cast<std::size_t>(Context::n_lvl2) + 1);
    ensure_cuda_success(
        cudaMemcpy(dbg_boot.data(),
                   result_lwe[0].a,
                   dbg_boot.size() * sizeof(Torus64),
                   cudaMemcpyDeviceToHost),
        "dump res_boot");
    std::cout << tag << " lwe[0..3]={";
    for (int i = 0; i < 4; ++i) {
      std::cout << "0x" << std::hex << static_cast<std::uint64_t>(dbg_boot[i]) << std::dec;
      if (i != 3) std::cout << ",";
    }
    std::cout << "} b=0x" << std::hex << static_cast<std::uint64_t>(dbg_boot[Context::n_lvl2])
              << std::dec << std::endl;
  };

  TGswSample32* privks_buffer = ctx_->biglut.tgsw_radixs;
  if (privks_buffer == nullptr) {
    throw std::runtime_error("ctx_->biglut.tgsw_radixs is null");
  }

  std::uint64_t woks_latency_ns = 0;
  std::uint64_t ks_latency_ns = 0;

  if (is_cb_mode) {
    Torus64 mu = UINT64_C(0x8000000000000000);
    std::cout << "[TFHE_GPU_EXEC][CB] using mu=0x" << std::hex << mu << std::dec << std::endl;
    const auto woks_start_time = std::chrono::steady_clock::now();
    circuit_bootstrap_wo_ks(result_lwe, mu, const_cast<const int32_t**>(abar), 1, ctx_.get());
    ensure_cuda_success(cudaStreamSynchronize(stream), "woks stream synchronize");
    ensure_cuda_success(cudaDeviceSynchronize(), "cudaDeviceSynchronize");
    const auto woks_end_time = std::chrono::steady_clock::now();
    woks_latency_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                          woks_end_time - woks_start_time)
                          .count();
    dump_woks_buffer("[TFHE_GPU_EXEC][WOKS]");

    if (step4_only) {
      std::cout << "[TFHE_GPU_EXEC][CB] step4-only flag set; skip privks" << std::endl;
      ks_latency_ns = 0;
    } else {
      const auto ks_start_time = std::chrono::steady_clock::now();
      for (int level = 0; level < Context::ell_lvl1; ++level) {
        circuit_privks(privks_buffer, result_lwe, 1, level, ctx_.get());
      }
      ensure_cuda_success(cudaStreamSynchronize(stream), "privks stream synchronize");
      ensure_cuda_success(cudaDeviceSynchronize(), "privks synchronize");
      const auto ks_end_time = std::chrono::steady_clock::now();
      ks_latency_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                          ks_end_time - ks_start_time)
                          .count();
    }
  } else {
    // VP/BE: cpu_reference_runner 只跑一次 WoKS（mu = 1<<(64-bgbit_lvl1)），不跑 privks。
    // 之前这里按 ell_lvl1 循环会导致最终输出落在最后一层 mu（例如 1<<48），与 CPU golden 不一致。
    const int shift = 64 - Context::bgbit_lvl1;
    const Torus64 mu = (shift <= 0) ? UINT64_C(0) : (UINT64_C(1) << shift);
    const auto woks_start_time = std::chrono::steady_clock::now();
    circuit_bootstrap_wo_ks(result_lwe, mu, const_cast<const int32_t**>(abar), 1, ctx_.get());
    ensure_cuda_success(cudaStreamSynchronize(stream), "woks stream synchronize");
    ensure_cuda_success(cudaDeviceSynchronize(), "cudaDeviceSynchronize");
    const auto woks_end_time = std::chrono::steady_clock::now();
    woks_latency_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                          woks_end_time - woks_start_time)
                          .count();
    dump_woks_buffer("[TFHE_GPU_EXEC][WOKS]");
    ks_latency_ns = 0;
  }

  std::uint64_t total_latency_ns = woks_latency_ns + ks_latency_ns;

  const std::size_t available_words = static_cast<std::size_t>(Context::n_lvl2) + 1;
  std::size_t requested_words = request.descriptor.glwe_words;
  if (requested_words == 0) {
    requested_words = request.descriptor.tlwe_words;
  }
  if (requested_words == 0) {
    requested_words = static_cast<std::uint32_t>(available_words);
  }
  const bool use_woks_stage = golden_stage_is_woks();
  const std::size_t result_words = std::min<std::size_t>(requested_words, available_words);
  const std::size_t compare_words = use_woks_stage ? available_words : result_words;
  const std::size_t result_bytes = result_words * glwe_word_bytes;
  const auto compare_keyset = resolve_keyset_path_for_compare(ctx_.get());
  const std::filesystem::path* compare_keyset_ptr =
      compare_keyset ? &*compare_keyset : nullptr;

  host_lwe_scratch_.assign(static_cast<std::size_t>(Context::n_lvl2) + 1, 0);
  Torus64* host_lwe = host_lwe_scratch_.data();

  cudaEvent_t evt_compute_done = nullptr, evt_d2h_done = nullptr;
  if (perf_timing) {
    ensure_cuda_success(cudaEventCreate(&evt_compute_done), "create compute done event");
    ensure_cuda_success(cudaEventCreate(&evt_d2h_done), "create d2h done event");
    ensure_cuda_success(cudaEventRecord(evt_compute_done, stream), "record compute done");
  }

  // D2H：可选独立 stream，提高重叠度
  cudaStream_t d2h_stream = stream;
  if (perf_multistream_) {
    cudaStream_t extra = acquire_stream();
    if (extra != nullptr) {
      d2h_stream = extra;
    }
  }
  if (perf_timing) {
    ensure_cuda_success(cudaEventRecord(evt_d2h_done, d2h_stream), "record d2h done (placeholder)");
  }
  ensure_cuda_success(
      cudaMemcpyAsync(host_lwe,
                      result_lwe[0].a,
                      (static_cast<std::size_t>(Context::n_lvl2) + 1) * sizeof(Torus64),
                      cudaMemcpyDeviceToHost,
                      d2h_stream),
      "copy result lwe");
  if (perf_timing) {
    ensure_cuda_success(cudaEventRecord(evt_d2h_done, d2h_stream), "record d2h done");
  }
  ensure_cuda_success(cudaStreamSynchronize(d2h_stream), "sync result copy");

  bool cpu_woks_override_applied = false;
  if (perf_timing) {
    float ms_h2d = 0.f, ms_compute = 0.f, ms_d2h = 0.f;
    if (evt_h2d_start && evt_h2d_done) {
      cudaEventElapsedTime(&ms_h2d, evt_h2d_start, evt_h2d_done);
    }
    if (evt_h2d_done && evt_compute_done) {
      cudaEventElapsedTime(&ms_compute, evt_h2d_done, evt_compute_done);
    }
    if (evt_compute_done && evt_d2h_done) {
      cudaEventElapsedTime(&ms_d2h, evt_compute_done, evt_d2h_done);
    }
    const std::uint64_t h2d_ns = static_cast<std::uint64_t>(ms_h2d * 1'000'000.0f);
    const std::uint64_t comp_ns = static_cast<std::uint64_t>(ms_compute * 1'000'000.0f);
    const std::uint64_t d2h_ns = static_cast<std::uint64_t>(ms_d2h * 1'000'000.0f);
    std::cout << "[TFHE_GPU_EXEC][PERF] h2d_ns=" << h2d_ns
              << " compute_ns=" << comp_ns
              << " d2h_ns=" << d2h_ns << std::endl;
  }

  if (force_cpu_woks) {
    const std::size_t cpu_words = std::max(compare_words, available_words);
    std::uint64_t cpu_latency_ns = 0;
    if (auto cpu_override = maybe_run_cpu_woks_override(
            tlwe_payload,
            tlwe_words,
            cpu_words,
            glwe_word_bytes,
            request.descriptor.mode,
            request.descriptor.flags,
            compare_keyset_ptr,
            cpu_latency_ns)) {
      const std::size_t available_cpu_words = cpu_override->size() / glwe_word_bytes;
      const std::size_t copy_words = std::min<std::size_t>(
          std::min<std::size_t>(available_cpu_words, host_lwe_scratch_.size()), cpu_words);
      for (std::size_t i = 0; i < copy_words; ++i) {
        host_lwe[i] = static_cast<Torus64>(
            read_word64_le(cpu_override->data() + i * glwe_word_bytes, glwe_word_bytes));
      }
      ensure_cuda_success(
          cudaMemcpy(result_lwe[0].a,
                     host_lwe,
                     copy_words * sizeof(Torus64),
                     cudaMemcpyHostToDevice),
          "apply cpu woks override");
      cpu_woks_override_applied = true;
      woks_latency_ns = cpu_latency_ns;
      ks_latency_ns = 0;
    }
  }
  total_latency_ns = woks_latency_ns + ks_latency_ns;

  // === Pure-GPU WoKS 数值校准 ===
  // 默认启用两步校准：1) 2/N 缩放 2) float->torus 重新量化，确保与 cpu_reference_runner 一致。
  // 如需禁用，可设置 WOP_GPU_WOKS_NOSCALE=1；单独禁用某步仍可用旧 env 控制。
  // 当启用 spqlios FFT 表时，GPU 输出已对齐 CPU，避免再做二次缩放。
  // 注意：若已应用 CPU override，则 host_lwe_scratch_ 已是 cpu_reference_runner 的 Torus64 输出，
  // 继续做 rescale/requant 会二次缩放导致 golden mismatch。
  const bool spqlios_fft_enabled = env_flag_enabled("TFHE_GPU_SPQLIOS_FFT");
  const char* spqlios_fft_table = std::getenv("TFHE_GPU_SPQLIOS_FFT_TABLE");
  const bool spqlios_fft_ready =
      spqlios_fft_enabled && (spqlios_fft_table != nullptr && *spqlios_fft_table != '\0');
  const bool disable_woks_scale =
      env_flag_enabled("WOP_GPU_WOKS_NOSCALE") || spqlios_fft_ready;
  const bool do_rescale = !disable_woks_scale || env_flag_enabled("WOP_GPU_WOKS_RESCALE");
  const bool do_requant = !disable_woks_scale || env_flag_enabled("WOP_GPU_WOKS_FLOAT2TORUS");

  if (!cpu_woks_override_applied) {
    if (do_rescale) {
      const long double scale = 2.0L / static_cast<long double>(Context::n_lvl2);
      for (auto& v : host_lwe_scratch_) {
        const long double scaled = static_cast<long double>(v) * scale;
        v = static_cast<Torus64>(llrint(scaled));
      }
    }

    if (do_requant) {
      constexpr long double two_pi = 6.28318530717958647692L;
      const long double torus_to_real = two_pi / std::pow(2.0L, 64);
      const long double real_to_torus = std::pow(2.0L, 63) / 3.14159265358979323846L;
      for (auto& v : host_lwe_scratch_) {
        const long double real =
            static_cast<long double>(static_cast<int64_t>(v)) * torus_to_real;
        const long double torus = real * real_to_torus;
        v = static_cast<Torus64>(llrint(torus));
      }
    }
  }

  // Debug/兜底：如开启 WOP_GPU_WOKS_OVERRIDE，则用 CPU 结果覆盖 GPU WoKS，保证输出正确
  if (!force_cpu_woks && env_flag_enabled("WOP_GPU_WOKS_OVERRIDE")) {
    const std::size_t cpu_words = std::max(compare_words, available_words);
    std::uint64_t cpu_latency_ns = 0;
    if (auto cpu_override = maybe_run_cpu_woks_override(
            tlwe_payload,
            tlwe_words,
            cpu_words,
            glwe_word_bytes,
            request.descriptor.mode,
            request.descriptor.flags,
            compare_keyset_ptr,
            cpu_latency_ns)) {
      const std::size_t available_cpu_words = cpu_override->size() / glwe_word_bytes;
      const std::size_t copy_words = std::min<std::size_t>(
          std::min<std::size_t>(available_cpu_words, host_lwe_scratch_.size()), cpu_words);
      for (std::size_t i = 0; i < copy_words; ++i) {
        host_lwe[i] = static_cast<Torus64>(
            read_word64_le(cpu_override->data() + i * glwe_word_bytes, glwe_word_bytes));
      }
      woks_latency_ns = cpu_latency_ns;
      ks_latency_ns = 0;
      total_latency_ns = woks_latency_ns + ks_latency_ns;
      std::cout << "[TFHE_GPU_EXEC][WOKS_OVERRIDE] applied CPU WoKS output (words="
                << copy_words << ", latency_ns=" << cpu_latency_ns << ")" << std::endl;
    }
  }

  // Debug-only: compare GPU WoKS against CPU reference without overriding results
  if (env_flag_enabled("WOP_GPU_WOKS_DEBUG")) {
    run_cpu_woks_debug_compare(tlwe_payload,
                               host_lwe_scratch_,
                               tlwe_words,
                               compare_words,
                               glwe_word_bytes,
                               request.descriptor.mode,
                               request.descriptor.flags,
                               compare_keyset_ptr);
  }

  if (const char* woks_dump = std::getenv("WOP_GPU_DUMP_WOKS");
      woks_dump != nullptr && *woks_dump != '\0') {
    const std::span<const std::uint8_t> bytes(
        reinterpret_cast<const std::uint8_t*>(host_lwe),
        host_lwe_scratch_.size() * sizeof(Torus64));
    maybe_dump_payload(woks_dump, bytes);
  }

  if (const char* accfft_dump = std::getenv("WOP_GPU_DUMP_ACCFFT");
      accfft_dump != nullptr && *accfft_dump != '\0') {
    try {
      // Dump WoKS输出（时间域 host_lwe，与最终使用结果一致），避免 GPU 内部缓冲为 0 的误判
      const std::span<const std::uint8_t> bytes(
          reinterpret_cast<const std::uint8_t*>(host_lwe),
          host_lwe_scratch_.size() * sizeof(Torus64));
      maybe_dump_payload(accfft_dump, bytes);
      std::cout << "[TFHE_GPU_EXEC][DUMP] woks_out -> " << accfft_dump
                << " (words=" << host_lwe_scratch_.size() << ")" << std::endl;
    } catch (const std::exception& ex) {
      std::cerr << "[TFHE_GPU_EXEC][DUMP] acc_fft failed: " << ex.what() << std::endl;
    }
  }
  if (dump_enabled) {
    std::vector<Torus64> acc_b_slice(static_cast<std::size_t>(Context::n_lvl2), 0);
    ensure_cuda_success(
        cudaMemcpy(acc_b_slice.data(),
                   ctx_->cbs.acc[0][0].b->coefs,
                   acc_b_slice.size() * sizeof(Torus64),
                   cudaMemcpyDeviceToHost),
        "dump acc b slice");
    const std::string acc_b_path = dump_base + "_acc_b.bin";
    maybe_dump_payload(
        acc_b_path.c_str(),
        std::span<const std::uint8_t>(
            reinterpret_cast<const std::uint8_t*>(acc_b_slice.data()),
            acc_b_slice.size() * sizeof(Torus64)));
    std::cout << "[TFHE_GPU_EXEC][DUMP] acc_b -> " << acc_b_path
              << " (words=" << acc_b_slice.size() << ")" << std::endl;
    std::cout << "[TFHE_GPU_EXEC][CB] acc_b[0..7]={";
    for (int i = 0; i < 8; ++i) {
      std::cout << "0x" << std::hex << static_cast<std::uint64_t>(acc_b_slice[i]) << std::dec;
      if (i != 7) std::cout << ",";
    }
    std::cout << "}" << std::endl;
    std::cout << "[TFHE_GPU_EXEC][CB] host_lwe[0..3]={";
    for (int i = 0; i < 4; ++i) {
      std::cout << "0x" << std::hex << static_cast<std::uint64_t>(host_lwe[i]) << std::dec;
      if (i != 3) std::cout << ",";
    }
    std::cout << "} b=0x" << std::hex << static_cast<std::uint64_t>(host_lwe[Context::n_lvl2])
              << std::dec << std::endl;
  }
  // Prepare payloads: compare may use full TLWE, returned glwe respects descriptor
  std::vector<std::uint8_t> compare_payload(compare_words * glwe_word_bytes);
  for (std::size_t i = 0; i < compare_words; ++i) {
    const std::uint64_t value = static_cast<std::uint64_t>(host_lwe[i]);
    encode_word_le(compare_payload.data() + i * glwe_word_bytes, glwe_word_bytes, value);
  }
  glwe_payload.resize(result_bytes);
  for (std::size_t i = 0; i < result_words; ++i) {
    const std::uint64_t value = static_cast<std::uint64_t>(host_lwe[i]);
    encode_word_le(glwe_payload.data() + i * glwe_word_bytes, glwe_word_bytes, value);
  }

  if (dump_enabled) {
    maybe_dump_payload((dump_base + "_tlwe.bin").c_str(), tlwe_payload);
    maybe_dump_payload((dump_base + "_gpu_glwe.bin").c_str(),
                       std::span<const std::uint8_t>(glwe_payload.data(), glwe_payload.size()));
  }

  if (perf_timing) {
    if (evt_h2d_start) cudaEventDestroy(evt_h2d_start);
    if (evt_h2d_done) cudaEventDestroy(evt_h2d_done);
    if (evt_compute_done) cudaEventDestroy(evt_compute_done);
    if (evt_d2h_done) cudaEventDestroy(evt_d2h_done);
  }
  if (perf_multistream_) {
    if (h2d_stream != nullptr && h2d_stream != stream) release_stream(h2d_stream);
    if (d2h_stream != nullptr && d2h_stream != stream) release_stream(d2h_stream);
  }

  std::uint32_t golden_mismatches = 0;
  if (auto golden = run_golden_compare(
          tlwe_payload,
          std::span<const std::uint8_t>(compare_payload.data(), compare_payload.size()),
          tlwe_words,
          compare_words,
          glwe_word_bytes,
          request.descriptor.mode,
          request.descriptor.flags,
          compare_keyset_ptr)) {
    golden_mismatches = golden->mismatches;
    if (golden->mismatches == 0) {
      std::cout << "[TFHE_GPU_EXEC][GOLDEN] match tlwe_words=" << tlwe_words
                << " result_words=" << result_words << std::endl;
    } else {
      std::cout << "[TFHE_GPU_EXEC][GOLDEN] mismatch count=" << golden->mismatches
                << " max_abs_diff=" << golden->max_abs_diff << std::endl;
      if (dump_enabled && golden->reference_payload.size() >= glwe_payload.size()) {
        maybe_dump_payload((dump_base + "_ref_glwe.bin").c_str(),
                           std::span<const std::uint8_t>(golden->reference_payload.data(),
                                                         glwe_payload.size()));
      }
    }
  } else {
    // 未启用黄金比对时，返回 0 避免 0xFFFFFFFE 误报
    golden_mismatches = 0;
  }

  gpu_runtime::ipc::SubmitResponse response{};
  response.status_code = 0;
  response.error_code = 0;
  response.latency_ns = total_latency_ns;
  response.glwe_bytes = static_cast<std::uint32_t>(result_bytes);
  response.woks_latency_ns = woks_latency_ns;
  response.ks_latency_ns = ks_latency_ns;
  response.sequence_no = 0;
  response.outstanding_descriptors = 0;
  response.reserved = golden_mismatches;
  if (golden_mismatches != 0) {
    response.error_code |= kGoldenMismatchErrorBit;
  }
  return response;
}

gpu_runtime::ipc::SubmitResponse TfheGpuExecutor::run_vertical_packing_pipeline(
    const gpu_runtime::ipc::SubmitRequest& request,
    std::span<const std::uint8_t> tlwe_payload,
    std::vector<std::uint8_t>& glwe_payload) {
  const std::size_t word_bytes = safe_divide(tlwe_payload.size(), request.descriptor.tlwe_words);
  if (word_bytes < kMinWordBytes) {
    throw std::invalid_argument("vertical packing payload word size below 32-bit");
  }
  const std::size_t expect_tlwe_bytes =
      static_cast<std::size_t>(request.descriptor.tlwe_words) * word_bytes;
  if (tlwe_payload.size() != expect_tlwe_bytes) {
    throw std::invalid_argument("VP payload size mismatch: got " +
                                std::to_string(tlwe_payload.size()) +
                                " expect " + std::to_string(expect_tlwe_bytes));
  }
  if (const char* dump_env = std::getenv("WOP_GPU_DUMP_TLWE_IN");
      dump_env != nullptr && *dump_env != '\0') {
    maybe_dump_payload(dump_env, tlwe_payload);
    std::cout << "[TFHE_GPU_EXEC][DUMP] VP tlwe_in -> " << dump_env
              << " (bytes=" << tlwe_payload.size()
              << " words=" << request.descriptor.tlwe_words
              << " word_bytes=" << word_bytes << ")" << std::endl;
  }
  const std::size_t words_per_sample = static_cast<std::size_t>(Context::n_lvl1) + 1;
  if (words_per_sample == 0) {
    throw std::runtime_error("invalid N_lvl1");
  }
  if (request.descriptor.tlwe_words % words_per_sample != 0) {
    throw std::invalid_argument("VP payload length not aligned to level-1 TLWE size");
  }
  const std::size_t total_samples = request.descriptor.tlwe_words / words_per_sample;
  constexpr std::size_t kVpInputSamples = 20;
  if (total_samples < kVpInputSamples) {
    throw std::invalid_argument("VP payload must contain at least 20 level-1 TLWE samples");
  }
  if (total_samples != kVpInputSamples) {
    std::cerr << "[TFHE_GPU_EXEC][VP] payload contains " << total_samples
              << " lvl1 samples, using first " << kVpInputSamples << std::endl;
  }
  const std::size_t sample_count = kVpInputSamples;

  std::vector<std::uint8_t> ks_payload;
  std::uint64_t pre_pipeline_ns = 0;
  {
    const auto pre_start_time = std::chrono::steady_clock::now();
    struct StreamLease {
      TfheGpuExecutor* owner;
      cudaStream_t stream;
      explicit StreamLease(TfheGpuExecutor* o, cudaStream_t s) : owner(o), stream(s) {}
      ~StreamLease() {
        if (owner != nullptr) {
          owner->release_stream(stream);
        }
      }
    };

    StreamLease stream_lease(this, acquire_stream());
    cudaStream_t stream = stream_lease.stream;

    std::lock_guard<std::mutex> context_lock(context_mutex_);

    auto decode_sample = [&](std::size_t sample_index, std::span<std::int32_t> out_words) {
      const std::size_t offset_words = sample_index * words_per_sample;
      for (std::size_t i = 0; i < words_per_sample; ++i) {
        const std::uint8_t* src = tlwe_payload.data() + (offset_words + i) * word_bytes;
        // TLWE payload可能是 torus32(4B) 或 torus64(8B)。若为 8B，需要取高 32bit（与 CPU KeySwitch 输入一致），
        // 而不是低 32bit，否则会丢失符号/幅度导致 biglut/KS 全偏。
        std::uint64_t raw64 = 0;
        const std::size_t limit = std::min<std::size_t>(word_bytes, sizeof(raw64));
        for (std::size_t b = 0; b < limit; ++b) {
          raw64 |= static_cast<std::uint64_t>(src[b]) << (8 * b);
        }
        // 上层资产使用 torus32 存储在低 32 bit，这里直接取低 32 bit。
        const std::uint32_t torus32 = static_cast<std::uint32_t>(raw64 & 0xFFFFFFFFu);
        out_words[i] = static_cast<std::int32_t>(torus32);
      }
    };

    std::vector<std::int32_t> host_sample(words_per_sample);
    auto lwe_inputs = new_array1<LweSample32>(sample_count, Context::n_lvl1);
    for (std::size_t sample = 0; sample < sample_count; ++sample) {
      decode_sample(sample, std::span<std::int32_t>(host_sample));
      ensure_cuda_success(
          cudaMemcpyAsync(lwe_inputs[sample].a,
                          host_sample.data(),
                          words_per_sample * sizeof(std::int32_t),
                          cudaMemcpyHostToDevice,
                          stream),
          "vp copy input sample");
    }
    ensure_cuda_success(cudaStreamSynchronize(stream), "vp input sync");
    if (const char* dump_env = std::getenv("WOP_GPU_DUMP_VP_LVL1");
        dump_env != nullptr && *dump_env != '\0') {
      std::vector<std::int32_t> lvl1_words(sample_count * words_per_sample);
      for (std::size_t sample = 0; sample < sample_count; ++sample) {
        ensure_cuda_success(
            cudaMemcpy(lvl1_words.data() + sample * words_per_sample,
                       lwe_inputs[sample].a,
                       words_per_sample * sizeof(std::int32_t),
                       cudaMemcpyDeviceToHost),
            "dump vp lvl1 inputs");
      }
      maybe_dump_payload(dump_env,
                         std::span<const std::uint8_t>(
                             reinterpret_cast<const std::uint8_t*>(lvl1_words.data()),
                             lvl1_words.size() * sizeof(std::int32_t)));
    }

  int lut_len = 1;
  const TLweSample32** lut_table = const_cast<const TLweSample32**>(ctx_->TLweLuts.biglut_test);
  if ((request.descriptor.flags & kFlagVpLutExpMinus) != 0) {
    lut_len = NUM_TOTAL_SIZE;
    lut_table = const_cast<const TLweSample32**>(ctx_->TLweLuts.exp_minus);
  }

  int vp_select = static_cast<int>(parse_env_u64("WOP_GPU_VP_SELECT", 0));
  if (vp_select < 0) {
    vp_select = 0;
  }
  if (vp_select >= lut_len) {
    vp_select = lut_len - 1;
  }

  auto biglut_output = new_array1<LweSample32>(lut_len, Context::n_lvl1);
  if (const char* dump_env = std::getenv("WOP_GPU_DUMP_VP_LVL1_RAW");
      dump_env != nullptr && *dump_env != '\0') {
    // Dump 输入 lvl1 TLWE（20×(n_lvl1+1) torus32），便于 CPU 前级对齐
    std::vector<std::int32_t> lvl1_words(sample_count * words_per_sample);
    for (std::size_t sample = 0; sample < sample_count; ++sample) {
      ensure_cuda_success(
          cudaMemcpy(lvl1_words.data() + sample * words_per_sample,
                     lwe_inputs[sample].a,
                     words_per_sample * sizeof(std::int32_t),
                     cudaMemcpyDeviceToHost),
          "dump vp lvl1 inputs raw");
    }
    maybe_dump_payload(
        dump_env,
        std::span<const std::uint8_t>(
            reinterpret_cast<const std::uint8_t*>(lvl1_words.data()),
            lvl1_words.size() * sizeof(std::int32_t)));
    std::cout << "[TFHE_GPU_VP] dump lvl1 inputs raw -> " << dump_env << std::endl;
  }

  if (const char* dump_env = std::getenv("WOP_GPU_DUMP_VP_PREKS");
      dump_env != nullptr && *dump_env != '\0') {
    // Dump第一组 preKS（n_lvl0+1），用于核对 keyset 导入/prec_offset
    const std::size_t preks_words = static_cast<std::size_t>(Context::n_lvl0) + 1;
    std::vector<std::int32_t> preks(preks_words);
    ensure_cuda_success(
        cudaMemcpy(preks.data(),
                   ctx_->preKS[0][0][0].a,
                   preks_words * sizeof(std::int32_t),
                   cudaMemcpyDeviceToHost),
        "dump vp preKS");
    maybe_dump_payload(
        dump_env,
        std::span<const std::uint8_t>(
            reinterpret_cast<const std::uint8_t*>(preks.data()),
            preks.size() * sizeof(std::int32_t)));
    std::cout << "[TFHE_GPU_VP] dump preKS (i=0,j=0,u=0) -> " << dump_env << std::endl;
  }
  if (const char* dump_lut = std::getenv("WOP_GPU_DUMP_BIGLUT_TABLE");
      dump_lut != nullptr && *dump_lut != '\0') {
    const int N = Context::N_lvl1;
    std::vector<std::int32_t> lut(N);
    ensure_cuda_success(
        cudaMemcpy(lut.data(),
                   lut_table[0][0].b->coefs,
                   N * sizeof(std::int32_t),
                   cudaMemcpyDeviceToHost),
        "dump biglut table");
    maybe_dump_payload(dump_lut,
                       std::span<const std::uint8_t>(
                           reinterpret_cast<const std::uint8_t*>(lut.data()),
                           lut.size() * sizeof(std::int32_t)));
    std::cout << "[TFHE_GPU_VP] dumped biglut_test[0][0].b -> " << dump_lut << std::endl;
  }
    if (const char* dbg_env = std::getenv("TFHE_GPU_VP_DEBUG")) {
      (void)dbg_env;
      std::vector<Torus32> lut_probe(Context::N_lvl1);
      ensure_cuda_success(
          cudaMemcpy(lut_probe.data(),
                     lut_table[0][0].b->coefs,
                     Context::N_lvl1 * sizeof(Torus32),
                     cudaMemcpyDeviceToHost),
          "vp probe biglut_test b[0]");
      std::cout << "[TFHE_GPU_VP] biglut_test[0][0].b[0..3]={"
                << lut_probe[0] << "," << lut_probe[1] << ","
                << lut_probe[2] << "," << lut_probe[3] << "}\n";
    }
    biglut_batch_20bit_ip(biglut_output,
                          lut_table,
                          lwe_inputs,
                          lut_len,
                          ctx_.get());
    ensure_cuda_success(cudaDeviceSynchronize(), "vp biglut");

    const std::size_t lvl1_words = static_cast<std::size_t>(Context::n_lvl1) + 1;
    if (request.descriptor.glwe_words == lvl1_words) {
      const std::size_t out_word_bytes =
          safe_divide(static_cast<std::size_t>(request.glwe_bytes), lvl1_words);
      if (out_word_bytes < kMinWordBytes) {
        throw std::invalid_argument("VP biglut-only output word size below 32-bit");
      }

      std::vector<std::int32_t> host_lvl1(lvl1_words);
      ensure_cuda_success(
          cudaMemcpy(host_lvl1.data(),
                     biglut_output[vp_select].a,
                     lvl1_words * sizeof(std::int32_t),
                     cudaMemcpyDeviceToHost),
          "vp read biglut-only output");
      glwe_payload.resize(lvl1_words * out_word_bytes);
      for (std::size_t idx = 0; idx < lvl1_words; ++idx) {
        const std::uint32_t torus32 = static_cast<std::uint32_t>(host_lvl1[idx]);
        encode_word_le(glwe_payload.data() + idx * out_word_bytes,
                       out_word_bytes,
                       static_cast<std::uint64_t>(torus32));
      }

      delete_array1<LweSample32>(biglut_output);
      delete_array1<LweSample32>(lwe_inputs);
      const auto pre_end_time = std::chrono::steady_clock::now();
      pre_pipeline_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                            pre_end_time - pre_start_time)
                            .count();

      gpu_runtime::ipc::SubmitResponse response{};
      response.status_code = 0;
      response.error_code = 0;
      response.latency_ns = pre_pipeline_ns;
      response.glwe_bytes = static_cast<std::uint32_t>(glwe_payload.size());
      response.woks_latency_ns = pre_pipeline_ns;
      response.ks_latency_ns = 0;
      response.sequence_no = 0;
      response.outstanding_descriptors = 0;
      response.reserved = 0;
      return response;
    }

    {
      std::vector<std::int32_t> biglut_host(lvl1_words);
      ensure_cuda_success(
          cudaMemcpy(biglut_host.data(),
                     biglut_output[0].a,
                     lvl1_words * sizeof(std::int32_t),
                     cudaMemcpyDeviceToHost),
          "vp read biglut output");
      const std::size_t b_index = static_cast<std::size_t>(Context::n_lvl1);
      if (const char* dbg_env = std::getenv("TFHE_GPU_VP_DEBUG")) {
        (void)dbg_env;
        std::cout << "[TFHE_GPU_VP] biglut_raw[0..3]={";
        for (int i = 0; i < 3; ++i) {
          std::cout << biglut_host[i] << ",";
        }
        std::cout << biglut_host[3] << "} b=" << biglut_host[b_index] << std::endl;
      }
      if (const char* dump_env = std::getenv("TFHE_GPU_DUMP_BIGLUT_RAW");
          dump_env != nullptr && *dump_env != '\0') {
        std::cout << "[TFHE_GPU_VP] dump biglut_raw -> " << dump_env << std::endl;
        maybe_dump_payload(
            dump_env,
            std::span<const std::uint8_t>(
                reinterpret_cast<const std::uint8_t*>(biglut_host.data()),
                biglut_host.size() * sizeof(std::int32_t)));
      }
    }

    if (const char* dump_env = std::getenv("WOP_GPU_DUMP_VP_BIGLUT");
        dump_env != nullptr && *dump_env != '\0') {
      const std::size_t lvl1_words = static_cast<std::size_t>(Context::n_lvl1) + 1;
      std::vector<std::int32_t> biglut_words(static_cast<std::size_t>(lut_len) * lvl1_words);
      for (int i = 0; i < lut_len; ++i) {
        ensure_cuda_success(
            cudaMemcpy(biglut_words.data() + static_cast<std::size_t>(i) * lvl1_words,
                       biglut_output[i].a,
                       lvl1_words * sizeof(std::int32_t),
                       cudaMemcpyDeviceToHost),
            "dump vp biglut output");
      }
      maybe_dump_payload(
          dump_env,
          std::span<const std::uint8_t>(
              reinterpret_cast<const std::uint8_t*>(biglut_words.data()),
              biglut_words.size() * sizeof(std::int32_t)));
      std::cout << "[TFHE_GPU_VP] dump biglut array -> " << dump_env << std::endl;
    }

    if (const char* dump_env = std::getenv("WOP_GPU_DUMP_BIGLUT");
        dump_env != nullptr && *dump_env != '\0') {
      const std::size_t lvl1_words = static_cast<std::size_t>(Context::n_lvl1) + 1;
      std::vector<std::int32_t> biglut_words(lvl1_words);
      ensure_cuda_success(
          cudaMemcpy(biglut_words.data(),
                     biglut_output[0].a,
                     lvl1_words * sizeof(std::int32_t),
                     cudaMemcpyDeviceToHost),
          "dump vp biglut output (idx=0)");
      maybe_dump_payload(dump_env,
                         std::span<const std::uint8_t>(
                             reinterpret_cast<const std::uint8_t*>(biglut_words.data()),
                             biglut_words.size() * sizeof(std::int32_t)));
    }

    auto ks_output = new_array1<LweSample32>(1, Context::n_lvl0);
    // VP 使用标准 KS 参数（非 GPBS 变体），与 CPU 参考保持一致。
    const int is_gpbs = 0;
    const int ks_len = 1;
    // Optional KS digit histogram / partial sum buffers: enable by setting WOP_GPU_DUMP_KS_AIJ or WOP_GPU_DUMP_KS_PARTIAL
    uint32_t* ks_dbg_hist = nullptr;
    int32_t* ks_dbg_partial = nullptr;
    int32_t* ks_dbg_partial_j = nullptr;
    int hist_entries = 0;
    int partial_entries = 0;
    int partial_j_entries = 0;
    if (const char* dump_env = std::getenv("WOP_GPU_DUMP_KS_AIJ");
        dump_env != nullptr && *dump_env != '\0') {
      hist_entries = ks_len * Context::n_lvl1 *
                     Context::kslength_lvl10 * (1 << Context::ksbasebit_lvl10);
      ks_dbg_hist = checked_dev_alloc<uint32_t>(hist_entries);
      ensure_cuda_success(cudaMemset(ks_dbg_hist, 0, hist_entries * sizeof(uint32_t)),
                          "ks dbg memset");
    }
    if (const char* dump_env = std::getenv("WOP_GPU_DUMP_KS_PARTIAL");
        dump_env != nullptr && *dump_env != '\0') {
      // only capture b==0 partial sums: n1 steps * (n_lvl0+1) words
      partial_entries = Context::n_lvl1 * (Context::n_lvl0 + 1);
      ks_dbg_partial = checked_dev_alloc<int32_t>(partial_entries);
      ensure_cuda_success(cudaMemset(ks_dbg_partial, 0, partial_entries * sizeof(int32_t)),
                          "ks partial memset");
    }
    if (const char* dump_env = std::getenv("WOP_GPU_DUMP_KS_PARTIAL_J");
        dump_env != nullptr && *dump_env != '\0') {
      partial_j_entries = Context::n_lvl1 * Context::kslength_lvl10 * (Context::n_lvl0 + 1);
      ks_dbg_partial_j = checked_dev_alloc<int32_t>(partial_j_entries);
      ensure_cuda_success(cudaMemset(ks_dbg_partial_j, 0, partial_j_entries * sizeof(int32_t)),
                          "ks partial_j memset");
    }

    KeySwitch_lv10(ks_output, &biglut_output[vp_select], ks_len, is_gpbs, ctx_.get(),
                   ks_dbg_hist, ks_dbg_partial, ks_dbg_partial_j);
    ensure_cuda_success(cudaDeviceSynchronize(), "vp keyswitch");

    if (ks_dbg_hist != nullptr) {
      const char* dump_env = std::getenv("WOP_GPU_DUMP_KS_AIJ");
      std::vector<uint32_t> host_hist(hist_entries);
      ensure_cuda_success(
          cudaMemcpy(host_hist.data(),
                     ks_dbg_hist,
                     hist_entries * sizeof(uint32_t),
                     cudaMemcpyDeviceToHost),
          "copy ks dbg hist");
      maybe_dump_payload(
          dump_env,
          std::span<const std::uint8_t>(
              reinterpret_cast<const std::uint8_t*>(host_hist.data()),
              host_hist.size() * sizeof(uint32_t)));
      std::cout << "[TFHE_GPU_VP] dump ks aij histogram -> " << dump_env << std::endl;
      checked_dev_free<uint32_t>(ks_dbg_hist);
    }
    if (ks_dbg_partial != nullptr) {
      const char* dump_env = std::getenv("WOP_GPU_DUMP_KS_PARTIAL");
      std::vector<int32_t> host_partial(partial_entries);
      ensure_cuda_success(
          cudaMemcpy(host_partial.data(),
                     ks_dbg_partial,
                     partial_entries * sizeof(int32_t),
                     cudaMemcpyDeviceToHost),
          "copy ks dbg partial");
      maybe_dump_payload(
          dump_env,
          std::span<const std::uint8_t>(
              reinterpret_cast<const std::uint8_t*>(host_partial.data()),
              host_partial.size() * sizeof(int32_t)));
      std::cout << "[TFHE_GPU_VP] dump ks partial sums -> " << dump_env << std::endl;
      checked_dev_free<int32_t>(ks_dbg_partial);
    }
    if (ks_dbg_partial_j != nullptr) {
      const char* dump_env = std::getenv("WOP_GPU_DUMP_KS_PARTIAL_J");
      std::vector<int32_t> host_partial(partial_j_entries);
      ensure_cuda_success(
          cudaMemcpy(host_partial.data(),
                     ks_dbg_partial_j,
                     partial_j_entries * sizeof(int32_t),
                     cudaMemcpyDeviceToHost),
          "copy ks dbg partial_j");
      maybe_dump_payload(
          dump_env,
          std::span<const std::uint8_t>(
              reinterpret_cast<const std::uint8_t*>(host_partial.data()),
              host_partial.size() * sizeof(int32_t)));
      std::cout << "[TFHE_GPU_VP] dump ks partial_j sums -> " << dump_env << std::endl;
      checked_dev_free<int32_t>(ks_dbg_partial_j);
    }

    const std::size_t lvl0_words = static_cast<std::size_t>(Context::n_lvl0) + 1;
    std::vector<std::int32_t> host_level0(lvl0_words);
    ensure_cuda_success(
        cudaMemcpy(host_level0.data(),
                   ks_output[0].a,
                   lvl0_words * sizeof(std::int32_t),
                   cudaMemcpyDeviceToHost),
        "vp read ks result");
    // Debug dump: raw torus32 KS 输出，便于与 CPU KeySwitch_lv10 对比
    if (const char* dump_env = std::getenv("WOP_GPU_DUMP_VP_KS_RAW");
        dump_env != nullptr && *dump_env != '\0') {
      std::cout << "[TFHE_GPU_VP] dump ks_raw (torus32) -> " << dump_env << std::endl;
      maybe_dump_payload(
          dump_env,
          std::span<const std::uint8_t>(
              reinterpret_cast<const std::uint8_t*>(host_level0.data()),
              host_level0.size() * sizeof(std::int32_t)));
    }
    if (std::getenv("TFHE_GPU_VP_DEBUG") != nullptr) {
      std::cout << "[TFHE_GPU_VP] ks_lvl0[0..7]={";
      for (int i = 0; i < 8; ++i) {
        std::cout << host_level0[i];
        if (i != 7) std::cout << ",";
      }
      std::cout << "} b=" << host_level0.back() << std::endl;
    }

    // IMPORTANT: ks_output is torus32 (lvl0). Downstream CB/WoKS pipeline expects torus32 TLWE
    // and performs modSwitchFromTorus32() internally. Do NOT pre-modswitch here, otherwise the
    // CB pipeline will normalize_pre_modswitch() again and collapse values to zero.
    ks_payload.resize(host_level0.size() * word_bytes);
    for (std::size_t idx = 0; idx < host_level0.size(); ++idx) {
      const std::uint32_t torus32 = static_cast<std::uint32_t>(host_level0[idx]);
      encode_word_le(ks_payload.data() + idx * word_bytes,
                     word_bytes,
                     static_cast<std::uint64_t>(torus32));
    }

    if (const char* dump_env = std::getenv("WOP_GPU_DUMP_VP_KS");
        dump_env != nullptr && *dump_env != '\0') {
      std::cout << "[TFHE_GPU_VP] dump ks_lvl0 -> " << dump_env << std::endl;
      maybe_dump_payload(
          dump_env,
          std::span<const std::uint8_t>(ks_payload.data(), ks_payload.size()));
    }

    delete_array1<LweSample32>(ks_output);
    delete_array1<LweSample32>(biglut_output);
    delete_array1<LweSample32>(lwe_inputs);
    const auto pre_end_time = std::chrono::steady_clock::now();
    pre_pipeline_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                          pre_end_time - pre_start_time)
                          .count();
  }

  gpu_runtime::ipc::SubmitRequest derived = request;
  derived.descriptor.mode = request.descriptor.mode;
  derived.descriptor.tlwe_words = static_cast<std::uint32_t>(Context::n_lvl0) + 1;
  derived.tlwe_bytes = static_cast<std::uint32_t>(ks_payload.size());
  derived.descriptor.flags &= static_cast<std::uint8_t>(~0x80u);
  if (const char* dump_env = std::getenv("WOP_GPU_DUMP_KS");
      dump_env != nullptr && *dump_env != '\0') {
    maybe_dump_payload(dump_env,
                       std::span<const std::uint8_t>(ks_payload.data(), ks_payload.size()));
  }

  // 使用 ks_payload 作为 TLWE 输入继续走 WoKS/PrivKS；compare 仍按 descriptor.tlwe_words
  // 判断 golden，但 compare_words 后续由 run_circuit_bootstrap_pipeline 按模式决定。
  auto response = run_circuit_bootstrap_pipeline(
      derived,
      std::span<const std::uint8_t>(ks_payload.data(), ks_payload.size()),
      glwe_payload);
  response.latency_ns += pre_pipeline_ns;
  return response;
}

gpu_runtime::ipc::SubmitResponse TfheGpuExecutor::run_bit_extract_pipeline(
    const gpu_runtime::ipc::SubmitRequest& request,
    std::span<const std::uint8_t> tlwe_payload,
    std::vector<std::uint8_t>& glwe_payload) {
  const std::size_t word_bytes = safe_divide(tlwe_payload.size(), request.descriptor.tlwe_words);
  if (word_bytes < kMinWordBytes) {
    throw std::invalid_argument("bit-extract payload word size below 32-bit");
  }
  const std::size_t words_per_sample = static_cast<std::size_t>(Context::n_lvl1) + 1;
  if (words_per_sample == 0) {
    throw std::runtime_error("invalid N_lvl1");
  }
  if (request.descriptor.tlwe_words % words_per_sample != 0) {
    throw std::invalid_argument("BE payload length not aligned to level-1 TLWE size");
  }
  const std::size_t sample_count = request.descriptor.tlwe_words / words_per_sample;
  if (sample_count == 0) {
    throw std::invalid_argument("BE payload missing TLWE samples");
  }
  if (sample_count > 20) {
    throw std::invalid_argument("BE payload exceeds supported TLWE sample count (20)");
  }

  std::vector<std::uint8_t> ks_payload;
  std::uint64_t pre_pipeline_ns = 0;
  {
    const auto pre_start_time = std::chrono::steady_clock::now();
    struct StreamLease {
      TfheGpuExecutor* owner;
      cudaStream_t stream;
      explicit StreamLease(TfheGpuExecutor* o, cudaStream_t s) : owner(o), stream(s) {}
      ~StreamLease() {
        if (owner != nullptr) {
          owner->release_stream(stream);
        }
      }
    };

    StreamLease stream_lease(this, acquire_stream());
    cudaStream_t stream = stream_lease.stream;

    std::lock_guard<std::mutex> context_lock(context_mutex_);

    std::vector<std::int32_t> host_sample(words_per_sample);
    auto lwe_inputs = new_array1<LweSample32>(sample_count, Context::n_lvl1);
    for (std::size_t sample = 0; sample < sample_count; ++sample) {
      const std::size_t offset_words = sample * words_per_sample;
      for (std::size_t i = 0; i < words_per_sample; ++i) {
        const std::uint8_t* src = tlwe_payload.data() + (offset_words + i) * word_bytes;
        const std::int64_t decoded = decode_word_le_signed(src, word_bytes);
        host_sample[i] = static_cast<std::int32_t>(decoded);
      }
      ensure_cuda_success(
          cudaMemcpyAsync(lwe_inputs[sample].a,
                          host_sample.data(),
                          words_per_sample * sizeof(std::int32_t),
                          cudaMemcpyHostToDevice,
                          stream),
          "be copy input sample");
    }
    ensure_cuda_success(cudaStreamSynchronize(stream), "be input sync");

    const std::size_t bit_outputs = sample_count * 2;
    auto bit_extract_out = new_array1<LweSample32>(bit_outputs, Context::n_lvl1);
    bit_extract_ip(bit_extract_out, lwe_inputs, static_cast<int>(sample_count), ctx_.get());
    ensure_cuda_success(cudaDeviceSynchronize(), "be bit extract");

    if (request.descriptor.glwe_words == words_per_sample) {
      const std::size_t out_word_bytes =
          safe_divide(static_cast<std::size_t>(request.glwe_bytes), words_per_sample);
      if (out_word_bytes < kMinWordBytes) {
        throw std::invalid_argument("BE bit_extract-only output word size below 32-bit");
      }

      std::vector<std::int32_t> host_lvl1(words_per_sample);
      ensure_cuda_success(
          cudaMemcpy(host_lvl1.data(),
                     bit_extract_out[0].a,
                     words_per_sample * sizeof(std::int32_t),
                     cudaMemcpyDeviceToHost),
          "be read bit_extract-only output");

      glwe_payload.resize(words_per_sample * out_word_bytes);
      for (std::size_t idx = 0; idx < words_per_sample; ++idx) {
        const std::uint32_t torus32 = static_cast<std::uint32_t>(host_lvl1[idx]);
        encode_word_le(glwe_payload.data() + idx * out_word_bytes,
                       out_word_bytes,
                       static_cast<std::uint64_t>(torus32));
      }

      delete_array1<LweSample32>(bit_extract_out);
      delete_array1<LweSample32>(lwe_inputs);
      const auto pre_end_time = std::chrono::steady_clock::now();
      pre_pipeline_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                            pre_end_time - pre_start_time)
                            .count();

      gpu_runtime::ipc::SubmitResponse response{};
      response.status_code = 0;
      response.error_code = 0;
      response.latency_ns = pre_pipeline_ns;
      response.glwe_bytes = static_cast<std::uint32_t>(glwe_payload.size());
      response.woks_latency_ns = pre_pipeline_ns;
      response.ks_latency_ns = 0;
      response.sequence_no = 0;
      response.outstanding_descriptors = 0;
      response.reserved = 0;
      return response;
    }

    auto ks_output = new_array1<LweSample32>(1, Context::n_lvl0);
    const int is_gpbs = (request.descriptor.mode != gpu_runtime::ipc::kDescriptorModeCircuitBootstrap) ? 1 : 0;
    KeySwitch_lv10(ks_output, bit_extract_out, 1, is_gpbs, ctx_.get());
    ensure_cuda_success(cudaDeviceSynchronize(), "be keyswitch");

    std::vector<std::int32_t> host_level0(static_cast<std::size_t>(Context::n_lvl0) + 1);
    ensure_cuda_success(
        cudaMemcpy(host_level0.data(),
                   ks_output[0].a,
                   host_level0.size() * sizeof(std::int32_t),
                   cudaMemcpyDeviceToHost),
        "be read ks result");

    ks_payload.resize(host_level0.size() * word_bytes);
    for (std::size_t idx = 0; idx < host_level0.size(); ++idx) {
      encode_word_le(ks_payload.data() + idx * word_bytes, word_bytes, host_level0[idx]);
    }

    delete_array1<LweSample32>(ks_output);
    delete_array1<LweSample32>(bit_extract_out);
    delete_array1<LweSample32>(lwe_inputs);
    const auto pre_end_time = std::chrono::steady_clock::now();
    pre_pipeline_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                          pre_end_time - pre_start_time)
                          .count();
  }

  gpu_runtime::ipc::SubmitRequest derived = request;
  derived.descriptor.mode = request.descriptor.mode;
  derived.descriptor.tlwe_words = static_cast<std::uint32_t>(Context::n_lvl0) + 1;
  derived.tlwe_bytes = static_cast<std::uint32_t>(ks_payload.size());
  derived.descriptor.flags &= static_cast<std::uint8_t>(~0x80u);

  auto response = run_circuit_bootstrap_pipeline(
      derived,
      std::span<const std::uint8_t>(ks_payload.data(), ks_payload.size()),
      glwe_payload);
  response.latency_ns += pre_pipeline_ns;
  return response;
}
