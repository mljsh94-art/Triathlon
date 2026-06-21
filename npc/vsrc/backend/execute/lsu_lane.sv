// vsrc/backend/execute/lsu.sv
import config_pkg::*;
import decode_pkg::*;

// Simple LSU:
// - Computes effective address (rs1 + imm)
// - Loads: optional store-buffer forwarding, otherwise blocking D$ request
// - Stores: write address/data into Store Buffer, then complete in ROB
// - Single in-flight load, no load queue
module lsu_lane #(
    parameter config_pkg::cfg_t Cfg           = config_pkg::EmptyCfg,
    parameter int unsigned      ROB_IDX_WIDTH = 6,
    parameter int unsigned      SB_DEPTH      = 32,
    parameter int unsigned      SB_IDX_WIDTH  = $clog2(SB_DEPTH),
    parameter int unsigned      ECAUSE_WIDTH  = 5
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // =========================================================
    // 1) Request from Issue/Execute
    // =========================================================
    input  logic                                 req_valid_i,
    output logic                                 req_ready_o,
    input  decode_pkg::uop_t                     uop_i,
    input  logic             [     Cfg.XLEN-1:0] rs2_data_i,
    // Effective address + alignment are produced by lsu_agu and supplied by the
    // group; the lane no longer computes rs1+imm or checks alignment itself.
    input  logic             [     Cfg.PLEN-1:0] eff_addr_i,
    input  logic                                 misaligned_i,
    input  logic                                 force_exception_i,
    input  logic             [ ECAUSE_WIDTH-1:0] force_ecause_i,
    input  logic             [ROB_IDX_WIDTH-1:0] rob_tag_i,
    input  logic             [ SB_IDX_WIDTH-1:0] sb_id_i,

    // =========================================================
    // 2) Store Buffer interface (execute fill)
    // =========================================================
    output logic                                    sb_ex_valid_o,
    output logic                [ SB_IDX_WIDTH-1:0] sb_ex_sb_id_o,
    output logic                [     Cfg.PLEN-1:0] sb_ex_addr_o,
    output logic                [     Cfg.XLEN-1:0] sb_ex_data_o,
    output decode_pkg::lsu_op_e                     sb_ex_op_o,
    output logic                [ROB_IDX_WIDTH-1:0] sb_ex_rob_idx_o,

    // Store-to-Load Forwarding (query)
    output logic [     Cfg.PLEN-1:0] sb_load_addr_o,
    output logic [ROB_IDX_WIDTH-1:0] sb_load_rob_idx_o,
    input  logic                     sb_load_hit_i,
    input  logic [     Cfg.XLEN-1:0] sb_load_data_i,

    // =========================================================
    // 3) D-Cache Load interface
    // =========================================================
    output logic                               ld_req_valid_o,
    input  logic                               ld_req_ready_i,
    output logic                [Cfg.PLEN-1:0] ld_req_addr_o,
    output decode_pkg::lsu_op_e                ld_req_op_o,

    input  logic                ld_rsp_valid_i,
    output logic                ld_rsp_ready_o,
    input  logic [Cfg.XLEN-1:0] ld_rsp_data_i,
    input  logic                ld_rsp_err_i,

    // =========================================================
    // 3b) MMIO Uncached Load interface (bypass D-Cache)
    // =========================================================
    input  logic [ROB_IDX_WIDTH-1:0] rob_head_i,

    output logic                               mmio_req_valid_o,
    input  logic                               mmio_req_ready_i,
    output logic                [Cfg.PLEN-1:0] mmio_req_addr_o,
    output decode_pkg::lsu_op_e                mmio_req_op_o,

    input  logic                               mmio_rsp_valid_i,
    input  logic [Cfg.XLEN-1:0]                mmio_rsp_data_i,

    // =========================================================
    // 4) Writeback to ROB/CDB
    // =========================================================
    output logic                     wb_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] wb_rob_idx_o,
    output logic [     Cfg.XLEN-1:0] wb_data_o,
    output logic                     wb_exception_o,
    output logic [ECAUSE_WIDTH-1:0]  wb_ecause_o,
    output logic                     wb_is_mispred_o,
    output logic [     Cfg.PLEN-1:0] wb_redirect_pc_o,
    input  logic                     wb_ready_i
);

  // ---------------------------------------------------------
  // Exception cause (RISC-V standard)
  // ---------------------------------------------------------
  localparam logic [ECAUSE_WIDTH-1:0] EXC_LD_ADDR_MISALIGNED = ECAUSE_WIDTH'(4);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_LD_ACCESS_FAULT = ECAUSE_WIDTH'(5);
  localparam logic [ECAUSE_WIDTH-1:0] EXC_ST_ADDR_MISALIGNED = ECAUSE_WIDTH'(6);

  // ---------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------
  // Forwarded data extraction (assumes store data aligns to byte_off=0)
  function automatic logic [Cfg.XLEN-1:0] extract_fwd(input logic [Cfg.XLEN-1:0] data,
                                                      input decode_pkg::lsu_op_e op);
    logic sign;
    begin
      extract_fwd = '0;
      unique case (op)
        LSU_LB: begin
          sign        = data[7];
          extract_fwd = {{(Cfg.XLEN - 8) {sign}}, data[7:0]};
        end
        LSU_LBU: begin
          extract_fwd = {{(Cfg.XLEN - 8) {1'b0}}, data[7:0]};
        end
        LSU_LH: begin
          sign        = data[15];
          extract_fwd = {{(Cfg.XLEN - 16) {sign}}, data[15:0]};
        end
        LSU_LHU: begin
          extract_fwd = {{(Cfg.XLEN - 16) {1'b0}}, data[15:0]};
        end
        LSU_LW, LSU_LR, LSU_AMO: begin
          if (Cfg.XLEN == 32) begin
            extract_fwd = data[31:0];
          end else begin
            sign        = data[31];
            extract_fwd = {{(Cfg.XLEN - 32) {sign}}, data[31:0]};
          end
        end
        LSU_LWU: begin
          if (Cfg.XLEN == 32) begin
            extract_fwd = data[31:0];
          end else begin
            extract_fwd = {{(Cfg.XLEN - 32) {1'b0}}, data[31:0]};
          end
        end
        LSU_LD: begin
          extract_fwd = data;
        end
        default: extract_fwd = data;
      endcase
    end
  endfunction

  // ---------------------------------------------------------
  // Internal signals
  // ---------------------------------------------------------
  logic is_load;
  logic is_store;
  logic [Cfg.PLEN-1:0] eff_addr;
  logic misaligned;
  logic [Cfg.XLEN-1:0] fwd_data;
  logic [Cfg.XLEN-1:0] eff_addr_tval;
  logic [Cfg.XLEN-1:0] req_addr_tval;
  logic handoff_from_resp_w;
  logic handoff_from_ld_rsp_w;
  logic handoff_from_mmio_rsp_w;
  logic req_fire_w;
  logic is_amo;
  logic is_mmio;

  assign is_load       = uop_i.is_load;
  assign is_store      = uop_i.is_store;
  assign is_amo        = (uop_i.lsu_op == decode_pkg::LSU_AMO);

  assign eff_addr      = eff_addr_i;
  assign misaligned    = misaligned_i;
  assign is_mmio       = config_pkg::is_mmio_addr({{(32-Cfg.PLEN){1'b0}}, eff_addr});

  assign fwd_data      = extract_fwd(sb_load_data_i, uop_i.lsu_op);
  assign eff_addr_tval = Cfg.XLEN'(eff_addr);
  assign req_addr_tval = Cfg.XLEN'(req_addr_q);

  // ---------------------------------------------------------
  // State machine
  // ---------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_LD_REQ,
    S_LD_RSP,
    S_RESP,
    S_MMIO_WAIT_ROB,  // MMIO Load: wait until instruction reaches ROB head
    S_MMIO_REQ        // MMIO Load: issue uncached read request
  } lsu_state_e;

  function automatic lsu_state_e next_state_after_accept(input logic acc_is_store,
                                                          input logic acc_is_load,
                                                          input logic acc_misaligned,
                                                          input logic acc_force_exception,
                                                          input logic acc_sb_hit,
                                                          input logic acc_is_mmio);
    begin
      if (acc_is_store) begin
        next_state_after_accept = S_RESP;
      end else if (acc_is_load) begin
        if (acc_misaligned || acc_force_exception || acc_sb_hit) begin
          next_state_after_accept = S_RESP;
        end else if (acc_is_mmio) begin
          next_state_after_accept = S_MMIO_WAIT_ROB;
        end else begin
          next_state_after_accept = S_LD_REQ;
        end
      end else begin
        next_state_after_accept = S_RESP;
      end
    end
  endfunction

  lsu_state_e state_q, state_d;

  // In-flight load request
  logic                [     Cfg.PLEN-1:0] req_addr_q;
  decode_pkg::lsu_op_e                     req_op_q;
  logic                [ROB_IDX_WIDTH-1:0] req_tag_q;

  // Response holding regs
  logic                [     Cfg.XLEN-1:0] resp_data_q;
  logic                                    resp_exc_q;
  logic                [ECAUSE_WIDTH-1:0]  resp_ecause_q;
  logic                [ROB_IDX_WIDTH-1:0] resp_tag_q;



  // ---------------------------------------------------------
  // Output defaults
  // ---------------------------------------------------------
  assign handoff_from_resp_w = (state_q == S_RESP) && wb_ready_i;
  assign handoff_from_ld_rsp_w = (state_q == S_LD_RSP) && ld_rsp_valid_i && wb_ready_i;
  assign handoff_from_mmio_rsp_w = (state_q == S_MMIO_REQ) && mmio_rsp_valid_i && mmio_req_ready_i && wb_ready_i;
  assign req_ready_o = !flush_i && ((state_q == S_IDLE) || handoff_from_resp_w || handoff_from_ld_rsp_w || handoff_from_mmio_rsp_w);
  assign req_fire_w = req_valid_i && req_ready_o;

  // Store buffer execute write (pulse when accepting a store)
  assign sb_ex_valid_o = req_fire_w && is_store && !misaligned;
  assign sb_ex_sb_id_o = sb_id_i;
  assign sb_ex_addr_o = eff_addr;
  assign sb_ex_data_o = rs2_data_i;
  assign sb_ex_op_o = uop_i.lsu_op;
  assign sb_ex_rob_idx_o = rob_tag_i;

  // Store-buffer forwarding address (only meaningful for incoming load)
  assign sb_load_addr_o = (req_fire_w && is_load) ? eff_addr : '0;
  assign sb_load_rob_idx_o = req_fire_w ? rob_tag_i : '0;

  // D-Cache load port
  assign ld_req_valid_o = (state_q == S_LD_REQ);
  assign ld_req_addr_o = req_addr_q;
  assign ld_req_op_o = req_op_q;

  assign ld_rsp_ready_o = (state_q == S_LD_RSP);

  // D-Cache load port
  // (MMIO loads never drive the D-Cache port)

  // MMIO uncached load port
  assign mmio_req_valid_o = (state_q == S_MMIO_REQ);
  assign mmio_req_addr_o  = req_addr_q;
  assign mmio_req_op_o    = req_op_q;

  // Writeback (to CDB/ROB)
  logic rsp_bypass_wb_valid;
  logic [ROB_IDX_WIDTH-1:0] rsp_bypass_wb_tag;
  logic [Cfg.XLEN-1:0] rsp_bypass_wb_data;
  logic rsp_bypass_wb_exc;
  logic [ECAUSE_WIDTH-1:0] rsp_bypass_wb_ecause;

  assign rsp_bypass_wb_valid = (state_q == S_LD_RSP) && ld_rsp_valid_i;
  assign rsp_bypass_wb_tag = req_tag_q;
  assign rsp_bypass_wb_data = ld_rsp_err_i ? req_addr_tval : ld_rsp_data_i;
  assign rsp_bypass_wb_exc = ld_rsp_err_i;
  assign rsp_bypass_wb_ecause = ld_rsp_err_i ? EXC_LD_ACCESS_FAULT : '0;

  // MMIO bypass writeback
  logic mmio_bypass_wb_valid;
  assign mmio_bypass_wb_valid = (state_q == S_MMIO_REQ) && mmio_rsp_valid_i && mmio_req_ready_i;

  assign wb_valid_o = (state_q == S_RESP) || rsp_bypass_wb_valid || mmio_bypass_wb_valid;
  assign wb_rob_idx_o = mmio_bypass_wb_valid ? req_tag_q :
                        rsp_bypass_wb_valid  ? rsp_bypass_wb_tag : resp_tag_q;
  assign wb_data_o = mmio_bypass_wb_valid ? mmio_rsp_data_i :
                     rsp_bypass_wb_valid  ? rsp_bypass_wb_data : resp_data_q;
  assign wb_exception_o = mmio_bypass_wb_valid ? 1'b0 :
                          rsp_bypass_wb_valid  ? rsp_bypass_wb_exc : resp_exc_q;
  assign wb_ecause_o = mmio_bypass_wb_valid ? '0 :
                       rsp_bypass_wb_valid  ? rsp_bypass_wb_ecause : resp_ecause_q;
  assign wb_is_mispred_o = 1'b0;
  assign wb_redirect_pc_o = '0;

  // ---------------------------------------------------------
  // Next-state logic
  // ---------------------------------------------------------
  always_comb begin
    state_d = state_q;

    unique case (state_q)
      S_IDLE: begin
        if (req_fire_w) begin
          state_d = next_state_after_accept(is_store, is_load, misaligned, force_exception_i,
                                            sb_load_hit_i, is_mmio);
        end
      end

      S_LD_REQ: begin
        if (ld_req_ready_i) begin
          state_d = S_LD_RSP;
        end
      end

      S_LD_RSP: begin
        if (ld_rsp_valid_i) begin
          if (wb_ready_i) begin
            if (req_fire_w) begin
              state_d = next_state_after_accept(is_store, is_load, misaligned, force_exception_i,
                                                sb_load_hit_i, is_mmio);
            end else begin
              state_d = S_IDLE;
            end
          end else begin
            state_d = S_RESP;
          end
        end
      end

      S_RESP: begin
        if (wb_ready_i) begin
          if (req_fire_w) begin
            state_d = next_state_after_accept(is_store, is_load, misaligned, force_exception_i,
                                              sb_load_hit_i, is_mmio);
          end else begin
            state_d = S_IDLE;
          end
        end
      end

      S_MMIO_WAIT_ROB: begin
        // Wait until this instruction reaches the ROB head (non-speculative)
        if (req_tag_q == rob_head_i) begin
          state_d = S_MMIO_REQ;
        end
      end

      S_MMIO_REQ: begin
        // Issue uncached MMIO read; wait for response
        if (mmio_req_ready_i && mmio_rsp_valid_i) begin
          if (wb_ready_i) begin
            if (req_fire_w) begin
              state_d = next_state_after_accept(is_store, is_load, misaligned, force_exception_i,
                                                sb_load_hit_i, is_mmio);
            end else begin
              state_d = S_IDLE;
            end
          end else begin
            state_d = S_RESP;
          end
        end
      end

      default: state_d = S_IDLE;
    endcase

    if (flush_i) begin
      state_d = S_IDLE;
    end
  end

  // ---------------------------------------------------------
  // Sequential logic
  // ---------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= S_IDLE;

      req_addr_q    <= '0;
      req_op_q      <= decode_pkg::LSU_LW;
      req_tag_q     <= '0;

      resp_data_q   <= '0;
      resp_exc_q    <= 1'b0;
      resp_ecause_q <= '0;
      resp_tag_q    <= '0;
    end else begin
      state_q <= state_d;

      if (flush_i) begin
        resp_data_q   <= '0;
        resp_exc_q    <= 1'b0;
        resp_ecause_q <= '0;
        resp_tag_q    <= '0;
      end else begin
        // Accept new request
        if (req_fire_w) begin
          if (is_load && !misaligned && !force_exception_i && !sb_load_hit_i) begin
            req_addr_q <= eff_addr;
            req_op_q   <= uop_i.lsu_op;
            req_tag_q  <= rob_tag_i;
          end

          if (is_store) begin
            resp_tag_q    <= rob_tag_i;
            resp_data_q   <= '0;
            resp_exc_q    <= misaligned;
            resp_ecause_q <= misaligned ? EXC_ST_ADDR_MISALIGNED : '0;
          end else if (is_load) begin
            resp_tag_q <= rob_tag_i;
            if (misaligned) begin
              resp_data_q   <= eff_addr_tval;
              resp_exc_q    <= 1'b1;
              resp_ecause_q <= is_amo ? EXC_ST_ADDR_MISALIGNED : EXC_LD_ADDR_MISALIGNED;
            end else if (force_exception_i) begin
              resp_data_q   <= eff_addr_tval;
              resp_exc_q    <= 1'b1;
              resp_ecause_q <= force_ecause_i;
            end else if (sb_load_hit_i) begin
              resp_data_q   <= fwd_data;
              resp_exc_q    <= 1'b0;
              resp_ecause_q <= '0;
            end
          end else begin
            // Non-LSU op (should not happen): complete without exception
            resp_tag_q    <= rob_tag_i;
            resp_data_q   <= '0;
            resp_exc_q    <= 1'b0;
            resp_ecause_q <= '0;
          end
        end

        // Capture load response
        if (state_q == S_LD_RSP && ld_rsp_valid_i && !wb_ready_i) begin
          resp_tag_q    <= req_tag_q;
          resp_data_q   <= ld_rsp_err_i ? req_addr_tval : ld_rsp_data_i;
          resp_exc_q    <= ld_rsp_err_i;
          resp_ecause_q <= ld_rsp_err_i ? EXC_LD_ACCESS_FAULT : '0;
        end

        // Capture MMIO response when CDB is not ready
        if (state_q == S_MMIO_REQ && mmio_rsp_valid_i && mmio_req_ready_i && !wb_ready_i) begin
          resp_tag_q    <= req_tag_q;
          resp_data_q   <= mmio_rsp_data_i;
          resp_exc_q    <= 1'b0;
          resp_ecause_q <= '0;
        end
      end
    end
  end

endmodule
