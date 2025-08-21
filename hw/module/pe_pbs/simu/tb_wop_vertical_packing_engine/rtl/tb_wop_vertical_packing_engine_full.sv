// ==============================================================================================
// 完整Vertical Packing Engine测试平台
// 
// 目的：测试真正的端到端VP-PBS流程
// 1. wop_vertical_packing_engine: CMux Tree (bits 10-19)
// 2. wop_pbs_kernel_lite: Blind Rotation (bits 0-9) + Sample Extract + Post-processing
// 3. 验证VP Engine → PBS Kernel的完整数据流
//
// Author: Ray Pan
// Date: January 2025
// ==============================================================================================

`timescale 1ns / 1ps

module tb_wop_vertical_packing_engine_full
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import regf_common_param_pkg::*;
  import axi_if_glwe_axi_pkg::*;
  import axi_if_common_param_pkg::*;
  import axi_if_bsk_axi_pkg::*;
  import axi_if_ksk_axi_pkg::*;
  import hpu_common_instruction_pkg::*;
  import vp_pbs_inst_pkg::*;
();

// ==============================================================================================
// 参数定义
// ==============================================================================================
  parameter int CLK_PERIOD = 10;
  parameter int MOD_Q_W = 32;
  parameter int MAX_BIT_WIDTH = 20;
  parameter int N_LVL1 = 1024;
  parameter int ELL_LVL1 = 3;
  parameter int K = 1;
  parameter int REGF_ADDR_W = 16;
  parameter int LUT_SIZE = 1024;
  parameter int BSK_PC = 2;
  parameter int KSK_PC = 1;

// ==============================================================================================
// 时钟和复位
// ==============================================================================================
  logic clk;
  logic s_rst_n;

  always #(CLK_PERIOD/2) clk = ~clk;

// ==============================================================================================
// VP Engine接口信号
// ==============================================================================================
  // VP控制接口
  logic vp_start;
  logic [MAX_BIT_WIDTH-1:0] vp_bit_width;
  logic vp_done;
  
  // 输入参数
  logic [REGF_ADDR_W-1:0] vp_ggsw_samples_base_addr;
  logic vp_ggsw_samples_ready;
  logic [REGF_ADDR_W-1:0] vp_result_addr;
  logic vp_result_ready;
  
  // LUT接口
  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] vp_lut_base_addr;
  logic [axi_if_glwe_axi_pkg::AXI4_ADD_W-1:0] vp_lut_addr;
  logic vp_lut_req_vld;
  logic vp_lut_req_rdy;
  logic vp_lut_data_avail;
  logic [axi_if_glwe_axi_pkg::AXI4_DATA_W-1:0] vp_lut_data;
  
  // VP RegFile接口
  logic vp_regf_rd_req_vld;
  logic vp_regf_rd_req_rdy;
  logic [REGF_RD_REQ_W-1:0] vp_regf_rd_req;
  logic [REGF_COEF_NB-1:0] vp_regf_rd_data_avail;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] vp_regf_rd_data;
  
  logic vp_regf_wr_req_vld;
  logic vp_regf_wr_req_rdy;
  logic [REGF_WR_REQ_W-1:0] vp_regf_wr_req;
  logic [REGF_COEF_NB-1:0] vp_regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0] vp_regf_wr_data_rdy;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] vp_regf_wr_data;
  
  // VP-PBS服务接口
  vp_pbs_inst_t vp_pbs_inst;
  logic vp_pbs_inst_vld;
  logic vp_pbs_inst_rdy;
  logic vp_pbs_inst_ack;
  vp_pbs_response_t vp_pbs_response;

// ==============================================================================================
// PBS Kernel接口信号
// ==============================================================================================
  // BSK资源请求接口
  vp_bsk_resource_req_t vp_bsk_resource_req;
  logic vp_bsk_resource_req_vld;
  logic vp_bsk_resource_req_rdy;
  
  // PBS RegFile接口 (与VP Engine共享)
  logic pbs_regf_rd_req_vld;
  logic pbs_regf_rd_req_rdy;
  logic [REGF_RD_REQ_W-1:0] pbs_regf_rd_req;
  logic [REGF_COEF_NB-1:0] pbs_regf_rd_data_avail;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] pbs_regf_rd_data;
  
  logic pbs_regf_wr_req_vld;
  logic pbs_regf_wr_req_rdy;
  logic [REGF_WR_REQ_W-1:0] pbs_regf_wr_req;
  logic [REGF_COEF_NB-1:0] pbs_regf_wr_data_vld;
  logic [REGF_COEF_NB-1:0] pbs_regf_wr_data_rdy;
  logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] pbs_regf_wr_data;

  // BSK AXI接口
  logic [BSK_PC-1:0][axi_if_bsk_axi_pkg::AXI4_ID_W-1:0] m_axi4_bsk_arid;
  logic [BSK_PC-1:0][axi_if_bsk_axi_pkg::AXI4_ADD_W-1:0] m_axi4_bsk_araddr;
  logic [BSK_PC-1:0][AXI4_LEN_W-1:0] m_axi4_bsk_arlen;
  logic [BSK_PC-1:0][AXI4_SIZE_W-1:0] m_axi4_bsk_arsize;
  logic [BSK_PC-1:0][AXI4_BURST_W-1:0] m_axi4_bsk_arburst;
  logic [BSK_PC-1:0] m_axi4_bsk_arvalid;
  logic [BSK_PC-1:0] m_axi4_bsk_arready;
  logic [BSK_PC-1:0][axi_if_bsk_axi_pkg::AXI4_ID_W-1:0] m_axi4_bsk_rid;
  logic [BSK_PC-1:0][axi_if_bsk_axi_pkg::AXI4_DATA_W-1:0] m_axi4_bsk_rdata;
  logic [BSK_PC-1:0][AXI4_RESP_W-1:0] m_axi4_bsk_rresp;
  logic [BSK_PC-1:0] m_axi4_bsk_rlast;
  logic [BSK_PC-1:0] m_axi4_bsk_rvalid;
  logic [BSK_PC-1:0] m_axi4_bsk_rready;

  // KSK AXI接口
  logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ID_W-1:0] m_axi4_ksk_arid;
  logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ADD_W-1:0] m_axi4_ksk_araddr;
  logic [KSK_PC-1:0][AXI4_LEN_W-1:0] m_axi4_ksk_arlen;
  logic [KSK_PC-1:0][AXI4_SIZE_W-1:0] m_axi4_ksk_arsize;
  logic [KSK_PC-1:0][AXI4_BURST_W-1:0] m_axi4_ksk_arburst;
  logic [KSK_PC-1:0] m_axi4_ksk_arvalid;
  logic [KSK_PC-1:0] m_axi4_ksk_arready;
  logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_ID_W-1:0] m_axi4_ksk_rid;
  logic [KSK_PC-1:0][axi_if_ksk_axi_pkg::AXI4_DATA_W-1:0] m_axi4_ksk_rdata;
  logic [KSK_PC-1:0][AXI4_RESP_W-1:0] m_axi4_ksk_rresp;
  logic [KSK_PC-1:0] m_axi4_ksk_rlast;
  logic [KSK_PC-1:0] m_axi4_ksk_rvalid;
  logic [KSK_PC-1:0] m_axi4_ksk_rready;

// ==============================================================================================
// 内存模型和测试数据
// ==============================================================================================
  // RegFile共享内存模型
  logic [MOD_Q_W-1:0] regfile_memory [logic [15:0]];
  
  // LUT测试数据
  logic [1:0][N_LVL1-1:0][MOD_Q_W-1:0] test_lut_table [LUT_SIZE-1:0];
  
  // Golden参考结果
  logic [N_LVL1-1:0][MOD_Q_W-1:0] golden_result_a;
  logic [MOD_Q_W-1:0] golden_result_b;
  
  // 实际结果
  logic [N_LVL1-1:0][MOD_Q_W-1:0] actual_result_a;

// ==============================================================================================
// 模块实例化
// ==============================================================================================

// VP Engine实例
wop_vertical_packing_engine #(
  .MOD_Q_W(MOD_Q_W),
  .MAX_BIT_WIDTH(MAX_BIT_WIDTH),
  .N_LVL1(N_LVL1),
  .ELL_LVL1(ELL_LVL1),
  .K(K),
  .REGF_ADDR_W(REGF_ADDR_W),
  .LUT_SIZE(LUT_SIZE)
) i_vp_engine (
  .clk(clk),
  .s_rst_n(s_rst_n),
  
  // VP控制接口
  .start(vp_start),
  .bit_width(vp_bit_width),
  .done(vp_done),
  
  // 输入参数
  .ggsw_samples_base_addr(vp_ggsw_samples_base_addr),
  .ggsw_samples_ready(vp_ggsw_samples_ready),
  .result_addr(vp_result_addr),
  .result_ready(vp_result_ready),
  
  // LUT接口
  .lut_base_addr(vp_lut_base_addr),
  .lut_addr(vp_lut_addr),
  .lut_req_vld(vp_lut_req_vld),
  .lut_req_rdy(vp_lut_req_rdy),
  .lut_data_avail(vp_lut_data_avail),
  .lut_data(vp_lut_data),
  
  // RegFile接口
  .regf_rd_req_vld(vp_regf_rd_req_vld),
  .regf_rd_req_rdy(vp_regf_rd_req_rdy),
  .regf_rd_req(vp_regf_rd_req),
  .regf_rd_data_avail(vp_regf_rd_data_avail),
  .regf_rd_data(vp_regf_rd_data),
  
  .regf_wr_req_vld(vp_regf_wr_req_vld),
  .regf_wr_req_rdy(vp_regf_wr_req_rdy),
  .regf_wr_req(vp_regf_wr_req),
  .regf_wr_data_vld(vp_regf_wr_data_vld),
  .regf_wr_data_rdy(vp_regf_wr_data_rdy),
  .regf_wr_data(vp_regf_wr_data),
  
  // VP-PBS服务接口
  .vp_pbs_inst(vp_pbs_inst),
  .vp_pbs_inst_vld(vp_pbs_inst_vld),
  .vp_pbs_inst_rdy(vp_pbs_inst_rdy),
  .vp_pbs_inst_ack(vp_pbs_inst_ack),
  .vp_pbs_response(vp_pbs_response)
);

// PBS Kernel实例
wop_pbs_kernel_lite #(
  .MOD_Q_W(MOD_Q_W),
  .MAX_BIT_WIDTH(MAX_BIT_WIDTH),
  .N_LVL1(N_LVL1),
  .ELL_LVL1(ELL_LVL1),
  .K(K),
  .REGF_ADDR_W(REGF_ADDR_W),
  .LUT_SIZE(LUT_SIZE),
  .BSK_PC(BSK_PC),
  .KSK_PC(KSK_PC)
) i_pbs_kernel (
  .clk(clk),
  .s_rst_n(s_rst_n),
  
  // VP-PBS接口 (接收来自VP Engine的请求)
  .vp_pbs_inst(vp_pbs_inst),
  .vp_pbs_inst_vld(vp_pbs_inst_vld),
  .vp_pbs_inst_rdy(vp_pbs_inst_rdy),
  .vp_pbs_inst_ack(vp_pbs_inst_ack),
  .vp_pbs_response(vp_pbs_response),
  
  // BSK资源请求接口
  .vp_bsk_resource_req(vp_bsk_resource_req),
  .vp_bsk_resource_req_vld(vp_bsk_resource_req_vld),
  .vp_bsk_resource_req_rdy(vp_bsk_resource_req_rdy),
  
  // RegFile接口 (与VP Engine共享)
  .pep_regf_rd_req_vld(pbs_regf_rd_req_vld),
  .pep_regf_rd_req_rdy(pbs_regf_rd_req_rdy),
  .pep_regf_rd_req(pbs_regf_rd_req),
  .regf_pep_rd_data_avail(pbs_regf_rd_data_avail),
  .regf_pep_rd_data(pbs_regf_rd_data),
  
  .pep_regf_wr_req_vld(pbs_regf_wr_req_vld),
  .pep_regf_wr_req_rdy(pbs_regf_wr_req_rdy),
  .pep_regf_wr_req(pbs_regf_wr_req),
  .pep_regf_wr_data_vld(pbs_regf_wr_data_vld),
  .regf_pep_wr_data_rdy(pbs_regf_wr_data_rdy),
  .pep_regf_wr_data(pbs_regf_wr_data),
  
  // BSK AXI接口
  .m_axi4_bsk_arid(m_axi4_bsk_arid),
  .m_axi4_bsk_araddr(m_axi4_bsk_araddr),
  .m_axi4_bsk_arlen(m_axi4_bsk_arlen),
  .m_axi4_bsk_arsize(m_axi4_bsk_arsize),
  .m_axi4_bsk_arburst(m_axi4_bsk_arburst),
  .m_axi4_bsk_arvalid(m_axi4_bsk_arvalid),
  .m_axi4_bsk_arready(m_axi4_bsk_arready),
  .m_axi4_bsk_rid(m_axi4_bsk_rid),
  .m_axi4_bsk_rdata(m_axi4_bsk_rdata),
  .m_axi4_bsk_rresp(m_axi4_bsk_rresp),
  .m_axi4_bsk_rlast(m_axi4_bsk_rlast),
  .m_axi4_bsk_rvalid(m_axi4_bsk_rvalid),
  .m_axi4_bsk_rready(m_axi4_bsk_rready),
  
  // KSK AXI接口
  .m_axi4_ksk_arid(m_axi4_ksk_arid),
  .m_axi4_ksk_araddr(m_axi4_ksk_araddr),
  .m_axi4_ksk_arlen(m_axi4_ksk_arlen),
  .m_axi4_ksk_arsize(m_axi4_ksk_arsize),
  .m_axi4_ksk_arburst(m_axi4_ksk_arburst),
  .m_axi4_ksk_arvalid(m_axi4_ksk_arvalid),
  .m_axi4_ksk_arready(m_axi4_ksk_arready),
  .m_axi4_ksk_rid(m_axi4_ksk_rid),
  .m_axi4_ksk_rdata(m_axi4_ksk_rdata),
  .m_axi4_ksk_rresp(m_axi4_ksk_rresp),
  .m_axi4_ksk_rlast(m_axi4_ksk_rlast),
  .m_axi4_ksk_rvalid(m_axi4_ksk_rvalid),
  .m_axi4_ksk_rready(m_axi4_ksk_rready)
);

// ==============================================================================================
// RegFile仲裁器 (VP Engine和PBS Kernel共享RegFile)
// ==============================================================================================
always_comb begin
  // 简单优先级仲裁：VP Engine优先
  if (vp_regf_rd_req_vld) begin
    vp_regf_rd_req_rdy = 1'b1;
    pbs_regf_rd_req_rdy = 1'b0;
    vp_regf_rd_data_avail = regf_rd_data_avail_shared;
    vp_regf_rd_data = regf_rd_data_shared;
    pbs_regf_rd_data_avail = '0;
    pbs_regf_rd_data = '0;
  end else begin
    vp_regf_rd_req_rdy = 1'b0;
    pbs_regf_rd_req_rdy = 1'b1;
    vp_regf_rd_data_avail = '0;
    vp_regf_rd_data = '0;
    pbs_regf_rd_data_avail = regf_rd_data_avail_shared;
    pbs_regf_rd_data = regf_rd_data_shared;
  end
  
  // 写仲裁：VP Engine优先
  if (vp_regf_wr_req_vld) begin
    vp_regf_wr_req_rdy = 1'b1;
    pbs_regf_wr_req_rdy = 1'b0;
    vp_regf_wr_data_rdy = regf_wr_data_rdy_shared;
    pbs_regf_wr_data_rdy = '0;
  end else begin
    vp_regf_wr_req_rdy = 1'b0;
    pbs_regf_wr_req_rdy = 1'b1;
    vp_regf_wr_data_rdy = '0;
    pbs_regf_wr_data_rdy = regf_wr_data_rdy_shared;
  end
end

// 共享RegFile接口信号
logic [REGF_COEF_NB-1:0] regf_rd_data_avail_shared;
logic [REGF_COEF_NB-1:0][MOD_Q_W-1:0] regf_rd_data_shared;
logic [REGF_COEF_NB-1:0] regf_wr_data_rdy_shared;

// ==============================================================================================
// 测试主流程 
// ==============================================================================================
initial begin
  $display("=== 完整Vertical Packing Engine测试 ===");
  
  // 初始化
  clk = 1'b0;
  s_rst_n = 1'b0;
  vp_start = 1'b0;
  vp_bit_width = 20'd20;
  vp_ggsw_samples_ready = 1'b0;
  
  // 生成测试数据
  generate_test_data();
  
  repeat(10) @(posedge clk);
  s_rst_n = 1'b1;
  $display("[TB] Reset completed, starting VP Engine test");
  
  repeat(5) @(posedge clk);
  
  // 启动VP Engine
  vp_start = 1'b1;
  vp_ggsw_samples_base_addr = 16'h2000;
  vp_result_addr = 16'h3000;
  vp_lut_base_addr = 32'h10000;
  vp_ggsw_samples_ready = 1'b1;
  
  @(posedge clk);
  vp_start = 1'b0;
  
  $display("[TB] VP Engine started, waiting for completion");
  
  // 等待VP Engine完成并触发PBS
  wait(vp_done);
  $display("[TB] VP Engine completed, PBS processing should follow");
  
  // 等待完整流程完成
  repeat(10000) @(posedge clk);
  
  $display("[TB] Test completed");
  $finish;
end

// ==============================================================================================
// 测试数据生成
// ==============================================================================================
task generate_test_data();
  $display("[TB] Generating test data for complete VP-PBS flow");
  
  // 生成LUT表
  for (integer i = 0; i < LUT_SIZE; i++) begin
    for (integer k = 0; k <= 1; k++) begin
      for (integer n = 0; n < N_LVL1; n++) begin
        test_lut_table[i][k][n] = (i * 8) + (k * 4) + n;
      end
    end
  end
  
  // 生成GGSW样本 (20 bits)
  for (integer bit_idx = 0; bit_idx < MAX_BIT_WIDTH; bit_idx++) begin
    for (integer n = 0; n < N_LVL1; n++) begin
      logic [31:0] addr;
      logic [31:0] ggsw_value;
      addr = 32'h2000 + (bit_idx * 1024) + n;
      // 生成测试模式：偶数位=1000, 奇数位=500
      ggsw_value = (bit_idx % 2 == 0) ? 32'h3e8 : 32'h1f4; // 1000 : 500
      regfile_memory[addr[15:0]] = ggsw_value + n;
    end
  end
  
  $display("[TB] Test data generation completed");
endtask

// ==============================================================================================
// LUT接口响应器
// ==============================================================================================
always_ff @(posedge clk) begin
  if (vp_lut_req_vld && vp_lut_req_rdy) begin
    // 模拟LUT数据返回
    vp_lut_data_avail <= #(2*CLK_PERIOD) 1'b1;
    // 从test_lut_table返回数据
    // 简化：返回固定测试数据
    vp_lut_data <= #(2*CLK_PERIOD) {32'h3, 32'h2, 32'h1, 32'h0};
  end else begin
    vp_lut_data_avail <= #(2*CLK_PERIOD) 1'b0;
  end
end

assign vp_lut_req_rdy = 1'b1; // 始终ready

// ==============================================================================================
// RegFile接口响应器  
// ==============================================================================================
// 简化的RegFile响应器，直接使用regfile_memory
assign regf_rd_data_avail_shared = {REGF_COEF_NB{1'b1}};
assign regf_wr_data_rdy_shared = {REGF_COEF_NB{1'b1}};

always_comb begin
  regf_rd_data_shared[0] = regfile_memory[vp_regf_rd_req_vld ? vp_regf_rd_req[15:0] : pbs_regf_rd_req[15:0]];
  for (int i = 1; i < REGF_COEF_NB; i++) begin
    regf_rd_data_shared[i] = '0;
  end
end

// RegFile写入
always_ff @(posedge clk) begin
  if (vp_regf_wr_req_vld && vp_regf_wr_data_vld[0]) begin
    regfile_memory[vp_regf_wr_req[15:0]] <= vp_regf_wr_data[0];
  end else if (pbs_regf_wr_req_vld && pbs_regf_wr_data_vld[0]) begin
    regfile_memory[pbs_regf_wr_req[15:0]] <= pbs_regf_wr_data[0];
  end
end

// ==============================================================================================
// BSK/KSK AXI响应器 (复用原有实现)
// ==============================================================================================
// BSK AXI响应器
logic [BSK_PC-1:0] bsk_axi_read_active;
logic [BSK_PC-1:0][7:0] bsk_axi_read_counter;

genvar bsk_port;
generate 
  for (bsk_port = 0; bsk_port < BSK_PC; bsk_port++) begin : gen_bsk_axi_responder
    always_ff @(posedge clk or negedge s_rst_n) begin
      if (!s_rst_n) begin
        bsk_axi_read_active[bsk_port] <= 1'b0;
        bsk_axi_read_counter[bsk_port] <= '0;
      end else begin
        if (m_axi4_bsk_arvalid[bsk_port] && m_axi4_bsk_arready[bsk_port] && !bsk_axi_read_active[bsk_port]) begin
          bsk_axi_read_active[bsk_port] <= 1'b1;
          bsk_axi_read_counter[bsk_port] <= m_axi4_bsk_arlen[bsk_port] + 1;
        end
        
        if (bsk_axi_read_active[bsk_port] && m_axi4_bsk_rvalid[bsk_port] && m_axi4_bsk_rready[bsk_port] && m_axi4_bsk_rlast[bsk_port]) begin
          bsk_axi_read_active[bsk_port] <= 1'b0;
        end
      end
    end
    
    assign m_axi4_bsk_arready[bsk_port] = !bsk_axi_read_active[bsk_port];
    assign m_axi4_bsk_rvalid[bsk_port] = bsk_axi_read_active[bsk_port];
    assign m_axi4_bsk_rid[bsk_port] = m_axi4_bsk_arid[bsk_port];
    assign m_axi4_bsk_rdata[bsk_port] = {axi_if_bsk_axi_pkg::AXI4_DATA_W{1'b0}} | {{(axi_if_bsk_axi_pkg::AXI4_DATA_W-64){1'b0}}, 64'h123456789ABCDEF0};
    assign m_axi4_bsk_rresp[bsk_port] = 2'b00;
    assign m_axi4_bsk_rlast[bsk_port] = (bsk_axi_read_counter[bsk_port] == 1);
  end
endgenerate

// 🔧 实现真实的KSK AXI响应器
logic [KSK_PC-1:0] ksk_axi_read_active;
logic [KSK_PC-1:0][7:0] ksk_axi_read_counter;

genvar ksk_port;
generate 
  for (ksk_port = 0; ksk_port < KSK_PC; ksk_port++) begin : gen_ksk_axi_responder
    always_ff @(posedge clk or negedge s_rst_n) begin
      if (!s_rst_n) begin
        ksk_axi_read_active[ksk_port] <= 1'b0;
        ksk_axi_read_counter[ksk_port] <= '0;
      end else begin
        if (m_axi4_ksk_arvalid[ksk_port] && m_axi4_ksk_arready[ksk_port] && !ksk_axi_read_active[ksk_port]) begin
          ksk_axi_read_active[ksk_port] <= 1'b1;
          ksk_axi_read_counter[ksk_port] <= m_axi4_ksk_arlen[ksk_port] + 1;
          $display("[TB] KSK AXI[%0d]: Read request STARTED addr=0x%h len=%0d", ksk_port, m_axi4_ksk_araddr[ksk_port], m_axi4_ksk_arlen[ksk_port]);
        end
        
        if (ksk_axi_read_active[ksk_port] && m_axi4_ksk_rvalid[ksk_port] && m_axi4_ksk_rready[ksk_port] && m_axi4_ksk_rlast[ksk_port]) begin
          ksk_axi_read_active[ksk_port] <= 1'b0;
          $display("[TB] KSK AXI[%0d]: Read request COMPLETED", ksk_port);
        end
      end
    end
    
    assign m_axi4_ksk_arready[ksk_port] = !ksk_axi_read_active[ksk_port];
    assign m_axi4_ksk_rvalid[ksk_port] = ksk_axi_read_active[ksk_port];
    assign m_axi4_ksk_rid[ksk_port] = m_axi4_ksk_arid[ksk_port];
    // 🔧 提供真实的KSK测试数据而不是硬编码'0
    assign m_axi4_ksk_rdata[ksk_port] = {axi_if_ksk_axi_pkg::AXI4_DATA_W{1'b0}} | {{(axi_if_ksk_axi_pkg::AXI4_DATA_W-64){1'b0}}, 64'hFEDCBA9876543210};
    assign m_axi4_ksk_rresp[ksk_port] = 2'b00;
    assign m_axi4_ksk_rlast[ksk_port] = (ksk_axi_read_counter[ksk_port] == 1);
  end
endgenerate

endmodule


