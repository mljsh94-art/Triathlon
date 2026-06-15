# Triathlon 专题文档（中文）

架构与 AI 入口见英文 [CLAUDE.md](../CLAUDE.md)。以下为操作手册，按需查阅。

| 文档 | 内容 |
|------|------|
| [build-and-test.md](build-and-test.md) | Makefile 目标、Make 变量、常用仿真命令 |
| [profile.md](profile.md) | 性能采集、看板、回归对比 |
| [sim-args.md](sim-args.md) | 仿真器 `ARGS` 参数、Snapshot、输出 Tag、镜像加载 |
| [difftest.md](difftest.md) | Spike DiffTest、Verilator RTL 断言 |
| [verification.md](verification.md) | verify-* 门禁、DiffTest 验收阶段 |
| [debugging.md](debugging.md) | NDJSON 日志、linux-early-debug、排障流程 |
| [full-system.md](full-system.md) | OpenSBI + Linux 构建、merge.py、全系统仿真 |

子项目 README：

- [npc/ref/README.md](../npc/ref/README.md) — Spike `.so` 构建与 smoke test
- [npc/tools/profiler/README.md](../npc/tools/profiler/README.md) — profiler 工具目录说明
