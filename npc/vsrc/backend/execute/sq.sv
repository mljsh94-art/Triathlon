module sq #(
    parameter int unsigned ROB_IDX_WIDTH = 6,
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned DEPTH = 16
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input  logic                     alloc_valid_i,
    output logic                     alloc_ready_o,
    input  logic [ROB_IDX_WIDTH-1:0] alloc_rob_tag_i,
    input  logic [   ADDR_WIDTH-1:0] alloc_addr_i,
    input  logic [   DATA_WIDTH-1:0] alloc_data_i,
    input  logic [DATA_WIDTH/8-1 : 0] alloc_be_i,

    input  logic pop_valid_i,
    output logic pop_ready_o,

    // Combinational store-to-load forwarding query.
    input  logic                     fwd_query_valid_i,
    input  logic [  ADDR_WIDTH-1:0]  fwd_query_addr_i,
    input  logic [DATA_WIDTH/8-1:0]  fwd_query_be_i,
    input  logic [ROB_IDX_WIDTH-1:0] fwd_query_rob_tag_i,
    input  logic [ROB_IDX_WIDTH-1:0] rob_head_i,
    output logic                     fwd_query_hit_o,
    output logic [ DATA_WIDTH-1:0]   fwd_query_data_o,

    output logic                     head_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] head_rob_tag_o,
    output logic [   ADDR_WIDTH-1:0] head_addr_o,
    output logic [   DATA_WIDTH-1:0] head_data_o,
    output logic [DATA_WIDTH/8-1 : 0] head_be_o,

    output logic [$clog2(DEPTH + 1)-1:0] count_o,
    output logic                         full_o,
    output logic                         empty_o
);

  localparam int unsigned PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int unsigned CNT_W = $clog2(DEPTH + 1);
  localparam int unsigned BYTE_W = DATA_WIDTH / 8;

  logic [DEPTH-1:0][ROB_IDX_WIDTH-1:0] rob_tag_q;
  logic [DEPTH-1:0][ADDR_WIDTH-1:0] addr_q;
  logic [DEPTH-1:0][DATA_WIDTH-1:0] data_q;
  logic [DEPTH-1:0][DATA_WIDTH/8-1:0] be_q;
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

  function automatic [PTR_W-1:0] ptr_dec(input [PTR_W-1:0] ptr);
    if (ptr == '0) begin
      ptr_dec = PTR_W'(DEPTH - 1);
    end else begin
      ptr_dec = ptr - PTR_W'(1);
    end
  endfunction

  function automatic logic [ROB_IDX_WIDTH-1:0] rob_age(input logic [ROB_IDX_WIDTH-1:0] idx,
                                                       input logic [ROB_IDX_WIDTH-1:0] head);
    logic [ROB_IDX_WIDTH-1:0] diff;
    begin
      diff = idx - head;
      return diff;
    end
  endfunction

  assign empty_o = (count_q == CNT_W'(0));
  assign full_o = (count_q == CNT_W'(DEPTH));
  assign count_o = count_q;

  assign alloc_ready_o = !full_o;
  assign head_valid_o = !empty_o;
  assign head_rob_tag_o = head_valid_o ? rob_tag_q[head_q] : '0;
  assign head_addr_o = head_valid_o ? addr_q[head_q] : '0;
  assign head_data_o = head_valid_o ? data_q[head_q] : '0;
  assign head_be_o = head_valid_o ? be_q[head_q] : '0;
  assign pop_ready_o = head_valid_o;

  assign alloc_fire = alloc_valid_i && alloc_ready_o;
  assign pop_fire = pop_valid_i && pop_ready_o;

  always_comb begin
    logic [BYTE_W-1:0] covered_be;
    logic [PTR_W-1:0] scan_idx;
    logic [ROB_IDX_WIDTH-1:0] load_age;
    logic [ROB_IDX_WIDTH-1:0] store_age;
    logic older_than_load;

    covered_be = '0;
    fwd_query_hit_o = 1'b0;
    fwd_query_data_o = '0;
    scan_idx = ptr_dec(tail_q);
    load_age = '0;
    store_age = '0;
    older_than_load = 1'b0;

    if (fwd_query_valid_i) begin
      load_age = rob_age(fwd_query_rob_tag_i, rob_head_i);
      for (int n = 0; n < DEPTH; n++) begin
        if (n < int'(count_q)) begin
          store_age = rob_age(rob_tag_q[scan_idx], rob_head_i);
          older_than_load = (store_age < load_age);
          if ((addr_q[scan_idx] == fwd_query_addr_i) && older_than_load) begin
            for (int b = 0; b < BYTE_W; b++) begin
              if (fwd_query_be_i[b] && be_q[scan_idx][b] && !covered_be[b]) begin
                fwd_query_data_o[(8 * b)+:8] = data_q[scan_idx][(8 * b)+:8];
                covered_be[b] = 1'b1;
              end
            end
          end
          scan_idx = ptr_dec(scan_idx);
        end
      end

      fwd_query_hit_o = ((covered_be & fwd_query_be_i) == fwd_query_be_i) &&
                        (fwd_query_be_i != '0);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rob_tag_q <= '0;
      addr_q <= '0;
      data_q <= '0;
      be_q <= '0;
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
        addr_q[tail_q] <= alloc_addr_i;
        data_q[tail_q] <= alloc_data_i;
        be_q[tail_q] <= alloc_be_i;
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
    else $fatal(1, "sq DEPTH must be > 0");
    assert (DATA_WIDTH % 8 == 0)
    else $fatal(1, "sq DATA_WIDTH must be byte-multiple");
  end

endmodule
