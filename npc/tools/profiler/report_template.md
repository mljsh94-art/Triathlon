# NPC Profiling Report

- Generated at: `{{GENERATED_AT}}`
- Profile directory: `{{PROFILE_DIR}}`

## Benchmark Summary

{{BENCHMARK_SECTIONS}}

## Notes

- `mispredict_flush_count` 和 `branch_penalty_cycles` 来自运行时 `flush/flushp` 事件日志。
- `flush_reason_histogram` 与 `flush_source_histogram` 用于区分 flush 根因及来源（ROB/外部）。
- `predict` 统计来自运行时 `[pred]` 汇总日志，按 `cond_branch/jump/return` 给出 hit/miss，并提供 `call_total`。
- `predict(cond local/global/selected acc)` 与 `predict(cond chooser local/global)` 用于评估 tournament predictor 的选择质量与收益。
- `predict(tage lookup/hit)` 与 `predict(tage override/correct)` 用于评估 TAGE 覆盖路径是否活跃、是否产生实际收益。
- `predict(sc_l lookup/confident/override/correct)` 用于评估 SC-L 触发频率、覆盖活跃度与覆盖正确率。
- `predict(loop lookup/hit/confident/override/correct)` 用于评估 loop predictor 命中、置信度和覆盖收益。
- `wrong_path_kill_uops` 与 `redirect_distance_*` 来自 flush 事件字段，用于估计错误路径清除开销。
- `stallm3/stallm4`（若存在）提供 `decode_blocked/rob_backpressure` 的周期级二级拆分；缺失时回退 sampled `[stall]` 明细。
- `benchmark_time_ms(self/host/effective)` 中 `host` 来自 NEMU `host time spent`，用于 self-reported 时间为 0 时的兜底口径。
