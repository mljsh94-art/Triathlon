# Triathlon - Out-of-Order RISC-V CPU

> **DOCUMENTATION RULES**
>
> - Update **this file** after architecture or layout changes; update **`docs/`** for operational detail.
> - Keep **architecture, module roles, and stable config** here; do not add change logs or history.
> - New runbooks and CLI reference belong in **`docs/`** (Chinese); add an index row in [Documentation Index](#documentation-index).

## Project Overview

Triathlon is a **4-wide superscalar out-of-order RISC-V RV32IMAC processor** (Tomasulo + in-order retire). SystemVerilog RTL, simulated with **Verilator 5.008**. Target AM arch: **riscv32im-npc**.

## Source Layout

| Path | Role |
|------|------|
| `npc/vsrc/` | RTL: `triathlon.sv`, frontend, backend, cache, mmu, platform, testbenches |
| `npc/vsrc/frontend/` | IFU, BPU, ICache hookup, instr aligner, ibuffer, FTQ |
| `npc/vsrc/backend/` | Decode, rename, issue, exu (ALU/CSR), lsu, retire (ROB) |
| `npc/vsrc/backend/exu/` | ALU, CSR |
| `npc/vsrc/backend/lsu/` | `lsu_group`, agu/mmu/arbiter, `ld_pipe`, `ldq`, `stq` |
| `npc/vsrc/cache/` | I/D cache, AXI wrappers, SRAM primitives |
| `npc/vsrc/include/` | Packages (`decode_pkg`, `test_config_pkg`, `sim_assert.sv`, …) |
| `npc/csrc/` | Verilator host: `npc_main.cpp`, args, DiffTest client, sim observer |
| `npc/ref/` | Spike DiffTest shared library |
| `npc/tools/profiler/` | Profile collection and dashboard scripts |
| `am-kernels/` | Tests and benchmarks |
| `abstract-machine/` | Bare-metal runtime |
| `opensbi/platform/triathlon/` | OpenSBI platform port |
| `linux_workspace/` | Linux build scripts, `merge.py` |
| `fw_combined.bin` | Prebuilt full-system image @ `0x80000000` |

Key RTL tops: `frontend.sv`, `backend.sv`, `ifu.sv`, `bpu.sv`, `instr_aligner.sv`, `ibuffer.sv`, `rob.sv`, `alu.sv`, `csr.sv`, `lsu_group.sv`, `lsu_agu.sv`, `lsu_mmu.sv`, `lsu_arbiter.sv`, `ldq.sv`, `ld_pipe.sv`, `stq.sv`, `icache.sv`, `dcache.sv`.

## Configuration (`test_config_pkg`)

| Parameter | Value | Description |
|-----------|-------|-------------|
| XLEN | 32 | Integer width |
| PLEN | 32 | Physical address width |
| INSTR_PER_FETCH | 4 | Fetch/decode/dispatch width |
| NRET | 4 | Retire width |
| SB_DEPTH | 32 | STQ entries |
| ROB_MAX_COMMIT_ST | 2 | Max store commits per cycle |
| RS_DEPTH | 16 | Reservation station entries per FU queue |
| ALU_COUNT | 2 | Config value (4 ALUs instantiated) |
| BPU_BTB_ENTRIES (FTB) | 1024 | Fetch-target buffer (4 slots/block) |
| FTQ_DEPTH | 32 | BPU→IFU fetch target queue |
| ICACHE / DCACHE | 32KB, 4-way, 256-bit line | L1 caches |
| ITLB / DTLB | 32 entries | SV32 TLBs |

## Microarchitecture

### Pipeline

```
Fetch -> Decode -> Rename -> Dispatch -> Issue -> Execute -> Writeback -> Commit
 (FE)    (BE)     (BE)      (BE)       (BE)     (BE)       (BE)        (BE)
```

**FE/BE boundary:** ibuffer dequeue (`fe_be_bundle_t`) — up to 4 decode-ready slots per cycle with `instrs`, `pcs`, `slot_valid`, `pred_npc`, `is_rvc`, `ftq_id`, `fetch_epoch`.

### Frontend (`frontend.sv`)

| Block | Role |
|-------|------|
| **BPU** | Autonomous next-PC into FTQ; stalls when FTQ full. TAGE, stat_corr (SC), loop predictor, ITTAGE, RAS. |
| **FTQ** | BPU↔IFU FIFO: fetch PC, predicted target, epoch, FTQ id; flushed on redirect. |
| **IFU** | Consumes FTQ; ICache + SV32 I-MMU. IPF quiesces fetch until backend trap redirect. |
| **ICache** | 32KB 4-way, 256-bit line, non-blocking refill, 32-entry I-TLB. |
| **Instr aligner** | Expands 4-word fetch group to ≤8 `ibuf_entry_t` (RVC halfword + carry + pred truncation). |
| **IBuffer** | 16-entry FIFO; 4-wide decode-ready dequeue. |

### Backend (`backend.sv`)

| Stage | Role |
|-------|------|
| **Decode** | 4-wide; illegal ops → CSR FU for precise trap. |
| **Rename** | ROB + RAT + stq alloc; stall if RS full. |
| **Issue** | ALU RS (4-way), BRU/CSR single, LSU single (ROB-head CSR ordering). |
| **Execute** | 4× ALU + CSR (`exu/`), LSU group (`lsu/`); see below. |
| **Writeback** | 7 FU → 4 CDB ports; LSU exposes `LOAD_WB_PORTS` load ports + 1 dedicated store port (`stq` completion report). |
| **Commit** | 64-entry ROB, up to 4/cycle (stores 2, branches 1, loads 2 max). Mispredict → flush + FE redirect. |
| **stq** | 32-entry STQ in `backend.sv`: rename alloc, execute fill, store-to-load forwarding, completion report to ROB, senior commit → DCache drain. |

#### EXU (`exu/`)

| Block | Role |
|-------|------|
| **alu ×4** | Integer ALU / BRU execute. |
| **csr** | CSR access, traps, delegation, PLIC/SEIP, counters, `satp`. |

#### LSU (`lsu/`, top `lsu_group.sv`)

| Block | Role |
|-------|------|
| **lsu_agu** | Combinational effective address, alignment, load/store/AMO classify. |
| **lsu_mmu** | SV32 D-MMU + DTLB; req/resp handshake isolated from dispatch. |
| **Dispatch** | Unified admission/backpressure (single `req_valid`/`req_ready`; load/store mutually exclusive per cycle). |
| **ld_pipe ×N** | Pure execute FSM: issue request → wait response → writeback (load/AMO/LR). |
| **stq** | **Single store structure** (instantiated in `backend.sv`, not inside `lsu_group`): rename alloc → execute fill (`ex_*`, addr/data for forwarding + DCache drain) → **completion report** (`st_complete_*` on store admission sets `executed` + trap/violation fields; program-order scan from `head_ptr` drives dedicated store WB port; `st_wb_fire` sets `reported`) → senior `commit_*` → head drain to DCache. Sole store-to-load forwarding source (byte-merge). No separate SQ or internal `store_wb_q`. |
| **lsu_arbiter** | DCache load RR, MMIO, and load writeback lane RR (`LOAD_WB_PORTS`). |
| **ldq** | In-flight load disambiguation queue (depth = ROB depth); holds `{pc, paddr, be, executed}` until commit. Store address resolution CAM detects load–store ordering violations; violation → `st_complete_is_mispred` on the completing store → ROB flush redirect to violating load PC. |

**Store completion path:** `lsu_group` `store_req_fire` → `st_complete_*` into `stq[st_id]` (faulting stores skip `ex_valid` but still complete-report) → `stq` selects oldest `valid && executed && !reported` entry → LSU `STORE_WB_PORT` → ROB/CDB. AMO store side still uses `ex_*` after load-lane AMO completes.

### Cache & Memory

| Component | Notes |
|-----------|-------|
| **ICache** | Tag 19 / index 8 / offset 5; IFU port + refill. |
| **DCache** | Same geometry; LSU load + stq; blocking committed store miss path. |
| **PMA** | Outside `0x80000000`–`0x87FFFFFF` → uncacheable MMIO (UART @ `0xA0000000`, PLIC, VirtIO, …). |
| **C++ platform** | `memory_models.h`: latched UART TX-empty IRQ, PLIC claim/complete; MMIO store pre-tick hook. |
| **Peripherals** | `plic.sv`, `virtio_blk.sv` in RTL; CLINT/timer via C++ → `timer_irq_i`. |

## Build & Verification (summary)

Build from `npc/Makefile`. Host: `-O3`, Verilator `-O3`, default `--threads 2`.

```bash
make -C npc sim IMG=/path/to/test.bin          # DiffTest on if .so present
make -C npc sim DIFFTEST= IMG=...              # off
make -C npc verify-all                         # unit → difftest → assert → cover
```

| Make var | Purpose |
|----------|---------|
| `IMG` | Program image |
| `ARGS` | Simulator flags — see `docs/sim-args.md` |
| `DIFFTEST=` | Disable Spike lockstep |
| `ASSERT=1` | Verilator assertions (rebuild) |
| `TOPNAME` | TB module name |

Full Makefile targets, profile workflow, DiffTest, Linux boot: **`docs/`** (Chinese).

## Documentation Index

| Document | Content |
|----------|---------|
| [docs/README.md](docs/README.md) | Chinese docs hub |
| [docs/build-and-test.md](docs/build-and-test.md) | Makefile targets and variables |
| [docs/profile.md](docs/profile.md) | Performance collection and dashboard |
| [docs/sim-args.md](docs/sim-args.md) | Simulator CLI, snapshot, trace tags |
| [docs/difftest.md](docs/difftest.md) | Spike DiffTest and `ASSERT` |
| [docs/verification.md](docs/verification.md) | `verify-*` gates |
| [docs/bpu-refactor.md](docs/bpu-refactor.md) | BPU refactor methodology, golden baseline |
| [docs/debugging.md](docs/debugging.md) | NDJSON, linux-early-debug |
| [docs/full-system.md](docs/full-system.md) | OpenSBI + Linux + `merge.py` |
| [README.md](README.md) | Human quick start (Chinese) |
| [npc/ref/README.md](npc/ref/README.md) | Spike `.so` build |
| [npc/tools/profiler/README.md](npc/tools/profiler/README.md) | Profiler tools |

---

Simulator: Verilator 5.008. Target: **riscv32im-npc**.
