module sv32_mmu #(
    parameter int unsigned TLB_ENTRIES = 8
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        req_valid_i,
    input  logic [31:0] req_vaddr_i,
    input  logic [1:0]  req_access_i,  // 0:instr 1:load 2:store
    input  logic [1:0]  req_priv_i,    // 0:U 1:S 3:M
    input  logic        req_sum_i,
    input  logic        req_mxr_i,
    input  logic [31:0] satp_i,
    input  logic        sfence_vma_i,

    output logic        req_ready_o,
    output logic        resp_valid_o,
    output logic [31:0] resp_paddr_o,
    output logic        resp_page_fault_o,

    output logic        pte_req_valid_o,
    input  logic        pte_req_ready_i,
    output logic [31:0] pte_req_paddr_o,
    input  logic        pte_rsp_valid_i,
    input  logic [31:0] pte_rsp_data_i,

    output logic        pte_upd_valid_o,
    input  logic        pte_upd_ready_i,
    output logic [31:0] pte_upd_paddr_o,
    output logic [31:0] pte_upd_data_o
);

  localparam logic [1:0] ACCESS_INSTR = 2'd0;
  localparam logic [1:0] ACCESS_LOAD  = 2'd1;
  localparam logic [1:0] ACCESS_STORE = 2'd2;

  localparam logic [1:0] PRIV_LVL_M = 2'b11;
  localparam logic [1:0] PRIV_LVL_S = 2'b01;
  localparam logic [1:0] PRIV_LVL_U = 2'b00;

  localparam int unsigned TLB_IDX_W = (TLB_ENTRIES <= 1) ? 1 : $clog2(TLB_ENTRIES);

  typedef enum logic [2:0] {
    ST_IDLE = 3'd0,
    ST_WALK_L1 = 3'd1,
    ST_WALK_L0 = 3'd2,
    ST_PTE_UPDATE = 3'd3
  } walk_state_e;

  walk_state_e state_q;

  logic [31:0] req_vaddr_q;
  logic [1:0]  req_access_q;
  logic [1:0]  req_priv_q;
  logic        req_sum_q;
  logic        req_mxr_q;
  logic [21:0] root_ppn_q;
  logic [21:0] next_ppn_q;

  logic        resp_valid_q;
  logic [31:0] resp_paddr_q;
  logic        resp_page_fault_q;

  logic [31:0] upd_pte_addr_q;
  logic [31:0] upd_pte_data_q;
  logic [31:0] upd_resp_paddr_q;
  logic        upd_from_tlb_hit_q;
  logic [TLB_IDX_W-1:0] upd_tlb_hit_idx_q;
  logic        upd_fill_super_q;
  logic [31:0] upd_fill_pte_q;
  logic [31:0] upd_fill_pte_addr_q;
  logic [31:0] upd_fill_vaddr_q;
  logic [31:0] satp_prev_q;
  logic        satp_context_flush_w;

  logic [TLB_ENTRIES-1:0]       tlb_valid_q;
  logic [TLB_ENTRIES-1:0]       tlb_super_q;
  logic [TLB_ENTRIES-1:0][ 9:0] tlb_vpn1_q;
  logic [TLB_ENTRIES-1:0][ 9:0] tlb_vpn0_q;
  logic [TLB_ENTRIES-1:0][31:0] tlb_pte_q;
  logic [TLB_ENTRIES-1:0][31:0] tlb_pte_addr_q;
  logic [TLB_IDX_W-1:0]         tlb_repl_ptr_q;

  logic        tlb_hit_w;
  logic [TLB_IDX_W-1:0] tlb_hit_idx_w;
  logic [31:0] tlb_hit_pte_w;
  logic        tlb_hit_super_w;
  logic [31:0] tlb_hit_pte_addr_w;

  logic        tlb_has_free_w;
  logic [TLB_IDX_W-1:0] tlb_free_idx_w;
  logic [TLB_IDX_W-1:0] tlb_fill_idx_w;

  logic [31:0] l1_pte_addr_w;
  logic [31:0] l0_pte_addr_w;
  logic [31:0] leaf_pte_updated_w;
`ifndef SYNTHESIS
  localparam int unsigned AGENT_MMU_PF_LOG_LIMIT = 32;
  logic [5:0] agent_mmu_pf_logs_q;
`endif

  function automatic logic pte_invalid(input logic [31:0] pte);
    pte_invalid = (!pte[0]) || (pte[2] && !pte[1]);
  endfunction

  function automatic logic pte_is_leaf(input logic [31:0] pte);
    pte_is_leaf = pte[1] || pte[3];
  endfunction

  function automatic logic pte_perm_ok(input logic [31:0] pte,
                                       input logic [1:0] access,
                                       input logic [1:0] priv,
                                       input logic sum,
                                       input logic mxr);
    logic read_ok;
    begin
      pte_perm_ok = 1'b0;

      if (pte_invalid(pte)) begin
        pte_perm_ok = 1'b0;
      end else begin
        if (priv == PRIV_LVL_U) begin
          if (!pte[4]) begin
            pte_perm_ok = 1'b0;
            return pte_perm_ok;
          end
        end else if (priv == PRIV_LVL_S) begin
          if (access == ACCESS_INSTR) begin
            if (pte[4]) begin
              pte_perm_ok = 1'b0;
              return pte_perm_ok;
            end
          end else if (pte[4] && !sum) begin
            pte_perm_ok = 1'b0;
            return pte_perm_ok;
          end
        end

        unique case (access)
          ACCESS_INSTR: pte_perm_ok = pte[3];
          ACCESS_LOAD: begin
            read_ok = pte[1] || (mxr && pte[3]);
            pte_perm_ok = read_ok;
          end
          ACCESS_STORE: pte_perm_ok = pte[1] && pte[2];
          default: pte_perm_ok = 1'b0;
        endcase
      end
    end
  endfunction

  function automatic logic pte_need_ad_update(input logic [31:0] pte, input logic [1:0] access);
    logic need_a;
    logic need_d;
    begin
      need_a = !pte[6];
      need_d = (access == ACCESS_STORE) && !pte[7];
      pte_need_ad_update = need_a || need_d;
    end
  endfunction

  function automatic logic [31:0] pte_with_ad(input logic [31:0] pte, input logic [1:0] access);
    logic [31:0] updated;
    begin
      updated = pte;
      updated[6] = 1'b1;
      if (access == ACCESS_STORE) begin
        updated[7] = 1'b1;
      end
      pte_with_ad = updated;
    end
  endfunction

  function automatic logic [31:0] compose_paddr(input logic [31:0] pte,
                                                input logic [31:0] vaddr,
                                                input logic is_superpage);
    begin
      if (is_superpage) begin
        compose_paddr = {pte[31:20], vaddr[21:0]};
      end else begin
        compose_paddr = {pte[31:10], vaddr[11:0]};
      end
    end
  endfunction

  assign l1_pte_addr_w = {root_ppn_q, 12'b0} + {20'b0, req_vaddr_q[31:22], 2'b00};
  assign l0_pte_addr_w = {next_ppn_q, 12'b0} + {20'b0, req_vaddr_q[21:12], 2'b00};

  assign req_ready_o = (state_q == ST_IDLE) && !satp_context_flush_w;
  assign pte_req_valid_o = !satp_context_flush_w && ((state_q == ST_WALK_L1) || (state_q == ST_WALK_L0));
  assign pte_req_paddr_o = (state_q == ST_WALK_L0) ? l0_pte_addr_w : l1_pte_addr_w;
  assign pte_upd_valid_o = !satp_context_flush_w && (state_q == ST_PTE_UPDATE);
  assign pte_upd_paddr_o = upd_pte_addr_q;
  assign pte_upd_data_o = upd_pte_data_q;

  assign resp_valid_o = resp_valid_q;
  assign resp_paddr_o = resp_paddr_q;
  assign resp_page_fault_o = resp_page_fault_q;
  assign satp_context_flush_w = sfence_vma_i || (satp_i != satp_prev_q);

  always_comb begin
    tlb_hit_w = 1'b0;
    tlb_hit_idx_w = '0;
    tlb_hit_pte_w = '0;
    tlb_hit_super_w = 1'b0;
    tlb_hit_pte_addr_w = '0;

    for (int i = 0; i < TLB_ENTRIES; i++) begin
      if (!tlb_hit_w && tlb_valid_q[i] && (tlb_vpn1_q[i] == req_vaddr_i[31:22]) &&
          (tlb_super_q[i] || (tlb_vpn0_q[i] == req_vaddr_i[21:12]))) begin
        tlb_hit_w = 1'b1;
        tlb_hit_idx_w = TLB_IDX_W'(i);
        tlb_hit_pte_w = tlb_pte_q[i];
        tlb_hit_super_w = tlb_super_q[i];
        tlb_hit_pte_addr_w = tlb_pte_addr_q[i];
      end
    end
  end

  always_comb begin
    tlb_has_free_w = 1'b0;
    tlb_free_idx_w = '0;
    for (int i = 0; i < TLB_ENTRIES; i++) begin
      if (!tlb_has_free_w && !tlb_valid_q[i]) begin
        tlb_has_free_w = 1'b1;
        tlb_free_idx_w = TLB_IDX_W'(i);
      end
    end
  end

  assign tlb_fill_idx_w = tlb_has_free_w ? tlb_free_idx_w : tlb_repl_ptr_q;
  assign leaf_pte_updated_w = pte_with_ad(pte_rsp_data_i, req_access_q);

  // Response and update handshakes are modeled as one-cycle pulses.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    logic [31:0] pte;
    logic [31:0] hit_pte_updated;
`ifndef SYNTHESIS
    integer agent_log_fd;
`endif

    if (!rst_ni) begin
      state_q <= ST_IDLE;
      req_vaddr_q <= '0;
      req_access_q <= '0;
      req_priv_q <= '0;
      req_sum_q <= 1'b0;
      req_mxr_q <= 1'b0;
      root_ppn_q <= '0;
      next_ppn_q <= '0;

      resp_valid_q <= 1'b0;
      resp_paddr_q <= '0;
      resp_page_fault_q <= 1'b0;

      upd_pte_addr_q <= '0;
      upd_pte_data_q <= '0;
      upd_resp_paddr_q <= '0;
      upd_from_tlb_hit_q <= 1'b0;
      upd_tlb_hit_idx_q <= '0;
      upd_fill_super_q <= 1'b0;
      upd_fill_pte_q <= '0;
      upd_fill_pte_addr_q <= '0;
      upd_fill_vaddr_q <= '0;
      satp_prev_q <= '0;

      tlb_valid_q <= '0;
      tlb_super_q <= '0;
      tlb_vpn1_q <= '0;
      tlb_vpn0_q <= '0;
      tlb_pte_q <= '0;
      tlb_pte_addr_q <= '0;
      tlb_repl_ptr_q <= '0;
`ifndef SYNTHESIS
      agent_mmu_pf_logs_q <= '0;
`endif
    end else begin
      pte = pte_rsp_data_i;
      hit_pte_updated = pte_with_ad(tlb_hit_pte_w, req_access_i);
      resp_valid_q <= 1'b0;
      satp_prev_q <= satp_i;

      if (satp_context_flush_w) begin
        tlb_valid_q <= '0;
      end

`ifndef SYNTHESIS

`endif

      if (satp_context_flush_w) begin
        // Drop any walk/update that was started under the previous translation context.
        state_q <= ST_IDLE;
        req_vaddr_q <= '0;
        req_access_q <= '0;
        req_priv_q <= '0;
        req_sum_q <= 1'b0;
        req_mxr_q <= 1'b0;
        root_ppn_q <= satp_i[21:0];
        next_ppn_q <= '0;
        upd_pte_addr_q <= '0;
        upd_pte_data_q <= '0;
        upd_resp_paddr_q <= '0;
        upd_from_tlb_hit_q <= 1'b0;
        upd_tlb_hit_idx_q <= '0;
        upd_fill_super_q <= 1'b0;
        upd_fill_pte_q <= '0;
        upd_fill_pte_addr_q <= '0;
        upd_fill_vaddr_q <= '0;
      end else begin
        unique case (state_q)
        ST_IDLE: begin
          if (req_valid_i) begin
            if (satp_i[31] == 1'b0 || req_priv_i == PRIV_LVL_M) begin
              resp_valid_q <= 1'b1;
              resp_page_fault_q <= 1'b0;
              resp_paddr_q <= req_vaddr_i;
            end else if (tlb_hit_w && !sfence_vma_i) begin
              if (!pte_perm_ok(tlb_hit_pte_w, req_access_i, req_priv_i, req_sum_i, req_mxr_i)) begin
                resp_valid_q <= 1'b1;
                resp_page_fault_q <= 1'b1;
                resp_paddr_q <= '0;
`ifndef SYNTHESIS
                // #region agent log
                if ((agent_mmu_pf_logs_q < AGENT_MMU_PF_LOG_LIMIT[5:0]) &&
                    (req_access_i == ACCESS_INSTR) &&
                    (req_vaddr_i >= 32'h9000_0000) && (req_vaddr_i < 32'hc000_0000)) begin
                  agent_log_fd = $fopen("../debug-fd94f9.log", "a");
                  if (agent_log_fd != 0) begin
                    $fwrite(agent_log_fd,
                            "{\"sessionId\":\"fd94f9\",\"runId\":\"mmu-priv-source\",\"hypothesisId\":\"H2-H3\",\"location\":\"npc/vsrc/mmu/sv32_mmu.sv:tlb_perm_fault\",\"message\":\"I-MMU TLB permission fault\",\"timestamp\":%0t,\"data\":{\"vaddr\":\"0x%08h\",\"access\":%0d,\"reqPriv\":%0d,\"sum\":%0d,\"mxr\":%0d,\"pte\":\"0x%08h\",\"pteU\":%0d,\"pteX\":%0d,\"permOk\":%0d,\"tlbHit\":1}}\n",
                            $time, req_vaddr_i, req_access_i, req_priv_i, req_sum_i, req_mxr_i,
                            tlb_hit_pte_w, tlb_hit_pte_w[4], tlb_hit_pte_w[3],
                            pte_perm_ok(tlb_hit_pte_w, req_access_i, req_priv_i, req_sum_i, req_mxr_i));
                    $fclose(agent_log_fd);
                  end
                  agent_mmu_pf_logs_q <= agent_mmu_pf_logs_q + 6'd1;
                end
                // #endregion
`endif
              end else if (pte_need_ad_update(tlb_hit_pte_w, req_access_i)) begin
                state_q <= ST_PTE_UPDATE;
                upd_pte_addr_q <= tlb_hit_pte_addr_w;
                upd_pte_data_q <= hit_pte_updated;
                upd_resp_paddr_q <= compose_paddr(tlb_hit_pte_w, req_vaddr_i, tlb_hit_super_w);
                upd_from_tlb_hit_q <= 1'b1;
                upd_tlb_hit_idx_q <= tlb_hit_idx_w;
                upd_fill_super_q <= tlb_hit_super_w;
                upd_fill_pte_q <= hit_pte_updated;
                upd_fill_pte_addr_q <= tlb_hit_pte_addr_w;
                upd_fill_vaddr_q <= req_vaddr_i;
              end else begin
                resp_valid_q <= 1'b1;
                resp_page_fault_q <= 1'b0;
                resp_paddr_q <= compose_paddr(tlb_hit_pte_w, req_vaddr_i, tlb_hit_super_w);
              end
            end else begin
              req_vaddr_q <= req_vaddr_i;
              req_access_q <= req_access_i;
              req_priv_q <= req_priv_i;
              req_sum_q <= req_sum_i;
              req_mxr_q <= req_mxr_i;
              root_ppn_q <= satp_i[21:0];
              state_q <= ST_WALK_L1;
            end
          end
        end

        ST_WALK_L1: begin
          if (pte_rsp_valid_i) begin
`ifndef SYNTHESIS
            if (((req_vaddr_q & 32'hfffff000) == 32'hc0001000) ||
                ((req_vaddr_q & 32'hfffff000) == 32'hc0401000)) begin
              $display("[mmu-l1] vaddr=%h satp=%h pte_addr=%h pte=%h leaf=%0d invalid=%0d",
                       req_vaddr_q, satp_i, l1_pte_addr_w, pte, pte_is_leaf(pte), pte_invalid(pte));
            end
`endif
            if (pte_invalid(pte)) begin
              state_q <= ST_IDLE;
              resp_valid_q <= 1'b1;
              resp_page_fault_q <= 1'b1;
              resp_paddr_q <= '0;
            end else if (pte_is_leaf(pte)) begin
              if ((pte[19:10] != 10'b0) ||
                  !pte_perm_ok(pte, req_access_q, req_priv_q, req_sum_q, req_mxr_q)) begin
                state_q <= ST_IDLE;
                resp_valid_q <= 1'b1;
                resp_page_fault_q <= 1'b1;
                resp_paddr_q <= '0;
              end else if (pte_need_ad_update(pte, req_access_q)) begin
                state_q <= ST_PTE_UPDATE;
                upd_pte_addr_q <= l1_pte_addr_w;
                upd_pte_data_q <= leaf_pte_updated_w;
                upd_resp_paddr_q <= compose_paddr(pte, req_vaddr_q, 1'b1);
                upd_from_tlb_hit_q <= 1'b0;
                upd_tlb_hit_idx_q <= '0;
                upd_fill_super_q <= 1'b1;
                upd_fill_pte_q <= leaf_pte_updated_w;
                upd_fill_pte_addr_q <= l1_pte_addr_w;
                upd_fill_vaddr_q <= req_vaddr_q;
              end else begin
                state_q <= ST_IDLE;
                resp_valid_q <= 1'b1;
                resp_page_fault_q <= 1'b0;
                resp_paddr_q <= compose_paddr(pte, req_vaddr_q, 1'b1);
                tlb_valid_q[tlb_fill_idx_w] <= 1'b1;
                tlb_super_q[tlb_fill_idx_w] <= 1'b1;
                tlb_vpn1_q[tlb_fill_idx_w] <= req_vaddr_q[31:22];
                tlb_vpn0_q[tlb_fill_idx_w] <= req_vaddr_q[21:12];
                tlb_pte_q[tlb_fill_idx_w] <= pte;
                tlb_pte_addr_q[tlb_fill_idx_w] <= l1_pte_addr_w;
                tlb_repl_ptr_q <= tlb_repl_ptr_q + TLB_IDX_W'(1);
              end
            end else begin
              next_ppn_q <= pte[31:10];
              state_q <= ST_WALK_L0;
            end
          end
        end

        ST_WALK_L0: begin
          if (pte_rsp_valid_i) begin
`ifndef SYNTHESIS
            if (((req_vaddr_q & 32'hfffff000) == 32'hc0001000) ||
                ((req_vaddr_q & 32'hfffff000) == 32'hc0401000)) begin
              $display("[mmu-l0] vaddr=%h pte_addr=%h pte=%h paddr=%h invalid=%0d leaf=%0d perm_ok=%0d",
                       req_vaddr_q, l0_pte_addr_w, pte, compose_paddr(pte, req_vaddr_q, 1'b0),
                       pte_invalid(pte), pte_is_leaf(pte),
                       pte_perm_ok(pte, req_access_q, req_priv_q, req_sum_q, req_mxr_q));
            end
`endif
            if (pte_invalid(pte) || !pte_is_leaf(pte) ||
                !pte_perm_ok(pte, req_access_q, req_priv_q, req_sum_q, req_mxr_q)) begin
              state_q <= ST_IDLE;
              resp_valid_q <= 1'b1;
              resp_page_fault_q <= 1'b1;
              resp_paddr_q <= '0;
`ifndef SYNTHESIS
              // #region agent log
              if ((agent_mmu_pf_logs_q < AGENT_MMU_PF_LOG_LIMIT[5:0]) &&
                  (req_access_q == ACCESS_INSTR) &&
                  (req_vaddr_q >= 32'h9000_0000) && (req_vaddr_q < 32'hc000_0000)) begin
                agent_log_fd = $fopen("../debug-fd94f9.log", "a");
                if (agent_log_fd != 0) begin
                  $fwrite(agent_log_fd,
                          "{\"sessionId\":\"fd94f9\",\"runId\":\"mmu-priv-source\",\"hypothesisId\":\"H2-H3\",\"location\":\"npc/vsrc/mmu/sv32_mmu.sv:l0_perm_fault\",\"message\":\"I-MMU L0 permission fault\",\"timestamp\":%0t,\"data\":{\"vaddr\":\"0x%08h\",\"access\":%0d,\"reqPriv\":%0d,\"sum\":%0d,\"mxr\":%0d,\"pteAddr\":\"0x%08h\",\"pte\":\"0x%08h\",\"pteValid\":%0d,\"pteLeaf\":%0d,\"pteU\":%0d,\"pteX\":%0d,\"permOk\":%0d,\"tlbHit\":0}}\n",
                          $time, req_vaddr_q, req_access_q, req_priv_q, req_sum_q, req_mxr_q,
                          l0_pte_addr_w, pte, !pte_invalid(pte), pte_is_leaf(pte), pte[4], pte[3],
                          pte_perm_ok(pte, req_access_q, req_priv_q, req_sum_q, req_mxr_q));
                  $fclose(agent_log_fd);
                end
                agent_mmu_pf_logs_q <= agent_mmu_pf_logs_q + 6'd1;
              end
              // #endregion
`endif
            end else if (pte_need_ad_update(pte, req_access_q)) begin
              state_q <= ST_PTE_UPDATE;
              upd_pte_addr_q <= l0_pte_addr_w;
              upd_pte_data_q <= leaf_pte_updated_w;
              upd_resp_paddr_q <= compose_paddr(pte, req_vaddr_q, 1'b0);
              upd_from_tlb_hit_q <= 1'b0;
              upd_tlb_hit_idx_q <= '0;
              upd_fill_super_q <= 1'b0;
              upd_fill_pte_q <= leaf_pte_updated_w;
              upd_fill_pte_addr_q <= l0_pte_addr_w;
              upd_fill_vaddr_q <= req_vaddr_q;
            end else begin
              state_q <= ST_IDLE;
              resp_valid_q <= 1'b1;
              resp_page_fault_q <= 1'b0;
              resp_paddr_q <= compose_paddr(pte, req_vaddr_q, 1'b0);
              tlb_valid_q[tlb_fill_idx_w] <= 1'b1;
              tlb_super_q[tlb_fill_idx_w] <= 1'b0;
              tlb_vpn1_q[tlb_fill_idx_w] <= req_vaddr_q[31:22];
              tlb_vpn0_q[tlb_fill_idx_w] <= req_vaddr_q[21:12];
              tlb_pte_q[tlb_fill_idx_w] <= pte;
              tlb_pte_addr_q[tlb_fill_idx_w] <= l0_pte_addr_w;
              tlb_repl_ptr_q <= tlb_repl_ptr_q + TLB_IDX_W'(1);
            end
          end
        end

        ST_PTE_UPDATE: begin
          if (pte_upd_ready_i) begin
            state_q <= ST_IDLE;
            resp_valid_q <= 1'b1;
            resp_page_fault_q <= 1'b0;
            resp_paddr_q <= upd_resp_paddr_q;
            if (upd_from_tlb_hit_q) begin
              tlb_pte_q[upd_tlb_hit_idx_q] <= upd_pte_data_q;
            end else begin
              tlb_valid_q[tlb_fill_idx_w] <= 1'b1;
              tlb_super_q[tlb_fill_idx_w] <= upd_fill_super_q;
              tlb_vpn1_q[tlb_fill_idx_w] <= upd_fill_vaddr_q[31:22];
              tlb_vpn0_q[tlb_fill_idx_w] <= upd_fill_vaddr_q[21:12];
              tlb_pte_q[tlb_fill_idx_w] <= upd_fill_pte_q;
              tlb_pte_addr_q[tlb_fill_idx_w] <= upd_fill_pte_addr_q;
              tlb_repl_ptr_q <= tlb_repl_ptr_q + TLB_IDX_W'(1);
            end
          end
        end

        default: begin
          state_q <= ST_IDLE;
        end
        endcase
      end
    end
  end

  // Keep interface compatibility; current model only requires response valid.
  wire _unused_ok = &{1'b0, pte_req_ready_i, 1'b0};

endmodule
