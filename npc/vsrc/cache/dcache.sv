// vsrc/cache/dcache.sv
import config_pkg::*;
import decode_pkg::*;

module dcache #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned      N_MSHR = 1,
    parameter int unsigned      LD_PORT_ID_WIDTH = 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // =============================================================
    // 1) Load port (from LSU)
    // =============================================================
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

    // =============================================================
    // 2) Committed store port (from Store Buffer)
    // =============================================================
    input  logic                               st_req_valid_i,
    output logic                               st_req_ready_o,
    input  logic                [Cfg.PLEN-1:0] st_req_addr_i,
    input  logic                [Cfg.XLEN-1:0] st_req_data_i,
    input  decode_pkg::lsu_op_e                st_req_op_i,

    // =============================================================
    // 3) Miss/Refill interface to lower memory (e.g. AXI wrapper)
    // =============================================================
    output logic                                  miss_req_valid_o,
    input  logic                                  miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] miss_req_paddr_o,
    output logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way_o,
    output logic [    Cfg.DCACHE_INDEX_WIDTH-1:0] miss_req_index_o,

    input  logic                                  refill_valid_i,
    output logic                                  refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] refill_paddr_i,
    input  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] refill_way_i,
    input  logic [     Cfg.DCACHE_LINE_WIDTH-1:0] refill_data_i,

    // =============================================================
    // 4) Writeback interface (eviction)
    // =============================================================
    output logic                             wb_req_valid_o,
    input  logic                             wb_req_ready_i,
    output logic [             Cfg.PLEN-1:0] wb_req_paddr_o,
    output logic [Cfg.DCACHE_LINE_WIDTH-1:0] wb_req_data_o
);

  // ---------------------------------------------------------------------------
  // Local parameters derived from Cfg
  // ---------------------------------------------------------------------------
  localparam int unsigned NUM_WAYS = Cfg.DCACHE_SET_ASSOC;
  localparam int unsigned NUM_BANKS = Cfg.DCACHE_NUM_BANKS;
  localparam int unsigned BANK_SEL_WIDTH = Cfg.DCACHE_BANK_SEL_WIDTH;
  localparam int unsigned INDEX_WIDTH = Cfg.DCACHE_INDEX_WIDTH;
  localparam int unsigned OFFSET_WIDTH = Cfg.DCACHE_OFFSET_WIDTH;
  localparam int unsigned TAG_WIDTH = Cfg.DCACHE_TAG_WIDTH;
  localparam int unsigned LINE_WIDTH = Cfg.DCACHE_LINE_WIDTH;
  localparam int unsigned LINE_BYTES = LINE_WIDTH / 8;
  localparam int unsigned LINE_ADDR_WIDTH = Cfg.PLEN - OFFSET_WIDTH;
  localparam int unsigned SETS_PER_BANK_WIDTH = (INDEX_WIDTH > BANK_SEL_WIDTH) ? (INDEX_WIDTH - BANK_SEL_WIDTH) : 1;

  // Tag meta bits: {dirty, valid}
  localparam int unsigned META_WIDTH = 2;
  localparam int unsigned MSHR_ENTRIES = (N_MSHR >= 1) ? N_MSHR :
      ((Cfg.DC_MSHR_DEPTH >= 1) ? Cfg.DC_MSHR_DEPTH : 1);
  localparam int unsigned MSHR_IDX_WIDTH = (MSHR_ENTRIES <= 1) ? 1 : $clog2(MSHR_ENTRIES);

  // ---------------------------------------------------------------------------
  // Helper functions (op decode / store merge / load extract)
  // ---------------------------------------------------------------------------
  function automatic logic is_load_op(input decode_pkg::lsu_op_e op);
    unique case (op)
      LSU_LB, LSU_LH, LSU_LW, LSU_LD, LSU_LBU, LSU_LHU, LSU_LWU: is_load_op = 1'b1;
      default: is_load_op = 1'b0;
    endcase
  endfunction

  function automatic logic is_store_op(input decode_pkg::lsu_op_e op);
    unique case (op)
      LSU_SB, LSU_SH, LSU_SW, LSU_SD: is_store_op = 1'b1;
      default: is_store_op = 1'b0;
    endcase
  endfunction

  function automatic int unsigned op_size_bytes(input decode_pkg::lsu_op_e op);
    unique case (op)
      LSU_LB, LSU_LBU, LSU_SB: op_size_bytes = 1;
      LSU_LH, LSU_LHU, LSU_SH: op_size_bytes = 2;
      LSU_LW, LSU_LWU, LSU_SW: op_size_bytes = 4;
      LSU_LD, LSU_SD:          op_size_bytes = 8;
      default:                 op_size_bytes = 4;
    endcase
  endfunction

  function automatic logic is_misaligned(input decode_pkg::lsu_op_e op,
                                         input logic [Cfg.PLEN-1:0] addr);
    unique case (op)
      LSU_LB, LSU_LBU, LSU_SB: is_misaligned = 1'b0;
      LSU_LH, LSU_LHU, LSU_SH: is_misaligned = addr[0];
      LSU_LW, LSU_LWU, LSU_SW: is_misaligned = |addr[1:0];
      LSU_LD, LSU_SD:          is_misaligned = |addr[2:0];
      default:                 is_misaligned = 1'b0;
    endcase
  endfunction

  function automatic logic [LINE_WIDTH-1:0] apply_store(
      input logic [LINE_WIDTH-1:0] line, input logic [OFFSET_WIDTH-1:0] byte_off,
      input decode_pkg::lsu_op_e op, input logic [Cfg.XLEN-1:0] wdata);
    logic [LINE_WIDTH-1:0] res;
    int unsigned bit_idx;
    // Zero-extend store data to 64b to avoid out-of-range selects when XLEN=32.
    logic [63:0] wdata64;
    wdata64 = '0;
    wdata64[Cfg.XLEN-1:0] = wdata;

    res = line;
    bit_idx = int'($unsigned(byte_off)) * 8;
    unique case (op)
      LSU_SB: res[bit_idx+:8] = wdata64[7:0];
      LSU_SH: res[bit_idx+:16] = wdata64[15:0];
      LSU_SW: res[bit_idx+:32] = wdata64[31:0];
      LSU_SD: res[bit_idx+:64] = wdata64[63:0];
      default:  /* do nothing */;
    endcase
    return res;
  endfunction

  function automatic logic [Cfg.XLEN-1:0] extract_load(input logic [LINE_WIDTH-1:0] line,
                                                       input logic [OFFSET_WIDTH-1:0] byte_off,
                                                       input decode_pkg::lsu_op_e op);
    logic [Cfg.XLEN-1:0] res;
    logic sign;
    int unsigned bit_idx;
    res = '0;
    bit_idx = int'($unsigned(byte_off)) * 8;
    unique case (op)
      LSU_LB: begin
        sign = line[bit_idx+7];
        res  = {{(Cfg.XLEN - 8) {sign}}, line[bit_idx+:8]};
      end
      LSU_LBU: begin
        res = {{(Cfg.XLEN - 8) {1'b0}}, line[bit_idx+:8]};
      end
      LSU_LH: begin
        sign = line[bit_idx+15];
        res  = {{(Cfg.XLEN - 16) {sign}}, line[bit_idx+:16]};
      end
      LSU_LHU: begin
        res = {{(Cfg.XLEN - 16) {1'b0}}, line[bit_idx+:16]};
      end
      LSU_LW, LSU_LR: begin
        if (Cfg.XLEN == 32) begin
          res = line[bit_idx+:32];
        end else begin
          sign = line[bit_idx+31];
          res  = {{(Cfg.XLEN - 32) {sign}}, line[bit_idx+:32]};
        end
      end
      LSU_LWU: begin
        // Only meaningful for RV64; for RV32 this is illegal but harmless.
        if (Cfg.XLEN == 32) begin
          res = line[bit_idx+:32];
        end else begin
          res = {{(Cfg.XLEN - 32) {1'b0}}, line[bit_idx+:32]};
        end
      end
      LSU_LD: begin
        // RV64
        res = line[bit_idx+:64];
      end
      default: res = '0;
    endcase
    return res;
  endfunction

  // ---------------------------------------------------------------------------
  // Request selection (load has priority over store).
  // Note: some younger loads may be satisfied by LSU SQ forwarding before reaching D$.
  // ---------------------------------------------------------------------------
  logic sel_is_load;
  logic sel_is_store;
  logic sel_use_pending_load;
  logic [Cfg.PLEN-1:0] sel_addr;
  decode_pkg::lsu_op_e sel_op;
  logic [Cfg.XLEN-1:0] sel_wdata;
  logic [LD_PORT_ID_WIDTH-1:0] sel_id;
  logic ld_req_line_in_mshr;
  logic st_req_line_in_mshr;
  logic rsp_fire_w;
  logic rsp_handoff_use_pending_w;
  logic rsp_handoff_use_live_req_w;
  logic rsp_handoff_fire_w;

  logic [Cfg.PLEN-1:0] rsp_handoff_addr_w;
  decode_pkg::lsu_op_e rsp_handoff_op_w;
  logic [LD_PORT_ID_WIDTH-1:0] rsp_handoff_id_w;
  logic [LINE_ADDR_WIDTH-1:0] rsp_handoff_line_addr_w;
  logic [INDEX_WIDTH-1:0] rsp_handoff_index_w;
  logic [TAG_WIDTH-1:0] rsp_handoff_tag_w;
  logic [OFFSET_WIDTH-1:0] rsp_handoff_byte_off_w;
  logic [SETS_PER_BANK_WIDTH-1:0] rsp_handoff_bank_addr_w;
  logic [BANK_SEL_WIDTH-1:0] rsp_handoff_bank_sel_w;
  logic rsp_handoff_err_w;

  // Ready policy: serve requests in IDLE, but give refill handshake priority.
  always_comb begin
    // Allow one buffered load request only when waiting on load response (S_RESP).
    // This avoids accepting a same-line request during miss LOOKUP before MSHR is visible.
    ld_req_ready_o = ((state_q == S_IDLE) || (state_q == S_RESP)) &&
                     !pending_ld_valid_q && !flush_i && !refill_valid_i &&
                     (!ld_req_valid_i || !ld_req_line_in_mshr);
    st_req_ready_o = (state_q == S_IDLE) && !pending_ld_valid_q && !ld_req_valid_i &&
                     !flush_i && !refill_valid_i &&
                     (!st_req_valid_i || !st_req_line_in_mshr);

    sel_is_load    = 1'b0;
    sel_is_store   = 1'b0;
    sel_use_pending_load = 1'b0;
    sel_addr       = '0;
    sel_op         = decode_pkg::LSU_LW;
    sel_wdata      = '0;
    sel_id         = '0;

    // Never start a new lookup in the same cycle that a refill request is
    // presented. This prevents pending-load dequeue from racing with refill-side
    // array access in banked single-port SRAM.
    if (!flush_i && !refill_valid_i) begin
      if ((state_q == S_IDLE) && pending_ld_valid_q) begin
        sel_is_load = 1'b1;
        sel_use_pending_load = 1'b1;
        sel_addr = pending_ld_addr_q;
        sel_op = pending_ld_op_q;
        sel_wdata = '0;
        sel_id = pending_ld_id_q;
      end else if ((state_q == S_IDLE) && ld_req_valid_i && ld_req_ready_o) begin
        sel_is_load = 1'b1;
        sel_addr    = ld_req_addr_i;
        sel_op      = ld_req_op_i;
        sel_wdata   = '0;
        sel_id      = ld_req_id_i;
      end else if (st_req_valid_i && st_req_ready_o) begin
        sel_is_store = 1'b1;
        sel_addr     = st_req_addr_i;
        sel_op       = st_req_op_i;
        sel_wdata    = st_req_data_i;
      end
    end
  end

  logic accept_req;
  assign accept_req = sel_is_load || sel_is_store;

  assign rsp_fire_w = (state_q == S_RESP) && ld_rsp_valid_o && ld_rsp_ready_i;
  assign rsp_handoff_use_pending_w = rsp_fire_w && pending_ld_valid_q && !flush_i && !refill_valid_i;
  assign rsp_handoff_use_live_req_w = rsp_fire_w && !pending_ld_valid_q && ld_req_valid_i &&
                                      ld_req_ready_o && !flush_i && !refill_valid_i;
  assign rsp_handoff_fire_w = rsp_handoff_use_pending_w || rsp_handoff_use_live_req_w;

  assign rsp_handoff_addr_w = rsp_handoff_use_pending_w ? pending_ld_addr_q : ld_req_addr_i;
  assign rsp_handoff_op_w = rsp_handoff_use_pending_w ? pending_ld_op_q : ld_req_op_i;
  assign rsp_handoff_id_w = rsp_handoff_use_pending_w ? pending_ld_id_q : ld_req_id_i;
  assign rsp_handoff_line_addr_w = rsp_handoff_addr_w[Cfg.PLEN-1:OFFSET_WIDTH];
  assign rsp_handoff_index_w = rsp_handoff_line_addr_w[INDEX_WIDTH-1:0];
  assign rsp_handoff_tag_w = rsp_handoff_line_addr_w[INDEX_WIDTH+:TAG_WIDTH];
  assign rsp_handoff_byte_off_w = rsp_handoff_addr_w[OFFSET_WIDTH-1:0];
  assign rsp_handoff_bank_addr_w = rsp_handoff_index_w[INDEX_WIDTH-1:BANK_SEL_WIDTH];
  assign rsp_handoff_bank_sel_w = rsp_handoff_index_w[BANK_SEL_WIDTH-1:0];
  assign rsp_handoff_err_w = is_misaligned(rsp_handoff_op_w, rsp_handoff_addr_w);

  // ---------------------------------------------------------------------------
  // Address decode for the selected request (combinational)
  // ---------------------------------------------------------------------------
  logic [LINE_ADDR_WIDTH-1:0] sel_line_addr;
  logic [    INDEX_WIDTH-1:0] sel_index;
  logic [      TAG_WIDTH-1:0] sel_tag;
  logic [   OFFSET_WIDTH-1:0] sel_byte_off;
  logic [LINE_ADDR_WIDTH-1:0] ld_req_line_addr;
  logic [LINE_ADDR_WIDTH-1:0] st_req_line_addr;

  assign sel_line_addr = sel_addr[Cfg.PLEN-1:OFFSET_WIDTH];
  assign sel_index     = sel_line_addr[INDEX_WIDTH-1:0];
  assign sel_tag       = sel_line_addr[INDEX_WIDTH+:TAG_WIDTH];
  assign sel_byte_off  = sel_addr[OFFSET_WIDTH-1:0];
  assign ld_req_line_addr = ld_req_addr_i[Cfg.PLEN-1:OFFSET_WIDTH];
  assign st_req_line_addr = st_req_addr_i[Cfg.PLEN-1:OFFSET_WIDTH];

  logic [SETS_PER_BANK_WIDTH-1:0] sel_bank_addr;
  logic [     BANK_SEL_WIDTH-1:0] sel_bank_sel;
  assign sel_bank_addr = sel_index[INDEX_WIDTH-1:BANK_SEL_WIDTH];
  assign sel_bank_sel  = sel_index[BANK_SEL_WIDTH-1:0];

  // ---------------------------------------------------------------------------
  // Cache arrays
  // ---------------------------------------------------------------------------
  logic [           NUM_WAYS-1:0][ TAG_WIDTH-1:0] tag_a;
  logic [           NUM_WAYS-1:0][META_WIDTH-1:0] meta_a;
  logic [           NUM_WAYS-1:0][LINE_WIDTH-1:0] line_a_all;

  // Unused read port B (tied to A)
  logic [           NUM_WAYS-1:0][ TAG_WIDTH-1:0] tag_b;
  logic [           NUM_WAYS-1:0][META_WIDTH-1:0] meta_b;
  logic [           NUM_WAYS-1:0][LINE_WIDTH-1:0] line_b_all;

  // Write port
  logic [           NUM_WAYS-1:0]                 we_way_mask;
  logic [SETS_PER_BANK_WIDTH-1:0]                 w_bank_addr;
  logic [     BANK_SEL_WIDTH-1:0]                 w_bank_sel;
  logic [          TAG_WIDTH-1:0]                 w_tag;
  logic [         META_WIDTH-1:0]                 w_meta;
  logic [         LINE_WIDTH-1:0]                 w_line;

  // Read address (port A). IMPORTANT: when writing, must match write address.
  logic [SETS_PER_BANK_WIDTH-1:0]                 r_bank_addr;
  logic [     BANK_SEL_WIDTH-1:0]                 r_bank_sel;

  // ---------------------------------------------------------------------------
  // State machine
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_LOOKUP,
    S_STORE_WRITE,
    S_WB_REQ,
    S_MISS_REQ,
    S_WAIT_REFILL,
    S_RESP
  } d_state_e;

  d_state_e state_q, state_d;

  // ---------------------------------------------------------------------------
  // In-flight request registers
  // ---------------------------------------------------------------------------
  logic                                                 req_is_store_q;
  logic                [                  Cfg.PLEN-1:0] req_addr_q;
  decode_pkg::lsu_op_e                                  req_op_q;
  logic                [                  Cfg.XLEN-1:0] req_wdata_q;
  logic                [          LD_PORT_ID_WIDTH-1:0] req_id_q;
  logic                                                 pending_ld_valid_q;
  logic                [                  Cfg.PLEN-1:0] pending_ld_addr_q;
  decode_pkg::lsu_op_e                                  pending_ld_op_q;
  logic                [          LD_PORT_ID_WIDTH-1:0] pending_ld_id_q;

  logic                [           LINE_ADDR_WIDTH-1:0] req_line_addr_q;
  logic                [               INDEX_WIDTH-1:0] req_index_q;
  logic                [                 TAG_WIDTH-1:0] req_tag_q;
  logic                [              OFFSET_WIDTH-1:0] req_byte_off_q;
  logic                [       SETS_PER_BANK_WIDTH-1:0] req_bank_addr_q;
  logic                [            BANK_SEL_WIDTH-1:0] req_bank_sel_q;

  logic                                                 req_err_q;

  // Miss/victim context
  logic                [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] victim_way_q;
  logic                [                 TAG_WIDTH-1:0] victim_tag_q;
  logic                [                LINE_WIDTH-1:0] victim_line_q;
  logic                                                 victim_valid_q;
  logic                                                 victim_dirty_q;

  logic                [                  Cfg.PLEN-1:0] miss_paddr_q;
  logic                [               INDEX_WIDTH-1:0] miss_index_q;
  logic                [       SETS_PER_BANK_WIDTH-1:0] miss_bank_addr_q;
  logic                [            BANK_SEL_WIDTH-1:0] miss_bank_sel_q;

  logic                [                  Cfg.PLEN-1:0] wb_paddr_q;

  // Store-hit update buffer
  logic                [                LINE_WIDTH-1:0] store_new_line_q;
  logic                [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] store_hit_way_q;

  // Last write bypass (fix RAW hazard on back-to-back stores/loads)
  logic                                 last_write_valid_q;
  logic                 [TAG_WIDTH-1:0] last_write_tag_q;
  logic               [INDEX_WIDTH-1:0] last_write_index_q;
  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] last_write_way_q;
  logic                [LINE_WIDTH-1:0] last_write_line_q;

  // Load response regs
  logic                                                 rsp_err_q;
  logic                [                  Cfg.XLEN-1:0] rsp_data_q;
  logic                [          LD_PORT_ID_WIDTH-1:0] rsp_id_q;

  // ---------------------------------------------------------------------------
  // MSHR (load-miss tracking, parameterized)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic wb_done;
    logic miss_sent;
    logic is_store;
    logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] victim_way;
    logic [TAG_WIDTH-1:0] victim_tag;
    logic [LINE_WIDTH-1:0] victim_line;
    logic victim_valid;
    logic victim_dirty;
    logic [INDEX_WIDTH-1:0] index;
    logic [SETS_PER_BANK_WIDTH-1:0] bank_addr;
    logic [BANK_SEL_WIDTH-1:0] bank_sel;
    logic [OFFSET_WIDTH-1:0] byte_off;
    decode_pkg::lsu_op_e op;
    logic [Cfg.XLEN-1:0] store_wdata;
    logic [LD_PORT_ID_WIDTH-1:0] id;
  } mshr_entry_t;

  localparam int unsigned MSHR_DATA_WIDTH = $bits(mshr_entry_t);

  logic [MSHR_ENTRIES-1:0] mshr_entry_valid;
  logic [MSHR_ENTRIES-1:0][LINE_ADDR_WIDTH-1:0] mshr_entry_key;
  logic [MSHR_ENTRIES-1:0][MSHR_DATA_WIDTH-1:0] mshr_entry_data_packed;
  mshr_entry_t [MSHR_ENTRIES-1:0] mshr_entry_data;

  logic mshr_alloc_valid, mshr_alloc_ready, mshr_alloc_fire;
  logic [MSHR_IDX_WIDTH-1:0] mshr_alloc_idx;
  logic [LINE_ADDR_WIDTH-1:0] mshr_alloc_key;
  logic [MSHR_DATA_WIDTH-1:0] mshr_alloc_data_packed;

  logic mshr_update_valid;
  logic [MSHR_IDX_WIDTH-1:0] mshr_update_idx;
  logic [MSHR_DATA_WIDTH-1:0] mshr_update_data_packed;

  logic mshr_dealloc_valid;
  logic [MSHR_IDX_WIDTH-1:0] mshr_dealloc_idx;

  logic mshr_full, mshr_empty;
  logic [$clog2(MSHR_ENTRIES + 1)-1:0] mshr_count;

  logic mshr_req_line_hit;
  logic [MSHR_IDX_WIDTH-1:0] mshr_req_line_idx;
  logic mshr_refill_hit;
  logic [MSHR_IDX_WIDTH-1:0] mshr_refill_idx;
  logic [LINE_ADDR_WIDTH-1:0] refill_line_addr;

  logic mshr_wb_candidate_valid;
  logic [MSHR_IDX_WIDTH-1:0] mshr_wb_candidate_idx;
  logic mshr_miss_candidate_valid;
  logic [MSHR_IDX_WIDTH-1:0] mshr_miss_candidate_idx;
  mshr_entry_t mshr_alloc_entry_d;
  mshr_entry_t mshr_update_entry_d;

  logic idle_refill_fire;
  logic idle_refill_match;
  logic idle_refill_is_store;
  logic lookup_store_refill_fire;
  logic miss_alloc_fire;

  // ---------------------------------------------------------------------------
  // Replacement policy (pseudo-random)
  // ---------------------------------------------------------------------------
  logic                [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] lfsr_out;
  lfsr #(
      .LfsrWidth(4),
      .OutWidth (Cfg.DCACHE_SET_ASSOC_WIDTH)
  ) u_lfsr (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .en_i  (1'b1),
      .out_o (lfsr_out)
  );

  generate
    for (genvar mi = 0; mi < MSHR_ENTRIES; mi++) begin : g_mshr_unpack
      assign mshr_entry_data[mi] = mshr_entry_t'(mshr_entry_data_packed[mi]);
    end
  endgenerate

  mshr #(
      .N_ENTRIES (MSHR_ENTRIES),
      .KEY_WIDTH (LINE_ADDR_WIDTH),
      .DATA_WIDTH(MSHR_DATA_WIDTH)
  ) u_mshr (
      .clk_i,
      .rst_ni,
      .flush_i,

      .alloc_valid_i(mshr_alloc_valid),
      .alloc_ready_o(mshr_alloc_ready),
      .alloc_key_i  (mshr_alloc_key),
      .alloc_data_i (mshr_alloc_data_packed),
      .alloc_fire_o (mshr_alloc_fire),
      .alloc_idx_o  (mshr_alloc_idx),

      .update_valid_i(mshr_update_valid),
      .update_idx_i  (mshr_update_idx),
      .update_data_i (mshr_update_data_packed),

      .dealloc_valid_i(mshr_dealloc_valid),
      .dealloc_idx_i  (mshr_dealloc_idx),

      .entry_valid_o(mshr_entry_valid),
      .entry_key_o  (mshr_entry_key),
      .entry_data_o (mshr_entry_data_packed),
      .full_o       (mshr_full),
      .empty_o      (mshr_empty),
      .count_o      (mshr_count)
  );

  // ---------------------------------------------------------------------------
  // Tag/data array instances
  // ---------------------------------------------------------------------------
  tag_array #(
      .NUM_WAYS           (NUM_WAYS),
      .NUM_BANKS          (NUM_BANKS),
      .SETS_PER_BANK_WIDTH(SETS_PER_BANK_WIDTH),
      .TAG_WIDTH          (TAG_WIDTH),
      .VALID_WIDTH        (META_WIDTH)
  ) u_tag_array (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .bank_addr_ra_i (r_bank_addr),
      .bank_sel_ra_i  (r_bank_sel),
      .bank_sel_ra_o_i(r_bank_sel),
      .rdata_tag_a_o  (tag_a),
      .rdata_valid_a_o(meta_a),

      .bank_addr_rb_i (r_bank_addr),
      .bank_sel_rb_i  (r_bank_sel),
      .bank_sel_rb_o_i(r_bank_sel),
      .rdata_tag_b_o  (tag_b),
      .rdata_valid_b_o(meta_b),

      .w_bank_addr_i(w_bank_addr),
      .w_bank_sel_i (w_bank_sel),
      .we_way_mask_i(we_way_mask),
      .wdata_tag_i  (w_tag),
      .wdata_valid_i(w_meta)
  );

  data_array #(
      .NUM_WAYS           (NUM_WAYS),
      .NUM_BANKS          (NUM_BANKS),
      .SETS_PER_BANK_WIDTH(SETS_PER_BANK_WIDTH),
      .BLOCK_WIDTH        (LINE_WIDTH)
  ) u_data_array (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .bank_addr_ra_i(r_bank_addr),
      .bank_sel_ra_i (r_bank_sel),
      .bank_sel_ra_o_i(r_bank_sel),
      .rdata_a_o     (line_a_all),

      .bank_addr_rb_i(r_bank_addr),
      .bank_sel_rb_i (r_bank_sel),
      .bank_sel_rb_o_i(r_bank_sel),
      .rdata_b_o     (line_b_all),

      .w_bank_addr_i(w_bank_addr),
      .w_bank_sel_i (w_bank_sel),
      .we_way_mask_i(we_way_mask),
      .wdata_i      (w_line)
  );

  // ---------------------------------------------------------------------------
  // Hit detection
  // ---------------------------------------------------------------------------
  logic [NUM_WAYS-1:0] way_valid;
  logic [NUM_WAYS-1:0] way_dirty;
  logic [NUM_WAYS-1:0] hit_way;
  logic hit;
  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] hit_way_idx;

  generate
    genvar w;
    for (w = 0; w < NUM_WAYS; w++) begin : gen_meta_extract
      assign way_valid[w] = meta_a[w][0];
      assign way_dirty[w] = meta_a[w][1];
      assign hit_way[w]   = way_valid[w] && (tag_a[w] == req_tag_q);
    end
  endgenerate

  assign hit = |hit_way;

  priority_encoder #(
      .WIDTH(NUM_WAYS)
  ) u_pe_hit (
      .in (hit_way),
      .out(hit_way_idx)
  );

  // Victim selection
  logic [NUM_WAYS-1:0] invalid_ways;
  logic has_invalid;
  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] first_invalid_idx;
  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] victim_way_d;

  assign invalid_ways = ~way_valid;
  assign has_invalid  = |invalid_ways;

  priority_encoder #(
      .WIDTH(NUM_WAYS)
  ) u_pe_invalid (
      .in (invalid_ways),
      .out(first_invalid_idx)
  );

  always_comb begin
    if (has_invalid) victim_way_d = first_invalid_idx;
    else victim_way_d = lfsr_out;
  end

  assign refill_line_addr = refill_paddr_i[Cfg.PLEN-1:OFFSET_WIDTH];

  always_comb begin
    mshr_req_line_hit = 1'b0;
    mshr_req_line_idx = '0;
    ld_req_line_in_mshr = 1'b0;
    st_req_line_in_mshr = 1'b0;
    mshr_refill_hit = 1'b0;
    mshr_refill_idx = '0;
    mshr_wb_candidate_valid = 1'b0;
    mshr_wb_candidate_idx = '0;
    mshr_miss_candidate_valid = 1'b0;
    mshr_miss_candidate_idx = '0;

    for (int i = 0; i < MSHR_ENTRIES; i++) begin
      if (!mshr_req_line_hit && mshr_entry_valid[i] && (mshr_entry_key[i] == req_line_addr_q)) begin
        mshr_req_line_hit = 1'b1;
        mshr_req_line_idx = MSHR_IDX_WIDTH'(i);
      end
      if (!ld_req_line_in_mshr && mshr_entry_valid[i] && (mshr_entry_key[i] == ld_req_line_addr)) begin
        ld_req_line_in_mshr = 1'b1;
      end
      if (!st_req_line_in_mshr && mshr_entry_valid[i] && (mshr_entry_key[i] == st_req_line_addr)) begin
        st_req_line_in_mshr = 1'b1;
      end
      if (!mshr_refill_hit && mshr_entry_valid[i] && (mshr_entry_key[i] == refill_line_addr)) begin
        mshr_refill_hit = 1'b1;
        mshr_refill_idx = MSHR_IDX_WIDTH'(i);
      end
      if (!mshr_wb_candidate_valid && mshr_entry_valid[i] && !mshr_entry_data[i].wb_done) begin
        mshr_wb_candidate_valid = 1'b1;
        mshr_wb_candidate_idx = MSHR_IDX_WIDTH'(i);
      end
      if (!mshr_miss_candidate_valid && mshr_entry_valid[i] &&
          mshr_entry_data[i].wb_done && !mshr_entry_data[i].miss_sent) begin
        mshr_miss_candidate_valid = 1'b1;
        mshr_miss_candidate_idx = MSHR_IDX_WIDTH'(i);
      end
    end
  end

  assign idle_refill_fire = (state_q == S_IDLE) && refill_valid_i && refill_ready_o;
  assign idle_refill_match = idle_refill_fire && mshr_refill_hit;
  assign idle_refill_is_store = idle_refill_match && mshr_entry_data[mshr_refill_idx].is_store;
  assign lookup_store_refill_fire =
      (state_q == S_LOOKUP) && refill_valid_i && refill_ready_o &&
      mshr_refill_hit && mshr_entry_data[mshr_refill_idx].is_store;

  assign miss_alloc_fire =
      (state_q == S_LOOKUP) && !req_err_q && !hit &&
      !mshr_req_line_hit && mshr_alloc_ready;

  always_comb begin
    mshr_alloc_valid = 1'b0;
    mshr_alloc_key = req_line_addr_q;
    mshr_alloc_data_packed = '0;
    mshr_alloc_entry_d = '0;

    mshr_update_valid = 1'b0;
    mshr_update_idx = '0;
    mshr_update_data_packed = '0;
    mshr_update_entry_d = '0;

    mshr_dealloc_valid = 1'b0;
    mshr_dealloc_idx = '0;

    if (miss_alloc_fire) begin
      mshr_alloc_entry_d.wb_done = !(way_valid[victim_way_d] && way_dirty[victim_way_d]);
      mshr_alloc_entry_d.miss_sent = 1'b0;
      mshr_alloc_entry_d.is_store = req_is_store_q;
      mshr_alloc_entry_d.victim_way = victim_way_d;
      mshr_alloc_entry_d.victim_tag = tag_a[victim_way_d];
      mshr_alloc_entry_d.victim_line = line_a_all[victim_way_d];
      mshr_alloc_entry_d.victim_valid = way_valid[victim_way_d];
      mshr_alloc_entry_d.victim_dirty = way_dirty[victim_way_d];
      mshr_alloc_entry_d.index = req_index_q;
      mshr_alloc_entry_d.bank_addr = req_bank_addr_q;
      mshr_alloc_entry_d.bank_sel = req_bank_sel_q;
      mshr_alloc_entry_d.byte_off = req_byte_off_q;
      mshr_alloc_entry_d.op = req_op_q;
      mshr_alloc_entry_d.store_wdata = req_wdata_q;
      mshr_alloc_entry_d.id = req_id_q;

      mshr_alloc_valid = 1'b1;
      mshr_alloc_key = req_line_addr_q;
      mshr_alloc_data_packed = MSHR_DATA_WIDTH'(mshr_alloc_entry_d);
    end

    if ((state_q != S_WB_REQ) && mshr_wb_candidate_valid && wb_req_ready_i) begin
      mshr_update_entry_d = mshr_entry_data[mshr_wb_candidate_idx];
      mshr_update_entry_d.wb_done = 1'b1;
      mshr_update_valid = 1'b1;
      mshr_update_idx = mshr_wb_candidate_idx;
      mshr_update_data_packed = MSHR_DATA_WIDTH'(mshr_update_entry_d);
    end else if ((state_q != S_MISS_REQ) && !mshr_wb_candidate_valid &&
                 mshr_miss_candidate_valid && miss_req_ready_i) begin
      mshr_update_entry_d = mshr_entry_data[mshr_miss_candidate_idx];
      mshr_update_entry_d.miss_sent = 1'b1;
      mshr_update_valid = 1'b1;
      mshr_update_idx = mshr_miss_candidate_idx;
      mshr_update_data_packed = MSHR_DATA_WIDTH'(mshr_update_entry_d);
    end

    if (idle_refill_match || lookup_store_refill_fire) begin
      mshr_dealloc_valid = 1'b1;
      mshr_dealloc_idx = mshr_refill_idx;
    end
  end

  // ---------------------------------------------------------------------------
  // Read-address mux (keep aligned with write address when writing)
  // ---------------------------------------------------------------------------
  always_comb begin
    // Defaults: drive the current request index
    r_bank_addr = req_bank_addr_q;
    r_bank_sel  = req_bank_sel_q;

    // In IDLE, when we accept a request, use the selected request address
    if (state_q == S_IDLE && accept_req) begin
      r_bank_addr = sel_bank_addr;
      r_bank_sel  = sel_bank_sel;
    end

    if ((state_q == S_IDLE && idle_refill_match) || lookup_store_refill_fire) begin
      r_bank_addr = mshr_entry_data[mshr_refill_idx].bank_addr;
      r_bank_sel  = mshr_entry_data[mshr_refill_idx].bank_sel;
    end

    // During store-hit update, force read A to same bank/address as the write
    if (state_q == S_STORE_WRITE) begin
      r_bank_addr = req_bank_addr_q;
      r_bank_sel  = req_bank_sel_q;
    end

    // Response handoff: predrive next lookup address because SRAM read is sync.
    if ((state_q == S_RESP) && rsp_handoff_fire_w) begin
      r_bank_addr = rsp_handoff_bank_addr_w;
      r_bank_sel  = rsp_handoff_bank_sel_w;
    end

    // During refill write, force read A to same bank/address as the write
    if (state_q == S_WAIT_REFILL) begin
      r_bank_addr = miss_bank_addr_q;
      r_bank_sel  = miss_bank_sel_q;
    end
  end

  // Select the freshest line data for a hit (bypass last write if same line/way).
  logic [LINE_WIDTH-1:0] hit_line;
  always_comb begin
    hit_line = line_a_all[hit_way_idx];
    if (last_write_valid_q &&
        (last_write_tag_q == req_tag_q) &&
        (last_write_index_q == req_index_q) &&
        (last_write_way_q == hit_way_idx)) begin
      hit_line = last_write_line_q;
    end
  end

  // ---------------------------------------------------------------------------
  // Default assignments for write port and memory interface
  // ---------------------------------------------------------------------------
  always_comb begin
    // Array write defaults
    we_way_mask           = '0;
    w_bank_addr           = '0;
    w_bank_sel            = '0;
    w_tag                 = '0;
    w_meta                = '0;
    w_line                = '0;

    // Miss/Refill defaults
    miss_req_valid_o      = 1'b0;
    miss_req_paddr_o      = miss_paddr_q;
    miss_req_victim_way_o = victim_way_q;
    miss_req_index_o      = miss_index_q;

    refill_ready_o        = ((state_q == S_WAIT_REFILL) || (state_q == S_IDLE) ||
                             ((state_q == S_LOOKUP) && mshr_refill_hit &&
                              mshr_entry_data[mshr_refill_idx].is_store));

    // Writeback defaults
    wb_req_valid_o        = 1'b0;
    wb_req_paddr_o        = wb_paddr_q;
    wb_req_data_o         = victim_line_q;

    // Load response outputs
    ld_rsp_valid_o        = (state_q == S_RESP);
    ld_rsp_data_o         = rsp_data_q;
    ld_rsp_err_o          = rsp_err_q;
    ld_rsp_id_o           = rsp_id_q;

    unique case (state_q)
      S_STORE_WRITE: begin
        // Write back the merged line to the hit way and mark dirty.
        we_way_mask                  = '0;
        we_way_mask[store_hit_way_q] = 1'b1;
        w_bank_addr                  = req_bank_addr_q;
        w_bank_sel                   = req_bank_sel_q;
        w_tag                        = req_tag_q;
        w_meta                       = {1'b1  /*dirty*/, 1'b1  /*valid*/};
        w_line                       = store_new_line_q;
      end

      S_WB_REQ: begin
        wb_req_valid_o = 1'b1;
      end

      S_MISS_REQ: begin
        miss_req_valid_o = 1'b1;
      end

      S_WAIT_REFILL: begin
        if (refill_valid_i) begin
          // Write refill (load miss) or refill+merge (store miss)
          we_way_mask = '0;
          we_way_mask[refill_way_i] = 1'b1;
          w_bank_addr = miss_bank_addr_q;
          w_bank_sel = miss_bank_sel_q;
          // Tag from refill address
          w_tag = refill_paddr_i[Cfg.PLEN-1:OFFSET_WIDTH][INDEX_WIDTH+:TAG_WIDTH];
          w_meta = {req_is_store_q  /*dirty for store*/, 1'b1  /*valid*/};
          if (req_is_store_q) begin
            w_line = apply_store(refill_data_i, req_byte_off_q, req_op_q, req_wdata_q);
          end else begin
            w_line = refill_data_i;
          end
        end
      end

      default: begin
        // no writes
      end
    endcase

    // MSHR-driven non-blocking writeback/miss request path.
    if ((state_q != S_WB_REQ) && mshr_wb_candidate_valid) begin
      wb_req_valid_o = 1'b1;
      wb_req_paddr_o = {
          mshr_entry_data[mshr_wb_candidate_idx].victim_tag,
          mshr_entry_data[mshr_wb_candidate_idx].index,
          {OFFSET_WIDTH{1'b0}}
      };
      wb_req_data_o = mshr_entry_data[mshr_wb_candidate_idx].victim_line;
    end else if ((state_q != S_MISS_REQ) && !mshr_wb_candidate_valid && mshr_miss_candidate_valid) begin
      miss_req_valid_o = 1'b1;
      miss_req_paddr_o = {mshr_entry_key[mshr_miss_candidate_idx], {OFFSET_WIDTH{1'b0}}};
      miss_req_victim_way_o = mshr_entry_data[mshr_miss_candidate_idx].victim_way;
      miss_req_index_o = mshr_entry_data[mshr_miss_candidate_idx].index;
    end

    // Refill response for an MSHR-tracked load miss.
    if (idle_refill_match || lookup_store_refill_fire) begin
      we_way_mask = '0;
      we_way_mask[mshr_entry_data[mshr_refill_idx].victim_way] = 1'b1;
      w_bank_addr = mshr_entry_data[mshr_refill_idx].bank_addr;
      w_bank_sel = mshr_entry_data[mshr_refill_idx].bank_sel;
      w_tag = refill_paddr_i[Cfg.PLEN-1:OFFSET_WIDTH][INDEX_WIDTH+:TAG_WIDTH];
      w_meta = {mshr_entry_data[mshr_refill_idx].is_store, 1'b1};
      if (mshr_entry_data[mshr_refill_idx].is_store) begin
        w_line = apply_store(
            refill_data_i,
            mshr_entry_data[mshr_refill_idx].byte_off,
            mshr_entry_data[mshr_refill_idx].op,
            mshr_entry_data[mshr_refill_idx].store_wdata
        );
      end else begin
        w_line = refill_data_i;
      end
    end

    // On flush, suppress handshakes/responses.
    if (flush_i && !(state_q != S_IDLE && req_is_store_q)) begin
      miss_req_valid_o = 1'b0;
      refill_ready_o   = 1'b0;
      wb_req_valid_o   = 1'b0;
      ld_rsp_valid_o   = 1'b0;
      ld_rsp_data_o    = '0;
      ld_rsp_err_o     = 1'b0;
      ld_rsp_id_o      = '0;
    end
  end

  // ---------------------------------------------------------------------------
  // Next-state logic
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d = state_q;

    unique case (state_q)
      S_IDLE: begin
        if (idle_refill_match && !idle_refill_is_store) begin
          state_d = S_RESP;
        end else if (accept_req) begin
          state_d = S_LOOKUP;
        end
      end

      S_LOOKUP: begin
        // Alignment errors: treat as "complete" without touching memory.
        if (req_err_q) begin
          if (!req_is_store_q) begin
            state_d = S_RESP;
          end else begin
            state_d = S_IDLE;
          end
        end else if (hit) begin
          if (req_is_store_q) state_d = S_STORE_WRITE;
          else state_d = S_RESP;
        end else begin
          // Miss path
          if (req_is_store_q) begin
            // Store miss: allocate MSHR and return to IDLE.
            if (mshr_req_line_hit || !mshr_alloc_ready) begin
              state_d = S_LOOKUP;
            end else begin
              state_d = S_IDLE;
            end
          end else begin
            // Load miss: allocate MSHR and return to IDLE.
            if (mshr_req_line_hit || !mshr_alloc_ready) begin
              state_d = S_LOOKUP;
            end else begin
              state_d = S_IDLE;
            end
          end
        end
      end

      S_STORE_WRITE: begin
        // One cycle write
        state_d = S_IDLE;
      end

      S_WB_REQ: begin
        if (wb_req_valid_o && wb_req_ready_i) begin
          state_d = S_MISS_REQ;
        end
      end

      S_MISS_REQ: begin
        if (miss_req_valid_o && miss_req_ready_i) begin
          state_d = S_WAIT_REFILL;
        end
      end

      S_WAIT_REFILL: begin
        if (refill_valid_i && refill_ready_o) begin
          if (req_is_store_q) state_d = S_IDLE;
          else state_d = S_RESP;
        end
      end

      S_RESP: begin
        if (ld_rsp_valid_o && ld_rsp_ready_i) begin
          if (rsp_handoff_fire_w) begin
            state_d = S_LOOKUP;
          end else begin
            state_d = S_IDLE;
          end
        end
      end

      default: state_d = S_IDLE;
    endcase

    if (flush_i && !(state_q != S_IDLE && req_is_store_q)) begin
      state_d = S_IDLE;
    end
  end

  // ---------------------------------------------------------------------------
  // Sequential logic
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q          <= S_IDLE;

      req_is_store_q   <= 1'b0;
      req_addr_q       <= '0;
      req_op_q         <= decode_pkg::LSU_LW;
      req_wdata_q      <= '0;
      req_id_q         <= '0;
      pending_ld_valid_q <= 1'b0;
      pending_ld_addr_q  <= '0;
      pending_ld_op_q    <= decode_pkg::LSU_LW;
      pending_ld_id_q    <= '0;
      req_line_addr_q  <= '0;
      req_index_q      <= '0;
      req_tag_q        <= '0;
      req_byte_off_q   <= '0;
      req_bank_addr_q  <= '0;
      req_bank_sel_q   <= '0;
      req_err_q        <= 1'b0;

      victim_way_q     <= '0;
      victim_tag_q     <= '0;
      victim_line_q    <= '0;
      victim_valid_q   <= 1'b0;
      victim_dirty_q   <= 1'b0;

      miss_paddr_q     <= '0;
      miss_index_q     <= '0;
      miss_bank_addr_q <= '0;
      miss_bank_sel_q  <= '0;

      wb_paddr_q       <= '0;

      store_new_line_q <= '0;
      store_hit_way_q  <= '0;

      rsp_err_q        <= 1'b0;
      rsp_data_q       <= '0;
      rsp_id_q         <= '0;

      last_write_valid_q <= 1'b0;
      last_write_tag_q   <= '0;
      last_write_index_q <= '0;
      last_write_way_q   <= '0;
      last_write_line_q  <= '0;

    end else if (flush_i && !(state_q != S_IDLE && req_is_store_q)) begin
      state_q          <= S_IDLE;

      req_is_store_q   <= 1'b0;
      req_addr_q       <= '0;
      req_op_q         <= decode_pkg::LSU_LW;
      req_wdata_q      <= '0;
      req_id_q         <= '0;
      pending_ld_valid_q <= 1'b0;
      pending_ld_addr_q  <= '0;
      pending_ld_op_q    <= decode_pkg::LSU_LW;
      pending_ld_id_q    <= '0;
      req_line_addr_q  <= '0;
      req_index_q      <= '0;
      req_tag_q        <= '0;
      req_byte_off_q   <= '0;
      req_bank_addr_q  <= '0;
      req_bank_sel_q   <= '0;
      req_err_q        <= 1'b0;

      victim_way_q     <= '0;
      victim_tag_q     <= '0;
      victim_line_q    <= '0;
      victim_valid_q   <= 1'b0;
      victim_dirty_q   <= 1'b0;

      miss_paddr_q     <= '0;
      miss_index_q     <= '0;
      miss_bank_addr_q <= '0;
      miss_bank_sel_q  <= '0;

      wb_paddr_q       <= '0;

      store_new_line_q <= '0;
      store_hit_way_q  <= '0;

      rsp_err_q        <= 1'b0;
      rsp_data_q       <= '0;
      rsp_id_q         <= '0;

      last_write_valid_q <= 1'b0;
      last_write_tag_q   <= '0;
      last_write_index_q <= '0;
      last_write_way_q   <= '0;
      last_write_line_q  <= '0;

    end else begin
      state_q <= state_d;

      // ----------------------------------------------------------
      // Accept new request
      // ----------------------------------------------------------
      if ((state_q == S_RESP) && ld_req_valid_i && ld_req_ready_o && !rsp_fire_w) begin
        pending_ld_valid_q <= 1'b1;
        pending_ld_addr_q  <= ld_req_addr_i;
        pending_ld_op_q    <= ld_req_op_i;
        pending_ld_id_q    <= ld_req_id_i;
      end

      if ((state_q == S_RESP) && rsp_handoff_fire_w) begin
        req_is_store_q  <= 1'b0;
        req_addr_q      <= rsp_handoff_addr_w;
        req_op_q        <= rsp_handoff_op_w;
        req_wdata_q     <= '0;
        req_id_q        <= rsp_handoff_id_w;
        req_line_addr_q <= rsp_handoff_line_addr_w;
        req_index_q     <= rsp_handoff_index_w;
        req_tag_q       <= rsp_handoff_tag_w;
        req_byte_off_q  <= rsp_handoff_byte_off_w;
        req_bank_addr_q <= rsp_handoff_bank_addr_w;
        req_bank_sel_q  <= rsp_handoff_bank_sel_w;
        req_err_q       <= rsp_handoff_err_w;

        if (rsp_handoff_use_pending_w) begin
          pending_ld_valid_q <= 1'b0;
        end
      end

      if (state_q == S_IDLE && accept_req) begin
        req_is_store_q  <= sel_is_store;
        req_addr_q      <= sel_addr;
        req_op_q        <= sel_op;
        req_wdata_q     <= sel_wdata;
        req_id_q        <= sel_is_load ? sel_id : '0;

        if (sel_use_pending_load) begin
          pending_ld_valid_q <= 1'b0;
        end

        req_line_addr_q <= sel_line_addr;
        req_index_q     <= sel_index;
        req_tag_q       <= sel_tag;
        req_byte_off_q  <= sel_byte_off;
        req_bank_addr_q <= sel_bank_addr;
        req_bank_sel_q  <= sel_bank_sel;

        req_err_q       <= is_misaligned(sel_op, sel_addr);
      end

      // ----------------------------------------------------------
      // LOOKUP stage actions
      // ----------------------------------------------------------
      if (state_q == S_LOOKUP) begin
        // Precompute victim context (valid in miss case)
        victim_way_q     <= victim_way_d;
        victim_tag_q     <= tag_a[victim_way_d];
        victim_line_q    <= line_a_all[victim_way_d];
        victim_valid_q   <= way_valid[victim_way_d];
        victim_dirty_q   <= way_dirty[victim_way_d];

        // Miss context (line-aligned request)
        miss_paddr_q     <= {req_line_addr_q, {OFFSET_WIDTH{1'b0}}};
        miss_index_q     <= req_index_q;
        miss_bank_addr_q <= req_bank_addr_q;
        miss_bank_sel_q  <= req_bank_sel_q;

        // Writeback address from current victim tag + current index.
        // NOTE: must use tag_a[...] of this cycle; victim_tag_q updates with NBA.
        wb_paddr_q       <= {{tag_a[victim_way_d], req_index_q}, {OFFSET_WIDTH{1'b0}}};

        if (req_err_q) begin
          // Only loads have response
          if (!req_is_store_q) begin
            rsp_err_q  <= 1'b1;
            rsp_data_q <= '0;
            rsp_id_q   <= req_id_q;
          end else begin
            // Misaligned store should never be committed; flag in simulation.
            $warning("[D$] Misaligned committed store at addr=%h op=%0d", req_addr_q, req_op_q);
          end
        end else if (hit) begin
          if (!req_is_store_q) begin
            rsp_err_q  <= 1'b0;
            rsp_data_q <= extract_load(hit_line, req_byte_off_q, req_op_q);
            rsp_id_q   <= req_id_q;
          end else begin
            // Store hit: compute merged line, write in next state.
            store_hit_way_q <= hit_way_idx;
            store_new_line_q <= apply_store(
                hit_line, req_byte_off_q, req_op_q, req_wdata_q
            );
          end
        end
      end

      // ----------------------------------------------------------
      // Refill completion (capture load response)
      // ----------------------------------------------------------
      if (state_q == S_WAIT_REFILL && refill_valid_i && refill_ready_o) begin
        if (!req_is_store_q) begin
          rsp_err_q  <= 1'b0;
          rsp_data_q <= extract_load(refill_data_i, req_byte_off_q, req_op_q);
          rsp_id_q   <= req_id_q;
        end
      end

      if (idle_refill_match && !mshr_entry_data[mshr_refill_idx].is_store) begin
        rsp_err_q  <= 1'b0;
        rsp_data_q <= extract_load(
            refill_data_i,
            mshr_entry_data[mshr_refill_idx].byte_off,
            mshr_entry_data[mshr_refill_idx].op
        );
        rsp_id_q <= mshr_entry_data[mshr_refill_idx].id;
      end

      // ----------------------------------------------------------
      // Track last write to handle RAW hazards on the same line/way
      // ----------------------------------------------------------
      if (state_q == S_STORE_WRITE) begin
        last_write_valid_q <= 1'b1;
        last_write_tag_q   <= req_tag_q;
        last_write_index_q <= req_index_q;
        last_write_way_q   <= store_hit_way_q;
        last_write_line_q  <= store_new_line_q;
      end else if (idle_refill_match || lookup_store_refill_fire) begin
        last_write_valid_q <= 1'b1;
        last_write_tag_q   <= refill_paddr_i[Cfg.PLEN-1:OFFSET_WIDTH][INDEX_WIDTH+:TAG_WIDTH];
        last_write_index_q <= mshr_entry_data[mshr_refill_idx].index;
        last_write_way_q   <= mshr_entry_data[mshr_refill_idx].victim_way;
        if (mshr_entry_data[mshr_refill_idx].is_store) begin
          last_write_line_q <= apply_store(
              refill_data_i,
              mshr_entry_data[mshr_refill_idx].byte_off,
              mshr_entry_data[mshr_refill_idx].op,
              mshr_entry_data[mshr_refill_idx].store_wdata
          );
        end else begin
          last_write_line_q <= refill_data_i;
        end
      end else if (state_q == S_WAIT_REFILL && refill_valid_i && refill_ready_o) begin
        last_write_valid_q <= 1'b1;
        last_write_tag_q   <= refill_paddr_i[Cfg.PLEN-1:OFFSET_WIDTH][INDEX_WIDTH+:TAG_WIDTH];
        last_write_index_q <= miss_index_q;
        last_write_way_q   <= refill_way_i;
        last_write_line_q  <= w_line;
      end else if (state_q == S_IDLE && !accept_req) begin
        last_write_valid_q <= 1'b0;
      end

      // ----------------------------------------------------------
      // If response was accepted, clear outputs next cycle by state.
      // (ld_rsp_valid_o is state-based)
      // ----------------------------------------------------------
    end
  end

endmodule
