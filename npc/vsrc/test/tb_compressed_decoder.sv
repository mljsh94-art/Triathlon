module tb_compressed_decoder (
    input  logic [31:0] instr_i,
    output logic [31:0] instr_o,
    output logic        is_compressed_o,
    output logic        is_illegal_o
);

  compressed_decoder dut (
      .instr_i(instr_i),
      .instr_o(instr_o),
      .is_compressed_o(is_compressed_o),
      .is_illegal_o(is_illegal_o)
  );

endmodule
