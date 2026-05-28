import config_pkg::*;
import test_config_pkg::*;
import build_config_pkg::*;

module tb_sc_l (
    input logic clk_i,
    input logic rst_i,
    input logic [31:0] predict_base_pc_i,
    input logic [7:0] predict_ghr_i,
    output logic [3:0] predict_taken_o,
    output logic [3:0] predict_confident_o,

    input logic update_valid_i,
    input logic [31:0] update_pc_i,
    input logic [7:0] update_ghr_i,
    input logic update_taken_i
);
  localparam config_pkg::cfg_t Cfg = build_config_pkg::build_config(test_config_pkg::TestCfg);

  sc_l #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(4),
      .GHR_BITS(8),
      .ENTRIES(256),
      .CTR_BITS(4),
      .CONF_THRESH(3)
  ) dut (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(predict_base_pc_i),
      .predict_ghr_i(predict_ghr_i),
      .predict_taken_o(predict_taken_o),
      .predict_confident_o(predict_confident_o),
      .update_valid_i(update_valid_i),
      .update_pc_i(update_pc_i),
      .update_ghr_i(update_ghr_i),
      .update_taken_i(update_taken_i)
  );

endmodule
