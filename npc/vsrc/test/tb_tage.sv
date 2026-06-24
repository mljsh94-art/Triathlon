import config_pkg::*;
import test_config_pkg::*;
import build_config_pkg::*;

module tb_tage (
    input  logic clk_i,
    input  logic rst_i,
    input  logic [31:0] predict_base_pc_i,
    input  logic [7:0] predict_ghr_i,
    output logic [3:0] predict_hit_o,
    output logic [3:0] predict_taken_o,
    output logic [3:0] predict_strong_o,
    output logic [7:0] predict_provider_o,
    output logic [7:0] predict_useful_o,

    input  logic update_valid_i,
    input  logic [31:0] update_pc_i,
    input  logic [7:0] update_ghr_i,
    input  logic update_taken_i
);
  localparam config_pkg::cfg_t Cfg = build_config_pkg::build_config(test_config_pkg::TestCfg);

  tage #(
      .Cfg(Cfg),
      .INSTR_PER_FETCH(4),
      .GHR_BITS(8),
      .TABLE_ENTRIES(64),
      .TAG_BITS(8)
  ) dut (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_base_pc_i(predict_base_pc_i),
      .predict_ghr_i(predict_ghr_i),
      .predict_hit_o(predict_hit_o),
      .predict_taken_o(predict_taken_o),
      .predict_strong_o(predict_strong_o),
      .predict_provider_o(predict_provider_o),
      .predict_useful_o(predict_useful_o),
      .update_valid_i(update_valid_i),
      .update_pc_i(update_pc_i),
      .update_ghr_i(update_ghr_i),
      .update_taken_i(update_taken_i)
  );

endmodule
