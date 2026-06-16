# DiffTest 与 RTL 断言

## Spike DiffTest

Triathlon 使用 Spike `rv32imac` / MSU / Sv32 lockstep 参考模型。共享库 `npc/ref/riscv32-spike-difftest.so` 由 `make -C npc/ref` 构建。构建与 smoke test 见 [npc/ref/README.md](../npc/ref/README.md)。

### 源码分工

| 路径 | 作用 |
|------|------|
| `npc/csrc/include/difftest_arch.h` | `DUTCoreState` 布局 |
| `npc/csrc/lib/difftest_client.cpp` | retire 点 lockstep |
| `npc/csrc/npc_main.cpp` | commit 探针采集 |
| `npc/vsrc/test/tb_triathlon.sv` | CSR/store/trap 探针 |
| `npc/ref/spike-diff/difftest.cc` | Spike 封装 |

### DUTCoreState 比对字段

| 组 | 字段 |
|----|------|
| 核心 | `gpr[32]`, `pc` |
| 特权 | `priv`（0=U, 1=S, 3=M） |
| Trap | `mstatus`, `sstatus`, `mepc`, `sepc`, `mcause`, `scause`, `mtval`, `stval`, `mtvec`, `stvec`, `mscratch`, `sscratch` |
| 中断/委托 | `mie`, `mip`, `medeleg`, `mideleg` |
| MMU | `satp` |

`sstatus` 取自 `dbg_csr_sstatus_o`（RTL `csr_sstatus_view`）。

### Lockstep 流程（`step_and_check`）

1. `regcpy(FROM_REF)`；trap entry 时先用 DUT 覆盖 ref。
2. 判定是否跳过 Spike 执行（见下表）。
3. 未跳过：`difftest_exec(1)`。
4. 跳过：`regcpy(TO_REF)` 用 DUT 覆盖 ref。
5. DRAM store commit：增量 `difftest_memcpy(TO_REF)`；每拍同步 DUT `mip` 到 Spike。
6. `check_arch_state()` 逐项比对；MMIO load 的 `rd` 忽略。

### 非确定性路径（DUT 驱动 ref）

| 条件 | 检测 |
|------|------|
| CSR trap / 中断 | `dbg_csr_irq_trap_o` |
| MMIO load/store | PMA 判 MMIO（DRAM 外 `0x80000000`–`0x87FFFFFF`） |
| DUT 覆盖 CSR | `cycle`/`time`/`instret`、PMP、machine ID 等 |
| A 扩展临时覆盖 | Linux Sv32 下 U/S 模式 RV32A `.W` |
| Linux 取指真值覆盖 | 页边界半字与 ROB `decoded_inst` 不一致 |
| Trap entry 覆盖 | M/S trap handler 首条退休前全状态覆盖 |

### RTL 探针

- CSR：`dbg_csr_*_o`（`u_backend.u_csr`）
- Store：`commit_store_*`、`commit_sb_id_o`
- Trap：`dbg_csr_irq_trap_o`、`dbg_csr_irq_redirect_pc_o`

### 失败输出

`[difftest] mismatch cycle=... pc=... field=...` + DUT/REF 全状态 dump。Smoke：`make -C npc/ref check`。

### 验收阶段

| 阶段 | 范围 | 命令 |
|------|------|------|
| Phase 1 | 裸机 lockstep | `make ARCH=riscv32im-npc run`（cpu-tests） |
| Phase 2 | store/MMIO/trap 覆盖 | dhrystone/coremark；`tb_plic` 等 |
| Phase 3 | Linux 全系统 | **未验收**；建议 `DIFFTEST=` |

Profile 采集默认 `DIFFTEST=`。

---

## Verilator RTL 断言（ASSERT）

与 DiffTest 共用 `build/$(TOPNAME)`；`ASSERT=1` 编译期 `--assert`，切换须重编。

| | DiffTest | ASSERT |
|---|----------|--------|
| Make 变量 | `DIFFTEST=` 关 | `ASSERT=1` 开 |
| 生效 | 运行时 `-d .so` | 编译期 `--assert` |
| 切换重编 | 否 | 是 |

源码：`npc/vsrc/include/sim_assert.sv`（``NPC_ASSERT` / ``NPC_COVER`）。

```bash
make -C npc sim ASSERT=1 IMG=.../test.bin
make -C npc ASSERT=1 TOPNAME=tb_rob_exception SIM_MAIN=csrc/test/test_rob_exception.cpp
make -C npc verify-unit MODULE=all
make -C npc verify-assert-programs
```

- 直接 `assert`/`$fatal` 不依赖 `--assert`。
- AM 透传：`NPC_EXTRA='ASSERT=1'`（`abstract-machine/scripts/platform/npc.mk`）。

SNAPSHOT：`SNAPSHOT=1` → `--savable --threads 1`；与 ASSERT 独立，切换均触发重编。Linux 全系统 DiffTest + Snapshot 长跑见 [full-system.md](full-system.md#全系统仿真fw_combinedbin)。
