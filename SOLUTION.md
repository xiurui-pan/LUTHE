# KSK Hardware Integration Multiple Driver Conflict - Production Solution

## Root Cause Analysis

The KS command corruption from `0x1` to `0x70` is caused by a **multiple driver conflict** in the KS command interface. The issue occurs because:

1. **wop_pbs_kernel_lite.sv** has its own internal `pep_key_switch` instance with KS command generation logic
2. **pep_sequencer.sv** also generates KS commands for regular PBS operations  
3. Both modules attempt to drive the same KS command signals simultaneously, creating electrical bus conflicts

## Detailed Technical Analysis

### Driver Sources
1. **VP-PBS Driver** (`wop_pbs_kernel_lite.sv:1919`):
   ```systemverilog
   seq_ks_cmd = {{(KS_CMD_W-3){1'b0}}, 3'b001}; // Produces 0x1
   ```

2. **Regular PBS Driver** (`pep_sequencer.sv:835`):
   ```systemverilog
   seq_ks_cmd <= u1_cmd; // Produces 0x70
   ```

### Conflict Result
- Expected: `seq_ks_cmd=0x1` (ks_loop=0, rp=0, wp=1)
- Actual: `cmd=0x70` (corrupted by bus conflict)
- Error: "batch_cmd does not match a unique slot! (sm1_slot_1h=0x00)"

## Production-Grade Solution

### Approach 1: Remove Duplicate KS Instance (Recommended)

The `wop_pbs_kernel_lite.sv` module should NOT have its own `pep_key_switch` instance. Instead, it should use the shared KS infrastructure through proper interface signals.

#### Implementation Steps:

1. **Remove Internal KS Instance** from `wop_pbs_kernel_lite.sv`:
   ```systemverilog
   // REMOVE: Lines 1738-1786 (entire pep_key_switch instantiation)
   ```

2. **Convert KS Signals to Output Ports** in `wop_pbs_kernel_lite.sv`:
   ```systemverilog
   // Change from internal logic to output ports
   input  logic                     ks_seq_cmd_enquiry,
   output logic [KS_CMD_W-1:0]     seq_ks_cmd,
   output logic                     seq_ks_cmd_avail,
   
   // Add KS result interface
   input  logic [KS_RESULT_W-1:0]  ks_seq_result,
   input  logic                     ks_seq_result_vld,
   output logic                     ks_seq_result_rdy
   ```

3. **Update Module Port List** in `wop_pbs_kernel_lite.sv`:
   Add KS interface ports to the module declaration.

4. **Modify Testbench Connection** in `tb_wop_vertical_packing_engine.sv`:
   ```systemverilog
   // Connect VP-PBS to shared KS interface
   .ks_seq_cmd_enquiry(ks_seq_cmd_enquiry),
   .seq_ks_cmd(vp_seq_ks_cmd),
   .seq_ks_cmd_avail(vp_seq_ks_cmd_avail),
   .ks_seq_result(ks_seq_result),
   .ks_seq_result_vld(ks_seq_result_vld), 
   .ks_seq_result_rdy(vp_ks_seq_result_rdy)
   ```

5. **Add KS Arbitration Logic** in testbench:
   ```systemverilog
   // VP-PBS has priority when active
   logic vp_pbs_ks_active;
   assign vp_pbs_ks_active = vp_seq_ks_cmd_avail;
   
   // Arbitrated outputs
   assign seq_ks_cmd = vp_pbs_ks_active ? vp_seq_ks_cmd : regular_seq_ks_cmd;
   assign seq_ks_cmd_avail = vp_pbs_ks_active ? vp_seq_ks_cmd_avail : regular_seq_ks_cmd_avail;
   
   // Route results back appropriately
   assign ks_seq_result_rdy = vp_pbs_ks_active ? vp_ks_seq_result_rdy : regular_ks_seq_result_rdy;
   ```

### Approach 2: Enable/Disable Logic (Alternative)

If removing the internal KS instance is not feasible, add enable/disable logic:

1. **Add VP-PBS Active Signal**:
   ```systemverilog
   logic vp_pbs_ks_mode_active;
   assign vp_pbs_ks_mode_active = (current_state == POST_PROCESSING || 
                                   current_state == STEP5_KEY_SWITCHING);
   ```

2. **Conditional KS Interface Driving**:
   ```systemverilog
   // Only drive KS interface when VP-PBS is active
   always_comb begin
     if (vp_pbs_ks_mode_active) begin
       // VP-PBS drives the interface
       seq_ks_cmd_avail = vp_ks_cmd_avail_internal;
       seq_ks_cmd = vp_ks_cmd_internal;
     end else begin
       // High-impedance when inactive
       seq_ks_cmd_avail = 1'bZ;
       seq_ks_cmd = {KS_CMD_W{1'bZ}};
     end
   end
   ```

3. **Add External Override Mechanism**:
   ```systemverilog
   // Allow external system to disable VP-PBS KS interface
   input logic vp_pbs_ks_enable;
   ```

## Implementation Priority

### Phase 1: Immediate Fix (Approach 1)
- Remove duplicate KS instance from `wop_pbs_kernel_lite.sv`
- Add proper port interface 
- Update testbench connections with arbitration

### Phase 2: Integration Testing
- Verify VP-PBS KS commands reach KSK manager correctly
- Test regular PBS operation remains unaffected
- Validate slot matching in KSK manager

### Phase 3: Optimization
- Implement proper handshaking protocols
- Add error detection for KS command corruption
- Performance tuning and timing closure

## Files to Modify

1. `/home/pxr/workspace/hpu_fpga/hw/module/pe_pbs/rtl/wop_pbs_kernel_lite.sv`
2. `/home/pxr/workspace/hpu_fpga/hw/module/pe_pbs/simu/tb_wop_vertical_packing_engine/rtl/tb_wop_vertical_packing_engine.sv`
3. Potentially: KSK manager slot matching logic if needed

## Verification Strategy

1. **Signal Integrity**: Ensure seq_ks_cmd maintains expected values
2. **Functional Testing**: VP-PBS and regular PBS both work independently  
3. **Integration Testing**: Verify proper arbitration when both are active
4. **Performance Testing**: No degradation in KS command response time

## Success Criteria

- ✅ No multiple driver conflicts in synthesis
- ✅ seq_ks_cmd = 0x1 reaches KSK manager without corruption
- ✅ KSK manager slot matching succeeds
- ✅ VP-PBS key switching completes successfully
- ✅ Regular PBS operation unaffected

This solution addresses the fundamental architectural issue while maintaining system functionality and enabling proper VP-PBS integration.