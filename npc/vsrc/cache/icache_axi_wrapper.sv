module icache_axi_wrapper #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned AXI_ID_WIDTH = 4,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ADDR_WIDTH = Cfg.PLEN
) (
    input logic clk_i,
    input logic rst_ni,

    // ========= IFU Interface (upper layer) =========
    input global_config_pkg::handshake_t ifu_req_handshake_i,
    output global_config_pkg::handshake_t ifu_rsp_handshake_o,
    input logic [Cfg.VLEN-1:0] ifu_req_pc_i,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ifu_rsp_instrs_o,
    input logic ifu_req_flush_i,

    // ========= AXI4 Read Address Channel =========
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

    // ========= AXI4 Read Data Channel =========
    input  logic [  AXI_ID_WIDTH-1:0] rid_i,
    input  logic [AXI_DATA_WIDTH-1:0] rdata_i,
    input  logic [               1:0] rresp_i,
    input  logic                      rlast_i,
    input  logic                      rvalid_i,
    output logic                      rready_o
);

  // ================================================================
  // =============== 1. Local parameters for AXI ====================
  // ================================================================
  localparam int unsigned LINE_BYTES = Cfg.ICACHE_LINE_WIDTH / 8;
  localparam int unsigned AXI_BYTES = AXI_DATA_WIDTH / 8;
  localparam int unsigned BEATS_PER_LINE = LINE_BYTES / AXI_BYTES;

  initial begin
    if (LINE_BYTES % AXI_BYTES != 0) begin
      $error("ICache line (%0dB) must be multiple of AXI beat (%0dB)", LINE_BYTES, AXI_BYTES);
    end
  end

  // ================================================================
  // =============== 2. Wires between icache and wrapper ============
  // ================================================================
  logic                                  miss_req_valid;
  logic                                  miss_req_ready;
  logic [                  Cfg.PLEN-1:0] miss_req_paddr;
  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way;
  logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] miss_req_index;

  logic                                  refill_valid;
  logic                                  refill_ready;
  logic [                  Cfg.PLEN-1:0] refill_paddr;
  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] refill_way;
  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] refill_data;

  // ================================================================
  // ====================== 3. Instantiate icache ====================
  // ================================================================
  icache #(
      .Cfg(Cfg)
  ) u_icache (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .ifu_req_handshake_i(ifu_req_handshake_i),
      .ifu_rsp_handshake_o(ifu_rsp_handshake_o),
      .ifu_req_pc_i       (ifu_req_pc_i),
      .ifu_rsp_instrs_o   (ifu_rsp_instrs_o),
      .ifu_req_flush_i    (ifu_req_flush_i),

      .miss_req_valid_o     (miss_req_valid),
      .miss_req_ready_i     (miss_req_ready),
      .miss_req_paddr_o     (miss_req_paddr),
      .miss_req_victim_way_o(miss_req_victim_way),
      .miss_req_index_o     (miss_req_index),

      .refill_valid_i(refill_valid),
      .refill_ready_o(refill_ready),
      .refill_paddr_i(refill_paddr),
      .refill_way_i  (refill_way),
      .refill_data_i (refill_data)
  );

  // ================================================================
  // =================== 4. AXI Read FSM =============================
  // ================================================================
  typedef enum logic [1:0] {
    S_IDLE,
    S_AR,
    S_R,
    S_REFILL
  } axi_state_e;

  axi_state_e state_q, state_d;

  logic [            AXI_ADDR_WIDTH-1:0] req_addr_q;
  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] req_way_q;

  logic [Cfg.ICACHE_LINE_WIDTH-1:0] line_buf_q, line_buf_d;
  logic [$clog2(BEATS_PER_LINE):0] beat_cnt_q, beat_cnt_d;

  // ========= FSM Combinational =========
  always_comb begin
    state_d        = state_q;
    beat_cnt_d     = beat_cnt_q;
    line_buf_d     = line_buf_q;

    miss_req_ready = 1'b0;

    refill_valid   = 1'b0;
    refill_paddr   = req_addr_q;
    refill_way     = req_way_q;
    refill_data    = line_buf_q;

    arid_o         = '0;
    araddr_o       = req_addr_q;
    arlen_o        = BEATS_PER_LINE - 1;
    arsize_o       = $clog2(AXI_BYTES);
    arburst_o      = 2'b01;  // INCR
    arlock_o       = 1'b0;
    arcache_o      = 4'b0011;
    arprot_o       = 3'b000;
    arqos_o        = 4'b0000;
    arvalid_o      = 1'b0;

    rready_o       = 1'b0;

    case (state_q)
      // -----------------------------
      S_IDLE: begin
        miss_req_ready = 1'b1;
        if (miss_req_valid && miss_req_ready) state_d = S_AR;
      end

      // -----------------------------
      S_AR: begin
        arvalid_o = 1'b1;
        if (arvalid_o && arready_i) begin
          beat_cnt_d = '0;
          state_d    = S_R;
        end
      end

      // -----------------------------
      S_R: begin
        rready_o = 1'b1;
        if (rvalid_i && rready_o) begin
          line_buf_d[AXI_DATA_WIDTH*beat_cnt_q+:AXI_DATA_WIDTH] = rdata_i;
          beat_cnt_d = beat_cnt_q + 1;
          if (rlast_i) state_d = S_REFILL;
        end
      end

      // -----------------------------
      S_REFILL: begin
        refill_valid = 1'b1;
        if (refill_valid && refill_ready) state_d = S_IDLE;
      end
    endcase
  end

  // ========= FSM Sequential =========
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= S_IDLE;
      beat_cnt_q <= '0;
      line_buf_q <= '0;
      req_addr_q <= '0;
      req_way_q  <= '0;
    end else begin
      state_q    <= state_d;
      beat_cnt_q <= beat_cnt_d;
      line_buf_q <= line_buf_d;

      if (state_q == S_IDLE && miss_req_valid && miss_req_ready) begin
        req_addr_q <= miss_req_paddr;
        req_way_q  <= miss_req_victim_way;
      end
    end
  end

endmodule
