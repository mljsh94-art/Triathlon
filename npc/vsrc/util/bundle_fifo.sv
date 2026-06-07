// vsrc/util/bundle_fifo.sv
module bundle_fifo #(
    parameter int unsigned DATA_W = 32,
    parameter int unsigned DEPTH = 2,
    parameter bit BYPASS_EN = 1'b1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input  logic              enq_valid_i,
    output logic              enq_ready_o,
    input  logic [DATA_W-1:0] enq_data_i,

    output logic              deq_valid_o,
    input  logic              deq_ready_i,
    output logic [DATA_W-1:0] deq_data_o,

    output logic [$clog2(DEPTH + 1)-1:0] count_o,
    output logic                         full_o,
    output logic                         empty_o
);

  localparam int unsigned PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int unsigned CNT_W = $clog2(DEPTH + 1);

  logic [DEPTH-1:0][DATA_W-1:0] mem_q;
  logic [PTR_W-1:0] head_q;
  logic [PTR_W-1:0] tail_q;
  logic [CNT_W-1:0] count_q;

  logic empty_w;
  logic full_w;
  logic bypass_path_w;
  logic bypass_fire_w;
  logic enq_fire_w;
  logic deq_fire_w;
  logic push_mem_w;
  logic pop_mem_w;

  function automatic [PTR_W-1:0] ptr_inc(input [PTR_W-1:0] ptr);
    if (ptr == PTR_W'(DEPTH - 1)) begin
      ptr_inc = '0;
    end else begin
      ptr_inc = ptr + PTR_W'(1);
    end
  endfunction

  assign empty_w = (count_q == CNT_W'(0));
  assign full_w = (count_q == CNT_W'(DEPTH));

  assign bypass_path_w = (BYPASS_EN != 1'b0) && empty_w && enq_valid_i;

  always_comb begin
    if (flush_i) begin
      deq_valid_o = 1'b0;
      deq_data_o  = '0;
      enq_ready_o = 1'b0;
    end else begin
      deq_valid_o = !empty_w || bypass_path_w;
      deq_data_o  = !empty_w ? mem_q[head_q] : enq_data_i;
      enq_ready_o = !full_w || (deq_fire_w && !bypass_path_w);
    end
  end

  assign deq_fire_w = deq_valid_o && deq_ready_i;
  assign enq_fire_w = enq_valid_i && enq_ready_o;
  assign bypass_fire_w = bypass_path_w && deq_ready_i;

  assign push_mem_w = enq_fire_w && !bypass_fire_w;
  assign pop_mem_w = deq_fire_w && !bypass_fire_w;

  assign count_o = count_q;
  assign full_o = full_w;
  assign empty_o = empty_w;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
      mem_q   <= '0;
    end else if (flush_i) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
    end else begin
      if (push_mem_w) begin
        mem_q[tail_q] <= enq_data_i;
        tail_q <= ptr_inc(tail_q);
      end

      if (pop_mem_w) begin
        head_q <= ptr_inc(head_q);
      end

      unique case ({
        push_mem_w, pop_mem_w
      })
        2'b10: count_q <= count_q + CNT_W'(1);
        2'b01: count_q <= count_q - CNT_W'(1);
        default: begin
        end
      endcase
    end
  end

  initial begin
    assert (DEPTH > 0)
    else $fatal(1, "bundle_fifo DEPTH must be > 0");
  end

endmodule
