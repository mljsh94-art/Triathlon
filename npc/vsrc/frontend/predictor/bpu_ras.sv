// vsrc/frontend/predictor/bpu_ras.sv
// Return Address Stack (RAS): dual arch/spec stacks with commit-time
// architectural push/pop and speculative push/pop on predicted call/ret.
// Behavior is identical to the inline RAS previously living in bpu.sv:
// logic was moved out unchanged, only scope/wiring differs.
import global_config_pkg::*;
module bpu_ras #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned RAS_DEPTH = 16
) (
    input logic clk_i,
    input logic rst_i,

    // Commit-time architectural update (in program order, NRET-wide).
    input logic [Cfg.NRET-1:0]               ras_update_valid_i,
    input logic [Cfg.NRET-1:0]               ras_update_is_call_i,
    input logic [Cfg.NRET-1:0]               ras_update_is_ret_i,
    input logic [Cfg.NRET-1:0]               ras_update_is_rvc_i,
    input logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] ras_update_pc_i,

    // Speculative event: predicted call/ret (registered in bpu), plus flush.
    input logic                flush_i,
    input logic                pred_event_valid_i,
    input logic                pred_event_is_call_i,
    input logic                pred_event_is_ret_i,
    input logic                pred_event_is_rvc_i,
    input logic [Cfg.PLEN-1:0] pred_event_pc_i,

    // Lookup outputs.
    output logic [Cfg.PLEN-1:0] spec_ras_top_o,
    output logic                spec_ras_has_entry_o,
    output logic [Cfg.PLEN-1:0] arch_ras_top_o,
    output logic                arch_ras_has_entry_o
);

  localparam int unsigned RAS_CNT_W = (RAS_DEPTH > 0) ? $clog2(RAS_DEPTH + 1) : 1;
  localparam int unsigned INSTR_BYTES = Cfg.ILEN / 8;

  logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] arch_ras_stack_q;
  logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] spec_ras_stack_q;
  logic [RAS_CNT_W-1:0] arch_ras_count_q;
  logic [RAS_CNT_W-1:0] spec_ras_count_q;

  logic [Cfg.PLEN-1:0] spec_ras_top_w;
  logic spec_ras_has_entry_w;
  logic [Cfg.PLEN-1:0] arch_ras_top_w;
  logic arch_ras_has_entry_w;

  always_comb begin
    spec_ras_has_entry_w = (spec_ras_count_q != '0);
    spec_ras_top_w = '0;
    if (spec_ras_has_entry_w) begin
      spec_ras_top_w = spec_ras_stack_q[spec_ras_count_q-1];
    end
  end

  always_comb begin
    arch_ras_has_entry_w = (arch_ras_count_q != '0);
    arch_ras_top_w = '0;
    if (arch_ras_has_entry_w) begin
      arch_ras_top_w = arch_ras_stack_q[arch_ras_count_q-1];
    end
  end

  assign spec_ras_top_o = spec_ras_top_w;
  assign spec_ras_has_entry_o = spec_ras_has_entry_w;
  assign arch_ras_top_o = arch_ras_top_w;
  assign arch_ras_has_entry_o = arch_ras_has_entry_w;

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      arch_ras_stack_q <= '0;
      spec_ras_stack_q <= '0;
      arch_ras_count_q <= '0;
      spec_ras_count_q <= '0;
    end else begin
      logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] arch_stack_n;
      logic [RAS_DEPTH-1:0][Cfg.PLEN-1:0] spec_stack_n;
      logic [RAS_CNT_W-1:0] arch_count_n;
      logic [RAS_CNT_W-1:0] spec_count_n;

      arch_stack_n = arch_ras_stack_q;
      spec_stack_n = spec_ras_stack_q;
      arch_count_n = arch_ras_count_q;
      spec_count_n = spec_ras_count_q;

      for (int i = 0; i < Cfg.NRET; i++) begin
        if (ras_update_valid_i[i]) begin
          if (ras_update_is_call_i[i]) begin
            logic [Cfg.PLEN-1:0] call_ret_addr;
            call_ret_addr = ras_update_pc_i[i] +
                            (ras_update_is_rvc_i[i] ? Cfg.PLEN'(2) : Cfg.PLEN'(INSTR_BYTES));
            if (arch_count_n < RAS_DEPTH) begin
              arch_stack_n[arch_count_n] = call_ret_addr;
              arch_count_n = arch_count_n + 1'b1;
            end else begin
              for (int j = 0; j < RAS_DEPTH - 1; j++) begin
                arch_stack_n[j] = arch_stack_n[j+1];
              end
              arch_stack_n[RAS_DEPTH-1] = call_ret_addr;
              arch_count_n = RAS_DEPTH[RAS_CNT_W-1:0];
            end
          end else if (ras_update_is_ret_i[i]) begin
            if (arch_count_n != '0) begin
              arch_count_n = arch_count_n - 1'b1;
            end
          end
        end
      end

      if (flush_i) begin
        spec_stack_n = arch_stack_n;
        spec_count_n = arch_count_n;
      end else if (pred_event_valid_i && pred_event_is_call_i) begin
        logic [Cfg.PLEN-1:0] spec_ret_addr;
        spec_ret_addr = pred_event_pc_i +
                        (pred_event_is_rvc_i ? Cfg.PLEN'(2) : Cfg.PLEN'(INSTR_BYTES));
        if (spec_count_n < RAS_DEPTH) begin
          spec_stack_n[spec_count_n] = spec_ret_addr;
          spec_count_n = spec_count_n + 1'b1;
        end else begin
          for (int i = 0; i < RAS_DEPTH - 1; i++) begin
            spec_stack_n[i] = spec_stack_n[i+1];
          end
          spec_stack_n[RAS_DEPTH-1] = spec_ret_addr;
          spec_count_n = RAS_DEPTH[RAS_CNT_W-1:0];
        end
      end else if (pred_event_valid_i && pred_event_is_ret_i) begin
        if (spec_count_n != '0) begin
          spec_count_n = spec_count_n - 1'b1;
        end
      end

      arch_ras_stack_q <= arch_stack_n;
      arch_ras_count_q <= arch_count_n;
      spec_ras_stack_q <= spec_stack_n;
      spec_ras_count_q <= spec_count_n;
    end
  end

endmodule : bpu_ras
