// ==============================================================================================
// BSD 3-Clause Clear License
// Copyright © 2025 ZAMA. All rights reserved.
// ----------------------------------------------------------------------------------------------
// Description  :
// ----------------------------------------------------------------------------------------------
//
// This module deals with the reading of BLWE coefficients
// for the KS operation.
// ==============================================================================================

module pep_ks_control
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import pep_common_param_pkg::*;
  import pep_ks_common_param_pkg::*;
#(
  parameter  int OP_W             = 64,
  parameter  int BLWE_RAM_DEPTH   = (BLWE_K+LBY-1)/LBY * TOTAL_PBS_NB,
  localparam int BLWE_RAM_ADD_W   = $clog2(BLWE_RAM_DEPTH),
  parameter  int DATA_LATENCY     = 6, // RAM access read latency
  parameter  int ALMOST_DONE_BLINE_ID = 0
)
(
  input  logic                                clk,        // clock
  input  logic                                s_rst_n,    // synchronous reset

  // Sequencer command
  output logic                                ks_seq_cmd_enquiry,
  input  logic [KS_CMD_W-1:0]                 seq_ks_cmd,
  input  logic                                seq_ks_cmd_avail,
  output logic                                seq_ks_cmd_rdy,

  // Command for result_format
  output logic [KS_CMD_W-1:0]                 ctrl_res_cmd,
  output logic                                ctrl_res_cmd_vld,
  input  logic                                ctrl_res_cmd_rdy,

  // Command for body map
  output logic [KS_CMD_W-1:0]                 ctrl_bmap_cmd,
  output logic                                ctrl_bmap_cmd_vld,
  input  logic                                ctrl_bmap_cmd_rdy,

  // ksk_if
  input  logic                                inc_ksk_wr_ptr,
  // Output FIFO
  input  logic                                outp_ks_loop_done_mh,

  // reset cache
  input  logic                                reset_cache,

  // To ksk manager
  output logic [KS_BATCH_CMD_W-1:0]           batch_cmd,
  output logic                                batch_cmd_avail, // pulse

  // BLWE RAM interface
  output logic [LBY-1:0]                      ctrl_blram_rd_en,
  output logic [LBY-1:0][BLWE_RAM_ADD_W-1:0]  ctrl_blram_rd_add,
  input  logic [LBY-1:0][KS_DECOMP_W-1:0]     blram_ctrl_rd_data,
  input  logic [LBY-1:0]                      blram_ctrl_rd_data_avail,

  // Output to mult
  output logic [LBY-1:0][LBZ-1:0][KS_B_W-1:0] ctrl_mult_data,
  output logic [LBY-1:0][LBZ-1:0]             ctrl_mult_sign,
  output logic [LBY-1:0]                      ctrl_mult_avail,
  // last coef info
  output logic                                ctrl_mult_last_eol,
  output logic                                ctrl_mult_last_eoy,
  output logic                                ctrl_mult_last_last_iter, // last iteration within the column
  output logic [TOTAL_BATCH_NB_W-1:0]         ctrl_mult_last_batch_id // Unused. Is a constant.

);

// ============================================================================================== --
// Parameter
// ============================================================================================== --
// Check
  generate
    if (KS_BLOCK_COL_NB < 2) begin : __UNSUPPORTED_KS_BLOCK_COL_NB
      $fatal(1,"> ERROR: Unsupported KS_BLOCK_COL_NB (%0d), should be greater or equal to 2.", KS_BLOCK_COL_NB);
    end
  endgenerate

// ============================================================================================== --
// Input pipe
// ============================================================================================== --
  logic                  reset_loop;

  always_ff @(posedge clk)
    if (!s_rst_n) reset_loop <= 1'b0;
    else          reset_loop <= reset_cache;

// The sequencer command, contains the command for 1 BCOL process.
  //== cmd
  logic                  seq_ks_cmd_vld;

  ks_cmd_t               s0_cmd;
  logic                  s0_cmd_in_vld;
  logic                  s0_cmd_in_rdy;
  logic [BPBS_NB_WW-1:0] s0_cmd_ct_nb_m1;

  assign s0_cmd_ct_nb_m1 = pt_elt_nb(s0_cmd.wp, s0_cmd.rp) - 1;

  assign seq_ks_cmd_vld = seq_ks_cmd_avail;

  fifo_element #(
    .WIDTH          (KS_CMD_W),
    .DEPTH          (1),
    .TYPE_ARRAY     (4'h3),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) s0_cmd_fifo_element (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  (seq_ks_cmd),
    .in_vld   (seq_ks_cmd_vld),
    .in_rdy   (seq_ks_cmd_rdy),

    .out_data (s0_cmd),
    .out_vld  (s0_cmd_in_vld),
    .out_rdy  (s0_cmd_in_rdy)
  );

// pragma translate_off
  // Circuit breaker to prevent infinite debug printing
  logic [15:0] debug_print_counter;
  logic [7:0]  rdy_debug_counter;
  
  // Declare s0_cmd_rdy here to avoid "used before declaration" error
  logic s0_cmd_rdy;
  
  // Enhanced debug prints for KS control flow tracking
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      debug_print_counter <= 0;
    end else begin
      if (seq_ks_cmd_vld) begin
        if (!seq_ks_cmd_rdy) begin
          // Circuit breaker: Only print first 100 occurrences to prevent log overflow
          if (debug_print_counter < 100) begin
            $display("[KS_CTRL] ⚠️ WARNING: s0_cmd_fifo_element not ready, waiting for next cycle... (count=%0d)", debug_print_counter);
            $display("[KS_CTRL] 🔍 FIFO_DEBUG: seq_ks_cmd_rdy=%b s0_cmd_rdy=%b ctrl_res_cmd_rdy=%b ctrl_bmap_cmd_rdy=%b", 
              seq_ks_cmd_rdy, s0_cmd_rdy, ctrl_res_cmd_rdy, ctrl_bmap_cmd_rdy);
            debug_print_counter <= debug_print_counter + 1;
          end else if (debug_print_counter == 100) begin
            $display("[KS_CTRL] 🚫 CIRCUIT BREAKER: Stopping debug prints after 100 cycles. KS FIFO permanently not ready!");
            $display("[KS_CTRL] 🔍 Final state: seq_ks_cmd_rdy=%b s0_cmd_rdy=%b ctrl_res_cmd_rdy=%b ctrl_bmap_cmd_rdy=%b", 
              seq_ks_cmd_rdy, s0_cmd_rdy, ctrl_res_cmd_rdy, ctrl_bmap_cmd_rdy);
            debug_print_counter <= debug_print_counter + 1;
          end
        end else begin
          // Command ready, proceed with processing
          $display("[KS_CTRL] ★ Command processing: seq_ks_cmd=0x%0h rdy=%0d", seq_ks_cmd, seq_ks_cmd_rdy);
          $display("[KS_CTRL]   - Raw command decode: ks_loop_c=%b ks_loop=%0d wp=%0d rp=%0d", 
            seq_ks_cmd[15], seq_ks_cmd[14:10], seq_ks_cmd[9:5], seq_ks_cmd[4:0]);
          debug_print_counter <= 0; // Reset counter when successful
        end
      end
    end
    
    // 🔧 CRITICAL DEBUG: Monitor seq_ks_cmd_rdy state continuously  
    if (rdy_debug_counter == 0) begin
      $display("[KS_CTRL] 🔍 READY STATE: seq_ks_cmd_rdy=%b s0_cmd_rdy=%b ctrl_res_rdy=%b ctrl_bmap_rdy=%b in_vld=%b", 
               seq_ks_cmd_rdy, s0_cmd_rdy, ctrl_res_cmd_rdy, ctrl_bmap_cmd_rdy, seq_ks_cmd_vld);
    end
    rdy_debug_counter <= rdy_debug_counter + 1;
    
    // Track command forwarding to result formatter and body mapper
    if (ctrl_res_cmd_vld && ctrl_res_cmd_rdy)
      $display("[KS_CTRL] ★ Command sent to result formatter: cmd=0x%0h", ctrl_res_cmd);
    
    if (ctrl_bmap_cmd_vld && ctrl_bmap_cmd_rdy)  
      $display("[KS_CTRL] ★ Command sent to body mapper: cmd=0x%0h", ctrl_bmap_cmd);
  end
// pragma translate_on

  //== Fork the command between the main path and the other paths
  logic s0_cmd_vld;

  assign s0_cmd_vld        = s0_cmd_in_vld & ctrl_res_cmd_rdy & ctrl_bmap_cmd_rdy;
  assign ctrl_res_cmd_vld  = s0_cmd_in_vld & s0_cmd_rdy       & ctrl_bmap_cmd_rdy;
  assign ctrl_bmap_cmd_vld = s0_cmd_in_vld & ctrl_res_cmd_rdy & s0_cmd_rdy;
  assign s0_cmd_in_rdy     = s0_cmd_rdy    & ctrl_res_cmd_rdy & ctrl_bmap_cmd_rdy;

  assign ctrl_res_cmd      = s0_cmd;
  assign ctrl_bmap_cmd     = s0_cmd;

  // pointers
  logic s0_inc_ksk_wr_ptr;
  logic s0_inc_ksk_rd_ptr;

  always_ff @(posedge clk)
    if (!s_rst_n) s0_inc_ksk_wr_ptr <= '0;
    else          s0_inc_ksk_wr_ptr <= inc_ksk_wr_ptr;

// ============================================================================================== --
// KSK pointer
// ============================================================================================== --
  // Keep track of the filling of the KSK. Do not start command if the key is not present.
  logic [KS_BLOCK_COL_W:0] ksk_wp;
  logic [KS_BLOCK_COL_W:0] ksk_rp;
  logic [KS_BLOCK_COL_W:0] ksk_wpD;
  logic [KS_BLOCK_COL_W:0] ksk_rpD;
  logic                ksk_empty;
  logic                ksk_full;
  logic                ksk_wp_last;
  logic                ksk_rp_last;

  always_ff @(posedge clk)
    if (!s_rst_n || reset_loop) begin
      ksk_wp <= '0;
      ksk_rp <= '0;
    end
    else begin
      ksk_rp <= ksk_rpD;
      ksk_wp <= ksk_wpD;
    end

  assign ksk_wp_last = ksk_wp == (KS_BLOCK_COL_NB-1);
  assign ksk_rp_last = ksk_rp == (KS_BLOCK_COL_NB-1);

  assign ksk_empty = ksk_rp == ksk_wp;
  assign ksk_full  = (ksk_rp[KS_BLOCK_COL_W-1:0] == ksk_wp[KS_BLOCK_COL_W-1:0]) & (ksk_rp[KS_BLOCK_COL_W] != ksk_wp[KS_BLOCK_COL_W]);

  assign ksk_wpD = s0_inc_ksk_wr_ptr ? ksk_wp_last ? {~ksk_wp[KS_BLOCK_COL_W],{KS_BLOCK_COL_W{1'b0}}} : ksk_wp + 1 : ksk_wp;
  assign ksk_rpD = s0_inc_ksk_rd_ptr ? ksk_rp_last ? {~ksk_rp[KS_BLOCK_COL_W],{KS_BLOCK_COL_W{1'b0}}} : ksk_rp + 1 : ksk_rp;

// pragma translate_off
  always_ff @(posedge clk)
    if (!s_rst_n) begin
      // do nothing
    end
    else begin
      if (s0_inc_ksk_wr_ptr) begin
        assert(!ksk_full)
        else begin
          $fatal(1,"%t> ERROR: Increase ksk write pointer, while it is already full.",$time);
        end
      end
      if (s0_inc_ksk_rd_ptr) begin
        assert(!ksk_empty)
        else begin
          $fatal(1,"%t> ERROR: Increase ksk read pointer, while it is empty.",$time);
        end
      end
    end
// pragma translate_on

// ============================================================================================== --
// Process
// ============================================================================================== --
  proc_cmd_t ffifo_in_pcmd;
  logic      ffifo_in_vld;
  logic      ffifo_in_rdy;

  proc_cmd_t ffifo_out_pcmd;
  logic      ffifo_out_vld;
  logic      ffifo_out_rdy;

//-------------------------------------------------------------------------------------------------
// Feed FIFO
//-------------------------------------------------------------------------------------------------
  logic [KS_BLOCK_COL_W-1:0] s0_ks_loop;
  logic [KS_BLOCK_COL_W-1:0] s0_ks_loopD;
  logic                      s0_last_ks_loop;

  assign s0_last_ks_loop = s0_ks_loop == KS_BLOCK_COL_NB-1;
  assign s0_ks_loopD = (ffifo_in_vld && ffifo_in_rdy) ? s0_last_ks_loop ? '0 : s0_ks_loop + 1 : s0_ks_loop;

  always_ff @(posedge clk)
    if (!s_rst_n || reset_loop) s0_ks_loop <= '0;
    else                        s0_ks_loop <= s0_ks_loopD;

  fifo_element #(
    .WIDTH          (PROC_CMD_W),
    .DEPTH          (1),
    .TYPE_ARRAY     (4'h1),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) feed_fifo (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  (ffifo_in_pcmd),
    .in_vld   (ffifo_in_vld),
    .in_rdy   (ffifo_in_rdy),

    .out_data (ffifo_out_pcmd),
    .out_vld  (ffifo_out_vld),
    .out_rdy  (ffifo_out_rdy)
  );

  // Loopback path has priority over input new command
  assign ffifo_in_vld              = s0_cmd_vld;
  assign s0_cmd_rdy                = ffifo_in_rdy;
  assign ffifo_in_pcmd.first_pid   = s0_cmd.rp[PID_W-1:0];
  assign ffifo_in_pcmd.batch_id    = '0;
  assign ffifo_in_pcmd.batch_id_1h = 1;
  assign ffifo_in_pcmd.pbs_cnt_max = s0_cmd_ct_nb_m1;
  assign ffifo_in_pcmd.ks_loop     = s0_ks_loop;

// pragma translate_off
  always_ff @(posedge clk)
    if (s0_cmd_vld && s0_cmd_rdy) begin
      $display("[KS_CTRL] LOOP_DEBUG: LBX=%0d, cmd.ks_loop=%0d, internal s0_ks_loop=%0d", LBX, s0_cmd.ks_loop, s0_ks_loop);
      // In the command, ks_loop indicates the LWE_K_P1 column.
      assert(s0_ks_loop == s0_cmd.ks_loop / LBX)
      else begin
        $fatal(1,"%t > ERROR: ks_loop mismatch: internal_counter=%0d, command=%0d", $time,s0_ks_loop, s0_cmd.ks_loop / LBX);
      end
    end
// pragma translate_on

//-------------------------------------------------------------------------------------------------
// Feed process
//-------------------------------------------------------------------------------------------------
  logic proc_almost_done;
  pep_ks_ctrl_feed
  #(
    .DATA_LATENCY   (DATA_LATENCY),
    .BLWE_RAM_DEPTH (BLWE_RAM_DEPTH),
    .ALMOST_DONE_BLINE_ID (ALMOST_DONE_BLINE_ID)
  ) pep_ks_ctrl_feed (
    .clk                        (clk),
    .s_rst_n                    (s_rst_n),

    .reset_cache                (reset_cache),

    .ksk_empty                  (ksk_empty),
    .inc_ksk_rd_ptr             (s0_inc_ksk_rd_ptr),
    .ofifo_inc_rp               (outp_ks_loop_done_mh),

    .ffifo_feed_pcmd            (ffifo_out_pcmd),
    .ffifo_feed_vld             (ffifo_out_vld),
    .ffifo_feed_rdy             (ffifo_out_rdy),

    .ctrl_blram_rd_en           (ctrl_blram_rd_en),
    .ctrl_blram_rd_add          (ctrl_blram_rd_add),
    .blram_ctrl_rd_data         (blram_ctrl_rd_data),
    .blram_ctrl_rd_data_avail   (blram_ctrl_rd_data_avail),

    .ctrl_mult_avail            (ctrl_mult_avail),
    .ctrl_mult_data             (ctrl_mult_data),
    .ctrl_mult_sign             (ctrl_mult_sign),
    .ctrl_mult_last_eol         (ctrl_mult_last_eol),
    .ctrl_mult_last_eoy         (ctrl_mult_last_eoy),
    .ctrl_mult_last_last_iter   (ctrl_mult_last_last_iter),
    .ctrl_mult_last_batch_id    (ctrl_mult_last_batch_id),

    .batch_cmd                  (batch_cmd),
    .batch_cmd_avail            (batch_cmd_avail),

    .proc_almost_done           (proc_almost_done)
  );

// pragma translate_off
  // SIM-ONLY: Trace feed path activity to debug missing mult/result activity
  logic [LBY-1:0] ctrl_mult_avail_q;
  logic [LBY-1:0] blram_ctrl_rd_data_avail_q;
  logic           ffifo_out_vld_q, ffifo_out_rdy_q;
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      ctrl_mult_avail_q <= '0;
      blram_ctrl_rd_data_avail_q <= '0;
      ffifo_out_vld_q <= 1'b0;
      ffifo_out_rdy_q <= 1'b0;
    end else begin
      if ((|ctrl_mult_avail) && !(|ctrl_mult_avail_q)) begin
        $display("[KS_CTRL][FEED] ★ ctrl_mult_avail asserted: 0x%0h eol=%0b eoy=%0b last_iter=%0b", 
                 ctrl_mult_avail, ctrl_mult_last_eol, ctrl_mult_last_eoy, ctrl_mult_last_last_iter);
      end
      if ((|blram_ctrl_rd_data_avail) && !(|blram_ctrl_rd_data_avail_q)) begin
        $display("[KS_CTRL][FEED] ★ BLWE data avail: 0x%0h", blram_ctrl_rd_data_avail);
      end
      if ((ffifo_out_vld && ffifo_out_rdy) && !(ffifo_out_vld_q && ffifo_out_rdy_q)) begin
        $display("[KS_CTRL][FEED] ★ FFIFO OUT handshake: vld=1 rdy=1 ks_loop=%0d", ffifo_out_pcmd.ks_loop);
      end
      ctrl_mult_avail_q <= ctrl_mult_avail;
      blram_ctrl_rd_data_avail_q <= blram_ctrl_rd_data_avail;
      ffifo_out_vld_q <= ffifo_out_vld;
      ffifo_out_rdy_q <= ffifo_out_rdy;
    end
  end
// pragma translate_on

//-------------------------------------------------------------------------------------------------
// Enquiry
//-------------------------------------------------------------------------------------------------
// Build the very first enquiry after the reset
// Set it some cycle after the reset. TOREVIEW
  localparam int ENQ_DEPTH = 8;
  logic [ENQ_DEPTH-1:0] enq_init;
  logic [ENQ_DEPTH-1:0] enq_initD;

  logic pending_cmd;
  logic pending_cmdD;

  logic ks_seq_cmd_enquiryD;

  // 🔧 VP-PBS INTEGRATION FIX: Add VP-PBS compatible enquiry generation
  logic vp_pbs_initial_enquiry;  // Allow initial enquiry without pending command
  logic first_enquiry_sent;      // Track if initial enquiry has been sent

  // 🔧 VP-PBS TIMING FIX: pending_cmd logic should maintain enquiry until handshake
  assign pending_cmdD = seq_ks_cmd_avail   ? 1'b0 :  // Clear when VP-PBS sends command (processing starts)
                        proc_almost_done   ? 1'b1 :  // Set when processing completes (ready for next)  
                        pending_cmd;                  // Otherwise maintain current state
  assign enq_initD = enq_init << 1;
  
  // VP-PBS compatible enquiry generation: Initial enquiry OR standard protocol  
  assign vp_pbs_initial_enquiry = enq_init[ENQ_DEPTH-1] & ~first_enquiry_sent;
  
  // 🔧 VP-PBS TIMING FIX: Hold enquiry until handshake completes
  logic enquiry_hold;  // Hold enquiry signal until VP-PBS responds
  assign ks_seq_cmd_enquiryD = vp_pbs_initial_enquiry | 
                               (enq_init[ENQ_DEPTH-1] & pending_cmd) | 
                               proc_almost_done |
                               (enquiry_hold & ~seq_ks_cmd_avail);  // Hold until response

  always_ff @(posedge clk)
    if (!s_rst_n || reset_loop) begin
      enq_init <= 1;
      first_enquiry_sent <= 1'b0;  // Reset enquiry tracking
      enquiry_hold <= 1'b0;        // Reset enquiry hold
    end
    else begin
      enq_init <= enq_initD;
      // Set first_enquiry_sent when initial enquiry is generated
      if (vp_pbs_initial_enquiry) begin
        first_enquiry_sent <= 1'b1;
      end
      
      // 🔧 VP-PBS TIMING FIX: Set enquiry_hold when enquiry generated, clear when VP-PBS responds
      if ((vp_pbs_initial_enquiry | (enq_init[ENQ_DEPTH-1] & pending_cmd) | proc_almost_done) & ~enquiry_hold) begin
        enquiry_hold <= 1'b1;  // Start holding enquiry
      end else if (seq_ks_cmd_avail) begin
        enquiry_hold <= 1'b0;  // Clear hold when VP-PBS responds
      end
    end

  always_ff @(posedge clk)
    if (!s_rst_n) begin
      ks_seq_cmd_enquiry <= 1'b0;
      pending_cmd        <= 1'b1;  // 🔧 CRITICAL: Initialize as ready for commands
    end
    else begin
      ks_seq_cmd_enquiry <= ks_seq_cmd_enquiryD;
      pending_cmd        <= pending_cmdD;
    end

// pragma translate_off
  // Enhanced debug prints for KS control dataflow tracking
  logic ks_seq_cmd_enquiry_q;
  logic batch_cmd_avail_q;
  always_ff @(posedge clk) begin
    if (!s_rst_n) begin
      ks_seq_cmd_enquiry_q <= 1'b0;
      batch_cmd_avail_q <= 1'b0;
    end else begin
      if (reset_loop) begin
        $display("[KS_CTRL] ★ reset_loop=1 (reset_cache asserted)");
      end
      
      if (ks_seq_cmd_enquiryD && !ks_seq_cmd_enquiry_q) begin
        $display("[KS_CTRL] ★★★ VP-PBS ENQUIRY GENERATED ★★★");
        $display("[KS_CTRL] ★ ENQ asserted: enq_init_msb=%0b pending_cmd=%0b proc_almost_done=%0b", 
          enq_init[ENQ_DEPTH-1], pending_cmd, proc_almost_done);
        $display("[KS_CTRL] ★ VP-PBS FIX: vp_pbs_initial=%0b first_enq_sent=%0b", 
          vp_pbs_initial_enquiry, first_enquiry_sent);
        if (vp_pbs_initial_enquiry) begin
          $display("[KS_CTRL] ★★★ BREAKTHROUGH: VP-PBS INITIAL ENQUIRY TRIGGERED ★★★");
          $display("[KS_CTRL] ★ This should break the circular dependency deadlock!");
        end
      end
      
      // Track batch command generation to KSK manager
      if (batch_cmd_avail && !batch_cmd_avail_q) begin
        // Print as raw vector to avoid mismatched field indexing during debug
        $display("[KS_CTRL] ★ Batch command generated (raw)=0x%0h", batch_cmd);
      end
      
      // Track FIFO operations
      if (ffifo_in_vld && ffifo_in_rdy) begin
        $display("[KS_CTRL] ★ FIFO input: first_pid=%0d ks_loop=%0d pbs_cnt_max=%0d", 
          ffifo_in_pcmd.first_pid, ffifo_in_pcmd.ks_loop, ffifo_in_pcmd.pbs_cnt_max);
      end
      
      if (ffifo_out_vld && ffifo_out_rdy) begin
        $display("[KS_CTRL] ★ FIFO output: first_pid=%0d ks_loop=%0d pbs_cnt_max=%0d", 
          ffifo_out_pcmd.first_pid, ffifo_out_pcmd.ks_loop, ffifo_out_pcmd.pbs_cnt_max);
      end
      
      ks_seq_cmd_enquiry_q <= ks_seq_cmd_enquiryD;
      batch_cmd_avail_q <= batch_cmd_avail;
    end
    
    // 🔧 VP-PBS KSK Pointer Debug - Track why KSK is always empty
    if (s0_inc_ksk_wr_ptr) begin
      $display("[KS_CTRL] ★ KSK WR_PTR increment: wp=%0d→%0d (was_last=%0b)", ksk_wp, ksk_wpD, ksk_wp_last);
      $display("[KS_CTRL]   - KSK status after increment: empty=%0b full=%0b", ksk_empty, ksk_full);
    end
    
    if (s0_inc_ksk_rd_ptr) begin
      $display("[KS_CTRL] ★ KSK RD_PTR increment: rp=%0d→%0d (was_last=%0b)", ksk_rp, ksk_rpD, ksk_rp_last);  
      $display("[KS_CTRL]   - KSK status after increment: empty=%0b full=%0b", ksk_empty, ksk_full);
    end
  end
// pragma translate_on

endmodule
