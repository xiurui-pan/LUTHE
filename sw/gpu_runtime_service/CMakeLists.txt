cmake_minimum_required(VERSION 3.20)

project(gpu_runtime_service LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

option(TFHE_GPU_DISABLE_FMA "Disable CUDA fused multiply-add (debug alignment)" OFF)
set(WOPBS_FP_TOTAL_BITS "" CACHE STRING "WOPBS fixed-point total bits (default: 32)")
set(WOPBS_FP_INT_BITS "" CACHE STRING "WOPBS fixed-point integer bits (default: 12)")
set(WOPBS_FP_EXP_LO_BITS "" CACHE STRING "WOPBS exp(-x) low bits (default: 6)")
set(WOPBS_FP_EXP_LUT_BITS "" CACHE STRING "WOPBS exp(-x) LUT bits (default: 20)")
set(WOPBS_FP_EXP_LUT_INDEX_BITS "" CACHE STRING "WOPBS exp(-x) LUT index bits (default: LUT_BITS)")
set(WOPBS_FP_EXP_LUT_LOW_BITS "" CACHE STRING "WOPBS exp(-x) LUT low bits (default: LUT_BITS/2)")

if(WOPBS_FP_TOTAL_BITS STREQUAL "16")
  if(WOPBS_FP_INT_BITS STREQUAL "")
    # Align CPU/GPU fixed-point integer bits for 16-bit builds.
    set(WOPBS_FP_INT_BITS "6")
  endif()
  if(WOPBS_FP_EXP_LO_BITS STREQUAL "")
    # Align CPU/GPU exp(-x) segmentation defaults for 16-bit builds.
    set(WOPBS_FP_EXP_LO_BITS "0")
  endif()
  if(WOPBS_FP_EXP_LUT_BITS STREQUAL "")
    set(WOPBS_FP_EXP_LUT_BITS "16")
  endif()
  if(WOPBS_FP_EXP_LUT_LOW_BITS STREQUAL "")
    set(WOPBS_FP_EXP_LUT_LOW_BITS "10")
  endif()
endif()

set(WOPBS_FP_DEFINES "")
if(WOPBS_FP_TOTAL_BITS)
  list(APPEND WOPBS_FP_DEFINES "WOPBS_FP_TOTAL_BITS=${WOPBS_FP_TOTAL_BITS}")
endif()
if(WOPBS_FP_INT_BITS)
  list(APPEND WOPBS_FP_DEFINES "WOPBS_FP_INT_BITS=${WOPBS_FP_INT_BITS}")
endif()
if(NOT WOPBS_FP_EXP_LO_BITS STREQUAL "")
  list(APPEND WOPBS_FP_DEFINES "WOPBS_FP_EXP_LO_BITS=${WOPBS_FP_EXP_LO_BITS}")
endif()
if(NOT WOPBS_FP_EXP_LUT_BITS STREQUAL "")
  list(APPEND WOPBS_FP_DEFINES "WOPBS_FP_EXP_LUT_BITS=${WOPBS_FP_EXP_LUT_BITS}")
endif()
if(NOT WOPBS_FP_EXP_LUT_INDEX_BITS STREQUAL "")
  list(APPEND WOPBS_FP_DEFINES "WOPBS_FP_EXP_LUT_INDEX_BITS=${WOPBS_FP_EXP_LUT_INDEX_BITS}")
endif()
if(NOT WOPBS_FP_EXP_LUT_LOW_BITS STREQUAL "")
  list(APPEND WOPBS_FP_DEFINES "WOPBS_FP_EXP_LUT_LOW_BITS=${WOPBS_FP_EXP_LUT_LOW_BITS}")
endif()

find_package(OpenMP REQUIRED)
find_package(CUDAToolkit REQUIRED)
enable_language(ASM)

add_library(gpu_runtime_ipc INTERFACE)
target_include_directories(gpu_runtime_ipc INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/include)

# Allow override (e.g. clean baseline for debugging); fallback to default path if not provided
if(NOT DEFINED TFHE_GPU_ROOT)
  set(TFHE_GPU_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../tfhe-gpu-baseline-wopbs)
endif()

file(GLOB TFHE_GPU_SOURCES
  ${TFHE_GPU_ROOT}/src/*.cpp
  ${TFHE_GPU_ROOT}/src/*.cu
  ${TFHE_GPU_ROOT}/src/basic/*.cu
  ${TFHE_GPU_ROOT}/src/fp_op/*.cu
  ${TFHE_GPU_ROOT}/src/fp_op/*.cpp
)
list(FILTER TFHE_GPU_SOURCES EXCLUDE REGEX ".*/main\\.cpp$")

add_library(tfhe_gpu_baseline STATIC ${TFHE_GPU_SOURCES})
target_include_directories(tfhe_gpu_baseline
  PUBLIC
    ${TFHE_GPU_ROOT}/src
)
if(WOPBS_FP_DEFINES)
  target_compile_definitions(tfhe_gpu_baseline PRIVATE ${WOPBS_FP_DEFINES})
endif()
set_target_properties(tfhe_gpu_baseline PROPERTIES
  CUDA_SEPARABLE_COMPILATION ON
)
target_link_libraries(tfhe_gpu_baseline
  PUBLIC
    OpenMP::OpenMP_CXX
    CUDA::cudart
    CUDA::cufft
)
target_compile_options(tfhe_gpu_baseline
  PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=-fopenmp>
)
if(TFHE_GPU_DISABLE_FMA)
  target_compile_options(tfhe_gpu_baseline
    PRIVATE
      $<$<COMPILE_LANGUAGE:CUDA>:-fmad=false>
  )
endif()

set(GPU_RUNTIME_COMMON_SOURCES
  src/tfhe_gpu_executor.cpp
  src/tfhe_keyset_utils.cpp
  src/tfhe_keyset_layout.cpp
)

add_executable(gpu_runtime_service
  src/service_main.cpp
  ${GPU_RUNTIME_COMMON_SOURCES}
)
target_include_directories(gpu_runtime_service PRIVATE include src)
target_link_libraries(gpu_runtime_service
  PRIVATE
    gpu_runtime_ipc
    tfhe_gpu_baseline
    CUDA::cudart
)
if(WOPBS_FP_DEFINES)
  target_compile_definitions(gpu_runtime_service PRIVATE ${WOPBS_FP_DEFINES})
endif()

add_executable(gpu_executor_smoke
  tests/executor_smoke.cpp
  ${GPU_RUNTIME_COMMON_SOURCES}
)
target_include_directories(gpu_executor_smoke PRIVATE include src)
target_link_libraries(gpu_executor_smoke
  PRIVATE
    gpu_runtime_ipc
    tfhe_gpu_baseline
    CUDA::cudart
)
if(WOPBS_FP_DEFINES)
  target_compile_definitions(gpu_executor_smoke PRIVATE ${WOPBS_FP_DEFINES})
endif()

add_executable(gpu_function_eval_smoke
  tools/function_eval_smoke.cpp
  ${GPU_RUNTIME_COMMON_SOURCES}
)
target_include_directories(gpu_function_eval_smoke PRIVATE include src)
target_link_libraries(gpu_function_eval_smoke
  PRIVATE
    gpu_runtime_ipc
    tfhe_gpu_baseline
    CUDA::cudart
)
if(WOPBS_FP_DEFINES)
  target_compile_definitions(gpu_function_eval_smoke PRIVATE ${WOPBS_FP_DEFINES})
endif()

add_executable(keyset_exporter
  tools/keyset_exporter.cpp
  src/tfhe_keyset_utils.cpp
)
target_include_directories(keyset_exporter PRIVATE include src)
target_link_libraries(keyset_exporter
  PRIVATE
    tfhe_gpu_baseline
    CUDA::cudart
)
if(WOPBS_FP_DEFINES)
  target_compile_definitions(keyset_exporter PRIVATE ${WOPBS_FP_DEFINES})
endif()

add_executable(dump_bk_fft
  tools/dump_bk_fft.cpp
  src/tfhe_keyset_utils.cpp
)
target_include_directories(dump_bk_fft PRIVATE include src)
target_link_libraries(dump_bk_fft
  PRIVATE
    tfhe_gpu_baseline
    CUDA::cudart
)
if(WOPBS_FP_DEFINES)
  target_compile_definitions(dump_bk_fft PRIVATE ${WOPBS_FP_DEFINES})
endif()

add_executable(keyset_layout_exporter
  tools/keyset_layout_exporter.cpp
  src/tfhe_keyset_layout.cpp
)
target_include_directories(keyset_layout_exporter PRIVATE include src)
target_link_libraries(keyset_layout_exporter
  PRIVATE
    CUDA::cudart
)
target_include_directories(keyset_layout_exporter PRIVATE ${TFHE_GPU_ROOT}/src)

add_executable(keyset_dram_builder
  tools/keyset_dram_builder.cpp
  src/tfhe_keyset_layout.cpp
)
target_include_directories(keyset_dram_builder PRIVATE include src)
target_link_libraries(keyset_dram_builder
  PRIVATE
    CUDA::cudart
)
target_include_directories(keyset_dram_builder PRIVATE ${TFHE_GPU_ROOT}/src)

add_executable(ks_partial_compare
  tools/ks_partial_compare.cpp
  src/tfhe_keyset_utils.cpp
  src/tfhe_keyset_layout.cpp
)
target_include_directories(ks_partial_compare PRIVATE include src)
target_link_libraries(ks_partial_compare
  PRIVATE
    CUDA::cudart
    tfhe_gpu_baseline
)
target_include_directories(ks_partial_compare PRIVATE ${TFHE_GPU_ROOT}/src)
if(WOPBS_FP_DEFINES)
  target_compile_definitions(ks_partial_compare PRIVATE ${WOPBS_FP_DEFINES})
endif()

if(NOT DEFINED TFHE_CPU_ROOT)
  if(DEFINED ENV{TFHE_CPU_ROOT} AND NOT "$ENV{TFHE_CPU_ROOT}" STREQUAL "")
    set(TFHE_CPU_ROOT $ENV{TFHE_CPU_ROOT})
  else()
    set(TFHE_CPU_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../tfhe-cpu-baseline-wopbs)
  endif()
endif()
file(GLOB TFHE_CPU_CPP_SOURCES
  ${TFHE_CPU_ROOT}/src/*.cpp
)
list(FILTER TFHE_CPU_CPP_SOURCES EXCLUDE REGEX ".*/(main|cmux_test|perf_test|parallel_perf_test|profiling_test|simple_perf_test)\\.cpp$")
set(TFHE_CPU_SPQLIOS_SOURCES
  ${TFHE_CPU_ROOT}/src/spqlios/fft_processor_spqlios.cpp
  ${TFHE_CPU_ROOT}/src/spqlios/spqlios-fft-impl.cpp
)
set(TFHE_CPU_ASM_SOURCES
  ${TFHE_CPU_ROOT}/src/spqlios/lagrangehalfc_impl_fma.s
  ${TFHE_CPU_ROOT}/src/spqlios/spqlios-fft-fma.s
  ${TFHE_CPU_ROOT}/src/spqlios/spqlios-ifft-fma.s
)

add_executable(cpu_reference_runner
  tools/cpu_reference_runner.cpp
  ${TFHE_CPU_CPP_SOURCES}
  ${TFHE_CPU_SPQLIOS_SOURCES}
  ${TFHE_CPU_ASM_SOURCES}
)
target_include_directories(cpu_reference_runner
  PRIVATE
    ${TFHE_CPU_ROOT}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
set_target_properties(cpu_reference_runner PROPERTIES
  POSITION_INDEPENDENT_CODE OFF
)
target_link_libraries(cpu_reference_runner
  PRIVATE
    OpenMP::OpenMP_CXX
)
target_link_options(cpu_reference_runner PRIVATE -no-pie)
if(WOPBS_FP_DEFINES)
  target_compile_definitions(cpu_reference_runner PRIVATE ${WOPBS_FP_DEFINES})
endif()

add_executable(spqlios_table_exporter
  tools/spqlios_table_exporter.cpp
  ${TFHE_CPU_ROOT}/src/spqlios/spqlios-fft-impl.cpp
)
target_include_directories(spqlios_table_exporter
  PRIVATE
    ${TFHE_CPU_ROOT}/src
)
target_link_libraries(spqlios_table_exporter
  PRIVATE
    OpenMP::OpenMP_CXX
)
target_link_options(spqlios_table_exporter PRIVATE -no-pie)

add_executable(digit_ifft
  tools/digit_ifft.cpp
  ${TFHE_CPU_CPP_SOURCES}
  ${TFHE_CPU_SPQLIOS_SOURCES}
  ${TFHE_CPU_ASM_SOURCES}
)
target_include_directories(digit_ifft
  PRIVATE
    ${TFHE_CPU_ROOT}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(digit_ifft
  PRIVATE
    OpenMP::OpenMP_CXX
)
target_link_options(digit_ifft PRIVATE -no-pie)
if(WOPBS_FP_DEFINES)
  target_compile_definitions(digit_ifft PRIVATE ${WOPBS_FP_DEFINES})
endif()

if(FALSE)
add_executable(ks_only_runner
  tools/ks_only_runner.cpp
  ${TFHE_CPU_CPP_SOURCES}
  ${TFHE_CPU_SPQLIOS_SOURCES}
  ${TFHE_CPU_ASM_SOURCES}
)
target_include_directories(ks_only_runner
  PRIVATE
    ${TFHE_CPU_ROOT}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
set_target_properties(ks_only_runner PROPERTIES
  POSITION_INDEPENDENT_CODE OFF
)
target_link_libraries(ks_only_runner
  PRIVATE
    OpenMP::OpenMP_CXX
)
target_link_options(ks_only_runner PRIVATE -no-pie)
endif()
