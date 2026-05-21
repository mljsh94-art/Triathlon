// vsrc/backend/decode/decoder.sv
// Multi-issue decoder using CVA6-style cast (riscv_pkg)
// Currently supports RV64I + M + Zicsr (I/M/CSR extensions).
// Other extensions (A/F/D/V, etc) have reserved TODO hooks.

import global_config_pkg::*;
import config_pkg::*;
import riscv::*;
import decode_pkg::*;

module decoder #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned DECODE_WIDTH = Cfg.INSTR_PER_FETCH
) (
    input logic clk_i,
    input logic rst_ni,

    // Instruction bundle from IBuffer
    input  logic                                  ibuf2dec_valid_i,
    output logic                                  dec2ibuf_ready_o,
    input  logic [DECODE_WIDTH-1:0][Cfg.ILEN-1:0] ibuf_instrs_i,
    input  logic [DECODE_WIDTH-1:0][Cfg.PLEN-1:0] ibuf_pcs_i,
    input  logic [DECODE_WIDTH-1:0]               ibuf_slot_valid_i,
    input  logic [DECODE_WIDTH-1:0][Cfg.PLEN-1:0] ibuf_pred_npc_i,
    input  logic [DECODE_WIDTH-1:0]               ibuf_is_rvc_i,
    input logic [DECODE_WIDTH-1:0][decode_pkg::FTQ_ID_W-1:0] ibuf_ftq_id_i,
    input logic [DECODE_WIDTH-1:0][decode_pkg::FETCH_EPOCH_W-1:0] ibuf_fetch_epoch_i,

    // Decoded uops to Rename / Issue
    output logic                                dec2backend_valid_o,
    input  logic                                backend2dec_ready_i,
    output logic             [DECODE_WIDTH-1:0] dec_slot_valid_o,
    output decode_pkg::uop_t [DECODE_WIDTH-1:0] dec_uops_o
);

`ifndef SYNTHESIS
  localparam int unsigned DEC_PC_DBG_BUDGET = 1024;
  logic [31:0] dec_pc_dbg_cnt_q;
  logic dec_diag_trace_en_q;
  initial dec_diag_trace_en_q = $test$plusargs("npc_diag_trace");
`endif

  // ----------------------------------------------------------------------
  // 0. Static check (current implementation assumes 32-bit instructions)
  // ----------------------------------------------------------------------
  // synthesis translate_off
  initial begin
    if (Cfg.ILEN != 32) begin
      $fatal(1, "decoder: only ILEN=32 is supported in this implementation.");
    end
  end
  // synthesis translate_on

  // ----------------------------------------------------------------------
  // 1. Opcode constants (RV64I/RV64M subset)
  // ----------------------------------------------------------------------
  localparam logic [6:0] OPCODE_LUI = 7'b0110111;
  localparam logic [6:0] OPCODE_AUIPC = 7'b0010111;
  localparam logic [6:0] OPCODE_JAL = 7'b1101111;
  localparam logic [6:0] OPCODE_JALR = 7'b1100111;
  localparam logic [6:0] OPCODE_BRANCH = 7'b1100011;
  localparam logic [6:0] OPCODE_LOAD = 7'b0000011;
  localparam logic [6:0] OPCODE_STORE = 7'b0100011;
  localparam logic [6:0] OPCODE_OP_IMM = 7'b0010011;
  localparam logic [6:0] OPCODE_OP_IMM_32 = 7'b0011011;  // RV64I W-type imm
  localparam logic [6:0] OPCODE_OP = 7'b0110011;
  localparam logic [6:0] OPCODE_OP_32 = 7'b0111011;  // RV64I W-type
  localparam logic [6:0] OPCODE_MISC_MEM = 7'b0001111;  // FENCE, FENCE.I
  localparam logic [6:0] OPCODE_AMO = 7'b0101111;  // A extension
  localparam logic [6:0] OPCODE_SYSTEM = 7'b1110011;  // ECALL/EBREAK/MRET/CSR

  // 将来扩展时可以在这里预留更多 opcode：
  // localparam logic [6:0] OPCODE_LOAD_FP   = 7'b0000111; // F/D
  // localparam logic [6:0] OPCODE_STORE_FP  = 7'b0100111; // F/D
  // localparam logic [6:0] OPCODE_VECTOR    = 7'b1010111; // V extension
  // ...

  // ----------------------------------------------------------------------
  // 2. Handshake: decoder is purely combinational w.r.t. IBuffer
  // ----------------------------------------------------------------------
  assign dec2ibuf_ready_o = backend2dec_ready_i;
  assign dec2backend_valid_o = ibuf2dec_valid_i;

  for (genvar slot_index = 0; slot_index < DECODE_WIDTH; slot_index++) begin : gen_slot_valid
    assign dec_slot_valid_o[slot_index] = ibuf2dec_valid_i && ibuf_slot_valid_i[slot_index];
  end

  // ----------------------------------------------------------------------
  // 3. Immediate helpers (using riscv::instruction_t cast)
  // ----------------------------------------------------------------------

  // I-type immediate (sign-extended)
  function automatic logic [Cfg.XLEN-1:0] get_imm_i(input riscv::instruction_t instr_union);
    logic signed [11:0] imm12_s;
    begin
      imm12_s   = instr_union.itype.imm;  // bits [31:20]
      get_imm_i = {{(Cfg.XLEN - 12) {imm12_s[11]}}, imm12_s};
    end
  endfunction

  // S-type immediate (sign-extended)
  function automatic logic [Cfg.XLEN-1:0] get_imm_s(input riscv::instruction_t instr_union);
    logic        [11:0] imm12_u;
    logic signed [11:0] imm12_s;
    begin
      // S-type: imm[11:5] = instr[31:25], imm[4:0] = instr[11:7]
      imm12_u   = {instr_union.stype.imm, instr_union.stype.imm0};
      imm12_s   = imm12_u;
      get_imm_s = {{(Cfg.XLEN - 12) {imm12_s[11]}}, imm12_s};
    end
  endfunction

  // B-type immediate (sign-extended)
  function automatic logic [Cfg.XLEN-1:0] get_imm_b(input riscv::instruction_t instr_union);
    logic [31:0] imm32;
    begin
      // B-type: imm[12|10:5|4:1|11|0] <- {31,30:25,11:8,7,0}
      imm32 = {
        {19{instr_union.instr[31]}},
        instr_union.instr[31],
        instr_union.instr[7],
        instr_union.instr[30:25],
        instr_union.instr[11:8],
        1'b0
      };
      get_imm_b = {{(Cfg.XLEN - 32) {imm32[31]}}, imm32};
    end
  endfunction

  // U-type immediate (sign-extended when XLEN > 32)
  function automatic logic [Cfg.XLEN-1:0] get_imm_u(input riscv::instruction_t instr_union);
    logic [31:0] imm32;
    begin
      imm32 = {instr_union.utype.imm, 12'b0};
      get_imm_u = {{(Cfg.XLEN - 32) {imm32[31]}}, imm32};
    end
  endfunction

  // J-type immediate (sign-extended)
  function automatic logic [Cfg.XLEN-1:0] get_imm_j(input riscv::instruction_t instr_union);
    logic [31:0] imm32;
    begin
      // J-type: imm[20|10:1|11|19:12|0] <- {31,30:21,20,19:12,0}
      imm32 = {
        {11{instr_union.instr[31]}},
        instr_union.instr[31],
        instr_union.instr[19:12],
        instr_union.instr[20],
        instr_union.instr[30:21],
        1'b0
      };
      get_imm_j = {{(Cfg.XLEN - 32) {imm32[31]}}, imm32};
    end
  endfunction

  // ----------------------------------------------------------------------
  // 4. decode_one: decode a single 32-bit instruction into one uop_t
  // ----------------------------------------------------------------------

  function automatic decode_pkg::uop_t decode_one_instruction(input logic [Cfg.ILEN-1:0] instr_bits,
                                                              input logic [Cfg.PLEN-1:0] instr_pc);
    // Union view of instruction
    riscv::instruction_t instr_union;

    // Structured views
    riscv::rtype_t instr_rtype;
    riscv::itype_t instr_itype;
    riscv::stype_t instr_stype;
    riscv::utype_t instr_utype;
    riscv::atype_t instr_atype;

    decode_pkg::uop_t uop_decoded;

    logic [6:0] opcode_field;
    logic [2:0] funct3_field;
    logic [6:0] funct7_field;
    logic [4:0] funct5_field;

    begin
      // Bind raw bits to union and derive typed views
      instr_union.instr     = instr_bits;

      instr_rtype           = instr_union.rtype;
      instr_itype           = instr_union.itype;
      instr_stype           = instr_union.stype;
      instr_utype           = instr_union.utype;
      instr_atype           = instr_union.atype;

      opcode_field          = instr_rtype.opcode;
      funct3_field          = instr_rtype.funct3;
      funct7_field          = instr_rtype.funct7;
      funct5_field          = instr_atype.funct5;

      // Default initialization
      uop_decoded.valid     = 1'b1;
      uop_decoded.illegal   = 1'b0;

      uop_decoded.fu        = FU_ALU;  // default FU
      uop_decoded.alu_op    = ALU_NOP;
      uop_decoded.br_op     = BR_EQ;
      uop_decoded.lsu_op    = LSU_LW;

      uop_decoded.rs1       = instr_rtype.rs1;
      uop_decoded.rs2       = instr_rtype.rs2;
      uop_decoded.rd        = instr_rtype.rd;
      uop_decoded.has_rs1   = 1'b0;
      uop_decoded.has_rs2   = 1'b0;
      uop_decoded.has_rd    = 1'b0;

      uop_decoded.imm       = '0;
      uop_decoded.pc        = instr_pc;
      uop_decoded.ftq_id    = '0;
      uop_decoded.fetch_epoch = '0;
      uop_decoded.is_rvc    = 1'b0;

      uop_decoded.is_load   = 1'b0;
      uop_decoded.is_store  = 1'b0;
      uop_decoded.is_branch = 1'b0;
      uop_decoded.is_jump   = 1'b0;
      uop_decoded.is_word_op = 1'b0;
      uop_decoded.is_csr    = 1'b0;
      uop_decoded.is_fence  = 1'b0;
      uop_decoded.is_ecall  = 1'b0;
      uop_decoded.is_ebreak = 1'b0;
      uop_decoded.is_mret   = 1'b0;
      uop_decoded.is_sret   = 1'b0;
      uop_decoded.is_wfi    = 1'b0;
      uop_decoded.is_sfence_vma = 1'b0;
      uop_decoded.csr_addr  = 12'h000;
      uop_decoded.csr_op    = CSR_RW;

      // ======================================================
      //           RV64I + RV64M Decode
      // ======================================================
      unique case (opcode_field)

        // -------------------------
        // U-type: LUI / AUIPC
        // -------------------------
        OPCODE_LUI: begin
          uop_decoded.fu     = FU_ALU;
          uop_decoded.alu_op = ALU_LUI;
          uop_decoded.has_rd = (instr_rtype.rd != '0);
          uop_decoded.imm    = get_imm_u(instr_union);
        end

        OPCODE_AUIPC: begin
          uop_decoded.fu     = FU_ALU;
          uop_decoded.alu_op = ALU_AUIPC;
          uop_decoded.has_rd = (instr_rtype.rd != '0);
          uop_decoded.imm    = get_imm_u(instr_union);
        end

        // -------------------------
        // Jumps: JAL / JALR
        // -------------------------
        OPCODE_JAL: begin
          uop_decoded.fu        = FU_BRANCH;
          uop_decoded.br_op     = BR_JAL;
          uop_decoded.is_jump   = 1'b1;
          uop_decoded.is_branch = 1'b1;
          uop_decoded.has_rd    = (instr_rtype.rd != '0);
          uop_decoded.imm       = get_imm_j(instr_union);
        end

        OPCODE_JALR: begin
          uop_decoded.fu        = FU_BRANCH;
          uop_decoded.br_op     = BR_JALR;
          uop_decoded.is_jump   = 1'b1;
          uop_decoded.is_branch = 1'b1;
          uop_decoded.has_rs1   = 1'b1;
          uop_decoded.has_rd    = (instr_rtype.rd != '0);
          uop_decoded.imm       = get_imm_i(instr_union);
        end

        // -------------------------
        // Branch
        // -------------------------
        OPCODE_BRANCH: begin
          uop_decoded.fu        = FU_BRANCH;
          uop_decoded.is_branch = 1'b1;
          uop_decoded.has_rs1   = 1'b1;
          uop_decoded.has_rs2   = 1'b1;
          uop_decoded.imm       = get_imm_b(instr_union);

          unique case (funct3_field)
            3'b000:  uop_decoded.br_op = BR_EQ;  // BEQ
            3'b001:  uop_decoded.br_op = BR_NE;  // BNE
            3'b100:  uop_decoded.br_op = BR_LT;  // BLT
            3'b101:  uop_decoded.br_op = BR_GE;  // BGE
            3'b110:  uop_decoded.br_op = BR_LTU;  // BLTU
            3'b111:  uop_decoded.br_op = BR_GEU;  // BGEU
            default: uop_decoded.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // Load / Store
        // -------------------------
        OPCODE_LOAD: begin
          uop_decoded.fu      = FU_LSU;
          uop_decoded.is_load = 1'b1;
          uop_decoded.has_rs1 = 1'b1;
          uop_decoded.has_rd  = (instr_rtype.rd != '0);
          uop_decoded.imm     = get_imm_i(instr_union);

          unique case (funct3_field)
            3'b000:  uop_decoded.lsu_op = LSU_LB;
            3'b001:  uop_decoded.lsu_op = LSU_LH;
            3'b010:  uop_decoded.lsu_op = LSU_LW;
            3'b011:  uop_decoded.lsu_op = LSU_LD;
            3'b100:  uop_decoded.lsu_op = LSU_LBU;
            3'b101:  uop_decoded.lsu_op = LSU_LHU;
            3'b110:  uop_decoded.lsu_op = LSU_LWU;
            default: uop_decoded.illegal = 1'b1;
          endcase
        end

        OPCODE_STORE: begin
          uop_decoded.fu       = FU_LSU;
          uop_decoded.is_store = 1'b1;
          uop_decoded.has_rs1  = 1'b1;
          uop_decoded.has_rs2  = 1'b1;
          uop_decoded.imm      = get_imm_s(instr_union);

          unique case (funct3_field)
            3'b000:  uop_decoded.lsu_op = LSU_SB;
            3'b001:  uop_decoded.lsu_op = LSU_SH;
            3'b010:  uop_decoded.lsu_op = LSU_SW;
            3'b011:  uop_decoded.lsu_op = LSU_SD;
            default: uop_decoded.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // OP-IMM (I-type ALU)
        // -------------------------
        OPCODE_OP_IMM: begin
          uop_decoded.fu      = FU_ALU;
          uop_decoded.has_rs1 = 1'b1;
          uop_decoded.has_rd  = (instr_rtype.rd != '0);
          uop_decoded.imm     = get_imm_i(instr_union);

          unique case (funct3_field)
            3'b000: uop_decoded.alu_op = ALU_ADD;  // ADDI
            3'b010: uop_decoded.alu_op = ALU_SLT;  // SLTI
            3'b011: uop_decoded.alu_op = ALU_SLTU;  // SLTIU
            3'b100: uop_decoded.alu_op = ALU_XOR;  // XORI
            3'b110: uop_decoded.alu_op = ALU_OR;  // ORI
            3'b111: uop_decoded.alu_op = ALU_AND;  // ANDI

            3'b001: uop_decoded.alu_op = ALU_SLL;  // SLLI
            3'b101: begin  // SRLI / SRAI
              if (funct7_field[5]) uop_decoded.alu_op = ALU_SRA;
              else uop_decoded.alu_op = ALU_SRL;
            end

            default: uop_decoded.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // OP-IMM-32 (RV64I W-type)
        // -------------------------
        OPCODE_OP_IMM_32: begin
          uop_decoded.fu        = FU_ALU;
          uop_decoded.has_rs1   = 1'b1;
          uop_decoded.has_rd    = (instr_rtype.rd != '0);
          uop_decoded.imm       = get_imm_i(instr_union);
          uop_decoded.is_word_op = 1'b1;

          unique case (funct3_field)
            3'b000: uop_decoded.alu_op = ALU_ADD;  // ADDIW
            3'b001: uop_decoded.alu_op = ALU_SLL;  // SLLIW
            3'b101: begin  // SRLIW / SRAIW
              if (funct7_field[5]) uop_decoded.alu_op = ALU_SRA;
              else uop_decoded.alu_op = ALU_SRL;
            end
            default: uop_decoded.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // OP (R-type ALU + M-extension)
        // -------------------------
        OPCODE_OP: begin
          uop_decoded.fu      = FU_ALU;
          uop_decoded.has_rs1 = 1'b1;
          uop_decoded.has_rs2 = 1'b1;
          uop_decoded.has_rd  = (instr_rtype.rd != '0);

          unique case ({
            funct7_field, funct3_field
          })
            // RV64I
            {7'b0000000, 3'b000} : uop_decoded.alu_op = ALU_ADD;  // ADD
            {7'b0100000, 3'b000} : uop_decoded.alu_op = ALU_SUB;  // SUB
            {7'b0000000, 3'b010} : uop_decoded.alu_op = ALU_SLT;  // SLT
            {7'b0000000, 3'b011} : uop_decoded.alu_op = ALU_SLTU;  // SLTU
            {7'b0000000, 3'b100} : uop_decoded.alu_op = ALU_XOR;  // XOR
            {7'b0000000, 3'b110} : uop_decoded.alu_op = ALU_OR;  // OR
            {7'b0000000, 3'b111} : uop_decoded.alu_op = ALU_AND;  // AND
            {7'b0000000, 3'b001} : uop_decoded.alu_op = ALU_SLL;  // SLL
            {7'b0000000, 3'b101} : uop_decoded.alu_op = ALU_SRL;  // SRL
            {7'b0100000, 3'b101} : uop_decoded.alu_op = ALU_SRA;  // SRA

            // RV64M: M extension, mapped to dedicated FU for scheduling
            {
              7'b0000001, 3'b000
            } : begin
              uop_decoded.fu = FU_MUL;  /* MUL   */
              uop_decoded.alu_op = ALU_MUL;
            end
            {
              7'b0000001, 3'b001
            } : begin
              uop_decoded.fu = FU_MUL;  /* MULH  */
              uop_decoded.alu_op = ALU_MULH;
            end
            {
              7'b0000001, 3'b010
            } : begin
              uop_decoded.fu = FU_MUL;  /* MULHSU*/
              uop_decoded.alu_op = ALU_MULHSU;
            end
            {
              7'b0000001, 3'b011
            } : begin
              uop_decoded.fu = FU_MUL;  /* MULHU */
              uop_decoded.alu_op = ALU_MULHU;
            end
            {
              7'b0000001, 3'b100
            } : begin
              uop_decoded.fu = FU_DIV;  /* DIV   */
              uop_decoded.alu_op = ALU_DIV;
            end
            {
              7'b0000001, 3'b101
            } : begin
              uop_decoded.fu = FU_DIV;  /* DIVU  */
              uop_decoded.alu_op = ALU_DIVU;
            end
            {
              7'b0000001, 3'b110
            } : begin
              uop_decoded.fu = FU_DIV;  /* REM   */
              uop_decoded.alu_op = ALU_REM;
            end
            {
              7'b0000001, 3'b111
            } : begin
              uop_decoded.fu = FU_DIV;  /* REMU  */
              uop_decoded.alu_op = ALU_REMU;
            end

            default: uop_decoded.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // OP-32 (RV64I W-type)
        // -------------------------
        OPCODE_OP_32: begin
          uop_decoded.fu        = FU_ALU;
          uop_decoded.has_rs1   = 1'b1;
          uop_decoded.has_rs2   = 1'b1;
          uop_decoded.has_rd    = (instr_rtype.rd != '0);
          uop_decoded.is_word_op = 1'b1;

          unique case ({
            funct7_field, funct3_field
          })
            {7'b0000000, 3'b000} : uop_decoded.alu_op = ALU_ADD;  // ADDW
            {7'b0100000, 3'b000} : uop_decoded.alu_op = ALU_SUB;  // SUBW
            {7'b0000000, 3'b001} : uop_decoded.alu_op = ALU_SLL;  // SLLW
            {7'b0000000, 3'b101} : uop_decoded.alu_op = ALU_SRL;  // SRLW
            {7'b0100000, 3'b101} : uop_decoded.alu_op = ALU_SRA;  // SRAW
            default: uop_decoded.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // Atomic memory operations (A extension, RV32A word form)
        // -------------------------
        OPCODE_AMO: begin
          uop_decoded.fu      = FU_LSU;
          uop_decoded.has_rs1 = 1'b1;
          uop_decoded.has_rd  = (instr_rtype.rd != '0);

          if (funct3_field != 3'b010) begin
            uop_decoded.illegal = 1'b1;
          end else begin
            unique case (funct5_field)
              5'b00010: begin  // LR.W
                if (instr_atype.rs2 != 5'b0) begin
                  uop_decoded.illegal = 1'b1;
                end else begin
                  uop_decoded.rs2     = '0;
                  uop_decoded.has_rs2 = 1'b0;
                  uop_decoded.is_load = 1'b1;
                  uop_decoded.lsu_op  = LSU_LR;
                end
              end

              5'b00011: begin  // SC.W
                uop_decoded.has_rs2  = 1'b1;
                uop_decoded.is_store = 1'b1;
                uop_decoded.lsu_op   = LSU_SC;
              end

              // AMOSWAP/ADD/XOR/AND/OR/MIN/MAX/MINU/MAXU
              5'b00001, 5'b00000, 5'b00100, 5'b01100, 5'b01000, 5'b10000,
              5'b10100, 5'b11000, 5'b11100: begin
                uop_decoded.has_rs2  = 1'b1;
                uop_decoded.is_load  = 1'b1;
                uop_decoded.is_store = 1'b1;
                uop_decoded.lsu_op   = LSU_SW;
              end

              default: begin
                uop_decoded.illegal = 1'b1;
              end
            endcase
          end
        end

        // -------------------------
        // Fence / Fence.I
        // -------------------------
        OPCODE_MISC_MEM: begin
          uop_decoded.fu       = FU_ALU;
          uop_decoded.is_fence = 1'b1;
          // RV32I: FENCE(funct3=000), Zifencei: FENCE.I(funct3=001)
          if (!(funct3_field inside {3'b000, 3'b001})) begin
            uop_decoded.illegal = 1'b1;
          end
        end

        // -------------------------
        // SYSTEM (ECALL/EBREAK/MRET/CSR...)
        //   支持 ECALL/EBREAK/MRET + Zicsr
        // -------------------------
        OPCODE_SYSTEM: begin
          unique case (funct3_field)
            3'b000: begin
              // Privileged SYSTEM instructions are handled by CSR FU.
              uop_decoded.fu     = FU_CSR;
              uop_decoded.is_csr = 1'b0;
              uop_decoded.rs2    = '0;
              uop_decoded.has_rs2 = 1'b0;
              uop_decoded.has_rs1 = 1'b0;
              uop_decoded.has_rd  = 1'b0;
              if (instr_itype.imm == 12'h000) uop_decoded.is_ecall = 1'b1;
              else if (instr_itype.imm == 12'h001) uop_decoded.is_ebreak = 1'b1;
              else if (instr_itype.imm == 12'h302) uop_decoded.is_mret = 1'b1;
              else if (instr_itype.imm == 12'h102) uop_decoded.is_sret = 1'b1;
              else if (instr_itype.imm == 12'h105) uop_decoded.is_wfi = 1'b1;
              else if (instr_itype.imm == 12'h120) begin
                uop_decoded.is_sfence_vma = 1'b1;
                uop_decoded.has_rs1 = 1'b1;
                uop_decoded.has_rs2 = 1'b1;
                uop_decoded.rs1 = instr_rtype.rs1;
                uop_decoded.rs2 = instr_rtype.rs2;
              end
              else uop_decoded.illegal = 1'b1;
            end

            3'b001, 3'b010, 3'b011, 3'b101, 3'b110, 3'b111: begin
              uop_decoded.fu      = FU_CSR;
              uop_decoded.is_csr  = 1'b1;
              uop_decoded.csr_addr = instr_itype.imm;

              // CSR 指令不使用 rs2
              uop_decoded.rs2     = '0;
              uop_decoded.has_rs2 = 1'b0;

              unique case (funct3_field)
                3'b001: begin  // CSRRW
                  uop_decoded.csr_op  = CSR_RW;
                  uop_decoded.has_rs1 = 1'b1;
                end
                3'b010: begin  // CSRRS
                  uop_decoded.csr_op  = CSR_RS;
                  uop_decoded.has_rs1 = 1'b1;
                end
                3'b011: begin  // CSRRC
                  uop_decoded.csr_op  = CSR_RC;
                  uop_decoded.has_rs1 = 1'b1;
                end
                3'b101: begin  // CSRRWI
                  uop_decoded.csr_op  = CSR_RWI;
                  uop_decoded.has_rs1 = 1'b0;
                  uop_decoded.rs1     = '0;
                  uop_decoded.imm     = {{(Cfg.XLEN-5){1'b0}}, instr_itype.rs1};
                end
                3'b110: begin  // CSRRSI
                  uop_decoded.csr_op  = CSR_RSI;
                  uop_decoded.has_rs1 = 1'b0;
                  uop_decoded.rs1     = '0;
                  uop_decoded.imm     = {{(Cfg.XLEN-5){1'b0}}, instr_itype.rs1};
                end
                3'b111: begin  // CSRRCI
                  uop_decoded.csr_op  = CSR_RCI;
                  uop_decoded.has_rs1 = 1'b0;
                  uop_decoded.rs1     = '0;
                  uop_decoded.imm     = {{(Cfg.XLEN-5){1'b0}}, instr_itype.rs1};
                end
                default: uop_decoded.illegal = 1'b1;
              endcase

              uop_decoded.has_rd = (instr_rtype.rd != '0);
            end

            default: uop_decoded.illegal = 1'b1;
          endcase
        end

        // -------------------------
        // 未支持/预留扩展
        // -------------------------
        // 例如：A/F/D/V 等扩展可以在这里添加新分支
        // OPCODE_AMO:      ...
        // OPCODE_LOAD_FP:  ...
        // OPCODE_STORE_FP: ...
        // OPCODE_VECTOR:   ...
        // -------------------------
        default: begin
          uop_decoded.illegal = 1'b1;
        end
      endcase

      // Narrow guard: only reroute illegal uops that would otherwise enter LSU issue.
      // This prevents FU_LSU non-load/store entries from deadlocking the backend.
      if (uop_decoded.illegal && (uop_decoded.fu == FU_LSU)) begin
        uop_decoded.fu      = FU_CSR;
        uop_decoded.alu_op  = ALU_NOP;
        uop_decoded.is_load = 1'b0;
        uop_decoded.is_store = 1'b0;
        uop_decoded.is_branch = 1'b0;
        uop_decoded.is_jump   = 1'b0;
        uop_decoded.is_fence  = 1'b0;
        uop_decoded.is_word_op = 1'b0;
        uop_decoded.is_csr   = 1'b0;
        uop_decoded.is_ecall = 1'b0;
        uop_decoded.is_ebreak = 1'b0;
        uop_decoded.is_mret  = 1'b0;
        uop_decoded.is_sret  = 1'b0;
        uop_decoded.is_wfi   = 1'b0;
        uop_decoded.is_sfence_vma = 1'b0;
        uop_decoded.has_rs1  = 1'b0;
        uop_decoded.has_rs2  = 1'b0;
        uop_decoded.has_rd   = 1'b0;
        uop_decoded.rs1      = '0;
        uop_decoded.rs2      = '0;
        uop_decoded.rd       = '0;
        uop_decoded.imm      = '0;
        uop_decoded.csr_addr = 12'h000;
        uop_decoded.csr_op   = CSR_RW;
      end

      decode_one_instruction = uop_decoded;
    end
  endfunction

  // ----------------------------------------------------------------------
  // 5. Multi-issue decode: 每个 lane 独立 decode
  // ----------------------------------------------------------------------
  for (genvar lane_index = 0; lane_index < DECODE_WIDTH; lane_index++) begin : gen_decode_lane
    always_comb begin
      decode_pkg::uop_t lane_uop;
      lane_uop = decode_one_instruction(ibuf_instrs_i[lane_index], ibuf_pcs_i[lane_index]);
      lane_uop.valid = ibuf2dec_valid_i && ibuf_slot_valid_i[lane_index];
      lane_uop.pred_npc = ibuf_pred_npc_i[lane_index];
      lane_uop.is_rvc = ibuf_is_rvc_i[lane_index];
      lane_uop.ftq_id = ibuf_ftq_id_i[lane_index];
      lane_uop.fetch_epoch = ibuf_fetch_epoch_i[lane_index];
      dec_uops_o[lane_index] = lane_uop;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dec_pc_dbg_cnt_q <= '0;
    end else if (dec_diag_trace_en_q && ibuf2dec_valid_i && backend2dec_ready_i) begin
      logic [31:0] dec_pc_dbg_cnt_n;
      dec_pc_dbg_cnt_n = dec_pc_dbg_cnt_q;
      for (int i = 0; i < DECODE_WIDTH; i++) begin
        logic watch_pc;
        watch_pc = ibuf_slot_valid_i[i] &&
                   (((ibuf_pcs_i[i] >= 32'hc0803b30) && (ibuf_pcs_i[i] <= 32'hc0803c20)) ||
                    ((ibuf_pcs_i[i] >= 32'hc0803d50) && (ibuf_pcs_i[i] <= 32'hc0803d72)) ||
                    ((ibuf_pcs_i[i] >= 32'hc0803d80) && (ibuf_pcs_i[i] <= 32'hc0803dd0)) ||
                    ((ibuf_pcs_i[i] >= 32'hc080ab50) && (ibuf_pcs_i[i] <= 32'hc080ab90)) ||
                    ((ibuf_pcs_i[i] >= 32'hc07872b0) && (ibuf_pcs_i[i] <= 32'hc07873f0)) ||
                    ((ibuf_pcs_i[i] >= 32'hc0097640) && (ibuf_pcs_i[i] <= 32'hc0097670)));
        if (watch_pc && (dec_pc_dbg_cnt_n < DEC_PC_DBG_BUDGET)) begin
          $display("[dec-pc] pc=%h instr=%h lo16=%h is_rvc=%0d pred_npc=%h slot=%0d ftq=%0d epoch=%0d",
                   ibuf_pcs_i[i], ibuf_instrs_i[i], ibuf_instrs_i[i][15:0], ibuf_is_rvc_i[i],
                   ibuf_pred_npc_i[i], i, ibuf_ftq_id_i[i], ibuf_fetch_epoch_i[i]);
          dec_pc_dbg_cnt_n = dec_pc_dbg_cnt_n + 32'd1;
        end
      end
      dec_pc_dbg_cnt_q <= dec_pc_dbg_cnt_n;
    end
  end
`endif

endmodule
