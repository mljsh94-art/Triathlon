module compressed_decoder (
    input  logic [31:0] instr_i,
    output logic [31:0] instr_o,
    output logic        is_compressed_o,
    output logic        is_illegal_o
);
  localparam logic [6:0] OPCODE_OP_IMM = 7'b0010011;
  localparam logic [6:0] OPCODE_OP = 7'b0110011;
  localparam logic [6:0] OPCODE_LUI = 7'b0110111;
  localparam logic [6:0] OPCODE_JAL = 7'b1101111;
  localparam logic [6:0] OPCODE_JALR = 7'b1100111;
  localparam logic [6:0] OPCODE_BRANCH = 7'b1100011;
  localparam logic [6:0] OPCODE_LOAD = 7'b0000011;
  localparam logic [6:0] OPCODE_STORE = 7'b0100011;

  logic [15:0] c_insn;
  logic [4:0] rd;
  logic [4:0] rs1p;
  logic [4:0] rs2p;

  assign c_insn = instr_i[15:0];
  assign rd = c_insn[11:7];
  assign rs1p = {2'b01, c_insn[9:7]};
  assign rs2p = {2'b01, c_insn[4:2]};

  always_comb begin
    instr_o = instr_i;
    is_compressed_o = 1'b0;
    is_illegal_o = 1'b0;

    if (c_insn[1:0] != 2'b11) begin
      is_compressed_o = 1'b1;
      instr_o = 32'h0000_0013;

      unique case (c_insn[1:0])
        2'b00: begin
          unique case (c_insn[15:13])
            3'b000: begin  // c.addi4spn
              instr_o = {
                2'b00,
                c_insn[10:7],
                c_insn[12:11],
                c_insn[5],
                c_insn[6],
                2'b00,
                5'd2,
                3'b000,
                {2'b01, c_insn[4:2]},
                OPCODE_OP_IMM
              };
              if (c_insn[12:5] == 8'b0) begin
                is_illegal_o = 1'b1;
              end
            end
            3'b010: begin  // c.lw
              instr_o = {
                5'b0,
                c_insn[5],
                c_insn[12:10],
                c_insn[6],
                2'b00,
                rs1p,
                3'b010,
                rs2p,
                OPCODE_LOAD
              };
            end
            3'b110: begin  // c.sw
              instr_o = {
                5'b0,
                c_insn[5],
                c_insn[12],
                rs2p,
                rs1p,
                3'b010,
                c_insn[11:10],
                c_insn[6],
                2'b00,
                OPCODE_STORE
              };
            end
            default: begin
              is_illegal_o = 1'b1;
            end
          endcase
        end

        2'b01: begin
          unique case (c_insn[15:13])
            3'b000: begin  // c.addi / c.nop
              instr_o = {
                {6{c_insn[12]}},
                c_insn[12],
                c_insn[6:2],
                rd,
                3'b000,
                rd,
                OPCODE_OP_IMM
              };
            end
            3'b001: begin  // c.jal (RV32C)
              instr_o = {
                c_insn[12],
                c_insn[8],
                c_insn[10:9],
                c_insn[6],
                c_insn[7],
                c_insn[2],
                c_insn[11],
                c_insn[5:3],
                {9{c_insn[12]}},
                5'b00001,
                OPCODE_JAL
              };
            end
            3'b010: begin  // c.li
              instr_o = {
                {6{c_insn[12]}},
                c_insn[12],
                c_insn[6:2],
                5'b00000,
                3'b000,
                rd,
                OPCODE_OP_IMM
              };
            end
            3'b011: begin  // c.addi16sp / c.lui
              if (rd == 5'd2) begin
                instr_o = {
                  {3{c_insn[12]}},
                  c_insn[4:3],
                  c_insn[5],
                  c_insn[2],
                  c_insn[6],
                  4'b0000,
                  5'd2,
                  3'b000,
                  5'd2,
                  OPCODE_OP_IMM
                };
                if ({c_insn[12], c_insn[6:2]} == 6'b0) begin
                  is_illegal_o = 1'b1;
                end
              end else begin
                instr_o = {{15{c_insn[12]}}, c_insn[6:2], rd, OPCODE_LUI};
                if ((rd == 5'd0) || ({c_insn[12], c_insn[6:2]} == 6'b0)) begin
                  is_illegal_o = 1'b1;
                end
              end
            end
            3'b100: begin  // misc-alu
              unique case (c_insn[11:10])
                2'b00, 2'b01: begin  // c.srli / c.srai
                  instr_o = {
                    1'b0,
                    c_insn[10],
                    4'b0000,
                    c_insn[12],
                    c_insn[6:2],
                    rs1p,
                    3'b101,
                    rs1p,
                    OPCODE_OP_IMM
                  };
                  if (c_insn[12]) begin
                    is_illegal_o = 1'b1;
                  end
                end
                2'b10: begin  // c.andi
                  instr_o = {
                    {6{c_insn[12]}},
                    c_insn[12],
                    c_insn[6:2],
                    rs1p,
                    3'b111,
                    rs1p,
                    OPCODE_OP_IMM
                  };
                end
                2'b11: begin
                  unique case ({c_insn[12], c_insn[6:5]})
                    3'b000: begin  // c.sub
                      instr_o = {
                        2'b01,
                        5'b00000,
                        rs2p,
                        rs1p,
                        3'b000,
                        rs1p,
                        OPCODE_OP
                      };
                    end
                    3'b001: begin  // c.xor
                      instr_o = {
                        7'b0000000,
                        rs2p,
                        rs1p,
                        3'b100,
                        rs1p,
                        OPCODE_OP
                      };
                    end
                    3'b010: begin  // c.or
                      instr_o = {
                        7'b0000000,
                        rs2p,
                        rs1p,
                        3'b110,
                        rs1p,
                        OPCODE_OP
                      };
                    end
                    3'b011: begin  // c.and
                      instr_o = {
                        7'b0000000,
                        rs2p,
                        rs1p,
                        3'b111,
                        rs1p,
                        OPCODE_OP
                      };
                    end
                    default: begin
                      is_illegal_o = 1'b1;
                    end
                  endcase
                end
              endcase
            end
            3'b101: begin  // c.j
              instr_o = {
                c_insn[12],
                c_insn[8],
                c_insn[10:9],
                c_insn[6],
                c_insn[7],
                c_insn[2],
                c_insn[11],
                c_insn[5:3],
                {9{c_insn[12]}},
                5'b00000,
                OPCODE_JAL
              };
            end
            3'b110, 3'b111: begin  // c.beqz / c.bnez
              instr_o = {
                {4{c_insn[12]}},
                c_insn[6:5],
                c_insn[2],
                5'b00000,
                rs1p,
                2'b00,
                c_insn[13],
                c_insn[11:10],
                c_insn[4:3],
                c_insn[12],
                OPCODE_BRANCH
              };
            end
            default: begin
              is_illegal_o = 1'b1;
            end
          endcase
        end

        2'b10: begin
          unique case (c_insn[15:13])
            3'b000: begin  // c.slli
              instr_o = {
                6'b000000,
                c_insn[12],
                c_insn[6:2],
                rd,
                3'b001,
                rd,
                OPCODE_OP_IMM
              };
              if (c_insn[12]) begin
                is_illegal_o = 1'b1;
              end
            end
            3'b010: begin  // c.lwsp
              instr_o = {
                4'b0000,
                c_insn[3:2],
                c_insn[12],
                c_insn[6:4],
                2'b00,
                5'd2,
                3'b010,
                rd,
                OPCODE_LOAD
              };
              if (rd == 5'd0) begin
                is_illegal_o = 1'b1;
              end
            end
            3'b100: begin  // c.jr/c.mv/c.ebreak/c.jalr/c.add
              if (c_insn[12] == 1'b0) begin
                instr_o = {7'b0000000, c_insn[6:2], 5'b00000, 3'b000, rd, OPCODE_OP};
                if (c_insn[6:2] == 5'b00000) begin
                  instr_o = {12'b000000000000, rd, 3'b000, 5'b00000, OPCODE_JALR};
                  if (rd == 5'b00000) begin
                    is_illegal_o = 1'b1;
                  end
                end
              end else begin
                instr_o = {7'b0000000, c_insn[6:2], rd, 3'b000, rd, OPCODE_OP};
                if (c_insn[6:2] == 5'b00000) begin
                  if (rd == 5'b00000) begin
                    instr_o = 32'h00100073;
                  end else begin
                    instr_o = {12'b000000000000, rd, 3'b000, 5'b00001, OPCODE_JALR};
                  end
                end
              end
            end
            3'b110: begin  // c.swsp
              instr_o = {
                4'b0000,
                c_insn[8:7],
                c_insn[12],
                c_insn[6:2],
                5'd2,
                3'b010,
                c_insn[11:9],
                2'b00,
                OPCODE_STORE
              };
            end
            default: begin
              is_illegal_o = 1'b1;
            end
          endcase
        end
        default: begin
          is_illegal_o = 1'b1;
        end
      endcase

      if (is_illegal_o) begin
        instr_o = 32'h00000000;
      end
    end
  end
endmodule
