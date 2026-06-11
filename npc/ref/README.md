# Spike DiffTest Reference (Phase 0)

Spike `rv32imac` / MSU / Sv32 lockstep reference for Triathlon DiffTest.

## Build (WSL/Linux)

```bash
make -C npc/ref              # or: ./build_spike_diff.sh
make -C npc/ref check        # smoke test
make -C npc spike-ref        # same from npc/
```

**Output:** `npc/ref/riscv32-spike-difftest.so`（strip 后约 **4–5 MiB**；未 strip 时因 Spike 静态库携带 debug info 可达 ~100 MiB，属正常现象）

**Dependencies:** `g++`, Spike sources in `src/repo/riscv-isa-sim/` (out-of-tree configure in `src/repo/riscv-isa-sim/build/` on first run).

## API

Exports NEMU-compatible symbols:

- `difftest_init(int port)`
- `difftest_memcpy(uint32_t addr, void *buf, size_t n, bool direction)`
- `difftest_regcpy(void *dut, bool direction)` — buffer layout: `npc/csrc/include/difftest_arch.h` (`DUTCoreState`)
- `difftest_exec(uint64_t n)`
- `difftest_raise_intr(uint64_t cause)` (Phase 2)

## Smoke test

`test_spike_ref` loads the `.so`, writes `addi x1, x0, 42` at `0x80000000`, single-steps Spike, checks `x1==42` and `pc==0x80000004`.

## Mismatch dump demo

`make -C npc/ref demo-mismatch` runs `test_mismatch_dump`: injects `x1=99` vs Spike `x1=42` and prints full DUT/REF architectural state compare (same path as `npc/csrc/lib/difftest_client.cpp`).

## Patches

`src/patches/0001-take-trap-public.patch` — exposes `processor_t::take_trap_public()` for interrupt injection (applied in vendored Spike tree).
