import config_pkg::*;
import test_config_pkg::*;
import build_config_pkg::*;

// GEHL 2-lane SC 单元测试 wrapper：predict 为 2 个 cond PC + TAGE 侧带，update 单口。
module tb_stat_corr (
    input logic clk_i,
    input logic rst_i,
    // lane0 = predict_pc_i[31:0], lane1 = predict_pc_i[63:32]
    input logic [63:0] predict_pc_i,
    input logic [31:0] predict_ghr_i,
    input logic [1:0] tage_taken_i,
    input logic [1:0] tage_hit_i,
    input logic [5:0] tage_conf_i,
    output logic [1:0] sc_taken_o,
    output logic [1:0] sc_use_o,

    input logic update_valid_i,
    input logic [31:0] update_pc_i,
    input logic [31:0] update_ghr_i,
    input logic update_taken_i,
    input logic update_tage_taken_i,
    input logic update_tage_hit_i,
    input logic [2:0] update_tage_conf_i
);
  localparam config_pkg::cfg_t Cfg = build_config_pkg::build_config(test_config_pkg::TestCfg);

  stat_corr #(
      .Cfg(Cfg),
      .LANES(2),
      .GHR_BITS(Cfg.BPU_GHR_BITS),
      .NUM_TABLES(Cfg.BPU_SC_NUM_TABLES),
      .ENTRIES(Cfg.BPU_SC_ENTRIES),
      .CTR_BITS(Cfg.BPU_SC_CTR_BITS),
      .HIST_LEN1(Cfg.BPU_SC_HIST1),
      .HIST_LEN2(Cfg.BPU_SC_HIST2),
      .HIST_LEN3(Cfg.BPU_SC_HIST3),
      .THRESH_INIT(Cfg.BPU_SC_THRESH_INIT)
  ) dut (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .predict_pc_i(predict_pc_i),
      .predict_ghr_i(predict_ghr_i),
      .tage_taken_i(tage_taken_i),
      .tage_hit_i(tage_hit_i),
      .tage_conf_i(tage_conf_i),
      .sc_taken_o(sc_taken_o),
      .sc_use_o(sc_use_o),
      .update_valid_i(update_valid_i),
      .update_pc_i(update_pc_i),
      .update_ghr_i(update_ghr_i),
      .update_taken_i(update_taken_i),
      .update_tage_taken_i(update_tage_taken_i),
      .update_tage_hit_i(update_tage_hit_i),
      .update_tage_conf_i(update_tage_conf_i)
  );

endmodule
