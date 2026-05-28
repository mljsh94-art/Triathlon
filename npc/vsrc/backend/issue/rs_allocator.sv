module rs_allocator #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter RS_DEPTH = Cfg.RS_DEPTH
) (
    input  wire  [        RS_DEPTH-1:0] rs_busy,
    input  wire  [                 3:0] instr_valid,
    output logic [        RS_DEPTH-1:0] entry_wen,
    output logic [$clog2(RS_DEPTH)-1:0] idx_map    [0:3],
    output logic                        full_stall
);

  integer i;
  logic [2:0] found_count;
  logic [2:0] needed_count;
  always_comb begin
    entry_wen   = 0;
    idx_map[0]  = 0;
    idx_map[1]  = 0;
    idx_map[2]  = 0;
    idx_map[3]  = 0;
    found_count = 0;
    full_stall  = 0;

    for (i = 0; i < RS_DEPTH; i = i + 1) begin
      if (!rs_busy[i]) begin

        case (found_count)
          0: begin
            if (instr_valid[0]) begin
              entry_wen[i] = 1'b1;
              idx_map[0]   = i;
            end
          end
          1: begin
            if (instr_valid[1]) begin
              entry_wen[i] = 1'b1;
              idx_map[1]   = i;
            end
          end
          2: begin
            if (instr_valid[2]) begin
              entry_wen[i] = 1'b1;
              idx_map[2]   = i;
            end
          end
          3: begin
            if (instr_valid[3]) begin
              entry_wen[i] = 1'b1;
              idx_map[3]   = i;
            end
          end
        endcase

        if (found_count < 4) begin
          found_count = found_count + 1;
        end
      end
    end
    needed_count = instr_valid[0] + instr_valid[1] + instr_valid[2] + instr_valid[3];
    if (found_count < needed_count || found_count == 0) begin
      full_stall = 1'b1;
      entry_wen  = 0;
    end
  end

endmodule
