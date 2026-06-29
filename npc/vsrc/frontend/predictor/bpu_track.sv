// vsrc/frontend/predictor/bpu_track.sv
// BPU diagnostic / override-tracking state. Owns the per-provider override
// tracking FIFOs (tage/sc/loop/cond) that defer prediction-time decisions until
// the matching FTQ commit, plus every dbg_* accuracy/usage counter that used to
// live inline in bpu.sv's 770-line always_ff. Behavior is identical to the
// inline tracking that previously lived in bpu.sv: the logic was moved out
// unchanged, only scope/wiring differs. The testbench reads the dbg_*_q
// counters by hierarchy (dut.u_frontend.i_bpu.u_track.dbg_*_q), exactly as it
// already does for u_bht/u_ras, so the dbg_bpu_* profile signature is preserved.
module bpu_track #(
    parameter bit USE_TAGE = 1'b0,
    parameter bit USE_SC = 1'b0,
    parameter bit USE_LOOP = 1'b0,
    parameter int unsigned TRACK_DEPTH = 16
) (
    input logic clk_i,
    input logic rst_i,
    input logic flush_i,

    // Commit-time (FTQ update) side: drives FIFO pops + train/accuracy counters.
    input logic update_valid_i,
    input logic update_is_cond_i,
    input logic update_taken_i,
    input logic ittage_update_valid_i,

    // Predict-time side: drives FIFO pushes + lookup/usage counters. pred_fire_i
    // is (ftq_enq_valid && ftq_enq_ready), i.e. a prediction actually enqueued.
    input logic pred_fire_i,
    input logic pred_slot_is_cond_i,
    input logic pred_slot_taken_i,
    input logic tage_hit_i,
    input logic cond_tage_override_i,
    input logic sc_confident_i,
    input logic cond_sc_override_i,
    input logic loop_hit_i,
    input logic loop_confident_i,
    input logic cond_loop_override_i,
    input logic [1:0] cond_selected_provider_i,
    input logic cond_selected_taken_i,
    input logic cond_taken_legacy_i,
    input logic tage_taken_i,
    input logic sc_taken_i,
    input logic loop_taken_i,
    input logic cond_tage_candidate_i,
    input logic cond_sc_candidate_i,
    input logic cond_loop_candidate_i,

    // FTB/ITTAGE predict-time snapshot sideband (drives FTB/ITTAGE counters).
    input logic dbg_snap_ftb_cond_hit_i,
    input logic dbg_snap_ftb_jump_hit_i,
    input logic dbg_snap_ftb_pick_cond_i,
    input logic dbg_snap_ftb_pick_jump_i,
    input logic dbg_snap_ftb_cond_tag_miss_i,
    input logic dbg_snap_ftb_jump_tag_miss_i,
    input logic dbg_snap_ftb_jump_indirect_i,
    input logic dbg_snap_ittage_raw_hit_i,
    input logic dbg_snap_ittage_use_i
);

  localparam int unsigned TAGE_TRACK_DEPTH = (TRACK_DEPTH >= 2) ? TRACK_DEPTH : 2;
  localparam int unsigned TAGE_TRACK_PTR_W = (TAGE_TRACK_DEPTH > 1) ? $clog2(TAGE_TRACK_DEPTH) : 1;
  localparam int unsigned TAGE_TRACK_CNT_W = $clog2(TAGE_TRACK_DEPTH + 1);
  localparam logic [1:0] COND_PROVIDER_LEGACY = 2'd0;
  localparam logic [1:0] COND_PROVIDER_TAGE = 2'd1;
  localparam logic [1:0] COND_PROVIDER_SC = 2'd2;
  localparam logic [1:0] COND_PROVIDER_LOOP = 2'd3;

  logic [63:0] dbg_tage_lookup_total_q;
  logic [63:0] dbg_tage_hit_total_q;
  logic [63:0] dbg_tage_override_total_q;
  logic [63:0] dbg_tage_override_correct_q;
  logic [63:0] dbg_sc_lookup_total_q;
  logic [63:0] dbg_sc_confident_total_q;
  logic [63:0] dbg_sc_override_total_q;
  logic [63:0] dbg_sc_override_correct_q;
  logic [63:0] dbg_loop_lookup_total_q;
  logic [63:0] dbg_loop_hit_total_q;
  logic [63:0] dbg_loop_confident_total_q;
  logic [63:0] dbg_loop_override_total_q;
  logic [63:0] dbg_loop_override_correct_q;
  logic [63:0] dbg_cond_provider_legacy_selected_q;
  logic [63:0] dbg_cond_provider_tage_selected_q;
  logic [63:0] dbg_cond_provider_sc_selected_q;
  logic [63:0] dbg_cond_provider_loop_selected_q;
  logic [63:0] dbg_cond_provider_legacy_correct_q;
  logic [63:0] dbg_cond_provider_tage_correct_q;
  logic [63:0] dbg_cond_provider_sc_correct_q;
  logic [63:0] dbg_cond_provider_loop_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_legacy_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_tage_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_sc_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_loop_correct_q;
  logic [63:0] dbg_cond_selected_wrong_alt_any_correct_q;
  logic [63:0] dbg_ftb_lookup_total_q;
  logic [63:0] dbg_ftb_cond_hit_total_q;
  logic [63:0] dbg_ftb_jump_hit_total_q;
  logic [63:0] dbg_ftb_cond_pick_total_q;
  logic [63:0] dbg_ftb_jump_pick_total_q;
  logic [63:0] dbg_ftb_cond_tag_miss_total_q;
  logic [63:0] dbg_ftb_jump_tag_miss_total_q;
  logic [63:0] dbg_ftb_train_cond_total_q;
  logic [63:0] dbg_ftb_train_jump_total_q;
  logic [63:0] dbg_ittage_lookup_total_q;
  logic [63:0] dbg_ittage_hit_total_q;
  logic [63:0] dbg_ittage_use_total_q;
  logic [63:0] dbg_ittage_train_total_q;

  logic [TAGE_TRACK_DEPTH-1:0] tage_track_override_q;
  logic [TAGE_TRACK_DEPTH-1:0] tage_track_pred_taken_q;
  logic [TAGE_TRACK_PTR_W-1:0] tage_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] tage_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] tage_track_count_q;
  logic [TAGE_TRACK_DEPTH-1:0] sc_track_override_q;
  logic [TAGE_TRACK_DEPTH-1:0] sc_track_pred_taken_q;
  logic [TAGE_TRACK_PTR_W-1:0] sc_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] sc_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] sc_track_count_q;
  logic [TAGE_TRACK_DEPTH-1:0] loop_track_override_q;
  logic [TAGE_TRACK_DEPTH-1:0] loop_track_pred_taken_q;
  logic [TAGE_TRACK_PTR_W-1:0] loop_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] loop_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] loop_track_count_q;
  logic [TAGE_TRACK_DEPTH-1:0][1:0] cond_track_provider_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_selected_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_legacy_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_tage_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_sc_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_loop_taken_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_tage_candidate_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_sc_candidate_q;
  logic [TAGE_TRACK_DEPTH-1:0] cond_track_loop_candidate_q;
  logic [TAGE_TRACK_PTR_W-1:0] cond_track_head_q;
  logic [TAGE_TRACK_PTR_W-1:0] cond_track_tail_q;
  logic [TAGE_TRACK_CNT_W-1:0] cond_track_count_q;

  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      dbg_tage_lookup_total_q <= '0;
      dbg_tage_hit_total_q <= '0;
      dbg_tage_override_total_q <= '0;
      dbg_tage_override_correct_q <= '0;
      dbg_sc_lookup_total_q <= '0;
      dbg_sc_confident_total_q <= '0;
      dbg_sc_override_total_q <= '0;
      dbg_sc_override_correct_q <= '0;
      dbg_loop_lookup_total_q <= '0;
      dbg_loop_hit_total_q <= '0;
      dbg_loop_confident_total_q <= '0;
      dbg_loop_override_total_q <= '0;
      dbg_loop_override_correct_q <= '0;
      dbg_cond_provider_legacy_selected_q <= '0;
      dbg_cond_provider_tage_selected_q <= '0;
      dbg_cond_provider_sc_selected_q <= '0;
      dbg_cond_provider_loop_selected_q <= '0;
      dbg_cond_provider_legacy_correct_q <= '0;
      dbg_cond_provider_tage_correct_q <= '0;
      dbg_cond_provider_sc_correct_q <= '0;
      dbg_cond_provider_loop_correct_q <= '0;
      dbg_cond_selected_wrong_alt_legacy_correct_q <= '0;
      dbg_cond_selected_wrong_alt_tage_correct_q <= '0;
      dbg_cond_selected_wrong_alt_sc_correct_q <= '0;
      dbg_cond_selected_wrong_alt_loop_correct_q <= '0;
      dbg_cond_selected_wrong_alt_any_correct_q <= '0;
      dbg_ftb_lookup_total_q <= '0;
      dbg_ftb_cond_hit_total_q <= '0;
      dbg_ftb_jump_hit_total_q <= '0;
      dbg_ftb_cond_pick_total_q <= '0;
      dbg_ftb_jump_pick_total_q <= '0;
      dbg_ftb_cond_tag_miss_total_q <= '0;
      dbg_ftb_jump_tag_miss_total_q <= '0;
      dbg_ftb_train_cond_total_q <= '0;
      dbg_ftb_train_jump_total_q <= '0;
      dbg_ittage_lookup_total_q <= '0;
      dbg_ittage_hit_total_q <= '0;
      dbg_ittage_use_total_q <= '0;
      dbg_ittage_train_total_q <= '0;
      tage_track_override_q <= '0;
      tage_track_pred_taken_q <= '0;
      tage_track_head_q <= '0;
      tage_track_tail_q <= '0;
      tage_track_count_q <= '0;
      sc_track_override_q <= '0;
      sc_track_pred_taken_q <= '0;
      sc_track_head_q <= '0;
      sc_track_tail_q <= '0;
      sc_track_count_q <= '0;
      loop_track_override_q <= '0;
      loop_track_pred_taken_q <= '0;
      loop_track_head_q <= '0;
      loop_track_tail_q <= '0;
      loop_track_count_q <= '0;
      cond_track_provider_q <= '0;
      cond_track_selected_taken_q <= '0;
      cond_track_legacy_taken_q <= '0;
      cond_track_tage_taken_q <= '0;
      cond_track_sc_taken_q <= '0;
      cond_track_loop_taken_q <= '0;
      cond_track_tage_candidate_q <= '0;
      cond_track_sc_candidate_q <= '0;
      cond_track_loop_candidate_q <= '0;
      cond_track_head_q <= '0;
      cond_track_tail_q <= '0;
      cond_track_count_q <= '0;
    end else begin
      logic [TAGE_TRACK_PTR_W-1:0] tage_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] tage_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] tage_count_n;
      logic [TAGE_TRACK_DEPTH-1:0] tage_override_n;
      logic [TAGE_TRACK_DEPTH-1:0] tage_pred_taken_n;
      logic [TAGE_TRACK_PTR_W-1:0] sc_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] sc_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] sc_count_n;
      logic [TAGE_TRACK_DEPTH-1:0] sc_override_n;
      logic [TAGE_TRACK_DEPTH-1:0] sc_pred_taken_n;
      logic [TAGE_TRACK_PTR_W-1:0] loop_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] loop_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] loop_count_n;
      logic [TAGE_TRACK_DEPTH-1:0] loop_override_n;
      logic [TAGE_TRACK_DEPTH-1:0] loop_pred_taken_n;
      logic tage_pop_override;
      logic tage_pop_pred_taken;
      logic tage_push_override;
      logic sc_pop_override;
      logic sc_pop_pred_taken;
      logic sc_push_override;
      logic loop_pop_override;
      logic loop_pop_pred_taken;
      logic loop_push_override;
      logic [TAGE_TRACK_PTR_W-1:0] cond_head_n;
      logic [TAGE_TRACK_PTR_W-1:0] cond_tail_n;
      logic [TAGE_TRACK_CNT_W-1:0] cond_count_n;
      logic [TAGE_TRACK_DEPTH-1:0][1:0] cond_provider_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_selected_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_legacy_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_tage_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_sc_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_loop_taken_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_tage_candidate_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_sc_candidate_n;
      logic [TAGE_TRACK_DEPTH-1:0] cond_loop_candidate_n;
      logic [1:0] cond_pop_provider;
      logic cond_pop_selected_taken;
      logic cond_pop_legacy_taken;
      logic cond_pop_tage_taken;
      logic cond_pop_sc_taken;
      logic cond_pop_loop_taken;
      logic cond_pop_tage_candidate;
      logic cond_pop_sc_candidate;
      logic cond_pop_loop_candidate;
      logic cond_selected_pred_correct;
      logic cond_alt_any_correct;

      tage_head_n = tage_track_head_q;
      tage_tail_n = tage_track_tail_q;
      tage_count_n = tage_track_count_q;
      tage_override_n = tage_track_override_q;
      tage_pred_taken_n = tage_track_pred_taken_q;
      sc_head_n = sc_track_head_q;
      sc_tail_n = sc_track_tail_q;
      sc_count_n = sc_track_count_q;
      sc_override_n = sc_track_override_q;
      sc_pred_taken_n = sc_track_pred_taken_q;
      loop_head_n = loop_track_head_q;
      loop_tail_n = loop_track_tail_q;
      loop_count_n = loop_track_count_q;
      loop_override_n = loop_track_override_q;
      loop_pred_taken_n = loop_track_pred_taken_q;
      cond_head_n = cond_track_head_q;
      cond_tail_n = cond_track_tail_q;
      cond_count_n = cond_track_count_q;
      cond_provider_n = cond_track_provider_q;
      cond_selected_taken_n = cond_track_selected_taken_q;
      cond_legacy_taken_n = cond_track_legacy_taken_q;
      cond_tage_taken_n = cond_track_tage_taken_q;
      cond_sc_taken_n = cond_track_sc_taken_q;
      cond_loop_taken_n = cond_track_loop_taken_q;
      cond_tage_candidate_n = cond_track_tage_candidate_q;
      cond_sc_candidate_n = cond_track_sc_candidate_q;
      cond_loop_candidate_n = cond_track_loop_candidate_q;
      tage_pop_override = 1'b0;
      tage_pop_pred_taken = 1'b0;
      tage_push_override = 1'b0;
      sc_pop_override = 1'b0;
      sc_pop_pred_taken = 1'b0;
      sc_push_override = 1'b0;
      loop_pop_override = 1'b0;
      loop_pop_pred_taken = 1'b0;
      loop_push_override = 1'b0;
      cond_pop_provider = COND_PROVIDER_LEGACY;
      cond_pop_selected_taken = 1'b0;
      cond_pop_legacy_taken = 1'b0;
      cond_pop_tage_taken = 1'b0;
      cond_pop_sc_taken = 1'b0;
      cond_pop_loop_taken = 1'b0;
      cond_pop_tage_candidate = 1'b0;
      cond_pop_sc_candidate = 1'b0;
      cond_pop_loop_candidate = 1'b0;
      cond_selected_pred_correct = 1'b0;
      cond_alt_any_correct = 1'b0;

      if (update_valid_i) begin
        // FTB 训练计数：与 u_ftb 内 up_do_ftb_train 条件保持一致。
        if (!update_is_cond_i || update_taken_i) begin
          if (update_is_cond_i) begin
            dbg_ftb_train_cond_total_q <= dbg_ftb_train_cond_total_q + 64'd1;
          end else begin
            dbg_ftb_train_jump_total_q <= dbg_ftb_train_jump_total_q + 64'd1;
          end
        end
        if (ittage_update_valid_i) begin
          dbg_ittage_train_total_q <= dbg_ittage_train_total_q + 64'd1;
        end

        if (USE_TAGE && update_is_cond_i && (tage_count_n != '0)) begin
          tage_pop_override = tage_override_n[tage_head_n];
          tage_pop_pred_taken = tage_pred_taken_n[tage_head_n];
          tage_head_n = tage_head_n + TAGE_TRACK_PTR_W'(1);
          tage_count_n = tage_count_n - TAGE_TRACK_CNT_W'(1);
          if (tage_pop_override && (tage_pop_pred_taken == update_taken_i)) begin
            dbg_tage_override_correct_q <= dbg_tage_override_correct_q + 64'd1;
          end
        end
        if (USE_SC && update_is_cond_i && (sc_count_n != '0)) begin
          sc_pop_override = sc_override_n[sc_head_n];
          sc_pop_pred_taken = sc_pred_taken_n[sc_head_n];
          sc_head_n = sc_head_n + TAGE_TRACK_PTR_W'(1);
          sc_count_n = sc_count_n - TAGE_TRACK_CNT_W'(1);
          if (sc_pop_override && (sc_pop_pred_taken == update_taken_i)) begin
            dbg_sc_override_correct_q <= dbg_sc_override_correct_q + 64'd1;
          end
        end
        if (USE_LOOP && update_is_cond_i && (loop_count_n != '0)) begin
          loop_pop_override = loop_override_n[loop_head_n];
          loop_pop_pred_taken = loop_pred_taken_n[loop_head_n];
          loop_head_n = loop_head_n + TAGE_TRACK_PTR_W'(1);
          loop_count_n = loop_count_n - TAGE_TRACK_CNT_W'(1);
          if (loop_pop_override && (loop_pop_pred_taken == update_taken_i)) begin
            dbg_loop_override_correct_q <= dbg_loop_override_correct_q + 64'd1;
          end
        end
        if (update_is_cond_i && (cond_count_n != '0)) begin
          cond_pop_provider = cond_provider_n[cond_head_n];
          cond_pop_selected_taken = cond_selected_taken_n[cond_head_n];
          cond_pop_legacy_taken = cond_legacy_taken_n[cond_head_n];
          cond_pop_tage_taken = cond_tage_taken_n[cond_head_n];
          cond_pop_sc_taken = cond_sc_taken_n[cond_head_n];
          cond_pop_loop_taken = cond_loop_taken_n[cond_head_n];
          cond_pop_tage_candidate = cond_tage_candidate_n[cond_head_n];
          cond_pop_sc_candidate = cond_sc_candidate_n[cond_head_n];
          cond_pop_loop_candidate = cond_loop_candidate_n[cond_head_n];
          cond_head_n = cond_head_n + TAGE_TRACK_PTR_W'(1);
          cond_count_n = cond_count_n - TAGE_TRACK_CNT_W'(1);

          cond_selected_pred_correct = (cond_pop_selected_taken == update_taken_i);
          case (cond_pop_provider)
            COND_PROVIDER_TAGE: begin
              dbg_cond_provider_tage_selected_q <= dbg_cond_provider_tage_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_tage_correct_q <= dbg_cond_provider_tage_correct_q + 64'd1;
              end
            end
            COND_PROVIDER_SC: begin
              dbg_cond_provider_sc_selected_q <= dbg_cond_provider_sc_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_sc_correct_q <= dbg_cond_provider_sc_correct_q + 64'd1;
              end
            end
            COND_PROVIDER_LOOP: begin
              dbg_cond_provider_loop_selected_q <= dbg_cond_provider_loop_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_loop_correct_q <= dbg_cond_provider_loop_correct_q + 64'd1;
              end
            end
            default: begin
              dbg_cond_provider_legacy_selected_q <= dbg_cond_provider_legacy_selected_q + 64'd1;
              if (cond_selected_pred_correct) begin
                dbg_cond_provider_legacy_correct_q <= dbg_cond_provider_legacy_correct_q + 64'd1;
              end
            end
          endcase

          if (!cond_selected_pred_correct) begin
            cond_alt_any_correct = 1'b0;
            if ((cond_pop_provider != COND_PROVIDER_LEGACY) &&
                (cond_pop_legacy_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_legacy_correct_q <=
                  dbg_cond_selected_wrong_alt_legacy_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_TAGE) &&
                cond_pop_tage_candidate &&
                (cond_pop_tage_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_tage_correct_q <=
                  dbg_cond_selected_wrong_alt_tage_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_SC) &&
                cond_pop_sc_candidate &&
                (cond_pop_sc_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_sc_correct_q <=
                  dbg_cond_selected_wrong_alt_sc_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if ((cond_pop_provider != COND_PROVIDER_LOOP) &&
                cond_pop_loop_candidate &&
                (cond_pop_loop_taken == update_taken_i)) begin
              dbg_cond_selected_wrong_alt_loop_correct_q <=
                  dbg_cond_selected_wrong_alt_loop_correct_q + 64'd1;
              cond_alt_any_correct = 1'b1;
            end
            if (cond_alt_any_correct) begin
              dbg_cond_selected_wrong_alt_any_correct_q <=
                  dbg_cond_selected_wrong_alt_any_correct_q + 64'd1;
            end
          end
        end
      end

      if (flush_i) begin
        tage_head_n = '0;
        tage_tail_n = '0;
        tage_count_n = '0;
        tage_override_n = '0;
        tage_pred_taken_n = '0;
        sc_head_n = '0;
        sc_tail_n = '0;
        sc_count_n = '0;
        sc_override_n = '0;
        sc_pred_taken_n = '0;
        loop_head_n = '0;
        loop_tail_n = '0;
        loop_count_n = '0;
        loop_override_n = '0;
        loop_pred_taken_n = '0;
        cond_head_n = '0;
        cond_tail_n = '0;
        cond_count_n = '0;
        cond_provider_n = '0;
        cond_selected_taken_n = '0;
        cond_legacy_taken_n = '0;
        cond_tage_taken_n = '0;
        cond_sc_taken_n = '0;
        cond_loop_taken_n = '0;
        cond_tage_candidate_n = '0;
        cond_sc_candidate_n = '0;
        cond_loop_candidate_n = '0;
      end else begin
        if (USE_TAGE && pred_fire_i && pred_slot_is_cond_i) begin
          dbg_tage_lookup_total_q <= dbg_tage_lookup_total_q + 64'd1;
          if (tage_hit_i) begin
            dbg_tage_hit_total_q <= dbg_tage_hit_total_q + 64'd1;
          end
          tage_push_override = cond_tage_override_i;
          if (tage_push_override) begin
            dbg_tage_override_total_q <= dbg_tage_override_total_q + 64'd1;
          end
          if (tage_count_n < TAGE_TRACK_DEPTH) begin
            tage_override_n[tage_tail_n] = tage_push_override;
            tage_pred_taken_n[tage_tail_n] = pred_slot_taken_i;
            tage_tail_n = tage_tail_n + TAGE_TRACK_PTR_W'(1);
            tage_count_n = tage_count_n + TAGE_TRACK_CNT_W'(1);
          end
        end
        if (USE_SC && pred_fire_i && pred_slot_is_cond_i) begin
          dbg_sc_lookup_total_q <= dbg_sc_lookup_total_q + 64'd1;
          if (sc_confident_i) begin
            dbg_sc_confident_total_q <= dbg_sc_confident_total_q + 64'd1;
          end
          sc_push_override = cond_sc_override_i;
          if (sc_push_override) begin
            dbg_sc_override_total_q <= dbg_sc_override_total_q + 64'd1;
          end
          if (sc_count_n < TAGE_TRACK_DEPTH) begin
            sc_override_n[sc_tail_n] = sc_push_override;
            sc_pred_taken_n[sc_tail_n] = pred_slot_taken_i;
            sc_tail_n = sc_tail_n + TAGE_TRACK_PTR_W'(1);
            sc_count_n = sc_count_n + TAGE_TRACK_CNT_W'(1);
          end
        end
        if (USE_LOOP && pred_fire_i && pred_slot_is_cond_i) begin
          dbg_loop_lookup_total_q <= dbg_loop_lookup_total_q + 64'd1;
          if (loop_hit_i) begin
            dbg_loop_hit_total_q <= dbg_loop_hit_total_q + 64'd1;
          end
          if (loop_confident_i) begin
            dbg_loop_confident_total_q <= dbg_loop_confident_total_q + 64'd1;
          end
          loop_push_override = cond_loop_override_i;
          if (loop_push_override) begin
            dbg_loop_override_total_q <= dbg_loop_override_total_q + 64'd1;
          end
          if (loop_count_n < TAGE_TRACK_DEPTH) begin
            loop_override_n[loop_tail_n] = loop_push_override;
            loop_pred_taken_n[loop_tail_n] = pred_slot_taken_i;
            loop_tail_n = loop_tail_n + TAGE_TRACK_PTR_W'(1);
            loop_count_n = loop_count_n + TAGE_TRACK_CNT_W'(1);
          end
        end
        if (pred_fire_i) begin
          dbg_ftb_lookup_total_q <= dbg_ftb_lookup_total_q + 64'd1;
          if (dbg_snap_ftb_cond_hit_i) begin
            dbg_ftb_cond_hit_total_q <= dbg_ftb_cond_hit_total_q + 64'd1;
          end
          if (dbg_snap_ftb_jump_hit_i) begin
            dbg_ftb_jump_hit_total_q <= dbg_ftb_jump_hit_total_q + 64'd1;
          end
          if (dbg_snap_ftb_pick_cond_i) begin
            dbg_ftb_cond_pick_total_q <= dbg_ftb_cond_pick_total_q + 64'd1;
          end
          if (dbg_snap_ftb_pick_jump_i) begin
            dbg_ftb_jump_pick_total_q <= dbg_ftb_jump_pick_total_q + 64'd1;
          end
          if (dbg_snap_ftb_cond_tag_miss_i) begin
            dbg_ftb_cond_tag_miss_total_q <= dbg_ftb_cond_tag_miss_total_q + 64'd1;
          end
          if (dbg_snap_ftb_jump_tag_miss_i) begin
            dbg_ftb_jump_tag_miss_total_q <= dbg_ftb_jump_tag_miss_total_q + 64'd1;
          end
          if (dbg_snap_ftb_jump_indirect_i) begin
            dbg_ittage_lookup_total_q <= dbg_ittage_lookup_total_q + 64'd1;
            if (dbg_snap_ittage_raw_hit_i) begin
              dbg_ittage_hit_total_q <= dbg_ittage_hit_total_q + 64'd1;
            end
          end
          if (dbg_snap_ittage_use_i) begin
            dbg_ittage_use_total_q <= dbg_ittage_use_total_q + 64'd1;
          end
        end
        if (pred_fire_i && pred_slot_is_cond_i && (cond_count_n < TAGE_TRACK_DEPTH)) begin
          cond_provider_n[cond_tail_n] = cond_selected_provider_i;
          cond_selected_taken_n[cond_tail_n] = cond_selected_taken_i;
          cond_legacy_taken_n[cond_tail_n] = cond_taken_legacy_i;
          cond_tage_taken_n[cond_tail_n] = tage_taken_i;
          cond_sc_taken_n[cond_tail_n] = sc_taken_i;
          cond_loop_taken_n[cond_tail_n] = loop_taken_i;
          cond_tage_candidate_n[cond_tail_n] = cond_tage_candidate_i;
          cond_sc_candidate_n[cond_tail_n] = cond_sc_candidate_i;
          cond_loop_candidate_n[cond_tail_n] = cond_loop_candidate_i;
          cond_tail_n = cond_tail_n + TAGE_TRACK_PTR_W'(1);
          cond_count_n = cond_count_n + TAGE_TRACK_CNT_W'(1);
        end
      end

      tage_track_head_q <= tage_head_n;
      tage_track_tail_q <= tage_tail_n;
      tage_track_count_q <= tage_count_n;
      tage_track_override_q <= tage_override_n;
      tage_track_pred_taken_q <= tage_pred_taken_n;
      sc_track_head_q <= sc_head_n;
      sc_track_tail_q <= sc_tail_n;
      sc_track_count_q <= sc_count_n;
      sc_track_override_q <= sc_override_n;
      sc_track_pred_taken_q <= sc_pred_taken_n;
      loop_track_head_q <= loop_head_n;
      loop_track_tail_q <= loop_tail_n;
      loop_track_count_q <= loop_count_n;
      loop_track_override_q <= loop_override_n;
      loop_track_pred_taken_q <= loop_pred_taken_n;
      cond_track_head_q <= cond_head_n;
      cond_track_tail_q <= cond_tail_n;
      cond_track_count_q <= cond_count_n;
      cond_track_provider_q <= cond_provider_n;
      cond_track_selected_taken_q <= cond_selected_taken_n;
      cond_track_legacy_taken_q <= cond_legacy_taken_n;
      cond_track_tage_taken_q <= cond_tage_taken_n;
      cond_track_sc_taken_q <= cond_sc_taken_n;
      cond_track_loop_taken_q <= cond_loop_taken_n;
      cond_track_tage_candidate_q <= cond_tage_candidate_n;
      cond_track_sc_candidate_q <= cond_sc_candidate_n;
      cond_track_loop_candidate_q <= cond_loop_candidate_n;
    end
  end

endmodule : bpu_track
