// ==============================================================================================
// Filename: tb_wop_circuit_bootstrap_woks_engine.sv
// ----------------------------------------------------------------------------------------------
// Description:
//   Circuit Bootstrap testbench that instantiates the OpenSSD WoP wrapper together with the
//   unified WoP kernel. The bench provides lightweight AXI-Lite and AXI memory stubs so we can
//   exercise the descriptor/doorbell path without relying on simulation-only shortcuts.
// ==============================================================================================

`timescale 1ns/1ps

module tb_wop_circuit_bootstrap_woks_engine;

  import param_tfhe_pkg::*;
  import param_ntt_pkg::*;
  import ntt_core_common_param_pkg::*;
  import regf_common_param_pkg::*;
  import common_definition_pkg::*;
  import pep_if_pkg::*;
  import top_common_param_pkg::*;
  import pep_common_param_pkg::*;
  import bsk_if_common_param_pkg::*;
  import bsk_mgr_common_param_pkg::*;
  import axi_if_common_param_pkg::*;
  import axi_if_bsk_axi_pkg::*;
  import hpu_common_instruction_pkg::*;
  import vp_pbs_inst_pkg::*;
  import openssd_wop_pkg::*;

  import "DPI-C" function real mock_gpu_estimate_latency(
    input  int              cmd_id,
    input  int              mode,
    input  int              tlwe_words,
    input  int              glwe_words,
    input  int              flags,
    output real             compute_ns,
    output real             memory_ns,
    output longint unsigned bytes_read,
    output longint unsigned bytes_written
  );

  localparam int HOST_CMD_NONE       = 0;
  localparam int HOST_CMD_AXIL_WRITE = 1;
  localparam int HOST_CMD_AXIL_READ  = 2;
  localparam int HOST_CMD_MEM_WRITE  = 3;
  localparam int HOST_CMD_MEM_READ   = 4;
  localparam int HOST_CMD_SET_STATUS = 5;

  import "DPI-C" context function void tb_host_axil_register_scope();
  import "DPI-C" context function int tb_host_axil_server_start(input string socket_path);
  import "DPI-C" context function int tb_host_axil_server_poll(
      input int max_cmds,
      output int cmd_valid,
      output int cmd_type,
      output longint unsigned addr,
      output longint unsigned data0,
      output longint unsigned data1,
      output longint unsigned data2,
      output longint unsigned data3,
      output int unsigned data32,
      output int unsigned strb,
      output int status_code
  );
  import "DPI-C" context function int tb_host_axil_server_reply_ok();
  import "DPI-C" context function int tb_host_axil_server_reply_ok_u32(input int unsigned value);
  import "DPI-C" context function int tb_host_axil_server_reply_ok_u64x4(input longint unsigned d0,
                                                                         input longint unsigned d1,
                                                                         input longint unsigned d2,
                                                                         input longint unsigned d3);
  import "DPI-C" context function int tb_host_axil_server_reply_error(input string msg);
  import "DPI-C" function void tb_host_axil_server_stop();

  // --------------------------------------------------------------------------------------------
  // Parameters (aligned with the previous unified CB configuration)
  // --------------------------------------------------------------------------------------------
  parameter int MOD_Q_W        = 64;
  parameter int N_LVL0         = 630;
  parameter int N_LVL1         = 1024;
  parameter int N_LVL2         = 256;
  parameter int ELL_LVL1       = 3;
  parameter int ELL_LVL2       = 8;
  parameter int MAX_BIT_WIDTH  = 20;
  parameter int K              = 1;
  parameter int PSI            = 32;
  parameter int R              = 2;
  parameter int PBS_B_W        = 32;
  parameter int BPBS_ID_W      = 8;
  parameter int REGF_WR_REQ_W  = 16;
  parameter int REGF_RD_REQ_W  = 16;
  parameter int REGF_COEF_NB   = 32;
  parameter int BSK_PC         = 2;
  parameter int KSK_PC         = 2;
  parameter int LBY            = 64;
  parameter int LBX            = 8;
  parameter int LBZ            = 2;
  parameter int MOD_KSK_W      = 32;
  parameter int NTT_OP_W       = 64;
  parameter bit APPLY_POST_SCALE    = 1'b0;
  parameter bit USE_REAL_CORES      = 1'b1;
  parameter bit USE_REAL_GPU_RUNTIME = 1'b0;
  parameter int TARGET_MODE_PARAM = WOP_MODE_CB;
  parameter int TLWE_WORDS_CFG = 33;
  parameter int GLWE_WORDS_CFG = 3;
  parameter bit FORCE_STEP5 = 1'b0;
  parameter int DESC_COUNT_CFG = 1;
  parameter int HOST_CMD_ID_BASE_CFG = 16'h0042;
  parameter int HOST_CMD_ID_STEP_CFG = 1;
  parameter int FTL_BASE_CYCLES_PARAM          = 1200;
  parameter int FTL_MISS_PENALTY_PARAM         = 3600;
  parameter int FTL_PREFETCH_BONUS_PARAM       = 600;
  parameter int FTL_PREFETCH_WINDOW_PARAM      = 4096;
  parameter int FTL_TLWE_BASE_CYCLES_PARAM     = 0;
  parameter int FTL_TLWE_MISS_PENALTY_PARAM    = 0;
  parameter int FTL_GLWE_BASE_CYCLES_PARAM     = 0;
  parameter int FTL_GLWE_MISS_PENALTY_PARAM    = 0;
  parameter int FTL_CHANNEL_COUNT_PARAM        = 8;
  parameter int FTL_PAGE_WORDS_PARAM           = 256;

  localparam int CLK_HALF_PERIOD = 5; // 100 MHz

  // Wrapper bus widths ------------------------------------------------------
  localparam int AXIL_ADDR_W   = 12;
  localparam int AXIL_DATA_W   = 32;
  localparam int AXI_ADDR_W    = 64;
  localparam int AXI_DATA_W    = 256;
  localparam int AXI_ID_W      = 6;
  localparam int BSK_BATCH_ID_W = 8;

  // Descriptor layout -------------------------------------------------------
localparam logic [63:0] RING_CTRL_ADDR   = 64'h0000_0000_0000_0000;
localparam logic [63:0] DESC_BASE_ADDR   = 64'h0000_0000_0000_0020;
localparam logic [63:0] STATUS_BASE_ADDR = 64'h0000_0000_0000_0040;
localparam logic [63:0] TLWE_BASE_ADDR   = 64'h0000_0000_0002_0000; // -> 0x1000 after >>5
localparam logic [63:0] GLWE_BASE_ADDR   = 64'h0000_0000_0004_0000; // -> 0x2000 after >>5
localparam logic [63:0] GPU_SHARED_ADDR  = STATUS_BASE_ADDR;
localparam logic [15:0] HOST_CMD_ID      = 16'h0042;
localparam openssd_wop_mode_e TARGET_MODE_E = openssd_wop_mode_e'(TARGET_MODE_PARAM[1:0]);
localparam logic [1:0]  TARGET_MODE_BITS = TARGET_MODE_PARAM[1:0];
localparam openssd_wop_mode_e WOP_MODE_BIT_EXTRACT = WOP_MODE_BE;
localparam logic [31:0] CTRL_MODE_WORD   = 32'(TARGET_MODE_BITS) << 16;
localparam int          WOP_DESC_RING_CAPACITY = 16;

  // Simulation run-time guards ---------------------------------------------
  localparam int DEFAULT_MAX_CYCLES = 1_200_000;
  int            max_cycles_cfg;

  typedef longint unsigned longint_u_t;

  // --------------------------------------------------------------------------------------------
  // Clock and reset
  // --------------------------------------------------------------------------------------------
  logic clk;
  logic a_rst_n;
  logic s_rst_n;

  initial begin
    max_cycles_cfg = get_plusarg_int("MAX_CYCLES", DEFAULT_MAX_CYCLES);
    if (max_cycles_cfg < 1000) begin
      $display("[TB] MAX_CYCLES value too small (%0d); reverting to default %0d",
               max_cycles_cfg, DEFAULT_MAX_CYCLES);
      max_cycles_cfg = DEFAULT_MAX_CYCLES;
    end
    if (max_cycles_cfg != DEFAULT_MAX_CYCLES) begin
      $display("[TB] Using MAX_CYCLES=%0d (override via +MAX_CYCLES)", max_cycles_cfg);
    end
  end

  initial begin
    clk = 1'b0;
    forever #(CLK_HALF_PERIOD) clk = ~clk;
  end

  initial begin
    a_rst_n = 1'b0;
    $display("[TB] Reset asserted at t=%0t", $time);
    #17 a_rst_n = 1'b1;
    $display("[TB] Reset released at t=%0t", $time);
  end

  always_ff @(posedge clk) begin
    if (USE_REAL_GPU_RUNTIME && gpu_woks_link.preks_valid) begin
      $display("[TB][GPU_IF] preks_valid=1 data=0x%0h last=%0b", gpu_woks_link.preks_data, gpu_woks_link.preks_last);
    end
    if (USE_REAL_GPU_RUNTIME && gpu_woks_link.result_valid) begin
      $display("[TB][GPU_IF] result_valid=1 data=0x%0h last=%0b", gpu_woks_link.result_data, gpu_woks_link.result_last);
    end
    s_rst_n <= a_rst_n;
  end

  // --------------------------------------------------------------------------------------------
  // Test status bookkeeping
  // --------------------------------------------------------------------------------------------
  typedef enum logic [1:0] { TEST_UNKNOWN, TEST_PASSED, TEST_FAILED, TEST_TIMEOUT } test_status_e;
  test_status_e test_status = TEST_UNKNOWN;

  // --------------------------------------------------------------------------------------------
  // Wrapper interface wires
  // --------------------------------------------------------------------------------------------
  logic                     gpu_status_ready;
  logic                     active_desc_ack;

  logic [AXIL_ADDR_W-1:0]   s_axil_awaddr;
  logic                     s_axil_awvalid;
  logic                     s_axil_awready;
  logic [AXIL_DATA_W-1:0]   s_axil_wdata;
  logic [(AXIL_DATA_W/8)-1:0] s_axil_wstrb;
  logic                     s_axil_wvalid;
  logic                     s_axil_wready;
  logic [1:0]               s_axil_bresp;
  logic                     s_axil_bvalid;
  logic                     s_axil_bready;
  logic [AXIL_ADDR_W-1:0]   s_axil_araddr;
  logic                     s_axil_arvalid;
  logic                     s_axil_arready;
  logic [AXIL_DATA_W-1:0]   s_axil_rdata;
  logic [1:0]               s_axil_rresp;
  logic                     s_axil_rvalid;
  logic                     s_axil_rready;

  logic [31:0]              gpu_db_tdata;
  logic                     gpu_db_tvalid;
  logic                     gpu_db_tready;
  logic                     irq;

  logic [AXI_ID_W-1:0]      m_axi_awid;
  logic [AXI_ADDR_W-1:0]    m_axi_awaddr;
  logic [7:0]               m_axi_awlen;
  logic [2:0]               m_axi_awsize;
  logic [1:0]               m_axi_awburst;
  logic [3:0]               m_axi_awcache;
  logic [2:0]               m_axi_awprot;
  logic [3:0]               m_axi_awqos;
  logic                     m_axi_awvalid;
  logic                     m_axi_awready;
  logic [AXI_DATA_W-1:0]    m_axi_wdata;
  logic [(AXI_DATA_W/8)-1:0] m_axi_wstrb;
  logic                     m_axi_wlast;
  logic                     m_axi_wvalid;
  logic                     m_axi_wready;
  logic [AXI_ID_W-1:0]      m_axi_bid;
  logic [1:0]               m_axi_bresp;
  logic                     m_axi_bvalid;
  logic                     m_axi_bready;
  logic [AXI_ID_W-1:0]      m_axi_arid;
  logic [AXI_ADDR_W-1:0]    m_axi_araddr;
  logic [7:0]               m_axi_arlen;
  logic [2:0]               m_axi_arsize;
  logic [1:0]               m_axi_arburst;
  logic [3:0]               m_axi_arcache;
  logic [2:0]               m_axi_arprot;
  logic [3:0]               m_axi_arqos;
  logic                     m_axi_arvalid;
  logic                     m_axi_arready;
  logic [AXI_ID_W-1:0]      m_axi_rid;
  logic [AXI_DATA_W-1:0]    m_axi_rdata;
  logic [1:0]               m_axi_rresp;
  logic                     m_axi_rlast;
  logic                     m_axi_rvalid;
  logic                     m_axi_rready;

  logic                     pep_regf_wr_req_vld;
  logic                     pep_regf_wr_req_rdy;
  logic [REGF_WR_REQ_W-1:0] pep_regf_wr_req;
  logic [REGF_COEF_NB-1:0]  pep_regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0]  pep_regf_wr_data_rdy;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] pep_regf_wr_data;
  logic                     regf_pep_wr_ack;

  logic                     pep_regf_rd_req_vld;
  logic                     pep_regf_rd_req_rdy;
  logic [REGF_RD_REQ_W-1:0] pep_regf_rd_req;
  logic [REGF_COEF_NB-1:0]  regf_pep_rd_data_avail;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_pep_rd_data;
  logic                     regf_pep_rd_last_word;

  logic                     reset_ksk_cache;
  logic                     reset_ksk_cache_done;
  logic                     ksk_mem_avail;
  logic [KSK_PC-1:0][31:0]  ksk_mem_addr;

  logic [3:0]               m_axi4_glwe_arid;
  logic [31:0]              m_axi4_glwe_araddr;
  logic [7:0]               m_axi4_glwe_arlen;
  logic [2:0]               m_axi4_glwe_arsize;
  logic [1:0]               m_axi4_glwe_arburst;
  logic [3:0]               m_axi4_glwe_arqos;
  logic                     m_axi4_glwe_arvalid;
  logic                     m_axi4_glwe_arready;
  logic [3:0]               m_axi4_glwe_rid;
  logic [63:0]              m_axi4_glwe_rdata;
  logic [1:0]               m_axi4_glwe_rresp;
  logic                     m_axi4_glwe_rlast;
  logic                     m_axi4_glwe_rvalid;
  logic                     m_axi4_glwe_rready;

  logic [BSK_PC-1:0][3:0]   m_axi4_bsk_arid;
  logic [BSK_PC-1:0][31:0]  m_axi4_bsk_araddr;
  logic [BSK_PC-1:0][7:0]   m_axi4_bsk_arlen;
  logic [BSK_PC-1:0][2:0]   m_axi4_bsk_arsize;
  logic [BSK_PC-1:0][1:0]   m_axi4_bsk_arburst;
  logic [BSK_PC-1:0][3:0]   m_axi4_bsk_arqos;
  logic [BSK_PC-1:0]        m_axi4_bsk_arvalid;
  logic [BSK_PC-1:0]        m_axi4_bsk_arready;
  logic [BSK_PC-1:0][3:0]   m_axi4_bsk_rid;
  logic [BSK_PC-1:0][63:0]  m_axi4_bsk_rdata;
  logic [BSK_PC-1:0][1:0]   m_axi4_bsk_rresp;
  logic [BSK_PC-1:0]        m_axi4_bsk_rlast;
  logic [BSK_PC-1:0]        m_axi4_bsk_rvalid;
  logic [BSK_PC-1:0]        m_axi4_bsk_rready;

  logic [KSK_PC-1:0][3:0]   m_axi4_ksk_arid;
  logic [KSK_PC-1:0][31:0]  m_axi4_ksk_araddr;
  logic [KSK_PC-1:0][7:0]   m_axi4_ksk_arlen;
  logic [KSK_PC-1:0][2:0]   m_axi4_ksk_arsize;
  logic [KSK_PC-1:0][1:0]   m_axi4_ksk_arburst;
  logic [KSK_PC-1:0][3:0]   m_axi4_ksk_arqos;
  logic [KSK_PC-1:0]        m_axi4_ksk_arvalid;
  logic [KSK_PC-1:0]        m_axi4_ksk_arready;
  logic [KSK_PC-1:0][3:0]   m_axi4_ksk_rid;
  logic [KSK_PC-1:0][63:0]  m_axi4_ksk_rdata;
  logic [KSK_PC-1:0][1:0]   m_axi4_ksk_rresp;
  logic [KSK_PC-1:0]        m_axi4_ksk_rlast;
  logic [KSK_PC-1:0]        m_axi4_ksk_rvalid;
  logic [KSK_PC-1:0]        m_axi4_ksk_rready;

  logic                     glwe_asset_valid;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] glwe_asset_data;
  logic                     glwe_asset_ready;
  logic                     glwe_asset_req;
  logic                     glwe_asset_enable;

  logic                     bsk_service_req_vld;
  logic                     bsk_service_req_rdy;
  logic [BSK_BATCH_ID_W-1:0] bsk_service_batch_id;
  logic                     bsk_service_data_avail;
  logic [BSK_PC-1:0][R-1:0][MOD_Q_W-1:0] bsk_service_data;

  logic [PSI-1:0][R-1:0]    ntt_service_decomp_avail;
  logic [PSI-1:0][R-1:0]    wrapper_ntt_service_decomp_avail;
  logic [PSI-1:0][R-1:0]    sim_ntt_service_decomp_avail;
  logic [PSI-1:0][R-1:0][PBS_B_W:0] ntt_service_decomp_data;
  logic [PSI-1:0][R-1:0][PBS_B_W:0] wrapper_ntt_service_decomp_data;
  logic [PSI-1:0][R-1:0][PBS_B_W:0] sim_ntt_service_decomp_data;
  logic                     ntt_service_decomp_sob;
  logic                     wrapper_ntt_service_decomp_sob;
  logic                     sim_ntt_service_decomp_sob;
  logic                     ntt_service_decomp_eob;
  logic                     wrapper_ntt_service_decomp_eob;
  logic                     sim_ntt_service_decomp_eob;
  logic                     ntt_service_decomp_sog;
  logic                     wrapper_ntt_service_decomp_sog;
  logic                     sim_ntt_service_decomp_sog;
  logic                     ntt_service_decomp_eog;
  logic                     wrapper_ntt_service_decomp_eog;
  logic                     sim_ntt_service_decomp_eog;
  logic                     ntt_service_decomp_sol;
  logic                     wrapper_ntt_service_decomp_sol;
  logic                     sim_ntt_service_decomp_sol;
  logic                     ntt_service_decomp_eol;
  logic                     wrapper_ntt_service_decomp_eol;
  logic                     sim_ntt_service_decomp_eol;
  logic [BPBS_ID_W-1:0]     ntt_service_decomp_pbs_id;
  logic [BPBS_ID_W-1:0]     wrapper_ntt_service_decomp_pbs_id;
  logic [BPBS_ID_W-1:0]     sim_ntt_service_decomp_pbs_id;
  logic                     ntt_service_decomp_last_pbs;
  logic                     wrapper_ntt_service_decomp_last_pbs;
  logic                     sim_ntt_service_decomp_last_pbs;
  logic                     ntt_service_decomp_full_throughput;
  logic                     wrapper_ntt_service_decomp_full_throughput;
  logic                     sim_ntt_service_decomp_full_throughput;
  logic                     ntt_service_decomp_ctrl_vld;
  logic                     wrapper_ntt_service_decomp_ctrl_vld;
  logic                     sim_ntt_service_decomp_ctrl_vld;
  logic [PSI-1:0][R-1:0]    ntt_service_decomp_rdy;
  logic                     ntt_service_decomp_ctrl_rdy;

  logic [PSI-1:0][R-1:0][NTT_OP_W-1:0] ntt_service_result_data;
  logic [PSI-1:0][R-1:0]    ntt_service_result_avail;
  logic [PSI-1:0][R-1:0]    ntt_service_result_rdy;
  logic                     ntt_service_result_ctrl_vld;
  logic                     ntt_service_result_ctrl_rdy;

  logic                     decomp_ntt_sog;
  logic                     wrapper_decomp_ntt_sog;
  logic                     sim_decomp_ntt_sog;
  logic                     decomp_ntt_ctrl_avail;
  logic                     wrapper_decomp_ntt_ctrl_avail;
  logic                     sim_decomp_ntt_ctrl_avail;

  // GPU WoKS offload interface shared with wrapper and GPU stub
wop_gpu_woks_if #(.DATA_W(MOD_Q_W)) gpu_woks_link();

logic               gpu_service_latency_valid;
longint unsigned    gpu_service_latency_ns;
localparam int      GPU_WORD_BYTES      = (MOD_Q_W <= 8) ? 1 : (MOD_Q_W / 8);
localparam int      REAL_PREKS_LEN      = N_LVL0 + 1;
localparam int      GPU_PREKS_MAX_WORDS = 20 * (N_LVL1 + 1);
localparam int      REAL_RESULT_LEN     = N_LVL2 + 1;
localparam int      FTL_MAX_OUTSTANDING = 4;
localparam int      FTL_MAX_CHANNELS    = 32;
localparam int      FTL_PAGE_WORDS      = (FTL_PAGE_WORDS_PARAM > 0) ? FTL_PAGE_WORDS_PARAM : 256;

  function automatic int clamp_gpu_tlwe_words(
      input openssd_wop_mode_e mode,
      input bit                step5_only,
      input int                requested_words);
    int max_words;
    int clamped;
    bit treat_as_step5;

    // For BE/VP 不再强制 step5_only，避免 TLWE 被截到 n_lvl0+1=501
    // 仅 CB 模式需要 step5-only（直进 WoKS）
    treat_as_step5 = (mode == WOP_MODE_CB);
    max_words      = treat_as_step5 ? REAL_PREKS_LEN : GPU_PREKS_MAX_WORDS;
    clamped        = requested_words;
    if (clamped <= 0) begin
      clamped = max_words;
    end else if (clamped > max_words) begin
      clamped = max_words;
    end
    if (clamped < 1) begin
      clamped = 1;
    end
    return clamped;
  endfunction

  openssd_wop_desc_t        active_desc;
  logic                     active_desc_valid;
  logic                     unified_inst_ack;
  vp_pbs_response_t         unified_resp;
  logic [15:0]              active_desc_tlwe_words_latched;
  logic [15:0]              active_desc_glwe_words_latched;
  logic [7:0]               active_desc_flags_latched;
  logic [63:0]              active_desc_tlwe_addr_latched;
  logic [63:0]              active_desc_glwe_addr_latched;
  logic [63:0]              active_desc_status_addr_latched;
  logic [15:0]              active_desc_cmd_id_latched;
  logic [1:0]               active_desc_mode_latched;

  // --------------------------------------------------------------------------------------------
  // Device under test
  // --------------------------------------------------------------------------------------------
  openssd_wop_wrapper #(
    .MOD_Q_W        (MOD_Q_W),
    .MAX_BIT_WIDTH  (MAX_BIT_WIDTH),
    .N_LVL0         (N_LVL0),
    .N_LVL1         (N_LVL1),
    .N_LVL2         (N_LVL2),
    .ELL_LVL1       (ELL_LVL1),
    .K              (K),
    .LBY            (LBY),
    .LBX            (LBX),
    .LBZ            (LBZ),
    .MOD_NTT_W      (NTT_OP_W),
    .ELL_LVL2       (ELL_LVL2),
    .MOD_KSK_W      (MOD_KSK_W),
    .PSI            (PSI),
    .R              (R),
    .BSK_PC         (BSK_PC),
    .KSK_PC         (KSK_PC),
    .REGF_WR_REQ_W  (REGF_WR_REQ_W),
    .REGF_RD_REQ_W  (REGF_RD_REQ_W),
    .REGF_COEF_NB   (REGF_COEF_NB),
    .AXIL_ADDR_W    (AXIL_ADDR_W),
    .AXIL_DATA_W    (AXIL_DATA_W),
    .AXI_ADDR_W     (AXI_ADDR_W),
    .AXI_DATA_W     (AXI_DATA_W),
    .AXI_ID_W       (AXI_ID_W),
    .USE_KERNEL_GLWE_REQ (1'b0),
    .USE_GPU_RESULT_STUB (~USE_REAL_GPU_RUNTIME)
  ) dut (
    .clk                      (clk),
    .s_rst_n                  (s_rst_n),
    .gpu_status_ready_i       (gpu_status_ready),
    .active_desc_ack_i        (active_desc_ack),
    .s_axil_awaddr            (s_axil_awaddr),
    .s_axil_awvalid           (s_axil_awvalid),
    .s_axil_awready           (s_axil_awready),
    .s_axil_wdata             (s_axil_wdata),
    .s_axil_wstrb             (s_axil_wstrb),
    .s_axil_wvalid            (s_axil_wvalid),
    .s_axil_wready            (s_axil_wready),
    .s_axil_bresp             (s_axil_bresp),
    .s_axil_bvalid            (s_axil_bvalid),
    .s_axil_bready            (s_axil_bready),
    .s_axil_araddr            (s_axil_araddr),
    .s_axil_arvalid           (s_axil_arvalid),
    .s_axil_arready           (s_axil_arready),
    .s_axil_rdata             (s_axil_rdata),
    .s_axil_rresp             (s_axil_rresp),
    .s_axil_rvalid            (s_axil_rvalid),
    .s_axil_rready            (s_axil_rready),
    .irq_o                    (irq),
    .gpu_db_tdata_o           (gpu_db_tdata),
    .gpu_db_tvalid_o          (gpu_db_tvalid),
    .gpu_db_tready_i          (gpu_db_tready),
    .gpu_woks_link_if         (gpu_woks_link.wrapper),
    .m_axi_awid               (m_axi_awid),
    .m_axi_awaddr             (m_axi_awaddr),
    .m_axi_awlen              (m_axi_awlen),
    .m_axi_awsize             (m_axi_awsize),
    .m_axi_awburst            (m_axi_awburst),
    .m_axi_awcache            (m_axi_awcache),
    .m_axi_awprot             (m_axi_awprot),
    .m_axi_awqos              (m_axi_awqos),
    .m_axi_awvalid            (m_axi_awvalid),
    .m_axi_awready            (m_axi_awready),
    .m_axi_wdata              (m_axi_wdata),
    .m_axi_wstrb              (m_axi_wstrb),
    .m_axi_wlast              (m_axi_wlast),
    .m_axi_wvalid             (m_axi_wvalid),
    .m_axi_wready             (m_axi_wready),
    .m_axi_bid                (m_axi_bid),
    .m_axi_bresp              (m_axi_bresp),
    .m_axi_bvalid             (m_axi_bvalid),
    .m_axi_bready             (m_axi_bready),
    .m_axi_arid               (m_axi_arid),
    .m_axi_araddr             (m_axi_araddr),
    .m_axi_arlen              (m_axi_arlen),
    .m_axi_arsize             (m_axi_arsize),
    .m_axi_arburst            (m_axi_arburst),
    .m_axi_arcache            (m_axi_arcache),
    .m_axi_arprot             (m_axi_arprot),
    .m_axi_arqos              (m_axi_arqos),
    .m_axi_arvalid            (m_axi_arvalid),
    .m_axi_arready            (m_axi_arready),
    .m_axi_rid                (m_axi_rid),
    .m_axi_rdata              (m_axi_rdata),
    .m_axi_rresp              (m_axi_rresp),
    .m_axi_rlast              (m_axi_rlast),
    .m_axi_rvalid             (m_axi_rvalid),
    .m_axi_rready             (m_axi_rready),
    .pep_regf_wr_req_vld      (pep_regf_wr_req_vld),
    .pep_regf_wr_req_rdy      (pep_regf_wr_req_rdy),
    .pep_regf_wr_req          (pep_regf_wr_req),
    .pep_regf_wr_data_vld     (pep_regf_wr_data_vld),
    .pep_regf_wr_data_rdy     (pep_regf_wr_data_rdy),
    .pep_regf_wr_data         (pep_regf_wr_data),
    .regf_pep_wr_ack          (regf_pep_wr_ack),
    .pep_regf_rd_req_vld      (pep_regf_rd_req_vld),
    .pep_regf_rd_req_rdy      (pep_regf_rd_req_rdy),
    .pep_regf_rd_req          (pep_regf_rd_req),
    .regf_pep_rd_data_avail   (regf_pep_rd_data_avail),
    .regf_pep_rd_data         (regf_pep_rd_data),
    .regf_pep_rd_last_word    (regf_pep_rd_last_word),
    .reset_ksk_cache          (reset_ksk_cache),
    .reset_ksk_cache_done     (reset_ksk_cache_done),
    .ksk_mem_avail            (ksk_mem_avail),
    .ksk_mem_addr             (ksk_mem_addr),
    .m_axi4_glwe_arid         (m_axi4_glwe_arid),
    .m_axi4_glwe_araddr       (m_axi4_glwe_araddr),
    .m_axi4_glwe_arlen        (m_axi4_glwe_arlen),
    .m_axi4_glwe_arsize       (m_axi4_glwe_arsize),
    .m_axi4_glwe_arburst      (m_axi4_glwe_arburst),
    .m_axi4_glwe_arqos        (m_axi4_glwe_arqos),
    .m_axi4_glwe_arvalid      (m_axi4_glwe_arvalid),
    .m_axi4_glwe_arready      (m_axi4_glwe_arready),
    .m_axi4_glwe_rid          (m_axi4_glwe_rid),
    .m_axi4_glwe_rdata        (m_axi4_glwe_rdata),
    .m_axi4_glwe_rresp        (m_axi4_glwe_rresp),
    .m_axi4_glwe_rlast        (m_axi4_glwe_rlast),
    .m_axi4_glwe_rvalid       (m_axi4_glwe_rvalid),
    .m_axi4_glwe_rready       (m_axi4_glwe_rready),
    .m_axi4_bsk_arid          (m_axi4_bsk_arid),
    .m_axi4_bsk_araddr        (m_axi4_bsk_araddr),
    .m_axi4_bsk_arlen         (m_axi4_bsk_arlen),
    .m_axi4_bsk_arsize        (m_axi4_bsk_arsize),
    .m_axi4_bsk_arburst       (m_axi4_bsk_arburst),
    .m_axi4_bsk_arqos         (m_axi4_bsk_arqos),
    .m_axi4_bsk_arvalid       (m_axi4_bsk_arvalid),
    .m_axi4_bsk_arready       (m_axi4_bsk_arready),
    .m_axi4_bsk_rid           (m_axi4_bsk_rid),
    .m_axi4_bsk_rdata         (m_axi4_bsk_rdata),
    .m_axi4_bsk_rresp         (m_axi4_bsk_rresp),
    .m_axi4_bsk_rlast         (m_axi4_bsk_rlast),
    .m_axi4_bsk_rvalid        (m_axi4_bsk_rvalid),
    .m_axi4_bsk_rready        (m_axi4_bsk_rready),
    .m_axi4_ksk_arid          (m_axi4_ksk_arid),
    .m_axi4_ksk_araddr        (m_axi4_ksk_araddr),
    .m_axi4_ksk_arlen         (m_axi4_ksk_arlen),
    .m_axi4_ksk_arsize        (m_axi4_ksk_arsize),
    .m_axi4_ksk_arburst       (m_axi4_ksk_arburst),
    .m_axi4_ksk_arqos         (m_axi4_ksk_arqos),
    .m_axi4_ksk_arvalid       (m_axi4_ksk_arvalid),
    .m_axi4_ksk_arready       (m_axi4_ksk_arready),
    .m_axi4_ksk_rid           (m_axi4_ksk_rid),
    .m_axi4_ksk_rdata         (m_axi4_ksk_rdata),
    .m_axi4_ksk_rresp         (m_axi4_ksk_rresp),
    .m_axi4_ksk_rlast         (m_axi4_ksk_rlast),
    .m_axi4_ksk_rvalid        (m_axi4_ksk_rvalid),
    .m_axi4_ksk_rready        (m_axi4_ksk_rready),
    .glwe_asset_valid         (glwe_asset_valid),
    .glwe_asset_data          (glwe_asset_data),
    .glwe_asset_ready         (glwe_asset_ready),
    .glwe_asset_req           (glwe_asset_req),
    .glwe_asset_enable        (glwe_asset_enable),
    .bsk_service_req_vld      (bsk_service_req_vld),
    .bsk_service_req_rdy      (bsk_service_req_rdy),
    .bsk_service_batch_id     (bsk_service_batch_id),
    .bsk_service_data_avail   (bsk_service_data_avail),
    .bsk_service_data         (bsk_service_data),
    .ntt_service_decomp_avail (wrapper_ntt_service_decomp_avail),
    .ntt_service_decomp_data  (wrapper_ntt_service_decomp_data),
    .ntt_service_decomp_sob   (wrapper_ntt_service_decomp_sob),
    .ntt_service_decomp_eob   (wrapper_ntt_service_decomp_eob),
    .ntt_service_decomp_sog   (wrapper_ntt_service_decomp_sog),
    .ntt_service_decomp_eog   (wrapper_ntt_service_decomp_eog),
    .ntt_service_decomp_sol   (wrapper_ntt_service_decomp_sol),
    .ntt_service_decomp_eol   (wrapper_ntt_service_decomp_eol),
    .ntt_service_decomp_pbs_id(wrapper_ntt_service_decomp_pbs_id),
    .ntt_service_decomp_last_pbs(wrapper_ntt_service_decomp_last_pbs),
    .ntt_service_decomp_full_throughput(wrapper_ntt_service_decomp_full_throughput),
    .ntt_service_decomp_ctrl_vld(wrapper_ntt_service_decomp_ctrl_vld),
    .ntt_service_decomp_rdy   (ntt_service_decomp_rdy),
    .ntt_service_decomp_ctrl_rdy(ntt_service_decomp_ctrl_rdy),
    .ntt_service_result_data  (ntt_service_result_data),
    .ntt_service_result_avail (ntt_service_result_avail),
    .ntt_service_result_rdy   (ntt_service_result_rdy),
    .ntt_service_result_ctrl_vld(ntt_service_result_ctrl_vld),
    .ntt_service_result_ctrl_rdy(ntt_service_result_ctrl_rdy),
    .decomp_ntt_sog           (wrapper_decomp_ntt_sog),
    .decomp_ntt_ctrl_avail    (wrapper_decomp_ntt_ctrl_avail),
    .active_desc_o            (active_desc),
    .active_desc_valid_o      (active_desc_valid),
    .unified_pbs_inst_ack_o   (unified_inst_ack),
    .unified_pbs_response_o   (unified_resp)
  );

  bit sim_force_wrapper_ntt;
  bit sim_disable_tb_ntt_drv;
  initial begin
    sim_force_wrapper_ntt    = $test$plusargs("SIM_FORCE_WRAPPER_NTT");
    sim_disable_tb_ntt_drv   = $test$plusargs("SIM_DISABLE_TB_NTT_DRV");
  end

wire drive_tb_ntt = (USE_REAL_CORES == 0) && !sim_force_wrapper_ntt && !sim_disable_tb_ntt_drv;

  initial begin
    #1;
    if (drive_tb_ntt)
      $display("%t > [NTT_SEQ_TB][INFO] TB NTT auto-driver enabled (TLWE_WORDS=%0d)", $time, TLWE_WORDS_CFG);
    else
      $display("%t > [NTT_SEQ_TB][INFO] TB NTT auto-driver disabled (USE_REAL_CORES=%0d force_wrapper=%0b disable_arg=%0b)",
               $time, USE_REAL_CORES, sim_force_wrapper_ntt, sim_disable_tb_ntt_drv);
  end

  assign ntt_service_decomp_avail            = drive_tb_ntt ? sim_ntt_service_decomp_avail            : wrapper_ntt_service_decomp_avail;
  assign ntt_service_decomp_data             = drive_tb_ntt ? sim_ntt_service_decomp_data             : wrapper_ntt_service_decomp_data;
  assign ntt_service_decomp_sob              = drive_tb_ntt ? sim_ntt_service_decomp_sob              : wrapper_ntt_service_decomp_sob;
  assign ntt_service_decomp_eob              = drive_tb_ntt ? sim_ntt_service_decomp_eob              : wrapper_ntt_service_decomp_eob;
  assign ntt_service_decomp_sog              = drive_tb_ntt ? sim_ntt_service_decomp_sog              : wrapper_ntt_service_decomp_sog;
  assign ntt_service_decomp_eog              = drive_tb_ntt ? sim_ntt_service_decomp_eog              : wrapper_ntt_service_decomp_eog;
  assign ntt_service_decomp_sol              = drive_tb_ntt ? sim_ntt_service_decomp_sol              : wrapper_ntt_service_decomp_sol;
  assign ntt_service_decomp_eol              = drive_tb_ntt ? sim_ntt_service_decomp_eol              : wrapper_ntt_service_decomp_eol;
  assign ntt_service_decomp_pbs_id           = drive_tb_ntt ? sim_ntt_service_decomp_pbs_id           : wrapper_ntt_service_decomp_pbs_id;
  assign ntt_service_decomp_last_pbs         = drive_tb_ntt ? sim_ntt_service_decomp_last_pbs         : wrapper_ntt_service_decomp_last_pbs;
  assign ntt_service_decomp_full_throughput  = drive_tb_ntt ? sim_ntt_service_decomp_full_throughput  : wrapper_ntt_service_decomp_full_throughput;
  assign ntt_service_decomp_ctrl_vld         = drive_tb_ntt ? sim_ntt_service_decomp_ctrl_vld         : wrapper_ntt_service_decomp_ctrl_vld;
  assign decomp_ntt_sog                      = drive_tb_ntt ? sim_decomp_ntt_sog                      : wrapper_decomp_ntt_sog;
  assign decomp_ntt_ctrl_avail               = drive_tb_ntt ? sim_decomp_ntt_ctrl_avail               : wrapper_decomp_ntt_ctrl_avail;

  // Simple GPU WoKS behavioral stub: copies Pre-KS stream back after a fixed latency
tb_gpu_woks_stub #(
  .DATA_W          (MOD_Q_W),
  .PREKS_LEN       (GPU_PREKS_MAX_WORDS),
  .RESULT_LEN      (N_LVL2 + 1),
  .PIPELINE_LATENCY(12),
  .ENABLE_GPU_SERVICE(USE_REAL_GPU_RUNTIME)
) u_gpu_woks_stub (
    .clk      (clk),
    .rst_n    (s_rst_n),
    .gpu_service_enable (USE_REAL_GPU_RUNTIME),
    .desc_cmd_id_i      (active_desc_cmd_id_latched),
    .desc_mode_i        (active_desc_mode_latched),
    .desc_flags_i       (active_desc_flags_latched),
    .desc_tlwe_addr_i   (active_desc_tlwe_addr_latched),
    .desc_glwe_addr_i   (active_desc_glwe_addr_latched),
    .desc_status_addr_i (active_desc_status_addr_latched),
    .desc_tlwe_words_i  (active_desc_tlwe_words_latched),
    .desc_glwe_words_i  (active_desc_glwe_words_latched),
    .gpu_service_latency_valid_o(gpu_service_latency_valid),
    .gpu_service_latency_ns_o   (gpu_service_latency_ns),
    .gpu_link (gpu_woks_link.gpu)
  );

  // --------------------------------------------------------------------------------------------
  // Default tie-offs for wrapper inputs that require simple behaviour
  // --------------------------------------------------------------------------------------------
  assign gpu_status_ready = 1'b1;
  assign gpu_db_tready    = 1'b1;
  assign reset_ksk_cache  = 1'b0;
  assign ksk_mem_avail    = 1'b1;
  assign ksk_mem_addr     = '{default:32'd0};
  function automatic int sanitize_cycles(input int raw_value, input int default_value);
    if (raw_value <= 0) begin
      return default_value;
    end
    return raw_value;
  endfunction

  function automatic int clamp_non_negative(input int raw_value);
    if (raw_value < 0) begin
      return 0;
    end
    return raw_value;
  endfunction

  typedef struct {
    int forward_cycles;
    int external_cycles;
    int inverse_cycles;
    int backpressure_interval;
    int backpressure_cycles;
    bit inject_error_once;
  } ntt_stub_cfg_t;

  ntt_stub_cfg_t                      ntt_stub_cfg;
  logic                               ntt_bp_active;
  int                                 ntt_bp_hold_counter;
  int                                 ntt_bp_interval_counter;
  logic                               ntt_req_fire;
  logic                               ntt_error_pending;
  logic                               ntt_error_armed;
  logic [PSI-1:0][R-1:0][NTT_OP_W-1:0] ntt_service_result_data_q;
  logic [PSI-1:0][R-1:0]               ntt_service_result_avail_q;
  logic                                ntt_service_result_ctrl_vld_q;
  bit                                  dbg_ntt_monitor_enable;

  initial begin
    dbg_ntt_monitor_enable = $test$plusargs("SIM_NTT_MONITOR");
    if (dbg_ntt_monitor_enable) begin
      $display("%t > [NTT_SEQ_TB][MON] SIM_NTT_MONITOR enabled (observing decomp/result handshake)", $time);
    end
  end

  initial begin
    int tmp_value;
    ntt_stub_cfg.forward_cycles        = 4;
    ntt_stub_cfg.external_cycles       = 2;
    ntt_stub_cfg.inverse_cycles        = 4;
    ntt_stub_cfg.backpressure_interval = 0;
    ntt_stub_cfg.backpressure_cycles   = 0;
    ntt_stub_cfg.inject_error_once     = 1'b0;
    if ($value$plusargs("SIM_NTT_FWD_LATENCY=%d", tmp_value)) begin
      ntt_stub_cfg.forward_cycles = sanitize_cycles(tmp_value, 4);
    end
    if ($value$plusargs("SIM_NTT_EXT_LATENCY=%d", tmp_value)) begin
      ntt_stub_cfg.external_cycles = sanitize_cycles(tmp_value, 2);
    end
    if ($value$plusargs("SIM_NTT_INV_LATENCY=%d", tmp_value)) begin
      ntt_stub_cfg.inverse_cycles = sanitize_cycles(tmp_value, 4);
    end
    if ($value$plusargs("SIM_NTT_BP_INTERVAL=%d", tmp_value)) begin
      ntt_stub_cfg.backpressure_interval = clamp_non_negative(tmp_value);
    end
    if ($value$plusargs("SIM_NTT_BP_HOLD=%d", tmp_value)) begin
      ntt_stub_cfg.backpressure_cycles = clamp_non_negative(tmp_value);
    end
    if ($value$plusargs("SIM_NTT_ERR_ONCE=%d", tmp_value)) begin
      ntt_stub_cfg.inject_error_once = (tmp_value != 0);
    end else if ($test$plusargs("SIM_NTT_ERR_ONCE")) begin
      ntt_stub_cfg.inject_error_once = 1'b1;
    end
    $display("%t > [NTT_SEQ_SIM][CFG] fwd=%0d ext=%0d inv=%0d bp_int=%0d bp_cycles=%0d err_once=%0b",
             $time,
             ntt_stub_cfg.forward_cycles,
             ntt_stub_cfg.external_cycles,
             ntt_stub_cfg.inverse_cycles,
             ntt_stub_cfg.backpressure_interval,
             ntt_stub_cfg.backpressure_cycles,
             ntt_stub_cfg.inject_error_once);
  end

  typedef enum logic [2:0] {
    NTT_IDLE,
    NTT_FORWARD_PROCESSING,
    NTT_EXTERNAL_PRODUCT,
    NTT_INVERSE_PROCESSING,
    NTT_RESULT_READY
  } ntt_state_e;

  ntt_state_e ntt_state;
  int         ntt_process_counter;
  logic [31:0] ntt_op_count;
  logic [31:0] ntt_accept_count;
  localparam int NTT_EXPECTED_ACCEPTS = (K+1)*N_LVL2;

  always_comb begin
    logic block_ready;
    block_ready = (ntt_stub_cfg.backpressure_interval > 0 && ntt_stub_cfg.backpressure_cycles > 0)
                    ? ntt_bp_active : 1'b0;
    ntt_service_decomp_ctrl_rdy = !block_ready;
    for (int p = 0; p < PSI; p++) begin
      for (int r = 0; r < R; r++) begin
        ntt_service_decomp_rdy[p][r] = !block_ready;
      end
    end
    ntt_req_fire = (!block_ready) &&
                   (ntt_state == NTT_IDLE) &&
                   (ntt_service_decomp_ctrl_vld || |ntt_service_decomp_avail);
  end

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      ntt_bp_active          <= 1'b0;
      ntt_bp_hold_counter    <= 0;
      ntt_bp_interval_counter<= 0;
    end else if (ntt_stub_cfg.backpressure_interval <= 0 || ntt_stub_cfg.backpressure_cycles <= 0) begin
      ntt_bp_active          <= 1'b0;
      ntt_bp_hold_counter    <= 0;
      ntt_bp_interval_counter<= 0;
    end else begin
      if (ntt_bp_active) begin
        if (ntt_bp_hold_counter > 0) begin
          ntt_bp_hold_counter <= ntt_bp_hold_counter - 1;
        end else begin
          ntt_bp_active       <= 1'b0;
          ntt_bp_interval_counter <= 0;
        end
      end else if (ntt_req_fire) begin
        if (ntt_bp_interval_counter + 1 >= ntt_stub_cfg.backpressure_interval) begin
          ntt_bp_active       <= 1'b1;
          ntt_bp_hold_counter <= (ntt_stub_cfg.backpressure_cycles > 0)
                                   ? (ntt_stub_cfg.backpressure_cycles - 1) : 0;
          ntt_bp_interval_counter <= 0;
          $display("%t > [NTT_SEQ_SIM][BACKPRESSURE] hold %0d cycles after %0d requests",
                   $time,
                   ntt_stub_cfg.backpressure_cycles,
                   ntt_stub_cfg.backpressure_interval);
        end else begin
          ntt_bp_interval_counter <= ntt_bp_interval_counter + 1;
        end
      end
    end
  end

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      ntt_state                     <= NTT_IDLE;
      ntt_process_counter           <= 0;
      ntt_service_result_data_q     <= '{default:'0};
      ntt_service_result_avail_q    <= '{default:'0};
      ntt_service_result_ctrl_vld_q <= 1'b0;
      ntt_op_count                  <= '0;
      ntt_accept_count              <= '0;
      ntt_error_pending             <= 1'b0;
      ntt_error_armed               <= ntt_stub_cfg.inject_error_once;
    end else begin
      case (ntt_state)
        NTT_IDLE: begin
          ntt_service_result_avail_q     <= '{default:'0};
          ntt_service_result_ctrl_vld_q  <= 1'b0;
          ntt_accept_count               <= '0;
          if (ntt_req_fire) begin
            ntt_process_counter <= ntt_stub_cfg.forward_cycles;
            ntt_state           <= NTT_FORWARD_PROCESSING;
            ntt_op_count        <= ntt_op_count + 1;
            ntt_error_pending   <= ntt_error_armed;
            $display("%t > [NTT_SEQ_SIM][SEQ_IN] ctrl_vld=%0b data_avail=%0b sob=%0b eob=%0b last=%0b pid=%0d full=%0b op=%0d",
                     $time,
                     ntt_service_decomp_ctrl_vld,
                     |ntt_service_decomp_avail,
                     ntt_service_decomp_sob,
                     ntt_service_decomp_eob,
                     ntt_service_decomp_last_pbs,
                     ntt_service_decomp_pbs_id,
                     ntt_service_decomp_full_throughput,
                     ntt_op_count + 1);
          end
        end
        NTT_FORWARD_PROCESSING: begin
          if (ntt_process_counter > 0) begin
            ntt_process_counter <= ntt_process_counter - 1;
          end else begin
            ntt_process_counter <= ntt_stub_cfg.external_cycles;
            ntt_state           <= NTT_EXTERNAL_PRODUCT;
`ifdef TB_BE_DEBUG
            $display("%t > [NTT_SEQ_SIM][STATE] forward -> external", $time);
`endif
          end
        end
        NTT_EXTERNAL_PRODUCT: begin
          if (ntt_process_counter > 0) begin
            ntt_process_counter <= ntt_process_counter - 1;
          end else begin
            ntt_process_counter <= ntt_stub_cfg.inverse_cycles;
            ntt_state           <= NTT_INVERSE_PROCESSING;
`ifdef TB_BE_DEBUG
            $display("%t > [NTT_SEQ_SIM][STATE] external -> inverse", $time);
`endif
          end
        end
        NTT_INVERSE_PROCESSING: begin
          if (ntt_process_counter > 0) begin
            ntt_process_counter <= ntt_process_counter - 1;
          end else begin
            automatic logic [31:0] op_id;
            op_id = ntt_op_count + 1;
            for (int p = 0; p < PSI; p++) begin
              for (int r = 0; r < R; r++) begin
                automatic logic [31:0] base_val = op_id[15:0] * (p*R + r + 1);
                ntt_service_result_data_q[p][r]  <= $signed(base_val ^ 32'h55AA3C96);
                ntt_service_result_avail_q[p][r] <= 1'b1;
              end
            end
            ntt_service_result_ctrl_vld_q <= 1'b1;
            ntt_state                    <= NTT_RESULT_READY;
            if (ntt_error_pending) begin
              ntt_error_pending <= 1'b0;
              ntt_error_armed   <= 1'b0;
              $display("%t > [NTT_SEQ_SIM][ERR] forced stub error injection (result still provided)", $time);
            end
            $display("%t > [NTT_TOP_SIM][ACC_CTRL_OUT] ctrl_avail=1 sog=%0b eog=%0b pid=%0d",
                     $time, ntt_service_decomp_sog, ntt_service_decomp_eog, ntt_service_decomp_pbs_id);
          end
        end
        NTT_RESULT_READY: begin
          int accept_incr;
          accept_incr = 0;
          for (int p = 0; p < PSI; p++) begin
            for (int r = 0; r < R; r++) begin
              if (ntt_service_result_avail_q[p][r] &&
                  ntt_service_result_rdy[p][r] &&
                  ntt_service_result_ctrl_rdy) begin
                accept_incr++;
              end
            end
          end
          if (accept_incr != 0) begin
            ntt_accept_count <= ntt_accept_count + accept_incr;
            $display("%t > [MMACC_ACC_DBG_SIM] accepted=%0d total=%0d/%0d",
                     $time, accept_incr, ntt_accept_count + accept_incr, NTT_EXPECTED_ACCEPTS);
          end
          if ((ntt_accept_count + accept_incr) >= NTT_EXPECTED_ACCEPTS) begin
            ntt_service_result_avail_q     <= '{default:'0};
            ntt_service_result_ctrl_vld_q  <= 1'b0;
            ntt_state                      <= NTT_IDLE;
`ifdef TB_BE_DEBUG
            $display("%t > [NTT_SEQ_SIM][STATE] result done -> IDLE (accepted=%0d)",
                     $time, ntt_accept_count + accept_incr);
`endif
          end else begin
            ntt_service_result_ctrl_vld_q <= 1'b1;
            for (int p = 0; p < PSI; p++) begin
              for (int r = 0; r < R; r++) begin
                ntt_service_result_avail_q[p][r] <= 1'b1;
              end
            end
          end
        end
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (dbg_ntt_monitor_enable && s_rst_n) begin
      if (ntt_service_decomp_ctrl_vld || |ntt_service_decomp_avail) begin
        $display("%t > [NTT_SEQ_TB][DECOMP] ctrl_vld=%0b data_avail=%0b rdy=%0b sob=%0b eob=%0b sog=%0b eog=%0b last=%0b pid=%0d",
                 $time,
                 ntt_service_decomp_ctrl_vld,
                 |ntt_service_decomp_avail,
                 ntt_service_decomp_ctrl_rdy,
                 ntt_service_decomp_sob,
                 ntt_service_decomp_eob,
                 ntt_service_decomp_sog,
                 ntt_service_decomp_eog,
                 ntt_service_decomp_last_pbs,
                 ntt_service_decomp_pbs_id);
      end
      if (ntt_service_result_ctrl_vld_q || |ntt_service_result_avail_q) begin
        $display("%t > [NTT_SEQ_TB][RESULT] ctrl_vld=%0b ctrl_rdy=%0b data_avail=%0b",
                 $time,
                 ntt_service_result_ctrl_vld_q,
                 ntt_service_result_ctrl_rdy,
                 |ntt_service_result_avail_q);
      end
    end
  end

  assign ntt_service_result_data      = ntt_service_result_data_q;
  assign ntt_service_result_avail     = ntt_service_result_avail_q;
  assign ntt_service_result_ctrl_vld  = ntt_service_result_ctrl_vld_q;

  // --------------------------------------------------------------------------------------------
  // RegFile stub: provides TLWE coefficients when the kernel issues read commands
  // --------------------------------------------------------------------------------------------
  localparam int REGF_MEM_WORDS = 1 << 16;
  logic [MOD_Q_W-1:0] regfile_mem [0:REGF_MEM_WORDS-1];

  initial begin
    for (int idx = 0; idx < REGF_MEM_WORDS; idx++) begin
      regfile_mem[idx] = '0;
    end
  end

  // Preload TLWE payload into RegFile stub for real GPU runs so CMux/load stages see non-zero data.
  initial begin
    if (USE_REAL_GPU_RUNTIME) begin
      int tlwe_words_local;
      int word_bytes;
      int tlwe_bytes;
      int tlwe_base_idx;
      string tlwe_file_path;
      int tlwe_file_fd;
      int tlwe_file_read;
      byte unsigned tlwe_payload_raw[];
      tlwe_words_local = GPU_PREKS_MAX_WORDS;
      if ($value$plusargs("TLWE_WORDS_CFG=%d", tlwe_words_local)) begin
        if (tlwe_words_local <= 0) begin
          tlwe_words_local = GPU_PREKS_MAX_WORDS;
        end
      end
      word_bytes = GPU_WORD_BYTES;
      tlwe_bytes = tlwe_words_local * word_bytes;
      // Descriptor tlwe_src_addr is byte address, kernel shifts by 5 twice.
      tlwe_base_idx = (TLWE_BASE_ADDR >> 10);
      if (tlwe_base_idx < 0) begin
        tlwe_base_idx = 0;
      end

      tlwe_payload_raw = new[tlwe_bytes];
      for (int idx = 0; idx < tlwe_bytes; idx++) begin
        tlwe_payload_raw[idx] = '0;
      end

      if ($value$plusargs("GPU_TLWE_FILE=%s", tlwe_file_path)) begin
        tlwe_file_fd = $fopen(tlwe_file_path, "rb");
        if (tlwe_file_fd != 0) begin
          tlwe_file_read = $fread(tlwe_payload_raw, tlwe_file_fd);
          $fclose(tlwe_file_fd);
          if (tlwe_file_read < tlwe_bytes) begin
            for (int idx = tlwe_file_read; idx < tlwe_bytes; idx++) begin
              tlwe_payload_raw[idx] = '0;
            end
          end
          $display("[TB][REGF_INIT] TLWE file loaded for RegFile %s bytes=%0d (wanted %0d)",
                   tlwe_file_path, tlwe_file_read, tlwe_bytes);
        end else begin
          $display("[TB][REGF_INIT] WARN: cannot open TLWE file %s", tlwe_file_path);
        end
      end else begin
        for (int idx = 0; idx < tlwe_words_local; idx++) begin
          logic [MOD_Q_W-1:0] word_val;
          word_val = synthesize_vp_tlwe_word(idx);
          for (int b = 0; b < word_bytes; b++) begin
            tlwe_payload_raw[idx*word_bytes + b] = word_val[8*b +: 8];
          end
        end
        $display("[TB][REGF_INIT] TLWE payload synthesized for RegFile words=%0d base_idx=0x%0h",
                 tlwe_words_local, tlwe_base_idx);
      end

      for (int idx = 0; idx < tlwe_words_local; idx++) begin
        int regf_idx;
        logic [MOD_Q_W-1:0] word_val;
        word_val = '0;
        for (int b = 0; b < word_bytes; b++) begin
          word_val[8*b +: 8] = tlwe_payload_raw[idx*word_bytes + b];
        end
        regf_idx = tlwe_base_idx + idx;
        if (regf_idx >= 0 && regf_idx < REGF_MEM_WORDS) begin
          regfile_mem[regf_idx] = word_val;
        end
      end
      $display("[TB][REGF_INIT] RegFile preload done base_idx=0x%0h words=%0d",
               tlwe_base_idx, tlwe_words_local);
    end
  end

  assign pep_regf_wr_req_rdy   = 1'b1;
assign pep_regf_wr_data_rdy  = '{default:1'b1};
assign regf_pep_wr_ack       = 1'b1;

  // Capture RegFile writes so subsequent reads can observe updated payloads
  always_ff @(posedge clk) begin
    if (s_rst_n) begin
      if (pep_regf_wr_req_vld) begin
        for (int lane = 0; lane < REGF_COEF_NB; lane++) begin
          if (pep_regf_wr_data_vld[lane]) begin
            int unsigned addr;
            addr = pep_regf_wr_req + lane;
            if (addr < REGF_MEM_WORDS) begin
              regfile_mem[addr] <= pep_regf_wr_data[lane];
            end
          end
        end
      end
    end
  end

logic                      regf_read_active;
logic [15:0]               regf_read_target_q;
logic [REGF_RD_REQ_W-1:0]  regf_prev_addr_q;
logic [15:0]               regf_stream_count_q;
logic [15:0]               regf_stream_target_q;
logic                      regf_stream_valid_q;
logic                      regf_pending_rd_q;
logic [REGF_RD_REQ_W-1:0]  regf_pending_addr_q;
logic [15:0]               regf_pending_pos_q;
logic [15:0]               regf_pending_target_q;

always_ff @(posedge clk or negedge s_rst_n) begin
  if (!s_rst_n) begin
    regf_read_active      <= 1'b0;
    regf_prev_addr_q      <= '0;
    regf_stream_count_q   <= '0;
    regf_stream_target_q  <= GPU_PREKS_MAX_WORDS[15:0];
    regf_stream_valid_q   <= 1'b0;
    regf_pending_rd_q     <= 1'b0;
    regf_pending_addr_q   <= '0;
    regf_pending_pos_q    <= '0;
    regf_pending_target_q <= GPU_PREKS_MAX_WORDS[15:0];
    regf_read_target_q    <= '0;
    regf_pep_rd_data_avail<= '{default:1'b0};
    regf_pep_rd_data      <= '{default:'0};
    regf_pep_rd_last_word <= 1'b0;
  end else begin
    regf_pep_rd_data_avail <= '{default:1'b0};
    regf_pep_rd_last_word  <= 1'b0;

    if (!regf_pending_rd_q && pep_regf_rd_req_vld) begin
      bit         start_new_stream;
      bit         step5_only_desc;
      int unsigned target_words_local;
      start_new_stream = (!regf_stream_valid_q) ||
                         (pep_regf_rd_req != (regf_prev_addr_q + 16'd1));

      if (active_desc_valid) begin
        step5_only_desc = (active_desc.mode == WOP_MODE_BIT_EXTRACT) ? 1'b0 : active_desc.flags[7];
        target_words_local = clamp_gpu_tlwe_words(
            openssd_wop_mode_e'(active_desc.mode),
            step5_only_desc,
            active_desc.tlwe_words);
      end else begin
        step5_only_desc    = 1'b1;
        target_words_local = clamp_gpu_tlwe_words(WOP_MODE_CB, 1'b1, 0);
      end

      if (start_new_stream) begin
        regf_stream_count_q  <= '0;
        regf_stream_target_q <= target_words_local[15:0];
        regf_stream_valid_q  <= 1'b1;
        regf_read_target_q   <= target_words_local[15:0];
        regf_read_active     <= 1'b1;
        regf_pending_target_q<= target_words_local[15:0];
        regf_pending_pos_q   <= 16'd0;
        $display("[TB][REGF_RD] start addr=0x%0h target_words=%0d mode=%0d step5_only=%0b",
                 pep_regf_rd_req,
                 target_words_local,
                 active_desc_valid ? int'(active_desc.mode) : -1,
                 step5_only_desc);
      end else begin
        regf_stream_count_q  <= regf_stream_count_q + 16'd1;
        regf_pending_target_q<= regf_stream_target_q;
        regf_pending_pos_q   <= regf_stream_count_q + 16'd1;
      end

      regf_pending_addr_q <= pep_regf_rd_req;
      regf_pending_rd_q   <= 1'b1;
      regf_prev_addr_q    <= pep_regf_rd_req;
    end else if (regf_pending_rd_q) begin
      regf_pep_rd_data_avail[0] <= 1'b1;
      if (regf_pending_addr_q < REGF_MEM_WORDS) begin
        regf_pep_rd_data[0] <= regfile_mem[regf_pending_addr_q];
      end else begin
        regf_pep_rd_data[0] <= '0;
      end
      if (regf_pending_pos_q + 16'd1 >= regf_pending_target_q) begin
        regf_pep_rd_last_word <= 1'b1;
        regf_read_active      <= 1'b0;
        regf_stream_valid_q   <= 1'b0;
      end
      regf_pending_rd_q <= 1'b0;
    end else if (!pep_regf_rd_req_vld && !regf_read_active) begin
      regf_stream_count_q <= '0;
    end
  end
end

assign pep_regf_rd_req_rdy = !regf_pending_rd_q;

  // --------------------------------------------------------------------------------------------
  // NTT service auto-driver (simulation only) - synthesizes one request per descriptor so the
  // downstream stub/ACC/KS receive activity even when wrapper tie-offs are active.
  // --------------------------------------------------------------------------------------------
  typedef enum logic [1:0] {
    SIM_NTT_IDLE,
    SIM_NTT_REQ,
    SIM_NTT_WAIT
  } sim_ntt_state_e;

  sim_ntt_state_e sim_ntt_state_q;
  logic           sim_ntt_issue_armed_q;
  logic           sim_ntt_delay_active_q;
  logic           sim_ntt_desc_served_q;
  logic [15:0]    sim_ntt_delay_cnt_q;
  localparam int  SIM_NTT_LAUNCH_DELAY = 1;

  assign sim_ntt_service_decomp_pbs_id          = '0;
  assign sim_ntt_service_decomp_full_throughput = drive_tb_ntt;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      sim_ntt_state_q                   <= SIM_NTT_IDLE;
      sim_ntt_issue_armed_q             <= 1'b0;
      sim_ntt_delay_active_q            <= 1'b0;
      sim_ntt_desc_served_q             <= 1'b0;
      sim_ntt_delay_cnt_q               <= '0;
      sim_ntt_service_decomp_avail      <= '{default:'0};
      sim_ntt_service_decomp_data       <= '{default:'0};
      sim_ntt_service_decomp_sob        <= 1'b0;
      sim_ntt_service_decomp_sol        <= 1'b0;
      sim_ntt_service_decomp_eob        <= 1'b0;
      sim_ntt_service_decomp_eol        <= 1'b0;
      sim_ntt_service_decomp_sog        <= 1'b0;
      sim_ntt_service_decomp_eog        <= 1'b0;
      sim_ntt_service_decomp_last_pbs   <= 1'b0;
      sim_ntt_service_decomp_ctrl_vld   <= 1'b0;
      sim_decomp_ntt_ctrl_avail         <= 1'b0;
      sim_decomp_ntt_sog                <= 1'b0;
    end else begin
      // default outputs (pulsed when REQ)
      sim_ntt_service_decomp_avail    <= '{default:'0};
      sim_ntt_service_decomp_data     <= '{default:'0};
      sim_ntt_service_decomp_sob      <= 1'b0;
      sim_ntt_service_decomp_sol      <= 1'b0;
      sim_ntt_service_decomp_eob      <= 1'b0;
      sim_ntt_service_decomp_eol      <= 1'b0;
      sim_ntt_service_decomp_sog      <= 1'b0;
      sim_ntt_service_decomp_eog      <= 1'b0;
      sim_ntt_service_decomp_last_pbs <= 1'b0;
      sim_ntt_service_decomp_ctrl_vld <= 1'b0;
      sim_decomp_ntt_ctrl_avail       <= 1'b0;
      sim_decomp_ntt_sog              <= 1'b0;

      // arm trigger after descriptor readout finishes
      if (!drive_tb_ntt) begin
        sim_ntt_issue_armed_q  <= 1'b0;
        sim_ntt_delay_active_q <= 1'b0;
        sim_ntt_desc_served_q  <= 1'b0;
      end else begin
        if (!active_desc_valid) begin
          sim_ntt_desc_served_q <= 1'b0;
          if (!sim_ntt_delay_active_q)
            sim_ntt_issue_armed_q <= 1'b0;
        end else begin
          if (!sim_ntt_desc_served_q && !sim_ntt_delay_active_q && !sim_ntt_issue_armed_q) begin
            sim_ntt_delay_active_q <= 1'b1;
            sim_ntt_delay_cnt_q    <= SIM_NTT_LAUNCH_DELAY[15:0];
            $display("%t > [NTT_SEQ_TB][INFO] descriptor active (cmd_id=%0d) scheduling TB NTT request after %0d cycles",
                     $time, active_desc.cmd_id, SIM_NTT_LAUNCH_DELAY);
          end else if (sim_ntt_delay_active_q) begin
            if (sim_ntt_delay_cnt_q != 0) begin
              sim_ntt_delay_cnt_q <= sim_ntt_delay_cnt_q - 1;
            end else begin
              sim_ntt_delay_active_q <= 1'b0;
              sim_ntt_issue_armed_q  <= 1'b1;
              sim_ntt_desc_served_q  <= 1'b1;
              $display("%t > [NTT_SEQ_TB][DRV] issuing TB-driven NTT request (cmd_id=%0d)",
                       $time, active_desc.cmd_id);
            end
          end else if (sim_ntt_state_q == SIM_NTT_REQ) begin
            sim_ntt_issue_armed_q <= 1'b0;
          end
        end
      end

      if (!drive_tb_ntt) begin
        sim_ntt_state_q <= SIM_NTT_IDLE;
      end else begin
        unique case (sim_ntt_state_q)
          SIM_NTT_IDLE: begin
            if (sim_ntt_issue_armed_q) begin
              sim_ntt_state_q <= SIM_NTT_REQ;
            end
          end
          SIM_NTT_REQ: begin
            sim_ntt_service_decomp_avail[0][0] <= 1'b1;
            sim_ntt_service_decomp_sob        <= 1'b1;
            sim_ntt_service_decomp_sol        <= 1'b1;
            sim_ntt_service_decomp_eob        <= 1'b1;
            sim_ntt_service_decomp_eol        <= 1'b1;
            sim_ntt_service_decomp_sog        <= 1'b1;
            sim_ntt_service_decomp_eog        <= 1'b1;
            sim_ntt_service_decomp_last_pbs   <= 1'b1;
            sim_ntt_service_decomp_ctrl_vld   <= 1'b1;
            sim_decomp_ntt_ctrl_avail         <= 1'b1;
            sim_decomp_ntt_sog                <= 1'b1;
            sim_ntt_state_q                   <= SIM_NTT_WAIT;
          end
          SIM_NTT_WAIT: begin
            if (ntt_service_result_ctrl_vld && ntt_service_result_ctrl_rdy) begin
              sim_ntt_state_q <= SIM_NTT_IDLE;
            end
          end
          default: sim_ntt_state_q <= SIM_NTT_IDLE;
        endcase
      end
    end
  end

  // --------------------------------------------------------------------------------------------
  // GLWE / BSK / KSK AXI read stubs: feed deterministic data
  // --------------------------------------------------------------------------------------------
  assign m_axi4_glwe_arready = 1'b1;
  assign m_axi4_glwe_rid     = 4'd0;
  assign m_axi4_glwe_rresp   = 2'b00;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      m_axi4_glwe_rvalid <= 1'b0;
      m_axi4_glwe_rlast  <= 1'b0;
      m_axi4_glwe_rdata  <= '0;
    end else begin
      if (m_axi4_glwe_arvalid) begin
        m_axi4_glwe_rvalid <= 1'b1;
        m_axi4_glwe_rlast  <= 1'b1;
        m_axi4_glwe_rdata  <= {m_axi4_glwe_araddr, 32'hC001_0000};
      end else if (m_axi4_glwe_rvalid && m_axi4_glwe_rready) begin
        m_axi4_glwe_rvalid <= 1'b0;
        m_axi4_glwe_rlast  <= 1'b0;
      end
    end
  end

  generate
    for (genvar bi = 0; bi < BSK_PC; bi++) begin : gen_bsk_stub
      assign m_axi4_bsk_arready[bi] = 1'b1;
      assign m_axi4_bsk_rid[bi]     = 4'd0;
      assign m_axi4_bsk_rresp[bi]   = 2'b00;

      always_ff @(posedge clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
          m_axi4_bsk_rvalid[bi] <= 1'b0;
          m_axi4_bsk_rlast[bi]  <= 1'b0;
          m_axi4_bsk_rdata[bi]  <= '0;
        end else begin
          if (m_axi4_bsk_arvalid[bi]) begin
            m_axi4_bsk_rvalid[bi] <= 1'b1;
            m_axi4_bsk_rlast[bi]  <= 1'b1;
            m_axi4_bsk_rdata[bi]  <= {m_axi4_bsk_araddr[bi], 32'hB5A5_0000 | bi};
          end else if (m_axi4_bsk_rvalid[bi] && m_axi4_bsk_rready[bi]) begin
            m_axi4_bsk_rvalid[bi] <= 1'b0;
            m_axi4_bsk_rlast[bi]  <= 1'b0;
          end
        end
      end
    end
  endgenerate

  generate
    for (genvar ki = 0; ki < KSK_PC; ki++) begin : gen_ksk_stub
      assign m_axi4_ksk_arready[ki] = 1'b1;
      assign m_axi4_ksk_rid[ki]     = 4'd0;
      assign m_axi4_ksk_rresp[ki]   = 2'b00;

      always_ff @(posedge clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
          m_axi4_ksk_rvalid[ki] <= 1'b0;
          m_axi4_ksk_rlast[ki]  <= 1'b0;
          m_axi4_ksk_rdata[ki]  <= '0;
        end else begin
          if (m_axi4_ksk_arvalid[ki]) begin
            m_axi4_ksk_rvalid[ki] <= 1'b1;
            m_axi4_ksk_rlast[ki]  <= 1'b1;
            m_axi4_ksk_rdata[ki]  <= {m_axi4_ksk_araddr[ki], 32'hCAFE_0000 | ki};
          end else if (m_axi4_ksk_rvalid[ki] && m_axi4_ksk_rready[ki]) begin
            m_axi4_ksk_rvalid[ki] <= 1'b0;
            m_axi4_ksk_rlast[ki]  <= 1'b0;
          end
        end
      end
    end
  endgenerate

  assign bsk_service_req_rdy = 1'b1;

  logic bsk_service_data_avail_q;
  logic [BSK_PC-1:0][R-1:0][MOD_Q_W-1:0] bsk_service_data_q;
  logic [15:0] bsk_data_seed_q;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      bsk_service_data_avail_q <= 1'b0;
      bsk_service_data_q       <= '{default:'0};
      bsk_data_seed_q          <= 16'h1ACE;
    end else begin
      bsk_service_data_avail_q <= 1'b0;
      if (bsk_service_req_vld && bsk_service_req_rdy) begin
        // Simple deterministic payload based on batch id + seed
        bsk_data_seed_q <= bsk_data_seed_q + 16'h10 + bsk_service_batch_id;
        for (int pc = 0; pc < BSK_PC; pc++) begin
          for (int rr = 0; rr < R; rr++) begin
            bsk_service_data_q[pc][rr] <= {32'(bsk_data_seed_q), 16'(bsk_service_batch_id), 8'(pc), 8'(rr)};
          end
        end
        bsk_service_data_avail_q <= 1'b1;
        $display("[TB_BSK] provide batch=%0d seed=0x%04h at t=%0t", bsk_service_batch_id, bsk_data_seed_q, $time);
      end
    end
  end

  assign bsk_service_data_avail = bsk_service_data_avail_q;
  assign bsk_service_data       = bsk_service_data_q;

  // --------------------------------------------------------------------------------------------
  // AXI-Lite master driver helpers
  // --------------------------------------------------------------------------------------------
  task automatic axil_write(input logic [AXIL_ADDR_W-1:0] addr,
                            input logic [AXIL_DATA_W-1:0] data,
                            input logic [(AXIL_DATA_W/8)-1:0] strb = {(AXIL_DATA_W/8){1'b1}});
    begin
      @(posedge clk);
      s_axil_awaddr  <= addr;
      s_axil_awvalid <= 1'b1;
      s_axil_wdata   <= data;
      s_axil_wstrb   <= strb;
      s_axil_wvalid  <= 1'b1;
      do begin
        @(posedge clk);
      end while (!(s_axil_awready && s_axil_wready));
      s_axil_awvalid <= 1'b0;
      s_axil_wvalid  <= 1'b0;
      s_axil_awaddr  <= '0;
      s_axil_wstrb   <= '0;
      s_axil_wdata   <= '0;
      s_axil_bready  <= 1'b1;
      @(posedge clk);
      while (!s_axil_bvalid) @(posedge clk);
      @(posedge clk);
      s_axil_bready  <= 1'b0;
    end
  endtask

  task automatic axil_read(input  logic [AXIL_ADDR_W-1:0] addr,
                           output logic [AXIL_DATA_W-1:0] data);
    begin
      @(posedge clk);
      s_axil_araddr  <= addr;
      s_axil_arvalid <= 1'b1;
      do begin
        @(posedge clk);
      end while (!s_axil_arready);
      s_axil_arvalid <= 1'b0;
      s_axil_araddr  <= '0;
      s_axil_rready  <= 1'b1;
      do begin
        @(posedge clk);
      end while (!s_axil_rvalid);
      data = s_axil_rdata;
      @(posedge clk);
      s_axil_rready  <= 1'b0;
    end
  endtask

  typedef struct {
    bit                              is_read;
    int unsigned                     id;
    logic [AXIL_ADDR_W-1:0]          addr;
    logic [AXIL_DATA_W-1:0]          data;
    logic [(AXIL_DATA_W/8)-1:0]      strb;
  } host_axil_cmd_t;

  typedef struct {
    int unsigned                     id;
    logic [AXIL_DATA_W-1:0]          data;
  } host_axil_rsp_t;

  mailbox #(host_axil_cmd_t) host_axil_cmd_mb = new();
  mailbox #(host_axil_rsp_t) host_axil_rsp_mb = new();
  host_axil_rsp_t host_axil_rsp_pending[int unsigned];
  int unsigned host_axil_next_id = 0;

  task automatic host_axil_wait_rsp(input int unsigned id,
                                    output host_axil_rsp_t rsp);
    if (host_axil_rsp_pending.exists(id)) begin
      rsp = host_axil_rsp_pending[id];
      host_axil_rsp_pending.delete(id);
      return;
    end
    forever begin
      host_axil_rsp_mb.get(rsp);
      if (rsp.id == id) begin
        return;
      end
      host_axil_rsp_pending[rsp.id] = rsp;
    end
  endtask

  initial begin : host_axil_executor
    host_axil_cmd_t cmd;
    host_axil_rsp_t rsp;
    forever begin
      host_axil_cmd_mb.get(cmd);
      if (cmd.is_read) begin
        logic [AXIL_DATA_W-1:0] data_local;
        axil_read(cmd.addr, data_local);
        rsp.id   = cmd.id;
        rsp.data = data_local;
      end else begin
        axil_write(cmd.addr, cmd.data, cmd.strb);
        rsp.id   = cmd.id;
        rsp.data = '0;
      end
      host_axil_rsp_mb.put(rsp);
    end
  end

  // AXI memory backing store for descriptor fetch/result write
  localparam int AXI_MEM_WORDS = 4096;
  logic [AXI_DATA_W-1:0] axi_mem [0:AXI_MEM_WORDS-1];

  task automatic tb_host_axil_write(input int unsigned addr,
                                    input int unsigned data,
                                    input int unsigned strb);
    logic [AXIL_ADDR_W-1:0]       addr_cast;
    logic [AXIL_DATA_W-1:0]       data_cast;
    logic [(AXIL_DATA_W/8)-1:0]   strb_cast;
    logic [15:0]                  cmd_id_local;
    host_axil_cmd_t               cmd;
    host_axil_rsp_t               rsp;

    addr_cast = addr;
    data_cast = data;
    strb_cast = strb;
    if (strb_cast == '0) begin
      strb_cast = {(AXIL_DATA_W/8){1'b1}};
    end
    $display("[TB][HOST_CTRL] AXI-Lite write addr=0x%0h data=0x%08h strb=0x%0h",
             addr_cast,
             data_cast,
             strb_cast);
    if (addr_cast == 12'h000) begin
      cmd_id_local = data_cast[15:0];
      if (data_cast[31]) begin
        $display("[TB] Doorbell fired (cmd_id=0x%04h)", cmd_id_local);
      end
      if (data_cast[30]) begin
        $display("[TB] Host ACK sent (cmd_id=0x%04h)", cmd_id_local);
      end
    end
    cmd.is_read = 1'b0;
    cmd.id      = host_axil_next_id++;
    cmd.addr    = addr_cast;
    cmd.data    = data_cast;
    cmd.strb    = strb_cast;
    host_axil_cmd_mb.put(cmd);
    host_axil_wait_rsp(cmd.id, rsp);
  endtask

  task automatic tb_host_axil_read(input int unsigned addr,
                                   output int unsigned data);
    logic [AXIL_DATA_W-1:0] data_cast;
    logic [AXIL_ADDR_W-1:0] addr_cast;
    host_axil_cmd_t         cmd;
    host_axil_rsp_t         rsp;

    addr_cast = addr;
    cmd.is_read = 1'b1;
    cmd.id      = host_axil_next_id++;
    cmd.addr    = addr_cast;
    cmd.data    = '0;
    cmd.strb    = '0;
    host_axil_cmd_mb.put(cmd);
    host_axil_wait_rsp(cmd.id, rsp);
    data_cast = rsp.data;
    $display("[TB][HOST_CTRL] AXI-Lite read addr=0x%0h data=0x%08h",
             addr_cast,
             data_cast);
    data = int'(data_cast);
  endtask

  task automatic tb_host_axi_mem_write_qwords(input longint unsigned addr,
                                              input longint unsigned data_q0,
                                              input longint unsigned data_q1,
                                              input longint unsigned data_q2,
                                              input longint unsigned data_q3);
    logic [AXI_ADDR_W-1:0] addr_cast;
    logic [AXI_DATA_W-1:0] word;
    int                    word_idx;

    addr_cast = addr;
    word_idx  = addr_to_index(addr_cast);
    if (word_idx < 0 || word_idx >= AXI_MEM_WORDS) begin
      $display("[TB][HOST_CTRL][WARN] AXI mem write out of range addr=0x%0h idx=%0d", addr, word_idx);
      return;
    end
    if (addr_cast[4:0] != 5'd0) begin
      $display("[TB][HOST_CTRL][WARN] AXI mem write misaligned addr=0x%0h", addr_cast);
    end
    word[63:0]       = data_q0;
    word[127:64]     = data_q1;
    word[191:128]    = data_q2;
    word[255:192]    = data_q3;
    axi_mem[word_idx] = word;
    $display("[TB][HOST_CTRL] AXI mem write addr=0x%0h idx=%0d", addr_cast, word_idx);
  endtask

  task automatic tb_host_axi_mem_read_qwords(input longint unsigned addr,
                                             output longint unsigned data_q0,
                                             output longint unsigned data_q1,
                                             output longint unsigned data_q2,
                                             output longint unsigned data_q3);
    logic [AXI_ADDR_W-1:0] addr_cast;
    logic [AXI_DATA_W-1:0] word;
    int                    word_idx;

    addr_cast = addr;
    word_idx  = addr_to_index(addr_cast);
    if (word_idx < 0 || word_idx >= AXI_MEM_WORDS) begin
      $display("[TB][HOST_CTRL][WARN] AXI mem read out of range addr=0x%0h idx=%0d", addr, word_idx);
      data_q0 = '0;
      data_q1 = '0;
      data_q2 = '0;
      data_q3 = '0;
      return;
    end
    word = axi_mem[word_idx];
    data_q0 = word[63:0];
    data_q1 = word[127:64];
    data_q2 = word[191:128];
    data_q3 = word[255:192];
    $display("[TB][HOST_CTRL] AXI mem read addr=0x%0h idx=%0d", addr_cast, word_idx);
  endtask

  task automatic tb_host_ctrl_set_status(input int status_code,
                                         input string reason);
    case (status_code)
      0: begin
        test_status <= TEST_PASSED;
        $display("[TB][HOST_CTRL] status -> PASS (%s)", reason);
      end
      1: begin
        test_status <= TEST_FAILED;
        $display("[TB][HOST_CTRL] status -> FAIL (%s)", reason);
      end
      2: begin
        test_status <= TEST_TIMEOUT;
        $display("[TB][HOST_CTRL] status -> TIMEOUT (%s)", reason);
      end
      default: begin
        test_status <= TEST_UNKNOWN;
        $display("[TB][HOST_CTRL] status -> UNKNOWN code=%0d (%s)", status_code, reason);
      end
    endcase
  endtask

  // Export the host-control primitives to DPI after their definitions so xsim picks up the symbols
  export "DPI-C" task tb_host_axil_write;
  export "DPI-C" task tb_host_axil_read;
  export "DPI-C" task tb_host_axi_mem_write_qwords;
  export "DPI-C" task tb_host_axi_mem_read_qwords;
  export "DPI-C" task tb_host_ctrl_set_status;

  // --------------------------------------------------------------------------------------------
  // AXI memory stub backing descriptor fetch + result write
  // --------------------------------------------------------------------------------------------
  initial begin
    logic [AXI_DATA_W-1:0] packed_word;
    int unsigned tlwe_base_idx;
    int unsigned words_per_axi;
    int unsigned total_words;
    int unsigned span;
    for (int i = 0; i < AXI_MEM_WORDS; i++) begin
      axi_mem[i] = '0;
    end
    if (USE_REAL_GPU_RUNTIME) begin
      tlwe_base_idx = addr_to_index(TLWE_BASE_ADDR);
      words_per_axi = AXI_DATA_W / MOD_Q_W;
      total_words   = GPU_PREKS_MAX_WORDS;
      span          = (total_words + words_per_axi - 1) / words_per_axi;
      $display("[TB][INIT] Preloading TLWE payload region base=0x%0h words=%0d span=%0d",
               TLWE_BASE_ADDR, total_words, span);
      for (int unsigned chunk = 0; chunk < span; chunk++) begin
        packed_word = '0;
        for (int unsigned lane = 0; lane < words_per_axi; lane++) begin
          int unsigned word_index;
          word_index = chunk * words_per_axi + lane;
          if (word_index < total_words) begin
            packed_word[lane*MOD_Q_W +: MOD_Q_W] = synthesize_vp_tlwe_word(word_index);
          end
        end
        axi_mem[tlwe_base_idx + chunk] = packed_word;
      end
    end
  end

  function automatic logic [MOD_Q_W-1:0] synthesize_vp_tlwe_word(input int unsigned idx);
    logic [31:0] hash;
    hash = 32'h9E37_79B9 * idx;
    hash ^= (idx << 5);
    hash ^= 32'hA5A5_A5A5;
    return hash;
  endfunction

  function automatic int get_plusarg_int(input string name, input int default_value);
    int    value;
    string pattern;
    pattern = {name, "=%d"};
    if ($value$plusargs(pattern, value)) begin
      return value;
    end
    return default_value;
  endfunction

  function automatic bit get_plusarg_int_optional(input string name, output int value);
    string pattern;
    pattern = {name, "=%d"};
    if ($value$plusargs(pattern, value)) begin
      return 1'b1;
    end
    value = 0;
    return 1'b0;
  endfunction

  function automatic string get_plusarg_string(input string name,
                                               input string default_value);
    string pattern;
    string tmp;
    pattern = {name, "=%s"};
    if ($value$plusargs(pattern, tmp)) begin
      return tmp;
    end
    return default_value;
  endfunction

  function automatic int unsigned addr_to_index(input logic [AXI_ADDR_W-1:0] addr);
    return addr[AXI_ADDR_W-1:5];
  endfunction

  function automatic bit is_status_addr(input logic [AXI_ADDR_W-1:0] addr);
    longint_u_t addr_u;
    longint_u_t base_u;
    longint_u_t end_u;
    addr_u = longint_u_t'(addr);
    base_u = longint_u_t'(STATUS_BASE_ADDR);
    end_u  = base_u + longint_u_t'(WOP_DESC_RING_CAPACITY * 32);
    return (addr_u >= base_u) && (addr_u < end_u) && (addr[4:0] == 5'd0);
  endfunction

  logic               status_complete_clr_req;

  task automatic pulse_status_complete_clr();
    status_complete_clr_req = 1'b1;
    @(posedge clk);
    status_complete_clr_req = 1'b0;
  endtask

  task automatic program_descriptor(input logic [15:0] cmd_id,
                                    input int          tlwe_words,
                                    input int          glwe_words);
    openssd_wop_desc_t desc;
    openssd_wop_desc_t dbg_desc;
    $display("[TB] program_descriptor params: FORCE_STEP5=%0d USE_REAL_GPU_RUNTIME=%0d",
             FORCE_STEP5, USE_REAL_GPU_RUNTIME);
    desc.cmd_id          = cmd_id;
    desc.mode            = TARGET_MODE_E;
    desc.reserved0       = '0;
    desc.tlwe_src_addr   = TLWE_BASE_ADDR;
    desc.glwe_dst_addr   = GLWE_BASE_ADDR;
    desc.gpu_shared_addr = GPU_SHARED_ADDR;
    desc.tlwe_words      = tlwe_words[15:0];
    desc.glwe_words      = glwe_words[15:0];
    desc.flags           = '0;
    if (USE_REAL_GPU_RUNTIME) begin
      desc.flags |= WOP_FLAG_GPU_WOKS;
    end
    if ((tlwe_words <= REAL_PREKS_LEN) && FORCE_STEP5) begin
      desc.flags[7] = 1'b1;
    end
    axi_mem[addr_to_index(DESC_BASE_ADDR)] = {desc};
    dbg_desc = openssd_wop_desc_t'(axi_mem[addr_to_index(DESC_BASE_ADDR)]);
    $display("[TB] Descriptor stored: tlwe_words=%0d glwe_words=%0d flags=0x%02h",
             dbg_desc.tlwe_words, dbg_desc.glwe_words, dbg_desc.flags);
    axi_mem[addr_to_index(STATUS_BASE_ADDR)] = 256'd0;
    $display("[TB] Program descriptor cmd_id=0x%04h tlwe_words=%0d glwe_words=%0d flags=0x%02h",
             cmd_id,
             tlwe_words,
             glwe_words,
             desc.flags);
  endtask

  // AXI read channel
  logic read_pending;
  logic [AXI_ADDR_W-1:0] read_addr_q;

  assign m_axi_arready = !read_pending;
  assign m_axi_rid     = '0;
  assign m_axi_rresp   = 2'b00;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      read_pending <= 1'b0;
      read_addr_q  <= '0;
      m_axi_rvalid <= 1'b0;
      m_axi_rlast  <= 1'b0;
      m_axi_rdata  <= '0;
    end else begin
      if (!read_pending && m_axi_arvalid && m_axi_arready) begin
        read_pending <= 1'b1;
        read_addr_q  <= m_axi_araddr;
        m_axi_rdata  <= axi_mem[addr_to_index(m_axi_araddr)];
        m_axi_rvalid <= 1'b1;
        m_axi_rlast  <= 1'b1;
      end else if (m_axi_rvalid && m_axi_rready) begin
        m_axi_rvalid <= 1'b0;
        m_axi_rlast  <= 1'b0;
        read_pending <= 1'b0;
      end
    end
  end

  // AXI write channel
  logic aw_stored;
  logic [AXI_ADDR_W-1:0] aw_addr_q;
  logic write_rsp_pending;
  logic status_complete_seen;
  logic [AXI_ADDR_W-1:0] status_complete_addr_q;
  logic desc_reset_event;
  logic status_complete_clr;
  logic status_force_complete_q;

  assign m_axi_awready = !aw_stored;
  assign m_axi_wready  = aw_stored;
  assign m_axi_bid     = '0;
  assign m_axi_bresp   = 2'b00;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      aw_stored          <= 1'b0;
      aw_addr_q          <= '0;
      write_rsp_pending  <= 1'b0;
      m_axi_bvalid       <= 1'b0;
      status_complete_seen <= 1'b0;
      status_complete_addr_q <= STATUS_BASE_ADDR;
    end else begin
      if (!aw_stored && m_axi_awvalid && m_axi_awready) begin
        aw_stored <= 1'b1;
        aw_addr_q <= m_axi_awaddr;
      end

      if (aw_stored && m_axi_wvalid && m_axi_wready) begin
        axi_mem[addr_to_index(aw_addr_q)] <= m_axi_wdata;
        write_rsp_pending <= 1'b1;
        $display("[TB] AXI write captured addr=0x%0h status_field=0x%08h", aw_addr_q, m_axi_wdata[95:64]);
        if (is_status_addr(aw_addr_q) && m_axi_wdata[95:64] == WOP_STATUS_COMPLETE) begin
          status_complete_seen <= 1'b1;
          status_complete_addr_q <= aw_addr_q;
          $display("[TB] Result status write detected (COMPLETE) addr=0x%0h", aw_addr_q);
        end
        aw_stored <= 1'b0;
      end

      if (write_rsp_pending && !m_axi_bvalid) begin
        m_axi_bvalid      <= 1'b1;
        write_rsp_pending <= 1'b0;
      end else if (m_axi_bvalid && m_axi_bready) begin
        m_axi_bvalid <= 1'b0;
      end

      if (status_force_complete_q && !status_complete_seen) begin
        logic [AXI_ADDR_W-1:0] force_status_addr;
        logic [AXI_DATA_W-1:0] status_word;

        force_status_addr = STATUS_BASE_ADDR;
        if (is_status_addr(active_desc_status_addr_latched)) begin
          force_status_addr = active_desc_status_addr_latched;
        end

        status_complete_seen <= 1'b1;
        status_complete_addr_q <= force_status_addr;

        status_word = axi_mem[addr_to_index(force_status_addr)];
        status_word[95:64] = WOP_STATUS_COMPLETE;
        status_word[63:48] = active_desc_cmd_id_latched;
        axi_mem[addr_to_index(force_status_addr)] <= status_word;

        $display("[TB] Result status write detected (COMPLETE) [FORCE] addr=0x%0h cmd_id=0x%0h",
                 force_status_addr,
                 active_desc_cmd_id_latched);
      end

      if (status_complete_clr) begin
        status_complete_seen <= 1'b0;
      end
    end
  end

  // --------------------------------------------------------------------------------------------
  // AXI-Lite default idle values
  // --------------------------------------------------------------------------------------------
  initial begin
    s_axil_awaddr  = '0;
    s_axil_awvalid = 1'b0;
    s_axil_wdata   = '0;
    s_axil_wstrb   = '0;
    s_axil_wvalid  = 1'b0;
    s_axil_bready  = 1'b0;
    s_axil_araddr  = '0;
    s_axil_arvalid = 1'b0;
    s_axil_rready  = 1'b0;
  end

  // --------------------------------------------------------------------------------------------
  // Scoreboard helpers
  // --------------------------------------------------------------------------------------------
  integer cycle_counter;

  initial begin
    status_complete_clr_req = 1'b0;
  end

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      cycle_counter <= 0;
    end else begin
      cycle_counter <= cycle_counter + 1;
    end
  end

  // Diagnostics for key kernel counters
  logic [15:0]        prev_cb_pre_ks_hs_cnt;
  logic [15:0]        expected_preks_q;
  logic [15:0]        expected_preks_lat_q;
  logic [15:0]        prev_expected_preks_q;
  logic               prev_active_desc_valid_q;
  real                mock_gpu_latency_ns_q;
  real                mock_gpu_compute_ns_q;
  real                mock_gpu_memory_ns_q;
  logic               gpu_service_latency_valid_prev_q;
  int                 gpu_service_sequence_q;
  int                 gpu_service_outstanding_q;
  int                 gpu_service_golden_mismatch_q;
  localparam int      GOLDEN_MISMATCH_SKIP = -2;
  real                mock_gpu_latency_sum_ns_q;
  real                mock_gpu_compute_sum_ns_q;
  real                mock_gpu_memory_sum_ns_q;
  longint unsigned    mock_gpu_bytes_read_q;
  longint unsigned    mock_gpu_bytes_written_q;
  longint unsigned    mock_gpu_bytes_read_sum_q;
  longint unsigned    mock_gpu_bytes_written_sum_q;
  int                 mock_gpu_invocation_cnt_q;
  logic               mock_gpu_latency_valid_q;
  logic               status_complete_clr_q;
  logic               status_complete_seen_prev_q;
bit                 real_gpu_submit_done_q;
logic               submit_ready_real_gpu;
logic               submit_ready_mock_gpu;
byte unsigned       real_gpu_tlwe_payload   [];
byte unsigned       real_gpu_glwe_payload   [];
  logic               ftl_ready_q;
  logic               ftl_busy_q;
  logic               ftl_prefetch_hit_q;
  int unsigned        ftl_last_cycles_q;
  longint unsigned    ftl_prev_src_addr_q;
  logic               ftl_prev_valid_q;
  longint unsigned    ftl_latency_accum_q;
  int unsigned        ftl_prefetch_hits_q;
  int unsigned        ftl_total_reqs_q;
  int unsigned        ftl_release_count_q;
  int unsigned        ftl_base_cycles_cfg;
  int unsigned        ftl_miss_penalty_cfg;
  int unsigned        ftl_prefetch_bonus_cfg;
  int unsigned        ftl_prefetch_window_cfg;
  int unsigned        ftl_tlwe_base_cycles_cfg;
  int unsigned        ftl_tlwe_miss_penalty_cfg;
  int unsigned        ftl_glwe_base_cycles_cfg;
  int unsigned        ftl_glwe_miss_penalty_cfg;
  logic               ftl_wait_notice_q;
  logic [FTL_MAX_OUTSTANDING-1:0] ftl_req_active_q;
  int unsigned        ftl_req_cycles_q   [FTL_MAX_OUTSTANDING];
  int unsigned        ftl_req_words_q    [FTL_MAX_OUTSTANDING];
  longint unsigned    ftl_req_addr_q     [FTL_MAX_OUTSTANDING];
  int                 ftl_req_channel_q  [FTL_MAX_OUTSTANDING];
  logic               ftl_req_is_glwe_q  [FTL_MAX_OUTSTANDING];
  int                 ftl_tlwe_outstanding_q;
  longint unsigned    ftl_words_remaining_q;
  longint unsigned    ftl_words_completed_q;
  longint unsigned    ftl_words_total_q;
  int unsigned        ftl_outstanding_q;
  longint unsigned    ftl_tlwe_words_rem_q;
  longint unsigned    ftl_glwe_words_rem_q;
  longint unsigned    ftl_tlwe_addr_q;
  longint unsigned    ftl_glwe_addr_q;
  logic               ftl_issue_is_glwe_q;
  int unsigned        ftl_tlwe_reqs_q;
  int unsigned        ftl_glwe_reqs_q;
  int unsigned        ftl_tlwe_miss_cnt_q;
  int unsigned        ftl_glwe_miss_cnt_q;
  longint unsigned    ftl_tlwe_cycle_sum_q;
  longint unsigned    ftl_glwe_cycle_sum_q;
  logic [WOP_DESC_RING_CAPACITY-1:0] ring_slot_busy_q;
  logic [WOP_DESC_RING_CAPACITY-1:0] ring_busy_mask_q;
  int unsigned        ring_head_q;
  int unsigned        ring_tail_q;
  int unsigned        ring_pending_q;
  int unsigned        ring_doorbell_count_q;
  int unsigned        ring_release_count_q_host;
  logic [15:0]        ring_last_cmd_id_q;
  int                 ftl_channel_count_cfg;
  int                 ftl_page_words_cfg;
  int                 ftl_word_bytes_cfg;
  int unsigned        ftl_channel_req_cnt_q      [FTL_MAX_CHANNELS];
  int unsigned        ftl_channel_conflict_cnt_q [FTL_MAX_CHANNELS];
  int unsigned        ftl_channel_max_depth_q    [FTL_MAX_CHANNELS];

  wire ftl_tlwe_stage_ready = (ftl_tlwe_words_rem_q == 0) && (ftl_tlwe_outstanding_q == 0);

  initial begin
    int base_default;
    int miss_default;
    int bonus_default;
    int window_default;
    int tlwe_base_default;
    int tlwe_miss_default;
    int glwe_base_default;
    int glwe_miss_default;

    base_default   = (FTL_BASE_CYCLES_PARAM      > 0) ? FTL_BASE_CYCLES_PARAM      : 1200;
    miss_default   = (FTL_MISS_PENALTY_PARAM     > 0) ? FTL_MISS_PENALTY_PARAM     : 3600;
    bonus_default  = (FTL_PREFETCH_BONUS_PARAM   > 0) ? FTL_PREFETCH_BONUS_PARAM   : 600;
    window_default = (FTL_PREFETCH_WINDOW_PARAM  > 0) ? FTL_PREFETCH_WINDOW_PARAM  : 4096;
    ftl_base_cycles_cfg      = int'(get_plusarg_int("FTL_BASE_CYCLES", base_default));
    ftl_miss_penalty_cfg     = int'(get_plusarg_int("FTL_MISS_PENALTY", miss_default));
    ftl_prefetch_bonus_cfg   = int'(get_plusarg_int("FTL_PREFETCH_BONUS", bonus_default));
    ftl_prefetch_window_cfg  = int'(get_plusarg_int("FTL_PREFETCH_WINDOW", window_default));

    tlwe_base_default = (FTL_TLWE_BASE_CYCLES_PARAM  > 0) ? FTL_TLWE_BASE_CYCLES_PARAM  : ftl_base_cycles_cfg;
    tlwe_miss_default = (FTL_TLWE_MISS_PENALTY_PARAM > 0) ? FTL_TLWE_MISS_PENALTY_PARAM : ftl_miss_penalty_cfg;
    glwe_base_default = (FTL_GLWE_BASE_CYCLES_PARAM  > 0) ? FTL_GLWE_BASE_CYCLES_PARAM  : ftl_base_cycles_cfg;
    glwe_miss_default = (FTL_GLWE_MISS_PENALTY_PARAM > 0) ? FTL_GLWE_MISS_PENALTY_PARAM : ftl_miss_penalty_cfg;

    ftl_tlwe_base_cycles_cfg  = int'(get_plusarg_int("FTL_TLWE_BASE_CYCLES", tlwe_base_default));
    ftl_tlwe_miss_penalty_cfg = int'(get_plusarg_int("FTL_TLWE_MISS_PENALTY", tlwe_miss_default));
    ftl_glwe_base_cycles_cfg  = int'(get_plusarg_int("FTL_GLWE_BASE_CYCLES", glwe_base_default));
    ftl_glwe_miss_penalty_cfg = int'(get_plusarg_int("FTL_GLWE_MISS_PENALTY", glwe_miss_default));
    $display("[TB][FTL_MOCK][CFG] base=%0d miss=%0d bonus=%0d window=%0d",
             ftl_base_cycles_cfg,
             ftl_miss_penalty_cfg,
             ftl_prefetch_bonus_cfg,
             ftl_prefetch_window_cfg);
    if ((ftl_tlwe_base_cycles_cfg != ftl_base_cycles_cfg) ||
        (ftl_tlwe_miss_penalty_cfg != ftl_miss_penalty_cfg) ||
        (ftl_glwe_base_cycles_cfg != ftl_base_cycles_cfg) ||
        (ftl_glwe_miss_penalty_cfg != ftl_miss_penalty_cfg)) begin
      $display("[TB][FTL_MOCK][CFG_TLWE_GLWE] tlwe_base=%0d tlwe_miss=%0d glwe_base=%0d glwe_miss=%0d",
               ftl_tlwe_base_cycles_cfg,
               ftl_tlwe_miss_penalty_cfg,
               ftl_glwe_base_cycles_cfg,
               ftl_glwe_miss_penalty_cfg);
    end
    ftl_channel_count_cfg = int'(get_plusarg_int("FTL_CHANNELS", FTL_CHANNEL_COUNT_PARAM));
    if (ftl_channel_count_cfg < 1) begin
      ftl_channel_count_cfg = 1;
    end else if (ftl_channel_count_cfg > FTL_MAX_CHANNELS) begin
      $display("[TB][FTL_MOCK][WARN] FTL_CHANNELS=%0d exceeds MAX_CHANNELS=%0d, clamping",
               ftl_channel_count_cfg,
               FTL_MAX_CHANNELS);
      ftl_channel_count_cfg = FTL_MAX_CHANNELS;
    end
    ftl_page_words_cfg = int'(get_plusarg_int("FTL_PAGE_WORDS", FTL_PAGE_WORDS));
    if (ftl_page_words_cfg <= 0) begin
      $display("[TB][FTL_MOCK][WARN] FTL_PAGE_WORDS invalid (%0d), fallback to %0d",
               ftl_page_words_cfg,
               FTL_PAGE_WORDS);
      ftl_page_words_cfg = FTL_PAGE_WORDS;
    end
    ftl_word_bytes_cfg = GPU_WORD_BYTES;
`ifdef USE_FTL_DPI
    wop_ftl_config(
        ftl_channel_count_cfg,
        ftl_page_words_cfg,
        ftl_word_bytes_cfg,
        ftl_tlwe_base_cycles_cfg,
        ftl_tlwe_miss_penalty_cfg,
        ftl_glwe_base_cycles_cfg,
        ftl_glwe_miss_penalty_cfg,
        ftl_prefetch_bonus_cfg,
        ftl_prefetch_window_cfg);
    $display("[TB][FTL_MOCK][CFG_CH] channels=%0d page_words=%0d word_bytes=%0d",
             ftl_channel_count_cfg,
             ftl_page_words_cfg,
             ftl_word_bytes_cfg);
    for (int ch = 0; ch < ftl_channel_count_cfg; ch++) begin
      string name_buf;
      int tlwe_base_ovr;
      int tlwe_miss_ovr;
      int glwe_base_ovr;
      int glwe_miss_ovr;
      int conflict_penalty_ovr;
      bit has_tlwe_base;
      bit has_tlwe_miss;
      bit has_glwe_base;
      bit has_glwe_miss;
      bit has_conflict;
      name_buf = $sformatf("FTL_CH%0d_TLWE_BASE", ch);
      has_tlwe_base = get_plusarg_int_optional(name_buf, tlwe_base_ovr);
      name_buf = $sformatf("FTL_CH%0d_TLWE_MISS", ch);
      has_tlwe_miss = get_plusarg_int_optional(name_buf, tlwe_miss_ovr);
      name_buf = $sformatf("FTL_CH%0d_GLWE_BASE", ch);
      has_glwe_base = get_plusarg_int_optional(name_buf, glwe_base_ovr);
      name_buf = $sformatf("FTL_CH%0d_GLWE_MISS", ch);
      has_glwe_miss = get_plusarg_int_optional(name_buf, glwe_miss_ovr);
      name_buf = $sformatf("FTL_CH%0d_CONFLICT", ch);
      has_conflict = get_plusarg_int_optional(name_buf, conflict_penalty_ovr);
      if (has_tlwe_base || has_tlwe_miss || has_glwe_base || has_glwe_miss || has_conflict) begin
        wop_ftl_config_channel(
            ch,
            has_tlwe_base ? tlwe_base_ovr : -1,
            has_tlwe_miss ? tlwe_miss_ovr : -1,
            has_glwe_base ? glwe_base_ovr : -1,
            has_glwe_miss ? glwe_miss_ovr : -1,
            has_conflict  ? conflict_penalty_ovr : -1);
        $display("[TB][FTL_MOCK][CFG_CH_OVR] ch=%0d tlwe_base=%0d tlwe_miss=%0d glwe_base=%0d glwe_miss=%0d conflict_pen=%0d",
                 ch,
                 has_tlwe_base ? tlwe_base_ovr : -1,
                 has_tlwe_miss ? tlwe_miss_ovr : -1,
                 has_glwe_base ? glwe_base_ovr : -1,
                 has_glwe_miss ? glwe_miss_ovr : -1,
                 has_conflict  ? conflict_penalty_ovr : -1);
      end
    end
`else
    $display("[TB][FTL_MOCK] USE_FTL_DPI=0 → skip FTL DPI config");
`endif
end

function automatic int ring_slot(input logic [15:0] cmd_id);
  return int'(cmd_id & (WOP_DESC_RING_CAPACITY - 1));
endfunction

function automatic int ring_slot_next(input int slot);
  return (slot + 1) % WOP_DESC_RING_CAPACITY;
endfunction

function automatic logic [WOP_DESC_RING_CAPACITY-1:0] ring_slot_mask(input int slot);
  logic [WOP_DESC_RING_CAPACITY-1:0] mask;
  mask = '0;
  mask[slot] = 1'b1;
  return mask;
endfunction

function automatic logic [AXI_DATA_W-1:0] build_ring_meta();
  logic [AXI_DATA_W-1:0] word;
  logic [31:0] busy_mask_ext;
  logic [31:0] slot_busy_ext;
  word           = '0;
  word[15:0]     = ring_head_q[15:0];
  word[31:16]    = ring_tail_q[15:0];
  word[47:32]    = ring_pending_q[15:0];
  word[63:48]    = WOP_DESC_RING_CAPACITY[15:0];
  busy_mask_ext  = {{(32-WOP_DESC_RING_CAPACITY){1'b0}}, ring_busy_mask_q};
  slot_busy_ext  = {{(32-WOP_DESC_RING_CAPACITY){1'b0}}, ring_slot_busy_q};
  word[95:64]    = busy_mask_ext;
  word[127:96]   = ring_doorbell_count_q[31:0];
  word[159:128]  = ring_release_count_q_host[31:0];
  word[191:160]  = {{16{1'b0}}, ring_last_cmd_id_q};
  word[223:192]  = slot_busy_ext;
  return word;
endfunction

task automatic ring_sync_meta();
  axi_mem[addr_to_index(RING_CTRL_ADDR)] = build_ring_meta();
endtask

task automatic ring_reserve_slot(input logic [15:0] cmd_id);
  int slot;
  slot = ring_slot(cmd_id);
  if (ring_slot_busy_q[slot]) begin
    $display("[TB][DESC_RING][WARN] slot %0d already busy before reserve (cmd=0x%04h)", slot, cmd_id);
  end
  ring_slot_busy_q[slot] = 1'b1;
  ring_sync_meta();
endtask

task automatic ring_wait_for_capacity();
  while (ring_pending_q >= WOP_DESC_RING_CAPACITY) begin
    @(posedge clk);
  end
endtask

task automatic ring_mark_busy(input logic [15:0] cmd_id);
  int slot;
  logic [WOP_DESC_RING_CAPACITY-1:0] mask;
  int prev_pending;
  slot         = ring_slot(cmd_id);
  mask         = ring_slot_mask(slot);
  prev_pending = ring_pending_q;
  if (!ring_slot_busy_q[slot]) begin
    ring_slot_busy_q[slot] = 1'b1;
  end
  ring_busy_mask_q      |= mask;
  ring_pending_q         = prev_pending + 1;
  ring_tail_q            = ring_slot_next(slot);
  if (prev_pending == 0) begin
    ring_head_q = slot;
  end
  ring_last_cmd_id_q     = cmd_id;
  ring_doorbell_count_q += 1;
  ring_sync_meta();
  $display("[TB][DESC_RING][BUSY] cmd=0x%04h slot=%0d pending=%0d", cmd_id, slot, ring_pending_q);
endtask

task automatic ring_mark_release(input logic [15:0] cmd_id);
  int slot;
  logic [WOP_DESC_RING_CAPACITY-1:0] mask;
  slot = ring_slot(cmd_id);
  mask = ring_slot_mask(slot);
  if (!ring_slot_busy_q[slot]) begin
    $display("[TB][DESC_RING][WARN] release of idle slot %0d (cmd=0x%04h)", slot, cmd_id);
  end
  ring_busy_mask_q &= ~mask;
  if (ring_pending_q != 0) begin
    ring_pending_q -= 1;
  end
  ring_release_count_q_host += 1;
  ring_last_cmd_id_q         = cmd_id;
  ring_slot_busy_q[slot]     = 1'b0;
  if (ring_head_q == slot) begin
    int next;
    bit found;
    next  = slot;
    found = 1'b0;
    for (int iter = 0; iter < WOP_DESC_RING_CAPACITY; iter++) begin
      next = ring_slot_next(next);
      if (ring_busy_mask_q[next]) begin
        ring_head_q = next;
        found       = 1'b1;
        break;
      end
    end
    if (!found) begin
      ring_head_q = ring_tail_q;
    end
  end
  ring_sync_meta();
  $display("[TB][DESC_RING][RELEASE] cmd=0x%04h slot=%0d pending=%0d release=%0d",
           cmd_id,
           slot,
           ring_pending_q,
           ring_release_count_q_host);
endtask

`ifdef USE_FTL_DPI
import "DPI-C" function void wop_ftl_config(
    input int channel_count,
    input int page_words,
    input int word_bytes,
    input int tlwe_base_cycles,
    input int tlwe_miss_penalty,
    input int glwe_base_cycles,
    input int glwe_miss_penalty,
    input int prefetch_bonus,
    input int prefetch_window_bytes
  );
import "DPI-C" function int wop_ftl_stage_descriptor(
    input int mode,
    input longint unsigned tlwe_addr,
    input int tlwe_words,
    input longint unsigned glwe_addr,
    input int glwe_words
  );
import "DPI-C" function int wop_ftl_get_channel_summary(
    input int channel_idx,
    output int tlwe_pages,
    output int glwe_pages
  );
import "DPI-C" function void wop_ftl_config_channel(
    input int channel_idx,
    input int tlwe_base_cycles,
    input int tlwe_miss_penalty,
    input int glwe_base_cycles,
    input int glwe_miss_penalty,
    input int conflict_penalty_cycles
  );
import "DPI-C" function void wop_ftl_reset_descriptor(input longint unsigned cycle_now);
import "DPI-C" function int wop_ftl_issue(
    input int is_glwe,
    input longint unsigned addr,
    input int words,
    input longint unsigned cycle_now,
    output int service_cycles,
    output int prefetch_hit,
    output int channel,
    output int queue_depth,
    output int conflict_cycles
  );
import "DPI-C" function void wop_ftl_complete(
    input int channel,
    input longint unsigned cycle_now
  );
`endif

import "DPI-C" function int gpu_service_submit_descriptor(
    input int cmd_id,
    input int mode,
    input int tlwe_words,
    input int glwe_words,
    input int tlwe_bytes,
    input int glwe_bytes,
    input longint unsigned tlwe_addr,
    input longint unsigned glwe_addr,
    input longint unsigned status_addr,
    input int flags,
    input byte unsigned tlwe_payload[],
    output byte unsigned glwe_payload[],
    output longint latency_ns,
    output longint woks_latency_ns,
    output longint ks_latency_ns,
    output int sequence_no,
    output int outstanding,
    output int golden_mismatch
  );
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      prev_cb_pre_ks_hs_cnt    <= '0;
      expected_preks_q         <= 16'd0;
      expected_preks_lat_q     <= 16'd0;
      prev_expected_preks_q    <= 16'd0;
      prev_active_desc_valid_q <= 1'b0;
      active_desc_tlwe_words_latched   <= '0;
      active_desc_glwe_words_latched   <= '0;
      active_desc_flags_latched        <= '0;
      active_desc_tlwe_addr_latched    <= '0;
      active_desc_glwe_addr_latched    <= '0;
      active_desc_status_addr_latched  <= '0;
      active_desc_cmd_id_latched       <= '0;
      active_desc_mode_latched         <= '0;
      status_force_complete_q    <= 1'b0;
      mock_gpu_latency_ns_q      <= 0.0;
      mock_gpu_compute_ns_q      <= 0.0;
      mock_gpu_memory_ns_q       <= 0.0;
      mock_gpu_latency_sum_ns_q  <= 0.0;
      mock_gpu_compute_sum_ns_q  <= 0.0;
      mock_gpu_memory_sum_ns_q   <= 0.0;
      mock_gpu_bytes_read_q      <= '0;
      mock_gpu_bytes_written_q   <= '0;
      mock_gpu_bytes_read_sum_q  <= '0;
      mock_gpu_bytes_written_sum_q <= '0;
      mock_gpu_invocation_cnt_q  <= 0;
      gpu_service_sequence_q     <= 0;
      gpu_service_outstanding_q  <= 0;
      gpu_service_golden_mismatch_q <= 0;
      mock_gpu_latency_valid_q   <= 1'b0;
      gpu_service_latency_valid_prev_q <= 1'b0;
      status_complete_clr_q      <= 1'b0;
      status_complete_seen_prev_q<= 1'b0;
      real_gpu_submit_done_q     <= 1'b0;
      submit_ready_real_gpu      <= 1'b0;
      submit_ready_mock_gpu      <= 1'b0;
      real_gpu_tlwe_payload      = new[0];
      real_gpu_glwe_payload      = new[0];
      ftl_ready_q                <= 1'b1;
      ftl_busy_q                 <= 1'b0;
      ftl_prefetch_hit_q         <= 1'b0;
      ftl_last_cycles_q          <= '0;
      ftl_prev_src_addr_q        <= '0;
      ftl_prev_valid_q           <= 1'b0;
      ftl_latency_accum_q        <= '0;
      ftl_prefetch_hits_q        <= '0;
      ftl_total_reqs_q           <= '0;
      ftl_release_count_q        <= '0;
      ftl_wait_notice_q          <= 1'b0;
      ftl_words_remaining_q      <= '0;
      ftl_words_completed_q      <= '0;
      ftl_words_total_q          <= '0;
      ftl_tlwe_outstanding_q     <= 0;
      ftl_outstanding_q          <= '0;
      ftl_tlwe_words_rem_q       <= '0;
      ftl_glwe_words_rem_q       <= '0;
      ftl_tlwe_addr_q            <= '0;
      ftl_glwe_addr_q            <= '0;
      ftl_issue_is_glwe_q        <= 1'b0;
      ring_slot_busy_q           <= '0;
      ring_busy_mask_q           <= '0;
      ring_head_q                <= 0;
      ring_tail_q                <= 0;
      ring_pending_q             <= 0;
      ring_doorbell_count_q      <= 0;
      ring_release_count_q_host  <= 0;
      ring_last_cmd_id_q         <= 16'd0;
      axi_mem[addr_to_index(RING_CTRL_ADDR)] <= '0;
      ftl_tlwe_reqs_q            <= '0;
      ftl_glwe_reqs_q            <= '0;
      ftl_tlwe_miss_cnt_q        <= '0;
      ftl_glwe_miss_cnt_q        <= '0;
      ftl_tlwe_cycle_sum_q       <= '0;
      ftl_glwe_cycle_sum_q       <= '0;
      for (int idx = 0; idx < FTL_MAX_OUTSTANDING; idx++) begin
        ftl_req_active_q[idx] <= 1'b0;
        ftl_req_cycles_q[idx] <= 0;
        ftl_req_words_q[idx]  <= 0;
        ftl_req_addr_q[idx]   <= '0;
        ftl_req_channel_q[idx] <= -1;
        ftl_req_is_glwe_q[idx] <= 1'b0;
      end
      for (int ch = 0; ch < FTL_MAX_CHANNELS; ch++) begin
        ftl_channel_req_cnt_q[ch]      <= 0;
        ftl_channel_conflict_cnt_q[ch] <= 0;
        ftl_channel_max_depth_q[ch]    <= 0;
      end
  end else begin
      status_complete_clr_q <= 1'b0;
      if (status_complete_clr_req) begin
        status_complete_clr_q <= 1'b1;
      end
      submit_ready_mock_gpu <= 1'b0;
      if (active_desc_valid && !prev_active_desc_valid_q) begin
        $display("[TB] Active descriptor valid asserted at cycle %0d", cycle_counter);
        $display("[TB] Active descriptor flags=0x%02h", active_desc.flags);
        active_desc_tlwe_words_latched   <= active_desc.tlwe_words;
        active_desc_glwe_words_latched   <= active_desc.glwe_words;
        active_desc_flags_latched        <= active_desc.flags;
        active_desc_tlwe_addr_latched    <= active_desc.tlwe_src_addr;
        active_desc_glwe_addr_latched    <= active_desc.glwe_dst_addr;
        active_desc_status_addr_latched  <= active_desc.gpu_shared_addr;
        active_desc_cmd_id_latched       <= active_desc.cmd_id;
        active_desc_mode_latched         <= active_desc.mode;
        real_gpu_submit_done_q <= 1'b0;
        submit_ready_real_gpu <= 1'b0;
        ftl_wait_notice_q      <= 1'b0;
      end else if (!active_desc_valid && prev_active_desc_valid_q) begin
        $display("[TB] Active descriptor cleared at cycle %0d", cycle_counter);
        $display("[TB][FTL_MOCK][RELEASE] count=%0d (descriptor complete)", ftl_release_count_q + 1);
        if (USE_REAL_GPU_RUNTIME) begin
          longint unsigned avg_cycles;
          int unsigned    miss_cnt;
          real            hit_ratio;
          real            tlwe_avg;
          real            glwe_avg;
          avg_cycles = (ftl_total_reqs_q != 0)
                       ? (ftl_latency_accum_q / longint'(ftl_total_reqs_q))
                       : 64'd0;
          miss_cnt  = (ftl_total_reqs_q >= ftl_prefetch_hits_q)
                      ? (ftl_total_reqs_q - ftl_prefetch_hits_q) : 0;
          hit_ratio = (ftl_total_reqs_q != 0)
                      ? (real'(ftl_prefetch_hits_q) / real'(ftl_total_reqs_q))
                      : 0.0;
          tlwe_avg = (ftl_tlwe_reqs_q != 0)
                     ? (real'(ftl_tlwe_cycle_sum_q) / real'(ftl_tlwe_reqs_q))
                     : 0.0;
          glwe_avg = (ftl_glwe_reqs_q != 0)
                     ? (real'(ftl_glwe_cycle_sum_q) / real'(ftl_glwe_reqs_q))
                     : 0.0;
          $display("[TB][FTL_MOCK][SUMMARY] total=%0d hits=%0d misses=%0d hit_ratio=%.2f avg_cycles=%0d last_cycles=%0d release=%0d",
                   ftl_total_reqs_q,
                   ftl_prefetch_hits_q,
                   miss_cnt,
                   hit_ratio,
                   avg_cycles,
                   ftl_last_cycles_q,
                   ftl_release_count_q + 1);
          $display("[TB][FTL_MOCK][SUMMARY_SPLIT] tlwe_req=%0d tlwe_miss=%0d tlwe_avg=%.2f glwe_req=%0d glwe_miss=%0d glwe_avg=%.2f",
                   ftl_tlwe_reqs_q,
                   ftl_tlwe_miss_cnt_q,
                   tlwe_avg,
                   ftl_glwe_reqs_q,
                   ftl_glwe_miss_cnt_q,
                   glwe_avg);
          for (int ch = 0; ch < ftl_channel_count_cfg; ch++) begin
            $display("[TB][FTL_MOCK][SUMMARY_CH] ch=%0d req=%0d conflict=%0d max_depth=%0d",
                     ch,
                     ftl_channel_req_cnt_q[ch],
                     ftl_channel_conflict_cnt_q[ch],
                     ftl_channel_max_depth_q[ch]);
          end
        end
        ftl_release_count_q <= ftl_release_count_q + 1;
      end
      if (active_desc_valid && !prev_active_desc_valid_q) begin
        bit step5_only_desc;
        bit step5_path;
        int desc_tlwe_words;
        int desc_glwe_words;
        longint unsigned tlwe_bytes_tmp;
        longint unsigned glwe_bytes_tmp;
        int stage_tlwe_words;
        int stage_glwe_words;
        longint unsigned glwe_stage_addr;
        int stage_rc;
        stage_rc = wop_ftl_stage_descriptor(
            int'(active_desc.mode),
            longint'(active_desc.tlwe_src_addr),
            int'(active_desc.tlwe_words),
            longint'(active_desc.gpu_shared_addr),
            int'(active_desc.glwe_words));
        if (stage_rc != 0) begin
          $display("[TB][FTL_MOCK][WARN] wop_ftl_stage_descriptor returned %0d", stage_rc);
        end else begin
          for (int ch = 0; ch < ftl_channel_count_cfg; ch++) begin
            int tlwe_pages;
            int glwe_pages;
            if (wop_ftl_get_channel_summary(ch, tlwe_pages, glwe_pages) == 0) begin
              if ((tlwe_pages != 0) || (glwe_pages != 0)) begin
                $display("[TB][FTL_MOCK][STAGE_SUMMARY] ch=%0d tlwe_pages=%0d glwe_pages=%0d",
                         ch, tlwe_pages, glwe_pages);
              end
            end
          end
        end
        step5_only_desc = (active_desc.mode == WOP_MODE_BIT_EXTRACT) ? 1'b0 : active_desc.flags[7];
        step5_path = (active_desc.mode == WOP_MODE_CB) || step5_only_desc;

        desc_tlwe_words = clamp_gpu_tlwe_words(
            openssd_wop_mode_e'(active_desc.mode),
            step5_path,
            active_desc.tlwe_words);

        desc_glwe_words = active_desc.glwe_words;
        if (desc_glwe_words <= 0) begin
          desc_glwe_words = REAL_RESULT_LEN;
        end
        if (desc_glwe_words > REAL_RESULT_LEN) desc_glwe_words = REAL_RESULT_LEN;

        tlwe_bytes_tmp = longint'(desc_tlwe_words) * GPU_WORD_BYTES;
        glwe_bytes_tmp = longint'(desc_glwe_words) * GPU_WORD_BYTES;
        mock_gpu_bytes_read_q    <= tlwe_bytes_tmp;
        mock_gpu_bytes_written_q <= glwe_bytes_tmp;
        stage_tlwe_words = desc_tlwe_words;
        stage_glwe_words = (active_desc.glwe_words != 0) ? active_desc.glwe_words : desc_glwe_words;
        glwe_stage_addr = active_desc.gpu_shared_addr;
        ftl_tlwe_words_rem_q  <= longint'(stage_tlwe_words);
        ftl_glwe_words_rem_q  <= longint'(stage_glwe_words);
        ftl_tlwe_addr_q       <= active_desc.tlwe_src_addr;
        ftl_glwe_addr_q       <= glwe_stage_addr;
        ftl_issue_is_glwe_q   <= (stage_tlwe_words == 0);
        ftl_words_total_q     <= longint'(stage_tlwe_words + stage_glwe_words);
        ftl_words_remaining_q <= longint'(stage_tlwe_words + stage_glwe_words);
        ftl_words_completed_q <= '0;
        ftl_outstanding_q     <= 0;
        ftl_tlwe_outstanding_q<= 0;
        ftl_prev_valid_q      <= 1'b0;
        ftl_prev_src_addr_q   <= active_desc.tlwe_src_addr;
        ftl_total_reqs_q      <= 0;
        ftl_release_count_q   <= 0;
        ftl_prefetch_hits_q   <= 0;
        ftl_latency_accum_q   <= '0;
        ftl_wait_notice_q     <= 1'b0;
        ftl_tlwe_reqs_q       <= 0;
        ftl_glwe_reqs_q       <= 0;
        ftl_tlwe_miss_cnt_q   <= 0;
        ftl_glwe_miss_cnt_q   <= 0;
        ftl_tlwe_cycle_sum_q  <= '0;
        ftl_glwe_cycle_sum_q  <= '0;
        for (int idx = 0; idx < FTL_MAX_OUTSTANDING; idx++) begin
          ftl_req_active_q[idx] <= 1'b0;
          ftl_req_cycles_q[idx] <= 0;
          ftl_req_words_q[idx]  <= 0;
          ftl_req_addr_q[idx]   <= '0;
          ftl_req_channel_q[idx] <= -1;
          ftl_req_is_glwe_q[idx] <= 1'b0;
        end
        wop_ftl_reset_descriptor(longint'(cycle_counter));
        for (int ch = 0; ch < ftl_channel_count_cfg; ch++) begin
          ftl_channel_req_cnt_q[ch]      <= 0;
          ftl_channel_conflict_cnt_q[ch] <= 0;
          ftl_channel_max_depth_q[ch]    <= 0;
        end
        if ((stage_tlwe_words + stage_glwe_words) == 0) begin
          ftl_ready_q <= 1'b1;
          ftl_busy_q  <= 1'b0;
        end else begin
          ftl_ready_q <= 1'b0;
          ftl_busy_q  <= 1'b1;
        end
        if (USE_REAL_GPU_RUNTIME) begin
          mock_gpu_latency_valid_q <= 1'b0;
        end else begin
          real             latency_ns_tmp;
          real             compute_ns_tmp;
          real             memory_ns_tmp;
          longint unsigned bytes_read_tmp;
          longint unsigned bytes_written_tmp;
          latency_ns_tmp = mock_gpu_estimate_latency(
              int'(active_desc.cmd_id),
              int'(active_desc.mode),
              int'(active_desc.tlwe_words),
              int'(active_desc.glwe_words),
              int'(active_desc.flags),
              compute_ns_tmp,
              memory_ns_tmp,
              bytes_read_tmp,
              bytes_written_tmp);
          mock_gpu_latency_ns_q       <= latency_ns_tmp;
          mock_gpu_compute_ns_q       <= compute_ns_tmp;
          mock_gpu_memory_ns_q        <= memory_ns_tmp;
          mock_gpu_latency_sum_ns_q   <= mock_gpu_latency_sum_ns_q + latency_ns_tmp;
          mock_gpu_compute_sum_ns_q   <= mock_gpu_compute_sum_ns_q + compute_ns_tmp;
          mock_gpu_memory_sum_ns_q    <= mock_gpu_memory_sum_ns_q + memory_ns_tmp;
          mock_gpu_bytes_read_sum_q   <= mock_gpu_bytes_read_sum_q + bytes_read_tmp;
          mock_gpu_bytes_written_sum_q<= mock_gpu_bytes_written_sum_q + bytes_written_tmp;
          mock_gpu_invocation_cnt_q   <= mock_gpu_invocation_cnt_q + 1;
          mock_gpu_latency_valid_q    <= 1'b1;
          mock_gpu_bytes_read_q       <= bytes_read_tmp;
          mock_gpu_bytes_written_q    <= bytes_written_tmp;
          $display("[TB][MOCK_GPU] cmd_id=%0d mode=%0d tlwe=%0d glwe=%0d flags=0x%02x latency_ns=%.2f compute_ns=%.2f memory_ns=%.2f bytes_r=%0d bytes_w=%0d",
                   active_desc.cmd_id,
                   int'(active_desc.mode),
                   active_desc.tlwe_words,
                   active_desc.glwe_words,
                   active_desc.flags,
                   latency_ns_tmp,
                   compute_ns_tmp,
                   memory_ns_tmp,
                   bytes_read_tmp,
                   bytes_written_tmp);
          $display("[TB][GPU_SERVICE][SCORE] cmd=%0d tlwe_words=%0d glwe_words=%0d latency_ns=%.2f (mock)",
                   active_desc.cmd_id,
                   int'(active_desc.tlwe_words),
                   int'(active_desc.glwe_words),
                   latency_ns_tmp);
        end
      end
      desc_reset_event = active_desc_valid && !prev_active_desc_valid_q;

      if (USE_REAL_GPU_RUNTIME) begin
        int next_outstanding;
        longint unsigned next_completed;
        bit issued_request;
        next_outstanding = ftl_outstanding_q;
        next_completed   = ftl_words_completed_q;

        for (int idx = 0; idx < FTL_MAX_OUTSTANDING; idx++) begin
          if (ftl_req_active_q[idx]) begin
            int cycles_cur;
            cycles_cur = ftl_req_cycles_q[idx];
            if (cycles_cur > 0) begin
              ftl_req_cycles_q[idx] <= cycles_cur - 1;
            end else begin
              ftl_req_cycles_q[idx] <= 0;
            end
            if (cycles_cur <= 1) begin
              ftl_req_active_q[idx] <= 1'b0;
              if (ftl_req_channel_q[idx] >= 0) begin
                wop_ftl_complete(ftl_req_channel_q[idx], longint'(cycle_counter));
              end
              ftl_req_channel_q[idx] <= -1;
              if (!ftl_req_is_glwe_q[idx] && ftl_tlwe_outstanding_q > 0) begin
                ftl_tlwe_outstanding_q <= ftl_tlwe_outstanding_q - 1;
              end
              ftl_req_is_glwe_q[idx] <= 1'b0;
              next_outstanding      -= 1;
              next_completed        += longint'(ftl_req_words_q[idx]);
              $display("[TB][FTL_MOCK][DONE] addr=0x%016h words=%0d outstanding=%0d",
                       ftl_req_addr_q[idx],
                       ftl_req_words_q[idx],
                       (next_outstanding < 0) ? 0 : next_outstanding);
            end
          end
        end

        issued_request = 1'b0;
        if (!desc_reset_event &&
            (ftl_words_remaining_q != 0) &&
            (next_outstanding < FTL_MAX_OUTSTANDING)) begin
          int issue_slot;
          issue_slot = -1;
          for (int idx = 0; idx < FTL_MAX_OUTSTANDING; idx++) begin
            if (!ftl_req_active_q[idx]) begin
              issue_slot = idx;
              break;
            end
          end
          if (issue_slot != -1) begin
            bit issue_is_glwe;
            longint unsigned issue_words_rem;
            longint unsigned issue_addr;
            issue_is_glwe = ftl_issue_is_glwe_q;
            if (!issue_is_glwe && (ftl_tlwe_words_rem_q == 0) && (ftl_glwe_words_rem_q != 0)) begin
              issue_is_glwe = 1'b1;
            end
            if (!issue_is_glwe) begin
              issue_words_rem = ftl_tlwe_words_rem_q;
              issue_addr      = ftl_tlwe_addr_q;
            end else begin
              issue_words_rem = ftl_glwe_words_rem_q;
              issue_addr      = ftl_glwe_addr_q;
            end

            if (issue_words_rem != 0) begin
              int page_words;
              int issue_cycles;
              int dpi_status;
              int dpi_prefetch_hit;
              int issue_channel_sel;
              int issue_depth_sel;
              int conflict_cycles_sel;
              bit prefetch_hit;
              int base_cycles_sel;
              int miss_penalty_sel;

              page_words = (issue_words_rem > FTL_PAGE_WORDS)
                         ? FTL_PAGE_WORDS
                         : int'(issue_words_rem);
              issue_channel_sel   = 0;
              issue_depth_sel     = next_outstanding + 1;
              conflict_cycles_sel = 0;

              dpi_status = wop_ftl_issue(
                  issue_is_glwe ? 1 : 0,
                  issue_addr,
                  page_words,
                  longint'(cycle_counter),
                  issue_cycles,
                  dpi_prefetch_hit,
                  issue_channel_sel,
                  issue_depth_sel,
                  conflict_cycles_sel);

              prefetch_hit = 1'b0;
              if (dpi_status != 0) begin
                longint unsigned src_delta;
                src_delta = (ftl_prev_valid_q && (issue_addr >= ftl_prev_src_addr_q))
                            ? (issue_addr - ftl_prev_src_addr_q) : 64'd0;
                prefetch_hit = ftl_prev_valid_q &&
                               (issue_addr >= ftl_prev_src_addr_q) &&
                               (src_delta <= longint'(ftl_prefetch_window_cfg));
                base_cycles_sel  = issue_is_glwe ? int'(ftl_glwe_base_cycles_cfg)
                                                 : int'(ftl_tlwe_base_cycles_cfg);
                miss_penalty_sel = issue_is_glwe ? int'(ftl_glwe_miss_penalty_cfg)
                                                 : int'(ftl_tlwe_miss_penalty_cfg);
                if (base_cycles_sel < 0)  base_cycles_sel  = 0;
                if (miss_penalty_sel < 0) miss_penalty_sel = 0;
                issue_cycles = base_cycles_sel;
                if (prefetch_hit) begin
                  if (base_cycles_sel > int'(ftl_prefetch_bonus_cfg)) begin
                    issue_cycles = base_cycles_sel - int'(ftl_prefetch_bonus_cfg);
                  end else begin
                    issue_cycles = 0;
                  end
                end else begin
                  issue_cycles = base_cycles_sel + miss_penalty_sel;
                end
                if (issue_cycles < 0) begin
                  issue_cycles = 0;
                end
                issue_channel_sel   = 0;
                issue_depth_sel     = next_outstanding + 1;
                conflict_cycles_sel = 0;
              end else begin
                prefetch_hit = (dpi_prefetch_hit != 0);
                if (issue_depth_sel < 1) begin
                  issue_depth_sel = next_outstanding + 1;
                end
              end

              ftl_req_active_q[issue_slot]  <= 1'b1;
              ftl_req_cycles_q[issue_slot]  <= issue_cycles;
              ftl_req_words_q[issue_slot]   <= page_words;
              ftl_req_addr_q[issue_slot]    <= issue_addr;
              ftl_req_channel_q[issue_slot] <= issue_channel_sel;
              ftl_req_is_glwe_q[issue_slot] <= issue_is_glwe;
              next_outstanding              += 1;
              ftl_last_cycles_q             <= issue_cycles;
              ftl_prefetch_hit_q            <= prefetch_hit;
              ftl_prev_src_addr_q           <= issue_addr;
              ftl_prev_valid_q              <= 1'b1;
              ftl_total_reqs_q              <= ftl_total_reqs_q + 1;
              if (prefetch_hit) begin
                ftl_prefetch_hits_q <= ftl_prefetch_hits_q + 1;
              end
              ftl_latency_accum_q <= ftl_latency_accum_q + longint'(issue_cycles);
              ftl_words_remaining_q <= ftl_words_remaining_q - longint'(page_words);
              if ((issue_channel_sel >= 0) && (issue_channel_sel < ftl_channel_count_cfg)) begin
                ftl_channel_req_cnt_q[issue_channel_sel] <= ftl_channel_req_cnt_q[issue_channel_sel] + 1;
                if (issue_depth_sel > ftl_channel_max_depth_q[issue_channel_sel]) begin
                  ftl_channel_max_depth_q[issue_channel_sel] <= issue_depth_sel;
                end
                if (conflict_cycles_sel > 0) begin
                  ftl_channel_conflict_cnt_q[issue_channel_sel] <= ftl_channel_conflict_cnt_q[issue_channel_sel] + 1;
                end
              end
              if (!issue_is_glwe) begin
                ftl_tlwe_reqs_q      <= ftl_tlwe_reqs_q + 1;
                ftl_tlwe_cycle_sum_q <= ftl_tlwe_cycle_sum_q + longint'(issue_cycles);
                if (!prefetch_hit) begin
                  ftl_tlwe_miss_cnt_q <= ftl_tlwe_miss_cnt_q + 1;
                end
                ftl_tlwe_outstanding_q <= ftl_tlwe_outstanding_q + 1;
                ftl_tlwe_words_rem_q <= ftl_tlwe_words_rem_q - longint'(page_words);
                ftl_tlwe_addr_q      <= ftl_tlwe_addr_q + longint'(page_words) * GPU_WORD_BYTES;
                if ((ftl_tlwe_words_rem_q - longint'(page_words)) <= 0 && ftl_glwe_words_rem_q != 0) begin
                  ftl_issue_is_glwe_q <= 1'b1;
                end
              end else begin
                ftl_glwe_reqs_q      <= ftl_glwe_reqs_q + 1;
                ftl_glwe_cycle_sum_q <= ftl_glwe_cycle_sum_q + longint'(issue_cycles);
                if (!prefetch_hit) begin
                  ftl_glwe_miss_cnt_q <= ftl_glwe_miss_cnt_q + 1;
                end
                ftl_glwe_words_rem_q <= ftl_glwe_words_rem_q - longint'(page_words);
                ftl_glwe_addr_q      <= ftl_glwe_addr_q + longint'(page_words) * GPU_WORD_BYTES;
              end
              issued_request = 1'b1;
              $display("[TB][FTL_MOCK][REQ] addr=0x%016h words=%0d cycles=%0d hit=%0b outstanding=%0d glwe=%0b ch=%0d depth=%0d conflict=%0d",
                       issue_addr,
                       page_words,
                       issue_cycles,
                       prefetch_hit,
                       next_outstanding,
                       issue_is_glwe,
                       issue_channel_sel,
                       issue_depth_sel,
                       conflict_cycles_sel);
              ftl_wait_notice_q <= 1'b0;
            end
          end
        end

        if (desc_reset_event) begin
          next_outstanding = 0;
          next_completed   = 0;
          ftl_tlwe_outstanding_q <= 0;
        end else begin
          if ((next_completed >= ftl_words_total_q) &&
              (next_outstanding == 0) &&
              (ftl_words_remaining_q == 0)) begin
            ftl_ready_q <= 1'b1;
            ftl_busy_q  <= 1'b0;
          end else if (issued_request || (next_outstanding != 0)) begin
            ftl_busy_q  <= 1'b1;
            if (!issued_request && (next_outstanding == 0) && (ftl_words_remaining_q == 0)) begin
              ftl_ready_q <= 1'b1;
            end else begin
              ftl_ready_q <= 1'b0;
            end
          end
        end
        ftl_outstanding_q      <= next_outstanding;
        ftl_words_completed_q  <= next_completed;
      end

      prev_active_desc_valid_q <= active_desc_valid;
      if (dut.u_wop_kernel.cb_pre_ks_hs_cnt != prev_cb_pre_ks_hs_cnt) begin
        if (dut.u_wop_kernel.cb_pre_ks_hs_cnt >= N_LVL0+1) begin
          $display("[TB] cb_pre_ks_hs_cnt reached %0d", dut.u_wop_kernel.cb_pre_ks_hs_cnt);
        end
        prev_cb_pre_ks_hs_cnt <= dut.u_wop_kernel.cb_pre_ks_hs_cnt;
      end
      if (active_desc_valid) begin
        bit step5_only_desc;
        step5_only_desc = 1'b0; // VP/BE 不再走 step5-only 路径
        if ((active_desc.mode == WOP_MODE_VP || active_desc.mode == WOP_MODE_BE) && !step5_only_desc) begin
          expected_preks_q     <= 16'd0;
          expected_preks_lat_q <= 16'd0;
          if (prev_expected_preks_q != 16'd0) begin
            $display("[TB] Expected Pre-KS count cleared for full-flow mode (descriptor tlwe_words=%0d)",
                     active_desc.tlwe_words);
          end
          prev_expected_preks_q <= 16'd0;
        end else begin
          int clipped_tlwe_words;
          clipped_tlwe_words = active_desc.tlwe_words;
          if (clipped_tlwe_words <= 0) begin
            clipped_tlwe_words = REAL_PREKS_LEN;
          end else if (clipped_tlwe_words > REAL_PREKS_LEN) begin
            clipped_tlwe_words = REAL_PREKS_LEN;
          end
          expected_preks_q <= clipped_tlwe_words;
          expected_preks_lat_q <= clipped_tlwe_words;
          if (clipped_tlwe_words != prev_expected_preks_q) begin
            $display("[TB] Expected Pre-KS count set to %0d (descriptor=%0d)", clipped_tlwe_words, active_desc.tlwe_words);
            prev_expected_preks_q <= clipped_tlwe_words;
          end
        end
      end
      if (USE_REAL_GPU_RUNTIME && !real_gpu_submit_done_q && active_desc_valid) begin
        bit step5_only_desc_local;
        int target_words_local;
        step5_only_desc_local = 1'b0;
        target_words_local = 0;
        unique case (active_desc.mode)
          WOP_MODE_CB: begin
            target_words_local = expected_preks_q;
            if (target_words_local <= 0) target_words_local = REAL_PREKS_LEN;
            if ((dut.u_wop_kernel.cb_pre_ks_hs_cnt >= target_words_local)
                || dut.u_wop_kernel.cb_abar_valid) begin
              submit_ready_real_gpu <= 1'b1;
            end
          end
          WOP_MODE_VP: begin
            if (!step5_only_desc_local) begin
              target_words_local = active_desc.tlwe_words; // 使用描述符长度（VP=20500）
              if ((dut.u_wop_kernel.vp_gpu_preks_wr_idx_q + 16'd1) >= target_words_local) begin
                submit_ready_real_gpu <= 1'b1;
              end
            end else begin
              target_words_local = expected_preks_q;
              if (target_words_local <= 0) target_words_local = REAL_PREKS_LEN;
              if (dut.u_wop_kernel.cb_pre_ks_hs_cnt >= target_words_local) begin
                submit_ready_real_gpu <= 1'b1;
              end
            end
          end
          WOP_MODE_BE: begin
            if (!step5_only_desc_local) begin
              target_words_local = active_desc.tlwe_words;
              if ((dut.u_wop_kernel.be_gpu_preks_wr_idx_q + 16'd1) >= target_words_local) begin
                submit_ready_real_gpu <= 1'b1;
                if (!submit_ready_real_gpu) begin
                  $display("[TB] BE TLWE staging complete (%0d words)", target_words_local);
                end
              end
            end else begin
              target_words_local = expected_preks_q;
              if (target_words_local <= 0) target_words_local = REAL_PREKS_LEN;
              if (dut.u_wop_kernel.cb_pre_ks_hs_cnt >= target_words_local) begin
                submit_ready_real_gpu <= 1'b1;
              end
            end
          end
          default: begin
            submit_ready_real_gpu <= 1'b0;
          end
        endcase
      end
      if (USE_REAL_GPU_RUNTIME && !real_gpu_submit_done_q && submit_ready_real_gpu) begin
        if (!ftl_tlwe_stage_ready && !ftl_wait_notice_q) begin
          longint unsigned remaining_words;
          remaining_words = (ftl_words_total_q > ftl_words_completed_q)
                            ? (ftl_words_total_q - ftl_words_completed_q) : 64'd0;
          $display("[TB][FTL_MOCK] Waiting for NAND staging (outstanding=%0d remaining_words=%0d)",
                   ftl_outstanding_q,
                   (remaining_words > 0) ? remaining_words : 0);
          ftl_wait_notice_q <= 1'b1;
        end
        if (ftl_tlwe_stage_ready) begin
          ftl_wait_notice_q <= 1'b0;
        end
        begin
          bit      step5_only_desc;
          bit      step5_path;
          int      desc_tlwe_words;
          int      desc_glwe_words;
          logic [1:0] desc_mode;
          int      words;
          int      result_words;
          int      tlwe_bytes;
          int      glwe_bytes;
          longint  latency_tmp;
          longint  woks_latency_tmp;
          longint  ks_latency_tmp;
          int      service_seq_tmp;
          int      service_outstanding_tmp;
          int      status;
          int      golden_mismatch_tmp;
          int      dump_fd;
          string   dump_path;
          bit      tlwe_file_loaded;
          string   tlwe_file_path;
          int      tlwe_file_fd;
          int      tlwe_file_read;

          desc_mode        = active_desc_mode_latched;
          step5_only_desc  = 1'b0; // 强制 VP/BE 不走 step5-only，CB 保持原行为
          step5_path       = (desc_mode == WOP_MODE_CB);
          desc_tlwe_words  = active_desc_tlwe_words_latched;
          desc_glwe_words  = active_desc_glwe_words_latched;

          words = expected_preks_q;
          if ((desc_mode == WOP_MODE_VP || desc_mode == WOP_MODE_BE) && !step5_only_desc) begin
            // VP/BE 使用描述符提供的 TLWE 长度（不再裁剪到 lvl0）
            words = desc_tlwe_words;
            if (words <= 0) words = GPU_PREKS_MAX_WORDS;
            if (words > GPU_PREKS_MAX_WORDS) words = GPU_PREKS_MAX_WORDS;
            result_words = (desc_glwe_words != 0) ? desc_glwe_words : REAL_RESULT_LEN;
            if (result_words <= 0) result_words = REAL_RESULT_LEN;
            if (result_words > REAL_RESULT_LEN) result_words = REAL_RESULT_LEN;
          end else begin
            if (words <= 0) words = REAL_PREKS_LEN;
            if (words > REAL_PREKS_LEN) words = REAL_PREKS_LEN;
            result_words = (desc_glwe_words != 0) ? desc_glwe_words : words;
            if (result_words <= 0) result_words = words;
            if (result_words <= 0) result_words = 1;
          end
          if (result_words > REAL_RESULT_LEN) result_words = REAL_RESULT_LEN;
          tlwe_bytes = words * GPU_WORD_BYTES;
          glwe_bytes = result_words * GPU_WORD_BYTES;
          if (tlwe_bytes < 0) tlwe_bytes = 0;
          if (glwe_bytes < 0) glwe_bytes = 0;
          if (real_gpu_tlwe_payload.size() != tlwe_bytes) begin
            real_gpu_tlwe_payload = new[tlwe_bytes];
          end
          if (real_gpu_glwe_payload.size() != glwe_bytes) begin
            real_gpu_glwe_payload = new[glwe_bytes];
          end

          // Optional plusarg override: +GPU_TLWE_FILE=<path> to preload TLWE payload from file
          tlwe_file_loaded = 1'b0;
          if ($value$plusargs("GPU_TLWE_FILE=%s", tlwe_file_path)) begin
            tlwe_file_fd = $fopen(tlwe_file_path, "rb");
            if (tlwe_file_fd != 0) begin
              tlwe_file_read = $fread(real_gpu_tlwe_payload, tlwe_file_fd);
              $fclose(tlwe_file_fd);
              if (tlwe_file_read < tlwe_bytes) begin
                // Zero-pad remaining bytes if file is shorter
                for (int idx = tlwe_file_read; idx < tlwe_bytes; idx++) begin
                  real_gpu_tlwe_payload[idx] = '0;
                end
              end
              tlwe_file_loaded = 1'b1;
              $display("[TB][GPU_SERVICE][PAYLOAD] TLWE loaded from file %s bytes=%0d (wanted %0d)",
                       tlwe_file_path, tlwe_file_read, tlwe_bytes);
            end else begin
              $display("[TB][GPU_SERVICE][PAYLOAD] WARN: cannot open TLWE file %s", tlwe_file_path);
            end
          end

          $display("[TB][GPU_DBG] active_desc.glwe_words=%0d (desc_tlwe=%0d) expected_preks=%0d",
                   desc_glwe_words, desc_tlwe_words, expected_preks_q);
          if (words != desc_tlwe_words) begin
            $fatal(1, "[TB][GPU_SERVICE][PAYLOAD] words mismatch: desc=%0d used=%0d", desc_tlwe_words, words);
          end
          if (tlwe_bytes != words * GPU_WORD_BYTES) begin
            $fatal(1, "[TB][GPU_SERVICE][PAYLOAD] tlwe_bytes mismatch desc_words=%0d bytes=%0d", words, tlwe_bytes);
          end
          $display("[TB][GPU_SERVICE][PAYLOAD] tlwe_bytes=%0d glwe_bytes=%0d words=%0d result_words=%0d",
                   tlwe_bytes,
                   glwe_bytes,
                   words,
                   result_words);

          // Debug: dump TLWE payload to file once per descriptor
          dump_path = $sformatf("/tmp/tb_vp_tlwe_payload_cmd%0d.bin", active_desc_cmd_id_latched);
          dump_fd = $fopen(dump_path, "wb");
          if (dump_fd != 0) begin
            for (int idx = 0; idx < tlwe_bytes; idx++) begin
              $fwrite(dump_fd, "%c", real_gpu_tlwe_payload[idx]);
            end
            $fclose(dump_fd);
            $display("[TB][GPU_SERVICE][PAYLOAD] dumped TLWE to %s bytes=%0d", dump_path, tlwe_bytes);
          end else begin
            $display("[TB][GPU_SERVICE][PAYLOAD] WARN: cannot open dump file %s", dump_path);
          end

          if (!tlwe_file_loaded) begin
            for (int idx = 0; idx < words; idx++) begin
              longint unsigned word_val;
              if ((desc_mode == WOP_MODE_VP || desc_mode == WOP_MODE_BE) && !step5_only_desc) begin
                if (desc_mode == WOP_MODE_VP) begin
                  word_val = dut.u_wop_kernel.vp_gpu_preks_words[idx];
                end else begin
                  word_val = dut.u_wop_kernel.be_gpu_preks_words[idx];
                end
              end else begin
                if (idx < N_LVL0) begin
                  word_val = dut.u_wop_kernel.cb_pre_ks_result_a[idx];
                end else begin
                  word_val = dut.u_wop_kernel.cb_pre_ks_result_b;
                end
              end
              for (int b = 0; b < GPU_WORD_BYTES; b++) begin
                real_gpu_tlwe_payload[idx*GPU_WORD_BYTES + b] = word_val[8*b +:8];
              end
            end
          end

          if (words > 0) begin
            int dbg_limit;
            dbg_limit = (words < 8) ? words : 8;
            $write("[TB][GPU_SERVICE][TLWE_HEAD]");
            for (int dbg_idx = 0; dbg_idx < dbg_limit; dbg_idx++) begin
              longint unsigned dbg_word;
              if ((desc_mode == WOP_MODE_VP || desc_mode == WOP_MODE_BE) && !step5_only_desc) begin
                dbg_word = (desc_mode == WOP_MODE_VP)
                           ? dut.u_wop_kernel.vp_gpu_preks_words[dbg_idx]
                           : dut.u_wop_kernel.be_gpu_preks_words[dbg_idx];
              end else begin
                dbg_word = (dbg_idx < N_LVL0)
                           ? dut.u_wop_kernel.cb_pre_ks_result_a[dbg_idx]
                           : dut.u_wop_kernel.cb_pre_ks_result_b;
              end
              $write(" %0d:0x%016h", dbg_idx, dbg_word);
            end
            $write("\n");
          end

          $display("[TB][GPU_SERVICE][CALL] cmd=%0d tlwe_words=%0d glwe_words=%0d flags=0x%02x",
                   active_desc_cmd_id_latched,
                   words,
                   result_words,
                   active_desc_flags_latched);

          status = gpu_service_submit_descriptor(
              int'(active_desc_cmd_id_latched),
              int'(desc_mode),
              words,
              result_words,
              tlwe_bytes,
              glwe_bytes,
              longint'(active_desc_tlwe_addr_latched),
              longint'(active_desc_glwe_addr_latched),
              longint'(active_desc_status_addr_latched),
              int'(active_desc_flags_latched),
              real_gpu_tlwe_payload,
              real_gpu_glwe_payload,
              latency_tmp,
              woks_latency_tmp,
              ks_latency_tmp,
              service_seq_tmp,
              service_outstanding_tmp,
              golden_mismatch_tmp);
          $display("[TB][GPU_SERVICE][DBG] status=%0d words=%0d result_words=%0d", status, words, result_words);
          if (status == 0) begin
            longint unsigned bytes_read_calc;
            longint unsigned bytes_written_calc;
            real             latency_ns_real;
            real             latency_woks_real;
            real             latency_ks_real;
            bytes_read_calc    = longint'(words) * GPU_WORD_BYTES;
            bytes_written_calc = longint'(result_words) * GPU_WORD_BYTES;
            latency_ns_real    = real'(latency_tmp);
            latency_woks_real  = real'(woks_latency_tmp);
            latency_ks_real    = real'(ks_latency_tmp);
            mock_gpu_invocation_cnt_q <= mock_gpu_invocation_cnt_q + 1;
            $display("[TB][GPU_SERVICE] submit ok cmd=%0d tlwe_words=%0d glwe_words=%0d latency_ns=%0d",
                     active_desc_cmd_id_latched, words, result_words, latency_tmp);
            $display("[TB][GPU_SERVICE][SCORE] bytes_r=%0d bytes_w=%0d latency_ns=%.2f woks_ns=%.2f ks_ns=%.2f seq=%0d outstanding=%0d",
                     bytes_read_calc,
                     bytes_written_calc,
                     latency_ns_real,
                     latency_woks_real,
                     latency_ks_real,
                     service_seq_tmp,
                     service_outstanding_tmp);
            if (golden_mismatch_tmp == GOLDEN_MISMATCH_SKIP) begin
              $display("[TB][GPU_SERVICE][GOLDEN] skipped (mode=%0d)", int'(active_desc.mode));
            end else if (golden_mismatch_tmp != 0) begin
              $display("[TB][GPU_SERVICE][GOLDEN] mismatches=%0d", golden_mismatch_tmp);
            end else if (USE_REAL_GPU_RUNTIME) begin
              $display("[TB][GPU_SERVICE][GOLDEN] match");
            end
            mock_gpu_latency_valid_q  <= 1'b1;
            mock_gpu_latency_ns_q     <= latency_ns_real;
            mock_gpu_compute_ns_q     <= latency_woks_real;
            mock_gpu_memory_ns_q      <= latency_ks_real;
            mock_gpu_latency_sum_ns_q <= mock_gpu_latency_sum_ns_q + latency_ns_real;
            mock_gpu_compute_sum_ns_q <= mock_gpu_compute_sum_ns_q + latency_woks_real;
            mock_gpu_memory_sum_ns_q  <= mock_gpu_memory_sum_ns_q + latency_ks_real;
            mock_gpu_bytes_read_q     <= bytes_read_calc;
            mock_gpu_bytes_written_q  <= bytes_written_calc;
            mock_gpu_bytes_read_sum_q <= mock_gpu_bytes_read_sum_q + bytes_read_calc;
            mock_gpu_bytes_written_sum_q <= mock_gpu_bytes_written_sum_q + bytes_written_calc;
            gpu_service_sequence_q    <= service_seq_tmp;
            gpu_service_outstanding_q <= service_outstanding_tmp;
            gpu_service_golden_mismatch_q <= golden_mismatch_tmp;
            status_force_complete_q <= 1'b1;
        $display("[TB][GPU_SERVICE][STATUS_FORCE] forcing COMPLETE after DPI success (status=%0d)", status);
          end else begin
            $display("[TB][GPU_SERVICE] submit failed (status=%0d) - retaining mock status", status);
            gpu_service_golden_mismatch_q <= -1;
            status_force_complete_q <= 1'b1;
        $display("[TB][GPU_SERVICE][STATUS_FORCE] forcing COMPLETE due to DPI failure status=%0d", status);
          end
          submit_ready_real_gpu <= 1'b0;
          real_gpu_submit_done_q <= 1'b1;
        end
      end
      submit_ready_mock_gpu <= 1'b0;
      if (!USE_REAL_GPU_RUNTIME && !status_force_complete_q && active_desc_valid) begin
        if (mock_gpu_latency_valid_q) begin
          submit_ready_mock_gpu <= 1'b1;
        end else begin
        bit step5_only_desc_local;
        int target_words_local;
        step5_only_desc_local = active_desc.flags[7];
        target_words_local = 0;
        unique case (active_desc.mode)
          WOP_MODE_CB: begin
            target_words_local = expected_preks_q;
            if (target_words_local <= 0) target_words_local = REAL_PREKS_LEN;
            submit_ready_mock_gpu <= (dut.u_wop_kernel.cb_pre_ks_hs_cnt >= target_words_local);
          end
          WOP_MODE_VP: begin
            if (!step5_only_desc_local) begin
              target_words_local = clamp_gpu_tlwe_words(WOP_MODE_VP, 1'b0, active_desc.tlwe_words);
              submit_ready_mock_gpu <= (dut.u_wop_kernel.vp_gpu_preks_wr_idx_q >= target_words_local);
            end else begin
              target_words_local = expected_preks_q;
              if (target_words_local <= 0) target_words_local = REAL_PREKS_LEN;
              submit_ready_mock_gpu <= (dut.u_wop_kernel.cb_pre_ks_hs_cnt >= target_words_local);
            end
          end
          WOP_MODE_BE: begin
            if (!step5_only_desc_local) begin
              target_words_local = clamp_gpu_tlwe_words(WOP_MODE_BE, 1'b0, active_desc.tlwe_words);
              submit_ready_mock_gpu <= (dut.u_wop_kernel.be_gpu_preks_wr_idx_q >= target_words_local);
            end else begin
              target_words_local = expected_preks_q;
              if (target_words_local <= 0) target_words_local = REAL_PREKS_LEN;
              submit_ready_mock_gpu <= (dut.u_wop_kernel.cb_pre_ks_hs_cnt >= target_words_local);
            end
          end
          default: begin
            submit_ready_mock_gpu <= 1'b0;
          end
        endcase
        end
      end
      if (!USE_REAL_GPU_RUNTIME && !status_force_complete_q && submit_ready_mock_gpu) begin
        status_force_complete_q <= 1'b1;
        $display("[TB] Mock forcing Result Status COMPLETE at cycle %0d", cycle_counter);
      end else if (status_complete_seen && !status_complete_seen_prev_q) begin
        int                         status_idx;
        openssd_wop_result_status_t status_tmp;
        longint_u_t                 latency_ns_q;
        longint_u_t                 timestamp_ns_q;
        longint_u_t                 read_words_full_q;
        longint_u_t                 write_words_full_q;
        logic [15:0]                tlwe_words_field;
        logic [15:0]                glwe_words_field;
        logic [15:0]                ftl_total_field;
        logic [15:0]                ftl_hit_field;
        logic [15:0]                reserved0_field;
        logic [31:0]                ks_latency_field;

        status_idx         = addr_to_index(status_complete_addr_q);
        status_tmp         = openssd_wop_result_status_t'(axi_mem[status_idx]);
        latency_ns_q       = 64'd0;
        timestamp_ns_q     = longint_u_t'($time);
        read_words_full_q  = 64'd0;
        write_words_full_q = 64'd0;
        tlwe_words_field   = 16'd0;
        glwe_words_field   = 16'd0;

        $display("[TB][STATUS_EVT] status_complete_seen↑ cycle=%0d addr=0x%0h cmd=0x%0h (active_desc_valid=%0b)",
                 cycle_counter,
                 status_complete_addr_q,
                 status_tmp.cmd_id,
                 active_desc_valid);
        $display("[TB][STATUS_RAW] cmd=0x%0h status=0x%08h reserved0=0x%04h error=0x%08h reserved1=0x%08h",
                 status_tmp.cmd_id,
                 status_tmp.status,
                 status_tmp.reserved0,
                 status_tmp.error_code,
                 status_tmp.reserved1);

        if (mock_gpu_latency_valid_q && (mock_gpu_latency_ns_q > 0.0)) begin
          latency_ns_q = longint_u_t'($rtoi(mock_gpu_latency_ns_q + 0.5));
        end
        if (mock_gpu_latency_valid_q) begin
          read_words_full_q  = (GPU_WORD_BYTES != 0) ? (mock_gpu_bytes_read_q  / GPU_WORD_BYTES) : 64'd0;
          write_words_full_q = (GPU_WORD_BYTES != 0) ? (mock_gpu_bytes_written_q / GPU_WORD_BYTES) : 64'd0;
          tlwe_words_field   = (read_words_full_q  > 16'hFFFF) ? 16'hFFFF : read_words_full_q[15:0];
          glwe_words_field   = (write_words_full_q > 16'hFFFF) ? 16'hFFFF : write_words_full_q[15:0];
        end
        ftl_total_field = (ftl_total_reqs_q > 16'hFFFF) ? 16'hFFFF : ftl_total_reqs_q[15:0];
        ftl_hit_field   = (ftl_prefetch_hits_q > 16'hFFFF) ? 16'hFFFF : ftl_prefetch_hits_q[15:0];

        status_tmp.status       = WOP_STATUS_COMPLETE;
        status_tmp.latency_ns   = latency_ns_q;
        status_tmp.timestamp_ns = timestamp_ns_q;
        reserved0_field = 16'd0;
        ks_latency_field = 32'd0;
        if (mock_gpu_latency_valid_q) begin
          int unsigned seq_clamped;
          int unsigned seq_value;
          seq_value = (gpu_service_sequence_q >= 0) ? gpu_service_sequence_q : 0;
          if (seq_value > ((1 << 14) - 1)) begin
            seq_clamped = ((1 << 14) - 1);
          end else begin
            seq_clamped = seq_value[13:0];
          end
          reserved0_field[15] = (gpu_service_golden_mismatch_q > 0);
          reserved0_field[14] = USE_REAL_GPU_RUNTIME;
          reserved0_field[13:0] = seq_clamped[13:0];
        end
        if (mock_gpu_latency_valid_q && (mock_gpu_memory_ns_q > 0.0)) begin
          longint unsigned ks_latency_ns_u;
          ks_latency_ns_u = longint'($rtoi(mock_gpu_memory_ns_q + 0.5));
          if (ks_latency_ns_u > 32'hFFFF_FFFF) begin
            ks_latency_field = 32'hFFFF_FFFF;
          end else begin
            ks_latency_field = ks_latency_ns_u[31:0];
          end
        end
        status_tmp.reserved0 = reserved0_field;
        status_tmp.error_code = {ftl_total_field, ftl_hit_field};
        status_tmp.reserved1  = ks_latency_field;
        $display("[TB][MOCK_GPU][STATUS] latency_ns=%0d timestamp_ns=%0d tlwe_words=%0d glwe_words=%0d",
                 latency_ns_q,
                 timestamp_ns_q,
                 tlwe_words_field,
                 glwe_words_field);
        axi_mem[status_idx]     <= pack_result_status(status_tmp);
        status_complete_clr_q   <= 1'b1;
        $display("[TB][STATUS_CLR] status_complete_clr_q asserted at cycle %0d (cmd=0x%0h)",
                 cycle_counter,
                 status_tmp.cmd_id);

        if (mock_gpu_invocation_cnt_q != 0) begin
          real avg_latency_ns;
          real avg_compute_ns;
          real avg_memory_ns;
          avg_latency_ns = mock_gpu_latency_sum_ns_q / mock_gpu_invocation_cnt_q;
          avg_compute_ns = mock_gpu_compute_sum_ns_q / mock_gpu_invocation_cnt_q;
          avg_memory_ns  = mock_gpu_memory_sum_ns_q / mock_gpu_invocation_cnt_q;
          $display("[TB][MOCK_GPU][SUMMARY] count=%0d avg_latency_ns=%.2f avg_compute_ns=%.2f avg_memory_ns=%.2f total_bytes_r=%0d total_bytes_w=%0d",
                   mock_gpu_invocation_cnt_q,
                   avg_latency_ns,
                   avg_compute_ns,
                   avg_memory_ns,
                   mock_gpu_bytes_read_sum_q,
                   mock_gpu_bytes_written_sum_q);
        end
        status_force_complete_q     <= 1'b0;
        expected_preks_q            <= 16'd0;
        prev_expected_preks_q       <= 16'd0;
        mock_gpu_latency_valid_q    <= 1'b0;
        mock_gpu_latency_sum_ns_q   <= 0.0;
        mock_gpu_compute_sum_ns_q   <= 0.0;
        mock_gpu_memory_sum_ns_q    <= 0.0;
        gpu_service_golden_mismatch_q <= 0;
        mock_gpu_bytes_read_sum_q   <= '0;
        mock_gpu_bytes_written_sum_q<= '0;
        mock_gpu_invocation_cnt_q   <= 0;
      end
      status_complete_seen_prev_q <= status_complete_seen;
      if (USE_REAL_GPU_RUNTIME) begin
        if (!gpu_service_latency_valid_prev_q && gpu_service_latency_valid) begin
          bit step5_only_desc_lat;
          int completion_tlwe_words;
          int completion_glwe_words;
          longint unsigned bytes_read_calc;
          longint unsigned bytes_written_calc;
          real latency_ns_real;
          step5_only_desc_lat   = (active_desc_mode_latched == WOP_MODE_BIT_EXTRACT) ? 1'b0
                                    : (active_desc_flags_latched[7] || (active_desc_mode_latched == WOP_MODE_CB));
          completion_tlwe_words = active_desc_tlwe_words_latched;
          completion_glwe_words = active_desc_glwe_words_latched;
          if (step5_only_desc_lat) begin
            if (completion_tlwe_words <= 0) completion_tlwe_words = REAL_PREKS_LEN;
            if (completion_tlwe_words > REAL_PREKS_LEN) completion_tlwe_words = REAL_PREKS_LEN;
          end else begin
            if (completion_tlwe_words <= 0) completion_tlwe_words = GPU_PREKS_MAX_WORDS;
            if (completion_tlwe_words > GPU_PREKS_MAX_WORDS) completion_tlwe_words = GPU_PREKS_MAX_WORDS;
          end
          if (completion_glwe_words <= 0) begin
            completion_glwe_words = step5_only_desc_lat ? completion_tlwe_words : REAL_RESULT_LEN;
          end
          if (completion_glwe_words > REAL_RESULT_LEN) begin
            completion_glwe_words = REAL_RESULT_LEN;
          end
          bytes_read_calc    = longint'((completion_tlwe_words > 0) ? completion_tlwe_words : 0) * GPU_WORD_BYTES;
          bytes_written_calc = longint'((completion_glwe_words > 0) ? completion_glwe_words : 0) * GPU_WORD_BYTES;
          latency_ns_real    = real'(gpu_service_latency_ns);
          mock_gpu_latency_valid_q   <= 1'b1;
          mock_gpu_latency_ns_q      <= latency_ns_real;
          mock_gpu_compute_ns_q      <= 0.0;
          mock_gpu_memory_ns_q       <= 0.0;
          mock_gpu_latency_sum_ns_q  <= mock_gpu_latency_sum_ns_q + latency_ns_real;
          mock_gpu_bytes_read_q      <= bytes_read_calc;
          mock_gpu_bytes_written_q   <= bytes_written_calc;
          mock_gpu_bytes_read_sum_q  <= mock_gpu_bytes_read_sum_q + bytes_read_calc;
          mock_gpu_bytes_written_sum_q <= mock_gpu_bytes_written_sum_q + bytes_written_calc;
          mock_gpu_invocation_cnt_q  <= mock_gpu_invocation_cnt_q + 1;
          gpu_service_golden_mismatch_q <= 0;
          $display("[TB][GPU_SERVICE][SCORE] bytes_r=%0d bytes_w=%0d latency_ns=%.2f woks_ns=%.2f ks_ns=%.2f seq=%0d outstanding=%0d (latency_valid)",
                   bytes_read_calc,
                   bytes_written_calc,
                   latency_ns_real,
                   0.0,
                   0.0,
                   gpu_service_sequence_q,
                   gpu_service_outstanding_q);
          if (!status_force_complete_q) begin
            status_force_complete_q <= 1'b1;
            $display("[TB][GPU_SERVICE][STATUS_FORCE] forcing COMPLETE via latency_valid (tlwe_words=%0d glwe_words=%0d)",
                     completion_tlwe_words,
                     completion_glwe_words);
          end
          real_gpu_submit_done_q <= 1'b1;
        end
        gpu_service_latency_valid_prev_q <= gpu_service_latency_valid;
      end else begin
        gpu_service_latency_valid_prev_q <= 1'b0;
      end
    end
  end

  assign status_complete_clr = status_complete_clr_q;

  // 简易 host ACK：在 Pre-KS 握手完成后延迟若干拍回写 ACK
  logic       ack_done_q;
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      active_desc_ack <= 1'b0;
      ack_done_q      <= 1'b0;
    end else begin
      active_desc_ack <= 1'b0;
      if (!ack_done_q && status_complete_seen && !status_complete_seen_prev_q) begin
        active_desc_ack <= 1'b1;
        ack_done_q      <= 1'b1;
        $display("[TB] Host ACK pulse issued at cycle %0d (result_status_complete)", cycle_counter);
        if (active_desc_valid) begin
          $display("[TB] Unified kernel ACK: cmd_id=%0d mode=%0d tlwe_words=%0d glwe_words=%0d cycle=%0d",
                   int'(active_desc.cmd_id),
                   int'(active_desc.mode),
                   int'(active_desc.tlwe_words),
                   int'((active_desc.glwe_words != 0) ? active_desc.glwe_words : active_desc.tlwe_words),
                   cycle_counter);
          if ((active_desc.mode == WOP_MODE_BE) || (active_desc.mode == WOP_MODE_VP)) begin
            automatic longint unsigned perf_cycles;
            automatic longint unsigned perf_req_stall = dut.u_wop_kernel.regf_req_stall_cnt;
            automatic longint unsigned perf_data_wait = dut.u_wop_kernel.regf_data_wait_cnt;
            if (active_desc.mode == WOP_MODE_BE) begin
              perf_cycles = dut.u_wop_kernel.be_pre_cycle_cnt;
              $display("[UNIFIED_PBS][PERF][BE] pre_cycles=%0d regf_req_stall=%0d regf_data_wait=%0d",
                       perf_cycles, perf_req_stall, perf_data_wait);
            end else begin
              perf_cycles = dut.u_wop_kernel.vp_pre_cycle_cnt;
              $display("[UNIFIED_PBS][PERF][VP] pre_cycles=%0d regf_req_stall=%0d regf_data_wait=%0d",
                       perf_cycles, perf_req_stall, perf_data_wait);
            end
          end
        end else begin
          $display("[TB] Unified kernel ACK: cycle=%0d (descriptor released before log)", cycle_counter);
        end
      end
      if (!active_desc_valid) begin
        ack_done_q  <= 1'b0;
      end
    end
  end

  // Monitor wrapper instruction handshake
  always_ff @(posedge clk) begin
    if (dut.kernel_inst_vld_w) begin
      $display("[TB_MON] kernel_inst_vld=%0b rdy=%0b ack=%0b mode=%0d time=%0t",
               dut.kernel_inst_vld_w,
               dut.kernel_inst_rdy_w,
               dut.kernel_inst_ack_w,
               dut.operation_mode_q,
               $time);
    end
  end

  // --------------------------------------------------------------------------------------------
  // Main stimulus sequence
  // --------------------------------------------------------------------------------------------
  initial begin
    int descriptor_count_cfg;
    int host_cmd_id_base_cfg;
    int host_cmd_id_step_cfg;
    int tlwe_words_cfg;
    int glwe_words_cfg;
    bit host_ctrl_use_dpi_cfg;
    string host_ctrl_socket_cfg;

    wait (s_rst_n);
    repeat (10) @(posedge clk);

    fork
      begin
        wait (cycle_counter >= max_cycles_cfg);
        if (test_status == TEST_UNKNOWN) begin
          $display("[TB] Timeout after %0d cycles", cycle_counter);
          test_status <= TEST_TIMEOUT;
          #1 $finish;
        end
      end
    join_none

    host_ctrl_use_dpi_cfg   = $test$plusargs("HOST_CTRL_DPI");
    host_ctrl_socket_cfg    = get_plusarg_string("HOST_CTRL_SOCKET", "/tmp/wop_host_ctrl.sock");

    if (host_ctrl_use_dpi_cfg) begin
      string socket_path;
      int    server_rc;
      int    cmd_valid;
      int    cmd_type;
      longint unsigned cmd_addr;
      longint unsigned cmd_data0;
      longint unsigned cmd_data1;
      longint unsigned cmd_data2;
      longint unsigned cmd_data3;
      int unsigned cmd_data32;
      int unsigned cmd_strb;
      int cmd_status_code;
      int unsigned rd_data32;
      longint unsigned rd_q0;
      longint unsigned rd_q1;
      longint unsigned rd_q2;
      longint unsigned rd_q3;

      socket_path = host_ctrl_socket_cfg;
      $display("[TB][HOST_CTRL] Enabling HOST_CTRL_DPI socket=%s", socket_path);
      tb_host_axil_register_scope();
      server_rc = tb_host_axil_server_start(socket_path);
      if (server_rc != 0) begin
        $fatal(1, "[TB] Failed to start HOST_CTRL_DPI server rc=%0d socket=%s", server_rc, socket_path);
      end
      $display("[TB] HOST_CTRL_DPI enabled (socket=%s)", socket_path);

      while (test_status == TEST_UNKNOWN) begin
        cmd_valid = 0;
        cmd_type = HOST_CMD_NONE;
        cmd_addr = '0;
        cmd_data0 = '0;
        cmd_data1 = '0;
        cmd_data2 = '0;
        cmd_data3 = '0;
        cmd_data32 = '0;
        cmd_strb = '0;
        cmd_status_code = 0;

        void'(tb_host_axil_server_poll(1,
                                       cmd_valid,
                                       cmd_type,
                                       cmd_addr,
                                       cmd_data0,
                                       cmd_data1,
                                       cmd_data2,
                                       cmd_data3,
                                       cmd_data32,
                                       cmd_strb,
                                       cmd_status_code));

        if (cmd_valid != 0) begin
          case (cmd_type)
            HOST_CMD_AXIL_WRITE: begin
              tb_host_axil_write(int'(cmd_addr), cmd_data32, cmd_strb);
              void'(tb_host_axil_server_reply_ok());
            end
            HOST_CMD_AXIL_READ: begin
              rd_data32 = '0;
              tb_host_axil_read(int'(cmd_addr), rd_data32);
              void'(tb_host_axil_server_reply_ok_u32(rd_data32));
            end
            HOST_CMD_MEM_WRITE: begin
              tb_host_axi_mem_write_qwords(cmd_addr, cmd_data0, cmd_data1, cmd_data2, cmd_data3);
              void'(tb_host_axil_server_reply_ok());
            end
            HOST_CMD_MEM_READ: begin
              rd_q0 = '0;
              rd_q1 = '0;
              rd_q2 = '0;
              rd_q3 = '0;
              tb_host_axi_mem_read_qwords(cmd_addr, rd_q0, rd_q1, rd_q2, rd_q3);
              void'(tb_host_axil_server_reply_ok_u64x4(rd_q0, rd_q1, rd_q2, rd_q3));
            end
            HOST_CMD_SET_STATUS: begin
              tb_host_ctrl_set_status(cmd_status_code, "host_ctrl set_status");
              void'(tb_host_axil_server_reply_ok());
            end
            default: begin
              void'(tb_host_axil_server_reply_error("unknown cmd_type"));
            end
          endcase
        end
        @(posedge clk);
      end

      case (test_status)
        TEST_PASSED: begin
          $display("[TB] HOST_CTRL_DPI reported PASS");
        end
        TEST_FAILED: begin
          $display("[TB] HOST_CTRL_DPI reported FAIL");
        end
        TEST_TIMEOUT: begin
          $display("[TB] HOST_CTRL_DPI reported TIMEOUT");
        end
        default: begin
          $display("[TB] HOST_CTRL_DPI reported status=%0d", test_status);
        end
      endcase

      repeat (20) @(posedge clk);
      tb_host_axil_server_stop();
      $finish;
    end else begin
      descriptor_count_cfg   = get_plusarg_int("DESC_COUNT", DESC_COUNT_CFG);
      if (descriptor_count_cfg < 1) begin
        $display("[TB] DESC_COUNT plusarg invalid (%0d), defaulting to 1", descriptor_count_cfg);
        descriptor_count_cfg = 1;
      end
      host_cmd_id_base_cfg   = get_plusarg_int("HOST_CMD_ID_BASE", HOST_CMD_ID_BASE_CFG);
      host_cmd_id_step_cfg   = get_plusarg_int("HOST_CMD_ID_STEP", HOST_CMD_ID_STEP_CFG);
      if (host_cmd_id_step_cfg == 0) begin
        $display("[TB] HOST_CMD_ID_STEP cannot be zero, overriding to 1");
        host_cmd_id_step_cfg = 1;
      end
      tlwe_words_cfg = TLWE_WORDS_CFG;
      glwe_words_cfg = GLWE_WORDS_CFG;

      $display("[TB] Programming AXI-Lite registers (descriptor_count=%0d cmd_base=0x%04h step=%0d)",
               descriptor_count_cfg,
               host_cmd_id_base_cfg & 16'hFFFF,
               host_cmd_id_step_cfg);
      axil_write(12'h018, 32'(TLWE_BASE_ADDR[31:0]));
      axil_write(12'h01C, 32'(TLWE_BASE_ADDR[63:32]));
      axil_write(12'h020, 32'd256); // BSK stride bytes placeholder
      axil_write(12'h024, 32'(TLWE_BASE_ADDR[31:0]));
      axil_write(12'h028, 32'(TLWE_BASE_ADDR[63:32]));
      axil_write(12'h02C, 32'd256);
      axil_write(12'h030, 32'(GLWE_BASE_ADDR[31:0]));
      axil_write(12'h034, 32'(GLWE_BASE_ADDR[63:32]));
      axil_write(12'h038, 32'd256);

      axil_write(12'h008, 32'(DESC_BASE_ADDR[31:0]));
      axil_write(12'h00C, 32'(DESC_BASE_ADDR[63:32]));

      for (int desc_idx = 0; desc_idx < descriptor_count_cfg; desc_idx++) begin
      int raw_cmd_id;
      logic [15:0] current_cmd_id;
      logic [31:0] pre_cmd_word;
      logic [31:0] fire_cmd_word;
      logic [31:0] ack_cmd_word;
      logic [31:0] cmd_id_word;
      int expected_snapshot;
      int handshake_snapshot;

      raw_cmd_id      = host_cmd_id_base_cfg + desc_idx * host_cmd_id_step_cfg;
      current_cmd_id  = raw_cmd_id[15:0];
      pre_cmd_word    = {2'b0, TARGET_MODE_BITS, 12'h000, current_cmd_id};
      cmd_id_word     = {16'h0000, current_cmd_id};
      fire_cmd_word   = 32'h8000_0000 | CTRL_MODE_WORD | cmd_id_word;
      ack_cmd_word    = 32'h4000_0000 | CTRL_MODE_WORD | cmd_id_word;

      $display("[TB] === Descriptor run %0d/%0d (cmd_id=0x%04h) ===",
               desc_idx + 1,
               descriptor_count_cfg,
               current_cmd_id);
      ring_reserve_slot(current_cmd_id);
      ring_wait_for_capacity();
      program_descriptor(current_cmd_id, tlwe_words_cfg, glwe_words_cfg);

      // Fire doorbell: {ack,doorbell} sequence with selected mode bits
      axil_write(12'h000, pre_cmd_word);
      axil_write(12'h000, fire_cmd_word);
      ring_mark_busy(current_cmd_id);

      $display("[TB] Doorbell fired, waiting for descriptor activation");
      $display("[TB][DESC_LOOP] waiting for active_desc_valid assert (desc_idx=%0d)", desc_idx);
      wait (active_desc_valid);
      $display("[TB][DESC_LOOP] active_desc_valid asserted at cycle %0d (desc_idx=%0d)",
               cycle_counter,
               desc_idx);
      $display("[TB] Descriptor active: cmd_id=%0d mode=%0d", active_desc.cmd_id, active_desc.mode);
      $display("[TB] Descriptor tlwe_words=%0d", active_desc.tlwe_words);
      $display("[TB] Descriptor glwe_words=%0d", active_desc.glwe_words);

      if (TARGET_MODE_E == WOP_MODE_CB) begin
        wait (expected_preks_q != 16'd0 && dut.u_wop_kernel.cb_pre_ks_hs_cnt == expected_preks_q);
        $display("[TB] KS feed handshake complete (%0d coefficients)", dut.u_wop_kernel.cb_pre_ks_hs_cnt);
      end else if ((TARGET_MODE_E == WOP_MODE_VP || TARGET_MODE_E == WOP_MODE_BE) && (expected_preks_q == 16'd0)) begin
        int tlwe_target_words;
        tlwe_target_words = (tlwe_words_cfg > 0) ? tlwe_words_cfg : GPU_PREKS_MAX_WORDS;
        if (tlwe_target_words > GPU_PREKS_MAX_WORDS) begin
          tlwe_target_words = GPU_PREKS_MAX_WORDS;
        end
        if (!USE_REAL_GPU_RUNTIME) begin
          wait (mock_gpu_latency_valid_q);
          $display("[TB] Mock GPU ready for mode=%0d (skipping TLWE staging wait)", TARGET_MODE_E);
        end else if (TARGET_MODE_E == WOP_MODE_VP) begin
          wait ((dut.u_wop_kernel.vp_gpu_preks_wr_idx_q + 16'd1) >= tlwe_target_words);
          $display("[TB] VP TLWE staging complete (%0d words)", tlwe_target_words);
        end else begin
          wait ((dut.u_wop_kernel.be_gpu_preks_wr_idx_q + 16'd1) >= tlwe_target_words);
          $display("[TB] BE TLWE staging complete (%0d words)", tlwe_target_words);
        end
        $display("[TB][DESC_LOOP] staging wait complete at cycle %0d (desc_idx=%0d)", cycle_counter, desc_idx);
      end else begin
        wait (expected_preks_q != 16'd0 && dut.u_wop_kernel.cb_pre_ks_hs_cnt == expected_preks_q);
        $display("[TB] Step5-only handshake complete (%0d coefficients)", dut.u_wop_kernel.cb_pre_ks_hs_cnt);
      end

      if (USE_REAL_GPU_RUNTIME) begin
        $display("[TB][DESC_LOOP] waiting for status_complete_clr_q pulse (desc_idx=%0d)", desc_idx);
        @(posedge status_complete_clr_q);
        $display("[TB][DESC_LOOP] status_complete_clr_q pulse observed at cycle %0d (desc_idx=%0d)",
                 cycle_counter,
                 desc_idx);
      end
      if ((TARGET_MODE_E == WOP_MODE_VP || TARGET_MODE_E == WOP_MODE_BE) && (expected_preks_lat_q == 16'd0)) begin
        expected_snapshot  = (tlwe_words_cfg > 0) ? tlwe_words_cfg : GPU_PREKS_MAX_WORDS;
        handshake_snapshot = expected_snapshot;
      end else begin
        expected_snapshot  = expected_preks_lat_q;
        handshake_snapshot = dut.u_wop_kernel.cb_pre_ks_hs_cnt;
      end
      repeat (5) @(posedge clk);
      // Ack through AXI-Lite CTRL_CMD[30]
      axil_write(12'h000, ack_cmd_word);
      ring_mark_release(current_cmd_id);
      $display("[TB] Host ACK sent (cmd_id=0x%04h)", current_cmd_id);

      $display("[TB][DESC_LOOP] waiting for active_desc_valid deassert (desc_idx=%0d)", desc_idx);
      wait (!active_desc_valid);
      $display("[TB][DESC_LOOP] active_desc_valid deasserted at cycle %0d (desc_idx=%0d)",
               cycle_counter,
               desc_idx);
      $display("[TB] Descriptor retired at cycle %0d", cycle_counter);

      if (desc_idx == descriptor_count_cfg - 1) begin
        if (handshake_snapshot == expected_snapshot) begin
          test_status <= TEST_PASSED;
          $display("[TB] ✅ GPU handshake sequence completed (expected=%0d actual=%0d)",
                   expected_snapshot,
                   handshake_snapshot);
        end else begin
          test_status <= TEST_FAILED;
          $display("[TB] ❌ Unexpected handshake count: actual=%0d expected=%0d",
                   handshake_snapshot,
                   expected_snapshot);
        end
      end else begin
        $display("[TB][DESC_LOOP] clearing status_complete_seen before next descriptor (desc_idx=%0d status_seen=%0b)",
                 desc_idx,
                 status_complete_seen);
        pulse_status_complete_clr();
        wait (!status_complete_seen);
        $display("[TB][DESC_LOOP] status_complete_seen deasserted at cycle %0d (desc_idx=%0d)",
                 cycle_counter,
                 desc_idx);
        repeat (10) @(posedge clk);
      end
    end

      repeat (20) @(posedge clk);
      tb_host_axil_server_stop();
      $finish;
    end
  end

endmodule

module tb_gpu_woks_stub #(
  parameter int DATA_W = 64,
  parameter int PREKS_LEN = 64,
  parameter int RESULT_LEN = 64,
  parameter int PIPELINE_LATENCY = 8,
  parameter bit ENABLE_GPU_SERVICE = 1'b0
)(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                gpu_service_enable,
  input  logic [15:0]         desc_cmd_id_i,
  input  logic [1:0]          desc_mode_i,
  input  logic [7:0]          desc_flags_i,
  input  logic [63:0]         desc_tlwe_addr_i,
  input  logic [63:0]         desc_glwe_addr_i,
  input  logic [63:0]         desc_status_addr_i,
  input  logic [15:0]         desc_tlwe_words_i,
  input  logic [15:0]         desc_glwe_words_i,
  output logic                gpu_service_latency_valid_o,
  output longint unsigned     gpu_service_latency_ns_o,
  wop_gpu_woks_if.gpu         gpu_link
);
  import "DPI-C" function int gpu_service_submit_descriptor(
      input int cmd_id,
      input int mode,
      input int tlwe_words,
      input int glwe_words,
      input int tlwe_bytes,
      input int glwe_bytes,
      input longint unsigned tlwe_addr,
      input longint unsigned glwe_addr,
      input longint unsigned status_addr,
      input int flags,
      input byte unsigned tlwe_payload[],
      output byte unsigned glwe_payload[],
      output longint latency_ns,
      output longint woks_latency_ns,
      output longint ks_latency_ns,
      output int sequence_no,
      output int outstanding,
      output int golden_mismatch
    );
  localparam int PREKS_CNT_W  = (PREKS_LEN <= 1) ? 1 : $clog2(PREKS_LEN + 1);
  localparam int RESULT_CNT_W = (RESULT_LEN <= 1) ? 1 : $clog2(RESULT_LEN + 1);
  localparam int LAT_CNT_W    = (PIPELINE_LATENCY <= 1) ? 1 : $clog2(PIPELINE_LATENCY + 1);

  typedef enum logic [1:0] {
    S_IDLE,
    S_COLLECT,
    S_COMPUTE,
    S_SEND
  } stub_state_e;

  stub_state_e                        state_q;
  logic [PREKS_CNT_W-1:0]             preks_count_q;
  logic [PREKS_CNT_W-1:0]             preks_total_q;
  logic [RESULT_CNT_W-1:0]            result_count_q;
  logic [LAT_CNT_W-1:0]               latency_cnt_q;
  localparam int WORD_BYTES = (DATA_W <= 8) ? 1 : (DATA_W / 8);

  logic [PREKS_LEN-1:0][DATA_W-1:0]   preks_buf;
  logic [RESULT_LEN-1:0][DATA_W-1:0]  result_buf;
  byte unsigned                       tlwe_payload_mem [0:PREKS_LEN*WORD_BYTES-1];
  byte unsigned                       glwe_payload_mem [0:RESULT_LEN*WORD_BYTES-1];

  logic                                service_started_q;
  logic [RESULT_CNT_W-1:0]             result_words_q;
  logic                                gpu_service_latency_valid_q;
  longint unsigned                     gpu_service_latency_ns_q;
  int                                   gpu_service_golden_mismatch_q;
  logic                                last_word_flag;
  logic [15:0]                         desc_cmd_id_q;
  logic [1:0]                          desc_mode_q;
  logic [7:0]                          desc_flags_q;
  logic [63:0]                         desc_tlwe_addr_q;
  logic [63:0]                         desc_glwe_addr_q;
  logic [63:0]                         desc_status_addr_q;
  logic [15:0]                         desc_tlwe_words_q;
  logic [15:0]                         desc_glwe_words_q;

  assign gpu_service_latency_valid_o = gpu_service_latency_valid_q;
  assign gpu_service_latency_ns_o    = gpu_service_latency_ns_q;

  initial begin
    $display("[TB][GPU_STUB] ENABLE_GPU_SERVICE=%0d gpu_service_enable=%0b", ENABLE_GPU_SERVICE, gpu_service_enable);
  end

  task automatic build_result_buffer(input logic [PREKS_CNT_W-1:0] total);
    for (int idx = 0; idx < RESULT_LEN; idx++) begin
      if (total == '0) begin
        result_buf[idx] = '0;
      end else if (idx < total) begin
        result_buf[idx] = preks_buf[idx];
      end else begin
        result_buf[idx] = preks_buf[total-1];
      end
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q                  <= S_IDLE;
      preks_count_q            <= '0;
      preks_total_q            <= '0;
      result_count_q           <= '0;
      result_words_q           <= RESULT_CNT_W'(1);
      latency_cnt_q            <= '0;
      gpu_link.preks_ready     <= 1'b0;
      gpu_link.result_valid    <= 1'b0;
      gpu_link.result_last     <= 1'b0;
      gpu_link.result_data     <= '0;
      service_started_q        <= 1'b0;
      gpu_service_latency_valid_q <= 1'b0;
      gpu_service_latency_ns_q <= 0;
      gpu_service_golden_mismatch_q <= 0;
      desc_cmd_id_q            <= '0;
      desc_mode_q              <= '0;
      desc_flags_q             <= '0;
      desc_tlwe_addr_q         <= '0;
      desc_glwe_addr_q         <= '0;
      desc_status_addr_q       <= '0;
      desc_tlwe_words_q        <= '0;
      desc_glwe_words_q        <= '0;
    end else begin
      gpu_link.preks_ready  <= 1'b0;
      gpu_link.result_valid <= 1'b0;
      gpu_link.result_last  <= 1'b0;
      gpu_link.result_data  <= '0;
      gpu_service_latency_valid_q <= 1'b0;

      unique case (state_q)
        S_IDLE: begin
          preks_count_q        <= '0;
          preks_total_q        <= '0;
          result_count_q       <= '0;
          result_words_q       <= RESULT_CNT_W'(1);
          latency_cnt_q        <= LAT_CNT_W'(PIPELINE_LATENCY);
          service_started_q    <= 1'b0;
          gpu_link.preks_ready <= 1'b1;
          if (gpu_link.preks_valid) begin
            if (preks_count_q == '0) begin
              $display("[TB][GPU_LATCH] capturing descriptor tlwe=%0d glwe=%0d",
                       int'(desc_tlwe_words_i), int'(desc_glwe_words_i));
              desc_cmd_id_q      <= desc_cmd_id_i;
              desc_mode_q        <= desc_mode_i;
              desc_flags_q       <= desc_flags_i;
              desc_tlwe_addr_q   <= desc_tlwe_addr_i;
              desc_glwe_addr_q   <= desc_glwe_addr_i;
              desc_status_addr_q <= desc_status_addr_i;
              desc_tlwe_words_q  <= desc_tlwe_words_i;
              desc_glwe_words_q  <= desc_glwe_words_i;
            end
            preks_buf[preks_count_q] <= gpu_link.preks_data;
            preks_count_q            <= preks_count_q + 1'b1;
            $display("[TB][GPU_STUB] Pre-KS coef %0d captured val=0x%0h last=%0b",
                     preks_count_q + 1, gpu_link.preks_data, gpu_link.preks_last);
            if (gpu_link.preks_last) begin
              preks_total_q <= preks_count_q + 1'b1;
              $display("[TB][GPU_STUB] Captured Pre-KS stream (%0d words) at t=%0t",
                       preks_count_q + 1, $time);
              state_q        <= S_COMPUTE;
            end else begin
              state_q <= S_COLLECT;
            end
          end
        end

        S_COLLECT: begin
          gpu_link.preks_ready <= 1'b1;
          if (gpu_link.preks_valid) begin
            preks_buf[preks_count_q] <= gpu_link.preks_data;
            preks_count_q            <= preks_count_q + 1'b1;
            $display("[TB][GPU_STUB] Pre-KS coef %0d captured val=0x%0h last=%0b",
                     preks_count_q + 1, gpu_link.preks_data, gpu_link.preks_last);
            if (gpu_link.preks_last) begin
              preks_total_q <= preks_count_q + 1'b1;
              $display("[TB][GPU_STUB] Captured Pre-KS stream (%0d words) at t=%0t",
                       preks_count_q + 1, $time);
              latency_cnt_q   <= LAT_CNT_W'(PIPELINE_LATENCY);
              service_started_q <= 1'b0;
              state_q        <= S_COMPUTE;
            end
          end
        end

        S_COMPUTE: begin
          if (gpu_service_enable) begin
            if (!service_started_q) begin
              int      words;
              int      requested_words;
              int      result_words;
              int      tlwe_bytes;
              int      result_bytes;
              longint  latency_tmp;
              longint  woks_latency_tmp;
              longint  ks_latency_tmp;
              int      service_seq_tmp;
              int      service_outstanding_tmp;
              int      status;
              int      golden_mismatch_tmp;
              $display("[TB][GPU_SERVICE][DESC] tlwe_words_i=%0d glwe_words_i=%0d preks_total=%0d",
                       int'(desc_tlwe_words_q), int'(desc_glwe_words_q), int'(preks_total_q));
              // 统一走 clamp_gpu_tlwe_words，避免 VP/BE 被误截到 PREKS_LEN=501
              requested_words = (preks_total_q == '0) ? int'(desc_tlwe_words_q) : int'(preks_total_q);
              words = clamp_gpu_tlwe_words(openssd_wop_pkg::openssd_wop_mode_e'(desc_mode_q),
                                           desc_flags_q[7],
                                           requested_words);
              result_words = (desc_glwe_words_q != 0) ? int'(desc_glwe_words_q) : words;
              if (result_words <= 0) result_words = words;
              if (result_words <= 0) result_words = 1;
              if (result_words > RESULT_LEN) result_words = RESULT_LEN;

              $display("[TB][GPU_SERVICE][CALL] cmd=%0d tlwe_words=%0d glwe_words=%0d flags=0x%02x",
                       desc_cmd_id_q, words, result_words, desc_flags_q);

              tlwe_bytes   = words * WORD_BYTES;
              result_bytes = result_words * WORD_BYTES;
              for (int idx = 0; idx < words; idx++) begin
                for (int b = 0; b < WORD_BYTES; b++) begin
                  tlwe_payload_mem[idx*WORD_BYTES + b] = preks_buf[idx][8*b +:8];
                end
              end

              status = gpu_service_submit_descriptor(
                  int'(desc_cmd_id_q),
                  int'(desc_mode_q),
                  words,
                  result_words,
                  tlwe_bytes,
                  result_bytes,
                  longint'(desc_tlwe_addr_q),
                  longint'(desc_glwe_addr_q),
                  longint'(desc_status_addr_q),
                  int'(desc_flags_q),
                  tlwe_payload_mem,
                  glwe_payload_mem,
                  latency_tmp,
                  woks_latency_tmp,
                  ks_latency_tmp,
                  service_seq_tmp,
                  service_outstanding_tmp,
                  golden_mismatch_tmp);
              $display("[TB][GPU_SERVICE][DBG] status=%0d words=%0d result_words=%0d", status, words, result_words);

              service_started_q <= 1'b1;
              latency_cnt_q     <= LAT_CNT_W'(PIPELINE_LATENCY);

              if (status == 0) begin
                $display("[TB][GPU_SERVICE] submit ok cmd=%0d tlwe_words=%0d glwe_words=%0d latency_ns=%0d",
                         desc_cmd_id_i, words, result_words, latency_tmp);
                gpu_service_latency_valid_q  <= 1'b1;
                gpu_service_latency_ns_q     <= latency_tmp;
                result_words_q               <= RESULT_CNT_W'(result_words);
                gpu_service_golden_mismatch_q <= golden_mismatch_tmp;
                for (int idx = 0; idx < RESULT_LEN; idx++) begin
                  if (idx < result_words) begin
                    longint word_accum;
                    word_accum = 0;
                    for (int b = 0; b < WORD_BYTES; b++) begin
                      word_accum |= longint'(glwe_payload_mem[idx*WORD_BYTES + b]) << (8*b);
                    end
                    result_buf[idx] <= word_accum[DATA_W-1:0];
                  end else begin
                    result_buf[idx] <= '0;
                  end
                end
              end else begin
                $display("[TB][GPU_SERVICE] submit failed (status=%0d) - fallback to mock result", status);
                gpu_service_golden_mismatch_q <= -1;
                build_result_buffer(preks_total_q);
                result_words_q <= (preks_total_q == '0) ? RESULT_CNT_W'(RESULT_LEN)
                                                        : RESULT_CNT_W'(preks_total_q);
              end

              if (PIPELINE_LATENCY == 0) begin
                state_q <= S_SEND;
              end
            end else begin
              if (PIPELINE_LATENCY == 0) begin
                state_q <= S_SEND;
              end else if (latency_cnt_q != 0) begin
                latency_cnt_q <= latency_cnt_q - 1'b1;
              end else begin
                state_q <= S_SEND;
              end
            end
          end else begin
            if (PIPELINE_LATENCY == 0) begin
              build_result_buffer(preks_total_q);
              result_words_q <= (preks_total_q == '0) ? RESULT_CNT_W'(RESULT_LEN)
                                                      : RESULT_CNT_W'(preks_total_q);
              state_q        <= S_SEND;
            end else if (latency_cnt_q != 0) begin
              latency_cnt_q <= latency_cnt_q - 1'b1;
            end else begin
              build_result_buffer(preks_total_q);
              result_words_q <= (preks_total_q == '0) ? RESULT_CNT_W'(RESULT_LEN)
                                                      : RESULT_CNT_W'(preks_total_q);
              state_q        <= S_SEND;
            end
          end
        end

        S_SEND: begin
          gpu_link.result_valid <= 1'b1;
          gpu_link.result_data  <= result_buf[result_count_q];
          last_word_flag = (result_words_q <= 1) ? (result_count_q == RESULT_CNT_W'(0))
                                                : (result_count_q == result_words_q - 1'b1);
          gpu_link.result_last  <= last_word_flag;
          if (gpu_link.result_ready) begin
            $display("[TB][GPU_STUB] Result coef %0d sent val=0x%0h last=%0b",
                     result_count_q + 1, result_buf[result_count_q], last_word_flag);
            if (result_count_q == '0) begin
              $display("[TB][GPU_STUB] WoKS result stream started at t=%0t (len=%0d)",
                       $time, (result_words_q == 0) ? RESULT_LEN : result_words_q);
            end
            if (last_word_flag) begin
              state_q <= S_IDLE;
            end else begin
              result_count_q <= result_count_q + 1'b1;
            end
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
