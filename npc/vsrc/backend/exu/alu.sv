// vsrc/backend/execute/alu.sv
import config_pkg::*;
import decode_pkg::*;

module execute_alu #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter TAG_W = 6,
    // [改进] 提取通用参数，避免代码中到处写 Cfg.XLEN
    parameter XLEN = Cfg.XLEN,
    parameter PC_W = Cfg.PLEN
) (
    input logic clk_i,
    input logic rst_ni,

    // 来自 Issue 阶段
    input logic                         alu_valid_i,
    input decode_pkg::uop_t             uop_i,
    input logic             [ XLEN-1:0] rs1_data_i,   // [改进] 使用参数化位宽
    input logic             [ XLEN-1:0] rs2_data_i,
    input logic             [TAG_W-1:0] rob_tag_i,

    // 写回结果端口
    output logic             alu_valid_o,
    output logic [TAG_W-1:0] alu_rob_tag_o,
    output logic [ XLEN-1:0] alu_result_o,

    // 控制流信息
    output logic            alu_is_mispred_o,
    output logic [PC_W-1:0] alu_redirect_pc_o
);

  localparam SHAMT_W = $clog2(XLEN);  // 移位量位宽 (32位为5, 64位为6)
`ifndef SYNTHESIS
  localparam int unsigned ALU_TRACE_BUDGET = 256;
  logic [31:0] alu_trace_cnt_q;
  logic alu_diag_trace_en_q;
  logic alu_legacy_trace_en_q;
  logic alu_bsearch_trace_en_q;
  initial alu_diag_trace_en_q = $test$plusargs("npc_diag_trace");
  initial alu_legacy_trace_en_q = $test$plusargs("npc_diag_alu_legacy");
  initial alu_bsearch_trace_en_q = $test$plusargs("npc_diag_bsearch");

`endif

  // --- 1. 操作数准备 ---
  logic [XLEN-1:0] op_a;
  logic [XLEN-1:0] op_b;

  // Operand A 选择
  // [注意] PC 需要扩展到 XLEN 宽度参与运算
  assign op_a = (uop_i.alu_op == ALU_AUIPC) ? XLEN'(uop_i.pc) : rs1_data_i;

  // Operand B 选择
  assign op_b = (uop_i.has_rs2) ? rs2_data_i : uop_i.imm;

  // --- 2. 算术与逻辑核心 ---
  logic [XLEN-1:0] alu_res;
  logic [31:0]     alu_res_w;
  logic [31:0]     op_a_w;
  logic [31:0]     op_b_w;
  logic signed [XLEN-1:0] op_a_s;
  logic signed [XLEN-1:0] op_b_s;
  logic [XLEN-1:0] op_a_u;
  logic [XLEN-1:0] op_b_u;
  logic signed [XLEN:0] mul_a_ss;
  logic signed [XLEN:0] mul_b_ss;
  logic signed [XLEN:0] mul_b_su;
  logic [XLEN:0] mul_a_uu;
  logic [XLEN:0] mul_b_uu;
  logic signed [2*XLEN+1:0] mul_prod_ss;
  logic signed [2*XLEN+1:0] mul_prod_su;
  logic [2*XLEN+1:0] mul_prod_uu;
  logic [XLEN-1:0] min_int;

  assign op_a_s = $signed(op_a);
  assign op_b_s = $signed(op_b);
  assign op_a_u = op_a;
  assign op_b_u = op_b;
  assign mul_a_ss = {op_a[XLEN-1], op_a};
  assign mul_b_ss = {op_b[XLEN-1], op_b};
  assign mul_b_su = $signed({1'b0, op_b});
  assign mul_a_uu = {1'b0, op_a};
  assign mul_b_uu = {1'b0, op_b};
  assign mul_prod_ss = mul_a_ss * mul_b_ss;
  assign mul_prod_su = mul_a_ss * mul_b_su;
  assign mul_prod_uu = mul_a_uu * mul_b_uu;
  assign min_int = {1'b1, {(XLEN - 1) {1'b0}}};

  always_comb begin
    alu_res = '0;
    alu_res_w = '0;
    op_a_w = op_a[31:0];
    op_b_w = op_b[31:0];

    if (uop_i.is_word_op) begin
      unique case (uop_i.alu_op)
        ALU_ADD:   alu_res_w = op_a_w + op_b_w;
        ALU_SUB:   alu_res_w = op_a_w - op_b_w;
        ALU_SLL:   alu_res_w = op_a_w << op_b_w[4:0];
        ALU_SRL:   alu_res_w = op_a_w >> op_b_w[4:0];
        ALU_SRA:   alu_res_w = $signed(op_a_w) >>> op_b_w[4:0];
        default:   alu_res_w = '0;
      endcase
      alu_res = {{(XLEN-32){alu_res_w[31]}}, alu_res_w};
    end else begin
      unique case (uop_i.alu_op)
        ALU_ADD:   alu_res = op_a + op_b;
        ALU_SUB:   alu_res = op_a - op_b;
        ALU_LUI:   alu_res = uop_i.imm;
        ALU_AUIPC: alu_res = op_a + op_b;
        ALU_AND:   alu_res = op_a & op_b;
        ALU_OR:    alu_res = op_a | op_b;
        ALU_XOR:   alu_res = op_a ^ op_b;
        // [改进] 移位操作数位宽使用 SHAMT_W 截断，避免硬编码 [4:0]
        ALU_SLL:   alu_res = op_a << op_b[SHAMT_W-1:0];
        ALU_SRL:   alu_res = op_a >> op_b[SHAMT_W-1:0];
        ALU_SRA:   alu_res = $signed(op_a) >>> op_b[SHAMT_W-1:0];
        // [改进] 比较结果使用 XLEN'(1) 适配位宽
        ALU_SLT:   alu_res = ($signed(op_a) < $signed(op_b)) ? XLEN'(1) : '0;
        ALU_SLTU:  alu_res = (op_a < op_b) ? XLEN'(1) : '0;
        ALU_MUL:   alu_res = mul_prod_uu[XLEN-1:0];
        ALU_MULH:  alu_res = mul_prod_ss[2*XLEN-1:XLEN];
        ALU_MULHSU: alu_res = mul_prod_su[2*XLEN-1:XLEN];
        ALU_MULHU: alu_res = mul_prod_uu[2*XLEN-1:XLEN];
        ALU_DIV: begin
          if (op_b_u == '0) begin
            alu_res = '1;
          end else if ((op_a_u == min_int) && (op_b_u == {XLEN{1'b1}})) begin
            alu_res = min_int;
          end else begin
            alu_res = op_a_s / op_b_s;
          end
        end
        ALU_DIVU: begin
          if (op_b_u == '0) begin
            alu_res = '1;
          end else begin
            alu_res = op_a_u / op_b_u;
          end
        end
        ALU_REM: begin
          if (op_b_u == '0) begin
            alu_res = op_a_u;
          end else if ((op_a_u == min_int) && (op_b_u == {XLEN{1'b1}})) begin
            alu_res = '0;
          end else begin
            alu_res = op_a_s % op_b_s;
          end
        end
        ALU_REMU: begin
          if (op_b_u == '0) begin
            alu_res = op_a_u;
          end else begin
            alu_res = op_a_u % op_b_u;
          end
        end
        default:   alu_res = '0;
      endcase
    end
  end

  // --- 3. 跳转与分支处理 ---
  logic [PC_W-1:0] br_target;
  logic            br_take;

  // 正确的跳转目标计算
  assign br_target = (uop_i.br_op == BR_JALR) ?
      // [改进] JALR 最低位清零使用位宽参数
      ((rs1_data_i + uop_i.imm) & ~XLEN'(1)) : (uop_i.pc + uop_i.imm);

  // 实际分支执行结果
  always_comb begin
    br_take = 1'b0;
    if (uop_i.is_branch) begin
      unique case (uop_i.br_op)
        BR_EQ: br_take = (rs1_data_i == rs2_data_i);
        BR_NE: br_take = (rs1_data_i != rs2_data_i);
        BR_LT: br_take = ($signed(rs1_data_i) < $signed(rs2_data_i));
        BR_GE: br_take = ($signed(rs1_data_i) >= $signed(rs2_data_i));
        BR_LTU: br_take = (rs1_data_i < rs2_data_i);
        BR_GEU: br_take = (rs1_data_i >= rs2_data_i);
        BR_JAL, BR_JALR: br_take = 1'b1;
        default: br_take = 1'b0;
      endcase
    end else if (uop_i.is_jump) begin
      br_take = 1'b1;
    end
  end

  // --- 4. 预测错误判断 (给 ROB) ---
  logic            control_uop;
  logic [PC_W-1:0] instr_size;
  logic [PC_W-1:0] actual_npc;

  assign control_uop = uop_i.is_branch || uop_i.is_jump;
  assign instr_size = uop_i.is_rvc ? PC_W'(2) : PC_W'(4);
  assign actual_npc = br_take ? br_target : (uop_i.pc + instr_size);

  always_comb begin
    alu_is_mispred_o  = 1'b0;
    alu_redirect_pc_o = '0;

    if (alu_valid_i && control_uop) begin
      alu_redirect_pc_o = actual_npc;
      alu_is_mispred_o  = (actual_npc != uop_i.pred_npc);
    end
  end

  // --- 5. 输出赋值 ---
  assign alu_valid_o = alu_valid_i;
  assign alu_rob_tag_o = rob_tag_i;

  // [改进] 使用 PC_W 截断和常量
  assign alu_result_o = (uop_i.is_jump)   ? XLEN'(uop_i.pc + instr_size) :
                        (uop_i.is_branch) ? '0 : alu_res;

`ifndef SYNTHESIS
  always_ff @(posedge clk_i or negedge rst_ni) begin
    logic watch_pc;
    watch_pc = 1'b0;
    if (alu_bsearch_trace_en_q) begin
      watch_pc = watch_pc ||
                 (uop_i.pc == 32'hc0399942) ||  // bsearch: mv s1,a2
                 (uop_i.pc == 32'hc039994c) ||  // bsearch: srli s3,s1,1
                 (uop_i.pc == 32'hc0399950) ||  // bsearch: mul s2,s4,s3
                 (uop_i.pc == 32'hc0399956) ||  // bsearch: addi s1,s1,-1
                 (uop_i.pc == 32'hc0399958) ||  // bsearch: add s2,s2,s5
                 (uop_i.pc == 32'hc039995a) ||  // bsearch: mv a1,s2
                 (uop_i.pc == 32'hc0399964) ||  // bsearch: srli s1,s1,1
                 (uop_i.pc == 32'hc0399986);    // bsearch: mv s1,s3
    end
    if (alu_legacy_trace_en_q) begin
      watch_pc = watch_pc ||
                 ((uop_i.pc >= 32'hc0803d80) && (uop_i.pc <= 32'hc0803dd0)) ||
                 ((uop_i.pc >= 32'hc080ab50) && (uop_i.pc <= 32'hc080ab90)) ||
                 ((uop_i.pc >= 32'hc080ab20) && (uop_i.pc <= 32'hc080ab44)) ||
                 ((uop_i.pc >= 32'hc0803b30) && (uop_i.pc <= 32'hc0803c20)) ||
                 ((uop_i.pc >= 32'hc0803d50) && (uop_i.pc <= 32'hc0803d72));
    end
    if (!rst_ni) begin
      alu_trace_cnt_q <= '0;
    end else if (alu_diag_trace_en_q && alu_valid_i && watch_pc &&
                 (alu_trace_cnt_q < ALU_TRACE_BUDGET)) begin
      $display("[alu-trace] pc=%h alu_op=%0d br_op=%0d is_word=%0d is_j=%0d is_b=%0d rs1=%h rs2=%h imm=%h op_a=%h op_b=%h res=%h pred_npc=%h mispred=%0d redir=%h rob=%0d ftq=%0d epoch=%0d rvc=%0d",
               uop_i.pc, uop_i.alu_op, uop_i.br_op, uop_i.is_word_op, uop_i.is_jump, uop_i.is_branch,
               rs1_data_i, rs2_data_i, uop_i.imm,
               op_a, op_b, alu_result_o, uop_i.pred_npc, alu_is_mispred_o, alu_redirect_pc_o,
               rob_tag_i, uop_i.ftq_id, uop_i.fetch_epoch, uop_i.is_rvc);
      alu_trace_cnt_q <= alu_trace_cnt_q + 32'd1;
    end

  end
`endif

endmodule
