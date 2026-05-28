// vsrc/cache/icache.sv
module icache #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter bit HIT_PIPELINE_EN = 1'b0
) (
    input logic clk_i,
    input logic rst_ni,

    // IFU Interface
    input global_config_pkg::handshake_t ifu_req_handshake_i,
    output global_config_pkg::handshake_t ifu_rsp_handshake_o,
    input logic [Cfg.VLEN-1:0] ifu_req_pc_i,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ifu_rsp_instrs_o,
    input logic ifu_req_flush_i,

    // Miss / Refill interface to external memory system (e.g. AXI wrapper)
    output logic                                  miss_req_valid_o,
    input  logic                                  miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] miss_req_paddr_o,       // line-aligned address
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way_o,  // which way to fill
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] miss_req_index_o,       // index within cache

    input  logic                                  refill_valid_i,
    output logic                                  refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] refill_data_i
);

  // ---------------------------------------------------------------------------
  // Local parameters derived from Cfg
  // ---------------------------------------------------------------------------
  localparam int unsigned NUM_WAYS = Cfg.ICACHE_SET_ASSOC;
  localparam int unsigned NUM_BANKS = Cfg.ICACHE_NUM_BANKS;
  localparam int unsigned BANK_SEL_WIDTH = Cfg.ICACHE_BANK_SEL_WIDTH;
  localparam int unsigned INDEX_WIDTH = Cfg.ICACHE_INDEX_WIDTH;
  localparam int unsigned OFFSET_WIDTH = Cfg.ICACHE_OFFSET_WIDTH;
  localparam int unsigned TAG_WIDTH = Cfg.ICACHE_TAG_WIDTH;
  localparam int unsigned LINE_WIDTH = Cfg.ICACHE_LINE_WIDTH;
  localparam int unsigned SETS_PER_BANK_WIDTH = INDEX_WIDTH - BANK_SEL_WIDTH;
  localparam int unsigned LINE_BYTES = LINE_WIDTH / 8;
  localparam int unsigned ILEN = Cfg.ILEN;
  localparam int unsigned ILEN_BYTES = ILEN / 8;
  localparam int unsigned ILEN_OFFSET_BITS = (ILEN_BYTES > 1) ? $clog2(ILEN_BYTES) : 0;
  localparam int unsigned FETCH_NUM = Cfg.INSTR_PER_FETCH;
  localparam int unsigned LINE_WORDS = LINE_WIDTH / ILEN;
  localparam int unsigned SLOT_WIDTH = (LINE_WORDS > 1) ? $clog2(LINE_WORDS) : 1;
  localparam int unsigned LINE_ADDR_WIDTH = Cfg.PLEN - OFFSET_WIDTH;

  // ---------------------------------------------------------------------------
  // State machine
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    LOOKUP,
    MISS_REQ,
    MISS_WAIT_REFILL,
    REFILL_RECOVER
  } ic_state_e;
  ic_state_e state_q, state_d;
  logic req_killed_q;

  // ---------------------------------------------------------------------------
  // Request pipeline registers (one in-flight request)
  // ---------------------------------------------------------------------------
  logic [       Cfg.PLEN-1:0] pc_q;
  logic [     SLOT_WIDTH-1:0] start_slot_q;
  logic                       cross_line_q;
  logic                       halfword_sel_q;
  // Line address (TAG+INDEX) for current PC and the next line
  logic [LINE_ADDR_WIDTH-1:0] line_addr_a_q;
  logic [LINE_ADDR_WIDTH-1:0] line_addr_b_q;  // next line (for cross-line fetch)

  // Decoded index/tag/bank for A/B
  logic [INDEX_WIDTH-1:0] index_a_q, index_b_q;
  logic [TAG_WIDTH-1:0] tag_a_expected_q, tag_b_expected_q;

  // [New] Next state signals for decoding (Fix BLKANDNBLK)
  logic [LINE_ADDR_WIDTH-1:0] line_addr_a_d;
  logic [LINE_ADDR_WIDTH-1:0] line_addr_b_d;
  logic [INDEX_WIDTH-1:0] index_a_d, index_b_d;
  logic [TAG_WIDTH-1:0] tag_a_expected_d, tag_b_expected_d;
  logic [SLOT_WIDTH-1:0] start_slot_d;
  logic                  cross_line_d;
  logic                  halfword_sel_d;

  // ---------------------------------------------------------------------------
  // Array address mux (fix for synchronous SRAM model)
  // ---------------------------------------------------------------------------
  // sram.sv updates rdata_o on the clock edge (registered output). To achieve a
  // 1-cycle lookup latency (IDLE accept -> LOOKUP compare), we must drive the
  // SRAM address with the combinationally decoded index in the accept cycle.
  // Otherwise, using index_a_q/index_b_q directly would introduce an extra
  // cycle of latency (and can cause functional mismatch in simulation).
  logic [INDEX_WIDTH-1:0] index_a_mem, index_b_mem;
  logic req_accept_w;
  assign req_accept_w = ifu_req_handshake_i.valid && ifu_rsp_handshake_o.ready && !ifu_req_flush_i;
  assign index_a_mem = req_accept_w ? index_a_d : index_a_q;
  assign index_b_mem = req_accept_w ? index_b_d : index_b_q;

  // Miss context
  logic [                  Cfg.PLEN-1:0] miss_paddr_q;
  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] miss_victim_way_q;
  logic [               INDEX_WIDTH-1:0] miss_index_q;
  logic [       SETS_PER_BANK_WIDTH-1:0] miss_bank_addr_q;
  logic [            BANK_SEL_WIDTH-1:0] miss_bank_sel_q;

  // ---------------------------------------------------------------------------
  // Request decode helper (combinational)
  // ---------------------------------------------------------------------------
  function automatic void decode_pc(
      input logic [Cfg.PLEN-1:0] pc, output logic [LINE_ADDR_WIDTH-1:0] line_addr_a,
      output logic [LINE_ADDR_WIDTH-1:0] line_addr_b, output logic [INDEX_WIDTH-1:0] index_a,
      output logic [INDEX_WIDTH-1:0] index_b, output logic [TAG_WIDTH-1:0] tag_a_exp,
      output logic [TAG_WIDTH-1:0] tag_b_exp, output logic [SLOT_WIDTH-1:0] start_slot,
      output logic cross_line, output logic halfword_sel);

    logic [LINE_ADDR_WIDTH-1:0] line_addr_base;
    int unsigned words_needed;
    line_addr_base = pc[Cfg.PLEN-1:OFFSET_WIDTH];
    line_addr_a    = line_addr_base;
    line_addr_b    = line_addr_base + 1'b1;
    index_a        = line_addr_a[INDEX_WIDTH-1:0];
    index_b        = line_addr_b[INDEX_WIDTH-1:0];
    tag_a_exp      = line_addr_a[INDEX_WIDTH+:TAG_WIDTH];
    tag_b_exp      = line_addr_b[INDEX_WIDTH+:TAG_WIDTH];
    halfword_sel   = pc[1];

    // Slot of first instruction within the line (ILEN alignment)
    if (ILEN_BYTES > 1) begin
      start_slot = pc[OFFSET_WIDTH-1:ILEN_OFFSET_BITS];
    end else begin
      start_slot = '0;
    end

    words_needed = FETCH_NUM + (halfword_sel ? 1 : 0);
    if (words_needed > LINE_WORDS) begin
      cross_line = 1'b1;
    end else begin
      cross_line = (start_slot > (LINE_WORDS - words_needed));
    end
  endfunction

  // Combinational decode logic
  always_comb begin
    decode_pc(ifu_req_pc_i, line_addr_a_d, line_addr_b_d, index_a_d, index_b_d, tag_a_expected_d,
              tag_b_expected_d, start_slot_d, cross_line_d, halfword_sel_d);
  end

  // ---------------------------------------------------------------------------
  // Tag & Data arrays
  // ---------------------------------------------------------------------------
  logic [NUM_WAYS-1:0][TAG_WIDTH-1:0] tag_a, tag_b;
  logic [NUM_WAYS-1:0][0:0] valid_a, valid_b;
  logic [NUM_WAYS-1:0][LINE_WIDTH-1:0] line_a_all, line_b_all;

  // Write ports (for refill)
  logic [           NUM_WAYS-1:0] we_way_mask;
  logic [SETS_PER_BANK_WIDTH-1:0] w_bank_addr;
  logic [     BANK_SEL_WIDTH-1:0] w_bank_sel;
  logic [          TAG_WIDTH-1:0] w_tag;
  logic [                    0:0] w_valid;
  logic [         LINE_WIDTH-1:0] w_line;

  // Tag array instance
  tag_array #(
      .NUM_WAYS           (NUM_WAYS),
      .NUM_BANKS          (NUM_BANKS),
      .SETS_PER_BANK_WIDTH(SETS_PER_BANK_WIDTH),
      .TAG_WIDTH          (TAG_WIDTH),
      .VALID_WIDTH        (1)
  ) u_tag_array (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      // Read port A
      .bank_addr_ra_i (index_a_mem[INDEX_WIDTH-1:BANK_SEL_WIDTH]),
      .bank_sel_ra_i  (index_a_mem[BANK_SEL_WIDTH-1:0]),
      .bank_sel_ra_o_i(index_a_q[BANK_SEL_WIDTH-1:0]),
      .rdata_tag_a_o  (tag_a),
      .rdata_valid_a_o(valid_a),
      // Read port B
      .bank_addr_rb_i (index_b_mem[INDEX_WIDTH-1:BANK_SEL_WIDTH]),
      .bank_sel_rb_i  (index_b_mem[BANK_SEL_WIDTH-1:0]),
      .bank_sel_rb_o_i(index_b_q[BANK_SEL_WIDTH-1:0]),
      .rdata_tag_b_o  (tag_b),
      .rdata_valid_b_o(valid_b),
      // Write port
      .w_bank_addr_i  (w_bank_addr),
      .w_bank_sel_i   (w_bank_sel),
      .we_way_mask_i  (we_way_mask),
      .wdata_tag_i    (w_tag),
      .wdata_valid_i  (w_valid)
  );

  // Data array instance
  data_array #(
      .NUM_WAYS           (NUM_WAYS),
      .NUM_BANKS          (NUM_BANKS),
      .SETS_PER_BANK_WIDTH(SETS_PER_BANK_WIDTH),
      .BLOCK_WIDTH        (LINE_WIDTH)
  ) u_data_array (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      // Read port A
      .bank_addr_ra_i(index_a_mem[INDEX_WIDTH-1:BANK_SEL_WIDTH]),
      .bank_sel_ra_i (index_a_mem[BANK_SEL_WIDTH-1:0]),
      .bank_sel_ra_o_i(index_a_q[BANK_SEL_WIDTH-1:0]),
      .rdata_a_o     (line_a_all),
      // Read port B
      .bank_addr_rb_i(index_b_mem[INDEX_WIDTH-1:BANK_SEL_WIDTH]),
      .bank_sel_rb_i (index_b_mem[BANK_SEL_WIDTH-1:0]),
      .bank_sel_rb_o_i(index_b_q[BANK_SEL_WIDTH-1:0]),
      .rdata_b_o     (line_b_all),
      // Write port
      .w_bank_addr_i (w_bank_addr),
      .w_bank_sel_i  (w_bank_sel),
      .we_way_mask_i (we_way_mask),
      .wdata_i       (w_line)
  );

  // ---------------------------------------------------------------------------
  // LFSR for pseudo-random replacement
  // ---------------------------------------------------------------------------
  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] lfsr_out;
  lfsr #(
      .LfsrWidth(4),
      .OutWidth (Cfg.ICACHE_SET_ASSOC_WIDTH)
  ) u_lfsr (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .en_i  (1'b1),     // free running
      .out_o (lfsr_out)
  );

  // ---------------------------------------------------------------------------
  // Hit / replacement logic
  // ---------------------------------------------------------------------------
  logic [NUM_WAYS-1:0] way_valid_a, way_valid_b;
  logic [NUM_WAYS-1:0] hit_way_a, hit_way_b;
  logic hit_a, hit_b, hit_all;
  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] hit_way_idx_a, hit_way_idx_b;

  // Extract valid bits
  generate
    genvar w;
    for (w = 0; w < NUM_WAYS; w++) begin : gen_valid_extract
      assign way_valid_a[w] = valid_a[w][0];
      assign way_valid_b[w] = valid_b[w][0];
    end
  endgenerate

  // Hit detection
  genvar wi;
  generate
    for (wi = 0; wi < NUM_WAYS; wi++) begin : gen_hit
      assign hit_way_a[wi] = way_valid_a[wi] && (tag_a[wi] == tag_a_expected_q);
      assign hit_way_b[wi] = way_valid_b[wi] && (tag_b[wi] == tag_b_expected_q);
    end
  endgenerate

  assign hit_a   = |hit_way_a;
  assign hit_b   = |hit_way_b;
  assign hit_all = hit_a && (!cross_line_q || hit_b);

  // Priority encoders to select first hit way
  priority_encoder #(
      .WIDTH(NUM_WAYS)
  ) u_pe_hit_a (
      .in (hit_way_a),
      .out(hit_way_idx_a)
  );
  priority_encoder #(
      .WIDTH(NUM_WAYS)
  ) u_pe_hit_b (
      .in (hit_way_b),
      .out(hit_way_idx_b)
  );

  // Determine which Line missed (A or B)
  // If !hit_all, and we have cross line, and A hit, then it must be B that missed.
  // Note: hit_a is comb logic, stable during LOOKUP.
  logic miss_on_b;
  assign miss_on_b = hit_a && cross_line_q;

  // Select valid bits for the set that missed
  logic [NUM_WAYS-1:0] ways_valid_for_victim;
  assign ways_valid_for_victim = miss_on_b ? way_valid_b : way_valid_a;

  // Replacement (victim) selection
  logic [                  NUM_WAYS-1:0] invalid_ways;
  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] first_invalid_idx;
  logic                                  has_invalid;
  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] victim_way_d;

  // invalid_ways now derived from the correct set
  assign invalid_ways = ~ways_valid_for_victim;
  assign has_invalid  = |invalid_ways;

  priority_encoder #(
      .WIDTH(NUM_WAYS)
  ) u_pe_invalid (
      .in (invalid_ways),
      .out(first_invalid_idx)
  );

  always_comb begin
    if (has_invalid) begin
      victim_way_d = first_invalid_idx;
    end else begin
      victim_way_d = lfsr_out;
    end
  end

  // ---------------------------------------------------------------------------
  // Output instruction assembly from cache lines
  // ---------------------------------------------------------------------------
  logic [LINE_WORDS-1:0][ILEN-1:0] line_a_words, line_b_words;
  logic [FETCH_NUM-1:0][ILEN-1:0] assembled_instrs;

  generate
    genvar wi2;
    for (wi2 = 0; wi2 < LINE_WORDS; wi2++) begin : gen_line_words
      assign line_a_words[wi2] = line_a_all[hit_way_idx_a][ILEN*wi2+:ILEN];
      assign line_b_words[wi2] = line_b_all[hit_way_idx_b][ILEN*wi2+:ILEN];
    end
  endgenerate

  always_comb begin
    int word_idx;
    logic [ILEN-1:0] word_cur;
    logic [ILEN-1:0] word_next;
    assembled_instrs = '0;

    for (int i = 0; i < FETCH_NUM; i++) begin
      word_idx = int'(start_slot_q) + i;
      word_cur = '0;
      word_next = '0;

      if (word_idx < LINE_WORDS) begin
        word_cur = line_a_words[word_idx];
      end else begin
        word_cur = line_b_words[word_idx - LINE_WORDS];
      end

      if (halfword_sel_q) begin
        if ((word_idx + 1) < LINE_WORDS) begin
          word_next = line_a_words[word_idx + 1];
        end else begin
          word_next = line_b_words[word_idx + 1 - LINE_WORDS];
        end
        assembled_instrs[i] = {word_next[15:0], word_cur[31:16]};
      end else begin
        assembled_instrs[i] = word_cur;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Simple response registers
  // ---------------------------------------------------------------------------
  logic                           rsp_valid_q;
  logic [FETCH_NUM-1:0][ILEN-1:0] rsp_instrs_q;
`ifndef SYNTHESIS

`endif

  assign ifu_rsp_instrs_o          = rsp_instrs_q;
  assign ifu_rsp_handshake_o.valid = rsp_valid_q;
  assign ifu_rsp_handshake_o.ready = (state_q == IDLE) ||
      (HIT_PIPELINE_EN && (state_q == LOOKUP) && hit_all && !ifu_req_flush_i);

  // ---------------------------------------------------------------------------
  // Miss / refill write port & handshake defaults
  // ---------------------------------------------------------------------------
  logic [LINE_ADDR_WIDTH-1:0] refill_line_addr;

  always_comb begin
    // Default: no write
    we_way_mask           = '0;
    w_bank_addr           = miss_bank_addr_q;
    w_bank_sel            = miss_bank_sel_q;
    w_tag                 = '0;
    w_valid               = '0;
    w_line                = '0;
    refill_ready_o        = 1'b0;
    miss_req_valid_o      = 1'b0;
    miss_req_paddr_o      = miss_paddr_q;
    miss_req_victim_way_o = miss_victim_way_q;
    miss_req_index_o      = miss_index_q;

    case (state_q)
      MISS_REQ: begin
        miss_req_valid_o = 1'b1;
      end

      MISS_WAIT_REFILL: begin
        refill_ready_o = 1'b1;
        if (refill_valid_i) begin
          // Accept refill, write into arrays
          we_way_mask = '0;
          we_way_mask[refill_way_i] = 1'b1;

          // Use stored bank addr / sel from miss context
          w_bank_addr = miss_bank_addr_q;
          w_bank_sel = miss_bank_sel_q;

          // Extract tag from refill address
          refill_line_addr = refill_paddr_i[Cfg.PLEN-1:OFFSET_WIDTH];
          w_tag = refill_line_addr[INDEX_WIDTH+:TAG_WIDTH];
          w_valid = 1'b1;
          w_line = refill_data_i;
        end
      end

      default: begin
        // nothing
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Sequential logic: state, request pipeline, miss context, response regs
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= IDLE;
      req_killed_q      <= 1'b0;
      pc_q              <= '0;
      start_slot_q      <= '0;
      cross_line_q      <= 1'b0;
      halfword_sel_q    <= 1'b0;
      line_addr_a_q     <= '0;
      line_addr_b_q     <= '0;
      index_a_q         <= '0;
      index_b_q         <= '0;
      tag_a_expected_q  <= '0;
      tag_b_expected_q  <= '0;
      rsp_valid_q       <= 1'b0;
      rsp_instrs_q      <= '0;
`ifndef SYNTHESIS
`endif
      miss_paddr_q      <= '0;
      miss_victim_way_q <= '0;
      miss_index_q      <= '0;
      miss_bank_addr_q  <= '0;
      miss_bank_sel_q   <= '0;
    end else begin
      state_q <= state_d;
      // Flush: drop response; mark current request as killed if in-flight
      if (ifu_req_flush_i) begin
        rsp_valid_q  <= 1'b0;
        rsp_instrs_q <= '0;
        if (state_q != IDLE) begin
          req_killed_q <= 1'b1;
        end
      end

      unique case (state_q)
        IDLE: begin
          if (req_accept_w) begin
            // Latch request (Use computed _d signals)
            pc_q             <= ifu_req_pc_i;
            line_addr_a_q    <= line_addr_a_d;
            line_addr_b_q    <= line_addr_b_d;
            index_a_q        <= index_a_d;
            index_b_q        <= index_b_d;
            tag_a_expected_q <= tag_a_expected_d;
            tag_b_expected_q <= tag_b_expected_d;
            start_slot_q     <= start_slot_d;
            cross_line_q     <= cross_line_d;
            halfword_sel_q   <= halfword_sel_d;
            rsp_valid_q      <= 1'b0;
            req_killed_q     <= 1'b0;
          end
        end

        LOOKUP: begin
          if (!ifu_req_flush_i) begin
            // Use array outputs + stored expected tag to determine hit/miss
            if (hit_all) begin
`ifndef SYNTHESIS

`endif
              if (!req_killed_q) begin
                rsp_valid_q  <= 1'b1;
                rsp_instrs_q <= assembled_instrs;
              end else begin
                rsp_valid_q <= 1'b0;
              end
              if (HIT_PIPELINE_EN && req_accept_w) begin
                // Accept next request in the same cycle as current hit resolution.
                pc_q             <= ifu_req_pc_i;
                line_addr_a_q    <= line_addr_a_d;
                line_addr_b_q    <= line_addr_b_d;
                index_a_q        <= index_a_d;
                index_b_q        <= index_b_d;
                tag_a_expected_q <= tag_a_expected_d;
                tag_b_expected_q <= tag_b_expected_d;
                start_slot_q     <= start_slot_d;
                cross_line_q     <= cross_line_d;
                halfword_sel_q   <= halfword_sel_d;
                req_killed_q     <= 1'b0;
              end
            end else begin
              rsp_valid_q <= 1'b0;
              // [Fix] Capture miss context for the SPECIFIC line that missed
              if (miss_on_b) begin
                miss_paddr_q     <= {line_addr_b_q, {OFFSET_WIDTH{1'b0}}};
                miss_index_q     <= index_b_q;
                miss_bank_addr_q <= index_b_q[INDEX_WIDTH-1:BANK_SEL_WIDTH];
                miss_bank_sel_q  <= index_b_q[BANK_SEL_WIDTH-1:0];
              end else begin
                miss_paddr_q     <= {line_addr_a_q, {OFFSET_WIDTH{1'b0}}};
                miss_index_q     <= index_a_q;
                miss_bank_addr_q <= index_a_q[INDEX_WIDTH-1:BANK_SEL_WIDTH];
                miss_bank_sel_q  <= index_a_q[BANK_SEL_WIDTH-1:0];
              end

              miss_victim_way_q <= victim_way_d;
            end
          end
        end

        MISS_WAIT_REFILL: begin
          // When we accept a refill (combinational block will do the array write)
          if (refill_valid_i && refill_ready_o) begin
            rsp_valid_q <= 1'b0;
          end
        end

        REFILL_RECOVER: begin
          // Keep one quiet cycle after refill write so sync SRAM read path
          // observes updated line, then retry LOOKUP for the same request.
          rsp_valid_q <= 1'b0;
        end

        default: begin
          // nothing
        end
      endcase
    end
`ifdef TRIATHLON_VERBOSE
    $display("ifu2icache_pc: %h", ifu_req_pc_i);
    $display("icache2ifu_valid: %b", ifu_rsp_handshake_o.valid);
    $display("icache2ifu_ready: %b", ifu_rsp_handshake_o.ready);
    $display("icache_current_state: %d", state_q);
`endif

  end

  // ---------------------------------------------------------------------------
  // Next state logic
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d = state_q;
    unique case (state_q)
      IDLE: begin
        if (ifu_req_handshake_i.valid && !ifu_req_flush_i) begin
          // Next cycle arrays will output data for this request
          state_d = LOOKUP;
        end
      end

      LOOKUP: begin
        if (hit_all) begin
          if (HIT_PIPELINE_EN && req_accept_w) begin
            state_d = LOOKUP;
          end else begin
            state_d = IDLE;
          end
        end else begin
          state_d = MISS_REQ;
        end
      end

      MISS_REQ: begin
        if (miss_req_valid_o && miss_req_ready_i) begin
          state_d = MISS_WAIT_REFILL;
        end
      end

      MISS_WAIT_REFILL: begin
        if (refill_valid_i && refill_ready_o) begin
          // After refill write, wait one cycle before re-lookup to avoid
          // issuing a duplicate miss on stale array read data.
          state_d = REFILL_RECOVER;
        end
      end

      REFILL_RECOVER: begin
        state_d = LOOKUP;
      end

      default: state_d = IDLE;
    endcase
  end

endmodule : icache
