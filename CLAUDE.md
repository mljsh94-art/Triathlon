# Triathlon - Out-of-Order RISC-V CPU

> **IMPORTANT DOCUMENTATION RULES:** 
> - **Update this MD after every modification** to the project.
> - **Keep ONLY** system file descriptions, architecture descriptions, compilation toolchains, etc.
> - **DO NOT add history records** or logs of past changes to this file.

## Project Overview

Triathlon is a **4-wide superscalar out-of-order RISC-V RV32I processor** implementing the Tomasulo algorithm with in-order retirement. Built with SystemVerilog, simulated using Verilator 5.008.

## Directory Structure

```
Triathlon/
├── npc/vsrc/                        # RTL source
│   ├── triathlon.sv                 # Top-level module
│   ├── frontend/                    # Frontend pipeline
│   │   ├── frontend.sv              # Frontend top (IFU + BPU + ICache)
│   │   ├── ifu.sv                   # Instruction fetch unit + FTQ
│   │   ├── bpu.sv                   # Branch prediction unit
│   │   └── fetch_target_queue.sv    # Fetch target queue
│   ├── backend/                     # Backend pipeline
│   │   ├── backend.sv               # Backend top (all backend wiring)
│   │   ├── buffer/
│   │   │   ├── ibuffer.sv           # Instruction buffer (FIFO, 16 entries)
│   │   │   └── store_buffer.sv      # Store buffer (16 entries)
│   │   ├── decode/
│   │   │   └── decoder.sv           # 4-wide instruction decoder
│   │   ├── rename/
│   │   │   ├── rename.sv            # Rename/dispatch stage
│   │   │   └── rat.sv               # Register Alias Table (32 entries)
│   │   ├── issue/
│   │   │   ├── issue.sv             # ALU issue queue (4-way)
│   │   │   ├── issue_single.sv      # Single-issue queue (BRU, CSR)
│   │   │   ├── issue_lsu.sv         # LSU issue queue
│   │   │   ├── issue_select.sv      # Ready-entry selector
│   │   │   ├── rs.sv                # Reservation station base
│   │   │   ├── rs_lsu.sv            # LSU reservation station
│   │   │   └── rs_allocator.sv      # RS allocation logic
│   │   ├── regfile/
│   │   │   └── arf.sv               # Architectural register file (8R/4W)
│   │   ├── retire/
│   │   │   ├── rob.sv               # Reorder buffer (64 entries)
│   │   │   └── writeback.sv         # Writeback arbiter (CDB)
│   │   └── execute/
│   │       ├── alu.sv               # ALU (execute_alu, also used for BRU)
│   │       ├── lsu.sv               # Load/store unit
│   │       └── csr.sv               # CSR execution unit
│   ├── cache/
│   │   ├── icache.sv                # Instruction cache
│   │   ├── dcache.sv                # Data cache
│   │   ├── icache_axi_wrapper.sv    # ICache AXI bridge
│   │   ├── dcache_axi_wrapper.sv    # DCache AXI bridge
│   │   ├── tag_array.sv             # Tag SRAM
│   │   ├── data_array.sv            # Data SRAM
│   │   ├── sram.sv                  # Generic SRAM primitive
│   │   └── lfsr.sv                  # LFSR (for cache replacement)
│   ├── include/                     # Packages and configs
│   │   ├── config_pkg.sv            # Configuration struct definitions
│   │   ├── global_config_pkg.sv     # Global config instantiation
│   │   ├── test_config_pkg.sv       # Test configuration parameters
│   │   ├── build_config_pkg.sv      # Build config
│   │   ├── decode_pkg.sv            # Decode types (uop_t, FU enums)
│   │   ├── issue_pkg.sv             # Issue types
│   │   └── riscv_pkg.sv             # RISC-V ISA constants
│   ├── test/                        # Testbenches (tb_*.sv)
│   ├── mmu/
│   │   └── sv32_mmu.sv              # RISC-V SV32 Paging MMU
│   ├── platform/
│   │   ├── plic.sv                  # Platform-Level Interrupt Controller
│   │   └── virtio_blk.sv            # VirtIO Block Device Simulation
│   └── util/
│       └── priority_encoder.sv      # Priority encoder
├── am-kernels/                      # Test programs and benchmarks
├── nemu/                            # Reference simulator
├── abstract-machine/                # Bare-metal runtime
├── opensbi/                         # OpenSBI firmware (platform/triathlon, FW_JUMP + DTB handoff)
│   └── platform/triathlon/
│       ├── objects.mk               # FW_JUMP_ADDR / FW_JUMP_FDT_ADDR 等平台参数
│       ├── platform.c               # PLIC / CLINT / UART 平台驱动
│       ├── triathlon.dts            # 设备树源（merge.py 编译为 DTB）
│       └── configs/defconfig        # CONFIG_PLATFORM_TRIATHLON=y
├── echo_payload/                    # Optional lightweight S-mode test (NOT used by merge.py)
│   ├── Makefile                     # riscv64-unknown-elf-gcc，链接 0x80400000
│   ├── link.ld                      # Linker script (links at 0x80400000)
│   └── payload.S                    # Minimal S-mode program (SBI DBCN console output)
├── linux_workspace/                 # Linux kernel build tree (gitignored); Image consumed by merge.py
├── build/triathlon.dtb              # merge.py 生成的 DTB（gitignore 或未跟踪）
├── merge.py                         # 合并 OpenSBI + Linux Image + DTB → fw_combined.bin
├── fw_combined.bin                  # 全系统仿真镜像（加载到 0x80000000）
└── Makefile                         # Top-level build script
```


## Configuration (test_config_pkg)

| Parameter | Value | Description |
|-----------|-------|-------------|
| XLEN | 32 | Integer register width |
| PLEN | 32 | Physical address width |
| INSTR_PER_FETCH | 4 | Fetch/decode/dispatch width |
| NRET | 4 | Retire/commit width |
| RS_DEPTH | 16 | Entries per reservation station |
| ALU_COUNT | 2 | Configured ALU count (actual: 4 ALUs instantiated) |
| FTQ_DEPTH | 8 | Fetch target queue depth |
| ICACHE | 4KB, 4-way, 256-bit line | Instruction cache |
| DCACHE | 4KB, 4-way, 256-bit line | Data cache |

## Microarchitecture

### Pipeline Stages

```
Fetch -> Decode -> Rename -> Dispatch -> Issue -> Execute -> Writeback -> Commit
 (FE)    (BE)     (BE)      (BE)       (BE)     (BE)       (BE)        (BE)
```

### Frontend (frontend.sv)

- **IFU (Instruction Fetch Unit)**: Manages PC register, sends fetch requests to ICache/MMU, interfaces with BPU for next-PC prediction. Incorporates an SV32 MMU for instruction page walks.
- **BPU (Branch Prediction Unit)**: Highly advanced tournament predictor supporting speculative fetching. Components include:
  - **TAGE**: Primary conditional branch predictor.
  - **SC_L (Statistical Correlator)**: Assists TAGE for hard-to-predict branches.
  - **Loop Predictor**: Specialized for loop bounds.
  - **ITTAGE**: Indirect Target TAGE for indirect jumps.
  - **RAS (Return Address Stack)**: Predicts function returns, updated speculatively.
- **ICache**: 4-way set-associative, 4KB, 256-bit line (8 instructions). Non-blocking architecture with refill interface.
- **Fetch Target Queue (FTQ)**: Tracks fetch PCs, epochs, and prediction metadata for branch resolution and redirect recovery.

Frontend outputs: 4 instructions + PC per cycle via valid/ready handshake to the backend IBuffer.

### Backend (backend.sv)

#### Decode
- **IBuffer**: 16-entry FIFO between frontend and decode. Absorbs fetch/decode rate mismatch.
- **Decoder**: 4-wide decode. Converts 32-bit RISC-V instructions into uop_t micro-ops.

#### Rename & Dispatch
- **Rename**: Allocates ROB entries, queries RAT for source register mappings, allocates Store Buffer entries for stores.
- **RAT**: 32-entry register alias table mapping logical registers to ROB indices (speculative) or ARF (committed). Flushed on branch misprediction.
- **Operand Read**: Reads ARF (8 read ports), queries ROB for in-flight results, supports commit-to-rename bypass in the same cycle.
- **FU Demux**: Distributes uops to per-FU issue queues based on fu_type field.

#### Issue
- **ALU RS** (issue.sv): 4-way issue, 16-entry depth. 4 independent ALU outputs.
- **BRU RS** (issue_single.sv): Single issue, 16-entry depth.
- **LSU RS** (issue_lsu.sv): Single issue, coupled with Store Buffer allocation.
- **CSR RS** (issue_single.sv): Single issue, head-of-ROB gated (strict ordering).
- All RS entries snooping CDB for operand forwarding.
- **Backpressure**: Rename stalls if any needed FU's RS lacks free entries.

#### Execute (7 functional units)
- **ALU0-ALU3** (`execute_alu`): Single-cycle integer ALU. Operations: ADD, SUB, SLT, SLTU, XOR, OR, AND, SLL, SRL, SRA, LUI, AUIPC
- **BRU** (uses `execute_alu`): Branch resolution (BEQ/BNE/BLT/BGE/BLTU/BGEU/JAL/JALR). Checks predictions and triggers backend flush on mispredict.
- **LSU Group** (`lsu_group.sv` & `lsu_lane.sv`): Advanced Out-of-Order Load/Store Unit.
  - **MMU**: Incorporates SV32 D-TLB and page walk logic.
  - **Load Queue (LQ) & Store Queue (SQ)**: Tracks in-flight memory operations for OOO execution, memory disambiguation, and load-store forwarding.
  - **Memory Dependence Predictor (MDP)**: Predicts memory aliasing to prevent load-store ordering violations.
  - Supports RISC-V A Extension (`LR`/`SC`) atomic operations.
- **CSR** (`csr.sv`): CSR read/modify/write and exception/interrupt handling. Single-issue, ROB-head ordered.

#### Writeback & CDB
- **Writeback Arbiter** (`writeback.sv`): 7 FU inputs -> 4 CDB ports. Priority arbitration broadcasts execution results.
- **CDB (Common Data Bus)**: Broadcasts (valid, tag, value) to all RS modules for operand wake-up and to the ROB for completion tracking.

#### Commit
- **ROB** (rob.sv): 64-entry circular buffer. In-order retirement, up to 4 per cycle.
  - Stores: 1 per cycle max
  - Branches: 1 per cycle max
  - Loads: 2 per cycle max
- Commits update ARF and clear RAT speculative mappings.
- On misprediction: flush pipeline, redirect frontend.

#### Store Buffer
- 16-entry buffer. LSU fills store data; ROB commit triggers DCache writeback.
- Supports load-to-store forwarding (store buffer hit check before DCache access).

### Cache & Memory Interface

#### ICache (icache.sv)
- 4KB, 4-way set-associative, 256-bit (32-byte) line
- Tag: 18 bits, Index: 8 bits, Offset: 6 bits
- Ports: IFU request/response
- Miss interface: valid/ready handshake to external memory (refill)

#### DCache (dcache.sv)
- 4KB, 4-way set-associative, 256-bit line (same structure as ICache)
- **Load port**: From LSU (ld_req/ld_rsp)
- **Store port**: From Store Buffer (st_req)
- **Miss interface**: valid/ready to external memory (refill)
- **Writeback interface**: valid/ready for dirty line eviction

#### External Memory Interface & Platform
- Custom refill/writeback protocol at the triathlon top level.
- Incorporates AXI wrappers (`icache_axi_wrapper.sv`, `dcache_axi_wrapper.sv`) for system integration.
- Built-in minimal platform peripherals for full-system simulation:
  - **PLIC** (`plic.sv`): Platform-Level Interrupt Controller.
  - **VirtIO Block** (`virtio_blk.sv`): For block device / disk simulation.

### Key Data Structures

#### uop_t (decode_pkg.sv)
```systemverilog
struct packed {
  logic valid, illegal;
  fu_e fu;           // FU_ALU, FU_BRANCH, FU_LSU, FU_MUL, FU_DIV, FU_CSR
  alu_op_e alu_op;
  branch_op_e br_op;
  lsu_op_e lsu_op;
  logic [4:0] rs1, rs2, rd;    // Logical register numbers
  logic has_rs1, has_rs2, has_rd;
  logic [XLEN-1:0] imm;
  logic [PLEN-1:0] pc;
  // Flags: is_load, is_store, is_branch, is_jump, is_csr, is_fence, is_ecall, is_ebreak, is_mret
  logic [11:0] csr_addr;
  csr_op_e csr_op;
}
```

### Frontend-Backend Interface

```
Frontend -> Backend:
  fe_ibuf_valid/ready     (handshake)
  fe_ibuf_instrs [4][32]  (instruction bundle)
  fe_ibuf_pc [32]         (fetch group PC)

Backend -> Frontend:
  backend_flush           (ROB flush signal)
  backend_redirect_pc [32] (redirect target PC)
```

## Build, Test & Toolchain (编译工具链说明)

编译与测试流程基于 `npc/Makefile` 运行。通过 Verilator 编译 SystemVerilog 设计和 C++ 仿真程序。

### 1. 编译与执行目标 (Makefile Targets)

| 目标 (Target) | 常用指令 | 功能描述 |
| :--- | :--- | :--- |
| `default` / `all` | `make` 或 `make all` | 默认目标。编译 SystemVerilog 设计和 C++ 仿真源文件，生成二进制仿真程序 `build/tb_triathlon` |
| `sim` | `make sim` | 编译并直接运行仿真。支持加载二进制镜像并传入仿真参数。 |
| `gdb` | `make gdb` | 编译并在 GDB 调试器中运行仿真可执行文件，方便 C++ 侧的调试。 |
| `profile-report` | `make profile-report` | 运行性能分析（Profiling）脚本 `run_profile.sh`，生成分析数据。 |
| `profile-parse` | `make profile-parse` | 解析性能分析数据，并将结果输出为 Markdown 报告和 JSON 汇总。 |
| `profile-task` | `make profile-task` | 一键执行：先运行性能分析，再解析生成对应的报告（存放在指定 tag 目录下）。|
| `profile-baseline` | `make profile-baseline` | 以 `baseline` 为 tag 运行一键性能分析和解析，生成基准测试报告。 |
| `linux-smoke` | `make linux-smoke` | 运行 Linux 冒烟测试脚本 `run_linux_smoke.sh`。 |
| `clean` | `make clean` | 清理编译生成目录，删除整个 `build` 文件夹。 |

### 2. 常用控制参数/变量 (Configuration Variables)

可以在命令行中通过 `VAR=value` 的形式传入以下变量控制构建和运行：

| 变量名 (Variable) | 默认值 | 作用说明 |
| :--- | :--- | :--- |
| `TOPNAME` | `tb_triathlon` | 指定仿真的顶层模块名（对应 `vsrc/` 目录下的 `.sv` 文件）。 |
| `IMG` | *(空)* | 待运行的程序镜像路径（例如编译好的 RISC-V 测试 bin/elf 文件）。 |
| `ARGS` | *(空)* | 传给仿真器的自定义参数。 |
| `DIFFTEST_SO` | `$(NPC_HOME)/ref/riscv32-nemu-interpreter-so` | DiffTest 动态链接库的路径，用于与 NEMU 进行协同仿真比对。 |

### 3. 典型使用示例

- **编译并运行特定测试镜像（启用 DiffTest）：**
  ```bash
  cd npc
  make sim IMG=/path/to/image.bin
  ```
- **使用特定顶层模块（如 test_top）：**
  ```bash
  cd npc
  make TOPNAME=test_top
  ```
- **运行 CPU Tests 测试套件下的特定测试（如 dummy）：**
  ```bash
  cd am-kernels/tests/cpu-tests
  make ARCH=riscv32i-npc ALL=dummy run
  ```

### 4. OpenSBI + Linux 镜像合并与全系统仿真

`merge.py` 生成的是 **OpenSBI + Linux Kernel Image + DTB** 组合镜像，**不是** `echo_payload/payload.bin`。OpenSBI 通过 `FW_JUMP_ADDR=0x80400000` 跳转到 S-mode Linux 入口，并通过 `FW_JUMP_FDT_ADDR=0x87F00000` 将 DTB 地址传给 Linux 的 `a1`。

#### 内存布局（`fw_combined.bin`）

| 组件 | 物理地址 | 来源 |
| :--- | :--- | :--- |
| OpenSBI (`fw_jump.bin`) | `0x80000000` | `opensbi/build/platform/triathlon/firmware/fw_jump.bin` |
| Linux Kernel Image | `0x80400000` | `linux_workspace/linux/arch/riscv/boot/Image` |
| DTB | `0x87F00000` | `build/triathlon.dtb`（由 `merge.py` 生成） |

仿真器将 `fw_combined.bin` 加载到 `0x80000000`（`npc/csrc/include/platform_contract.h` 中 `kPmemBase`）。OpenSBI 启动 banner 中应出现 `Domain0 Next Arg1 : 0x87f00000`（即 Linux 的 `a1`）。

#### OpenSBI 平台配置（`opensbi/platform/triathlon/`）

| 文件 | 作用 |
| :--- | :--- |
| `objects.mk` | 平台构建参数与 `FW_JUMP` 跳转地址 |
| `platform.c` | PLIC / CLINT / UART8250 等外设初始化 |
| `triathlon.dts` | 设备树源文件（memory、cpu、clint、plic、uart） |
| `configs/defconfig` | Kconfig：`CONFIG_PLATFORM_TRIATHLON=y` |

`objects.mk` 当前关键配置：

```makefile
PLATFORM_RISCV_XLEN = 32
PLATFORM_RISCV_ABI = ilp32
PLATFORM_RISCV_ISA = rv32ima
PLATFORM_RISCV_CODE_MODEL = medlow

FW_JUMP=y
FW_JUMP_ADDR=0x80400000      # OpenSBI 跳转到 Linux 入口
FW_JUMP_FDT_ADDR=0x87F00000  # OpenSBI 传给 Linux 的 a1（DTB 物理地址）
```

修改 `FW_JUMP_FDT_ADDR` 或 `FW_JUMP_ADDR` 后，必须重新编译 OpenSBI 并重新运行 `merge.py`。

#### 工具链

| 用途 | 工具链前缀 | 说明 |
| :--- | :--- | :--- |
| **OpenSBI（Triathlon 平台）** | `riscv64-linux-gnu-` | WSL 下推荐；需支持 PIE（OpenSBI 固件链接要求） |
| **echo_payload / 裸机测试** | `riscv64-unknown-elf-` | 见 `echo_payload/Makefile`；**不能**用于 OpenSBI（linker 不支持 PIE 时会报错） |
| **Verilator 仿真** | 宿主机 `g++` + Verilator 5.008 | 见 `npc/Makefile`；与 OpenSBI 交叉编译无关 |
| **DTB 编译（可选）** | `dtc`（device-tree-compiler） | 有则优先从 `triathlon.dts` 生成 DTB；无则 `merge.py` 使用内置等价 DTB |

OpenSBI 编译示例（WSL）：

```bash
make -C opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-
# 修改 objects.mk 后强制重建：
make -B -C opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-
```

输出：`opensbi/build/platform/triathlon/firmware/fw_jump.bin`

#### 前置条件

- OpenSBI：已用 `riscv64-linux-gnu-` 编译 `fw_jump.bin`（见上）
- Linux：`linux_workspace/linux/arch/riscv/boot/Image` 已编译（`linux_workspace/` 在 `.gitignore` 中）
- DTB：`merge.py` 生成 `build/triathlon.dtb`（优先 `dtc` 编译 `triathlon.dts`，否则脚本内置 DTB）

#### 合并与仿真示例

```bash
# 1. 重建 OpenSBI（修改 objects.mk 后必做）
wsl bash -c "make -C /mnt/e/vivado_project/OOOcpu_design/Triathlon/opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-"

# 2. 合并镜像并仿真
wsl bash -c "cd /mnt/e/vivado_project/OOOcpu_design/Triathlon && python3 merge.py && make -C npc sim IMG=/mnt/e/vivado_project/OOOcpu_design/Triathlon/fw_combined.bin DIFFTEST_SO= ARGS='--max-cycles=2000000 --progress=500000 --linux-early-debug' > npc/sim_final_verify.log 2>&1"
```

#### 流程步骤

1. **编译 OpenSBI**
   - `make -C opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-`
   - 确认 `objects.mk` 中 `FW_JUMP_ADDR` / `FW_JUMP_FDT_ADDR` 与 `merge.py` 中 `LINUX_LOAD_ADDR` / `DTB_LOAD_ADDR` 一致
2. **合并镜像 (`python3 merge.py`)**
   - 读取 `opensbi/build/platform/triathlon/firmware/fw_jump.bin`
   - 读取 `linux_workspace/linux/arch/riscv/boot/Image`
   - 生成 `build/triathlon.dtb`（优先 `dtc` + `triathlon.dts`，否则内置 DTB）
   - 输出 `fw_combined.bin`（布局见上表）
3. **启动 Verilator 仿真 (`make -C npc sim ...`)**
   - **`IMG=...`**: 加载 `fw_combined.bin` 到 `0x80000000`
   - **`DIFFTEST_SO=`**: 置空以禁用 DiffTest（OpenSBI/Linux 涉及 SV32 MMU、特权级 CSR 与外设，bare-metal NEMU 无法对齐）
   - **`--linux-early-debug`**: 启用 Linux 早期启动调试输出（satp 变更、页故障、异常 flush 等），并输出一次性 `[linux-stage]` 里程碑（pc/inst/a0/a1/sp/gp/satp/CSR 等），由 `npc/csrc/include/linux_boot_stage.h` 实现
   - **`--commit-trace`**: 可选，输出 commit 级 trace（`[commit]` / `[stwb]` / `[ldreq]` / `[ldrsp]` / `[flush]` / `[bru]` / `[flushp]`）；默认全周期。可限定窗口（窗口外上述 trace 均不打印，profile 统计仍全程收集）：
     - `--commit-trace START:END` 或 `--commit-trace=START:END`（含首尾 cycle）
     - `--commit-trace START END`（两个参数）
     - `--commit-trace-start N` + `--commit-trace-end N`（`end=0` 表示不设上限）

#### `--linux-early-debug` 启动阶段标记

启用 `--linux-early-debug` 后，仿真器对每个关键阶段仅打印一次 `[linux-stage]` 行，典型顺序：

| stage | 含义 |
| :--- | :--- |
| `opensbi-reset` | M-mode 复位入口 @ 0x80000000 |
| `opensbi-dtb-a0` | OpenSBI 将 DTB 地址装入 a0 |
| `opensbi-init` | OpenSBI 固件主路径 |
| `opensbi-pre-jump` | 跳转 Linux 前 (hart_switch_mode) |
| `linux-handoff` | 进入 Linux S-mode 物理入口 |
| `linux-head` / `linux-decompress` / `linux-gp-init` | head.S / 解压 / gp 初始化 |
| `linux-dtb-a1` | Linux 收到 a1=DTB |
| `linux-mmu-enable` | 写 satp 开启 SV32 |
| `linux-first-ipf` | 开 MMU 后首次 instruction page fault |
| `linux-trap-redirect` / `linux-trap-vec` | fixmap trap 入口 |
| `linux-swap-pgdir` | trap 路径切换页表 |
| `linux-vtext` | 进入内核高地址虚拟文本区 |

#### echo_payload（可选，独立测试）

`echo_payload/` 是轻量级 S-mode 程序（通过 SBI DBCN 打印一行字符串后自旋），**不参与** `merge.py` 流程。若需单独验证 OpenSBI 跳转到最小 payload，需自行修改 `merge.py` 或手动将 `payload.bin` 拼接到 OpenSBI 之后，并确保链接地址为 `0x80400000`。

---

Simulator: Verilator 5.008 + GTKWave. Target: RISC-V 32-bit (riscv32i-npc).