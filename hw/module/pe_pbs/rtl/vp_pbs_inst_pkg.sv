// ==============================================================================================
// Filename: vp_pbs_inst_pkg.sv
// ----------------------------------------------------------------------------------------------
// Description:
//   Common package for Vertical Packing to construct PBS instruction in a unified format.
//   This reuses the same encoding as bit_extract so that kernel/pe_pbs can decode consistently.
// ==============================================================================================

package vp_pbs_inst_pkg;
  import pep_common_param_pkg::*;
  import hpu_common_instruction_pkg::*;
  import regf_common_param_pkg::*;

  // Helper function to create PBS instruction (compatible with bit_extract)
  function automatic logic [PE_INST_W-1:0] make_pbs_inst(
    input logic [GID_W-1:0] lut_gid,
    input logic [REGF_ADDR_W-1:0] src_addr,
    input logic [REGF_ADDR_W-1:0] dst_addr
  );
    pep_inst_t inst_struct;
    inst_struct.dop.kind = DOPT_PBS; // PBS operation
    inst_struct.dop.flush_pbs = 1'b0;
    inst_struct.dop.log_lut_nb = 2'b00; // Single LUT
    inst_struct.gid = lut_gid;
    inst_struct.src_rid = src_addr;
    inst_struct.dst_rid = dst_addr;
    return inst_struct;
  endfunction

endpackage : vp_pbs_inst_pkg


