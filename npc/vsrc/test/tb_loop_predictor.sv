import config_pkg::*;
import test_config_pkg::*;
import build_config_pkg::*;

module tb_loop_predictor (
    input logic clk_i,
    input logic rst_i,
    input logic [31:0] predict_base_pc_i,
    output logic [3:0] predict_taken_o,
    output logic [3:0] predict_confident_o,
    output logic [3:0] predict_hit_o,

    input logic update_valid_i,
    input logic [31:0] update_pc_i,
    input logic update_is_cond_i,
    input logic update_taken_i
);
  localparam config_pkg::cfg_t Cfg = build_config_pkg::build_config(test_config_pkg::TestCfg);

  loop_predictor #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(4),
      .ENTRIES(64),
      .TAG_BITS(10),
      .CONF_THRESH(2)
  ) dut (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(predict_base_pc_i),
      .predict_taken_o(predict_taken_o),
      .predict_confident_o(predict_confident_o),
      .predict_hit_o(predict_hit_o),
      .update_valid_i(update_valid_i),
      .update_pc_i(update_pc_i),
      .update_is_cond_i(update_is_cond_i),
      .update_taken_i(update_taken_i)
  );

endmodule
