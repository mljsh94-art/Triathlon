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
├── opensbi/                         # OpenSBI firmware (RISC-V Supervisor Binary Interface)
├── echo_payload/                    # S-mode test payload (uses SBI DBCN extension to print console)
│   ├── Makefile                     # Build system for payload
│   ├── link.ld                      # Linker script (links at 0x80400000)
│   └── payload.S                    # S-mode payload assembly source
├── merge.py                         # Python script to pad OpenSBI (to 4MB) and append the payload
├── fw_combined.bin                  # Combined image loaded during full-system simulation
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

### 4. S-mode Payload 编译合并与 Trace 仿真流程 (OpenSBI + S-mode Payload)

当需要运行 S-mode 测试程序（通过 OpenSBI 引导）并导出详细的仿真轨迹（Commit Trace）进行 Debug 时，可使用以下一整套流水线命令：

```bash
wsl bash -c "cd echo_payload && make && cd .. && python3 merge.py && make -C npc sim IMG=/mnt/e/vivado_project/OOOcpu_design/Triathlon/fw_combined.bin DIFFTEST_SO= ARGS='--commit-trace --max-cycles=10000000' > npc/sim_trace.log 2>&1"
```

#### 流程步骤详细解析：

1. **编译 Payload (`cd echo_payload && make && cd ..`)**
   - 进入 `echo_payload` 目录，编译汇编源码 `payload.S`（通常使用 SBI 的 `DBCN` 扩展进行控制台字符打印）。
   - 编译后生成裸二进制文件 `payload.bin` 并返回项目主目录。
2. **合并固件与 Payload (`python3 merge.py`)**
   - 运行 Python 脚本，读取 OpenSBI 固件二进制文件 `opensbi/build/platform/triathlon/firmware/fw_jump.bin`。
   - 对 OpenSBI 固件填充（Pad）零字节至 `0x400000` (4MB) 大小，然后追加 `payload.bin`。
   - 生成完整的系统引导镜像 `fw_combined.bin`。这使得 S-mode payload 正好位于物理地址 `0x80400000`，即 OpenSBI 跳转启动的默认负载地址。
3. **启动 Verilator RTL 仿真并重定向日志 (`make -C npc sim ... > npc/sim_trace.log 2>&1`)**
   - **`IMG=...`**: 指定加载上述合并生成的 `fw_combined.bin` 镜像。
   - **`DIFFTEST_SO=`**: **置空此变量以禁用 DiffTest 协同仿真**。由于 S-mode 程序及 OpenSBI 涉及大量的特权级 CSR 寄存器切换、内存分页 (SV32 MMU) 机制以及特定的平台外设操作，普通的 bare-metal DiffTest 解释器（如 NEMU）无法与 RTL 设计严格对齐。
   - **`ARGS='--commit-trace --max-cycles=10000000'`**:
     - `--commit-trace`: 开启指令提交级的 Trace 输出，详尽记录每一步指令流执行（PC、GPR 写入等），方便进行指令流追踪。
     - `--max-cycles=10000000`: 限制仿真最大时钟周期为 1000 万周期，防止死锁、挂死或产生超大型无限增长的日志文件。
   - **`> npc/sim_trace.log 2>&1`**: 将所有仿真器的标准输出和错误信息重定向至 `npc/sim_trace.log`，以便后续离线分析 CPU 执行轨迹。

---

Simulator: Verilator 5.008 + GTKWave. Target: RISC-V 32-bit (riscv32i-npc).