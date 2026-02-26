`timescale 1ns/1ps

// ==============================================================================================
// Module: openssd_wop_wrapper
// ----------------------------------------------------------------------------------------------
// Description:
//   Top-level wrapper that prepares the WoP-PBS unified kernel for integration
//   inside the OpenSSD design. It adds AXI-Lite control registers, a descriptor
//   DMA fetch path, and a GPU doorbell bridge while exposing the existing
//   kernel resource interfaces.
// ==============================================================================================

`timescale 1ns/1ps

import common_definition_pkg::*;
import param_tfhe_definition_pkg::*;
import param_tfhe_pkg::*;
import param_ntt_pkg::*;
import ntt_core_common_param_pkg::*;
import vp_pbs_inst_pkg::*;
import pep_common_param_pkg::*;
import pep_ks_common_param_pkg::*;
import regf_common_param_pkg::*;
import hpu_common_instruction_pkg::*;
import axi_if_common_param_pkg::*;
import openssd_wop_pkg::*;

module openssd_wop_wrapper #(
  parameter int MOD_Q_W = 32,
  parameter int MAX_BIT_WIDTH = 20,
  parameter int N_LVL0 = 512,
  parameter int N_LVL1 = 1024,
  parameter int N_LVL2 = 2048,
  parameter int ELL_LVL1 = 3,
  parameter int K = 1,
  parameter int LBY = 64,
  parameter int LBX = 8,
  parameter int LBZ = 2,
  parameter int MOD_NTT_W = 64,
  parameter int MOD_NTT_TYPE = 0,
  parameter int ELL_LVL2 = 3,
  parameter int MOD_KSK_W = 32,
  parameter int PSI = ntt_core_common_param_pkg::PSI,
  parameter int R = ntt_core_common_param_pkg::R,
  parameter int PBS_B_W = param_tfhe_pkg::PBS_B_W,
  parameter int BPBS_ID_W = pep_common_param_pkg::BPBS_ID_W,
  parameter int NTT_OP_W = 64,
  parameter int BSK_BATCH_ID_W = 8,
  parameter int BSK_PC = 2,
  parameter int KSK_PC = 2,
  parameter int REGF_WR_REQ_W = 14,
  parameter int REGF_RD_REQ_W = 21,
  parameter int REGF_COEF_NB = 32,
  parameter int AXIL_ADDR_W = 12,
  parameter int AXIL_DATA_W = 32,
  parameter int AXI_ADDR_W = 64,
  parameter int AXI_DATA_W = 256,
  parameter int AXI_ID_W   = 6,
  // Simulation helper: when 0 (default) the wrapper auto-prefetches GLWE assets
  // immediately after descriptor acceptance instead of waiting for the kernel
  // to assert glwe_asset_req. Set to 1 to require explicit kernel requests.
  parameter bit USE_KERNEL_GLWE_REQ = 1'b0,
  parameter bit USE_GPU_RESULT_STUB = 1'b1
)(
  input  logic                     clk,
  input  logic                     s_rst_n,

  // Status/control inputs ---------------------------------------------------
  input  logic                     gpu_status_ready_i,
  input  logic                     active_desc_ack_i,

  // AXI-Lite control window -------------------------------------------------
  input  logic [AXIL_ADDR_W-1:0]   s_axil_awaddr,
  input  logic                     s_axil_awvalid,
  output logic                     s_axil_awready,
  input  logic [AXIL_DATA_W-1:0]   s_axil_wdata,
  input  logic [(AXIL_DATA_W/8)-1:0] s_axil_wstrb,
  input  logic                     s_axil_wvalid,
  output logic                     s_axil_wready,
  output logic [1:0]               s_axil_bresp,
  output logic                     s_axil_bvalid,
  input  logic                     s_axil_bready,
  input  logic [AXIL_ADDR_W-1:0]   s_axil_araddr,
  input  logic                     s_axil_arvalid,
  output logic                     s_axil_arready,
  output logic [AXIL_DATA_W-1:0]   s_axil_rdata,
  output logic [1:0]               s_axil_rresp,
  output logic                     s_axil_rvalid,
  input  logic                     s_axil_rready,

  output logic                     irq_o,

  // GPU doorbell interface --------------------------------------------------
  output logic [31:0]              gpu_db_tdata_o,
  output logic                     gpu_db_tvalid_o,
  input  logic                     gpu_db_tready_i,
  // GPU WoKS streaming link -------------------------------------------------
  wop_gpu_woks_if.wrapper          gpu_woks_link_if,

  // AXI master interface ----------------------------------------------------
  output logic [AXI_ID_W-1:0]      m_axi_awid,
  output logic [AXI_ADDR_W-1:0]    m_axi_awaddr,
  output logic [7:0]               m_axi_awlen,
  output logic [2:0]               m_axi_awsize,
  output logic [1:0]               m_axi_awburst,
  output logic [3:0]               m_axi_awcache,
  output logic [2:0]               m_axi_awprot,
  output logic [3:0]               m_axi_awqos,
  output logic                     m_axi_awvalid,
  input  logic                     m_axi_awready,
  output logic [AXI_DATA_W-1:0]    m_axi_wdata,
  output logic [(AXI_DATA_W/8)-1:0] m_axi_wstrb,
  output logic                     m_axi_wlast,
  output logic                     m_axi_wvalid,
  input  logic                     m_axi_wready,
  input  logic [AXI_ID_W-1:0]      m_axi_bid,
  input  logic [1:0]               m_axi_bresp,
  input  logic                     m_axi_bvalid,
  output logic                     m_axi_bready,
  output logic [AXI_ID_W-1:0]      m_axi_arid,
  output logic [AXI_ADDR_W-1:0]    m_axi_araddr,
  output logic [7:0]               m_axi_arlen,
  output logic [2:0]               m_axi_arsize,
  output logic [1:0]               m_axi_arburst,
  output logic [3:0]               m_axi_arcache,
  output logic [2:0]               m_axi_arprot,
  output logic [3:0]               m_axi_arqos,
  output logic                     m_axi_arvalid,
  input  logic                     m_axi_arready,
  input  logic [AXI_ID_W-1:0]      m_axi_rid,
  input  logic [AXI_DATA_W-1:0]    m_axi_rdata,
  input  logic [1:0]               m_axi_rresp,
  input  logic                     m_axi_rlast,
  input  logic                     m_axi_rvalid,
  output logic                     m_axi_rready,

  // Kernel resource interfaces ---------------------------------------------
  output logic                     pep_regf_wr_req_vld,
  input  logic                     pep_regf_wr_req_rdy,
  output logic [REGF_WR_REQ_W-1:0] pep_regf_wr_req,
  output logic [REGF_COEF_NB-1:0]  pep_regf_wr_data_vld,
  input  logic [REGF_COEF_NB-1:0]  pep_regf_wr_data_rdy,
  output logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] pep_regf_wr_data,
  input  logic                     regf_pep_wr_ack,

  output logic                     pep_regf_rd_req_vld,
  input  logic                     pep_regf_rd_req_rdy,
  output logic [REGF_RD_REQ_W-1:0] pep_regf_rd_req,
  input  logic [REGF_COEF_NB-1:0]  regf_pep_rd_data_avail,
  input  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_pep_rd_data,
  input  logic                     regf_pep_rd_last_word,

  input  logic                     reset_ksk_cache,
  output logic                     reset_ksk_cache_done,
  input  logic                     ksk_mem_avail,
  input  logic [KSK_PC-1:0][31:0]  ksk_mem_addr,

  output logic [3:0]               m_axi4_glwe_arid,
  output logic [31:0]              m_axi4_glwe_araddr,
  output logic [7:0]               m_axi4_glwe_arlen,
  output logic [2:0]               m_axi4_glwe_arsize,
  output logic [1:0]               m_axi4_glwe_arburst,
  output logic [3:0]               m_axi4_glwe_arqos,
  output logic                     m_axi4_glwe_arvalid,
  input  logic                     m_axi4_glwe_arready,
  input  logic [3:0]               m_axi4_glwe_rid,
  input  logic [63:0]              m_axi4_glwe_rdata,
  input  logic [1:0]               m_axi4_glwe_rresp,
  input  logic                     m_axi4_glwe_rlast,
  input  logic                     m_axi4_glwe_rvalid,
  output logic                     m_axi4_glwe_rready,

  output logic [BSK_PC-1:0][3:0]   m_axi4_bsk_arid,
  output logic [BSK_PC-1:0][31:0]  m_axi4_bsk_araddr,
  output logic [BSK_PC-1:0][7:0]   m_axi4_bsk_arlen,
  output logic [BSK_PC-1:0][2:0]   m_axi4_bsk_arsize,
  output logic [BSK_PC-1:0][1:0]   m_axi4_bsk_arburst,
  output logic [BSK_PC-1:0][3:0]   m_axi4_bsk_arqos,
  output logic [BSK_PC-1:0]        m_axi4_bsk_arvalid,
  input  logic [BSK_PC-1:0]        m_axi4_bsk_arready,
  input  logic [BSK_PC-1:0][3:0]   m_axi4_bsk_rid,
  input  logic [BSK_PC-1:0][63:0]  m_axi4_bsk_rdata,
  input  logic [BSK_PC-1:0][1:0]   m_axi4_bsk_rresp,
  input  logic [BSK_PC-1:0]        m_axi4_bsk_rlast,
  input  logic [BSK_PC-1:0]        m_axi4_bsk_rvalid,
  output logic [BSK_PC-1:0]        m_axi4_bsk_rready,

  output logic [KSK_PC-1:0][3:0]   m_axi4_ksk_arid,
  output logic [KSK_PC-1:0][31:0]  m_axi4_ksk_araddr,
  output logic [KSK_PC-1:0][7:0]   m_axi4_ksk_arlen,
  output logic [KSK_PC-1:0][2:0]   m_axi4_ksk_arsize,
  output logic [KSK_PC-1:0][1:0]   m_axi4_ksk_arburst,
  output logic [KSK_PC-1:0][3:0]   m_axi4_ksk_arqos,
  output logic [KSK_PC-1:0]        m_axi4_ksk_arvalid,
  input  logic [KSK_PC-1:0]        m_axi4_ksk_arready,
  input  logic [KSK_PC-1:0][3:0]   m_axi4_ksk_rid,
  input  logic [KSK_PC-1:0][63:0]  m_axi4_ksk_rdata,
  input  logic [KSK_PC-1:0][1:0]   m_axi4_ksk_rresp,
  input  logic [KSK_PC-1:0]        m_axi4_ksk_rlast,
  input  logic [KSK_PC-1:0]        m_axi4_ksk_rvalid,
  output logic [KSK_PC-1:0]        m_axi4_ksk_rready,

  output logic                     glwe_asset_valid,
  output logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] glwe_asset_data,
  output logic                     glwe_asset_ready,
  output logic                     glwe_asset_req,
  output logic                     glwe_asset_enable,

  output logic                     bsk_service_req_vld,
  input  logic                     bsk_service_req_rdy,
  output logic [BSK_BATCH_ID_W-1:0] bsk_service_batch_id,
  input  logic                     bsk_service_data_avail,
  input  logic [BSK_PC-1:0][R-1:0][MOD_Q_W-1:0] bsk_service_data,

  output logic [PSI-1:0][R-1:0]    ntt_service_decomp_avail,
  output logic [PSI-1:0][R-1:0][PBS_B_W:0] ntt_service_decomp_data,
  output logic                     ntt_service_decomp_sob,
  output logic                     ntt_service_decomp_eob,
  output logic                     ntt_service_decomp_sog,
  output logic                     ntt_service_decomp_eog,
  output logic                     ntt_service_decomp_sol,
  output logic                     ntt_service_decomp_eol,
  output logic [BPBS_ID_W-1:0]     ntt_service_decomp_pbs_id,
  output logic                     ntt_service_decomp_last_pbs,
  output logic                     ntt_service_decomp_full_throughput,
  output logic                     ntt_service_decomp_ctrl_vld,
  input  logic [PSI-1:0][R-1:0]    ntt_service_decomp_rdy,
  input  logic                     ntt_service_decomp_ctrl_rdy,

  input  logic [PSI-1:0][R-1:0][NTT_OP_W-1:0] ntt_service_result_data,
  input  logic [PSI-1:0][R-1:0]    ntt_service_result_avail,
  output logic [PSI-1:0][R-1:0]    ntt_service_result_rdy,
  input  logic                     ntt_service_result_ctrl_vld,
  output logic                     ntt_service_result_ctrl_rdy,

  output logic                     decomp_ntt_sog,
  output logic                     decomp_ntt_ctrl_avail,

  output openssd_wop_desc_t        active_desc_o,
  output logic                     active_desc_valid_o,

  output logic                     unified_pbs_inst_ack_o,
  output vp_pbs_response_t         unified_pbs_response_o
);

`ifndef SYNTHESIS
  import "DPI-C" function int wop_ftl_stage_descriptor(
    int mode,
    longint unsigned tlwe_addr,
    int tlwe_words,
    longint unsigned glwe_addr,
    int glwe_words
  );
  import "DPI-C" function int wop_ftl_get_channel_summary(
    int channel,
    output int tlwe_pages,
    output int glwe_pages
  );
`endif

  initial begin
    $display("[OPENSSD_WRAPPER] USE_GPU_RESULT_STUB=%0d", USE_GPU_RESULT_STUB);
  end

  localparam int LOADER_OUTSTANDING_BITS = 3;
  localparam int FTL_STAGE_TRACKED_CHANNELS = 16;

  // -------------------------------------------------------------------------
  // Internal signals
  logic                     doorbell_pulse;
  openssd_wop_mode_e        mode_sel;
  logic [15:0]              cmd_id_sel;
  logic [63:0]              desc_ptr_sel;
  logic [1:0]               irq_mask_dummy;
  openssd_wop_mode_e        mode_latched_q;
  logic [15:0]              cmd_id_q;
  logic [63:0]              desc_ptr_q;

  logic                     dma_start;
  logic                     dma_busy;
  logic                     dma_error;
  logic                     desc_dma_error;
  logic                     status_wr_busy;
  logic                     status_wr_error;
  logic                     status_wr_fault;
  logic                     status_fifo_overflow_q;
  logic [1:0]               status_fifo_valid_q;
  logic [1:0][63:0]         status_fifo_addr_q;
  logic [1:0][15:0]         status_fifo_cmd_q;
  logic [1:0][31:0]         status_fifo_code_q;
  logic                     status_wr_start;
  logic [63:0]              status_wr_addr;
  logic [255:0]             status_wr_data;
  openssd_wop_result_status_t status_payload_int;
  logic                     completion_ack_pending_q;
  logic                     internal_desc_ack_pulse;
  logic                     status_wr_complete_start;
`ifdef SIM_WOP_AUTO_DESC_ACK
  logic                     sim_auto_desc_ack_pulse;
`endif

  logic                     desc_valid;
  logic                     desc_ready;
  openssd_wop_desc_t        desc_payload;

  logic                     gpu_pending;
  logic                     gpu_overflow;
  logic [31:0]              gpu_token_q;
  logic                     gpu_token_valid_q;
  logic                     gpu_overflow_q;

  logic                     doorbell_ready_w;
  logic                     doorbell_reject_pulse;
  logic                     doorbell_pending_q;
  logic                     doorbell_start_pulse;
  logic                     doorbell_reject_evt;

  logic                     ctrl_busy;
  logic                     ctrl_error;
  logic                     error_raw_q;
  logic                     error_evt;
  logic                     error_raw;
  logic [7:0]               error_vector_bus;
  logic                     done_evt;
  logic                     completion_evt;
  logic                     gpu_completion_edge;
  logic                     kernel_ack_edge;
  logic                     prev_kernel_ack_q;
  logic                     prev_active_desc_ack_q;
  logic                     prev_active_desc_valid_q;

  logic [15:0]              ftl_stage_tlwe_total_q;
  logic [15:0]              ftl_stage_glwe_total_q;
  logic [15:0]              ftl_stage_tlwe_mask_q;
  logic [15:0]              ftl_stage_glwe_mask_q;
  logic [15:0]              ftl_stage_cmd_id_q;
  logic                     ftl_stage_gpu_flag_q;
  logic                     ftl_stage_valid_q;
  logic [15:0]              ftl_status_tlwe_total_q;
  logic [15:0]              ftl_status_glwe_total_q;
  logic [15:0]              ftl_status_tlwe_mask_q;
  logic [15:0]              ftl_status_glwe_mask_q;
  logic [15:0]              ftl_status_gpu_flags_q;
  logic                     ftl_status_valid_q;

  logic [15:0]              last_cmd_id_q;
  logic                     ack_q;
  logic                     gpu_status_ready_mux;
  logic                     gpu_db_tready_mux;
  logic                     active_desc_ack_mux;
  logic                     host_desc_ack_w;
  logic                     ctrl_desc_ack_w;
  logic                     kernel_inst_ack_w;
`ifdef SIM_WOP_GPU_LOOPBACK
  logic                     gpu_loopback_ready;
  logic                     gpu_loopback_tready;
  logic                     gpu_loopback_ack;
`endif
`ifdef SIM_WOP_AUTO_DESC_ACK
  `ifndef SIM_WOP_AUTO_ACK_DELAY
    `define SIM_WOP_AUTO_ACK_DELAY 256
  `endif
  localparam int SIM_AUTO_ACK_CNT_W = ($clog2(`SIM_WOP_AUTO_ACK_DELAY + 1) == 0)
                                    ? 1
                                    : $clog2(`SIM_WOP_AUTO_ACK_DELAY + 1);
  logic [SIM_AUTO_ACK_CNT_W-1:0] sim_auto_ack_cnt_q;
  logic                          sim_auto_ack_pending_q;
  logic                          sim_auto_desc_ack_pulse_q;
`endif

  openssd_wop_desc_t        active_desc_int;
  logic                     active_desc_valid_int;
  logic                     kernel_desc_error;
  logic                     kernel_gpu_preks_ready_w;
  logic                     kernel_gpu_preks_valid_w;
  logic [MOD_Q_W-1:0]       kernel_gpu_preks_data_w;
  logic                     kernel_gpu_preks_last_w;
  logic                     kernel_gpu_result_valid_w;
  logic [MOD_Q_W-1:0]       kernel_gpu_result_data_w;
  logic                     kernel_gpu_result_last_w;
  logic                     gpu_result_buf_valid_q;
  logic [MOD_Q_W-1:0]       gpu_result_buf_data_q;
  logic                     gpu_result_buf_last_q;
  logic                     kernel_gpu_result_ready_w;
  logic                     kernel_bsk_throttle_w;
  logic                     kernel_ksk_throttle_w;
  localparam int VP_DEFAULT_SAMPLES    = 20;
  localparam int TLWE_LEN_CB          = N_LVL0 + 1;
  localparam int TLWE_LEN_VP          = VP_DEFAULT_SAMPLES * (N_LVL1 + 1);
  localparam int GPU_PREKS_LEN        = (TLWE_LEN_VP > TLWE_LEN_CB) ? TLWE_LEN_VP : TLWE_LEN_CB;
  localparam int GPU_RESULT_LEN   = N_LVL2 + 1;
  localparam int GPU_PREKS_CNT_W  = (GPU_PREKS_LEN <= 1) ? 1 : $clog2(GPU_PREKS_LEN + 1);
  localparam int GPU_RESULT_CNT_W = (GPU_RESULT_LEN <= 1) ? 1 : $clog2(GPU_RESULT_LEN + 1);
  typedef enum logic [2:0] {
    GPU_IDLE,
    GPU_COLLECT,
    GPU_EXEC,
    GPU_STREAM,
    GPU_WAIT
  } gpu_state_e;
  gpu_state_e                 gpu_state_q;
  logic [GPU_PREKS_CNT_W-1:0] gpu_preks_count_q;
  logic [GPU_PREKS_CNT_W-1:0] gpu_preks_count_latched_q;
  logic [GPU_RESULT_CNT_W-1:0] gpu_result_ptr_q;
logic [GPU_PREKS_LEN-1:0][MOD_Q_W-1:0]   gpu_preks_mem;
logic [GPU_RESULT_LEN-1:0][MOD_Q_W-1:0]  gpu_result_mem;
logic                                    gpu_woks_mode_active_q;
logic                                    gpu_result_streaming_q;
`ifndef SIM_WOP_GPU_LOOPBACK
  logic [GPU_PREKS_CNT_W-1:0]              gpu_preks_last_idx_q;
  logic [GPU_PREKS_CNT_W-1:0]              gpu_send_idx_q;
`endif

  assign host_desc_ack_w = ctrl_desc_ack_w
                         | active_desc_ack_i
                         | internal_desc_ack_pulse
`ifdef SIM_WOP_AUTO_DESC_ACK
                         | sim_auto_desc_ack_pulse
`endif
                         ;

`ifdef SIM_WOP_GPU_LOOPBACK
  assign gpu_status_ready_mux = gpu_loopback_ready;
  assign gpu_db_tready_mux    = gpu_loopback_tready;
  assign active_desc_ack_mux  = gpu_loopback_ack | host_desc_ack_w;
`else
  assign gpu_status_ready_mux = gpu_status_ready_i;
  assign gpu_db_tready_mux    = gpu_db_tready_i;
  assign active_desc_ack_mux  = host_desc_ack_w;
`endif

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      prev_kernel_ack_q      <= 1'b0;
      prev_active_desc_ack_q <= 1'b0;
      prev_active_desc_valid_q <= 1'b0;
    end else begin
      prev_kernel_ack_q      <= kernel_inst_ack_w;
      prev_active_desc_ack_q <= active_desc_ack_i;
      prev_active_desc_valid_q <= active_desc_valid_int;
    end
  end

  assign kernel_ack_edge      = kernel_inst_ack_w && !prev_kernel_ack_q;
  assign gpu_completion_edge  = active_desc_ack_i && !prev_active_desc_ack_q;
  assign completion_evt       = active_desc_valid_int
                              & (kernel_ack_edge | gpu_completion_edge);

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      gpu_woks_mode_active_q <= 1'b0;
    end else begin
      if (desc_valid && desc_ready) begin
        gpu_woks_mode_active_q <= |(desc_payload.flags & WOP_FLAG_GPU_WOKS);
      end else if (!active_desc_valid_int) begin
        gpu_woks_mode_active_q <= 1'b0;
      end
    end
  end

`ifdef SIM_WOP_GPU_LOOPBACK
  assign gpu_woks_link_if.preks_valid = 1'b0;
  assign gpu_woks_link_if.preks_last  = 1'b0;
  assign gpu_woks_link_if.preks_data  = '0;
  assign gpu_woks_link_if.result_ready = kernel_gpu_result_ready_w;
  assign kernel_gpu_preks_ready_w = (gpu_state_q == GPU_COLLECT);

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      gpu_state_q                 <= GPU_IDLE;
      gpu_preks_count_q           <= '0;
      gpu_preks_count_latched_q   <= '0;
      gpu_result_ptr_q            <= '0;
      kernel_gpu_result_valid_w   <= 1'b0;
      kernel_gpu_result_last_w    <= 1'b0;
      kernel_gpu_result_data_w    <= '0;
      gpu_result_streaming_q      <= 1'b0;
    end else begin
      kernel_gpu_result_valid_w <= 1'b0;
      kernel_gpu_result_last_w  <= 1'b0;

      case (gpu_state_q)
        GPU_IDLE: begin
          gpu_preks_count_q         <= '0;
          gpu_result_ptr_q          <= '0;
          gpu_result_streaming_q    <= 1'b0;
          if (active_desc_valid_int && gpu_woks_mode_active_q) begin
            gpu_state_q <= GPU_COLLECT;
          end
        end

        GPU_COLLECT: begin
          if (kernel_gpu_preks_valid_w && kernel_gpu_preks_ready_w) begin
            gpu_preks_mem[gpu_preks_count_q] <= kernel_gpu_preks_data_w;
            if (kernel_gpu_preks_last_w) begin
              gpu_preks_count_latched_q <= gpu_preks_count_q + 1'b1;
              gpu_state_q               <= GPU_EXEC;
            end
            gpu_preks_count_q <= gpu_preks_count_q + 1'b1;
          end
        end

        GPU_EXEC: begin
          for (int i = 0; i < GPU_RESULT_LEN; i++) begin
            if (gpu_preks_count_latched_q != 0) begin
              if (i < gpu_preks_count_latched_q)
                gpu_result_mem[i] <= gpu_preks_mem[i];
              else
                gpu_result_mem[i] <= gpu_preks_mem[gpu_preks_count_latched_q-1];
            end else begin
              gpu_result_mem[i] <= '0;
            end
          end
          gpu_result_ptr_q <= '0;
          gpu_state_q      <= GPU_STREAM;
        end

        GPU_STREAM: begin
          kernel_gpu_result_valid_w <= 1'b1;
          kernel_gpu_result_data_w  <= gpu_result_mem[gpu_result_ptr_q];
          kernel_gpu_result_last_w  <= (gpu_result_ptr_q == GPU_RESULT_LEN-1);
          if (kernel_gpu_result_ready_w) begin
            if (kernel_gpu_result_last_w) begin
              gpu_state_q              <= GPU_WAIT;
              gpu_result_ptr_q         <= '0;
              gpu_result_streaming_q   <= 1'b0;
            end else begin
              gpu_result_ptr_q         <= gpu_result_ptr_q + 1'b1;
              gpu_result_streaming_q   <= 1'b1;
            end
          end
        end

        GPU_WAIT: begin
          if (!active_desc_valid_int) begin
            gpu_state_q <= GPU_IDLE;
          end
        end

        default: gpu_state_q <= GPU_IDLE;
      endcase
    end
  end
`else
  assign kernel_gpu_preks_ready_w = (gpu_state_q == GPU_COLLECT);
  assign gpu_woks_link_if.preks_valid = (gpu_state_q == GPU_EXEC) &&
                                        (gpu_send_idx_q <= gpu_preks_last_idx_q);
  assign gpu_woks_link_if.preks_data  = (gpu_state_q == GPU_EXEC)
                                      ? gpu_preks_mem[gpu_send_idx_q]
                                      : '0;
  assign gpu_woks_link_if.preks_last  = (gpu_state_q == GPU_EXEC) &&
                                        (gpu_send_idx_q == gpu_preks_last_idx_q);
  assign gpu_woks_link_if.result_ready = kernel_gpu_result_ready_w
                                       && !gpu_result_buf_valid_q;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      gpu_state_q                 <= GPU_IDLE;
      gpu_preks_count_q           <= '0;
      gpu_preks_count_latched_q   <= '0;
      gpu_preks_last_idx_q        <= '0;
      gpu_send_idx_q              <= '0;
      gpu_result_ptr_q            <= '0;
      gpu_result_streaming_q      <= 1'b0;
    end else begin
      case (gpu_state_q)
        GPU_IDLE: begin
          gpu_preks_count_q         <= '0;
          gpu_preks_count_latched_q <= '0;
          gpu_preks_last_idx_q      <= '0;
          gpu_send_idx_q            <= '0;
          gpu_result_ptr_q          <= '0;
          gpu_result_streaming_q    <= 1'b0;
          if (active_desc_valid_int && gpu_woks_mode_active_q) begin
            $display("[WRAPPER][GPU] GPU WoKS mode active for descriptor cmd_id=0x%0h",
                     active_desc_int.cmd_id);
            gpu_state_q <= GPU_COLLECT;
          end
        end

        GPU_COLLECT: begin
          if (kernel_gpu_preks_valid_w && kernel_gpu_preks_ready_w) begin
            gpu_preks_mem[gpu_preks_count_q] <= kernel_gpu_preks_data_w;
            $display("[WRAPPER][GPU] Collecting Pre-KS idx=%0d data=0x%0h last=%0b",
                     gpu_preks_count_q, kernel_gpu_preks_data_w, kernel_gpu_preks_last_w);
            if (kernel_gpu_preks_last_w) begin
              gpu_preks_last_idx_q       <= gpu_preks_count_q;
              gpu_preks_count_latched_q  <= gpu_preks_count_q + 1'b1;
              $display("[WRAPPER][GPU] Captured %0d Pre-KS words for GPU WoKS mode",
                       gpu_preks_count_q + 1);
              gpu_state_q                <= GPU_EXEC;
            end
            gpu_preks_count_q <= gpu_preks_count_q + 1'b1;
          end
        end

        GPU_EXEC: begin
          if (gpu_woks_link_if.preks_valid && gpu_woks_link_if.preks_ready) begin
            if (gpu_send_idx_q == '0) begin
              $display("[WRAPPER][GPU] Pre-KS stream → GPU started (total=%0d)",
                       gpu_preks_count_latched_q);
            end
            if (gpu_send_idx_q == gpu_preks_last_idx_q) begin
              gpu_send_idx_q            <= '0;
              gpu_result_ptr_q          <= '0;
              gpu_result_streaming_q    <= 1'b0;
              gpu_state_q               <= GPU_STREAM;
              $display("[WRAPPER][GPU] Pre-KS stream → GPU completed (last idx=%0d)",
                       gpu_preks_last_idx_q);
            end else begin
              gpu_send_idx_q <= gpu_send_idx_q + 1'b1;
            end
          end
        end

        GPU_STREAM: begin
          if (gpu_woks_link_if.result_valid && kernel_gpu_result_ready_w) begin
            if (gpu_result_ptr_q == '0) begin
              $display("[WRAPPER][GPU] GPU WoKS result stream started");
            end
            if (gpu_result_ptr_q < GPU_RESULT_LEN) begin
              gpu_result_mem[gpu_result_ptr_q] <= gpu_woks_link_if.result_data;
            end
            if (gpu_woks_link_if.result_last) begin
              gpu_state_q              <= GPU_WAIT;
              gpu_result_ptr_q         <= '0;
              gpu_result_streaming_q   <= 1'b0;
              $display("[WRAPPER][GPU] GPU WoKS result stream completed");
            end else begin
              gpu_result_ptr_q         <= gpu_result_ptr_q + 1'b1;
              gpu_result_streaming_q   <= 1'b1;
            end
          end
        end

        GPU_WAIT: begin
          if (!active_desc_valid_int) begin
            gpu_state_q <= GPU_IDLE;
          end
        end

        default: gpu_state_q <= GPU_IDLE;
      endcase
    end
  end

  assign kernel_gpu_result_valid_w = gpu_result_buf_valid_q;
  assign kernel_gpu_result_data_w  = gpu_result_buf_data_q;
  assign kernel_gpu_result_last_w  = gpu_result_buf_last_q;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      gpu_result_buf_valid_q <= 1'b0;
      gpu_result_buf_data_q  <= '0;
      gpu_result_buf_last_q  <= 1'b0;
    end else begin
      if (gpu_result_buf_valid_q && kernel_gpu_result_ready_w) begin
        gpu_result_buf_valid_q <= 1'b0;
      end

      if (gpu_woks_link_if.result_valid
          && kernel_gpu_result_ready_w
          && !gpu_result_buf_valid_q) begin
        gpu_result_buf_data_q  <= gpu_woks_link_if.result_data;
        gpu_result_buf_last_q  <= gpu_woks_link_if.result_last;
        gpu_result_buf_valid_q <= 1'b1;
      end
    end
  end
`endif

  logic [1:0]               operation_mode_q;
  logic [63:0]              bsk_base_addr;
  logic [31:0]              bsk_stride_bytes;
  logic [63:0]              ksk_base_addr;
  logic [31:0]              ksk_stride_bytes;
  logic [63:0]              glwe_base_addr;
  logic [31:0]              glwe_stride_bytes;
  logic [KSK_PC-1:0][31:0]  ksk_mem_addr_int;
  logic [KSK_PC-1:0][31:0]  ksk_mem_addr_mux;
  logic                     ksk_mem_avail_int;
  logic                     ksk_mem_avail_mux;
  logic                     ksk_stride_zero;
  logic                     ksk_asset_ready_q;
  logic                     glwe_stride_zero;
  logic                     cfg_param_error_q;
  logic                     cfg_param_error;
  localparam int            BSK_TOTAL_ELEMS = BSK_PC * R;
  localparam int            KSK_TOTAL_ELEMS = LBX * LBY * LBZ;
  logic [BSK_TOTAL_ELEMS-1:0][MOD_Q_W-1:0] bsk_data_flat;
  logic [BSK_PC-1:0][R-1:0][MOD_Q_W-1:0] bsk_service_data_int;
  logic                     bsk_loader_error;
  logic [31:0]              bsk_axi_araddr_w;
  logic [7:0]               bsk_axi_arlen_w;
  logic [2:0]               bsk_axi_arsize_w;
  logic [1:0]               bsk_axi_arburst_w;
  logic                     bsk_axi_arvalid_w;
  logic                     bsk_axi_arready_w;
  logic [63:0]              bsk_axi_rdata_w;
  logic [1:0]               bsk_axi_rresp_w;
  logic                     bsk_axi_rlast_w;
  logic                     bsk_axi_rvalid_w;
  logic                     bsk_axi_rready_w;
  logic                     bsk_service_req_vld_int;
  logic                     bsk_service_req_rdy_int;
  logic [BSK_BATCH_ID_W-1:0] bsk_service_batch_id_int;
  logic                     bsk_service_data_avail_int;
  logic [BSK_PC-1:0][R-1:0][MOD_Q_W-1:0] bsk_service_data_q;
  logic                     bsk_service_data_valid_q;
  logic                     loader_priority_mode_cfg;
  logic [3:0]               loader_bsk_weight_cfg;
  logic [3:0]               loader_ksk_weight_cfg;
  logic [LOADER_OUTSTANDING_BITS-1:0] loader_bsk_max_outstanding_cfg;
  logic [LOADER_OUTSTANDING_BITS-1:0] loader_ksk_max_outstanding_cfg;
  logic                     bsk_req_ready_w;
  logic                     bsk_issue_valid_w;
  logic [BSK_BATCH_ID_W-1:0] bsk_issue_index_w;
  logic [LOADER_OUTSTANDING_BITS-1:0] bsk_outstanding_w;
  logic [LOADER_OUTSTANDING_BITS-1:0] ksk_outstanding_w;
  logic                     bsk_throttle_w;
  logic                     ksk_throttle_w;
  logic [AXI_ID_W-1:0]      desc_axi_awid_unused;
  logic [AXI_ADDR_W-1:0]    desc_axi_awaddr_unused;
  logic [7:0]               desc_axi_awlen_unused;
  logic [2:0]               desc_axi_awsize_unused;
  logic [1:0]               desc_axi_awburst_unused;
  logic [3:0]               desc_axi_awcache_unused;
  logic [2:0]               desc_axi_awprot_unused;
  logic                     desc_axi_awvalid_unused;
  logic [AXI_DATA_W-1:0]    desc_axi_wdata_unused;
  logic [(AXI_DATA_W/8)-1:0] desc_axi_wstrb_unused;
  logic                     desc_axi_wlast_unused;
  logic                     desc_axi_wvalid_unused;
  logic                     desc_axi_bready_unused;

  logic [AXI_ID_W-1:0]      status_axi_awid;
  logic [AXI_ADDR_W-1:0]    status_axi_awaddr;
  logic [7:0]               status_axi_awlen;
  logic [2:0]               status_axi_awsize;
  logic [1:0]               status_axi_awburst;
  logic [3:0]               status_axi_awcache;
  logic [2:0]               status_axi_awprot;
  logic                     status_axi_awvalid;
  logic [AXI_DATA_W-1:0]    status_axi_wdata;
  logic [(AXI_DATA_W/8)-1:0] status_axi_wstrb;
  logic                     status_axi_wlast;
  logic                     status_axi_wvalid;
  logic                     status_axi_bready;

  logic [63:0]              status_cycle_counter_q;
  logic                     bsk_loader_req_ready_w;
  logic                     bsk_req_fire;
  logic                     bsk_loader_data_vld;
  logic                     ksk_prefetch_pending_q;
  logic                     ksk_prefetch_active_q;
  logic [31:0]              ksk_prefetch_addr_q;
  logic                     ksk_prefetch_addr_valid_q;
  logic                     ksk_prefetch_req_vld;
  logic                     ksk_prefetch_req_ready;
  logic                     ksk_prefetch_req_fire;
  logic                     ksk_loader_req_ready_w;
  logic                     ksk_issue_valid_w;
  logic [3:0]               ksk_issue_index_w;
  logic                     ksk_loader_data_vld;
  logic [KSK_TOTAL_ELEMS-1:0][MOD_KSK_W-1:0] ksk_loader_data;
  logic                     ksk_loader_error;
  logic                     ksk_asset_valid_int;
  logic                     ksk_asset_ready_int;
  logic [KSK_TOTAL_ELEMS-1:0][MOD_KSK_W-1:0] ksk_asset_buffer_q;
  logic                     kernel_ksk_asset_ready_w;
  logic [31:0]              ksk_axi_araddr_w;
  logic [7:0]               ksk_axi_arlen_w;
  logic [2:0]               ksk_axi_arsize_w;
  logic [1:0]               ksk_axi_arburst_w;
  logic                     ksk_axi_arvalid_w;
  logic                     ksk_axi_arready_w;
  logic [63:0]              ksk_axi_rdata_w;
  logic [1:0]               ksk_axi_rresp_w;
  logic                     ksk_axi_rlast_w;
  logic                     ksk_axi_rvalid_w;
  logic                     ksk_axi_rready_w;
  // GLWE asset prefetch handshake (loader → unified kernel)
  logic                     glwe_asset_valid_int;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] glwe_asset_data_int;
  logic                     kernel_glwe_asset_ready_w;
  logic                     glwe_prefetch_pending_q;
  logic                     glwe_prefetch_active_q;
  logic [31:0]              glwe_prefetch_addr_q;
  logic                     glwe_prefetch_req_vld;
  logic                     glwe_prefetch_req_fire;
  logic                     glwe_prefetch_req_ready;
  logic                     glwe_loader_data_vld;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] glwe_loader_data;
  logic                     glwe_loader_error;
  logic                     glwe_asset_ready_int;
  logic                     kernel_glwe_asset_req_w;
  logic                     glwe_prefetch_addr_valid_q;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] glwe_asset_buffer_q;
  logic [31:0]              glwe_axi_araddr_w;
  logic [7:0]               glwe_axi_arlen_w;
  logic [2:0]               glwe_axi_arsize_w;
  logic [1:0]               glwe_axi_arburst_w;
  logic                     glwe_axi_arvalid_w;
  logic                     glwe_axi_arready_w;
  logic [63:0]              glwe_axi_rdata_w;
  logic [1:0]               glwe_axi_rresp_w;
  logic                     glwe_axi_rlast_w;
  logic                     glwe_axi_rvalid_w;
  logic                     glwe_axi_rready_w;

  vp_pbs_inst_t             kernel_inst_w;
  logic                     kernel_inst_vld_w;
  logic                     kernel_inst_rdy_w;
  vp_pbs_response_t         kernel_resp_w;

  // -------------------------------------------------------------------------
  // AXI-Lite control block
  openssd_wop_axi_lite_ctrl #(
    .AXIL_ADDR_W (AXIL_ADDR_W),
    .AXIL_DATA_W (AXIL_DATA_W)
  ) u_axil_ctrl (
    .clk               (clk),
    .rst_n             (s_rst_n),
    .s_axil_awaddr     (s_axil_awaddr),
    .s_axil_awvalid    (s_axil_awvalid),
    .s_axil_awready    (s_axil_awready),
    .s_axil_wdata      (s_axil_wdata),
    .s_axil_wstrb      (s_axil_wstrb),
    .s_axil_wvalid     (s_axil_wvalid),
    .s_axil_wready     (s_axil_wready),
    .s_axil_bresp      (s_axil_bresp),
    .s_axil_bvalid     (s_axil_bvalid),
    .s_axil_bready     (s_axil_bready),
    .s_axil_araddr     (s_axil_araddr),
    .s_axil_arvalid    (s_axil_arvalid),
    .s_axil_arready    (s_axil_arready),
    .s_axil_rdata      (s_axil_rdata),
    .s_axil_rresp      (s_axil_rresp),
    .s_axil_rvalid     (s_axil_rvalid),
    .s_axil_rready     (s_axil_rready),
    .busy_i            (ctrl_busy),
    .error_i           (ctrl_error),
    .error_vector_i    (error_vector_bus),
    .gpu_ready_i       (gpu_status_ready_mux),
    .doorbell_ready_i  (doorbell_ready_w),
    .last_cmd_id_i     (last_cmd_id_q),
    .done_evt_i        (done_evt),
    .error_evt_i       (error_evt),
    .doorbell_pulse_o  (doorbell_pulse),
    .doorbell_reject_o (doorbell_reject_pulse),
    .mode_o            (mode_sel),
    .cmd_id_o          (cmd_id_sel),
    .desc_ptr_o        (desc_ptr_sel),
    .irq_mask_o        (irq_mask_dummy),
    .irq_o             (irq_o),
    .bsk_base_addr_o   (bsk_base_addr),
    .bsk_stride_bytes_o(bsk_stride_bytes),
    .ksk_base_addr_o   (ksk_base_addr),
    .ksk_stride_bytes_o(ksk_stride_bytes),
    .glwe_base_addr_o  (glwe_base_addr),
    .glwe_stride_bytes_o(glwe_stride_bytes),
    .loader_priority_mode_o       (loader_priority_mode_cfg),
    .loader_bsk_weight_o          (loader_bsk_weight_cfg),
    .loader_ksk_weight_o          (loader_ksk_weight_cfg),
    .loader_bsk_max_outstanding_o (loader_bsk_max_outstanding_cfg),
    .loader_ksk_max_outstanding_o (loader_ksk_max_outstanding_cfg),
    .desc_ack_pulse_o             (ctrl_desc_ack_w)
  );

  assign bsk_service_data_int    = bsk_service_data_q;
  assign bsk_service_data_avail_int = bsk_service_data_valid_q;

  // Capture loader output into local buffer so requests can be throttled safely
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      bsk_service_data_q      <= '0;
      bsk_service_data_valid_q<= 1'b0;
    end else begin
      if (bsk_loader_data_vld) begin
        for (int pc = 0; pc < BSK_PC; pc++) begin
          for (int rr = 0; rr < R; rr++) begin
            if (((pc * R) + rr) < BSK_TOTAL_ELEMS) begin
              bsk_service_data_q[pc][rr] <= bsk_data_flat[(pc * R) + rr];
            end else begin
              bsk_service_data_q[pc][rr] <= '0;
            end
          end
        end
        bsk_service_data_valid_q <= 1'b1;
      end else if (bsk_req_fire) begin
        bsk_service_data_valid_q <= 1'b0;
      end else if (desc_valid && desc_ready) begin
        bsk_service_data_valid_q <= 1'b0;
      end
    end
  end

  assign bsk_req_fire = bsk_service_req_vld_int && bsk_service_req_rdy_int;

  // Expose internal handshake signals for optional external monitoring
  assign bsk_service_req_vld = bsk_service_req_vld_int;
  assign bsk_service_batch_id = bsk_service_batch_id_int;

  // Loader arbitration between BSK / KSK channels
  openssd_wop_loader_arbiter #(
    .BSK_INDEX_W      (BSK_BATCH_ID_W),
    .KSK_INDEX_W      (4),
    .OUTSTANDING_BITS (LOADER_OUTSTANDING_BITS)
  ) u_loader_arbiter (
    .clk                        (clk),
    .rst_n                      (s_rst_n),
    .cfg_priority_mode_i        (loader_priority_mode_cfg),
    .cfg_bsk_weight_i           (loader_bsk_weight_cfg),
    .cfg_ksk_weight_i           (loader_ksk_weight_cfg),
    .cfg_bsk_max_outstanding_i  (loader_bsk_max_outstanding_cfg),
    .cfg_ksk_max_outstanding_i  (loader_ksk_max_outstanding_cfg),
    .bsk_req_valid_i            (bsk_service_req_vld_int),
    .bsk_req_ready_o            (bsk_req_ready_w),
    .bsk_req_index_i            (bsk_service_batch_id_int),
    .ksk_req_valid_i            (ksk_prefetch_req_vld),
    .ksk_req_ready_o            (ksk_prefetch_req_ready),
    .ksk_req_index_i            (4'd0),
    .bsk_issue_valid_o          (bsk_issue_valid_w),
    .bsk_issue_ready_i          (bsk_loader_req_ready_w),
    .bsk_issue_index_o          (bsk_issue_index_w),
    .ksk_issue_valid_o          (ksk_issue_valid_w),
    .ksk_issue_ready_i          (ksk_loader_req_ready_w),
    .ksk_issue_index_o          (ksk_issue_index_w),
    .bsk_complete_i             (bsk_loader_data_vld),
    .ksk_complete_i             (ksk_loader_data_vld),
    .bsk_outstanding_o          (bsk_outstanding_w),
    .ksk_outstanding_o          (ksk_outstanding_w),
    .bsk_throttle_o             (bsk_throttle_w),
    .ksk_throttle_o             (ksk_throttle_w)
  );

  // Map loader AXI signals to top-level BSK master port (index 0 only)
  assign bsk_axi_arready_w = m_axi4_bsk_arready[0];
  assign bsk_axi_rdata_w   = m_axi4_bsk_rdata[0];
  assign bsk_axi_rresp_w   = m_axi4_bsk_rresp[0];
  assign bsk_axi_rlast_w   = m_axi4_bsk_rlast[0];
  assign bsk_axi_rvalid_w  = m_axi4_bsk_rvalid[0];

  generate
    for (genvar bi = 0; bi < BSK_PC; bi++) begin : gen_bsk_axi_ports
      assign m_axi4_bsk_arid[bi]    = '0;
      assign m_axi4_bsk_araddr[bi]  = (bi == 0) ? bsk_axi_araddr_w : '0;
      assign m_axi4_bsk_arlen[bi]   = (bi == 0) ? bsk_axi_arlen_w  : '0;
      assign m_axi4_bsk_arsize[bi]  = (bi == 0) ? bsk_axi_arsize_w : '0;
      assign m_axi4_bsk_arburst[bi] = (bi == 0) ? bsk_axi_arburst_w: '0;
      assign m_axi4_bsk_arvalid[bi] = (bi == 0) ? bsk_axi_arvalid_w: 1'b0;
      assign m_axi4_bsk_rready[bi]  = (bi == 0) ? bsk_axi_rready_w : 1'b0;
    end
  endgenerate

  // -------------------------------------------------------------------------
  // BSK resource loader (AXI read → buffered service interface)
  openssd_wop_stream_loader #(
    .AXI_ADDR_W (32),
    .AXI_DATA_W (64),
    .INDEX_W    (BSK_BATCH_ID_W),
    .ELEM_W     (MOD_Q_W),
    .ELEM_COUNT (BSK_TOTAL_ELEMS)
  ) u_bsk_loader (
    .clk                 (clk),
    .rst_n               (s_rst_n),
    .req_valid_i         (bsk_issue_valid_w),
    .req_ready_o         (bsk_loader_req_ready_w),
    .req_index_i         (bsk_issue_index_w),
    .req_override_addr_i (1'b0),
    .override_addr_i     (32'h0),
    .base_addr_i         (bsk_base_addr[31:0]),
    .stride_bytes_i      (bsk_stride_bytes),
    .data_valid_o        (bsk_loader_data_vld),
    .data_o              (bsk_data_flat),
    .error_o             (bsk_loader_error),
    .m_axi_araddr        (bsk_axi_araddr_w),
    .m_axi_arlen         (bsk_axi_arlen_w),
    .m_axi_arsize        (bsk_axi_arsize_w),
    .m_axi_arburst       (bsk_axi_arburst_w),
    .m_axi_arvalid       (bsk_axi_arvalid_w),
    .m_axi_arready       (bsk_axi_arready_w),
    .m_axi_rdata         (bsk_axi_rdata_w),
    .m_axi_rresp         (bsk_axi_rresp_w),
    .m_axi_rlast         (bsk_axi_rlast_w),
    .m_axi_rvalid        (bsk_axi_rvalid_w),
    .m_axi_rready        (bsk_axi_rready_w)
  );

  assign bsk_service_req_rdy_int = bsk_req_ready_w;

`ifndef SYNTHESIS
`ifdef SIMULATION
  // Debug tracing for BSK loader activity
  always_ff @(posedge clk) begin
    if (bsk_service_req_vld_int && bsk_service_req_rdy_int) begin
      $display("[%0t][WRP_ARB_DBG] BSK req accept batch=%0d outstanding=%0d throttle=%0b kernel_throttle=%0b",
               $time, bsk_service_batch_id_int, bsk_outstanding_w, bsk_throttle_w, kernel_bsk_throttle_w);
    end
    if (bsk_loader_data_vld) begin
      $display("[%0t][WRP_ARB_DBG] BSK data ready (loader_vld=1)", $time);
    end
    if (bsk_throttle_w) begin
      $display("[%0t][WRP_ARB_DBG] BSK throttled outstanding=%0d limit_hit=1 kernel_throttle=%0b",
               $time, bsk_outstanding_w, kernel_bsk_throttle_w);
    end
  end
`endif
`endif

  // -------------------------------------------------------------------------
  // KSK resource loader (descriptor-triggered prefetch)
  assign ksk_prefetch_req_vld  = ksk_prefetch_pending_q && !ksk_prefetch_active_q;
  assign ksk_prefetch_req_fire = ksk_prefetch_req_vld && ksk_prefetch_req_ready;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      ksk_prefetch_pending_q    <= 1'b0;
      ksk_prefetch_active_q     <= 1'b0;
      ksk_prefetch_addr_q       <= '0;
      ksk_prefetch_addr_valid_q <= 1'b0;
    end else begin
      if (desc_valid && desc_ready) begin
        ksk_prefetch_addr_q       <= ksk_base_addr[31:0];
        ksk_prefetch_addr_valid_q <= !ksk_stride_zero;
        ksk_prefetch_pending_q    <= 1'b0;
        ksk_prefetch_active_q     <= 1'b0;
      end else begin
        if (!ksk_asset_valid_int && ksk_prefetch_addr_valid_q &&
            !ksk_prefetch_pending_q && !ksk_prefetch_active_q &&
            !ksk_loader_data_vld) begin
          ksk_prefetch_pending_q <= 1'b1;
        end else if (ksk_prefetch_req_fire) begin
          ksk_prefetch_pending_q <= 1'b0;
          ksk_prefetch_active_q  <= 1'b1;
        end
        if (ksk_loader_data_vld) begin
          ksk_prefetch_active_q <= 1'b0;
        end
      end

      if (reset_ksk_cache) begin
        ksk_prefetch_pending_q <= ksk_prefetch_addr_valid_q && !ksk_loader_data_vld;
        ksk_prefetch_active_q  <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      ksk_asset_valid_int <= 1'b0;
      ksk_asset_buffer_q  <= '0;
    end else begin
      if (ksk_loader_data_vld) begin
        ksk_asset_buffer_q  <= ksk_loader_data;
        ksk_asset_valid_int <= 1'b1;
      end else if (ksk_asset_ready_int) begin
        ksk_asset_valid_int <= 1'b0;
      end else if (desc_valid && desc_ready) begin
        ksk_asset_valid_int <= 1'b0;
      end else if (reset_ksk_cache) begin
        ksk_asset_valid_int <= 1'b0;
      end
    end
  end

  assign ksk_asset_ready_int = ksk_asset_valid_int && kernel_ksk_asset_ready_w;

  openssd_wop_stream_loader #(
    .AXI_ADDR_W (32),
    .AXI_DATA_W (64),
    .INDEX_W    (4),
    .ELEM_W     (MOD_KSK_W),
    .ELEM_COUNT (KSK_TOTAL_ELEMS)
  ) u_ksk_loader (
    .clk                 (clk),
    .rst_n               (s_rst_n),
    .req_valid_i         (ksk_issue_valid_w),
    .req_ready_o         (ksk_loader_req_ready_w),
    .req_index_i         (ksk_issue_index_w),
    .req_override_addr_i (1'b1),
    .override_addr_i     (ksk_prefetch_addr_q),
    .base_addr_i         (ksk_base_addr[31:0]),
    .stride_bytes_i      (ksk_stride_bytes),
    .data_valid_o        (ksk_loader_data_vld),
    .data_o              (ksk_loader_data),
    .error_o             (ksk_loader_error),
    .m_axi_araddr        (ksk_axi_araddr_w),
    .m_axi_arlen         (ksk_axi_arlen_w),
    .m_axi_arsize        (ksk_axi_arsize_w),
    .m_axi_arburst       (ksk_axi_arburst_w),
    .m_axi_arvalid       (ksk_axi_arvalid_w),
    .m_axi_arready       (ksk_axi_arready_w),
    .m_axi_rdata         (ksk_axi_rdata_w),
    .m_axi_rresp         (ksk_axi_rresp_w),
    .m_axi_rlast         (ksk_axi_rlast_w),
    .m_axi_rvalid        (ksk_axi_rvalid_w),
    .m_axi_rready        (ksk_axi_rready_w)
  );

`ifndef SYNTHESIS
`ifdef SIMULATION
  // Debug tracing for KSK loader activity
  always_ff @(posedge clk) begin
    if (ksk_prefetch_req_vld && ksk_prefetch_req_ready) begin
      $display("[%0t][WRP_ARB_DBG] KSK req accept addr=0x%08x outstanding=%0d throttle=%0b kernel_throttle=%0b",
               $time, ksk_prefetch_addr_q, ksk_outstanding_w, ksk_throttle_w, kernel_ksk_throttle_w);
    end
    if (ksk_loader_data_vld) begin
      $display("[%0t][WRP_ARB_DBG] KSK data loaded", $time);
    end
    if (ksk_throttle_w) begin
      $display("[%0t][WRP_ARB_DBG] KSK throttled outstanding=%0d limit_hit=1 kernel_throttle=%0b",
               $time, ksk_outstanding_w, kernel_ksk_throttle_w);
    end
  end
`endif
`endif

  assign ksk_axi_arready_w = m_axi4_ksk_arready[0];
  assign ksk_axi_rdata_w   = m_axi4_ksk_rdata[0];
  assign ksk_axi_rresp_w   = m_axi4_ksk_rresp[0];
  assign ksk_axi_rlast_w   = m_axi4_ksk_rlast[0];
  assign ksk_axi_rvalid_w  = m_axi4_ksk_rvalid[0];

  generate
    for (genvar ki = 0; ki < KSK_PC; ki++) begin : gen_ksk_axi_ports
      assign m_axi4_ksk_arid[ki]    = '0;
      assign m_axi4_ksk_araddr[ki]  = (ki == 0) ? ksk_axi_araddr_w  : '0;
      assign m_axi4_ksk_arlen[ki]   = (ki == 0) ? ksk_axi_arlen_w   : '0;
      assign m_axi4_ksk_arsize[ki]  = (ki == 0) ? ksk_axi_arsize_w  : '0;
      assign m_axi4_ksk_arburst[ki] = (ki == 0) ? ksk_axi_arburst_w : '0;
      assign m_axi4_ksk_arvalid[ki] = (ki == 0) ? ksk_axi_arvalid_w : 1'b0;
      assign m_axi4_ksk_rready[ki]  = (ki == 0) ? ksk_axi_rready_w  : 1'b0;
      assign m_axi4_ksk_arqos[ki]   = 4'h6;
    end
  endgenerate
  assign m_axi4_bsk_arqos = '{default:4'h6};
  assign m_axi4_glwe_arqos = 4'h4;

  // -------------------------------------------------------------------------
  // GLWE asset loader (prefetch TLWE/GLWE resources for unified kernel)
  openssd_wop_stream_loader #(
    .AXI_ADDR_W (32),
    .AXI_DATA_W (64),
    .INDEX_W    (4),
    .ELEM_W     (MOD_Q_W),
    .ELEM_COUNT (REGF_COEF_NB)
  ) u_glwe_loader (
    .clk                 (clk),
    .rst_n               (s_rst_n),
    .req_valid_i         (glwe_prefetch_req_vld),
    .req_ready_o         (glwe_prefetch_req_ready),
    .req_index_i         (4'd0),
    .req_override_addr_i (1'b1),
    .override_addr_i     (glwe_prefetch_addr_q),
    .base_addr_i         (glwe_base_addr[31:0]),
    .stride_bytes_i      (glwe_stride_bytes),
    .data_valid_o        (glwe_loader_data_vld),
    .data_o              (glwe_loader_data),
    .error_o             (glwe_loader_error),
    .m_axi_araddr        (glwe_axi_araddr_w),
    .m_axi_arlen         (glwe_axi_arlen_w),
    .m_axi_arsize        (glwe_axi_arsize_w),
    .m_axi_arburst       (glwe_axi_arburst_w),
    .m_axi_arvalid       (glwe_axi_arvalid_w),
    .m_axi_arready       (glwe_axi_arready_w),
    .m_axi_rdata         (glwe_axi_rdata_w),
    .m_axi_rresp         (glwe_axi_rresp_w),
    .m_axi_rlast         (glwe_axi_rlast_w),
    .m_axi_rvalid        (glwe_axi_rvalid_w),
    .m_axi_rready        (glwe_axi_rready_w)
  );

  // -------------------------------------------------------------------------
  // Derived resource configuration helpers
  assign ksk_stride_zero  = (ksk_stride_bytes == 32'd0);
  assign glwe_stride_zero = (glwe_stride_bytes == 32'd0);
  assign ksk_mem_avail_int = ksk_asset_ready_q;

  // Prefetch control for GLWE loader
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      glwe_prefetch_pending_q     <= 1'b0;
      glwe_prefetch_active_q      <= 1'b0;
      glwe_prefetch_addr_q        <= '0;
      glwe_prefetch_addr_valid_q  <= 1'b0;
    end else begin
      if (desc_valid && desc_ready) begin
        $display("[WRAPPER] Descriptor accepted @%0t mode=%0d cmd_id=0x%0h flags=0x%02h tlwe=0x%016h glwe=0x%016h gpu_shared=0x%016h",
                 $time, desc_payload.mode, desc_payload.cmd_id, desc_payload.flags,
                 desc_payload.tlwe_src_addr, desc_payload.glwe_dst_addr, desc_payload.gpu_shared_addr);
        if (desc_payload.mode == WOP_MODE_CB || desc_payload.mode == WOP_MODE_VP) begin
          glwe_prefetch_addr_q       <= desc_payload.tlwe_src_addr[31:0];
          glwe_prefetch_addr_valid_q <= 1'b1;
        end else begin
          glwe_prefetch_addr_valid_q <= 1'b0;
        end
        glwe_prefetch_pending_q <= 1'b0;
        glwe_prefetch_active_q  <= 1'b0;
      end else begin
        if (((kernel_glwe_asset_req_w) || !USE_KERNEL_GLWE_REQ) &&
            glwe_prefetch_addr_valid_q &&
            !glwe_prefetch_pending_q && !glwe_prefetch_active_q &&
            !glwe_loader_data_vld && !glwe_asset_valid_int) begin
          glwe_prefetch_pending_q <= 1'b1;
        end else if (glwe_prefetch_req_fire) begin
          glwe_prefetch_pending_q <= 1'b0;
          glwe_prefetch_active_q  <= 1'b1;
        end

        if (glwe_loader_data_vld) begin
          glwe_prefetch_active_q <= 1'b0;
        end
      end
    end
  end

  // Buffering of prefetched GLWE assets
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      glwe_asset_valid_int <= 1'b0;
      glwe_asset_buffer_q  <= '0;
    end else begin
      if (glwe_loader_data_vld) begin
        glwe_asset_buffer_q  <= glwe_loader_data;
        glwe_asset_valid_int <= 1'b1;
      end else if ((glwe_asset_ready_int) || (desc_valid && desc_ready)) begin
        glwe_asset_valid_int <= 1'b0;
      end
    end
  end

  assign glwe_asset_data_int = glwe_asset_buffer_q;
  assign glwe_asset_ready_int = glwe_asset_valid_int && kernel_glwe_asset_ready_w;

  assign glwe_asset_valid  = glwe_asset_valid_int;
  assign glwe_asset_data   = glwe_asset_data_int;
  assign glwe_asset_ready  = kernel_glwe_asset_ready_w;
  assign glwe_asset_req    = kernel_glwe_asset_req_w;
  assign glwe_asset_enable = 1'b1;

  // Map GLWE loader AXI wires to top-level interface (single port)
  assign glwe_axi_arready_w = m_axi4_glwe_arready;
  assign glwe_axi_rdata_w   = m_axi4_glwe_rdata;
  assign glwe_axi_rresp_w   = m_axi4_glwe_rresp;
  assign glwe_axi_rlast_w   = m_axi4_glwe_rlast;
  assign glwe_axi_rvalid_w  = m_axi4_glwe_rvalid;
  assign m_axi4_glwe_arid   = 4'h0;
  assign m_axi4_glwe_araddr = glwe_axi_araddr_w;
  assign m_axi4_glwe_arlen  = glwe_axi_arlen_w;
  assign m_axi4_glwe_arsize = glwe_axi_arsize_w;
  assign m_axi4_glwe_arburst= glwe_axi_arburst_w;
  assign m_axi4_glwe_arvalid= glwe_axi_arvalid_w;
  assign m_axi4_glwe_rready = glwe_axi_rready_w;

  assign glwe_prefetch_req_vld  = glwe_prefetch_pending_q && !glwe_prefetch_active_q;
  assign glwe_prefetch_req_fire = glwe_prefetch_req_vld && glwe_prefetch_req_ready;

  always_comb begin
    for (int port = 0; port < KSK_PC; port++) begin
      ksk_mem_addr_int[port] = ksk_base_addr[31:0] + (ksk_stride_bytes * port);
    end
  end

  assign ksk_mem_addr_mux  = ksk_mem_avail ? ksk_mem_addr : ksk_mem_addr_int;
  assign ksk_mem_avail_mux = ksk_mem_avail | ksk_mem_avail_int;

  // -------------------------------------------------------------------------
  // Doorbell staging and DMA start pulse
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      doorbell_pending_q <= 1'b0;
    end else begin
      if (doorbell_pulse) begin
        doorbell_pending_q <= 1'b1;
      end else if (doorbell_start_pulse) begin
        doorbell_pending_q <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      status_fifo_valid_q    <= '0;
      status_fifo_addr_q     <= '{default:'0};
      status_fifo_cmd_q      <= '{default:'0};
      status_fifo_code_q     <= '{default:'0};
      status_fifo_overflow_q <= 1'b0;
    end else begin
      logic [1:0]               next_valid;
      logic [1:0][63:0]         next_addr;
      logic [1:0][15:0]         next_cmd;
      logic [1:0][31:0]         next_code;

      next_valid = status_fifo_valid_q;
      next_addr  = status_fifo_addr_q;
      next_cmd   = status_fifo_cmd_q;
      next_code  = status_fifo_code_q;

      if (status_wr_start) begin
        next_valid[0] = next_valid[1];
        next_addr[0]  = next_addr[1];
        next_cmd[0]   = next_cmd[1];
        next_code[0]  = next_code[1];
        next_valid[1] = 1'b0;
      end

      if (desc_valid && desc_ready) begin
        logic entry_written;
        entry_written = 1'b0;
        if (!next_valid[0]) begin
          next_valid[0] = 1'b1;
          next_addr[0]  = desc_payload.gpu_shared_addr;
          next_cmd[0]   = desc_payload.cmd_id;
          next_code[0]  = WOP_STATUS_PENDING;
          entry_written = 1'b1;
        end else if (!next_valid[1]) begin
          next_valid[1] = 1'b1;
          next_addr[1]  = desc_payload.gpu_shared_addr;
          next_cmd[1]   = desc_payload.cmd_id;
          next_code[1]  = WOP_STATUS_PENDING;
          entry_written = 1'b1;
        end
        if (!entry_written) begin
          status_fifo_overflow_q <= 1'b1;
        end
      end

      if (done_evt && active_desc_valid_int) begin
        if (!next_valid[0]) begin
          next_valid[0] = 1'b1;
          next_addr[0]  = active_desc_int.gpu_shared_addr;
          next_cmd[0]   = active_desc_int.cmd_id;
          next_code[0]  = WOP_STATUS_COMPLETE;
        end else if (!next_valid[1]) begin
          next_valid[1] = 1'b1;
          next_addr[1]  = active_desc_int.gpu_shared_addr;
          next_cmd[1]   = active_desc_int.cmd_id;
          next_code[1]  = WOP_STATUS_COMPLETE;
        end else begin
          status_fifo_overflow_q <= 1'b1;
        end
      end

      status_fifo_valid_q <= next_valid;
      status_fifo_addr_q  <= next_addr;
      status_fifo_cmd_q   <= next_cmd;
      status_fifo_code_q  <= next_code;

      if (doorbell_pulse) begin
        status_fifo_overflow_q <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      status_cycle_counter_q <= '0;
    end else begin
      status_cycle_counter_q <= status_cycle_counter_q + 1'b1;
    end
  end

  assign status_wr_fault = status_wr_error | status_fifo_overflow_q;
  assign dma_error       = desc_dma_error | status_wr_fault;

  assign doorbell_ready_w     = (!ctrl_busy) && gpu_status_ready_mux;
  assign doorbell_reject_evt  = doorbell_reject_pulse;
  assign doorbell_start_pulse = doorbell_pending_q && desc_ready && !dma_busy && !gpu_pending;
  assign dma_start            = doorbell_start_pulse;

  assign status_wr_start = (!status_wr_busy) && status_fifo_valid_q[0];
  assign status_wr_addr  = status_fifo_valid_q[0] ? status_fifo_addr_q[0] : 64'd0;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      completion_ack_pending_q <= 1'b0;
    end else begin
      if (internal_desc_ack_pulse || !active_desc_valid_int) begin
        completion_ack_pending_q <= 1'b0;
      end else if (done_evt && active_desc_valid_int) begin
        completion_ack_pending_q <= 1'b1;
      end
    end
  end

  assign status_wr_complete_start = status_wr_start
                                  && status_fifo_valid_q[0]
                                  && (status_fifo_code_q[0] == WOP_STATUS_COMPLETE);

  assign internal_desc_ack_pulse = completion_ack_pending_q
                                 & status_wr_complete_start
                                 & active_desc_valid_int;

`ifdef SIM_WOP_AUTO_DESC_ACK
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      sim_auto_ack_cnt_q     <= '0;
      sim_auto_ack_pending_q <= 1'b0;
      sim_auto_desc_ack_pulse_q <= 1'b0;
    end else begin
      sim_auto_desc_ack_pulse_q <= 1'b0;

      if (desc_valid && desc_ready) begin
        sim_auto_ack_pending_q <= 1'b1;
        sim_auto_ack_cnt_q     <= SIM_AUTO_ACK_CNT_W'(`SIM_WOP_AUTO_ACK_DELAY);
        $display("[SIM_WOP_AUTO_DESC_ACK] descriptor accepted at time=%0t (mode=%0d)", $time, desc_payload.mode);
      end else if (sim_auto_ack_pending_q) begin
        if (sim_auto_ack_cnt_q != '0) begin
          sim_auto_ack_cnt_q <= sim_auto_ack_cnt_q - {{(SIM_AUTO_ACK_CNT_W-1){1'b0}}, 1'b1};
        end else begin
          sim_auto_desc_ack_pulse_q <= 1'b1;
          sim_auto_ack_pending_q    <= 1'b0;
          $display("[SIM_WOP_AUTO_DESC_ACK] auto ACK pulse at time=%0t", $time);
        end
      end
    end
  end

  assign sim_auto_desc_ack_pulse = sim_auto_desc_ack_pulse_q;
`endif

  always_comb begin
    logic [31:0] status_error_code_field;
    logic [31:0] status_reserved1_field;
    logic [15:0] status_reserved0_field;

    status_error_code_field = 32'd0;
    status_reserved1_field  = 32'd0;
    status_reserved0_field  = 16'd0;

    if (status_fifo_valid_q[0]
        && (status_fifo_code_q[0] == WOP_STATUS_COMPLETE)
        && ftl_status_valid_q) begin
      status_error_code_field = {ftl_status_tlwe_total_q, ftl_status_glwe_total_q};
      status_reserved1_field  = {ftl_status_tlwe_mask_q, ftl_status_glwe_mask_q};
      status_reserved0_field  = ftl_status_gpu_flags_q;
    end

    status_payload_int = make_result_status(
      status_fifo_valid_q[0] ? status_fifo_cmd_q[0]  : 16'd0,
      status_fifo_valid_q[0] ? status_fifo_code_q[0] : WOP_STATUS_PENDING,
      32'd0,
      64'd0,
      status_cycle_counter_q);
    status_payload_int.error_code = status_error_code_field;
    status_payload_int.reserved1  = status_reserved1_field;
    status_payload_int.reserved0  = status_reserved0_field;
  end

  assign status_wr_data = pack_result_status(status_payload_int);

  // -------------------------------------------------------------------------
    // Latch command parameters when a doorbell is accepted
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      mode_latched_q <= WOP_MODE_VP;
      cmd_id_q       <= '0;
      desc_ptr_q     <= '0;
    end else if (doorbell_pulse) begin
      mode_latched_q <= mode_sel;
      cmd_id_q       <= cmd_id_sel;
      desc_ptr_q     <= desc_ptr_sel;
    end
  end

// Descriptor DMA fetcher
  openssd_wop_dma_descriptor #(
    .AXI_ADDR_W (AXI_ADDR_W),
    .AXI_DATA_W (AXI_DATA_W),
    .AXI_ID_W   (AXI_ID_W)
  ) u_dma_desc (
    .clk            (clk),
    .rst_n          (s_rst_n),
    .start_i        (dma_start),
    .desc_ptr_i     (desc_ptr_q),
    .cmd_id_i       (cmd_id_q),
    .busy_o         (dma_busy),
    .error_o        (desc_dma_error),
    .desc_valid_o   (desc_valid),
    .desc_o         (desc_payload),
    .desc_ready_i   (desc_ready),
    .m_axi_awid     (desc_axi_awid_unused),
    .m_axi_awaddr   (desc_axi_awaddr_unused),
    .m_axi_awlen    (desc_axi_awlen_unused),
    .m_axi_awsize   (desc_axi_awsize_unused),
    .m_axi_awburst  (desc_axi_awburst_unused),
    .m_axi_awcache  (desc_axi_awcache_unused),
    .m_axi_awprot   (desc_axi_awprot_unused),
    .m_axi_awvalid  (desc_axi_awvalid_unused),
    .m_axi_awready  (m_axi_awready),
    .m_axi_wdata    (desc_axi_wdata_unused),
    .m_axi_wstrb    (desc_axi_wstrb_unused),
    .m_axi_wlast    (desc_axi_wlast_unused),
    .m_axi_wvalid   (desc_axi_wvalid_unused),
    .m_axi_wready   (m_axi_wready),
    .m_axi_bid      (m_axi_bid),
    .m_axi_bresp    (m_axi_bresp),
    .m_axi_bvalid   (m_axi_bvalid),
    .m_axi_bready   (desc_axi_bready_unused),
    .m_axi_arid     (m_axi_arid),
    .m_axi_araddr   (m_axi_araddr),
    .m_axi_arlen    (m_axi_arlen),
    .m_axi_arsize   (m_axi_arsize),
    .m_axi_arburst  (m_axi_arburst),
    .m_axi_arcache  (m_axi_arcache),
    .m_axi_arprot   (m_axi_arprot),
    .m_axi_arvalid  (m_axi_arvalid),
    .m_axi_arready  (m_axi_arready),
    .m_axi_rid      (m_axi_rid),
    .m_axi_rdata    (m_axi_rdata),
    .m_axi_rresp    (m_axi_rresp),
    .m_axi_rlast    (m_axi_rlast),
    .m_axi_rvalid   (m_axi_rvalid),
    .m_axi_rready   (m_axi_rready)
  );

  openssd_wop_result_writer #(
    .AXI_ADDR_W (AXI_ADDR_W),
    .AXI_DATA_W (AXI_DATA_W),
    .AXI_ID_W   (AXI_ID_W)
  ) u_result_writer (
    .clk            (clk),
    .rst_n          (s_rst_n),
    .start_i        (status_wr_start),
    .addr_i         (status_wr_addr),
    .data_i         (status_wr_data),
    .busy_o         (status_wr_busy),
    .error_o        (status_wr_error),
    .m_axi_awid     (status_axi_awid),
    .m_axi_awaddr   (status_axi_awaddr),
    .m_axi_awlen    (status_axi_awlen),
    .m_axi_awsize   (status_axi_awsize),
    .m_axi_awburst  (status_axi_awburst),
    .m_axi_awcache  (status_axi_awcache),
    .m_axi_awprot   (status_axi_awprot),
    .m_axi_awvalid  (status_axi_awvalid),
    .m_axi_awready  (m_axi_awready),
    .m_axi_wdata    (status_axi_wdata),
    .m_axi_wstrb    (status_axi_wstrb),
    .m_axi_wlast    (status_axi_wlast),
    .m_axi_wvalid   (status_axi_wvalid),
    .m_axi_wready   (m_axi_wready),
    .m_axi_bid      (m_axi_bid),
    .m_axi_bresp    (m_axi_bresp),
    .m_axi_bvalid   (m_axi_bvalid),
    .m_axi_bready   (status_axi_bready)
  );

  assign m_axi_awid    = status_axi_awid;
  assign m_axi_awaddr  = status_axi_awaddr;
  assign m_axi_awlen   = status_axi_awlen;
  assign m_axi_awsize  = status_axi_awsize;
  assign m_axi_awburst = status_axi_awburst;
  assign m_axi_awcache = status_axi_awcache;
  assign m_axi_awprot  = status_axi_awprot;
  assign m_axi_awvalid = status_axi_awvalid;
  assign m_axi_awqos   = 4'h2;

  assign m_axi_wdata   = status_axi_wdata;
  assign m_axi_wstrb   = status_axi_wstrb;
  assign m_axi_wlast   = status_axi_wlast;
  assign m_axi_wvalid  = status_axi_wvalid;

  assign m_axi_bready  = status_axi_bready;
  assign m_axi_arqos   = 4'hC;

  // -------------------------------------------------------------------------
  // GPU doorbell notifier (inlined)
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      gpu_token_q        <= '0;
      gpu_token_valid_q  <= 1'b0;
      gpu_overflow_q     <= 1'b0;
    end else begin
      gpu_overflow_q <= 1'b0;

      if (gpu_token_valid_q && gpu_db_tready_mux) begin
        gpu_token_valid_q <= 1'b0;
      end

      if (doorbell_start_pulse) begin
        if (gpu_token_valid_q && !gpu_db_tready_mux) begin
          gpu_overflow_q <= 1'b1;
        end else begin
          gpu_token_q       <= {cmd_id_q, 14'h0, mode_latched_q};
          gpu_token_valid_q <= 1'b1;
        end
      end
    end
  end

  assign gpu_db_tdata_o  = gpu_token_q;
  assign gpu_db_tvalid_o = gpu_token_valid_q;
  assign gpu_pending     = gpu_token_valid_q;
  assign gpu_overflow    = gpu_overflow_q;

  // -------------------------------------------------------------------------
  // Kernel descriptor bridge
  openssd_wop_kernel_bridge u_kernel_bridge (
    .clk             (clk),
    .rst_n           (s_rst_n),
    .desc_valid_i    (desc_valid),
    .desc_i          (desc_payload),
    .desc_ready_o    (desc_ready),
    .kernel_accept_i (active_desc_ack_mux),
    .active_desc_o   (active_desc_int),
    .active_valid_o  (active_desc_valid_int),
    .desc_error_o    (kernel_desc_error),
    .unified_inst_o  (kernel_inst_w),
    .unified_inst_vld_o(kernel_inst_vld_w),
    .unified_inst_rdy_i(kernel_inst_rdy_w)
  );

  assign active_desc_o       = active_desc_int;
  assign active_desc_valid_o = active_desc_valid_int;

  // DaisyPlus-style FTL stage summary capture --------------------------------
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      ftl_stage_tlwe_total_q <= '0;
      ftl_stage_glwe_total_q <= '0;
      ftl_stage_tlwe_mask_q  <= '0;
      ftl_stage_glwe_mask_q  <= '0;
      ftl_stage_cmd_id_q     <= '0;
      ftl_stage_gpu_flag_q   <= 1'b0;
      ftl_stage_valid_q      <= 1'b0;
    end else begin
`ifndef SYNTHESIS
      if (active_desc_valid_int && !prev_active_desc_valid_q) begin
        int rc;
        int tlwe_sum;
        int glwe_sum;
        logic [15:0] tlwe_mask_local;
        logic [15:0] glwe_mask_local;

        rc = wop_ftl_stage_descriptor(
          int'(active_desc_int.mode),
          longint'(active_desc_int.tlwe_src_addr),
          int'(active_desc_int.tlwe_words),
          longint'(active_desc_int.gpu_shared_addr),
          int'(active_desc_int.glwe_words)
        );

        tlwe_sum = 0;
        glwe_sum = 0;
        tlwe_mask_local = '0;
        glwe_mask_local = '0;

        if (rc != 0) begin
          ftl_stage_tlwe_total_q <= '0;
          ftl_stage_glwe_total_q <= '0;
          ftl_stage_tlwe_mask_q  <= '0;
          ftl_stage_glwe_mask_q  <= '0;
          ftl_stage_cmd_id_q     <= '0;
          ftl_stage_gpu_flag_q   <= 1'b0;
          ftl_stage_valid_q      <= 1'b0;
        end else begin
          for (int ch = 0; ch < FTL_STAGE_TRACKED_CHANNELS; ch++) begin
            int tlwe_pages;
            int glwe_pages;
            if (wop_ftl_get_channel_summary(ch, tlwe_pages, glwe_pages) == 0) begin
              if (tlwe_pages != 0) begin
                tlwe_sum += tlwe_pages;
                tlwe_mask_local[ch] = 1'b1;
              end
              if (glwe_pages != 0) begin
                glwe_sum += glwe_pages;
                glwe_mask_local[ch] = 1'b1;
              end
            end
          end
          if (tlwe_sum > 16'hFFFF) begin
            ftl_stage_tlwe_total_q <= 16'hFFFF;
          end else begin
            ftl_stage_tlwe_total_q <= tlwe_sum[15:0];
          end
          if (glwe_sum > 16'hFFFF) begin
            ftl_stage_glwe_total_q <= 16'hFFFF;
          end else begin
            ftl_stage_glwe_total_q <= glwe_sum[15:0];
          end
          ftl_stage_tlwe_mask_q  <= tlwe_mask_local;
          ftl_stage_glwe_mask_q  <= glwe_mask_local;
          ftl_stage_cmd_id_q     <= active_desc_int.cmd_id;
          ftl_stage_gpu_flag_q   <= |(active_desc_int.flags & WOP_FLAG_GPU_WOKS);
          ftl_stage_valid_q      <= 1'b1;
`ifndef SYNTHESIS
          $display("[WRAPPER][FTL_STAGE] cmd=%0d tlwe_pages=%0d glwe_pages=%0d tlwe_mask=0x%04h glwe_mask=0x%04h",
                   active_desc_int.cmd_id,
                   (tlwe_sum > 16'hFFFF) ? 16'hFFFF : tlwe_sum[15:0],
                   (glwe_sum > 16'hFFFF) ? 16'hFFFF : glwe_sum[15:0],
                   tlwe_mask_local,
                   glwe_mask_local);
`endif
        end
      end
`endif
    end
  end

  // Hold stage summary until Result Status write --------------------------------
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      ftl_status_tlwe_total_q <= '0;
      ftl_status_glwe_total_q <= '0;
      ftl_status_tlwe_mask_q  <= '0;
      ftl_status_glwe_mask_q  <= '0;
      ftl_status_gpu_flags_q  <= '0;
      ftl_status_valid_q      <= 1'b0;
    end else begin
      if (done_evt) begin
        ftl_status_tlwe_total_q <= ftl_stage_tlwe_total_q;
        ftl_status_glwe_total_q <= ftl_stage_glwe_total_q;
        ftl_status_tlwe_mask_q  <= ftl_stage_tlwe_mask_q;
        ftl_status_glwe_mask_q  <= ftl_stage_glwe_mask_q;
        ftl_status_gpu_flags_q  <= ftl_stage_gpu_flag_q ? 16'h4000 : 16'd0;
        ftl_status_valid_q      <= ftl_stage_valid_q;
      end else if (status_wr_complete_start) begin
        ftl_status_tlwe_total_q <= '0;
        ftl_status_glwe_total_q <= '0;
        ftl_status_tlwe_mask_q  <= '0;
        ftl_status_glwe_mask_q  <= '0;
        ftl_status_gpu_flags_q  <= '0;
        ftl_status_valid_q      <= 1'b0;
      end
    end
  end

  // Record last completed command id ---------------------------------------
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      last_cmd_id_q <= '0;
      ack_q         <= 1'b0;
    end else begin
      ack_q <= active_desc_ack_mux;
      if (active_desc_ack_mux && !ack_q && active_desc_valid_int) begin
        last_cmd_id_q <= active_desc_int.cmd_id;
      end
    end
  end

  assign done_evt = completion_evt;

  // Track availability of KSK assets (basic cache-ready handshake)
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      ksk_asset_ready_q <= 1'b0;
    end else begin
      if (ksk_asset_ready_int) begin
        ksk_asset_ready_q <= !ksk_loader_error;
      end else if (desc_valid && desc_ready) begin
        ksk_asset_ready_q <= 1'b0;
      end else if (reset_ksk_cache || done_evt) begin
        ksk_asset_ready_q <= 1'b0;
      end
    end
  end

  // Configuration sanity tracking ------------------------------------------
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      cfg_param_error_q <= 1'b0;
    end else begin
      if (doorbell_pulse) begin
        cfg_param_error_q <= 1'b0;
      end else if (doorbell_start_pulse && (ksk_stride_zero || glwe_stride_zero)) begin
        cfg_param_error_q <= 1'b1;
      end
    end
  end

  assign cfg_param_error = cfg_param_error_q;

  // Error tracking ----------------------------------------------------------
  assign error_vector_bus = {
    ksk_loader_error,    // [7] KSK loader AXI error
    cfg_param_error,     // [6] invalid stride configuration
    glwe_loader_error,   // [5] GLWE loader AXI error
    bsk_loader_error,    // [4] BSK loader AXI error
    kernel_desc_error,   // [3] descriptor decode failure
    doorbell_reject_evt, // [2] doorbell denied (wrapper busy or GPU not ready)
    gpu_overflow,        // [1] GPU notification overflow
    dma_error            // [0] descriptor or status write failure
  };

  assign error_raw = |error_vector_bus;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      error_raw_q <= 1'b0;
    end else begin
      error_raw_q <= error_raw;
    end
  end

  assign error_evt = error_raw & ~error_raw_q;

  logic ctrl_error_q;
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      ctrl_error_q <= 1'b0;
    end else begin
      if (doorbell_pulse) begin
        ctrl_error_q <= 1'b0;
      end else if (error_evt) begin
        ctrl_error_q <= 1'b1;
      end
    end
  end

  assign ctrl_error = ctrl_error_q;

  assign ctrl_busy = doorbell_pending_q
                   | dma_busy
                   | active_desc_valid_int
                   | gpu_pending
                   | status_wr_busy
                   | status_fifo_valid_q[0]
                   | status_fifo_valid_q[1];

  // Operation mode captured for kernel until descriptor consumed ------------
  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      operation_mode_q <= 2'b00;
    end else if (doorbell_pulse) begin
      operation_mode_q <= mode_sel;
    end else if (active_desc_ack_mux && !ack_q && active_desc_valid_int) begin
      operation_mode_q <= 2'b00;
    end
  end

  // Kernel instantiation ----------------------------------------------------
  // Keep KS result stub enabled unless caller supplies real GPU runtime.
  localparam bit USE_GPU_KS_RESULT_STUB = USE_GPU_RESULT_STUB;

  wop_pbs_kernel_unified #(
    .MOD_Q_W          (MOD_Q_W),
    .MAX_BIT_WIDTH    (MAX_BIT_WIDTH),
    .N_LVL0           (N_LVL0),
    .N_LVL1           (N_LVL1),
    .N_LVL2           (N_LVL2),
    .ELL_LVL1         (ELL_LVL1),
    .K                (K),
    .LBY              (LBY),
    .LBX              (LBX),
    .LBZ              (LBZ),
    .MOD_NTT_W        (MOD_NTT_W),
    .MOD_NTT_TYPE     (MOD_NTT_TYPE),
    .ELL_LVL2         (ELL_LVL2),
    .MOD_KSK_W        (MOD_KSK_W),
    .BSK_PC           (BSK_PC),
    .KSK_PC           (KSK_PC),
    .REGF_WR_REQ_W    (REGF_WR_REQ_W),
    .REGF_RD_REQ_W    (REGF_RD_REQ_W),
    .REGF_COEF_NB     (REGF_COEF_NB),
    .SIM_KS_RESULT_STUB (USE_GPU_KS_RESULT_STUB)
  ) u_wop_kernel (
    .clk                        (clk),
    .s_rst_n                    (s_rst_n),
    .unified_pbs_inst           (kernel_inst_w),
    .unified_pbs_inst_vld       (kernel_inst_vld_w),
    .unified_pbs_inst_rdy       (kernel_inst_rdy_w),
    .unified_pbs_inst_ack       (kernel_inst_ack_w),
    .unified_pbs_response       (kernel_resp_w),
    .operation_mode             (operation_mode_q),
    .gpu_woks_mode              (gpu_woks_mode_active_q),
    .gpu_desc_tlwe_words        (active_desc_int.tlwe_words),
    .gpu_desc_glwe_words        (16'(active_desc_int.glwe_words)),
    .gpu_desc_flags             (active_desc_int.flags),
    .gpu_woks_preks_valid       (kernel_gpu_preks_valid_w),
    .gpu_woks_preks_data        (kernel_gpu_preks_data_w),
    .gpu_woks_preks_last        (kernel_gpu_preks_last_w),
    .gpu_woks_preks_ready       (kernel_gpu_preks_ready_w),
    .gpu_woks_result_valid      (kernel_gpu_result_valid_w),
    .gpu_woks_result_data       (kernel_gpu_result_data_w),
    .gpu_woks_result_last       (kernel_gpu_result_last_w),
    .gpu_woks_result_ready      (kernel_gpu_result_ready_w),
    .bsk_throttle_o             (kernel_bsk_throttle_w),
    .ksk_throttle_o             (kernel_ksk_throttle_w),
    .pep_regf_wr_req_vld        (pep_regf_wr_req_vld),
    .pep_regf_wr_req_rdy        (pep_regf_wr_req_rdy),
    .pep_regf_wr_req            (pep_regf_wr_req),
    .pep_regf_wr_data_vld       (pep_regf_wr_data_vld),
    .pep_regf_wr_data_rdy       (pep_regf_wr_data_rdy),
    .pep_regf_wr_data           (pep_regf_wr_data),
    .regf_pep_wr_ack            (regf_pep_wr_ack),
    .pep_regf_rd_req_vld        (pep_regf_rd_req_vld),
    .pep_regf_rd_req_rdy        (pep_regf_rd_req_rdy),
    .pep_regf_rd_req            (pep_regf_rd_req),
    .regf_pep_rd_data_avail     (regf_pep_rd_data_avail),
    .regf_pep_rd_data           (regf_pep_rd_data),
    .regf_pep_rd_last_word      (regf_pep_rd_last_word),
    .reset_ksk_cache            (reset_ksk_cache),
    .reset_ksk_cache_done       (reset_ksk_cache_done),
    .ksk_mem_avail              (ksk_mem_avail_mux),
    .ksk_mem_addr               (ksk_mem_addr_mux),
    .m_axi4_glwe_arid           (),
    .m_axi4_glwe_araddr         (),
    .m_axi4_glwe_arlen          (),
    .m_axi4_glwe_arsize         (),
    .m_axi4_glwe_arburst        (),
    .m_axi4_glwe_arvalid        (),
    .m_axi4_glwe_arready        (1'b0),
    .m_axi4_glwe_rid            ('0),
    .m_axi4_glwe_rdata          ('0),
    .m_axi4_glwe_rresp          ('0),
    .m_axi4_glwe_rlast          (1'b0),
    .m_axi4_glwe_rvalid         (1'b0),
    .m_axi4_glwe_rready         (),
    .m_axi4_bsk_arid            (),
    .m_axi4_bsk_araddr          (),
    .m_axi4_bsk_arlen           (),
    .m_axi4_bsk_arsize          (),
    .m_axi4_bsk_arburst         (),
    .m_axi4_bsk_arvalid         (),
    .m_axi4_bsk_arready         ({BSK_PC{1'b0}}),
    .m_axi4_bsk_rid             ('0),
    .m_axi4_bsk_rdata           ('0),
    .m_axi4_bsk_rresp           ('0),
    .m_axi4_bsk_rlast           ('0),
    .m_axi4_bsk_rvalid          ('0),
    .m_axi4_bsk_rready          (),
    .m_axi4_ksk_arid            (),
    .m_axi4_ksk_araddr          (),
    .m_axi4_ksk_arlen           (),
    .m_axi4_ksk_arsize          (),
    .m_axi4_ksk_arburst         (),
    .m_axi4_ksk_arvalid         (),
    .m_axi4_ksk_arready         ({KSK_PC{1'b0}}),
    .m_axi4_ksk_rid             ('0),
    .m_axi4_ksk_rdata           ('0),
    .m_axi4_ksk_rresp           ('0),
    .m_axi4_ksk_rlast           ('0),
    .m_axi4_ksk_rvalid          ('0),
    .m_axi4_ksk_rready          ()
    // NTT service interfaces are stubbed in current kernel build; tie-offs below
  );

  // Tie-offs for loader/NTT service interfaces (current kernel build exposes no ports).
  assign kernel_ksk_asset_ready_w      = 1'b1;
  assign kernel_glwe_asset_ready_w     = 1'b1;
  assign kernel_glwe_asset_req_w       = 1'b0;
  assign ntt_service_decomp_avail            = '0;
  assign ntt_service_decomp_data             = '0;
  assign ntt_service_decomp_sob              = 1'b0;
  assign ntt_service_decomp_eob              = 1'b0;
  assign ntt_service_decomp_sog              = 1'b0;
  assign ntt_service_decomp_eog              = 1'b0;
  assign ntt_service_decomp_sol              = 1'b0;
  assign ntt_service_decomp_eol              = 1'b0;
  assign ntt_service_decomp_pbs_id           = '0;
  assign ntt_service_decomp_last_pbs         = 1'b0;
  assign ntt_service_decomp_full_throughput  = 1'b0;
  assign ntt_service_decomp_ctrl_vld         = 1'b0;
  assign ntt_service_result_rdy              = '1;
  assign ntt_service_result_ctrl_rdy         = 1'b1;
  assign decomp_ntt_sog                      = 1'b0;
  assign decomp_ntt_ctrl_avail               = 1'b0;

`ifdef TB_BE_DEBUG
  initial begin
    $display("%t > [NTT_TOP_SIM][WARN] openssd_wop_wrapper keeps ntt_service_* tied off (tb_sim_models drives DUT)", $time);
  end
`endif

  logic gpu_ack_pulse;
  assign gpu_ack_pulse = done_evt && (active_desc_int.mode == WOP_MODE_CB);

  assign unified_pbs_inst_ack_o = kernel_inst_ack_w | gpu_ack_pulse;
  assign unified_pbs_response_o = kernel_resp_w;

`ifdef SIM_WOP_GPU_LOOPBACK
  localparam int SIM_GPU_LOOPBACK_LATENCY   = 32;
  localparam int SIM_GPU_LOOPBACK_CNT_W     = $clog2(SIM_GPU_LOOPBACK_LATENCY + 1);
  localparam int SIM_GPU_LOOPBACK_MAX_OUT   = 2;

  logic [SIM_GPU_LOOPBACK_CNT_W-1:0] loopback_ctr_q;
  logic                              loopback_active_q;
  logic                              loopback_wait_clear_q;
  logic                              gpu_loopback_ack_q;
  logic [$clog2(SIM_GPU_LOOPBACK_MAX_OUT+1)-1:0] loopback_outstanding_q;

  always_ff @(posedge clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      loopback_ctr_q        <= '0;
      loopback_active_q     <= 1'b0;
      loopback_wait_clear_q <= 1'b0;
      gpu_loopback_ack_q    <= 1'b0;
      loopback_outstanding_q<= '0;
    end else begin
      gpu_loopback_ack_q <= 1'b0;

      if (!loopback_active_q && !loopback_wait_clear_q && active_desc_valid_int) begin
        loopback_active_q <= 1'b1;
        loopback_ctr_q    <= SIM_GPU_LOOPBACK_LATENCY;
      end else if (loopback_active_q) begin
        if (!active_desc_valid_int) begin
          loopback_active_q     <= 1'b0;
          loopback_wait_clear_q <= 1'b0;
        end else if (loopback_ctr_q != '0) begin
          loopback_ctr_q <= loopback_ctr_q - 1'b1;
        end else begin
          gpu_loopback_ack_q    <= 1'b1;
          loopback_active_q     <= 1'b0;
          loopback_wait_clear_q <= 1'b1;
        end
      end

      if (loopback_wait_clear_q && !active_desc_valid_int) begin
        loopback_wait_clear_q <= 1'b0;
      end

      if (desc_valid && desc_ready) begin
        if (loopback_outstanding_q < SIM_GPU_LOOPBACK_MAX_OUT[$clog2(SIM_GPU_LOOPBACK_MAX_OUT+1)-1:0]) begin
          loopback_outstanding_q <= loopback_outstanding_q + 1'b1;
        end
      end
      if (gpu_loopback_ack_q && (loopback_outstanding_q != '0)) begin
        loopback_outstanding_q <= loopback_outstanding_q - 1'b1;
      end
    end
  end

  assign gpu_loopback_ready  = (loopback_outstanding_q < SIM_GPU_LOOPBACK_MAX_OUT[$clog2(SIM_GPU_LOOPBACK_MAX_OUT+1)-1:0]);
  assign gpu_loopback_tready = 1'b1;
  assign gpu_loopback_ack    = gpu_loopback_ack_q;

  always_ff @(posedge clk) begin
    if (gpu_loopback_ack_q) begin
      $display("[%0t][GPU_LOOPBACK_ACK] cmd_id=%0d mode=%0d", $time,
               active_desc_int.cmd_id, active_desc_int.mode);
    end
  end
`endif

endmodule
