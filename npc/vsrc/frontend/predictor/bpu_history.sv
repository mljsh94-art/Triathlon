// vsrc/frontend/predictor/bpu_history.sv
// Shared branch history: architectural/speculative GHR + path history.
// Centralizes speculative advance (on registered predicted cond events),
// commit-time architectural advance, and flush rollback (spec <= arch).
// Also derives the ITTAGE predict-time path context. Behavior is identical
// to the inline history previously living in bpu.sv: logic was moved out
// unchanged, only scope/wiring differs. Predictors read history read-only
// via predict_req_t.ghr / predict_req_t.path supplied by the bpu top.
import global_config_pkg::*;
module bpu_history #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned GHR_BITS = 8,
    parameter int unsigned PATH_HIST_BITS = 16
) (
    input logic clk_i,
    input logic rst_i,

    input logic flush_i,

    // Commit-time architectural update (FTQ commit回灌).
    input logic                update_valid_i,
    input logic                update_is_cond_i,
    input logic                update_taken_i,
    input logic [Cfg.PLEN-1:0] update_pc_i,

    // Registered predicted event (shared with u_ras): drives speculative advance.
    input logic                pred_event_valid_i,
    input logic                pred_event_is_cond_i,
    input logic                pred_event_taken_i,
    input logic [Cfg.PLEN-1:0] pred_event_pc_i,
    input logic [1:0]          pred_cond_event_valid_i,
    input logic [1:0]          pred_cond_event_taken_i,
    input logic [1:0][Cfg.PLEN-1:0] pred_cond_event_pc_i,

    // History outputs consumed by predictors / update path.
    output logic [((GHR_BITS > 0) ? GHR_BITS : 1)-1:0]             arch_ghr_o,
    output logic [((GHR_BITS > 0) ? GHR_BITS : 1)-1:0]             spec_ghr_o,
    output logic [((PATH_HIST_BITS > 0) ? PATH_HIST_BITS : 1)-1:0] ittage_predict_ctx_o
);

  localparam int unsigned GHR_W = (GHR_BITS > 0) ? GHR_BITS : 1;
  localparam int unsigned PATH_HIST_W = (PATH_HIST_BITS > 0) ? PATH_HIST_BITS : 1;

  logic [GHR_W-1:0] arch_ghr_q;
  logic [GHR_W-1:0] spec_ghr_q;
  logic [PATH_HIST_W-1:0] arch_path_hist_q;
  logic [PATH_HIST_W-1:0] spec_path_hist_q;
  logic [PATH_HIST_W-1:0] ittage_predict_ctx_w;

  function automatic logic [GHR_W-1:0] ghr_shift(input logic [GHR_W-1:0] hist,
                                                 input logic                 taken);
    begin
      ghr_shift = (hist << 1) | GHR_W'(taken);
    end
  endfunction

  function automatic logic [PATH_HIST_W-1:0] path_shift(input logic [PATH_HIST_W-1:0] hist,
                                                         input logic [Cfg.PLEN-1:0]      pc,
                                                         input logic                      taken);
    logic [PATH_HIST_W-1:0] pc_mix;
    begin
      pc_mix = '0;
      for (int i = 0; i < Cfg.PLEN; i++) begin
        pc_mix[i%PATH_HIST_W] ^= pc[i];
      end
      path_shift = {hist[PATH_HIST_W-2:0], taken} ^ pc_mix;
    end
  endfunction

  // ITTAGE predict-time path context: speculative path with the in-flight
  // registered cond event folded in (unless flushing).
  always_comb begin
    ittage_predict_ctx_w = spec_path_hist_q;
    if (!flush_i) begin
      for (int i = 0; i < 2; i++) begin
        if (pred_cond_event_valid_i[i]) begin
          ittage_predict_ctx_w =
              path_shift(ittage_predict_ctx_w, pred_cond_event_pc_i[i], pred_cond_event_taken_i[i]);
        end
      end
    end
  end

  assign arch_ghr_o = arch_ghr_q;
  assign spec_ghr_o = spec_ghr_q;
  assign ittage_predict_ctx_o = ittage_predict_ctx_w;

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      arch_ghr_q <= '0;
      spec_ghr_q <= '0;
      arch_path_hist_q <= '0;
      spec_path_hist_q <= '0;
    end else begin
      logic [GHR_W-1:0] arch_ghr_n;
      logic [GHR_W-1:0] spec_ghr_n;
      logic [PATH_HIST_W-1:0] arch_path_hist_n;
      logic [PATH_HIST_W-1:0] spec_path_hist_n;

      arch_ghr_n = arch_ghr_q;
      spec_ghr_n = spec_ghr_q;
      arch_path_hist_n = arch_path_hist_q;
      spec_path_hist_n = spec_path_hist_q;

      if (update_valid_i) begin
        // 架构历史（GHR/path）随 commit 推进。
        if (update_is_cond_i) begin
          arch_ghr_n = ghr_shift(arch_ghr_n, update_taken_i);
          arch_path_hist_n = path_shift(arch_path_hist_n, update_pc_i, update_taken_i);
        end
      end

      if (flush_i) begin
        spec_path_hist_n = arch_path_hist_n;
      end

      if (flush_i) begin
        spec_ghr_n = arch_ghr_n;
      end else if (pred_event_valid_i) begin
        for (int i = 0; i < 2; i++) begin
          if (pred_cond_event_valid_i[i]) begin
            spec_ghr_n = ghr_shift(spec_ghr_n, pred_cond_event_taken_i[i]);
            spec_path_hist_n =
                path_shift(spec_path_hist_n, pred_cond_event_pc_i[i], pred_cond_event_taken_i[i]);
          end
        end
      end

      arch_ghr_q <= arch_ghr_n;
      spec_ghr_q <= spec_ghr_n;
      arch_path_hist_q <= arch_path_hist_n;
      spec_path_hist_q <= spec_path_hist_n;
    end
  end

endmodule : bpu_history
