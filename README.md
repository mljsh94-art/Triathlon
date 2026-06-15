# Triathlon

4-wide superscalar out-of-order **RV32IMAC** RISC-V CPU（Tomasulo + in-order retire），SystemVerilog RTL + Verilator 5.008 仿真。支持 AM cpu-tests、DiffTest（NEMU），以及 **OpenSBI + Linux 6.6.30** 全系统启动。

微架构与 AI 入口见英文 [CLAUDE.md](CLAUDE.md)；仿真参数、DiffTest、全系统构建等中文专题见 [docs/](docs/README.md)。

---

## 目录结构

```
Triathlon/
├── npc/                 # RTL + Verilator 仿真（核心）
├── nemu/                # 参考模拟器（DiffTest）
├── abstract-machine/    # 裸机运行时（AM cpu-tests）
├── am-kernels/          # 测试与 benchmark
├── opensbi/             # OpenSBI（platform/triathlon）
├── linux_workspace/     # Linux 构建脚本、预合并镜像（见下文；不含内核源码树）
│   ├── build_kernel.sh  # 生成最小 RV32 Linux 配置并编译 Image
│   ├── merge.py         # 合并 OpenSBI + Linux Image + DTB → fw_combined.bin
├── fw_combined.bin      # 预构建全系统仿真镜像（可 git 拉取后直接仿真）
├── echo_payload/        # 可选最小 S-mode payload（不参与 merge.py 默认流程）
├── CLAUDE.md            # 微架构与配置（英文，AI 入口）
└── docs/                # 中文专题：编译、ARGS、DiffTest、调试、全系统
```

---

## 主机环境要求

推荐 **Ubuntu 22.04** 或 **WSL2 Ubuntu**。Windows 原生需自行安装 Verilator 与 g++。

### 必需组件

| 组件 | 要求 | 用途 |
|------|------|------|
| **Verilator** | **必须 5.008** | 编译 `npc/build/tb_triathlon` |
| **g++ / make** | 支持 C++17 | Verilator 生成代码与 host 仿真 |
| **python3** | 3.8+ | `linux_workspace/merge.py` |
| **build-essential** | gcc/g++ | 通用编译 |
| **libreadline-dev** |  | NEMU / DiffTest 链接 |
| **git** |  | 克隆子项目、内核源码 |

### 可选组件

| 组件 | 用途 |
|------|------|
| **GTKWave** | 波形查看（需 `VM_TRACE=1` 构建仿真器） |
| **llvm-dev** | 部分 host 工具 |
| **dtc**（device-tree-compiler） | 从 `opensbi/platform/triathlon/triathlon.dts` 生成 DTB；无则 `merge.py` 使用内置等价 DTB |

### 工具链（按用途选择）

| 用途 | 工具链前缀 | 说明 |
|------|------------|------|
| **OpenSBI** | `riscv64-linux-gnu-` | `PLATFORM_RISCV_XLEN=32`，需支持 PIE |
| **Linux 内核** | `riscv64-linux-gnu-`（推荐） | 目标为 **RV32** 内核（`CONFIG_32BIT=y`），与 OpenSBI 同前缀即可 |
| **AM cpu-tests** | `riscv64-unknown-elf-` 等 | 由 AbstractMachine 文档/脚本决定；ARCH 见下文 |
| **本地 musl 工具链** | `linux_workspace/toolchain/...` | **不在 Git 中**；可选，不设置时用上面的 `riscv64-linux-gnu-` |

安装示例（Ubuntu）：

```bash
sudo apt-get update
sudo apt-get install -y build-essential git python3 \
  libreadline-dev device-tree-compiler \
  g++-riscv64-linux-gnu binutils-riscv64-linux-gnu
# Verilator 5.008 请从官方源码安装到 PATH
# AM 裸机工具链按 abstract-machine 文档安装 riscv64-unknown-elf-gcc
```

---

## 环境变量

在 `~/.bashrc` 中加入（路径改成你的 clone 目录）：

```bash
export TRIATHLON_HOME=/path/to/Triathlon
export NPC_HOME=$TRIATHLON_HOME/npc
export NEMU_HOME=$TRIATHLON_HOME/nemu
export AM_HOME=$TRIATHLON_HOME/abstract-machine
export KERNELS_HOME=$TRIATHLON_HOME/am-kernels
export TEST_HOME=$KERNELS_HOME/tests
export CPU_TEST_HOME=$TEST_HOME/cpu-tests
```

```bash
source ~/.bashrc
```

---

## 克隆仓库

```bash
git clone https://github.com/mljsh94-art/Triathlon.git
cd Triathlon
# 按上一节设置 TRIATHLON_HOME 等
```

---

## 快速开始 A：CPU 测试（AM）

```bash
cd $NPC_HOME
make clean
make

cd $CPU_TEST_HOME
make clean
make ARCH=riscv32im-npc ALL=dummy run
```

成功时终端出现绿色 **`HIT GOOD TRAP`**。出现 **`HIT BAD TRAP`** 多为 CPU 实现问题；编译失败请检查 Verilator 版本与 AM 工具链。

启用 DiffTest（与 NEMU 对比）：

```bash
cd $NPC_HOME
make sim IMG=/path/to/test.bin
# 默认链接 npc/ref/riscv32-nemu-interpreter-so；禁用：make sim DIFFTEST= IMG=...
```

---

## 快速开始 B：全系统 Linux（OpenSBI + 内核）

### 1. 准备 Linux 内核源码（仓库内不含）

本仓库 **不包含** `linux_workspace/linux/`（完整内核树约 1.5GB，不适合放入 Git）。请自行下载 **Linux 6.6.30** 到该路径（与 [`linux_workspace/build_kernel.sh`](linux_workspace/build_kernel.sh) 一致）：

```bash
cd linux_workspace

# 方式 1：官方 tarball
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.30.tar.xz
tar xf linux-6.6.30.tar.xz
mv linux-6.6.30 linux

# 方式 2：kernel.org git
git clone --depth 1 --branch v6.6.30 \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux
```

| 项 | 说明 |
|----|------|
| 验证版本 | 内核树内 `Makefile` 前几行应为 `VERSION=6`、`PATCHLEVEL=6`、`SUBLEVEL=30` |
| 架构 | `ARCH=riscv`，**32 位 RV32 内核**（非 rv64 内核） |
| 其它版本 | 未验证；建议固定 **6.6.30** |

**`linux_workspace/` 目录说明：**

| 路径 | 是否在 Git | 说明 |
|------|------------|------|
| `linux/` | 否（用户自备） | 6.6.30 源码树 |
| `toolchain/` | 否 | 可选本地 musl 工具链；可用系统 `riscv64-linux-gnu-` 代替 |
| `rootfs/` | 部分 | 含 busybox 符号链接目录树；**在 Linux/WSL 下**用 busybox 安装生成（见下） |
| `rootfs_extra.list` | 是 | cpio 额外节点（如 `/dev/console`） |
| `busybox/.config` | 是 | busybox 配置；源码树需自行下载或使用 release tarball |

**生成 `rootfs/`（在 Linux 或 WSL 下执行）：**

```bash
cd linux_workspace
# 下载 busybox 源码（版本与 .config 匹配），或使用你本地的 busybox 目录
make -C busybox ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)"
make -C busybox ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- CONFIG_PREFIX="$PWD/rootfs" install
```

Windows 原生 Git 无法可靠提交 `rootfs/` 内大量符号链接，因此仓库以 **`rootfs_extra.list` + `busybox/.config`** 为主；完整 `rootfs/` 请在上面的 Unix 环境中生成。

### 2. 可选：Linux 启动临时补丁

若内核在 `check_unaligned_access()` 阶段 panic，可对 `linux/arch/riscv/kernel/cpufeature.c` 做临时 bypass（见 [docs/full-system.md](docs/full-system.md)）。RTL 稳定后应恢复原始探测逻辑。

### 3. 编译 OpenSBI

```bash
make -C opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-
```

输出：`opensbi/build/platform/triathlon/firmware/fw_jump.bin`

### 4. 编译 Linux Image

```bash
export CROSS_COMPILE=riscv64-linux-gnu-
./linux_workspace/build_kernel.sh
```

输出：`linux_workspace/linux/arch/riscv/boot/Image`  
脚本会写入 `.triathlon_min.config` 片段、执行 `allnoconfig` 并编译最小 RV32 配置（内置 initramfs、8250/SBI earlycon 等）。

### 5. 合并全系统镜像

```bash
python3 linux_workspace/merge.py
```

生成仓库根目录 **`fw_combined.bin`**，布局：

| 组件 | 物理地址 |
|------|----------|
| OpenSBI `fw_jump.bin` | `0x80000000` |
| Linux `Image` | `0x80400000` |
| DTB | `0x83F00000` |

设备树向 Linux 报告 **64MB** 可见内存（`0x80000000`–`0x83FFFFFF`）。

### 6. Verilator 仿真

Linux/OpenSBI 涉及 SV32 MMU 与特权级，**请禁用 DiffTest**：

```bash
make -C npc sim DIFFTEST= IMG=../fw_combined.bin \
  ARGS='--max-cycles=100000000 --progress=1000000'
```

可选早期调试：`ARGS='... --linux-early-debug'`（里程碑见 [docs/debugging.md](docs/debugging.md)）。

**成功标志（节选）：**

- OpenSBI banner 中出现 `Domain0 Next Arg1 : 0x83f00000`
- 内核 earlycon / 控制台有输出

---

## 常见问题

1. **Verilator 版本不对** — 必须使用 **5.008**，否则易出现仿真异常。
2. **Linux 仿真不要开 DiffTest** — bare-metal NEMU 无法对齐全系统 SV32/PLIC 行为，请 `DIFFTEST=`。
3. **`merge.py` 报缺文件** — 先完成 OpenSBI 与 `./linux_workspace/build_kernel.sh`，并确认 `linux_workspace/linux` 存在。
4. **工具链** — OpenSBI 与 Linux 推荐 `riscv64-linux-gnu-`；`linux_workspace/build_kernel.sh` 默认 `../toolchain/bin/riscv32-linux-musl-` 仅在你本地放了 toolchain 时有效。
5. **跳过本地编译** — 仓库已包含根目录 `fw_combined.bin`，可直接 `make -C npc sim DIFFTEST= IMG=../fw_combined.bin`。

---

## 更多文档

- [CLAUDE.md](CLAUDE.md) — 微架构与配置（英文，AI 入口）
- [docs/README.md](docs/README.md) — 中文专题：编译测试、ARGS、DiffTest、调试、全系统
- [npc/tools/profiler/README.md](npc/tools/profiler/README.md) — 性能分析工具
