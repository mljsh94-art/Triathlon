module lq #(
    parameter int unsigned ROB_IDX_WIDTH = 6,
    parameter int unsigned DEPTH = 16
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input  logic                     alloc_valid_i,
    output logic                     alloc_ready_o,
    input  logic [ROB_IDX_WIDTH-1:0] alloc_rob_tag_i,

    input  logic pop_valid_i,
    output logic pop_ready_o,

    output logic                     head_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] head_rob_tag_o,

    output logic [$clog2(DEPTH + 1)-1:0] count_o,
    output logic                         full_o,
    output logic                         empty_o
);

  localparam int unsigned PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int unsigned CNT_W = $clog2(DEPTH + 1);

  logic [DEPTH-1:0][ROB_IDX_WIDTH-1:0] rob_tag_q;
  logic [PTR_W-1:0] head_q;
  logic [PTR_W-1:0] tail_q;
  logic [CNT_W-1:0] count_q;

  logic alloc_fire;
  logic pop_fire;

  function automatic [PTR_W-1:0] ptr_inc(input [PTR_W-1:0] ptr);
    if (ptr == PTR_W'(DEPTH - 1)) begin
      ptr_inc = '0;
    end else begin
      ptr_inc = ptr + PTR_W'(1);
    end
  endfunction

  assign empty_o = (count_q == CNT_W'(0));
  assign full_o = (count_q == CNT_W'(DEPTH));
  assign count_o = count_q;

  assign alloc_ready_o = !full_o;
  assign head_valid_o = !empty_o;
  assign head_rob_tag_o = head_valid_o ? rob_tag_q[head_q] : '0;
  assign pop_ready_o = head_valid_o;

  assign alloc_fire = alloc_valid_i && alloc_ready_o;
  assign pop_fire = pop_valid_i && pop_ready_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rob_tag_q <= '0;
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
    end else if (flush_i) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
    end else begin
      if (alloc_fire) begin
        rob_tag_q[tail_q] <= alloc_rob_tag_i;
        tail_q <= ptr_inc(tail_q);
      end
      if (pop_fire) begin
        head_q <= ptr_inc(head_q);
      end

      unique case ({alloc_fire, pop_fire})
        2'b10: count_q <= count_q + CNT_W'(1);
        2'b01: count_q <= count_q - CNT_W'(1);
        default: begin
        end
      endcase
    end
  end

  initial begin
    assert (DEPTH > 0)
    else $fatal(1, "lq DEPTH must be > 0");
  end

endmodule
