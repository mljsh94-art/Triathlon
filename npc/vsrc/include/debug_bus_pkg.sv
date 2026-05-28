package debug_bus_pkg;

  typedef struct packed {
    logic valid;
    logic fe_valid;
    logic dec_valid;
    logic dec_ready;
    logic rob_ready;
  } pipe_dbg_t;

  typedef struct packed {
    logic valid;
    logic lsu_issue_valid;
    logic lsu_req_ready;
  } mem_dbg_t;

endpackage : debug_bus_pkg
