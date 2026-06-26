// vsrc/backend/lsu/lsu_agu.sv
import config_pkg::*;
import decode_pkg::*;

// Address Generation Unit (pure combinational).
// Single source of truth for:
//   - effective address  : eff_addr = rs1 + imm
//   - access alignment    : misaligned (keyed on lsu_op + eff_addr)
//   - load/store class    : is_load / is_store / is_amo
// The lsu lane no longer derives the address itself; the group feeds the
// AGU-produced address downstream, removing the old addr_override patch.
module lsu_agu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg
) (
    input  decode_pkg::uop_t    uop_i,
    input  logic [Cfg.XLEN-1:0] rs1_data_i,

    output logic [Cfg.XLEN-1:0] eff_addr_xlen_o,
    output logic [Cfg.PLEN-1:0] eff_addr_o,
    output logic                is_load_o,
    output logic                is_store_o,
    output logic                is_amo_o,
    output logic                misaligned_o
);

  assign eff_addr_xlen_o = rs1_data_i + uop_i.imm;
  assign eff_addr_o      = eff_addr_xlen_o[Cfg.PLEN-1:0];

  assign is_load_o       = uop_i.is_load;
  assign is_store_o      = uop_i.is_store;
  assign is_amo_o        = (uop_i.lsu_op == decode_pkg::LSU_AMO);

  always_comb begin
    unique case (uop_i.lsu_op)
      decode_pkg::LSU_LB, decode_pkg::LSU_LBU, decode_pkg::LSU_SB:
        misaligned_o = 1'b0;
      decode_pkg::LSU_LH, decode_pkg::LSU_LHU, decode_pkg::LSU_SH:
        misaligned_o = eff_addr_o[0];
      decode_pkg::LSU_LW, decode_pkg::LSU_LWU, decode_pkg::LSU_SW,
      decode_pkg::LSU_LR, decode_pkg::LSU_SC, decode_pkg::LSU_AMO:
        misaligned_o = |eff_addr_o[1:0];
      decode_pkg::LSU_LD, decode_pkg::LSU_SD:
        misaligned_o = |eff_addr_o[2:0];
      default:
        misaligned_o = 1'b0;
    endcase
  end

endmodule
