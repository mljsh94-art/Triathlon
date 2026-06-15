# 验证门禁

## verify-* 流水线

| 步骤 | 目标 | 脚本 |
|------|------|------|
| ① | 单元 ASSERT TB | `scripts/subshell/run_assert_unit.sh` |
| ② | DiffTest 门禁 | `run_difftest_suite.sh` |
| ③ | 程序 ASSERT | `run_assert_programs.sh` |
| ④ | cover 壳子 | `run_cover_check.sh` |

```bash
make -C npc verify-unit              # MODULE=rob/fe/issue/lsu/all
make -C npc verify-difftest
make -C npc verify-assert-programs
make -C npc verify-cover
make -C npc verify-all               # ①→②→③→④
```

## DiffTest 验收阶段

详见 [difftest.md](difftest.md#验收阶段)。

- **Phase 1–2**：裸机 + benchmark，DiffTest 启用。
- **Phase 3**：Linux 全系统未验收；仿真用 `DIFFTEST=`。

## ASSERT 回归

- 单元：`make -C npc verify-unit MODULE=all`
- 程序（含 neg 负向）：`make -C npc verify-assert-programs`
- cpu-tests：`make ARCH=riscv32im-npc NPC_EXTRA='ASSERT=1' run`

DiffTest 与 ASSERT 机制见 [difftest.md](difftest.md)。
