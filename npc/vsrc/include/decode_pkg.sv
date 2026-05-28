package decode_pkg;
  import config_pkg::*;
  localparam int unsigned FTQ_DEPTH = (Cfg.FTQ_DEPTH >= 2) ? Cfg.FTQ_DEPTH : 2;
  localparam int unsigned FTQ_ID_W = (Cfg.FTQ_ID_W >= 1) ? Cfg.FTQ_ID_W : 1;
  localparam int unsigned FETCH_EPOCH_W = (Cfg.FETCH_EPOCH_W >= 1) ? Cfg.FETCH_EPOCH_W : 3;

  typedef enum logic [2:0] {
    FU_NONE,
    FU_ALU,
    FU_BRANCH,
    FU_LSU,
    FU_MUL,
    FU_DIV,
    FU_CSR
  } fu_e;

  typedef enum logic [4:0] {
    ALU_ADD,
    ALU_SUB,
    ALU_SLT,
    ALU_SLTU,
    ALU_XOR,
    ALU_OR,
    ALU_AND,
    ALU_SLL,
    ALU_SRL,
    ALU_SRA,
    ALU_LUI,
    ALU_AUIPC,
    ALU_NOP,
    ALU_MUL,
    ALU_MULH,
    ALU_MULHSU,
    ALU_MULHU,
    ALU_DIV,
    ALU_DIVU,
    ALU_REM,
    ALU_REMU
  } alu_op_e;

  typedef enum logic [2:0] {
    BR_EQ,
    BR_NE,
    BR_LT,
    BR_GE,
    BR_LTU,
    BR_GEU,
    BR_JAL,
    BR_JALR
  } branch_op_e;

  typedef enum logic [3:0] {
    LSU_LB,
    LSU_LH,
    LSU_LW,
    LSU_LD,
    LSU_LBU,
    LSU_LHU,
    LSU_LWU,
    LSU_SB,
    LSU_SH,
    LSU_SW,
    LSU_SD,
    LSU_LR,
    LSU_SC,
    LSU_SC_FAIL,
    LSU_AMO
  } lsu_op_e;

  typedef enum logic [3:0] {
    AMO_NONE,
    AMO_SWAP,
    AMO_ADD,
    AMO_XOR,
    AMO_AND,
    AMO_OR,
    AMO_MIN,
    AMO_MAX,
    AMO_MINU,
    AMO_MAXU
  } amo_op_e;

  typedef enum logic [2:0] {
    CSR_RW,
    CSR_RS,
    CSR_RC,
    CSR_RWI,
    CSR_RSI,
    CSR_RCI
  } csr_op_e;

  typedef struct packed {
    // 基本信息
    logic valid;
    logic illegal;

    fu_e        fu;
    alu_op_e    alu_op;
    branch_op_e br_op;
    lsu_op_e    lsu_op;
    amo_op_e    amo_op;

    // 寄存器号（逻辑）
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [4:0] rd;

    logic has_rs1;
    logic has_rs2;
    logic has_rd;

    // 立即数（按 XLEN 展开）
    logic [Cfg.XLEN-1:0] imm;

    // PC & 控制流信息
    logic [Cfg.ILEN-1:0] inst;
    logic [Cfg.ILEN-1:0] raw_inst;
    logic [Cfg.PLEN-1:0] pc;
    logic [Cfg.PLEN-1:0] pred_npc;
    logic is_rvc;
    logic [FTQ_ID_W-1:0] ftq_id;
    logic [FETCH_EPOCH_W-1:0] fetch_epoch;

    // 其它 flag（后面可以扩展）
    logic is_word_op;
    logic is_load;
    logic is_store;
    logic is_branch;
    logic is_jump;
    logic is_csr;
    logic is_fence;
    logic is_ecall;
    logic is_ebreak;
    logic is_mret;
    logic is_sret;
    logic is_wfi;
    logic is_sfence_vma;

    // CSR 相关字段
    logic [11:0] csr_addr;
    csr_op_e     csr_op;
  } uop_t;
endpackage : decode_pkg
