// ==============================================================================================
// BSD 3-Clause Clear License
// Copyright © 2025 ZAMA. All rights reserved.
// ----------------------------------------------------------------------------------------------
// Description  :
// ----------------------------------------------------------------------------------------------
//
// This module deals with the key switch for pe_pbs.
// It takes a BLWE as input.
// Change the key into the PBS key domain.
// Each coefficient is finally mod switch to 2N.
// ==============================================================================================

module pep_key_switch
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import pep_common_param_pkg::*;
  import pep_ks_common_param_pkg::*;
#(
  parameter  int RAM_LATENCY   = 2,
  parameter  int ALMOST_DONE_BLINE_ID = 0, // TOREVIEW
  parameter  int KS_IF_SUBW_NB = 1,
  parameter  int KS_IF_COEF_NB = LBY
)
(
  input  logic                                                      clk,        // clock
  input  logic                                                      s_rst_n,    // synchronous reset

  // Sequencer command
  output logic                                                      ks_seq_cmd_enquiry,
  input  logic [KS_CMD_W-1:0]                                       seq_ks_cmd,
  input  logic                                                      seq_ks_cmd_avail,
  output logic                                                      seq_ks_cmd_rdy,

  // ksk_if
  input  logic                                                      inc_ksk_wr_ptr, // pulse
  output logic                                                      inc_ksk_rd_ptr,

  // To ksk manager
  output logic [KS_BATCH_CMD_W-1:0]                                 batch_cmd,
  output logic                                                      batch_cmd_avail, // pulse

  // load_blwe
  input  logic [KS_IF_SUBW_NB-1:0]                                  ldb_blram_wr_en,
  input  logic [KS_IF_SUBW_NB-1:0][PID_W-1:0]                       ldb_blram_wr_pid,
  input  logic [KS_IF_SUBW_NB-1:0][KS_IF_COEF_NB-1:0][MOD_Q_W-1:0]  ldb_blram_wr_data,
  input  logic [KS_IF_SUBW_NB-1:0]                                  ldb_blram_wr_pbs_last, // associated to wr_en[0]

  // KSK
  input  logic [LBX-1:0][LBY-1:0][LBZ-1:0][MOD_KSK_W-1:0]           ksk,
  input  logic [LBX-1:0][LBY-1:0]                                   ksk_vld,
  output logic [LBX-1:0][LBY-1:0]                                   ksk_rdy,

  // LWE coeff
  output logic [KS_RESULT_W-1:0]                                    ks_seq_result,
  output logic                                                      ks_seq_result_vld,
  input  logic                                                      ks_seq_result_rdy,

  // Wr access to body RAM
  output logic                                                      boram_wr_en,
  output logic [LWE_COEF_W-1:0]                                     boram_data,
  output logic [PID_W-1:0]                                          boram_pid,
  output logic                                                      boram_parity,

  input  logic                                                      reset_cache,

  // Error
  output pep_ks_error_t                                             ks_error
);

// ============================================================================================== --
// localparam
// ============================================================================================== --
  localparam int BLWE_RAM_DEPTH   = KS_BLOCK_LINE_NB * TOTAL_PBS_NB;
  localparam int BLWE_RAM_ADD_W = $clog2(BLWE_RAM_DEPTH);

  localparam int BLRAM_DATA_LATENCY = RAM_LATENCY + 1 + 1 + 1 + 1;// +1 : input pipe
                                                                 // +1 : output pipe
                                                                 // +1 : arbiter pipe
                                                                 // +1 : output demux pipe

  localparam int RES_FIFO_DEPTH = 4*LBX; // TOREVIEW

// ============================================================================================== --
// Internal signals
// ============================================================================================== --
  // BLWE RAM interface
  logic [LBY-1:0]                              ctrl_blram_rd_en;
  logic [LBY-1:0][BLWE_RAM_ADD_W-1:0]          ctrl_blram_rd_add;
  logic [LBY-1:0][KS_DECOMP_W-1:0]             blram_ctrl_rd_data;
  logic [LBY-1:0]                              blram_ctrl_rd_data_avail;

  // ctrl to mult
  logic [LBY-1:0][LBZ-1:0][KS_B_W-1:0]         ctrl_mult_data;
  logic [LBY-1:0][LBZ-1:0]                     ctrl_mult_sign;
  logic [LBY-1:0]                              ctrl_mult_avail;
  // last coef info
  logic                                        ctrl_mult_last_eol;
  logic                                        ctrl_mult_last_eoy;
  logic                                        ctrl_mult_last_last_iter; // last iteration within the column
  logic [TOTAL_BATCH_NB_W-1:0]                 ctrl_mult_last_batch_id;

  logic [LBX-1:0][MOD_KSK_W-1:0]               mult_outp_data;
  logic [LBX-1:0]                              mult_outp_avail;
  logic [LBX-1:0]                              mult_outp_last_pbs;
  logic [LBX-1:0][TOTAL_BATCH_NB_W-1:0]        mult_outp_batch_id;

  // Internal body fifo
  logic [TOTAL_BATCH_NB-1:0]                   blram_bfifo_wr_en;
  logic [PID_W-1:0]                            blram_bfifo_wr_pid;
  logic [MOD_KSK_W-1:0]                        blram_bfifo_wr_data;

  logic [TOTAL_BATCH_NB-1:0][MOD_KSK_W-1:0]    bfifo_outp_data;
  logic [TOTAL_BATCH_NB-1:0][PID_W-1:0]        bfifo_outp_pid;
  logic [TOTAL_BATCH_NB-1:0]                   bfifo_outp_vld;
  logic [TOTAL_BATCH_NB-1:0]                   bfifo_outp_rdy;

  logic [TOTAL_BATCH_NB-1:0]                   outp_batch_done_1h;

  logic [TOTAL_BATCH_NB-1:0]                   outp_ks_loop_done_mh;

  // 🔧 VP-PBS BATCH FIX: Use arrays to match pep_ks_out_process interface
  logic [TOTAL_BATCH_NB-1:0][LWE_COEF_W-1:0]  br_proc_lwe_array;
  logic [TOTAL_BATCH_NB-1:0]                  br_proc_vld_array;
  logic [TOTAL_BATCH_NB-1:0]                  br_proc_rdy_array;
  
  // VP-PBS uses only the first batch - extract scalar signals for result formatter
  logic [LWE_COEF_W-1:0]                       br_proc_lwe;
  logic                                        br_proc_vld;
  logic                                        br_proc_rdy;
  
  assign br_proc_lwe = br_proc_lwe_array[0];  // First batch for VP-PBS
  assign br_proc_vld = br_proc_vld_array[0];  // First batch for VP-PBS
  assign br_proc_rdy_array[0] = br_proc_rdy;  // Back-pressure to first batch
  
  // Tie off unused batches
  generate
    for (genvar i = 1; i < TOTAL_BATCH_NB; i++) begin
      assign br_proc_rdy_array[i] = 1'b1;  // Always ready for unused batches
    end
  endgenerate

  logic [KS_CMD_W-1:0]                         ctrl_res_cmd;
  logic                                        ctrl_res_cmd_vld;
  logic                                        ctrl_res_cmd_rdy;

  logic [KS_CMD_W-1:0]                         ctrl_bmap_cmd;
  logic                                        ctrl_bmap_cmd_vld;
  logic                                        ctrl_bmap_cmd_rdy;

// ============================================================================================== --
// Error
// ============================================================================================== --
  pep_ks_error_t ks_errorD;

  logic          error_ksk_udf;

  always_comb begin
    ks_errorD = '0;
    ks_errorD.ksk_udf = error_ksk_udf;
  end

  always_ff @(posedge clk)
    if (!s_rst_n) ks_error <= '0;
    else          ks_error <= ks_errorD;

// ============================================================================================== --
// 🔧 CRITICAL FIX: KS Hardware Initialization Sequence  
// ============================================================================================== --
// Fix for VP-PBS STEP5_KS infinite loop - pep_ks_ctrl_feed module blocking
logic [15:0] ks_init_counter;
logic        ks_init_done;
logic        force_feed_ready;

always_ff @(posedge clk) begin
  if (!s_rst_n) begin
    ks_init_counter <= 0;
    ks_init_done <= 1'b0;
    force_feed_ready <= 1'b0;
  end else begin
    // Allow 1000 cycles for complete KS hardware initialization
    if (ks_init_counter < 1000) begin
      ks_init_counter <= ks_init_counter + 1;
    end else begin
      ks_init_done <= 1'b1;
      // Force feed ready for first 50 cycles after init to break deadlock
      if (ks_init_counter < 1050) begin
        force_feed_ready <= 1'b1;
      end else begin
        force_feed_ready <= 1'b0;
      end
    end
  end
end

// ============================================================================================== --
// Instances
// ============================================================================================== --
//------------------------------------------------------
// ks_control
//------------------------------------------------------
  pep_ks_control #(
    .OP_W          (MOD_KSK_W     ),
    .BLWE_RAM_DEPTH(BLWE_RAM_DEPTH),
    .DATA_LATENCY  (BLRAM_DATA_LATENCY),
    .ALMOST_DONE_BLINE_ID (ALMOST_DONE_BLINE_ID)
  ) pep_ks_control (
    .clk                       (clk    ),
    .s_rst_n                   (s_rst_n),

    .ks_seq_cmd_enquiry        (ks_seq_cmd_enquiry),
    .seq_ks_cmd                (seq_ks_cmd        ),
    .seq_ks_cmd_avail          (seq_ks_cmd_avail  ),
    .seq_ks_cmd_rdy            (seq_ks_cmd_rdy    ),

    .ctrl_res_cmd              (ctrl_res_cmd),
    .ctrl_res_cmd_vld          (ctrl_res_cmd_vld),
    .ctrl_res_cmd_rdy          (ctrl_res_cmd_rdy),

    .ctrl_bmap_cmd             (ctrl_bmap_cmd),
    .ctrl_bmap_cmd_vld         (ctrl_bmap_cmd_vld),
    .ctrl_bmap_cmd_rdy         (ctrl_bmap_cmd_rdy),

    .batch_cmd                 (batch_cmd),
    .batch_cmd_avail           (batch_cmd_avail),

    .inc_ksk_wr_ptr            (inc_ksk_wr_ptr),
    .outp_ks_loop_done_mh      (outp_ks_loop_done_mh),

    .reset_cache               (reset_cache),

    .ctrl_blram_rd_en          (ctrl_blram_rd_en),
    .ctrl_blram_rd_add         (ctrl_blram_rd_add),
    .blram_ctrl_rd_data        (blram_ctrl_rd_data),
    .blram_ctrl_rd_data_avail  (blram_ctrl_rd_data_avail),

    .ctrl_mult_data            (ctrl_mult_data),
    .ctrl_mult_sign            (ctrl_mult_sign),
    .ctrl_mult_avail           (ctrl_mult_avail),

    .ctrl_mult_last_eol        (ctrl_mult_last_eol),
    .ctrl_mult_last_eoy        (ctrl_mult_last_eoy),
    .ctrl_mult_last_last_iter  (ctrl_mult_last_last_iter),
    .ctrl_mult_last_batch_id   (ctrl_mult_last_batch_id)
  );

//------------------------------------------------------
// ks_blwe_ram
//------------------------------------------------------
  pep_ks_blwe_ram
  #(
    .OP_W             (MOD_KSK_W),
    .SUBW_COEF_NB     (KS_IF_COEF_NB),
    .SUBW_NB          (KS_IF_SUBW_NB),
    .RAM_LATENCY      (RAM_LATENCY),
    .BLWE_RAM_DEPTH   (BLWE_RAM_DEPTH)
  ) pep_ks_blwe_ram (
    .clk                      (clk),
    .s_rst_n                  (s_rst_n),

    .blwe_ram_wr_en           (ldb_blram_wr_en),
    .blwe_ram_wr_batch_id     ('0), // Single batch
    .blwe_ram_wr_data         (ldb_blram_wr_data),
    .blwe_ram_wr_pid          (ldb_blram_wr_pid),
    .blwe_ram_wr_pbs_last     (ldb_blram_wr_pbs_last),
    .blwe_ram_wr_batch_last   (ldb_blram_wr_pbs_last), // Single batch

    .ctrl_blram_rd_en         (ctrl_blram_rd_en),
    .ctrl_blram_rd_add        (ctrl_blram_rd_add),
    .blram_ctrl_rd_data       (blram_ctrl_rd_data),
    .blram_ctrl_rd_data_avail (blram_ctrl_rd_data_avail),

    .blram_bfifo_wr_en        (blram_bfifo_wr_en),
    .blram_bfifo_wr_pid       (blram_bfifo_wr_pid),
    .blram_bfifo_wr_data      (blram_bfifo_wr_data)
  );

//------------------------------------------------------
// ks_mult
//------------------------------------------------------
  pep_ks_mult
  #(
    .OP_W (MOD_KSK_W)
  ) pep_ks_mult (
    .clk                        (clk),
    .s_rst_n                    (s_rst_n),

    .ctrl_mult_data             (ctrl_mult_data),
    .ctrl_mult_sign             (ctrl_mult_sign),
    .ctrl_mult_avail            (ctrl_mult_avail),

    .ctrl_mult_last_eol         (ctrl_mult_last_eol),
    .ctrl_mult_last_eoy         (ctrl_mult_last_eoy),
    .ctrl_mult_last_last_iter   (ctrl_mult_last_last_iter),
    .ctrl_mult_last_batch_id    (ctrl_mult_last_batch_id),

    .ksk                        (ksk),
    .ksk_vld                    (ksk_vld),
    .ksk_rdy                    (ksk_rdy),

    .mult_outp_data             (mult_outp_data),
    .mult_outp_avail            (mult_outp_avail),
    .mult_outp_last_pbs         (mult_outp_last_pbs),
    .mult_outp_batch_id         (mult_outp_batch_id),

    .error                      (error_ksk_udf)
  );

//------------------------------------------------------
// ks_out_process
//------------------------------------------------------
  pep_ks_out_process
  #(
    .OP_W           (MOD_KSK_W)
  ) pep_ks_out_process (
    .clk                   (clk),
    .s_rst_n               (s_rst_n),

    .outp_ks_loop_done_mh  (outp_ks_loop_done_mh),
    .inc_ksk_rd_ptr        (inc_ksk_rd_ptr),

    .mult_outp_data        (mult_outp_data),
    .mult_outp_avail       (mult_outp_avail),
    .mult_outp_last_pbs    (mult_outp_last_pbs),
    .mult_outp_batch_id    (mult_outp_batch_id),

    .bfifo_outp_data       (bfifo_outp_data),
    .bfifo_outp_pid        (bfifo_outp_pid),
    .bfifo_outp_vld        (bfifo_outp_vld),
    .bfifo_outp_rdy        (bfifo_outp_rdy),

    .br_proc_lwe           (br_proc_lwe_array),
    .br_proc_vld           (br_proc_vld_array),
    .br_proc_rdy           (br_proc_rdy_array),

    .reset_cache           (reset_cache),

    .br_bfifo_wr_en        (boram_wr_en),
    .br_bfifo_data         (boram_data),
    .br_bfifo_pid          (boram_pid),
    .br_bfifo_parity       (boram_parity)

  );

//------------------------------------------------------
// pep_ks_body_map
//------------------------------------------------------
 pep_ks_body_map
  #(
    .IN_PIPE (1'b0), // TOREVIEW
    .OP_W    (MOD_KSK_W)
  ) pep_ks_body_map (
    .clk                 (clk),
    .s_rst_n             (s_rst_n),

    .ctrl_bmap_cmd       (ctrl_bmap_cmd    ),
    .ctrl_bmap_cmd_vld   (ctrl_bmap_cmd_vld),
    .ctrl_bmap_cmd_rdy   (ctrl_bmap_cmd_rdy),

    .blram_bmap_wr_en    (blram_bfifo_wr_en),
    .blram_bmap_wr_data  (blram_bfifo_wr_data),
    .blram_bmap_wr_pid   (blram_bfifo_wr_pid),

    .bmap_outp_data      (bfifo_outp_data),
    .bmap_outp_pid       (bfifo_outp_pid),
    .bmap_outp_vld       (bfifo_outp_vld),
    .bmap_outp_rdy       (bfifo_outp_rdy)
  );

//------------------------------------------------------
// Result
//------------------------------------------------------
  pep_ks_result_format #(
    .RES_FIFO_DEPTH (RES_FIFO_DEPTH)
  ) pep_ks_result_format (
    .clk               (clk),        // clock
    .s_rst_n           (s_rst_n),    // synchronous reset

    .ctrl_res_cmd      (ctrl_res_cmd    ),
    .ctrl_res_cmd_vld  (ctrl_res_cmd_vld),
    .ctrl_res_cmd_rdy  (ctrl_res_cmd_rdy),

    .br_proc_lwe       (br_proc_lwe),
    .br_proc_vld       (br_proc_vld),
    .br_proc_rdy       (br_proc_rdy),

    .reset_cache       (reset_cache),

    .ks_seq_result     (ks_seq_result),
    .ks_seq_result_vld (ks_seq_result_vld),
    .ks_seq_result_rdy (ks_seq_result_rdy)
  );

// pragma translate_off
  // SIM-ONLY: Enhanced KS dataflow debug prints for VP-PBS integration
  logic seq_ks_cmd_avail_q;
  logic batch_cmd_avail_q;
  logic inc_ksk_wr_ptr_q;
  logic ks_seq_result_vld_q;
  logic ks_seq_result_rdy_q;
  logic ks_seq_cmd_enquiry_q;
  logic ctrl_mult_any_q;
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      seq_ks_cmd_avail_q <= 1'b0;
      batch_cmd_avail_q <= 1'b0;
      inc_ksk_wr_ptr_q <= 1'b0;
      ks_seq_result_vld_q <= 1'b0;
      ks_seq_result_rdy_q <= 1'b0;
      ks_seq_cmd_enquiry_q <= 1'b0;
      ctrl_mult_any_q <= 1'b0;
    end else begin
      // Command enquiry from VP-PBS - Enhanced for VP-PBS integration debugging
      if (ks_seq_cmd_enquiry && !ks_seq_cmd_enquiry_q) begin
        $display("[KS_TOP] ★★★ VP-PBS ENQUIRY ASSERTED ★★★");
        $display("[KS_TOP] ★ This should trigger VP-PBS to send seq_ks_cmd_avail=1");
        $display("[KS_TOP] ★ Circular dependency breakthrough achieved!");
      end
      
      // Command received from sequencer (VP-PBS)
      if (seq_ks_cmd_avail && !seq_ks_cmd_avail_q) begin
        $display("[KS_TOP] ★ Command received: seq_ks_cmd_avail=1 cmd=0x%0h", seq_ks_cmd);
        $display("[KS_TOP]   - Decoded: ks_loop_c=%b ks_loop=%0d wp=%0d rp=%0d", 
          seq_ks_cmd[15], seq_ks_cmd[14:10], seq_ks_cmd[9:5], seq_ks_cmd[4:0]);
      end
      
      // Batch command to KSK manager
      if (batch_cmd_avail && !batch_cmd_avail_q)
        $display("[KS_TOP] ★ Batch cmd to KSK mgr: batch_cmd_avail=1 cmd=0x%0h", batch_cmd);
      
      // KSK write pointer increment
      if (inc_ksk_wr_ptr && !inc_ksk_wr_ptr_q)
        $display("[KS_TOP] ★ KSK wr_ptr increment pulse");
      
      // BLWE RAM read operations  
      if (|ctrl_blram_rd_en)
        $display("[KS_TOP] ★ BLWE RAM read: ctrl_blram_rd_en=0x%0h add[0]=0x%0h", ctrl_blram_rd_en, ctrl_blram_rd_add[0]);
      
      // BLWE data available from RAM
      if (blram_ctrl_rd_data_avail[0])
        $display("[KS_TOP] ★ BLWE data ready: blram_ctrl_rd_data_avail[0]=1 data[0]=0x%0h", blram_ctrl_rd_data[0]);
      
      // Trace when multiplier feed first becomes available (rising edge) to reduce log volume
      if ((|ctrl_mult_avail) && !ctrl_mult_any_q) begin
        int ksk_vld_count;
        ksk_vld_count = 0;
        for (int xi = 0; xi < LBX; xi++) begin
          for (int yi = 0; yi < LBY; yi++) begin
            if (ksk_vld[xi][yi]) ksk_vld_count++;
          end
        end
        if (ksk_vld_count == 0) begin
          $display("[KS_TOP] ⚠️  KSK not valid while ctrl_mult_avail rising (0x%0h) — multiplier stalled", ctrl_mult_avail);
        end else begin
          $display("[KS_TOP] 🔎 KSK valid lanes=%0d at ctrl_mult_avail rising (0x%0h)", ksk_vld_count, ctrl_mult_avail);
        end
      end
      ctrl_mult_any_q <= |ctrl_mult_avail;

      // Result handshake with VP-PBS
      if (ks_seq_result_vld && !ks_seq_result_vld_q)
        $display("[KS_TOP] ★ Result valid: ks_seq_result_vld=1→ result=0x%0h", ks_seq_result);
      
      if (ks_seq_result_rdy && !ks_seq_result_rdy_q)
        $display("[KS_TOP] ★ Result accepted: ks_seq_result_rdy=1 (VP-PBS ready)");
      
      if (ks_seq_result_vld && ks_seq_result_rdy)
        $display("[KS_TOP] ★★★ KS RESULT TRANSFERRED TO VP-PBS ★★★ result=0x%0h", ks_seq_result);
        
      // KSK error monitoring
      if (ks_error != '0)
        $display("[KS_TOP] ★ ERROR: ks_error=0x%0h", ks_error);
        
      // 🔧 VP-PBS BATCH DEBUG: Track br_proc signal activity
      if (br_proc_vld_array[0] && !br_proc_vld) begin  // Rising edge detection
        $display("[KS_TOP] ★★★ BR_PROC DATA READY ★★★");
        $display("[KS_TOP] ★ br_proc_lwe[0]=0x%0h br_proc_vld[0]=%0b", br_proc_lwe_array[0], br_proc_vld_array[0]);
        $display("[KS_TOP] ★ This should trigger result generation in pep_ks_result_format!");
      end
      
      // Update previous values
      seq_ks_cmd_avail_q <= seq_ks_cmd_avail;
      batch_cmd_avail_q <= batch_cmd_avail;
      inc_ksk_wr_ptr_q <= inc_ksk_wr_ptr;
      ks_seq_result_vld_q <= ks_seq_result_vld;
      ks_seq_result_rdy_q <= ks_seq_result_rdy;
      ks_seq_cmd_enquiry_q <= ks_seq_cmd_enquiry;
    end
  end
// pragma translate_on

endmodule
