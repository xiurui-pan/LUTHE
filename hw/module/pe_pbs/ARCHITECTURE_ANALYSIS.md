# WoP-PBS Vertical Packing Engine - Architecture Analysis

## 🚨 **Current Architecture Problems**

### Problem 1: Non-compliant Architecture
Current implementation violates all 4 development requirements:

**❌ VIOLATION 1**: VP still contains Blind-Rotation logic (bits 0-9)
```systemverilog
// WRONG: These should NOT be in VP
BLIND_ROTATION_INIT,      
BLIND_ROTATION_PROCESS,   
```

**❌ VIOLATION 2**: Using simplified PBS simulator instead of real pe_pbs
```systemverilog
// WRONG: Testbench implements simplified PBS
// ==============================================================================================
// Simplified Real PBS Hardware (Basic but effective implementation)  
// ==============================================================================================
```

**❌ VIOLATION 3**: Duplicated PBS logic in testbench instead of using wop_pbs_kernel
```systemverilog
// WRONG: Re-implementing PBS Sample Extract in testbench
for (int i = 0; i < N_LVL1; i++) begin
  if (i == 0) begin
    pbs_src_idx = (0 + pbs_rotation_shift) % N_LVL1;
    regfile_memory[pbs_dst_addr_captured + i] <= test_lut_table[pbs_selected_index][0][pbs_src_idx];
```

**❌ VIOLATION 4**: Architecture doesn't align with tfhe-cpu-baseline-wopbs design intent

## ✅ **Correct Architecture Requirements**

### Requirement 1: VP Scope Limitation
```
VP Engine ONLY handles:
- LUT loading
- GGSW samples loading (all 20 bits)
- CMux Tree processing (bits 10-19)
- TLWE preparation for PBS
- Result collection from PBS
```

### Requirement 2: PBS Delegation  
```
pe_pbs handles COMPLETE:
- Blind-Rotation (bits 0-9)
- Sample Extraction
- Post-processing (modSwitchToTorus32 + keyswitch)
```

### Requirement 3: Shared Resource Usage
```
Use existing wop_pbs_kernel infrastructure:
- Shared RegFile
- Shared NTT engines
- Shared BSK/KSK memories
- Shared AXI interfaces
```

### Requirement 4: C++ Algorithm Alignment
```
Based on tfhe-cpu-baseline-wopbs bigLut_20bit_lvl1():
1. CMux Tree (bits 10-19) → VP responsibility
2. Blind Rotation (bits 0-9) → PBS responsibility  
3. Sample Extract → PBS responsibility
4. Post-processing → PBS responsibility
```

## 🔧 **Required Architecture Fixes**

### Fix 1: VP State Machine Simplification
```systemverilog
// CORRECT STATE MACHINE
typedef enum logic [3:0] {
  IDLE,
  LOAD_LUT_ENTRIES,         // VP: Load LUT
  LOAD_GGSW_SAMPLES,        // VP: Load all 20 GGSW bits
  CMUX_TREE_INIT,           // VP: CMux tree setup
  CMUX_TREE_PROCESS,        // VP: CMux tree (bits 10-19)
  PREPARE_PBS_TLWE,         // VP: Prepare TLWE for PBS
  PBS_SEND_REQUEST,         // VP: Send PBS instruction
  PBS_WAIT_COMPLETION,      // VP: Wait for PBS
  PBS_READ_RESULT,          // VP: Read final result
  WRITE_RESULT,             // VP: Write to output
  DONE
} state_e;
```

### Fix 2: PBS Instruction Format
```systemverilog
// CORRECT PBS INSTRUCTION
pbs_inst[REGF_ADDR_W-1:0] = cmux_tlwe_addr;           // CMux result TLWE
pbs_inst[2*REGF_ADDR_W-1:REGF_ADDR_W] = output_addr;  // Final output
pbs_inst[...] = ggsw_samples_addr;                    // GGSW bits 0-9  
pbs_inst[...] = lut_base_addr;                        // LUT for rotation
// PBS will handle: Blind-Rotation + Extract + Post-process
```

### Fix 3: Real pe_pbs Integration
```systemverilog
// CORRECT: Use real pe_pbs module
pe_pbs_wrapper u_pbs (
  .clk(clk),
  .rst_n(s_rst_n),
  .pbs_inst(pbs_inst),
  .pbs_inst_vld(pbs_inst_vld),
  .pbs_inst_rdy(pbs_inst_rdy),
  .pbs_inst_ack(pbs_inst_ack),
  // Connect to shared RegFile/NTT/BSK/KSK/AXI
);
```

## 📊 **Architecture Comparison**

| Component | Current (WRONG) | Required (CORRECT) |
|-----------|-----------------|-------------------|
| CMux Tree | ✅ VP handles | ✅ VP handles |
| Blind Rotation | ❌ VP handles | ✅ PBS handles |
| Sample Extract | ❌ Testbench sim | ✅ PBS handles |
| Post-processing | ❌ Simplified | ✅ PBS handles |
| PBS Implementation | ❌ Simplified sim | ✅ Real pe_pbs |
| Resource Sharing | ❌ Isolated | ✅ wop_pbs_kernel |

## 🎯 **Implementation Priority**

### Priority 1: Remove VP Blind-Rotation Logic
- ❌ Remove `BLIND_ROTATION_INIT/PROCESS` states
- ❌ Remove blind rotation variables (`rotate_lut`, `tmp_mid`)
- ❌ Remove blind rotation operation logic

### Priority 2: Simplify PBS Interface
- ✅ VP sends comprehensive PBS instruction
- ✅ PBS handles complete processing pipeline
- ✅ VP only collects final results

### Priority 3: Replace Testbench PBS Simulator
- ❌ Remove simplified PBS logic from testbench
- ✅ Instantiate real pe_pbs module
- ✅ Connect to shared wop_pbs_kernel resources

### Priority 4: Verification Alignment
- ✅ Maintain C++ algorithm equivalence
- ✅ Test against tfhe-cpu-baseline-wopbs
- ✅ Validate end-to-end functionality

## 🚀 **Next Steps**

1. **Complete VP cleanup** (remove blind rotation logic)
2. **Update testbench** (use real pe_pbs instead of simulator)
3. **Integrate with wop_pbs_kernel** (shared resources)
4. **Verify against C++ reference** (end-to-end testing)

## ⚠️ **Critical Issues to Address**

1. **False Success**: Current "SUCCESS" is misleading due to simplified PBS
2. **Architecture Mismatch**: Current design doesn't match intended VP-PBS separation
3. **Resource Duplication**: PBS logic implemented in both VP and testbench
4. **Integration Gap**: Not using real wop_pbs_kernel infrastructure

The current implementation, while functionally working, fundamentally violates the architectural requirements and needs significant restructuring to meet the development goals.
