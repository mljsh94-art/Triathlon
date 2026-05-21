# OpenSBI 移植到 Triathlon NPC

## 背景

将 OpenSBI (M-Mode SBI 固件) 移植到 Triathlon 乱序 RISC-V 处理器上。OpenSBI 将作为 M-Mode 运行时，负责初始化硬件、提供 SBI 调用接口，然后将控制权交给 S-Mode 的操作系统内核。

---

## 当前硬件能力审计

### ✅ 已具备的能力

| 特性 | 状态 | 详情 |
|------|------|------|
| **ISA** | ✅ RV32IMACSU | `CSR_MISA_VALUE = 0x40141105` → I/M/A/C/S/U |
| **特权模式** | ✅ M/S/U 三级 | CSR 中有完整的 `current_priv` 切换逻辑 |
| **M-Mode CSR** | ✅ 完整 | `mstatus`, `mtvec`, `mepc`, `mcause`, `mtval`, `mscratch`, `mie`, `mip`, `misa`, `mhartid`, `mvendorid`, `marchid`, `mimpid`, `medeleg`, `mideleg` |
| **S-Mode CSR** | ✅ 完整 | `sstatus`, `stvec`, `sepc`, `scause`, `stval`, `sscratch`, `sie`, `sip`, `satp` |
| **Trap/异常处理** | ✅ 完整 | ECALL(U/S/M)、EBREAK、MRET、SRET、illegal instruction，且支持 trap delegation (`medeleg`/`mideleg`) |
| **WFI** | ✅ 作为 NOP 处理 | `csr.sv` L342-344 |
| **SFENCE.VMA** | ✅ | 支持 TLB flush |
| **FENCE/FENCE.I** | ✅ | 解码为 `is_fence` |
| **Timer 中断** | ✅ 输入端口 | `timer_irq_i` 作为核顶层输入 |
| **外部中断** | ✅ 输入端口 | `ext_irq_i` 作为核顶层输入 |
| **CLINT (仿真侧)** | ✅ C++ 模型 | `memory_models.h` 中已实现 `mtime`/`mtimecmp` MMIO 读写，地址 `0x02000000` |
| **PLIC (RTL)** | ✅ 简化版 | `plic.sv` 已有单源中断控制器，带 priority/enable/threshold/claim/complete |
| **内存映射** | ✅ 已定义 | `platform_contract.h` 定义了完整的地址映射 |
| **Boot ROM** | ✅ | `0x00001000`，大小 4KB |
| **DTB 地址** | ✅ 预留 | `0x87F00000` |
| **MMU (Sv32)** | ✅ | 支持页表遍历 |

### ⚠️ 需要确认/补充的能力

| 特性 | 状态 | 需要的工作 |
|------|------|-----------|
| **CLINT MMIO 映射到 AXI** | ⚠️ 仅 C++ 仿真模型 | CLINT 的 `mtime`/`mtimecmp` 目前在 Verilator C++ 侧 (`memory_models.h`) 作为 MMIO 被拦截处理。NPC 的 AXI 总线需要能将 `0x02000000` 区域的访问路由到这个模型 |
| **UART 串口** | ⚠️ 待完善 8250 | 当前 UART 是简单的 `0xA00003F8` 写入。已确认使用 UART 8250 驱动，需在 C++ 侧实现极简 8250 模型 |
| **MSWI (软件中断)** | ❌ 未实现 | OpenSBI 使用 ACLINT MSWI 实现核间中断 (IPI)。单核可以 stub 掉 |
| **A 扩展原子操作** | ✅ 已支持 | `lr.w`/`sc.w` 已经支持，满足 OpenSBI 内部锁和原子操作需求 |
| **PMU 计数器** | ⚠️ 读为零 | `csr.sv` 中 `0xB00-0xB1F`, `0xC00-0xC1F` 等地址 read-as-zero，对 OpenSBI 可接受 |
| **mcounteren** | ✅ 可写 | 支持控制 S/U 模式对计数器的访问权限 |

---

## 内存映射 (已定义)

```
0x00001000 - 0x00001FFF  Boot ROM (4KB)
0x02000000 - 0x0200FFFF  CLINT (mtime/mtimecmp/msip)
0x0C000000 - 0x0FFFFFFF  PLIC
0x10001000 - 0x10001FFF  VirtIO Block (placeholder)
0x80000000 - 0x87FFFFFF  Main Memory (128MB)
0x87F00000               DTB 加载地址
0xA0000000               UART/RTC MMIO
```

---

## 设计决策与确认 (已解决)

- **架构选型**：已明确基于 RV32 架构进行移植。
- **A 扩展原子操作**：`lr.w`/`sc.w` 已经支持，不再作为 block 项。
- **UART 模型**：使用 UART 8250 驱动，将在 C++ 仿真侧实现极简 UART 8250 寄存器模型对接。
- **启动地址**：OpenSBI 固件默认从 `0x80000000` 启动。
- **Payload 引导**：移植完成后，引导一个 S-Mode 下的简单 SBI echo 测试程序。

---

## Proposed Changes

### Phase 1: 创建 OpenSBI NPC Platform

#### [NEW] opensbi/platform/triathlon/platform.c
NPC 专属 platform 描述文件。配置：
- CLINT base: `0x02000000`，mtimer freq: `10000000` (10MHz)
- PLIC base: `0x0C000000`，1 个中断源
- UART: `0xA0000000` 或 `0xA00003F8`
- Hart count: 1
- 禁用 MSWI (单核不需要 IPI)

#### [NEW] opensbi/platform/triathlon/objects.mk
平台编译配置：
```makefile
PLATFORM_RISCV_XLEN = 32
PLATFORM_RISCV_ABI = ilp32
PLATFORM_RISCV_ISA = rv32imac
PLATFORM_RISCV_CODE_MODEL = medlow
FW_JUMP=y
FW_JUMP_ADDR=0x80400000      # OpenSBI @0x80000000, payload @0x80400000
FW_JUMP_FDT_ADDR=0x87F00000  # DTB 地址
```

#### [NEW] opensbi/platform/triathlon/Kconfig
平台 Kconfig 入口。

#### [NEW] opensbi/platform/triathlon/triathlon.dts
设备树源文件，描述 NPC SoC 硬件拓扑：
- CPU: rv32imac, mmu-type=sv32
- Memory: `0x80000000` - `0x87FFFFFF` (128MB)
- CLINT: `0x02000000`
- PLIC: `0x0C000000`
- UART: `0xA00003F8` (compatible = "ns8250")

---

### Phase 2: 仿真环境适配

#### [MODIFY] [memory_models.h](file:///e:/vivado_project/OOOcpu_design/Triathlon/npc/csrc/include/memory_models.h)
- 将 UART MMIO 区域扩展为最小的 8250 寄存器集 (THR/LSR/IER)
- 确认 CLINT `mtime` 自增逻辑正确 (每周期 +1 或按频率比例)
- 确认 `mtimecmp` 比较逻辑能正确触发 `timer_irq`

#### [MODIFY] [platform_contract.h](file:///e:/vivado_project/OOOcpu_design/Triathlon/npc/csrc/include/platform_contract.h)
- 如果 UART 基址需要调整以匹配 8250 标准布局 (base + 0~7)，在此更新

---

### Phase 3: 编译与集成

#### 编译 OpenSBI
```bash
cd opensbi
make CROSS_COMPILE=riscv32-unknown-elf- \
     PLATFORM=triathlon \
     PLATFORM_RISCV_XLEN=32 \
     FW_JUMP=y
```

生成 `build/platform/triathlon/firmware/fw_jump.bin`

#### 加载方式
在 Verilator 仿真中，将 `fw_jump.bin` 作为 IMG 加载到 `0x80000000`：
```bash
cd npc
make sim IMG=../opensbi/build/platform/triathlon/firmware/fw_jump.bin
```

---

### Phase 4: 验证

#### 预期行为
1. OpenSBI 启动，初始化 CSR (mtvec, mideleg, medeleg 等)
2. 初始化 CLINT timer
3. 打印 OpenSBI banner 到 UART
4. 跳转到 `FW_JUMP_ADDR` (S-Mode payload)

#### 验证步骤
1. **Step 1**: 先单独编译 OpenSBI，确保交叉编译通过
2. **Step 2**: 编写一个 S-Mode 的简单 SBI echo 测试 payload (在 `0x80400000`)，使用 SBI `ecall` 进行字符收发
3. **Step 3**: 将 OpenSBI + payload 组合成完整的镜像，在 Verilator 仿真中运行
4. **Step 4**: 观察 UART 输出是否有 OpenSBI banner，并测试 echo 测试程序是否正常工作

#### 可能遇到的问题
- UART 驱动初始化失败 → 检查 8250 寄存器模型
- Timer 中断不触发 → 检查 CLINT mtime 自增和 mtimecmp 比较逻辑
- CSR 访问异常 → 检查特权级切换和 CSR 地址映射

---

## Verification Plan

### Automated Tests
1. `make -C opensbi CROSS_COMPILE=riscv32-unknown-elf- PLATFORM=triathlon PLATFORM_RISCV_XLEN=32 FW_JUMP=y` — 编译必须成功
2. `make -C npc sim IMG=fw_jump.bin` — 仿真运行，检查 UART 输出包含 "OpenSBI"
3. 使用 `+npc_diag_trace` 追踪 CSR 写入序列，确认 OpenSBI 的初始化路径

### Manual Verification
- 检查 objdump 输出确认 OpenSBI 入口点在 `0x80000000`
- 对照 Spike 或 QEMU 的 OpenSBI 启动日志，逐步对比 CSR 写入序列
