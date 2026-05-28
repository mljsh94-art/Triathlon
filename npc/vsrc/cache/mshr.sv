// vsrc/cache/mshr.sv
module mshr #(
    parameter int unsigned N_ENTRIES  = 2,
    parameter int unsigned KEY_WIDTH  = 32,
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned IDX_WIDTH  = (N_ENTRIES <= 1) ? 1 : $clog2(N_ENTRIES),
    parameter int unsigned CNT_WIDTH  = $clog2(N_ENTRIES + 1)
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input  logic                  alloc_valid_i,
    output logic                  alloc_ready_o,
    input  logic [ KEY_WIDTH-1:0] alloc_key_i,
    input  logic [DATA_WIDTH-1:0] alloc_data_i,
    output logic                  alloc_fire_o,
    output logic [ IDX_WIDTH-1:0] alloc_idx_o,

    input logic                  update_valid_i,
    input logic [ IDX_WIDTH-1:0] update_idx_i,
    input logic [DATA_WIDTH-1:0] update_data_i,

    input logic                  dealloc_valid_i,
    input logic [ IDX_WIDTH-1:0] dealloc_idx_i,

    output logic [N_ENTRIES-1:0]                 entry_valid_o,
    output logic [N_ENTRIES-1:0][ KEY_WIDTH-1:0] entry_key_o,
    output logic [N_ENTRIES-1:0][DATA_WIDTH-1:0] entry_data_o,
    output logic                  full_o,
    output logic                  empty_o,
    output logic [CNT_WIDTH-1:0] count_o
);

  localparam int unsigned ENTRY_COUNT = (N_ENTRIES < 1) ? 1 : N_ENTRIES;

  logic [ENTRY_COUNT-1:0] entry_valid_q;
  logic [ENTRY_COUNT-1:0][KEY_WIDTH-1:0] entry_key_q;
  logic [ENTRY_COUNT-1:0][DATA_WIDTH-1:0] entry_data_q;
  logic [ENTRY_COUNT-1:0] entry_free_w;

  always_comb begin
    for (int i = 0; i < ENTRY_COUNT; i++) begin
      entry_free_w[i] = !entry_valid_q[i] || (dealloc_valid_i && (dealloc_idx_i == IDX_WIDTH'(i)));
    end
  end

  always_comb begin
    alloc_ready_o = 1'b0;
    alloc_idx_o = '0;
    for (int i = 0; i < ENTRY_COUNT; i++) begin
      if (!alloc_ready_o && entry_free_w[i]) begin
        alloc_ready_o = 1'b1;
        alloc_idx_o = IDX_WIDTH'(i);
      end
    end
  end

  assign alloc_fire_o = alloc_valid_i && alloc_ready_o;

  always_comb begin
    empty_o = 1'b1;
    count_o = '0;
    for (int i = 0; i < ENTRY_COUNT; i++) begin
      if (entry_valid_q[i]) begin
        empty_o = 1'b0;
        count_o = count_o + CNT_WIDTH'(1);
      end
    end
    full_o = !alloc_ready_o;
  end

  assign entry_valid_o = entry_valid_q;
  assign entry_key_o = entry_key_q;
  assign entry_data_o = entry_data_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      entry_valid_q <= '0;
      entry_key_q <= '0;
      entry_data_q <= '0;
    end else if (flush_i) begin
      entry_valid_q <= '0;
      entry_key_q <= '0;
      entry_data_q <= '0;
    end else begin
      if (dealloc_valid_i) begin
        entry_valid_q[dealloc_idx_i] <= 1'b0;
      end

      if (update_valid_i) begin
        entry_data_q[update_idx_i] <= update_data_i;
      end

      if (alloc_fire_o) begin
        entry_valid_q[alloc_idx_o] <= 1'b1;
        entry_key_q[alloc_idx_o] <= alloc_key_i;
        entry_data_q[alloc_idx_o] <= alloc_data_i;
      end
    end
  end

  initial begin
    if (N_ENTRIES < 1) begin
      $error("mshr: N_ENTRIES must be >= 1, got %0d", N_ENTRIES);
    end
  end

endmodule
