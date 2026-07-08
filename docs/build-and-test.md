# 编译与测试

编译与测试流程基于 `npc/Makefile`。通过 Verilator 编译 SystemVerilog 设计和 C++ 仿真程序。

`npc/Makefile` 内置 Verilator/host 编译选项（不可通过 Make 变量覆盖）：host C++ `-O3 -march=native -fno-plt`；Verilator 生成代码 `OPT_FAST/SLOW/GLOBAL=-O3`；仿真 `--threads 2`；并行编译 `-j $(nproc)`。Profile 采集固定使用 AM 架构 **riscv32im-npc**（`tools/profiler/run_profile.sh`）。

## Makefile 目标

| 目标 | 常用指令 | 功能描述 |
|------|----------|----------|
| `default` / `all` | `make` 或 `make all` | 编译 RTL + C++，生成 `build/tb_triathlon` |
| `sim` | `make sim` | 编译并运行仿真 |
| `profile-report` | `make profile-report` | dhrystone/coremark/microbench(test) 采集并 merge 为 `summary.json` |
| `profile-task` | `make profile-task` | 采集到 `npc/profile/<PROFILE_TAG>/` |
| `profile-baseline` | `make profile-baseline` | 以 `baseline` 为 tag 的回归基线 |
| `profile-index` | `make profile-index` | 生成 `index.json` |
| `profile-dashboard` | `make profile-dashboard` | 生成看板 HTML |
| `profile-clean` | `make profile-clean` | 清空 `npc/profile/` |
| `clean` | `make clean` | 删除 `build/` |
| `verify-unit` | `make verify-unit` | ① 单元 ASSERT TB（`MODULE=rob/fe/issue/lsu/all`） |
| `verify-difftest` | `make verify-difftest` | ② DiffTest 门禁 |
| `verify-assert-programs` | `make verify-assert-programs` | ③ 程序 ASSERT 全门禁 |
| `verify-cover` | `make verify-cover` | ④ cover 壳子（Phase 7 占位） |
| `verify-bpu-golden` | `make verify-bpu-golden` | ⑤ BPU golden：coremark+dhrystone 行为签名 diff |
| `verify-bpu-golden-update` | `make verify-bpu-golden-update` | 刷新 `scripts/golden/bpu_baseline.json` |
| `verify-all` | `make verify-all` | ①→②→③→④ 发版全量回归（不含 ⑤） |

详见 [verification.md](verification.md)。BPU 重构 golden 方法论见 [bpu-refactor.md](bpu-refactor.md)。

## Make 变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TOPNAME` | `tb_triathlon` | 顶层模块名（对应 `vsrc/tb_*.sv`） |
| `IMG` | *(空)* | 程序镜像路径 |
| `ARGS` | *(空)* | 仿真器扩展参数，见 [sim-args.md](sim-args.md) |
| `DIFFTEST_SO` | `npc/ref/riscv32-spike-difftest.so` | Spike DiffTest；`DIFFTEST=` 禁用 |
| `ASSERT` | *(关)* | `ASSERT=1` 开启 Verilator `--assert`，切换须重编 |
| `NPC_EXTRA` | *(空)* | AM `npc.mk` 透传（例：`NPC_EXTRA='ASSERT=1'`） |
| `CROSS_COMPILE` | `riscv64-unknown-elf-` | profile-report 交叉编译前缀 |
| `PROFILE_OUT_DIR` | 自动时间戳 | profile 输出目录 |
| `PROFILE_NAME` | *(空)* | 输出 `npc/profile/<name>-<timestamp>/`，看板 `display_name` 为 `<name>` |
| `PROFILE_TAG` | `latest` | profile-task 目录 tag |
| `PROFILE_DISPLAY_NAME` | 目录名 | 看板显示名（可单独覆盖 `PROFILE_NAME` 的标签） |
| `PROFILE_ROOT` | `npc/profile` | index/dashboard 扫描根 |

## 典型命令

```bash
# 编译并运行（默认 DiffTest 在 .so 存在时启用）
make -C npc sim IMG=/path/to/image.bin

# 禁用 DiffTest
make -C npc sim DIFFTEST= IMG=/path/to/image.bin

# Verilator 断言（须重编）
make -C npc sim ASSERT=1 IMG=/path/to/image.bin

# 单元 TB
make -C npc TOPNAME=tb_rob_exception SIM_MAIN=csrc/test/test_rob_exception.cpp

# cpu-tests 单项
cd am-kernels/tests/cpu-tests && make ARCH=riscv32im-npc ALL=dummy run

# Linux 全系统 + DiffTest + Snapshot（详见 full-system.md）
make -C npc/ref && make -C npc SNAPSHOT=1
make -C npc sim SNAPSHOT=1 IMG=$PWD/fw_combined.bin \
  ARGS='--max-cycles=100000000 --progress=2000000 --linux-early-debug \
        --snapshot-interval=5000000 --snapshot-dir=snapshots --snapshot-keep=3'
```

DiffTest 与 ASSERT 细节见 [difftest.md](difftest.md)。Profile 见 [profile.md](profile.md)。
