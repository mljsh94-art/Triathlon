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
│   │   └── sv32_mmu.sv              # RISC-V SV32 Paging MMU with TLB/context flush handling
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
- **Decoder**: 4-wide decode. Converts 32-bit RISC-V instructions into uop_t micro-ops. Illegal instructions are routed to the CSR FU so they retire as precise illegal-instruction traps.

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
  - **MMU**: Incorporates SV32 D-TLB and page walk logic; SATP/SFENCE.VMA changes invalidate TLB state and abort in-flight walks. Routine non-synthesis page-fault diagnostics (`[mmu-pf-l0]`, `[mmu-pf-l1]`, `[mmu-pf-tlb]`) are disabled to avoid flooding Linux boot logs.
  - **Load Queue (LQ) & Store Queue (SQ)**: Tracks in-flight memory operations for OOO execution, memory disambiguation, and load-store forwarding.
  - **Memory Dependence Predictor (MDP)**: Predicts memory aliasing to prevent load-store ordering violations.
  - Supports RV32A word atomic operations (`LR.W`/`SC.W`, `AMOSWAP.W`, `AMOADD.W`, `AMOXOR.W`, `AMOAND.W`, `AMOOR.W`, `AMOMIN.W`, `AMOMAX.W`, `AMOMINU.W`, `AMOMAXU.W`) through a conservative LSU read-modify-write sequence.
- **CSR** (`csr.sv`): CSR read/modify/write and exception/interrupt handling. Single-issue, ROB-head ordered. CSR/system exceptions are reported to the ROB first, then applied through the commit-time trap injection path so trap CSRs and `mstatus.MPP`/`SPP` are updated precisely once. `satp` exposes SV32 mode and PPN fields with ASIDLEN=0; ASID bits are WARL-masked to zero because the current TLB is not ASID-tagged.

#### Writeback & CDB
- **Writeback Arbiter** (`writeback.sv`): 7 FU inputs -> 4 CDB ports. Priority arbitration broadcasts execution results.
- **CDB (Common Data Bus)**: Broadcasts (valid, tag, value) to all RS modules for operand wake-up and to the ROB for completion tracking.

#### Commit
- **ROB** (rob.sv): 64-entry circular buffer. In-order retirement, up to 4 per cycle.
  - Stores raw and decoded instruction words for each uop and exports retired instruction metadata to the simulator.
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
  logic [31:0] inst, raw_inst;       // Decoded 32-bit instruction and raw retired encoding
  fu_e fu;           // FU_ALU, FU_BRANCH, FU_LSU, FU_MUL, FU_DIV, FU_CSR
  alu_op_e alu_op;
  branch_op_e br_op;
  lsu_op_e lsu_op;
  amo_op_e amo_op;
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
| `bench` | `make bench BENCH_IMG=...` | 使用当前仿真器执行固定镜像并打印墙钟耗时，便于对比仿真速度。 |
| `clean` | `make clean` | 清理编译生成目录，删除整个 `build` 文件夹。 |

### 2. 常用控制参数/变量 (Configuration Variables)

可以在命令行中通过 `VAR=value` 的形式传入以下变量控制构建和运行：

| 变量名 (Variable) | 默认值 | 作用说明 |
| :--- | :--- | :--- |
| `TOPNAME` | `tb_triathlon` | 指定仿真的顶层模块名（对应 `vsrc/` 目录下的 `.sv` 文件）。 |
| `IMG` | *(空)* | 待运行的程序镜像路径（例如编译好的 RISC-V 测试 bin/elf 文件）。 |
| `ARGS` | *(空)* | 传给仿真器的扩展参数，详见 **§4**。 |
| `DIFFTEST_SO` | `$(NPC_HOME)/ref/riscv32-nemu-interpreter-so` | DiffTest 动态链接库的路径，用于与 NEMU 进行协同仿真比对。 |
| `VL_THREADS` | `2` | Verilator 多线程仿真线程数；当前设计在 Verilator 5.008 下 4 线程会出现 `UNOPTTHREADS`，需要时可手动调整。 |
| `VL_JOBS` | `$(nproc)` | Verilator/host C++ 并行编译任务数。 |
| `VL_OPTFLAGS` | `-O3 -march=native -fno-plt` | 传给 Verilator generated make 的 `OPT_FAST` / `OPT_SLOW` / `OPT_GLOBAL` 与 host C++ 的默认优化参数。 |
| `VL_OPTLEVEL` | `-O3` | 通过 Verilator `-MAKEFLAGS` 覆盖 generated make 的默认 `-Os`，确保 generated C++ 以 `-O3` 编译。 |
| `DEBUG` | `0` | 设为 `1` 时使用 `-O0 -g` 编译 host 仿真器，默认使用 `-O3 -march=native`。 |
| `BENCH_IMG` | `$(IMG)` | `bench` 目标运行的镜像路径。 |
| `BENCH_ARGS` | `--max-cycles=10000000 --progress=0` | `bench` 目标传给仿真器的参数。 |

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

### 4. 仿真器命令行扩展参数（`ARGS`）

仿真主程序为 `npc/build/tb_triathlon`，参数解析见 `npc/csrc/lib/args_parser.cpp` 与 `npc/csrc/include/args_parser.h`。

#### 传参方式

```bash
# Makefile（推荐）：ARGS 与 Makefile 变量 DIFFTEST 一并拼入命令行
make -C npc sim IMG=/path/to/image.bin ARGS='--max-cycles=1000000 --progress=500000'
make -C npc sim DIFFTEST= IMG=/path/to/fw_combined.bin ARGS='--linux-early-debug'  # 禁用 DiffTest

# 直接运行
./npc/build/tb_triathlon /path/to/image.bin --max-cycles=1000000
```

Makefile 拼装顺序：`ARGS` → DiffTest（`-d $(DIFFTEST_SO)`，当库文件存在且未设 `DIFFTEST=`）→ `IMG`（ positional，镜像路径）。Positional 参数 `<IMG>` 为**必需**。

#### 参数一览

| 参数 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `<IMG>` | — | 待加载二进制镜像路径（positional，必需） |
| `--max-cycles N` / `--max-cycles=N` | `600000000` | 最大仿真周期；超出后打印 `TIMEOUT after N cycles` 并以退出码 1 结束 |
| `-d REF_SO` / `--difftest=REF_SO` | Makefile 自动注入 | NEMU DiffTest 共享库；`DIFFTEST_SO=` 或 `DIFFTEST=` 可禁用 |
| `--progress [N]` / `--progress=N` | 禁用；仅 `--progress` 时 `N=1000000` | 每 `N` 周期打印轻量 `[progress]` 心跳（cycles、commits、IPC、last_pc 等） |
| `--progress-verbose` | 禁用 | 将 `[progress]` 扩展为详细快照（ROB、Store Buffer、LSU、DCache MSHR 等）；`--linux-early-debug` 也会启用详细进度输出。 |
| `--trace [path]` / `--trace=path` | 默认 `npc.vcd` | 生成 VCD 波形；需编译时定义 `VM_TRACE`，否则忽略并打印 `[warn]` |
| `--commit-trace [窗口]` | 禁用 | 启用 commit 级 trace 与仿真结束 profile 汇总（见下文「输出 Tag」） |
| `--commit-trace=START:END` | — | 等价于 `--commit-trace START:END` |
| `--commit-trace-start N` | `0` | 与 `--commit-trace` 配合：trace 起始 cycle（含） |
| `--commit-trace-end N` | `0`（无上限） | 与 `--commit-trace` 配合：trace 结束 cycle（含）；`0` 表示不设上限 |
| `--bru-trace` | 禁用 | BRU writeback trace（`[bruwb]`）+ pipeline flush trace（`[flush]`/`[flushp]`/`[bru]`，**无** cycle 窗口限制）+ profile 汇总 |
| `--fe-trace` | 禁用 | 取指校验：前端 bundle 与内存指令不一致，或 slot_valid 不完整时打印 `[fe]` |
| `--stall-trace [N]` / `--stall-trace=N` | 禁用；`N=200` | 连续 `N` 周期无 commit 时打印 `[stall]`，之后每再 stall `N` 周期重复打印 |
| `--boot-handoff` | 禁用 | Boot ROM handoff 启动链（见下文） |
| `--dtb <path>` / `--dtb=path` | 内置最小 FDT | `--boot-handoff` 下加载外部 DTB；省略则在 `0x83F00000` 写入占位 FDT |
| `--firmware-load-base <addr>` / `=addr` | `0x80020000`（OpenSBI 区） | `--boot-handoff` 下固件加载基址；须 **4MiB 对齐**（RV32 Linux `setup_vm()` 要求），推荐 `0x80400000`；不得与复位 PC `0x80000000` 重叠 |
| `--virtio-blk-image <path>` / `=path` | 无 | VirtIO block 后端磁盘镜像 |
| `--linux-early-debug` | 禁用 | Linux/OpenSBI 早期启动调试：一次性 `[linux-stage]` 里程碑 + 条件 `[debug][...]` 细粒度日志 |

#### `--commit-trace` 窗口语法

窗口仅抑制 stdout 上的 commit/LSU/store trace 以及（在与 `--bru-trace` 同开时）`[flush]`/`[flushp]`/`[bru]`；**profile 汇总统计仍全程收集**。

| 写法 | 含义 |
| :--- | :--- |
| `--commit-trace` | 全周期 |
| `--commit-trace START:END` 或 `--commit-trace=START:END` | cycle `[START, END]`（含首尾） |
| `--commit-trace START` | 单点 cycle `START` |
| `--commit-trace START END` | 两个 positional：`START` 与 `END` |
| `--commit-trace-start N` + `--commit-trace-end M` | 分别指定起止；`end=0` 无上限 |

#### 镜像加载模式

| 模式 | 条件 | 行为 |
| :--- | :--- | :--- |
| **整镜像加载**（默认） | 无 `--boot-handoff` | `<IMG>` 加载到 `0x80000000`（`kPmemBase`）；适用于 `merge.py` 输出的 `fw_combined.bin` |
| **Boot handoff** | `--boot-handoff` | `<IMG>` 加载到 `--firmware-load-base`；在 `0x00001000` 安装 handoff stub（a0/a1/satp → 跳固件），复位 PC `0x80000000` 经 jump stub 进入 boot ROM；适用于 `fw_payload.bin` + 独立 DTB（见 `linux-smoke`） |

#### 输出 Tag 速查

| Tag | 触发条件 | 内容 |
| :--- | :--- | :--- |
| `[commit]` | `--commit-trace`（窗口内） | ROB retire：slot、pc、inst、we、rd、wdata、a0 |
| `[stwb]` | `--commit-trace`（窗口内） | Store Buffer → DCache 写：`addr`、`data`、`op` |
| `[ldreq]` / `[ldrsp]` | `--commit-trace`（窗口内） | LSU load 请求 / 响应：addr、tag、data、err |
| `[flush]` | `--commit-trace`（窗口内）或 `--bru-trace` | Pipeline flush：reason、src_pc、redirect_pc、BPU RAS、miss 分类 |
| `[flushp]` | 同上 | flush 后首个有 commit 的 cycle：惩罚周期数 |
| `[bru]` | 同上（flush 同拍且 BRU mispred） | BRU 执行细节 |
| `[bruwb]` | `--bru-trace` | 每拍 BRU writeback 有效：pc、操作数、redirect、mispred |
| `[fe]` | `--fe-trace` | 取指 PC、slot_valid、FE/内存指令 mismatch、预测 NPC |
| `[stall]` | `--stall-trace` | 无 commit stall：前端/IFU/解码/rename/ROB/LSU 等快照 |
| `[progress]` | `--progress` | 周期性仿真心跳 |
| `[linux-stage]` | `--linux-early-debug` | 启动里程碑（每 stage 仅一次，见下表） |
| `[debug][...]` | `--linux-early-debug` | satp 变更、页表写、异常 flush、UART 等细粒度调试 |
| `[commitm]` / `[controlm]` / `[stallm]` / `[stallm2]`–`[stallm6]` / `[ifum]` / `[pred  ]` / `[hotpcm]` / `[hotinstm]` | `--commit-trace` 或 `--bru-trace` | 仿真结束由 `ProfileCollector` 输出的汇总（commit 宽度、控制流、stall 分类、IFU FQ、BPU 命中率、热 PC/指令等） |
| `HIT GOOD TRAP` / `HIT BAD TRAP` | — | AM 测试 `ebreak`：a0=0 成功 / 非 0 失败 |
| `IPC=` / `CPI=` | — | 成功 trap 或超时前输出的性能指标 |

#### `--linux-early-debug` 启动阶段标记

启用后，每个关键阶段仅打印一次 `[linux-stage]` 行（含 cycle、pc、inst、priv、satp、CSR、a0/a1/sp/gp 等），典型顺序：

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

实现：`npc/csrc/include/linux_boot_stage.h`。

#### 常用组合示例

```bash
# AM 基准测试 + profile（run_profile.sh 默认组合）
make -C npc sim DIFFTEST= IMG=.../dhrystone-riscv32i-npc.bin \
  ARGS='--commit-trace --bru-trace --stall-trace=100 --progress=50000'

# 限定 commit trace 窗口
make -C npc sim IMG=.../test.bin ARGS='--commit-trace 100000:150000'

# merge.py 全系统镜像 + 早期调试
make -C npc sim DIFFTEST_SO= IMG=../fw_combined.bin \
  ARGS='--max-cycles=2000000 --progress=500000 --linux-early-debug'

# Boot handoff + VirtIO（linux-smoke 风格）
make -C npc sim DIFFTEST= IMG=~/rv32-linux/out/fw_payload.bin \
  ARGS='--boot-handoff --dtb ~/rv32-linux/out/npc.dtb \
        --virtio-blk-image ~/rv32-linux/out/rootfs.img \
        --firmware-load-base 0x80400000 --max-cycles=80000000 --progress=0'

# 波形（需 VM_TRACE 构建）
make -C npc sim IMG=.../test.bin ARGS='--trace wave.vcd --max-cycles=50000'
```

### 5. OpenSBI + Linux 镜像合并与全系统仿真

`merge.py` 生成的是 **OpenSBI + Linux Kernel Image + DTB** 组合镜像，**不是** `echo_payload/payload.bin`。OpenSBI 通过 `FW_JUMP_ADDR=0x80400000` 跳转到 S-mode Linux 入口，并通过 `FW_JUMP_FDT_ADDR=0x83F00000` 将 DTB 地址传给 Linux 的 `a1`。设备树当前向 Linux 报告 64MB 可见内存（`0x80000000`–`0x83FFFFFF`），用于降低全系统仿真的 early memory/per-CPU 初始化成本。

#### 内存布局（`fw_combined.bin`）

| 组件 | 物理地址 | 来源 |
| :--- | :--- | :--- |
| OpenSBI (`fw_jump.bin`) | `0x80000000` | `opensbi/build/platform/triathlon/firmware/fw_jump.bin` |
| Linux Kernel Image | `0x80400000` | `linux_workspace/linux/arch/riscv/boot/Image` |
| DTB | `0x83F00000` | `build/triathlon.dtb`（由 `merge.py` 生成） |

仿真器将 `fw_combined.bin` 加载到 `0x80000000`（`npc/csrc/include/platform_contract.h` 中 `kPmemBase`）。OpenSBI 启动 banner 中应出现 `Domain0 Next Arg1 : 0x83f00000`（即 Linux 的 `a1`）。

#### OpenSBI 平台配置（`opensbi/platform/triathlon/`）

| 文件 | 作用 |
| :--- | :--- |
| `objects.mk` | 平台构建参数与 `FW_JUMP` 跳转地址 |
| `platform.c` | PLIC / CLINT / UART8250 等外设初始化 |
| `triathlon.dts` | 设备树源文件（memory、cpu、clint、plic、uart） |
| `configs/defconfig` | Kconfig：`CONFIG_PLATFORM_TRIATHLON=y` |

设备树中的 PLIC 仅向 Linux 暴露 S-mode external interrupt context（`interrupts-extended = <&cpu0_intc 9>`），与仿真平台当前单 context PLIC MMIO 布局保持一致。

`objects.mk` 当前关键配置：

```makefile
PLATFORM_RISCV_XLEN = 32
PLATFORM_RISCV_ABI = ilp32
PLATFORM_RISCV_ISA = rv32imac
PLATFORM_RISCV_CODE_MODEL = medlow

FW_JUMP=y
FW_JUMP_ADDR=0x80400000      # OpenSBI 跳转到 Linux 入口
FW_JUMP_FDT_ADDR=0x83F00000  # OpenSBI 传给 Linux 的 a1（DTB 物理地址）
```

修改 `FW_JUMP_FDT_ADDR` 或 `FW_JUMP_ADDR` 后，必须重新编译 OpenSBI 并重新运行 `merge.py`。

#### 工具链

| 用途 | 工具链前缀 | 说明 |
| :--- | :--- | :--- |
| **OpenSBI（Triathlon 平台）** | `riscv64-linux-gnu-` | WSL 下推荐；需支持 PIE（OpenSBI 固件链接要求） |
| **echo_payload / 裸机测试** | `riscv64-unknown-elf-` | 见 `echo_payload/Makefile`；**不能**用于 OpenSBI（linker 不支持 PIE 时会报错） |
| **Verilator 仿真** | 宿主机 `g++` + Verilator 5.008 | 见 `npc/Makefile`；与 OpenSBI 交叉编译无关 |
| **DTB 编译（可选）** | `dtc`（device-tree-compiler） | 有则优先从 `triathlon.dts` 生成 DTB；无则 `merge.py` 使用内置等价 DTB |

编译命令与参数见下方 **OpenSBI / Linux 编译流程与参数**。

#### OpenSBI / Linux 编译流程与参数

全系统镜像由三路输入经 `merge.py` 合并后交给 Verilator 仿真：

```
OpenSBI (fw_jump.bin) ──┐
Linux   (Image)       ──┼── merge.py ── fw_combined.bin ── make -C npc sim
DTB     (triathlon.dts)─┘
```

##### 何时需要重编

| 修改内容 | 需要重编 | 需要重跑 merge.py |
| :--- | :--- | :--- |
| `opensbi/platform/triathlon/objects.mk` | OpenSBI | 是 |
| `opensbi/platform/triathlon/triathlon.dts` | 否（merge 时编 DTB） | 是 |
| `opensbi/platform/triathlon/platform.c` | OpenSBI | 是 |
| Linux 源码 / `.config` / 临时验证补丁 | Linux `Image` | 是 |
| RTL / `npc/csrc` / 仿真参数 | `make -C npc` | 否 |

##### OpenSBI 编译

| Make 变量 | 值 | 说明 |
| :--- | :--- | :--- |
| `PLATFORM` | `triathlon` | 平台目录 `opensbi/platform/triathlon/` |
| `CROSS_COMPILE` | `riscv64-linux-gnu-` | 工具链前缀；目标 XLEN 由 `objects.mk` 中 `PLATFORM_RISCV_XLEN=32` 决定 |

```bash
make -C opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-
# 修改 objects.mk 后强制重建：
make -B -C opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-
```

输出：`opensbi/build/platform/triathlon/firmware/fw_jump.bin`

##### Linux 内核编译

Linux 工作树位于 `linux_workspace/linux/`（`.gitignore` 中）。工具链前缀为 `riscv64-linux-gnu-`，但内核配置为 **RV32**（`CONFIG_32BIT=y`），与 Triathlon RTL 的 32 位 ISA 一致；banner 中出现 `riscv64-linux-gnu-gcc` 不代表 64 位内核。

| Make 变量 | 值 | 说明 |
| :--- | :--- | :--- |
| `ARCH` | `riscv` | 必传 |
| `CROSS_COMPILE` | `riscv64-linux-gnu-` | 与 OpenSBI 相同前缀 |
| 目标 | `Image` | 输出裸内核镜像，非 `vmlinux` ELF |

```bash
# 首次配置（可选起点：arch/riscv/configs/rv32_defconfig）
make -C linux_workspace/linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- rv32_defconfig
make -C linux_workspace/linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- menuconfig

# 编译内核镜像
make -C linux_workspace/linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) Image
```

输出：`linux_workspace/linux/arch/riscv/boot/Image`

关键 Kconfig（须与 Triathlon RV32 + SV32 对齐）：

| 选项 | 典型值 | 说明 |
| :--- | :--- | :--- |
| `CONFIG_32BIT` | `y` | 32 位 RISC-V 内核 |
| `CONFIG_ARCH_RV32I` | `y` | RV32I 基座 |
| `CONFIG_PAGE_OFFSET` | `0xC0000000` | 内核虚拟地址起点 |
| `CONFIG_RISCV_ISA_C` | `y` | 压缩指令（与 RTL 一致） |
| `CONFIG_INITRAMFS_SOURCE` | `../rootfs` | 内置 initramfs 根文件系统 |
| `CONFIG_INITRAMFS_COMPRESSION_NONE` | `y` | initramfs 不压缩，减少 gzip 解压热点在 RTL 仿真中的启动开销 |

启动命令行（`CONFIG_CMDLINE` 或 bootargs）常用：`earlycon=sbi console=ttyS0 root=/dev/ram0`（initramfs 根文件系统）。

精简配置原则：单核 RV32、SBI、PLIC、RISC-V timer、OF/DT、8250/SBI earlycon、initramfs、`proc`/`sysfs`/`tmpfs`；关闭通用 RISC-V 板卡驱动、块设备驱动、图形/输入/USB/MMC/RTC、非必要文件系统以及 debug/trace 开销。当前 `build_kernel.sh` 使用 `allnoconfig` + `.triathlon_min.config` 最小配置片段生成内核配置，只保留 RV32/SV32、SBI、DT、8250 控制台、内置 initramfs、ELF/script 执行和 `proc`/`sysfs`/`devtmpfs`/`tmpfs`；脚本末尾会检查并拒绝 `NET`、`BLOCK`、`PCI`、`CGROUPS`、`BPF`、`PERF`、`KALLSYMS`、`FTRACE`、`CRYPTO`、`INPUT`、`PINCTRL`、`USB`、`MMC`、`RTC`、`THERMAL`、`VIRTIO`、`FW_LOADER`、`PM`、`IO_URING` 等无关子系统被重新选中。`CONFIG_DEBUG_KERNEL` 是调试菜单总开关，`allnoconfig` 下可能保持为 `y`，但具体 debug/ftrace/debug-info 子项保持关闭。

##### merge.py 参数

脚本顶部常量（须与 `objects.mk` 中 `FW_JUMP_*` 保持一致）：

| 变量 | 值 | 说明 |
| :--- | :--- | :--- |
| `PMEM_BASE` | `0x80000000` | 仿真器加载 `fw_combined.bin` 的物理基址 |
| `PMEM_SIZE` | `0x08000000` | 物理内存窗口大小（128MB） |
| `LINUX_LOAD_ADDR` | `0x80400000` | 对应 `FW_JUMP_ADDR` |
| `DTB_LOAD_ADDR` | `0x83F00000` | 对应 `FW_JUMP_FDT_ADDR` |
| `LINUX_VISIBLE_MEM_SIZE` | `0x04000000` | DTB 向 Linux 报告的可见内存（64MB） |

输入/输出路径：

| 路径 | 角色 |
| :--- | :--- |
| `opensbi/build/platform/triathlon/firmware/fw_jump.bin` | OpenSBI 输入 |
| `linux_workspace/linux/arch/riscv/boot/Image` | Linux 输入 |
| `opensbi/platform/triathlon/triathlon.dts` | DTB 源（有 `dtc` 时编译） |
| `build/triathlon.dtb` | 生成的 DTB |
| `fw_combined.bin` | 合并输出 |

```bash
python3 merge.py
```

##### 完整构建示例（WSL）

```bash
# 1. OpenSBI
make -C opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-

# 2. Linux
make -C linux_workspace/linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) Image

# 3. 合并
python3 merge.py

# 4. 仿真
make -C npc sim DIFFTEST_SO= IMG=../fw_combined.bin \
  ARGS='--max-cycles=100000000 --progress=1000000 --linux-early-debug'
```

#### Linux 非对齐访问探测临时补丁

当前 RTL 能对非对齐 load/store 产生异常，但 Linux 早期启动中的 `check_unaligned_access()` 会主动执行非对齐 word copy 来探测硬件能力；现阶段该探测会触发 `load address misaligned` panic，阻塞后续 boot 验证。Linux 工作树可在 `linux_workspace/linux/arch/riscv/kernel/cpufeature.c` 中临时关闭该探测：`check_unaligned_access()` 直接将 `misaligned_access_speed` 标记为 `RISCV_HWPROBE_MISALIGNED_SLOW` 并返回，不再调用 `__riscv_copy_words_unaligned()`。

该补丁仅用于绕过启动阶段的硬件能力 probe。RTL LSU 支持非对齐访存，或 Linux 异常路径能稳定模拟/恢复非对齐访问后，应恢复原始 `check_unaligned_access()` 探测逻辑，并重新编译 `Image`。

#### 合并与仿真示例

```bash
# 1. 重建 OpenSBI（修改 objects.mk 后必做）
wsl bash -c "make -C /mnt/e/vivado_project/OOOcpu_design/Triathlon/opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-"

# 2. 重建 Linux（修改内核源码/.config/临时补丁后必做）
wsl bash -c "make -C /mnt/e/vivado_project/OOOcpu_design/Triathlon/linux_workspace/linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) Image"

# 3. 合并镜像并仿真
wsl bash -c "cd /mnt/e/vivado_project/OOOcpu_design/Triathlon && python3 merge.py && make -C npc sim IMG=/mnt/e/vivado_project/OOOcpu_design/Triathlon/fw_combined.bin DIFFTEST_SO= ARGS='--max-cycles=100000000 --progress=1000000 --linux-early-debug' > npc/sim_final_verify.log 2>&1"
```

#### 流程步骤

1. **编译 OpenSBI**
   - `make -C opensbi PLATFORM=triathlon CROSS_COMPILE=riscv64-linux-gnu-`
   - 确认 `objects.mk` 中 `FW_JUMP_ADDR` / `FW_JUMP_FDT_ADDR` 与 `merge.py` 中 `LINUX_LOAD_ADDR` / `DTB_LOAD_ADDR` 一致
2. **编译 Linux**
   - `make -C linux_workspace/linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) Image`
   - 确认 `.config` 中 `CONFIG_32BIT=y`（RV32 内核，非 64 位）
3. **合并镜像 (`python3 merge.py`)**
   - 读取 `opensbi/build/platform/triathlon/firmware/fw_jump.bin`
   - 读取 `linux_workspace/linux/arch/riscv/boot/Image`
   - 生成 `build/triathlon.dtb`（优先 `dtc` + `triathlon.dts`，否则内置 DTB）
   - 输出 `fw_combined.bin`（布局见上表）
4. **启动 Verilator 仿真 (`make -C npc sim ...`)**
   - **`IMG=...`**: 加载 `fw_combined.bin` 到 `0x80000000`
   - **`DIFFTEST_SO=`**: 置空以禁用 DiffTest（OpenSBI/Linux 涉及 SV32 MMU、特权级 CSR 与外设，bare-metal NEMU 无法对齐）
   - 仿真扩展参数见 **§4 仿真器命令行扩展参数**（常用：`--max-cycles`、`--progress`、`--linux-early-debug`、`--commit-trace` 等）

#### echo_payload（可选，独立测试）

`echo_payload/` 是轻量级 S-mode 程序（通过 SBI DBCN 打印一行字符串后自旋），**不参与** `merge.py` 流程。若需单独验证 OpenSBI 跳转到最小 payload，需自行修改 `merge.py` 或手动将 `payload.bin` 拼接到 OpenSBI 之后，并确保链接地址为 `0x80400000`。

---

Simulator: Verilator 5.008 + GTKWave. Target: RISC-V 32-bit (riscv32i-npc).