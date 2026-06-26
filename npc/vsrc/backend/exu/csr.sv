// vsrc/backend/execute/csr.sv
import config_pkg::*;
import decode_pkg::*;

module execute_csr #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter TAG_W = 6,
    parameter XLEN = Cfg.XLEN
) (
    input logic clk_i,
    input logic rst_ni,

    input logic             csr_valid_i,
    input decode_pkg::uop_t uop_i,
    input logic [XLEN-1:0]  rs1_data_i,
    input logic [TAG_W-1:0] rob_tag_i,
    input logic             interrupt_inject_i,
    input logic             async_exception_inject_i,
    input logic [4:0]       async_exception_cause_i,
    input logic [Cfg.PLEN-1:0] async_exception_tval_i,
    input logic             timer_irq_i,
    input logic             external_irq_i,
    input logic [Cfg.PLEN-1:0] trap_pc_i,

    output logic             csr_valid_o,
    output logic [TAG_W-1:0] csr_rob_tag_o,
    output logic [XLEN-1:0]  csr_result_o,
    output logic             csr_exception_o,
    output logic [4:0]       csr_ecause_o,
    output logic             csr_is_mispred_o,
    output logic [Cfg.PLEN-1:0] csr_redirect_pc_o,
    output logic             irq_trap_o,
    output logic [4:0]       irq_trap_cause_o,
    output logic [Cfg.PLEN-1:0] irq_trap_pc_o,
    output logic [Cfg.PLEN-1:0] irq_trap_redirect_pc_o,
    output logic [XLEN-1:0]  satp_o,
    output logic [1:0]       priv_mode_o,
    output logic             mstatus_sum_o,
    output logic             mstatus_mxr_o,
    output logic             sfence_vma_flush_o
);

  localparam logic [4:0] EXC_ILLEGAL_INSTR = 5'd2;
  localparam logic [4:0] EXC_BREAKPOINT = 5'd3;
  localparam logic [4:0] EXC_LD_ADDR_MISALIGNED = 5'd4;
  localparam logic [4:0] EXC_ST_ADDR_MISALIGNED = 5'd6;
  localparam logic [4:0] EXC_ECALL_UMODE = 5'd8;
  localparam logic [4:0] EXC_ECALL_SMODE = 5'd9;
  localparam logic [4:0] EXC_ECALL_MMODE = 5'd11;
  localparam logic [4:0] EXC_S_EXT = 5'd9;
  localparam logic [4:0] EXC_M_EXT = 5'd11;
  localparam logic [4:0] EXC_M_TIMER = 5'd7;

  localparam logic [1:0] PRIV_LVL_M = 2'b11;
  localparam logic [1:0] PRIV_LVL_S = 2'b01;
  localparam logic [1:0] PRIV_LVL_U = 2'b00;

  localparam logic [11:0] CSR_SSTATUS = 12'h100;
  localparam logic [11:0] CSR_SCOUNTEREN = 12'h106;
  localparam logic [11:0] CSR_SIE = 12'h104;
  localparam logic [11:0] CSR_STVEC = 12'h105;
  localparam logic [11:0] CSR_SSCRATCH = 12'h140;
  localparam logic [11:0] CSR_MSTATUS = 12'h300;
  localparam logic [11:0] CSR_MISA = 12'h301;
  localparam logic [11:0] CSR_MSTATUSH = 12'h310;
  localparam logic [11:0] CSR_MEDELEG = 12'h302;
  localparam logic [11:0] CSR_MIDELEG = 12'h303;
  localparam logic [11:0] CSR_MCOUNTEREN = 12'h306;
  localparam logic [11:0] CSR_MENVCFG = 12'h30A;
  localparam logic [11:0] CSR_MENVCFGH = 12'h31A;
  localparam logic [11:0] CSR_MIE = 12'h304;
  localparam logic [11:0] CSR_MTVEC = 12'h305;
  localparam logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
  localparam logic [11:0] CSR_MCYCLE = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET = 12'hB02;
  localparam logic [11:0] CSR_MCYCLEH = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH = 12'hB82;
  localparam logic [11:0] CSR_CYCLE = 12'hC00;
  localparam logic [11:0] CSR_TIME = 12'hC01;
  localparam logic [11:0] CSR_INSTRET = 12'hC02;
  localparam logic [11:0] CSR_CYCLEH = 12'hC80;
  localparam logic [11:0] CSR_TIMEH = 12'hC81;
  localparam logic [11:0] CSR_INSTRETH = 12'hC82;
  localparam logic [11:0] CSR_SEPC = 12'h141;
  localparam logic [11:0] CSR_SCAUSE = 12'h142;
  localparam logic [11:0] CSR_STVAL = 12'h143;
  localparam logic [11:0] CSR_SIP = 12'h144;
  localparam logic [11:0] CSR_MSCRATCH = 12'h340;
  localparam logic [11:0] CSR_MEPC = 12'h341;
  localparam logic [11:0] CSR_MCAUSE = 12'h342;
  localparam logic [11:0] CSR_MTVAL = 12'h343;
  localparam logic [11:0] CSR_MIP = 12'h344;
  localparam logic [11:0] CSR_MVENDORID = 12'hF11;
  localparam logic [11:0] CSR_MARCHID = 12'hF12;
  localparam logic [11:0] CSR_MIMPID = 12'hF13;
  localparam logic [11:0] CSR_MHARTID = 12'hF14;
  localparam logic [11:0] CSR_SATP = 12'h180;
  localparam logic [11:0] CSR_SEED = 12'h015;
  localparam logic [11:0] CSR_TSELECT = 12'h7A0;
  localparam logic [11:0] CSR_MCONFIGPTR = 12'hFB0;

  localparam int unsigned MSTATUS_SIE_BIT = 1;
  localparam int unsigned MSTATUS_MIE_BIT = 3;
  localparam int unsigned MSTATUS_SPIE_BIT = 5;
  localparam int unsigned MSTATUS_MPIE_BIT = 7;
  localparam int unsigned MSTATUS_SPP_BIT = 8;
  localparam int unsigned MSTATUS_MPP_LSB = 11;
  localparam int unsigned MSTATUS_MPP_MSB = 12;
  localparam int unsigned MSTATUS_SUM_BIT = 18;
  localparam int unsigned MSTATUS_MXR_BIT = 19;
  localparam int unsigned MIE_SEIE_BIT = 9;
  localparam int unsigned MIE_MEIE_BIT = 11;
  localparam int unsigned MIE_MTIE_BIT = 7;
  localparam int unsigned MIP_SEIP_BIT = 9;
  localparam int unsigned MIP_MEIP_BIT = 11;
  localparam int unsigned MIP_MTIP_BIT = 7;
  localparam logic [XLEN-1:0] CSR_MISA_VALUE = XLEN'(32'h40141105);
  localparam logic [XLEN-1:0] MSTATUS_SUPPORTED_MASK =
      (XLEN'(1) << MSTATUS_SIE_BIT) |
      (XLEN'(1) << MSTATUS_MIE_BIT) |
      (XLEN'(1) << MSTATUS_SPIE_BIT) |
      (XLEN'(1) << MSTATUS_MPIE_BIT) |
      (XLEN'(1) << MSTATUS_SPP_BIT) |
      (XLEN'(3) << MSTATUS_MPP_LSB) |
      (XLEN'(1) << MSTATUS_SUM_BIT) |
      (XLEN'(1) << MSTATUS_MXR_BIT);
  localparam logic [XLEN-1:0] MEDELEG_SUPPORTED_MASK = XLEN'(32'h0000_B109);
  localparam logic [XLEN-1:0] MIDELEG_SUPPORTED_MASK =
      (XLEN'(1) << 1) |   // SSIP
      (XLEN'(1) << 5) |   // STIP
      (XLEN'(1) << MIP_SEIP_BIT);
  localparam logic [XLEN-1:0] SATP_MODE_MASK = XLEN'(32'h8000_0000);
  localparam logic [XLEN-1:0] SATP_PPN_MASK = XLEN'(32'h003f_ffff);
  localparam logic [XLEN-1:0] SATP_SUPPORTED_MASK = SATP_MODE_MASK | SATP_PPN_MASK;

  logic [XLEN-1:0] csr_scounteren;
  logic [XLEN-1:0] csr_stvec;
  logic [XLEN-1:0] csr_sscratch;
  logic [XLEN-1:0] csr_sepc;
  logic [XLEN-1:0] csr_scause;
  logic [XLEN-1:0] csr_stval;
  logic [XLEN-1:0] csr_sip;
  logic [XLEN-1:0] csr_mscratch;
  logic [XLEN-1:0] csr_mstatus;
  logic [XLEN-1:0] csr_mstatush;
  logic [XLEN-1:0] csr_medeleg;
  logic [XLEN-1:0] csr_mideleg;
  logic [XLEN-1:0] csr_mcounteren;
  logic [XLEN-1:0] csr_mcountinhibit;
  logic [XLEN-1:0] csr_mie;
  logic [XLEN-1:0] csr_mtvec;
  logic [XLEN-1:0] csr_mepc;
  logic [XLEN-1:0] csr_mcause;
  logic [XLEN-1:0] csr_mtval;
  logic [XLEN-1:0] csr_satp;
  logic [63:0] cycle_counter_q;
  logic [63:0] instret_counter_q;
  logic [1:0] current_priv;

  logic [XLEN-1:0] csr_mip;
  logic [XLEN-1:0] csr_sie_view;
  logic [XLEN-1:0] csr_sip_view;
  logic [XLEN-1:0] csr_sstatus_view;
  logic [XLEN-1:0] csr_sstatus_mask;
  logic [XLEN-1:0] csr_read_val;
  logic [XLEN-1:0] csr_write_val;
  logic [XLEN-1:0] csr_src;
  logic [XLEN-1:0] mstatus_trap_next;
  logic [XLEN-1:0] mstatus_s_trap_next;
  logic [XLEN-1:0] mstatus_mret_next;
  logic [XLEN-1:0] mstatus_sret_next;
  logic csr_write_en;
  logic csr_write_req;
  logic csr_addr_known;
  logic csr_priv_valid;
  logic csr_addr_valid;
  logic sys_op_valid;
  logic sys_exception;
  logic [4:0] sys_ecause;
  logic sys_is_mispred;
  logic [Cfg.PLEN-1:0] sys_redirect_pc;
  logic [1:0] mret_target_priv;
  logic [1:0] sret_target_priv;
  logic csr_illegal_exception;
  logic decode_illegal_exception;
  logic interrupt_pending;
  logic interrupt_ext_pending;
  logic interrupt_s_ext_pending;
  logic interrupt_m_ext_pending;
  logic interrupt_timer_pending;
  logic interrupt_take;
  logic [4:0] interrupt_cause;
  logic async_exception_take;
  logic system_take_exception;
  logic trap_take;
  logic trap_to_s_mode;
  logic [4:0] trap_ecause;
  logic [XLEN-1:0] trap_mcause;
  logic [XLEN-1:0] trap_scause;
  logic [Cfg.PLEN-1:0] trap_tval;
  logic [Cfg.PLEN-1:0] trap_pc;
  logic [Cfg.PLEN-1:0] trap_redirect_pc;
  logic trap_delegate_to_s;
  logic [1:0] trap_record_priv;
  logic regular_valid;
  logic satp_write_flush;

  function automatic logic csr_probe_read_as_zero(input logic [11:0] addr);
    begin
      csr_probe_read_as_zero = 1'b0;
      if ((addr >= 12'hB00 && addr <= 12'hB1F) ||
          (addr >= 12'hB80 && addr <= 12'hB9F) ||
          (addr >= 12'hC00 && addr <= 12'hC1F) ||
          (addr >= 12'hC80 && addr <= 12'hC9F) ||
          (addr >= 12'h3A0 && addr <= 12'h3AF) ||
          (addr >= 12'h3B0 && addr <= 12'h3EF)) begin
        csr_probe_read_as_zero = 1'b1;
      end else if (addr == CSR_TSELECT ||
                   addr == CSR_MCONFIGPTR || addr == CSR_MENVCFG) begin
        csr_probe_read_as_zero = 1'b1;
      end
    end
  endfunction

  function automatic logic [XLEN-1:0] sanitize_satp(input logic [XLEN-1:0] value);
    begin
      // Current SV32 MMU/TLB does not tag entries by ASID, so expose ASIDLEN=0.
      sanitize_satp = value & SATP_SUPPORTED_MASK;
    end
  endfunction

  function automatic logic [XLEN-1:0] sanitize_mstatus(input logic [XLEN-1:0] value);
    begin
      sanitize_mstatus = value & MSTATUS_SUPPORTED_MASK;
    end
  endfunction

  function automatic logic [XLEN-1:0] sanitize_medeleg(input logic [XLEN-1:0] value);
    begin
      sanitize_medeleg = value & MEDELEG_SUPPORTED_MASK;
    end
  endfunction

  function automatic logic [XLEN-1:0] sanitize_mideleg(input logic [XLEN-1:0] value);
    begin
      sanitize_mideleg = value & MIDELEG_SUPPORTED_MASK;
    end
  endfunction

  always_comb begin
    csr_mip = '0;
    csr_mip[MIP_SEIP_BIT] = external_irq_i;
    csr_mip[MIP_MEIP_BIT] = external_irq_i && !csr_mideleg[MIP_SEIP_BIT];
    csr_mip[MIP_MTIP_BIT] = timer_irq_i;
  end

  always_comb begin
    csr_sip_view = csr_sip;
    csr_sip_view[MIP_SEIP_BIT] = external_irq_i;
  end

  always_comb begin
    csr_sstatus_mask = '0;
    csr_sstatus_mask[MSTATUS_SIE_BIT] = 1'b1;
    csr_sstatus_mask[MSTATUS_SPIE_BIT] = 1'b1;
    csr_sstatus_mask[MSTATUS_SPP_BIT] = 1'b1;
    csr_sstatus_mask[MSTATUS_SUM_BIT] = 1'b1;
    csr_sstatus_mask[MSTATUS_MXR_BIT] = 1'b1;
  end

  assign csr_sstatus_view = csr_mstatus & csr_sstatus_mask;
  assign csr_sie_view = csr_mie & csr_mideleg;
  assign csr_priv_valid = (current_priv >= uop_i.csr_addr[9:8]);

  // CSR read mux
  always_comb begin
    csr_addr_known = 1'b1;
    unique case (uop_i.csr_addr)
      CSR_SSTATUS: csr_read_val = csr_sstatus_view;
      CSR_SCOUNTEREN: csr_read_val = csr_scounteren;
      CSR_SIE: csr_read_val = csr_sie_view;
      CSR_STVEC: csr_read_val = csr_stvec;
      CSR_SSCRATCH: csr_read_val = csr_sscratch;
      CSR_MSTATUS: csr_read_val = csr_mstatus;
      CSR_MISA: csr_read_val = CSR_MISA_VALUE;
      CSR_MSTATUSH: csr_read_val = csr_mstatush;
      CSR_MEDELEG: csr_read_val = csr_medeleg;
      CSR_MIDELEG: csr_read_val = csr_mideleg;
      CSR_MCOUNTEREN: csr_read_val = csr_mcounteren;
      CSR_MENVCFG: csr_read_val = '0;
      CSR_MENVCFGH: csr_read_val = '0;
      CSR_MIE: csr_read_val = csr_mie;
      CSR_MTVEC: csr_read_val = csr_mtvec;
      CSR_MCOUNTINHIBIT: csr_read_val = csr_mcountinhibit;
      CSR_MCYCLE, CSR_CYCLE, CSR_TIME: csr_read_val = cycle_counter_q[31:0];
      CSR_MINSTRET, CSR_INSTRET: csr_read_val = instret_counter_q[31:0];
      CSR_MCYCLEH, CSR_CYCLEH, CSR_TIMEH: csr_read_val = cycle_counter_q[63:32];
      CSR_MINSTRETH, CSR_INSTRETH: csr_read_val = instret_counter_q[63:32];
      CSR_SEPC: csr_read_val = csr_sepc;
      CSR_SCAUSE: csr_read_val = csr_scause;
      CSR_STVAL: csr_read_val = csr_stval;
      CSR_SIP: csr_read_val = csr_sip_view;
      CSR_MSCRATCH: csr_read_val = csr_mscratch;
      CSR_MEPC: csr_read_val = csr_mepc;
      CSR_MCAUSE: csr_read_val = csr_mcause;
      CSR_MTVAL: csr_read_val = csr_mtval;
      CSR_MIP: csr_read_val = csr_mip;
      CSR_MVENDORID: csr_read_val = '0;
      CSR_MARCHID: csr_read_val = '0;
      CSR_MIMPID: csr_read_val = '0;
      CSR_MHARTID: csr_read_val = '0;
      CSR_SATP: csr_read_val = csr_satp;
      default: begin
        if (csr_probe_read_as_zero(uop_i.csr_addr)) begin
          csr_addr_known = 1'b1;
          csr_read_val = '0;
        end else begin
          csr_addr_known = 1'b0;
          csr_read_val = '0;
        end
      end
    endcase
  end

  assign csr_addr_valid = csr_addr_known && csr_priv_valid;

  // CSR source value
  always_comb begin
    unique case (uop_i.csr_op)
      CSR_RWI, CSR_RSI, CSR_RCI: csr_src = uop_i.imm;
      default: csr_src = rs1_data_i;
    endcase
  end

  // CSR write semantics
  always_comb begin
    csr_write_req = 1'b0;
    csr_write_en = 1'b0;
    csr_write_val = csr_read_val;

    unique case (uop_i.csr_op)
      CSR_RW, CSR_RWI: begin
        csr_write_req = 1'b1;
        csr_write_val = csr_src;
      end
      CSR_RS, CSR_RSI: begin
        csr_write_req = 1'b1;
        csr_write_val = csr_read_val | csr_src;
      end
      CSR_RC, CSR_RCI: begin
        csr_write_req = 1'b1;
        csr_write_val = csr_read_val & ~csr_src;
      end
      default: begin
        csr_write_req = 1'b0;
        csr_write_val = csr_read_val;
      end
    endcase

    // RISC-V rule: CSRRS/CSRRC only write when rs1 != x0,
    // CSRRSI/CSRRCI only write when zimm != 0
    unique case (uop_i.csr_op)
      CSR_RS, CSR_RC: begin
        csr_write_en = csr_write_req && (uop_i.rs1 != 0);
      end
      CSR_RSI, CSR_RCI: begin
        csr_write_en = csr_write_req && (uop_i.imm[4:0] != 0);
      end
      CSR_RW, CSR_RWI: begin
        csr_write_en = csr_write_req;
      end
      default: csr_write_en = 1'b0;
    endcase

    csr_write_en = csr_write_en && csr_addr_valid;
  end

  always_comb begin
    sys_op_valid = uop_i.is_ecall | uop_i.is_ebreak | uop_i.is_mret | uop_i.is_sret |
                   uop_i.is_wfi | uop_i.is_sfence_vma;
    sys_exception = 1'b0;
    sys_ecause = '0;
    sys_is_mispred = 1'b0;
    sys_redirect_pc = '0;
    mret_target_priv = csr_mstatus[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB];
    sret_target_priv = csr_mstatus[MSTATUS_SPP_BIT] ? PRIV_LVL_S : PRIV_LVL_U;

    if (uop_i.is_ecall) begin
      sys_exception = 1'b1;
      unique case (current_priv)
        PRIV_LVL_M: sys_ecause = EXC_ECALL_MMODE;
        PRIV_LVL_S: sys_ecause = EXC_ECALL_SMODE;
        default: sys_ecause = EXC_ECALL_UMODE;
      endcase
    end else if (uop_i.is_ebreak) begin
      sys_exception = 1'b1;
      sys_ecause = EXC_BREAKPOINT;
    end else if (uop_i.is_mret) begin
      if (current_priv == PRIV_LVL_M) begin
        sys_is_mispred = 1'b1;
        sys_redirect_pc = csr_mepc[Cfg.PLEN-1:0];
      end else begin
        sys_exception = 1'b1;
        sys_ecause = EXC_ILLEGAL_INSTR;
      end
    end else if (uop_i.is_sret) begin
      if (current_priv == PRIV_LVL_S) begin
        sys_is_mispred = 1'b1;
        sys_redirect_pc = csr_sepc[Cfg.PLEN-1:0];
      end else begin
        sys_exception = 1'b1;
        sys_ecause = EXC_ILLEGAL_INSTR;
      end
    end else if (uop_i.is_wfi) begin
      // Treat WFI as a nop-like retire point in current model.
      sys_redirect_pc = '0;
    end else if (uop_i.is_sfence_vma) begin
      if (current_priv == PRIV_LVL_U) begin
        sys_exception = 1'b1;
        sys_ecause = EXC_ILLEGAL_INSTR;
      end
    end
  end

  assign interrupt_s_ext_pending = external_irq_i && csr_mideleg[MIP_SEIP_BIT] &&
                                   csr_mie[MIE_SEIE_BIT] &&
                                   ((current_priv == PRIV_LVL_U) ||
                                    (current_priv == PRIV_LVL_S && csr_mstatus[MSTATUS_SIE_BIT]));
  assign interrupt_m_ext_pending = external_irq_i && !csr_mideleg[MIP_SEIP_BIT] &&
                                   csr_mstatus[MSTATUS_MIE_BIT] &&
                                   csr_mie[MIE_MEIE_BIT];
  assign interrupt_ext_pending = interrupt_s_ext_pending || interrupt_m_ext_pending;
  assign interrupt_timer_pending = timer_irq_i && csr_mstatus[MSTATUS_MIE_BIT] &&
                                   csr_mie[MIE_MTIE_BIT];
  assign interrupt_pending = interrupt_ext_pending || interrupt_timer_pending;
  assign interrupt_cause = interrupt_s_ext_pending ? EXC_S_EXT :
                           (interrupt_m_ext_pending ? EXC_M_EXT : EXC_M_TIMER);
  assign interrupt_take = csr_valid_i && interrupt_inject_i && interrupt_pending;
  assign async_exception_take = csr_valid_i && async_exception_inject_i;
  assign decode_illegal_exception = csr_valid_i && uop_i.illegal;
  assign csr_illegal_exception = csr_valid_i && uop_i.is_csr && !csr_addr_valid;
  assign system_take_exception = csr_valid_i && sys_op_valid && sys_exception;
  assign trap_take = decode_illegal_exception || csr_illegal_exception ||
                     system_take_exception || interrupt_take ||
                     async_exception_take;
  assign trap_delegate_to_s = csr_medeleg[trap_ecause] ||
                              (trap_ecause == EXC_LD_ADDR_MISALIGNED) ||
                              (trap_ecause == EXC_ST_ADDR_MISALIGNED);
  assign trap_to_s_mode = interrupt_s_ext_pending ||
                          ((current_priv != PRIV_LVL_M) &&
                           (decode_illegal_exception || csr_illegal_exception ||
                            system_take_exception ||
                            async_exception_take) &&
                           trap_delegate_to_s);
  assign satp_write_flush = csr_valid_i && uop_i.is_csr && csr_write_en &&
                            (uop_i.csr_addr == CSR_SATP) && !trap_take;

  always_comb begin
    trap_ecause = '0;
    trap_mcause = '0;
    trap_scause = '0;
    trap_tval = '0;
    trap_pc = trap_pc_i;
    trap_redirect_pc = csr_mtvec[Cfg.PLEN-1:0];

    if (decode_illegal_exception || csr_illegal_exception) begin
      trap_ecause = EXC_ILLEGAL_INSTR;
      trap_mcause = XLEN'(EXC_ILLEGAL_INSTR);
      trap_scause = XLEN'(EXC_ILLEGAL_INSTR);
      trap_pc = uop_i.pc;
    end else if (interrupt_take) begin
      trap_ecause = interrupt_cause;
      trap_mcause = XLEN'((32'h1 << (XLEN - 1)) | interrupt_cause);
      trap_scause = XLEN'((32'h1 << (XLEN - 1)) | interrupt_cause);
      trap_pc = trap_pc_i;
    end else if (async_exception_take) begin
      trap_ecause = async_exception_cause_i;
      trap_mcause = XLEN'(async_exception_cause_i);
      trap_scause = XLEN'(async_exception_cause_i);
      trap_tval = async_exception_tval_i;
      trap_pc = trap_pc_i;
    end else if (system_take_exception) begin
      trap_ecause = sys_ecause;
      trap_mcause = XLEN'(sys_ecause);
      trap_scause = XLEN'(sys_ecause);
      trap_pc = uop_i.pc;
    end

    if (trap_to_s_mode) begin
      trap_redirect_pc = csr_stvec[Cfg.PLEN-1:0];
    end
  end

  always_comb begin
    trap_record_priv = current_priv;
    if (trap_take && uop_i.is_ecall) begin
      unique case (trap_ecause)
        EXC_ECALL_MMODE: trap_record_priv = PRIV_LVL_M;
        EXC_ECALL_SMODE: trap_record_priv = PRIV_LVL_S;
        default: trap_record_priv = PRIV_LVL_U;
      endcase
    end

    mstatus_trap_next = csr_mstatus;
    mstatus_trap_next[MSTATUS_MPIE_BIT] = csr_mstatus[MSTATUS_MIE_BIT];
    mstatus_trap_next[MSTATUS_MIE_BIT] = 1'b0;
    mstatus_trap_next[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] = trap_record_priv;

    mstatus_s_trap_next = csr_mstatus;
    mstatus_s_trap_next[MSTATUS_SPIE_BIT] = csr_mstatus[MSTATUS_SIE_BIT];
    mstatus_s_trap_next[MSTATUS_SIE_BIT] = 1'b0;
    mstatus_s_trap_next[MSTATUS_SPP_BIT] = (current_priv == PRIV_LVL_S);

    mstatus_mret_next = csr_mstatus;
    mstatus_mret_next[MSTATUS_MIE_BIT] = csr_mstatus[MSTATUS_MPIE_BIT];
    mstatus_mret_next[MSTATUS_MPIE_BIT] = 1'b1;
    mstatus_mret_next[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] = PRIV_LVL_U;

    mstatus_sret_next = csr_mstatus;
    mstatus_sret_next[MSTATUS_SIE_BIT] = csr_mstatus[MSTATUS_SPIE_BIT];
    mstatus_sret_next[MSTATUS_SPIE_BIT] = 1'b1;
    mstatus_sret_next[MSTATUS_SPP_BIT] = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      csr_scounteren <= '0;
      csr_stvec <= '0;
      csr_sscratch <= '0;
      csr_sepc <= '0;
      csr_scause <= '0;
      csr_stval <= '0;
      csr_sip <= '0;
      csr_mscratch <= '0;
      csr_mstatus <= XLEN'(32'h1800);
      csr_mstatush <= '0;
      csr_medeleg <= '0;
      csr_mideleg <= '0;
      csr_mcounteren <= '0;
      csr_mcountinhibit <= '0;
      csr_mie <= '0;
      csr_mtvec <= '0;
      csr_mepc <= '0;
      csr_mcause <= '0;
      csr_mtval <= '0;
      csr_satp <= '0;
      cycle_counter_q <= '0;
      instret_counter_q <= '0;
      current_priv <= PRIV_LVL_M;
    end else begin
      cycle_counter_q <= cycle_counter_q + 64'd1;
      if (csr_valid_i) begin
        instret_counter_q <= instret_counter_q + 64'd1;
      end

      if (csr_valid_i && uop_i.is_csr && csr_write_en) begin
        unique case (uop_i.csr_addr)
          CSR_SSTATUS: csr_mstatus <= sanitize_mstatus((csr_mstatus & ~csr_sstatus_mask) |
                                                       (csr_write_val & csr_sstatus_mask));
          CSR_SCOUNTEREN: csr_scounteren <= csr_write_val;
          CSR_SIE: csr_mie <= (csr_mie & ~csr_mideleg) | (csr_write_val & csr_mideleg);
          CSR_STVEC: csr_stvec <= csr_write_val;
          CSR_SSCRATCH: csr_sscratch <= csr_write_val;
          CSR_MSTATUS: csr_mstatus <= sanitize_mstatus(csr_write_val);
          CSR_MSTATUSH: csr_mstatush <= csr_write_val;
          CSR_MEDELEG: csr_medeleg <= sanitize_medeleg(csr_write_val);
          CSR_MIDELEG: csr_mideleg <= sanitize_mideleg(csr_write_val);
          CSR_MCOUNTEREN: csr_mcounteren <= csr_write_val;
          CSR_MIE: csr_mie <= csr_write_val;
          CSR_MTVEC: csr_mtvec <= csr_write_val;
          CSR_MCOUNTINHIBIT: csr_mcountinhibit <= csr_write_val;
          CSR_SEPC: csr_sepc <= csr_write_val;
          CSR_SCAUSE: csr_scause <= csr_write_val;
          CSR_STVAL: csr_stval <= csr_write_val;
          CSR_SIP: csr_sip <= csr_write_val;
          CSR_MSCRATCH: csr_mscratch <= csr_write_val;
          CSR_MEPC: csr_mepc <= csr_write_val;
          CSR_MCAUSE: csr_mcause <= csr_write_val;
          CSR_MTVAL: csr_mtval <= csr_write_val;
          CSR_MIP: ;
          CSR_SATP: csr_satp <= sanitize_satp(csr_write_val);
          default: ;
        endcase
      end

      if (interrupt_take || async_exception_take) begin
        if (trap_to_s_mode) begin
          csr_sepc <= XLEN'(trap_pc);
          csr_scause <= trap_scause;
          csr_stval <= XLEN'(trap_tval);
          csr_mstatus <= sanitize_mstatus(mstatus_s_trap_next);
          current_priv <= PRIV_LVL_S;
        end else begin
          csr_mepc <= XLEN'(trap_pc);
          csr_mcause <= trap_mcause;
          csr_mtval <= XLEN'(trap_tval);
          csr_mstatus <= sanitize_mstatus(mstatus_trap_next);
          current_priv <= PRIV_LVL_M;
        end
      end else if (csr_valid_i && sys_op_valid && uop_i.is_mret && !sys_exception) begin
        csr_mstatus <= sanitize_mstatus(mstatus_mret_next);
        current_priv <= mret_target_priv;
      end else if (csr_valid_i && sys_op_valid && uop_i.is_sret && !sys_exception) begin
        csr_mstatus <= sanitize_mstatus(mstatus_sret_next);
        current_priv <= sret_target_priv;
      end
    end
  end

  assign regular_valid = csr_valid_i && (uop_i.illegal || uop_i.is_csr || sys_op_valid);
  assign csr_valid_o = regular_valid;
  assign csr_rob_tag_o = rob_tag_i;
  assign csr_result_o = (csr_valid_i && uop_i.is_csr) ? csr_read_val : '0;
  assign csr_exception_o = regular_valid && trap_take && !interrupt_take && !async_exception_take;
  assign csr_ecause_o = (regular_valid && trap_take && !interrupt_take &&
                         !async_exception_take) ? trap_ecause : '0;
  assign csr_is_mispred_o = (csr_valid_i && sys_op_valid && sys_is_mispred) || satp_write_flush;
  assign csr_redirect_pc_o = (regular_valid && trap_take && !interrupt_take &&
                              !async_exception_take) ? trap_redirect_pc :
                             (satp_write_flush ? (uop_i.pc + Cfg.PLEN'(4)) :
                             ((csr_valid_i && sys_op_valid && sys_is_mispred) ?
                             sys_redirect_pc :
                             ((csr_valid_i && sys_op_valid) ? sys_redirect_pc : '0)));
  assign irq_trap_o = interrupt_take || async_exception_take;
  assign irq_trap_cause_o = interrupt_take ? interrupt_cause :
                            (async_exception_take ? async_exception_cause_i : '0);
  assign irq_trap_pc_o = (interrupt_take || async_exception_take) ? trap_pc_i : '0;
  assign irq_trap_redirect_pc_o = (interrupt_take || async_exception_take) ? trap_redirect_pc : '0;
  assign satp_o = csr_satp;
  assign priv_mode_o = current_priv;
  assign mstatus_sum_o = csr_mstatus[MSTATUS_SUM_BIT];
  assign mstatus_mxr_o = csr_mstatus[MSTATUS_MXR_BIT];
  assign sfence_vma_flush_o = csr_valid_i && sys_op_valid && uop_i.is_sfence_vma && !trap_take;

endmodule
