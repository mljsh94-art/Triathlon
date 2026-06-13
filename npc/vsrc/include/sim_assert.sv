// Simulation-only assertion/cover macros (included from PKG_VSRCS; not a module).
`ifndef NPC_SIM_ASSERT_SV
`define NPC_SIM_ASSERT_SV

`ifndef SYNTHESIS
  `define NPC_ASSERT(cond, msg) \
    assert (cond) else $fatal(1, "[assert] %s", msg);

  `define NPC_ASSERT_ONEHOT0(mask, msg) \
    assert ($onehot0(mask)) else $fatal(1, "[assert] %s (mask=%b)", msg, mask);

  `define NPC_COVER(cover_id, prop) \
    cover property (prop) \
      $display("[cover] hit: %s", cover_id);
`endif

`endif
