// vsrc/cache/dcache_axi_wrapper.sv
import config_pkg::*;
import decode_pkg::*;

module dcache_axi_wrapper #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned AXI_ID_WIDTH = 4,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ADDR_WIDTH = Cfg.PLEN,
    parameter int unsigned N_MSHR = 1,
    parameter int unsigned LD_PORT_ID_WIDTH = 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // ================= LSU load interface =================
    input  logic                               ld_req_valid_i,
    output logic                               ld_req_ready_o,
    input  logic                [Cfg.PLEN-1:0] ld_req_addr_i,
    input  decode_pkg::lsu_op_e                ld_req_op_i,
    input  logic [LD_PORT_ID_WIDTH-1:0]        ld_req_id_i,

    output logic                ld_rsp_valid_o,
    input  logic                ld_rsp_ready_i,
    output logic [Cfg.XLEN-1:0] ld_rsp_data_o,
    output logic                ld_rsp_err_o,
    output logic [LD_PORT_ID_WIDTH-1:0] ld_rsp_id_o,

    // ================= Store buffer interface ==============
    input  logic                               st_req_valid_i,
    output logic                               st_req_ready_o,
    input  logic                [Cfg.PLEN-1:0] st_req_addr_i,
    input  logic                [Cfg.XLEN-1:0] st_req_data_i,
    input  decode_pkg::lsu_op_e                st_req_op_i,

    // ================= AXI4 Read Address Channel ===========
    output logic [  AXI_ID_WIDTH-1:0] arid_o,
    output logic [AXI_ADDR_WIDTH-1:0] araddr_o,
    output logic [               7:0] arlen_o,
    output logic [               2:0] arsize_o,
    output logic [               1:0] arburst_o,
    output logic                      arlock_o,
    output logic [               3:0] arcache_o,
    output logic [               2:0] arprot_o,
    output logic [               3:0] arqos_o,
    output logic                      arvalid_o,
    input  logic                      arready_i,

    // ================= AXI4 Read Data Channel ==============
    input  logic [  AXI_ID_WIDTH-1:0] rid_i,
    input  logic [AXI_DATA_WIDTH-1:0] rdata_i,
    input  logic [               1:0] rresp_i,
    input  logic                      rlast_i,
    input  logic                      rvalid_i,
    output logic                      rready_o,

    // ================= AXI4 Write Address Channel ==========
    output logic [  AXI_ID_WIDTH-1:0] awid_o,
    output logic [AXI_ADDR_WIDTH-1:0] awaddr_o,
    output logic [               7:0] awlen_o,
    output logic [               2:0] awsize_o,
    output logic [               1:0] awburst_o,
    output logic                      awlock_o,
    output logic [               3:0] awcache_o,
    output logic [               2:0] awprot_o,
    output logic [               3:0] awqos_o,
    output logic                      awvalid_o,
    input  logic                      awready_i,

    // ================= AXI4 Write Data Channel =============
    output logic [  AXI_DATA_WIDTH-1:0] wdata_o,
    output logic [AXI_DATA_WIDTH/8-1:0] wstrb_o,
    output logic                        wlast_o,
    output logic                        wvalid_o,
    input  logic                        wready_i,

    // ================= AXI4 Write Response Channel =========
    input  logic [AXI_ID_WIDTH-1:0] bid_i,
    input  logic [             1:0] bresp_i,
    input  logic                    bvalid_i,
    output logic                    bready_o
);

  // =============================================================
  // Local params
  // =============================================================
  localparam int unsigned LINE_BYTES = Cfg.DCACHE_LINE_WIDTH / 8;
  localparam int unsigned AXI_BYTES = AXI_DATA_WIDTH / 8;
  localparam int unsigned BEATS_PER_LINE = LINE_BYTES / AXI_BYTES;

  initial begin
    if (LINE_BYTES % AXI_BYTES != 0) begin
      $error("DCache line (%0dB) must be multiple of AXI beat (%0dB)", LINE_BYTES, AXI_BYTES);
    end
  end

  // =============================================================
  // Wires between dcache and wrapper
  // =============================================================
  logic                                  miss_req_valid;
  logic                                  miss_req_ready;
  logic [                  Cfg.PLEN-1:0] miss_req_paddr;
  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way;
  logic [    Cfg.DCACHE_INDEX_WIDTH-1:0] miss_req_index;

  logic                                  refill_valid;
  logic                                  refill_ready;
  logic [                  Cfg.PLEN-1:0] refill_paddr;
  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] refill_way;
  logic [     Cfg.DCACHE_LINE_WIDTH-1:0] refill_data;

  logic                                  wb_req_valid;
  logic                                  wb_req_ready;
  logic [                  Cfg.PLEN-1:0] wb_req_paddr;
  logic [     Cfg.DCACHE_LINE_WIDTH-1:0] wb_req_data;

  // =============================================================
  // Instantiate dcache
  // =============================================================
  dcache #(
      .Cfg(Cfg),
      .N_MSHR(N_MSHR),
      .LD_PORT_ID_WIDTH(LD_PORT_ID_WIDTH)
  ) u_dcache (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .flush_i(flush_i),

      .ld_req_valid_i(ld_req_valid_i),
      .ld_req_ready_o(ld_req_ready_o),
      .ld_req_addr_i (ld_req_addr_i),
      .ld_req_op_i   (ld_req_op_i),
      .ld_req_id_i   (ld_req_id_i),

      .ld_rsp_valid_o(ld_rsp_valid_o),
      .ld_rsp_ready_i(ld_rsp_ready_i),
      .ld_rsp_data_o (ld_rsp_data_o),
      .ld_rsp_err_o  (ld_rsp_err_o),
      .ld_rsp_id_o   (ld_rsp_id_o),

      .st_req_valid_i(st_req_valid_i),
      .st_req_ready_o(st_req_ready_o),
      .st_req_addr_i (st_req_addr_i),
      .st_req_data_i (st_req_data_i),
      .st_req_op_i   (st_req_op_i),

      .miss_req_valid_o     (miss_req_valid),
      .miss_req_ready_i     (miss_req_ready),
      .miss_req_paddr_o     (miss_req_paddr),
      .miss_req_victim_way_o(miss_req_victim_way),
      .miss_req_index_o     (miss_req_index),

      .refill_valid_i(refill_valid),
      .refill_ready_o(refill_ready),
      .refill_paddr_i(refill_paddr),
      .refill_way_i  (refill_way),
      .refill_data_i (refill_data),

      .wb_req_valid_o(wb_req_valid),
      .wb_req_ready_i(wb_req_ready),
      .wb_req_paddr_o(wb_req_paddr),
      .wb_req_data_o (wb_req_data)
  );

  // =============================================================
  // AXI FSM
  // =============================================================
  typedef enum logic [2:0] {
    S_IDLE,
    // Writeback path
    S_W_AW,
    S_W_W,
    S_W_B,
    // Refill path
    S_R_AR,
    S_R_R,
    S_R_REFILL
  } axi_state_e;

  axi_state_e state_q, state_d;

  // Latched request context
  logic [AXI_ADDR_WIDTH-1:0] wb_addr_q, miss_addr_q;
  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] miss_way_q;

  logic [Cfg.DCACHE_LINE_WIDTH-1:0] line_buf_q, line_buf_d;
  logic [$clog2(BEATS_PER_LINE):0] beat_cnt_q, beat_cnt_d;

  // =============================================================
  // Combinational
  // =============================================================
  always_comb begin
    state_d    = state_q;
    beat_cnt_d = beat_cnt_q;
    line_buf_d = line_buf_q;

    // Default handshake to cache
    wb_req_ready   = 1'b0;
    miss_req_ready = 1'b0;

    refill_valid = 1'b0;
    refill_paddr = miss_addr_q;
    refill_way   = miss_way_q;
    refill_data  = line_buf_q;

    // ---------------- AXI default signals ----------------
    arid_o    = '0;
    araddr_o  = miss_addr_q;
    arlen_o   = BEATS_PER_LINE - 1;
    arsize_o  = $clog2(AXI_BYTES);
    arburst_o = 2'b01;  // INCR
    arlock_o  = 1'b0;
    arcache_o = 4'b0011;
    arprot_o  = 3'b000;
    arqos_o   = 4'b0000;
    arvalid_o = 1'b0;

    rready_o  = 1'b0;

    awid_o    = '0;
    awaddr_o  = wb_addr_q;
    awlen_o   = BEATS_PER_LINE - 1;
    awsize_o  = $clog2(AXI_BYTES);
    awburst_o = 2'b01;  // INCR
    awlock_o  = 1'b0;
    awcache_o = 4'b0011;
    awprot_o  = 3'b000;
    awqos_o   = 4'b0000;
    awvalid_o = 1'b0;

    wdata_o  = '0;
    wstrb_o  = {AXI_DATA_WIDTH/8{1'b1}}; // full writeback
    wlast_o  = 1'b0;
    wvalid_o = 1'b0;

    bready_o = 1'b0;

    // ===========================================================
    // FSM
    // ===========================================================
    unique case (state_q)
      // --------------------------------------------------------
      S_IDLE: begin
        // Priority: writeback > refill
        if (wb_req_valid) begin
          wb_req_ready = 1'b1;
          if (wb_req_valid && wb_req_ready) begin
            line_buf_d = wb_req_data;
            beat_cnt_d = '0;
            state_d    = S_W_AW;
          end
        end else if (miss_req_valid) begin
          miss_req_ready = 1'b1;
          if (miss_req_valid && miss_req_ready) begin
            line_buf_d = '0;
            beat_cnt_d = '0;
            state_d    = S_R_AR;
          end
        end
      end

      // --------------------------------------------------------
      // Writeback: send AW
      S_W_AW: begin
        awvalid_o = 1'b1;
        if (awvalid_o && awready_i) begin
          beat_cnt_d = '0;
          state_d    = S_W_W;
        end
      end

      // Writeback: send W beats
      S_W_W: begin
        wvalid_o = 1'b1;
        wdata_o  = line_buf_q[AXI_DATA_WIDTH*beat_cnt_q+:AXI_DATA_WIDTH];
        wlast_o  = (beat_cnt_q == (BEATS_PER_LINE - 1));
        if (wvalid_o && wready_i) begin
          beat_cnt_d = beat_cnt_q + 1;
          if (wlast_o) begin
            state_d = S_W_B;
          end
        end
      end

      // Writeback: wait for B
      S_W_B: begin
        bready_o = 1'b1;
        if (bvalid_i && bready_o) begin
          state_d = S_IDLE;
        end
      end

      // --------------------------------------------------------
      // Refill: send AR
      S_R_AR: begin
        arvalid_o = 1'b1;
        if (arvalid_o && arready_i) begin
          beat_cnt_d = '0;
          state_d    = S_R_R;
        end
      end

      // Refill: receive R beats
      S_R_R: begin
        rready_o = 1'b1;
        if (rvalid_i && rready_o) begin
          line_buf_d[AXI_DATA_WIDTH*beat_cnt_q+:AXI_DATA_WIDTH] = rdata_i;
          beat_cnt_d = beat_cnt_q + 1;
          if (rlast_i) begin
            state_d = S_R_REFILL;
          end
        end
      end

      // Refill: hand data to cache
      S_R_REFILL: begin
        refill_valid = 1'b1;
        if (refill_valid && refill_ready) begin
          state_d = S_IDLE;
        end
      end

      default: state_d = S_IDLE;
    endcase
  end

  // =============================================================
  // Sequential
  // =============================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= S_IDLE;
      beat_cnt_q  <= '0;
      line_buf_q  <= '0;
      wb_addr_q   <= '0;
      miss_addr_q <= '0;
      miss_way_q  <= '0;
    end else begin
      state_q    <= state_d;
      beat_cnt_q <= beat_cnt_d;
      line_buf_q <= line_buf_d;

      if (state_q == S_IDLE) begin
        if (wb_req_valid && wb_req_ready) begin
          wb_addr_q <= wb_req_paddr;
        end else if (miss_req_valid && miss_req_ready) begin
          miss_addr_q <= miss_req_paddr;
          miss_way_q  <= miss_req_victim_way;
        end
      end
    end
  end

endmodule
