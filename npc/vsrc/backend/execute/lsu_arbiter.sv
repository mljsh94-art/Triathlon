// vsrc/backend/execute/lsu_arbiter.sv
import config_pkg::*;
import decode_pkg::*;

// Sole owner of the three shared-resource arbitrations in the LSU group:
//
//   1) D-Cache load request  : round-robin among lanes (ld_req_rr_q pointer).
//   2) D-Cache load response : route the response back to the owning lane
//                              (by the id echoed on ld_rsp_id_i).
//   3) MMIO request          : fixed priority (lowest lane index first).
//   4) Writeback lane select : round-robin among lanes (wb_rr_q pointer). The
//                              final mux against the store-writeback path stays
//                              in lsu_group (store path), so the group feeds
//                              back `wb_pop_i` to advance the pointer when the
//                              granted lane is actually consumed.
//
// The lanes (`lsu_lane`) are reduced to a pure request -> wait -> writeback
// FSM and never touch a shared resource directly; all selection/muxing lives
// here. Behaviorally identical to the inline arbitration that used to sit in
// lsu_group.
module lsu_arbiter #(
    parameter config_pkg::cfg_t Cfg           = config_pkg::EmptyCfg,
    parameter int unsigned      N_LSU         = 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // =========================================================
    // 1) D-Cache load request (per-lane in, arbitrated out)
    // =========================================================
    input  logic                [         N_LSU-1:0]                lane_ld_req_valid_i,
    input  logic                [         N_LSU-1:0][Cfg.PLEN-1:0]  lane_ld_req_addr_i,
    input  decode_pkg::lsu_op_e                                     lane_ld_req_op_i     [N_LSU],
    output logic                [         N_LSU-1:0]                lane_ld_req_ready_o,

    output logic                                                    ld_req_valid_o,
    input  logic                                                    ld_req_ready_i,
    output logic                [          Cfg.PLEN-1:0]            ld_req_addr_o,
    output decode_pkg::lsu_op_e                                     ld_req_op_o,
    output logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0]           ld_req_id_o,

    // =========================================================
    // 2) D-Cache load response routing (route to owning lane)
    // =========================================================
    input  logic                                                    ld_rsp_valid_i,
    input  logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0]           ld_rsp_id_i,
    output logic                                                    ld_rsp_ready_o,
    input  logic                [         N_LSU-1:0]                lane_ld_rsp_ready_i,
    output logic                [         N_LSU-1:0]                lane_ld_rsp_valid_o,

    // =========================================================
    // 3) MMIO request (per-lane in, arbitrated out, priority)
    // =========================================================
    input  logic                [         N_LSU-1:0]                lane_mmio_req_valid_i,
    input  logic                [         N_LSU-1:0][Cfg.PLEN-1:0]  lane_mmio_req_addr_i,
    input  decode_pkg::lsu_op_e                                     lane_mmio_req_op_i   [N_LSU],
    output logic                [         N_LSU-1:0]                lane_mmio_req_ready_o,
    output logic                [         N_LSU-1:0]                lane_mmio_rsp_valid_o,

    output logic                                                    mmio_req_valid_o,
    input  logic                                                    mmio_req_ready_i,
    output logic                [          Cfg.PLEN-1:0]            mmio_req_addr_o,
    output decode_pkg::lsu_op_e                                     mmio_req_op_o,
    input  logic                                                    mmio_rsp_valid_i,

    // =========================================================
    // 4) Writeback lane arbitration (round-robin)
    // =========================================================
    input  logic                [         N_LSU-1:0]                lane_wb_valid_i,
    input  logic                                                    wb_pop_i,
    output logic                                                    wb_grant_valid_o,
    output logic [((N_LSU <= 1) ? 1 : $clog2(N_LSU))-1:0]           wb_lane_idx_o
);

  localparam int unsigned LANE_SEL_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU);
  localparam int unsigned LD_ID_WIDTH = (N_LSU <= 1) ? 1 : $clog2(N_LSU);

  function automatic logic [LANE_SEL_WIDTH-1:0] rr_next_idx(
      input logic [LANE_SEL_WIDTH-1:0] idx
  );
    begin
      if (N_LSU <= 1) begin
        rr_next_idx = '0;
      end else if (idx == LANE_SEL_WIDTH'(N_LSU - 1)) begin
        rr_next_idx = '0;
      end else begin
        rr_next_idx = idx + LANE_SEL_WIDTH'(1);
      end
    end
  endfunction

  // ---------------------------------------------------------
  // Round-robin pointers
  // ---------------------------------------------------------
  logic [LANE_SEL_WIDTH-1:0] ld_req_rr_q;
  logic [LANE_SEL_WIDTH-1:0] wb_rr_q;

  // ---------------------------------------------------------
  // 1) D-Cache load request arbitration (round-robin)
  // ---------------------------------------------------------
  logic [N_LSU-1:0]          ld_req_grant;
  logic [LANE_SEL_WIDTH-1:0] ld_req_lane_idx;
  logic                      ld_req_grant_valid;
  logic                      ld_req_fire;

  always_comb begin
    ld_req_grant = '0;
    ld_req_lane_idx = '0;
    ld_req_grant_valid = 1'b0;
    for (int off = 0; off < N_LSU; off++) begin
      int unsigned idx;
      idx = $unsigned(ld_req_rr_q) + off;
      if (idx >= N_LSU) begin
        idx -= N_LSU;
      end
      if (!ld_req_grant_valid && lane_ld_req_valid_i[idx]) begin
        ld_req_grant_valid = 1'b1;
        ld_req_grant[idx] = 1'b1;
        ld_req_lane_idx = LANE_SEL_WIDTH'(idx);
      end
    end
  end

  assign ld_req_valid_o = ld_req_grant_valid;
  assign ld_req_id_o = LD_ID_WIDTH'(ld_req_lane_idx);

  always_comb begin
    ld_req_addr_o = '0;
    ld_req_op_o = decode_pkg::LSU_LW;
    lane_ld_req_ready_o = '0;

    if (ld_req_grant_valid) begin
      ld_req_addr_o = lane_ld_req_addr_i[ld_req_lane_idx];
      ld_req_op_o = lane_ld_req_op_i[ld_req_lane_idx];
      lane_ld_req_ready_o[ld_req_lane_idx] = ld_req_ready_i;
    end
  end

  assign ld_req_fire = ld_req_grant_valid && ld_req_ready_i;

  // ---------------------------------------------------------
  // 2) D-Cache load response routing
  // ---------------------------------------------------------
  logic                      rsp_id_in_range;
  logic [LANE_SEL_WIDTH-1:0] rsp_lane_idx;

  assign rsp_lane_idx = LANE_SEL_WIDTH'(ld_rsp_id_i);
  assign rsp_id_in_range = ($unsigned(ld_rsp_id_i) < N_LSU);

  always_comb begin
    lane_ld_rsp_valid_o = '0;
    ld_rsp_ready_o = 1'b0;
    if (ld_rsp_valid_i && rsp_id_in_range) begin
      lane_ld_rsp_valid_o[rsp_lane_idx] = 1'b1;
      ld_rsp_ready_o = lane_ld_rsp_ready_i[rsp_lane_idx];
    end
  end

  // ---------------------------------------------------------
  // 3) MMIO request arbitration (priority: lowest lane index)
  // ---------------------------------------------------------
  always_comb begin
    mmio_req_valid_o      = 1'b0;
    mmio_req_addr_o       = '0;
    mmio_req_op_o         = decode_pkg::LSU_LW;
    lane_mmio_req_ready_o = '0;
    lane_mmio_rsp_valid_o = '0;
    for (int i = 0; i < N_LSU; i++) begin
      if (!mmio_req_valid_o && lane_mmio_req_valid_i[i]) begin
        mmio_req_valid_o         = 1'b1;
        mmio_req_addr_o          = lane_mmio_req_addr_i[i];
        mmio_req_op_o            = lane_mmio_req_op_i[i];
        lane_mmio_req_ready_o[i] = mmio_req_ready_i;
        lane_mmio_rsp_valid_o[i] = mmio_rsp_valid_i;
      end
    end
  end

  // ---------------------------------------------------------
  // 4) Writeback lane arbitration (round-robin)
  // ---------------------------------------------------------
  logic [N_LSU-1:0]          wb_grant;

  always_comb begin
    wb_grant = '0;
    wb_lane_idx_o = '0;
    wb_grant_valid_o = 1'b0;
    for (int off = 0; off < N_LSU; off++) begin
      int unsigned idx;
      idx = $unsigned(wb_rr_q) + off;
      if (idx >= N_LSU) begin
        idx -= N_LSU;
      end
      if (!wb_grant_valid_o && lane_wb_valid_i[idx]) begin
        wb_grant_valid_o = 1'b1;
        wb_grant[idx] = 1'b1;
        wb_lane_idx_o = LANE_SEL_WIDTH'(idx);
      end
    end
  end

  // ---------------------------------------------------------
  // Round-robin pointer updates
  // ---------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ld_req_rr_q <= '0;
      wb_rr_q     <= '0;
    end else if (flush_i) begin
      ld_req_rr_q <= '0;
      wb_rr_q     <= '0;
    end else begin
      if (ld_req_fire) begin
        ld_req_rr_q <= rr_next_idx(ld_req_lane_idx);
      end
      if (wb_pop_i) begin
        wb_rr_q <= rr_next_idx(wb_lane_idx_o);
      end
    end
  end

endmodule
