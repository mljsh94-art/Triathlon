// vsrc/include/bpu_pkg.sv
// BPU predictor interface bundles (predict / update contract).
package bpu_pkg;

  import global_config_pkg::*;

  localparam int unsigned GHR_W =
      (Cfg.BPU_GHR_BITS > 0) ? Cfg.BPU_GHR_BITS : 1;
  localparam int unsigned PATH_W =
      (Cfg.BPU_PATH_HIST_BITS > 0) ? Cfg.BPU_PATH_HIST_BITS : 1;

  // Provider-private sideband bits carried with a predict response.
  typedef struct packed {
    logic       is_strong;
    logic [1:0] useful;
    logic       confident;
    logic       loop_hit;
    logic       is_backward;
    logic       is_call;
    logic       is_ret;
    logic       is_rvc;
    logic       is_cond;
    logic       is_indirect;
  } predict_resp_meta_t;

  // Commit-time sideband for predictor training.
  typedef struct packed {
    logic [GHR_W-1:0]  ghr;
    logic [PATH_W-1:0] path;
  } update_meta_t;

  typedef struct packed {
    logic                valid;
    logic [Cfg.PLEN-1:0] pc;
    logic [GHR_W-1:0]    ghr;
    logic [PATH_W-1:0]   path;
  } predict_req_t;

  typedef struct packed {
    logic                hit;
    logic                taken;
    logic [Cfg.PLEN-1:0] target;
    logic [1:0]          provider;
    predict_resp_meta_t  meta;
  } predict_resp_t;

  typedef struct packed {
    logic                valid;
    logic [Cfg.PLEN-1:0] pc;
    logic                taken;
    logic [Cfg.PLEN-1:0] target;
    logic                mispred;
    logic                is_cond;
    logic                is_call;
    logic                is_ret;
    logic                is_rvc;
    update_meta_t        meta;
  } update_t;

endpackage : bpu_pkg
