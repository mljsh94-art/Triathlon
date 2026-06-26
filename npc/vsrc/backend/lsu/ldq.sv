// vsrc/backend/lsu/ldq.sv
//
// Load Disambiguation Queue (LDQ): set of in-flight loads used for memory disambiguation.
// Each entry tracks the load's ROB tag, PC, translated physical address and
// byte-enable mask plus an `executed` flag that marks when the load has
// produced its value via writeback.
//
// Lifecycle (B2): an entry lives from admission (alloc) until the load
// *commits* (retires) from the ROB, NOT until writeback. Writeback only sets
// `executed`; the entry is freed associatively when the ROB commits the
// matching rob_idx. This keeps the disambiguation record alive long enough for
// a later store address resolution to detect an ordering violation.
//
// Because the LSU admits loads out of program order (issue picks the oldest
// *ready* op) while the ROB commits strictly in program order, free cannot be
// a simple in-order head pop. The queue is therefore a flat valid-bitmap
// free-list: alloc takes any free slot, free clears the slot whose rob_tag
// matches a committing rob_idx, and the executed update / violation CAM are
// associative (content addressed by ROB tag / physical address).
module ldq #(
    parameter int unsigned ROB_IDX_WIDTH = 6,
    parameter int unsigned DEPTH         = 16,
    parameter int unsigned PLEN          = 32,
    parameter int unsigned BE_WIDTH      = 4,
    parameter int unsigned COMMIT_WIDTH  = 4,
    // Number of concurrent load-writeback (executed) update ports. With a wide
    // LSU writeback (multiple load lanes retiring per cycle) more than one entry
    // may transition to `executed` in the same cycle; the disambiguation CAM
    // must observe all of them to avoid missing an ordering violation.
    parameter int unsigned N_EXEC        = 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // ---------------------------------------------------------------
    // Allocate (load admitted into the pipe). Payload carries the load's
    // PC / physical address / byte-enable mask for later disambiguation.
    // ---------------------------------------------------------------
    input  logic                     alloc_valid_i,
    output logic                     alloc_ready_o,
    input  logic [ROB_IDX_WIDTH-1:0] alloc_rob_tag_i,
    input  logic [         PLEN-1:0] alloc_pc_i,
    input  logic [         PLEN-1:0] alloc_paddr_i,
    input  logic [     BE_WIDTH-1:0] alloc_be_i,

    // ---------------------------------------------------------------
    // Commit free (load retired). The ROB commit ports are broadcast here;
    // any entry whose rob_tag matches a valid committing slot is freed. Only
    // loads live in the LDQ, so non-load commits never match.
    // ---------------------------------------------------------------
    input logic [COMMIT_WIDTH-1:0]                    commit_valid_i,
    input logic [COMMIT_WIDTH-1:0][ROB_IDX_WIDTH-1:0] commit_rob_idx_i,

    // ---------------------------------------------------------------
    // Executed update (load writeback): mark the matching entry as having
    // produced its value. Associative match on ROB tag.
    // ---------------------------------------------------------------
    input logic [N_EXEC-1:0]                    exec_valid_i,
    input logic [N_EXEC-1:0][ROB_IDX_WIDTH-1:0] exec_rob_tag_i,

    // ---------------------------------------------------------------
    // Store->load violation CAM. Driven when a store resolves its address.
    // A violation is an executed younger load that overlaps the store.
    // `rob_head_i` is the ROB head pointer used for circular age compare.
    // ---------------------------------------------------------------
    input  logic                     st_query_valid_i,
    input  logic [         PLEN-1:0] st_paddr_i,
    input  logic [     BE_WIDTH-1:0] st_be_i,
    input  logic [ROB_IDX_WIDTH-1:0] st_rob_tag_i,
    input  logic [ROB_IDX_WIDTH-1:0] rob_head_i,
    output logic                     violation_valid_o,
    output logic [         PLEN-1:0] violation_pc_o,
    output logic [ROB_IDX_WIDTH-1:0] violation_rob_idx_o,

    // ---------------------------------------------------------------
    // Status
    // ---------------------------------------------------------------
    output logic                     head_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] head_rob_tag_o,

    output logic [$clog2(DEPTH + 1)-1:0] count_o,
    output logic                         full_o,
    output logic                         empty_o,
    // High when no allocated entry is still waiting for its value (used by
    // the AMO/LR ordering gate that needs all prior loads drained).
    output logic                         inflight_empty_o
);

  localparam int unsigned PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int unsigned CNT_W = $clog2(DEPTH + 1);

  logic [DEPTH-1:0]                    valid_q;
  logic [DEPTH-1:0][ROB_IDX_WIDTH-1:0] rob_tag_q;
  logic [DEPTH-1:0][         PLEN-1:0] pc_q;
  logic [DEPTH-1:0][         PLEN-1:0] paddr_q;
  logic [DEPTH-1:0][     BE_WIDTH-1:0] be_q;
  logic [DEPTH-1:0]                    executed_q;

  logic [CNT_W-1:0] count_q;

  // Circular age relative to ROB head: smaller == older.
  function automatic [ROB_IDX_WIDTH-1:0] rob_age(input [ROB_IDX_WIDTH-1:0] tag);
    rob_age = tag - rob_head_i;
  endfunction

  // -----------------------------------------------------------------
  // Allocation: pick the lowest-index free (invalid) slot.
  // -----------------------------------------------------------------
  logic             free_found;
  logic [PTR_W-1:0] free_idx;
  always_comb begin
    free_found = 1'b0;
    free_idx   = '0;
    for (int i = 0; i < DEPTH; i++) begin
      if (!free_found && !valid_q[i]) begin
        free_found = 1'b1;
        free_idx   = PTR_W'(i);
      end
    end
  end

  logic alloc_fire;
  assign full_o        = (count_q == CNT_W'(DEPTH));
  assign empty_o       = (count_q == CNT_W'(0));
  assign count_o       = count_q;
  assign alloc_ready_o = !full_o;
  assign alloc_fire    = alloc_valid_i && alloc_ready_o;

  // -----------------------------------------------------------------
  // Commit free match: an entry is freed when its rob_tag equals a valid
  // committing rob_idx. rob_idx is unique per in-flight instruction, so at
  // most one commit slot matches any given entry.
  // -----------------------------------------------------------------
  logic [DEPTH-1:0] free_match;
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      free_match[i] = 1'b0;
      if (valid_q[i]) begin
        for (int c = 0; c < COMMIT_WIDTH; c++) begin
          if (commit_valid_i[c] && (commit_rob_idx_i[c] == rob_tag_q[i])) begin
            free_match[i] = 1'b1;
          end
        end
      end
    end
  end

  logic [CNT_W-1:0] free_count;
  always_comb begin
    free_count = '0;
    for (int i = 0; i < DEPTH; i++) begin
      if (free_match[i]) free_count = free_count + CNT_W'(1);
    end
  end

  // Debug-only "head": report the lowest-index valid entry.
  always_comb begin
    head_valid_o   = !empty_o;
    head_rob_tag_o = '0;
    for (int i = DEPTH - 1; i >= 0; i--) begin
      if (valid_q[i]) head_rob_tag_o = rob_tag_q[i];
    end
  end

  // No allocated entry is still awaiting its value.
  always_comb begin
    inflight_empty_o = 1'b1;
    for (int i = 0; i < DEPTH; i++) begin
      if (valid_q[i] && !executed_q[i]) begin
        inflight_empty_o = 1'b0;
      end
    end
  end

  // -----------------------------------------------------------------
  // Store->load violation CAM (combinational over registered state).
  // Overlap = same word address AND intersecting byte mask. Violation =
  // an executed load that is younger (larger age) than the resolving store.
  // Among all matches the oldest load is reported.
  //
  // A load whose value lands *this* cycle (exec_valid_i) is treated as
  // executed for the CAM: its paddr/be were registered at alloc, only the
  // `executed` flag is being set now. This closes the 1-cycle hole where a
  // store resolves its address in the same cycle a younger overlapping load
  // writes back (it could not have forwarded from the still-addressless
  // store, so it read stale data and must be squashed). No combinational
  // loop arises: the violation outputs only feed registered store-writeback
  // fields, never exec_valid_i.
  // -----------------------------------------------------------------
  logic [ROB_IDX_WIDTH-1:0] st_age;
  assign st_age = rob_age(st_rob_tag_i);

  always_comb begin
    logic                     best_valid;
    logic [ROB_IDX_WIDTH-1:0] best_age;
    logic [         PLEN-1:0] best_pc;
    logic [ROB_IDX_WIDTH-1:0] best_rob;
    logic [ROB_IDX_WIDTH-1:0] ld_age;
    logic                     ld_executed;

    best_valid = 1'b0;
    best_age   = '0;
    best_pc    = '0;
    best_rob   = '0;

    for (int i = 0; i < DEPTH; i++) begin
      ld_executed = executed_q[i];
      for (int e = 0; e < N_EXEC; e++) begin
        if (exec_valid_i[e] && (rob_tag_q[i] == exec_rob_tag_i[e])) begin
          ld_executed = 1'b1;
        end
      end
      if (valid_q[i] && ld_executed &&
          (paddr_q[i][PLEN-1:2] == st_paddr_i[PLEN-1:2]) &&
          ((be_q[i] & st_be_i) != '0)) begin
        ld_age = rob_age(rob_tag_q[i]);
        if (ld_age > st_age) begin
          if (!best_valid || (ld_age < best_age)) begin
            best_valid = 1'b1;
            best_age   = ld_age;
            best_pc    = pc_q[i];
            best_rob   = rob_tag_q[i];
          end
        end
      end
    end

    violation_valid_o   = st_query_valid_i && best_valid;
    violation_pc_o      = best_pc;
    violation_rob_idx_o = best_rob;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= '0;
      rob_tag_q <= '0;
      pc_q <= '0;
      paddr_q <= '0;
      be_q <= '0;
      executed_q <= '0;
      count_q <= '0;
    end else if (flush_i) begin
      // Flush clears the whole queue: any survivor would be younger than the
      // mispredicting/faulting instruction and is squashed regardless.
      valid_q <= '0;
      executed_q <= '0;
      count_q <= '0;
    end else begin
      for (int i = 0; i < DEPTH; i++) begin
        if (alloc_fire && (PTR_W'(i) == free_idx)) begin
          // Allocation targets a free (invalid) slot, so it never collides
          // with a free_match (which only hits valid slots).
          valid_q[i] <= 1'b1;
          executed_q[i] <= 1'b0;
          rob_tag_q[i] <= alloc_rob_tag_i;
          pc_q[i] <= alloc_pc_i;
          paddr_q[i] <= alloc_paddr_i;
          be_q[i] <= alloc_be_i;
        end else if (free_match[i]) begin
          valid_q[i] <= 1'b0;
        end else if (valid_q[i]) begin
          for (int e = 0; e < N_EXEC; e++) begin
            if (exec_valid_i[e] && (rob_tag_q[i] == exec_rob_tag_i[e])) begin
              executed_q[i] <= 1'b1;
            end
          end
        end
      end

      count_q <= count_q + CNT_W'(alloc_fire) - free_count;
    end
  end

  initial begin
    assert (DEPTH > 0)
    else $fatal(1, "ldq DEPTH must be > 0");
  end

`ifndef SYNTHESIS
  // Allocation must never overwrite a live entry, and the queue must never
  // overflow.
  always_ff @(posedge clk_i) begin
    if (rst_ni && !flush_i) begin
      if (alloc_fire) begin
        assert (free_found)
        else $fatal(1, "ldq: alloc_fire without a free slot");
      end
    end
  end
`endif

endmodule
